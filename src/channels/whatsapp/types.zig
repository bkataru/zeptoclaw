const std = @import("std");

/// WhatsApp message types
pub const MessageType = enum {
    text,
    image,
    video,
    audio,
    document,
    location,
    poll,
    reaction,
    unknown,
};

/// Chat types
pub const ChatType = enum {
    direct,
    group,
};

/// Connection status
pub const ConnectionStatus = enum {
    disconnected,
    connecting,
    connected,
    logged_out,
};

/// DM policy types
pub const DmPolicy = enum {
    allowlist,
    pairing,
    open,
    disabled,
};

/// Group policy types
pub const GroupPolicy = enum {
    allowlist,
    open,
    disabled,
};

/// Location data
pub const Location = struct {
    latitude: f64,
    longitude: f64,
};

/// Reply context
pub const ReplyContext = struct {
    message_id: []const u8,
    participant: ?[]const u8,
    quoted_message: ?[]const u8,
};

/// WhatsApp message
pub const WhatsAppMessage = struct {
    allocator: std.mem.Allocator,

    // Message identifiers
    id: []const u8,
    from: []const u8, // E.164 for DM, JID for group
    to: []const u8, // Self E.164
    chat_id: []const u8, // JID
    chat_type: ChatType,

    // Sender information
    sender_jid: []const u8,
    sender_e164: ?[]const u8,
    sender_name: ?[]const u8,

    // Message content
    body: []const u8,
    message_type: MessageType,
    media_type: ?[]const u8,
    location: ?Location,

    // Metadata
    mentioned_jids: std.ArrayList([]const u8),
    reply_context: ?ReplyContext,
    timestamp: i64,

    pub fn init(allocator: std.mem.Allocator) !WhatsAppMessage {
        return .{
            .allocator = allocator,
            .id = "",
            .from = "",
            .to = "",
            .chat_id = "",
            .chat_type = .direct,
            .sender_jid = "",
            .sender_e164 = null,
            .sender_name = null,
            .body = "",
            .message_type = .text,
            .media_type = null,
            .location = null,
            .mentioned_jids = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .reply_context = null,
            .timestamp = 0,
        };
    }

    pub fn deinit(self: *WhatsAppMessage) void {
        self.allocator.free(self.id);
        self.allocator.free(self.from);
        self.allocator.free(self.to);
        self.allocator.free(self.chat_id);
        self.allocator.free(self.sender_jid);
        if (self.sender_e164) |s| self.allocator.free(s);
        if (self.sender_name) |s| self.allocator.free(s);
        self.allocator.free(self.body);
        if (self.media_type) |s| self.allocator.free(s);
        if (self.location) |*loc| {
            _ = loc;
            // Location is a value type, no cleanup needed
        }
        for (self.mentioned_jids.items) |jid| {
            self.allocator.free(jid);
        }
        self.mentioned_jids.deinit(self.allocator);
        if (self.reply_context) |*ctx| {
            self.allocator.free(ctx.message_id);
            if (ctx.participant) |p| self.allocator.free(p);
            if (ctx.quoted_message) |q| self.allocator.free(q);
        }
    }

    pub fn isGroup(self: *const WhatsAppMessage) bool {
        return self.chat_type == .group;
    }

    pub fn isDirect(self: *const WhatsAppMessage) bool {
        return self.chat_type == .direct;
    }

    pub fn hasMedia(self: *const WhatsAppMessage) bool {
        return self.message_type != .text and self.message_type != .reaction and self.message_type != .poll;
    }
};

/// Poll option
pub const PollOption = struct {
    name: []const u8,
};

/// Poll data
pub const Poll = struct {
    name: []const u8,
    options: []PollOption,
    selectable_count: u32,
};

/// Connection update event
pub const ConnectionUpdate = struct {
    status: ConnectionStatus,
    self_jid: ?[]const u8,
    self_e164: ?[]const u8,
    @"error": ?[]const u8,
};

/// QR code event
pub const QrEvent = struct {
    qr: []const u8,
};

