//! Execution Context
//! Context object passed to skills during execution

const std = @import("std");
const types = @import("types.zig");
const providers = @import("../providers/types.zig");

const SkillMetadata = types.SkillMetadata;
const Message = providers.Message;
const MessageRole = providers.MessageRole;

/// ExecutionContext provides context for skill execution
pub const ExecutionContext = struct {
    allocator: std.mem.Allocator,
    skill: SkillMetadata,
    message: Message,
    session_id: []const u8,
    config: std.json.Value,
    tools: *const ToolRegistry,
    send_response: *const fn (ctx: *ExecutionContext, response: []const u8) anyerror!void,

    /// Create a new execution context
    pub fn init(
        allocator: std.mem.Allocator,
        skill: SkillMetadata,
        message: Message,
        session_id: []const u8,
        config: std.json.Value,
        tools: *const ToolRegistry,
        send_response: *const fn (ctx: *ExecutionContext, response: []const u8) anyerror!void,
    ) ExecutionContext {
        return .{
            .allocator = allocator,
            .skill = skill,
            .message = message,
            .session_id = session_id,
            .config = config,
            .tools = tools,
            .send_response = send_response,
        };
    }

    /// Send a response back to the user
    pub fn respond(self: *ExecutionContext, response: []const u8) !void {
        try self.send_response(self, response);
    }

    /// Get the message content
    pub fn getMessageContent(self: *ExecutionContext) ?[]const u8 {
        return self.message.content;
    }

    /// Get the message role
    pub fn getMessageRole(self: *ExecutionContext) MessageRole {
        return self.message.role;
    }

    /// Get a configuration value
    pub fn getConfig(self: *ExecutionContext, key: []const u8) ?std.json.Value {
        if (self.config != .object) return null;
        return self.config.object.get(key);
    }

    /// Get a string configuration value
    pub fn getConfigString(self: *ExecutionContext, key: []const u8) ?[]const u8 {
        const val = self.getConfig(key) orelse return null;
        if (val != .string) return null;
        return val.string;
    }

    /// Get an integer configuration value
    pub fn getConfigInt(self: *ExecutionContext, key: []const u8) ?i64 {
        const val = self.getConfig(key) orelse return null;
        if (val != .integer) return null;
        return val.integer;
    }

    /// Get a boolean configuration value
    pub fn getConfigBool(self: *ExecutionContext, key: []const u8) ?bool {
        const val = self.getConfig(key) orelse return null;
        if (val != .bool) return null;
        return val.bool;
    }

    /// Call a tool
    pub fn callTool(self: *ExecutionContext, tool_name: []const u8, arguments: []const u8) ![]const u8 {
        return self.tools.call(self.allocator, tool_name, arguments);
    }

    /// Log a message (for debugging)
    pub fn log(self: *ExecutionContext, level: LogLevel, message: []const u8) void {
        const level_str = level.toString();
        std.log.print("[{s}] [{s}] {s}\n", .{ level_str, self.skill.id, message });
    }
};

/// LogLevel for skill logging
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

/// ToolRegistry provides access to available tools
pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(ToolDefinition),

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(ToolDefinition).init(allocator),
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        var iter = self.tools.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.tools.deinit();
    }

    /// Register a tool
    pub fn register(self: *ToolRegistry, tool: ToolDefinition) !void {
        const name = try self.allocator.dupe(u8, tool.name);
        errdefer self.allocator.free(name);

        const tool_copy = try tool.dupe(self.allocator);
        errdefer tool_copy.deinit(self.allocator);

        try self.tools.put(name, tool_copy);
    }

    /// Call a tool
    pub fn call(self: *ToolRegistry, allocator: std.mem.Allocator, tool_name: []const u8, arguments: []const u8) ![]const u8 {
        _ = self.tools.get(tool_name) orelse return error.ToolNotFound;

        // In a real implementation, this would execute the tool
        // For now, return a mock response
        const response = try std.fmt.allocPrint(allocator, "Tool '{s}' called with args: {s}", .{ tool_name, arguments });
        return response;
    }

    /// Get all tool definitions
    pub fn getToolDefinitions(self: *ToolRegistry) ![]ToolDefinition {
        const tools = try self.allocator.alloc(ToolDefinition, self.tools.count());
        var i: usize = 0;
        var iter = self.tools.iterator();
        while (iter.next()) |entry| : (i += 1) {
            tools[i] = try entry.value_ptr.dupe(self.allocator);
        }
        return tools;
    }
};

/// ToolDefinition defines a tool
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
    handler: *const fn (allocator: std.mem.Allocator, arguments: []const u8) anyerror![]const u8,

    pub fn deinit(self: *ToolDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        // Don't deep-free JSON parameters for simplicity
    }

    pub fn dupe(self: ToolDefinition, allocator: std.mem.Allocator) !ToolDefinition {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .description = try allocator.dupe(u8, self.description),
            .parameters = self.parameters,
            .handler = self.handler,
        };
    }
};

