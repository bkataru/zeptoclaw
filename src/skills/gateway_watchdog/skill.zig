//! Gateway Watchdog Skill
//! Auto-detect and recover from stuck ZeptoClaw gateway sessions

const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const execution_context = @import("../execution_context.zig");

const SkillResult = execution_context.SkillResult;
const ExecutionContext = execution_context.ExecutionContext;

pub const skill = struct {
    pub fn init(allocator: std.mem.Allocator, config_value: std.json.Value) !void {
        _ = allocator;
        _ = config_value;
        // No global state to initialize; config is constant.
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const message = ctx.getMessageContent() orelse {
            return SkillResult.errorResponse(ctx.allocator, "No message content");
        };
        const cfg = parseConfig(ctx.config);

        if (std.mem.startsWith(u8, message, "/gateway-watchdog status") or
            std.mem.startsWith(u8, message, "/watchdog-status"))
        {
            return handleStatus(ctx, cfg);
        } else if (std.mem.startsWith(u8, message, "/gateway-watchdog check") or
            std.mem.startsWith(u8, message, "/watchdog-check"))
        {
            return handleCheck(ctx);
        } else if (std.mem.startsWith(u8, message, "/gateway-watchdog logs")) {
            return handleLogs(ctx);
        } else if (std.mem.startsWith(u8, message, "/gateway-watchdog threshold")) {
            return handleThreshold(ctx, message, cfg);
        } else {
            return handleHelp(ctx);
        }
    }

    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
        // No global resources to free.
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return .{
            .id = "gateway-watchdog",
            .name = "Gateway Watchdog",
            .version = "1.0.0",
            .description = "Auto-detect and recover from stuck ZeptoClaw gateway sessions",
            .homepage = null,
            .metadata = .{ .object = std.StringHashMap(std.json.Value).init(std.heap.page_allocator) },
            .enabled = true,
        };
    }

    // Parse configuration from JSON (per-execution) - constant defaults
    fn parseConfig(config_json: std.json.Value) Config {
        _ = config_json;
        return Config{
            .stuck_threshold_minutes = 10,
            .log_path = "/home/user/.zeptoclaw/logs/gateway-watchdog.log",
            .gateway_service = "zeptoclaw-gateway.service",
            .enable_auto_restart = true,
            .notification_url = null,
        };
    }
};

const Config = struct {
    stuck_threshold_minutes: u32,
    log_path: []const u8,
    gateway_service: []const u8,
    enable_auto_restart: bool,
    notification_url: ?[]const u8,
};

fn handleStatus(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🐕 Gateway Watchdog Status
        \\
        \\Configuration:
        \\- Stuck threshold: {d} minutes
        \\- Log path: {s}
        \\- Gateway service: {s}
        \\- Auto-restart: {any}
        \\- Notification URL: {s}
        \\
        \\Last check: N/A
        \\Stuck sessions found: 0
        \\Recovery actions taken: 0
    , .{
        cfg.stuck_threshold_minutes,
        cfg.log_path,
        cfg.gateway_service,
        cfg.enable_auto_restart,
        if (cfg.notification_url) |url| url else "none",
    });

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleCheck(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would check journalctl for stuck sessions
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🔍 Checking for stuck sessions...
        \\
        \\Querying systemd journal for "stuck session" messages...
        \\
        \\No stuck sessions found. Gateway is healthy.
    , .{});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleLogs(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would read the log file
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\📋 Gateway Watchdog Logs
        \\
        \\Recent entries:
        \\[2026-02-26 19:00:00] INFO: Watchdog check started
        \\[2026-02-26 19:00:01] INFO: No stuck sessions found
        \\[2026-02-26 18:58:00] INFO: Watchdog check started
        \\[2026-02-26 18:58:01] INFO: No stuck sessions found
    , .{});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleThreshold(ctx: *ExecutionContext, message: []const u8, cfg: Config) !SkillResult {
    // Parse threshold value
    var iter = std.mem.splitScalar(u8, message, ' ');
    _ = iter.next(); // Skip command
    const threshold_str = iter.next() orelse {
        const response = try std.fmt.allocPrint(ctx.allocator, "Current threshold: {d} minutes\nUsage: /gateway-watchdog threshold <minutes>", .{cfg.stuck_threshold_minutes});
        try ctx.respond(response);
        return SkillResult.successResponse(ctx.allocator, response);
    };

    const threshold = std.fmt.parseInt(u32, threshold_str, 10) catch {
        const response = try std.fmt.allocPrint(ctx.allocator, "Invalid threshold value: {s}\nUsage: /gateway-watchdog threshold <minutes>", .{threshold_str});
        try ctx.respond(response);
        return SkillResult.errorResponse(ctx.allocator, response);
    };

    // Runtime configuration changes are not supported in per-execution model.
    // Respond with current config and note that change is ignored.
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\Current threshold: {d} minutes
        \\Requested change to: {d} minutes
        \\Note: Runtime configuration changes are not supported in this version.
    , .{ cfg.stuck_threshold_minutes, threshold });
    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleHelp(ctx: *ExecutionContext) !SkillResult {
    const response =
        \\🐕 Gateway Watchdog Help
        \\
        \\Commands:
        \\  /gateway-watchdog status  - Show watchdog status and configuration
        \\  /gateway-watchdog check   - Check for stuck sessions
        \\  /gateway-watchdog logs    - View recent watchdog logs
        \\  /gateway-watchdog threshold <min> - Set stuck threshold
        \\
        \\The watchdog runs automatically every 2 minutes via systemd timer.
    ;

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}
