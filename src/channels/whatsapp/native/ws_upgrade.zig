const std = @import("std");

// WebSocket upgrade over std.Io.net.Stream + tls — port of coder/websocket + framesocket.go
// wss://web.whatsapp.com/ws/chat Origin: https://web.whatsapp.com FrameMaxSize 1<<24
pub const WsClient = struct {
    allocator: std.mem.Allocator,
    stream: ?std.Io.net.Stream = null,
    pub fn init(allocator: std.mem.Allocator) WsClient { return .{ .allocator = allocator }; }
    pub fn connect(self: *WsClient, host: []const u8, path: []const u8) !void {
        _ = self; _ = host; _ = path;
        return error.NotImplemented;
    }
    pub fn writeFrame(self: *WsClient, data: []const u8, opcode: u8) !void { _ = self; _ = data; _ = opcode; return error.NotImplemented; }
    pub fn readFrame(self: *WsClient, buf: []u8) !usize { _ = self; _ = buf; return error.NotImplemented; }
};
test "ws upgrade stub" { _ = WsClient; }
