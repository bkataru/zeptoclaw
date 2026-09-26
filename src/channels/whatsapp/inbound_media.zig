//! Same-chat inbound image: data URL for NIM vision, last-image index by JID.
const std = @import("std");
const compat = @import("../../compat.zig");

const MAX_BYTES: usize = 4 * 1024 * 1024;

fn safeChat(out: []u8, chat_id: []const u8) []const u8 {
    var n: usize = 0;
    for (chat_id) |c| {
        if (n >= out.len) break;
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        out[n] = if (ok) c else '_';
        n += 1;
    }
    return out[0..n];
}

/// Memory: caller owns the returned path. Mirrors where the channel writes
/// (`WHATSAPP_AUTH_DIR` wins, else `~/.zeptoclaw/sessions/whatsapp`).
fn authDirPath(allocator: std.mem.Allocator) ![]u8 {
    if (compat.getEnvVarOwned(allocator, "WHATSAPP_AUTH_DIR")) |auth| return auth else |_| {}
    return compat.homeJoin(allocator, ".zeptoclaw/sessions/whatsapp");
}

fn lastFile(allocator: std.mem.Allocator, chat_id: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    const safe = safeChat(&buf, chat_id);
    const auth = try authDirPath(allocator);
    defer allocator.free(auth);
    return std.fmt.allocPrint(allocator, "{s}/last-image/{s}.txt", .{ auth, safe });
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
    const sz: usize = @intCast(@min(st.size, @as(u64, 4096)));
    const buf = allocator.alloc(u8, sz) catch return null;
    var r = f.reader(cwd.io, &[_]u8{});
    r.interface.readSliceAll(buf) catch {
        allocator.free(buf);
        return null;
    };
    return buf;
}

pub fn remember(allocator: std.mem.Allocator, chat_id: []const u8, mime: []const u8, path: []const u8) void {
    const fp = lastFile(allocator, chat_id) catch return;
    defer allocator.free(fp);
    const body = std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{ mime, path }) catch return;
    defer allocator.free(body);
    writeAll(fp, body);
}

/// Memory: caller owns path if non-null. mime_out is filled if non-null (static slice, not owned).
pub fn loadLast(allocator: std.mem.Allocator, chat_id: []const u8, mime_buf: *[64]u8) ?[]u8 {
    const fp = lastFile(allocator, chat_id) catch return null;
    defer allocator.free(fp);
    const buf = readAll(allocator, fp) orelse return null;
    defer allocator.free(buf);
    var it = std.mem.splitScalar(u8, buf, '\n');
    const mime = std.mem.trim(u8, it.next() orelse return null, " \r\t");
    const path = std.mem.trim(u8, it.next() orelse return null, " \r\t");
    if (path.len == 0) return null;
    const n = @min(mime.len, mime_buf.len);
    @memcpy(mime_buf[0..n], mime[0..n]);
    if (n < mime_buf.len) mime_buf[n] = 0;
    return allocator.dupe(u8, path) catch null;
}

/// Memory: caller owns data URL.
pub fn fileToDataUrl(allocator: std.mem.Allocator, path: []const u8, mime: []const u8) ?[]u8 {
    return fileToDataUrlCapped(allocator, path, mime, MAX_BYTES);
}

/// Memory: caller owns data URL. Video clips run bigger than images; callers
/// pass their own ceiling (WhatsApp videos regularly exceed the 4MB default).
pub fn fileToDataUrlCapped(allocator: std.mem.Allocator, path: []const u8, mime: []const u8, max_bytes: usize) ?[]u8 {
    const cwd = compat.cwd();
    const f = cwd.openFile(path, .{}) catch return null;
    defer f.close(cwd.io);
    const st = f.stat(cwd.io) catch return null;
    if (st.kind != .file or st.size == 0 or st.size > max_bytes) return null;
    const sz: usize = @intCast(st.size);
    const raw = allocator.alloc(u8, sz) catch return null;
    defer allocator.free(raw);
    var r = f.reader(cwd.io, &[_]u8{});
    r.interface.readSliceAll(raw) catch return null;
    const enc_len = std.base64.standard.Encoder.calcSize(raw.len);
    const b64 = allocator.alloc(u8, enc_len) catch return null;
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, raw);
    const m = if (mime.len > 0) mime else "image/jpeg";
    return std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ m, b64 }) catch null;
}

/// Disk budget for downloaded media. Photos, voice notes, and clips accumulate
/// forever otherwise, so the oldest files are evicted once the directory
/// passes this ceiling.
pub const CACHE_LIMIT_BYTES: u64 = 1024 * 1024 * 1024;

const CacheEntry = struct {
    name: []u8,
    size: u64,
    mtime_ns: i96,
};

