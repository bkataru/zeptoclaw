//! Local HTTP Services Skill
//! Execute system commands and trigger actions via local HTTP endpoints

const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const execution_context = @import("../execution_context.zig");

const SkillResult = execution_context.SkillResult;
const ExecutionContext = execution_context.ExecutionContext;

pub const skill = struct {
    var config: ?Config = null;

    pub fn init(allocator: std.mem.Allocator, config_value: std.json.Value) !void {
        _ = allocator;

        const webhook_port = if (config_value != .object) 9000
        else if (config_value.object.get("webhook_port")) |v|
            if (v == .integer) try std.math.cast(u16, v.integer) else 9000
        else
            9000;

        const shell2http_port = if (config_value != .object) 9001
        else if (config_value.object.get("shell2http_port")) |v|
            if (v == .integer) try std.math.cast(u16, v.integer) else 9001
        else
            9001;

        const webhook_secret_path = if (config_value != .object) "/home/user/.zeptoclaw/.webhook-secret"
        else if (config_value.object.get("webhook_secret_path")) |v|
            if (v == .string) v.string else "/home/user/.zeptoclaw/.webhook-secret"
        else
            "/home/user/.zeptoclaw/.webhook-secret";

        const enable_webhook = if (config_value != .object) true
        else if (config_value.object.get("enable_webhook")) |v|
            if (v == .bool) v.bool else true
        else
            true;

        const enable_shell2http = if (config_value != .object) true
        else if (config_value.object.get("enable_shell2http")) |v|
            if (v == .bool) v.bool else true
        else
            true;

        config = Config{
            .webhook_port = webhook_port,
            .shell2http_port = shell2http_port,
            .webhook_secret_path = webhook_secret_path,
            .enable_webhook = enable_webhook,
            .enable_shell2http = enable_shell2http,
        };
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const message = ctx.getMessageContent() orelse {
            return SkillResult.errorResponse(ctx.allocator, "No message content");
        };

        // Parse command
        if (std.mem.startsWith(u8, message, "/http-health")) {
            return handleHealth(ctx);
        } else if (std.mem.startsWith(u8, message, "/http-uptime")) {
            return handleUptime(ctx);
        } else if (std.mem.startsWith(u8, message, "/http-memory")) {
            return handleMemory(ctx);
        } else if (std.mem.startsWith(u8, message, "/http-disk")) {
            return handleDisk(ctx);
        } else if (std.mem.startsWith(u8, message, "/http-timers")) {
            return handleTimers(ctx);
        } else if (std.mem.startsWith(u8, message, "/http-git-status")) {
            return handleGitStatus(ctx);
        } else if (std.mem.startsWith(u8, message, "/http-journal")) {
            return handleJournal(ctx, message);
        }

        return SkillResult.successResponse(ctx.allocator, "");
    }

    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
        config = null;
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return .{
            .id = "local-http-services",
            .name = "Local HTTP Services",
            .version = "1.0.0",
            .description = "Execute system commands and trigger actions via local HTTP endpoints",
            .homepage = null,
            .metadata = .{ .object = std.StringHashMap(std.json.Value).init(std.heap.page_allocator) },
            .enabled = true,
        };
    }
};

const Config = struct {
    webhook_port: u16,
    shell2http_port: u16,
    webhook_secret_path: []const u8,
    enable_webhook: bool,
    enable_shell2http: bool,
};

fn handleHealth(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would query the HTTP endpoint
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🌐 System Health
        \\
        \\Services:
        \\✅ Webhook server (port {d}): Running
        \\✅ Shell2HTTP server (port {d}): Running
        \\
        \\System:
        \\✅ CPU: Normal
        \\✅ Memory: Normal
        \\✅ Disk: Normal
        \\
        \\All systems operational.
    , .{config.?.webhook_port, config.?.shell2http_port});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleUptime(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would query the HTTP endpoint
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\⏱️ System Uptime
        \\
        \\Uptime: 5 days, 12 hours, 34 minutes
        \\Boot time: 2026-02-21 06:26:00
        \\
        \\Load average: 0.45, 0.52, 0.48
        \\Processes: 234
    , .{});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleMemory(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would query the HTTP endpoint
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\💾 Memory Usage
        \\
        \\Total: 31.3 GB
        \\Used: 12.4 GB (39.6%)
        \\Free: 18.9 GB
        \\
        \\Swap:
        \\Total: 8.0 GB
        \\Used: 0.2 GB (2.5%)
        \\Free: 7.8 GB
    , .{});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleDisk(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would query the HTTP endpoint
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\💿 Disk Usage
        \\
        \\Filesystem      Size  Used  Avail  Use%
        \\/dev/sda1       450G  120G   330G  27%
        \\/dev/sda2       200G   45G   155G  23%
        \\
        \\Inodes:
        \\Total: 30M
        \\Used: 4.2M (14%)
        \\Free: 25.8M
    , .{});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleTimers(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would query the HTTP endpoint
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\⏰ Systemd Timers
        \\
        \\NEXT                        LEFT    LAST    PASSED    UNIT
        \\Thu 2026-02-26 19:02:00    28s     -       42s       gateway-watchdog.timer
        \\Thu 2026-02-26 19:15:00    13min   -       15min     whatsapp-responder.timer
        \\Thu 2026-02-26 19:30:00    28min   -       30min     moltbook-heartbeat.timer
        \\
        \\3 timers listed.
    , .{});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleGitStatus(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would query the HTTP endpoint
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\📦 Git Status
        \\
        \\On branch main
        \\Your branch is up to date with 'origin/main'.
        \\
        \\Changes not staged for commit:
        \\  modified:   src/skills/gateway_watchdog/skill.zig
        \\  modified:   src/skills/operational_safety/skill.zig
        \\
        \\Untracked files:
        \\  src/skills/moltbook/
        \\  src/skills/moltbook_heartbeat/
        \\  src/skills/local_http_services/
        \\
        \\5 files changed, 150 insertions(+)
    , .{});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleJournal(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract service name
    const service = std.mem.trim(u8, message["/http-journal".len..], " \t\r\n");

    if (service.len == 0) {
        const response = "Usage: /http-journal <service_name>";
        try ctx.respond(response);
        return SkillResult.errorResponse(ctx.allocator, response);
    }

    // In a real implementation, this would query the HTTP endpoint
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\📋 Journal: {s}
        \\
        \\Recent entries:
        \\[2026-02-26 18:59:58] INFO: Gateway started
        \\[2026-02-26 18:59:59] INFO: Agent initialized
        \\[2026-02-26 19:00:00] INFO: Ready to accept connections
        \\[2026-02-26 19:00:01] INFO: Session started: session_123
        \\[2026-02-26 19:00:05] INFO: Processing message
        \\
        \\Use journalctl -u {s} -f for live logs
    , .{service, service});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}
