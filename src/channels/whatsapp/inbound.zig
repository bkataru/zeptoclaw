const std = @import("std");
const compat = @import("../../compat.zig");
const types = @import("types.zig");
const session = @import("session.zig");

const Allocator = std.mem.Allocator;
const WhatsAppMessage = types.WhatsAppMessage;
const WhatsAppConfig = types.WhatsAppConfig;
const WhatsAppSession = session.WhatsAppSession;
const ProcessResult = session.ProcessResult;

/// Inbound message processor.
///
/// Dedup has two layers, both required to survive a gateway restart: on
/// reconnect the WhatsApp transport re-requests an offline batch of
/// recently-missed messages (native/client.zig requestOfflineBatch), so a
/// message already processed minutes ago can arrive again as if new.
///   1. `seen_messages`/`seen_order`: exact wire message-id membership, no
///      TTL, capped at `max_seen` (FIFO eviction).
///   2. `fingerprints`: chat+fromMe+body content match within
///      `fingerprint_ttl_ms`, catching the same logical message arriving
///      under a *different* wire id (multi-device fanout/resend).
/// Both persist to `{auth_dir}/gateway-inbound-ledger.json`, mirroring the
/// Baileys wrapper's inbound-ledger.json. Without this, a crash-triggered
/// restart during an unacknowledged inbound message reliably produced
/// duplicate agent replies (observed live 2026-09-03: 12+ duplicate sends
/// to self-chat across a restart storm).
pub const InboundProcessor = struct {
    allocator: Allocator,
    config: WhatsAppConfig,
    whatsapp_session: *WhatsAppSession,

    seen_messages: std.StringHashMap(void),
    seen_order: std.ArrayList([]const u8),
    max_seen: usize = 2000,

    fingerprints: std.StringHashMap(i64),
    fingerprint_ttl_ms: u64 = 3 * 60 * 1000,
    fingerprint_max_age_s: i64 = 24 * 3600,

    ledger_path: ?[]u8 = null,

    pub fn init(allocator: Allocator, config: WhatsAppConfig, whatsapp_session: *WhatsAppSession) InboundProcessor {
        var self: InboundProcessor = .{
            .allocator = allocator,
            .config = config,
            .whatsapp_session = whatsapp_session,
            .seen_messages = std.StringHashMap(void).init(allocator),
            .seen_order = .empty,
            .fingerprints = std.StringHashMap(i64).init(allocator),
        };
        if (config.auth_dir.len > 0) {
            self.ledger_path = std.fmt.allocPrint(allocator, "{s}/gateway-inbound-ledger.json", .{config.auth_dir}) catch null;
        }
        if (self.ledger_path) |path| self.loadLedger(path);
        return self;
    }

    pub fn deinit(self: *InboundProcessor) void {
        var iter = self.seen_messages.keyIterator();
        while (iter.next()) |k| self.allocator.free(k.*);
        self.seen_messages.deinit();
        for (self.seen_order.items) |k| self.allocator.free(k);
        self.seen_order.deinit(self.allocator);
        var fiter = self.fingerprints.keyIterator();
        while (fiter.next()) |k| self.allocator.free(k.*);
        self.fingerprints.deinit();
        if (self.ledger_path) |p| self.allocator.free(p);
    }

/// Memory: Callee borrows `msg` (does not take ownership); returned ProcessResult.message is borrowed from WhatsAppSession.stable_messages (session-owned); pairing_code if set is owned by session and borrowed. Caller must NOT free.
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

    fn fingerprintKey(allocator: Allocator, msg: *const WhatsAppMessage) ![]u8 {
        const clipped = if (msg.body.len > 400) msg.body[0..400] else msg.body;
        return std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ msg.chat_id, if (msg.from_me) "1" else "0", clipped });
    }

    /// Check if message is a duplicate: exact id ever seen, or a matching
    /// content fingerprint within the TTL.
    fn isDuplicate(self: *InboundProcessor, msg: *const WhatsAppMessage) bool {
        const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ msg.chat_id, msg.id }) catch return false;
        defer self.allocator.free(key);
        if (self.seen_messages.contains(key)) return true;

        const fp = fingerprintKey(self.allocator, msg) catch return false;
        defer self.allocator.free(fp);
        if (self.fingerprints.get(fp)) |ts| {
            const now = compat.timestamp();
            const elapsed_ms = (std.math.cast(u64, now - ts) orelse return false) * 1000;
            return elapsed_ms < self.fingerprint_ttl_ms;
        }
        return false;
    }

    fn rememberId(self: *InboundProcessor, msg: *const WhatsAppMessage) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ msg.chat_id, msg.id });
        if (self.seen_messages.contains(key)) {
            self.allocator.free(key);
            return;
        }
        if (self.seen_order.items.len >= self.max_seen) {
            const oldest = self.seen_order.orderedRemove(0);
            _ = self.seen_messages.remove(oldest);
            self.allocator.free(oldest);
        }
        try self.seen_messages.put(key, {});
        const order_copy = self.allocator.dupe(u8, key) catch {
            _ = self.seen_messages.remove(key);
            self.allocator.free(key);
            return;
        };
        self.seen_order.append(self.allocator, order_copy) catch {
            _ = self.seen_messages.remove(key);
            self.allocator.free(key);
            self.allocator.free(order_copy);
            return;
        };
    }

    fn rememberFingerprint(self: *InboundProcessor, msg: *const WhatsAppMessage) !void {
        const fp = try fingerprintKey(self.allocator, msg);
        if (self.fingerprints.getPtr(fp)) |ts_ptr| {
            ts_ptr.* = compat.timestamp();
            self.allocator.free(fp);
            return;
        }
        try self.fingerprints.put(fp, compat.timestamp());
    }

    /// Mark message as seen: records id (capped, FIFO-evicted) and content
    /// fingerprint, then persists to disk so a later restart still knows.
    fn markSeen(self: *InboundProcessor, msg: *const WhatsAppMessage) !void {
        self.rememberId(msg) catch {};
        self.rememberFingerprint(msg) catch {};
        self.saveLedger();
    }

    /// Sweep stale fingerprints. Id-based entries are FIFO-capped inline in
    /// markSeen and never need a time-based sweep.
    pub fn cleanup(self: *InboundProcessor) !void {
        const now = compat.timestamp();
        var keys_to_remove = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer keys_to_remove.deinit(self.allocator);

        var iter = self.fingerprints.iterator();
        while (iter.next()) |entry| {
            if (now - entry.value_ptr.* >= self.fingerprint_max_age_s) {
                try keys_to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }
        for (keys_to_remove.items) |key| {
            if (self.fingerprints.fetchRemove(key)) |kv| self.allocator.free(kv.key);
        }
        self.saveLedger();
    }

    fn jsonEscapeInto(out: *std.ArrayList(u8), allocator: Allocator, s: []const u8) !void {
        try out.append(allocator, '"');
        for (s) |c| {
            switch (c) {
                '"' => try out.appendSlice(allocator, "\\\""),
                '\\' => try out.appendSlice(allocator, "\\\\"),
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                else => try out.append(allocator, c),
            }
        }
        try out.append(allocator, '"');
    }

    /// Best-effort: a ledger write failure only costs replay protection
    /// across the next restart, never the current turn.
    fn saveLedger(self: *InboundProcessor) void {
        const path = self.ledger_path orelse return;
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.allocator);
        out.appendSlice(self.allocator, "{\"seen\":[") catch return;
        for (self.seen_order.items, 0..) |k, i| {
            if (i != 0) out.appendSlice(self.allocator, ",") catch return;
            jsonEscapeInto(&out, self.allocator, k) catch return;
        }
        out.appendSlice(self.allocator, "],\"fp\":{") catch return;
        const now = compat.timestamp();
        var first = true;
        var it = self.fingerprints.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.* > self.fingerprint_max_age_s) continue;
            if (!first) out.appendSlice(self.allocator, ",") catch return;
            first = false;
            jsonEscapeInto(&out, self.allocator, entry.key_ptr.*) catch return;
            out.appendSlice(self.allocator, ":") catch return;
            const num = std.fmt.allocPrint(self.allocator, "{d}", .{entry.value_ptr.*}) catch return;
            defer self.allocator.free(num);
            out.appendSlice(self.allocator, num) catch return;
        }
        out.appendSlice(self.allocator, "}}") catch return;

        const cwd = compat.cwd();
        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.createDirPath(cwd.dir, cwd.io, dir) catch {};
        }
        const f = cwd.createFile(path, .{ .truncate = true }) catch return;
        defer f.close(cwd.io);
        var w = f.writer(cwd.io, &[_]u8{});
        w.interface.writeAll(out.items) catch return;
    }

    fn loadLedger(self: *InboundProcessor, path: []const u8) void {
        const cwd = compat.cwd();
        const f = cwd.openFile(path, .{}) catch return;
        defer f.close(cwd.io);
        const st = f.stat(cwd.io) catch return;
        if (st.kind != .file or st.size == 0) return;
        const sz: usize = @intCast(@min(st.size, @as(u64, 512 * 1024)));
        const buf = self.allocator.alloc(u8, sz) catch return;
        defer self.allocator.free(buf);
        var r = f.reader(cwd.io, &[_]u8{});
        r.interface.readSliceAll(buf) catch return;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, buf, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;

        if (parsed.value.object.get("seen")) |seen_val| {
            if (seen_val == .array) {
                for (seen_val.array.items) |item| {
                    if (item != .string) continue;
                    if (self.seen_order.items.len >= self.max_seen) break;
                    if (self.seen_messages.contains(item.string)) continue;
                    const key_copy = self.allocator.dupe(u8, item.string) catch continue;
                    const order_copy = self.allocator.dupe(u8, item.string) catch {
                        self.allocator.free(key_copy);
                        continue;
                    };
                    self.seen_order.append(self.allocator, order_copy) catch {
                        self.allocator.free(key_copy);
                        self.allocator.free(order_copy);
                        continue;
                    };
                    self.seen_messages.put(key_copy, {}) catch {};
                }
            }
        }

        if (parsed.value.object.get("fp")) |fp_val| {
            if (fp_val == .object) {
                const now = compat.timestamp();
                var it = fp_val.object.iterator();
                while (it.next()) |entry| {
                    const ts: i64 = switch (entry.value_ptr.*) {
                        .integer => |n| n,
                        else => continue,
                    };
                    if (now - ts > self.fingerprint_max_age_s) continue;
                    const key_copy = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                    self.fingerprints.put(key_copy, ts) catch self.allocator.free(key_copy);
                }
            }
        }
    }


