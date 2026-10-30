const std = @import("std");
const types = @import("types.zig");
const config_module = @import("../config.zig");
const compat = @import("../compat.zig");




/// NIM client for NVIDIA NIM API.
/// Memory: NIMClient owns its internal `std.http.Client`; caller must call `deinit()` to free. `api_key`/`model`/`base_url` are borrowed and not freed by deinit.
fn sleepMs(ms: u64) void {
    var left = ms;
    while (left > 0) {
        const chunk: u64 = @min(left, 1000);
        const sec: i64 = @intCast(chunk / 1000);
        const nsec: i64 = @intCast((chunk % 1000) * 1_000_000);
        _ = std.c.nanosleep(&.{ .sec = sec, .nsec = nsec }, null);
        left -= chunk;
    }
}

/// NVIDIA integrate.api is 40 requests/minute. Failures slow us down; successes speed us back up.
var g_nim_pace_mu: std.Io.Mutex = .init;
var g_nim_last_s: i64 = 0;
var g_nim_min_gap_s: i64 = 2;
var g_nim_backoff_s: u64 = 2;
const NIM_MIN_GAP_S: i64 = 2;
const NIM_BACKOFF_MIN_S: u64 = 2;
const NIM_BACKOFF_MAX_S: u64 = 180;

var g_nim_shutdown: std.atomic.Value(bool) = .init(false);

pub fn setShutdown() void {
    g_nim_shutdown.store(true, .seq_cst);
}

pub fn shutdownRequested() bool {
    return g_nim_shutdown.load(.seq_cst);
}

pub const MAX_REQUEST_BYTES: usize = 32768;

/// When set (tests only), `chatWithToolsInner` returns this error before any HTTP.
var g_test_force_chat_err: ?types.ProviderError = null;
var g_test_rotate_to: ?[]const u8 = null;

pub fn nextBackoff(current: u64) u64 {
    const doubled = if (current > NIM_BACKOFF_MAX_S / 2) NIM_BACKOFF_MAX_S else current * 2;
    return @max(NIM_BACKOFF_MIN_S, @min(NIM_BACKOFF_MAX_S, doubled));
}

pub fn decayBackoff(current: u64) u64 {
    const half = current / 2;
    return if (half < NIM_BACKOFF_MIN_S) NIM_BACKOFF_MIN_S else half;
}

fn jitterMs(base_s: u64) u64 {
    var n: u8 = 0;
    compat.fillRandom(std.mem.asBytes(&n));
    const extra = (base_s * 1000 * @as(u64, n)) / (4 * 255);
    return base_s * 1000 + extra;
}

/// Wait after a failed NVIDIA call. Doubles the backoff (capped). Does not give up.
pub fn sleepAfterFailure() void {
    if (@import("builtin").is_test) return;
    if (shutdownRequested()) return;
    var wait_s: u64 = NIM_BACKOFF_MIN_S;
    g_nim_pace_mu.lock(compat.getIo()) catch {
        wait_s = g_nim_backoff_s;
        g_nim_backoff_s = nextBackoff(g_nim_backoff_s);
        std.log.warn("[nim] backing off {d}s then retrying", .{wait_s});
        sleepMs(jitterMs(wait_s));
        return;
    };
    wait_s = g_nim_backoff_s;
    g_nim_min_gap_s = @intCast(@min(@as(u64, 60), wait_s));
    g_nim_backoff_s = nextBackoff(g_nim_backoff_s);
    g_nim_pace_mu.unlock(compat.getIo());
    std.log.warn("[nim] backing off {d}s (next {d}s) then retrying; turn is not dropped", .{ wait_s, g_nim_backoff_s });
    sleepMs(jitterMs(wait_s));
}

/// After a successful NVIDIA call, speed the gap back toward normal.
pub fn noteSuccess() void {
    g_nim_pace_mu.lock(compat.getIo()) catch return;
    defer g_nim_pace_mu.unlock(compat.getIo());
    g_nim_backoff_s = decayBackoff(g_nim_backoff_s);
    g_nim_min_gap_s = @intCast(@max(NIM_MIN_GAP_S, @as(i64, @intCast(g_nim_backoff_s))));
    if (g_nim_backoff_s <= NIM_BACKOFF_MIN_S) g_nim_min_gap_s = NIM_MIN_GAP_S;
}

fn paceForRpm() void {
    var wait_ms: u64 = 0;
    g_nim_pace_mu.lock(compat.getIo()) catch return;
    const now = compat.timestamp();
    if (g_nim_last_s != 0) {
        const elapsed = now - g_nim_last_s;
        const gap = g_nim_min_gap_s;
        if (elapsed < gap) wait_ms = @intCast((gap - elapsed) * 1000);
    }
    g_nim_pace_mu.unlock(compat.getIo());
    if (wait_ms > 0) sleepMs(wait_ms);
    g_nim_pace_mu.lock(compat.getIo()) catch return;
    g_nim_last_s = compat.timestamp();
    g_nim_pace_mu.unlock(compat.getIo());
}

