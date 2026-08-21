const std = @import("std");

// FrameSocket — wss://web.whatsapp.com/ws/chat framing over websocket
// Port of whatsmeow/socket/framesocket.go
pub const FrameSocket = struct {
    allocator: std.mem.Allocator,
    header: [4]u8 = [_]u8{ 'W', 'A', 6, 3 }, // WA 6, DictVersion 3
    const Self = @This();
    pub fn init(allocator: std.mem.Allocator) Self { return .{ .allocator = allocator }; }
    pub fn sendFrame(self: *Self, data: []const u8) !void { _ = self; _ = data; return error.NotImplemented; }
    pub fn recvFrame(self: *Self, buf: []u8) !usize { _ = self; _ = buf; return error.NotImplemented; }
};
test "framesocket stub" { _ = FrameSocket; }
