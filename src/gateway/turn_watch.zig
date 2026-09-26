//! Stuck-turn watchdog.
//!
//! A turn that never finishes is invisible from the outside: the WhatsApp
//! connection stays up, inbound keeps being journalled, and the only symptom
//! is that replies stop arriving. That is exactly how the 4xx retry loop ran
//! unnoticed for over a week. This tracks in-flight turns so the gateway can
//! warn in the journal at every threshold crossing and report the count on
//! `/health`.
//!
//! One `Watch` is shared by every turn thread and the watchdog thread, so all
//! state access goes through the mutex.
const std = @import("std");
const compat = @import("../compat.zig");

/// A turn older than this is worth a warning. Overridable with
/// `ZEPTO_SLOW_TURN_S` so an operator can tighten or loosen it without a
/// rebuild.
pub const DEFAULT_WARN_AFTER_S: i64 = 600;

const Entry = struct {
    id: u64,
    chat_id: []const u8,
    started: i64,
    /// Threshold multiple already warned about, so a wedged turn logs once per
    /// threshold step instead of on every sweep.
    warned_step: i64 = 0,
};

pub const Stats = struct {
    in_flight: u32 = 0,
    oldest_age_s: i64 = 0,
    slow: u32 = 0,
};

pub const Watch = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    next_id: u64 = 1,
    warn_after_s: i64 = DEFAULT_WARN_AFTER_S,
    mu: std.Io.Mutex = .init,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator) Watch {
        return .{ .allocator = allocator, .io = compat.getIo() };
    }

    pub fn deinit(self: *Watch) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.entries.items) |e| self.allocator.free(e.chat_id);
        self.entries.deinit(self.allocator);
    }

    /// Apply `ZEPTO_SLOW_TURN_S` if set. Call once at startup.
    pub fn loadWarnThreshold(self: *Watch, allocator: std.mem.Allocator) void {
        const raw = compat.getEnvVarOwned(allocator, "ZEPTO_SLOW_TURN_S") catch return;
        defer allocator.free(raw);
        const parsed = std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \r\t"), 10) catch return;
        if (parsed > 0) self.warn_after_s = parsed;
    }

    /// Register a turn starting now. Caller passes the returned token to `end`.
    /// Memory: `chat_id` is copied.
    pub fn begin(self: *Watch, chat_id: []const u8) u64 {
        const copy = self.allocator.dupe(u8, chat_id) catch return 0;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const id = self.next_id;
        self.next_id += 1;
        self.entries.append(self.allocator, .{ .id = id, .chat_id = copy, .started = compat.timestamp() }) catch {
            self.allocator.free(copy);
            return 0;
        };
        return id;
    }

    /// Clear a finished turn. No-op for a token `begin` already dropped, or for
    /// the sentinel 0 from a failed `begin`.
    pub fn end(self: *Watch, id: u64) void {
        if (id == 0) return;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        for (self.entries.items, 0..) |e, i| {
            if (e.id != id) continue;
            self.allocator.free(e.chat_id);
            _ = self.entries.swapRemove(i);
            return;
        }
    }

    /// Log every turn past the threshold that has not been warned at this step
    /// yet. Returns the stats read after the sweep.
    pub fn sweep(self: *Watch, now: i64) Stats {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var snap = Stats{};
        for (self.entries.items) |*e| {
            const age = now - e.started;
            snap.in_flight += 1;
            if (age > snap.oldest_age_s) snap.oldest_age_s = age;
            if (age < self.warn_after_s) continue;
            snap.slow += 1;
            const step = @divFloor(age, self.warn_after_s);
            if (step <= e.warned_step) continue;
            e.warned_step = step;
            std.log.warn("[whatsapp] turn stuck chat={s} age={d}s; later messages in this chat queue behind it", .{ e.chat_id, age });
        }
        return snap;
    }

    /// Snapshot without logging. Used by `/health`.
    pub fn stats(self: *Watch) Stats {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        var snap = Stats{};
        const now = compat.timestamp();
        for (self.entries.items) |e| {
            const age = now - e.started;
            snap.in_flight += 1;
            if (age > snap.oldest_age_s) snap.oldest_age_s = age;
            if (age >= self.warn_after_s) snap.slow += 1;
        }
        return snap;
    }
};

/// Watchdog thread body: warn about stuck turns forever. Runs against the same
/// `Watch` the turn handlers register with.
pub fn run(watch: *Watch, interval_s: u64) void {
    std.log.info("[whatsapp] stuck-turn watchdog on: warn after {d}s, sweep {d}s", .{ watch.warn_after_s, interval_s });
    while (true) {
        sleepSeconds(interval_s);
        _ = watch.sweep(compat.timestamp());
    }
}

fn sleepSeconds(s: u64) void {
    var left = s;
    while (left > 0) {
        const chunk: u64 = @min(left, 60);
        _ = std.c.nanosleep(&.{ .sec = @intCast(chunk), .nsec = 0 }, null);
        left -= chunk;
    }
}

test "Watch clears a turn on end and counts only live ones" {
    const a = std.testing.allocator;
    var watch = Watch.init(a);
    defer watch.deinit();

    const first = watch.begin("chat-a");
    const second = watch.begin("chat-b");
    try std.testing.expectEqual(@as(u32, 2), watch.stats().in_flight);

    watch.end(first);
    try std.testing.expectEqual(@as(u32, 1), watch.stats().in_flight);

    // Ending twice, or with the sentinel token, must not corrupt the list.
    watch.end(first);
    watch.end(0);
    try std.testing.expectEqual(@as(u32, 1), watch.stats().in_flight);

    watch.end(second);
    try std.testing.expectEqual(@as(u32, 0), watch.stats().in_flight);
}

test "Watch warns once per threshold step and goes quiet when the turn ends" {
    const a = std.testing.allocator;
    var watch = Watch.init(a);
    defer watch.deinit();
    watch.warn_after_s = 100;

    const id = watch.begin("chat-stuck");
    try std.testing.expect(id != 0);
    const started = watch.entries.items[0].started;

    // Just under the threshold: not yet slow, nothing warned.
    var stats = watch.sweep(started + 99);
    try std.testing.expectEqual(@as(u32, 0), stats.slow);
    try std.testing.expectEqual(@as(i64, 0), watch.entries.items[0].warned_step);

    // First crossing warns once.
    stats = watch.sweep(started + 100);
    try std.testing.expectEqual(@as(u32, 1), stats.slow);
    try std.testing.expectEqual(@as(i64, 1), watch.entries.items[0].warned_step);
    try std.testing.expectEqual(@as(i64, 100), stats.oldest_age_s);

    // Further sweeps inside the same step stay quiet.
    _ = watch.sweep(started + 150);
    try std.testing.expectEqual(@as(i64, 1), watch.entries.items[0].warned_step);

    // A later step warns again: a turn stuck for 20 minutes matters more.
    stats = watch.sweep(started + 250);
    try std.testing.expectEqual(@as(i64, 2), watch.entries.items[0].warned_step);
    try std.testing.expectEqual(@as(i64, 250), stats.oldest_age_s);

    // The live snapshot agrees with the sweep.
    try std.testing.expectEqual(@as(u32, 1), watch.stats().in_flight);

    // Ending the turn silences it even at a much later time.
    watch.end(id);
    stats = watch.sweep(started + 5000);
    try std.testing.expectEqual(@as(u32, 0), stats.slow);
    try std.testing.expectEqual(@as(i64, 0), stats.oldest_age_s);
}
