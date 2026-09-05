//! Workspace memory: daily journals + curated MEMORY.md.
//! Dates are real Gregorian YYYY-MM-DD in IST, not the old 366-day fake calendar.
const std = @import("std");
const compat = @import("../compat.zig");
const openclaw = @import("../openclaw_compat/openclaw.zig");

const IST_OFFSET: i64 = 5 * 3600 + 30 * 60;
const MEMORY_CAP: usize = 32 * 1024;
const AUTO_HEADING = "## Running notes (auto)";

pub const Civil = struct { year: i32, month: u8, day: u8 };

/// Unix days since 1970-01-01 → Gregorian (Howard Hinnant).
pub fn civilFromUnixDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u32 = @intCast(z - era * 146097);
    const yoe: u32 = @intCast(@divFloor(@as(i64, doe) - @divFloor(@as(i64, doe), 1460) + @divFloor(@as(i64, doe), 36524) - @divFloor(@as(i64, doe), 146096), 365));
    const y = @as(i64, yoe) + era * 400;
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u32 = (5 * doy + 2) / 153;
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const year: i32 = @intCast(if (m <= 2) y + 1 else y);
    return .{ .year = year, .month = m, .day = d };
}

pub fn civilNowIst() Civil {
    const ist = compat.timestamp() + IST_OFFSET;
    return civilFromUnixDays(@divFloor(ist, 86400));
}

pub fn clockIst() struct { h: u8, m: u8 } {
    const ist = compat.timestamp() + IST_OFFSET;
    const sod = @mod(ist, 86400);
    return .{ .h = @intCast(@divFloor(sod, 3600)), .m = @intCast(@divFloor(@mod(sod, 3600), 60)) };
}

/// Memory: Caller owns returned path.
pub fn dailyPath(allocator: std.mem.Allocator, ws_dir: []const u8, civil: Civil, day_offset: i64) ![]u8 {
    const days = unixDays(civil) + day_offset;
    const c = civilFromUnixDays(days);
    return std.fmt.allocPrint(allocator, "{s}/memory/{d:0>4}-{d:0>2}-{d:0>2}.md", .{
        ws_dir, @as(u32, @intCast(c.year)), c.month, c.day,
    });
}

fn unixDays(c: Civil) i64 {
    var y: i64 = c.year;
    var m: i64 = c.month;
    if (m <= 2) {
        y -= 1;
        m += 9;
    } else {
        m -= 3;
    }
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * m + 2, 5) + @as(i64, c.day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn readFileCapped(allocator: std.mem.Allocator, path: []const u8, cap: usize) ?[]u8 {
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

fn writeFile(path: []const u8, body: []const u8) void {
    const cwd = compat.cwd();
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.createDirPath(cwd.dir, cwd.io, dir) catch {};
    }
    const out = cwd.createFile(path, .{ .truncate = true }) catch return;
    defer out.close(cwd.io);
    var w = out.writer(cwd.io, &[_]u8{});
    w.interface.writeAll(body) catch return;
}

pub fn journalAppend(allocator: std.mem.Allocator, kind: []const u8, chat_id: []const u8, text: []const u8, who: ?[]const u8) void {
    const ws = openclaw.resolveWorkspaceDir(allocator) catch return;
    defer allocator.free(ws);
    const path = dailyPath(allocator, ws, civilNowIst(), 0) catch return;
    defer allocator.free(path);
    // Full turn text: daily journals are the raw trace. Do not clip messages.
    const existing = readFileCapped(allocator, path, 8 * 1024 * 1024) orelse "";
    defer if (existing.len > 0) allocator.free(existing);
    const clock = clockIst();
    // Sender tag sits after the chat marker so `] (chat):` keeps matching.
    const line = if (who) |w| std.fmt.allocPrint(allocator, "\n- {d:0>2}:{d:0>2} IST [{s}] ({s}): [{s}] {s}\n", .{
        clock.h, clock.m, kind, chat_id, w, text,
    }) catch return else std.fmt.allocPrint(allocator, "\n- {d:0>2}:{d:0>2} IST [{s}] ({s}): {s}\n", .{
        clock.h, clock.m, kind, chat_id, text,
    }) catch return;
    defer allocator.free(line);
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    if (existing.len == 0) {
        body.appendSlice(allocator, "# Barvis Journal\n") catch return;
    } else {
        body.appendSlice(allocator, existing) catch return;
    }
    body.appendSlice(allocator, line) catch return;
    writeFile(path, body.items);
    std.log.info("[memory] journal {s} {s}", .{ kind, path });
}

/// Memory: Caller owns returned slice if non-null.
pub fn lineBelongsToChat(line: []const u8, chat_id: []const u8) bool {
    if (chat_id.len == 0) return false;
    var marker_buf: [160]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "] ({s}):", .{chat_id}) catch return false;
    return std.mem.indexOf(u8, line, marker) != null;
}

