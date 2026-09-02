const std = @import("std");
const wsc = @import("ws_client.zig");

/// WebSocket upgrade over TCP+TLS for `wss://web.whatsapp.com/ws/chat`.
/// Port of coder/websocket + whatsmeow FrameSocket transport (RFC6455).
///
/// Zig 0.16 has no `std.Io.tls`; the TLS record layer is `std.crypto.tls.Client`
/// (same path as `std.http.Client`). `wsc.connectTls` returns a raw TCP stream;
/// this file wraps it. If handshake setup cannot run, `connect` returns
/// `error.TlsNotWired` rather than sending an upgrade on plaintext TCP.

pub const default_host: []const u8 = "web.whatsapp.com";
pub const default_path: []const u8 = "/ws/chat";
pub const default_origin: []const u8 = "https://web.whatsapp.com";
pub const default_port: u16 = 443;

pub const ParsedUrl = struct {
    host: []const u8,
    path: []const u8,
    port: u16,
    tls: bool,
};

pub const ParsedUpgrade = struct {
    status: u16,
    accept: []const u8,
};

/// Parse `wss://host[:port]/path` (slices alias `url`).
pub fn parseWssUrl(url: []const u8) ParsedUrl {
    var rest = url;
    var tls = true;
    var port: u16 = default_port;
    if (std.mem.startsWith(u8, rest, "wss://")) {
        rest = rest["wss://".len..];
        tls = true;
        port = 443;
    } else if (std.mem.startsWith(u8, rest, "ws://")) {
        rest = rest["ws://".len..];
        tls = false;
        port = 80;
    }
    const slash = std.mem.findScalar(u8, rest, '/');
    const hostport = if (slash) |i| rest[0..i] else rest;
    const path = if (slash) |i| rest[i..] else default_path;
    var host = hostport;
    if (hostport.len > 0 and hostport[0] != '[') {
        if (std.mem.findScalarLast(u8, hostport, ':')) |c| {
            if (std.fmt.parseInt(u16, hostport[c + 1 ..], 10)) |p| {
                host = hostport[0..c];
                port = p;
            } else |_| {}
        }
    }
    if (host.len == 0) host = default_host;
    if (path.len == 0) return .{ .host = host, .path = default_path, .port = port, .tls = tls };
    return .{ .host = host, .path = path, .port = port, .tls = tls };
}

/// Memory: caller owns the returned request bytes (`allocator.free`).
pub fn buildUpgradeRequest(
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
    origin: []const u8,
    sec_key: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Origin: {s}\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "\r\n",
        .{ path, host, origin, sec_key },
    );
}

/// Parse an HTTP/1.1 upgrade response. `accept` aliases `bytes`.
pub fn parseUpgradeResponse(bytes: []const u8) !ParsedUpgrade {
    const sep = std.mem.find(u8, bytes, "\r\n\r\n") orelse return error.IncompleteHeaders;
    const head = bytes[0..sep];
    const first_nl = std.mem.find(u8, head, "\r\n") orelse return error.BadStatusLine;
    const status_line = head[0..first_nl];
    var sit = std.mem.splitScalar(u8, status_line, ' ');
    _ = sit.next() orelse return error.BadStatusLine;
    const code_s = sit.next() orelse return error.BadStatusLine;
    const status = std.fmt.parseInt(u16, code_s, 10) catch return error.BadStatusLine;

    var accept: ?[]const u8 = null;
    var rest = head[first_nl + 2 ..];
    while (rest.len > 0) {
        const nl = std.mem.find(u8, rest, "\r\n") orelse rest.len;
        const line = rest[0..nl];
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.BadHeader;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Accept")) {
            accept = value;
        }
        if (nl >= rest.len) break;
        rest = rest[nl + 2 ..];
    }
    if (status != 101) return error.UnexpectedStatus;
    return .{
        .status = status,
        .accept = accept orelse return error.MissingAccept,
    };
}

pub fn verifyAccept(client_key: []const u8, accept: []const u8) !void {
    var expected: [28]u8 = undefined;
    wsc.wsAcceptKey(client_key, &expected);
    if (!std.mem.eql(u8, accept, &expected)) return error.BadWebSocketAccept;
}

