const std = @import("std");
const compat = @import("../compat.zig");

pub fn readLine(allocator: std.mem.Allocator, prompt: []const u8) ![]const u8 {
    const stdout_file = std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false }};
    try stdout_file.writeStreamingAll(compat.getIo(), prompt);
    
    const stdin = std.Io.File{ .handle = std.posix.STDIN_FILENO, .flags = .{ .nonblocking = false }};
    var buf: [4096]u8 = undefined;
    const n = try stdin.readStreaming(compat.getIo(), &[_][]u8{buf[0..]});
    if (n == 0) return error.EndOfStream;
    const line = buf[0..n];
    const trimmed = if (line.len > 0 and line[line.len - 1] == '\n') line[0..line.len - 1] else line;
    return try allocator.dupe(u8, trimmed);
}

pub fn isEOF() bool {
    const stdin = std.Io.File.stdin();
    var buf: [1]u8 = undefined;
    var reader_buf: [1]u8 = undefined;
    var reader = stdin.reader(compat.getIo(), &reader_buf);
    const data = reader.interface.readSlice(&buf) catch return true;
    return data.len == 0;
}

test "input module loads" {
    _ = readLine;
    _ = isEOF;
}