/// Memory: Returns borrowed slice from msg.body; do NOT free.
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

/// Memory: Caller owns returned slice; must free with allocator.free.
    /// Format message for agent
    pub fn formatForAgent(msg: *const WhatsAppMessage, allocator: Allocator) ![]const u8 {
        var buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
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
            const now = compat.timestamp();
            const elapsed_ms = (std.math.cast(u64, now - timestamp) orelse return false) * 1000;
            return elapsed_ms < self.ttl_ms;
        }
        return false;
    }

    pub fn markSeen(self: *MessageDeduper, key: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        try self.cache.put(key_copy, compat.timestamp());
    }

    pub fn cleanup(self: *MessageDeduper) !void {
        const now = compat.timestamp();
        var keys_to_remove = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer {
            for (keys_to_remove.items) |key| {
                self.allocator.free(key);
            }
            keys_to_remove.deinit();
        }

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            const elapsed_ms = (std.math.cast(u64, now - entry.value_ptr.*) catch 0) * 1000;
            if (elapsed_ms >= self.ttl_ms) {
                keys_to_remove.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*)) catch continue;
            }
        }

        for (keys_to_remove.items) |key| {
            _ = self.cache.remove(key);
        }
    }
};

fn fillTestMsg(msg: *WhatsAppMessage, id: []const u8, chat_id: []const u8, body: []const u8) !void {
    const a = msg.allocator;
    a.free(msg.id);
    msg.id = try a.dupe(u8, id);
    a.free(msg.chat_id);
    msg.chat_id = try a.dupe(u8, chat_id);
    a.free(msg.body);
    msg.body = try a.dupe(u8, body);
}