/// Same-chat journal lines from today + yesterday. Never dumps other chats or MEMORY.md.
/// Memory: Caller owns returned slice if non-null.
pub fn dailyContextAt(allocator: std.mem.Allocator, ws: []const u8, chat_id: []const u8) ?[]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    out.appendSlice(allocator, "\n--- This chat only (daily journal; ignore other chats) ---\n") catch return null;
    const civil = civilNowIst();
    var day_i: i64 = 0;
    while (day_i < 2) : (day_i += 1) {
        const path = dailyPath(allocator, ws, civil, -day_i) catch continue;
        defer allocator.free(path);
        const buf = readFileCapped(allocator, path, 8 * 1024 * 1024) orelse continue;
        defer allocator.free(buf);
        var it = std.mem.splitScalar(u8, buf, '\n');
        while (it.next()) |line| {
            if (!lineBelongsToChat(line, chat_id)) continue;
            out.appendSlice(allocator, line) catch return null;
            out.appendSlice(allocator, "\n") catch return null;
        }
    }
    const header_len: usize = 64;
    if (out.items.len < header_len + 8) {
        out.deinit(allocator);
        return null;
    }
    const cap: usize = 12 * 1024;
    if (out.items.len > cap) {
        const keep = out.items[out.items.len - cap ..];
        const copy = allocator.dupe(u8, keep) catch {
            out.deinit(allocator);
            return null;
        };
        out.deinit(allocator);
        return copy;
    }
    return out.toOwnedSlice(allocator) catch return null;
}

/// Memory: Caller owns returned slice if non-null.
pub fn dailyContext(allocator: std.mem.Allocator, chat_id: []const u8, is_dm: bool) ?[]const u8 {
    _ = is_dm;
    const ws = openclaw.resolveWorkspaceDir(allocator) catch return null;
    defer allocator.free(ws);
    return dailyContextAt(allocator, ws, chat_id);
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn looksLikeRememberRequest(text: []const u8) bool {
    const needles = [_][]const u8{
        "remember",
        "don't forget",
        "dont forget",
        "this is how i write",
        "this is how I write",
        "save this",
        "memory.md",
        "going forward",
    };
    for (needles) |n| {
        if (containsIgnoreCase(text, n)) return true;
    }
    return false;
}

pub fn shouldPersistNote(user_text: []const u8, reply: []const u8) bool {
    if (looksLikeRememberRequest(user_text)) return true;
    if (reply.len >= 400 and user_text.len >= 40) return true;
    return false;
}

fn snippet(s: []const u8, cap: usize) []const u8 {
    return if (s.len > cap) s[0..cap] else s;
}

pub fn persistDmNote(allocator: std.mem.Allocator, chat_id: []const u8, user_text: []const u8, reply: []const u8) void {
    if (!shouldPersistNote(user_text, reply)) return;
    const ws = openclaw.resolveWorkspaceDir(allocator) catch return;
    defer allocator.free(ws);
    const mem_path = std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{ws}) catch return;
    defer allocator.free(mem_path);
    const existing = readFileCapped(allocator, mem_path, MEMORY_CAP * 2) orelse "";
    defer if (existing.len > 0) allocator.free(existing);

    const clock = clockIst();
    const civil = civilNowIst();
    const note = std.fmt.allocPrint(
        allocator,
        "- {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} IST ({s}): {s} → {s}\n",
        .{
            @as(u32, @intCast(civil.year)),
            civil.month,
            civil.day,
            clock.h,
            clock.m,
            chat_id,
            snippet(user_text, 240),
            snippet(reply, 360),
        },
    ) catch return;
    defer allocator.free(note);

    const merged = mergeAutoNotes(allocator, existing, note) catch return;
    defer allocator.free(merged);
    writeFile(mem_path, merged);
    std.log.info("[memory] wrote durable note to MEMORY.md ({d} bytes)", .{merged.len});
}

/// Memory: Caller owns returned slice if non-null.
pub fn getLongTerm(allocator: std.mem.Allocator, ws: []const u8) ?[]u8 {
    const path = std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{ws}) catch return null;
    defer allocator.free(path);
    return readFileCapped(allocator, path, MEMORY_CAP);
}

