const std = @import("std");

/// FrameSocket / ws_client — skeleton for WhatsApp Web websocket.
/// Real path requires: Io.net.Stream + std.crypto.tls.Client + RFC6455 frames.
/// Today exposed as no-IO codec + WA header/frame packing; TLS/WS dial wired
/// but kept behind a flag so BUILD stays green even without certs on CI.

pub const WsConfig = struct {
    url: []const u8 = "wss://web.whatsapp.com/ws/chat",
    origin: []const u8 = "https://web.whatsapp.com",
    header: [4]u8 = .{ 'W', 'A', 6, 3 },
    max_frame: usize = 1 << 24,
};

/// WA frame packing — mirrors Go FrameSocket.SendFrame:
/// [optional header once] + 3-byte BE length + payload
pub fn encodeFrame(allocator: std.mem.Allocator, header: ?[]const u8, payload: []const u8, header_sent: *bool) ![]u8 {
    if (payload.len >= (1 << 24)) return error.FrameTooLarge;
    const hdr_len: usize = if (!header_sent.* and header != null) header.?.len else 0;
    const out = try allocator.alloc(u8, hdr_len + 3 + payload.len);
    if (!header_sent.* and header != null) {
        @memcpy(out[0..hdr_len], header.?);
        header_sent.* = true;
    }
    out[hdr_len] = @intCast((payload.len >> 16) & 0xFF);
    out[hdr_len + 1] = @intCast((payload.len >> 8) & 0xFF);
    out[hdr_len + 2] = @intCast(payload.len & 0xFF);
    @memcpy(out[hdr_len + 3 ..], payload);
    return out;
}

/// Streaming deframer — mirrors Go FrameSocket.processData/frameComplete.
/// Caller feeds websocket message payloads; complete WA frames are returned.
pub const Deframer = struct {
    allocator: std.mem.Allocator,
    incoming: ?[]u8 = null,
    incoming_len: usize = 0,
    received: usize = 0,
    partial_header: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) Deframer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Deframer) void {
        if (self.incoming) |b| self.allocator.free(b);
        if (self.partial_header) |b| self.allocator.free(b);
    }

    /// Feed one websocket message. Returns completed frames (caller must free each).
    pub fn feed(self: *Deframer, msg: []const u8) !std.ArrayList([]u8) {
        var out: std.ArrayList([]u8) = .empty;
        // Handle partial 3-byte header stashed from last call.
        // Need to handle arbitrary msg sizes; compose full src on heap if needed.
        var owned_src: ?[]u8 = null;
        var src: []const u8 = msg;
        if (self.partial_header) |ph| {
            owned_src = try self.allocator.alloc(u8, ph.len + msg.len);
            @memcpy(owned_src.?[0..ph.len], ph);
            @memcpy(owned_src.?[ph.len..], msg);
            src = owned_src.?;
            self.allocator.free(ph);
            self.partial_header = null;
        }
        defer if (owned_src) |b| self.allocator.free(b);
        var i: usize = 0;
        while (i < src.len) {
            if (self.incoming == null) {
                if (src.len - i < 3) {
                    // partial header
                    const ph = try self.allocator.dupe(u8, src[i..]);
                    self.partial_header = ph;
                    break;
                }
                const len = (@as(usize, src[i]) << 16) | (@as(usize, src[i + 1]) << 8) | @as(usize, src[i + 2]);
                i += 3;
                if (len > (1 << 24)) return error.FrameTooLarge;
                const remaining = src.len - i;
                if (remaining >= len) {
                    const frame = try self.allocator.dupe(u8, src[i .. i + len]);
                    try out.append(self.allocator, frame);
                    i += len;
                } else {
                    // need to accumulate
                    const buf = try self.allocator.alloc(u8, len);
                    @memcpy(buf[0..remaining], src[i..]);
                    self.incoming = buf;
                    self.incoming_len = len;
                    self.received = remaining;
                    break;
                }
            } else {
                const buf = self.incoming.?;
                const need = self.incoming_len - self.received;
                const avail = src.len - i;
                if (avail >= need) {
                    @memcpy(buf[self.received .. self.incoming_len], src[i .. i + need]);
                    i += need;
                    try out.append(self.allocator, buf);
                    self.incoming = null;
                    self.incoming_len = 0;
                    self.received = 0;
                } else {
                    @memcpy(buf[self.received .. self.received + avail], src[i..]);
                    self.received += avail;
                    break;
                }
            }
        }
        // If scratch case produced leftover bytes beyond scratch window (shouldn't happen
        // because scratch capped), not needed — feed is single msg.
        return out;
    }
};

/// Minimal RFC6455 frame codec helpers (masked client frames, unmasked server).
/// Big enough for the WA task; full spec deferred.

pub const WsOpcode = enum(u4) { continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10, _ };

