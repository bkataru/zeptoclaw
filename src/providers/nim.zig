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

    pub fn chatCompletion(self: *NIMClient, request: types.ChatCompletionRequest) !types.ChatCompletionResponse {
        // Build request body
        var body_buf: std.ArrayList(u8) = .{};
        defer body_buf.deinit(self.allocator);
        
        var stringify: std.json.Stringify = .{ .writer = body_buf.writer(self.allocator) };
        try stringify.write(std.json.Value{ .object = try requestToMap(request, self.allocator) });
        
        // Make HTTP request
        var header_buf: [1024]u8 = undefined;
        var req = try self.client.open(.POST, std.Uri.parse(BASE_URL), .{
            .server_header_buffer = &header_buf,
            .extra_headers = &.{
                .{ .name = "Authorization", .value = "Bearer " ++ self.api_key },
                .{ .name = "Content-Type", .value = "application/json" },
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
        
        // Read response
        const response_body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(response_body);
        
        // Parse JSON response
        const parsed = try std.json.parseFromSlice(types.ChatCompletionResponse, self.allocator, response_body, .{});
        return parsed.value;
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

test "NIMClient initialization" {
    const allocator = std.testing.allocator;
    const cfg = config_module.Config{
        .nim_api_key = "test-key",
        .nim_model = "test-model",
    };
    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();
    
    try std.testing.expectEqualStrings("test-key", client.api_key);
    try std.testing.expectEqualStrings("test-model", client.model);
}