fn freePairing(allocator: Allocator, pairing_code: ?[]const u8) void {
    if (pairing_code) |c| allocator.free(c);
}

test "InboundProcessor basic" {
    const allocator = std.testing.allocator;
    var config = try WhatsAppConfig.init(allocator);
    defer config.deinit();

    var whatsapp_session = try WhatsAppSession.init(allocator, config, 50);
    defer whatsapp_session.deinit();

    var processor = InboundProcessor.init(allocator, config, &whatsapp_session);
    defer processor.deinit();

    var msg = try WhatsAppMessage.init(allocator);
    defer msg.deinit();
    try fillTestMsg(&msg, "test123", "1234567890@s.whatsapp.net", "Hello");

    // Default dm_policy is pairing and the sender is unpaired, so the first
    // delivery is policy-denied — but markSeen still records it.
    const result = try processor.process(msg);
    defer freePairing(allocator, result.pairing_code);
    try std.testing.expectEqual(false, result.allowed);
    try std.testing.expectEqualStrings("Sender not paired", result.reason.?);

    const result2 = try processor.process(msg);
    defer freePairing(allocator, result2.pairing_code);
    try std.testing.expectEqual(false, result2.allowed);
    try std.testing.expectEqualStrings("Duplicate message", result2.reason.?);
}

