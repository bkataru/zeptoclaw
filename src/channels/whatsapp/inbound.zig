const std = @import("std");
const types = @import("types.zig");
const session = @import("session.zig");

const Allocator = std.mem.Allocator;
const WhatsAppMessage = types.WhatsAppMessage;
const WhatsAppConfig = types.WhatsAppConfig;
const WhatsAppSession = session.WhatsAppSession;
const ProcessResult = session.ProcessResult;

/// Inbound message processor
pub const InboundProcessor = struct {
    allocator: Allocator,
    config: WhatsAppConfig,
    whatsapp_session: *WhatsAppSession,

    // Deduplication cache
    seen_messages: std.StringHashMap(i64),
    dedupe_ttl_ms: u64 = 60000, // 1 minute

    pub fn init(allocator: Allocator, config: WhatsAppConfig, whatsapp_session: *WhatsAppSession) InboundProcessor {
        return .{
            .allocator = allocator,
            .config = config,
            .whatsapp_session = whatsapp_session,
            .seen_messages = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *InboundProcessor) void {
        var iter = self.seen_messages.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.seen_messages.deinit();
    }

    /// Process an inbound message
    pub fn process(self: *InboundProcessor, msg: WhatsAppMessage) !ProcessResult {
        // Check for duplicates
        if (self.isDuplicate(&msg)) {
            return ProcessResult{
                .allowed = false,
                .reason = "Duplicate message",
                .pairing_code = null,
                .message = null,
            };
        }

        // Mark as seen
        try self.markSeen(&msg);

        // Process through session (access control + debouncing)
        return try self.whatsapp_session.processInboundMessage(msg);
    }

    /// Check if message is a duplicate
    fn isDuplicate(self: *InboundProcessor, msg: *const WhatsAppMessage) bool {
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ msg.chat_id, msg.id });
        defer self.allocator.free(key);

        if (self.seen_messages.get(key)) |timestamp| {
            const now = std.time.timestamp();
            const elapsed_ms = @as(u64, @intCast(now - timestamp)) * 1000;
            return elapsed_ms < self.dedupe_ttl_ms;
        }

        return false;
    }

    /// Mark message as seen
    fn markSeen(self: *InboundProcessor, msg: *const WhatsAppMessage) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ msg.chat_id, msg.id });
        errdefer self.allocator.free(key);

        try self.seen_messages.put(key, std.time.timestamp());
    }

    /// Clean up old entries from deduplication cache
    pub fn cleanup(self: *InboundProcessor) void {
        const now = std.time.timestamp();
        var keys_to_remove = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;
        defer {
            for (keys_to_remove.items) |key| {
                self.allocator.free(key);
            }
            keys_to_remove.deinit();
        }

        var iter = self.seen_messages.iterator();
        while (iter.next()) |entry| {
            const elapsed_ms = @as(u64, @intCast(now - entry.value_ptr.*)) * 1000;
            if (elapsed_ms >= self.dedupe_ttl_ms) {
                keys_to_remove.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*)) catch continue;
            }
        }

        for (keys_to_remove.items) |key| {
            _ = self.seen_messages.remove(key);
        }
    }

    /// Extract text from message
    pub fn extractText(msg: *const WhatsAppMessage) []const u8 {
        return msg.body;
    }

    /// Extract mentions from message
    pub fn extractMentions(msg: *const WhatsAppMessage) []const []const u8 {
        return msg.mentioned_jids.items;
    }

    /// Check if message mentions bot
    pub fn mentionsBot(msg: *const WhatsAppMessage, bot_e164: ?[]const u8) bool {
        if (bot_e164 == null) return false;

        for (msg.mentioned_jids.items) |jid| {
            // Convert JID to E.164 for comparison
            const e164 = jidToE164(jid);
            if (std.mem.eql(u8, e164, bot_e164.?)) {
                return true;
            }
        }

        return false;
    }

    /// Convert JID to E.164
    fn jidToE164(jid: []const u8) []const u8 {
        if (std.mem.indexOf(u8, jid, "@s.whatsapp.net")) |idx| {
            return jid[0..idx];
        }
        return jid;
    }

    /// Format message for agent
    pub fn formatForAgent(msg: *const WhatsAppMessage, allocator: Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
        defer buffer.deinit();

        // Add sender info
        if (msg.sender_name) |name| {
            try buffer.appendSlice(name);
            try buffer.append(allocator, ' ');
        }

        if (msg.sender_e164) |e164| {
            try buffer.appendSlice("(");
            try buffer.appendSlice(e164);
            try buffer.appendSlice(")");
        }

        try buffer.appendSlice(":\n");

        // Add message body
        try buffer.appendSlice(msg.body);

        // Add location if present
        if (msg.location) |loc| {
            try buffer.appendSlice("\n📍 Location: ");
            try std.fmt.format(buffer.writer(), "{d:.6}, {d:.6}", .{ loc.latitude, loc.longitude });
        }

        // Add reply context if present
        if (msg.reply_context) |ctx| {
            try buffer.appendSlice("\n\nReplying to: ");
            if (ctx.quoted_message) |quoted| {
                try buffer.appendSlice(quoted);
            }
        }

        return buffer.toOwnedSlice(allocator);
    }
};

