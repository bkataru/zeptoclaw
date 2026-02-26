const std = @import("std");

pub fn readLine(allocator: std.mem.Allocator, prompt: []const u8) ![]const u8 {
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    try stdout_file.writeAll(prompt);
    
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var buf: [4096]u8 = undefined;
    const n = try stdin.read(&buf);
    
    if (n == 0) return error.EndOfStream;
    
    // Trim newline
    const line = buf[0..n];
    const trimmed = if (line.len > 0 and line[line.len - 1] == '\n') line[0..line.len - 1] else line;
    
    return try allocator.dupe(u8, trimmed);
}

pub fn isEOF() bool {
    const stdin = std.fs.File.stdin();
    var buf: [1]u8 = undefined;
    const n = stdin.read(&buf) catch return true;
    return n == 0;
}

test "input module loads" {
    _ = readLine;
    _ = isEOF;
}
