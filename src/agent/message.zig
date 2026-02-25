const std = @import("std");
const types = @import("../providers/types.zig");

pub const Message = types.Message;
pub const ToolCall = types.ToolCall;
pub const MessageRole = types.MessageRole;

/// Parse a message from JSON
pub fn fromJSON(allocator: std.mem.Allocator, json_str: []const u8) !Message {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    
    const obj = parsed.value.object;
    const role_str = obj.get("role").?.string;
    const role = MessageRole.fromString(role_str) orelse return error.InvalidRole;
    
    var message = Message{
        .role = role,
        .content = null,
        .tool_call_id = null,
        .tool_calls = null,
    };
    
    if (obj.get("content")) |content_val| {
        if (content_val == .string) {
            message.content = try allocator.dupe(u8, content_val.string);
        }
    }
    
    if (obj.get("tool_call_id")) |tcid_val| {
        if (tcid_val == .string) {
            message.tool_call_id = try allocator.dupe(u8, tcid_val.string);
        }
    }
    
    if (obj.get("tool_calls")) |calls_val| {
        if (calls_val == .array) {
            const calls = try allocator.alloc(ToolCall, calls_val.array.items.len);
            errdefer allocator.free(calls);
            
            for (calls_val.array.items, 0..) |call_val, i| {
                calls[i] = try parseToolCall(allocator, call_val);
            }
            message.tool_calls = calls;
        }
    }
    
    return message;
}

fn parseToolCall(allocator: std.mem.Allocator, value: std.json.Value) !ToolCall {
    const obj = value.object;
    const func_obj = obj.get("function").?.object;
    
    return .{
        .id = try allocator.dupe(u8, obj.get("id").?.string),
        .@"type" = try allocator.dupe(u8, obj.get("type").?.string),
        .function = .{
            .name = try allocator.dupe(u8, func_obj.get("name").?.string),
            .arguments = try allocator.dupe(u8, func_obj.get("arguments").?.string),
        },
    };
}

/// Extract tool calls from a message
pub fn extractToolCalls(message: Message) ?[]ToolCall {
    return message.tool_calls;
}

/// Create a user message
pub fn userMessage(allocator: std.mem.Allocator, content: []const u8) !Message {
    return .{
        .role = .user,
        .content = try allocator.dupe(u8, content),
        .tool_call_id = null,
        .tool_calls = null,
    };
}

/// Create an assistant message
pub fn assistantMessage(allocator: std.mem.Allocator, content: []const u8) !Message {
    return .{
        .role = .assistant,
        .content = try allocator.dupe(u8, content),
        .tool_call_id = null,
        .tool_calls = null,
    };
}

/// Create a tool result message
pub fn toolResultMessage(allocator: std.mem.Allocator, tool_call_id: []const u8, content: []const u8) !Message {
    return .{
        .role = .tool,
        .content = try allocator.dupe(u8, content),
        .tool_call_id = try allocator.dupe(u8, tool_call_id),
        .tool_calls = null,
    };
}

test "MessageRole conversion" {
    try std.testing.expectEqualStrings("user", MessageRole.toString(.user));
    try std.testing.expectEqualStrings("assistant", MessageRole.toString(.assistant));
}

test "fromJSON with basic message" {
    const allocator = std.testing.allocator;
    const json = "{\"role\": \"user\", \"content\": \"Hello\"}";
    const msg = try fromJSON(allocator, json);
    defer { if (msg.content) |c| allocator.free(c); }
    
    try std.testing.expectEqual(MessageRole.user, msg.role);
    try std.testing.expectEqualStrings("Hello", msg.content.?);
}

test "fromJSON with tool calls" {
    const allocator = std.testing.allocator;
    const json = 
        \\{"role": "assistant", "content": "Let me help", "tool_calls": [
        \\  {"id": "call_1", "type": "function", "function": {"name": "echo", "arguments": "{\"msg\": \"hi\"}"}}
        \\]}
    ;
    const msg = try fromJSON(allocator, json);
    defer {
        if (msg.content) |c| allocator.free(c);
        if (msg.tool_calls) |calls| {
            for (calls) |*call| call.deinit(allocator);
            allocator.free(calls);
        }
    }
    
    try std.testing.expectEqual(MessageRole.assistant, msg.role);
    try std.testing.expect(msg.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), msg.tool_calls.?.len);
}

test "extractToolCalls" {
    const allocator = std.testing.allocator;
    var msg = try assistantMessage(allocator, "No tools here");
    defer msg.deinit(allocator);
    
    try std.testing.expect(extractToolCalls(msg) == null);
}
