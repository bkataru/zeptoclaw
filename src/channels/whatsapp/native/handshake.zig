const std = @import("std");
const proto = @import("proto.zig");
const nh_mod = @import("noise_handshake.zig");
const nc = @import("noise_crypto.zig");

/// Noise_XX_25519_AESGCM_SHA256 handshake framing + crypto driver.
/// Port of whatsmeow/handshake.go doHandshake — protobuf + Mix/Decrypt/Encrypt only.
/// No socket I/O.

const NoiseHandshake = nh_mod.NoiseHandshake;

/// Memory: caller frees with allocator. HandshakeMessage.clientHello nested.
pub fn clientHelloBytes(allocator: std.mem.Allocator, ephemeral_pub: [32]u8) ![]u8 {
    const msg = proto.HandshakeMessage{ .client_hello = .{ .ephemeral = &ephemeral_pub } };
    return msg.encode(allocator);
}

/// Memory: caller frees `static_ct` and `payload_ct` with allocator.
pub fn parseServerHello(allocator: std.mem.Allocator, resp: []const u8) !struct {
    ephemeral: [32]u8,
    static_ct: []u8,
    payload_ct: []u8,
} {
    const msg = try proto.HandshakeMessage.decode(allocator, resp);
    const sh = msg.server_hello orelse return error.MissingServerHello;
    if (sh.ephemeral.len != 32) return error.InvalidEphemeral;
    var ephemeral: [32]u8 = undefined;
    @memcpy(&ephemeral, sh.ephemeral[0..32]);
    const static_ct = try allocator.dupe(u8, sh.static);
    errdefer allocator.free(static_ct);
    const payload_ct = try allocator.dupe(u8, sh.payload);
    return .{ .ephemeral = ephemeral, .static_ct = static_ct, .payload_ct = payload_ct };
}

/// Memory: caller frees with allocator. HandshakeMessage.clientFinish nested.
pub fn clientFinishBytes(allocator: std.mem.Allocator, static_ct: []const u8, payload_ct: []const u8) ![]u8 {
    const msg = proto.HandshakeMessage{ .client_finish = .{ .static = static_ct, .payload = payload_ct } };
    return msg.encode(allocator);
}

pub const HandshakeCryptoResult = struct {
    /// Memory: caller frees — decrypted server static (32 bytes).
    server_static: []u8,
    /// Memory: caller frees — decrypted cert/payload plaintext.
    cert_plaintext: []u8,
    /// Memory: caller frees — Encrypt(noise pub).
    static_ct: []u8,
    /// Memory: caller frees — Encrypt(ClientPayload).
    payload_ct: []u8,
    write_key: [32]u8,
    read_key: [32]u8,

    pub fn deinit(self: HandshakeCryptoResult, allocator: std.mem.Allocator) void {
        allocator.free(self.server_static);
        allocator.free(self.cert_plaintext);
        allocator.free(self.static_ct);
        allocator.free(self.payload_ct);
    }
};

