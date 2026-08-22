//! Seeded mutation pass over untrusted parsers. Does not need `zig test --fuzz`
//! (Zig 0.16's test_runner currently fails to rebuild with `-ffuzz`).
const std = @import("std");
const pending = @import("channels/whatsapp/pending.zig");
const memory_update = @import("agent/memory_update.zig");
const memory_compact = @import("agent/memory_compact.zig");
const memory = @import("agent/memory.zig");
const nim = @import("providers/nim.zig");
const inbound_media = @import("channels/whatsapp/inbound_media.zig");
const WhatsAppChannel = @import("channels/whatsapp/whatsapp_channel.zig").WhatsAppChannel;
const engagement = @import("channels/whatsapp/engagement.zig");

pub const builtin_seeds = [_][]const u8{
    "{}",
    "{\"chatId\":\"15555550101@lid\",\"body\":\"hi\",\"fromMe\":true,\"id\":\"m1\"}",
    "{\"type\":\"connected\",\"selfJid\":\"15555550100:55@s.whatsapp.net\"}",
    "{\"id\":\"m1\",\"chat_id\":\"15555550101@lid\",\"body\":\"hi\",\"from_me\":true,\"direct\":true}\n",
    "{\"name\":\"exec\",\"args\":{\"command\":\"true\"}}",
    "UPDATE\nplease",
    "SKIP",
    "COMPACT",
    "{\"id\":\"cmpl\",\"model\":\"x\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}],\"created\":1,\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}",
    "{\"error\":{\"message\":\"rate\",\"type\":\"rate_limit\"}}",
    "{\"seen\":[\"AAA\"],\"sent\":[],\"fingerprints\":{\"15555550101@lid|1|hi\":1}}",
    "image/jpeg\n/tmp/zeptoclaw-vision-tiny.jpg\n",
    "- 18:34 IST [in] (15555550101@lid): x\n- 18:44 IST [in] (15555550102@lid): y\n",
};

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

fn oneShot(a: std.mem.Allocator, r: std.Random, mut: []const u8) void {
    if (std.json.parseFromSlice(std.json.Value, a, mut, .{})) |parsed| {
        defer parsed.deinit();
        var msg = WhatsAppChannel.parseMessage(a, parsed.value) catch {
            const upd = WhatsAppChannel.parseConnectionUpdate(a, parsed.value) catch return;
            if (upd.self_jid) |s| a.free(s);
            if (upd.self_e164) |s| a.free(s);
            if (upd.@"error") |s| a.free(s);
            return;
        };
        msg.deinit();
        if (nim.tryParseCompletion(a, mut)) |comp| {
            var c = comp;
            c.deinit();
        } else |_| {}
    } else |_| {}

    const path = "/tmp/zeptoclaw-fuzz-pending.jsonl";
    pending.enqueueAt(a, path, "id", "15555550101@lid", mut, r.boolean(), true);
    if (pending.loadFrom(a, path)) |rows| {
        for (rows) |*row| row.deinit(a);
        a.free(rows);
    } else |_| {}

    _ = memory_update.parseDecision(mut);
    _ = memory_compact.parseDecision(mut);

    var line_buf: [240]u8 = undefined;
    const clip = mut[0..@min(mut.len, 40)];
    const line = std.fmt.bufPrint(&line_buf, "- [in] (15555550101@lid): {s}", .{clip}) catch return;
    _ = memory.lineBelongsToChat(line, "15555550101@lid");
    _ = memory.lineBelongsToChat(line, "15555550102@lid");
    _ = memory.lineBelongsToChat(line, mut);

    engagement.subscribe(mut);
    _ = engagement.isSubscribed(mut);
    engagement.unsubscribe(mut);

    var mime_buf: [64]u8 = [_]u8{0} ** 64;
    if (inbound_media.loadLast(a, "15555550101@lid", &mime_buf)) |p| a.free(p);
}

/// Memory: no return ownership. `iters` is havoc count.
pub fn runHavoc(a: std.mem.Allocator, iters: usize, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const seed_s = builtin_seeds[i % builtin_seeds.len];
        const mut = havoc(r, &buf, seed_s);
        oneShot(a, r, mut);
    }
}

test "mutate inbound json and pending jsonl" {
    runHavoc(std.testing.allocator, 400, 0x7e970c1a);
}

test "parseMessage rejects non-object without panic" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "[]", .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidMessage, WhatsAppChannel.parseMessage(a, parsed.value));
}

test "tryParseCompletion valid and invalid" {
    const a = std.testing.allocator;
    if (nim.tryParseCompletion(a, "")) |p| p.deinit() else |_| {}
    if (nim.tryParseCompletion(a, "{}")) |p| p.deinit() else |_| {}
    const ok = "{\"id\":\"i\",\"model\":\"m\",\"choices\":[],\"created\":0,\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":0,\"total_tokens\":0}}";
    var p = try nim.tryParseCompletion(a, ok);
    p.deinit();
}
