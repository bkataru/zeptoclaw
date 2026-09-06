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
    audio_path: ?[]const u8 = null,
    audio_mime: ?[]const u8 = null,
    video_path: ?[]const u8 = null,
    video_mime: ?[]const u8 = null,
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
        const audio_path: ?[]const u8 = if (opts.audio_path) |ap| (if (ap.len > 0) ap else null) else null;
        core_tools.setAudioAttachment(audio_path, opts.audio_mime);
        if (audio_path) |ap| std.log.info("[agent] turn audio available path={s}", .{ap});
        const video_path: ?[]const u8 = if (opts.video_path) |vp| (if (vp.len > 0) vp else null) else null;
        core_tools.setVideoAttachment(video_path, opts.video_mime);
        if (video_path) |vp| std.log.info("[agent] turn video available path={s}", .{vp});
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
            var response = try self.chatUntilDone(use_tools);
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
                const raw = self.core.execute(call.function.name, call.function.arguments) catch |err|
                    try std.fmt.allocPrint(self.allocator, "tool error: {s}", .{@errorName(err)});
                defer self.allocator.free(raw);
                // Tool output is arbitrary process bytes (e.g. filenames that
                // are not valid UTF-8). NVIDIA parses request JSON as strict
                // UTF-8 and 400s the whole turn when a tool result carries
                // raw non-UTF-8 bytes — observed 2026-09-04 via `ls` output.
                // Scrub to U+FFFD so history stays valid UTF-8.
                const out = try sanitizeUtf8(self.allocator, raw);
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

    /// Transient errors (server slow, throttled, connection blip) deserve
    /// infinite retry. Anything else (bad key, malformed/rejected request)
    /// fails deterministically — retrying the identical body forever wedges
    /// the turn and swallows every later wake-up via coalescing.
    pub fn isTransient(err: types.ProviderError) bool {
        // Single definition lives on NIMClient; media tools share it too.
        return NIMClient.isTransientErr(err);
    }

    /// Permanent errors get 3 attempts, then propagate so the caller can
    /// answer gracefully instead of wedging the turn forever.
    pub const MAX_PERMANENT_RETRIES: u32 = 3;

    fn chatUntilDone(self: *Agent, defs: ?[]const types.ToolDefinition) types.ProviderError!types.ChatCompletionResponse {
        var n: u32 = 0;
        var bad: u32 = 0;
        while (true) : (n += 1) {
            if (self.nim_client.chatWithTools(self.session.getHistory(), defs)) |resp| return resp else |err| {
                std.log.warn("[agent] {} — keeping turn, retry {d}", .{ err, n + 1 });
                nim.sleepAfterFailure();
                if (!isTransient(err)) {
                    bad += 1;
                    if (bad >= MAX_PERMANENT_RETRIES) return err;
                }
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

/// Reply scrub: drop malformed UTF-8 sequences (usually truncated emoji from
/// the model) so phones never render a ?. Returns the input slice untouched
/// when already valid; otherwise an owned copy the caller must free.
/// Contrast sanitizeUtf8 below: tool output keeps U+FFFD so the model can see
/// data loss, but replies drop for clean display.
pub fn sanitizeReply(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            continue;
        };
        if (i + n > s.len) {
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i..][0..n]) catch {
            i += 1;
            continue;
        };
        const m = std.unicode.utf8CodepointSequenceLength(cp) catch {
            i += 1;
            continue;
        };
        if (m != n) {
            i += 1;
            continue;
        }
        try out.appendSlice(allocator, s[i..][0..n]);
        i += n;
    }
    return out.toOwnedSlice(allocator);
}

