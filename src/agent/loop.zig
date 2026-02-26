const std = @import("std");
const types = @import("../providers/types.zig");
const message = @import("message.zig");
const Session = @import("../channels/session.zig").Session;
const NIMClient = @import("../providers/nim.zig").NIMClient;

pub const Agent = struct {
    allocator: std.mem.Allocator,
    session: Session,
    nim_client: *NIMClient,

    pub fn init(allocator: std.mem.Allocator, nim_client: *NIMClient, max_messages: u32) Agent {
        return .{
            .allocator = allocator,
            .session = Session.init(allocator, max_messages),
            .nim_client = nim_client,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.session.deinit();
    }

    pub fn run(self: *Agent, initial_user_message: []const u8) ![]const u8 {
        // Add initial user message to session
        const user_msg = try message.userMessage(self.allocator, initial_user_message);
        try self.session.addMessage(user_msg);

        // Call NIM provider with session history
        const response = try self.nim_client.chat(self.session.getHistory());
        
        // Extract assistant response content
        if (response.choices.len > 0) {
            const assistant_message = response.choices[0].message;
            if (assistant_message.content) |content| {
                // Add assistant response to session
                const assistant_msg = try message.assistantMessage(self.allocator, content);
                try self.session.addMessage(assistant_msg);
                
                // Return a copy of the content (caller frees)
                return self.allocator.dupe(u8, content);
            }
        }
        
        return "";
    }
};

test "agent loop basic" {
    const allocator = std.testing.allocator;
    _ = allocator;
    // Test requires NIMClient instance - skip for now
    // This test would need a mock provider or actual API key
}
