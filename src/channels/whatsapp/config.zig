const std = @import("std");
const types = @import("types.zig");

/// Load WhatsApp configuration from ZeptoClaw config
pub fn loadFromZeptoConfig(allocator: std.mem.Allocator, zepto_config: anytype) !types.WhatsAppConfig {
    // Parse DM policy
    const dm_policy = if (std.mem.eql(u8, zepto_config.whatsapp_dm_policy, "allowlist"))
        types.DmPolicy.allowlist
    else if (std.mem.eql(u8, zepto_config.whatsapp_dm_policy, "pairing"))
        types.DmPolicy.pairing
    else if (std.mem.eql(u8, zepto_config.whatsapp_dm_policy, "open"))
        types.DmPolicy.open
    else if (std.mem.eql(u8, zepto_config.whatsapp_dm_policy, "disabled"))
        types.DmPolicy.disabled
    else
        return error.InvalidDmPolicy;

    // Parse group policy
    const group_policy = if (std.mem.eql(u8, zepto_config.whatsapp_group_policy, "allowlist"))
        types.GroupPolicy.allowlist
    else if (std.mem.eql(u8, zepto_config.whatsapp_group_policy, "open"))
        types.GroupPolicy.open
    else if (std.mem.eql(u8, zepto_config.whatsapp_group_policy, "disabled"))
        types.GroupPolicy.disabled
    else
        return error.InvalidGroupPolicy;

    // Duplicate allow_from list
    var allow_from = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    for (zepto_config.whatsapp_allow_from) |item| {
        try allow_from.append(try allocator.dupe(u8, item));
    }

    // Duplicate group_activation_commands list
    var group_activation_commands = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    for (zepto_config.whatsapp_group_activation_commands) |item| {
        try group_activation_commands.append(try allocator.dupe(u8, item));
    }

    return types.WhatsAppConfig{
        .allocator = allocator,
        .enabled = zepto_config.whatsapp_enabled,
        .auth_dir = try allocator.dupe(u8, zepto_config.whatsapp_auth_dir),
        .dm_policy = dm_policy,
        .allow_from = allow_from,
        .group_policy = group_policy,
        .media_max_mb = zepto_config.whatsapp_media_max_mb,
        .debounce_ms = zepto_config.whatsapp_debounce_ms,
        .send_read_receipts = zepto_config.whatsapp_send_read_receipts,
        .group_require_mention = zepto_config.whatsapp_group_require_mention,
        .group_activation_commands = group_activation_commands,
    };
}

test "loadFromZeptoConfig with pairing policy" {
    const allocator = std.testing.allocator;

    // Create a mock ZeptoClaw config
    const MockZeptoConfig = struct {
        whatsapp_enabled: bool = true,
        whatsapp_auth_dir: []const u8 = "/tmp/whatsapp",
        whatsapp_dm_policy: []const u8 = "pairing",
        whatsapp_allow_from: [][]const u8 = &.{},
        whatsapp_group_policy: []const u8 = "allowlist",
        whatsapp_media_max_mb: u32 = 50,
        whatsapp_debounce_ms: u32 = 0,
        whatsapp_send_read_receipts: bool = true,
        whatsapp_group_require_mention: bool = true,
        whatsapp_group_activation_commands: [][]const u8 = &.{"/start"},
    };

    const mock_config = MockZeptoConfig{};
    const whatsapp_config = try loadFromZeptoConfig(allocator, mock_config);
    defer whatsapp_config.deinit();

    try std.testing.expectEqual(true, whatsapp_config.enabled);
    try std.testing.expectEqual(types.DmPolicy.pairing, whatsapp_config.dm_policy);
    try std.testing.expectEqual(types.GroupPolicy.allowlist, whatsapp_config.group_policy);
    try std.testing.expectEqual(@as(u32, 50), whatsapp_config.media_max_mb);
}

test "loadFromZeptoConfig with invalid dm policy" {
    const allocator = std.testing.allocator;

    const MockZeptoConfig = struct {
        whatsapp_enabled: bool = true,
        whatsapp_auth_dir: []const u8 = "/tmp/whatsapp",
        whatsapp_dm_policy: []const u8 = "invalid",
        whatsapp_allow_from: [][]const u8 = &.{},
        whatsapp_group_policy: []const u8 = "allowlist",
        whatsapp_media_max_mb: u32 = 50,
        whatsapp_debounce_ms: u32 = 0,
        whatsapp_send_read_receipts: bool = true,
        whatsapp_group_require_mention: bool = true,
        whatsapp_group_activation_commands: [][]const u8 = &.{"/start"},
    };

    const mock_config = MockZeptoConfig{};
    const result = loadFromZeptoConfig(allocator, mock_config);
    try std.testing.expectError(error.InvalidDmPolicy, result);
}
