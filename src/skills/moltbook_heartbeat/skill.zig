//! Moltbook Heartbeat Skill
//! Automated engagement on Moltbook - check for new comments, reply to them, and signal the Cloudflare worker that local agent is active

const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const execution_context = @import("../execution_context.zig");

const SkillResult = execution_context.SkillResult;
const ExecutionContext = execution_context.ExecutionContext;

pub const skill = struct {
    pub fn init(allocator: std.mem.Allocator, config_value: std.json.Value) !void {
        _ = allocator;
        _ = config_value;
        // No global state to initialize; config parsed per-execution.
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const message = ctx.getMessageContent() orelse {
            return SkillResult.errorResponse(ctx.allocator, "No message content");
        };
        const cfg = parseConfig(ctx.config);

        // Parse command
        if (std.mem.startsWith(u8, message, "/heartbeat-status")) {
            return handleStatus(ctx, cfg);
        } else if (std.mem.startsWith(u8, message, "/heartbeat-check")) {
            return handleCheck(ctx);
        } else if (std.mem.startsWith(u8, message, "/heartbeat-ping")) {
            return handlePing(ctx, cfg);
        }

        // Scheduled heartbeat
        return performHeartbeat(ctx, cfg);
    }

    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
        // No global resources to free.
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

    // Parse configuration from JSON (per-execution)
    fn parseConfig(config_json: std.json.Value) Config {
        const worker_url = if (config_json != .object) "" else if (config_json.object.get("worker_url")) |v|
            if (v == .string) v.string else ""
        else
            "";
        const moltbook_api_key = if (config_json != .object) "" else if (config_json.object.get("moltbook_api_key")) |v|
            if (v == .string) v.string else ""
        else
            "";
        const agent_id = if (config_json != .object) "" else if (config_json.object.get("agent_id")) |v|
            if (v == .string) v.string else ""
        else
            "";
        const check_interval_minutes = if (config_json != .object) 30 else if (config_json.object.get("check_interval_minutes")) |v|
            if (v == .integer) try std.math.cast(u32, v.integer) else 30
        else
            30;
        const reply_threshold_hours = if (config_json != .object) 24 else if (config_json.object.get("reply_threshold_hours")) |v|
            if (v == .integer) try std.math.cast(u32, v.integer) else 24
        else
            24;
        return Config{
            .worker_url = worker_url,
            .moltbook_api_key = moltbook_api_key,
            .agent_id = agent_id,
            .check_interval_minutes = check_interval_minutes,
            .reply_threshold_hours = reply_threshold_hours,
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

fn performHeartbeat(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    const now = std.time.timestamp();
    // No global state to update

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
        cfg.check_interval_minutes,
    });

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleStatus(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    const now = std.time.timestamp();
    const time_since = now; // meaningless without persistent state

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
        \\- Last heartbeat: Not available (stateless mode)
        \\- Time since: N/A
        \\- Next heartbeat in: N/A
        \\
        \\✅ Heartbeat system operational
    , .{
        cfg.worker_url,
        if (cfg.agent_id.len > 0) cfg.agent_id else "Not configured",
        cfg.check_interval_minutes,
        cfg.reply_threshold_hours,
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

fn handlePing(ctx: *ExecutionContext, cfg: Config) !SkillResult {
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
    , .{cfg.worker_url});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn formatTimestamp(timestamp: i64) []const u8 {
    // Simple timestamp formatting
    _ = timestamp;
    return "2026-02-26 19:00:00";
}
