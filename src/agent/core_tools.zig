//! Workspace-scoped tools the model may call (OpenClaw-style read/write/edit/exec).
const std = @import("std");
const compat = @import("../compat.zig");
const types = @import("../providers/types.zig");
const tools = @import("tools.zig");
const memory = @import("memory.zig");
const message = @import("message.zig");
const nim = @import("../providers/nim.zig");
const inbound_media = @import("../channels/whatsapp/inbound_media.zig");

const Allocator = std.mem.Allocator;

threadlocal var g_workspace: []const u8 = ".";
threadlocal var g_exec_enabled: bool = true;

pub fn setWorkspace(path: []const u8) void {
    g_workspace = path;
}

pub fn setExecEnabled(on: bool) void {
    g_exec_enabled = on;
}

pub fn execEnabled() bool {
    return g_exec_enabled;
}

pub fn workspace() []const u8 {
    return g_workspace;
}

threadlocal var g_chat_id: []const u8 = "agent";

threadlocal var g_vision_image_path: ?[]const u8 = null;
threadlocal var g_vision_image_mime: []const u8 = "image/jpeg";
threadlocal var g_vision_api_key: []const u8 = "";
threadlocal var g_vision_model: []const u8 = "";
threadlocal var g_vision_base_url: []const u8 = "";
    const vision_breaker_trips: u32 = 3;
    const vision_breaker_cooldown_s: i64 = 600;
    var g_vision_fail_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
    var g_vision_last_fail_sec: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
    /// True while the breaker is open: repeated vision failures within cooldown.
    fn visionBreakerOpen() bool {
        if (g_vision_fail_count.load(.acquire) < vision_breaker_trips) return false;
        const dt = compat.timestamp() - g_vision_last_fail_sec.load(.acquire);
        if (dt < vision_breaker_cooldown_s) return true;
        g_vision_fail_count.store(0, .release);
        return false;
    }
    fn visionNoteFailure() void {
        _ = g_vision_fail_count.fetchAdd(1, .monotonic);
        g_vision_last_fail_sec.store(compat.timestamp(), .release);
    }

/// Sets the image attached to the current turn (if any). Call once per turn; pass null to clear.
pub fn setVisionImage(path: ?[]const u8, mime: ?[]const u8) void {
    g_vision_image_path = path;
    g_vision_image_mime = mime orelse "image/jpeg";
}

/// Sets the vision-capable model the `see_image` tool dispatches to.
pub fn setVisionClient(api_key: []const u8, model: []const u8, base_url: []const u8) void {
    g_vision_api_key = api_key;
    g_vision_model = model;
    g_vision_base_url = base_url;
}

pub fn setChatId(id: []const u8) void {
    g_chat_id = id;
}

fn jsonStr(parsed: std.json.Value, key: []const u8) ?[]const u8 {
    if (parsed != .object) return null;
    const v = parsed.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Memory: Caller owns returned path; free with allocator. Rejects escapes outside workspace.
fn resolveInWorkspace(allocator: Allocator, rel: []const u8) ![]u8 {
    if (rel.len == 0) return error.InvalidPath;
    if (std.mem.indexOf(u8, rel, "\x00") != null) return error.InvalidPath;
    if (std.fs.path.isAbsolute(rel)) {
        if (!std.mem.startsWith(u8, rel, g_workspace)) return error.PathEscape;
        return allocator.dupe(u8, rel);
    }
    return std.fs.path.join(allocator, &.{ g_workspace, rel });
}

/// Memory: Caller owns returned UTF-8 slice.
pub fn readTool(allocator: Allocator, args: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch
        return allocator.dupe(u8, "error: invalid json");
    defer parsed.deinit();
    const path_rel = jsonStr(parsed.value, "path") orelse return allocator.dupe(u8, "error: missing path");
    const full = resolveInWorkspace(allocator, path_rel) catch |err|
        return std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)});
    defer allocator.free(full);
    const cwd = compat.cwd();
    const f = cwd.openFile(full, .{}) catch |err|
        return std.fmt.allocPrint(allocator, "error: open {s}: {s}", .{ path_rel, @errorName(err) });
    defer f.close(cwd.io);
    const st = f.stat(cwd.io) catch return allocator.dupe(u8, "error: stat failed");
    const sz: usize = @intCast(@min(st.size, 64 * 1024));
    const buf = try allocator.alloc(u8, sz);
    var rdr = f.reader(cwd.io, &[_]u8{});
    rdr.interface.readSliceAll(buf) catch {
        allocator.free(buf);
        return allocator.dupe(u8, "error: read failed");
    };
    return buf;
}

/// Memory: Caller owns returned status string.
pub fn writeTool(allocator: Allocator, args: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch
        return allocator.dupe(u8, "error: invalid json");
    defer parsed.deinit();
    const path_rel = jsonStr(parsed.value, "path") orelse return allocator.dupe(u8, "error: missing path");
    const content = jsonStr(parsed.value, "content") orelse return allocator.dupe(u8, "error: missing content");
    const full = resolveInWorkspace(allocator, path_rel) catch |err|
        return std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)});
    defer allocator.free(full);
    const cwd = compat.cwd();
    if (std.fs.path.dirname(full)) |dir| {
        std.Io.Dir.createDirPath(cwd.dir, cwd.io, dir) catch {};
    }
    const f = cwd.createFile(full, .{ .truncate = true }) catch |err|
        return std.fmt.allocPrint(allocator, "error: create {s}: {s}", .{ path_rel, @errorName(err) });
    defer f.close(cwd.io);
    var w = f.writer(cwd.io, &[_]u8{});
    w.interface.writeAll(content) catch return allocator.dupe(u8, "error: write failed");
    return std.fmt.allocPrint(allocator, "wrote {d} bytes to {s}", .{ content.len, path_rel });
}

