const std = @import("std");
const zeptoclaw = @import("zeptoclaw");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    const cfg = zeptoclaw.config.Config.load(allocator) catch {
        std.debug.print("Error: NVIDIA_API_KEY environment variable not set\n", .{});
        std.debug.print("Please set it and try again: export NVIDIA_API_KEY=your-key\n", .{});
        return error.MissingApiKey;
    };
    defer @constCast(@as(*const zeptoclaw.config.Config, &cfg)).deinit(allocator);

    // Initialize agent
    var agent = try zeptoclaw.agent.loop.Agent.init(allocator, cfg);
    defer agent.deinit();

    // Run interactive session
    try zeptoclaw.channels.cli.runInteractiveSession(&agent);
}

test "main" {
    _ = main;
}
