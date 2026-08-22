//! OpenClaw compat adapter — zero runtime dependency.
//! Reads legacy openclaw.json / sessions / creds / group-policies while
//! keeping zeptoclaw as the canonical source.
//! Nothing here imports npm `openclaw`; it only bridges file formats/paths/APIs.

const std = @import("std");
const compat = @import("../compat.zig");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Path constants
// ---------------------------------------------------------------------------

pub const primary_config_paths = [_][]const u8{
    "/home/user/.zeptoclaw/config.json",
    "./zeptoclaw.json",
    "./config.json",
};

pub const legacy_config_paths = [_][]const u8{
    "/home/user/.openclaw/openclaw.json",
    "/home/user/.openclaw/workspace/openclaw.json",
};

// Ordered: try primary first, then legacy (read-only fallback).
pub fn defaultConfigCandidates() []const []const u8 {
    return &(primary_config_paths ++ legacy_config_paths);
}

fn dirExists(path: []const u8) bool {
    const io = compat.getIo();
    var d = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

// Workspace: ~/.zeptoclaw/workspace first (symlink to OpenClaw workspace on this host),
// then ~/.openclaw/workspace. Both should be the bkataru/barvis git tree.
pub fn resolveWorkspaceDir(allocator: Allocator) ![]const u8 {
    const home = compat.getEnvVarOwned(allocator, "HOME") catch try allocator.dupe(u8, "/home/user");
    defer allocator.free(home);
    const zepto_ws = try std.fmt.allocPrint(allocator, "{s}/.zeptoclaw/workspace", .{home});
    if (dirExists(zepto_ws)) return zepto_ws;
    allocator.free(zepto_ws);
    const legacy_ws = try std.fmt.allocPrint(allocator, "{s}/.openclaw/workspace", .{home});
    if (dirExists(legacy_ws)) return legacy_ws;
    return legacy_ws;
}

// Return the first existing config file, or null if none.
pub fn findExistingConfig(allocator: Allocator) ?[]const u8 {
    const candidates = primary_config_paths ++ legacy_config_paths;
    for (candidates) |p| {
        const cwd = compat.cwd();
        if (cwd.openFile(p, .{})) |f| {
            f.close(cwd.io);
            // dupe so caller can free
            return allocator.dupe(u8, p) catch null;
        } else |_| continue;
    }
    return null;
}

// Home dir helper (owned)
pub fn getHomeDir(allocator: Allocator) ![]const u8 {
    return compat.getEnvVarOwned(allocator, "HOME");
}

// ---------------------------------------------------------------------------
// Service compat
// ---------------------------------------------------------------------------

pub const primary_gateway_service = "zeptoclaw-gateway.service";
pub const legacy_gateway_service = "openclaw-gateway.service";

/// Returns command argv to query gateway logs, trying zeptoclaw first then legacy.
pub fn gatewayServiceVariants() [2][]const u8 {
    return .{ primary_gateway_service, legacy_gateway_service };
}

/// Build systemctl --user argv for gateway logs; caller frees? static strings.
pub fn journalGatewayArgs(service: []const u8) [6][]const u8 {
    return .{ "/usr/bin/journalctl", "--user", "-u", service, "-n", "50" };
}

// ---------------------------------------------------------------------------
// Credentials / sessions / group policies paths (compat)
// ---------------------------------------------------------------------------

pub fn legacyCredentialsDir(allocator: Allocator) ![]const u8 {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.openclaw/credentials", .{home});
}

pub fn primaryCredentialsDir(allocator: Allocator) ![]const u8 {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.zeptoclaw/credentials", .{home});
}

pub fn legacySessionsDir(allocator: Allocator) ![]const u8 {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.openclaw/agents/main/sessions", .{home});
}

pub fn primarySessionsDir(allocator: Allocator) ![]const u8 {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.zeptoclaw/sessions", .{home});
}

// ---------------------------------------------------------------------------
// Gateway API compat — legacy endpoint aliases
// ---------------------------------------------------------------------------

/// Legacy openclaw gateway mapped /health -> /gateway/health etc.
/// Zeptoclaw exposes canonical + legacy aliases so old clients keep working.
pub fn isLegacyGatewayAlias(path: []const u8) bool {
    return std.mem.eql(u8, path, "/gateway/health") or
        std.mem.eql(u8, path, "/gateway/state") or
        std.mem.eql(u8, path, "/gateway/status");
}

pub fn canonicalizeGatewayPath(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "/gateway/health")) return "/health";
    if (std.mem.eql(u8, path, "/gateway/state")) return "/state";
    if (std.mem.eql(u8, path, "/gateway/status")) return "/status";
    return path;
}

// ---------------------------------------------------------------------------
// Config ingest helpers
// ---------------------------------------------------------------------------

/// Normalize an E.164-like entry by stripping non-digits, preserving leading '+'.
/// Used to compare allowFrom entries in openclaw.json vs runtime.
pub fn normalizeE164Digits(allocator: Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, s.len + 1);
    errdefer out.deinit(allocator);
    for (s) |c| if (c >= '0' and c <= '9') try out.append(allocator, c);
    // For compat compare we compare digits only; caller may re-add '+'.
    return out.toOwnedSlice(allocator);
}

/// Check whether a normalized digits string appears in allowFrom (digits-only compare).
pub fn isAllowFromMatch(allow_from: []const []const u8, candidate_e164: []const u8) bool {
    var cand_digits: [32]u8 = undefined;
    var cand_len: usize = 0;
    for (candidate_e164) |c| if (c >= '0' and c <= '9') {
        if (cand_len < cand_digits.len) { cand_digits[cand_len] = c; cand_len += 1; }
    };
    for (allow_from) |entry| {
        var e_len: usize = 0;
        var e_digits: [32]u8 = undefined;
        for (entry) |c| if (c >= '0' and c <= '9') {
            if (e_len < e_digits.len) { e_digits[e_len] = c; e_len += 1; }
        };
        if (e_len == cand_len and std.mem.eql(u8, e_digits[0..e_len], cand_digits[0..cand_len])) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isLegacyGatewayAlias" {
    try std.testing.expect(isLegacyGatewayAlias("/gateway/health"));
    try std.testing.expectEqualStrings("/health", canonicalizeGatewayPath("/gateway/health"));
    try std.testing.expect(!isLegacyGatewayAlias("/health"));
}

test "isAllowFromMatch digits-only" {
    const allow = &[_][]const u8{ "+15555550101", "+15555550102" };
    try std.testing.expect(isAllowFromMatch(allow, "+15555550101"));
    try std.testing.expect(isAllowFromMatch(allow, "15555550101"));
    try std.testing.expect(isAllowFromMatch(allow, "+91 9674746069"));
    try std.testing.expect(!isAllowFromMatch(allow, "+919999999999"));
}
