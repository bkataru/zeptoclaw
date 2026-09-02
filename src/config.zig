const std = @import("std");
const migration_config = @import("config/migration_config.zig");
const compat = @import("compat.zig");


/// Legacy Config struct for backward compatibility
/// This wraps the new ZeptoClawConfig to maintain existing API
pub const Config = struct {
    allocator: std.mem.Allocator,
    nim_api_key: []const u8,
    nim_model: []const u8,
    max_iterations: u32,
    temperature: f32,
    max_tokens: u32,
    nim_timeout_ms: u32 = 30000,
    // New fields for multi-provider support
    fallback_models: [][]const u8,
    image_model: []const u8,
    gateway_port: u32,
    gateway_mode: []const u8,
    gateway_bind: []const u8,
    gateway_auth_token: ?[]const u8,
    gateway_control_ui_enabled: bool,
    gateway_allow_insecure_auth: bool,
    workspace: []const u8,
    max_concurrent: u32,
    source: migration_config.ConfigSource,
    // WhatsApp configuration
    whatsapp_enabled: bool,
    whatsapp_auth_dir: []const u8,
    whatsapp_dm_policy: []const u8,
    whatsapp_native: bool = false,

    whatsapp_allow_from: [][]const u8,
    whatsapp_group_policy: []const u8,
    whatsapp_media_max_mb: u32,
    whatsapp_debounce_ms: u32,
    whatsapp_send_read_receipts: bool,
    whatsapp_group_require_mention: bool,
    whatsapp_group_activation_commands: [][]const u8,

    /// Load configuration from all sources with priority: CLI > env > file > defaults
    pub fn load(allocator: std.mem.Allocator) !Config {
        var loader = migration_config.ConfigLoader.init(allocator);
        const zepto_config = try loader.load(null);

        return .{
            .allocator = allocator,
            .nim_api_key = zepto_config.api_key,
            .nim_model = zepto_config.primary_model,
            .max_iterations = zepto_config.max_iterations,
            .temperature = zepto_config.temperature,
            .max_tokens = zepto_config.max_tokens,
.nim_timeout_ms = zepto_config.nim_timeout_ms,
            .fallback_models = zepto_config.fallback_models,
            .image_model = zepto_config.image_model,
            .gateway_port = zepto_config.gateway_port,
            .gateway_mode = zepto_config.gateway_mode,
            .gateway_bind = zepto_config.gateway_bind,
            .gateway_auth_token = zepto_config.gateway_auth_token,
            .gateway_control_ui_enabled = zepto_config.gateway_control_ui_enabled,
            .gateway_allow_insecure_auth = zepto_config.gateway_allow_insecure_auth,
            .workspace = zepto_config.workspace,
            .max_concurrent = zepto_config.max_concurrent,
            .source = zepto_config.source,
.whatsapp_enabled = zepto_config.whatsapp_enabled,
            .whatsapp_auth_dir = zepto_config.whatsapp_auth_dir,
            .whatsapp_dm_policy = zepto_config.whatsapp_dm_policy,
            .whatsapp_native = resolveWhatsAppNative(allocator, zepto_config.whatsapp_native),

            .whatsapp_allow_from = zepto_config.whatsapp_allow_from,
            .whatsapp_group_policy = zepto_config.whatsapp_group_policy,
            .whatsapp_media_max_mb = zepto_config.whatsapp_media_max_mb,
            .whatsapp_debounce_ms = zepto_config.whatsapp_debounce_ms,
            .whatsapp_send_read_receipts = zepto_config.whatsapp_send_read_receipts,
            .whatsapp_group_require_mention = zepto_config.whatsapp_group_require_mention,
            .whatsapp_group_activation_commands = zepto_config.whatsapp_group_activation_commands,
        };
    }

    /// Load configuration with CLI arguments
    pub fn loadWithArgs(allocator: std.mem.Allocator, args: struct {
        api_key: ?[]const u8 = null,
        model: ?[]const u8 = null,
        config_file: ?[]const u8 = null,
    }) !Config {
        var loader = migration_config.ConfigLoader.init(allocator);
        const zepto_config = try loader.load(args);

        return .{
            .allocator = allocator,
            .nim_api_key = zepto_config.api_key,
            .nim_model = zepto_config.primary_model,
            .max_iterations = zepto_config.max_iterations,
            .temperature = zepto_config.temperature,
            .max_tokens = zepto_config.max_tokens,
.nim_timeout_ms = zepto_config.nim_timeout_ms,
            .fallback_models = zepto_config.fallback_models,
            .image_model = zepto_config.image_model,
            .gateway_port = zepto_config.gateway_port,
            .gateway_mode = zepto_config.gateway_mode,
            .gateway_bind = zepto_config.gateway_bind,
            .gateway_auth_token = zepto_config.gateway_auth_token,
            .gateway_control_ui_enabled = zepto_config.gateway_control_ui_enabled,
            .gateway_allow_insecure_auth = zepto_config.gateway_allow_insecure_auth,
            .workspace = zepto_config.workspace,
            .max_concurrent = zepto_config.max_concurrent,
            .source = zepto_config.source,
.whatsapp_enabled = zepto_config.whatsapp_enabled,
            .whatsapp_auth_dir = zepto_config.whatsapp_auth_dir,
            .whatsapp_dm_policy = zepto_config.whatsapp_dm_policy,
            .whatsapp_native = resolveWhatsAppNative(allocator, zepto_config.whatsapp_native),

            .whatsapp_allow_from = zepto_config.whatsapp_allow_from,
            .whatsapp_group_policy = zepto_config.whatsapp_group_policy,
            .whatsapp_media_max_mb = zepto_config.whatsapp_media_max_mb,
            .whatsapp_debounce_ms = zepto_config.whatsapp_debounce_ms,
            .whatsapp_send_read_receipts = zepto_config.whatsapp_send_read_receipts,
            .whatsapp_group_require_mention = zepto_config.whatsapp_group_require_mention,
            .whatsapp_group_activation_commands = zepto_config.whatsapp_group_activation_commands,
        };
    }

    /// Load configuration from a specific file
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
        var loader = migration_config.ConfigLoader.init(allocator);
        const zepto_config = try loader.load(.{ .config_file = path });

        return .{
            .allocator = allocator,
            .nim_api_key = zepto_config.api_key,
            .nim_model = zepto_config.primary_model,
            .max_iterations = zepto_config.max_iterations,
            .temperature = zepto_config.temperature,
            .max_tokens = zepto_config.max_tokens,
.nim_timeout_ms = zepto_config.nim_timeout_ms,
            .fallback_models = zepto_config.fallback_models,
            .image_model = zepto_config.image_model,
            .gateway_port = zepto_config.gateway_port,
            .gateway_mode = zepto_config.gateway_mode,
            .gateway_bind = zepto_config.gateway_bind,
            .gateway_auth_token = zepto_config.gateway_auth_token,
            .gateway_control_ui_enabled = zepto_config.gateway_control_ui_enabled,
            .gateway_allow_insecure_auth = zepto_config.gateway_allow_insecure_auth,
            .workspace = zepto_config.workspace,
            .max_concurrent = zepto_config.max_concurrent,
            .source = zepto_config.source,
.whatsapp_enabled = zepto_config.whatsapp_enabled,
            .whatsapp_auth_dir = zepto_config.whatsapp_auth_dir,
            .whatsapp_dm_policy = zepto_config.whatsapp_dm_policy,
            .whatsapp_native = resolveWhatsAppNative(allocator, zepto_config.whatsapp_native),

            .whatsapp_allow_from = zepto_config.whatsapp_allow_from,
            .whatsapp_group_policy = zepto_config.whatsapp_group_policy,
            .whatsapp_media_max_mb = zepto_config.whatsapp_media_max_mb,
            .whatsapp_debounce_ms = zepto_config.whatsapp_debounce_ms,
            .whatsapp_send_read_receipts = zepto_config.whatsapp_send_read_receipts,
            .whatsapp_group_require_mention = zepto_config.whatsapp_group_require_mention,
            .whatsapp_group_activation_commands = zepto_config.whatsapp_group_activation_commands,
        };
}

    pub fn deinit(self: *Config) void {
        const a = self.allocator;
        a.free(self.nim_api_key);
        a.free(self.nim_model);
        for (self.fallback_models) |model| {
            a.free(model);
        }
        a.free(self.fallback_models);
        a.free(self.image_model);
        a.free(self.gateway_mode);
        a.free(self.gateway_bind);
        if (self.gateway_auth_token) |token| {
            a.free(token);
        }
        a.free(self.workspace);
        a.free(self.whatsapp_auth_dir);
        a.free(self.whatsapp_dm_policy);
        for (self.whatsapp_allow_from) |item| {
            a.free(item);
        }
        a.free(self.whatsapp_allow_from);
        a.free(self.whatsapp_group_policy);
        for (self.whatsapp_group_activation_commands) |item| {
            a.free(item);
        }
        a.free(self.whatsapp_group_activation_commands);
    }

    /// Get the primary model ID
    pub fn getPrimaryModel(self: *const Config) []const u8 {
        return self.nim_model;
    }

    /// Get the fallback model IDs
    pub fn getFallbackModels(self: *const Config) [][]const u8 {
        return self.fallback_models;
    }

    /// Get the image model ID
    pub fn getImageModel(self: *const Config) []const u8 {
        return self.image_model;
    }

    /// Check if configuration was loaded from a file
    pub fn isFromFile(self: *const Config) bool {
        return self.source == .file;
    }

    /// Check if configuration was loaded from environment variables
    pub fn isFromEnv(self: *const Config) bool {
        return self.source == .env;
    }

    /// Check if configuration was loaded from CLI arguments
    pub fn isFromCli(self: *const Config) bool {
        return self.source == .cli;
    }
};