pub const NIMClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    timeout_ms: u32,
    max_tokens: u32 = 32768,
    fallback_models: []const []const u8 = &.{},
    client: std.http.Client,
    const DEFAULT_BASE_URL = "https://integrate.api.nvidia.com/v1/chat/completions";

    /// Permanent failures (4xx, unparseable body) get a bounded budget before
    /// the error propagates. Transient failures (Timeout, RateLimit, Network)
    /// still retry without limit — the server being slow is not a reason to
    /// drop a turn, a rejected payload is.
    pub const MAX_PERMANENT_ATTEMPTS: u32 = 3;

    /// Memory: Caller owns returned NIMClient; call `deinit()` to free http.Client resources.
    pub fn init(allocator: std.mem.Allocator, cfg: config_module.Config) NIMClient {
        return .{
            .allocator = allocator,
            .api_key = cfg.nim_api_key,
            .model = cfg.nim_model,
            .base_url = DEFAULT_BASE_URL,
            .timeout_ms = cfg.nim_timeout_ms,
            .max_tokens = cfg.max_tokens,
            .fallback_models = cfg.fallback_models,
            .client = std.http.Client{ .allocator = allocator, .io = compat.getIo() },
        };
    }

    /// Initialize with a specific model ID
    /// Initialize with a specific model ID
    /// Memory: Caller owns returned NIMClient; call `deinit()` to free http.Client resources.
    pub fn initWithModel(allocator: std.mem.Allocator, cfg: config_module.Config, model_id: []const u8) NIMClient {
        return .{
            .allocator = allocator,
            .api_key = cfg.nim_api_key,
            .model = model_id,
            .base_url = DEFAULT_BASE_URL,
            .timeout_ms = cfg.nim_timeout_ms,
            .max_tokens = cfg.max_tokens,
            .fallback_models = cfg.fallback_models,
            .client = std.http.Client{ .allocator = allocator, .io = compat.getIo() },
        };
    }

    /// Initialize with custom base URL
    /// Initialize with custom base URL
    /// Memory: Caller owns returned NIMClient; call `deinit()` to free http.Client resources. Caller retains ownership of `api_key`/`model_id`/`base_url`.
    pub fn initWithBaseUrl(allocator: std.mem.Allocator, api_key: []const u8, model_id: []const u8, base_url: []const u8) NIMClient {
        return .{
            .allocator = allocator,
            .api_key = api_key,
            .model = model_id,
            .base_url = base_url,
            .timeout_ms = 30000,
            .client = std.http.Client{ .allocator = allocator, .io = compat.getIo() },
        };
    }

