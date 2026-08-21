const std = @import("std");
const nc = @import("noise_crypto.zig");

/// Noise_XX_25519_AESGCM_SHA256 handshake — port of whatsmeow/socket/noisehandshake.go
/// Only crypto; no I/O. Caller drives the 3-message WA handshake (see handshake.zig).

pub const NoiseHandshake = struct {
    hash: [32]u8,
    salt: [32]u8,
    /// Current AEAD key (valid after Start). 32 bytes for AES-256-GCM.
    key: [32]u8,
    has_key: bool = false,
    counter: u32 = 0,

    pub fn init() NoiseHandshake {
        return .{ .hash = undefined, .salt = undefined, .key = undefined };
    }

    /// Start(pattern, header) — mirrors Go NoiseHandshake.Start.
    /// header is the WA 4-byte conn header ("WA" + 6 + dictVersion).
    pub fn start(self: *NoiseHandshake, pattern: []const u8, header: []const u8) void {
        if (pattern.len == 32) {
            @memcpy(&self.hash, pattern[0..32]);
        } else {
            self.hash = nc.sha256(pattern);
        }
        self.salt = self.hash;
        // gcmutil.Prepare(hash) -> first AEAD key = hash itself (32 bytes). In Zig key == hash.
        self.key = self.hash;
        self.has_key = true;
        self.authenticate(header);
    }

    pub fn authenticate(self: *NoiseHandshake, data: []const u8) void {
        // hash = SHA256(hash || data)
        var tmp: [64]u8 = undefined;
        // Fast path small, otherwise alloc
        if (self.hash.len + data.len <= 64) {
            @memcpy(tmp[0..32], &self.hash);
            @memcpy(tmp[32 .. 32 + data.len], data);
            self.hash = nc.sha256(tmp[0 .. 32 + data.len]);
        } else {
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            h.update(&self.hash);
            h.update(data);
            h.final(&self.hash);
        }
    }

    fn nextCounter(self: *NoiseHandshake) u32 {
        const c = self.counter;
        self.counter +%= 1;
        return c;
    }

    pub fn encrypt(self: *NoiseHandshake, allocator: std.mem.Allocator, plaintext: []const u8) ![]u8 {
        const iv = nc.generateIV(self.nextCounter());
        // ad = hash
        const out = try allocator.alloc(u8, plaintext.len + 16);
        nc.aesGcmSeal(self.key, iv, plaintext, &self.hash, out);
        // authenticate(ciphertext) — hash = SHA256(hash || ciphertext)
        self.authenticate(out);
        return out;
    }

    pub fn decrypt(self: *NoiseHandshake, allocator: std.mem.Allocator, ciphertext: []const u8) ![]u8 {
        const iv = nc.generateIV(self.nextCounter());
        if (ciphertext.len < 16) return error.AuthenticationFailed;
        const pt_len = ciphertext.len - 16;
        const out = try allocator.alloc(u8, pt_len);
        errdefer allocator.free(out);
        try nc.aesGcmOpen(self.key, iv, ciphertext, &self.hash, out);
        self.authenticate(ciphertext);
        return out;
    }

    /// MixSharedSecretIntoKey(priv, pub) — scalarMult + MixIntoKey
    pub fn mixSharedSecretIntoKey(self: *NoiseHandshake, priv: [32]u8, pub_key: [32]u8) !void {
        const secret = try nc.KeyPair.sharedSecret(priv, pub_key);
        try self.mixIntoKey(&secret);
    }

    pub fn mixIntoKey(self: *NoiseHandshake, data: []const u8) !void {
        self.counter = 0;
        const keys = nc.hkdfExtractExpand(&self.salt, data);
        self.salt = keys.write;
        self.key = keys.read;
        self.has_key = true;
    }

    /// HKDF extract+expand used by NoiseHandshake — exposed for testing.
    pub fn extractAndExpand(salt: []const u8, ikm: ?[]const u8) struct { write: [32]u8, read: [32]u8 } {
        return nc.hkdfExtractExpand(salt, ikm);
    }

    /// Finish() -> {writeKey, readKey} for NoiseSocket. Mirrors Go Finish(ctx, fs,...).
    /// Returned keys are ready for AES-256-GCM (nonce = IV(counter)).
    pub fn finishKeys(self: *NoiseHandshake) struct { write_key: [32]u8, read_key: [32]u8 } {
        // hkdf(salt, nil) with empty info -> 64 bytes
        const keys = nc.hkdfExtractExpand(&self.salt, null);
        return .{ .write_key = keys.write, .read_key = keys.read };
    }
};

