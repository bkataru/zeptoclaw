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
};

// Configuration
pub const config = @import("config.zig");

// ============================================================================
// BACKWARDS COMPATIBILITY (old test functions)
// ============================================================================

pub fn printAnotherMessage(writer: *std.Io.Writer) !void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
    try writer.flush();
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