/// RFC6455 upgrade on an already-decrypted (TLS or test) byte stream.
/// `raw_writer`: transport beneath `writer` (tls.Client.flush only encrypts into
/// its output buffer and never flushes it to the socket).
pub fn performUpgrade(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    raw_writer: ?*std.Io.Writer,
    host: []const u8,
    path: []const u8,
    origin: []const u8,
    io: std.Io,
) !void {
    var key: [24]u8 = undefined;
    wsc.wsGenKey(io, &key);
    const req = try buildUpgradeRequest(allocator, host, path, origin, &key);
    defer allocator.free(req);
    try writer.writeAll(req);
    try writer.flush();
    if (raw_writer) |rw| try rw.flush();
    const head = try readHttpHead(allocator, reader);
    defer allocator.free(head);
    const parsed = try parseUpgradeResponse(head);
    try verifyAccept(&key, parsed.accept);
}

fn readHttpHead(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var parser: std.http.HeadParser = .{};
    while (parser.state != .finished) {
        reader.fill(1) catch |err| switch (err) {
            error.EndOfStream => return error.IncompleteHeaders,
            else => |e| return e,
        };
        const chunk = reader.buffered();
        if (chunk.len == 0) return error.IncompleteHeaders;
        const n = parser.feed(chunk);
        if (n == 0) return error.IncompleteHeaders;
        try list.appendSlice(allocator, chunk[0..n]);
        reader.toss(n);
        if (list.items.len > 16 * 1024) return error.HttpHeadersOversize;
    }
    return try list.toOwnedSlice(allocator);
}

const TlsSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    stream_reader: std.Io.net.Stream.Reader,
    stream_writer: std.Io.net.Stream.Writer,
    client: std.crypto.tls.Client,
    ca_bundle: std.crypto.Certificate.Bundle,
    ca_lock: std.Io.RwLock,
    enc_in: []u8,
    enc_out: []u8,
    pt_in: []u8,
    pt_out: []u8,
    handshake_ok: bool,

    /// tls.Client.writer.flush() only encrypts into `stream_writer`'s buffer;
    /// push that buffer to the socket too.
    fn flush(self: *TlsSession) !void {
        try self.client.writer.flush();
        try self.stream_writer.interface.flush();
    }

    fn destroy(self: *TlsSession) void {
        if (self.handshake_ok) {
            self.client.end() catch {};
            self.stream_writer.interface.flush() catch {};
        }
        self.ca_bundle.deinit(self.allocator);
        self.stream.close(self.io);
        self.allocator.free(self.enc_in);
        self.allocator.free(self.enc_out);
        self.allocator.free(self.pt_in);
        self.allocator.free(self.pt_out);
        const a = self.allocator;
        a.destroy(self);
    }
};

fn abortUnconnected(session: *TlsSession) void {
    session.ca_bundle.deinit(session.allocator);
    session.allocator.free(session.enc_in);
    session.allocator.free(session.enc_out);
    session.allocator.free(session.pt_in);
    session.allocator.free(session.pt_out);
    const a = session.allocator;
    a.destroy(session);
}

fn startTls(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    host: []const u8,
) !*TlsSession {
    const min_buf = std.crypto.tls.Client.min_buffer_len;
    var session_owns_buffers = false;
    const enc_in = try allocator.alloc(u8, min_buf);
    errdefer if (!session_owns_buffers) allocator.free(enc_in);
    const enc_out = try allocator.alloc(u8, min_buf);
    errdefer if (!session_owns_buffers) allocator.free(enc_out);
    const pt_in = try allocator.alloc(u8, min_buf + 8192);
    errdefer if (!session_owns_buffers) allocator.free(pt_in);
    const pt_out = try allocator.alloc(u8, min_buf);
    errdefer if (!session_owns_buffers) allocator.free(pt_out);

    const session = try allocator.create(TlsSession);
    session.* = .{
        .allocator = allocator,
        .io = io,
        .stream = stream,
        .stream_reader = stream.reader(io, enc_in),
        .stream_writer = stream.writer(io, enc_out),
        .client = undefined,
        .ca_bundle = .empty,
        .ca_lock = .init,
        .enc_in = enc_in,
        .enc_out = enc_out,
        .pt_in = pt_in,
        .pt_out = pt_out,
        .handshake_ok = false,
    };
    session_owns_buffers = true;
    var success = false;
    errdefer if (!success) abortUnconnected(session);

    const now = std.Io.Clock.real.now(io);
    session.ca_bundle.rescan(allocator, io, now) catch return error.TlsNotWired;

    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);

    session.client = std.crypto.tls.Client.init(
        &session.stream_reader.interface,
        &session.stream_writer.interface,
        .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = .{
                .gpa = allocator,
                .io = io,
                .lock = &session.ca_lock,
                .bundle = &session.ca_bundle,
            } },
            .read_buffer = pt_in,
            .write_buffer = pt_out,
            .entropy = &entropy,
            .realtime_now = now,
            .allow_truncation_attacks = true,
        },
    ) catch |err| switch (err) {
        error.WriteFailed => return session.stream_writer.err orelse error.TlsNotWired,
        error.ReadFailed => return session.stream_reader.err orelse error.TlsNotWired,
        else => return error.TlsNotWired,
    };
    session.handshake_ok = true;
    success = true;
    return session;
}

