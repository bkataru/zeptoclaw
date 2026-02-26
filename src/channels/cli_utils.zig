const std = @import("std");
const types = @import("../providers/types.zig");

pub fn formatMessagePrefix(role: types.MessageRole) []const u8 {
    return switch (role) {
        .user => "\x1b[32mUser:\x1b[0m ",
        .assistant => "\x1b[34mAssistant:\x1b[0m ",
        .system => "\x1b[35mSystem:\x1b[0m ",
        else => "\x1b[33mTool:\x1b[0m ",
    };
}

pub fn formatToolCall(name: []const u8, args: []const u8, writer: anytype) !void {
    try writer.writeAll("\x1b[36m→\x1b[0m Calling ");
    try writer.writeAll(name);
    try writer.writeAll(" with ");
    try writer.writeAll(args);
    try writer.writeAll("\n");
}

pub fn formatToolResult(name: []const u8, result: []const u8, writer: anytype) !void {
    try writer.writeAll("\x1b[36m✓\x1b[0m ");
    try writer.writeAll(name);
    try writer.writeAll(": ");
    try writer.writeAll(result);
    try writer.writeAll("\n");
}

pub fn formatError(err: []const u8, writer: anytype) !void {
    try writer.writeAll("\x1b[31mError:\x1b[0m ");
    try writer.writeAll(err);
    try writer.writeAll("\n");
}

pub fn formatStreamingToken(token: []const u8, writer: anytype) !void {
    try writer.writeAll(token);
}
pub fn clearCurrentLine(writer: anytype) !void {
    try writer.writeAll("\r\x1b[K");
}

test "formatMessagePrefix returns colors" {
    _ = formatMessagePrefix(.user);
    _ = formatMessagePrefix(.assistant);
}

test "formatToolCall formats correctly" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const writer = buf.writer();
    
    try formatToolCall("echo", "hello", writer);
    const result = buf.items;
    
    try std.testing.expect(std.mem.indexOf(u8, result, "echo") != null);
}

test "formatError formats correctly" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const writer = buf.writer();
    
    try formatError("test error", writer);
    const result = buf.items;
    
    try std.testing.expect(std.mem.indexOf(u8, result, "Error:") != null);
}
