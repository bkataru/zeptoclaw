const std = @import("std");
const types = @import("../providers/types.zig");
const message = @import("message.zig");
const Session = @import("../channels/session.zig").Session;
const NIMClient = @import("../providers/nim.zig").NIMClient;
const tools_mod = @import("tools.zig");
const core_tools = @import("core_tools.zig");
const transcript = @import("transcript.zig");
const openclaw = @import("../openclaw_compat/openclaw.zig");
const engagement = @import("../channels/whatsapp/engagement.zig");

const skills = @import("../skills/skill_sdk.zig");
const execution_context = @import("../skills/execution_context.zig");
const git_workflow = @import("../skills/git_workflow/skill.zig");

fn dummySendResponse(ctx: *execution_context.ExecutionContext, response: []const u8) anyerror!void {
    _ = ctx;
    _ = response;
}

var g_skill_agent: ?*Agent = null;

fn skillHandler(allocator: std.mem.Allocator, name: []const u8, command: []const u8) anyerror![]const u8 {
    const self = g_skill_agent orelse return allocator.dupe(u8, "error: no agent");
    if (!std.mem.eql(u8, name, "git_workflow") and !std.mem.eql(u8, name, "git")) {
        return std.fmt.allocPrint(allocator, "unknown skill {s}; available: git_workflow", .{name});
    }
    const body = if (command.len == 0) "/git-status" else if (command[0] == '/') command else blk: {
        break :blk try std.fmt.allocPrint(allocator, "/{s}", .{command});
    };
    defer if (command.len != 0 and command[0] != '/') allocator.free(body);

    var ctx_msg = try message.userMessage(allocator, body);
    defer ctx_msg.deinit(allocator);
    var ctx: execution_context.ExecutionContext = .{
        .allocator = allocator,
        .skill = self.skill_metadata,
        .message = ctx_msg,
        .session_id = self.session_id,
        .config = std.json.Value{ .null = {} },
        .tools = &self.exec_tools,
        .send_response = dummySendResponse,
    };
    var result = try git_workflow.skill.execute(&ctx);
    defer result.deinit(allocator);
    if (result.response) |resp| return allocator.dupe(u8, resp);
    return allocator.dupe(u8, "(skill produced no text)");
}

