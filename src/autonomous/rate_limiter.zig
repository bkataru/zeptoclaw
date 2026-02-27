const std = @import("std");

/// Rate limiter for Moltbook API calls
pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    last_post_time: i64 = 0,
    last_comment_time: i64 = 0,
    comments_today: u32 = 0,
    last_day_reset: i64 = 0,

    // Rate limits (in milliseconds)
    const POST_COOLDOWN_MS = 30 * 60 * 1000; // 30 minutes
    const COMMENT_COOLDOWN_MS = 20 * 1000; // 20 seconds
    const MAX_COMMENTS_PER_DAY = 50;

    pub fn init(allocator: std.mem.Allocator) RateLimiter {
        return .{
            .allocator = allocator,
        };
    }
    pub fn deinit(_: *RateLimiter) void {}

    /// Check if a post can be created now
    pub fn canPost(self: *RateLimiter, current_time: i64) bool {
        return (current_time - self.last_post_time) >= POST_COOLDOWN_MS;
    }

    /// Check if a comment can be created now
    pub fn canComment(self: *RateLimiter, current_time: i64) bool {
        // Check cooldown
        if ((current_time - self.last_comment_time) < COMMENT_COOLDOWN_MS) {
            return false;
        }

        // Check daily limit
        self.resetDayIfNeeded(current_time);
        return self.comments_today < MAX_COMMENTS_PER_DAY;
    }

    /// Get time until next post is allowed (in milliseconds)
    pub fn timeUntilNextPost(self: *RateLimiter, current_time: i64) i64 {
        const elapsed = current_time - self.last_post_time;
        const remaining = POST_COOLDOWN_MS - elapsed;
        return if (remaining > 0) remaining else 0;
    }

    /// Get time until next comment is allowed (in milliseconds)
    pub fn timeUntilNextComment(self: *RateLimiter, current_time: i64) i64 {
        const elapsed = current_time - self.last_comment_time;
        const remaining = COMMENT_COOLDOWN_MS - elapsed;
        return if (remaining > 0) remaining else 0;
    }

    /// Get remaining comments for today
    pub fn remainingCommentsToday(self: *RateLimiter, current_time: i64) u32 {
        self.resetDayIfNeeded(current_time);
        return MAX_COMMENTS_PER_DAY - self.comments_today;
    }

    /// Record a post creation
    pub fn recordPost(self: *RateLimiter, current_time: i64) void {
        self.last_post_time = current_time;
    }

    /// Record a comment creation
    pub fn recordComment(self: *RateLimiter, current_time: i64) void {
        self.resetDayIfNeeded(current_time);
        self.last_comment_time = current_time;
        self.comments_today += 1;
    }

    /// Reset daily counter if needed
    fn resetDayIfNeeded(self: *RateLimiter, current_time: i64) void {
        const current_day = @divTrunc(current_time, 24 * 60 * 60 * 1000);
        const last_day = @divTrunc(self.last_day_reset, 24 * 60 * 60 * 1000);

        if (current_day > last_day) {
            self.comments_today = 0;
            self.last_day_reset = current_time;
        }
    }

    /// Get rate limit status
    pub fn getStatus(self: *RateLimiter, current_time: i64) RateLimitStatus {
        self.resetDayIfNeeded(current_time);

        return .{
            .can_post = self.canPost(current_time),
            .can_comment = self.canComment(current_time),
            .time_until_post_ms = self.timeUntilNextPost(current_time),
            .time_until_comment_ms = self.timeUntilNextComment(current_time),
            .comments_today = self.comments_today,
            .comments_remaining = self.remainingCommentsToday(current_time),
            .max_comments_per_day = MAX_COMMENTS_PER_DAY,
        };
    }
};

/// Rate limit status
pub const RateLimitStatus = struct {
    can_post: bool,
    can_comment: bool,
    time_until_post_ms: i64,
    time_until_comment_ms: i64,
    comments_today: u32,
    comments_remaining: u32,
    max_comments_per_day: u32,
};

// ============================================================================
// Tests
// ============================================================================

test "RateLimiter init" {
    const allocator = std.testing.allocator;
    const limiter = RateLimiter.init(allocator);

    try std.testing.expectEqual(@as(i64, 0), limiter.last_post_time);
    try std.testing.expectEqual(@as(i64, 0), limiter.last_post_time);
    try std.testing.expectEqual(@as(i64, 0), limiter.last_comment_time);
    try std.testing.expectEqual(@as(u32, 0), limiter.comments_today);
}

