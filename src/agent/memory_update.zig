//! Periodic MEMORY.md update via NVIDIA NIM.
//! Own process (systemd oneshot / compact child) so rate-limit backoff never
//! shares state with the live WhatsApp gateway.
//!
//! Cycle:
//! 1. If journals have not changed since last stamp, skip (no NIM).
//! 2. One NIM call: the model decides UPDATE or SKIP.
//! 3. If UPDATE, a second NIM call synthesizes the new MEMORY.md.
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

fn fileMtime(path: []const u8) i64 {
    const cwd = compat.cwd();
    const f = cwd.openFile(path, .{}) catch return 0;
    defer f.close(cwd.io);
    const st = f.stat(cwd.io) catch return 0;
    const ns = st.mtime.nanoseconds;
    return @intCast(@divTrunc(ns, 1_000_000_000));
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

pub const Decision = enum { update, skip };

/// Parse the decide-turn reply. First token wins; default skip if unclear.
pub fn parseDecision(raw: []const u8) Decision {
    var s = std.mem.trim(u8, raw, " \t\r\n`");
    if (std.mem.startsWith(u8, s, "```")) {
        if (std.mem.indexOfScalar(u8, s, '\n')) |nl| s = std.mem.trim(u8, s[nl + 1 ..], " \t\r\n");
    }
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n:.,;");
    const first = it.next() orelse return .skip;
    if (std.ascii.eqlIgnoreCase(first, "UPDATE") or
        std.ascii.eqlIgnoreCase(first, "YES") or
        std.ascii.eqlIgnoreCase(first, "TRUE"))
        return .update;
    return .skip;
}

fn journalHasTurns(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "[in]") != null or
        std.mem.indexOf(u8, text, "[out]") != null or
        std.mem.indexOf(u8, text, "[note]") != null;
}

fn loadJournals(allocator: std.mem.Allocator, ws: []const u8) !struct { text: []u8, newest_mtime: i64, has_turns: bool } {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var newest: i64 = 0;
    var has = false;
    const civil = memory.civilNowIst();
    var i: i64 = 0;
    while (i < 2) : (i += 1) {
        const path = try memory.dailyPath(allocator, ws, civil, -i);
        defer allocator.free(path);
        const mt = fileMtime(path);
        if (mt > newest) newest = mt;
        if (readCapped(allocator, path, 12 * 1024)) |buf| {
            defer allocator.free(buf);
            if (journalHasTurns(buf)) has = true;
            try out.appendSlice(allocator, "--- daily ");
            try out.appendSlice(allocator, path);
            try out.appendSlice(allocator, " ---\n");
            try out.appendSlice(allocator, buf);
            try out.appendSlice(allocator, "\n\n");
        }
    }
    return .{ .text = try out.toOwnedSlice(allocator), .newest_mtime = newest, .has_turns = has };
}

fn lastUpdateTs(allocator: std.mem.Allocator, ws: []const u8) i64 {
    const path = std.fmt.allocPrint(allocator, "{s}/memory/heartbeat-state.json", .{ws}) catch return 0;
    defer allocator.free(path);
    const buf = readCapped(allocator, path, 4096) orelse return 0;
    defer allocator.free(buf);
    const key = "\"lastMemoryUpdate\":";
    const idx = std.mem.indexOf(u8, buf, key) orelse return 0;
    var p = idx + key.len;
    while (p < buf.len and (buf[p] == ' ' or buf[p] == '\t')) p += 1;
    var end = p;
    while (end < buf.len and buf[end] >= '0' and buf[end] <= '9') end += 1;
    if (end == p) return 0;
    return std.fmt.parseInt(i64, buf[p..end], 10) catch 0;
}

fn loadDecidePrompt(allocator: std.mem.Allocator, journals: []const u8, mem_md: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\Decide whether Barvis MEMORY.md needs an update from recent journals.
        \\Reply with exactly one line: UPDATE <reason>  or  SKIP <reason>
        \\UPDATE only if journals contain durable facts, preferences, decisions, voice, or lessons not already in MEMORY.md.
        \\SKIP if idle, no new conversations, only pings, tool JSON, duplicates, or nothing worth keeping.
        \\Do not rewrite MEMORY.md in this turn.
        \\
        \\--- MEMORY.md (current, truncated) ---
        \\
    );
    const mem_clip = if (mem_md.len > 6000) mem_md[0..6000] else mem_md;
    try out.appendSlice(allocator, mem_clip);
    try out.appendSlice(allocator, "\n\n--- recent journals ---\n");
    try out.appendSlice(allocator, journals);
    return out.toOwnedSlice(allocator);
}

fn loadUpdatePrompt(allocator: std.mem.Allocator, ws: []const u8, journals: []const u8, reason: []const u8) ![]u8 {
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
        \\Decision from previous turn: UPDATE
        \\
    );
    try out.appendSlice(allocator, reason);
    try out.appendSlice(allocator, "\n\n");

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
    try out.appendSlice(allocator, journals);
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

