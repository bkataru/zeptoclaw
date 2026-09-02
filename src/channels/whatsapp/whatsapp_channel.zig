const std = @import("std");
const compat = @import("../../compat.zig");
const types = @import("types.zig");
const native_mod = @import("native/client.zig");
const qrcode = @import("native/qrcode.zig");
const media_mod = @import("native/media.zig");

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
    node_stdout: ?std.Io.File,
    node_stderr: ?std.Io.File,
    node_stdin: ?std.Io.File,

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
    mutex: std.Io.Mutex,
    use_native: bool = false,
    native_client: ?*native_mod.Client = null,
    native_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // JSON-RPC pending response (single-flight; gateway is single-threaded caller,
    // reader thread delivers responses)
    next_rpc_id: u64 = 1,
    rpc_pending_id: ?u64 = null,
    rpc_response_line: ?[]u8 = null,
    rpc_has_response: bool = false,
    rpc_mutex: std.Io.Mutex = .init,
    /// Threaded Io used for process spawn and child pipes. `self.channelIo()` is
    /// `global_single_threaded`, whose processSpawn vtable always returns OutOfMemory.
    spawn_threaded: ?*std.Io.Threaded = null,
    restart_in_flight: bool = false,
    last_restart_ms: i64 = 0,

    fn channelIo(self: *WhatsAppChannel) std.Io {
        if (self.spawn_threaded) |t| return t.io();
        return compat.getIo();
    }

    /// Memory: Callee borrows `config` (not freed by deinit); caller owns returned channel and must call deinit().
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
            .mutex = .init,
            .use_native = config.native,
            .native_client = null,
            .native_stop = std.atomic.Value(bool).init(false),
        };
    }

    /// Memory: Callee takes responsibility for child process, Threaded Io, and duped self_jid/self_e164/rpc_response_line.
    pub fn deinit(self: *WhatsAppChannel) void {
        self.disconnect() catch {};

        if (self.self_jid) |jid| self.allocator.free(jid);
        if (self.self_e164) |e164| self.allocator.free(e164);
        if (self.rpc_response_line) |line| self.allocator.free(line);
        if (self.spawn_threaded) |t| {
            t.deinit();
            self.allocator.destroy(t);
            self.spawn_threaded = null;
        }
    }

    /// Connect to WhatsApp
    /// Memory: Callee owns Node child, pipes, and Threaded Io until disconnect/deinit.
    pub fn connect(self: *WhatsAppChannel) !void {
        try self.mutex.lock(self.channelIo());
        const already_connected = self.connected;
        self.mutex.unlock(self.channelIo());
        if (already_connected) return;

        if (self.config.native) {
            self.use_native = true;
            try self.connectNative();
            return;
        }

        if (self.spawn_threaded == null) {
            const t = try self.allocator.create(std.Io.Threaded);
            t.* = compat.threadedIoWithOsEnviron(self.allocator);
            self.spawn_threaded = t;
        }
        const spawn_io = self.channelIo();

        const home = compat.getEnvVarOwned(self.allocator, "HOME") catch try self.allocator.dupe(u8, ".");
        defer self.allocator.free(home);
        const wrapper_path = try std.fmt.allocPrint(self.allocator, "{s}/zeptoclaw/src/channels/whatsapp/baileys_wrapper.js", .{home});
        defer self.allocator.free(wrapper_path);
        const node_owned = compat.getEnvVarOwned(self.allocator, "ZEPTO_NODE") catch null;
        defer if (node_owned) |n| self.allocator.free(n);
        const node_bin = node_owned orelse "node";

        std.log.info("[whatsapp] connect: spawning {s} {s}", .{ node_bin, wrapper_path });
        const child = try std.process.spawn(spawn_io, .{
            .argv = &[_][]const u8{ node_bin, wrapper_path },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        std.log.info("[whatsapp] connect: node spawned ok", .{});

        self.node_process = child;
        self.node_stdin = child.stdin.?;
        self.node_stdout = child.stdout.?;
        self.node_stderr = child.stderr.?;

        const stderr_thread = try std.Thread.spawn(.{}, stderrLoop, .{self});
        stderr_thread.detach();

        // Start reader thread
        self.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{self});
        std.log.err("[whatsapp] connect: reader spawned ok", .{});

        // Initialize WhatsApp connection (pass allowFrom so wrapper can symmetric-wake fromMe DMs)
        {
            var allow_from_arr = std.json.Array.init(self.allocator);
            defer allow_from_arr.deinit();
            for (self.config.allow_from.items) |jid| {
                try allow_from_arr.append(.{ .string = jid });
            }
            // Build the init params object.
            var obj = try std.json.ObjectMap.init(self.allocator, &.{}, &.{});
            try obj.put(self.allocator, "auth_dir", .{ .string = self.config.auth_dir });
            try obj.put(self.allocator, "print_qr", .{ .bool = false });
            try obj.put(self.allocator, "allow_from", .{ .array = allow_from_arr });
            _ = try self.sendRequest(.{
                .method = "init",
                .params = .{ .object = obj },
            });
        }

        // Register event handlers
        const empty_obj = try std.json.ObjectMap.init(self.allocator, &.{}, &.{});
        _ = try self.sendRequest(.{ .method = "onMessage", .params = .{ .object = empty_obj } });
        _ = try self.sendRequest(.{ .method = "onConnection", .params = .{ .object = empty_obj } });
        _ = try self.sendRequest(.{ .method = "onQr", .params = .{ .object = empty_obj } });
    }

    pub fn setAllowFrom(self: *WhatsAppChannel, entries: []const []const u8) !void {
        if (self.use_native) return;
        var allow_from_arr = std.json.Array.init(self.allocator);
        defer allow_from_arr.deinit();
        for (entries) |jid| {
            try allow_from_arr.append(.{ .string = jid });
        }
        var obj = try std.json.ObjectMap.init(self.allocator, &.{}, &.{});
        try obj.put(self.allocator, "allow_from", .{ .array = allow_from_arr });
        try self.sendFireAndForget(.{
            .method = "setAllowFrom",
            .params = .{ .object = obj },
        });
    }

    pub fn heal(self: *WhatsAppChannel) !void {
        if (self.use_native) return;
        try self.sendFireAndForget(.{
            .method = "heal",
            .params = .{ .object = try std.json.ObjectMap.init(self.allocator, &.{}, &.{}) },
        });
    }

    pub fn healthSnapshot(self: *WhatsAppChannel, jid_buf: []u8) struct { connected: bool, jid_len: usize } {
        self.mutex.lock(self.channelIo()) catch {
            return .{ .connected = false, .jid_len = 0 };
        };
        defer self.mutex.unlock(self.channelIo());
        const src = self.self_jid orelse "";
        const n = @min(src.len, jid_buf.len);
        if (n > 0) @memcpy(jid_buf[0..n], src[0..n]);
        return .{ .connected = self.connected, .jid_len = n };
    }

    pub fn restartChild(self: *WhatsAppChannel) !void {
        if (self.restart_in_flight) return;
        const now = compat.timestamp();
        if (now - self.last_restart_ms < 600) return;
        self.restart_in_flight = true;
        defer self.restart_in_flight = false;
        self.last_restart_ms = now;
        std.log.warn("[whatsapp] restartChild begin", .{});
        try self.disconnect();
        try self.connect();
        std.log.warn("[whatsapp] restartChild done connected={}", .{self.connected});
    }

    fn restartChildThread(self: *WhatsAppChannel) void {
        self.restartChild() catch |err| {
            std.log.err("[whatsapp] restartChild failed: {}", .{err});
        };
    }

    /// Disconnect from WhatsApp
    pub fn disconnect(self: *WhatsAppChannel) !void {
        try self.mutex.lock(self.channelIo());
        self.connected = false;
        self.mutex.unlock(self.channelIo());

        if (self.use_native) {
            self.native_stop.store(true, .seq_cst);
            if (self.native_client) |cli| cli.disconnect();
            if (self.reader_thread) |thread| {
                thread.join();
                self.reader_thread = null;
            }
            if (self.native_client) |cli| {
                cli.deinit();
                self.allocator.destroy(cli);
                self.native_client = null;
            }
            return;
        }

        if (self.node_stdin != null) {
            self.sendFireAndForget(.{ .method = "disconnect", .params = .{ .object = try std.json.ObjectMap.init(self.allocator, &.{}, &.{}) } }) catch {};
            _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 100 * 1000000 }, null);
        }

        if (self.node_process) |*proc| {
            proc.kill(self.channelIo());
            // POSIX childKill already wait4-reaps and nulls id. A second wait()
            // asserts id != null and SIGABRTs the gateway (systemd: Failed with result 'signal').
            if (proc.id != null) {
                _ = proc.wait(self.channelIo()) catch {};
            }
            self.node_process = null;
        }
        self.node_stdin = null;
        self.node_stdout = null;
        self.node_stderr = null;

        if (self.reader_thread) |thread| {
            // Join deadlocks when restartChild runs from a thread spawned by
            // processLine on this reader. Detach; readerLoop exits on stdout EOF.
            thread.detach();
            self.reader_thread = null;
        }
    }

    /// Wait for connection to be established
    pub fn waitForConnection(self: *WhatsAppChannel, timeout_ms: u32) !void {
        const start = compat.timestamp();
        const timeout_sec = timeout_ms / 1000;

        while (true) {
            try self.mutex.lock(self.channelIo());
            const is_connected = self.connected;
            self.mutex.unlock(self.channelIo());
            if (is_connected) break;
            const now = compat.timestamp();
            if (now - start >= timeout_sec) {
                return error.ConnectionTimeout;
            }
            _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 100 * 1000000 }, null);
        }
    }
    /// Memory: Caller owns returned messageId slice; must free with allocator.free (allocator.dupe).
    /// Send a text message
    pub fn sendMessage(self: *WhatsAppChannel, to: []const u8, text: []const u8) ![]const u8 {
        if (self.use_native) {
            const cli = self.native_client orelse return error.NotConnected;
            return cli.sendText(to, text);
        }
        var params_obj = try std.json.ObjectMap.init(self.allocator, &.{}, &.{});
        try params_obj.put(self.allocator, "to", .{ .string = to });
        try params_obj.put(self.allocator, "text", .{ .string = text });
        const response = try self.sendRequest(.{
            .method = "sendMessage",
            .params = .{ .object = params_obj },
        });

        if (response.message_id) |mid| return mid;
        if (response.result) |result| {
            if (result == .object) {
                if (result.object.get("messageId") orelse result.object.get("message_id")) |id_val| {
                    if (id_val == .string) return try self.allocator.dupe(u8, id_val.string);
                }
            }
        }

        return error.SendMessageFailed;
    }

    /// Memory: Caller owns returned messageId slice; must free with allocator.free.
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
            if (result == .object) {
                if (result.object.get("messageId") orelse result.object.get("message_id")) |id_val| {
                    if (id_val == .string) return try self.allocator.dupe(u8, id_val.string);
                }
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

    /// Memory: Caller owns returned messageId slice; must free with allocator.free.
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
            if (result == .object) {
                if (result.object.get("messageId") orelse result.object.get("message_id")) |id_val| {
                    if (id_val == .string) return try self.allocator.dupe(u8, id_val.string);
                }
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

    /// Memory: Caller owns returned jid dupe inside struct; must free with allocator.free.
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

    /// Memory: Caller owns returned subject dupe; must free with allocator.free. Participants slice is static empty in this stub.
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

    /// Heap-allocate a Client, open `{auth_dir}/native.sqlite`, spawn nativeLoop.
    /// Memory: channel owns the Client until disconnect/deinit.
    fn connectNative(self: *WhatsAppChannel) !void {
        if (self.native_client != null) return;
        self.native_stop.store(false, .seq_cst);
        ensureAuthDir(self.config.auth_dir);
        const store_path = try std.fmt.allocPrint(self.allocator, "{s}/native.sqlite", .{self.config.auth_dir});
        defer self.allocator.free(store_path);

        const cli = try self.allocator.create(native_mod.Client);
        cli.* = native_mod.Client.init(self.allocator);
        errdefer {
            cli.deinit();
            self.allocator.destroy(cli);
            self.native_client = null;
        }
        try cli.openStore(store_path);
        cli.loadFromStore() catch |err| {
            if (err != error.NotPaired) return err;
        };
        self.native_client = cli;
        self.reader_thread = try std.Thread.spawn(.{}, nativeLoop, .{self});
        std.log.info("[whatsapp] native loop started store={s}", .{store_path});
    }

    fn nativeLoop(self: *WhatsAppChannel) void {
        var backoff_ms: u64 = 2000;
        while (!self.native_stop.load(.seq_cst)) {
            const cli = self.native_client orelse return;
            cli.connect("") catch |err| {
                std.log.warn("[whatsapp] native connect failed: {}", .{err});
                if (self.sleepInterruptible(backoff_ms)) return;
                backoff_ms = nextBackoff(backoff_ms);
                continue;
            };
            backoff_ms = 2000;
            var immediate = false;
            inner: while (!self.native_stop.load(.seq_cst)) {
                const ev = cli.poll() catch |err| {
                    std.log.warn("[whatsapp] native poll: {}", .{err});
                    self.emitDisconnected();
                    // After pair-success the server closes the socket; that is
                    // the restart-required path, same as disconnected code 515.
                    if (pollErrorIsRestart(err) and immediate) {
                        backoff_ms = 2000;
                    }
                    break :inner;
                };
                switch (ev) {
                    .qr => |codes| self.handleNativeQr(codes),
                    .paired => |p| {
                        std.log.info("[whatsapp] paired jid={s} lid={s}", .{ p.jid, p.lid });
                        immediate = true;
                    },
                    .connected => |c| self.handleNativeConnected(c.jid),
                    .message => |msg| self.handleNativeMessage(msg),
                    .disconnected => |d| {
                        self.emitDisconnected();
                        if (d.logged_out) {
                            std.log.warn("[whatsapp] logged out; unpair and re-pair (native)", .{});
                            return;
                        }
                        if (d.code == 515) immediate = true;
                        break :inner;
                    },
                    .idle => {},
                }
            }
            cli.disconnect();
            if (self.native_stop.load(.seq_cst)) return;
            if (immediate) {
                backoff_ms = 2000;
                continue;
            }
            if (self.sleepInterruptible(backoff_ms)) return;
            backoff_ms = nextBackoff(backoff_ms);
        }
    }

    fn sleepInterruptible(self: *WhatsAppChannel, ms: u64) bool {
        var left = ms;
        while (left > 0) {
            if (self.native_stop.load(.seq_cst)) return true;
            const chunk: u64 = @min(left, 100);
            _ = std.c.nanosleep(&.{ .sec = 0, .nsec = @intCast(chunk * 1_000_000) }, null);
            left -= chunk;
        }
        return self.native_stop.load(.seq_cst);
    }

    fn handleNativeQr(self: *WhatsAppChannel, codes: []const []const u8) void {
        if (codes.len == 0) return;
        const first = codes[0];
        std.log.info("[whatsapp] scan QR (native)", .{});
        printQrUtf8AndLog(self.allocator, first);
        const duped = self.allocator.dupe(u8, first) catch return;
        defer self.allocator.free(duped);
        if (self.qr_handler) |handler| {
            handler(.{ .qr = duped }) catch |err| {
                std.log.warn("[whatsapp] qr handler failed: {}", .{err});
            };
        }
    }

    fn handleNativeConnected(self: *WhatsAppChannel, jid: []const u8) void {
        const e164 = digitsBeforeColon(jid);
        const jid_store = self.allocator.dupe(u8, jid) catch return;
        const e164_store = self.allocator.dupe(u8, e164) catch {
            self.allocator.free(jid_store);
            return;
        };
        self.mutex.lock(self.channelIo()) catch {
            self.allocator.free(jid_store);
            self.allocator.free(e164_store);
            return;
        };
        if (self.self_jid) |old| self.allocator.free(old);
        if (self.self_e164) |old| self.allocator.free(old);
        self.self_jid = jid_store;
        self.self_e164 = e164_store;
        self.connected = true;
        self.mutex.unlock(self.channelIo());

        const upd_jid = self.allocator.dupe(u8, jid) catch null;
        const upd_e164 = self.allocator.dupe(u8, e164) catch null;
        const update = ConnectionUpdate{
            .status = .connected,
            .self_jid = upd_jid,
            .self_e164 = upd_e164,
            .@"error" = null,
        };
        if (self.connection_handler) |handler| {
            handler(update) catch |err| {
                std.log.err("[whatsapp] connection handler failed: {}", .{err});
            };
        }
        if (upd_jid) |s| self.allocator.free(s);
        if (upd_e164) |s| self.allocator.free(s);
    }

    fn emitDisconnected(self: *WhatsAppChannel) void {
        self.mutex.lock(self.channelIo()) catch {};
        self.connected = false;
        self.mutex.unlock(self.channelIo());
        const update = ConnectionUpdate{
            .status = .disconnected,
            .self_jid = null,
            .self_e164 = null,
            .@"error" = null,
        };
        if (self.connection_handler) |handler| {
            handler(update) catch |err| {
                std.log.err("[whatsapp] connection handler failed: {}", .{err});
            };
        }
    }

    fn handleNativeMessage(self: *WhatsAppChannel, inbound: native_mod.InboundMessage) void {
        var owned_in = inbound;
        defer owned_in.deinit();
        const media_att = owned_in.media;
        owned_in.media = null;
        self.mutex.lock(self.channelIo()) catch {};
        const own_jid = self.self_jid;
        const own_e164 = self.self_e164;
        self.mutex.unlock(self.channelIo());
        const wa = inboundToWhatsAppMessage(self.allocator, owned_in, own_jid, own_e164) catch |err| {
            std.log.err("[whatsapp] native message map failed: {}", .{err});
            return;
        };
        if (self.message_handler) |handler| {
            const th = std.Thread.spawn(.{}, dispatchNativeMessage, .{ self, handler, wa, media_att }) catch |err| {
                std.log.err("[whatsapp] failed to spawn message handler: {}", .{err});
                var doomed = wa;
                doomed.deinit();
                if (media_att) |*a| a.deinit(self.allocator);
                return;
            };
            th.detach();
        } else {
            var unused = wa;
            unused.deinit();
        }
    }

    /// Foreground native pairing used by `zeptoclaw whatsapp pair`.
    /// Prints each QR batch's first code (utf8 render + raw URL) until pair-success,
    /// then reconnects once and waits for login.
    /// Memory: caller owns returned jid; must free with allocator.free.
    pub fn runNativePairForeground(allocator: Allocator, auth_dir: []const u8) ![]u8 {
        ensureAuthDir(auth_dir);
        var cli = native_mod.Client.init(allocator);
        defer cli.deinit();
        const store_path = try std.fmt.allocPrint(allocator, "{s}/native.sqlite", .{auth_dir});
        defer allocator.free(store_path);
        try cli.openStore(store_path);
        cli.loadFromStore() catch |err| {
            if (err != error.NotPaired) return err;
        };

        var seen_paired = cli.selfJid() != null;
        while (true) {
            cli.connect("") catch |err| {
                std.debug.print("native connect failed: {}\n", .{err});
                _ = std.c.nanosleep(&.{ .sec = 2, .nsec = 0 }, null);
                continue;
            };
            var reconnect_now = false;
            poll: while (true) {
                // Socket errors after pair-success are the server's "restart now"
                // (same as disconnected 515); `reconnect_now`/`seen_paired` handle it below.
                const ev = cli.poll() catch break :poll;
                switch (ev) {
                    .qr => |codes| {
                        if (codes.len > 0) printQrUtf8(allocator, codes[0]);
                    },
                    .paired => |p| {
                        std.debug.print("pair-success jid={s} lid={s}\n", .{ p.jid, p.lid });
                        seen_paired = true;
                        reconnect_now = true;
                    },
                    .connected => |c| {
                        const jid = try allocator.dupe(u8, c.jid);
                        cli.disconnect();
                        return jid;
                    },
                    .disconnected => |d| {
                        if (d.logged_out) return error.LoggedOut;
                        if (d.code == 515) reconnect_now = true;
                        break :poll;
                    },
                    .message => |msg| {
                        var m = msg;
                        m.deinit();
                    },
                    .idle => {},
                }
            }
            cli.disconnect();
            if (reconnect_now or seen_paired) continue;
            _ = std.c.nanosleep(&.{ .sec = 2, .nsec = 0 }, null);
        }
    }

    /// Send JSON-RPC request
    /// Send JSON-RPC request and wait for response (single-flight, 15s timeout).
    /// Memory: Caller owns Response.result strings via allocator; for fire-and-forget
    /// callers we still wait for the ack; they ignore the result.
    fn sendFireAndForget(self: *WhatsAppChannel, request: Request) !void {
        if (self.node_stdin == null) return error.NotConnected;
        try self.rpc_mutex.lock(self.channelIo());
        const id = self.next_rpc_id;
        self.next_rpc_id +%= 1;
        self.rpc_mutex.unlock(self.channelIo());
        var req = request;
        req.id = id;
        const json_str = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(req, .{})});
        defer self.allocator.free(json_str);
        const line = try std.fmt.allocPrint(self.allocator, "{s}\n", .{json_str});
        defer self.allocator.free(line);
        try self.node_stdin.?.writeStreamingAll(self.channelIo(), line);
    }

    fn sendRequest(self: *WhatsAppChannel, request: Request) !Response {
        if (self.node_stdin == null) return error.NotConnected;

        // Assign id and clear pending slot
        try self.rpc_mutex.lock(self.channelIo());
        const id = self.next_rpc_id;
        self.next_rpc_id +%= 1;
        if (self.rpc_response_line) |old| {
            self.allocator.free(old);
            self.rpc_response_line = null;
        }
        self.rpc_has_response = false;
        self.rpc_pending_id = id;
        self.rpc_mutex.unlock(self.channelIo());

        var req = request;
        req.id = id;
        const json_str = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(req, .{})});
        defer self.allocator.free(json_str);

        const line = try std.fmt.allocPrint(self.allocator, "{s}\n", .{json_str});
        defer self.allocator.free(line);

        try self.node_stdin.?.writeStreamingAll(self.channelIo(), line);

        const start = compat.timestamp();
        while (true) {
            try self.rpc_mutex.lock(self.channelIo());
            const done = self.rpc_has_response;
            const resp_line = self.rpc_response_line;
            self.rpc_mutex.unlock(self.channelIo());
            if (done) {
                var out = Response{};
                if (resp_line) |rl| {
                    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, rl, .{}) catch return out;
                    defer parsed.deinit();
                    if (parsed.value == .object) {
                        if (parsed.value.object.get("result")) |result| {
                            if (result == .object) {
                                const mid = result.object.get("messageId") orelse result.object.get("messageId") orelse result.object.get("message_id");
                                if (mid) |id_val| {
                                    if (id_val == .string) {
                                        out.message_id = try self.allocator.dupe(u8, id_val.string);
                                    }
                                }
                            }
                        }
                    }
                }
                return out;
            }
            if (compat.timestamp() - start >= 30) {
                std.log.err("[whatsapp] RpcTimeout waiting for rpc id={d} method={s}", .{ id, request.method });
                return error.RpcTimeout;
            }
            _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 20 * 1_000_000 }, null);
        }
    }

    fn stderrLoop(self: *WhatsAppChannel) void {
        const f = self.node_stderr orelse return;
        var buffer: [2048]u8 = undefined;
        while (true) {
            const n = f.readStreaming(self.channelIo(), &.{buffer[0..]}) catch break;
            if (n == 0) break;
            const chunk = buffer[0..n];
            if (chunk.len > 0) std.log.warn("[whatsapp][js] {s}", .{chunk});
        }
    }

    /// Reader loop for processing Node.js output
    fn readerLoop(self: *WhatsAppChannel) !void {
        if (self.node_stdout == null) return;

        var buffer: [8192]u8 = undefined;
        var line_buffer = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
        defer line_buffer.deinit(self.allocator);

        while (true) {
            const bytes_read = self.node_stdout.?.readStreaming(self.channelIo(), &.{buffer[0..]}) catch |err| {
                if (err == error.EndOfStream) break;
                continue;
            };

            if (bytes_read == 0) break;

            try line_buffer.appendSlice(self.allocator, buffer[0..bytes_read]);

            // Process complete lines
            var start: usize = 0;
            while (start < line_buffer.items.len) {
                const end = std.mem.indexOfScalar(u8, line_buffer.items[start..], '\n') orelse break;
                const line = line_buffer.items[start .. start + end];

                if (line.len > 0) {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (trimmed.len != 0 and trimmed[0] == '{') {
                        self.processLine(trimmed) catch |err| {
                            if (err != error.SyntaxError and err != error.UnexpectedToken) {
                                std.log.warn("[whatsapp] rpc line: {}", .{err});
                            }
                        };
                    }
                }

                start += end + 1;
            }

            // Keep remaining partial line
            if (start < line_buffer.items.len) {
                const remaining = try self.allocator.dupe(u8, line_buffer.items[start..]);
                line_buffer.clearRetainingCapacity();
                try line_buffer.appendSlice(self.allocator, remaining);
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

        if (parsed.value != .object) return;
        const value = parsed.value;
        // JSON-RPC response (has id, no method) — deliver to waiting sendRequest
        if (value.object.get("id") != null and value.object.get("method") == null) {
            const id_val = value.object.get("id").?;
            const resp_id: u64 = switch (id_val) {
                .integer => |i| @intCast(i),
                .float => |f| @intFromFloat(f),
                .number_string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
                .string => |str| std.fmt.parseInt(u64, str, 10) catch 0,
                else => 0,
            };
            self.rpc_mutex.lock(self.channelIo()) catch {};
            const pending = self.rpc_pending_id;
            if (pending != null and pending.? == resp_id) {
                if (self.rpc_response_line) |old| self.allocator.free(old);
                self.rpc_response_line = try self.allocator.dupe(u8, line);
                self.rpc_has_response = true;
            }
            self.rpc_mutex.unlock(self.channelIo());
            return;
        }

        if (value.object.get("method")) |method_val| {
            const method = jsonStr(method_val) orelse return;
            if (std.mem.eql(u8, method, "needNodeRestart")) {
                const reason = blk: {
                    if (value.object.get("params")) |params| {
                        if (params == .object) {
                            if (params.object.get("reason")) |r| {
                                if (jsonStr(r)) |s| break :blk s;
                            }
                        }
                    }
                    break :blk "";
                };
                std.log.warn("[whatsapp] needNodeRestart reason={s}", .{reason});
                const th = std.Thread.spawn(.{}, restartChildThread, .{self}) catch |err| {
                    std.log.err("[whatsapp] failed to spawn restartChild: {}", .{err});
                    return;
                };
                th.detach();
            } else if (std.mem.eql(u8, method, "stats")) {
                var fails: i64 = 0;
                if (value.object.get("params")) |params| {
                    if (params == .object) {
                        if (params.object.get("decryptFails")) |v| {
                            fails = jsonI64(v);
                        }
                    }
                }
                std.log.info("[whatsapp] stats decryptFails={d}", .{fails});
            } else if (std.mem.eql(u8, method, "message")) {
                if (value.object.get("params")) |params| {
                    if (params != .object) {
                        std.log.err("[whatsapp] message params not object", .{});
                        return;
                    }
                    const msg = parseMessage(self.allocator, params) catch |err| {
                        std.log.err("[whatsapp] parseMessage failed: {}", .{err});
                        return;
                    };
                    if (self.message_handler) |handler| {
                        const th = std.Thread.spawn(.{}, dispatchMessage, .{ handler, msg }) catch |err| {
                            std.log.err("[whatsapp] failed to spawn message handler: {}", .{err});
                            var doomed = msg;
                            doomed.deinit();
                            return;
                        };
                        th.detach();
                    } else {
                        var unused = msg;
                        unused.deinit();
                    }
                }
            } else if (std.mem.eql(u8, method, "connection")) {
                if (value.object.get("params")) |params| {
                    const update = try parseConnectionUpdate(self.allocator, params);
                    const status = update.status;
                    if (status == .connected) {
                        var new_jid = if (update.self_jid) |jid| try self.allocator.dupe(u8, jid) else null;
                        errdefer if (new_jid) |nj| self.allocator.free(nj);
                        var new_e164 = if (update.self_e164) |e164| try self.allocator.dupe(u8, e164) else null;
                        errdefer if (new_e164) |ne| self.allocator.free(ne);
                        try self.mutex.lock(self.channelIo());
                        if (self.self_jid) |old| self.allocator.free(old);
                        self.self_jid = new_jid;
                        new_jid = null;
                        if (self.self_e164) |old| self.allocator.free(old);
                        self.self_e164 = new_e164;
                        new_e164 = null;
                        self.connected = true;
                        self.mutex.unlock(self.channelIo());
                    } else if (status == .disconnected) {
                        try self.mutex.lock(self.channelIo());
                        self.connected = false;
                        self.mutex.unlock(self.channelIo());
                    }
                    if (self.connection_handler) |handler| {
                        try handler(update);
                    }
                } else if (std.mem.eql(u8, method, "qr")) {
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

    /// Memory: Caller owns returned WhatsAppMessage; must call deinit() to free all duped strings. All fields are allocator.dupe'd.
    fn parseMessageType(s: []const u8) types.MessageType {
        if (std.mem.eql(u8, s, "image") or std.mem.startsWith(u8, s, "image")) return .image;
        if (std.mem.eql(u8, s, "video") or std.mem.startsWith(u8, s, "video")) return .video;
        if (std.mem.eql(u8, s, "audio") or std.mem.startsWith(u8, s, "audio")) return .audio;
        if (std.mem.eql(u8, s, "document") or std.mem.startsWith(u8, s, "document")) return .document;
        if (std.mem.eql(u8, s, "location")) return .location;
        return .text;
    }

    fn jsonStr(v: std.json.Value) ?[]const u8 {
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    fn jsonI64(v: std.json.Value) i64 {
        return switch (v) {
            .integer => |i| i,
            .float => |f| blk: {
                if (!std.math.isFinite(f)) break :blk 0;
                if (f > @as(f64, @floatFromInt(std.math.maxInt(i64)))) break :blk std.math.maxInt(i64);
                if (f < @as(f64, @floatFromInt(std.math.minInt(i64)))) break :blk std.math.minInt(i64);
                break :blk @intFromFloat(f);
            },
            .number_string => |ns| std.fmt.parseInt(i64, ns, 10) catch 0,
            else => 0,
        };
    }

    pub fn parseMessage(allocator: Allocator, value: std.json.Value) !WhatsAppMessage {
        if (value != .object) return error.InvalidMessage;
        var msg = try WhatsAppMessage.init(allocator);
        errdefer msg.deinit();

        if (value.object.get("id")) |id| {
            if (jsonStr(id)) |s| msg.id = try allocator.dupe(u8, s);
        }
        if (value.object.get("from")) |from| {
            if (jsonStr(from)) |s| msg.from = try allocator.dupe(u8, s);
        }
        if (value.object.get("to")) |to| {
            if (jsonStr(to)) |s| msg.to = try allocator.dupe(u8, s);
        }
        if (value.object.get("chatId")) |chat_id| {
            if (jsonStr(chat_id)) |s| msg.chat_id = try allocator.dupe(u8, s);
        }
        if (value.object.get("chatType")) |chat_type| {
            if (jsonStr(chat_type)) |s| {
                msg.chat_type = if (std.mem.eql(u8, s, "group")) .group else .direct;
            }
        }
        if (value.object.get("senderJid")) |sender_jid| {
            if (jsonStr(sender_jid)) |s| msg.sender_jid = try allocator.dupe(u8, s);
        }
        if (value.object.get("senderE164")) |sender_e164| {
            if (jsonStr(sender_e164)) |s| msg.sender_e164 = try allocator.dupe(u8, s);
        }
        if (value.object.get("senderName")) |sender_name| {
            if (jsonStr(sender_name)) |s| msg.sender_name = try allocator.dupe(u8, s);
        }
        if (value.object.get("messageType")) |mt| {
            if (mt == .string) msg.message_type = parseMessageType(mt.string);
        }
        if (value.object.get("mediaType")) |mt| {
            if (mt == .string) {
                if (msg.media_type) |oldm| allocator.free(oldm);
                msg.media_type = try allocator.dupe(u8, mt.string);
                if (msg.message_type == .text) msg.message_type = parseMessageType(mt.string);
            }
        }
        if (value.object.get("mediaPath")) |mp| {
            if (mp == .string and mp.string.len > 0) {
                if (msg.media_path) |old| allocator.free(old);
                msg.media_path = try allocator.dupe(u8, mp.string);
            }
        }
        if (value.object.get("caption")) |cap| {
            if (cap == .string and msg.body.len == 0) {
                allocator.free(msg.body);
                msg.body = try allocator.dupe(u8, cap.string);
            }
        }
        if (value.object.get("body")) |body| {
            if (body == .string and body.string.len > 0) {
                allocator.free(msg.body);
                msg.body = try allocator.dupe(u8, body.string);
            }
        }
        // Synthesize a body so empty media still reaches the agent loop.
        if (msg.body.len == 0 and msg.message_type != .text) {
            allocator.free(msg.body);
            const tag = @tagName(msg.message_type);
            msg.body = try std.fmt.allocPrint(allocator, "[{s} attached] barvis", .{tag});
        }
        if (value.object.get("timestamp")) |timestamp| msg.timestamp = jsonI64(timestamp);
        if (value.object.get("fromMe")) |fm| msg.from_me = switch (fm) {
            .bool => |b| b,
            .integer => |i| i != 0,
            else => false,
        };

        return msg;
    }

    /// Memory: Callee takes ownership of `msg` and calls deinit() when the handler returns.
    fn dispatchMessage(handler: *const fn (message: WhatsAppMessage) anyerror!void, msg: WhatsAppMessage) void {
        var owned = msg;
        defer owned.deinit();
        handler(owned) catch |err| {
            std.log.err("[whatsapp] message handler failed: {}", .{err});
        };
    }

    /// Reusable HTTP transport for media downloads/uploads. `getFn`/`postFn`
    /// return transport-owned memory valid until the next call on the same
    /// transport (media.zig Transport contract).
    const MediaHttp = struct {
        alloc: Allocator,
        client: std.http.Client,
        last: ?[]u8 = null,

        fn init(alloc: Allocator) MediaHttp {
            return .{ .alloc = alloc, .client = std.http.Client{ .allocator = alloc, .io = compat.getIo() } };
        }

        fn deinit(self: *MediaHttp) void {
            if (self.last) |l| self.alloc.free(l);
            self.last = null;
            self.client.deinit();
        }

        fn readAll(m: *MediaHttp, req: *std.http.Client.Request) anyerror![]const u8 {
            var redirect_buffer: [1024]u8 = undefined;
            var response = req.receiveHead(&redirect_buffer) catch return error.MediaConnect;
            if (response.head.status.class() != .success) return error.MediaHttpStatus;
            var transfer_buffer: [16384]u8 = undefined;
            const reader = response.reader(&transfer_buffer);
            // Media files buffer in memory (Baileys streams; 64 MiB covers
            // realistic voice notes/images/docs for an agent loop).
            const bytes = reader.allocRemaining(m.alloc, .limited(64 * 1024 * 1024)) catch return error.MediaIo;
            m.last = bytes;
            return m.last.?;
        }

        fn getFn(ptr: *anyopaque, url: []const u8) anyerror![]const u8 {
            const m: *MediaHttp = @ptrCast(@alignCast(ptr));
            if (m.last) |l| m.alloc.free(l);
            m.last = null;
            const uri = std.Uri.parse(url) catch return error.BadMediaUrl;
            var req = m.client.request(.GET, uri, .{}) catch return error.MediaConnect;
            defer req.deinit();
            req.sendBodiless() catch return error.MediaConnect;
            return readAll(m, &req);
        }

        fn postFn(ptr: *anyopaque, url: []const u8, body: []const u8) anyerror![]const u8 {
            const m: *MediaHttp = @ptrCast(@alignCast(ptr));
            if (m.last) |l| m.alloc.free(l);
            m.last = null;
            const uri = std.Uri.parse(url) catch return error.BadMediaUrl;
            const body_copy = m.alloc.dupe(u8, body) catch return error.OutOfMemory;
            defer m.alloc.free(body_copy);
            var req = m.client.request(.POST, uri, .{}) catch return error.MediaConnect;
            defer req.deinit();
            req.sendBodyComplete(body_copy) catch return error.MediaConnect;
            return readAll(m, &req);
        }
    };

    fn mediaTypeName(kind: media_mod.Kind) []const u8 {
        return switch (kind) {
            .image => "image",
            .sticker => "sticker",
            .video => "video",
            .audio, .ptt => "audio",
            .document => "document",
        };
    }

    fn mediaExt(kind: media_mod.Kind, mime: ?[]const u8) []const u8 {
        if (mime) |m| {
            if (std.mem.indexOf(u8, m, "png") != null) return "png";
            if (std.mem.indexOf(u8, m, "webp") != null) return "webp";
            if (std.mem.indexOf(u8, m, "mp4") != null) return "mp4";
            if (std.mem.indexOf(u8, m, "ogg") != null) return "ogg";
            if (std.mem.indexOf(u8, m, "opus") != null) return "opus";
            if (std.mem.indexOf(u8, m, "m4a") != null) return "m4a";
            if (std.mem.indexOf(u8, m, "amr") != null) return "amr";
            if (std.mem.indexOf(u8, m, "pdf") != null) return "pdf";
        }
        return switch (kind) {
            .image => "jpg",
            .sticker => "webp",
            .video => "mp4",
            .audio, .ptt => "ogg",
            .document => "bin",
        };
    }

    /// Download + decrypt an inbound media attachment into `{auth_dir}/media/{id}.{ext}`,
    /// mirroring the Baileys wrapper's file layout (baileys_wrapper.js saveMedia).
    fn saveNativeMedia(self: *WhatsAppChannel, msg: *WhatsAppMessage, att: *native_mod.InboundMessage.MediaAttachment) !void {
        var mh = MediaHttp.init(self.allocator);
        defer mh.deinit();
        const t = media_mod.Transport{ .ptr = &mh, .getFn = MediaHttp.getFn, .postFn = MediaHttp.postFn };
        const plain = try media_mod.download(self.allocator, att.kind, &att.media_key, att.url, t);
        defer self.allocator.free(plain);
        ensureAuthDir(self.config.auth_dir);
        const clean_id = try self.allocator.dupe(u8, msg.id);
        defer self.allocator.free(clean_id);
        for (clean_id) |*ch| {
            if (!std.ascii.isAlphanumeric(ch.*) and ch.* != '_' and ch.* != '-') ch.* = '_';
        }
        const media_dir = try std.fmt.allocPrint(self.allocator, "{s}/media", .{self.config.auth_dir});
        defer self.allocator.free(media_dir);
        const cwd = compat.cwd();
        std.Io.Dir.createDirPath(cwd.dir, cwd.io, media_dir) catch {};
        const fname = try std.fmt.allocPrint(self.allocator, "{s}/media/{s}.{s}", .{
            self.config.auth_dir, clean_id, mediaExt(att.kind, att.mimetype),
        });
        defer self.allocator.free(fname);
        var f = cwd.createFile(fname, .{ .truncate = true }) catch |err| {
            std.log.warn("[whatsapp] native media create {s} failed: {}", .{ fname, err });
            return err;
        };
        defer f.close(cwd.io);
        var w = f.writer(cwd.io, &[_]u8{});
        try w.interface.writeAll(plain);
        msg.media_path = try self.allocator.dupe(u8, fname);
    }

    /// Per-message handler thread for native inbound: downloads media off the
    /// reader loop, then hands the mapped message to the channel handler.
    /// Memory: takes ownership of `msg` and `media_att`.
    fn dispatchNativeMessage(
        self: *WhatsAppChannel,
        handler: *const fn (message: WhatsAppMessage) anyerror!void,
        msg: WhatsAppMessage,
        media_att: ?native_mod.InboundMessage.MediaAttachment,
    ) void {
        var owned = msg;
        defer owned.deinit();
        var att = media_att;
        defer if (att) |*a| a.deinit(self.allocator);
        if (att) |*a| {
            const mt = mediaTypeName(a.kind);
            if (owned.media_type) |old| self.allocator.free(old);
            owned.media_type = self.allocator.dupe(u8, mt) catch null;
            owned.message_type = parseMessageType(mt);
            self.saveNativeMedia(&owned, a) catch |err| {
                std.log.warn("[whatsapp] native media download failed ({s}): {}", .{ mt, err });
            };
        }
        handler(owned) catch |err| {
            std.log.err("[whatsapp] message handler failed: {}", .{err});
        };
    }

    /// Parse connection update from JSON
    /// Memory: Caller owns returned self_jid/self_e164/error strings; must free each non-null field.
    pub fn parseConnectionUpdate(allocator: Allocator, value: std.json.Value) !ConnectionUpdate {
        var update: ConnectionUpdate = .{
            .status = .disconnected,
            .self_jid = null,
            .self_e164 = null,
            .@"error" = null,
        };

        if (value != .object) return error.InvalidConnection;
        if (value.object.get("type")) |type_str| {
            if (jsonStr(type_str)) |s| {
                if (std.mem.eql(u8, s, "connected")) {
                    update.status = .connected;
                } else if (std.mem.eql(u8, s, "disconnected")) {
                    update.status = .disconnected;
                }
            }
        }

        if (value.object.get("selfJid")) |self_jid| {
            if (jsonStr(self_jid)) |s| update.self_jid = try allocator.dupe(u8, s);
        }
        if (value.object.get("selfE164")) |self_e164| {
            if (jsonStr(self_e164)) |s| update.self_e164 = try allocator.dupe(u8, s);
        }
        if (value.object.get("error")) |err_val| {
            if (jsonStr(err_val)) |s| update.@"error" = try allocator.dupe(u8, s);
        }

        return update;
    }
};

fn ensureAuthDir(path: []const u8) void {
    if (path.len == 0) return;
    const cwd = compat.cwd();
    std.Io.Dir.createDirPath(cwd.dir, cwd.io, path) catch {};
}

fn nextBackoff(ms: u64) u64 {
    const doubled = ms *| 2;
    return if (doubled > 60_000) 60_000 else doubled;
}

fn pollErrorIsRestart(err: anyerror) bool {
    return err == error.WebSocketClosed or err == error.EndOfStream;
}

fn jidUserPart(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '@')) |at| return s[0..at];
    return s;
}

fn digitsBeforeColon(s: []const u8) []const u8 {
    const user_part = jidUserPart(s);
    if (std.mem.indexOfScalar(u8, user_part, ':')) |c| return user_part[0..c];
    return user_part;
}

fn replaceOwned(allocator: Allocator, dest: *[]const u8, src: []const u8) !void {
    const n = try allocator.dupe(u8, src);
    allocator.free(dest.*);
    dest.* = n;
}

fn printQrUtf8(allocator: Allocator, code: []const u8) void {
    const rendered = qrcode.renderUtf8(allocator, code) catch {
        std.debug.print("{s}\n", .{code});
        return;
    };
    defer allocator.free(rendered);
    std.debug.print("{s}", .{rendered});
    if (rendered.len == 0 or rendered[rendered.len - 1] != '\n') std.debug.print("\n", .{});
    std.debug.print("{s}\n", .{code});
}

fn printQrUtf8AndLog(allocator: Allocator, code: []const u8) void {
    const rendered = qrcode.renderUtf8(allocator, code) catch {
        std.debug.print("{s}\n", .{code});
        std.log.info("{s}", .{code});
        return;
    };
    defer allocator.free(rendered);
    std.debug.print("{s}", .{rendered});
    if (rendered.len == 0 or rendered[rendered.len - 1] != '\n') std.debug.print("\n", .{});
    var it = std.mem.splitScalar(u8, rendered, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        std.log.info("{s}", .{line});
    }
}

/// Map a native InboundMessage onto the same WhatsAppMessage fields the Node
/// `[zepto] emit` path produces. `inbound` is borrowed; own_jid/own_e164 are borrowed.
/// Memory: caller owns returned WhatsAppMessage; must call deinit().
pub fn inboundToWhatsAppMessage(
    allocator: Allocator,
    inbound: native_mod.InboundMessage,
    own_jid: ?[]const u8,
    own_e164: ?[]const u8,
) !WhatsAppMessage {
    var msg = try WhatsAppMessage.init(allocator);
    errdefer msg.deinit();

    try replaceOwned(allocator, &msg.id, inbound.id);
    try replaceOwned(allocator, &msg.chat_id, inbound.chat);
    msg.chat_type = if (inbound.is_group) .group else .direct;
    msg.from_me = inbound.from_me;
    msg.timestamp = inbound.timestamp;
    msg.message_type = .text;
    try replaceOwned(allocator, &msg.body, inbound.text);

    if (inbound.is_group) {
        try replaceOwned(allocator, &msg.from, inbound.chat);
    } else {
        try replaceOwned(allocator, &msg.from, jidUserPart(inbound.chat));
    }
    if (own_e164) |e| try replaceOwned(allocator, &msg.to, e);

    const sender_jid = blk: {
        if (inbound.from_me) break :blk own_jid orelse inbound.sender;
        if (inbound.is_group) break :blk inbound.sender;
        break :blk inbound.sender_pn orelse inbound.sender;
    };
    try replaceOwned(allocator, &msg.sender_jid, sender_jid);

    const e164_src: []const u8 = blk: {
        if (inbound.from_me) {
            if (own_e164) |e| if (e.len > 0) break :blk e;
            if (inbound.sender_pn) |pn| break :blk digitsBeforeColon(pn);
            break :blk digitsBeforeColon(own_jid orelse inbound.sender);
        }
        if (inbound.sender_pn) |pn| break :blk digitsBeforeColon(pn);
        break :blk digitsBeforeColon(inbound.sender);
    };
    if (e164_src.len > 0) {
        if (msg.sender_e164) |old| allocator.free(old);
        msg.sender_e164 = try allocator.dupe(u8, e164_src);
    }

    const name: ?[]const u8 = if (inbound.from_me) "Baala" else inbound.push_name;
    if (name) |n| {
        if (n.len > 0) {
            if (msg.sender_name) |old| allocator.free(old);
            msg.sender_name = try allocator.dupe(u8, n);
        }
    }
    return msg;
}

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
    message_id: ?[]const u8 = null,
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

test "disconnect on never-connected channel" {
    const allocator = std.testing.allocator;
    var config = try WhatsAppConfig.init(allocator);
    defer config.deinit();

    var channel = WhatsAppChannel.init(allocator, config);
    defer channel.deinit();

    try channel.disconnect();
    try std.testing.expectEqual(false, channel.connected);
    try std.testing.expect(channel.node_process == null);
}

test "disconnect on never-connected native channel" {
    const allocator = std.testing.allocator;
    var config = try WhatsAppConfig.init(allocator);
    defer config.deinit();
    config.native = true;

    var channel = WhatsAppChannel.init(allocator, config);
    defer channel.deinit();

    try std.testing.expect(channel.use_native);
    try channel.disconnect();
    try std.testing.expectEqual(false, channel.connected);
    try std.testing.expect(channel.native_client == null);
    try std.testing.expect(channel.node_process == null);
}

fn testInbound(
    allocator: std.mem.Allocator,
    id: []const u8,
    chat: []const u8,
    sender: []const u8,
    sender_pn: ?[]const u8,
    push_name: ?[]const u8,
    text: []const u8,
    from_me: bool,
    timestamp: i64,
    is_group: bool,
) !native_mod.InboundMessage {
    return .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, id),
        .chat = try allocator.dupe(u8, chat),
        .sender = try allocator.dupe(u8, sender),
        .sender_pn = if (sender_pn) |x| try allocator.dupe(u8, x) else null,
        .push_name = if (push_name) |x| try allocator.dupe(u8, x) else null,
        .text = try allocator.dupe(u8, text),
        .from_me = from_me,
        .timestamp = timestamp,
        .is_group = is_group,
    };
}

test "inboundToWhatsAppMessage fromMe self-chat LID and peer PN DM" {
    const allocator = std.testing.allocator;
    const own_jid = "917019895010:55@s.whatsapp.net";
    const own_e164 = "917019895010";

    var self_chat = try testInbound(
        allocator,
        "m1",
        "216638251077681@lid",
        "917019895010:55@s.whatsapp.net",
        "917019895010:55@s.whatsapp.net",
        null,
        "barvis ping",
        true,
        1_700_000_000,
        false,
    );
    defer self_chat.deinit();
    var self_msg = try inboundToWhatsAppMessage(allocator, self_chat, own_jid, own_e164);
    defer self_msg.deinit();
    try std.testing.expectEqualStrings("216638251077681@lid", self_msg.chat_id);
    try std.testing.expectEqualStrings("917019895010", self_msg.sender_e164.?);
    try std.testing.expectEqual(true, self_msg.from_me);
    try std.testing.expectEqual(types.ChatType.direct, self_msg.chat_type);
    try std.testing.expectEqualStrings("216638251077681", self_msg.from);
    try std.testing.expectEqualStrings(own_jid, self_msg.sender_jid);
    try std.testing.expectEqualStrings("Baala", self_msg.sender_name.?);
    try std.testing.expectEqualStrings("barvis ping", self_msg.body);
    try std.testing.expectEqualStrings("m1", self_msg.id);
    try std.testing.expectEqual(types.MessageType.text, self_msg.message_type);
    try std.testing.expectEqualStrings(own_e164, self_msg.to);

    var peer = try testInbound(
        allocator,
        "m2",
        "15551212@s.whatsapp.net",
        "15551212@s.whatsapp.net",
        "15551212@s.whatsapp.net",
        "Alice",
        "hello",
        false,
        1_700_000_001,
        false,
    );
    defer peer.deinit();
    var peer_msg = try inboundToWhatsAppMessage(allocator, peer, own_jid, own_e164);
    defer peer_msg.deinit();
    try std.testing.expectEqualStrings("15551212@s.whatsapp.net", peer_msg.chat_id);
    try std.testing.expectEqualStrings("15551212", peer_msg.from);
    try std.testing.expectEqualStrings("15551212@s.whatsapp.net", peer_msg.sender_jid);
    try std.testing.expectEqualStrings("15551212", peer_msg.sender_e164.?);
    try std.testing.expectEqual(false, peer_msg.from_me);
    try std.testing.expectEqual(types.ChatType.direct, peer_msg.chat_type);
    try std.testing.expectEqualStrings("Alice", peer_msg.sender_name.?);
    try std.testing.expectEqualStrings("hello", peer_msg.body);
    try std.testing.expectEqualStrings(own_e164, peer_msg.to);
    try std.testing.expectEqual(types.MessageType.text, peer_msg.message_type);
}

fn fuzzParseInbound(_: void, smith: *std.testing.Smith) !void {
    var buf: [1024]u8 = undefined;
    const n = smith.slice(&buf);
    const slice = buf[0..n];
    const allocator = std.testing.allocator;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, slice, .{}) catch return;
    defer parsed.deinit();
    var msg = WhatsAppChannel.parseMessage(allocator, parsed.value) catch return;
    defer msg.deinit();
    _ = msg.body.len;
    const upd = WhatsAppChannel.parseConnectionUpdate(allocator, parsed.value) catch return;
    if (upd.self_jid) |s| allocator.free(s);
    if (upd.self_e164) |s| allocator.free(s);
    if (upd.@"error") |s| allocator.free(s);
}

test "fuzz inbound json parse" {
    try std.testing.fuzz({}, fuzzParseInbound, .{
        .corpus = &.{
            "{}",
            "[]",
            "null",
            "not-json",
            "{\"chatId\":\"19082673946862@lid\",\"body\":\"hi barvis\",\"fromMe\":true,\"id\":\"m1\"}",
            "{\"type\":\"connected\",\"selfJid\":\"917019895010:55@s.whatsapp.net\"}",
            "{\"id\":1,\"fromMe\":\"yes\",\"timestamp\":1e308,\"body\":{\"x\":1}}",
            "{\"mediaType\":\"image\",\"mediaPath\":\"/tmp/x.jpg\",\"caption\":\"top\"}",
            "{\"chatType\":\"group\",\"mentionedJids\":[1,2]}",
        },
    });
}