pub const TurnOpts = struct {
    system_prompt: ?[]const u8 = null,
    extra_context: ?[]const u8 = null,
    max_iters: u32 = 8,
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    session: Session,
    nim_client: *NIMClient,
    workspace: []const u8,
    session_id: []const u8,
    core: tools_mod.ToolRegistry,
    params: core_tools.ParamHold,
    skill_metadata: skills.SkillMetadata,
    exec_tools: execution_context.ToolRegistry,
    transcripts: transcript.Store,
    owns_workspace: bool = false,

    /// Memory: Caller owns returned Agent; must call deinit(). `nim_client` is borrowed.
    pub fn init(allocator: std.mem.Allocator, nim_client: *NIMClient, max_messages: u32) !Agent {
        var meta = git_workflow.skill.getMetadata();
        var skill_metadata = try meta.dupe(allocator);
        errdefer skill_metadata.deinit(allocator);
        try git_workflow.skill.init(allocator, std.json.Value{ .null = {} });

        var core = tools_mod.ToolRegistry.init(allocator);
        var params: core_tools.ParamHold = undefined;
        try core_tools.registerAll(&core, &params);

        var ws: []const u8 = ".";
        var owns = false;
        if (openclaw.resolveWorkspaceDir(allocator)) |w| {
            ws = w;
            owns = true;
        } else |_| {}

        return .{
            .allocator = allocator,
            .session = Session.init(allocator, max_messages),
            .nim_client = nim_client,
            .workspace = ws,
            .session_id = "main",
            .core = core,
            .params = params,
            .skill_metadata = skill_metadata,
            .exec_tools = execution_context.ToolRegistry.init(allocator),
            .transcripts = transcript.Store.init(allocator, "sessions/transcripts"),
            .owns_workspace = owns,
        };
    }

    pub fn setWorkspace(self: *Agent, path: []const u8) void {
        if (self.owns_workspace) self.allocator.free(self.workspace);
        self.workspace = path;
        self.owns_workspace = false;
    }

    pub fn setSessionId(self: *Agent, id: []const u8) void {
        self.session_id = id;
    }

    /// Memory: Callee takes responsibility for session, registries, skill metadata.
    pub fn deinit(self: *Agent) void {
        self.session.deinit();
        self.core.deinit();
        self.params.deinit();
        self.skill_metadata.deinit(self.allocator);
        self.exec_tools.deinit();
        git_workflow.skill.deinit(self.allocator);
        if (self.owns_workspace) self.allocator.free(self.workspace);
    }

    /// Memory: Caller owns returned slice; call allocator.free.
    pub fn run(self: *Agent, initial_user_message: []const u8) ![]const u8 {
        return self.runTurn(initial_user_message, .{});
    }

    /// Memory: Caller owns returned reply text.
    pub fn runTurn(self: *Agent, user_text: []const u8, opts: TurnOpts) ![]const u8 {
        core_tools.setWorkspace(self.workspace);
        core_tools.resetPresence();
        g_skill_agent = self;
        core_tools.setSkillHandler(skillHandler);
        defer {
            g_skill_agent = null;
            core_tools.setSkillHandler(null);
        }

        if (opts.system_prompt) |sp| {
            if (self.session.messages.items.len == 0) {
                try self.session.addMessage(.{
                    .role = .system,
                    .content = try self.allocator.dupe(u8, sp),
                    .tool_call_id = null,
                    .tool_calls = null,
                });
            }
        }
        if (opts.extra_context) |ex| {
            if (ex.len > 0) {
                try self.session.addMessage(.{
                    .role = .system,
                    .content = try self.allocator.dupe(u8, ex),
                    .tool_call_id = null,
                    .tool_calls = null,
                });
            }
        }

        const user_msg = try message.userMessage(self.allocator, user_text);
        try self.session.addMessage(user_msg);
        self.transcripts.append(self.session_id, "user", user_text);

        const defs = try core_tools.collectDefinitions(&self.core, self.allocator);
        defer {
            for (defs) |*d| d.deinit(self.allocator);
            self.allocator.free(defs);
        }

        var iter: u32 = 0;
        while (iter < opts.max_iters) : (iter += 1) {
            var response = self.nim_client.chatWithTools(self.session.getHistory(), defs) catch |err| {
                std.log.err("[agent] NIM chat failed after retries: {}", .{err});
                // Do not send a stub to the user; skip outbound.
                return try self.allocator.dupe(u8, "");
            };
            defer response.deinit(self.allocator);
            if (response.choices.len == 0) return try self.allocator.dupe(u8, "");

            var assistant = try response.choices[0].message.dupe(self.allocator);
            const has_tools = assistant.hasToolCalls();
            try self.session.addMessage(assistant);

            if (!has_tools) {
                if (core_tools.wantLeave()) {
                    engagement.unsubscribe(self.session_id);
                    std.log.info("[agent] leave chat={s}", .{self.session_id});
                    return try self.allocator.dupe(u8, "");
                }
                if (core_tools.wantSilent()) {
                    std.log.info("[agent] listen/silent chat={s}", .{self.session_id});
                    return try self.allocator.dupe(u8, "");
                }
                const text = assistant.content orelse "";
                self.transcripts.append(self.session_id, "assistant", text);
                return try self.allocator.dupe(u8, text);
            }

            const calls = assistant.tool_calls.?;
            for (calls) |call| {
                std.log.info("[agent] tool {s} args={s}", .{ call.function.name, call.function.arguments });
                const out = self.core.execute(call.function.name, call.function.arguments) catch |err|
                    try std.fmt.allocPrint(self.allocator, "tool error: {s}", .{@errorName(err)});
                defer self.allocator.free(out);
                const tool_msg = try message.toolResultMessage(self.allocator, call.id, out);
                try self.session.addMessage(tool_msg);
            }
            if (core_tools.wantLeave()) {
                engagement.unsubscribe(self.session_id);
                std.log.info("[agent] leave after tools chat={s}", .{self.session_id});
                return try self.allocator.dupe(u8, "");
            }
            if (core_tools.wantSilent()) {
                std.log.info("[agent] listen after tools chat={s}", .{self.session_id});
                return try self.allocator.dupe(u8, "");
            }
        }
        return try self.allocator.dupe(u8, "");
    }
};

test "agent loop basic" {
    const allocator = std.testing.allocator;
    _ = allocator;
}