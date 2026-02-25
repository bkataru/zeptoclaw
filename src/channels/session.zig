const std = @import("std");
const types = @import("../providers/types.zig");

pub const Session = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(types.Message),
    start_time: i64,
    message_count: u32,
    max_messages: u32,

    pub fn init(allocator: std.mem.Allocator, max: u32) Session {
        return .{
            .allocator = allocator,
            .messages = std.ArrayList(types.Message).init(allocator),
            .start_time = @as(i64, std.time.timestamp()),
            .message_count = 0,
            .max_messages = max,
        };
    }

    pub fn deinit(self: *Session) void {
        for (self.messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.messages.deinit();
    }

    pub fn addMessage(self: *Session, msg: types.Message) !void {
        if (self.messages.items.len >= self.max_messages) {
            self.messages.items[0].deinit(self.allocator);
            _ = self.messages.orderedRemove(0);
        }
        try self.messages.append(msg);
        self.message_count += 1;
    }

    pub fn getHistory(self: *Session) []types.Message {
        return self.messages.items;
    }

    pub fn clear(self: *Session) void {
        for (self.messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.messages.clearRetainCapacity();
        self.message_count = 0;
    }
};

test "session init" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, 50);
    defer session.deinit();
    
    try std.testing.expectEqual(@as(u32, 50), session.max_messages);
    try std.testing.expectEqual(@as(u32, 0), session.message_count);
}

test "session addMessage" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, 50);
    defer session.deinit();
    
    const msg = try types.Message.user(allocator, "test");
    try session.addMessage(msg);
    
    try std.testing.expectEqual(@as(u32, 1), session.message_count);
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
}

test "session message limit" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, 3);
    defer session.deinit();
    
    const msg1 = try types.Message.user(allocator, "test1");
    const msg2 = try types.Message.user(allocator, "test2");
    const msg3 = try types.Message.user(allocator, "test3");
    const msg4 = try types.Message.user(allocator, "test4");
    
    try session.addMessage(msg1);
    try session.addMessage(msg2);
    try session.addMessage(msg3);
    try session.addMessage(msg4);
    
    try std.testing.expectEqual(@as(usize, 3), session.messages.items.len);
}
