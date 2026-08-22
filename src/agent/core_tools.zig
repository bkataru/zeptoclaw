//! Workspace-scoped tools the model may call (OpenClaw-style read/write/edit/exec).
const std = @import("std");
const compat = @import("../compat.zig");
const types = @import("../providers/types.zig");
const tools = @import("tools.zig");

const Allocator = std.mem.Allocator;

threadlocal var g_workspace: []const u8 = ".";

pub fn setWorkspace(path: []const u8) void {
    g_workspace = path;
}

pub fn workspace() []const u8 {
    return g_workspace;
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

    if (!execApproved(command)) {
        writePending(command);
        return allocator.dupe(u8, "error: exec denied. Approve by setting ZEPTO_EXEC_APPROVE=1, or POST /exec/approve {\"command\":\"...\"} / append the exact command to sessions/exec-approvals.txt");
    }

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .cwd = .{ .path = g_workspace },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| {
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



fn approvalsPath() []const u8 {
    return "sessions/exec-approvals.txt";
}
fn pendingPath() []const u8 {
    return "sessions/exec-pending.txt";
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
const PARAM_EMPTY = "{\"type\":\"object\",\"properties\":{}}";
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
    parsed: [12]std.json.Parsed(std.json.Value) = undefined,
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
        .{ .name = "exec", .desc = "Run a shell command in the workspace (requires approval)", .json = PARAM_EXEC, .h = execTool },
        .{ .name = "web_search", .desc = "Search the web via DuckDuckGo HTML", .json = PARAM_SEARCH, .h = webSearchTool },
        .{ .name = "listen", .desc = "Stay silent this turn; keep recording inbound", .json = PARAM_EMPTY, .h = listenTool },
        .{ .name = "leave", .desc = "Leave this chat until woken with barvis", .json = PARAM_EMPTY, .h = leaveTool },
        .{ .name = "skill", .desc = "Run a named skill command", .json = PARAM_SKILL, .h = skillTool },
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
