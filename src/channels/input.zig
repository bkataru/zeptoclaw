const std = @import("std");

pub fn readLine(allocator: std.mem.Allocator, prompt: []const u8) ![]const u8 {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(prompt);
    try stdout.flush();
    
    const stdin = std.io.getStdIn();
    var reader = stdin.reader();
    
    return try reader.readUntilDelimiterAlloc(allocator, '\n', 4096);
}

pub fn isEOF() bool {
    const stdin = std.io.getStdIn();
    var buf: [1]u8 = undefined;
    const n = stdin.read(&buf) catch return true;
    return n == 0;
}

test "input module loads" {
    _ = readLine;
    _ = isEOF;
}
