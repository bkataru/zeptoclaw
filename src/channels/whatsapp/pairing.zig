const std = @import("std");
const Config = @import("zeptoclaw").config.Config;
const WhatsAppChannel = @import("zeptoclaw").channels.whatsapp.WhatsAppChannel;

pub fn runPairing(allocator: std.mem.Allocator) !void {
    // Pairing needs only WhatsApp fields; never require NVIDIA_API_KEY here.
    var cfg = Config.loadForPairing(allocator) catch |err| {
        std.debug.print("Configuration error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer cfg.deinit();

    const auth_dir = try allocator.dupe(u8, cfg.whatsapp_auth_dir);
    defer allocator.free(auth_dir);

    std.debug.print("\nWhatsApp Pairing (native)\n  Auth dir: {s}\n  Store: {s}/native.sqlite\n  Allow from: ", .{ auth_dir, auth_dir });
    for (cfg.whatsapp_allow_from, 0..) |jid, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{jid});
    }
    std.debug.print("\n\nScan QR with WhatsApp (Linked Devices). Ctrl+C to abort.\n\n", .{});
    const jid = try WhatsAppChannel.runNativePairForeground(allocator, auth_dir);
    defer allocator.free(jid);
    std.debug.print("paired as {s}\n", .{jid});
    std.debug.print("Credentials saved to {s}/native.sqlite\nRestart gateway: systemctl --user restart zeptoclaw-gateway.service\n", .{auth_dir});
}