fn envWhatsAppNative(allocator: std.mem.Allocator) ?bool {
    const v = compat.getEnvVarOwned(allocator, "ZEPTO_WA_NATIVE") catch return null;
    defer allocator.free(v);
    if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "TRUE") or std.mem.eql(u8, v, "yes")) return true;
    if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "FALSE") or std.mem.eql(u8, v, "no")) return false;
    return null;
}

fn nativeFlagFromJsonFile(allocator: std.mem.Allocator, path: []const u8) ?bool {
    const cwd = compat.cwd();
    const file = cwd.openFile(path, .{}) catch return null;
    defer file.close(cwd.io);
    const stat = file.stat(cwd.io) catch return null;
    const n: usize = @intCast(stat.size);
    if (n == 0 or n > 4 * 1024 * 1024) return null;
    const buf = allocator.alloc(u8, n) catch return null;
    defer allocator.free(buf);
    var reader = file.reader(cwd.io, &[_]u8{});
    reader.interface.readSliceAll(buf) catch return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, buf, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const channels = parsed.value.object.get("channels") orelse return null;
    if (channels != .object) return null;
    const wa = channels.object.get("whatsapp") orelse return null;
    if (wa != .object) return null;
    const native = wa.object.get("native") orelse return null;
    return switch (native) {
        .bool => |b| b,
        else => null,
    };
}