/// Evict oldest media files until the cache fits `limit_bytes`. Returns bytes
/// reclaimed. `last-image` pointers whose file was evicted are dropped too, so
/// the media tools never report an attachment that is already gone.
pub fn enforceCacheLimit(allocator: std.mem.Allocator, limit_bytes: u64) u64 {
    const auth = authDirPath(allocator) catch return 0;
    defer allocator.free(auth);
    const media_path = std.fmt.allocPrint(allocator, "{s}/media", .{auth}) catch return 0;
    defer allocator.free(media_path);
    const reclaimed = evictOldest(allocator, media_path, limit_bytes);
    if (reclaimed > 0) {
        std.log.info("[whatsapp] media cache capped at {d}MB; evicted oldest {d}MB", .{ limit_bytes / (1024 * 1024), reclaimed / (1024 * 1024) });
        pruneDanglingPointers(allocator, auth);
    }
    return reclaimed;
}

/// Delete oldest-first from `dir_path` until `limit_bytes` is satisfied.
fn evictOldest(allocator: std.mem.Allocator, dir_path: []const u8, limit_bytes: u64) u64 {
    const io = compat.getIo();
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var entries: std.ArrayList(CacheEntry) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        const st = dir.statFile(io, e.name, .{}) catch continue;
        total += st.size;
        const name = allocator.dupe(u8, e.name) catch continue;
        entries.append(allocator, .{ .name = name, .size = st.size, .mtime_ns = st.mtime.nanoseconds }) catch {
            allocator.free(name);
            continue;
        };
    }
    if (total <= limit_bytes) return 0;
    std.mem.sort(CacheEntry, entries.items, {}, struct {
        fn olderFirst(_: void, a: CacheEntry, b: CacheEntry) bool {
            return a.mtime_ns < b.mtime_ns;
        }
    }.olderFirst);
    var reclaimed: u64 = 0;
    for (entries.items) |e| {
        if (total <= limit_bytes) break;
        dir.deleteFile(io, e.name) catch continue;
        total -= e.size;
        reclaimed += e.size;
    }
    return reclaimed;
}

fn pruneDanglingPointers(allocator: std.mem.Allocator, auth: []const u8) void {
    const io = compat.getIo();
    const dir_path = std.fmt.allocPrint(allocator, "{s}/last-image", .{auth}) catch return;
    defer allocator.free(dir_path);
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, e.name }) catch continue;
        defer allocator.free(full);
        const body = readAll(allocator, full) orelse continue;
        defer allocator.free(body);
        // Format: "<mime>\n<path>\n".
        const nl = std.mem.indexOfScalar(u8, body, '\n') orelse continue;
        const target = std.mem.trim(u8, body[nl + 1 ..], " \r\t\n");
        if (target.len == 0) continue;
        std.Io.Dir.accessAbsolute(io, target, .{}) catch dir.deleteFile(io, e.name) catch continue;
    }
}

test "fileToDataUrl jpeg tiny" {
    const a = std.testing.allocator;
    const path = "/tmp/zeptoclaw-vision-tiny.jpg";
    writeAll(path, "abc");
    const url = fileToDataUrl(a, path, "image/jpeg") orelse unreachable;
    defer a.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, "data:image/jpeg;base64,"));
}

test "evictOldest drops oldest files first and stops at the cap" {
    const a = std.testing.allocator;
    const io = compat.getIo();
    const dir_path = "/tmp/zeptoclaw-media-evict";
    std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);

    // 3 x 400 bytes: oldest, middle, newest.
    const names = [_][]const u8{ "old.jpg", "mid.jpg", "new.jpg" };
    const base = 1_700_000_000_000_000_000;
    for (names, 0..) |name, i| {
        const f = try dir.createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        var w = f.writer(io, &[_]u8{});
        try w.interface.writeAll(&[_]u8{'x'} ** 400);
        try dir.setTimestamps(io, name, .{
            .modify_timestamp = .{ .new = .{ .nanoseconds = base + @as(i96, @intCast(i)) * std.time.ns_per_hour } },
        });
    }

    // Cap below two files: with 1200 bytes total and an 800-byte cap, only the
    // oldest file needs to go.
    const reclaimed = evictOldest(a, dir_path, 800);
    try std.testing.expectEqual(@as(u64, 400), reclaimed);
    try std.testing.expectError(error.FileNotFound, dir.statFile(io, "old.jpg", .{}));
    _ = try dir.statFile(io, "mid.jpg", .{});
    _ = try dir.statFile(io, "new.jpg", .{});

    // Under the cap: nothing more is touched.
    try std.testing.expectEqual(@as(u64, 0), evictOldest(a, dir_path, 800));
    _ = try dir.statFile(io, "mid.jpg", .{});
}