/// Message deduplication cache
pub const MessageDeduper = struct {
    allocator: Allocator,
    cache: std.StringHashMap(i64),
    ttl_ms: u64,

    pub fn init(allocator: Allocator, ttl_ms: u64) MessageDeduper {
        return .{
            .allocator = allocator,
            .cache = std.StringHashMap(i64).init(allocator),
            .ttl_ms = ttl_ms,
        };
    }

    pub fn deinit(self: *MessageDeduper) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.deinit();
    }

    pub fn isDuplicate(self: *MessageDeduper, key: []const u8) bool {
        if (self.cache.get(key)) |timestamp| {
            const now = std.time.timestamp();
            const elapsed_ms = @as(u64, @intCast(now - timestamp)) * 1000;
            return elapsed_ms < self.ttl_ms;
        }
        return false;
    }

    pub fn markSeen(self: *MessageDeduper, key: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        try self.cache.put(key_copy, std.time.timestamp());
    }

    pub fn cleanup(self: *MessageDeduper) void {
        const now = std.time.timestamp();
        var keys_to_remove = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;
        defer {
            for (keys_to_remove.items) |key| {
                self.allocator.free(key);
            }
            keys_to_remove.deinit();
        }

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            const elapsed_ms = @as(u64, @intCast(now - entry.value_ptr.*)) * 1000;
            if (elapsed_ms >= self.ttl_ms) {
                keys_to_remove.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*)) catch continue;
            }
        }

        for (keys_to_remove.items) |key| {
            _ = self.cache.remove(key);
        }
    }
};

test "InboundProcessor basic" {
    const allocator = std.testing.allocator;
    var config = WhatsAppConfig.init(allocator);
    defer config.deinit();

    var whatsapp_session = WhatsAppSession.init(allocator, config, 50);
    defer whatsapp_session.deinit();

    var processor = InboundProcessor.init(allocator, config, &whatsapp_session);
    defer processor.deinit();

    var msg = WhatsAppMessage.init(allocator);
    defer msg.deinit();
    msg.id = "test123";
    msg.chat_id = "1234567890@s.whatsapp.net";
    msg.body = "Hello";

    const result = try processor.process(msg);
    try std.testing.expectEqual(true, result.allowed);

    // Test duplicate detection
    const result2 = try processor.process(msg);
    try std.testing.expectEqual(false, result2.allowed);
}

test "MessageDeduper basic" {
    const allocator = std.testing.allocator;
    var deduper = MessageDeduper.init(allocator, 60000);
    defer deduper.deinit();

    const key = "test:message:id";

    try std.testing.expectEqual(false, deduper.isDuplicate(key));
    try deduper.markSeen(key);
    try std.testing.expectEqual(true, deduper.isDuplicate(key));
}