/// WhatsApp configuration
pub const WhatsAppConfig = struct {
    allocator: std.mem.Allocator,

    enabled: bool,
    auth_dir: []const u8,

    // Access control
    dm_policy: DmPolicy,
    allow_from: std.ArrayList([]const u8),
    group_policy: GroupPolicy,

    // Message handling
    media_max_mb: u32,
    debounce_ms: u32,
    send_read_receipts: bool,

    // Group settings
    group_require_mention: bool,
    group_activation_commands: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) !WhatsAppConfig {
        return .{
            .allocator = allocator,
            .enabled = false,
            .auth_dir = "",
            .dm_policy = .pairing,
            .allow_from = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .group_policy = .allowlist,
            .media_max_mb = 50,
            .debounce_ms = 0,
            .send_read_receipts = true,
            .group_require_mention = true,
            .group_activation_commands = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *WhatsAppConfig) void {
        self.allocator.free(self.auth_dir);
        for (self.allow_from.items) |item| {
            self.allocator.free(item);
        }
        self.allow_from.deinit(self.allocator);
        for (self.group_activation_commands.items) |item| {
            self.allocator.free(item);
        }
        self.group_activation_commands.deinit(self.allocator);
    }

    pub fn isAllowedSender(self: *const WhatsAppConfig, sender_e164: []const u8) bool {
        // Check wildcard
        for (self.allow_from.items) |item| {
            if (std.mem.eql(u8, item, "*")) {
                return true;
            }
        }

        // Check exact match
        for (self.allow_from.items) |item| {
            if (std.mem.eql(u8, item, sender_e164)) {
                return true;
            }
        }

        return false;
    }
};

/// Send message options
pub const SendMessageOptions = struct {
    media_url: ?[]const u8 = null,
    caption: ?[]const u8 = null,
    gif_playback: bool = false,
};

/// Send reaction options
pub const SendReactionOptions = struct {
    from_me: bool = false,
    participant: ?[]const u8 = null,
    remove: bool = false,
};

/// Debounced message entry
pub const DebouncedEntry = struct {
    message: WhatsAppMessage,
    timestamp: i64,
};

/// Debouncer state
pub const Debouncer = struct {
    allocator: std.mem.Allocator,
    debounce_ms: u32,
    entries: std.StringHashMap(std.ArrayList(DebouncedEntry)),
    last_flush: std.StringHashMap(i64),

    pub fn init(allocator: std.mem.Allocator, debounce_ms: u32) Debouncer {
        return .{
            .allocator = allocator,
            .debounce_ms = debounce_ms,
            .entries = std.StringHashMap(std.ArrayList(DebouncedEntry)).init(allocator),
            .last_flush = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *Debouncer) void {
        var entry_iter = self.entries.iterator();
        while (entry_iter.next()) |entry| {
            for (entry.value_ptr.items) |*deb| {
                deb.message.deinit();
            }
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();

        var flush_iter = self.last_flush.iterator();
        while (flush_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.last_flush.deinit();
    }

    pub fn enqueue(self: *Debouncer, message: WhatsAppMessage) !void {
        const key = try self.allocator.dupe(u8, message.from);

        const gop = try self.entries.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = try std.ArrayList(DebouncedEntry).initCapacity(self.allocator, 0);
        }

        try gop.value_ptr.append(self.allocator, .{
            .message = message,
            .timestamp = std.time.timestamp(),
        });
    }

    pub fn shouldFlush(self: *Debouncer, key: []const u8) bool {
        const now = std.time.timestamp();
        const last_flush_ms = self.last_flush.get(key) orelse 0;
        return (now - last_flush_ms) * 1000 >= self.debounce_ms;
    }

    pub fn flush(self: *Debouncer, key: []const u8) ![]DebouncedEntry {
        const entries = self.entries.fetchRemove(key) orelse return &[_]DebouncedEntry{};
        defer {
            self.allocator.free(key);
            entries.value.deinit(self.allocator);
        }

        try self.last_flush.put(try self.allocator.dupe(u8, key), std.time.timestamp());

        return entries.value.items;
    }
};

test "WhatsAppMessage init/deinit" {
    const allocator = std.testing.allocator;
    var msg = try WhatsAppMessage.init(allocator);
    defer msg.deinit();

    try std.testing.expectEqual(@as(usize, 0), msg.id.len);
    try std.testing.expectEqual(ChatType.direct, msg.chat_type);
}

test "WhatsAppConfig init/deinit" {
    const allocator = std.testing.allocator;
    var cfg = try WhatsAppConfig.init(allocator);
    defer cfg.deinit();

    try std.testing.expectEqual(false, cfg.enabled);
    try std.testing.expectEqual(DmPolicy.pairing, cfg.dm_policy);
}

test "Debouncer basic" {
    const allocator = std.testing.allocator;
    var debouncer = Debouncer.init(allocator, 1000);
    defer debouncer.deinit();

    var msg = try WhatsAppMessage.init(allocator);
    // removed: defer msg.deinit() to avoid double free with enqueue copy
    msg.from = try allocator.dupe(u8, "1234567890");

    try debouncer.enqueue(msg);
    try std.testing.expect(debouncer.shouldFlush("1234567890"));
}
