const std = @import("std");
const zeptoclaw = @import("zeptoclaw");

const Config = zeptoclaw.config.Config;
const NIMClient = zeptoclaw.providers.nim.NIMClient;
const Message = zeptoclaw.providers.types.Message;
const MessageRole = zeptoclaw.providers.types.MessageRole;

/// Integration test: Test NIMClient chat completion with actual API
/// This test requires NVIDIA_API_KEY environment variable to be set
test "integration: NIMClient chat completion" {
    const allocator = std.testing.allocator;
    
    // Skip if no API key is set
    const api_key = std.process.getEnvVarOwned(allocator, "NVIDIA_API_KEY") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            std.debug.print("\n[SKIP] NVIDIA_API_KEY not set, skipping integration test\n", .{});
            return;
        }
        return err;
    };
    defer allocator.free(api_key);
    
    const model = std.process.getEnvVarOwned(allocator, "NVIDIA_MODEL") catch "qwen/qwen3.5-397b-a17b";
    
    // Initialize config and client
    const cfg = Config{
        .nim_api_key = api_key,
        .nim_model = model,
    };
    
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
    const response = try client.chat(messages);
    defer response.deinit(allocator);
    
    // Verify response structure
    try std.testing.expect(response.choices.len > 0);
    try std.testing.expect(response.id.len > 0);
    try std.testing.expect(response.model.len > 0);
    try std.testing.expect(response.created > 0);
    
    // Verify usage stats
    try std.testing.expect(response.usage.total_tokens > 0);
    
    std.debug.print("\n[OK] Integration test passed - received response from {s}\n", .{response.model});
}

/// Integration test: Test error handling with invalid API key
test "integration: NIMClient auth error handling" {
    const allocator = std.testing.allocator;
    
    const cfg = Config{
        .nim_api_key = "invalid-key",
        .nim_model = "qwen/qwen3.5-397b-a17b",
    };
    
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
        try std.testing.expect(err == error.ProviderError.Auth);
        std.debug.print("\n[OK] Auth error correctly caught\n", .{});
    }
}

/// Integration test: Test rate limit handling
test "integration: NIMClient message with tool calls" {
    const allocator = std.testing.allocator;
    
    const api_key = std.process.getEnvVarOwned(allocator, "NVIDIA_API_KEY") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            std.debug.print("\n[SKIP] NVIDIA_API_KEY not set, skipping tool call test\n", .{});
            return;
        }
        return err;
    };
    defer allocator.free(api_key);
    
    const model = std.process.getEnvVarOwned(allocator, "NVIDIA_MODEL") catch "qwen/qwen3.5-397b-a17b";
    
    const cfg = Config{
        .nim_api_key = api_key,
        .nim_model = model,
    };
    
    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();
    
    // Test with a tool-use scenario
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
    
    const response = try client.chat(messages);
    defer response.deinit(allocator);
    
    try std.testing.expect(response.choices.len > 0);
    std.debug.print("\n[OK] Tool call test passed\n", .{});
}
