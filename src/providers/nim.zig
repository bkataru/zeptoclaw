const std = @import("std");
const types = @import("types.zig");
const config_module = @import("../config.zig");
const compat = @import("../compat.zig");




pub const NIMClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    timeout_ms: u32,
    client: std.http.Client,
    const DEFAULT_BASE_URL = "https://integrate.api.nvidia.com/v1/chat/completions";

    pub fn init(allocator: std.mem.Allocator, cfg: config_module.Config) NIMClient {
        return .{
            .allocator = allocator,
            .api_key = cfg.nim_api_key,
            .model = cfg.nim_model,
            .base_url = DEFAULT_BASE_URL,
            .timeout_ms = 30000,
            .client = std.http.Client{ .allocator = allocator, .io = compat.getIo() },
        };
    }

    /// Initialize with a specific model ID
    pub fn initWithModel(allocator: std.mem.Allocator, cfg: config_module.Config, model_id: []const u8) NIMClient {
        return .{
            .allocator = allocator,
            .api_key = cfg.nim_api_key,
            .model = model_id,
            .base_url = DEFAULT_BASE_URL,
            .timeout_ms = 30000,
            .client = std.http.Client{ .allocator = allocator, .io = compat.getIo() },
        };
    }

    /// Initialize with custom base URL
    pub fn initWithBaseUrl(allocator: std.mem.Allocator, api_key: []const u8, model_id: []const u8, base_url: []const u8) NIMClient {
        return .{
            .allocator = allocator,
            .api_key = api_key,
            .model = model_id,
            .base_url = base_url,
            .timeout_ms = 30000,
            .client = std.http.Client{ .allocator = allocator, .io = compat.getIo() },
        };
    }

pub fn deinit(self: *NIMClient) void {
    self.client.deinit();
}

    /// Change the model being used
    pub fn setModel(self: *NIMClient, model_id: []const u8) void {
        self.model = model_id;
    }

    /// Get the current model ID
    pub fn getModel(self: *const NIMClient) []const u8 {
        return self.model;
    }

    /// Get the API key
    pub fn getApiKey(self: *const NIMClient) []const u8 {
        return self.api_key;
    }

    /// Get the base URL
    pub fn getBaseUrl(self: *const NIMClient) []const u8 {
        return self.base_url;
    }

    /// Send chat completion request and return response
    /// Send chat completion request and return response
    pub fn chat(self: *NIMClient, messages: []types.Message) types.ProviderError!types.ChatCompletionResponse {
        // Build request body as JSON string
        var out = std.Io.Writer.Allocating.init(self.allocator);
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
        const start_ns = compat.timestamp(); // fallback
        const overall_timeout_ns = @as(u64, self.timeout_ms) * std.time.ns_per_ms;

        // Build Authorization header value
        var auth_buf: std.ArrayList(u8) = .empty;
        defer auth_buf.deinit(self.allocator);
        auth_buf.appendSlice(self.allocator, "Bearer ") catch return types.ProviderError.Network;
        auth_buf.appendSlice(self.allocator, self.api_key) catch return types.ProviderError.Network;

        // Make HTTP request
        // Make HTTP request
        const uri = std.Uri.parse(self.base_url) catch return types.ProviderError.Network;
        var req = self.client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_buf.items },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return types.ProviderError.Network;
        defer req.deinit();
        // Enforce request timeout via timer checks below
        // Send body
        // Send body with timeout enforcement
        req.sendBodyComplete(body) catch {
            if (@as(u64, @intCast(compat.timestamp() - start_ns)) * std.time.ns_per_s > overall_timeout_ns) {
                return types.ProviderError.Timeout;
            }
            return types.ProviderError.Network;
        };
        if ((@as(u64, @intCast(compat.timestamp() - start_ns)) * @as(u64, std.time.ns_per_s)) > overall_timeout_ns) {
            return types.ProviderError.Timeout;
        }

        // Receive response head
        var redirect_buffer: [1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch {
            if (@as(u64, @intCast(compat.timestamp() - start_ns)) * std.time.ns_per_s > overall_timeout_ns) {
                return types.ProviderError.Timeout;
            }
            return types.ProviderError.Network;
        };
        if ((@as(u64, @intCast(compat.timestamp() - start_ns)) * @as(u64, std.time.ns_per_s)) > overall_timeout_ns) {
            return types.ProviderError.Timeout;
        }
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
        const response_bytes = reader.allocRemaining(self.allocator, .limited(1024 * 1024)) catch {
            if (@as(u64, @intCast(compat.timestamp() - start_ns)) * std.time.ns_per_s > overall_timeout_ns) {
                return types.ProviderError.Timeout;
            }
            return types.ProviderError.Network;
        };
        if ((@as(u64, @intCast(compat.timestamp() - start_ns)) * @as(u64, std.time.ns_per_s)) > overall_timeout_ns) {
            return types.ProviderError.Timeout;
        }
        defer self.allocator.free(response_bytes);
        // Parse JSON response
        var parsed = std.json.parseFromSlice(types.ChatCompletionResponse, self.allocator, response_bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return types.ProviderError.InvalidResponse;
        defer parsed.deinit();
        // Deep copy out of arena before defer frees it — ChatCompletionResponse owns allocs
        const val = parsed.value;
        const duped_id = self.allocator.dupe(u8, val.id) catch return types.ProviderError.InvalidResponse;
        errdefer self.allocator.free(duped_id);
        const duped_model = self.allocator.dupe(u8, val.model) catch return types.ProviderError.InvalidResponse;
        errdefer self.allocator.free(duped_model);
        const duped_choices = self.allocator.alloc(types.Choice, val.choices.len) catch return types.ProviderError.InvalidResponse;
        for (val.choices, 0..) |ch, i| {
            var c = ch.message.dupe(self.allocator) catch return types.ProviderError.InvalidResponse;
            errdefer c.deinit(self.allocator);
            duped_choices[i] = .{ .index = ch.index, .message = c, .finish_reason = if (ch.finish_reason) |fr| self.allocator.dupe(u8, fr) catch return types.ProviderError.InvalidResponse else null };
        }
        const usage = val.usage;
        return .{ .id = duped_id, .model = duped_model, .choices = duped_choices, .created = val.created, .usage = usage };
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const TestConfig = config_module.Config;

test "NIMClient initialization" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "test-key",
        .nim_model = "test-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .fallback_models = &.{},
        .image_model = "test-image-model",
    .gateway_port = 18789,
    .gateway_mode = "local",
    .gateway_bind = "lan",
    .gateway_auth_token = null,
    .workspace = "/tmp/test",
    .max_concurrent = 4,
    .source = .default,
};
var client = NIMClient.init(allocator, cfg);
defer client.deinit();

try std.testing.expectEqualStrings("test-key", client.api_key);
try std.testing.expectEqualStrings("test-model", client.model);
}

