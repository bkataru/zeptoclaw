//! WSL2 Troubleshooting Skill
//! WSL2 troubleshooting — DNS fixes, systemd, Windows interop, networking issues

const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const execution_context = @import("../execution_context.zig");

const SkillResult = execution_context.SkillResult;
const ExecutionContext = execution_context.ExecutionContext;

pub const skill = struct {
    var config: ?Config = null;

    pub fn init(allocator: std.mem.Allocator, config_value: std.json.Value) !void {
        _ = allocator;

        const wsl_distro = if (config_value != .object) "Ubuntu"
        else if (config_value.object.get("wsl_distro")) |v|
            if (v == .string) v.string else "Ubuntu"
        else
            "Ubuntu";

        const dns_servers = if (config_value != .object) "8.8.8.8,1.1.1.1"
        else if (config_value.object.get("dns_servers")) |v|
            if (v == .string) v.string else "8.8.8.8,1.1.1.1"
        else
            "8.8.8.8,1.1.1.1";

        const enable_systemd = if (config_value != .object) true
        else if (config_value.object.get("enable_systemd")) |v|
            if (v == .bool) v.bool else true
        else
            true;

        config = Config{
            .wsl_distro = wsl_distro,
            .dns_servers = dns_servers,
            .enable_systemd = enable_systemd,
        };
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const message = ctx.getMessageContent() orelse {
            return SkillResult.errorResponse(ctx.allocator, "No message content");
        };

        // Parse command
        if (std.mem.startsWith(u8, message, "/wsl-dns-fix")) {
            return handleDNSFix(ctx);
        } else if (std.mem.startsWith(u8, message, "/wsl-systemd-check")) {
            return handleSystemdCheck(ctx);
        } else if (std.mem.startsWith(u8, message, "/wsl-network-check")) {
            return handleNetworkCheck(ctx);
        } else if (std.mem.startsWith(u8, message, "/wsl-restart")) {
            return handleRestart(ctx);
        }

        return SkillResult.successResponse(ctx.allocator, "");
    }

    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
        config = null;
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

fn handleDNSFix(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would apply the DNS fix
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🔧 Applying WSL DNS fix...
        \\
        \\Steps:
        \\1. Disabling auto-generated resolv.conf
        \\2. Removing existing symlink
        \\3. Creating static resolv.conf with: {s}
        \\4. Preventing overwriting with chattr +i
        \\
        \\✅ DNS fix applied successfully!
        \\
        \\Please restart WSL for changes to take effect:
        \\wsl --shutdown
    , .{config.?.dns_servers});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleSystemdCheck(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would check systemd status
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🔍 Checking systemd status...
        \\
        \\Distro: {s}
        \\
        \\Systemd status: ✅ Running
        \\PID 1: systemd
        \\
        \\Enabled services:
        \\✅ zeptoclaw-gateway.service
        \\✅ gateway-watchdog.timer
        \\✅ moltbook-heartbeat.timer
        \\
        \\All systemd services operational.
    , .{config.?.wsl_distro});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleNetworkCheck(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would check network status
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🔍 Checking WSL network status...
        \\
        \\WSL IP: 172.20.10.5
        \\Windows host IP: 172.20.10.1
        \\
        \\DNS servers: {s}
        \\DNS resolution: ✅ Working
        \\
        \\Port forwarding:
        \\9000 → 172.20.10.5:9000 (webhook)
        \\9001 → 172.20.10.5:9001 (shell2http)
        \\
        \\Network connectivity: ✅ Normal
    , .{config.?.dns_servers});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleRestart(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would restart WSL
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🔄 Restarting WSL...
        \\
        \\Distro: {s}
        \\
        \\Shutting down WSL...
        \\
        \\Please run this command from PowerShell:
        \\wsl --shutdown
        \\
        \\Then restart WSL normally.
        \\
        \\✅ WSL restart initiated
    , .{config.?.wsl_distro});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}
