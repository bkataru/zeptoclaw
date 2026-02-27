//! Webhook Endpoint Implementations
//! All 12 webhook endpoints from OpenClaw with exact command mappings

const std = @import("std");
const http = @import("http_utils.zig");

const log = std.log.scoped(.webhook_endpoints);

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

/// 1. health - echo "ok"
pub fn health(ctx: *EndpointContext, body: ?[]const u8) !http.HttpResponse {
    _ = body;
    return http.HttpResponse.text(ctx.allocator, "ok");
}

/// 2. gateway-restart - systemctl --user restart openclaw-gateway.service
pub fn gatewayRestart(ctx: *EndpointContext, body: ?[]const u8) !http.HttpResponse {
    _ = body;

    // Set up environment for systemctl --user
    const uid = std.os.linux.getuid();
    const xdg_runtime = try std.fmt.allocPrint(ctx.allocator, "/run/user/{d}", .{uid});
    defer ctx.allocator.free(xdg_runtime);

    const dbus_address = try std.fmt.allocPrint(ctx.allocator, "unix:path={s}/bus", .{xdg_runtime});
    defer ctx.allocator.free(dbus_address);

    const argv = &[_][]const u8{
        "/usr/bin/systemctl",
        "--user",
        "restart",
        "openclaw-gateway.service",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.home_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// 3. git-pull - git pull --ff-only
pub fn gitPull(ctx: *EndpointContext, body: ?[]const u8) !http.HttpResponse {
    _ = body;

    const argv = &[_][]const u8{
        "/usr/bin/git",
        "pull",
        "--ff-only",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.workspace_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// 4. git-push - git push
pub fn gitPush(ctx: *EndpointContext, body: ?[]const u8) !http.HttpResponse {
    _ = body;

    const argv = &[_][]const u8{
        "/usr/bin/git",
        "push",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.workspace_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// 5. sync-memory - run sync-memory.sh
pub fn syncMemory(ctx: *EndpointContext, body: ?[]const u8) !http.HttpResponse {
    _ = body;

    const script_path = try std.fmt.allocPrint(ctx.allocator, "{s}/.openclaw/scripts/sync-memory.sh", .{ctx.home_dir});
    defer ctx.allocator.free(script_path);

    const argv = &[_][]const u8{ script_path };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.workspace_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// 6. deploy-worker - run deploy-worker.sh
pub fn deployWorker(ctx: *EndpointContext, body: ?[]const u8) !http.HttpResponse {
    _ = body;

    const script_path = try std.fmt.allocPrint(ctx.allocator, "{s}/.openclaw/scripts/deploy-worker.sh", .{ctx.home_dir});
    defer ctx.allocator.free(script_path);

    const worker_dir = try std.fmt.allocPrint(ctx.allocator, "{s}/.openclaw/workspace/barvis-router", .{ctx.home_dir});
    defer ctx.allocator.free(worker_dir);

    const argv = &[_][]const u8{ script_path };

    const result = try http.executeCommandSimple(ctx.allocator, argv, worker_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// 7. run-tests - run run-tests.sh
pub fn runTests(ctx: *EndpointContext, body: ?[]const u8) !http.HttpResponse {
    _ = body;

    const script_path = try std.fmt.allocPrint(ctx.allocator, "{s}/.openclaw/scripts/run-tests.sh", .{ctx.home_dir});
    defer ctx.allocator.free(script_path);

    const worker_dir = try std.fmt.allocPrint(ctx.allocator, "{s}/.openclaw/workspace/barvis-router", .{ctx.home_dir});
    defer ctx.allocator.free(worker_dir);

    const argv = &[_][]const u8{ script_path };

    const result = try http.executeCommandSimple(ctx.allocator, argv, worker_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// 8. ollama-run - POST with prompt → ollama query
pub fn ollamaRun(ctx: *EndpointContext, body: ?[]const u8) !http.HttpResponse {
    if (body == null or body.?.len == 0) {
        return http.HttpResponse.badRequest(ctx.allocator, "Missing request body");
    }

    // Parse JSON body
    const parsed = try std.json.parseFromSlice(struct {
        prompt: ?[]const u8 = null,
        model: ?[]const u8 = null,
    }, ctx.allocator, body.?, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const prompt = parsed.value.prompt orelse return http.HttpResponse.badRequest(ctx.allocator, "Missing 'prompt' field");
    const model = parsed.value.model orelse "llama2";

    const script_path = try std.fmt.allocPrint(ctx.allocator, "{s}/.openclaw/scripts/ollama-query.sh", .{ctx.home_dir});
    defer ctx.allocator.free(script_path);

    const argv = &[_][]const u8{ script_path, prompt, model };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.home_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// 9. notify - POST with message → queue-notification.sh
pub fn notify(ctx: *EndpointContext, body: ?[]const u8) !http.HttpResponse {
    if (body == null or body.?.len == 0) {
        return http.HttpResponse.badRequest(ctx.allocator, "Missing request body");
    }

    // Parse JSON body
    const parsed = try std.json.parseFromSlice(struct {
        message: ?[]const u8 = null,
    }, ctx.allocator, body.?, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const message = parsed.value.message orelse return http.HttpResponse.badRequest(ctx.allocator, "Missing 'message' field");

    const script_path = try std.fmt.allocPrint(ctx.allocator, "{s}/.openclaw/scripts/queue-notification.sh", .{ctx.home_dir});
    defer ctx.allocator.free(script_path);

    const argv = &[_][]const u8{ script_path, message };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.home_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// 10. timer-status - systemctl --user list-timers
pub fn timerStatus(ctx: *EndpointContext, body: ?[]const u8) !http.HttpResponse {
    _ = body;

    const argv = &[_][]const u8{
        "/usr/bin/systemctl",
        "--user",
        "list-timers",
        "--no-pager",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.home_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// 11. journal-tail - journal-gateway.sh
pub fn journalTail(ctx: *EndpointContext, body: ?[]const u8) !http.HttpResponse {
    _ = body;

    const script_path = try std.fmt.allocPrint(ctx.allocator, "{s}/.openclaw/scripts/journal-gateway.sh", .{ctx.home_dir});
    defer ctx.allocator.free(script_path);

    const argv = &[_][]const u8{ script_path };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.home_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

/// 12. heartbeat - POST to Cloudflare worker /heartbeat
pub fn heartbeat(ctx: *EndpointContext, body: ?[]const u8) !http.HttpResponse {
    _ = body;

    const argv = &[_][]const u8{
        "/usr/bin/curl",
        "-s",
        "-X",
        "POST",
        "https://barvis-router.bkataru.workers.dev/heartbeat",
    };

    const result = try http.executeCommandSimple(ctx.allocator, argv, ctx.home_dir);
    return http.HttpResponse{ .status = 200, .content_type = "text/plain", .body = result };
}

// ============================================================================
// Endpoint Registry
// ============================================================================

pub const EndpointHandler = *const fn (*EndpointContext, ?[]const u8) anyerror!http.HttpResponse;

pub const Endpoint = struct {
    name: []const u8,
    handler: EndpointHandler,
    requires_auth: bool = true,
    method: []const u8 = "POST",
};

pub const endpoints = &[_]Endpoint{
    .{ .name = "health", .handler = health, .requires_auth = false, .method = "GET" },
    .{ .name = "gateway-restart", .handler = gatewayRestart },
    .{ .name = "git-pull", .handler = gitPull },
    .{ .name = "git-push", .handler = gitPush },
    .{ .name = "sync-memory", .handler = syncMemory },
    .{ .name = "deploy-worker", .handler = deployWorker },
    .{ .name = "run-tests", .handler = runTests },
    .{ .name = "ollama-run", .handler = ollamaRun },
    .{ .name = "notify", .handler = notify },
    .{ .name = "timer-status", .handler = timerStatus, .requires_auth = false, .method = "GET" },
    .{ .name = "journal-tail", .handler = journalTail, .requires_auth = false, .method = "GET" },
    .{ .name = "heartbeat", .handler = heartbeat },
};

pub fn getEndpoint(name: []const u8) ?*const Endpoint {
    for (endpoints) |*endpoint| {
        if (std.mem.eql(u8, endpoint.name, name)) {
            return endpoint;
        }
    }
    return null;
}
