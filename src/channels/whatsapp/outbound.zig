const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const WhatsAppConfig = types.WhatsAppConfig;

/// Outbound message processor
pub const OutboundProcessor = struct {
    allocator: Allocator,
    config: WhatsAppConfig,

    // Chunking settings
    text_chunk_limit: usize = 4000,

    // Retry settings
    max_retries: u32 = 3,
    retry_delay_ms: u32 = 1000,

    pub fn init(allocator: Allocator, config: WhatsAppConfig) OutboundProcessor {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Send a text message with chunking and retry logic
    pub fn sendText(
        self: *OutboundProcessor,
        send_fn: *const fn ([]const u8, []const u8) anyerror![]const u8,
        to: []const u8,
        text: []const u8,
    ) !SendResult {
        // Convert markdown tables to WhatsApp-compatible format
        const converted = try self.convertMarkdownTables(text);
        defer self.allocator.free(converted);

        // Chunk if necessary
        const chunks = try self.chunkText(converted);
        defer {
            for (chunks.items) |chunk| {
                self.allocator.free(chunk);
            }
            chunks.deinit();
        }

        var message_ids = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;
        defer {
            for (message_ids.items) |id| {
                self.allocator.free(id);
            }
            message_ids.deinit();
        }

        // Send each chunk
        for (chunks.items) |chunk| {
            const message_id = try self.sendWithRetry(send_fn, to, chunk);
            try message_ids.append(try self.allocator.dupe(u8, message_id));
        }

        return SendResult{
            .success = true,
            .message_ids = message_ids.items,
            .chunk_count = chunks.items.len,
        };
    }

    /// Send a media message
    pub fn sendMedia(
        self: *OutboundProcessor,
        send_fn: *const fn ([]const u8, []const u8, ?[]const u8) anyerror![]const u8,
        to: []const u8,
        media_path: []const u8,
        caption: ?[]const u8,
    ) !SendResult {
        // Check media size
        const file_size = try self.getMediaSize(media_path);
        const max_bytes = self.config.media_max_mb * 1024 * 1024;

        if (file_size > max_bytes) {
            return error.MediaTooLarge;
        }

        // Convert caption if provided
        var converted_caption: ?[]const u8 = null;
        defer {
            if (converted_caption) |cap| self.allocator.free(cap);
        }

        if (caption) |cap| {
            converted_caption = try self.convertMarkdownTables(cap);
        }

        // Send media
        const message_id = try send_fn(to, media_path, converted_caption);

        return SendResult{
            .success = true,
            .message_ids = &[_][]const u8{try self.allocator.dupe(u8, message_id)},
            .chunk_count = 1,
        };
    }

    /// Send a reaction
    pub fn sendReaction(
        send_fn: *const fn ([]const u8, []const u8, []const u8) anyerror!void,
        chat_jid: []const u8,
        message_id: []const u8,
        emoji: []const u8,
    ) !void {
        try send_fn(chat_jid, message_id, emoji);
    }

    /// Send a poll
    pub fn sendPoll(
        self: *OutboundProcessor,
        send_fn: *const fn ([]const u8, types.Poll) anyerror![]const u8,
        to: []const u8,
        poll: types.Poll,
    ) !SendResult {
        const message_id = try send_fn(to, poll);

        return SendResult{
            .success = true,
            .message_ids = &[_][]const u8{try self.allocator.dupe(u8, message_id)},
            .chunk_count = 1,
        };
    }

    /// Chunk text into smaller pieces
    fn chunkText(self: *OutboundProcessor, text: []const u8) !std.ArrayList([]const u8) {
        var chunks = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;

        if (text.len <= self.text_chunk_limit) {
            try chunks.append(try self.allocator.dupe(u8, text));
            return chunks;
        }

        // Split at word boundaries
        var start: usize = 0;
        while (start < text.len) {
            var end = start + self.text_chunk_limit;

            if (end >= text.len) {
                end = text.len;
            } else {
                // Find last space before limit
                while (end > start and text[end] != ' ' and text[end] != '\n') {
                    end -= 1;
                }

                if (end == start) {
                    // No space found, force split
                    end = start + self.text_chunk_limit;
                } else {
                    end += 1; // Include the space
                }
            }

            try chunks.append(try self.allocator.dupe(u8, text[start..end]));
            start = end;
        }

        return chunks;
    }

    /// Convert markdown tables to WhatsApp-compatible format
    fn convertMarkdownTables(self: *OutboundProcessor, text: []const u8) ![]const u8 {
        // Simple table conversion: replace | with spaces
        var result = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
        errdefer result.deinit();

        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '|') {
                try result.append(' ');
            } else if (text[i] == '\n' and i + 1 < text.len and text[i + 1] == '|') {
                // Table row separator
                try result.append('\n');
                i += 1;
                while (i < text.len and text[i] != '\n') {
                    if (text[i] == '-' or text[i] == '|') {
                        try result.append(' ');
                    } else {
                        try result.append(text[i]);
                    }
                    i += 1;
                }
            } else {
                try result.append(text[i]);
            }
            i += 1;
        }

        return result.toOwnedSlice();
    }

    /// Send with retry logic
    fn sendWithRetry(
        self: *OutboundProcessor,
        send_fn: *const fn ([]const u8, []const u8) anyerror![]const u8,
        to: []const u8,
        text: []const u8,
    ) ![]const u8 {
        var retry_count: u32 = 0;

        while (retry_count < self.max_retries) {
            const result = send_fn(to, text) catch |err| {
                retry_count += 1;

                // Check if error is retryable
                if (!self.isRetryableError(err)) {
                    return err;
                }

                // Wait before retry
                if (retry_count < self.max_retries) {
                    std.time.sleep(self.retry_delay_ms * std.time.ns_per_ms);
                }

                continue;
            };

            return result;
        }

        return error.MaxRetriesExceeded;
    }

    /// Check if error is retryable
    fn isRetryableError(self: *OutboundProcessor, err: anyerror) bool {
        _ = self;

        // Common retryable errors
        return err == error.ConnectionReset or
            err == error.ConnectionTimedOut or
            err == error.NetworkUnreachable or
            err == error.TemporaryFailure;
    }

    /// Get media file size
    fn getMediaSize(self: *OutboundProcessor, path: []const u8) !u64 {
        _ = self;

        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        const stat = try file.stat();
        return stat.size;
    }
};

