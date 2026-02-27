const std = @import("std");

/// Autonomous action types for the agent
pub const AutonomousAction = enum {
    REPLY_COMMENTS,      // Priority: respond to comments on monitored posts
    BROWSE_FEED,         // Browse feed, upvote, comment on interesting posts
    CREATE_POST,         // Post original content
    SEARCH_TOPICS,       // Search for topics of interest
    IDLE,                // Nothing to do

    pub fn toString(self: AutonomousAction) []const u8 {
        return switch (self) {
            .REPLY_COMMENTS => "REPLY_COMMENTS",
            .BROWSE_FEED => "BROWSE_FEED",
            .CREATE_POST => "CREATE_POST",
            .SEARCH_TOPICS => "SEARCH_TOPICS",
            .IDLE => "IDLE",
        };
    }

    pub fn fromString(s: []const u8) ?AutonomousAction {
        return if (std.mem.eql(u8, s, "REPLY_COMMENTS"))
            .REPLY_COMMENTS
        else if (std.mem.eql(u8, s, "BROWSE_FEED"))
            .BROWSE_FEED
        else if (std.mem.eql(u8, s, "CREATE_POST"))
            .CREATE_POST
        else if (std.mem.eql(u8, s, "SEARCH_TOPICS"))
            .SEARCH_TOPICS
        else if (std.mem.eql(u8, s, "IDLE"))
            .IDLE
        else
            null;
    }
};

/// Discovery types for tracking interesting findings
pub const DiscoveryType = enum {
    interesting_molty,
    good_post,
    mention,
    conversation,

    pub fn toString(self: DiscoveryType) []const u8 {
        return switch (self) {
            .interesting_molty => "interesting_molty",
            .good_post => "good_post",
            .mention => "mention",
            .conversation => "conversation",
        };
    }
};

/// Discovery record
pub const Discovery = struct {
    timestamp: i64,
    type: DiscoveryType,
    username: ?[]const u8 = null,
    content: []const u8,
    post_id: ?[]const u8 = null,
    reason: []const u8,

    pub fn deinit(self: *Discovery, allocator: std.mem.Allocator) void {
        if (self.username) |u| allocator.free(u);
        allocator.free(self.content);
        if (self.post_id) |p| allocator.free(p);
        allocator.free(self.reason);
    }
};

/// Moltbook post structure
pub const MoltbookPost = struct {
    id: []const u8,
    content: []const u8,
    title: ?[]const u8 = null,
    author: MoltbookUser,
    created_at: []const u8,
    comment_count: u32,
    upvote_count: u32 = 0,
    submolt: ?MoltbookSubmolt = null,

    pub fn deinit(self: *MoltbookPost, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.content);
        if (self.title) |t| allocator.free(t);
        self.author.deinit(allocator);
        allocator.free(self.created_at);
        if (self.submolt) |*s| s.deinit(allocator);
    }
};

/// Moltbook user structure
pub const MoltbookUser = struct {
    id: []const u8,
    username: []const u8,
    display_name: ?[]const u8 = null,
    bio: ?[]const u8 = null,
    post_count: u32 = 0,
    follower_count: u32 = 0,

    pub fn deinit(self: *MoltbookUser, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.username);
        if (self.display_name) |d| allocator.free(d);
        if (self.bio) |b| allocator.free(b);
    }
};

/// Moltbook submolt structure
pub const MoltbookSubmolt = struct {
    name: []const u8,
    id: []const u8,

    pub fn deinit(self: *MoltbookSubmolt, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.id);
    }
};

/// Moltbook comment structure
pub const MoltbookComment = struct {
    id: []const u8,
    content: []const u8,
    author: MoltbookUser,
    created_at: []const u8,
    parent_id: ?[]const u8 = null,
    replies: ?[]MoltbookComment = null,

    pub fn deinit(self: *MoltbookComment, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.content);
        self.author.deinit(allocator);
        allocator.free(self.created_at);
        if (self.parent_id) |p| allocator.free(p);
        if (self.replies) |*replies| {
            for (replies) |*r| r.deinit(allocator);
            allocator.free(replies);
        }
    }
};

