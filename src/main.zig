const std = @import("std");
const zeptoclaw = @import("zeptoclaw");

const NIMClient = zeptoclaw.providers.nim.NIMClient;
const Agent = zeptoclaw.agent.loop.Agent;
const Config = zeptoclaw.config.Config;
const validator = zeptoclaw.validator;
const pairing = @import("channels/whatsapp/pairing.zig");
const compat = zeptoclaw.compat;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args_vec = init.minimal.args.vector;
    // args_vec[0] is exe, [1] whatsapp, [2] pair etc
    if (args_vec.len >= 3 and std.mem.eql(u8, std.mem.span(args_vec[1]), "whatsapp") and std.mem.eql(u8, std.mem.span(args_vec[2]), "pair")) {
        try pairing.runPairing(allocator);
        return;
    }
    if (args_vec.len >= 3 and std.mem.eql(u8, std.mem.span(args_vec[1]), "channels") and std.mem.eql(u8, std.mem.span(args_vec[2]), "login")) {
        try pairing.runPairing(allocator);
        return;
    }
    if (args_vec.len >= 2 and (std.mem.eql(u8, std.mem.span(args_vec[1]), "--help") or std.mem.eql(u8, std.mem.span(args_vec[1]), "-h") or std.mem.eql(u8, std.mem.span(args_vec[1]), "help"))) {
        printHelp();
        return;
    }
    if (args_vec.len >= 3 and std.mem.eql(u8, std.mem.span(args_vec[1]), "memory") and (std.mem.eql(u8, std.mem.span(args_vec[2]), "update") or std.mem.eql(u8, std.mem.span(args_vec[2]), "rewrite"))) {
        try zeptoclaw.agent.memory_update.runOnce(allocator);
        return;
    }
    if (args_vec.len >= 3 and std.mem.eql(u8, std.mem.span(args_vec[1]), "memory") and (std.mem.eql(u8, std.mem.span(args_vec[2]), "compact") or std.mem.eql(u8, std.mem.span(args_vec[2]), "compress"))) {
        try zeptoclaw.agent.memory_compact.runOnce(allocator);
        return;
    }
    if (args_vec.len >= 2 and std.mem.eql(u8, std.mem.span(args_vec[1]), "fuzz")) {
        var iters: usize = 50_000;
        if (args_vec.len >= 3) {
            iters = std.fmt.parseInt(usize, std.mem.span(args_vec[2]), 10) catch 50_000;
        }
        const seed: u64 = @intCast(@as(u64, @bitCast(@as(i64, compat.timestamp()))));
        std.debug.print("fuzz havoc iters={d} seed={d}\n", .{ iters, seed });
        zeptoclaw.fuzz_mutate.runHavoc(allocator, iters, seed);
        std.debug.print("fuzz ok\n", .{});
        return;
    }
    // Env fallback
    {
        const env_pair = compat.getEnvVarOwned(allocator, "ZEPTO_PAIR") catch "";
        if (env_pair.len > 0 and (env_pair[0] == '1' or env_pair[0] == 't')) {
            allocator.free(env_pair);
            try pairing.runPairing(allocator);
            return;
        }
        if (env_pair.len > 0) allocator.free(env_pair);
    }

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

fn printHelp() void {
    std.debug.print(
        \\ZeptoClaw — Zig-native AI agent
        \\
        \\Usage:
        \\  zeptoclaw                          Interactive CLI
        \\  zeptoclaw whatsapp pair            Pair WhatsApp (scan QR)
        \\  zeptoclaw channels login           Alias for whatsapp pair
        \\  zeptoclaw memory update            Ingest journals into MEMORY.md (30-min job; own NIM budget)
        \\  zeptoclaw memory compact           Compress MEMORY.md itself (2-hour job; own NIM budget)
        \\  zeptoclaw fuzz [iters]             Parser havoc (default 50000). No NIM, no WhatsApp.
        \\  zeptoclaw --help                   This help
        \\
        \\
    , .{});
}

test "main" {
    _ = main;
}
