const std = @import("std");
const types = @import("types.zig");
const compat = @import("../../compat.zig");

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

    /// Memory: Caller owns returned processor; holds no heap besides borrowed config. Destroy with allocator.destroy if heap-boxed.
    pub fn init(allocator: Allocator, config: WhatsAppConfig) OutboundProcessor {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

/// Memory: Caller owns returned SendResult.message_ids slice and each id string; must free each id with allocator.free and then free the slice with allocator.free.
    /// Send a text message with chunking and retry logic
    /// Memory: Caller owns SendResult.message_ids slices (each id and the array); free both.
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
        var chunks = try self.chunkText(converted);
        defer {
            for (chunks.items) |chunk| {
                self.allocator.free(chunk);
            }
            chunks.deinit(self.allocator);
        }

        var message_ids = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        errdefer {
            for (message_ids.items) |id| {
                self.allocator.free(id);
            }
            message_ids.deinit(self.allocator);
        }

        // Send each chunk; duped ids are owned by the returned result slice.
        for (chunks.items) |chunk| {
            const message_id = try self.sendWithRetry(send_fn, to, chunk);
            try message_ids.append(self.allocator, try self.allocator.dupe(u8, message_id));
        }

        return SendResult{
            .success = true,
            .message_ids = try message_ids.toOwnedSlice(self.allocator),
            .chunk_count = chunks.items.len,
        };
    }

/// Memory: Caller owns returned SendResult.message_ids (single id dupe); must free as above.
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

/// Memory: Caller owns returned SendResult.message_ids; must free with allocator.free.
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

/// Memory: Caller owns returned ArrayList and each chunk string inside; must free each chunk and deinit list with allocator.
    /// Chunk text into smaller pieces
    fn chunkText(self: *OutboundProcessor, text: []const u8) !std.ArrayList([]const u8) {
        var chunks = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);

        if (text.len <= self.text_chunk_limit) {
            try chunks.append(self.allocator, try self.allocator.dupe(u8, text));
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

            try chunks.append(self.allocator, try self.allocator.dupe(u8, text[start..end]));
            start = end;
        }

        return chunks;
    }

/// Memory: Caller owns returned slice; must free with allocator.free.
    /// Convert markdown tables to WhatsApp-compatible format
    fn convertMarkdownTables(self: *OutboundProcessor, text: []const u8) ![]const u8 {
        // Simple table conversion: replace | with spaces
        var result = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '|') {
                try result.append(self.allocator, ' ');
            } else if (text[i] == '\n' and i + 1 < text.len and text[i + 1] == '|') {
                // Table row separator
                try result.append(self.allocator, '\n');
                i += 1;
                while (i < text.len and text[i] != '\n') {
                    if (text[i] == '-' or text[i] == '|') {
                        try result.append(self.allocator, ' ');
                    } else {
                        try result.append(self.allocator, text[i]);
                    }
                    i += 1;
                }
            } else {
                try result.append(self.allocator, text[i]);
            }
            i += 1;
        }

        return result.toOwnedSlice(self.allocator);
    }

/// Memory: Caller owns returned slice (messageId) from underlying send_fn; callee does not dupe - caller of sendWithRetry receives borrowed result from send_fn (but sendText dupes it).
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
                    std.Io.sleep(compat.getIo(), .fromMilliseconds(self.retry_delay_ms), .awake) catch {};
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

/// Memory: Caller owns returned slice; must free with allocator.free.
    /// Convert markdown table to plain text
    pub fn convert(self: *MarkdownTableConverter, markdown: []const u8) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        errdefer result.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, markdown, '\n');

        while (lines.next()) |line| {
            // Skip separator lines
            if (self.isSeparatorLine(line)) {
                continue;
            }

            // Convert table row
            const converted = try self.convertTableRow(line);
            defer self.allocator.free(converted);
            try result.appendSlice(self.allocator, converted);
            try result.append(self.allocator, '\n');
        }

        return result.toOwnedSlice(self.allocator);
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
        var result = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        errdefer result.deinit(self.allocator);

        var cells = std.mem.splitScalar(u8, line, '|');

        while (cells.next()) |cell| {
            const trimmed = std.mem.trim(u8, cell, " \t");
            if (trimmed.len > 0) {
                if (result.items.len > 0) {
                    try result.append(self.allocator, ' ');
                }
                try result.appendSlice(self.allocator, trimmed);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }
};

test "OutboundProcessor chunking" {
    const allocator = std.testing.allocator;
    var config = try WhatsAppConfig.init(allocator);
    defer config.deinit();

    var processor = OutboundProcessor.init(allocator, config);

    const text = "This is a short message";
    var chunks = try processor.chunkText(text);
    defer {
        for (chunks.items) |chunk| allocator.free(chunk);
        chunks.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
}

test "OutboundProcessor table conversion" {
    const allocator = std.testing.allocator;
    var config = try WhatsAppConfig.init(allocator);
    defer config.deinit();

    var processor = OutboundProcessor.init(allocator, config);

    const markdown = "| Header 1 | Header 2 |\n|----------|----------|\n| Cell 1   | Cell 2   |";
    const converted = try processor.convertMarkdownTables(markdown);
    defer allocator.free(converted);

    try std.testing.expect(std.mem.indexOf(u8, converted, "|") == null);
}

test "MarkdownTableConverter basic" {
    const allocator = std.testing.allocator;
    var converter = MarkdownTableConverter.init(allocator);

    const markdown = "| A | B |\n|---|---|\n| 1 | 2 |";
    const converted = try converter.convert(markdown);
    defer allocator.free(converted);

    try std.testing.expect(std.mem.indexOf(u8, converted, "|") == null);
    try std.testing.expect(std.mem.indexOf(u8, converted, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, converted, "B") != null);
}