fn nativeFlagFromConfigFiles(allocator: std.mem.Allocator) ?bool {
    const home_rels = [_][]const u8{
        ".zeptoclaw/config.json",
        ".openclaw/openclaw.json",
        ".openclaw/workspace/openclaw.json",
    };
    for (home_rels) |rel| {
        const path = compat.homeJoin(allocator, rel) catch continue;
        defer allocator.free(path);
        if (nativeFlagFromJsonFile(allocator, path)) |b| return b;
    }
    const cwd_rels = [_][]const u8{ "./zeptoclaw.json", "./config.json" };
    for (cwd_rels) |path| {
        if (nativeFlagFromJsonFile(allocator, path)) |b| return b;
    }
    return null;
}

fn resolveWhatsAppNative(allocator: std.mem.Allocator, from_loader: bool) bool {
    if (envWhatsAppNative(allocator)) |b| return b;
    if (nativeFlagFromConfigFiles(allocator)) |b| return b;
    return from_loader;
}


/// Re-export the new configuration types for advanced usage
pub const ConfigSource = migration_config.ConfigSource;
pub const ConfigLoader = migration_config.ConfigLoader;
pub const ZeptoClawConfig = migration_config.ZeptoClawConfig;
pub const OpenClawConfig = migration_config.OpenClawConfig;


