const std = @import("std");
const zeptoclaw = @import("zeptoclaw");
const Config = zeptoclaw.config.Config;
const NIMClient = zeptoclaw.providers.nim.NIMClient;
const Message = zeptoclaw.providers.types.Message;

// Helper to create a Config with all required fields for testing
fn makeTestConfig(allocator: std.mem.Allocator, api_key: []const u8, model: []const u8) !Config {
    // Allocate required string fields (will be freed by Config.deinit)
    const image_model = try allocator.dupe(u8, "");
    const gateway_mode = try allocator.dupe(u8, "local");
    const gateway_bind = try allocator.dupe(u8, "lan");
    const workspace = try allocator.dupe(u8, "/tmp/zeptoclaw_test");
    const fallback_models = try allocator.alloc([]const u8, 0);

    return Config{
        .allocator = allocator,
        .nim_api_key = api_key,
        .nim_model = model,
        .max_iterations = 1,
        .temperature = 0.0,
        .max_tokens = 1,
        .fallback_models = fallback_models,
        .image_model = image_model,
        .gateway_port = 18789,
        .gateway_mode = gateway_mode,
        .gateway_bind = gateway_bind,
        .gateway_auth_token = null,
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = workspace,
        .max_concurrent = 4,
        .source = .default,
    };
}

test "integration: NIMClient chat completion" {
    const allocator = std.testing.allocator;

    // Get API key from env, skip if not set
    const api_key = std.process.getEnvVarOwned(allocator, "NVIDIA_API_KEY") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            std.debug.print("\n[SKIP] NVIDIA_API_KEY not set, skipping integration test\n", .{});
            return;
        }
        return err;
    };
    // Get model from env or default
    const model_opt = std.process.getEnvVarOwned(allocator, "NVIDIA_MODEL") catch null;
    const model = if (model_opt) |m| m else try allocator.dupe(u8, "qwen/qwen3.5-397b-a17b");

    var cfg = try makeTestConfig(allocator, api_key, model);
    defer cfg.deinit();

    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    // Create test messages
    var messages = try allocator.alloc(Message, 2);
    defer allocator.free(messages);

    messages[0] = Message{
        .role = .system,
        .content = "You are a helpful assistant. Respond with one word only.",
        .tool_call_id = null,
        .tool_calls = null,
    };
    messages[1] = Message{
        .role = .user,
        .content = "Say hello.",
        .tool_call_id = null,
        .tool_calls = null,
    };

    // Make API call
    var response = try client.chat(messages);
    defer response.deinit(allocator);

    // Verify response structure
    try std.testing.expect(response.choices.len > 0);
    try std.testing.expect(response.id.len > 0);
    try std.testing.expect(response.model.len > 0);
    try std.testing.expect(response.created > 0);
    try std.testing.expect(response.usage.total_tokens > 0);

    std.debug.print("\n[OK] Integration test passed - received response from {s}\n", .{response.model});
}

test "integration: NIMClient auth error handling" {
    const allocator = std.testing.allocator;

    // Use an invalid API key
    const invalid_key = try allocator.dupe(u8, "invalid-key");
    const model = try allocator.dupe(u8, "qwen/qwen3.5-397b-a17b");

    var cfg = try makeTestConfig(allocator, invalid_key, model);
    defer cfg.deinit();

    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    var messages = try allocator.alloc(Message, 1);
    defer allocator.free(messages);

    messages[0] = Message{
        .role = .user,
        .content = "Test",
        .tool_call_id = null,
        .tool_calls = null,
    };

    // Should fail with auth error
    const result = client.chat(messages);
    if (result) |_| {
        try std.testing.expect(false); // Should have failed
    } else |err| {
        try std.testing.expect(err == zeptoclaw.providers.types.ProviderError.Auth);
        std.debug.print("\n[OK] Auth error correctly caught\n", .{});
    }
}

test "integration: NIMClient message with tool calls" {
    const allocator = std.testing.allocator;

    const api_key = std.process.getEnvVarOwned(allocator, "NVIDIA_API_KEY") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            std.debug.print("\n[SKIP] NVIDIA_API_KEY not set, skipping tool call test\n", .{});
            return;
        }
        return err;
    };
    const model_opt = std.process.getEnvVarOwned(allocator, "NVIDIA_MODEL") catch null;
    const model = if (model_opt) |m| m else try allocator.dupe(u8, "qwen/qwen3.5-397b-a17b");

    var cfg = try makeTestConfig(allocator, api_key, model);
    defer cfg.deinit();

    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    var messages = try allocator.alloc(Message, 3);
    defer allocator.free(messages);

    messages[0] = Message{
        .role = .system,
        .content = "You are a helpful assistant with access to tools.",
        .tool_call_id = null,
        .tool_calls = null,
    };
    messages[1] = Message{
        .role = .user,
        .content = "What's the weather in London?",
        .tool_call_id = null,
        .tool_calls = null,
    };
    messages[2] = Message{
        .role = .assistant,
        .content = null,
        .tool_call_id = null,
        .tool_calls = null,
    };

    var response = try client.chat(messages);
    defer response.deinit(allocator);

    try std.testing.expect(response.choices.len > 0);
    std.debug.print("\n[OK] Tool call test passed\n", .{});
}
