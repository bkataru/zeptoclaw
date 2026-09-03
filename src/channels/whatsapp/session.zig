const std = @import("std");
const compat = @import("../../compat.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const WhatsAppMessage = types.WhatsAppMessage;
const WhatsAppConfig = types.WhatsAppConfig;
const Debouncer = types.Debouncer;

fn jidToE164(jid: []const u8) []const u8 {
    const base = if (std.mem.indexOf(u8, jid, "@s.whatsapp.net")) |idx| jid[0..idx] else if (std.mem.indexOf(u8, jid, "@g.us")) |idx| jid[0..idx] else jid;
    if (std.mem.indexOfScalar(u8, base, ':')) |cidx| return base[0..cidx];
    return base;
}

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

    // Stable copies of flushed messages handed to gateway (id -> *msg)
    stable_messages: std.StringHashMap(*WhatsAppMessage),

    // Rolling per-chat transcript for group pre-context (chat_id -> last N lines).
    // Records ALL group traffic (even when policy blocks replies) per openclaw
    // "50-msg pre-context window since our last reply" mechanics.
    group_transcripts: std.StringHashMap(std.ArrayList([]const u8)),

    /// Memory: Caller owns returned session; must call deinit(). `config` is borrowed.
    pub fn init(allocator: Allocator, config: WhatsAppConfig, max_messages: usize) !WhatsAppSession {
        return .{
            .allocator = allocator,
            .config = config,
            .messages = try std.ArrayList(WhatsAppMessage).initCapacity(allocator, 0),
            .max_messages = max_messages,
            .message_count = 0,
            .debouncer = Debouncer.init(allocator, config.debounce_ms),
            .paired_senders = std.StringHashMap(void).init(allocator),
            .pending_pairing = std.StringHashMap(i64).init(allocator),
            .group_participants = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .stable_messages = std.StringHashMap(*WhatsAppMessage).init(allocator),
            .group_transcripts = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
    }

    /// Memory: Callee takes responsibility for stored messages, pairing maps, and transcripts.
    pub fn deinit(self: *WhatsAppSession) void {
        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.deinit(self.allocator);

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
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.group_participants.deinit();

        var stable_iter = self.stable_messages.iterator();
        while (stable_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.stable_messages.deinit();

        var gt_iter = self.group_transcripts.iterator();
        while (gt_iter.next()) |entry| {
            for (entry.value_ptr.items) |line| self.allocator.free(line);
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.group_transcripts.deinit();
    }

    /// Add a message to the session (deep-copies; history owns the copy).
/// Memory: Callee duplicates `msg` via `dupeAlloc`; caller retains ownership of `msg` and must still `deinit()` it. History copy is freed by `WhatsAppSession.deinit` / `clear`.
    /// Memory: Callee deep-copies `msg` into session-owned storage; caller retains original `msg`.
    pub fn addMessage(self: *WhatsAppSession, msg: WhatsAppMessage) !void {
        // Deep-copy so history owning its own body/id/chat_id survives the debouncer
        // pruning `effective_msg`'s backing storage. A shallow store left dangling
        // pointers that segfaulted utf8ValidateSlice during request serialization.
        var owned = try msg.dupeAlloc();
        errdefer owned.deinit();

        // Enforce message limit
        if (self.messages.items.len >= self.max_messages) {
            self.messages.items[0].deinit();
            _ = self.messages.orderedRemove(0);
        }

        try self.messages.append(self.allocator, owned);
        self.message_count += 1;
    }

    /// Get message history (borrowed slice).
/// Memory: Caller borrows the returned slice; do NOT free. Slice invalidated by `addMessage`, `clear`, or `deinit`.
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

    /// Generate pairing code for sender.
/// Memory: Caller owns returned slice; must free with `allocator.free`.
    /// Memory: Caller owns returned pairing code slice; must free with session allocator.
    pub fn generatePairingCode(self: *WhatsAppSession, sender_e164: []const u8) ![]const u8 {
        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(compat.timestamp())));
        const code = try std.fmt.allocPrint(self.allocator, "{d}", .{prng.random().int(u32)});
        const key = try self.allocator.dupe(u8, sender_e164);
        try self.pending_pairing.put(key, compat.timestamp());
        return code;
    }

    /// Validate pairing code
    pub fn validatePairingCode(self: *WhatsAppSession, sender_e164: []const u8, code: []const u8) !bool {
        const entry = self.pending_pairing.fetchRemove(sender_e164) orelse return false;
        defer self.allocator.free(entry.key);

        // Check if code expired (5 minutes)
        const now = compat.timestamp();
        if (now - entry.value > 300) {
            return false;
        }

        // For simplicity, accept any code for now
        // In production, you'd validate against the stored code
        _ = code;
        return true;
    }

    /// Check access control for a message.
/// Memory: Caller owns `AccessResult.pairing_code` if non-null; must free with `allocator.free`. `reason` is a static string, not owned.
    pub fn checkAccessControl(self: *WhatsAppSession, msg: *const WhatsAppMessage) !AccessResult {
        var result = AccessResult{
            .allowed = false,
            .reason = null,
            .pairing_code = null,
        };

        // Symmetric DM wake: fromMe DMs are own messages; only allow when peer is allowlisted.
        // Peer is inferred from chat_id (the 1:1 JID). Without from_me awareness the
        // old baileys_wrapper unconditionally dropped fromMe; new wrapper only forwards
        // fromMe when peer ∈ allowFrom. Here we double-guard: drop stray fromMe DMs.
        if (msg.isDirect() and msg.from_me) {
            // LID self-chat ("Message yourself" on new WA clients): chat_id ends '@lid',
            // digits are NOT a phone number. fromMe + @lid = Baala talking to himself -> allow.
            const is_lid_chat = std.mem.endsWith(u8, msg.chat_id, "@lid");
            const peer_e164 = jidToE164(msg.chat_id);
            if (!is_lid_chat) {
                if (peer_e164.len == 0 or !self.config.isAllowedSender(peer_e164)) {
                    result.reason = "fromMe DM with non-allowlisted peer";
                    return result;
                }
            }
            // Allowlisted peer DM: treat own fromMe as inbound (sender_e164 is self).
        }

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
    /// Record a message line into the per-chat rolling transcript (max 50 entries).
    fn recordTranscript(self: *WhatsAppSession, chat_id: []const u8, who: []const u8, body: []const u8) void {
        if (std.mem.indexOf(u8, chat_id, "@g.us") == null) return; // groups only
        const gop = self.group_transcripts.getOrPut(chat_id) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, chat_id) catch {
                _ = self.group_transcripts.remove(chat_id);
                return;
            };
            gop.value_ptr.* = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch return;
        }
        const blen = @min(body.len, 300);
        const line = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ who, body[0..blen] }) catch return;
        gop.value_ptr.append(self.allocator, line) catch {
            self.allocator.free(line);
            return;
        };
        if (gop.value_ptr.items.len > 50) {
            const old_line = gop.value_ptr.orderedRemove(0);
            self.allocator.free(old_line);
        }
    }

    /// Snapshot of last-50 group transcript lines as owned context text.
