const std = @import("std");
const types = @import("types.zig");
const config_module = @import("../config.zig");


pub const NIMClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    client: std.http.Client,

    const BASE_URL = "https://integrate.api.nvidia.com/v1/chat/completions";

    pub fn init(allocator: std.mem.Allocator, cfg: config_module.Config) NIMClient {
        return .{
            .allocator = allocator,
            .api_key = cfg.nim_api_key,
            .model = cfg.nim_model,
            .client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *NIMClient) void {
        self.client.deinit();
    }

    /// Send chat completion request and return response
    pub fn chat(self: *NIMClient, messages: []types.Message) types.ProviderError!types.ChatCompletionResponse {
        // Build request body as JSON string
        var out = std.io.Writer.Allocating.init(self.allocator);
        defer out.deinit();

        var stringifier = std.json.Stringify{
            .writer = &out.writer,
            .options = .{},
        };

        stringifier.beginObject() catch |err| return switch (err) {
            error.WriteFailed => types.ProviderError.Network,
        };
        stringifier.objectField("model") catch |err| return switch (err) {
            error.WriteFailed => types.ProviderError.Network,
        };
        stringifier.write(self.model) catch |err| return switch (err) {
            error.WriteFailed => types.ProviderError.Network,
        };

        // Add messages
        stringifier.objectField("messages") catch |err| return switch (err) {
            error.WriteFailed => types.ProviderError.Network,
        };
        stringifier.beginArray() catch |err| return switch (err) {
            error.WriteFailed => types.ProviderError.Network,
        };
        for (messages) |msg| {
            stringifier.beginObject() catch |err| return switch (err) {
                error.WriteFailed => types.ProviderError.Network,
            };
            stringifier.objectField("role") catch |err| return switch (err) {
                error.WriteFailed => types.ProviderError.Network,
            };
            stringifier.write(msg.role.toString()) catch |err| return switch (err) {
                error.WriteFailed => types.ProviderError.Network,
            };
            if (msg.content) |content| {
                stringifier.objectField("content") catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.write(content) catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
            }
            stringifier.endObject() catch |err| return switch (err) {
                error.WriteFailed => types.ProviderError.Network,
            };
        }
        stringifier.endArray() catch |err| return switch (err) {
            error.WriteFailed => types.ProviderError.Network,
        };
        stringifier.endObject() catch |err| return switch (err) {
            error.WriteFailed => types.ProviderError.Network,
        };

        const body = out.written();

        // Build Authorization header value
        var auth_buf = std.ArrayList(u8){};
        defer auth_buf.deinit(self.allocator);
        auth_buf.writer(self.allocator).writeAll("Bearer ") catch return types.ProviderError.Network;
        auth_buf.writer(self.allocator).writeAll(self.api_key) catch return types.ProviderError.Network;

        // Make HTTP request
        const uri = std.Uri.parse(BASE_URL) catch return types.ProviderError.Network;
        var req = self.client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_buf.items },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return types.ProviderError.Network;
        defer req.deinit();

        // Send body
        req.sendBodyComplete(body) catch return types.ProviderError.Network;

        // Receive response head
        var redirect_buffer: [1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch return types.ProviderError.Network;
        // Check response status
        if (response.head.status != .ok) {
            return switch (response.head.status) {
                .unauthorized => types.ProviderError.Auth,
                .too_many_requests => types.ProviderError.RateLimit,
                else => types.ProviderError.InvalidResponse,
            };
        }

        // Read response body
        var transfer_buffer: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buffer);

        // Read all remaining bytes from response
        const response_bytes = reader.allocRemaining(self.allocator, .limited(1024 * 1024)) catch return types.ProviderError.Network;
        defer self.allocator.free(response_bytes);

        // Parse JSON response
        var parsed = std.json.parseFromSlice(types.ChatCompletionResponse, self.allocator, response_bytes, .{}) catch return types.ProviderError.InvalidResponse;
        defer parsed.deinit();
        return parsed.value;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const TestConfig = config_module.Config;

test "NIMClient initialization" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .nim_api_key = "test-key",
        .nim_model = "test-model",
    };
    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
    try std.testing.expectEqualStrings("test-model", client.model);
}

test "NIMClient BASE_URL constant" {
    // Verify the URL is correctly set to NVIDIA NIM endpoint
    try std.testing.expectEqualStrings("https://integrate.api.nvidia.com/v1/chat/completions", NIMClient.BASE_URL);
}

test "NIMClient deinit does not crash" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .nim_api_key = "test-key",
        .nim_model = "test-model",
    };
    var client = NIMClient.init(allocator, cfg);
    client.deinit();
}

test "NIMClient handles empty API key" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .nim_api_key = "",
        .nim_model = "test-model",
    };
    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    try std.testing.expectEqualStrings("", client.api_key);
}

test "NIMClient model name flexibility" {
    const allocator = std.testing.allocator;
    
    // Test with various model names
    const models = [_][]const u8{
        "qwen/qwen3.5-397b-a17b",
        "meta/llama3-70b-instruct",
        "mistralai/mixtral-8x7b-instruct-v0.1",
        "",
    };

    for (models) |model_name| {
        const cfg = TestConfig{
            .nim_api_key = "test-key",
            .nim_model = model_name,
        };
        var client = NIMClient.init(allocator, cfg);
        defer client.deinit();
        
        try std.testing.expectEqualStrings(model_name, client.model);
    }
}
