//! Seeded mutation pass over untrusted parsers. Does not need `zig test --fuzz`
//! (Zig 0.16's test_runner currently fails to rebuild with `-ffuzz`).
const std = @import("std");
const pending = @import("channels/whatsapp/pending.zig");
const memory_update = @import("agent/memory_update.zig");
const memory_compact = @import("agent/memory_compact.zig");
const memory = @import("agent/memory.zig");

fn havoc(r: std.Random, dst: []u8, src: []const u8) []u8 {
    if (src.len == 0) {
        const n = r.intRangeAtMost(usize, 0, dst.len);
        for (dst[0..n]) |*c| c.* = r.int(u8);
        return dst[0..n];
    }
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    var len = n;
    var k: usize = 0;
    while (k < 8) : (k += 1) {
        if (len == 0) break;
        switch (r.intRangeAtMost(u8, 0, 4)) {
            0 => dst[r.intRangeLessThan(usize, 0, len)] ^= r.int(u8),
            1 => dst[r.intRangeLessThan(usize, 0, len)] = r.int(u8),
            2 => {
                if (len + 1 <= dst.len) {
                    const i = r.intRangeAtMost(usize, 0, len);
                    var j = len;
                    while (j > i) : (j -= 1) dst[j] = dst[j - 1];
                    dst[i] = r.int(u8);
                    len += 1;
                }
            },
            3 => {
                const i = r.intRangeLessThan(usize, 0, len);
                std.mem.copyForwards(u8, dst[i .. len - 1], dst[i + 1 .. len]);
                len -= 1;
            },
            else => {
                dst[r.intRangeLessThan(usize, 0, len)] = "{}[]\"\\n"[r.intRangeLessThan(usize, 0, 6)];
            },
        }
    }
    return dst[0..len];
}

test "mutate inbound json and pending jsonl" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7e970c1a);
    const r = prng.random();
    const seeds = [_][]const u8{
        "{}",
        "{\"chatId\":\"19082673946862@lid\",\"body\":\"hi\",\"fromMe\":true}",
        "{\"type\":\"connected\",\"selfJid\":\"x\"}",
        "{\"id\":\"m1\",\"chat_id\":\"190@lid\",\"body\":\"hi\",\"from_me\":true,\"direct\":true}\n",
        "{\"name\":\"exec\",\"args\":{\"command\":\"true\"}}",
        "UPDATE\nplease",
        "SKIP",
        "COMPACT",
    };
    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const seed = seeds[i % seeds.len];
        const mut = havoc(r, &buf, seed);
        const parsed = std.json.parseFromSlice(std.json.Value, a, mut, .{}) catch continue;
        parsed.deinit();

        const path = "/tmp/zeptoclaw-fuzz-pending.jsonl";
        pending.enqueueAt(a, path, "id", "c", mut, r.boolean(), true);
        const rows = pending.loadFrom(a, path) catch continue;
        for (rows) |*row| row.deinit(a);
        a.free(rows);

        _ = memory_update.parseDecision(mut);
        _ = memory_compact.parseDecision(mut);

        var line_buf: [200]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "- [in] (19082673946862@lid): {s}", .{mut[0..@min(mut.len, 40)]}) catch continue;
        _ = memory.lineBelongsToChat(line, "19082673946862@lid");
        _ = memory.lineBelongsToChat(line, "216638251077681@lid");
        _ = memory.lineBelongsToChat(line, mut);
    }
}
