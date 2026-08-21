const std = @import("std");

// Port of whatsmeow appstate/lthash — LTHash pointwise mod 2^16 over 128 bytes
pub const LTHash = struct {
    hash: [128]u8 = [_]u8{0} ** 128,
    pub fn add(self: *LTHash, value_mac: []const u8) void {
        _ = self; _ = value_mac;
    }
    pub fn subtractThenAdd(self: *LTHash, removed: [][]const u8, added: [][]const u8) void {
        _ = self; _ = removed; _ = added;
    }
};

test "lthash stub" { var h = LTHash{}; h.add(&[_]u8{0} ** 32); }
