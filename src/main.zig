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
    var cfg = Config.load(allocator) catch |err| {
        std.debug.print("Configuration error: {}\n", .{err});
        return err;
    };
    defer cfg.deinit();

    // Initialize NIM client
    var nim_client = NIMClient.init(allocator, cfg);
    defer nim_client.deinit();

    // Initialize agent with NIM client
    var agent = try Agent.init(allocator, &nim_client, 50);
    defer agent.deinit();

    // Run interactive CLI session
    try zeptoclaw.channels.cli.runInteractiveSession(&agent);
}

test "main" {
    _ = main;
}
