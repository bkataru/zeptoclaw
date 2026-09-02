const std = @import("std");

/// Port of whatsmeow/appstate/lthash — pointwise uint16 add/sub (mod 2^16)
/// over a 128-byte HKDF-SHA256 expansion of each mutation.

pub const hash_size: usize = 128;
const hkdf_info: []const u8 = "WhatsApp Patch Integrity";

pub const LTHash = struct {
    hash: [hash_size]u8 = [_]u8{0} ** hash_size,

    pub fn add(self: *LTHash, value_mac: []const u8) void {
        var expanded: [hash_size]u8 = undefined;
        expand(value_mac, &expanded);
        pointwise(&self.hash, &expanded, false);
    }

    pub fn subtract(self: *LTHash, value_mac: []const u8) void {
        var expanded: [hash_size]u8 = undefined;
        expand(value_mac, &expanded);
        pointwise(&self.hash, &expanded, true);
    }

    pub fn subtractThenAdd(self: *LTHash, removed: []const []const u8, added: []const []const u8) void {
        for (removed) |r| self.subtract(r);
        for (added) |a| self.add(a);
    }
};

fn expand(item: []const u8, out: *[hash_size]u8) void {
    const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
    const prk = Hkdf.extract(&[_]u8{}, item);
    Hkdf.expand(out, hkdf_info, prk);
}

fn pointwise(base: *[hash_size]u8, input: *const [hash_size]u8, subtract: bool) void {
    var i: usize = 0;
    while (i < hash_size) : (i += 2) {
        const x = std.mem.readInt(u16, base[i..][0..2], .little);
        const y = std.mem.readInt(u16, input[i..][0..2], .little);
        const result: u16 = if (subtract) x -% y else x +% y;
        std.mem.writeInt(u16, base[i..][0..2], result, .little);
    }
}

test "lthash add then subtract restores zero" {
    var h = LTHash{};
    const a = [_]u8{0x11} ** 32;
    const b = [_]u8{0x22} ** 32;
    h.add(&a);
    h.add(&b);
    var h2 = LTHash{};
    h2.subtractThenAdd(&.{}, &.{ &a, &b });
    try std.testing.expectEqualSlices(u8, &h.hash, &h2.hash);
    h.subtract(&a);
    h.subtract(&b);
    try std.testing.expectEqual([_]u8{0} ** hash_size, h.hash);
}

test "lthash commutative add" {
    const a = [_]u8{1} ** 32;
    const b = [_]u8{2} ** 32;
    var h1 = LTHash{};
    h1.add(&a);
    h1.add(&b);
    var h2 = LTHash{};
    h2.add(&b);
    h2.add(&a);
    try std.testing.expectEqualSlices(u8, &h1.hash, &h2.hash);
}
