//! Periodic MEMORY.md update via NVIDIA NIM.
//! Own process (systemd oneshot) so rate-limit backoff never shares state
//! with the live WhatsApp gateway.
//!
//! Each cycle: take current MEMORY.md (old memories) + recent daily journals
//! (new memories) and produce a combined, transformed MEMORY.md.
const std = @import("std");
const compat = @import("../compat.zig");
const openclaw = @import("../openclaw_compat/openclaw.zig");
const config_mod = @import("../config.zig");
const NIMClient = @import("../providers/nim.zig").NIMClient;
const types = @import("../providers/types.zig");
const memory = @import("memory.zig");

const MEMORY_CAP: usize = 32 * 1024;
const AUTO_HEADING = "## Running notes (auto)";

fn readCapped(allocator: std.mem.Allocator, path: []const u8, cap: usize) ?[]u8 {
    const cwd = compat.cwd();
    const f = cwd.openFile(path, .{}) catch return null;
    defer f.close(cwd.io);
    const st = f.stat(cwd.io) catch return null;
    if (st.size == 0) return allocator.dupe(u8, "") catch return null;
    const sz: usize = @intCast(@min(st.size, cap));
    const buf = allocator.alloc(u8, sz) catch return null;
    var rdr = f.reader(cwd.io, &[_]u8{});
    rdr.interface.readSliceAll(buf) catch {
        allocator.free(buf);
        return null;
    };
    return buf;
}

fn writeFile(path: []const u8, body: []const u8) !void {
    const cwd = compat.cwd();
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.createDirPath(cwd.dir, cwd.io, dir) catch {};
    }
    const out = try cwd.createFile(path, .{ .truncate = true });
    defer out.close(cwd.io);
    var w = out.writer(cwd.io, &[_]u8{});
    try w.interface.writeAll(body);
}

pub fn extractMarkdown(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, s, "```")) {
        if (std.mem.indexOfScalar(u8, s, '\n')) |nl| {
            s = s[nl + 1 ..];
        }
        if (std.mem.endsWith(u8, s, "```")) {
            s = s[0 .. s.len - 3];
        }
        s = std.mem.trim(u8, s, " \t\r\n");
    }
    return s;
}

pub fn looksLikeMemoryDoc(s: []const u8) bool {
    if (s.len < 40) return false;
    return std.mem.indexOf(u8, s, "# MEMORY") != null or
        std.mem.indexOf(u8, s, "## Who") != null or
        std.mem.startsWith(u8, s, "# ");
}

fn loadBundle(allocator: std.mem.Allocator, ws: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\Update MEMORY.md for Barvis (Baala's Jarvis).
        \\This is memory *update*, not a wipe: synthesize and distill.
        \\Combine the existing long-term MEMORY.md (old memories) with new daily notes (raw chat journals).
        \\Extract durable facts, preferences, decisions, voice, and lessons. Merge duplicates. Drop noise, tool JSON, and one-off pings.
        \\Write a coherent knowledge document, not a dump of raw [in]/[out] lines.
        \\Preserve heading structure. Keep section `## Running notes (auto)` if present.
        \\Do not invent facts. Do not include secrets or API keys. Output ONLY the full updated MEMORY.md markdown.
        \\
        \\
    );

    const files = [_][]const u8{ "SOUL.md", "IDENTITY.md", "MEMORY.md" };
    for (files) |name| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ws, name });
        defer allocator.free(path);
        const cap: usize = if (std.mem.eql(u8, name, "MEMORY.md")) MEMORY_CAP else 8 * 1024;
        if (readCapped(allocator, path, cap)) |buf| {
            defer allocator.free(buf);
            try out.appendSlice(allocator, "--- ");
            try out.appendSlice(allocator, name);
            try out.appendSlice(allocator, " ---\n");
            try out.appendSlice(allocator, buf);
            try out.appendSlice(allocator, "\n\n");
        }
    }

    const civil = memory.civilNowIst();
    var i: i64 = 0;
    while (i < 2) : (i += 1) {
        const path = try memory.dailyPath(allocator, ws, civil, -i);
        defer allocator.free(path);
        if (readCapped(allocator, path, 12 * 1024)) |buf| {
            defer allocator.free(buf);
            try out.appendSlice(allocator, "--- new daily notes ");
            try out.appendSlice(allocator, path);
            try out.appendSlice(allocator, " ---\n");
            try out.appendSlice(allocator, buf);
            try out.appendSlice(allocator, "\n\n");
        }
    }
    return out.toOwnedSlice(allocator);
}

