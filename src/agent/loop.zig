const std = @import("std");
const types = @import("../providers/types.zig");
const nim = @import("../providers/nim.zig");
const message = @import("./message.zig");
const tools = @import("./tools.zig");

pub const Agent = struct {
    allocator: std.mem.Allocator,
    client: nim.NIMClient,
    registry: tools.ToolRegistry,
    max_iterations: u32 = 10,

    pub fn init(allocator: std.mem.Allocator, cfg: anytype) !Agent {
        var client = nim.NIMClient.init(allocator, cfg);
        errdefer client.deinit();
        
        var registry = tools.ToolRegistry.init(allocator);
        try registry.register(.{
            .name = "echo",
            .description = "Echo back the input message",
            .parameters = std.json.Value{ .object = std.json.ObjectMap.init(allocator) },
            .handler = tools.echoTool,
        });
        try registry.register(.{
            .name = "current_time",
            .description = "Get the current Unix timestamp",
            .parameters = std.json.Value{ .object = std.json.ObjectMap.init(allocator) },
            .handler = tools.currentTimeTool,
        });
        return .{
            .allocator = allocator,
            .client = client,
            .registry = registry,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.registry.deinit();
        self.client.deinit();
    }

    pub fn run(self: *Agent, initial_user_message: []const u8) ![]const u8 {
        var messages = std.ArrayList(types.Message).init(self.allocator);
        defer {
            for (messages.items) |*msg| msg.deinit(self.allocator);
            messages.deinit(self.allocator);
        }

        // Add initial user message
        const user_msg = try message.userMessage(self.allocator, initial_user_message);
        try messages.append(user_msg);

        var iteration: u32 = 0;
        while (iteration < self.max_iterations) : (iteration += 1) {
            // Get tool definitions for this request
            const tool_defs = try self.registry.toToolDefinitions();
            defer self.allocator.free(tool_defs);

            // Build chat completion request
            const request = types.ChatCompletionRequest{
                .model = self.client.model,
                .messages = messages.items,
                .tools = tool_defs,
                .temperature = 0.7,
                .max_tokens = 1024,
            };

            // Call NIM API
            const response = try self.client.chatCompletion(request);

            // Get assistant's message
            const assistant_msg = response.choices[0].message;

            // Add assistant message to conversation
            const assistant_copy = try assistant_msg.dupe(self.allocator);
            try messages.append(assistant_copy);

            // Check for tool calls
            if (assistant_msg.hasToolCalls()) {
                for (assistant_msg.tool_calls.?) |*tool_call| {
                    // Execute tool
                    const result = self.registry.execute(
                        tool_call.function.name,
                        tool_call.function.arguments,
                    ) catch |err| {
                        try self.allocator.dupe(u8, @errorName(err));
                    };

                    // Add tool result as a message
                    const tool_msg = try message.toolResultMessage(
                        self.allocator,
                        tool_call.id,
                        result,
                    );
                    try messages.append(tool_msg);
                }
            } else {
                // No more tool calls, return the final response
                if (assistant_msg.content) |content| {
                    return try self.allocator.dupe(u8, content);
                }
                return error.NoContent;
            }
        }

        return error.MaxIterationsExceeded;
    }
};

test "Agent initialization" {
    const allocator = std.testing.allocator;
    const cfg = struct {
        nim_api_key: []const u8 = "test",
        nim_model: []const u8 = "test",
    }{};
    
    var agent = try Agent.init(allocator, cfg);
    defer agent.deinit();
    
    try std.testing.expect(agent.registry.get("echo") != null);
    try std.testing.expect(agent.registry.get("current_time") != null);
}