/// Memory: Frees http.Client resources; does not free borrowed `api_key`/`model`/`base_url`.
pub fn deinit(self: *NIMClient) void {
    self.client.deinit();
}

    /// Change the model being used
    /// Memory: Does not allocate; borrows `model_id` until next setModel call.
    pub fn setModel(self: *NIMClient, model_id: []const u8) void {
        self.model = model_id;
    }

    /// Get the current model ID
    pub fn getModel(self: *const NIMClient) []const u8 {
        return self.model;
    }

    /// Get the API key
    pub fn getApiKey(self: *const NIMClient) []const u8 {
        return self.api_key;
    }

    /// Get the base URL
    pub fn getBaseUrl(self: *const NIMClient) []const u8 {
        return self.base_url;
    }

    /// One `{"type":kind, kind:{"url":url}}` content part (image_url, audio_url,
    /// video_url). Keeps the three media branches from triplicating stringifier calls.
    fn writeMediaUrlPart(s: anytype, kind: []const u8, url: []const u8) !void {
        try s.beginObject();
        try s.objectField("type");
        try s.write(kind);
        try s.objectField(kind);
        try s.beginObject();
        try s.objectField("url");
        try s.write(url);
        try s.endObject();
        try s.endObject();
    }

    /// Mainline resilience, shared by chat turns and media tools: transient
    /// errors (slow server, throttle, blip) deserve infinite retry; anything
    /// else fails deterministically.
    pub fn isTransientErr(err: types.ProviderError) bool {
        return switch (err) {
            error.Timeout, error.RateLimit, error.Network => true,
            else => false,
        };
    }

    /// Plain chat with mainline retry: transient errors retry forever,
    /// permanent errors get 3 attempts, then propagate. Backs off between
    /// tries like the agent loop.
    pub fn chatWithRetry(self: *NIMClient, messages: []types.Message) types.ProviderError!types.ChatCompletionResponse {
        var bad: u32 = 0;
        while (true) {
            if (self.chat(messages)) |resp| return resp else |err| {
                std.log.warn("[nim] media {s} — retrying", .{@errorName(err)});
                sleepAfterFailure();
                if (!isTransientErr(err)) {
                    bad += 1;
                    if (bad >= MAX_PERMANENT_ATTEMPTS) return err;
                }
            }
        }
    }

    /// Send chat completion request and return response
    /// Memory: Caller owns returned ChatCompletionResponse; call `response.deinit(allocator)` to free id/model/choices. Messages slice is borrowed.
    pub fn chat(self: *NIMClient, messages: []types.Message) types.ProviderError!types.ChatCompletionResponse {
        return self.chatWithTools(messages, null);
    }

    /// Step to the next fallback model, cycling back to `primary` once the list
    /// is exhausted. Rotation is per-request recovery: the caller restores the
    /// primary before returning so one bad turn cannot downgrade every later
    /// turn to a weaker model.
    fn rotateModel(self: *NIMClient, model_idx: *usize, primary: []const u8, attempt: u32) void {
        if (self.fallback_models.len == 0) return;
        const next = self.fallback_models[model_idx.* % self.fallback_models.len];
        std.log.warn("[nim] rotating model {s} -> {s} after {d} failures", .{ self.model, next, attempt });
        self.setModel(next);
        model_idx.* += 1;
        if (model_idx.* > self.fallback_models.len) {
            self.setModel(primary);
            model_idx.* = 0;
        }
    }

    fn protectedPrefixCount(messages: []const types.Message) usize {
        var last_user: ?usize = null;
        for (messages, 0..) |m, i| {
            if (m.role == .user) last_user = i;
        }
        if (last_user) |lu| return lu + 1;
        if (messages.len > 0 and messages[0].role == .system) return 1;
        return 0;
    }

    fn dropLastUnit(messages: []const types.Message, end: usize) usize {
        if (end == 0) return 0;
        const idx = end - 1;
        const m = messages[idx];
        if (m.tool_calls != null) return idx;
        return idx;
    }

    fn fixDanglingToolCalls(messages: []const types.Message, end: usize) usize {
        var k = end;
        while (k > 0) {
            var shrink: ?usize = null;
            outer: for (messages[0..k], 0..) |msg, i| {
                if (msg.tool_calls) |calls| {
                    for (calls) |call| {
                        var has_result = false;
                        for (messages[0..k]) |t| {
                            if (t.role != .tool) continue;
                            if (t.tool_call_id) |tcid| {
                                if (std.mem.eql(u8, tcid, call.id)) has_result = true;
                            }
                        }
                        if (!has_result) {
                            shrink = i;
                            break :outer;
                        }
                    }
                }
            }
            if (shrink) |s| {
                k = s;
                continue;
            }
            break;
        }
        return k;
    }

    fn trimMessageKeepCount(self: *NIMClient, messages: []types.Message, tools: ?[]const types.ToolDefinition, cap: usize) !usize {
        if (messages.len == 0) return 0;
        const full = try self.buildChatRequestBody(messages, tools);
        defer self.allocator.free(full);
        if (full.len <= cap) return messages.len;

        const prot = protectedPrefixCount(messages);
        const prot_body = try self.buildChatRequestBody(messages[0..prot], tools);
        defer self.allocator.free(prot_body);
        if (prot_body.len > cap) return messages.len;

        var end = messages.len;
        while (end > prot) {
            end = dropLastUnit(messages, end);
            end = fixDanglingToolCalls(messages, end);
            const body = try self.buildChatRequestBody(messages[0..end], tools);
            defer self.allocator.free(body);
            if (body.len <= cap) return end;
        }
        return prot;
    }

    /// Memory: Caller owns returned JSON body; `messages` and `tools` are borrowed.
    fn buildChatRequestBody(self: *NIMClient, messages: []types.Message, tools: ?[]const types.ToolDefinition) ![]u8 {
        var out = std.Io.Writer.Allocating.init(self.allocator);
        defer out.deinit();

        var stringifier = std.json.Stringify{
            .writer = &out.writer,
            .options = .{},
        };

        stringifier.beginObject() catch return error.OutOfMemory;
        stringifier.objectField("model") catch return error.OutOfMemory;
        stringifier.write(self.model) catch return error.OutOfMemory;

        stringifier.objectField("messages") catch return error.OutOfMemory;
        stringifier.beginArray() catch return error.OutOfMemory;
        for (messages) |msg| {
            try self.writeChatMessageJson(&stringifier, msg);
        }
        stringifier.endArray() catch return error.OutOfMemory;
        if (tools) |tool_list| {
            if (tool_list.len > 0) {
                stringifier.objectField("tools") catch return error.OutOfMemory;
                stringifier.beginArray() catch return error.OutOfMemory;
                for (tool_list) |t| {
                    stringifier.beginObject() catch return error.OutOfMemory;
                    stringifier.objectField("type") catch return error.OutOfMemory;
                    stringifier.write("function") catch return error.OutOfMemory;
                    stringifier.objectField("function") catch return error.OutOfMemory;
                    stringifier.beginObject() catch return error.OutOfMemory;
                    stringifier.objectField("name") catch return error.OutOfMemory;
                    stringifier.write(t.name) catch return error.OutOfMemory;
                    stringifier.objectField("description") catch return error.OutOfMemory;
                    stringifier.write(t.description) catch return error.OutOfMemory;
                    stringifier.objectField("parameters") catch return error.OutOfMemory;
                    stringifier.write(t.parameters) catch return error.OutOfMemory;
                    stringifier.endObject() catch return error.OutOfMemory;
                    stringifier.endObject() catch return error.OutOfMemory;
                }
                stringifier.endArray() catch return error.OutOfMemory;
            }
        }
        stringifier.objectField("max_tokens") catch return error.OutOfMemory;
        stringifier.write(self.max_tokens) catch return error.OutOfMemory;
        stringifier.endObject() catch return error.OutOfMemory;

        return self.allocator.dupe(u8, out.written());
    }

    fn writeChatMessageJson(self: *NIMClient, stringifier: *std.json.Stringify, msg: types.Message) !void {
        _ = self;
        stringifier.beginObject() catch return error.OutOfMemory;
        stringifier.objectField("role") catch return error.OutOfMemory;
        stringifier.write(msg.role.toString()) catch return error.OutOfMemory;
        if (msg.image_data_url != null or msg.audio_data_url != null or msg.video_data_url != null) {
            stringifier.objectField("content") catch return error.OutOfMemory;
            stringifier.beginArray() catch return error.OutOfMemory;
            stringifier.beginObject() catch return error.OutOfMemory;
            stringifier.objectField("type") catch return error.OutOfMemory;
            stringifier.write("text") catch return error.OutOfMemory;
            stringifier.objectField("text") catch return error.OutOfMemory;
            stringifier.write(msg.content orelse "") catch return error.OutOfMemory;
            stringifier.endObject() catch return error.OutOfMemory;
            if (msg.image_data_url) |url| {
                try writeMediaUrlPart(stringifier, "image_url", url);
            }
            if (msg.audio_data_url) |url| {
                try writeMediaUrlPart(stringifier, "audio_url", url);
            }
            if (msg.video_data_url) |url| {
                try writeMediaUrlPart(stringifier, "video_url", url);
            }
            stringifier.endArray() catch return error.OutOfMemory;
        } else if (msg.content) |content| {
            stringifier.objectField("content") catch return error.OutOfMemory;
            stringifier.write(content) catch return error.OutOfMemory;
        } else if (msg.role == .tool or msg.tool_calls != null) {
            stringifier.objectField("content") catch return error.OutOfMemory;
            stringifier.write("") catch return error.OutOfMemory;
        }
        if (msg.tool_call_id) |tcid| {
            stringifier.objectField("tool_call_id") catch return error.OutOfMemory;
            stringifier.write(tcid) catch return error.OutOfMemory;
        }
        if (msg.tool_calls) |calls| {
            stringifier.objectField("tool_calls") catch return error.OutOfMemory;
            stringifier.beginArray() catch return error.OutOfMemory;
            for (calls) |call| {
                stringifier.beginObject() catch return error.OutOfMemory;
                stringifier.objectField("id") catch return error.OutOfMemory;
                stringifier.write(call.id) catch return error.OutOfMemory;
                stringifier.objectField("type") catch return error.OutOfMemory;
                stringifier.write(call.@"type") catch return error.OutOfMemory;
                stringifier.objectField("function") catch return error.OutOfMemory;
                stringifier.beginObject() catch return error.OutOfMemory;
                stringifier.objectField("name") catch return error.OutOfMemory;
                stringifier.write(call.function.name) catch return error.OutOfMemory;
                stringifier.objectField("arguments") catch return error.OutOfMemory;
                stringifier.write(call.function.arguments) catch return error.OutOfMemory;
                stringifier.endObject() catch return error.OutOfMemory;
                stringifier.endObject() catch return error.OutOfMemory;
            }
            stringifier.endArray() catch return error.OutOfMemory;
        }
        stringifier.endObject() catch return error.OutOfMemory;
    }

    /// Memory: Caller owns returned ChatCompletionResponse. `messages` and `tools` are borrowed.
    pub fn chatWithTools(self: *NIMClient, messages: []types.Message, tools: ?[]const types.ToolDefinition) types.ProviderError!types.ChatCompletionResponse {
        const primary = self.model;
        defer self.setModel(primary);
        return self.chatWithToolsInner(messages, tools);
    }

    fn chatWithToolsInner(self: *NIMClient, messages: []types.Message, tools: ?[]const types.ToolDefinition) types.ProviderError!types.ChatCompletionResponse {
        if (@import("builtin").is_test) {
            if (g_test_rotate_to) |m| self.setModel(m);
            if (g_test_force_chat_err) |e| return e;
        }
        const keep = self.trimMessageKeepCount(messages, tools, MAX_REQUEST_BYTES) catch return types.ProviderError.Network;
        const body = self.buildChatRequestBody(messages[0..keep], tools) catch return types.ProviderError.Network;
        defer self.allocator.free(body);

        var attempt: u32 = 0;
        var model_idx: usize = 0;
        const primary = self.model;
        const turn_start = compat.timestamp();
        var permanent: u32 = 0;
        while (true) : (attempt += 1) {
            paceForRpm();
            const req_start = compat.timestamp();
            if (self.postOnceWithDeadline(body)) |resp| {
                const req_ms = (compat.timestamp() - req_start) * 1000;
                const turn_ms = (compat.timestamp() - turn_start) * 1000;
                const tok_in = resp.usage.prompt_tokens;
                const tok_out = resp.usage.completion_tokens;
                std.log.info("[nim] ok model={s} attempt={d} req={d}ms turn={d}ms tok_in={d} tok_out={d}", .{ self.model, attempt + 1, req_ms, turn_ms, tok_in, tok_out });
                noteSuccess();
                return resp;
            } else |err| switch (err) {
                error.RateLimit, error.Timeout, error.Network, error.InvalidResponse => {
                    // A rejected payload fails identically however often it is
                    // retried, so it gets a bounded budget and a rotation first
                    // (a text-only model rejecting an image is model-specific).
                    // Giving up lets the caller answer from what it already has
                    // instead of wedging the turn and swallowing every later
                    // message via coalescing.
                    if (!isTransientErr(err)) {
                        permanent += 1;
                        self.rotateModel(&model_idx, primary, attempt);
                        if (permanent >= MAX_PERMANENT_ATTEMPTS) {
                            std.log.err("[nim] {s} rejected {d} times on model={s}; abandoning request", .{ @errorName(err), permanent, self.model });
                            return err;
                        }
                    } else if (attempt > 0 and attempt % 2 == 0) {
                        // Transient: one retry, then move to the next model.
                        self.rotateModel(&model_idx, primary, attempt);
                    }
                    const fail_ms = (compat.timestamp() - req_start) * 1000;
                    std.log.warn("[nim] {s} attempt={d} model={s} req={d}ms; retrying", .{ @errorName(err), attempt + 1, self.model, fail_ms });
                    sleepAfterFailure();
                },
                else => {
                    const tail_n = @min(body.len, 3000);
                    std.log.warn("[nim] body tail ({d} total): {s}", .{ body.len, body[body.len - tail_n ..] });
                    for (messages, 0..) |m, i| {
                        std.log.warn("[nim] req msg[{d}] role={s} clen={d} ntcalls={d} tcid={d} img={d}", .{
                            i,
                            m.role.toString(),
                            if (m.content) |c| @as(i64, @intCast(c.len)) else @as(i64, -1),
                            if (m.tool_calls) |tc| @as(i64, @intCast(tc.len)) else @as(i64, -1),
                            @intFromBool(m.tool_call_id != null),
                            @intFromBool(m.image_data_url != null),
                        });
                        if (m.tool_calls) |tc| for (tc) |call| {
                            const an = @min(call.function.arguments.len, 300);
                            std.log.warn("[nim] req msg[{d}] call id={s} fn={s} args={s}", .{ i, call.id, call.function.name, call.function.arguments[0..an] });
                        };
                        if (m.role == .tool) {
                            const cn = @min(if (m.content) |c| c.len else 0, 200);
                            std.log.warn("[nim] req msg[{d}] tool_call_id={s} out={s}", .{ i, m.tool_call_id orelse "?", if (m.content) |c| c[0..cn] else "" });
                        }
                    }
                    return err;
                },
            }
        }
    }

    /// Wall-clock enforced wrapper: spawns postOnce in a dedicated thread
    /// with its own NIMClient clone and joins with a hard deadline. If the
    /// thread doesn't return in time (NVIDIA accepted TCP but went silent),
    /// returns Timeout. The orphaned thread owns its clone and frees it on
    /// exit; no shared mutable state after spawn.
    fn postOnceWithDeadline(self: *NIMClient, body: []const u8) types.ProviderError!types.ChatCompletionResponse {
        const deadline_sec: u64 = @divFloor(self.timeout_ms, 1000);
        const WorkerCtx = struct {
            done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
            ok: bool = false,
            resp: types.ChatCompletionResponse = undefined,
            err: types.ProviderError = error.Timeout,
            client: NIMClient,
            body: []const u8,
            alloc: std.mem.Allocator,
        };
        // Heap-allocate context so the detached thread always has a valid pointer.
        const ctx = self.allocator.create(WorkerCtx) catch return error.Network;
        var wc = NIMClient.initWithBaseUrl(self.allocator, self.api_key, self.model, self.base_url);
        wc.timeout_ms = self.timeout_ms;
        ctx.* = .{
            .client = wc,
            .body = self.allocator.dupe(u8, body) catch {
                self.allocator.destroy(ctx);
                return error.Network;
            },
            .alloc = self.allocator,
        };
        const thread = std.Thread.spawn(.{}, struct {
            fn run(c: *WorkerCtx) void {
                defer {
                    c.alloc.free(c.body);
                    c.client.deinit();
                    c.done.store(1, .release);
                }
                if (c.client.postOnce(c.body)) |resp| {
                    c.resp = resp;
                    c.ok = true;
                } else |err| {
                    c.err = err;
                }
            }
        }.run, .{ctx}) catch {
            self.allocator.free(ctx.body);
            ctx.client.deinit();
            self.allocator.destroy(ctx);
            return error.Network;
        };
        // Poll wall clock; break early if the thread signals done.
        var elapsed: u64 = 0;
        while (elapsed < deadline_sec) : (elapsed += 1) {
            if (shutdownRequested()) {
                if (ctx.done.load(.acquire) != 0) {
                    thread.join();
                    defer self.allocator.destroy(ctx);
                    if (ctx.ok) return ctx.resp;
                    return ctx.err;
                }
                thread.detach();
                return error.Timeout;
            }
            sleepMs(1000);
            if (ctx.done.load(.acquire) != 0) break;
        }
        if (ctx.done.load(.acquire) != 0) {
            thread.join();
            defer self.allocator.destroy(ctx);
            if (ctx.ok) return ctx.resp;
            return ctx.err;
        }
        // Deadline exceeded. Detach the thread — it owns ctx and will clean
        // up when NVIDIA eventually responds. The ctx allocation leaks
        // (one per hung request, cleaned on process exit).
        thread.detach();
        std.log.warn("[nim] postOnce wall-clock deadline {d}s exceeded; returning Timeout", .{deadline_sec});
        return error.Timeout;
    }

    /// 5xx is the provider having a bad time: transient, so it retries without
    /// limit. 4xx is our payload being rejected: permanent, so it gets a bounded
    /// budget — retrying a rejected body forever is what wedged turns before.
    pub fn statusToProviderError(status: std.http.Status) types.ProviderError {
        return switch (status) {
            .unauthorized => types.ProviderError.Auth,
            .too_many_requests => types.ProviderError.RateLimit,
            else => if (status.class() == .server_error)
                types.ProviderError.Network
            else
                types.ProviderError.InvalidResponse,
        };
    }

    fn postOnce(self: *NIMClient, body: []const u8) types.ProviderError!types.ChatCompletionResponse {
        const start_ns = compat.timestamp(); // fallback
        const overall_timeout_ns = @as(u64, self.timeout_ms) * std.time.ns_per_ms;

        // Build Authorization header value
        var auth_buf: std.ArrayList(u8) = .empty;
        defer auth_buf.deinit(self.allocator);
        auth_buf.appendSlice(self.allocator, "Bearer ") catch return types.ProviderError.Network;
        auth_buf.appendSlice(self.allocator, self.api_key) catch return types.ProviderError.Network;

        // Make HTTP request
        // Make HTTP request
        const uri = std.Uri.parse(self.base_url) catch return types.ProviderError.Network;
        var req = self.client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_buf.items },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return types.ProviderError.Network;
        defer req.deinit();
        // Enforce request timeout via timer checks below
        // Send body
        // Send body with timeout enforcement
        const body_mut = self.allocator.dupe(u8, body) catch return types.ProviderError.Network;
        defer self.allocator.free(body_mut);
        req.sendBodyComplete(body_mut) catch {
            if (@as(u64, @intCast(compat.timestamp() - start_ns)) * std.time.ns_per_s > overall_timeout_ns) {
                return types.ProviderError.Timeout;
            }
            return types.ProviderError.Network;
        };
        if ((@as(u64, @intCast(compat.timestamp() - start_ns)) * @as(u64, std.time.ns_per_s)) > overall_timeout_ns) {
            return types.ProviderError.Timeout;
        }

        // Receive response head
        var redirect_buffer: [1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch {
            if (@as(u64, @intCast(compat.timestamp() - start_ns)) * std.time.ns_per_s > overall_timeout_ns) {
                return types.ProviderError.Timeout;
            }
            return types.ProviderError.Network;
        };
        if ((@as(u64, @intCast(compat.timestamp() - start_ns)) * @as(u64, std.time.ns_per_s)) > overall_timeout_ns) {
            return types.ProviderError.Timeout;
        }
        // Check response status. Error bodies are small JSON diagnostics
        // (no secrets — NVIDIA never echoes the key); capture the head so
        // a deterministic 4xx names its cause instead of "InvalidResponse".
        var transfer_buffer: [4096]u8 = undefined;
        if (response.head.status != .ok) {
            const ereader = response.reader(&transfer_buffer);
            const ebytes = ereader.allocRemaining(self.allocator, .limited(512)) catch "";
            defer if (ebytes.len > 0) self.allocator.free(ebytes);
            std.log.warn("[nim] HTTP {s} from model {s}: {s}", .{ @tagName(response.head.status), self.model, ebytes });
            return statusToProviderError(response.head.status);
        }

        // Read response body
        const reader = response.reader(&transfer_buffer);

        // Read all remaining bytes from response
        const response_bytes = reader.allocRemaining(self.allocator, .limited(1024 * 1024)) catch {
            if (@as(u64, @intCast(compat.timestamp() - start_ns)) * std.time.ns_per_s > overall_timeout_ns) {
                return types.ProviderError.Timeout;
            }
            return types.ProviderError.Network;
        };
        if ((@as(u64, @intCast(compat.timestamp() - start_ns)) * @as(u64, std.time.ns_per_s)) > overall_timeout_ns) {
            return types.ProviderError.Timeout;
        }
        defer self.allocator.free(response_bytes);
        // Parse JSON response
        var parsed = tryParseCompletion(self.allocator, response_bytes) catch return types.ProviderError.InvalidResponse;
        defer parsed.deinit();
        // Deep copy out of arena before defer frees it — ChatCompletionResponse owns allocs
        const val = parsed.value;
        const duped_id = self.allocator.dupe(u8, val.id) catch return types.ProviderError.InvalidResponse;
        errdefer self.allocator.free(duped_id);
        const duped_model = self.allocator.dupe(u8, val.model) catch return types.ProviderError.InvalidResponse;
        errdefer self.allocator.free(duped_model);
        const duped_choices = self.allocator.alloc(types.Choice, val.choices.len) catch return types.ProviderError.InvalidResponse;
        for (val.choices, 0..) |ch, i| {
            var c = ch.message.dupe(self.allocator) catch return types.ProviderError.InvalidResponse;
            errdefer c.deinit(self.allocator);
            duped_choices[i] = .{ .index = ch.index, .message = c, .finish_reason = if (ch.finish_reason) |fr| self.allocator.dupe(u8, fr) catch return types.ProviderError.InvalidResponse else null };
        }
        const usage = val.usage;
        return .{ .id = duped_id, .model = duped_model, .choices = duped_choices, .created = val.created, .usage = usage };
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

/// Parse a NIM/OpenAI chat completion body. Invalid JSON or missing fields fail.
pub fn tryParseCompletion(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(types.ChatCompletionResponse) {
    return std.json.parseFromSlice(types.ChatCompletionResponse, allocator, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

test "status mapping keeps 5xx transient and 4xx permanent" {
    // A rejected payload (400) must be classified permanent so its retries stay
    // bounded; an unavailable provider (5xx) must stay transient so it retries.
    try std.testing.expectEqual(types.ProviderError.InvalidResponse, NIMClient.statusToProviderError(.bad_request));
    try std.testing.expectEqual(types.ProviderError.InvalidResponse, NIMClient.statusToProviderError(.forbidden));
    try std.testing.expectEqual(types.ProviderError.InvalidResponse, NIMClient.statusToProviderError(.not_found));
    try std.testing.expectEqual(types.ProviderError.RateLimit, NIMClient.statusToProviderError(.too_many_requests));
    try std.testing.expectEqual(types.ProviderError.Auth, NIMClient.statusToProviderError(.unauthorized));
    try std.testing.expectEqual(types.ProviderError.Network, NIMClient.statusToProviderError(.internal_server_error));
    try std.testing.expectEqual(types.ProviderError.Network, NIMClient.statusToProviderError(.bad_gateway));
    try std.testing.expect(NIMClient.isTransientErr(NIMClient.statusToProviderError(.service_unavailable)));
    try std.testing.expect(!NIMClient.isTransientErr(NIMClient.statusToProviderError(.bad_request)));
}

const TestConfig = config_module.Config;

test "NIMClient initialization" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "test-key",
        .nim_model = "test-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .nim_timeout_ms = 12345,
        .fallback_models = &.{},
        .image_model = "test-image-model",
    .vision_model = "test-vision-model",
.gateway_port = 18789,
    .gateway_mode = "local",
    .gateway_bind = "lan",
    .gateway_auth_token = null,
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
    .workspace = "/tmp/test",
    .max_concurrent = 4,
    .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
};
var client = NIMClient.init(allocator, cfg);
defer client.deinit();

try std.testing.expectEqualStrings("test-key", client.api_key);
try std.testing.expectEqualStrings("test-model", client.model);
try std.testing.expectEqual(@as(u32, 12345), client.timeout_ms);
}

test "NIMClient initWithModel" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "test-key",
        .nim_model = "default-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .nim_timeout_ms = 12345,
        .fallback_models = &.{},
        .image_model = "test-image-model",
        .vision_model = "test-vision-model",
.gateway_port = 18789,
        .gateway_mode = "local",
        .gateway_bind = "lan",
        .gateway_auth_token = null,
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
    };
    var client = NIMClient.initWithModel(allocator, cfg, "custom-model");
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
    try std.testing.expectEqualStrings("custom-model", client.model);
    try std.testing.expectEqual(@as(u32, 12345), client.timeout_ms);
}