/// Memory: Caller owns returned status string. Replaces first occurrence of old_str.
pub fn editTool(allocator: Allocator, args: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch
        return allocator.dupe(u8, "error: invalid json");
    defer parsed.deinit();
    const path_rel = jsonStr(parsed.value, "path") orelse return allocator.dupe(u8, "error: missing path");
    const old_str = jsonStr(parsed.value, "old_str") orelse return allocator.dupe(u8, "error: missing old_str");
    const new_str = jsonStr(parsed.value, "new_str") orelse return allocator.dupe(u8, "error: missing new_str");
    const full = resolveInWorkspace(allocator, path_rel) catch |err|
        return std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)});
    defer allocator.free(full);
    const current = blk: {
        const cwd = compat.cwd();
        const f = cwd.openFile(full, .{}) catch |err|
            break :blk try std.fmt.allocPrint(allocator, "error: open {s}: {s}", .{ path_rel, @errorName(err) });
        defer f.close(cwd.io);
        const st = f.stat(cwd.io) catch break :blk try allocator.dupe(u8, "error: stat failed");
        const sz: usize = @intCast(@min(st.size, 256 * 1024));
        const buf = try allocator.alloc(u8, sz);
        var rdr = f.reader(cwd.io, &[_]u8{});
        rdr.interface.readSliceAll(buf) catch {
            allocator.free(buf);
            break :blk try allocator.dupe(u8, "error: read failed");
        };
        break :blk buf;
    };
    defer allocator.free(current);
    if (std.mem.startsWith(u8, current, "error:")) return allocator.dupe(u8, current);
    const idx = std.mem.indexOf(u8, current, old_str) orelse
        return allocator.dupe(u8, "error: old_str not found");
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, current[0..idx]);
    try out.appendSlice(allocator, new_str);
    try out.appendSlice(allocator, current[idx + old_str.len ..]);
    const cwd = compat.cwd();
    const f = cwd.createFile(full, .{ .truncate = true }) catch
        return allocator.dupe(u8, "error: rewrite failed");
    defer f.close(cwd.io);
    var w = f.writer(cwd.io, &[_]u8{});
    w.interface.writeAll(out.items) catch return allocator.dupe(u8, "error: write failed");
    return allocator.dupe(u8, "ok");
}

/// Memory: Caller owns returned stdout/stderr text. Runs `/bin/sh -c` in workspace.
pub fn execTool(allocator: Allocator, args: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch
        return allocator.dupe(u8, "error: invalid json");
    defer parsed.deinit();
    const command = jsonStr(parsed.value, "command") orelse return allocator.dupe(u8, "error: missing command");
    if (command.len == 0) return allocator.dupe(u8, "error: empty command");

    if (!execEnabled()) {
        return allocator.dupe(u8, "error: exec denied (operator fromMe DM only)");
    }

    if (!execApproved(command)) {
        writePending(command);
        return allocator.dupe(u8, "error: exec denied. Approve by setting ZEPTO_EXEC_APPROVE=1, or POST /exec/approve {\"command\":\"...\"} / append the exact command to sessions/exec-approvals.txt");
    }

    const result = compat.runParentEnv(
        allocator,
        &.{ "/bin/sh", "-c", command },
        .limited(64 * 1024),
        .limited(16 * 1024),
        g_workspace,
    ) catch |err| {
        return std.fmt.allocPrint(allocator, "error: exec {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const code: u32 = switch (result.term) {
        .exited => |c| c,
        else => 1,
    };
    return std.fmt.allocPrint(allocator, "exit {d}\n{s}{s}", .{ code, result.stdout, result.stderr });
}



var g_approvals_path: ?[]const u8 = null;
var g_pending_path: ?[]const u8 = null;

fn approvalsPath() []const u8 {
    if (g_approvals_path) |p| return p;
    const pth = compat.homeJoin(std.heap.page_allocator, ".zeptoclaw/sessions/exec-approvals.txt") catch return "sessions/exec-approvals.txt";
    g_approvals_path = pth;
    return pth;
}
fn pendingPath() []const u8 {
    if (g_pending_path) |p| return p;
    const pth = compat.homeJoin(std.heap.page_allocator, ".zeptoclaw/sessions/exec-pending.txt") catch return "sessions/exec-pending.txt";
    g_pending_path = pth;
    return pth;
}

fn fileContainsLine(path: []const u8, needle: []const u8) bool {
    const cwd = compat.cwd();
    const f = cwd.openFile(path, .{}) catch return false;
    defer f.close(cwd.io);
    const st = f.stat(cwd.io) catch return false;
    const sz: usize = @intCast(@min(st.size, 64 * 1024));
    const buf = std.heap.page_allocator.alloc(u8, sz) catch return false;
    defer std.heap.page_allocator.free(buf);
    var rdr = f.reader(cwd.io, &[_]u8{});
    rdr.interface.readSliceAll(buf) catch return false;
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0 and std.mem.eql(u8, t, needle)) return true;
    }
    return false;
}

