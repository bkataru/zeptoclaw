//! Durable inbound turns that have not finished send/listen.
//! Survives SIGKILL. Replay on WhatsApp connected.
const std = @import("std");
const compat = @import("../../compat.zig");

const MAX_BODY: usize = 8 * 1024;
const MAX_ID: usize = 256;
const MAX_CHAT: usize = 256;
const MAX_ROWS: usize = 32;

pub const PendingTurn = struct {
    id: []u8,
    chat_id: []u8,
    body: []u8,
    from_me: bool,
    direct: bool,

    pub fn deinit(self: *PendingTurn, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.chat_id);
        allocator.free(self.body);
    }
};

/// Memory: caller owns returned path.
pub fn filePath(allocator: std.mem.Allocator) ![]u8 {
    if (compat.getEnvVarOwned(allocator, "WHATSAPP_AUTH_DIR")) |auth| {
        defer allocator.free(auth);
        return std.fmt.allocPrint(allocator, "{s}/pending-turns.jsonl", .{auth});
    } else |_| {}
    return compat.homeJoin(allocator, ".zeptoclaw/sessions/whatsapp/pending-turns.jsonl");
}

fn writeAll(path: []const u8, body: []const u8) void {
    const cwd = compat.cwd();
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.createDirPath(cwd.dir, cwd.io, dir) catch {};
    }
    const out = cwd.createFile(path, .{ .truncate = true }) catch return;
    defer out.close(cwd.io);
    var w = out.writer(cwd.io, &[_]u8{});
    w.interface.writeAll(body) catch return;
}

fn readAll(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const cwd = compat.cwd();
    const f = cwd.openFile(path, .{}) catch return null;
    defer f.close(cwd.io);
    const st = f.stat(cwd.io) catch return null;
    if (st.kind != .file or st.size == 0) return null;
    const sz: usize = @intCast(@min(st.size, @as(u64, 256 * 1024)));
    const buf = allocator.alloc(u8, sz) catch return null;
    var r = f.reader(cwd.io, &[_]u8{});
    r.interface.readSliceAll(buf) catch {
        allocator.free(buf);
        return null;
    };
    return buf;
}

fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "\"");
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn encodeLine(allocator: std.mem.Allocator, id: []const u8, chat_id: []const u8, body: []const u8, from_me: bool, direct: bool) ![]u8 {
    const id_e = try jsonEscape(allocator, id);
    defer allocator.free(id_e);
    const chat_e = try jsonEscape(allocator, chat_id);
    defer allocator.free(chat_e);
    const clipped = if (body.len > MAX_BODY) body[0..MAX_BODY] else body;
    const body_e = try jsonEscape(allocator, clipped);
    defer allocator.free(body_e);
    return std.fmt.allocPrint(allocator, "{{\"id\":{s},\"chat_id\":{s},\"body\":{s},\"from_me\":{},\"direct\":{}}}\n", .{
        id_e,
        chat_e,
        body_e,
        from_me,
        direct,
    });
}