test "NIMClient initWithBaseUrl" {
    const allocator = std.testing.allocator;
    var client = NIMClient.initWithBaseUrl(
        allocator,
        "test-key",
        "test-model",
        "https://custom.api.example.com/v1/chat/completions",
    );
    defer client.deinit();

    try std.testing.expectEqualStrings("test-key", client.api_key);
    try std.testing.expectEqualStrings("test-model", client.model);
    try std.testing.expectEqualStrings("https://custom.api.example.com/v1/chat/completions", client.base_url);
}

test "NIMClient setModel" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "test-key",
        .nim_model = "initial-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .fallback_models = &.{},
        .image_model = "test-image-model",
        .vision_model = "test-vision-model",
.gateway_port = 18789,
        .gateway_mode = "local",
        .gateway_bind = "lan",
        .gateway_auth_token = null,
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
    };
    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    try std.testing.expectEqualStrings("initial-model", client.getModel());

    client.setModel("new-model");
    try std.testing.expectEqualStrings("new-model", client.getModel());
}

test "NIMClient getModel" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "test-key",
        .nim_model = "test-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .fallback_models = &.{},
        .image_model = "test-image-model",
        .vision_model = "test-vision-model",
.gateway_port = 18789,
        .gateway_mode = "local",
        .gateway_bind = "lan",
        .gateway_auth_token = null,
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
    };
    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    try std.testing.expectEqualStrings("test-model", client.getModel());
}

