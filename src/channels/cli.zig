const std = @import("std");

pub fn runInteractiveSession(agent: anytype) !void {
    _ = agent;
    // Interactive session - for now just print a message
    // TODO: Fix stdin/stdout API in Zig 0.15
    std.debug.print("Interactive mode not fully implemented. Set NVIDIA_API_KEY and run with --help.\n", .{});
}

test "CLI" {
    _ = runInteractiveSession;
}
