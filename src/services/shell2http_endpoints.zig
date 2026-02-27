//! Shell2HTTP Endpoint Implementations
//! All 30+ read-only system monitoring endpoints from OpenClaw

const std = @import("std");
const http = @import("http_utils.zig");

const log = std.log.scoped(.shell2http_endpoints);

// ============================================================================
// Endpoint Context
// ============================================================================

pub const EndpointContext = struct {
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    workspace_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator) !EndpointContext {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        const workspace = try std.fmt.allocPrint(allocator, "{s}/.openclaw/workspace", .{home});

        return .{
            .allocator = allocator,
            .home_dir = home,
            .workspace_dir = workspace,
        };
    }

    pub fn deinit(self: *EndpointContext) void {
        self.allocator.free(self.home_dir);
        self.allocator.free(self.workspace_dir);
    }
};

// ============================================================================
// Endpoint Handlers
// ============================================================================

/// /health - echo "ok"
pub fn health(ctx: *EndpointContext) !http.HttpResponse {
    return http.HttpResponse.text(ctx.allocator, "ok");
}

/// /systemctl/status - systemctl --user status --no-pager
pub fn systemctlStatus(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/systemctl",
        "--user",
        "status",
        "--no-pager",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.home_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /timers - systemctl --user list-timers --no-pager
pub fn timers(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/systemctl",
        "--user",
        "list-timers",
        "--no-pager",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.home_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /journal/gateway - journalctl --user -u openclaw-gateway.service -n 50 --no-pager
pub fn journalGateway(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/journalctl",
        "--user",
        "-u",
        "openclaw-gateway.service",
        "-n",
        "50",
        "--no-pager",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.home_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /journal/watchdog - journalctl --user -u gateway-watchdog.service -n 20 --no-pager
pub fn journalWatchdog(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/journalctl",
        "--user",
        "-u",
        "gateway-watchdog.service",
        "-n",
        "20",
        "--no-pager",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.home_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /journal/webhook - journalctl --user -u barvis-webhook.service -n 20 --no-pager
pub fn journalWebhook(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/journalctl",
        "--user",
        "-u",
        "barvis-webhook.service",
        "-n",
        "20",
        "--no-pager",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.home_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /git/status - cd ~/.openclaw/workspace && git status --short
pub fn gitStatus(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/git",
        "status",
        "--short",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.workspace_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /git/log - cd ~/.openclaw/workspace && git log --oneline -10
pub fn gitLog(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/git",
        "log",
        "--oneline",
        "-10",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.workspace_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /disk - df -h / /home /tmp
pub fn disk(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/df",
        "-h",
        "/",
        "/home",
        "/tmp",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, null);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /memory - free -h
pub fn memory(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/free",
        "-h",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, null);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /uptime - uptime
pub fn uptime(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/uptime",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, null);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /date - date "+%Y-%m-%d %H:%M:%S %Z"
pub fn date(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/date",
        "+%Y-%m-%d %H:%M:%S %Z",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, null);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /ollama/list - ollama list
pub fn ollamaList(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/ollama",
        "list",
    };

    const result = http.executeCommandSimple(ctx.allocator, argv, null) catch {
        // If command fails, return a friendly message
        return http.HttpResponse.text(ctx.allocator, "ollama not running");
    };
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /ollama/ps - ollama ps

pub fn ollamaPs(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/ollama",
        "ps",
    };

    const result = http.executeCommandSimple(ctx.allocator, argv, null) catch {
        // If command fails, return a friendly message
        return http.HttpResponse.text(ctx.allocator, "no models loaded");
    };
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /process/openclaw - pgrep -a openclaw
pub fn processOpenclaw(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/pgrep",
        "-a",
        "openclaw",
    };

    const result = http.executeCommandSimple(ctx.allocator, argv, null) catch {
        // If command fails, return a friendly message
        return http.HttpResponse.text(ctx.allocator, "not running");
    };
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /process/all - ps aux --sort=-%mem | head -15


pub fn processAll(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/ps",
        "aux",
        "--sort=-%mem",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, null);

    // Take first 15 lines
    var newline_count: usize = 0;
    var end_idx: usize = 0;
    for (result, 0..) |c, i| {
        if (c == '\n') {
            newline_count += 1;
            if (newline_count >= 15) {
                end_idx = i + 1;
                break;
            }
        }
    }
    const truncated = if (end_idx > 0) result[0..end_idx] else result;
    return http.HttpResponse.text(ctx.allocator, truncated);
}


/// /worker/state - curl -s https://barvis-router.bkataru.workers.dev/state
pub fn workerState(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/curl",
        "-s",
        "https://barvis-router.bkataru.workers.dev/state",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, null);

    // Limit output to 200 lines
    var newline_count: usize = 0;
    var end_idx: usize = 0;
    for (result, 0..) |c, i| {
        if (c == '\n') {
            newline_count += 1;
            if (newline_count >= 200) {
                end_idx = i + 1;
                break;
            }
        }
    }
    const truncated = if (end_idx > 0) result[0..end_idx] else result;
    return http.HttpResponse.text(ctx.allocator, truncated);
}


/// /worker/health - curl -s https://barvis-router.bkataru.workers.dev/health
pub fn workerHealth(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/curl",
        "-s",
        "https://barvis-router.bkataru.workers.dev/health",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, null);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /worker/incidents - curl -s https://barvis-router.bkataru.workers.dev/gateway/incidents
pub fn workerIncidents(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/curl",
        "-s",
        "https://barvis-router.bkataru.workers.dev/gateway/incidents",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, null);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /worker/discoveries - curl -s https://barvis-router.bkataru.workers.dev/discoveries
pub fn workerDiscoveries(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/curl",
        "-s",
        "https://barvis-router.bkataru.workers.dev/discoveries",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, null);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// /network/test - curl -s -o /dev/null -w "%{http_code}" https://api.github.com
pub fn networkTest(ctx: *EndpointContext) !http.HttpResponse {
    const argv = &[_][]const u8{
        "/usr/bin/curl",
        "-s",
        "-o",
        "/dev/null",
        "-w",
        "%{http_code}",
        "https://api.github.com",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, null);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

// ============================================================================
// Endpoint Registry
// ============================================================================

pub const EndpointHandler = *const fn (*EndpointContext) anyerror!http.HttpResponse;

pub const Endpoint = struct {
    path: []const u8,
    handler: EndpointHandler,
    description: []const u8,
};

pub const endpoints = &[_]Endpoint{
    .{ .path = "/health", .handler = health, .description = "Health check" },
    .{ .path = "/systemctl/status", .handler = systemctlStatus, .description = "Systemctl status" },
    .{ .path = "/timers", .handler = timers, .description = "List systemd timers" },
    .{ .path = "/journal/gateway", .handler = journalGateway, .description = "Gateway journal logs" },
    .{ .path = "/journal/watchdog", .handler = journalWatchdog, .description = "Watchdog journal logs" },
    .{ .path = "/journal/webhook", .handler = journalWebhook, .description = "Webhook journal logs" },
    .{ .path = "/git/status", .handler = gitStatus, .description = "Git status" },
    .{ .path = "/git/log", .handler = gitLog, .description = "Git log" },
    .{ .path = "/disk", .handler = disk, .description = "Disk usage" },
    .{ .path = "/memory", .handler = memory, .description = "Memory usage" },
    .{ .path = "/uptime", .handler = uptime, .description = "System uptime" },
    .{ .path = "/date", .handler = date, .description = "Current date/time" },
    .{ .path = "/ollama/list", .handler = ollamaList, .description = "List Ollama models" },
    .{ .path = "/ollama/ps", .handler = ollamaPs, .description = "Ollama running models" },
    .{ .path = "/process/openclaw", .handler = processOpenclaw, .description = "OpenClaw processes" },
    .{ .path = "/process/all", .handler = processAll, .description = "All processes (top 15 by memory)" },
    .{ .path = "/worker/state", .handler = workerState, .description = "Worker state" },
    .{ .path = "/worker/health", .handler = workerHealth, .description = "Worker health" },
    .{ .path = "/worker/incidents", .handler = workerIncidents, .description = "Worker incidents" },
    .{ .path = "/worker/discoveries", .handler = workerDiscoveries, .description = "Worker discoveries" },
    .{ .path = "/network/test", .handler = networkTest, .description = "Network connectivity test" },
};

pub fn getEndpoint(path: []const u8) ?*const Endpoint {
    for (endpoints) |*endpoint| {
        if (std.mem.eql(u8, endpoint.path, path)) {
            return endpoint;
        }
    }
    return null;
}