test "sanitizeReply drops bad bytes, keeps valid text untouched" {
    const allocator = std.testing.allocator;
    const good = "Hey \xF0\x9F\x91\x8B";
    const kept = try sanitizeReply(allocator, good);
    defer if (kept.ptr != good.ptr) allocator.free(kept);
    try std.testing.expect(kept.ptr == good.ptr);
    try std.testing.expectEqualStrings(good, kept);
    const bad = "Hey \xF0\x9F\x91 coupling";
    const fixed = try sanitizeReply(allocator, bad);
    defer allocator.free(fixed);
    try std.testing.expectEqualStrings("Hey  coupling", fixed);
    const all_bad = "\xFF\xFE";
    const empty = try sanitizeReply(allocator, all_bad);
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

/// Lossy UTF-8 scrub: copies `s`, replacing each invalid byte sequence with
/// U+FFFD. Tool subprocesses emit arbitrary bytes; request JSON must be
/// strict UTF-8 or NVIDIA 400s the turn.
fn sanitizeUtf8(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, s.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        // utf8Decode panics (unreachable) on invalid start bytes instead of
        // erroring, so classify the lead byte first, then bounds-check.
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try out.appendSlice(allocator, "\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + n > s.len) {
            try out.appendSlice(allocator, "\u{FFFD}");
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i..][0..n]) catch {
            try out.appendSlice(allocator, "\u{FFFD}");
            i += 1;
            continue;
        };
        const m = std.unicode.utf8CodepointSequenceLength(cp) catch {
            try out.appendSlice(allocator, "\u{FFFD}");
            i += 1;
            continue;
        };
        // Overlong encodings decode but re-encode shorter: reject them.
        if (m != n) {
            try out.appendSlice(allocator, "\u{FFFD}");
            i += 1;
            continue;
        }
        try out.appendSlice(allocator, s[i..][0..n]);
        i += n;
    }
    return out.toOwnedSlice(allocator);
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
    // Unique per hydration: two text-emitted calls in one turn must not
    // share an id — NVIDIA rejects the follow-up request (400) when two
    // tool messages reference the same tool_call_id.
    const seq = struct {
        var n: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);
    }.n.fetchAdd(1, .monotonic);
    const call_id = try std.fmt.allocPrint(allocator, "text-tool-{d}", .{seq});
    errdefer allocator.free(call_id);
    const calls = try allocator.alloc(types.ToolCall, 1);
    errdefer allocator.free(calls);
    calls[0] = .{
        .id = call_id,
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

test "isTransient splits retryable from fatal" {
    try std.testing.expect(Agent.isTransient(error.Timeout));
    try std.testing.expect(Agent.isTransient(error.RateLimit));
    try std.testing.expect(Agent.isTransient(error.Network));
    try std.testing.expect(!Agent.isTransient(error.InvalidResponse));
    try std.testing.expect(!Agent.isTransient(error.Auth));
    try std.testing.expect(!Agent.isTransient(error.ParseError));
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

test "hydrateToolCallsFromContent mints unique ids" {
    const allocator = std.testing.allocator;
    var m1 = try message.assistantMessage(allocator, "{\"name\":\"exec\",\"args\":{\"command\":\"pwd\"}}");
    defer m1.deinit(allocator);
    var m2 = try message.assistantMessage(allocator, "{\"name\":\"exec\",\"args\":{\"command\":\"ls\"}}");
    defer m2.deinit(allocator);
    try hydrateToolCallsFromContent(allocator, &m1);
    try hydrateToolCallsFromContent(allocator, &m2);
    try std.testing.expect(m1.hasToolCalls());
    try std.testing.expect(m2.hasToolCalls());
    const id1 = m1.tool_calls.?[0].id;
    const id2 = m2.tool_calls.?[0].id;
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
}

test "hydrateToolCallsFromContent ignores normal chat" {
    const allocator = std.testing.allocator;
    var msg = try message.assistantMessage(allocator, "hey I read SOUL.md");
    defer msg.deinit(allocator);
    try hydrateToolCallsFromContent(allocator, &msg);
    try std.testing.expect(!msg.hasToolCalls());
}

test "sanitizeUtf8 scrubs invalid bytes" {
    const allocator = std.testing.allocator;
    const dirty = "exit 0\nfile \xaa\xaa\xaa ok";
    const clean = try sanitizeUtf8(allocator, dirty);
    defer allocator.free(clean);
    try std.testing.expect(std.unicode.utf8ValidateSlice(clean));
    try std.testing.expect(std.mem.indexOf(u8, clean, "file ") != null);
    try std.testing.expect(std.mem.indexOf(u8, clean, " ok") != null);
    const valid = try sanitizeUtf8(allocator, "plain ascii");
    defer allocator.free(valid);
    try std.testing.expectEqualStrings("plain ascii", valid);
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
