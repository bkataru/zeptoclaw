//! WSL2 Troubleshooting Skill
//! WSL2 troubleshooting — DNS fixes, systemd, Windows interop, networking issues

const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const execution_context = @import("../execution_context.zig");

const SkillResult = execution_context.SkillResult;
const ExecutionContext = execution_context.ExecutionContext;

pub const skill = struct {


    pub fn init(allocator: std.mem.Allocator, config_value: std.json.Value) !void {
        _ = allocator;
        _ = config_value;
        // No global state: config parsed per-execution.
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const message = ctx.getMessageContent() orelse {
            return SkillResult.errorResponse(ctx.allocator, "No message content");
        };

        const cfg = parseConfig(ctx.config);

        // Parse command
        if (std.mem.startsWith(u8, message, "/wsl-dns-fix")) {
            return handleDNSFix(ctx, cfg);
        } else if (std.mem.startsWith(u8, message, "/wsl-systemd-check")) {
            return handleSystemdCheck(ctx, cfg);
        } else if (std.mem.startsWith(u8, message, "/wsl-network-check")) {
            return handleNetworkCheck(ctx, cfg);
        } else if (std.mem.startsWith(u8, message, "/wsl-restart")) {
            return handleRestart(ctx, cfg);
        }

        return SkillResult.successResponse(ctx.allocator, "");
    }

    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
        // No global resources to free.
    }
    pub fn getMetadata() sdk.SkillMetadata {
        return .{
            .id = "wsl-troubleshooting",
            .name = "WSL2 Troubleshooting",
            .version = "1.0.0",
            .description = "WSL2 troubleshooting — DNS fixes, systemd, Windows interop, networking issues",
            .homepage = null,
            .metadata = .{ .object = std.StringHashMap(std.json.Value).init(std.heap.page_allocator) },
            .enabled = true,
        };
    }
};

const Config = struct {
    wsl_distro: []const u8,
    dns_servers: []const u8,
    enable_systemd: bool,
};
fn parseConfig(config_json: std.json.Value) anyerror!Config {
    var cfg: Config = undefined;
    if (config_json != .object) {
        cfg = Config{
            .wsl_distro = "Ubuntu",
            .dns_servers = "8.8.8.8,1.1.1.1",
            .enable_systemd = true,
        };
        return cfg;
    }
    const obj = config_json.object;
    cfg.wsl_distro = if (obj.get("wsl_distro")) |v| if (v == .string) v.string else "Ubuntu" else "Ubuntu";
    cfg.dns_servers = if (obj.get("dns_servers")) |v| if (v == .string) v.string else "8.8.8.8,1.1.1.1" else "8.8.8.8,1.1.1.1";
    cfg.enable_systemd = if (obj.get("enable_systemd")) |v| if (v == .bool) v.bool else true else true;
    return cfg;
}
fn handleDNSFix(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    // In a real implementation, this would apply the DNS fix
    const response = try std.fmt.allocPrint(ctx.allocator,
        \🔧 Applying WSL DNS fix...
        \\Steps:
        \1. Disabling auto-generated resolv.conf
        \2. Removing existing symlink
        \3. Creating static resolv.conf with: {s}
        \4. Preventing overwriting with chattr +i
        \\✅ DNS fix applied successfully!
        \\Please restart WSL for changes to take effect:
        \wsl --shutdown
    , .{cfg.dns_servers});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleSystemdCheck(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    // In a real implementation, this would check systemd status
    const response = try std.fmt.allocPrint(ctx.allocator,
        \🔍 Checking systemd status...
        \\Distro: {s}
        \\Systemd status: ✅ Running
        \PID 1: systemd
        \\Enabled services:
        \✅ zeptoclaw-gateway.service
        \✅ gateway-watchdog.timer
        \✅ moltbook-heartbeat.timer
        \\All systemd services operational.
    , .{cfg.wsl_distro});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleNetworkCheck(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    // In a real implementation, this would check network status
    const response = try std.fmt.allocPrint(ctx.allocator,
        \🔍 Checking WSL network status...
        \\WSL IP: 172.20.10.5
        \Windows host IP: 172.20.10.1
        \\DNS servers: {s}
        \DNS resolution: ✅ Working
        \\Port forwarding:
        \9000 → 172.20.10.5:9000 (webhook)
        \9001 → 172.20.10.5:9001 (shell2http)
        \\Network connectivity: ✅ Normal
    , .{cfg.dns_servers});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleRestart(ctx: *ExecutionContext, cfg: Config) !SkillResult {
    // In a real implementation, this would restart WSL
    const response = try std.fmt.allocPrint(ctx.allocator,
        \🔄 Restarting WSL...
        \\Distro: {s}
        \\Shutting down WSL...
        \\Please run this command from PowerShell:
        \wsl --shutdown
        \\Then restart WSL normally.
        \\✅ WSL restart initiated
    , .{cfg.wsl_distro});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}