test "InboundProcessor content fingerprint catches same message under a new id" {
    const allocator = std.testing.allocator;
    var config = try WhatsAppConfig.init(allocator);
    defer config.deinit();

    var whatsapp_session = try WhatsAppSession.init(allocator, config, 50);
    defer whatsapp_session.deinit();

    var processor = InboundProcessor.init(allocator, config, &whatsapp_session);
    defer processor.deinit();

    var msg1 = try WhatsAppMessage.init(allocator);
    defer msg1.deinit();
    try fillTestMsg(&msg1, "wire-id-1", "1234567890@s.whatsapp.net", "hi barvis");

    const result1 = try processor.process(msg1);
    defer freePairing(allocator, result1.pairing_code);
    try std.testing.expectEqualStrings("Sender not paired", result1.reason.?);

    // Same chat/body, offline-batch redelivered under a different wire id.
    var msg2 = try WhatsAppMessage.init(allocator);
    defer msg2.deinit();
    try fillTestMsg(&msg2, "wire-id-2", "1234567890@s.whatsapp.net", "hi barvis");

    const result2 = try processor.process(msg2);
    defer freePairing(allocator, result2.pairing_code);
    try std.testing.expectEqual(false, result2.allowed);
    try std.testing.expectEqualStrings("Duplicate message", result2.reason.?);
}

test "InboundProcessor dedup survives a restart via the persisted ledger" {
    const allocator = std.testing.allocator;
    const dir = "/tmp/zeptoclaw-inbound-ledger-test";
    const cwd = compat.cwd();
    cwd.dir.deleteTree(cwd.io, dir) catch {};
    defer cwd.dir.deleteTree(cwd.io, dir) catch {};

    {
        var config = try WhatsAppConfig.init(allocator);
        config.auth_dir = try allocator.dupe(u8, dir);
        defer config.deinit();

        var whatsapp_session = try WhatsAppSession.init(allocator, config, 50);
        defer whatsapp_session.deinit();

        var processor = InboundProcessor.init(allocator, config, &whatsapp_session);
        defer processor.deinit();

        var msg = try WhatsAppMessage.init(allocator);
        defer msg.deinit();
        try fillTestMsg(&msg, "test123", "1234567890@s.whatsapp.net", "hi barvis");

        const result = try processor.process(msg);
        defer freePairing(allocator, result.pairing_code);
        try std.testing.expectEqualStrings("Sender not paired", result.reason.?);
    }

    // Fresh process, same auth_dir: the offline-batch redelivery of the
    // same wire id must still be recognized as a duplicate.
    {
        var config = try WhatsAppConfig.init(allocator);
        config.auth_dir = try allocator.dupe(u8, dir);
        defer config.deinit();

        var whatsapp_session = try WhatsAppSession.init(allocator, config, 50);
        defer whatsapp_session.deinit();

        var processor = InboundProcessor.init(allocator, config, &whatsapp_session);
        defer processor.deinit();

        var msg = try WhatsAppMessage.init(allocator);
        defer msg.deinit();
        try fillTestMsg(&msg, "test123", "1234567890@s.whatsapp.net", "hi barvis");

        const result = try processor.process(msg);
        defer freePairing(allocator, result.pairing_code);
        try std.testing.expectEqual(false, result.allowed);
        try std.testing.expectEqualStrings("Duplicate message", result.reason.?);
    }
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