test "RateLimiter canPost" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator);

    const now = std.time.timestamp() * 1000;

    // Should be able to post initially
    try std.testing.expect(limiter.canPost(now));

    // Record a post
    limiter.recordPost(now);

    // Should not be able to post immediately after
    try std.testing.expect(!limiter.canPost(now));

    // Should be able to post after cooldown
    try std.testing.expect(limiter.canPost(now + RateLimiter.POST_COOLDOWN_MS));
}

test "RateLimiter canComment" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator);

    const now = std.time.timestamp() * 1000;

    // Should be able to comment initially
    try std.testing.expect(limiter.canComment(now));

    // Record a comment
    limiter.recordComment(now);

    // Should not be able to comment immediately after
    try std.testing.expect(!limiter.canComment(now));

    // Should be able to comment after cooldown
    try std.testing.expect(limiter.canComment(now + RateLimiter.COMMENT_COOLDOWN_MS));
}

test "RateLimiter daily limit" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator);

    const now = std.time.timestamp() * 1000;

    // Record 50 comments
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        limiter.recordComment(now + @as(i64, @intCast(i)) * RateLimiter.COMMENT_COOLDOWN_MS);
    }

    // Should not be able to comment after hitting daily limit
    try std.testing.expect(!limiter.canComment(now + 50 * RateLimiter.COMMENT_COOLDOWN_MS));

    // Should have 0 remaining comments
    try std.testing.expectEqual(@as(u32, 0), limiter.remainingCommentsToday(now + 50 * RateLimiter.COMMENT_COOLDOWN_MS));
}

test "RateLimiter timeUntilNextPost" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator);

    const now = std.time.timestamp() * 1000;

    // Should be 0 initially
    try std.testing.expectEqual(@as(i64, 0), limiter.timeUntilNextPost(now));

    // Record a post
    limiter.recordPost(now);

    // Should be full cooldown immediately after
    try std.testing.expectEqual(@as(i64, RateLimiter.POST_COOLDOWN_MS), limiter.timeUntilNextPost(now));

    // Should decrease over time
    try std.testing.expectEqual(@as(i64, RateLimiter.POST_COOLDOWN_MS - 1000), limiter.timeUntilNextPost(now + 1000));
}

test "RateLimiter timeUntilNextComment" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator);

    const now = std.time.timestamp() * 1000;

    // Should be 0 initially
    try std.testing.expectEqual(@as(i64, 0), limiter.timeUntilNextComment(now));

    // Record a comment
    limiter.recordComment(now);

    // Should be full cooldown immediately after
    try std.testing.expectEqual(@as(i64, RateLimiter.COMMENT_COOLDOWN_MS), limiter.timeUntilNextComment(now));

    // Should decrease over time
    try std.testing.expectEqual(@as(i64, RateLimiter.COMMENT_COOLDOWN_MS - 1000), limiter.timeUntilNextComment(now + 1000));
}

test "RateLimiter getStatus" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator);

    const now = std.time.timestamp() * 1000;

    const status = limiter.getStatus(now);

    try std.testing.expect(status.can_post);
    try std.testing.expect(status.can_comment);
    try std.testing.expectEqual(@as(i64, 0), status.time_until_post_ms);
    try std.testing.expectEqual(@as(i64, 0), status.time_until_comment_ms);
    try std.testing.expectEqual(@as(u32, 0), status.comments_today);
    try std.testing.expectEqual(@as(u32, RateLimiter.MAX_COMMENTS_PER_DAY), status.comments_remaining);
    try std.testing.expectEqual(@as(u32, RateLimiter.MAX_COMMENTS_PER_DAY), status.max_comments_per_day);
}

test "RateLimiter remainingCommentsToday" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator);

    const now = std.time.timestamp() * 1000;

    // Should start with max
    try std.testing.expectEqual(@as(u32, RateLimiter.MAX_COMMENTS_PER_DAY), limiter.remainingCommentsToday(now));

    // Record some comments
    limiter.recordComment(now);
    limiter.recordComment(now + RateLimiter.COMMENT_COOLDOWN_MS);
    limiter.recordComment(now + 2 * RateLimiter.COMMENT_COOLDOWN_MS);

    // Should decrease
    try std.testing.expectEqual(@as(u32, RateLimiter.MAX_COMMENTS_PER_DAY - 3), limiter.remainingCommentsToday(now + 3 * RateLimiter.COMMENT_COOLDOWN_MS));
}