fn nimText(allocator: std.mem.Allocator, nim: *NIMClient, prompt: []const u8) ![]u8 {
    var msgs = [_]types.Message{
        try types.Message.user(allocator, prompt),
    };
    defer msgs[0].deinit(allocator);
    var response = try nim.chat(&msgs);
    defer response.deinit(allocator);
    if (response.choices.len == 0) return error.EmptyUpdate;
    const raw = response.choices[0].message.content orelse return error.EmptyUpdate;
    return allocator.dupe(u8, raw);
}

/// One-shot update. Own process = own NVIDIA budget.
pub fn runOnce(allocator: std.mem.Allocator) !void {
    const ws = try openclaw.resolveWorkspaceDir(allocator);
    defer allocator.free(ws);
    const mem_path = try std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{ws});
    defer allocator.free(mem_path);
    const old_mem = readCapped(allocator, mem_path, MEMORY_CAP * 2) orelse "";
    defer if (old_mem.len > 0) allocator.free(old_mem);

    const journals = try loadJournals(allocator, ws);
    defer allocator.free(journals.text);

    if (!journals.has_turns) {
        std.log.info("[memory-update] no journal turns; skipping NIM", .{});
        return;
    }
    const last = lastUpdateTs(allocator, ws);
    if (last > 0 and journals.newest_mtime > 0 and journals.newest_mtime <= last) {
        std.log.info("[memory-update] journals unchanged since last update ({d}); skipping NIM", .{last});
        return;
    }

    var cfg = try config_mod.Config.load(allocator);
    defer cfg.deinit();
    var nim = NIMClient.init(allocator, cfg);
    defer nim.deinit();

    const decide_prompt = try loadDecidePrompt(allocator, journals.text, old_mem);
    defer allocator.free(decide_prompt);
    std.log.info("[memory-update] decide prompt bytes={d}", .{decide_prompt.len});
    const decide_raw = try nimText(allocator, &nim, decide_prompt);
    defer allocator.free(decide_raw);
    const decision = parseDecision(decide_raw);
    std.log.info("[memory-update] decision={s} raw={s}", .{ @tagName(decision), decide_raw[0..@min(decide_raw.len, 200)] });
    if (decision == .skip) {
        stamp(allocator, ws, old_mem.len);
        return;
    }

    const update_prompt = try loadUpdatePrompt(allocator, ws, journals.text, decide_raw);
    defer allocator.free(update_prompt);
    std.log.info("[memory-update] synthesize prompt bytes={d}", .{update_prompt.len});
    const raw = try nimText(allocator, &nim, update_prompt);
    defer allocator.free(raw);
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

fn jsonI64(buf: []const u8, key: []const u8) i64 {
    const idx = std.mem.indexOf(u8, buf, key) orelse return 0;
    var p = idx + key.len;
    while (p < buf.len and (buf[p] == ' ' or buf[p] == '\t')) p += 1;
    var end = p;
    while (end < buf.len and buf[end] >= '0' and buf[end] <= '9') end += 1;
    if (end == p) return 0;
    return std.fmt.parseInt(i64, buf[p..end], 10) catch 0;
}

fn stamp(allocator: std.mem.Allocator, ws: []const u8, bytes: usize) void {
    const path = std.fmt.allocPrint(allocator, "{s}/memory/heartbeat-state.json", .{ws}) catch return;
    defer allocator.free(path);
    const existing = readCapped(allocator, path, 4096) orelse "";
    defer if (existing.len > 0) allocator.free(existing);
    const last_compact = jsonI64(existing, "\"lastMemoryCompact\":");
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"lastMemoryUpdate\":{d},\"lastMemoryCompact\":{d},\"memoryBytes\":{d}}}\n",
        .{ compat.timestamp(), last_compact, bytes },
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

test "parseDecision first token" {
    try std.testing.expectEqual(Decision.update, parseDecision("UPDATE new preference about Zig"));
    try std.testing.expectEqual(Decision.update, parseDecision("update: keep the voice note"));
    try std.testing.expectEqual(Decision.update, parseDecision("```\nYES because he asked to remember\n```"));
    try std.testing.expectEqual(Decision.skip, parseDecision("SKIP idle, only pings"));
    try std.testing.expectEqual(Decision.skip, parseDecision("no new facts"));
    try std.testing.expectEqual(Decision.skip, parseDecision(""));
}

fn fuzzDecision(_: void, smith: *std.testing.Smith) !void {
    var buf: [256]u8 = undefined;
    const n = smith.slice(&buf);
    _ = parseDecision(buf[0..n]);
}

test "fuzz parseDecision update" {
    try std.testing.fuzz({}, fuzzDecision, .{
        .corpus = &.{
            "UPDATE",
            "SKIP",
            "```\nYES\n```",
            "",
            "update please",
            "NOPE",
        },
    });
}