// test "Config load from env" {
//     const allocator = std.testing.allocator;
//     // This test requires NVIDIA_API_KEY to be set. Skip if not present.
//     const api_key = compat.getEnvVarOwned(allocator, "NVIDIA_API_KEY") catch |err| {
//         if (err == error.EnvironmentVariableNotFound) {
//             return error.SkipTest;
//         }
//         return err;
//     };
//     defer allocator.free(api_key);
//     if (api_key.len > 0) {
//         var config = try Config.load(allocator);
//         defer config.deinit();
//         try std.testing.expect(config.isFromEnv());
//     } else {
//         return error.SkipTest;
//     }
// }

test "Config load with defaults" {
    const allocator = std.testing.allocator;
    var loader = migration_config.ConfigLoader.init(allocator);
    var result = try loader.mergeConfigs(null, null, null);
    defer result.deinit();

    try std.testing.expectEqual(migration_config.ConfigSource.default, result.source);
    try std.testing.expectEqualStrings("nvidia/nemotron-3-ultra-550b-a55b", result.primary_model);
    try std.testing.expectEqual(@as(u32, 18789), result.gateway_port);
}

test "Config getPrimaryModel" {
    const allocator = std.testing.allocator;
    var loader = migration_config.ConfigLoader.init(allocator);
    var zepto_config = try loader.mergeConfigs(null, null, null);
    defer zepto_config.deinit();

    const config = Config{
        .allocator = allocator,
        .nim_api_key = zepto_config.api_key,
        .nim_model = zepto_config.primary_model,
        .max_iterations = zepto_config.max_iterations,
        .temperature = zepto_config.temperature,
        .max_tokens = zepto_config.max_tokens,
        .fallback_models = zepto_config.fallback_models,
        .image_model = zepto_config.image_model,
        .gateway_port = zepto_config.gateway_port,
        .gateway_mode = zepto_config.gateway_mode,
        .gateway_bind = zepto_config.gateway_bind,
        .gateway_auth_token = zepto_config.gateway_auth_token,
        .gateway_control_ui_enabled = zepto_config.gateway_control_ui_enabled,
        .gateway_allow_insecure_auth = zepto_config.gateway_allow_insecure_auth,
        .workspace = zepto_config.workspace,
        .max_concurrent = zepto_config.max_concurrent,
        .source = zepto_config.source,
        .whatsapp_enabled = zepto_config.whatsapp_enabled,
        .whatsapp_auth_dir = zepto_config.whatsapp_auth_dir,
        .whatsapp_dm_policy = zepto_config.whatsapp_dm_policy,
        .whatsapp_allow_from = zepto_config.whatsapp_allow_from,
        .whatsapp_group_policy = zepto_config.whatsapp_group_policy,
        .whatsapp_media_max_mb = zepto_config.whatsapp_media_max_mb,
        .whatsapp_debounce_ms = zepto_config.whatsapp_debounce_ms,
        .whatsapp_send_read_receipts = zepto_config.whatsapp_send_read_receipts,
        .whatsapp_group_require_mention = zepto_config.whatsapp_group_require_mention,
        .whatsapp_group_activation_commands = zepto_config.whatsapp_group_activation_commands,
    };
    try std.testing.expectEqualStrings("nvidia/nemotron-3-ultra-550b-a55b", config.getPrimaryModel());
    try std.testing.expectEqualStrings("nvidia/nemotron-3-nano-omni-30b-a3b-reasoning", config.getFallbackModels()[0]);
}