test "NIMClient getApiKey" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "secret-key",
        .nim_model = "test-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .fallback_models = &.{},
        .image_model = "test-image-model",
        .vision_model = "test-vision-model",
.gateway_port = 18789,
        .gateway_mode = "local",
        .gateway_bind = "lan",
        .gateway_auth_token = null,
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
    };
    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    try std.testing.expectEqualStrings("secret-key", client.getApiKey());
}

test "NIMClient getBaseUrl" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "test-key",
        .nim_model = "test-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .fallback_models = &.{},
        .image_model = "test-image-model",
        .vision_model = "test-vision-model",
.gateway_port = 18789,
        .gateway_mode = "local",
        .gateway_bind = "lan",
        .gateway_auth_token = null,
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
    };
    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    try std.testing.expectEqualStrings(NIMClient.DEFAULT_BASE_URL, client.getBaseUrl());
    // Verify the URL is correctly set to NVIDIA NIM endpoint
    // Verify the URL is correctly set to NVIDIA NIM endpoint
    try std.testing.expectEqualStrings("https://integrate.api.nvidia.com/v1/chat/completions", NIMClient.DEFAULT_BASE_URL);
}

test "NIMClient deinit does not crash" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "test-key",
        .nim_model = "test-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .fallback_models = &.{},
        .image_model = "test-image-model",
        .vision_model = "test-vision-model",
