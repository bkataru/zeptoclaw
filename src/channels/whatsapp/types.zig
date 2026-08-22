const std = @import("std");
const compat = @import("../../compat.zig");

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
    media_path: ?[]const u8 = null,
    location: ?Location,

    // Metadata
    mentioned_jids: std.ArrayList([]const u8),
    reply_context: ?ReplyContext,
    timestamp: i64,
    from_me: bool = false,

    /// Create a zero-value message with all string fields heap-allocated.
/// Memory: Caller owns the returned WhatsAppMessage; must call `deinit()` to free all
    /// duplicated strings and `mentioned_jids`. Each field is `allocator.dupe("")` so `deinit`
    /// can unconditionally `allocator.free`.
    pub fn init(allocator: std.mem.Allocator) !WhatsAppMessage {
        // All string fields are allocated (zero-length) so deinit can unconditionally free.
        // Never assign static literals directly - always via allocator.dupe.
        return .{
            .allocator = allocator,
            .id = try allocator.dupe(u8, ""),
            .from = try allocator.dupe(u8, ""),
            .to = try allocator.dupe(u8, ""),
            .chat_id = try allocator.dupe(u8, ""),
            .chat_type = .direct,
            .sender_jid = try allocator.dupe(u8, ""),
            .sender_e164 = null,
            .sender_name = null,
            .body = try allocator.dupe(u8, ""),
            .message_type = .text,
            .media_type = null,
            .media_path = null,
            .location = null,
            .mentioned_jids = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .reply_context = null,
            .timestamp = 0,
            .from_me = false,
        };
    }

    /// Deep-copy a message into newly allocated memory owned by this struct's allocator.
/// Memory: Caller owns returned WhatsAppMessage; must call `deinit()` on it. All string
    /// fields are duplicated with `allocator.dupe`; caller must free with same allocator.
    pub fn dupeAlloc(self: *const WhatsAppMessage) !WhatsAppMessage {
        var m = try WhatsAppMessage.init(self.allocator);
        errdefer m.deinit();
        m.id = try self.allocator.dupe(u8, if (self.id.len > 0) self.id else "");
        m.from = try self.allocator.dupe(u8, if (self.from.len > 0) self.from else "");
        m.to = try self.allocator.dupe(u8, if (self.to.len > 0) self.to else "");
        m.chat_id = try self.allocator.dupe(u8, if (self.chat_id.len > 0) self.chat_id else "");
        m.sender_jid = try self.allocator.dupe(u8, if (self.sender_jid.len > 0) self.sender_jid else "");
        m.sender_e164 = if (self.sender_e164) |v| try self.allocator.dupe(u8, v) else null;
        m.sender_name = if (self.sender_name) |v| try self.allocator.dupe(u8, v) else null;
        m.body = try self.allocator.dupe(u8, if (self.body.len > 0) self.body else "");
        m.media_type = if (self.media_type) |v| try self.allocator.dupe(u8, v) else null;
        m.media_path = if (self.media_path) |v| try self.allocator.dupe(u8, v) else null;
        m.message_type = self.message_type;
        m.location = self.location;
        m.chat_type = self.chat_type;
        m.timestamp = self.timestamp;
        m.from_me = self.from_me;
        return m;
    }

    /// Free all heap-allocated fields of the message.
/// Memory: Callee takes ownership of all strings/lists; frees with `self.allocator`. Does not
    /// free `self` pointer itself when heap-boxed — caller must `allocator.destroy` after `deinit`.
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
        if (self.media_path) |s| self.allocator.free(s);
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

    /// Free all heap memory owned by the config.
/// Memory: Callee takes ownership of `auth_dir` and each element in `allow_from` /
    /// `group_activation_commands`; frees them and deinitializes the lists.
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
        for (self.allow_from.items) |item| {
            if (std.mem.eql(u8, item, "*")) return true;
            if (std.mem.eql(u8, item, sender_e164)) return true;
            // Strip device suffix :xx (e.g. 917...:51 -> 917...) before digit compare
            const s_clean = if (std.mem.indexOfScalar(u8, sender_e164, ':')) |idx| sender_e164[0..idx] else sender_e164;
            const a_clean = if (std.mem.indexOfScalar(u8, item, ':')) |idx| item[0..idx] else item;
            var s_digits: [64]u8 = undefined;
            var s_len: usize = 0;
            for (s_clean) |c| {
                if (c >= '0' and c <= '9') {
                    if (s_len < s_digits.len) { s_digits[s_len] = c; s_len += 1; }
                }
            }
            var a_digits: [64]u8 = undefined;
            var a_len: usize = 0;
            for (a_clean) |c| {
                if (c >= '0' and c <= '9') {
                    if (a_len < a_digits.len) { a_digits[a_len] = c; a_len += 1; }
                }
            }
            if (s_len == a_len and s_len != 0 and std.mem.eql(u8, s_digits[0..s_len], a_digits[0..a_len])) return true;
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

/// Memory: Callee takes ownership of all buffered messages and key dupes; frees them.
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

    /// Enqueue a message; transfers ownership of `message` to the debouncer.
/// Memory: Callee takes ownership of `message` (including all its duplicated strings and lists); caller must NOT call `message.deinit()` after enqueue.
    pub fn enqueue(self: *Debouncer, message: WhatsAppMessage) !void {
        const key = try self.allocator.dupe(u8, message.from);

        const gop = try self.entries.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = try std.ArrayList(DebouncedEntry).initCapacity(self.allocator, 0);
        }

        try gop.value_ptr.append(self.allocator, .{
            .message = message,
            .timestamp = compat.timestamp(),
        });
    }

    pub fn shouldFlush(self: *Debouncer, key: []const u8) bool {
        const now = compat.timestamp();
        const last_flush_ms = self.last_flush.get(key) orelse 0;
        return (now - last_flush_ms) * 1000 >= self.debounce_ms;
    }

    /// Flush all debounced entries for `key`. Returns the owning ArrayList.
/// Memory: Caller owns returned ArrayList and each `DebouncedEntry.message` inside; must call `list.deinit(allocator)` and `entry.message.deinit()` for each entry when done.
    pub fn flush(self: *Debouncer, key: []const u8) !std.ArrayList(DebouncedEntry) {
        const entries = self.entries.fetchRemove(key) orelse return std.ArrayList(DebouncedEntry).initCapacity(self.allocator, 0) catch unreachable;
        defer self.allocator.free(entries.key);

        try self.last_flush.put(try self.allocator.dupe(u8, key), compat.timestamp());

        return entries.value;
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
