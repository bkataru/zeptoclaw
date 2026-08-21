const std = @import("std");

// Port of whatsmeow/socket/{framesocket,noisehandshake,noisesocket}.go
// + handshake.go NOISE_XX
// TODO: websocket + noise — stub BUILD:0

pub const NoiseSocket = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) NoiseSocket { return .{ .allocator = allocator }; }
    pub fn connect(self: *NoiseSocket, url: []const u8) !void { _ = self; _ = url; return error.NotImplemented; }
    pub fn sendFrame(self: *NoiseSocket, data: []const u8) !void { _ = self; _ = data; return error.NotImplemented; }
    pub fn recvFrame(self: *NoiseSocket, buf: []u8) !usize { _ = self; _ = buf; return error.NotImplemented; }
};
test "socket stub" { _ = NoiseSocket; }
