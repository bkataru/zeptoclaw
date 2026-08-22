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

fn lastFile(allocator: std.mem.Allocator, chat_id: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    const safe = safeChat(&buf, chat_id);
    if (compat.getEnvVarOwned(allocator, "WHATSAPP_AUTH_DIR")) |auth| {
        defer allocator.free(auth);
        return std.fmt.allocPrint(allocator, "{s}/last-image/{s}.txt", .{ auth, safe });
    } else |_| {}
    const rel = try std.fmt.allocPrint(allocator, ".zeptoclaw/sessions/whatsapp/last-image/{s}.txt", .{safe});
    defer allocator.free(rel);
    return compat.homeJoin(allocator, rel);
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
    const cwd = compat.cwd();
    const f = cwd.openFile(path, .{}) catch return null;
    defer f.close(cwd.io);
    const st = f.stat(cwd.io) catch return null;
    if (st.kind != .file or st.size == 0 or st.size > MAX_BYTES) return null;
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

test "fileToDataUrl jpeg tiny" {
    const a = std.testing.allocator;
    const path = "/tmp/zeptoclaw-vision-tiny.jpg";
    writeAll(path, "abc");
    const url = fileToDataUrl(a, path, "image/jpeg") orelse unreachable;
    defer a.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, "data:image/jpeg;base64,"));
}