/// SkillResult represents the result of skill execution
pub const SkillResult = struct {
    success: bool,
    response: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    should_continue: bool = true, // Whether to continue processing other skills

    pub fn successResponse(allocator: std.mem.Allocator, response: []const u8) !SkillResult {
        return .{
            .success = true,
            .response = try allocator.dupe(u8, response),
            .error_message = null,
            .should_continue = true,
        };
    }

    pub fn errorResponse(allocator: std.mem.Allocator, error_message: []const u8) !SkillResult {
        return .{
            .success = false,
            .response = null,
            .error_message = try allocator.dupe(u8, error_message),
            .should_continue = true,
        };
    }

    pub fn stop(allocator: std.mem.Allocator, response: []const u8) !SkillResult {
        return .{
            .success = true,
            .response = try allocator.dupe(u8, response),
            .error_message = null,
            .should_continue = false,
        };
    }

    pub fn deinit(self: *SkillResult, allocator: std.mem.Allocator) void {
        if (self.response) |r| allocator.free(r);
        if (self.error_message) |e| allocator.free(e);
    }
};

test "ExecutionContext init" {
    const allocator = std.testing.allocator;

    var skill_metadata = types.SkillMetadata{
        .id = "test-skill",
        .name = "Test Skill",
        .version = null,
        .description = "A test skill",
        .homepage = null,
        .metadata = .null,
        .enabled = true,
    };
    defer skill_metadata.deinit(allocator);

    var message = Message{
        .role = .user,
        .content = try allocator.dupe(u8, "test message"),
        .tool_call_id = null,
        .tool_calls = null,
    };
    defer message.deinit(allocator);

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var ctx = ExecutionContext.init(
        allocator,
        skill_metadata,
        message,
        "session-123",
        .{ .object = std.StringHashMap(std.json.Value).init(allocator) },
        &tool_registry,
        testSendResponse,
    );

    try std.testing.expectEqualStrings("test-skill", ctx.skill.id);
    try std.testing.expectEqualStrings("test message", ctx.getMessageContent().?);
}

test "ExecutionContext getConfig" {
    const allocator = std.testing.allocator;

    var config_obj = std.StringHashMap(std.json.Value).init(allocator);
    try config_obj.put("api_key", std.json.Value{ .string = "test-key" });
    try config_obj.put("timeout", std.json.Value{ .integer = 30 });
    try config_obj.put("enabled", std.json.Value{ .bool = true });

    var skill_metadata = types.SkillMetadata{
        .id = "test-skill",
        .name = "Test Skill",
        .version = null,
        .description = "A test skill",
        .homepage = null,
        .metadata = .null,
        .enabled = true,
    };
    defer skill_metadata.deinit(allocator);

    var message = Message{
        .role = .user,
        .content = try allocator.dupe(u8, "test"),
        .tool_call_id = null,
        .tool_calls = null,
    };
    defer message.deinit(allocator);

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var ctx = ExecutionContext.init(
        allocator,
        skill_metadata,
        message,
        "session-123",
        .{ .object = config_obj },
        &tool_registry,
        testSendResponse,
    );

    try std.testing.expectEqualStrings("test-key", ctx.getConfigString("api_key").?);
    try std.testing.expectEqual(@as(i64, 30), ctx.getConfigInt("timeout").?);
    try std.testing.expectEqual(true, ctx.getConfigBool("enabled").?);
    try std.testing.expect(ctx.getConfig("missing") == null);
}

test "ToolRegistry register and call" {
    const allocator = std.testing.allocator;

    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    const tool = ToolDefinition{
        .name = "test_tool",
        .description = "A test tool",
        .parameters = .{ .object = std.StringHashMap(std.json.Value).init(allocator) },
        .handler = testToolHandler,
    };

    try registry.register(tool);

    const result = try registry.call(allocator, "test_tool", "{}");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Tool 'test_tool' called with args: {}", result);
}

test "SkillResult successResponse" {
    const allocator = std.testing.allocator;

    var result = try SkillResult.successResponse(allocator, "Success!");
    defer result.deinit(allocator);

    try std.testing.expectEqual(true, result.success);
    try std.testing.expectEqualStrings("Success!", result.response.?);
    try std.testing.expectEqual(true, result.should_continue);
}

test "SkillResult errorResponse" {
    const allocator = std.testing.allocator;

    var result = try SkillResult.errorResponse(allocator, "Error occurred");
    defer result.deinit(allocator);

    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqualStrings("Error occurred", result.error_message.?);
    try std.testing.expectEqual(true, result.should_continue);
}

test "SkillResult stop" {
    const allocator = std.testing.allocator;

    var result = try SkillResult.stop(allocator, "Stopping");
    defer result.deinit(allocator);

    try std.testing.expectEqual(true, result.success);
    try std.testing.expectEqualStrings("Stopping", result.response.?);
    try std.testing.expectEqual(false, result.should_continue);
}

// Test helpers
fn testSendResponse(ctx: *ExecutionContext, response: []const u8) anyerror!void {
    _ = ctx;
    _ = response;
}

fn testToolHandler(allocator: std.mem.Allocator, arguments: []const u8) anyerror![]const u8 {
    _ = allocator;
    return try std.fmt.allocPrint(std.testing.allocator, "Tool called with: {s}", .{arguments});
}
