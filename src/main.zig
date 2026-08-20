const std = @import("std");
const zeptoclaw = @import("zeptoclaw");

const NIMClient = zeptoclaw.providers.nim.NIMClient;
const Agent = zeptoclaw.agent.loop.Agent;
const Config = zeptoclaw.config.Config;
const validator = zeptoclaw.validator;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    var cfg = Config.load(allocator) catch |err| {
        std.debug.print("Configuration error: {}\n", .{err});
        return err;
    };
    defer cfg.deinit();

    // Validate configuration - convert legacy Config to view for validation
    const ZeptoClawConfig = zeptoclaw.config.ZeptoClawConfig;
    const zepto_view = ZeptoClawConfig{
        .allocator = allocator,
        .api_key = cfg.nim_api_key,
        .primary_model = cfg.nim_model,
        .fallback_models = cfg.fallback_models,
        .image_model = cfg.image_model,
        .max_iterations = cfg.max_iterations,
        .temperature = cfg.temperature,
        .max_tokens = cfg.max_tokens,
        .nim_timeout_ms = cfg.nim_timeout_ms,
        .gateway_port = cfg.gateway_port,
        .gateway_mode = cfg.gateway_mode,
        .gateway_bind = cfg.gateway_bind,
        .gateway_auth_token = cfg.gateway_auth_token,
        .gateway_control_ui_enabled = cfg.gateway_control_ui_enabled,
        .gateway_allow_insecure_auth = cfg.gateway_allow_insecure_auth,
        .workspace = cfg.workspace,
        .max_concurrent = cfg.max_concurrent,
        .source = cfg.source,
        .whatsapp_enabled = cfg.whatsapp_enabled,
        .whatsapp_auth_dir = cfg.whatsapp_auth_dir,
        .whatsapp_dm_policy = cfg.whatsapp_dm_policy,
        .whatsapp_allow_from = cfg.whatsapp_allow_from,
        .whatsapp_group_policy = cfg.whatsapp_group_policy,
        .whatsapp_media_max_mb = cfg.whatsapp_media_max_mb,
        .whatsapp_debounce_ms = cfg.whatsapp_debounce_ms,
        .whatsapp_send_read_receipts = cfg.whatsapp_send_read_receipts,
        .whatsapp_group_require_mention = cfg.whatsapp_group_require_mention,
        .whatsapp_group_activation_commands = cfg.whatsapp_group_activation_commands,
    };

    // Validate configuration
    const result = validator.validate(zepto_view);
    if (result.hasErrors()) {
        std.debug.print("Configuration validation failed with {} error(s).\n", .{result.errorCount()});
        std.process.exit(1);
    }

    // Initialize NIM client
    var nim_client = NIMClient.init(allocator, cfg);
    defer nim_client.deinit();

    // Initialize agent with NIM client
    var agent = try Agent.init(allocator, &nim_client, 50);
    defer agent.deinit();

    // Run interactive CLI session
    try zeptoclaw.channels.cli.runInteractiveSession(&agent);
}

test "main" {
    _ = main;
}
