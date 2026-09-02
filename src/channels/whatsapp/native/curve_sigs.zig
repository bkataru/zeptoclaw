const std = @import("std");

/// Curve25519 signatures used by WhatsApp pairing (libsignal `ecc.SignCurve25519`).
/// See https://moderncrypto.org/mail-archive/curves/2014/000205.html
/// Port of tulir/libsignal-protocol-go `ecc/SignCurve25519.go`.

const Edwards25519 = std.crypto.ecc.Edwards25519;
const Fe = Edwards25519.Fe;
const Ed25519 = std.crypto.sign.Ed25519;
const Sha512 = std.crypto.hash.sha2.Sha512;

const diversifier: [32]u8 = .{
    0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
};

fn clampedScalar(priv: [32]u8) [32]u8 {
    var s = priv;
    Edwards25519.scalar.clamp(&s);
    return s;
}

fn edPublicFromX25519Priv(priv: [32]u8) ![32]u8 {
    const s = clampedScalar(priv);
    const A = try Edwards25519.basePoint.mul(s);
    return A.toBytes();
}

/// Sign `message` with an X25519 private key. `random` is 64 bytes of nonce
/// (libsignal uses CSPRNG; tests may pass zeros).
pub fn sign(priv: [32]u8, message: []const u8, random: [64]u8) ![64]u8 {
    const scalar = clampedScalar(priv);
    const public_key = try edPublicFromX25519Priv(priv);

    var h = Sha512.init(.{});
    h.update(&diversifier);
    h.update(&priv);
    h.update(message);
    h.update(&random);
    var r64: [64]u8 = undefined;
    h.final(&r64);
    const r = Edwards25519.scalar.reduce64(r64);

    const R = try Edwards25519.basePoint.mul(r);
    const encoded_r = R.toBytes();

    h = Sha512.init(.{});
    h.update(&encoded_r);
    h.update(&public_key);
    h.update(message);
    var hram64: [64]u8 = undefined;
    h.final(&hram64);
    const hram = Edwards25519.scalar.reduce64(hram64);
    const s = Edwards25519.scalar.mulAdd(hram, scalar, r);

    var signature: [64]u8 = undefined;
    @memcpy(signature[0..32], &encoded_r);
    @memcpy(signature[32..64], &s);
    signature[63] |= public_key[31] & 0x80;
    return signature;
}

fn montgomeryToEdwardsY(mont_x: [32]u8) [32]u8 {
    var pk = mont_x;
    pk[31] &= 0x7F;
    const mont = Fe.fromBytes(pk);
    const one = Fe.one;
    const ed_y = mont.sub(one).mul(mont.add(one).invert());
    return ed_y.toBytes();
}

/// Verify `signature` over `message` with an X25519 (Montgomery) public key.
pub fn verify(mont_pub: [32]u8, message: []const u8, signature: [64]u8) !void {
    var sig = signature;
    var a_ed = montgomeryToEdwardsY(mont_pub);
    a_ed[31] |= sig[63] & 0x80;
    sig[63] &= 0x7F;
    const pk = try Ed25519.PublicKey.fromBytes(a_ed);
    const ed_sig = Ed25519.Signature.fromBytes(sig);
    try ed_sig.verify(message, pk);
}

test "curve25519 sign/verify roundtrip" {
    var priv: [32]u8 = [_]u8{0x42} ** 32;
    Edwards25519.scalar.clamp(&priv);
    const pub_key = std.crypto.dh.X25519.recoverPublicKey(priv) catch unreachable;
    const msg = "adv-device-signature";
    const sig = try sign(priv, msg, [_]u8{0} ** 64);
    try verify(pub_key, msg, sig);
    var bad = sig;
    bad[0] ^= 1;
    try std.testing.expectError(error.SignatureVerificationFailed, verify(pub_key, msg, bad));
}