/// Memory: Caller owns returned slice if non-null. `day_offset` 0=today IST, -1=yesterday.
pub fn getDaily(allocator: std.mem.Allocator, ws: []const u8, day_offset: i64) ?[]u8 {
    const path = dailyPath(allocator, ws, civilNowIst(), day_offset) catch return null;
    defer allocator.free(path);
    return readFileCapped(allocator, path, 32 * 1024);
}

pub fn appendLongTerm(allocator: std.mem.Allocator, ws: []const u8, note: []const u8) void {
    const path = std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{ws}) catch return;
    defer allocator.free(path);
    const existing = readFileCapped(allocator, path, MEMORY_CAP * 2) orelse "";
    defer if (existing.len > 0) allocator.free(existing);
    const clipped = snippet(std.mem.trim(u8, note, " \t\r\n"), 1200);
    const line = std.fmt.allocPrint(allocator, "- {s}\n", .{clipped}) catch return;
    defer allocator.free(line);
    const merged = mergeAutoNotes(allocator, existing, line) catch return;
    defer allocator.free(merged);
    writeFile(path, merged);
    std.log.info("[memory] agent append MEMORY.md ({d} bytes)", .{merged.len});
}

pub fn appendDailyNote(allocator: std.mem.Allocator, ws: []const u8, chat_id: []const u8, text: []const u8) void {
    const path = dailyPath(allocator, ws, civilNowIst(), 0) catch return;
    defer allocator.free(path);
    const existing = readFileCapped(allocator, path, 96 * 1024) orelse "";
    defer if (existing.len > 0) allocator.free(existing);
    const clock = clockIst();
    const clipped = snippet(text, 2000);
    const line = std.fmt.allocPrint(allocator, "\n- {d:0>2}:{d:0>2} IST [note] ({s}): {s}\n", .{
        clock.h, clock.m, chat_id, clipped,
    }) catch return;
    defer allocator.free(line);
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    if (existing.len == 0) {
        body.appendSlice(allocator, "# Barvis Journal\n") catch return;
    } else {
        body.appendSlice(allocator, existing) catch return;
    }
    body.appendSlice(allocator, line) catch return;
    writeFile(path, body.items);
}

/// Stopwords for recall term extraction: glue words that never identify a memory.
const recall_stopwords: []const []const u8 = &.{
    "the", "and", "for", "are", "but", "not", "you", "all", "any", "can",
    "had", "her", "was", "one", "our", "out", "day", "has", "have", "from",
    "they", "with", "that", "this", "what", "when", "where", "which", "who",
    "will", "how", "about", "into", "your", "then", "than", "them", "there",
    "their", "been", "also", "just", "said", "with", "are", "was", "were",
    "does", "did", "she", "him", "his", "hers", "its", "our", "ours", "yours",
    "please", "thanks", "thank", "hello", "hey", "morning", "evening", "today",
    "tell", "know", "like", "want", "need", "much", "more", "very", "here",
    "there", "some", "such", "only", "over", "under", "again", "once", "now",
};

fn isRecallStopword(w: []const u8) bool {
    for (recall_stopwords) |s| if (std.mem.eql(u8, s, w)) return true;
    return false;
}

/// Split text into lowercase query terms: alnum runs of 3+, deduped, no
/// stopwords, capped at 12. Caller frees each term and the list.
fn queryTerms(allocator: std.mem.Allocator, text: []const u8) !std.ArrayList([]u8) {
    var terms = std.ArrayList([]u8).empty;
    errdefer {
        for (terms.items) |t| allocator.free(t);
        terms.deinit(allocator);
    }
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !std.ascii.isAlphanumeric(text[i])) : (i += 1) {}
        const start = i;
        while (i < text.len and std.ascii.isAlphanumeric(text[i])) : (i += 1) {}
        if (i - start < 3) continue;
        const w = try allocator.dupe(u8, text[start..i]);
        errdefer allocator.free(w);
        for (w) |*c| c.* = std.ascii.toLower(c.*);
        var dup = false;
        for (terms.items) |t| if (std.mem.eql(u8, t, w)) {
            dup = true;
            break;
        };
        if (dup or isRecallStopword(w)) {
            allocator.free(w);
            continue;
        }
        try terms.append(allocator, w);
        if (terms.items.len >= 12) break;
    }
    return terms;
}

/// Distinct query terms contained in the line (case-insensitive).
fn scoreLine(line: []const u8, terms: []const []u8) usize {
    var n: usize = 0;
    for (terms) |t| {
        if (containsIgnoreCase(line, t)) n += 1;
    }
    return n;
}

const ScoredHit = struct { score: usize, name: []const u8, line: []const u8 };