.gateway_port = 18789,
        .gateway_mode = "local",
        .gateway_bind = "lan",
        .gateway_auth_token = null,
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
    };
    var client = NIMClient.init(allocator, cfg);
    client.deinit();
}

test "NIMClient handles empty API key" {
    const allocator = std.testing.allocator;
    const cfg = TestConfig{
        .allocator = allocator,
        .nim_api_key = "",
        .nim_model = "test-model",
        .max_iterations = 10,
        .temperature = 0.7,
        .max_tokens = 1024,
        .fallback_models = &.{},
        .image_model = "test-image-model",
        .vision_model = "test-vision-model",
.gateway_port = 18789,
        .gateway_mode = "local",
        .gateway_bind = "lan",
        .gateway_auth_token = null,
        .gateway_control_ui_enabled = true,
        .gateway_allow_insecure_auth = false,
        .workspace = "/tmp/test",
        .max_concurrent = 4,
        .source = .default,
        .whatsapp_enabled = false,
        .whatsapp_auth_dir = "/tmp",
        .whatsapp_dm_policy = "pairing",
        .whatsapp_allow_from = &.{},
        .whatsapp_group_policy = "allowlist",
        .whatsapp_media_max_mb = 50,
        .whatsapp_debounce_ms = 0,
        .whatsapp_send_read_receipts = false,
        .whatsapp_group_require_mention = false,
        .whatsapp_group_activation_commands = &.{},
    };
    var client = NIMClient.init(allocator, cfg);
    defer client.deinit();

    try std.testing.expectEqualStrings("", client.api_key);
}

