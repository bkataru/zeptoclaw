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

/// LLMProvider is the interface for LLM providers
/// This is a vtable-style interface for provider implementations
pub const LLMProvider = struct {
    /// chat sends a chat completion request and returns the response
    chat: *const fn (allocator: std.mem.Allocator, messages: []Message) ProviderError!ChatCompletionResponse,
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

test "MessageRole fromString with invalid input" {
    try std.testing.expectEqual(@as(?MessageRole, null), MessageRole.fromString(""));
    try std.testing.expectEqual(@as(?MessageRole, null), MessageRole.fromString("invalid"));
    try std.testing.expectEqual(@as(?MessageRole, null), MessageRole.fromString("SYSTEM")); // case sensitive
}

test "Message dupe and deinit" {
    const allocator = std.testing.allocator;
    
    const original = Message{
        .role = .user,
        .content = "Hello, world!",
        .tool_call_id = null,
        .tool_calls = null,
    };
    
    var duplicated = try original.dupe(allocator);
    defer duplicated.deinit(allocator);
    
    try std.testing.expectEqual(original.role, duplicated.role);
    try std.testing.expectEqualStrings(original.content.?, duplicated.content.?);
}

test "Message with tool_call_id" {
    const allocator = std.testing.allocator;
    
    var message = Message{
        .role = .tool,
        .content = "Weather: 72°F",
        .tool_call_id = try allocator.dupe(u8, "call_123"),
        .tool_calls = null,
    };
    defer message.deinit(allocator);
    
    try std.testing.expectEqualStrings("call_123", message.tool_call_id.?);
}

test "FunctionCall dupe" {
    const allocator = std.testing.allocator;
    
    const original = FunctionCall{
        .name = "get_weather",
        .arguments = "{\"location\": \"London\"}",
    };
    
    var duplicated = try original.dupe(allocator);
    defer duplicated.deinit(allocator);
    
    try std.testing.expectEqualStrings(original.name, duplicated.name);
    try std.testing.expectEqualStrings(original.arguments, duplicated.arguments);
}

test "ToolCall dupe" {
    const allocator = std.testing.allocator;
    
    const original = ToolCall{
        .id = "call_123",
        .@"type" = "function",
        .function = .{
            .name = "get_weather",
            .arguments = "{\"location\": \"London\"}",
        },
    };
    
    var duplicated = try original.dupe(allocator);
    defer duplicated.deinit(allocator);
    
    try std.testing.expectEqualStrings(original.id, duplicated.id);
    try std.testing.expectEqualStrings(original.@"type", duplicated.@"type");
    try std.testing.expectEqualStrings(original.function.name, duplicated.function.name);
}

test "ToolDefinition dupe" {
    const allocator = std.testing.allocator;
    
const params = (try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{})).value;
    // Value doesn't need explicit deinit
    
    const original = ToolDefinition{
        .@"type" = "function",
        .name = "get_weather",
        .description = "Get weather for a location",
        .parameters = params,
    };
    
    var duplicated = try original.dupe(allocator);
    defer duplicated.deinit(allocator);
    
    try std.testing.expectEqualStrings(original.name, duplicated.name);
    try std.testing.expectEqualStrings(original.description, duplicated.description);
}

test "Choice deinit" {
    const allocator = std.testing.allocator;
    
    var choice = Choice{
        .index = 0,
        .message = Message{
            .role = .assistant,
            .content = "Hello!",
            .tool_call_id = null,
            .tool_calls = null,
        },
        .finish_reason = try allocator.dupe(u8, "stop"),
    };
    
    choice.deinit(allocator);
}

test "ChatCompletionResponse deinit" {
    const allocator = std.testing.allocator;
    
    var response = ChatCompletionResponse{
        .id = try allocator.dupe(u8, "chatcmpl-123"),
        .model = try allocator.dupe(u8, "qwen/qwen3.5-397b-a17b"),
        .choices = try allocator.alloc(Choice, 0),
        .created = 1234567890,
        .usage = .{ .prompt_tokens = 10, .completion_tokens = 20, .total_tokens = 30 },
    };
    
    response.deinit(allocator);
}

test "ChatCompletionRequest deinit" {
    const allocator = std.testing.allocator;
    
    var messages = try allocator.alloc(Message, 1);
    messages[0] = Message{
        .role = .user,
        .content = "Hello",
        .tool_call_id = null,
        .tool_calls = null,
    };
    
    var request = ChatCompletionRequest{
        .model = try allocator.dupe(u8, "qwen/qwen3.5-397b-a17b"),
        .messages = messages,
        .tools = null,
        .tool_choice = null,
        .temperature = 0.7,
        .max_tokens = 100,
    };
    
    request.deinit(allocator);
}

test "Message with tool_calls hasToolCalls returns true" {
    const allocator = std.testing.allocator;
    // allocator used later in test
    
    var message = Message{
        .role = .assistant,
        .content = "Let me check the weather.",
        .tool_call_id = null,
        .tool_calls = null,
    };
    
    try std.testing.expect(!message.hasToolCalls());
    
    message.tool_calls = try allocator.alloc(ToolCall, 1);
    try std.testing.expect(message.hasToolCalls());
}
