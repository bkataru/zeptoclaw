//! JSONL session transcripts (one file per session_id) with naive compaction.
const std = @import("std");
const compat = @import("../compat.zig");
const types = @import("../providers/types.zig");

const Allocator = std.mem.Allocator;

pub const Store = struct {
    allocator: Allocator,
    dir: []const u8,
    keep: usize,

    /// Memory: Caller owns Store; `dir` is borrowed.
    pub fn init(allocator: Allocator, dir: []const u8) Store {
        return .{ .allocator = allocator, .dir = dir, .keep = 40 };
    }

    fn pathFor(self: Store, session_id: []const u8) ![]u8 {
        var safe = try self.allocator.alloc(u8, session_id.len);
        for (session_id, 0..) |c, i| {
            safe[i] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
        }
        defer self.allocator.free(safe);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}.jsonl", .{ self.dir, safe });
    }

    /// Memory: No return; appends one JSON line.
    pub fn append(self: Store, session_id: []const u8, role: []const u8, content: []const u8) void {
        const cwd = compat.cwd();
        std.Io.Dir.createDirPath(cwd.dir, cwd.io, self.dir) catch {};
        const path = self.pathFor(session_id) catch return;
        defer self.allocator.free(path);
        var existing: []u8 = &.{};
        if (cwd.openFile(path, .{})) |f| {
            defer f.close(cwd.io);
            const st = f.stat(cwd.io) catch return;
            if (st.size > 0) {
                const sz: usize = @intCast(@min(st.size, 512 * 1024));
                existing = self.allocator.alloc(u8, sz) catch return;
                var rdr = f.reader(cwd.io, &[_]u8{});
                _ = rdr.interface.readSliceAll(existing) catch {
                    self.allocator.free(existing);
                    existing = &.{};
                };
            }
        } else |_| {}
        defer if (existing.len > 0) self.allocator.free(existing);

        const esc = escape(self.allocator, content) catch return;
        defer self.allocator.free(esc);
        const line = std.fmt.allocPrint(self.allocator, "{{\"ts\":{d},\"role\":\"{s}\",\"content\":\"{s}\"}}\n", .{
            compat.timestamp(), role, esc,
        }) catch return;
        defer self.allocator.free(line);

        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);
        body.appendSlice(self.allocator, existing) catch return;
        body.appendSlice(self.allocator, line) catch return;

        compactInPlace(&body, self.allocator, self.keep);

        const out = cwd.createFile(path, .{ .truncate = true }) catch return;
        defer out.close(cwd.io);
        var w = out.writer(cwd.io, &[_]u8{});
        w.interface.writeAll(body.items) catch return;
    }
};

fn escape(allocator: Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn compactInPlace(body: *std.ArrayList(u8), allocator: Allocator, keep: usize) void {
    var lines: usize = 0;
    for (body.items) |c| {
        if (c == '\n') lines += 1;
    }
    if (lines <= keep) return;
    var drop = lines - keep;
    var i: usize = 0;
    while (drop > 0 and i < body.items.len) {
        if (body.items[i] == '\n') drop -= 1;
        i += 1;
    }
    const rest = body.items[i..];
    const note = "{\"role\":\"system\",\"content\":\"[compacted older turns]\"}\n";
    var neu = std.ArrayList(u8).empty;
    neu.appendSlice(allocator, note) catch return;
    neu.appendSlice(allocator, rest) catch {
        neu.deinit(allocator);
        return;
    };
    body.deinit(allocator);
    body.* = neu;
}

test "escape quotes" {
    const allocator = std.testing.allocator;
    const e = try escape(allocator, "a\"b");
    defer allocator.free(e);
    try std.testing.expectEqualStrings("a\\\"b", e);
}
