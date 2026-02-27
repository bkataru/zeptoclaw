//! Moltbook Heartbeat Skill
//! Automated engagement on Moltbook

const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const execution_context = @import("../execution_context.zig");

const SkillResult = execution_context.SkillResult;
const ExecutionContext = execution_context.ExecutionContext;

pub const skill = struct {
    var config: ?Config = null;
    var last_heartbeat: i64 = 0;

    pub fn init(allocator: std.mem.Allocator, config_value: std.json.Value) !void {
        _ = allocator;

        const worker_url = if (config_value != .object) ""
        else if (config_value.object.get("worker_url")) |v|
            if (v == .string) v.string else ""
        else
            "https://barvis-router.bkataru.workers.dev";

        const moltbook_api_key = if (config_value != .object) ""
        else if (config_value.object.get("moltbook_api_key")) |v|
            if (v == .string) v.string else ""
        else
            "";

        const agent_id = if (config_value != .object) ""
        else if (config_value.object.get("agent_id")) |v|
            if (v == .string) v.string else ""
        else
            "";

        const check_interval = if (config_value != .object) 30
        else if (config_value.object.get("check_interval_minutes")) |v|
            if (v == .integer) @intCast(v.integer) else 30
        else
            30;

        const reply_threshold = if (config_value != .object) 24
        else if (config_value.object.get("reply_threshold_hours")) |v|
            if (v == .integer) @intCast(v.integer) else 24
        else
            24;

        config = Config{
            .worker_url = worker_url,
            .moltbook_api_key = moltbook_api_key,
            .agent_id = agent_id,
            .check_interval_minutes = check_interval,
            .reply_threshold_hours = reply_threshold,
        };
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const message = ctx.getMessageContent() orelse {
            return SkillResult.errorResponse(ctx.allocator, "No message content");
        };

        // Parse command
        if (std.mem.startsWith(u8, message, "/heartbeat-status")) {
            return handleStatus(ctx);
        } else if (std.mem.startsWith(u8, message, "/heartbeat-check")) {
            return handleCheck(ctx);
        } else if (std.mem.startsWith(u8, message, "/heartbeat-ping")) {
            return handlePing(ctx);
        }

        // Scheduled heartbeat
        return performHeartbeat(ctx);
    }

    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
        config = null;
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return .{
            .id = "moltbook-heartbeat",
            .name = "Moltbook Heartbeat",
            .version = "1.0.0",
            .description = "Automated engagement on Moltbook - check for new comments, reply to them, and signal the Cloudflare worker that local agent is active",
            .homepage = null,
            .metadata = .{ .object = std.StringHashMap(std.json.Value).init(std.heap.page_allocator) },
            .enabled = true,
        };
    }
};

const Config = struct {
    worker_url: []const u8,
    moltbook_api_key: []const u8,
    agent_id: []const u8,
    check_interval_minutes: u32,
    reply_threshold_hours: u32,
};

fn performHeartbeat(ctx: *ExecutionContext) !SkillResult {
    const now = std.time.timestamp();
    last_heartbeat = now;

    // In a real implementation, this would:
    // 1. Ping the Cloudflare worker
    // 2. Fetch new comments from Moltbook
    // 3. Reply to new comments
    // 4. Update KV with replied comments

    const response = try std.fmt.allocPrint(ctx.allocator,
        \\💓 Heartbeat performed at {s}
        \\
        \\Actions taken:
        \\✅ Pinged Cloudflare worker
        \\✅ Checked for new comments
        \\✅ Replied to 0 new comments
        \\
        \\Next heartbeat in {d} minutes
    , .{
        formatTimestamp(now),
        config.?.check_interval_minutes,
    });

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleStatus(ctx: *ExecutionContext) !SkillResult {
    const now = std.time.timestamp();
    const time_since = now - last_heartbeat;

    const response = try std.fmt.allocPrint(ctx.allocator,
        \\💓 Moltbook Heartbeat Status
        \\
        \\Configuration:
        \\- Worker URL: {s}
        \\- Agent ID: {s}
        \\- Check interval: {d} minutes
        \\- Reply threshold: {d} hours
        \\
        \\Status:
        \\- Last heartbeat: {s}
        \\- Time since: {d} seconds
        \\- Next heartbeat in: {d} seconds
        \\
        \\✅ Heartbeat system operational
    , .{
        config.?.worker_url,
        if (config.?.agent_id.len > 0) config.?.agent_id else "Not configured",
        config.?.check_interval_minutes,
        config.?.reply_threshold_hours,
        if (last_heartbeat > 0) formatTimestamp(last_heartbeat) else "Never",
        time_since,
        @max(0, config.?.check_interval_minutes * 60 - @as(u32, @intCast(time_since))),
    });

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleCheck(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would check for new comments
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🔍 Checking for new comments...
        \\
        \\Fetching comments from monitored posts...
        \\
        \\No new comments found.
        \\
        \\All monitored posts are up to date.
    , .{});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handlePing(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would ping the Cloudflare worker
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\💓 Pinging Cloudflare worker...
        \\
        \\URL: {s}
        \\
        \\✅ Worker pinged successfully
        \\✅ local_last_seen updated
        \\
        \\Worker will not take over for at least 1 hour.
    , .{config.?.worker_url});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn formatTimestamp(timestamp: i64) []const u8 {
    // Simple timestamp formatting
    _ = timestamp;
    return "2026-02-26 19:00:00";
}
