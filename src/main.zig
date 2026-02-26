const std = @import("std");
const zeptoclaw = @import("zeptoclaw");

const NIMClient = zeptoclaw.providers.nim.NIMClient;
const Agent = zeptoclaw.agent.loop.Agent;
const Config = zeptoclaw.config.Config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    var cfg = Config.load(allocator) catch {
        std.debug.print("Error: NVIDIA_API_KEY environment variable not set\n", .{});
        std.debug.print("Please set it and try again: export NVIDIA_API_KEY=your-key\n", .{});
        return error.MissingApiKey;
    };
    defer cfg.deinit(allocator);

    // Initialize NIM client
    var nim_client = NIMClient.init(allocator, cfg);
    defer nim_client.deinit();

    // Initialize agent with NIM client
    var agent = Agent.init(allocator, &nim_client, 50);
    defer agent.deinit();

    // Run interactive session
    try zeptoclaw.channels.cli.runInteractiveSession(&agent);
}

test "main" {
    _ = main;
}