fn appendLine(path: []const u8, line: []const u8) void {
    const cwd = compat.cwd();
    std.Io.Dir.createDirPath(cwd.dir, cwd.io, "sessions") catch {};
    var existing: []u8 = &.{};
    if (cwd.openFile(path, .{})) |f| {
        defer f.close(cwd.io);
        const st = f.stat(cwd.io) catch return;
        if (st.size > 0) {
            const sz: usize = @intCast(@min(st.size, 64 * 1024));
            existing = std.heap.page_allocator.alloc(u8, sz) catch return;
            var rdr = f.reader(cwd.io, &[_]u8{});
            _ = rdr.interface.readSliceAll(existing) catch {
                std.heap.page_allocator.free(existing);
                existing = &.{};
            };
        }
    } else |_| {}
    defer if (existing.len > 0) std.heap.page_allocator.free(existing);
    const outf = cwd.createFile(path, .{ .truncate = true }) catch return;
    defer outf.close(cwd.io);
    var w = outf.writer(cwd.io, &[_]u8{});
    if (existing.len > 0) w.interface.writeAll(existing) catch return;
    w.interface.writeAll(line) catch return;
    w.interface.writeAll("\n") catch return;
}

fn writePending(command: []const u8) void {
    if (!fileContainsLine(pendingPath(), command)) appendLine(pendingPath(), command);
}

/// Memory: no heap return. Appends command to sessions/exec-approvals.txt.
pub fn approveExec(command: []const u8) void {
    const t = std.mem.trim(u8, command, " \t\r\n");
    if (t.len == 0) return;
    if (!fileContainsLine(approvalsPath(), t)) appendLine(approvalsPath(), t);
}

fn envTruthy(key: []const u8) bool {
    const v = compat.getEnvVarOwned(std.heap.page_allocator, key) catch return false;
    defer std.heap.page_allocator.free(v);
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes");
}

fn execApproved(command: []const u8) bool {
    if (envTruthy("ZEPTO_EXEC_APPROVE") or envTruthy("ZEPIO_EXEC_APPROVE")) return true;
    const t = std.mem.trim(u8, command, " \t");
    if (fileContainsLine(approvalsPath(), t)) return true;
    const readonly = [_][]const u8{ "ls", "pwd", "date", "whoami", "uname", "echo", "cat ", "head ", "tail ", "wc ", "git status", "git log", "git diff", "git show" };
    for (readonly) |p| {
        if (std.mem.eql(u8, t, p) or std.mem.startsWith(u8, t, p)) return true;
    }
    // bare cat/head without args
    if (std.mem.eql(u8, t, "cat") or std.mem.eql(u8, t, "git") or std.mem.eql(u8, t, "ls -la")) return true;
    return false;
}

/// Memory: Caller owns returned search snippet. Uses curl + DuckDuckGo HTML.
pub fn webSearchTool(allocator: Allocator, args: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch
        return allocator.dupe(u8, "error: invalid json");
    defer parsed.deinit();
    const q = jsonStr(parsed.value, "query") orelse return allocator.dupe(u8, "error: missing query");
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const url = try std.fmt.allocPrint(allocator, "https://html.duckduckgo.com/html/?q={s}", .{q});
    defer allocator.free(url);
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-sL", "--max-time", "15", url },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4 * 1024),
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "error: search {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const n = @min(result.stdout.len, 4000);
    return allocator.dupe(u8, result.stdout[0..n]);
}

/// Memory: Caller owns returned description. Dispatches the attached turn image to the configured vision model.
pub fn seeImageTool(allocator: Allocator, args: []const u8) ![]const u8 {
    const path = g_vision_image_path orelse return allocator.dupe(u8, "error: no image attached to this turn");
    if (path.len == 0) return allocator.dupe(u8, "error: no image attached to this turn");
    if (g_vision_api_key.len == 0 or g_vision_model.len == 0 or g_vision_base_url.len == 0)
        return allocator.dupe(u8, "error: vision model not configured");
    if (visionBreakerOpen()) return allocator.dupe(u8, "error: vision model temporarily unavailable after repeated failures (cooling down). Do not call see_image again this turn. Answer from the text context; if you already told the user about the outage, do not repeat it.");

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch null;
    defer if (parsed) |p| p.deinit();
    var question: []const u8 = "Describe what's in this image in detail.";
    if (parsed) |p| {
        if (jsonStr(p.value, "question")) |q| {
            if (q.len > 0) question = q;
        }
    }

    var msg = try message.userMessage(allocator, question);
    defer msg.deinit(allocator);
    msg.image_data_url = inbound_media.fileToDataUrl(allocator, path, g_vision_image_mime) orelse
        return allocator.dupe(u8, "error: failed to read attached image");

    var messages = [_]types.Message{msg};
    var client = nim.NIMClient.initWithBaseUrl(allocator, g_vision_api_key, g_vision_model, g_vision_base_url);
    defer client.deinit();

    var response = client.chat(&messages) catch |err| {
        visionNoteFailure();
        return std.fmt.allocPrint(allocator, "error: vision request failed: {s}. Do not retry see_image this turn; answer from the text context.", .{@errorName(err)});
    };
    g_vision_fail_count.store(0, .release);
    defer response.deinit(allocator);

    if (response.choices.len == 0) return allocator.dupe(u8, "error: vision model returned no response");
    const text = response.choices[0].message.content orelse "";
    if (text.len == 0) return allocator.dupe(u8, "error: vision model returned empty response");
    return allocator.dupe(u8, text);
}
threadlocal var g_audio_path: ?[]const u8 = null;
threadlocal var g_audio_mime: []const u8 = "";