test "NIMClient model name flexibility" {
    const allocator = std.testing.allocator;

    // Test with various model names
    const models = [_][]const u8{
        "thinkingmachines/inkling",
        "meta/llama3-70b-instruct",
        "mistralai/mixtral-8x7b-instruct-v0.1",
        "",
    };

    for (models) |model_name| {
        const cfg = TestConfig{
            .allocator = allocator,
            .nim_api_key = "test-key",
            .nim_model = model_name,
            .max_iterations = 10,
            .temperature = 0.7,
            .max_tokens = 1024,
            .fallback_models = &.{},
            .image_model = "test-image-model",
            .vision_model = "test-vision-model",
.gateway_port = 18789,
            .gateway_mode = "local",
            .gateway_bind = "lan",
            .gateway_auth_token = null,
            .gateway_control_ui_enabled = true,
            .gateway_allow_insecure_auth = false,
            .workspace = "/tmp/test",
            .max_concurrent = 4,
            .source = .default,
            .whatsapp_enabled = false,
            .whatsapp_auth_dir = "/tmp",
            .whatsapp_dm_policy = "pairing",
            .whatsapp_allow_from = &.{},
            .whatsapp_group_policy = "allowlist",
            .whatsapp_media_max_mb = 50,
            .whatsapp_debounce_ms = 0,
            .whatsapp_send_read_receipts = false,
            .whatsapp_group_require_mention = false,
            .whatsapp_group_activation_commands = &.{},
        };
        var client = NIMClient.init(allocator, cfg);
        defer client.deinit();

        try std.testing.expectEqualStrings(model_name, client.model);
    }
}

test "nim backoff doubles then caps" {
    try std.testing.expectEqual(@as(u64, 4), nextBackoff(2));
    try std.testing.expectEqual(@as(u64, 8), nextBackoff(4));
    try std.testing.expectEqual(@as(u64, 180), nextBackoff(128));
    try std.testing.expectEqual(@as(u64, 180), nextBackoff(180));
}

test "nim backoff decays toward minimum" {
    try std.testing.expectEqual(@as(u64, 90), decayBackoff(180));
    try std.testing.expectEqual(@as(u64, 2), decayBackoff(3));
    try std.testing.expectEqual(@as(u64, 2), decayBackoff(2));
}