/// Post evaluation result
pub const PostEvaluation = struct {
    interesting: bool,
    score: u8, // 0-10
    reason: []const u8,
    action: PostAction,
    comment_idea: ?[]const u8 = null,

    pub fn deinit(self: *PostEvaluation, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        if (self.comment_idea) |c| allocator.free(c);
    }
};

/// Action to take on a post
pub const PostAction = enum {
    upvote,
    comment,
    skip,
    follow_author,

    pub fn toString(self: PostAction) []const u8 {
        return switch (self) {
            .upvote => "upvote",
            .comment => "comment",
            .skip => "skip",
            .follow_author => "follow_author",
        };
    }
};

/// Heartbeat data from local agent
pub const HeartbeatData = struct {
    timestamp: i64,
    gateway_pid: u32 = 0,
    wsl_memory_percent: f32 = 0.0,
    gateway_http_status: ?[]const u8 = null,
    hostname: ?[]const u8 = null,

    pub fn deinit(self: *HeartbeatData, allocator: std.mem.Allocator) void {
        if (self.gateway_http_status) |s| allocator.free(s);
        if (self.hostname) |h| allocator.free(h);
    }
};

/// Gateway incident record
pub const GatewayIncident = struct {
    timestamp: i64,
    type: []const u8,
    session_id: ?[]const u8 = null,
    stuck_duration_seconds: ?u32 = null,
    hostname: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    reported_at: []const u8,

    pub fn deinit(self: *GatewayIncident, allocator: std.mem.Allocator) void {
        allocator.free(self.type);
        if (self.session_id) |s| allocator.free(s);
        if (self.hostname) |h| allocator.free(h);
        if (self.error_message) |e| allocator.free(e);
        allocator.free(self.reported_at);
    }
};

/// Result from autonomous action execution
pub const AutonomousResult = union(AutonomousAction) {
    REPLY_COMMENTS: ReplyCommentsResult,
    BROWSE_FEED: BrowseFeedResult,
    CREATE_POST: CreatePostResult,
    SEARCH_TOPICS: SearchTopicsResult,
    IDLE: IdleResult,

    pub fn deinit(self: *AutonomousResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .REPLY_COMMENTS => |*r| r.deinit(allocator),
            .BROWSE_FEED => |*r| r.deinit(allocator),
            .CREATE_POST => |*r| r.deinit(allocator),
            .SEARCH_TOPICS => |*r| r.deinit(allocator),
            .IDLE => |*r| r.deinit(allocator),
        }
    }
};

/// Result from REPLY_COMMENTS action
pub const ReplyCommentsResult = struct {
    checked: bool,
    replies_posted: u32,
    errors: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) ReplyCommentsResult {
        return .{
            .checked = false,
            .replies_posted = 0,
            .errors = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *ReplyCommentsResult, allocator: std.mem.Allocator) void {
        for (self.errors.items) |err| allocator.free(err);
        self.errors.deinit(allocator);
    }
};

/// Result from BROWSE_FEED action
pub const BrowseFeedResult = struct {
    posts_evaluated: u32,
    upvotes: u32,
    comments: u32,
    discoveries: u32,
    errors: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) BrowseFeedResult {
        return .{
            .posts_evaluated = 0,
            .upvotes = 0,
            .comments = 0,
            .discoveries = 0,
            .errors = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *BrowseFeedResult, allocator: std.mem.Allocator) void {
        for (self.errors.items) |err| allocator.free(err);
        self.errors.deinit(allocator);
    }
};

/// Result from CREATE_POST action
pub const CreatePostResult = struct {
    success: bool,
    post_id: ?[]const u8 = null,
    content: ?[]const u8 = null,
    @"error": ?[]const u8 = null,

    pub fn deinit(self: *CreatePostResult, allocator: std.mem.Allocator) void {
        if (self.post_id) |p| allocator.free(p);
        if (self.content) |c| allocator.free(c);
        if (self.@"error") |e| allocator.free(e);
    }
};