/// Memory: Caller owns returned slice; must free with `alloc.free` when done. Returns null if no transcript.
    pub fn groupPreContext(self: *WhatsAppSession, alloc: std.mem.Allocator, chat_id: []const u8) ?[]const u8 {
        const list = self.group_transcripts.get(chat_id) orelse return null;
        if (list.items.len == 0) return null;
        var out = std.ArrayList(u8).initCapacity(alloc, 2048) catch return null;
        errdefer out.deinit(alloc);
        out.appendSlice(alloc, "\n--- Group conversation before your reply (context only) ---\n") catch return null;
        for (list.items) |line| {
            out.appendSlice(alloc, line) catch return null;
            out.appendSlice(alloc, "\n") catch return null;
        }
        out.appendSlice(alloc, "--- End group context ---\n") catch return null;
        return out.toOwnedSlice(alloc) catch null;
    }

    /// Process inbound message (access control + debouncing). May produce a `ProcessResult.message`.
/// Memory: Callee takes ownership of `msg` (enqueues / consumes). Returned `ProcessResult.message` is owned by the session's `stable_messages`; caller borrows it (do NOT free / deinit) until session eviction/prune.
    pub fn processInboundMessage(self: *WhatsAppSession, msg: WhatsAppMessage) !ProcessResult {
        // Record into rolling group transcript BEFORE policy gate: pre-context needs all traffic.
        {
            const who: []const u8 = if (msg.from_me) "Barvis" else (msg.sender_name orelse (msg.sender_e164 orelse msg.from));
            self.recordTranscript(msg.chat_id, who, msg.body);
        }
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
            var entries_list = try self.debouncer.flush(key);
            defer entries_list.deinit(self.allocator);
            const entries = entries_list.items;

            // Deep-copy the flushed message into stable storage owned by the session.
            // entries[] memory dies on return; ProcessResult.message must outlive it.
            const src = if (entries.len == 1) &entries[0].message else blk: {
                const combined = try self.combineMessages(entries);
                defer combined.deinit();
                break :blk combined;
            };
            var copy_val = try src.dupeAlloc();
            errdefer copy_val.deinit();
            // Prune old stable copies beyond a small bound
            if (self.stable_messages.count() >= 16) {
                var it = self.stable_messages.iterator();
                if (it.next()) |kv| {
                    const old_key = kv.key_ptr.*;
                    const old_msg = kv.value_ptr.*;
                    _ = self.stable_messages.remove(old_key);
                    self.allocator.free(old_key);
                    old_msg.deinit();
                    self.allocator.destroy(old_msg);
                }
            }
            const boxed = try self.allocator.create(WhatsAppMessage);
            boxed.* = copy_val;
            const key_copy = try self.allocator.dupe(u8, boxed.id);
            try self.stable_messages.put(key_copy, boxed);
            return ProcessResult{
                .allowed = true,
                .reason = null,
                .pairing_code = null,
                .message = boxed,
            };
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
        var combined_body = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer combined_body.deinit(self.allocator);

        for (entries) |entry| {
            if (entry.message.body.len > 0) {
                if (combined_body.items.len > 0) {
                    try combined_body.append(self.allocator, '\n');
                }
                try combined_body.appendSlice(self.allocator, entry.message.body);
            }
        }

        // Create combined message
        const combined_msg = try self.allocator.create(WhatsAppMessage);
        combined_msg.* = try WhatsAppMessage.init(self.allocator);
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
            try combined_msg.mentioned_jids.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*));
        }

        return combined_msg;
    }

    /// Update group participants cache
    pub fn updateGroupParticipants(self: *WhatsAppSession, group_jid: []const u8, participants: []const []const u8) !void {
        const gop = try self.group_participants.getOrPut(group_jid);
        if (!gop.found_existing) {
            gop.value_ptr.* = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
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
    var config = try WhatsAppConfig.init(allocator);
    defer config.deinit();

    var session = try WhatsAppSession.init(allocator, config, 50);
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 50), session.max_messages);
    try std.testing.expectEqual(@as(u32, 0), session.message_count);
}

test "WhatsAppSession pairing" {
    const allocator = std.testing.allocator;
    var config = try WhatsAppConfig.init(allocator);
    defer config.deinit();

    var session = try WhatsAppSession.init(allocator, config, 50);
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
    var config = try WhatsAppConfig.init(allocator);
    defer config.deinit();

    config.dm_policy = .pairing;

    var session = try WhatsAppSession.init(allocator, config, 50);
    defer session.deinit();

    var msg = try WhatsAppMessage.init(allocator);
    defer msg.deinit();
    msg.chat_type = .direct;
    msg.sender_e164 = try allocator.dupe(u8, "1234567890");

    const result = try session.checkAccessControl(&msg);
    defer if (result.pairing_code) |c| allocator.free(c);
    try std.testing.expectEqual(false, result.allowed);
    try std.testing.expect(result.pairing_code != null);

    try session.pairSender("1234567890");
    const result2 = try session.checkAccessControl(&msg);
    defer if (result2.pairing_code) |c| allocator.free(c);
    try std.testing.expectEqual(true, result2.allowed);
}