/// Ranked recall over MEMORY.md plus every daily journal (newest first):
/// tokenize the text, score each line by distinct-term coverage, keep the
/// best `max_hits`. Returns "" when nothing matches. Caller owns result.
pub fn recall(allocator: std.mem.Allocator, ws: []const u8, text: []const u8, max_hits: usize) ![]u8 {
    return recallInner(allocator, ws, text, max_hits, true);
}

fn recallInner(allocator: std.mem.Allocator, ws: []const u8, text: []const u8, max_hits: usize, include_long: bool) ![]u8 {
    var terms = try queryTerms(allocator, text);
    defer {
        for (terms.items) |t| allocator.free(t);
        terms.deinit(allocator);
    }

    if (terms.items.len == 0 or max_hits == 0) return allocator.dupe(u8, "");
    // Newest journals first so recency wins score ties.
    var journal_names = std.ArrayList([]u8).empty;
    defer {
        for (journal_names.items) |n| allocator.free(n);
        journal_names.deinit(allocator);
    }
    // Journal dir lives at <ws>/memory.
    const io = compat.getIo();
    if (std.Io.Dir.openDirAbsolute(io, ws, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(io);
        if (dir.openDir(io, "memory", .{ .iterate = true })) |jd| {
            var jdir = jd;
            defer jdir.close(io);
            var it = jdir.iterate();
            while (it.next(io) catch null) |e| {
                if (e.kind != .file) continue;
                if (!std.mem.startsWith(u8, e.name, "20")) continue;
                if (!std.mem.endsWith(u8, e.name, ".md")) continue;
                journal_names.append(allocator, allocator.dupe(u8, e.name) catch continue) catch continue;
                if (journal_names.items.len >= 60) break;
            }
        } else |_| {}
    } else |_| {}
    std.mem.sort([]u8, journal_names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .gt; // newest first
        }
    }.lessThan);
    var best: [16]ScoredHit = undefined;
    var nbest: usize = 0;
    const cap_hits = @min(max_hits, best.len);
    // Distilled memory first, then journals newest-first.
    if (include_long) {
        if (getLongTerm(allocator, ws)) |buf| {
            defer allocator.free(buf);
            collectScored(allocator, &best, &nbest, cap_hits, "MEMORY.md", buf, terms.items);
        }
    }
    for (journal_names.items) |jn| {
        const path = std.fmt.allocPrint(allocator, "{s}/memory/{s}", .{ ws, jn }) catch continue;
        defer allocator.free(path);
        const buf = readFileCapped(allocator, path, 64 * 1024) orelse continue;
        defer allocator.free(buf);
        collectScored(allocator, &best, &nbest, cap_hits, jn, buf, terms.items);
    }
    if (nbest == 0) return allocator.dupe(u8, "");
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (best[0..nbest]) |h| {
        out.appendSlice(allocator, h.name) catch continue;
        out.appendSlice(allocator, ": ") catch continue;
        out.appendSlice(allocator, snippet(h.line, 240)) catch continue;
        out.append(allocator, '\n') catch continue;
        if (out.items.len > 6 * 1024) break;
    }
    for (best[0..nbest]) |h| allocator.free(h.line);
    return out.toOwnedSlice(allocator);
}

/// Score every line of `buf`, keeping the top `cap` hits. Kept lines are
/// duped (owned by `best`, freed by the caller after output); `buf` may die.
fn collectScored(allocator: std.mem.Allocator, best: *[16]ScoredHit, nbest: *usize, cap: usize, name: []const u8, buf: []const u8, terms: []const []u8) void {
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |line| {
        if (line.len < 4) continue;
        const s = scoreLine(line, terms);
        if (s == 0) continue;
        // Insert ranked (higher score first; ties keep earlier = newer file).
        var pos: usize = 0;
        while (pos < nbest.* and best[pos].score >= s) : (pos += 1) {}
        if (pos >= cap and nbest.* >= cap) continue;
        const owned = allocator.dupe(u8, line) catch continue;
        if (nbest.* < cap) nbest.* += 1;
        var j: usize = nbest.* - 1;
        while (j > pos) : (j -= 1) best[j] = best[j - 1];
        best[pos] = .{ .score = s, .name = name, .line = owned };
    }
}

/// Memory: Caller owns returned search hits. Ranked recall over MEMORY.md
/// and all daily journals; `include_long=false` skips MEMORY.md.
pub fn search(allocator: std.mem.Allocator, ws: []const u8, query: []const u8, include_long: bool) ![]u8 {
    if (query.len == 0) return allocator.dupe(u8, "error: empty query");
    const hits = try recallInner(allocator, ws, query, 20, include_long);
    if (hits.len == 0) {
        allocator.free(hits);
        return allocator.dupe(u8, "(no matches)");
    }
    return hits;
}