/// Drive NoiseHandshake Mix/Decrypt/Encrypt for the client half of Noise XX.
/// `server_hello` is the parsed ServerHello parts (ciphertext). No socket.
/// Memory: caller deinit()s the result.
pub fn runHandshakeCrypto(
    allocator: std.mem.Allocator,
    ephemeral: nc.KeyPair,
    noise: nc.KeyPair,
    server_hello: struct {
        ephemeral: [32]u8,
        static_ct: []const u8,
        payload_ct: []const u8,
    },
    client_payload: []const u8,
) !HandshakeCryptoResult {
    var nh = NoiseHandshake.init();
    nh.start(nc.noise_start_pattern, &nc.wa_conn_header);
    nh.authenticate(&ephemeral.pub_key);

    nh.authenticate(&server_hello.ephemeral);
    try nh.mixSharedSecretIntoKey(ephemeral.priv_key, server_hello.ephemeral);

    const server_static = try nh.decrypt(allocator, server_hello.static_ct);
    errdefer allocator.free(server_static);
    if (server_static.len != 32) return error.InvalidServerStatic;
    var static_arr: [32]u8 = undefined;
    @memcpy(&static_arr, server_static[0..32]);
    try nh.mixSharedSecretIntoKey(ephemeral.priv_key, static_arr);

    const cert_plaintext = try nh.decrypt(allocator, server_hello.payload_ct);
    errdefer allocator.free(cert_plaintext);

    const static_ct = try nh.encrypt(allocator, &noise.pub_key);
    errdefer allocator.free(static_ct);
    try nh.mixSharedSecretIntoKey(noise.priv_key, server_hello.ephemeral);

    const payload_ct = try nh.encrypt(allocator, client_payload);
    errdefer allocator.free(payload_ct);

    const keys = nh.finishKeys();
    return .{
        .server_static = server_static,
        .cert_plaintext = cert_plaintext,
        .static_ct = static_ct,
        .payload_ct = payload_ct,
        .write_key = keys.write_key,
        .read_key = keys.read_key,
    };
}

pub const HandshakeKeys = struct {
    write_key: [32]u8,
    read_key: [32]u8,
};

/// Drive the 3-message Noise XX handshake over a frame transport.
/// `sock` must provide `sendFrame([]const u8) !void` and `recvFrameAlloc() ![]u8`
/// (NoiseSocket or a test mock). Cert-chain verify is left to the caller.
/// Memory: does not take ownership of `client_payload`.
pub fn doHandshake(
    allocator: std.mem.Allocator,
    sock: anytype,
    ephemeral: nc.KeyPair,
    noise: nc.KeyPair,
    client_payload: []const u8,
) !HandshakeKeys {
    const hello = try clientHelloBytes(allocator, ephemeral.pub_key);
    defer allocator.free(hello);
    try sock.sendFrame(hello);

    const resp = try sock.recvFrameAlloc();
    defer allocator.free(resp);
    const parsed = try parseServerHello(allocator, resp);
    defer allocator.free(parsed.static_ct);
    defer allocator.free(parsed.payload_ct);

    const result = try runHandshakeCrypto(allocator, ephemeral, noise, .{
        .ephemeral = parsed.ephemeral,
        .static_ct = parsed.static_ct,
        .payload_ct = parsed.payload_ct,
    }, client_payload);
    defer result.deinit(allocator);

    const finish = try clientFinishBytes(allocator, result.static_ct, result.payload_ct);
    defer allocator.free(finish);
    try sock.sendFrame(finish);

    return .{ .write_key = result.write_key, .read_key = result.read_key };
}

pub const MockSock = struct {
    allocator: std.mem.Allocator,
    incoming: std.ArrayList([]u8) = .empty,
    outgoing: std.ArrayList([]u8) = .empty,

    fn deinit(self: *MockSock) void {
        for (self.incoming.items) |s| self.allocator.free(s);
        for (self.outgoing.items) |s| self.allocator.free(s);
        self.incoming.deinit(self.allocator);
        self.outgoing.deinit(self.allocator);
    }

    fn sendFrame(self: *MockSock, data: []const u8) !void {
        try self.outgoing.append(self.allocator, try self.allocator.dupe(u8, data));
    }

    fn recvFrameAlloc(self: *MockSock) ![]u8 {
        if (self.incoming.items.len == 0) return error.NeedMoreData;
        return self.incoming.orderedRemove(0);
    }
};

fn clampedPair(fill: u8) nc.KeyPair {
    var seed: [32]u8 = [_]u8{fill} ** 32;
    seed[0] &= 248;
    seed[31] &= 127;
    seed[31] |= 64;
    return nc.KeyPair.fromPrivate(seed);
}

