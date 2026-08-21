const std = @import("std");

// High-level native client — port of whatsmeow/client.go 1066 behind WhatsAppChannel facade
pub const NativeClient = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) NativeClient { return .{ .allocator = allocator }; }
    pub fn connect(self: *NativeClient) !void { _ = self; return error.NotImplemented; }
    pub fn disconnect(self: *NativeClient) void { _ = self; }
    pub fn sendText(self: *NativeClient, to: []const u8, text: []const u8) !void { _ = self; _ = to; _ = text; return error.NotImplemented; }
    pub fn getQr(self: *NativeClient) ![]const u8 { _ = self; return error.NotImplemented; }
};
test "native client stub" { _ = NativeClient; }