/// Sets the voice note attached to the current turn (if any). Call once per turn; pass null to clear.
pub fn setAudioAttachment(path: ?[]const u8, mime: ?[]const u8) void {
    g_audio_path = path;
    g_audio_mime = mime orelse "audio/ogg";
}

/// Memory: Caller owns returned transcription. Dispatches the attached turn audio to the same omni model as vision (it transcribes speech). Shares the vision breaker: one sick model, one cooldown.
pub fn hearAudioTool(allocator: Allocator, args: []const u8) ![]const u8 {
    const path = g_audio_path orelse return allocator.dupe(u8, "error: no audio attached to this turn");
    if (path.len == 0) return allocator.dupe(u8, "error: no audio attached to this turn");
    if (g_vision_api_key.len == 0 or g_vision_model.len == 0 or g_vision_base_url.len == 0)
        return allocator.dupe(u8, "error: audio model not configured");
    if (visionBreakerOpen()) return allocator.dupe(u8, "error: audio model temporarily unavailable after repeated failures (cooling down). Do not call hear_audio again this turn. Answer from the text context; if you already told the user about the outage, do not repeat it.");

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch null;
    defer if (parsed) |p| p.deinit();
    // WhatsApp voice notes arrive typed "audio" or "ptt" with .ogg paths; the
    // model API wants a full MIME type. Derive from the path when bare.
    var mime_buf: [32]u8 = undefined;
    const mime: []const u8 = blk: {
        if (std.mem.indexOf(u8, g_audio_mime, "/") != null) break :blk g_audio_mime;
        if (std.mem.endsWith(u8, path, ".mp3")) break :blk "audio/mpeg";
        if (std.mem.endsWith(u8, path, ".m4a") or std.mem.endsWith(u8, path, ".mp4")) break :blk "audio/mp4";
        if (std.mem.endsWith(u8, path, ".wav")) break :blk "audio/wav";
        if (std.mem.endsWith(u8, path, ".ogg") or std.mem.endsWith(u8, path, ".opus")) break :blk "audio/ogg";
        break :blk std.fmt.bufPrint(&mime_buf, "audio/{s}", .{g_audio_mime}) catch "audio/ogg";
    };
    var question: []const u8 = "Transcribe this audio, then briefly say what it means in context.";
    if (parsed) |p| {
        if (jsonStr(p.value, "question")) |q| {
            if (q.len > 0) question = q;
        }
    }

    var msg = try message.userMessage(allocator, question);
    defer msg.deinit(allocator);
    msg.audio_data_url = inbound_media.fileToDataUrl(allocator, path, mime) orelse
        return allocator.dupe(u8, "error: failed to read attached audio");

    var messages = [_]types.Message{msg};
    var client = nim.NIMClient.initWithBaseUrl(allocator, g_vision_api_key, g_vision_model, g_vision_base_url);
    defer client.deinit();

    var response = client.chat(&messages) catch |err| {
        visionNoteFailure();
        return std.fmt.allocPrint(allocator, "error: audio request failed: {s}. Do not retry hear_audio this turn; answer from the text context.", .{@errorName(err)});
    };
    g_vision_fail_count.store(0, .release);
    defer response.deinit(allocator);

    if (response.choices.len == 0) return allocator.dupe(u8, "error: audio model returned no response");
    const text = response.choices[0].message.content orelse "";
    if (text.len == 0) return allocator.dupe(u8, "error: audio model returned empty response");
    return allocator.dupe(u8, text);
}
threadlocal var g_video_path: ?[]const u8 = null;
threadlocal var g_video_mime: []const u8 = "";

/// Sets the video attached to the current turn (if any). Call once per turn; pass null to clear.
pub fn setVideoAttachment(path: ?[]const u8, mime: ?[]const u8) void {
    g_video_path = path;
    g_video_mime = mime orelse "video/mp4";
}

/// 20MB ceiling: WhatsApp clips regularly exceed the 4MB image default.
const VIDEO_MAX_BYTES: usize = 20 * 1024 * 1024;