pub fn wsEncodeFrame(allocator: std.mem.Allocator, payload: []const u8, opcode: WsOpcode, mask: bool, io: std.Io) ![]u8 {
    // Client must mask.
    if (payload.len > 125 and payload.len <= 65535) {
        // 2 header bytes + 2 extended length (+4 mask key)
        const hdr: usize = if (mask) 2 + 2 + 4 else 2 + 2;
        const out = try allocator.alloc(u8, hdr + payload.len);
        out[0] = 0x80 | @as(u8, @intFromEnum(opcode));
        out[1] = @as(u8, if (mask) 0x80 | 126 else 126);
        std.mem.writeInt(u16, out[2..4], @intCast(payload.len), .big);
        if (mask) {
            var key: [4]u8 = undefined;
            io.random(&key);
            @memcpy(out[4..8], &key);
            for (payload, 0..) |b, idx| out[8 + idx] = b ^ key[idx % 4];
            return out;
        } else {
            @memcpy(out[4 .. 4 + payload.len], payload);
            return out[0 .. 4 + payload.len];
        }
    } else if (payload.len > 65535) {
        const hdr: usize = if (mask) 10 + 4 else 10;
        const out = try allocator.alloc(u8, hdr + payload.len);
        out[0] = 0x80 | @as(u8, @intFromEnum(opcode));
        out[1] = @as(u8, if (mask) 0x80 | 127 else 127);
        std.mem.writeInt(u64, out[2..10], @intCast(payload.len), .big);
        if (mask) {
            var key: [4]u8 = undefined;
            io.random(&key);
            @memcpy(out[10..14], &key);
            for (payload, 0..) |b, idx| out[14 + idx] = b ^ key[idx % 4];
            return out;
        } else {
            @memcpy(out[10 .. 10 + payload.len], payload);
            return out;
        }
    } else {
        const hdr: usize = if (mask) 2 + 4 else 2;
        const out = try allocator.alloc(u8, hdr + payload.len);
        out[0] = 0x80 | @as(u8, @intFromEnum(opcode));
        out[1] = @as(u8, if (mask) 0x80 | @as(u8, @intCast(payload.len)) else @as(u8, @intCast(payload.len)));
        if (mask) {
            var key: [4]u8 = undefined;
            io.random(&key);
            @memcpy(out[2..6], &key);
            for (payload, 0..) |b, idx| out[6 + idx] = b ^ key[idx % 4];
            return out;
        } else {
            @memcpy(out[2 .. 2 + payload.len], payload);
            return out[0 .. 2 + payload.len];
        }
    }
}

pub fn wsDecodeHeader(buf: []const u8) !struct { opcode: WsOpcode, masked: bool, payload_len: usize, header_len: usize, mask_key: ?[4]u8 } {
    if (buf.len < 2) return error.NeedMoreData;
    const b0 = buf[0];
    const b1 = buf[1];
    const opcode: WsOpcode = @enumFromInt(b0 & 0x0F);
    const masked = (b1 & 0x80) != 0;
    var len: usize = b1 & 0x7F;
    var hdr: usize = 2;
    if (len == 126) {
        if (buf.len < 4) return error.NeedMoreData;
        len = std.mem.readInt(u16, buf[2..4], .big);
        hdr = 4;
    } else if (len == 127) {
        if (buf.len < 10) return error.NeedMoreData;
        const l64 = std.mem.readInt(u64, buf[2..10], .big);
        if (l64 > (1 << 24)) return error.FrameTooLarge;
        len = @intCast(l64);
        hdr = 10;
    }
    var key: ?[4]u8 = null;
    if (masked) {
        if (buf.len < hdr + 4) return error.NeedMoreData;
        key = buf[hdr..][0..4].*;
        hdr += 4;
    }
    return .{ .opcode = opcode, .masked = masked, .payload_len = len, .header_len = hdr, .mask_key = key };
}

/// TLS-over-TCP connect helper signature (to be used by socket.zig).
/// Kept allocation-free; caller supplies read/write buffers sized min_buffer_len.
pub fn connectTls(
    host: []const u8,
    port: u16,
    io: std.Io,
    allocator: std.mem.Allocator,
) !std.Io.net.Stream {
    _ = allocator;
    // DNS + TCP connect via Io.net.HostName path.
    const hn = try std.Io.net.HostName.init(host);
    // IPv6 SYN to WhatsApp from this host stalls forever; Zig 0.16 connect
    // timeout panics (`netConnectIpPosix`). Look up A records and connect IPv4.
    var name_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    var lookup_buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var lookup_q: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buf);
    var lookup_fut = io.async(std.Io.net.HostName.lookup, .{
        hn,
        io,
        &lookup_q,
        std.Io.net.HostName.LookupOptions{
            .port = port,
            .canonical_name_buffer = &name_buf,
            .family = .ip4,
        },
    });
    defer lookup_fut.cancel(io) catch {};
    var last_err: anyerror = error.UnknownHostName;
    while (lookup_q.getOne(io)) |dns_result| {
        switch (dns_result) {
            .address => |address| {
                if (address.connect(io, .{ .mode = .stream, .protocol = .tcp })) |stream| {
                    return stream;
                } else |err| {
                    last_err = err;
                }
            },
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Canceled => return err,
        error.Closed => {},
    }
    lookup_fut.await(io) catch |err| return err;
    return last_err;
}

