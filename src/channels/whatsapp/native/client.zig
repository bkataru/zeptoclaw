const std = @import("std");
const binary = @import("binary.zig");
const socket = @import("socket.zig");

// Port of whatsmeow/client.go 1066 lines — high level client
pub const Client = struct {
    allocator: std.mem.Allocator,
    sock: socket.NoiseSocket,
    pub fn init(allocator: std.mem.Allocator) Client {
        return .{ .allocator = allocator, .sock = socket.NoiseSocket.init(allocator) };
    }
    pub fn connect(self: *Client) !void { _ = self; return error.NotImplemented; }
    pub fn sendText(self: *Client, to: []const u8, text: []const u8) !void { _ = self; _ = to; _ = text; return error.NotImplemented; }
};
test "client stub" { _ = Client; }
