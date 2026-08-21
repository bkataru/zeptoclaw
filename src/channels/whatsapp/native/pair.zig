const std = @import("std");

// Port of whatsmeow/{qrchan,pair}.go
pub const PairEvent = union(enum) { qr: []const u8, connected: []const u8, timeout };
pub fn getQr(allocator: std.mem.Allocator) !PairEvent { _ = allocator; return error.NotImplemented; }
test "pair stub" { _ = getQr; }
