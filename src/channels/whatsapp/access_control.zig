const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const WhatsAppMessage = types.WhatsAppMessage;
const WhatsAppConfig = types.WhatsAppConfig;
const DmPolicy = types.DmPolicy;
const GroupPolicy = types.GroupPolicy;

/// Access control result
pub const AccessControlResult = struct {
    allowed: bool,
    reason: ?[]const u8,
    pairing_code: ?[]const u8,
};

/// Access control manager
pub const AccessControl = struct {
    allocator: Allocator,
    config: WhatsAppConfig,

    // Paired senders (for pairing mode)
    paired_senders: std.StringHashMap(void),

    // Pending pairings (sender -> code + timestamp)
    pending_pairings: std.StringHashMap(PendingPairing),

    // Group allowlist
    group_allowlist: std.StringHashMap(void),

    pub fn init(allocator: Allocator, config: WhatsAppConfig) AccessControl {
        return .{
            .allocator = allocator,
            .config = config,
            .paired_senders = std.StringHashMap(void).init(allocator),
            .pending_pairings = std.StringHashMap(PendingPairing).init(allocator),
            .group_allowlist = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *AccessControl) void {
        var sender_iter = self.paired_senders.iterator();
        while (sender_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.paired_senders.deinit();

        var pairing_iter = self.pending_pairings.iterator();
        while (pairing_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.code);
        }
        self.pending_pairings.deinit();

        var group_iter = self.group_allowlist.iterator();
        while (group_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.group_allowlist.deinit();
    }

    /// Check if a message should be allowed
    pub fn checkMessage(self: *AccessControl, msg: *const WhatsAppMessage) !AccessControlResult {
        var result = AccessControlResult{
            .allowed = false,
            .reason = null,
            .pairing_code = null,
        };

        // Check DM access
        if (msg.isDirect()) {
            const dm_result = try self.checkDirectMessage(msg);
            if (!dm_result.allowed) {
                return dm_result;
            }
        }

        // Check group access
        if (msg.isGroup()) {
            const group_result = try self.checkGroupMessage(msg);
            if (!group_result.allowed) {
                return group_result;
            }
        }

        result.allowed = true;
        return result;
    }

    /// Check direct message access
    fn checkDirectMessage(self: *AccessControl, msg: *const WhatsAppMessage) !AccessControlResult {
        var result = AccessControlResult{
            .allowed = false,
            .reason = null,
            .pairing_code = null,
        };

        const sender_e164 = msg.sender_e164 orelse "";

        switch (self.config.dm_policy) {
            .disabled => {
                result.reason = "DM access is disabled";
                return result;
            },
            .allowlist => {
                if (!self.config.isAllowedSender(sender_e164)) {
                    result.reason = "Sender not in allowlist";
                    return result;
                }
            },
            .pairing => {
                if (!self.isPaired(sender_e164)) {
                    // Generate pairing code
                    const code = try self.generatePairingCode(sender_e164);
                    result.pairing_code = code;
                    result.reason = "Sender not paired. Use pairing code to authorize.";
                    return result;
                }
            },
            .open => {
                // Allow all DMs
            },
        }

        result.allowed = true;
        return result;
    }

    /// Check group message access
    fn checkGroupMessage(self: *AccessControl, msg: *const WhatsAppMessage) !AccessControlResult {
        var result = AccessControlResult{
            .allowed = false,
            .reason = null,
            .pairing_code = null,
        };

        switch (self.config.group_policy) {
            .disabled => {
                result.reason = "Group access is disabled";
                return result;
            },
            .allowlist => {
                if (!self.isGroupAllowed(msg.chat_id)) {
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

        result.allowed = true;
        return result;
    }

    /// Check if sender is paired
    pub fn isPaired(self: *AccessControl, sender_e164: []const u8) bool {
        return self.paired_senders.contains(sender_e164);
    }

    /// Pair a sender
    pub fn pairSender(self: *AccessControl, sender_e164: []const u8) !void {
        const key = try self.allocator.dupe(u8, sender_e164);
        try self.paired_senders.put(key, {});
    }

    /// Unpair a sender
    pub fn unpairSender(self: *AccessControl, sender_e164: []const u8) void {
        const key = self.paired_senders.fetchRemove(sender_e164);
        if (key) |k| {
            self.allocator.free(k.key);
        }
    }

    /// Generate pairing code
    pub fn generatePairingCode(self: *AccessControl, sender_e164: []const u8) ![]const u8 {
        const code = try std.fmt.allocPrint(self.allocator, "{d}", .{std.crypto.random.int(u32)});
        const key = try self.allocator.dupe(u8, sender_e164);

        const pairing = PendingPairing{
            .code = code,
            .timestamp = std.time.timestamp(),
        };

        try self.pending_pairings.put(key, pairing);
        return code;
    }

    /// Validate pairing code
    pub fn validatePairingCode(self: *AccessControl, sender_e164: []const u8, code: []const u8) !bool {
        const entry = self.pending_pairings.fetchRemove(sender_e164) orelse return false;
        defer {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.code);
        }

        // Check if code expired (5 minutes)
        const now = std.time.timestamp();
        if (now - entry.value.timestamp > 300) {
            return false;
        }

        // Validate code
        return std.mem.eql(u8, entry.value.code, code);
    }

    /// Check if group is allowed
    pub fn isGroupAllowed(self: *AccessControl, group_jid: []const u8) bool {
        return self.group_allowlist.contains(group_jid);
    }

    /// Add group to allowlist
    pub fn addGroupToAllowlist(self: *AccessControl, group_jid: []const u8) !void {
        const key = try self.allocator.dupe(u8, group_jid);
        try self.group_allowlist.put(key, {});
    }

    /// Remove group from allowlist
    pub fn removeGroupFromAllowlist(self: *AccessControl, group_jid: []const u8) void {
        const key = self.group_allowlist.fetchRemove(group_jid);
        if (key) |k| {
            self.allocator.free(k.key);
        }
    }

    /// Clean up expired pairings
    pub fn cleanupExpiredPairings(self: *AccessControl) !void {
        const now = std.time.timestamp();
        var keys_to_remove = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer {
            for (keys_to_remove.items) |key| {
                self.allocator.free(key);
            }
            keys_to_remove.deinit();
        }

        var iter = self.pending_pairings.iterator();
        while (iter.next()) |entry| {
            if (now - entry.value_ptr.timestamp > 300) {
                keys_to_remove.append(try self.allocator.dupe(u8, entry.key_ptr.*)) catch continue;
            }
        }

        for (keys_to_remove.items) |key| {
            const removed = self.pending_pairings.fetchRemove(key);
            if (removed) |r| {
                self.allocator.free(r.value.code);
            }
        }
    }

    /// Get list of paired senders
    pub fn getPairedSenders(self: *AccessControl) ![][]const u8 {
        var senders = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);

        var iter = self.paired_senders.iterator();
        while (iter.next()) |entry| {
            try senders.append(try self.allocator.dupe(u8, entry.key_ptr.*));
        }

        return senders.toOwnedSlice(self.allocator);
    }

    /// Get list of allowed groups
    pub fn getAllowedGroups(self: *AccessControl) ![][]const u8 {
        var groups = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);

        var iter = self.group_allowlist.iterator();
        while (iter.next()) |entry| {
            try groups.append(try self.allocator.dupe(u8, entry.key_ptr.*));
        }

        return groups.toOwnedSlice(self.allocator);
    }
};

/// Pending pairing information
const PendingPairing = struct {
    code: []const u8,
    timestamp: i64,
};

/// E.164 normalizer
pub const E164Normalizer = struct {
    pub fn normalize(allocator: Allocator, input: []const u8) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer result.deinit();

        // Remove all non-digit characters
        for (input) |c| {
            if (c >= '0' and c <= '9') {
                try result.append(c);
            }
        }

        // Ensure it starts with country code (simplified check)
        if (result.items.len > 0 and result.items[0] != '+') {
            // Assume it needs a + prefix
            try result.insert(0, '+');
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn isValid(input: []const u8) bool {
        if (input.len < 8 or input.len > 15) {
            return false;
        }

        // Check if all characters are digits (after optional +)
        var start: usize = 0;
        if (input[0] == '+') {
            start = 1;
        }

        for (input[start..]) |c| {
            if (c < '0' or c > '9') {
                return false;
            }
        }

        return true;
    }
};

test "AccessControl basic" {
    const allocator = std.testing.allocator;
    var config = try WhatsAppConfig.init(allocator);
    defer config.deinit();

    config.dm_policy = .pairing;

    var access = AccessControl.init(allocator, config);
    defer access.deinit();

    const sender = "1234567890";

    try std.testing.expectEqual(false, access.isPaired(sender));
    try access.pairSender(sender);
    try std.testing.expectEqual(true, access.isPaired(sender));
}

test "AccessControl pairing code" {
    const allocator = std.testing.allocator;
    var config = try WhatsAppConfig.init(allocator);
    defer config.deinit();

    var access = AccessControl.init(allocator, config);
    defer access.deinit();

    const sender = "1234567890";

    const code = try access.generatePairingCode(sender);
    defer allocator.free(code);

    try std.testing.expect(code.len > 0);

    const valid = try access.validatePairingCode(sender, code);
    try std.testing.expectEqual(true, valid);

    const invalid = try access.validatePairingCode(sender, "wrong");
    try std.testing.expectEqual(false, invalid);
}

test "E164Normalizer basic" {
    const allocator = std.testing.allocator;

    const normalized = try E164Normalizer.normalize(allocator, "+1 (555) 123-4567");
    defer allocator.free(normalized);

    try std.testing.expectEqual(true, std.mem.eql(u8, normalized, "+15551234567"));
}

test "E164Normalizer isValid" {
    try std.testing.expectEqual(true, E164Normalizer.isValid("+15551234567"));
    try std.testing.expectEqual(true, E164Normalizer.isValid("15551234567"));
    try std.testing.expectEqual(false, E164Normalizer.isValid("123"));
    try std.testing.expectEqual(false, E164Normalizer.isValid("abc"));
}