pub fn replaceIn(allocator: std.mem.Allocator, ws: []const u8, rel: []const u8, old_str: []const u8, new_str: []const u8) ![]u8 {
    if (old_str.len == 0) return allocator.dupe(u8, "error: empty old_str");
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ws, rel });
    defer allocator.free(path);
    const current = readFileCapped(allocator, path, MEMORY_CAP * 2) orelse
        return allocator.dupe(u8, "error: file missing or empty");
    defer allocator.free(current);
    const idx = std.mem.indexOf(u8, current, old_str) orelse
        return allocator.dupe(u8, "error: old_str not found");
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, current[0..idx]);
    try body.appendSlice(allocator, new_str);
    try body.appendSlice(allocator, current[idx + old_str.len ..]);
    if (std.mem.endsWith(u8, rel, "MEMORY.md") and body.items.len > MEMORY_CAP) {
        trimToCap(&body, allocator);
    }
    writeFile(path, body.items);
    return std.fmt.allocPrint(allocator, "updated {s} ({d} bytes)", .{ rel, body.items.len });
}

fn mergeAutoNotes(allocator: std.mem.Allocator, existing: []const u8, note: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, existing, snippet(note, @min(note.len, 80)))) |_| {
        return allocator.dupe(u8, existing);
    }
    var body = std.ArrayList(u8).empty;
    errdefer body.deinit(allocator);
    if (existing.len == 0) {
        try body.appendSlice(allocator, "# MEMORY.md - Long-Term Memory\n\n");
        try body.appendSlice(allocator, AUTO_HEADING);
        try body.appendSlice(allocator, "\n\n");
        try body.appendSlice(allocator, note);
        return body.toOwnedSlice(allocator);
    }
    if (std.mem.indexOf(u8, existing, AUTO_HEADING)) |idx| {
        try body.appendSlice(allocator, existing[0 .. idx + AUTO_HEADING.len]);
        try body.appendSlice(allocator, "\n\n");
        try body.appendSlice(allocator, note);
        const rest = existing[idx + AUTO_HEADING.len ..];
        try body.appendSlice(allocator, rest);
    } else {
        try body.appendSlice(allocator, existing);
        if (existing.len > 0 and existing[existing.len - 1] != '\n') try body.append(allocator, '\n');
        try body.appendSlice(allocator, "\n");
        try body.appendSlice(allocator, AUTO_HEADING);
        try body.appendSlice(allocator, "\n\n");
        try body.appendSlice(allocator, note);
    }
    trimToCap(&body, allocator);
    return body.toOwnedSlice(allocator);
}

fn trimToCap(body: *std.ArrayList(u8), allocator: std.mem.Allocator) void {
    _ = allocator;
    while (body.items.len > MEMORY_CAP) {
        const start = std.mem.indexOf(u8, body.items, AUTO_HEADING) orelse break;
        const from = start + AUTO_HEADING.len;
        if (from >= body.items.len) break;
        const rest = body.items[from..];
        var skip: usize = 0;
        var n: usize = 0;
        var i: usize = 0;
        while (i < rest.len) {
            if (rest[i] == '\n') {
                if (skip < i and rest[skip] == '-') n += 1;
                skip = i + 1;
                i += 1;
                if (n >= 3) break;
                continue;
            }
            i += 1;
        }
        if (skip == 0) break;
        const drop = skip;
        std.mem.copyForwards(u8, body.items[from..], body.items[from + drop ..]);
        body.items.len -= drop;
    }
}

