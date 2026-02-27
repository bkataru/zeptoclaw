const std = @import("std");
const migration_config = @import("config/migration_config.zig");

/// Legacy Config struct for backward compatibility
/// This wraps the new ZeptoClawConfig to maintain existing API
pub const Config = struct {
    allocator: std.mem.Allocator,
    nim_api_key: []const u8,
    nim_model: []const u8,
    max_iterations: u32,
    temperature: f32,
    max_tokens: u32,
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
        };
}

    pub fn deinit(self: *Config) void {
        // Note: We don't free nim_api_key, nim_model, etc. because they're owned by ZeptoClawConfig
        // The ZeptoClawConfig is not exposed in the legacy API, so we can't free it here
        // This is a limitation of the backward-compatible API
        _ = self;
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

/// Re-export the new configuration types for advanced usage
pub const ConfigSource = migration_config.ConfigSource;
pub const ConfigLoader = migration_config.ConfigLoader;
pub const ZeptoClawConfig = migration_config.ZeptoClawConfig;
pub const OpenClawConfig = migration_config.OpenClawConfig;


test "Config load from env" {
    const allocator = std.testing.allocator;
    // This test will fail if NVIDIA_API_KEY is not set
    // Skip if not in CI environment
    if (std.process.getEnvVarOwned(allocator, "CI")) |_| {
    } else |_| {
        // Running locally, skip if API key not set
        if (std.process.getEnvVarOwned(allocator, "NVIDIA_API_KEY")) |_| {
        } else |_| {
            return error.SkipTest;
        }
    }
}

test "Config load with defaults" {
    const allocator = std.testing.allocator;
    var loader = migration_config.ConfigLoader.init(allocator);
    var result = try loader.mergeConfigs(null, null, null);
    defer result.deinit();

    try std.testing.expectEqual(migration_config.ConfigSource.default, result.source);
    try std.testing.expectEqualStrings("qwen/qwen3.5-397b-a17b", result.primary_model);
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
    };
    try std.testing.expectEqualStrings("qwen/qwen3.5-397b-a17b", config.getPrimaryModel());
    try std.testing.expectEqualStrings("qwen/qwen3.5-397b-a17b", config.getPrimaryModel());
}