test "client hello nested protobuf" {
    const eph = [_]u8{0x7E} ** 32;
    const enc = try clientHelloBytes(std.testing.allocator, eph);
    defer std.testing.allocator.free(enc);
    try std.testing.expectEqual(@as(u8, 0x12), enc[0]);
    try std.testing.expectEqual(@as(u8, 0x22), enc[1]);
    try std.testing.expectEqual(@as(u8, 0x0A), enc[2]);
    try std.testing.expectEqual(@as(u8, 0x20), enc[3]);
    const dec = try proto.HandshakeMessage.decode(std.testing.allocator, enc);
    try std.testing.expectEqualSlices(u8, &eph, dec.client_hello.?.ephemeral);
}

test "parseServerHello nested roundtrip" {
    const eph = [_]u8{0xA1} ** 32;
    const static_ct = [_]u8{0xB2} ** 48;
    const payload_ct = [_]u8{0xC3} ** 24;
    const framed = try (proto.HandshakeMessage{ .server_hello = .{
        .ephemeral = &eph,
        .static = &static_ct,
        .payload = &payload_ct,
    } }).encode(std.testing.allocator);
    defer std.testing.allocator.free(framed);
    const parsed = try parseServerHello(std.testing.allocator, framed);
    defer std.testing.allocator.free(parsed.static_ct);
    defer std.testing.allocator.free(parsed.payload_ct);
    try std.testing.expectEqual(eph, parsed.ephemeral);
    try std.testing.expectEqualSlices(u8, &static_ct, parsed.static_ct);
    try std.testing.expectEqualSlices(u8, &payload_ct, parsed.payload_ct);
}

test "client finish nested protobuf" {
    const st = [_]u8{0x09} ** 48;
    const pl = [_]u8{0x08} ** 12;
    const enc = try clientFinishBytes(std.testing.allocator, &st, &pl);
    defer std.testing.allocator.free(enc);
    try std.testing.expectEqual(@as(u8, 0x22), enc[0]);
    const dec = try proto.HandshakeMessage.decode(std.testing.allocator, enc);
    try std.testing.expectEqualSlices(u8, &st, dec.client_finish.?.static);
    try std.testing.expectEqualSlices(u8, &pl, dec.client_finish.?.payload);
}

test "runHandshakeCrypto two-party smoke" {
    const alloc = std.testing.allocator;
    const client_eph = clampedPair(0x11);
    const server_eph = clampedPair(0x22);
    const server_static = clampedPair(0x33);
    const client_noise = clampedPair(0x44);
    const dummy_cert = "noise-cert-plaintext";
    const payload = proto.ClientPayload{};
    const client_payload = try payload.encode(alloc);
    defer alloc.free(client_payload);

    // Server half of Noise XX (no I/O): e, ee, s, es + encrypt cert.
    var srv = NoiseHandshake.init();
    srv.start(nc.noise_start_pattern, &nc.wa_conn_header);
    srv.authenticate(&client_eph.pub_key);
    srv.authenticate(&server_eph.pub_key);
    try srv.mixSharedSecretIntoKey(server_eph.priv_key, client_eph.pub_key);
    const srv_static_ct = try srv.encrypt(alloc, &server_static.pub_key);
    defer alloc.free(srv_static_ct);
    try srv.mixSharedSecretIntoKey(server_static.priv_key, client_eph.pub_key);
    const srv_payload_ct = try srv.encrypt(alloc, dummy_cert);
    defer alloc.free(srv_payload_ct);

    const hello_frame = try (proto.HandshakeMessage{ .server_hello = .{
        .ephemeral = &server_eph.pub_key,
        .static = srv_static_ct,
        .payload = srv_payload_ct,
    } }).encode(alloc);
    defer alloc.free(hello_frame);
    const parsed = try parseServerHello(alloc, hello_frame);
    defer alloc.free(parsed.static_ct);
    defer alloc.free(parsed.payload_ct);

    const result = try runHandshakeCrypto(alloc, client_eph, client_noise, .{
        .ephemeral = parsed.ephemeral,
        .static_ct = parsed.static_ct,
        .payload_ct = parsed.payload_ct,
    }, client_payload);
    defer result.deinit(alloc);

    try std.testing.expectEqualSlices(u8, &server_static.pub_key, result.server_static);
    try std.testing.expectEqualSlices(u8, dummy_cert, result.cert_plaintext);

    // Server consumes ClientFinish: decrypt s, se, decrypt payload, Finish.
    const got_noise = try srv.decrypt(alloc, result.static_ct);
    defer alloc.free(got_noise);
    try std.testing.expectEqualSlices(u8, &client_noise.pub_key, got_noise);
    var noise_pub: [32]u8 = undefined;
    @memcpy(&noise_pub, got_noise[0..32]);
    try srv.mixSharedSecretIntoKey(server_eph.priv_key, noise_pub);
    const got_payload = try srv.decrypt(alloc, result.payload_ct);
    defer alloc.free(got_payload);
    try std.testing.expectEqualSlices(u8, client_payload, got_payload);

    const srv_keys = srv.finishKeys();
    try std.testing.expectEqual(result.write_key, srv_keys.write_key);
    try std.testing.expectEqual(result.read_key, srv_keys.read_key);
}

