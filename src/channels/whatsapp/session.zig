const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const WhatsAppMessage = types.WhatsAppMessage;
const WhatsAppConfig = types.WhatsAppConfig;
const Debouncer = types.Debouncer;

/// WhatsApp session manager
pub const WhatsAppSession = struct {
    allocator: Allocator,
    config: WhatsAppConfig,

    // Session state
    messages: std.ArrayList(WhatsAppMessage),
    max_messages: usize,
    message_count: u32,

    // Debouncing
    debouncer: Debouncer,

    // Access control state
    paired_senders: std.StringHashMap(void),
    pending_pairing: std.StringHashMap(i64), // sender -> timestamp

    // Group state
    group_participants: std.StringHashMap(std.ArrayList([]const u8)),

    pub fn init(allocator: Allocator, config: WhatsAppConfig, max_messages: usize) WhatsAppSession {
        return .{
            .allocator = allocator,
            .config = config,
            .messages = std.ArrayList(WhatsAppMessage).initCapacity(allocator, 0) catch unreachable,
            .max_messages = max_messages,
            .message_count = 0,
            .debouncer = Debouncer.init(allocator, config.debounce_ms),
            .paired_senders = std.StringHashMap(void).init(allocator),
            .pending_pairing = std.StringHashMap(i64).init(allocator),
            .group_participants = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *WhatsAppSession) void {
        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.deinit();

        self.debouncer.deinit();

        var sender_iter = self.paired_senders.iterator();
        while (sender_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.paired_senders.deinit();

        var pairing_iter = self.pending_pairing.iterator();
        while (pairing_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending_pairing.deinit();

        var group_iter = self.group_participants.iterator();
        while (group_iter.next()) |entry| {
            for (entry.value_ptr.items) |participant| {
                self.allocator.free(participant);
            }
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.group_participants.deinit();
    }

    /// Add a message to the session
    pub fn addMessage(self: *WhatsAppSession, msg: WhatsAppMessage) !void {
        // Enforce message limit
        if (self.messages.items.len >= self.max_messages) {
            self.messages.items[0].deinit();
            _ = self.messages.orderedRemove(0);
        }

        try self.messages.append(msg);
        self.message_count += 1;
    }

    /// Get message history
    pub fn getHistory(self: *WhatsAppSession) []WhatsAppMessage {
        return self.messages.items;
    }

    /// Clear session
    pub fn clear(self: *WhatsAppSession) void {
        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.clearRetainingCapacity();
        self.message_count = 0;
    }

    /// Check if sender is paired
    pub fn isPaired(self: *WhatsAppSession, sender_e164: []const u8) bool {
        return self.paired_senders.contains(sender_e164);
    }

    /// Pair a sender
    pub fn pairSender(self: *WhatsAppSession, sender_e164: []const u8) !void {
        const key = try self.allocator.dupe(u8, sender_e164);
        try self.paired_senders.put(key, {});
    }

    /// Unpair a sender
    pub fn unpairSender(self: *WhatsAppSession, sender_e164: []const u8) void {
        const key = self.paired_senders.fetchRemove(sender_e164);
        if (key) |k| {
            self.allocator.free(k.key);
        }
    }

    /// Generate pairing code
    pub fn generatePairingCode(self: *WhatsAppSession, sender_e164: []const u8) ![]const u8 {
        const code = try std.fmt.allocPrint(self.allocator, "{d}", .{std.crypto.random.int(u32)});
        const key = try self.allocator.dupe(u8, sender_e164);
        try self.pending_pairing.put(key, std.time.timestamp());
        return code;
    }

    /// Validate pairing code
    pub fn validatePairingCode(self: *WhatsAppSession, sender_e164: []const u8, code: []const u8) !bool {
        const entry = self.pending_pairing.fetchRemove(sender_e164) orelse return false;
        defer self.allocator.free(entry.key);

        // Check if code expired (5 minutes)
        const now = std.time.timestamp();
        if (now - entry.value > 300) {
            return false;
        }

        // For simplicity, accept any code for now
        // In production, you'd validate against the stored code
        _ = code;
        return true;
    }

    /// Check access control for a message
    pub fn checkAccessControl(self: *WhatsAppSession, msg: *const WhatsAppMessage) !AccessResult {
        const result = AccessResult{
            .allowed = false,
            .reason = null,
            .pairing_code = null,
        };

        // Check DM policy
        if (msg.isDirect()) {
            switch (self.config.dm_policy) {
                .disabled => {
                    result.reason = "DM access disabled";
                    return result;
                },
                .allowlist => {
                    if (!self.config.isAllowedSender(msg.sender_e164 orelse "")) {
                        result.reason = "Sender not in allowlist";
                        return result;
                    }
                },
                .pairing => {
                    if (!self.isPaired(msg.sender_e164 orelse "")) {
                        // Generate pairing code
                        result.pairing_code = try self.generatePairingCode(msg.sender_e164 orelse "");
                        result.reason = "Sender not paired";
                        return result;
                    }
                },
                .open => {
                    // Allow all DMs
                },
            }
        }

        // Check group policy
        if (msg.isGroup()) {
            switch (self.config.group_policy) {
                .disabled => {
                    result.reason = "Group access disabled";
                    return result;
                },
                .allowlist => {
                    // Check if group is in allowlist
                    var allowed = false;
                    for (self.config.allow_from.items) |allowed_jid| {
                        if (std.mem.eql(u8, allowed_jid, msg.chat_id)) {
                            allowed = true;
                            break;
                        }
                    }
                    if (!allowed) {
                        result.reason = "Group not in allowlist";
                        return result;
                    }
                },
                .open => {
                    // Allow all groups (mention-gated)
                },
            }

            // Check mention requirement
            if (self.config.group_require_mention) {
                if (msg.mentioned_jids.items.len == 0) {
                    result.reason = "Group message requires mention";
                    return result;
                }
            }
        }

        result.allowed = true;
        return result;
    }

    /// Process inbound message with debouncing
    pub fn processInboundMessage(self: *WhatsAppSession, msg: WhatsAppMessage) !ProcessResult {
        // Check access control
        const access = try self.checkAccessControl(&msg);
        if (!access.allowed) {
            return ProcessResult{
                .allowed = false,
                .reason = access.reason,
                .pairing_code = access.pairing_code,
                .message = null,
            };
        }

        // Enqueue for debouncing
        try self.debouncer.enqueue(msg);

        // Check if we should flush
        const key = msg.from;
        if (self.debouncer.shouldFlush(key)) {
            const entries = try self.debouncer.flush(key);

            if (entries.len == 1) {
                // Single message, return as-is
                return ProcessResult{
                    .allowed = true,
                    .reason = null,
                    .pairing_code = null,
                    .message = &entries[0].message,
                };
            } else {
                // Multiple messages, combine them
                const combined = try self.combineMessages(entries);
                return ProcessResult{
                    .allowed = true,
                    .reason = null,
                    .pairing_code = null,
                    .message = combined,
                };
            }
        }

        // Message debounced, wait for more
        return ProcessResult{
            .allowed = true,
            .reason = null,
            .pairing_code = null,
            .message = null,
        };
    }

    /// Combine multiple messages into one
    fn combineMessages(self: *WhatsAppSession, entries: []types.DebouncedEntry) !*WhatsAppMessage {
        const last = &entries[entries.len - 1].message;

        // Combine bodies
        var combined_body = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
        defer combined_body.deinit();

        for (entries) |entry| {
            if (entry.message.body.len > 0) {
                if (combined_body.items.len > 0) {
                    try combined_body.append('\n');
                }
                try combined_body.appendSlice(entry.message.body);
            }
        }

        // Create combined message
        const combined_msg = try self.allocator.create(WhatsAppMessage);
        combined_msg.* = WhatsAppMessage.init(self.allocator);
        combined_msg.id = try self.allocator.dupe(u8, last.id);
        combined_msg.from = try self.allocator.dupe(u8, last.from);
        combined_msg.to = try self.allocator.dupe(u8, last.to);
        combined_msg.chat_id = try self.allocator.dupe(u8, last.chat_id);
        combined_msg.chat_type = last.chat_type;
        combined_msg.sender_jid = try self.allocator.dupe(u8, last.sender_jid);
        if (last.sender_e164) |e164| {
            combined_msg.sender_e164 = try self.allocator.dupe(u8, e164);
        }
        if (last.sender_name) |name| {
            combined_msg.sender_name = try self.allocator.dupe(u8, name);
        }
        combined_msg.body = try combined_body.toOwnedSlice(self.allocator);
        combined_msg.message_type = last.message_type;
        combined_msg.timestamp = last.timestamp;

        // Combine mentioned JIDs
        var mentioned_set = std.StringHashMap(void).init(self.allocator);
        defer {
            var iter = mentioned_set.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            mentioned_set.deinit();
        }

        for (entries) |entry| {
            for (entry.message.mentioned_jids.items) |jid| {
                const key = try self.allocator.dupe(u8, jid);
                try mentioned_set.put(key, {});
            }
        }

        var mentioned_iter = mentioned_set.iterator();
        while (mentioned_iter.next()) |entry| {
            try combined_msg.mentioned_jids.append(try self.allocator.dupe(u8, entry.key_ptr.*));
        }

        return combined_msg;
    }

    /// Update group participants cache
    pub fn updateGroupParticipants(self: *WhatsAppSession, group_jid: []const u8, participants: []const []const u8) !void {
        const gop = try self.group_participants.getOrPut(group_jid);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;
        } else {
            // Clear existing
            for (gop.value_ptr.items) |p| {
                self.allocator.free(p);
            }
            gop.value_ptr.clearRetainingCapacity();
        }

        for (participants) |participant| {
            try gop.value_ptr.append(try self.allocator.dupe(u8, participant));
        }
    }

    /// Get group participants
    pub fn getGroupParticipants(self: *WhatsAppSession, group_jid: []const u8) ?[]const []const u8 {
        return self.group_participants.get(group_jid);
    }
};

/// Access control result
pub const AccessResult = struct {
    allowed: bool,
    reason: ?[]const u8,
    pairing_code: ?[]const u8,
};

/// Process result
pub const ProcessResult = struct {
    allowed: bool,
    reason: ?[]const u8,
    pairing_code: ?[]const u8,
    message: ?*WhatsAppMessage,
};

test "WhatsAppSession init/deinit" {
    const allocator = std.testing.allocator;
    var config = WhatsAppConfig.init(allocator);
    defer config.deinit();

    var session = WhatsAppSession.init(allocator, config, 50);
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 50), session.max_messages);
    try std.testing.expectEqual(@as(u32, 0), session.message_count);
}

test "WhatsAppSession pairing" {
    const allocator = std.testing.allocator;
    var config = WhatsAppConfig.init(allocator);
    defer config.deinit();

    var session = WhatsAppSession.init(allocator, config, 50);
    defer session.deinit();

    const sender = "1234567890";

    try std.testing.expectEqual(false, session.isPaired(sender));
    try session.pairSender(sender);
    try std.testing.expectEqual(true, session.isPaired(sender));
    session.unpairSender(sender);
    try std.testing.expectEqual(false, session.isPaired(sender));
}

test "WhatsAppSession access control" {
    const allocator = std.testing.allocator;
    var config = WhatsAppConfig.init(allocator);
    defer config.deinit();

    config.dm_policy = .pairing;

    var session = WhatsAppSession.init(allocator, config, 50);
    defer session.deinit();

    var msg = WhatsAppMessage.init(allocator);
    defer msg.deinit();
    msg.chat_type = .direct;
    msg.sender_e164 = try allocator.dupe(u8, "1234567890");

    const result = try session.checkAccessControl(&msg);
    try std.testing.expectEqual(false, result.allowed);
    try std.testing.expect(result.pairing_code != null);

    try session.pairSender("1234567890");
    const result2 = try session.checkAccessControl(&msg);
    try std.testing.expectEqual(true, result2.allowed);
}
