const std = @import("std");
const whatsapp = @import("whatsapp_channel.zig");

const StressThreadArgs = struct {
    channel: *whatsapp.WhatsAppChannel,
    stop: *std.atomic.Value(bool),
    err: *std.atomic.Value(bool),
    is_writer: bool,
};

fn stressThread(arg: *StressThreadArgs) void {
    const channel = arg.channel;
    const stop = arg.stop;
    const err_flag = arg.err;
    const is_writer = arg.is_writer;

    if (is_writer) {
        // Allocate strings once before loop
        const jid_str = "+1234567890@s.whatsapp.net";
        const e164_str = "+1234567890";
        const jid_copy = channel.allocator.dupe(u8, jid_str) catch {
            err_flag.store(true, .seq_cst);
            return;
        };
        const e164_copy = channel.allocator.dupe(u8, e164_str) catch {
            channel.allocator.free(jid_copy);
            err_flag.store(true, .seq_cst);
            return;
        };

        defer {
            channel.allocator.free(jid_copy);
            channel.allocator.free(e164_copy);
        }

        while (!stop.load(.seq_cst)) {
            channel.mutex.lock();
            channel.connected = true;
            channel.self_jid = jid_copy;
            channel.self_e164 = e164_copy;
            channel.mutex.unlock();
        }
    } else {
        while (!stop.load(.seq_cst)) {
            channel.mutex.lock();
            _ = channel.connected;
            _ = channel.self_jid;
            _ = channel.self_e164;
            channel.mutex.unlock();
        }
    }
}

test "thread safety stress test" {
    const allocator = std.testing.allocator;

    var config = try whatsapp.WhatsAppConfig.init(allocator);
    defer config.deinit();

    var channel = whatsapp.WhatsAppChannel.init(allocator, config);
    // Do not call connect; just manipulate state directly
    defer channel.deinit();

    var stop_flag = std.atomic.Value(bool).init(false);
    var error_flag = std.atomic.Value(bool).init(false);

    const num_writers = 2;
    const num_readers = 8;
    const total_threads = num_writers + num_readers;

    var threads: [total_threads]std.Thread = undefined;
    var args: [total_threads]StressThreadArgs = undefined;

    var i: usize = 0;
    while (i < total_threads) : (i += 1) {
        args[i] = .{
            .channel = &channel,
            .stop = &stop_flag,
            .err = &error_flag,
            .is_writer = i < num_writers,
        };
        threads[i] = try std.Thread.spawn(.{}, stressThread, .{&args[i]});
    }

    // Run for 5 seconds
    std.Thread.sleep(5 * std.time.ns_per_s);
    stop_flag.store(true, .seq_cst);

    // Join all threads
    i = 0;
    while (i < total_threads) : (i += 1) {
        threads[i].join();
    }
    // Reset to avoid double free
    channel.self_jid = null;
    channel.self_e164 = null;

    if (error_flag.load(.seq_cst)) {
        return error.TestFailed;
    }
}
