const std = @import("std");

/// MessageRole represents the role of a message in a conversation
pub const MessageRole = enum {
    system,
    user,
    assistant,
    tool,

    pub fn toString(self: MessageRole) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }

    pub fn fromString(s: []const u8) ?MessageRole {
        return if (std.mem.eql(u8, s, "system"))
            .system
        else if (std.mem.eql(u8, s, "user"))
            .user
        else if (std.mem.eql(u8, s, "assistant"))
            .assistant
        else if (std.mem.eql(u8, s, "tool"))
            .tool
        else
            null;
    }
};

/// FunctionCall represents a function call within a tool call
pub const FunctionCall = struct {
    name: []const u8,
    arguments: []const u8,

    pub fn deinit(self: *FunctionCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.arguments);
    }

    pub fn dupe(self: FunctionCall, allocator: std.mem.Allocator) !FunctionCall {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .arguments = try allocator.dupe(u8, self.arguments),
        };
    }
};

/// ToolCall represents a tool/function call from the LLM
pub const ToolCall = struct {
    id: []const u8,
    @"type": []const u8,
    function: FunctionCall,

    pub fn deinit(self: *ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.@"type");
        self.function.deinit(allocator);
    }

    pub fn dupe(self: ToolCall, allocator: std.mem.Allocator) !ToolCall {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .@"type" = try allocator.dupe(u8, self.@"type"),
            .function = try self.function.dupe(allocator),
        };
    }
};

/// ToolDefinition defines a tool available to the LLM
pub const ToolDefinition = struct {
    @"type": []const u8 = "function",
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,

    pub fn deinit(self: *ToolDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
    }

    pub fn dupe(self: ToolDefinition, allocator: std.mem.Allocator) !ToolDefinition {
        return .{
            .@"type" = try allocator.dupe(u8, self.@"type"),
            .name = try allocator.dupe(u8, self.name),
            .description = try allocator.dupe(u8, self.description),
            .parameters = self.parameters,
        };
    }
};

/// Message represents a single message in a conversation
pub const Message = struct {
    role: MessageRole,
    content: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls: ?[]ToolCall = null,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.tool_call_id) |tcid| allocator.free(tcid);
        if (self.tool_calls) |calls| {
            for (calls) |*call| call.deinit(allocator);
            allocator.free(calls);
        }
    }

    pub fn dupe(self: Message, allocator: std.mem.Allocator) !Message {
        var result = Message{
            .role = self.role,
            .content = if (self.content) |c| try allocator.dupe(u8, c) else null,
            .tool_call_id = if (self.tool_call_id) |tcid| try allocator.dupe(u8, tcid) else null,
            .tool_calls = null,
        };
        if (self.tool_calls) |calls| {
            result.tool_calls = try allocator.alloc(ToolCall, calls.len);
            for (calls, 0..) |call, i| {
                result.tool_calls.?[i] = try call.dupe(allocator);
            }
        }
        return result;
    }

    pub fn hasToolCalls(self: Message) bool {
        return self.tool_calls != null and self.tool_calls.?.len > 0;
    }
};

/// Choice represents a completion choice from the LLM
pub const Choice = struct {
    index: u32,
    message: Message,
    finish_reason: ?[]const u8 = null,

    pub fn deinit(self: *Choice, allocator: std.mem.Allocator) void {
        if (self.finish_reason) |fr| allocator.free(fr);
        self.message.deinit(allocator);
    }
};

/// Usage represents token usage statistics
pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

/// ChatCompletionResponse represents the response from a chat completion API
pub const ChatCompletionResponse = struct {
    id: []const u8,
    model: []const u8,
    choices: []Choice,
    created: i64,
    usage: Usage,

    pub fn deinit(self: *ChatCompletionResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.model);
        for (self.choices) |*choice| choice.deinit(allocator);
        allocator.free(self.choices);
    }
};

/// ChatCompletionRequest represents a request to a chat completion API
pub const ChatCompletionRequest = struct {
    model: []const u8,
    messages: []Message,
    tools: ?[]ToolDefinition = null,
    tool_choice: ?[]const u8 = null,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,

    pub fn deinit(self: *ChatCompletionRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.model);
        if (self.tool_choice) |tc| allocator.free(tc);
        for (self.messages) |*msg| msg.deinit(allocator);
        allocator.free(self.messages);
        if (self.tools) |tools| {
            for (tools) |*tool| tool.deinit(allocator);
            allocator.free(tools);
        }
    }
};

/// ProviderError represents errors from LLM providers
pub const ProviderError = error{
    Network,
    Auth,
    RateLimit,
    InvalidResponse,
    ParseError,
    Timeout,
};

test "MessageRole conversion" {
    try std.testing.expectEqualStrings("system", MessageRole.toString(.system));
    try std.testing.expectEqualStrings("user", MessageRole.toString(.user));
    try std.testing.expectEqualStrings("assistant", MessageRole.toString(.assistant));
    try std.testing.expectEqualStrings("tool", MessageRole.toString(.tool));

    try std.testing.expectEqual(MessageRole.system, MessageRole.fromString("system").?);
    try std.testing.expectEqual(MessageRole.user, MessageRole.fromString("user").?);
    try std.testing.expectEqual(MessageRole.assistant, MessageRole.fromString("assistant").?);
    try std.testing.expectEqual(MessageRole.tool, MessageRole.fromString("tool").?);
    try std.testing.expectEqual(@as(?MessageRole, null), MessageRole.fromString("invalid"));
}

test "Message hasToolCalls" {
    const allocator = std.testing.allocator;
    var message = Message{
        .role = .assistant,
        .content = "I'll help you.",
        .tool_calls = null,
        .tool_call_id = null,
    };
    try std.testing.expect(!message.hasToolCalls());

    message.tool_calls = try allocator.alloc(ToolCall, 1);
    errdefer allocator.free(message.tool_calls.?);
    message.tool_calls.?[0] = .{
        .id = "call_123",
        .@"type" = "function",
        .function = .{
            .name = "get_weather",
            .arguments = "{\"location\": \"London\"}",
        },
    };
    defer allocator.free(message.tool_calls.?);
}