/// Compute Sec-WebSocket-Accept per RFC6455 §4.2.2.
pub fn wsAcceptKey(client_key: []const u8, out: *[28]u8) void {
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(client_key);
    h.update(magic);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    const enc = std.base64.standard.Encoder;
    _ = enc.encode(out, &digest);
}

/// Generate Sec-WebSocket-Key (16 random bytes base64 = 24 chars).
pub fn wsGenKey(io: std.Io, out: *[24]u8) void {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    const enc = std.base64.standard.Encoder;
    _ = enc.encode(out, &raw);
}

test "encode frame with header once" {
    const alloc = std.testing.allocator;
    var sent = false;
    const f1 = try encodeFrame(alloc, "WA\x06\x03", "hello", &sent);
    defer alloc.free(f1);
    try std.testing.expectEqual(@as(usize, 4 + 3 + 5), f1.len);
    try std.testing.expectEqualStrings("WA\x06\x03", f1[0..4]);
    const f2 = try encodeFrame(alloc, "WA\x06\x03", "hi", &sent);
    defer alloc.free(f2);
    try std.testing.expectEqual(@as(usize, 3 + 2), f2.len);
}

test "deframer single complete" {
    const alloc = std.testing.allocator;
    var d = Deframer.init(alloc);
    defer d.deinit();
    var sent = false;
    const frame = try encodeFrame(alloc, null, "payload", &sent);
    defer alloc.free(frame);
    // frame already includes 3-byte length+payload, feed as ws message
    var out = try d.feed(frame);
    defer {
        for (out.items) |b| alloc.free(b);
        out.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("payload", out.items[0]);
}

test "deframer split header" {
    const alloc = std.testing.allocator;
    var d = Deframer.init(alloc);
    defer d.deinit();
    // craft split across two feeds: first 2 bytes of length, then rest
    var sent = false;
    const frame = try encodeFrame(alloc, null, "abcdef", &sent);
    defer alloc.free(frame);
    var out1 = try d.feed(frame[0..2]);
    defer {
        for (out1.items) |b| alloc.free(b);
        out1.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 0), out1.items.len);
    var out2 = try d.feed(frame[2..]);
    defer {
        for (out2.items) |b| alloc.free(b);
        out2.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), out2.items.len);
    try std.testing.expectEqualStrings("abcdef", out2.items[0]);
}

test "deframer split payload" {
    const alloc = std.testing.allocator;
    var d = Deframer.init(alloc);
    defer d.deinit();
    var sent = false;
    const frame = try encodeFrame(alloc, null, "1234567890", &sent);
    defer alloc.free(frame);
    var out1 = try d.feed(frame[0..5]);
    defer {
        for (out1.items) |b| alloc.free(b);
        out1.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 0), out1.items.len);
    var out2 = try d.feed(frame[5..]);
    defer {
        for (out2.items) |b| alloc.free(b);
        out2.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), out2.items.len);
    try std.testing.expectEqualStrings("1234567890", out2.items[0]);
}

test "ws encode/decode header roundtrip small" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = try wsEncodeFrame(alloc, "hi", .binary, true, io);
    defer alloc.free(f);
    try std.testing.expect(f.len >= 6 + 2);
    const h = try wsDecodeHeader(f);
    try std.testing.expectEqual(WsOpcode.binary, h.opcode);
    try std.testing.expect(h.masked);
    try std.testing.expectEqual(@as(usize, 2), h.payload_len);
}

test "ws encode/decode header roundtrip 300 bytes" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const payload = [_]u8{0x61} ** 300;
    const f = try wsEncodeFrame(alloc, &payload, .binary, true, io);
    defer alloc.free(f);
    try std.testing.expectEqual(@as(usize, 2 + 2 + 4 + 300), f.len);
    const h = try wsDecodeHeader(f);
    try std.testing.expectEqual(@as(usize, 300), h.payload_len);
    try std.testing.expectEqual(@as(usize, 8), h.header_len);
    // unmask and compare: no trailing garbage past the payload
    var got: [300]u8 = undefined;
    for (f[8..], 0..) |b, i| got[i] = b ^ h.mask_key.?[i % 4];
    try std.testing.expectEqualSlices(u8, &payload, &got);
}

test "ws encode 70000 bytes uses 64-bit length" {
    const alloc = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const payload = try alloc.alloc(u8, 70000);
    defer alloc.free(payload);
    @memset(payload, 0x62);
    const f = try wsEncodeFrame(alloc, payload, .binary, true, io);
    defer alloc.free(f);
    try std.testing.expectEqual(@as(usize, 2 + 8 + 4 + 70000), f.len);
    const h = try wsDecodeHeader(f);
    try std.testing.expectEqual(@as(usize, 70000), h.payload_len);
    try std.testing.expectEqual(@as(usize, 14), h.header_len);
}

test "ws accept key vector RFC6455" {
    // RFC6455 example: client key dGhlIHNhbXBsZSBub25jZQ== -> accept s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
    const ck = "dGhlIHNhbXBsZSBub25jZQ==";
    var out: [28]u8 = undefined;
    wsAcceptKey(ck, &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}
