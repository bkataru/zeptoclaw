const std = @import("std");

// Noise_XX_25519_AESGCM_SHA256 handshake — port of whatsmeow/socket/noisehandshake.go + whatsmeow/handshake.go
// Uses std.crypto: dh.X25519, hash.sha2.Sha256, kdf.hkdf.HkdfSha256, aead.aes_gcm.Aes256Gcm, auth.hmac.sha2

pub const WACertPubKey = [32]u8{ 0x14, 0x23, 0x75, 0x57, 0x4d, 0x0a, 0x58, 0x71, 0x66, 0xaa, 0xe7, 0x1e, 0xbe, 0x51, 0x64, 0x37, 0xc4, 0xa2, 0x8b, 0x73, 0xe3, 0x69, 0x5c, 0x6c, 0xe1, 0xf7, 0xf9, 0x54, 0x5d, 0xa8, 0xee, 0x6b };
pub const NoiseStartPattern = "Noise_XX_25519_AESGCM_SHA256\x00\x00\x00\x00";
pub const WAPrefix: []const u8 = "WA";
pub const WAVersion: u8 = 6; // WAConnHeader version 6, DictVersion 3

pub const NoiseHandshake = struct {
    hash: [32]u8 = undefined,
    salt: [32]u8 = undefined,
    key: [32]u8 = undefined, // AES-256 key for AEAD
    counter: u32 = 0,

    pub fn init() NoiseHandshake { return .{}; }

    pub fn start(self: *NoiseHandshake, pattern: []const u8, header: []const u8) void {
        if (pattern.len == 32) @memcpy(&self.hash, pattern[0..32]) else {
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            h.update(pattern);
            h.final(&self.hash);
        }
        self.salt = self.hash;
        // key = hash as AES key (gcmutil.Prepare(hash) -> AaesGcm with hash)
        self.key = self.hash;
        self.authenticate(header);
    }

    pub fn authenticate(self: *NoiseHandshake, data: []const u8) void {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(&self.hash);
        h.update(data);
        h.final(&self.hash);
    }

    pub fn generateKeyPair(allocator: std.mem.Allocator) ![2][32]u8 {
        _ = allocator;
        var priv: [32]u8 = undefined;
        std.crypto.random.bytes(&priv);
        priv[0] &= 248; priv[31] &= 127; priv[31] |= 64;
        const pub_key = try std.crypto.dh.X25519.recoverPublicKey(priv);
        return .{ priv, pub_key };
    }

    // MixSharedSecret: X25519(priv, pub) -> HKDF(salt, shared) -> salt, key
    pub fn mixSharedSecretIntoKey(self: *NoiseHandshake, priv: [32]u8, peer_pub: [32]u8) !void {
        const shared = std.crypto.dh.X25519.scalarmult(priv, peer_pub) catch return error.InvalidKey;
        var prk: [32]u8 = undefined;
        const hkdf_extract = std.crypto.kdf.hkdf.HkdfSha256.extract(&prk, &self.salt, &shared);
        _ = hkdf_extract;
        var okm: [64]u8 = undefined;
        try std.crypto.kdf.hkdf.HkdfSha256.expand(&okm, "", &prk);
        @memcpy(&self.salt, okm[0..32]);
        @memcpy(&self.key, okm[32..64]);
        self.counter = 0;
    }

    fn iv(counter: u32) [12]u8 {
        var nonce: [12]u8 = [_]u8{0} ** 12;
        std.mem.writeInt(u32, nonce[8..12], counter, .big);
        return nonce;
    }

    pub fn encrypt(self: *NoiseHandshake, plaintext: []const u8, out: []u8) !usize {
        const nonce = iv(self.counter);
        self.counter += 1;
        var tag: [16]u8 = undefined;
        std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(out[0..plaintext.len], &tag, plaintext, &[_]u8{}, nonce, self.key);
        @memcpy(out[plaintext.len .. plaintext.len + 16], &tag);
        self.authenticate(out[0 .. plaintext.len + 16]);
        return plaintext.len + 16;
    }

    pub fn decrypt(self: *NoiseHandshake, ciphertext: []const u8, out: []u8) !usize {
        if (ciphertext.len < 16) return error.InvalidCiphertext;
        const nonce = iv(self.counter);
        self.counter += 1;
        const ct = ciphertext[0 .. ciphertext.len - 16];
        const tag = ciphertext[ciphertext.len - 16 ..][0..16];
        try std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(out[0..ct.len], ct, tag.*, &[_]u8{}, nonce, self.key);
        self.authenticate(ciphertext);
        return ct.len;
    }

    pub fn finish(self: *NoiseHandshake) struct { write_key: [32]u8, read_key: [32]u8 } {
        var prk: [32]u8 = undefined;
        _ = std.crypto.kdf.hkdf.HkdfSha256.extract(&prk, &self.salt, &[_]u8{});
        var okm: [64]u8 = undefined;
        std.crypto.kdf.hkdf.HkdfSha256.expand(&okm, "", &prk) catch {};
        var res: struct { write_key: [32]u8, read_key: [32]u8 } = undefined;
        @memcpy(&res.write_key, okm[0..32]);
        @memcpy(&res.read_key, okm[32..64]);
        return res;
    }
};

test "noise WACertPubKey length" { try std.testing.expectEqual(@as(usize, 32), WACertPubKey.len); }
test "noise start pattern" {
    var nh = NoiseHandshake.init();
    nh.start(NoiseStartPattern, &[_]u8{ 'W', 'A', 6, 3 });
    try std.testing.expect(nh.hash[0] != 0);
}