test "NIMClient initWithModel" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "test-key",
        .nim_model = "default-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .fallback_models = &.{},
        .image_model = "test-image-model",
        .gateway_port = 18789,
        .gateway_mode = "local",
        .gateway_bind = "lan",
        .gateway_auth_token = null,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
    };
    var client = NIMClient.initWithModel(allocator, cfg, "custom-model");
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
    try std.testing.expectEqualStrings("custom-model", client.model);
}

test "NIMClient initWithBaseUrl" {
    const allocator = std.testing.allocator;
    var client = NIMClient.initWithBaseUrl(
        allocator,
        "test-key",
        "test-model",
        "https://custom.api.example.com/v1/chat/completions",
    );
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
    try std.testing.expectEqualStrings("test-model", client.model);
    try std.testing.expectEqualStrings("https://custom.api.example.com/v1/chat/completions", client.base_url);
}

test "NIMClient setModel" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "test-key",
        .nim_model = "initial-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .fallback_models = &.{},
        .image_model = "test-image-model",
        .gateway_port = 18789,
        .gateway_mode = "local",
        .gateway_bind = "lan",
        .gateway_auth_token = null,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
    };
    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    try std.testing.expectEqualStrings("initial-model", client.getModel());

    client.setModel("new-model");
    try std.testing.expectEqualStrings("new-model", client.getModel());
}

test "NIMClient getModel" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "test-key",
        .nim_model = "test-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .fallback_models = &.{},
        .image_model = "test-image-model",
        .gateway_port = 18789,
        .gateway_mode = "local",
        .gateway_bind = "lan",
        .gateway_auth_token = null,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
    };
    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    try std.testing.expectEqualStrings("test-model", client.getModel());
}

test "NIMClient getApiKey" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "secret-key",
        .nim_model = "test-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .fallback_models = &.{},
        .image_model = "test-image-model",
        .gateway_port = 18789,
        .gateway_mode = "local",
        .gateway_bind = "lan",
        .gateway_auth_token = null,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
    };
    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    try std.testing.expectEqualStrings("secret-key", client.getApiKey());
}

test "NIMClient getBaseUrl" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "test-key",
        .nim_model = "test-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .fallback_models = &.{},
        .image_model = "test-image-model",
        .gateway_port = 18789,
        .gateway_mode = "local",
        .gateway_bind = "lan",
        .gateway_auth_token = null,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
    };
    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    try std.testing.expectEqualStrings(NIMClient.DEFAULT_BASE_URL, client.getBaseUrl());
    // Verify the URL is correctly set to NVIDIA NIM endpoint
    // Verify the URL is correctly set to NVIDIA NIM endpoint
    try std.testing.expectEqualStrings("https://integrate.api.nvidia.com/v1/chat/completions", NIMClient.DEFAULT_BASE_URL);
}

test "NIMClient deinit does not crash" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "test-key",
        .nim_model = "test-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .fallback_models = &.{},
        .image_model = "test-image-model",
        .gateway_port = 18789,
        .gateway_mode = "local",
        .gateway_bind = "lan",
        .gateway_auth_token = null,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
    };
    var client = NIMClient.init(allocator, cfg);
    client.deinit();
}

test "NIMClient handles empty API key" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "",
        .nim_model = "test-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .fallback_models = &.{},
        .image_model = "test-image-model",
        .gateway_port = 18789,
        .gateway_mode = "local",
        .gateway_bind = "lan",
        .gateway_auth_token = null,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
    };
    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    try std.testing.expectEqualStrings("", client.api_key);
}

test "NIMClient model name flexibility" {
    const allocator = std.testing.allocator;

    // Test with various model names
    const models = [_][]const u8{
        "thinkingmachines/inkling",
        "meta/llama3-70b-instruct",
        "mistralai/mixtral-8x7b-instruct-v0.1",
        "",
    };

    for (models) |model_name| {
        const cfg = TestConfig{
            .allocator = allocator,
            .nim_api_key = "test-key",
            .nim_model = model_name,
            .max_iterations = 10,
            .temperature = 0.7,
            .max_tokens = 1024,
            .fallback_models = &.{},
            .image_model = "test-image-model",
            .gateway_port = 18789,
            .gateway_mode = "local",
            .gateway_bind = "lan",
            .gateway_auth_token = null,
            .workspace = "/tmp/test",
            .max_concurrent = 4,
            .source = .default,
        };
        var client = NIMClient.init(allocator, cfg);
        defer client.deinit();

        try std.testing.expectEqualStrings(model_name, client.model);
    }
}