fn jsonStr(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonBool(obj: std.json.Value, key: []const u8) bool {
    const v = obj.object.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

/// Memory: caller owns each PendingTurn and the slice.
pub fn loadFrom(allocator: std.mem.Allocator, path: []const u8) ![]PendingTurn {
    const buf = readAll(allocator, path) orelse return allocator.alloc(PendingTurn, 0);
    defer allocator.free(buf);
    var list = try std.ArrayList(PendingTurn).initCapacity(allocator, 0);
    errdefer {
        for (list.items) |*p| p.deinit(allocator);
        list.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, t, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const id = jsonStr(parsed.value, "id") orelse continue;
        const chat = jsonStr(parsed.value, "chat_id") orelse continue;
        const body = jsonStr(parsed.value, "body") orelse continue;
        var row: PendingTurn = .{
            .id = try allocator.dupe(u8, id[0..@min(id.len, MAX_ID)]),
            .chat_id = try allocator.dupe(u8, chat[0..@min(chat.len, MAX_CHAT)]),
            .body = try allocator.dupe(u8, body[0..@min(body.len, MAX_BODY)]),
            .from_me = jsonBool(parsed.value, "from_me"),
            .direct = jsonBool(parsed.value, "direct"),
        };
        errdefer row.deinit(allocator);
        try list.append(allocator, row);
        if (list.items.len >= MAX_ROWS) break;
    }
    return list.toOwnedSlice(allocator);
}

pub fn enqueueAt(allocator: std.mem.Allocator, path: []const u8, id: []const u8, chat_id: []const u8, body: []const u8, from_me: bool, direct: bool) void {
    const existing = loadFrom(allocator, path) catch return;
    defer {
        for (existing) |*p| p.deinit(allocator);
        allocator.free(existing);
    }
    for (existing) |p| {
        if (std.mem.eql(u8, p.id, id)) return;
    }
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const keep_from: usize = if (existing.len + 1 > MAX_ROWS) existing.len + 1 - MAX_ROWS else 0;
    var i: usize = keep_from;
    while (i < existing.len) : (i += 1) {
        const line = encodeLine(allocator, existing[i].id, existing[i].chat_id, existing[i].body, existing[i].from_me, existing[i].direct) catch continue;
        defer allocator.free(line);
        out.appendSlice(allocator, line) catch return;
    }
    const add = encodeLine(allocator, id, chat_id, body, from_me, direct) catch return;
    defer allocator.free(add);
    out.appendSlice(allocator, add) catch return;
    writeAll(path, out.items);
}

pub fn ackAt(allocator: std.mem.Allocator, path: []const u8, id: []const u8) void {
    const existing = loadFrom(allocator, path) catch return;
    defer {
        for (existing) |*p| p.deinit(allocator);
        allocator.free(existing);
    }
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (existing) |p| {
        if (std.mem.eql(u8, p.id, id)) continue;
        const line = encodeLine(allocator, p.id, p.chat_id, p.body, p.from_me, p.direct) catch continue;
        defer allocator.free(line);
        out.appendSlice(allocator, line) catch return;
    }
    writeAll(path, out.items);
}

pub fn enqueue(allocator: std.mem.Allocator, id: []const u8, chat_id: []const u8, body: []const u8, from_me: bool, direct: bool) void {
    const path = filePath(allocator) catch return;
    defer allocator.free(path);
    enqueueAt(allocator, path, id, chat_id, body, from_me, direct);
}

pub fn ack(allocator: std.mem.Allocator, id: []const u8) void {
    const path = filePath(allocator) catch return;
    defer allocator.free(path);
    ackAt(allocator, path, id);
}

/// Memory: caller owns each PendingTurn and the slice.
pub fn load(allocator: std.mem.Allocator) ![]PendingTurn {
    const path = filePath(allocator) catch return allocator.alloc(PendingTurn, 0);
    defer allocator.free(path);
    return loadFrom(allocator, path);
}

/// Memory: caller owns returned slice.
pub fn mergeBurstPrompt(allocator: std.mem.Allocator, bodies: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "The user sent several messages while a previous reply was generating. Answer the whole burst in one reply:\n");
    for (bodies) |b| {
        try out.appendSlice(allocator, "- ");
        try out.appendSlice(allocator, b);
        try out.appendSlice(allocator, "\n");
    }
    return out.toOwnedSlice(allocator);
}

test "mergeBurstPrompt joins bodies" {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{ "😊", "yayayay", "mfer" };
    const s = try mergeBurstPrompt(a, &bodies);
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "😊") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "yayayay") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "mfer") != null);
}

test "enqueue ack load filters id" {
    const a = std.testing.allocator;
    const path = "/tmp/zeptoclaw-pending-turns-test.jsonl";
    writeAll(path, "");
    enqueueAt(a, path, "m1", "190@lid", "i like ur top", true, true);
    enqueueAt(a, path, "m1", "190@lid", "dup", true, true);
    enqueueAt(a, path, "m2", "190@lid", "hi barvis", true, true);
    const rows = try loadFrom(a, path);
    defer {
        for (rows) |*p| p.deinit(a);
        a.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    ackAt(a, path, "m1");
    const left = try loadFrom(a, path);
    defer {
        for (left) |*p| p.deinit(a);
        a.free(left);
    }
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqualStrings("m2", left[0].id);
    try std.testing.expect(std.mem.indexOf(u8, left[0].body, "hi barvis") != null);
}

fn fuzzPendingJsonl(_: void, smith: *std.testing.Smith) !void {
    var buf: [800]u8 = undefined;
    const n = smith.slice(&buf);
    const path = "/tmp/zeptoclaw-fuzz-pending.jsonl";
    writeAll(path, buf[0..n]);
    const a = std.testing.allocator;
    const rows = loadFrom(a, path) catch return;
    defer {
        for (rows) |*row| row.deinit(a);
        a.free(rows);
    }
}

test "fuzz pending jsonl" {
    try std.testing.fuzz({}, fuzzPendingJsonl, .{
        .corpus = &.{
            "",
            "{\"id\":\"m1\",\"chat_id\":\"190@lid\",\"body\":\"hi\",\"from_me\":true,\"direct\":true}\n",
            "not json\n{\"id\":1}\n",
            "{\"id\":\"x\",\"chat_id\":\"c\",\"body\":\"\\\"\\\n\"}\n",
        },
    });
}
