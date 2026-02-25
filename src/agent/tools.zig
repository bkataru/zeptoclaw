const std = @import("std");
const types = @import("../providers/types.zig");

pub const ToolFn = *const fn (std.mem.Allocator, []const u8) anyerror![]const u8;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
    handler: ToolFn,

    pub fn deinit(self: *Tool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(Tool),

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(Tool).init(allocator),
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.tools.deinit();
    }

    pub fn register(self: *ToolRegistry, tool: Tool) !void {
        try self.tools.put(tool.name, tool);
    }

    pub fn get(self: *ToolRegistry, name: []const u8) ?*Tool {
        return self.tools.getPtr(name);
    }

    pub fn execute(self: *ToolRegistry, name: []const u8, args: []const u8) ![]const u8 {
        const tool = self.get(name) orelse return error.ToolNotFound;
        return tool.handler(self.allocator, args);
    }
};

// Echo tool
pub fn echoTool(allocator: std.mem.Allocator, args: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args, .{});
    defer parsed.deinit();
    
    if (parsed.value.object.get("message")) |msg_val| {
        if (msg_val == .string) {
            return try allocator.dupe(u8, msg_val.string);
        }
    }
    return try allocator.dupe(u8, "");
}

// Current time tool  
pub fn currentTimeTool(allocator: std.mem.Allocator, args: []const u8) ![]const u8 {
    _ = args;
    const now = std.time.timestamp();
    var buf: [32]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{d}", .{now});
    return try allocator.dupe(u8, result);
}

test "ToolRegistry basic operations" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "test_tool",
        .description = "A test tool",
        .parameters = std.json.Value{ .null = .{} },
        .handler = echoTool,
    });

    try std.testing.expect(registry.get("test_tool") != null);
    try std.testing.expect(registry.get("nonexistent") == null);
}

test "Echo tool execution" {
    const allocator = std.testing.allocator;
    const result = try echoTool(allocator, "{\"message\": \"hello\"}");
    defer allocator.free(result);
    
    try std.testing.expectEqualStrings("hello", result);
}

test "Current time tool" {
    const allocator = std.testing.allocator;
    const result = try currentTimeTool(allocator, "{}");
    defer allocator.free(result);
    
    // Just check it returns a number
    try std.testing.expect(result.len > 0);
}
