const std = @import("std");
const types = @import("types.zig");
const config_module = @import("../config.zig");
const compat = @import("../compat.zig");




/// NIM client for NVIDIA NIM API.
/// Memory: NIMClient owns its internal `std.http.Client`; caller must call `deinit()` to free. `api_key`/`model`/`base_url` are borrowed and not freed by deinit.
fn sleepMs(ms: u64) void {
    var left = ms;
    while (left > 0) {
        const chunk: u64 = @min(left, 1000);
        const sec: i64 = @intCast(chunk / 1000);
        const nsec: i64 = @intCast((chunk % 1000) * 1_000_000);
        _ = std.c.nanosleep(&.{ .sec = sec, .nsec = nsec }, null);
        left -= chunk;
    }
}

/// NVIDIA integrate.api is 40 requests/minute. Failures slow us down; successes speed us back up.
var g_nim_pace_mu: std.Io.Mutex = .init;
var g_nim_last_s: i64 = 0;
var g_nim_min_gap_s: i64 = 2;
var g_nim_backoff_s: u64 = 2;
const NIM_MIN_GAP_S: i64 = 2;
const NIM_BACKOFF_MIN_S: u64 = 2;
const NIM_BACKOFF_MAX_S: u64 = 180;

pub fn nextBackoff(current: u64) u64 {
    const doubled = if (current > NIM_BACKOFF_MAX_S / 2) NIM_BACKOFF_MAX_S else current * 2;
    return @max(NIM_BACKOFF_MIN_S, @min(NIM_BACKOFF_MAX_S, doubled));
}

pub fn decayBackoff(current: u64) u64 {
    const half = current / 2;
    return if (half < NIM_BACKOFF_MIN_S) NIM_BACKOFF_MIN_S else half;
}

fn jitterMs(base_s: u64) u64 {
    var n: u8 = 0;
    compat.fillRandom(std.mem.asBytes(&n));
    const extra = (base_s * 1000 * @as(u64, n)) / (4 * 255);
    return base_s * 1000 + extra;
}

/// Wait after a failed NVIDIA call. Doubles the backoff (capped). Does not give up.
pub fn sleepAfterFailure() void {
    if (@import("builtin").is_test) return;
    var wait_s: u64 = NIM_BACKOFF_MIN_S;
    g_nim_pace_mu.lock(compat.getIo()) catch {
        wait_s = g_nim_backoff_s;
        g_nim_backoff_s = nextBackoff(g_nim_backoff_s);
        std.log.warn("[nim] backing off {d}s then retrying", .{wait_s});
        sleepMs(jitterMs(wait_s));
        return;
    };
    wait_s = g_nim_backoff_s;
    g_nim_min_gap_s = @intCast(@min(@as(u64, 60), wait_s));
    g_nim_backoff_s = nextBackoff(g_nim_backoff_s);
    g_nim_pace_mu.unlock(compat.getIo());
    std.log.warn("[nim] backing off {d}s (next {d}s) then retrying; turn is not dropped", .{ wait_s, g_nim_backoff_s });
    sleepMs(jitterMs(wait_s));
}

/// After a successful NVIDIA call, speed the gap back toward normal.
pub fn noteSuccess() void {
    g_nim_pace_mu.lock(compat.getIo()) catch return;
    defer g_nim_pace_mu.unlock(compat.getIo());
    g_nim_backoff_s = decayBackoff(g_nim_backoff_s);
    g_nim_min_gap_s = @intCast(@max(NIM_MIN_GAP_S, @as(i64, @intCast(g_nim_backoff_s))));
    if (g_nim_backoff_s <= NIM_BACKOFF_MIN_S) g_nim_min_gap_s = NIM_MIN_GAP_S;
}

fn paceForRpm() void {
    var wait_ms: u64 = 0;
    g_nim_pace_mu.lock(compat.getIo()) catch return;
    const now = compat.timestamp();
    if (g_nim_last_s != 0) {
        const elapsed = now - g_nim_last_s;
        const gap = g_nim_min_gap_s;
        if (elapsed < gap) wait_ms = @intCast((gap - elapsed) * 1000);
    }
    g_nim_pace_mu.unlock(compat.getIo());
    if (wait_ms > 0) sleepMs(wait_ms);
    g_nim_pace_mu.lock(compat.getIo()) catch return;
    g_nim_last_s = compat.timestamp();
    g_nim_pace_mu.unlock(compat.getIo());
}

pub const NIMClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    timeout_ms: u32,
    client: std.http.Client,
    const DEFAULT_BASE_URL = "https://integrate.api.nvidia.com/v1/chat/completions";

    /// Memory: Caller owns returned NIMClient; call `deinit()` to free http.Client resources.
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
    /// Initialize with a specific model ID
    /// Memory: Caller owns returned NIMClient; call `deinit()` to free http.Client resources.
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
    /// Initialize with custom base URL
    /// Memory: Caller owns returned NIMClient; call `deinit()` to free http.Client resources. Caller retains ownership of `api_key`/`model_id`/`base_url`.
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

