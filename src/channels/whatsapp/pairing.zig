const std = @import("std");
const compat = @import("zeptoclaw").compat;
const Config = @import("zeptoclaw").config.Config;

pub fn runPairing(allocator: std.mem.Allocator) !void {
    var cfg = Config.load(allocator) catch |err| {
        std.debug.print("Configuration error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer cfg.deinit();

    const auth_dir = try allocator.dupe(u8, cfg.whatsapp_auth_dir);
    defer allocator.free(auth_dir);
    // Use page_allocator for large transient allocs to avoid GPA OOM
    const pa = std.heap.page_allocator;
    std.debug.print("\nWhatsApp Pairing\n  Auth dir: {s}\n  Allow from: ", .{auth_dir});
    for (cfg.whatsapp_allow_from, 0..) |jid, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{jid});
    }
    std.debug.print("\n\nStarting Baileys — scan QR with WhatsApp (Linked Devices).\nTimeout 120s, Ctrl+C to abort.\n\n", .{});

    const home = try compat.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const wrapper_path = try std.fmt.allocPrint(pa, "{s}/zeptoclaw/src/channels/whatsapp/baileys_wrapper.js", .{home});
    defer pa.free(wrapper_path);

    var child = try std.process.spawn(compat.getIo(), .{
        .argv = &[_][]const u8{ "node", wrapper_path },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // Build init JSON line
    var allow_json = try std.ArrayList(u8).initCapacity(pa, 0);
    defer allow_json.deinit(pa);
    try allow_json.append(pa, '[');
    for (cfg.whatsapp_allow_from, 0..) |jid, i| {
        if (i > 0) try allow_json.append(pa, ',');
        try allow_json.append(pa, '"');
        try allow_json.appendSlice(pa, jid);
        try allow_json.append(pa, '"');
    }
    try allow_json.append(pa, ']');

    const init_line = try std.fmt.allocPrint(pa, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"init\",\"params\":{{\"auth_dir\":\"{s}\",\"print_qr\":true,\"allow_from\":{s}}}}}\n", .{ auth_dir, allow_json.items });
    defer pa.free(init_line);

    if (child.stdin) |stdin| {
        const on_qr = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"onQr\"}\n";
        _ = try stdin.writeStreamingAll(compat.getIo(), on_qr);
        const on_conn = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"onConnection\"}\n";
        _ = try stdin.writeStreamingAll(compat.getIo(), on_conn);
        const on_msg = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"onMessage\"}\n";
        _ = try stdin.writeStreamingAll(compat.getIo(), on_msg);
        _ = try stdin.writeStreamingAll(compat.getIo(), init_line);
    }

    // Poll stdout for QR and connection
    var buf: [8192]u8 = undefined;
    var connected = false;
    const deadline = compat.timestamp() + 120;
    var line_acc = try std.ArrayList(u8).initCapacity(pa, 0);
    defer line_acc.deinit(pa);

    while (compat.timestamp() < deadline) {
        if (child.stdout) |stdout| {
            // non-blocking read via try; if no data, sleep
            const n = stdout.readStreaming(compat.getIo(), &.{buf[0..]}) catch 0;
            if (n > 0) {
                try line_acc.appendSlice(pa, buf[0..n]);
                // flush complete lines to terminal
                while (std.mem.indexOfScalar(u8, line_acc.items, '\n')) |idx| {
                    const line = line_acc.items[0..idx];
                    // Print raw line (contains QR ascii or json)
                    std.debug.print("{s}\n", .{line});
                    if (std.mem.indexOf(u8, line, "\"type\":\"connected\"") != null or std.mem.indexOf(u8, line, "connected") != null) {
                        connected = true;
                    }
                    // remove line
                    const remain = line_acc.items[idx + 1 ..];
                    const tmp = try pa.dupe(u8, remain);
                    line_acc.clearRetainingCapacity();
                    try line_acc.appendSlice(pa, tmp);
                    pa.free(tmp);
                    if (connected) break;
                }
                if (connected) break;
            }
        }
        if (connected) break;
        _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 300 * 1000000 }, null);
        // check if child exited
        // non-blocking check not available; keep polling
    }

    child.kill(compat.getIo());
    _ = child.wait(compat.getIo()) catch {};

    if (connected) {
        std.debug.print("\nPaired! Credentials saved to {s}\nRestart gateway: systemctl --user restart zeptoclaw-gateway.service\n", .{auth_dir});
    } else {
        std.debug.print("\nPairing timed out. Try again: zeptoclaw whatsapp pair\n", .{});
        return error.ConnectionTimeout;
    }
}
