const std = @import("std");
const wsc = @import("ws_client.zig");
const ws_upgrade = @import("ws_upgrade.zig");
const nc = @import("noise_crypto.zig");

/// Port of whatsmeow/socket/{framesocket,noisesocket}.go transport side:
/// WSS client + WA 3-byte length frames. Post-handshake AES-256-GCM lives here
/// (handshake Mix/Encrypt is in handshake.zig; AD is empty after Finish).
const wa_header: []const u8 = "WA\x06\x03";

/// AES-256-GCM frame cipher after Noise XX Finish(). Independent send/recv counters.
pub const FrameCipher = struct {
    write_key: [32]u8,
    read_key: [32]u8,
    write_ctr: u32 = 0,
    read_ctr: u32 = 0,

    /// Memory: caller frees the ciphertext (plaintext + 16-byte tag).
    pub fn encrypt(self: *FrameCipher, allocator: std.mem.Allocator, plaintext: []const u8) ![]u8 {
        const iv = nc.generateIV(self.write_ctr);
        self.write_ctr +%= 1;
        return nc.sealAlloc(allocator, self.write_key, iv, plaintext, &[_]u8{});
    }

    /// Memory: caller frees the plaintext. `ciphertext` is not consumed.
    pub fn decrypt(self: *FrameCipher, allocator: std.mem.Allocator, ciphertext: []const u8) ![]u8 {
        if (ciphertext.len < 16) return error.AuthenticationFailed;
        const iv = nc.generateIV(self.read_ctr);
        self.read_ctr +%= 1;
        const out = try allocator.alloc(u8, ciphertext.len - 16);
        errdefer allocator.free(out);
        try nc.aesGcmOpen(self.read_key, iv, ciphertext, &[_]u8{}, out);
        return out;
    }
};

pub const NoiseSocket = struct {
    allocator: std.mem.Allocator,
    ws: ws_upgrade.WsClient,
    header_sent: bool = false,
    deframer: wsc.Deframer,
    pending: std.ArrayList([]u8) = .empty,
    cipher: ?FrameCipher = null,

    pub fn init(allocator: std.mem.Allocator) NoiseSocket {
        return .{
            .allocator = allocator,
            .ws = ws_upgrade.WsClient.init(allocator),
            .deframer = wsc.Deframer.init(allocator),
        };
    }

    pub fn deinit(self: *NoiseSocket) void {
        self.clearPending();
        self.pending.deinit(self.allocator);
        self.deframer.deinit();
        self.ws.deinit();
        self.cipher = null;
    }

    fn clearPending(self: *NoiseSocket) void {
        for (self.pending.items) |frame| self.allocator.free(frame);
        self.pending.clearRetainingCapacity();
    }

    pub fn installCipher(self: *NoiseSocket, write_key: [32]u8, read_key: [32]u8) void {
        self.cipher = .{ .write_key = write_key, .read_key = read_key };
    }

    pub fn connect(self: *NoiseSocket, url: []const u8) !void {
        const parts = ws_upgrade.parseWssUrl(if (url.len == 0)
            "wss://web.whatsapp.com/ws/chat"
        else
            url);
        self.deframer.deinit();
        self.deframer = wsc.Deframer.init(self.allocator);
        self.header_sent = false;
        self.cipher = null;
        self.clearPending();
        try self.ws.connectTo(parts.host, parts.port, parts.path, ws_upgrade.default_origin);
    }

    pub fn sendFrame(self: *NoiseSocket, data: []const u8) !void {
        var payload = data;
        var owned = false;
        if (self.cipher) |*c| {
            payload = try c.encrypt(self.allocator, data);
            owned = true;
        }
        defer if (owned) self.allocator.free(payload);
        const packed_frame = try wsc.encodeFrame(self.allocator, wa_header, payload, &self.header_sent);
        defer self.allocator.free(packed_frame);
        try self.ws.writeFrame(packed_frame, @intFromEnum(wsc.WsOpcode.binary));
    }

    fn recvRawFrame(self: *NoiseSocket) ![]u8 {
        while (true) {
            if (self.pending.items.len > 0) {
                return self.pending.orderedRemove(0);
            }
            const ws_payload = try self.ws.readFrameAlloc();
            defer self.allocator.free(ws_payload);
            var frames = try self.deframer.feed(ws_payload);
            defer frames.deinit(self.allocator);
            for (frames.items) |frame| {
                try self.pending.append(self.allocator, frame);
            }
        }
    }

    /// Memory: caller owns the returned WA payload (`allocator.free`).
    pub fn recvFrameAlloc(self: *NoiseSocket) ![]u8 {
        const raw = try self.recvRawFrame();
        if (self.cipher) |*c| {
            defer self.allocator.free(raw);
            return c.decrypt(self.allocator, raw);
        }
        return raw;
    }

    pub fn recvFrame(self: *NoiseSocket, buf: []u8) !usize {
        const frame = try self.recvFrameAlloc();
        defer self.allocator.free(frame);
        if (frame.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[0..frame.len], frame);
        return frame.len;
    }
};

test "socket uses WsClient" {
    var sock = NoiseSocket.init(std.testing.allocator);
    defer sock.deinit();
    _ = sock.ws;
    _ = &NoiseSocket.connect;
    _ = &NoiseSocket.sendFrame;
    _ = &NoiseSocket.recvFrame;
    _ = &NoiseSocket.recvFrameAlloc;
    _ = &NoiseSocket.installCipher;
}

test "frame cipher encrypt/decrypt roundtrip" {
    const alloc = std.testing.allocator;
    const write = [_]u8{0x11} ** 32;
    const read = [_]u8{0x22} ** 32;
    var tx = FrameCipher{ .write_key = write, .read_key = read };
    var rx = FrameCipher{ .write_key = read, .read_key = write };
    const ct = try tx.encrypt(alloc, "hello-noise");
    defer alloc.free(ct);
    const pt = try rx.decrypt(alloc, ct);
    defer alloc.free(pt);
    try std.testing.expectEqualStrings("hello-noise", pt);
    const ct2 = try tx.encrypt(alloc, "frame-2");
    defer alloc.free(ct2);
    const pt2 = try rx.decrypt(alloc, ct2);
    defer alloc.free(pt2);
    try std.testing.expectEqualStrings("frame-2", pt2);
}

test "WA header prepended once via encodeFrame" {
    const alloc = std.testing.allocator;
    var sent = false;
    const f1 = try wsc.encodeFrame(alloc, wa_header, "hello", &sent);
    defer alloc.free(f1);
    try std.testing.expectEqual(@as(usize, 4 + 3 + 5), f1.len);
    try std.testing.expectEqualStrings("WA\x06\x03", f1[0..4]);
    const f2 = try wsc.encodeFrame(alloc, wa_header, "hi", &sent);
    defer alloc.free(f2);
    try std.testing.expectEqual(@as(usize, 3 + 2), f2.len);
}