/// Memory: Caller owns returned description. Dispatches the attached turn video to the same omni model (it watches clips). Shares the vision breaker.
pub fn watchVideoTool(allocator: Allocator, args: []const u8) ![]const u8 {
    const path = g_video_path orelse return allocator.dupe(u8, "error: no video attached to this turn");
    if (path.len == 0) return allocator.dupe(u8, "error: no video attached to this turn");
    if (g_vision_api_key.len == 0 or g_vision_model.len == 0 or g_vision_base_url.len == 0)
        return allocator.dupe(u8, "error: video model not configured");
    if (visionBreakerOpen()) return allocator.dupe(u8, "error: video model temporarily unavailable after repeated failures (cooling down). Do not call watch_video again this turn. Answer from the text context; if you already told the user about the outage, do not repeat it.");

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch null;
    defer if (parsed) |p| p.deinit();
    var mime_buf: [32]u8 = undefined;
    const mime: []const u8 = blk: {
        if (std.mem.indexOf(u8, g_video_mime, "/") != null) break :blk g_video_mime;
        if (std.mem.endsWith(u8, path, ".mp4") or std.mem.endsWith(u8, path, ".m4a")) break :blk "video/mp4";
        if (std.mem.endsWith(u8, path, ".mov")) break :blk "video/quicktime";
        if (std.mem.endsWith(u8, path, ".webm")) break :blk "video/webm";
        break :blk std.fmt.bufPrint(&mime_buf, "video/{s}", .{g_video_mime}) catch "video/mp4";
    };
    var question: []const u8 = "Describe what happens in this video briefly.";
    if (parsed) |p| {
        if (jsonStr(p.value, "question")) |q| {
            if (q.len > 0) question = q;
        }
    }

    var msg = try message.userMessage(allocator, question);
    defer msg.deinit(allocator);
    msg.video_data_url = inbound_media.fileToDataUrlCapped(allocator, path, mime, VIDEO_MAX_BYTES) orelse
        return allocator.dupe(u8, "error: failed to read attached video (missing or over 20MB)");

    var messages = [_]types.Message{msg};
    var client = nim.NIMClient.initWithBaseUrl(allocator, g_vision_api_key, g_vision_model, g_vision_base_url);
    defer client.deinit();

    var response = client.chat(&messages) catch |err| {
        visionNoteFailure();
        return std.fmt.allocPrint(allocator, "error: video request failed: {s}. Do not retry watch_video this turn; answer from the text context.", .{@errorName(err)});
    };
    g_vision_fail_count.store(0, .release);
    defer response.deinit(allocator);

    if (response.choices.len == 0) return allocator.dupe(u8, "error: video model returned no response");
    const text = response.choices[0].message.content orelse "";
    if (text.len == 0) return allocator.dupe(u8, "error: video model returned empty response");
    return allocator.dupe(u8, text);
}




threadlocal var g_silent: bool = false;
threadlocal var g_leave: bool = false;

pub fn resetPresence() void {
    g_silent = false;
    g_leave = false;
}

pub fn wantSilent() bool {
    return g_silent or g_leave;
}

pub fn wantLeave() bool {
    return g_leave;
}

/// Memory: Caller owns returned status string.
pub fn listenTool(allocator: Allocator, args: []const u8) ![]const u8 {
    _ = args;
    g_silent = true;
    return allocator.dupe(u8, "ok: silent this turn; inbound still recorded");
}

/// Memory: Caller owns returned status string.
pub fn leaveTool(allocator: Allocator, args: []const u8) ![]const u8 {
    _ = args;
    g_leave = true;
    g_silent = true;
    return allocator.dupe(u8, "ok: left; no more turns until barvis");
}

const PARAM_READ = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}";
const PARAM_WRITE = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}";
const PARAM_EDIT = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"old_str\":{\"type\":\"string\"},\"new_str\":{\"type\":\"string\"}},\"required\":[\"path\",\"old_str\",\"new_str\"]}";


const PARAM_EXEC = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}";
const PARAM_SEARCH = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}";
const PARAM_SEE_IMAGE = "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\",\"description\":\"What to look for or ask about the image; defaults to a general description.\"}}}";
const PARAM_HEAR_AUDIO = "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\",\"description\":\"What to transcribe or ask about the voice note; defaults to transcription plus brief meaning.\"}}}";
const PARAM_WATCH_VIDEO = "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\",\"description\":\"What to look for or ask about the video; defaults to a brief description of what happens.\"}}}";
const PARAM_EMPTY = "{\"type\":\"object\",\"properties\":{}}";

const PARAM_MEM_GET = "{\"type\":\"object\",\"properties\":{\"which\":{\"type\":\"string\",\"description\":\"long, daily, or yesterday\"}},\"required\":[\"which\"]}";
const PARAM_MEM_SEARCH = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"include_long\":{\"type\":\"boolean\"}},\"required\":[\"query\"]}";
const PARAM_MEM_APPEND = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"},\"target\":{\"type\":\"string\",\"description\":\"long (MEMORY.md) or daily\"}},\"required\":[\"text\"]}";
const PARAM_MEM_EDIT = "{\"type\":\"object\",\"properties\":{\"old_str\":{\"type\":\"string\"},\"new_str\":{\"type\":\"string\"},\"target\":{\"type\":\"string\",\"description\":\"long or daily\"}},\"required\":[\"old_str\",\"new_str\"]}";

/// Memory: Caller owns returned MEMORY.md or daily journal text.
pub fn memoryGetTool(allocator: Allocator, args: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch
        return allocator.dupe(u8, "error: invalid json");
    defer parsed.deinit();
    const which = jsonStr(parsed.value, "which") orelse "long";
    if (std.mem.eql(u8, which, "long") or std.mem.eql(u8, which, "memory")) {
        return memory.getLongTerm(allocator, g_workspace) orelse allocator.dupe(u8, "(empty MEMORY.md)");
    }
    const off: i64 = if (std.mem.eql(u8, which, "yesterday")) -1 else 0;
    return memory.getDaily(allocator, g_workspace, off) orelse allocator.dupe(u8, "(no daily journal)");
}