fn preserveAutoSection(allocator: std.mem.Allocator, old_mem: []const u8, updated: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, updated, AUTO_HEADING) != null) {
        return allocator.dupe(u8, updated);
    }
    const idx = std.mem.indexOf(u8, old_mem, AUTO_HEADING) orelse return allocator.dupe(u8, updated);
    var body = std.ArrayList(u8).empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, updated);
    if (updated.len == 0 or updated[updated.len - 1] != '\n') try body.append(allocator, '\n');
    try body.appendSlice(allocator, "\n");
    try body.appendSlice(allocator, old_mem[idx..]);
    return body.toOwnedSlice(allocator);
}

fn clipCap(s: []const u8) []const u8 {
    if (s.len <= MEMORY_CAP) return s;
    return s[0..MEMORY_CAP];
}

/// One-shot update. Own process = own NVIDIA budget.
pub fn runOnce(allocator: std.mem.Allocator) !void {
    const ws = try openclaw.resolveWorkspaceDir(allocator);
    defer allocator.free(ws);
    const mem_path = try std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{ws});
    defer allocator.free(mem_path);
    const old_mem = readCapped(allocator, mem_path, MEMORY_CAP * 2) orelse "";
    defer if (old_mem.len > 0) allocator.free(old_mem);

    const bundle = try loadBundle(allocator, ws);
    defer allocator.free(bundle);
    std.log.info("[memory-update] prompt bytes={d}", .{bundle.len});

    var cfg = try config_mod.Config.load(allocator);
    defer cfg.deinit();
    var nim = NIMClient.init(allocator, cfg);
    defer nim.deinit();

    var msgs = [_]types.Message{
        try types.Message.user(allocator, bundle),
    };
    defer msgs[0].deinit(allocator);

    var response = try nim.chat(&msgs);
    defer response.deinit(allocator);
    if (response.choices.len == 0) return error.EmptyUpdate;
    const raw = response.choices[0].message.content orelse return error.EmptyUpdate;
    const md = extractMarkdown(raw);
    if (!looksLikeMemoryDoc(md)) {
        std.log.warn("[memory-update] model output did not look like MEMORY.md; leaving file unchanged", .{});
        return error.InvalidUpdate;
    }
    const merged = try preserveAutoSection(allocator, old_mem, md);
    defer allocator.free(merged);
    const out = clipCap(merged);
    try writeFile(mem_path, out);
    stamp(allocator, ws, out.len);
    std.log.info("[memory-update] updated MEMORY.md ({d} bytes)", .{out.len});
}

fn stamp(allocator: std.mem.Allocator, ws: []const u8, bytes: usize) void {
    const path = std.fmt.allocPrint(allocator, "{s}/memory/heartbeat-state.json", .{ws}) catch return;
    defer allocator.free(path);
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"lastMemoryUpdate\":{d},\"memoryBytes\":{d}}}\n",
        .{ compat.timestamp(), bytes },
    ) catch return;
    defer allocator.free(body);
    writeFile(path, body) catch {};
}

test "extractMarkdown strips fences" {
    const raw = "```markdown\n# MEMORY.md\n\n## Who I Am\n- Barvis\n```";
    const md = extractMarkdown(raw);
    try std.testing.expect(std.mem.startsWith(u8, md, "# MEMORY.md"));
    try std.testing.expect(!std.mem.endsWith(u8, md, "```"));
}

test "looksLikeMemoryDoc" {
    try std.testing.expect(!looksLikeMemoryDoc("ok"));
    try std.testing.expect(looksLikeMemoryDoc("# MEMORY.md - Long-Term Memory\n\n## Who I Am\n- Barvis the assistant who remembers\n"));
}

test "preserveAutoSection appends missing heading" {
    const allocator = std.testing.allocator;
    const old = "# MEMORY.md\n\n## Running notes (auto)\n\n- keep me\n";
    const neu = "# MEMORY.md\n\n## Who I Am\n- Barvis\n";
    const merged = try preserveAutoSection(allocator, old, neu);
    defer allocator.free(merged);
    try std.testing.expect(std.mem.indexOf(u8, merged, AUTO_HEADING) != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "keep me") != null);
}