/// Isolated process so NIM backoff is not the WhatsApp client's.
fn spawnMemoryUpdate(allocator: std.mem.Allocator) bool {
    if (@import("builtin").is_test) return false;
    const home = compat.getEnvVarOwned(allocator, "HOME") catch return false;
    defer allocator.free(home);
    const path = std.fmt.allocPrint(allocator, "{s}/zeptoclaw/zig-out/bin/zeptoclaw", .{home}) catch return false;
    defer allocator.free(path);
    const result = compat.runParentEnv(allocator, &.{ path, "memory", "update" }, .limited(16 * 1024), .limited(64 * 1024), null) catch |err| {
        std.log.warn("[memory] synthesis spawn failed: {s}", .{@errorName(err)});
        return false;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stderr.len > 0) {
        std.log.info("[memory] synthesis stderr: {s}", .{result.stderr});
    }
    return switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

pub fn compactFromDaily(allocator: std.mem.Allocator) void {
    std.log.info("[memory] synthesizing MEMORY.md from journals (isolated NIM)", .{});
    if (spawnMemoryUpdate(allocator)) {
        std.log.info("[memory] synthesis child finished; MEMORY.md updated", .{});
        return;
    }
    std.log.warn("[memory] synthesis child failed; falling back to extractive compact", .{});
    const ws = openclaw.resolveWorkspaceDir(allocator) catch return;
    defer allocator.free(ws);
    const civil = civilNowIst();
    const path = dailyPath(allocator, ws, civil, 0) catch return;
    defer allocator.free(path);
    const daily = readFileCapped(allocator, path, 64 * 1024) orelse return;
    defer allocator.free(daily);

    var extracted = std.ArrayList(u8).empty;
    defer extracted.deinit(allocator);
    var it = std.mem.splitScalar(u8, daily, '\n');
    var kept: usize = 0;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "[out]") == null) continue;
        if (line.len < 80) continue;
        if (std.mem.indexOf(u8, line, "{\"name\"") != null) continue;
        extracted.appendSlice(allocator, snippet(line, 280)) catch break;
        extracted.append(allocator, '\n') catch break;
        kept += 1;
        if (kept >= 8) break;
    }
    if (kept == 0) return;

    const mem_path = std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{ws}) catch return;
    defer allocator.free(mem_path);
    const existing = readFileCapped(allocator, mem_path, MEMORY_CAP * 2) orelse "";
    defer if (existing.len > 0) allocator.free(existing);
    const merged = mergeAutoNotes(allocator, existing, extracted.items) catch return;
    defer allocator.free(merged);
    writeFile(mem_path, merged);
    stampHeartbeat(allocator, ws, merged.len);
    std.log.info("[memory] compacted {d} outbound notes into MEMORY.md", .{kept});
}

fn stampHeartbeat(allocator: std.mem.Allocator, ws: []const u8, bytes: usize) void {
    const path = std.fmt.allocPrint(allocator, "{s}/memory/heartbeat-state.json", .{ws}) catch return;
    defer allocator.free(path);
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"lastMemoryCompact\":{d},\"memoryBytes\":{d}}}\n",
        .{ compat.timestamp(), bytes },
    ) catch return;
    defer allocator.free(body);
    writeFile(path, body);
}

pub fn intervalSecs() u64 {
    const v = compat.getEnvVarOwned(std.heap.page_allocator, "ZEPTO_MEMORY_SECS") catch return 1800;
    defer std.heap.page_allocator.free(v);
    return std.fmt.parseInt(u64, v, 10) catch 1800;
}

pub fn runLoop() void {
    const secs = intervalSecs();
    if (secs == 0) {
        std.log.info("[memory] compact loop disabled (ZEPTO_MEMORY_SECS=0)", .{});
        return;
    }
    std.log.info("[memory] compact loop every {d}s (NIM synthesis in a child process)", .{secs});
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    while (true) {
        var remaining = secs;
        while (remaining > 0) {
            _ = std.c.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);
            remaining -= 1;
        }
        compactFromDaily(allocator);
    }
}

test "civilFromUnixDays epoch" {
    const c = civilFromUnixDays(0);
    try std.testing.expectEqual(@as(i32, 1970), c.year);
    try std.testing.expectEqual(@as(u8, 1), c.month);
    try std.testing.expectEqual(@as(u8, 1), c.day);
}

test "civilFromUnixDays 2026-08-22" {
    const days = @divFloor(@as(i64, 1787356800), 86400);
    const c = civilFromUnixDays(days);
    try std.testing.expectEqual(@as(i32, 2026), c.year);
    try std.testing.expectEqual(@as(u8, 8), c.month);
    try std.testing.expectEqual(@as(u8, 22), c.day);
}

test "unixDays roundtrip" {
    const orig = Civil{ .year = 2026, .month = 8, .day = 22 };
    const back = civilFromUnixDays(unixDays(orig));
    try std.testing.expectEqual(orig.year, back.year);
    try std.testing.expectEqual(orig.month, back.month);
    try std.testing.expectEqual(orig.day, back.day);
}

test "shouldPersistNote heuristics" {
    try std.testing.expect(!shouldPersistNote("hi", "hey"));
    try std.testing.expect(looksLikeRememberRequest("this is how I write, remember the voice"));
    try std.testing.expect(shouldPersistNote("this is how I write", "ok"));
    const long_user = "x" ** 50;
    const long_reply = "y" ** 400;
    try std.testing.expect(shouldPersistNote(long_user, long_reply));
}