/// Memory: Caller owns returned search hits.
pub fn memorySearchTool(allocator: Allocator, args: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch
        return allocator.dupe(u8, "error: invalid json");
    defer parsed.deinit();
    const query = jsonStr(parsed.value, "query") orelse return allocator.dupe(u8, "error: missing query");
    var include_long = true;
    if (parsed.value == .object) {
        if (parsed.value.object.get("include_long")) |v| {
            if (v == .bool) include_long = v.bool;
        }
    }
    return memory.search(allocator, g_workspace, query, include_long);
}

/// Memory: Caller owns returned status string.
pub fn memoryAppendTool(allocator: Allocator, args: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch
        return allocator.dupe(u8, "error: invalid json");
    defer parsed.deinit();
    const text = jsonStr(parsed.value, "text") orelse return allocator.dupe(u8, "error: missing text");
    const target = jsonStr(parsed.value, "target") orelse "long";
    if (std.mem.eql(u8, target, "daily")) {
        memory.appendDailyNote(allocator, g_workspace, g_chat_id, text);
        return allocator.dupe(u8, "ok: appended daily note");
    }
    memory.appendLongTerm(allocator, g_workspace, text);
    return allocator.dupe(u8, "ok: appended MEMORY.md");
}

/// Memory: Caller owns returned status string.
pub fn memoryEditTool(allocator: Allocator, args: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch
        return allocator.dupe(u8, "error: invalid json");
    defer parsed.deinit();
    const old_str = jsonStr(parsed.value, "old_str") orelse return allocator.dupe(u8, "error: missing old_str");
    const new_str = jsonStr(parsed.value, "new_str") orelse return allocator.dupe(u8, "error: missing new_str");
    const target = jsonStr(parsed.value, "target") orelse "long";
    if (std.mem.eql(u8, target, "daily")) {
        const path = memory.dailyPath(allocator, g_workspace, memory.civilNowIst(), 0) catch
            return allocator.dupe(u8, "error: daily path");
        defer allocator.free(path);
        const rel = try std.fmt.allocPrint(allocator, "memory/{s}", .{std.fs.path.basename(path)});
        defer allocator.free(rel);
        return memory.replaceIn(allocator, g_workspace, rel, old_str, new_str);
    }
    return memory.replaceIn(allocator, g_workspace, "MEMORY.md", old_str, new_str);
}

const PARAM_SKILL = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"command\":{\"type\":\"string\"}},\"required\":[\"name\"]}";

pub const SkillHandlerFn = *const fn (std.mem.Allocator, []const u8, []const u8) anyerror![]const u8;
var g_skill: ?SkillHandlerFn = null;

pub fn setSkillHandler(h: ?SkillHandlerFn) void {
    g_skill = h;
}

/// Memory: Caller owns returned skill output.
pub fn skillTool(allocator: Allocator, args: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args, .{}) catch
        return allocator.dupe(u8, "error: invalid json");
    defer parsed.deinit();
    const name = jsonStr(parsed.value, "name") orelse return allocator.dupe(u8, "error: missing name");
    const command = jsonStr(parsed.value, "command") orelse "";
    const h = g_skill orelse return allocator.dupe(u8, "error: no skill handler");
    return h(allocator, name, command);
}

pub const ParamHold = struct {
    parsed: [16]std.json.Parsed(std.json.Value) = undefined,
    n: usize = 0,

    pub fn deinit(self: *ParamHold) void {
        var i: usize = 0;
        while (i < self.n) : (i += 1) self.parsed[i].deinit();
        self.n = 0;
    }
};

