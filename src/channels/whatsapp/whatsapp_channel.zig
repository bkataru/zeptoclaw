const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const WhatsAppMessage = types.WhatsAppMessage;
pub const WhatsAppConfig = types.WhatsAppConfig;
const ConnectionUpdate = types.ConnectionUpdate;
const QrEvent = types.QrEvent;
const ConnectionStatus = types.ConnectionStatus;

/// WhatsApp channel plugin
pub const WhatsAppChannel = struct {
    allocator: Allocator,
    config: WhatsAppConfig,

    // Process management
    node_process: ?std.process.Child,
    node_stdout: ?std.fs.File,
    node_stderr: ?std.fs.File,
    node_stdin: ?std.fs.File,

    // State
    connected: bool,
    self_jid: ?[]const u8,
    self_e164: ?[]const u8,

    // Event handlers
    message_handler: ?*const fn (message: WhatsAppMessage) anyerror!void,
    connection_handler: ?*const fn (update: ConnectionUpdate) anyerror!void,
    qr_handler: ?*const fn (event: QrEvent) anyerror!void,

    // Reader thread
    reader_thread: ?std.Thread,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator, config: WhatsAppConfig) WhatsAppChannel {
        return .{
            .allocator = allocator,
            .config = config,
            .node_process = null,
            .node_stdout = null,
            .node_stderr = null,
            .node_stdin = null,
            .connected = false,
            .self_jid = null,
            .self_e164 = null,
            .message_handler = null,
            .connection_handler = null,
            .qr_handler = null,
            .reader_thread = null,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *WhatsAppChannel) void {
        self.disconnect() catch {};

        if (self.self_jid) |jid| self.allocator.free(jid);
        if (self.self_e164) |e164| self.allocator.free(e164);
    }

    /// Connect to WhatsApp
    pub fn connect(self: *WhatsAppChannel) !void {
        self.mutex.lock();
        const already_connected = self.connected;
        self.mutex.unlock();
        if (already_connected) return;

        // Get path to Node.js wrapper
        const wrapper_path = try std.fs.path.join(self.allocator, &[_][]const u8{
            std.fs.selfExeDirPath(self.allocator) catch ".",
            "src",
            "channels",
            "whatsapp",
            "baileys_wrapper.js",
        });
        defer self.allocator.free(wrapper_path);

        // Spawn Node.js process
        var node_process = std.process.Child.init(&[_][]const u8{
            "node",
            wrapper_path,
        }, self.allocator);

        node_process.stdin_behavior = .Pipe;
        node_process.stdout_behavior = .Pipe;
        node_process.stderr_behavior = .Pipe;

        try node_process.spawn();

        self.node_process = node_process;
        self.node_stdin = node_process.stdin.?;
        self.node_stdout = node_process.stdout.?;
        self.node_stderr = node_process.stderr.?;

        // Start reader thread
        self.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{self});

        // Initialize WhatsApp connection
        try self.sendRequest(.{
            .method = "init",
            .params = .{
                .auth_dir = self.config.auth_dir,
                .print_qr = true,
            },
        });

        // Register event handlers
        try self.sendRequest(.{ .method = "onMessage" });
        try self.sendRequest(.{ .method = "onConnection" });
        try self.sendRequest(.{ .method = "onQr" });
    }

    /// Disconnect from WhatsApp
    pub fn disconnect(self: *WhatsAppChannel) !void {
        self.mutex.lock();
        const was_connected = self.connected;
        if (was_connected) self.connected = false;
        self.mutex.unlock();
        if (!was_connected) return;

        _ = try self.sendRequest(.{ .method = "disconnect", .params = .{ .object = std.json.ObjectMap.init(self.allocator) } });

        // Wait a bit for graceful shutdown
        std.Thread.sleep(100 * std.time.ns_per_ms);

        if (self.node_process) |*proc| {
            _ = proc.kill() catch {};
            _ = proc.wait() catch {};
            self.node_process = null;
        }

        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
    }

    /// Wait for connection to be established
    pub fn waitForConnection(self: *WhatsAppChannel, timeout_ms: u32) !void {
        const start = std.time.timestamp();
        const timeout_sec = timeout_ms / 1000;

        while (true) {
            self.mutex.lock();
            const is_connected = self.connected;
            self.mutex.unlock();
            if (is_connected) break;
            const now = std.time.timestamp();
            if (now - start >= timeout_sec) {
                return error.ConnectionTimeout;
            }
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
    /// Send a text message
    pub fn sendMessage(self: *WhatsAppChannel, to: []const u8, text: []const u8) ![]const u8 {
        const response = try self.sendRequest(.{
            .method = "sendMessage",
            .params = .{
                .to = to,
                .text = text,
            },
        });

        if (response.result) |result| {
            if (result.message_id) |id| {
                return try self.allocator.dupe(u8, id);
            }
        }

        return error.SendMessageFailed;
    }

    /// Send a media message
    pub fn sendMedia(self: *WhatsAppChannel, to: []const u8, media_path: []const u8, caption: ?[]const u8) ![]const u8 {
        const response = try self.sendRequest(.{
            .method = "sendMedia",
            .params = .{
                .to = to,
                .mediaPath = media_path,
                .caption = caption,
            },
        });

        if (response.result) |result| {
            if (result.message_id) |id| {
                return try self.allocator.dupe(u8, id);
            }
        }

        return error.SendMediaFailed;
    }

    /// Send a reaction
    pub fn sendReaction(self: *WhatsAppChannel, chat_jid: []const u8, message_id: []const u8, emoji: []const u8) !void {
        _ = try self.sendRequest(.{
            .method = "sendReaction",
            .params = .{
                .chatJid = chat_jid,
                .messageId = message_id,
                .emoji = emoji,
            },
        });
    }

    /// Send a poll
    pub fn sendPoll(self: *WhatsAppChannel, to: []const u8, poll: types.Poll) ![]const u8 {
        const response = try self.sendRequest(.{
            .method = "sendPoll",
            .params = .{
                .to = to,
                .poll = poll,
            },
        });

        if (response.result) |result| {
            if (result.message_id) |id| {
                return try self.allocator.dupe(u8, id);
            }
        }

        return error.SendPollFailed;
    }

    /// Mark messages as read
    pub fn markRead(self: *WhatsAppChannel, messages: []const struct {
        remote_jid: []const u8,
        id: []const u8,
        from_me: bool,
        participant: ?[]const u8,
    }) !void {
        _ = try self.sendRequest(.{
            .method = "markRead",
            .params = .{ .messages = messages },
        });
    }

    /// Send presence update
    pub fn sendPresence(self: *WhatsAppChannel, presence: []const u8, to_jid: ?[]const u8) !void {
        const params: std.json.Value = if (to_jid) |jid|
            .{ .presence = presence, .toJid = jid }
        else
            .{ .presence = presence };

        _ = try self.sendRequest(.{
            .method = "sendPresence",
            .params = params,
        });
    }

    /// Get contact info
    pub fn getContactInfo(self: *WhatsAppChannel, jid: []const u8) !struct {
        exists: bool,
        jid: []const u8,
    } {
        const response = try self.sendRequest(.{
            .method = "getContactInfo",
            .params = .{ .jid = jid },
        });

        if (response.result) |result| {
            if (result.exists) |exists| {
                return .{
                    .exists = exists,
                    .jid = try self.allocator.dupe(u8, result.jid orelse jid),
                };
            }
        }

        return error.ContactNotFound;
    }

    /// Get group metadata
    pub fn getGroupMetadata(self: *WhatsAppChannel, jid: []const u8) !struct {
        subject: []const u8,
        participants: []struct {
            id: []const u8,
            admin: ?[]const u8,
        },
    } {
        const response = try self.sendRequest(.{
            .method = "getGroupMetadata",
            .params = .{ .jid = jid },
        });

        if (response.result) |result| {
            return .{
                .subject = try self.allocator.dupe(u8, result.subject orelse ""),
                .participants = &[_]struct {
                    id: []const u8,
                    admin: ?[]const u8,
                }{},
            };
        }

        return error.GroupNotFound;
    }

    /// Set message handler
    pub fn onMessage(self: *WhatsAppChannel, handler: *const fn (message: WhatsAppMessage) anyerror!void) void {
        self.message_handler = handler;
    }

    /// Set connection handler
    pub fn onConnection(self: *WhatsAppChannel, handler: *const fn (update: ConnectionUpdate) anyerror!void) void {
        self.connection_handler = handler;
    }

    /// Set QR handler
    pub fn onQr(self: *WhatsAppChannel, handler: *const fn (event: QrEvent) anyerror!void) void {
        self.qr_handler = handler;
    }

    /// Send JSON-RPC request
    fn sendRequest(self: *WhatsAppChannel, request: Request) !Response {
        if (self.node_stdin == null) return error.NotConnected;

        const json_str = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(request, .{})});
        defer self.allocator.free(json_str);

        const line = try std.fmt.allocPrint(self.allocator, "{s}\n", .{json_str});
        defer self.allocator.free(line);

        try self.node_stdin.?.writeAll(line);

        // Response will be handled by reader thread
        // For now, return a placeholder response
        // In a real implementation, we'd use a channel/future pattern
        return Response{};
    }

    /// Reader loop for processing Node.js output
    fn readerLoop(self: *WhatsAppChannel) !void {
        if (self.node_stdout == null) return;

        var buffer: [8192]u8 = undefined;
        var line_buffer = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
        defer line_buffer.deinit();

        while (true) {
            const bytes_read = self.node_stdout.?.read(&buffer) catch |err| {
                if (err == error.EndOfStream) break;
                continue;
            };

            if (bytes_read == 0) break;

            try line_buffer.appendSlice(buffer[0..bytes_read]);

            // Process complete lines
            var start: usize = 0;
            while (start < line_buffer.items.len) {
                const end = std.mem.indexOfScalar(u8, line_buffer.items[start..], '\n') orelse break;
                const line = line_buffer.items[start .. start + end];

                if (line.len > 0) {
                    self.processLine(line) catch |err| {
                        std.debug.print("Error processing line: {}\n", .{err});
                    };
                }

                start += end + 1;
            }

            // Keep remaining partial line
            if (start < line_buffer.items.len) {
                const remaining = try self.allocator.dupe(u8, line_buffer.items[start..]);
                line_buffer.clearRetainingCapacity();
                try line_buffer.appendSlice(remaining);
                self.allocator.free(remaining);
            } else {
                line_buffer.clearRetainingCapacity();
            }
        }
    }

    /// Process a line of JSON output
    pub fn processLine(self: *WhatsAppChannel, line: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, line, .{});
        defer parsed.deinit();

        const value = parsed.value;

        if (value.object.get("method")) |method| {
            // Event notification
            if (std.mem.eql(u8, method.string, "message")) {
                if (value.object.get("params")) |params| {
                    const msg = try parseMessage(self.allocator, params);
                    if (self.message_handler) |handler| {
                        try handler(msg);
                    }
                }
            } else if (std.mem.eql(u8, method.string, "connection")) {
                if (value.object.get("params")) |params| {
                    const update = try parseConnectionUpdate(self.allocator, params);
                    const status = update.status;
                    if (status == .connected) {
                        var new_jid = if (update.self_jid) |jid| try self.allocator.dupe(u8, jid) else null;
                        errdefer if (new_jid) |nj| self.allocator.free(nj);
                        var new_e164 = if (update.self_e164) |e164| try self.allocator.dupe(u8, e164) else null;
                        errdefer if (new_e164) |ne| self.allocator.free(ne);
                        self.mutex.lock();
                        if (self.self_jid) |old| self.allocator.free(old);
                        self.self_jid = new_jid;
                        new_jid = null;
                        if (self.self_e164) |old| self.allocator.free(old);
                        self.self_e164 = new_e164;
                        new_e164 = null;
                        self.connected = true;
                        self.mutex.unlock();
                    } else if (status == .disconnected) {
                        self.mutex.lock();
                        self.connected = false;
                        self.mutex.unlock();
                    }
                    if (self.connection_handler) |handler| {
                        try handler(update);
                    }
                } else if (std.mem.eql(u8, method.string, "qr")) {
                    if (value.object.get("params")) |params| {
                        if (params.object.get("qr")) |qr| {
                            const event = QrEvent{
                                .qr = try self.allocator.dupe(u8, qr.string),
                            };
                            if (self.qr_handler) |handler| {
                                try handler(event);
                            }
                        }
                    }
                }
            }
        }
    }

    fn parseMessage(allocator: Allocator, value: std.json.Value) !WhatsAppMessage {
        var msg = WhatsAppMessage.init(allocator);

        if (value.object.get("id")) |id| msg.id = try allocator.dupe(u8, id.string);
        if (value.object.get("from")) |from| msg.from = try allocator.dupe(u8, from.string);
        if (value.object.get("to")) |to| msg.to = try allocator.dupe(u8, to.string);
        if (value.object.get("chatId")) |chat_id| msg.chat_id = try allocator.dupe(u8, chat_id.string);
        if (value.object.get("chatType")) |chat_type| {
            msg.chat_type = if (std.mem.eql(u8, chat_type.string, "group"))
                .group
            else
                .direct;
        }
        if (value.object.get("senderJid")) |sender_jid| msg.sender_jid = try allocator.dupe(u8, sender_jid.string);
        if (value.object.get("senderE164")) |sender_e164| msg.sender_e164 = try allocator.dupe(u8, sender_e164.string);
        if (value.object.get("senderName")) |sender_name| msg.sender_name = try allocator.dupe(u8, sender_name.string);
        if (value.object.get("body")) |body| msg.body = try allocator.dupe(u8, body.string);
        if (value.object.get("timestamp")) |timestamp| msg.timestamp = timestamp.integer;

        return msg;
    }

    /// Parse connection update from JSON
    fn parseConnectionUpdate(allocator: Allocator, value: std.json.Value) !ConnectionUpdate {
        var update: ConnectionUpdate = .{
            .status = .disconnected,
            .self_jid = null,
            .self_e164 = null,
            .@"error" = null,
        };

        if (value.object.get("type")) |type_str| {
            if (std.mem.eql(u8, type_str.string, "connected")) {
                update.status = .connected;
            } else if (std.mem.eql(u8, type_str.string, "disconnected")) {
                update.status = .disconnected;
            }
        }

        if (value.object.get("selfJid")) |self_jid| {
            update.self_jid = try allocator.dupe(u8, self_jid.string);
        }
        if (value.object.get("selfE164")) |self_e164| {
            update.self_e164 = try allocator.dupe(u8, self_e164.string);
        }
        if (value.object.get("error")) |err_val| {
            update.@"error" = try allocator.dupe(u8, err_val.string);
        }

        return update;
    }
};

/// JSON-RPC request
const Request = struct {
    jsonrpc: []const u8 = "2.0",
    id: u64 = 0,
    method: []const u8,
    params: std.json.Value,
};

/// JSON-RPC response
const Response = struct {
    jsonrpc: []const u8 = "2.0",
    id: u64 = 0,
    result: ?std.json.Value = null,
    @"error": ?struct {
        code: i32,
        message: []const u8,
    } = null,
};

test "WhatsAppChannel init/deinit" {
    const allocator = std.testing.allocator;
    var config = try WhatsAppConfig.init(allocator);
    defer config.deinit();

    var channel = WhatsAppChannel.init(allocator, config);
    defer channel.deinit();

    try std.testing.expectEqual(false, channel.connected);
}
