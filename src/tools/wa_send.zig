//! Standalone one-shot WhatsApp native-client sender.
//!
//! Connects using an existing paired sqlite store, sends one text message to
//! a JID, waits briefly for the server ack, then exits. Useful to break a
//! stuck session (peer's device cached a stale prekey bundle and won't
//! decrypt inbound-triggered replies) by forcing a fresh outbound handshake
//! without needing a decryptable inbound message first.
//!
//! `sendText` blocks its caller waiting on IQ responses that only arrive via
//! a concurrently-running `poll()` loop (same pattern as the live gateway's
//! reader thread + agent-thread split) — so this spawns a dedicated poll
//! thread and calls `sendText` from main, not from inside the poll loop.
//!
//! Usage: zeptoclaw-wa-send <db-path> <to-jid> <text>
const std = @import("std");
const zc = @import("zeptoclaw");
const compat = zc.compat;

const native = zc.channels.whatsapp.native;

fn sleepMs(ms: u64) void {
    _ = std.c.nanosleep(&.{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) }, null);
}

const PollState = struct {
    cli: *native.client.Client,
    connected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn pollLoop(state: *PollState) void {
    while (!state.stop.load(.seq_cst)) {
        var ev = state.cli.poll() catch |err| {
            std.debug.print("poll error: {s}\n", .{@errorName(err)});
            return;
        };
        switch (ev) {
            .idle => {},
            .connected => |c| {
                std.debug.print("CONNECTED as {s} (lid {s})\n", .{ c.jid, c.lid });
                state.connected.store(true, .seq_cst);
            },
            .message => |*m| m.deinit(),
            .qr => {},
            .paired => {},
            .disconnected => |d| {
                std.debug.print("disconnected code={d} logged_out={}\n", .{ d.code, d.logged_out });
                return;
            },
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = init.minimal.args.vector;
    if (argv.len < 4) {
        std.debug.print("usage: zeptoclaw-wa-send <db-path> <to-jid> <text>\n", .{});
        return error.InvalidArgs;
    }
    const db_path = std.mem.span(argv[1]);
    const to = std.mem.span(argv[2]);
    const text = std.mem.span(argv[3]);

    var cli = native.client.Client.init(allocator);
    defer cli.deinit();
    try cli.openStore(db_path);
    try cli.loadFromStore();
    std.debug.print("loaded device {s} from {s}\n", .{ cli.selfJid() orelse "?", db_path });

    try cli.connect("");

    var state = PollState{ .cli = &cli };
    const poll_thread = try std.Thread.spawn(.{}, pollLoop, .{&state});

    var waited_s: i64 = 0;
    while (!state.connected.load(.seq_cst) and waited_s < 30) {
        sleepMs(200);
        waited_s += 1;
    }
    if (!state.connected.load(.seq_cst)) {
        state.stop.store(true, .seq_cst);
        cli.disconnect();
        poll_thread.join();
        std.debug.print("never connected in time\n", .{});
        return error.Timeout;
    }

    const msg_id = cli.sendText(to, text) catch |err| {
        std.debug.print("sendText failed: {s}\n", .{@errorName(err)});
        state.stop.store(true, .seq_cst);
        cli.disconnect();
        poll_thread.join();
        return err;
    };
    defer allocator.free(msg_id);
    std.debug.print("sent id={s} to={s}\n", .{ msg_id, to });

    // Give the poll thread a moment to observe the server ack before tearing down.
    sleepMs(8_000);

    state.stop.store(true, .seq_cst);
    cli.disconnect();
    poll_thread.join();
    std.debug.print("done\n", .{});
}