pub const WsClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: ?std.Io.net.Stream = null,
    tls: ?*TlsSession = null,

    pub fn init(allocator: std.mem.Allocator) WsClient {
        return .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
        };
    }

    pub fn deinit(self: *WsClient) void {
        self.disconnect();
    }

    pub fn disconnect(self: *WsClient) void {
        if (self.tls) |t| {
            t.destroy();
            self.tls = null;
            self.stream = null;
            return;
        }
        if (self.stream) |s| {
            s.close(self.io);
            self.stream = null;
        }
    }

    pub fn connect(self: *WsClient, host: []const u8, path: []const u8) !void {
        try self.connectTo(host, default_port, path, default_origin);
    }

    pub fn connectTo(
        self: *WsClient,
        host: []const u8,
        port: u16,
        path: []const u8,
        origin: []const u8,
    ) !void {
        self.disconnect();
        var stream = try wsc.connectTls(host, port, self.io, self.allocator);
        const session = startTls(self.allocator, self.io, stream, host) catch |err| {
            stream.close(self.io);
            return err;
        };
        errdefer session.destroy();

        const host_header = if (port == 443 or port == 80)
            host
        else
            try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ host, port });
        defer if (port != 443 and port != 80) self.allocator.free(host_header);

        try performUpgrade(
            self.allocator,
            &session.client.reader,
            &session.client.writer,
            &session.stream_writer.interface,
            host_header,
            path,
            origin,
            self.io,
        );
        self.stream = stream;
        self.tls = session;
    }

    fn tlsReader(self: *WsClient) !*std.Io.Reader {
        const session = self.tls orelse return error.NotConnected;
        return &session.client.reader;
    }

    pub fn writeFrame(self: *WsClient, data: []const u8, opcode: u8) !void {
        const session = self.tls orelse return error.NotConnected;
        const encoded = try wsc.wsEncodeFrame(
            self.allocator,
            data,
            @enumFromInt(opcode),
            true,
            self.io,
        );
        defer self.allocator.free(encoded);
        try session.client.writer.writeAll(encoded);
        try session.flush();
    }

    /// Memory: caller owns the returned payload (`allocator.free`).
    pub fn readFrameAlloc(self: *WsClient) ![]u8 {
        const reader = try self.tlsReader();
        while (true) {
            const payload = try readWsPayload(self.allocator, reader);
            const opcode: wsc.WsOpcode = payload.opcode;
            switch (opcode) {
                .binary, .text => return payload.bytes,
                .ping => {
                    defer self.allocator.free(payload.bytes);
                    try self.writeFrame(payload.bytes, @intFromEnum(wsc.WsOpcode.pong));
                },
                .pong, .continuation => {
                    self.allocator.free(payload.bytes);
                },
                .close => {
                    self.allocator.free(payload.bytes);
                    return error.WebSocketClosed;
                },
                _ => {
                    self.allocator.free(payload.bytes);
                    return error.UnsupportedOpcode;
                },
            }
        }
    }

    pub fn readFrame(self: *WsClient, buf: []u8) !usize {
        const payload = try self.readFrameAlloc();
        defer self.allocator.free(payload);
        if (payload.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[0..payload.len], payload);
        return payload.len;
    }
};

const WsPayload = struct {
    opcode: wsc.WsOpcode,
    bytes: []u8,
};

fn readWsPayload(allocator: std.mem.Allocator, reader: *std.Io.Reader) !WsPayload {
    var hdr: [14]u8 = undefined;
    try reader.readSliceAll(hdr[0..2]);
    const b1 = hdr[1];
    var need: usize = 2;
    const llen = b1 & 0x7F;
    if (llen == 126) need = 4 else if (llen == 127) need = 10;
    if (b1 & 0x80 != 0) need += 4;
    if (need > 2) try reader.readSliceAll(hdr[2..need]);
    const h = try wsc.wsDecodeHeader(hdr[0..need]);
    const bytes = try allocator.alloc(u8, h.payload_len);
    errdefer allocator.free(bytes);
    if (h.payload_len > 0) try reader.readSliceAll(bytes);
    if (h.mask_key) |key| {
        for (bytes, 0..) |*b, i| b.* ^= key[i % 4];
    }
    return .{ .opcode = h.opcode, .bytes = bytes };
}

