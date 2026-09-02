const std = @import("std");
const types = @import("../providers/types.zig");
const message = @import("message.zig");
const Session = @import("../channels/session.zig").Session;
const nim = @import("../providers/nim.zig");
const NIMClient = nim.NIMClient;
const tools_mod = @import("tools.zig");
const core_tools = @import("core_tools.zig");
const transcript = @import("transcript.zig");
const openclaw = @import("../openclaw_compat/openclaw.zig");
const compat = @import("../compat.zig");
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
    max_iters: u32 = 200,
    image_path: ?[]const u8 = null,
    image_mime: ?[]const u8 = null,
};

const DEFAULT_VISION_MODEL = "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning";

pub const Agent = struct {
    allocator: std.mem.Allocator,
    session: Session,
    nim_client: *NIMClient,
    workspace: []const u8,
    session_id: []const u8,
    vision_model: []const u8 = DEFAULT_VISION_MODEL,
    core: tools_mod.ToolRegistry,
    params: core_tools.ParamHold,
    skill_metadata: skills.SkillMetadata,
    exec_tools: execution_context.ToolRegistry,
    transcripts: transcript.Store,
    owns_workspace: bool = false,
    owns_transcript_dir: bool = false,

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

        const tdir = try compat.homeJoin(allocator, ".zeptoclaw/sessions/transcripts");

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
            .transcripts = transcript.Store.init(allocator, tdir),
            .owns_workspace = owns,
            .owns_transcript_dir = true,
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

    /// Sets the vision-capable model the `see_image` tool dispatches to for this agent's turns.
    pub fn setVisionModel(self: *Agent, model: []const u8) void {
        if (model.len > 0) self.vision_model = model;
    }

    /// Memory: Callee takes responsibility for session, registries, skill metadata.
    pub fn deinit(self: *Agent) void {
        self.session.deinit();
        self.core.deinit();
        self.params.deinit();
        self.skill_metadata.deinit(self.allocator);
        self.exec_tools.deinit();
        git_workflow.skill.deinit(self.allocator);
        if (self.owns_workspace) {
            self.allocator.free(self.workspace);
            self.owns_workspace = false;
        }
        if (self.owns_transcript_dir) {
            self.allocator.free(self.transcripts.dir);
            self.owns_transcript_dir = false;
        }
    }

    /// Memory: Caller owns returned slice; call allocator.free.
    pub fn run(self: *Agent, initial_user_message: []const u8) ![]const u8 {
        return self.runTurn(initial_user_message, .{});
    }

    /// Memory: Caller owns returned reply text.
    pub fn runTurn(self: *Agent, user_text: []const u8, opts: TurnOpts) ![]const u8 {
        core_tools.setWorkspace(self.workspace);
        core_tools.setChatId(self.session_id);
        core_tools.resetPresence();
        core_tools.setVisionClient(self.nim_client.api_key, self.vision_model, self.nim_client.base_url);
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
        const vision_path: ?[]const u8 = if (opts.image_path) |ip| (if (ip.len > 0) ip else null) else null;
        core_tools.setVisionImage(vision_path, opts.image_mime);
        if (vision_path) |vp| std.log.info("[agent] vision image available path={s}", .{vp});
        try self.session.addMessage(user_msg);
        self.transcripts.append(self.session_id, "user", user_text);

        const defs = try core_tools.collectDefinitions(&self.core, self.allocator);
        defer {
            for (defs) |*d| d.deinit(self.allocator);
            self.allocator.free(defs);
        }

        var tool_rounds: u32 = 0;
        while (true) {
            if (tool_rounds >= opts.max_iters) {
                std.log.warn("[agent] tool round cap {d}; asking for text without tools", .{opts.max_iters});
            }
            const use_tools: ?[]const types.ToolDefinition = if (tool_rounds >= opts.max_iters) null else defs;
            var response = self.chatUntilDone(use_tools);
            defer response.deinit(self.allocator);
            if (response.choices.len == 0) {
                std.log.warn("[agent] empty choices; keeping this turn, backing off", .{});
                nim.sleepAfterFailure();
                continue;
            }

            var assistant = try response.choices[0].message.dupe(self.allocator);
            if (!assistant.hasToolCalls()) {
                try hydrateToolCallsFromContent(self.allocator, &assistant);
            }
            const has_tools = assistant.hasToolCalls();
            if (!has_tools) {
                if (core_tools.wantLeave()) {
                    assistant.deinit(self.allocator);
                    engagement.unsubscribe(self.session_id);
                    std.log.info("[agent] leave chat={s}", .{self.session_id});
                    return try self.allocator.dupe(u8, "");
                }
                if (core_tools.wantSilent()) {
                    assistant.deinit(self.allocator);
                    std.log.info("[agent] listen/silent chat={s}", .{self.session_id});
                    return try self.allocator.dupe(u8, "");
                }
                const text = assistant.content orelse "";
                if (isBlank(text)) {
                    assistant.deinit(self.allocator);
                    std.log.warn("[agent] empty model content; keeping this turn, backing off", .{});
                    nim.sleepAfterFailure();
                    continue;
                }
                try self.session.addMessage(assistant);
                self.transcripts.append(self.session_id, "assistant", text);
                nim.noteSuccess();
                return try self.allocator.dupe(u8, text);
            }

            try self.session.addMessage(assistant);
            const calls = assistant.tool_calls.?;
            for (calls) |call| {
                std.log.info("[agent] tool {s} args={s}", .{ call.function.name, call.function.arguments });
                const out = self.core.execute(call.function.name, call.function.arguments) catch |err|
                    try std.fmt.allocPrint(self.allocator, "tool error: {s}", .{@errorName(err)});
                defer self.allocator.free(out);
                const tool_msg = try message.toolResultMessage(self.allocator, call.id, out);
                try self.session.addMessage(tool_msg);
            }
            tool_rounds += 1;
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
    }

    fn chatUntilDone(self: *Agent, defs: ?[]const types.ToolDefinition) types.ChatCompletionResponse {
        var n: u32 = 0;
        while (true) : (n += 1) {
            if (self.nim_client.chatWithTools(self.session.getHistory(), defs)) |resp| return resp else |err| {
                std.log.warn("[agent] {} — keeping turn, retry {d}", .{ err, n + 1 });
                nim.sleepAfterFailure();
            }
        }
    }
};

fn isBlank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r\n").len == 0;
}

