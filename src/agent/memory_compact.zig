//! Two-hour MEMORY.md compact: compress already-curated long-term memory.
//! Different job from 30-minute `memory update` (which ingests journals).
//!
//! This pass does not dump daily [in]/[out] into MEMORY.md. It densifies
//! the existing document: fold auto notes into durable sections, drop
//! transients, merge duplicates, keep identity-grade facts.
const std = @import("std");
const compat = @import("../compat.zig");
const openclaw = @import("../openclaw_compat/openclaw.zig");
const config_mod = @import("../config.zig");
const NIMClient = @import("../providers/nim.zig").NIMClient;
const types = @import("../providers/types.zig");
const memory_update = @import("memory_update.zig");

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

fn fileMtimeSecs(path: []const u8) i64 {
    const cwd = compat.cwd();
    const f = cwd.openFile(path, .{}) catch return 0;
    defer f.close(cwd.io);
    const st = f.stat(cwd.io) catch return 0;
    return @intCast(@divTrunc(st.mtime.nanoseconds, 1_000_000_000));
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

pub const Decision = enum { compact, skip };

pub fn parseDecision(raw: []const u8) Decision {
    var s = std.mem.trim(u8, raw, " \t\r\n`");
    if (std.mem.startsWith(u8, s, "```")) {
        if (std.mem.indexOfScalar(u8, s, '\n')) |nl| s = std.mem.trim(u8, s[nl + 1 ..], " \t\r\n");
    }
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n:.,;");
    const first = it.next() orelse return .skip;
    if (std.ascii.eqlIgnoreCase(first, "COMPACT") or
        std.ascii.eqlIgnoreCase(first, "UPDATE") or
        std.ascii.eqlIgnoreCase(first, "YES") or
        std.ascii.eqlIgnoreCase(first, "TRUE"))
        return .compact;
    return .skip;
}

fn lastCompactTs(allocator: std.mem.Allocator, ws: []const u8) i64 {
    const path = std.fmt.allocPrint(allocator, "{s}/memory/heartbeat-state.json", .{ws}) catch return 0;
    defer allocator.free(path);
    const buf = readCapped(allocator, path, 4096) orelse return 0;
    defer allocator.free(buf);
    const key = "\"lastMemoryCompact\":";
    const idx = std.mem.indexOf(u8, buf, key) orelse return 0;
    var p = idx + key.len;
    while (p < buf.len and (buf[p] == ' ' or buf[p] == '\t')) p += 1;
    var end = p;
    while (end < buf.len and buf[end] >= '0' and buf[end] <= '9') end += 1;
    if (end == p) return 0;
    return std.fmt.parseInt(i64, buf[p..end], 10) catch 0;
}

fn autoSectionBytes(mem_md: []const u8) usize {
    const idx = std.mem.indexOf(u8, mem_md, AUTO_HEADING) orelse return 0;
    return mem_md.len - idx;
}

fn loadDecidePrompt(allocator: std.mem.Allocator, mem_md: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\You are compressing Barvis long-term MEMORY.md (not ingesting chats).
        \\Reply with exactly one line: COMPACT <reason>  or  SKIP <reason>
        \\COMPACT if the file is bloated, has a long ## Running notes (auto) dump, duplicates, dated one-offs, or unstructured journal paste.
        \\SKIP if it is already dense identity-grade knowledge (who/how/preferences/projects) with little redundancy.
        \\Do not rewrite MEMORY.md in this turn.
        \\
        \\--- MEMORY.md ---
        \\
    );
    try out.appendSlice(allocator, mem_md);
    return out.toOwnedSlice(allocator);
}

fn loadCompactPrompt(allocator: std.mem.Allocator, mem_md: []const u8, reason: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\Compress MEMORY.md for Barvis. This is *compaction*, not journal ingest.
        \\Goal: a dense, stable knowledge document Baala can load later.
        \\Fold ## Running notes (auto) into durable sections (Who, How I write, Preferences, Projects, People).
        \\Merge duplicates. Drop pings, tool JSON, timestamps-as-narrative, and one-off status.
        \\Keep facts, voice, decisions, relationships. Prefer fewer, sharper bullets.
        \\Do not invent. No secrets or API keys. Output ONLY the full compacted MEMORY.md markdown.
        \\Keep a short ## Running notes (auto) section only for items still too fresh to classify.
        \\
        \\Decision from previous turn: COMPACT
        \\
    );
    try out.appendSlice(allocator, reason);
    try out.appendSlice(allocator, "\n\n--- MEMORY.md (current) ---\n");
    try out.appendSlice(allocator, mem_md);
    return out.toOwnedSlice(allocator);
}

