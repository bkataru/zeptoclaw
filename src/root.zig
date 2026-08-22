//! Zeptoclaw Library Root
//! The world's tiniest AI agent framework. Zig-powered, NVIDIA NIM-native.
const std = @import("std");

// ============================================================================
// PUBLIC API EXPORTS
// ============================================================================

// Provider types (OpenAI-compatible)
pub const providers = struct {
    pub const types = @import("providers/types.zig");
    pub const nim = @import("providers/nim.zig");
    pub const health_tracker = @import("providers/health_tracker.zig");
    pub const provider_pool = @import("providers/provider_pool.zig");
    pub const fallback_router = @import("providers/fallback_router.zig");
};

// Agent modules
pub const agent = struct {
    pub const message = @import("agent/message.zig");
    pub const loop = @import("agent/loop.zig");
    pub const tools = @import("agent/tools.zig");
    pub const core_tools = @import("agent/core_tools.zig");
    pub const transcript = @import("agent/transcript.zig");
    pub const cron = @import("agent/cron.zig");
};

// Channels
pub const channels = struct {
    pub const cli = @import("channels/cli.zig");
    pub const cli_utils = @import("channels/cli_utils.zig");
    pub const session = @import("channels/session.zig");
    pub const input = @import("channels/input.zig");
    pub const whatsapp = struct {
        pub const types = @import("channels/whatsapp/types.zig");
        pub const config = @import("channels/whatsapp/config.zig");
        pub const WhatsAppChannel = @import("channels/whatsapp/whatsapp_channel.zig").WhatsAppChannel;
        pub const WhatsAppSession = @import("channels/whatsapp/session.zig").WhatsAppSession;
        pub const InboundProcessor = @import("channels/whatsapp/inbound.zig").InboundProcessor;
        pub const OutboundProcessor = @import("channels/whatsapp/outbound.zig").OutboundProcessor;
        pub const engagement = @import("channels/whatsapp/engagement.zig");
        pub const AccessControl = @import("channels/whatsapp/access_control.zig").AccessControl;
        pub const native = struct {
            pub const tokens = @import("channels/whatsapp/native/tokens.zig");
            pub const binary = @import("channels/whatsapp/native/binary.zig");
            pub const noise = @import("channels/whatsapp/native/noise.zig");
            pub const noise_crypto = @import("channels/whatsapp/native/noise_crypto.zig");
            pub const noise_handshake = @import("channels/whatsapp/native/noise_handshake.zig");
            pub const ws_client = @import("channels/whatsapp/native/ws_client.zig");
            pub const socket = @import("channels/whatsapp/native/socket.zig");
            pub const pair = @import("channels/whatsapp/native/pair.zig");
            pub const client = @import("channels/whatsapp/native/client.zig");
            pub const store = @import("channels/whatsapp/native/store.zig");
            pub const store_impl = @import("channels/whatsapp/native/store/store.zig");
            pub const store_schema = @import("channels/whatsapp/native/store/schema.zig");
            pub const appstate = @import("channels/whatsapp/native/appstate.zig");
            pub const proto = @import("channels/whatsapp/native/proto.zig");
            pub const framesocket = @import("channels/whatsapp/native/framesocket.zig");
            pub const ws_upgrade = @import("channels/whatsapp/native/ws_upgrade.zig");
            pub const client_native = @import("channels/whatsapp/native/client_native.zig");
        };
    };
};
// Configuration
pub const config = @import("config.zig");
pub const validator = @import("config/validator.zig");
pub const compat = @import("compat.zig");
pub const openclaw_compat = @import("openclaw_compat/openclaw.zig");

// Autonomous Agent
pub const autonomous = struct {
    pub const types = @import("autonomous/types.zig");
    pub const state_store = @import("autonomous/state_store.zig");
    pub const moltbook_client = @import("autonomous/moltbook_client.zig");
    pub const rate_limiter = @import("autonomous/rate_limiter.zig");
    pub const agent_framework = @import("autonomous/agent_framework.zig");
};

// Gateway
pub const gateway = struct {
    pub const token_auth = @import("gateway/token_auth.zig");
    pub const session_store = @import("gateway/session_store.zig");
    pub const http_server = @import("gateway/http_server.zig");
    pub const control_ui = @import("gateway/control_ui.zig");
};

// Skills
pub const skills = struct {
    pub const skill_sdk = @import("skills/skill_sdk.zig");
    pub const execution_context = @import("skills/execution_context.zig");
    pub const git_workflow = @import("skills/git_workflow/skill.zig");
    pub const types = @import("skills/types.zig");
    pub const triggers = @import("skills/triggers.zig");
    pub const skill_registry = @import("skills/skill_registry.zig");
    pub const skill_loader = @import("skills/skill_loader.zig");
};

pub fn printAnotherMessage(writer: *std.Io.File) !void {
    try writer.writeStreamingAll(compat.getIo(), "Run `zig build test` to run the tests.\n");
    try writer.writeStreamingAll(compat.getIo(), "\n");
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test "providers.types module loads" {
    _ = providers.types;
}

test "config module loads" {
    _ = config;
}

test "agent.message module loads" {
    _ = agent.message;
}

comptime {
    if (@import("builtin").is_test) {
        _ = @import("channels/whatsapp/whatsapp_channel_test.zig");
        _ = @import("skills/git_workflow/git_workflow_test.zig");
        _ = @import("config/validator_test.zig");
        _ = @import("config/config_loader_test.zig");
        _ = providers.health_tracker;
        _ = providers.provider_pool;
        _ = providers.fallback_router;
        _ = agent.core_tools;
        _ = agent.loop;
        _ = agent.cron;
        _ = agent.tools;
        _ = agent.transcript;
        _ = channels.cli_utils;
        _ = channels.input;
        _ = channels.cli;
        _ = channels.session;
        _ = skills.types;
        _ = skills.triggers;
        _ = skills.skill_registry;
        _ = skills.skill_loader;
        _ = skills.execution_context;
        _ = openclaw_compat;
        _ = autonomous.types;
        _ = autonomous.rate_limiter;
        _ = autonomous.moltbook_client;
        _ = autonomous.agent_framework;
        _ = gateway.token_auth;
        _ = gateway.session_store;
        _ = channels.whatsapp.native.noise_crypto;
        _ = channels.whatsapp.native.noise_handshake;
        _ = channels.whatsapp.native.ws_client;
        _ = channels.whatsapp.native.store_impl;
        _ = channels.whatsapp.native.store_schema;
    }
}