test "mergeAutoNotes inserts heading" {
    const allocator = std.testing.allocator;
    const merged = try mergeAutoNotes(allocator, "# MEMORY.md\n\n## Who I Am\n- Barvis\n", "- 2026-08-22 note\n");
    defer allocator.free(merged);
    try std.testing.expect(std.mem.indexOf(u8, merged, AUTO_HEADING) != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "2026-08-22 note") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "## Who I Am") != null);
}

test "dailyPath pads month and day" {
    const allocator = std.testing.allocator;
    const p = try dailyPath(allocator, "/tmp/ws", .{ .year = 2026, .month = 8, .day = 22 }, 0);
    defer allocator.free(p);
    try std.testing.expectEqualStrings("/tmp/ws/memory/2026-08-22.md", p);
}

test "recall ranks multi-term lines first across journals" {
    const allocator = std.testing.allocator;
    const dir = "/tmp/zeptoclaw-recall-test";
    std.Io.Dir.createDirPath(compat.cwd().dir, compat.cwd().io, dir) catch {};
    const mem_path = try std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{dir});
    defer allocator.free(mem_path);
    writeFile(mem_path, "# MEMORY.md\n- Haimdall router design notes\n");
    const jdir_path = try std.fmt.allocPrint(allocator, "{s}/memory", .{dir});
    defer allocator.free(jdir_path);
    std.Io.Dir.createDirPath(compat.cwd().dir, compat.cwd().io, jdir_path) catch {};
    const old_path = try std.fmt.allocPrint(allocator, "{s}/memory/2026-01-05.md", .{dir});
    defer allocator.free(old_path);
    writeFile(old_path, "- talked about billing webhooks\n");
    const new_path = try std.fmt.allocPrint(allocator, "{s}/memory/2026-09-04.md", .{dir});
    defer allocator.free(new_path);
    writeFile(new_path, "- Haimdall metering crate plan\n- unrelated lunch note\n");
    // Multi-term line outranks single-term lines.
    const hits = try recall(allocator, dir, "Haimdall metering", 8);
    defer allocator.free(hits);
    try std.testing.expect(std.mem.indexOf(u8, hits, "metering crate") != null);
    const first = std.mem.indexOf(u8, hits, "metering crate") orelse unreachable;
    const router = std.mem.indexOf(u8, hits, "router design");
    if (router) |r| try std.testing.expect(first < r);
    // Stopword-only queries recall nothing.
    const none = try recall(allocator, dir, "what is the", 8);
    defer allocator.free(none);
    try std.testing.expectEqualStrings("", none);
    // Explicit search shares the engine and reports no-match text.
    const miss = try search(allocator, dir, "zxqvkjwx", true);
    defer allocator.free(miss);
    try std.testing.expectEqualStrings("(no matches)", miss);
}

test "appendLongTerm and search and replaceIn" {
    const allocator = std.testing.allocator;
    const dir = "/tmp/zeptoclaw-memory-tools-test";
    std.Io.Dir.createDirPath(compat.cwd().dir, compat.cwd().io, dir) catch {};
    const mem_path = try std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{dir});
    defer allocator.free(mem_path);
    writeFile(mem_path, "# MEMORY.md\n\n## Who I Am\n- Barvis\n");
    appendLongTerm(allocator, dir, "Baala prefers Zig");
    const got = getLongTerm(allocator, dir) orelse unreachable;
    defer allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "Baala prefers Zig") != null);
    const hits = try search(allocator, dir, "prefers zig", true);
    defer allocator.free(hits);
    try std.testing.expect(std.mem.indexOf(u8, hits, "Baala prefers Zig") != null);
    const upd = try replaceIn(allocator, dir, "MEMORY.md", "Barvis", "Barvis (Jarvis)");
    defer allocator.free(upd);
    const got2 = getLongTerm(allocator, dir) orelse unreachable;
    defer allocator.free(got2);
    try std.testing.expect(std.mem.indexOf(u8, got2, "Barvis (Jarvis)") != null);
}


test "dailyContextAt filters by chat id" {
    const allocator = std.testing.allocator;
    const dir = "/tmp/zeptoclaw-dailyctx-test";
    std.Io.Dir.createDirPath(compat.cwd().dir, compat.cwd().io, dir) catch {};
    const path = try dailyPath(allocator, dir, civilNowIst(), 0);
    defer allocator.free(path);
    const body =
        "# Journal\n" ++
        "- 18:34 IST [in] (19082673946862@lid): i like ur top\n" ++
        "- 18:44 IST [in] (216638251077681@lid): hi barvis secret from selfchat\n" ++
        "- 19:08 IST [in] (19082673946862@lid): hi barvis, i like her top\n";
    writeFile(path, body);
    const got = dailyContextAt(allocator, dir, "19082673946862@lid") orelse unreachable;
    defer allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "i like ur top") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "i like her top") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "secret from selfchat") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "MEMORY.md") == null);
}

