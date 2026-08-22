//! Interval cron: periodically runs Agent.runTurn (OpenClaw-style heartbeat/cron).
const std = @import("std");
const compat = @import("../compat.zig");
const config_mod = @import("../config.zig");
const NIMClient = @import("../providers/nim.zig").NIMClient;
const Agent = @import("loop.zig").Agent;

/// Seconds between turns. 0 = disabled. Override with ZEPTO_CRON_SECS.
pub fn intervalSecs() u64 {
    const v = compat.getEnvVarOwned(std.heap.page_allocator, "ZEPTO_CRON_SECS") catch return 0;
    defer std.heap.page_allocator.free(v);
    return std.fmt.parseInt(u64, v, 10) catch 0;
}

fn cronPrompt() []const u8 {
    return "CRON: This is a scheduled turn. Check workspace MEMORY.md if present. If nothing needs attention, reply HEARTBEAT_OK. Otherwise note one follow-up in one sentence.";
}

/// Blocking loop. Spawn on a thread from gateway main.
pub fn runLoop() void {
    const secs = intervalSecs();
    if (secs == 0) {
        std.log.info("[cron] disabled (ZEPTO_CRON_SECS=0 or unset)", .{});
        return;
    }
    std.log.info("[cron] starting interval={d}s", .{secs});
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    while (true) {
        var remaining = secs;
        while (remaining > 0) {
            _ = std.c.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);
            remaining -= 1;
        }
        fireOnce(allocator) catch |err| {
            std.log.err("[cron] turn failed: {}", .{err});
        };
    }
}

fn fireOnce(allocator: std.mem.Allocator) !void {
    const cfg = try config_mod.Config.load(allocator);
    var nim = NIMClient.init(allocator, cfg);
    defer nim.deinit();
    var agent = try Agent.init(allocator, &nim, 16);
    defer agent.deinit();
    agent.setSessionId("cron");
    const reply = try agent.runTurn(cronPrompt(), .{ .max_iters = 4 });
    defer allocator.free(reply);
    std.log.info("[cron] reply={s}", .{reply});
}

test "intervalSecs unset is zero" {
    try std.testing.expectEqual(@as(u64, 0), intervalSecs());
}
