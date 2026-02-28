//! Trigger System
//! Handles trigger matching for skill activation

const std = @import("std");
const types = @import("types.zig");

const Trigger = types.Trigger;
const TriggerType = types.TriggerType;

/// TriggerMatcher evaluates triggers against messages
pub const TriggerMatcher = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TriggerMatcher {
        return .{
            .allocator = allocator,
        };
    }

    /// Check if a trigger matches a message
    pub fn matches(self: *TriggerMatcher, trigger: Trigger, message: []const u8) !bool {
        return switch (trigger.trigger_type) {
            .mention => self.matchMention(trigger, message),
            .command => self.matchCommand(trigger, message),
            .pattern => self.matchPattern(trigger, message),
            .scheduled => error.ScheduledTriggersNotSupported,
            .event => error.EventTriggersNotSupported,
        };
    }

    /// Match mention triggers (@agent or !agent)
    fn matchMention(self: *TriggerMatcher, trigger: Trigger, message: []const u8) !bool {
        _ = self;

        const pattern = trigger.pattern orelse return false;

        // Check for @agent or !agent mentions
        const trimmed = std.mem.trim(u8, message, " \t\r\n");

        // Check if message starts with mention
        if (std.mem.startsWith(u8, trimmed, pattern)) {
            return true;
        }

        // Check if mention appears anywhere in message
        if (std.mem.indexOf(u8, trimmed, pattern)) |_| {
            return true;
        }

        return false;
    }

    /// Match command triggers (/command)
    fn matchCommand(self: *TriggerMatcher, trigger: Trigger, message: []const u8) !bool {
        _ = self;

        const pattern = trigger.pattern orelse return false;

        const trimmed = std.mem.trim(u8, message, " \t\r\n");

        // Command must be at the start of the message
        return std.mem.startsWith(u8, trimmed, pattern);
    }

    /// Match pattern triggers (regex)
    /// Match pattern triggers (regex)
    fn matchPattern(self: *TriggerMatcher, trigger: Trigger, message: []const u8) !bool {
        const pattern = trigger.pattern orelse return false;

        // Simple pattern matching (not full regex for now)
        // Supports * wildcard
        return self.matchWildcard(pattern, message);
    }

    /// Simple wildcard matching (* matches any sequence)
    fn matchWildcard(self: *TriggerMatcher, pattern: []const u8, text: []const u8) bool {
        _ = self;

        // If pattern is empty, only match empty text
        if (pattern.len == 0) {
            return text.len == 0;
        }

        // If text is empty, only match if pattern is just "*"
        if (text.len == 0) {
            return std.mem.eql(u8, pattern, "*");
        }

        // Split pattern by *
        var parts = std.mem.splitScalar(u8, pattern, '*');

        // Get first part
        var current_text = text;
        var first = parts.next();
        var has_wildcard = false;

        while (first) |part| {
            if (part.len > 0) {
                // Find this part in the current text
                const idx = std.mem.indexOf(u8, current_text, part) orelse return false;

                // If this is the first part and pattern doesn't start with *,
                // it must be at the beginning
                if (!has_wildcard and idx != 0) {
                    return false;
                }

                // Move past this part
                current_text = current_text[idx + part.len ..];
            }

            has_wildcard = true;
            first = parts.next();
        }

        // If pattern ends with *, we're done
        // Otherwise, the last part must match the end of text
        if (has_wildcard and pattern[pattern.len - 1] == '*') {
            return true;
        }

        // Check if remaining text is empty (last part matched to end)
        return current_text.len == 0;
    }

    /// Extract command arguments from a message
    pub fn extractCommandArgs(self: *TriggerMatcher, trigger: Trigger, message: []const u8) ![]const u8 {
        _ = self;

        const pattern = trigger.pattern orelse return "";

        const trimmed = std.mem.trim(u8, message, " \t\r\n");

        if (std.mem.startsWith(u8, trimmed, pattern)) {
            const args = trimmed[pattern.len..];
            return std.mem.trim(u8, args, " \t\r\n");
        }

        return "";
    }
};

/// TriggerScheduler handles scheduled triggers (cron-like)
pub const TriggerScheduler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TriggerScheduler {
        return .{
            .allocator = allocator,
        };
    }

    /// Check if a scheduled trigger should fire now
    /// Check if a scheduled trigger should fire now
    pub fn shouldFire(self: *TriggerScheduler, trigger: Trigger, current_time: i64) !bool {
        const cron_expr = trigger.cron_expr orelse return false;

        // Simple cron parsing (minute hour day month weekday)
        // Format: "0 * * * *" (every hour)
        var parts = std.mem.splitScalar(u8, cron_expr, ' ');

        const minute_str = parts.next() orelse return false;
        const hour_str = parts.next() orelse return false;
        const day_str = parts.next() orelse return false;
        const month_str = parts.next() orelse return false;
        const weekday_str = parts.next() orelse return false;

        // Parse current time
        const epoch_time = @import("std").time.epoch.EpochSeconds{ .secs = current_time };
        const epoch_day = epoch_time.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        const day_seconds = epoch_time.getDaySeconds();
        const minute = day_seconds.getMinutesIntoHour();
        const hour = day_seconds.getHoursIntoDay();
        const day = month_day.day_index;
        const month = month_day.month;
        // Calculate weekday: epoch day 0 (Jan 1, 1970) was Thursday (4)
        // Weekday: 0=Sunday, 1=Monday, ..., 6=Saturday
        const weekday = std.math.cast(u3, @mod(epoch_day.day + 4, 7)) catch unreachable;

        // Check each part
        if (!self.matchCronPart(minute_str, minute)) return false;
        if (!self.matchCronPart(hour_str, hour)) return false;
        if (!self.matchCronPart(day_str, day + 1)) return false; // 1-indexed
        if (!self.matchCronPart(month_str, @intFromEnum(month) + 1)) return false; // 1-indexed
        if (!self.matchCronPart(weekday_str, weekday)) return false; // 0-indexed

        return true;
    }

    /// Match a single cron part
    fn matchCronPart(self: *TriggerScheduler, part: []const u8, value: u8) bool {
        _ = self;

        // "*" matches any value
        if (std.mem.eql(u8, part, "*")) {
            return true;
        }

        // Parse specific value
        const parsed = std.fmt.parseInt(u8, part, 10) catch return false;
        return parsed == value;
    }
};