test "nim transient classifier" {
    try std.testing.expect(NIMClient.isTransientErr(error.Timeout));
    try std.testing.expect(NIMClient.isTransientErr(error.RateLimit));
    try std.testing.expect(NIMClient.isTransientErr(error.Network));
    try std.testing.expect(!NIMClient.isTransientErr(error.InvalidResponse));
    try std.testing.expect(!NIMClient.isTransientErr(error.Auth));
}

const trim_test_message = @import("../agent/message.zig");

fn testPad(allocator: std.mem.Allocator, n: usize) ![]u8 {
    const s = try allocator.alloc(u8, n);
    @memset(s, 'x');
    return s;
}

test "shutdownRequested and sleepAfterFailure" {
    const prev = g_nim_shutdown.load(.seq_cst);
    defer g_nim_shutdown.store(prev, .seq_cst);
    setShutdown();
    try std.testing.expect(shutdownRequested());
    sleepAfterFailure();
}

test "chatWithTools restores primary model on error return" {
    const allocator = std.testing.allocator;
    var client = NIMClient.initWithBaseUrl(allocator, "k", "primary-model", "http://127.0.0.1:1");
    defer client.deinit();
    g_test_force_chat_err = error.Auth;
    defer g_test_force_chat_err = null;
    var msg = try trim_test_message.userMessage(allocator, "hi");
    defer msg.deinit(allocator);
    var msgs = [_]types.Message{msg};
    g_test_rotate_to = "leaked-fallback";
    defer g_test_rotate_to = null;
    const msgs_slice: []types.Message = &msgs;
    const err = client.chatWithTools(msgs_slice, null) catch |e| e;
    try std.testing.expectEqual(types.ProviderError.Auth, err);
    try std.testing.expectEqualStrings("primary-model", client.getModel());
}

test "trimMessageKeepCount respects cap and protected prefix" {
    const allocator = std.testing.allocator;
    var client = NIMClient.initWithBaseUrl(allocator, "k", "m", "http://127.0.0.1:1");
    defer client.deinit();
    client.max_tokens = 64;

    var sys = types.Message{ .role = .system, .content = try testPad(allocator, 120) };
    defer sys.deinit(allocator);
    const old_pad = try testPad(allocator, 400);
    defer allocator.free(old_pad);
    var old = try trim_test_message.userMessage(allocator, old_pad);
    defer old.deinit(allocator);
    var user = try trim_test_message.userMessage(allocator, "current");
    defer user.deinit(allocator);
    const drop_pad = try testPad(allocator, 8000);
    defer allocator.free(drop_pad);
    var drop = try trim_test_message.assistantMessage(allocator, drop_pad);
    defer drop.deinit(allocator);

    var msgs = [_]types.Message{ sys, old, user, drop };
    const cap: usize = 1800;
    const msgs_slice: []types.Message = &msgs;
    const keep = try client.trimMessageKeepCount(msgs_slice, null, cap);
    const body = try client.buildChatRequestBody(msgs[0..keep], null);
    defer allocator.free(body);
    try std.testing.expect(keep >= 3);
    try std.testing.expect(body.len <= cap);
    try std.testing.expectEqual(@as(usize, 3), keep);
}

test "trimMessageKeepCount sends protected prefix as-is when alone over cap" {
    const allocator = std.testing.allocator;
    var client = NIMClient.initWithBaseUrl(allocator, "k", "m", "http://127.0.0.1:1");
    defer client.deinit();
    client.max_tokens = 16;
    var sys = types.Message{ .role = .system, .content = try testPad(allocator, 500) };
    defer sys.deinit(allocator);
    const user_pad = try testPad(allocator, 500);
    defer allocator.free(user_pad);
    var user = try trim_test_message.userMessage(allocator, user_pad);
    defer user.deinit(allocator);
    var msgs = [_]types.Message{ sys, user };
    const msgs_slice: []types.Message = &msgs;
    const keep = try client.trimMessageKeepCount(msgs_slice, null, 256);
    try std.testing.expectEqual(msgs.len, keep);
    const body = try client.buildChatRequestBody(&msgs, null);
    defer allocator.free(body);
    try std.testing.expect(body.len > 256);
}

test "trimMessageKeepCount drops tool call unit together" {
    const allocator = std.testing.allocator;
    var client = NIMClient.initWithBaseUrl(allocator, "k", "m", "http://127.0.0.1:1");
    defer client.deinit();
    client.max_tokens = 32;
    var user = try trim_test_message.userMessage(allocator, "q");
    defer user.deinit(allocator);
    var asst = try trim_test_message.assistantMessage(allocator, "");
    defer asst.deinit(allocator);
    const call_id = try allocator.dupe(u8, "tc1");
    asst.tool_calls = try allocator.alloc(types.ToolCall, 1);
    asst.tool_calls.?[0] = .{
        .id = call_id,
        .@"type" = try allocator.dupe(u8, "function"),
        .function = .{
            .name = try allocator.dupe(u8, "exec"),
            .arguments = try allocator.dupe(u8, "{}"),
        },
    };
    const tool_pad = try testPad(allocator, 6000);
    defer allocator.free(tool_pad);
    var tool = try trim_test_message.toolResultMessage(allocator, "tc1", tool_pad);
    defer tool.deinit(allocator);
    const tail_pad = try testPad(allocator, 6000);
    defer allocator.free(tail_pad);
    var tail = try trim_test_message.assistantMessage(allocator, tail_pad);
    defer tail.deinit(allocator);
    var msgs = [_]types.Message{ user, asst, tool, tail };
    const msgs_slice: []types.Message = &msgs;
    const keep = try client.trimMessageKeepCount(msgs_slice, null, 2048);
    try std.testing.expectEqual(@as(usize, 1), keep);
    const body = try client.buildChatRequestBody(msgs[0..keep], null);
    defer allocator.free(body);
    try std.testing.expect(body.len <= 2048);
}
