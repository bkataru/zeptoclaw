//! Standalone WhatsApp native-client pairing tool.
//!
//! Prints a scannable QR in the terminal, pairs a linked device into its own
//! sqlite auth dir, and stays connected printing inbound messages until
//! Ctrl-C. The default auth dir is separate from the Baileys gateway's
//! (`~/.zeptoclaw/sessions/whatsapp-native` vs `.../whatsapp`), so pairing
//! here never touches the live gateway session.
//!
//! Usage: zeptoclaw-wa-pair [auth-dir]
const std = @import("std");
const zc = @import("zeptoclaw");
const compat = zc.compat;

const native = zc.channels.whatsapp.native;

fn sleepMs(ms: u64) void {
    _ = std.c.nanosleep(&.{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) }, null);
}

fn printQr(allocator: std.mem.Allocator, ref: []const u8) void {
    const qr = native.qrcode.renderUtf8(allocator, ref) catch |err| {
        std.debug.print("(qr render failed: {s}; raw ref follows)\n{s}\n", .{ @errorName(err), ref });
        return;
    };
    defer allocator.free(qr);
    std.debug.print(
        \\
        \\{s}
        \\
        \\  -> WhatsApp app: Settings > Linked devices > Link a device
        \\  raw ref: {s}
        \\
        \\
    , .{ qr, ref });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const dir = if (init.minimal.args.vector.len >= 2)
        try allocator.dupe(u8, std.mem.span(init.minimal.args.vector[1]))
    else blk: {
        const home = try compat.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        break :blk try std.fmt.allocPrint(allocator, "{s}/.zeptoclaw/sessions/whatsapp-native", .{home});
    };
    defer allocator.free(dir);
    {
        const cwd = compat.cwd();
        std.Io.Dir.createDirPath(cwd.dir, cwd.io, dir) catch {};
    }

    const db_path = try std.fmt.allocPrint(allocator, "{s}/store.db", .{dir});
    defer allocator.free(db_path);

    var cli = native.client.Client.init(allocator);
    defer cli.deinit();
    try cli.openStore(db_path);
    cli.loadFromStore() catch |err| switch (err) {
        error.NotPaired => std.debug.print("no paired device in {s} — showing QR\n", .{dir}),
        else => return err,
    };
    if (cli.paired) {
        std.debug.print("restored device {s} from {s}\n", .{ cli.selfJid() orelse "?", dir });
    }

    var backoff_ms: u64 = 2000;
    while (true) {
        std.debug.print("connecting…\n", .{});
        cli.connect("") catch |err| {
            std.debug.print("connect failed: {s} — retrying in {d}ms\n", .{ @errorName(err), backoff_ms });
            sleepMs(backoff_ms);
            backoff_ms = @min(backoff_ms * 2, 60_000);
            continue;
        };
        backoff_ms = 2000;

        var need_reconnect = false;
        while (!need_reconnect) {
            var ev = cli.poll() catch |err| {
                std.debug.print("poll error: {s}\n", .{@errorName(err)});
                need_reconnect = true;
                continue;
            };
            switch (ev) {
                .idle => {},
                .qr => |codes| {
                    if (codes.len == 0) continue;
                    // Linked Devices camera must see exactly one live QR (Baileys
                    // rotates refs; dumping all of them at once garbles the scan).
                    std.debug.print("QR ready ({d} refs, showing first — scan within ~60s)\n", .{codes.len});
                    printQr(allocator, codes[0]);
                },
                .paired => |p| {
                    std.debug.print("PAIRED as {s} (lid {s}) — server closes next, reconnecting\n", .{ p.jid, p.lid });
                    need_reconnect = true;
                },
                .connected => |c| {
                    std.debug.print("CONNECTED as {s} (lid {s}) — Ctrl-C to quit\n", .{ c.jid, c.lid });
                },
                .message => |*m| {
                    std.debug.print("msg chat={s} from={s} text={s}\n", .{ m.chat, m.sender, m.text });
                    m.deinit();
                },
                .disconnected => |d| {
                    std.debug.print("disconnected code={d} logged_out={}\n", .{ d.code, d.logged_out });
                    if (d.logged_out) return;
                    need_reconnect = true;
                },
            }
        }
        cli.disconnect();
        sleepMs(backoff_ms);
    }
}