test "doHandshake over mock transport" {
    const alloc = std.testing.allocator;
    const client_eph = clampedPair(0x11);
    const server_eph = clampedPair(0x22);
    const server_static = clampedPair(0x33);
    const client_noise = clampedPair(0x44);
    const dummy_cert = "noise-cert-plaintext";
    const client_payload = try (proto.ClientPayload{}).encode(alloc);
    defer alloc.free(client_payload);

    var srv = NoiseHandshake.init();
    srv.start(nc.noise_start_pattern, &nc.wa_conn_header);
    srv.authenticate(&client_eph.pub_key);
    srv.authenticate(&server_eph.pub_key);
    try srv.mixSharedSecretIntoKey(server_eph.priv_key, client_eph.pub_key);
    const srv_static_ct = try srv.encrypt(alloc, &server_static.pub_key);
    defer alloc.free(srv_static_ct);
    try srv.mixSharedSecretIntoKey(server_static.priv_key, client_eph.pub_key);
    const srv_payload_ct = try srv.encrypt(alloc, dummy_cert);
    defer alloc.free(srv_payload_ct);
    const hello_frame = try (proto.HandshakeMessage{ .server_hello = .{
        .ephemeral = &server_eph.pub_key,
        .static = srv_static_ct,
        .payload = srv_payload_ct,
    } }).encode(alloc);

    var mock = MockSock{ .allocator = alloc };
    defer mock.deinit();
    try mock.incoming.append(alloc, hello_frame);

    const keys = try doHandshake(alloc, &mock, client_eph, client_noise, client_payload);
    try std.testing.expectEqual(@as(usize, 2), mock.outgoing.items.len);

    const finish_msg = try proto.HandshakeMessage.decode(alloc, mock.outgoing.items[1]);
    const cf = finish_msg.client_finish orelse return error.TestUnexpectedResult;
    const got_noise = try srv.decrypt(alloc, cf.static);
    defer alloc.free(got_noise);
    try std.testing.expectEqualSlices(u8, &client_noise.pub_key, got_noise);
    var noise_pub: [32]u8 = undefined;
    @memcpy(&noise_pub, got_noise[0..32]);
    try srv.mixSharedSecretIntoKey(server_eph.priv_key, noise_pub);
    const got_payload = try srv.decrypt(alloc, cf.payload);
    defer alloc.free(got_payload);
    try std.testing.expectEqualSlices(u8, client_payload, got_payload);

    const srv_keys = srv.finishKeys();
    try std.testing.expectEqual(keys.write_key, srv_keys.write_key);
    try std.testing.expectEqual(keys.read_key, srv_keys.read_key);
}
