const std = @import("std");

/// WhatsApp Noise constants — port of whatsmeow/socket/constants.go + handshake.go
pub const noise_start_pattern: []const u8 = "Noise_XX_25519_AESGCM_SHA256\x00\x00\x00\x00";
pub const wa_magic_value: u8 = 6;
pub const dict_version: u8 = 3;
pub const wa_conn_header: [4]u8 = .{ 'W', 'A', wa_magic_value, dict_version };
pub const wa_origin = "https://web.whatsapp.com";
pub const wa_ws_url = "wss://web.whatsapp.com/ws/chat";
pub const frame_max_size: usize = 1 << 24;
pub const frame_length_size: usize = 3;
pub const noise_handshake_timeout_ms: u64 = 20_000;

/// WACertPubKey — Ed25519 root public key for CertChain intermediate verification.
/// Port of handshake.go: WACertPubKey [32]byte{0x14,0x23,...}
pub const wa_cert_pub_key: [32]u8 = .{
    0x14, 0x23, 0x75, 0x57, 0x4d, 0x0a, 0x58, 0x71, 0x66, 0xaa, 0xe7, 0x1e, 0xbe, 0x51, 0x64, 0x37,
    0xc4, 0xa2, 0x8b, 0x73, 0xe3, 0x69, 0x5c, 0x6c, 0xe1, 0xf7, 0xf9, 0x54, 0x5d, 0xa8, 0xee, 0x6b,
};
pub const wa_cert_issuer_serial: u32 = 0;

// ---------------------------------------------------------------------------
// Low-level crypto helpers — all on std.crypto (no external deps)
// ---------------------------------------------------------------------------

/// SHA256 one-shot.
pub fn sha256(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

pub fn sha256Slice(data: []const u8) [32]u8 {
    return sha256(data);
}

/// HMAC-SHA256 (timing-safe not needed here but available via std).
pub fn hmacSha256(key: []const u8, msg: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&out, msg, key);
    return out;
}

/// Generate 12-byte AEAD IV from u32 counter (big-endian at offset 8).
/// Matches Go generateIV.
pub fn generateIV(counter: u32) [12]u8 {
    var iv: [12]u8 = [_]u8{0} ** 12;
    std.mem.writeInt(u32, iv[8..12], counter, .big);
    return iv;
}

/// X25519 keypair with clamping (exactly as whatsmeow/util/keys KeyPair).
pub const KeyPair = struct {
    pub_key: [32]u8,
    priv_key: [32]u8,

    /// Generate fresh clamped keypair using Io RNG (Zig 0.16 Io.random).
    pub fn generate(io: std.Io) KeyPair {
        var seed: [32]u8 = undefined;
        io.random(&seed);
        // Apply X25519 clamping
        seed[0] &= 248;
        seed[31] &= 127;
        seed[31] |= 64;
        return fromPrivate(seed);
    }

    pub fn fromPrivate(priv: [32]u8) KeyPair {
        const p = std.crypto.dh.X25519.recoverPublicKey(priv) catch unreachable;
        return .{ .priv_key = priv, .pub_key = p };
    }

    /// Raw scalarMult: X25519(priv, pub_key) with clamping already applied.
    pub fn sharedSecret(priv: [32]u8, pub_key: [32]u8) ![32]u8 {
        return try std.crypto.dh.X25519.scalarmult(priv, pub_key);
    }
};

/// HKDF-SHA256 extract+expand producing 64 bytes split into write[32] + read[32].
/// Mirrors Go's extractAndExpand(salt, data) using hkdf.New(sha256, data, salt, nil).
pub fn hkdfExtractExpand(salt: []const u8, ikm: ?[]const u8) struct { write: [32]u8, read: [32]u8 } {
    const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
    const ikm_slice: []const u8 = ikm orelse &[_]u8{};
    const salt_slice: []const u8 = salt;
    // extract: PRK = HMAC(salt, IKM)
    const prk = Hkdf.extract(salt_slice, ikm_slice);
    var okm: [64]u8 = undefined;
    Hkdf.expand(&okm, "", prk);
    var write: [32]u8 = undefined;
    var read: [32]u8 = undefined;
    @memcpy(&write, okm[0..32]);
    @memcpy(&read, okm[32..64]);
    return .{ .write = write, .read = read };
}

/// AES-256-GCM seal: c = Enc(key, nonce, plaintext, ad); caller provides buf of len plaintext+16.
pub fn aesGcmSeal(key: [32]u8, nonce: [12]u8, plaintext: []const u8, ad: []const u8, out: []u8) void {
    std.debug.assert(out.len == plaintext.len + 16);
    var tag: [16]u8 = undefined;
    std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(out[0..plaintext.len], &tag, plaintext, ad, nonce, key);
    @memcpy(out[plaintext.len .. plaintext.len + 16], &tag);
}

/// AES-256-GCM open: m = Dec(key, nonce, ciphertext||tag, ad); ciphertextAndTag = ciphertext+16
pub fn aesGcmOpen(key: [32]u8, nonce: [12]u8, ciphertext_and_tag: []const u8, ad: []const u8, out: []u8) !void {
    std.debug.assert(ciphertext_and_tag.len >= 16);
    const ct_len = ciphertext_and_tag.len - 16;
    std.debug.assert(out.len == ct_len);
    const ct = ciphertext_and_tag[0..ct_len];
    const tag: [16]u8 = ciphertext_and_tag[ct_len..][0..16].*;
    try std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(out, ct, tag, ad, nonce, key);
}