/// TriggerEvent handles event triggers
pub const TriggerEvent = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TriggerEvent {
        return .{
            .allocator = allocator,
        };
    }

    /// Check if an event trigger matches
    pub fn matches(self: *TriggerEvent, trigger: Trigger, event_type: []const u8) !bool {
        _ = self;

        const expected = trigger.event_type orelse return false;
        return std.mem.eql(u8, expected, event_type);
    }
};

test "TriggerMatcher matchMention" {
    const allocator = std.testing.allocator;
    var matcher = TriggerMatcher.init(allocator);

    const trigger = Trigger{
        .trigger_type = .mention,
        .pattern = "@agent",
        .cron_expr = null,
        .event_type = null,
    };
    // Don't call deinit since pattern is a string literal

    try std.testing.expect(try matcher.matches(trigger, "@agent help"));
    try std.testing.expect(try matcher.matches(trigger, "Hello @agent"));
    try std.testing.expect(!try matcher.matches(trigger, "Hello world"));
}

test "TriggerMatcher matchCommand" {
    const allocator = std.testing.allocator;
    var matcher = TriggerMatcher.init(allocator);

    const trigger = Trigger{
        .trigger_type = .command,
        .pattern = "/help",
        .cron_expr = null,
        .event_type = null,
    };
    // Don't call deinit since pattern is a string literal

    try std.testing.expect(try matcher.matches(trigger, "/help"));
    try std.testing.expect(try matcher.matches(trigger, "/help me"));
    try std.testing.expect(!try matcher.matches(trigger, "help me"));
    try std.testing.expect(!try matcher.matches(trigger, "say /help"));
}

test "TriggerMatcher matchPattern" {
    const allocator = std.testing.allocator;
    var matcher = TriggerMatcher.init(allocator);

    const trigger = Trigger{
        .trigger_type = .pattern,
        .pattern = "test*",
        .cron_expr = null,
        .event_type = null,
    };
    // Don't call deinit since pattern is a string literal

    try std.testing.expect(try matcher.matches(trigger, "test"));
    try std.testing.expect(try matcher.matches(trigger, "testing"));
    try std.testing.expect(try matcher.matches(trigger, "test123"));
    try std.testing.expect(!try matcher.matches(trigger, "hello"));
}

test "TriggerMatcher matchWildcard" {
    const allocator = std.testing.allocator;
    var matcher = TriggerMatcher.init(allocator);

    try std.testing.expect(matcher.matchWildcard("*", "anything"));
    try std.testing.expect(matcher.matchWildcard("test*", "test"));
    try std.testing.expect(matcher.matchWildcard("test*", "testing"));
    try std.testing.expect(matcher.matchWildcard("*test", "test"));
    try std.testing.expect(matcher.matchWildcard("*test", "mytest"));
    try std.testing.expect(matcher.matchWildcard("test*ing", "testing"));
    try std.testing.expect(matcher.matchWildcard("test*ing", "test123ing"));
    try std.testing.expect(!matcher.matchWildcard("test*", "hello"));
}

test "TriggerMatcher extractCommandArgs" {
    const allocator = std.testing.allocator;
    var matcher = TriggerMatcher.init(allocator);

    const trigger = Trigger{
        .trigger_type = .command,
        .pattern = "/help",
        .cron_expr = null,
        .event_type = null,
    };
    // Don't call deinit since pattern is a string literal

    const args1 = try matcher.extractCommandArgs(trigger, "/help");
    try std.testing.expectEqualStrings("", args1);

    const args2 = try matcher.extractCommandArgs(trigger, "/help me");
    try std.testing.expectEqualStrings("me", args2);

    const args3 = try matcher.extractCommandArgs(trigger, "/help me please");
    try std.testing.expectEqualStrings("me please", args3);
}

test "TriggerScheduler shouldFire" {
    const allocator = std.testing.allocator;
    var scheduler = TriggerScheduler.init(allocator);

    const trigger = Trigger{
        .trigger_type = .scheduled,
        .pattern = null,
        .cron_expr = "* * * * *", // Every minute
        .event_type = null,
    };
    // Don't call deinit since cron_expr is a string literal

    // This test is time-dependent, so we just check it doesn't crash
    _ = try scheduler.shouldFire(trigger, std.time.timestamp());
}

test "TriggerEvent matches" {
    const allocator = std.testing.allocator;
    var event = TriggerEvent.init(allocator);

    const trigger = Trigger{
        .trigger_type = .event,
        .pattern = null,
        .cron_expr = null,
        .event_type = "startup",
    };
    // Don't call deinit since event_type is a string literal

    try std.testing.expect(try event.matches(trigger, "startup"));
    try std.testing.expect(!try event.matches(trigger, "shutdown"));
}