/// Memory: Registers tools into `reg`. `hold` must outlive `reg` uses of parameters JSON.
pub fn registerAll(reg: *tools.ToolRegistry, hold: *ParamHold) !void {
    hold.n = 0;
    const Spec = struct { name: []const u8, desc: []const u8, json: []const u8, h: tools.ToolFn };
    const specs = [_]Spec{
        .{ .name = "read", .desc = "Read a UTF-8 file in the workspace", .json = PARAM_READ, .h = readTool },
        .{ .name = "write", .desc = "Write a UTF-8 file in the workspace", .json = PARAM_WRITE, .h = writeTool },
        .{ .name = "edit", .desc = "Replace old_str with new_str in a workspace file", .json = PARAM_EDIT, .h = editTool },
        .{ .name = "exec", .desc = "Run /bin/sh -c in the workspace cwd. Mutating commands need ZEPTO_EXEC_APPROVE or exec-approvals.txt. WhatsApp: operator fromMe DMs only. Absolute paths allowed. After editing ~/.zeptoclaw/config.json, POST /reload with X-Auth-Token $GATEWAY_AUTH_TOKEN (do not restart the gateway).", .json = PARAM_EXEC, .h = execTool },
        .{ .name = "web_search", .desc = "Search the web via DuckDuckGo HTML", .json = PARAM_SEARCH, .h = webSearchTool },
        .{ .name = "see_image", .desc = "Inspect the image attached to this turn (if any) using the vision-capable model; pass an optional question", .json = PARAM_SEE_IMAGE, .h = seeImageTool },
        .{ .name = "hear_audio", .desc = "Transcribe the voice note attached to this turn (if any) using the audio-capable model; pass an optional question", .json = PARAM_HEAR_AUDIO, .h = hearAudioTool },
        .{ .name = "watch_video", .desc = "Describe the video attached to this turn (if any) using the video-capable model; pass an optional question", .json = PARAM_WATCH_VIDEO, .h = watchVideoTool },
        .{ .name = "listen", .desc = "Stay silent this turn; keep recording inbound", .json = PARAM_EMPTY, .h = listenTool },
        .{ .name = "leave", .desc = "Leave this chat until woken with barvis", .json = PARAM_EMPTY, .h = leaveTool },
        .{ .name = "skill", .desc = "Run a named skill command", .json = PARAM_SKILL, .h = skillTool },
        .{ .name = "memory_get", .desc = "Read full MEMORY.md (which=long) or today's/yesterday's daily journal. Ranked recall is already preloaded per turn; use this for full files.", .json = PARAM_MEM_GET, .h = memoryGetTool },
        .{ .name = "memory_search", .desc = "Ranked search over MEMORY.md and all daily journals (same engine as preloaded recall, more hits)", .json = PARAM_MEM_SEARCH, .h = memorySearchTool },
        .{ .name = "memory_append", .desc = "Append a note to MEMORY.md (target=long) or today's journal (target=daily)", .json = PARAM_MEM_APPEND, .h = memoryAppendTool },
        .{ .name = "memory_edit", .desc = "Replace old_str with new_str in MEMORY.md or today's daily file", .json = PARAM_MEM_EDIT, .h = memoryEditTool },
    };
    for (specs) |sp| {
        hold.parsed[hold.n] = try std.json.parseFromSlice(std.json.Value, reg.allocator, sp.json, .{});
        const params = hold.parsed[hold.n].value;
        hold.n += 1;
        try reg.register(.{
            .name = try reg.allocator.dupe(u8, sp.name),
            .description = try reg.allocator.dupe(u8, sp.desc),
            .parameters = params,
            .handler = sp.h,
        });
    }
}

/// Memory: Caller owns returned slice and each ToolDefinition's owned strings.
pub fn collectDefinitions(reg: *tools.ToolRegistry, allocator: Allocator) ![]types.ToolDefinition {
    var list: std.ArrayList(types.ToolDefinition) = .empty;
    errdefer {
        for (list.items) |*d| d.deinit(allocator);
        list.deinit(allocator);
    }
    var it = reg.tools.iterator();
    while (it.next()) |e| {
        try list.append(allocator, .{
            .@"type" = try allocator.dupe(u8, "function"),
            .name = try allocator.dupe(u8, e.value_ptr.name),
            .description = try allocator.dupe(u8, e.value_ptr.description),
            .parameters = e.value_ptr.parameters,
        });
    }
    return list.toOwnedSlice(allocator);
}

test "core_tools read missing path" {
    const allocator = std.testing.allocator;
    const out = try readTool(allocator, "{}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "missing path") != null);
}

test "core_tools invalid json" {
    const allocator = std.testing.allocator;
    const out = try readTool(allocator, "not-json");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "invalid json") != null);
}