fn nimText(allocator: std.mem.Allocator, nim: *NIMClient, prompt: []const u8) ![]u8 {
    var msgs = [_]types.Message{
        try types.Message.user(allocator, prompt),
    };
    defer msgs[0].deinit(allocator);
    var response = try nim.chat(&msgs);
    defer response.deinit(allocator);
    if (response.choices.len == 0) return error.EmptyCompact;
    const raw = response.choices[0].message.content orelse return error.EmptyCompact;
    return allocator.dupe(u8, raw);
}

fn clipCap(s: []const u8) []const u8 {
    if (s.len <= MEMORY_CAP) return s;
    return s[0..MEMORY_CAP];
}

/// Two-hour compact. Own process = own NVIDIA budget.
pub fn runOnce(allocator: std.mem.Allocator) !void {
    const ws = try openclaw.resolveWorkspaceDir(allocator);
    defer allocator.free(ws);
    const mem_path = try std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{ws});
    defer allocator.free(mem_path);
    const old_mem = readCapped(allocator, mem_path, MEMORY_CAP * 2) orelse "";
    defer if (old_mem.len > 0) allocator.free(old_mem);

    if (old_mem.len < 80) {
        std.log.info("[memory-compact] MEMORY.md too small; skipping NIM", .{});
        return;
    }

    const last = lastCompactTs(allocator, ws);
    const mt = fileMtimeSecs(mem_path);
    if (last > 0 and mt > 0 and mt <= last) {
        std.log.info("[memory-compact] MEMORY.md unchanged since last compact ({d}); skipping NIM", .{last});
        return;
    }

    var cfg = try config_mod.Config.load(allocator);
    defer cfg.deinit();
    var nim = NIMClient.init(allocator, cfg);
    defer nim.deinit();

    const decide_prompt = try loadDecidePrompt(allocator, old_mem);
    defer allocator.free(decide_prompt);
    std.log.info("[memory-compact] decide prompt bytes={d} auto_tail={d}", .{ decide_prompt.len, autoSectionBytes(old_mem) });
    const decide_raw = try nimText(allocator, &nim, decide_prompt);
    defer allocator.free(decide_raw);
    const decision = parseDecision(decide_raw);
    std.log.info("[memory-compact] decision={s} raw={s}", .{ @tagName(decision), decide_raw[0..@min(decide_raw.len, 200)] });
    if (decision == .skip) {
        stamp(allocator, ws, old_mem.len);
        return;
    }

    const compact_prompt = try loadCompactPrompt(allocator, old_mem, decide_raw);
    defer allocator.free(compact_prompt);
    std.log.info("[memory-compact] compress prompt bytes={d}", .{compact_prompt.len});
    const raw = try nimText(allocator, &nim, compact_prompt);
    defer allocator.free(raw);
    const md = memory_update.extractMarkdown(raw);
    if (!memory_update.looksLikeMemoryDoc(md)) {
        std.log.warn("[memory-compact] model output did not look like MEMORY.md; leaving file unchanged", .{});
        return error.InvalidCompact;
    }
    const out = clipCap(md);
    try writeFile(mem_path, out);
    stamp(allocator, ws, out.len);
    std.log.info("[memory-compact] compacted MEMORY.md ({d} -> {d} bytes)", .{ old_mem.len, out.len });
}

fn stamp(allocator: std.mem.Allocator, ws: []const u8, bytes: usize) void {
    const path = std.fmt.allocPrint(allocator, "{s}/memory/heartbeat-state.json", .{ws}) catch return;
    defer allocator.free(path);
    const existing = readCapped(allocator, path, 4096) orelse "";
    defer if (existing.len > 0) allocator.free(existing);
    const last_update = blk: {
        const key = "\"lastMemoryUpdate\":";
        const idx = std.mem.indexOf(u8, existing, key) orelse break :blk @as(i64, 0);
        var p = idx + key.len;
        while (p < existing.len and (existing[p] == ' ' or existing[p] == '\t')) p += 1;
        var end = p;
        while (end < existing.len and existing[end] >= '0' and existing[end] <= '9') end += 1;
        break :blk std.fmt.parseInt(i64, existing[p..end], 10) catch 0;
    };
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"lastMemoryUpdate\":{d},\"lastMemoryCompact\":{d},\"memoryBytes\":{d}}}\n",
        .{ last_update, compat.timestamp(), bytes },
    ) catch return;
    defer allocator.free(body);
    writeFile(path, body) catch {};
}

test "parseDecision compact tokens" {
    try std.testing.expectEqual(Decision.compact, parseDecision("COMPACT auto notes are 12KB of pings"));
    try std.testing.expectEqual(Decision.compact, parseDecision("compact: fold duplicates"));
    try std.testing.expectEqual(Decision.skip, parseDecision("SKIP already dense"));
    try std.testing.expectEqual(Decision.skip, parseDecision("no need"));
    try std.testing.expectEqual(Decision.skip, parseDecision(""));
}