fn unmask(payload: []u8, key: [4]u8) void {
    for (payload, 0..) |*b, i| b.* ^= key[i % 4];
}

test "upgrade request builder" {
    const alloc = std.testing.allocator;
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const req = try buildUpgradeRequest(alloc, default_host, default_path, default_origin, key);
    defer alloc.free(req);
    try std.testing.expect(std.mem.startsWith(u8, req, "GET /ws/chat HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.find(u8, req, "Host: web.whatsapp.com\r\n") != null);
    try std.testing.expect(std.mem.find(u8, req, "Origin: https://web.whatsapp.com\r\n") != null);
    try std.testing.expect(std.mem.find(u8, req, "Connection: Upgrade\r\n") != null);
    try std.testing.expect(std.mem.find(u8, req, "Upgrade: websocket\r\n") != null);
    try std.testing.expect(std.mem.find(u8, req, "Sec-WebSocket-Version: 13\r\n") != null);
    try std.testing.expect(std.mem.find(u8, req, "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, req, "\r\n\r\n"));
}

test "upgrade response parser RFC6455" {
    const ck = "dGhlIHNhbXBsZSBub25jZQ==";
    const resp =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "\r\n";
    const parsed = try parseUpgradeResponse(resp);
    try std.testing.expectEqual(@as(u16, 101), parsed.status);
    try verifyAccept(ck, parsed.accept);
}

test "upgrade response rejects non-101" {
    const resp = "HTTP/1.1 400 Bad Request\r\nSec-WebSocket-Accept: x\r\n\r\n";
    try std.testing.expectError(error.UnexpectedStatus, parseUpgradeResponse(resp));
}

test "upgrade response rejects missing accept" {
    const resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n";
    try std.testing.expectError(error.MissingAccept, parseUpgradeResponse(resp));
}

test "upgrade response rejects wrong accept" {
    const ck = "dGhlIHNhbXBsZSBub25jZQ==";
    try std.testing.expectError(error.BadWebSocketAccept, verifyAccept(ck, "AAAAAAAAAAAAAAAAAAAAAAAAAAA="));
}

test "parse wss url defaults" {
    const p = parseWssUrl("wss://web.whatsapp.com/ws/chat");
    try std.testing.expectEqualStrings("web.whatsapp.com", p.host);
    try std.testing.expectEqualStrings("/ws/chat", p.path);
    try std.testing.expectEqual(@as(u16, 443), p.port);
    try std.testing.expect(p.tls);
}

test "ws frame mask roundtrip" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const payload = "hello-wa";
    const f = try wsc.wsEncodeFrame(alloc, payload, .binary, true, io);
    defer alloc.free(f);
    const h = try wsc.wsDecodeHeader(f);
    try std.testing.expectEqual(wsc.WsOpcode.binary, h.opcode);
    try std.testing.expect(h.masked);
    try std.testing.expectEqual(payload.len, h.payload_len);
    const body = try alloc.dupe(u8, f[h.header_len..][0..h.payload_len]);
    defer alloc.free(body);
    unmask(body, h.mask_key.?);
    try std.testing.expectEqualStrings(payload, body);
}

test "ws frame mask roundtrip 300 bytes" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const payload = [_]u8{0x61} ** 300;
    const f = try wsc.wsEncodeFrame(alloc, &payload, .binary, true, io);
    defer alloc.free(f);
    const h = try wsc.wsDecodeHeader(f);
    try std.testing.expectEqual(@as(usize, 300), h.payload_len);
    try std.testing.expect(h.masked);
    const body = try alloc.dupe(u8, f[h.header_len..][0..h.payload_len]);
    defer alloc.free(body);
    unmask(body, h.mask_key.?);
    try std.testing.expectEqualStrings(&payload, body);
}

test "WsClient connect symbols" {
    _ = &WsClient.connect;
    _ = &WsClient.connectTo;
    _ = &WsClient.writeFrame;
    _ = &WsClient.readFrame;
    _ = &WsClient.readFrameAlloc;
    _ = &performUpgrade;
}

// Live: TLS + RFC6455 upgrade against web.whatsapp.com (ZEPTO_LIVE_DIAL=1, -lc).
test "live wss upgrade (ZEPTO_LIVE_DIAL=1)" {
    if (std.c.getenv("ZEPTO_LIVE_DIAL") == null) return error.SkipZigTest;
    var ws = WsClient.init(std.testing.allocator);
    defer ws.deinit();
    try ws.connectTo(default_host, default_port, default_path, default_origin);
    try std.testing.expect(ws.tls != null);
}