/// Memory: Frees http.Client resources; does not free borrowed `api_key`/`model`/`base_url`.
pub fn deinit(self: *NIMClient) void {
    self.client.deinit();
}

    /// Change the model being used
    /// Memory: Does not allocate; borrows `model_id` until next setModel call.
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
    /// Memory: Caller owns returned ChatCompletionResponse; call `response.deinit(allocator)` to free id/model/choices. Messages slice is borrowed.
    pub fn chat(self: *NIMClient, messages: []types.Message) types.ProviderError!types.ChatCompletionResponse {
        return self.chatWithTools(messages, null);
    }

    /// Memory: Caller owns returned ChatCompletionResponse. `messages` and `tools` are borrowed.
    pub fn chatWithTools(self: *NIMClient, messages: []types.Message, tools: ?[]const types.ToolDefinition) types.ProviderError!types.ChatCompletionResponse {
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
            if (msg.image_data_url) |url| {
                stringifier.objectField("content") catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.beginArray() catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.beginObject() catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.objectField("type") catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.write("text") catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.objectField("text") catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.write(msg.content orelse "") catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.endObject() catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.beginObject() catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.objectField("type") catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.write("image_url") catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.objectField("image_url") catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.beginObject() catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.objectField("url") catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.write(url) catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.endObject() catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.endObject() catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.endArray() catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
            } else if (msg.content) |content| {
                stringifier.objectField("content") catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.write(content) catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
            }
            if (msg.tool_call_id) |tcid| {
                stringifier.objectField("tool_call_id") catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.write(tcid) catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
            }
            if (msg.tool_calls) |calls| {
                stringifier.objectField("tool_calls") catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.beginArray() catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                for (calls) |call| {
                    stringifier.beginObject() catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.objectField("id") catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.write(call.id) catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.objectField("type") catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.write(call.@"type") catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.objectField("function") catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.beginObject() catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.objectField("name") catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.write(call.function.name) catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.objectField("arguments") catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.write(call.function.arguments) catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.endObject() catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.endObject() catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                }
                stringifier.endArray() catch |err| return switch (err) {
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
        if (tools) |tool_list| {
            if (tool_list.len > 0) {
                stringifier.objectField("tools") catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                stringifier.beginArray() catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
                for (tool_list) |t| {
                    stringifier.beginObject() catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.objectField("type") catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.write("function") catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.objectField("function") catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.beginObject() catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.objectField("name") catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.write(t.name) catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.objectField("description") catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.write(t.description) catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.objectField("parameters") catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.write(t.parameters) catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.endObject() catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                    stringifier.endObject() catch |err| return switch (err) {
                        error.WriteFailed => types.ProviderError.Network,
                    };
                }
                stringifier.endArray() catch |err| return switch (err) {
                    error.WriteFailed => types.ProviderError.Network,
                };
            }
        }
        stringifier.endObject() catch |err| return switch (err) {
            error.WriteFailed => types.ProviderError.Network,
        };

        const body = out.written();

        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            paceForRpm();
            if (self.postOnce(body)) |resp| {
                noteSuccess();
                return resp;
            } else |err| switch (err) {
                error.RateLimit, error.Timeout, error.Network => {
                    std.log.warn("[nim] {} attempt {d}; will keep retrying until this request succeeds", .{ err, attempt + 1 });
                    sleepAfterFailure();
                },
                else => return err,
            }
        }
    }

    fn postOnce(self: *NIMClient, body: []const u8) types.ProviderError!types.ChatCompletionResponse {
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
        const body_mut = self.allocator.dupe(u8, body) catch return types.ProviderError.Network;
        defer self.allocator.free(body_mut);
        req.sendBodyComplete(body_mut) catch {
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
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
    .workspace = "/tmp/test",
    .max_concurrent = 4,
    .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
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
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
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
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
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
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
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
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
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
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
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
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
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
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
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
            .gateway_control_ui_enabled = true,
            .gateway_allow_insecure_auth = false,
            .workspace = "/tmp/test",
            .max_concurrent = 4,
            .source = .default,
            .whatsapp_enabled = false,
            .whatsapp_auth_dir = "/tmp",
            .whatsapp_dm_policy = "pairing",
            .whatsapp_allow_from = &.{},
            .whatsapp_group_policy = "allowlist",
            .whatsapp_media_max_mb = 50,
            .whatsapp_debounce_ms = 0,
            .whatsapp_send_read_receipts = false,
            .whatsapp_group_require_mention = false,
            .whatsapp_group_activation_commands = &.{},
        };
        var client = NIMClient.init(allocator, cfg);
        defer client.deinit();

        try std.testing.expectEqualStrings(model_name, client.model);
    }
}

test "nim backoff doubles then caps" {
    try std.testing.expectEqual(@as(u64, 4), nextBackoff(2));
    try std.testing.expectEqual(@as(u64, 8), nextBackoff(4));
    try std.testing.expectEqual(@as(u64, 180), nextBackoff(128));
    try std.testing.expectEqual(@as(u64, 180), nextBackoff(180));
}

test "nim backoff decays toward minimum" {
    try std.testing.expectEqual(@as(u64, 90), decayBackoff(180));
    try std.testing.expectEqual(@as(u64, 2), decayBackoff(3));
    try std.testing.expectEqual(@as(u64, 2), decayBackoff(2));
}