fn fuzzJournalJid(_: void, smith: *std.testing.Smith) !void {
    const ascii: []const std.testing.Smith.Weight = &.{
        .rangeAtMost(u8, '0', '9', 3),
        .rangeAtMost(u8, 'a', 'z', 2),
        .value(u8, '@', 1),
        .value(u8, '.', 1),
        .value(u8, '-', 1),
        .value(u8, '_', 1),
    };
    var a: [48]u8 = undefined;
    var b: [48]u8 = undefined;
    smith.bytesWeighted(&a, ascii);
    smith.bytesWeighted(&b, ascii);
    var line_buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "- 18:34 IST [in] ({s}): secret-from-a", .{a[0..]}) catch return;
    try std.testing.expect(lineBelongsToChat(line, a[0..]));
    if (!std.mem.eql(u8, &a, &b)) {
        var mb: [160]u8 = undefined;
        const marker_b = std.fmt.bufPrint(&mb, "] ({s}):", .{b[0..]}) catch {
            try std.testing.expect(!lineBelongsToChat(line, b[0..]));
            return;
        };
        try std.testing.expectEqual(std.mem.indexOf(u8, line, marker_b) != null, lineBelongsToChat(line, b[0..]));
    }
}

test "fuzz journal jid isolation" {
    try std.testing.fuzz({}, fuzzJournalJid, .{
        .corpus = &.{
            "19082673946862@lid\x00216638251077681@lid",
            "x@lid\x00x@lid.extra",
            "\x00peer",
        },
    });
}

test "lineBelongsToChat rejects other jid" {
    const line = "- 18:34 IST [in] (19082673946862@lid): i like ur top";
    try std.testing.expect(lineBelongsToChat(line, "19082673946862@lid"));
    try std.testing.expect(!lineBelongsToChat(line, "216638251077681@lid"));
    try std.testing.expect(!lineBelongsToChat(line, ""));
    try std.testing.expect(!lineBelongsToChat(line, "62@lid"));
}

test "lineBelongsToChat rejects suffix jid" {
    const line = "- 18:34 IST [in] (19082673946862@lid): i like ur top";
    try std.testing.expect(!lineBelongsToChat(line, "62@lid"));
    try std.testing.expect(!lineBelongsToChat(line, "lid"));
    try std.testing.expect(!lineBelongsToChat(line, "@lid"));
}

test "dailyContextAt isolation is a property of two chats" {
    const allocator = std.testing.allocator;
    const dir = "/tmp/zeptoclaw-dailyctx-prop";
    std.Io.Dir.createDirPath(compat.cwd().dir, compat.cwd().io, dir) catch {};
    const path = try dailyPath(allocator, dir, civilNowIst(), 0);
    defer allocator.free(path);
    const peer = "15555550101@lid";
    const self = "15555550102@lid";
    const body = try std.fmt.allocPrint(allocator,
        "# Journal\n- 18:34 IST [in] ({s}): peer-secret\n- 18:44 IST [in] ({s}): self-secret\n",
        .{ peer, self });
    defer allocator.free(body);
    writeFile(path, body);
    const got = dailyContextAt(allocator, dir, peer) orelse unreachable;
    defer allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "peer-secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "self-secret") == null);
}

test "memory update child argv uses HOME zeptoclaw binary" {
    const allocator = std.testing.allocator;
    const home = compat.getEnvVarOwned(allocator, "HOME") catch return;
    defer allocator.free(home);
    const path = try std.fmt.allocPrint(allocator, "{s}/zeptoclaw/zig-out/bin/zeptoclaw", .{home});
    defer allocator.free(path);
    try std.testing.expect(std.fs.path.isAbsolute(path));
}

test "runParentEnv printenv HOME is absolute like resolveWorkspaceDir needs" {
    const allocator = std.testing.allocator;
    const result = try compat.runParentEnv(allocator, &.{ "/usr/bin/printenv", "HOME" }, .limited(4096), .limited(4096), null);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const home = std.mem.trim(u8, result.stdout, " \t\r\n");
    const ws = try std.fmt.allocPrint(allocator, "{s}/.zeptoclaw/workspace", .{home});
    defer allocator.free(ws);
    try std.testing.expect(std.fs.path.isAbsolute(ws));
}