/// Send result
pub const SendResult = struct {
    success: bool,
    message_ids: []const []const u8,
    chunk_count: usize,
};

/// Markdown table converter
pub const MarkdownTableConverter = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) MarkdownTableConverter {
        return .{ .allocator = allocator };
    }

    /// Convert markdown table to plain text
    pub fn convert(self: *MarkdownTableConverter, markdown: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
        errdefer result.deinit();

        var lines = std.mem.splitScalar(u8, markdown, '\n');

        while (lines.next()) |line| {
            // Skip separator lines
            if (self.isSeparatorLine(line)) {
                continue;
            }

            // Convert table row
            const converted = try self.convertTableRow(line);
            try result.appendSlice(converted);
            try result.append('\n');
        }

        return result.toOwnedSlice();
    }

    /// Check if line is a separator line
    fn isSeparatorLine(self: *MarkdownTableConverter, line: []const u8) bool {
        _ = self;

        var has_dash = false;
        var has_pipe = false;

        for (line) |c| {
            if (c == '-') has_dash = true;
            if (c == '|') has_pipe = true;
        }

        return has_dash and has_pipe;
    }

    /// Convert a table row
    fn convertTableRow(self: *MarkdownTableConverter, line: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
        errdefer result.deinit();

        var cells = std.mem.splitScalar(u8, line, '|');

        while (cells.next()) |cell| {
            const trimmed = std.mem.trim(u8, cell, " \t");
            if (trimmed.len > 0) {
                if (result.items.len > 0) {
                    try result.append(' ');
                }
                try result.appendSlice(trimmed);
            }
        }

        return result.toOwnedSlice();
    }
};

test "OutboundProcessor chunking" {
    const allocator = std.testing.allocator;
    var config = WhatsAppConfig.init(allocator);
    defer config.deinit();

    var processor = OutboundProcessor.init(allocator, config);

    const text = "This is a short message";
    const chunks = try processor.chunkText(text);
    defer {
        for (chunks.items) |chunk| allocator.free(chunk);
        chunks.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
}

test "OutboundProcessor table conversion" {
    const allocator = std.testing.allocator;
    var config = WhatsAppConfig.init(allocator);
    defer config.deinit();

    var processor = OutboundProcessor.init(allocator, config);

    const markdown = "| Header 1 | Header 2 |\n|----------|----------|\n| Cell 1   | Cell 2   |";
    const converted = try processor.convertMarkdownTables(markdown);
    defer allocator.free(converted);

    try std.testing.expect(!std.mem.indexOf(u8, converted, "|") != null);
}

test "MarkdownTableConverter basic" {
    const allocator = std.testing.allocator;
    var converter = MarkdownTableConverter.init(allocator);

    const markdown = "| A | B |\n|---|---|\n| 1 | 2 |";
    const converted = try converter.convert(markdown);
    defer allocator.free(converted);

    try std.testing.expect(!std.mem.indexOf(u8, converted, "|") != null);
    try std.testing.expect(std.mem.indexOf(u8, converted, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, converted, "B") != null);
}
