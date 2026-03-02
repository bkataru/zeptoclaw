const std = @import("std");
const validator = @import("validator.zig");
const ZeptoClawConfig = @import("migration_config.zig").ZeptoClawConfig;

pub fn createValidTestConfig(allocator: std.mem.Allocator) !ZeptoClawConfig {
    return .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, "test_key"),
        .primary_model = try allocator.dupe(u8, "qwen/qwen3.5-397b-a17b"),
        .fallback_models = try allocator.alloc([]const u8, 0),
        .image_model = try allocator.dupe(u8, "stable-diffusion-3.5-large"),
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .nim_timeout_ms = 30000,
        .gateway_port = 18789,
        .gateway_mode = try allocator.dupe(u8, "local"),
        .gateway_bind = try allocator.dupe(u8, "lan"),
        .gateway_auth_token = null,
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = try allocator.dupe(u8, "/tmp/zeptoclaw"),
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = try allocator.dupe(u8, "/home/user/zeptoclaw/sessions/whatsapp"),
        .whatsapp_dm_policy = try allocator.dupe(u8, "pairing"),
        .whatsapp_allow_from = try allocator.alloc([]const u8, 0),
        .whatsapp_group_policy = try allocator.dupe(u8, "allowlist"),
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = true,
        .whatsapp_group_require_mention = true,
        .whatsapp_group_activation_commands = try allocator.alloc([]const u8, 0),
    };
}

test "validate: valid config passes" {
    const allocator = std.testing.allocator;
    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();

    const result = validator.validate(cfg);
    try std.testing.expect(!result.hasErrors());
}

test "validate: missing API key" {
    const allocator = std.testing.allocator;
    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();
    allocator.free(cfg.api_key);
    cfg.api_key = "";

    const result = validator.validate(cfg);
    try std.testing.expect(result.missing_api_key);
}

test "validate: missing primary model" {
    const allocator = std.testing.allocator;
    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();
    allocator.free(cfg.primary_model);
    cfg.primary_model = "";

    const result = validator.validate(cfg);
    try std.testing.expect(result.missing_primary_model);
}

test "validate: invalid gateway port - zero" {
    const allocator = std.testing.allocator;
    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();
    cfg.gateway_port = 0;

    const result = validator.validate(cfg);
    try std.testing.expect(result.invalid_gateway_port);
}

test "validate: invalid gateway port - too high" {
    const allocator = std.testing.allocator;
    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();
    cfg.gateway_port = 65536;

    const result = validator.validate(cfg);
    try std.testing.expect(result.invalid_gateway_port);
}

test "validate: valid gateway port boundaries" {
    const allocator = std.testing.allocator;

    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();
    cfg.gateway_port = 1;
    var result = validator.validate(cfg);
    try std.testing.expect(!result.invalid_gateway_port);

    cfg.gateway_port = 65535;
    result = validator.validate(cfg);
    try std.testing.expect(!result.invalid_gateway_port);
}

test "validate: invalid timeout - zero" {
    const allocator = std.testing.allocator;
    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();
    cfg.nim_timeout_ms = 0;

    const result = validator.validate(cfg);
    try std.testing.expect(result.invalid_timeout);
}

test "validate: invalid temperature - below zero" {
    const allocator = std.testing.allocator;
    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();
    cfg.temperature = -0.1;

    const result = validator.validate(cfg);
    try std.testing.expect(result.invalid_temperature);
}

test "validate: invalid temperature - above 2.0" {
    const allocator = std.testing.allocator;
    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();
    cfg.temperature = 2.1;

    const result = validator.validate(cfg);
    try std.testing.expect(result.invalid_temperature);
}

test "validate: valid temperature boundaries" {
    const allocator = std.testing.allocator;

    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();
    cfg.temperature = 0.0;
    var result = validator.validate(cfg);
    try std.testing.expect(!result.invalid_temperature);

    cfg.temperature = 2.0;
    result = validator.validate(cfg);
    try std.testing.expect(!result.invalid_temperature);
}

test "validate: invalid max iterations - zero" {
    const allocator = std.testing.allocator;
    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();
    cfg.max_iterations = 0;

    const result = validator.validate(cfg);
    try std.testing.expect(result.invalid_max_iterations);
}

test "validate: invalid max tokens - zero" {
    const allocator = std.testing.allocator;
    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();
    cfg.max_tokens = 0;

    const result = validator.validate(cfg);
    try std.testing.expect(result.invalid_max_tokens);
}

test "validate: invalid workspace - empty" {
    const allocator = std.testing.allocator;
    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();
    allocator.free(cfg.workspace);
    cfg.workspace = "";

    const result = validator.validate(cfg);
    try std.testing.expect(result.invalid_workspace);
}

test "validate: invalid whatsapp media max mb - zero" {
    const allocator = std.testing.allocator;
    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();
    cfg.whatsapp_media_max_mb = 0;

    const result = validator.validate(cfg);
    try std.testing.expect(result.invalid_whatsapp_media_max_mb);
}

test "validate: invalid whatsapp debounce ms - too low" {
    const allocator = std.testing.allocator;
    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();
    cfg.whatsapp_debounce_ms = 50; // Should be 0 or >= 100

    const result = validator.validate(cfg);
    try std.testing.expect(result.invalid_whatsapp_debounce_ms);
}

test "validate: multiple errors are collected" {
    const allocator = std.testing.allocator;
    var cfg = try createValidTestConfig(allocator);
    defer cfg.deinit();

    allocator.free(cfg.api_key);
    cfg.api_key = "";
    cfg.gateway_port = 0;
    cfg.temperature = 3.0;
    cfg.nim_timeout_ms = 0;
    allocator.free(cfg.workspace);
    cfg.workspace = "";
    cfg.max_concurrent = 0;

    const result = validator.validate(cfg);

    try std.testing.expect(result.missing_api_key);
    try std.testing.expect(result.invalid_gateway_port);
    try std.testing.expect(result.invalid_temperature);
    try std.testing.expect(result.invalid_timeout);
    try std.testing.expect(result.invalid_workspace);
    try std.testing.expect(result.invalid_max_concurrent);
}

test "ValidationResult: hasErrors and errorCount" {
    var result: validator.ValidationResult = .{};
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(result.errorCount() == 0);

    result.missing_api_key = true;
    result.invalid_gateway_port = true;

    try std.testing.expect(result.hasErrors());
    try std.testing.expect(result.errorCount() == 2);
}
