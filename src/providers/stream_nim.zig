const std = @import("std");
const types = @import("types.zig");
const config_module = @import("../config.zig");

pub const StreamNIMClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    client: std.http.Client,
    cancel_token: ?*std.atomic.Value(bool),

    const BASE_URL = "https://integrate.api.nvidia.com/v1/chat/completions";

    pub fn init(allocator: std.mem.Allocator, cfg: config_module.Config) StreamNIMClient {
        return .{
            .allocator = allocator,
            .api_key = cfg.nim_api_key,
            .model = cfg.nim_model,
            .client = std.http.Client{ .allocator = allocator },
            .cancel_token = null,
        };
    }

    pub fn deinit(self: *StreamNIMClient) void {
        self.client.deinit();
    }

    pub fn setCancelToken(self: *StreamNIMClient, token: *std.atomic.Value(bool)) void {
        self.cancel_token = token;
    }

    pub fn streamCompletion(
        self: *StreamNIMClient,
        request: types.ChatCompletionRequest,
        onChunk: *const fn ([]const u8) anyerror!void,
    ) !void {
        // Build request body with streaming enabled
        var body_buf: std.ArrayList(u8) = .{};
        defer body_buf.deinit(self.allocator);

        var stringify: std.json.Stringify = .{ .writer = body_buf.writer(self.allocator) };
        var req_map = try requestToMap(request, self.allocator);
        try req_map.put("stream", std.json.Value{ .bool = true });
        try stringify.write(std.json.Value{ .object = req_map });

        // Make HTTP request
        var header_buf: [1024]u8 = undefined;
        var req = try self.client.open(.POST, std.Uri.parse(BASE_URL), .{
            .server_header_buffer = &header_buf,
            .extra_headers = &.{
                .{ .name = "Authorization", .value = "Bearer " ++ self.api_key },
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Accept", .value = "text/event-stream" },
            },
        });
        defer req.deinit();

        try req.send(body_buf.items);
        try req.finish();
        try req.wait();

        if (req.response.status != .ok) {
            return switch (req.response.status) {
                .unauthorized => error.Auth,
                .too_many_requests => error.RateLimit,
                else => error.InvalidResponse,
            };
        }

        // Read and parse SSE stream
        var reader = req.reader();
        var line_buf: [4096]u8 = undefined;
        var content_buf = std.ArrayList(u8).init(self.allocator);
        defer content_buf.deinit();

        while (true) {
            // Check cancel token
            if (self.cancel_token) |token| {
                if (token.load(.seq) == true) {
                    return error.Cancelled;
                }
            }

            // Read line
            const line = try reader.readUntilDelimiter(&line_buf, '\n');
            if (line.len == 0) break;

            // Parse SSE data
            if (std.mem.startsWith(u8, line, "data: ")) {
                const data = line["data: ".len..];
                
                // Check for [DONE] marker
                if (std.mem.eql(u8, data, "[DONE]")) {
                    break;
                }

                // Parse JSON chunk
                const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
                defer parsed.deinit();

                // Extract delta content
                if (parsed.value.object) |obj| {
                    if (obj.get("choices")) |choices| {
                        if (choices.array) |choice_arr| {
                            if (choice_arr.items.len > 0) {
                                const choice = choice_arr.items[0];
                                if (choice.object) |choice_obj| {
                                    if (choice_obj.get("delta")) |delta_val| {
                                        if (delta_val.object) |delta_obj| {
                                            if (delta_obj.get("content")) |content_val| {
                                                if (content_val.string) |content| {
                                                    try onChunk(content);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    fn requestToMap(request: types.ChatCompletionRequest, allocator: std.mem.Allocator) !std.json.ObjectMap {
        var map = std.json.ObjectMap.init(allocator);
        errdefer map.deinit();

        try map.put("model", std.json.Value{ .string = request.model });

        // Convert messages to JSON array
        var messages_arr = std.json.Array.init(allocator);
        errdefer messages_arr.deinit();

        for (request.messages) |msg| {
            var msg_map = std.json.ObjectMap.init(allocator);
            try msg_map.put("role", std.json.Value{ .string = msg.role.toString() });
            if (msg.content) |c| {
                try msg_map.put("content", std.json.Value{ .string = c });
            }
            try messages_arr.append(std.json.Value{ .object = msg_map });
        }
        try map.put("messages", std.json.Value{ .array = messages_arr });

        if (request.temperature) |temp| {
            try map.put("temperature", std.json.Value{ .float = @as(f64, @floatCast(temp)) });
        }
        if (request.max_tokens) |max| {
            try map.put("max_tokens", std.json.Value{ .integer = @as(i64, @intCast(max)) });
        }

        return map;
    }
};

test "StreamNIMClient initialization" {
    const allocator = std.testing.allocator;
    const cfg = config_module.Config{
        .nim_api_key = "test-key",
        .nim_model = "test-model",
    };
    var client = StreamNIMClient.init(allocator, cfg);
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
    try std.testing.expectEqualStrings("test-model", client.model);
}
