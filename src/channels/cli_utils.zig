const std = @import("std");
const compat = @import("../compat.zig");
const types = @import("../providers/types.zig");

fn compatWriteAll(writer: anytype, bytes: []const u8) !void {
    const T = @TypeOf(writer);
    if (T == std.Io.File) {
        try writer.writeStreamingAll(compat.getIo(), bytes);
    } else {
        try writer.writeAll(bytes);
    }
}

pub fn formatMessagePrefix(role: types.MessageRole) []const u8 {
    return switch (role) {
        .user => "\x1b[32mUser:\x1b[0m ",
        .assistant => "\x1b[34mAssistant:\x1b[0m ",
        .system => "\x1b[35mSystem:\x1b[0m ",
        else => "\x1b[33mTool:\x1b[0m ",
    };
}

pub fn formatToolCall(name: []const u8, args: []const u8, writer: anytype) !void {
    if (@TypeOf(writer) == std.Io.File) {
        try writer.writeStreamingAll(compat.getIo(), "\x1b[36m→\x1b[0m Calling ");
        try writer.writeStreamingAll(compat.getIo(), name);
        try writer.writeStreamingAll(compat.getIo(), " with ");
        try writer.writeStreamingAll(compat.getIo(), args);
        try writer.writeStreamingAll(compat.getIo(), "\n");
    } else {
        try writer.writeAll("\x1b[36m→\x1b[0m Calling ");
        try writer.writeAll(name);
        try writer.writeAll(" with ");
        try writer.writeAll(args);
        try writer.writeAll("\n");
    }
}

pub fn formatToolResult(name: []const u8, result: []const u8, writer: anytype) !void {
    if (@TypeOf(writer) == std.Io.File) {
        try writer.writeStreamingAll(compat.getIo(), "\x1b[36m✓\x1b[0m ");
        try writer.writeStreamingAll(compat.getIo(), name);
        try writer.writeStreamingAll(compat.getIo(), ": ");
        try writer.writeStreamingAll(compat.getIo(), result);
        try writer.writeStreamingAll(compat.getIo(), "\n");
    } else {
        try writer.writeAll("\x1b[36m✓\x1b[0m ");
        try writer.writeAll(name);
        try writer.writeAll(": ");
        try writer.writeAll(result);
        try writer.writeAll("\n");
    }
}

pub fn formatError(err: []const u8, writer: anytype) !void {
    if (@TypeOf(writer) == std.Io.File) {
        try writer.writeStreamingAll(compat.getIo(), "\x1b[31mError:\x1b[0m ");
        try writer.writeStreamingAll(compat.getIo(), err);
        try writer.writeStreamingAll(compat.getIo(), "\n");
    } else {
        try writer.writeAll("\x1b[31mError:\x1b[0m ");
        try writer.writeAll(err);
        try writer.writeAll("\n");
    }
}

pub fn formatStreamingToken(token: []const u8, writer: anytype) !void {
    try compatWriteAll(writer, token);
}
pub fn clearCurrentLine(writer: anytype) !void {
    try compatWriteAll(writer, "\r\x1b[K");
}

test "formatMessagePrefix returns colors" {
    _ = formatMessagePrefix(.user);
    _ = formatMessagePrefix(.assistant);
}

test "formatToolCall formats correctly" {
    var storage: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&storage);
    try formatToolCall("echo", "hello", &w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "echo") != null);
}

test "formatError formats correctly" {
    var storage: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&storage);
    try formatError("test error", &w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Error:") != null);
}