/// Result from SEARCH_TOPICS action
pub const SearchTopicsResult = struct {
    posts_found: u32,
    upvotes: u32,
    discoveries: u32,
    search_topic: []const u8,
    errors: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, topic: []const u8) SearchTopicsResult {
        return .{
            .posts_found = 0,
            .upvotes = 0,
            .discoveries = 0,
            .search_topic = topic,
            .errors = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *SearchTopicsResult, allocator: std.mem.Allocator) void {
        allocator.free(self.search_topic);
        for (self.errors.items) |err| allocator.free(err);
        self.errors.deinit(allocator);
    }
};

/// Result from IDLE action
pub const IdleResult = struct {
    reason: []const u8,

    pub fn deinit(self: *IdleResult, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AutonomousAction toString and fromString" {
    try std.testing.expectEqualStrings("REPLY_COMMENTS", AutonomousAction.REPLY_COMMENTS.toString());
    try std.testing.expectEqualStrings("BROWSE_FEED", AutonomousAction.BROWSE_FEED.toString());
    try std.testing.expectEqualStrings("CREATE_POST", AutonomousAction.CREATE_POST.toString());
    try std.testing.expectEqualStrings("SEARCH_TOPICS", AutonomousAction.SEARCH_TOPICS.toString());
    try std.testing.expectEqualStrings("IDLE", AutonomousAction.IDLE.toString());

    try std.testing.expectEqual(AutonomousAction.REPLY_COMMENTS, AutonomousAction.fromString("REPLY_COMMENTS").?);
    try std.testing.expectEqual(AutonomousAction.BROWSE_FEED, AutonomousAction.fromString("BROWSE_FEED").?);
    try std.testing.expectEqual(AutonomousAction.CREATE_POST, AutonomousAction.fromString("CREATE_POST").?);
    try std.testing.expectEqual(AutonomousAction.SEARCH_TOPICS, AutonomousAction.fromString("SEARCH_TOPICS").?);
    try std.testing.expectEqual(AutonomousAction.IDLE, AutonomousAction.fromString("IDLE").?);
    try std.testing.expectEqual(@as(?AutonomousAction, null), AutonomousAction.fromString("INVALID"));
}

test "DiscoveryType toString" {
    try std.testing.expectEqualStrings("interesting_molty", DiscoveryType.interesting_molty.toString());
    try std.testing.expectEqualStrings("good_post", DiscoveryType.good_post.toString());
    try std.testing.expectEqualStrings("mention", DiscoveryType.mention.toString());
    try std.testing.expectEqualStrings("conversation", DiscoveryType.conversation.toString());
}

test "PostAction toString" {
    try std.testing.expectEqualStrings("upvote", PostAction.upvote.toString());
    try std.testing.expectEqualStrings("comment", PostAction.comment.toString());
    try std.testing.expectEqualStrings("skip", PostAction.skip.toString());
    try std.testing.expectEqualStrings("follow_author", PostAction.follow_author.toString());
}

test "ReplyCommentsResult init and deinit" {
    const allocator = std.testing.allocator;
    var result = ReplyCommentsResult.init(allocator);
    defer result.deinit(allocator);

    try std.testing.expect(!result.checked);
    try std.testing.expectEqual(@as(u32, 0), result.replies_posted);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
}

test "BrowseFeedResult init and deinit" {
    const allocator = std.testing.allocator;
    var result = BrowseFeedResult.init(allocator);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), result.posts_evaluated);
    try std.testing.expectEqual(@as(u32, 0), result.upvotes);
    try std.testing.expectEqual(@as(u32, 0), result.comments);
    try std.testing.expectEqual(@as(u32, 0), result.discoveries);
}

test "CreatePostResult deinit" {
    const allocator = std.testing.allocator;
    var result = CreatePostResult{
        .success = true,
        .post_id = try allocator.dupe(u8, "test-post-id"),
        .content = try allocator.dupe(u8, "test content"),
        .@"error" = null,
    };
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("test-post-id", result.post_id.?);
}

test "SearchTopicsResult init and deinit" {
    const allocator = std.testing.allocator;
    var result = SearchTopicsResult.init(allocator, "test topic");
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("test topic", result.search_topic);
    try std.testing.expectEqual(@as(u32, 0), result.posts_found);
}

test "IdleResult deinit" {
    const allocator = std.testing.allocator;
    var result = IdleResult{
        .reason = try allocator.dupe(u8, "nothing to do"),
    };
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("nothing to do", result.reason);
}