test "core_tools path escape" {
    const allocator = std.testing.allocator;
    setWorkspace("/tmp/zeptoclaw-ws-test");
    defer setWorkspace(".");
    const out = try readTool(allocator, "{\"path\":\"/etc/passwd\"}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "PathEscape") != null);
}

test "core_tools write read edit" {
    const allocator = std.testing.allocator;
    const dir = "/tmp/zeptoclaw-core-tools-test";
    std.Io.Dir.createDirPath(compat.cwd().dir, compat.cwd().io, dir) catch {};
    setWorkspace(dir);
    defer setWorkspace(".");

    const w = try writeTool(allocator, "{\"path\":\"note.txt\",\"content\":\"hello world\"}");
    defer allocator.free(w);
    try std.testing.expect(std.mem.startsWith(u8, w, "wrote"));

    const r = try readTool(allocator, "{\"path\":\"note.txt\"}");
    defer allocator.free(r);
    try std.testing.expectEqualStrings("hello world", r);

    const e = try editTool(allocator, "{\"path\":\"note.txt\",\"old_str\":\"world\",\"new_str\":\"barvis\"}");
    defer allocator.free(e);
    try std.testing.expectEqualStrings("ok", e);

    const r2 = try readTool(allocator, "{\"path\":\"note.txt\"}");
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("hello barvis", r2);
}

test "core_tools exec denied mutating" {
    const allocator = std.testing.allocator;
    setWorkspace(".");
    const out = try execTool(allocator, "{\"command\":\"rm -rf /tmp/not-a-real-zepto-target\"}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "exec denied") != null);
}

test "exec denied when setExecEnabled false" {
    const allocator = std.testing.allocator;
    setExecEnabled(false);
    defer setExecEnabled(true);
    const out = try execTool(allocator, "{\"command\":\"pwd\"}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "fromMe") != null);
}

test "execTool echo HOME is absolute" {
    const allocator = std.testing.allocator;
    setWorkspace(".");
    const out = try execTool(allocator, "{\"command\":\"echo \\\"$HOME\\\"\"}");
    defer allocator.free(out);
    const has_home = std.mem.indexOf(u8, out, "/home/") != null;
    const has_abs = std.mem.indexOf(u8, out, "\n/") != null;
    try std.testing.expect(has_home or has_abs);
}

test "core_tools exec pwd allowlisted" {
    const allocator = std.testing.allocator;
    setWorkspace(".");
    const out = try execTool(allocator, "{\"command\":\"pwd\"}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "exit"));
}

test "core_tools listen leave" {

    const allocator = std.testing.allocator;
    resetPresence();
    defer resetPresence();
    const a = try listenTool(allocator, "{}");
    defer allocator.free(a);
    try std.testing.expect(wantSilent());
    try std.testing.expect(!wantLeave());
    const b = try leaveTool(allocator, "{}");
    defer allocator.free(b);
    try std.testing.expect(wantLeave());
    try std.testing.expect(wantSilent());
}

test "core_tools hear_audio no audio attached" {
    const allocator = std.testing.allocator;
    setAudioAttachment(null, null);
    const out = try hearAudioTool(allocator, "{}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "no audio attached") != null);
}

test "core_tools hear_audio audio not configured" {
    const allocator = std.testing.allocator;
    setAudioAttachment("/tmp/zeptoclaw-audio-test.ogg", "audio/ogg");
    defer setAudioAttachment(null, null);
    setVisionClient("", "", "");
    const out = try hearAudioTool(allocator, "{}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "audio model not configured") != null);
}

test "core_tools watch_video no video attached" {
    const allocator = std.testing.allocator;
    const out = try watchVideoTool(allocator, "{}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "no video attached") != null);
}

test "core_tools watch_video video not configured" {
    const allocator = std.testing.allocator;
    setVideoAttachment("/tmp/zeptoclaw-video-test.mp4", "video/mp4");
    defer setVideoAttachment(null, null);
    setVisionClient("", "", "");
    const out = try watchVideoTool(allocator, "{}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "video model not configured") != null);
}

test "core_tools see_image no image attached" {
    const allocator = std.testing.allocator;
    setVisionImage(null, null);
    const out = try seeImageTool(allocator, "{}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "no image attached") != null);
}

test "core_tools vision breaker trips and cools down" {
    g_vision_fail_count.store(0, .release);
    try std.testing.expect(!visionBreakerOpen());
    visionNoteFailure();
    visionNoteFailure();
    try std.testing.expect(!visionBreakerOpen());
    visionNoteFailure();
    try std.testing.expect(visionBreakerOpen());
    // Cooldown expiry closes it and resets the count.
    g_vision_last_fail_sec.store(compat.timestamp() - 601, .release);
    try std.testing.expect(!visionBreakerOpen());
    try std.testing.expectEqual(@as(u32, 0), g_vision_fail_count.load(.acquire));
}

test "core_tools see_image vision not configured" {
    const allocator = std.testing.allocator;
    setVisionImage("/tmp/zeptoclaw-vision-test.jpg", "image/jpeg");
    defer setVisionImage(null, null);
    setVisionClient("", "", "");
    const out = try seeImageTool(allocator, "{}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "vision model not configured") != null);
}

test "core_tools registerAll" {
    const allocator = std.testing.allocator;
    var reg = tools.ToolRegistry.init(allocator);
    defer reg.deinit();
    var hold: ParamHold = undefined;
    try registerAll(&reg, &hold);
    defer hold.deinit();
    try std.testing.expect(reg.get("read") != null);
    try std.testing.expect(reg.get("leave") != null);
    try std.testing.expect(reg.get("memory_get") != null);
    try std.testing.expect(reg.get("see_image") != null);
    try std.testing.expect(reg.get("hear_audio") != null);
    try std.testing.expect(reg.get("watch_video") != null);
    try std.testing.expect(reg.get("memory_append") != null);
    const defs = try collectDefinitions(&reg, allocator);
    defer {
        for (defs) |*d| d.deinit(allocator);
        allocator.free(defs);
    }
    try std.testing.expect(defs.len >= 12);
}

test "core_tools skill missing handler" {
    const allocator = std.testing.allocator;
    setSkillHandler(null);
    const out = try skillTool(allocator, "{\"name\":\"git\"}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "no skill handler") != null);
}

test "core_tools memory_get and append" {
    const allocator = std.testing.allocator;
    const dir = "/tmp/zeptoclaw-core-memory-tools";
    std.Io.Dir.createDirPath(compat.cwd().dir, compat.cwd().io, dir) catch {};
    setWorkspace(dir);
    defer setWorkspace(".");
    setChatId("test-chat");
    const a = try memoryAppendTool(allocator, "{\"text\":\"likes espresso\",\"target\":\"long\"}");
    defer allocator.free(a);
    try std.testing.expect(std.mem.indexOf(u8, a, "appended") != null);
    const g = try memoryGetTool(allocator, "{\"which\":\"long\"}");
    defer allocator.free(g);
    try std.testing.expect(std.mem.indexOf(u8, g, "likes espresso") != null);
    const s = try memorySearchTool(allocator, "{\"query\":\"espresso\"}");
    defer allocator.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "espresso") != null);
}