fn jsonValueToOwnedString(allocator: std.mem.Allocator, v: std.json.Value) ![]u8 {
    if (v == .string) return allocator.dupe(u8, v.string);
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var stringifier = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    stringifier.write(v) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written());
}

fn hydrateToolCallsFromContent(allocator: std.mem.Allocator, assistant: *types.Message) !void {
    const raw = assistant.content orelse return;
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len < 12 or text[0] != '{') return;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const obj = parsed.value.object;
    const name = blk: {
        if (obj.get("name")) |n| if (n == .string) break :blk n.string;
        if (obj.get("tool")) |n| if (n == .string) break :blk n.string;
        return;
    };
    const args = blk: {
        if (obj.get("args")) |a| break :blk try jsonValueToOwnedString(allocator, a);
        if (obj.get("arguments")) |a| break :blk try jsonValueToOwnedString(allocator, a);
        return;
    };
    errdefer allocator.free(args);
    const calls = try allocator.alloc(types.ToolCall, 1);
    errdefer allocator.free(calls);
    calls[0] = .{
        .id = try allocator.dupe(u8, "text-tool-1"),
        .@"type" = try allocator.dupe(u8, "function"),
        .function = .{
            .name = try allocator.dupe(u8, name),
            .arguments = args,
        },
    };
    if (assistant.content) |c| {
        allocator.free(c);
        assistant.content = null;
    }
    assistant.tool_calls = calls;
    std.log.info("[agent] hydrated tool {s} from text JSON", .{name});
}

test "agent loop basic" {
    const opts = TurnOpts{};
    try std.testing.expectEqual(@as(u32, 200), opts.max_iters);
    try std.testing.expect(opts.system_prompt == null);
}

test "isBlank treats whitespace as empty" {
    try std.testing.expect(isBlank(""));
    try std.testing.expect(isBlank("  \n\t"));
    try std.testing.expect(!isBlank("ok"));
}

test "hydrateToolCallsFromContent parses exec json" {
    const allocator = std.testing.allocator;
    var msg = try message.assistantMessage(allocator, "{\"name\":\"exec\",\"args\":{\"command\":\"cat memory/2026-08-22.md\"}}");
    defer msg.deinit(allocator);
    try hydrateToolCallsFromContent(allocator, &msg);
    try std.testing.expect(msg.hasToolCalls());
    try std.testing.expectEqualStrings("exec", msg.tool_calls.?[0].function.name);
    try std.testing.expect(std.mem.indexOf(u8, msg.tool_calls.?[0].function.arguments, "cat memory") != null);
}

test "hydrateToolCallsFromContent ignores normal chat" {
    const allocator = std.testing.allocator;
    var msg = try message.assistantMessage(allocator, "hey I read SOUL.md");
    defer msg.deinit(allocator);
    try hydrateToolCallsFromContent(allocator, &msg);
    try std.testing.expect(!msg.hasToolCalls());
}

test "setWorkspace does not drop transcript dir ownership" {
    const allocator = std.testing.allocator;
    const tdir = try allocator.dupe(u8, "/tmp/zeptoclaw-transcript-own");
    var agent = Agent{
        .allocator = allocator,
        .session = Session.init(allocator, 4),
        .nim_client = undefined,
        .workspace = "old-ws",
        .session_id = "t",
        .core = tools_mod.ToolRegistry.init(allocator),
        .params = .{},
        .skill_metadata = undefined,
        .exec_tools = execution_context.ToolRegistry.init(allocator),
        .transcripts = transcript.Store.init(allocator, tdir),
        .owns_workspace = false,
        .owns_transcript_dir = true,
    };
    agent.setWorkspace("/tmp/zeptoclaw-ws-borrowed");
    try std.testing.expect(agent.owns_transcript_dir);
    try std.testing.expectEqualStrings(tdir, agent.transcripts.dir);
    agent.session.deinit();
    agent.core.deinit();
    agent.exec_tools.deinit();
    if (agent.owns_transcript_dir) {
        allocator.free(agent.transcripts.dir);
        agent.owns_transcript_dir = false;
    }
}
fn fuzzHydrate(_: void, smith: *std.testing.Smith) !void {
    var buf: [512]u8 = undefined;
    const n = smith.slice(&buf);
    const allocator = std.testing.allocator;
    var msg = try message.assistantMessage(allocator, buf[0..n]);
    defer msg.deinit(allocator);
    hydrateToolCallsFromContent(allocator, &msg) catch return;
}

test "fuzz hydrate tool json" {
    try std.testing.fuzz({}, fuzzHydrate, .{
        .corpus = &.{
            "hello",
            "{\"name\":\"exec\",\"args\":{\"command\":\"true\"}}",
            "{\"tool\":\"memory_get\",\"arguments\":[]}",
            "{",
            "{\"name\":1}",
            "{\"name\":\"x\"}",
        },
    });
}