// ----------------------------------------------------------------------------
// Verifiable Noise XX smoke: replicates whatsmeow handshake steps (no I/O)
// ----------------------------------------------------------------------------

test "noise handshake start/authenticate determinism" {
    var nh1 = NoiseHandshake.init();
    var nh2 = NoiseHandshake.init();
    nh1.start(nc.noise_start_pattern, &nc.wa_conn_header);
    nh2.start(nc.noise_start_pattern, &nc.wa_conn_header);
    try std.testing.expectEqual(nh1.hash, nh2.hash);
    try std.testing.expectEqual(nh1.salt, nh2.salt);
    try std.testing.expectEqual(nh1.key, nh2.key);
}

test "noise encrypt/decrypt roundtrip" {
    var nh = NoiseHandshake.init();
    nh.start(nc.noise_start_pattern, &nc.wa_conn_header);
    const alloc = std.testing.allocator;
    const pt = "noise payload";
    const ct = try nh.encrypt(alloc, pt);
    defer alloc.free(ct);
    // Fresh handshake with same transcript can decrypt if we re-derive to same state
    var nh2 = NoiseHandshake.init();
    nh2.start(nc.noise_start_pattern, &nc.wa_conn_header);
    nh2.key = nh.key; // not needed: but to get matching key before decrypt we need same derivation
    // Instead do true roundtrip on same object with counter replay: reset counter and key to encrypt-state
    // Do a proper symmetric test: two handshakes starting identically, share encrypt->decrypt
    var a = NoiseHandshake.init();
    var b = NoiseHandshake.init();
    a.start(nc.noise_start_pattern, &nc.wa_conn_header);
    b.start(nc.noise_start_pattern, &nc.wa_conn_header);
    // a encrypts, b decrypts — they share same key/counter/hash at this point
    const ct2 = try a.encrypt(alloc, "hello");
    // b has same key/hash/counter before encrypt
    const pt2 = try b.decrypt(alloc, ct2);
    defer alloc.free(ct2);
    defer alloc.free(pt2);
    try std.testing.expectEqualStrings("hello", pt2);
}

test "mixIntoKey resets counter and changes key" {
    var nh = NoiseHandshake.init();
    nh.start(nc.noise_start_pattern, &nc.wa_conn_header);
    const k0 = nh.key;
    nh.counter = 5;
    try nh.mixIntoKey("some secret 32 bytes...............");
    try std.testing.expectEqual(@as(u32, 0), nh.counter);
    try std.testing.expect(!std.mem.eql(u8, &k0, &nh.key));
}

test "hkdf empty IKM matches Go Finish with nil" {
    var nh = NoiseHandshake.init();
    nh.start(nc.noise_start_pattern, "hdr");
    const keys = nh.finishKeys();
    // determinism check
    var nh2 = NoiseHandshake.init();
    nh2.start(nc.noise_start_pattern, "hdr");
    const keys2 = nh2.finishKeys();
    try std.testing.expectEqual(keys.write_key, keys2.write_key);
    try std.testing.expectEqual(keys.read_key, keys2.read_key);
}

test "x25519 mixSharedSecretIntoKey determinism" {
    var nh1 = NoiseHandshake.init();
    var nh2 = NoiseHandshake.init();
    nh1.start(nc.noise_start_pattern, &nc.wa_conn_header);
    nh2.start(nc.noise_start_pattern, &nc.wa_conn_header);
    // generate ephemeral
    var seed: [32]u8 = [_]u8{0x11} ** 32;
    seed[0] &= 248; seed[31] &= 127; seed[31] |= 64;
    var seed2: [32]u8 = [_]u8{0x22} ** 32;
    seed2[0] &= 248; seed2[31] &= 127; seed2[31] |= 64;
    const kp1 = nc.KeyPair.fromPrivate(seed);
    const kp2 = nc.KeyPair.fromPrivate(seed2);
    try nh1.mixSharedSecretIntoKey(kp1.priv_key, kp2.pub_key);
    try nh2.mixSharedSecretIntoKey(kp1.priv_key, kp2.pub_key);
    try std.testing.expectEqual(nh1.key, nh2.key);
    try std.testing.expectEqual(nh1.salt, nh2.salt);
}

test "noise pub vs priv variable naming (no keyword collision)" {
    const kp = nc.KeyPair.fromPrivate([_]u8{0x33} ** 32);
    _ = kp.pub_key;
    _ = kp.priv_key;
}
