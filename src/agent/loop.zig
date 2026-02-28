const std = @import("std");
const types = @import("../providers/types.zig");
const message = @import("message.zig");
const Session = @import("../channels/session.zig").Session;
const NIMClient = @import("../providers/nim.zig").NIMClient;

// Skills integration
const skills = @import("../skills/skill_sdk.zig");
const execution_context = @import("../skills/execution_context.zig");
const git_workflow = @import("../skills/git_workflow/skill.zig");

// Dummy send_response for skill execution
fn dummySendResponse(ctx: *execution_context.ExecutionContext, response: []const u8) anyerror!void {
    _ = ctx;
    _ = response;
}

pub const Agent = struct {
    allocator: std.mem.Allocator,
    session: Session,
    nim_client: *NIMClient,
    tool_registry: execution_context.ToolRegistry,
    skill_metadata: skills.SkillMetadata,

    pub fn init(allocator: std.mem.Allocator, nim_client: *NIMClient, max_messages: u32) !Agent {
        // Initialize tool registry
        const tool_registry = execution_context.ToolRegistry.init(allocator);

        // Load and duplicate skill metadata
        var meta = git_workflow.skill.getMetadata();
        var skill_metadata = try meta.dupe(allocator);
        errdefer skill_metadata.deinit(allocator);

        // Initialize the git_workflow skill with null config (use defaults)
        try git_workflow.skill.init(allocator, std.json.Value{ .null = {} });

        return .{
            .allocator = allocator,
            .session = Session.init(allocator, max_messages),
            .nim_client = nim_client,
            .tool_registry = tool_registry,
            .skill_metadata = skill_metadata,
        };
    }

    pub fn deinit(self: *Agent) void {
        self.session.deinit();
        self.tool_registry.deinit();
        self.skill_metadata.deinit(self.allocator);
        git_workflow.skill.deinit(self.allocator);
    }

    pub fn run(self: *Agent, initial_user_message: []const u8) ![]const u8 {
        // Add initial user message to session
        const user_msg = try message.userMessage(self.allocator, initial_user_message);
        try self.session.addMessage(user_msg);

        // Execute skill with a fresh context
        var ctx_msg = try message.userMessage(self.allocator, initial_user_message);
        defer ctx_msg.deinit(self.allocator);

        var ctx: execution_context.ExecutionContext = .{
            .allocator = self.allocator,
            .skill = self.skill_metadata,
            .message = ctx_msg,
            .session_id = "",
            .config = std.json.Value{ .null = {} },
            .tools = &self.tool_registry,
            .send_response = dummySendResponse,
        };

        var result = try git_workflow.skill.execute(&ctx);
        defer result.deinit(self.allocator);

        if (result.response) |resp| {
            if (resp.len > 0) {
                // Add assistant response to session
                const assistant_msg = try message.assistantMessage(self.allocator, resp);
                try self.session.addMessage(assistant_msg);
                return try self.allocator.dupe(u8, resp);
            }
        }
        if (!result.should_continue) {
            return "";
        }

        // Fallback to NIM provider
        const response = try self.nim_client.chat(self.session.getHistory());
        if (response.choices.len > 0) {
            const assistant_message = response.choices[0].message;
            if (assistant_message.content) |content| {
                const assistant_msg = try message.assistantMessage(self.allocator, content);
                try self.session.addMessage(assistant_msg);
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
