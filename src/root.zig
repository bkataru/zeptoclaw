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
};

// Agent modules
pub const agent = struct {
    pub const message = @import("agent/message.zig");
    pub const loop = @import("agent/loop.zig");
    pub const tools = @import("agent/tools.zig");
};

// Channels
pub const channels = struct {
    pub const cli = @import("channels/cli.zig");
    pub const session = @import("channels/session.zig");
    pub const whatsapp = struct {
        pub const types = @import("channels/whatsapp/types.zig");
        pub const WhatsAppChannel = @import("channels/whatsapp/whatsapp_channel.zig").WhatsAppChannel;
        pub const WhatsAppSession = @import("channels/whatsapp/session.zig").WhatsAppSession;
        pub const InboundProcessor = @import("channels/whatsapp/inbound.zig").InboundProcessor;
        pub const OutboundProcessor = @import("channels/whatsapp/outbound.zig").OutboundProcessor;
        pub const AccessControl = @import("channels/whatsapp/access_control.zig").AccessControl;
    };
};
// Configuration
pub const config = @import("config.zig");

// Autonomous Agent
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
// Services
// BACKWARDS COMPATIBILITY (old test functions)
// ============================================================================

pub fn printAnotherMessage(writer: *std.fs.File) !void {
    try writer.writeAll("Run `zig build test` to run the tests.\n");
    try writer.writeAll("\n");
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