/// Convenience seal that allocates.
pub fn sealAlloc(allocator: std.mem.Allocator, key: [32]u8, nonce: [12]u8, plaintext: []const u8, ad: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, plaintext.len + 16);
    aesGcmSeal(key, nonce, plaintext, ad, out);
    return out;
}

/// Ed25519 verify (WA cert chain). Returns error.SignatureVerificationFailed on fail.
pub fn verifyEd25519(pub_key: [32]u8, msg: []const u8, sig: [64]u8) !void {
    const pk = try std.crypto.sign.Ed25519.PublicKey.fromBytes(pub_key);
    const signature = std.crypto.sign.Ed25519.Signature.fromBytes(sig);
    try signature.verify(msg, pk);
}

// ---------------------------------------------------------------------------
// Self tests (run via zig build test)
// ---------------------------------------------------------------------------

test "sha256 empty" {
    const h = sha256("");
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.bytesToHex(h, .lower)}) catch unreachable;
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &hex);
}

test "generateIV big endian" {
    const iv0 = generateIV(0);
    try std.testing.expectEqual([12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, iv0);
    const iv1 = generateIV(1);
    try std.testing.expectEqual([12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, iv1);
    const iv_big = generateIV(0x01020304);
    try std.testing.expectEqual(@as(u32, 0x01020304), std.mem.readInt(u32, iv_big[8..12], .big));
}

test "hkdf extract expand vectors (RFC5869-adjacent sanity)" {
    // Use known HKDF: IKM 22×0x0b, salt 00..0c, info f0..f9 -> PRK 0777...
    const ikm = [_]u8{0x0b} ** 22;
    const salt = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c };
    const context = [_]u8{ 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9 };
    const prk = std.crypto.kdf.hkdf.HkdfSha256.extract(&salt, &ikm);
    try std.testing.expectEqualStrings("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5", &std.fmt.bytesToHex(prk, .lower));
    var out: [42]u8 = undefined;
    std.crypto.kdf.hkdf.HkdfSha256.expand(&out, &context, prk);
    try std.testing.expectEqualStrings("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", &std.fmt.bytesToHex(out, .lower));
}

test "aes-gcm seal/open roundtrip" {
    const key: [32]u8 = [_]u8{0x42} ** 32;
    const nonce = generateIV(7);
    const pt = "hello whatsapp noise";
    const ad = "associated_data";
    const sealed = try sealAlloc(std.testing.allocator, key, nonce, pt, ad);
    defer std.testing.allocator.free(sealed);
    var dec: [20]u8 = undefined;
    // pt len 20
    try aesGcmOpen(key, nonce, sealed, ad, &dec);
    try std.testing.expectEqualSlices(u8, pt, &dec);
}

test "aes-gcm tamper fails" {
    const key: [32]u8 = [_]u8{0x42} ** 32;
    const nonce = generateIV(0);
    const pt = "tamper test";
    const sealed = try sealAlloc(std.testing.allocator, key, nonce, pt, "");
    defer std.testing.allocator.free(sealed);
    var bad = try std.testing.allocator.dupe(u8, sealed);
    defer std.testing.allocator.free(bad);
    bad[0] ^= 0x01;
    var out: [11]u8 = undefined;
    try std.testing.expectError(error.AuthenticationFailed, aesGcmOpen(key, nonce, bad, "", &out));
}

test "wa constants" {
    try std.testing.expectEqual(@as(usize, 4), wa_conn_header.len);
    try std.testing.expectEqual(@as(u8, 'W'), wa_conn_header[0]);
    try std.testing.expectEqual(@as(u8, 'A'), wa_conn_header[1]);
}

test "x25519 rfc7748 vector" {
    const sk = [32]u8{ 0xa5, 0x46, 0xe3, 0x6b, 0xf0, 0x52, 0x7c, 0x9d, 0x3b, 0x16, 0x15, 0x4b, 0x82, 0x46, 0x5e, 0xdd, 0x62, 0x14, 0x4c, 0x0a, 0xc1, 0xfc, 0x5a, 0x18, 0x50, 0x6a, 0x22, 0x44, 0xba, 0x44, 0x9a, 0xc4 };
    const pk = [32]u8{ 0xe6, 0xdb, 0x68, 0x67, 0x58, 0x30, 0x30, 0xdb, 0x35, 0x94, 0xc1, 0xa4, 0x24, 0xb1, 0x5f, 0x7c, 0x72, 0x66, 0x24, 0xec, 0x26, 0xb3, 0x35, 0x3b, 0x10, 0xa9, 0x03, 0xa6, 0xd0, 0xab, 0x1c, 0x4c };
    const expected = [32]u8{ 0xc3, 0xda, 0x55, 0x37, 0x9d, 0xe9, 0xc6, 0x90, 0x8e, 0x94, 0xea, 0x4d, 0xf2, 0x8d, 0x08, 0x4f, 0x32, 0xec, 0xcf, 0x03, 0x49, 0x1c, 0x71, 0xf7, 0x54, 0xb4, 0x07, 0x55, 0x77, 0xa2, 0x85, 0x52 };
    const out = try KeyPair.sharedSecret(sk, pk);
    try std.testing.expectEqual(expected, out);
}
