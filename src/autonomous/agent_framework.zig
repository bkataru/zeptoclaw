const std = @import("std");
const types = @import("types.zig");
const state_store = @import("state_store.zig");
const moltbook_client = @import("moltbook_client.zig");
const rate_limiter = @import("rate_limiter.zig");

/// Autonomous agent framework
pub const AutonomousAgent = struct {
    allocator: std.mem.Allocator,
    state_store: *state_store.StateStore,
    moltbook_client: *moltbook_client.MoltbookClient,
    rate_limiter: rate_limiter.RateLimiter,
    nim_client: *anyopaque, // Will be cast to NIMClient

    // Cooldowns (in milliseconds)
    const POST_COOLDOWN_MS = 4 * 60 * 60 * 1000; // 4 hours
    const BROWSE_COOLDOWN_MS = 25 * 60 * 1000; // 25 minutes
    const LOCAL_AGENT_TIMEOUT_MS = 60 * 60 * 1000; // 1 hour

    // Search topics
    const SEARCH_TOPICS = [_][]const u8{
        "neutrino physics",
        "zig programming",
        "agent architecture",
        "AI consciousness",
        "systems programming",
        "comptime",
        "SIMD optimization",
        "memory systems",
    };

    pub fn init(
        allocator: std.mem.Allocator,
        store: *state_store.StateStore,
        client: *moltbook_client.MoltbookClient,
        nim_client: *anyopaque,
    ) AutonomousAgent {
        return .{
            .allocator = allocator,
            .state_store = store,
            .moltbook_client = client,
            .rate_limiter = rate_limiter.RateLimiter.init(allocator),
            .nim_client = nim_client,
        };
    }

    /// Select the next action to execute based on priority
    pub fn selectNextAction(self: *AutonomousAgent) !types.AutonomousAction {
        const state = self.state_store.state;
        const now = std.time.timestamp() * 1000;

        // Priority 1: Always check for pending comment replies first
        const monitored_posts = self.moltbook_client.getMonitoredPosts();
        for (monitored_posts) |post_id| {
            if (try self.hasUnrepliedComments(post_id)) {
                std.log.info("Found pending replies - selecting REPLY_COMMENTS", .{});
                return .REPLY_COMMENTS;
            }
        }

        // Priority 2: Post if we haven't in 4+ hours and have ideas
        if ((now - state.last_post) > POST_COOLDOWN_MS and state.post_ideas.items.len > 0) {
            std.log.info("Post cooldown elapsed and have ideas - selecting CREATE_POST", .{});
            return .CREATE_POST;
        }

        // Priority 3: Browse feed if we haven't in 25+ minutes
        if ((now - state.last_browse) > BROWSE_COOLDOWN_MS) {
            std.log.info("Browse cooldown elapsed - selecting BROWSE_FEED", .{});
            return .BROWSE_FEED;
        }

        // Priority 4: Search for topics of interest (random chance)
        if (randomFloat() < 0.3) {
            std.log.info("Random selection - SEARCH_TOPICS", .{});
            return .SEARCH_TOPICS;
        }

        // Default: browse feed anyway
        std.log.info("Default action - BROWSE_FEED", .{});
        return .BROWSE_FEED;
    }

    /// Execute an autonomous action
    pub fn executeAction(self: *AutonomousAgent, action: types.AutonomousAction) !types.AutonomousResult {
        std.log.info("Executing action: {s}", .{action.toString()});

        const result = switch (action) {
            .REPLY_COMMENTS => try self.executeReplyComments(),
            .BROWSE_FEED => try self.executeBrowseFeed(),
            .CREATE_POST => try self.executeCreatePost(),
            .SEARCH_TOPICS => try self.executeSearchTopics(),
            .IDLE => types.AutonomousResult{
                .IDLE = types.IdleResult{
                    .reason = try self.allocator.dupe(u8, "No action needed"),
                },
            },
        };

        // Update last action
        try self.state_store.updateLastAction(action);

        return result;
    }

    /// Check if local agent is down and worker should take over
    pub fn shouldWorkerTakeOver(self: *AutonomousAgent) bool {
        const state = self.state_store.state;
        const now = std.time.timestamp() * 1000;

        // If local agent hasn't pinged in over an hour, worker takes over
        return (now - state.local_last_seen) > LOCAL_AGENT_TIMEOUT_MS;
    }

    /// Execute REPLY_COMMENTS action
    fn executeReplyComments(self: *AutonomousAgent) !types.AutonomousResult {
        var result = types.ReplyCommentsResult.init(self.allocator);
        errdefer result.deinit(self.allocator);

        var state = &self.state_store.state;
        const now = std.time.timestamp() * 1000;

        // Update last check time
        try self.state_store.updateLastCheck(now);

        // Get monitored posts
        const monitored_posts = self.moltbook_client.getMonitoredPosts();

        for (monitored_posts) |post_id| {
            // Fetch comments
            const comments = self.moltbook_client.getComments(post_id, .new) catch |err| {
                const err_msg = try std.fmt.allocPrint(self.allocator, "Error fetching comments for {s}: {}", .{ post_id, err });
                try result.errors.append(self.allocator, err_msg);
                continue;
            };
            defer self.allocator.free(comments);

            // Find unreplied comments
            const unreplied = try self.findUnrepliedComments(comments);

            std.log.info("Found {d} unreplied comments on post {s}", .{ unreplied.len, post_id });

            // Reply to up to 3 comments per check
            for (unreplied[0..@min(3, unreplied.len)]) |comment| {
                // Check rate limit
                if (!self.rate_limiter.canComment(now)) {
                    std.log.warn("Rate limit reached, skipping comment", .{});
                    break;
                }

                // Generate reply
                const reply = try self.generateReply();
                defer self.allocator.free(reply);

                // Post reply
                const success = self.moltbook_client.createComment(post_id, reply, comment.id) catch |err| {
                    const err_msg = try std.fmt.allocPrint(self.allocator, "Failed to post reply to {s}: {}", .{ comment.id, err });
                    try result.errors.append(self.allocator, err_msg);
                    continue;
                };

                if (success) {
                    result.replies_posted += 1;
                    try state.markCommentReplied(comment.id);
                    try self.state_store.updateLastReply(now);
                    state.total_replies += 1;
                    std.log.info("Successfully replied to comment {s}", .{comment.id});
                } else {
                    const err_msg = try std.fmt.allocPrint(self.allocator, "Failed to post reply to {s}", .{comment.id});
                    try result.errors.append(self.allocator, err_msg);
                }

                // Wait 20 seconds between replies (rate limit)
                if (result.replies_posted > 0) {
                    // std.time.sleep(21 * std.time.ns_per_s); // TODO: Implement sleep
                }
            }
        }

        result.checked = true;
        try self.state_store.save();

        return types.AutonomousResult{ .REPLY_COMMENTS = result };
    }

    /// Execute BROWSE_FEED action
    fn executeBrowseFeed(self: *AutonomousAgent) !types.AutonomousResult {
        var result = types.BrowseFeedResult.init(self.allocator);
        errdefer result.deinit(self.allocator);

        var state = &self.state_store.state;
        const now = std.time.timestamp() * 1000;

        // Update last browse time
        try self.state_store.updateLastBrowse(now);

        // Fetch hot posts
        const posts = self.moltbook_client.fetchFeed(.hot, 15) catch |err| {
            const err_msg = try std.fmt.allocPrint(self.allocator, "Error fetching feed: {}", .{err});
            try result.errors.append(self.allocator, err_msg);
            return types.AutonomousResult{ .BROWSE_FEED = result };
        };
        defer {
            for (posts) |*p| p.deinit(self.allocator);
            self.allocator.free(posts);
        }

        // Filter out posts we've already seen
        var new_posts = try std.ArrayList(*const types.MoltbookPost).initCapacity(self.allocator, 0);
        defer new_posts.deinit(self.allocator);

        for (posts) |*post| {
            if (!state.hasSeenPost(post.id)) {
                try new_posts.append(self.allocator, post);
            }
        }

        std.log.info("Found {d} new posts out of {d}", .{ new_posts.items.len, posts.len });

        // Mark these posts as seen
        for (new_posts.items) |post| {
            try state.markPostSeen(post.id);
        }

        // Evaluate up to 5 posts per run
        const posts_to_evaluate = @min(5, new_posts.items.len);
        for (new_posts.items[0..posts_to_evaluate]) |post| {
            // Skip our own posts
            if (std.mem.eql(u8, post.author.id, self.moltbook_client.agent_id)) {
                continue;
            }

            result.posts_evaluated += 1;

            // Evaluate post
            var evaluation = try self.evaluatePost();
            defer evaluation.deinit(self.allocator);

            if (!evaluation.interesting) {
                std.log.info("Skipping post - not interesting (score: {d})", .{evaluation.score});
                continue;
            }

            std.log.info("Interesting! Score: {d}, Action: {s}", .{ evaluation.score, evaluation.action.toString() });

            // Execute the recommended action
            if (evaluation.action == .upvote or evaluation.action == .comment) {
                // Always upvote interesting posts
                if (!state.hasUpvotedPost(post.id)) {
                    const upvote_success = self.moltbook_client.upvotePost(post.id) catch false;




                    if (upvote_success) {
                        result.upvotes += 1;
                        try state.markPostUpvoted(post.id);
                        state.total_upvotes += 1;
                    }
                }
            }

            if (evaluation.action == .comment and evaluation.comment_idea != null) {
                // Check rate limit
                if (!self.rate_limiter.canComment(now)) {
                    std.log.warn("Rate limit reached, skipping comment", .{});
                    break;
                }

                // Generate comment
                const comment = try self.generateComment();
                defer self.allocator.free(comment);

                if (!state.hasCommentedOnPost(post.id)) {
                    const comment_success = self.moltbook_client.createComment(post.id, comment, null) catch false;




                    if (comment_success) {
                        result.comments += 1;
                        try state.markPostCommented(post.id);
                        state.total_comments += 1;

                        // Log as discovery
                        const discovery = types.Discovery{
                            .timestamp = now,
                            .type = .good_post,
                            .username = try self.allocator.dupe(u8, post.author.username),
                            .content = try self.allocator.dupe(u8, post.content[0..@min(200, post.content.len)]),
                            .post_id = try self.allocator.dupe(u8, post.id),
                            .reason = try std.fmt.allocPrint(self.allocator, "Commented: {s}", .{comment[0..@min(100, comment.len)]}),
                        };
                        try state.addDiscovery(discovery);
                        result.discoveries += 1;
                    }
                }
            }

            if (evaluation.action == .follow_author) {
                // Track as interesting molty but don't follow immediately
                if (!state.isInterestingMolty(post.author.username)) {
                    try state.trackInterestingMolty(post.author.username);

                    const discovery = types.Discovery{
                        .timestamp = now,
                        .type = .interesting_molty,
                        .username = try self.allocator.dupe(u8, post.author.username),
                        .content = try self.allocator.dupe(u8, post.content[0..@min(200, post.content.len)]),
                        .post_id = try self.allocator.dupe(u8, post.id),
                        .reason = try self.allocator.dupe(u8, evaluation.reason),
                    };
                    try state.addDiscovery(discovery);
                    result.discoveries += 1;
                }
            }

            // Only process one comment per run to stay within time limits
            if (result.comments >= 1) break;
        }

        try self.state_store.save();

        return types.AutonomousResult{ .BROWSE_FEED = result };
    }

    /// Execute CREATE_POST action
    fn executeCreatePost(self: *AutonomousAgent) !types.AutonomousResult {
        var state = &self.state_store.state;
        const now = std.time.timestamp() * 1000;

        // Check rate limit
        if (!self.rate_limiter.canPost(now)) {
            return types.AutonomousResult{
                .CREATE_POST = types.CreatePostResult{
                    .success = false,
                    .@"error" = try self.allocator.dupe(u8, "Rate limit: too soon since last post"),
                },
            };
        }

        // Pop an idea from the queue, or generate freely
        const idea = state.popPostIdea();

        // Generate post content
        const content = try self.generatePost(idea);
        defer self.allocator.free(content);

        if (content.len < 50) {
            return types.AutonomousResult{
                .CREATE_POST = types.CreatePostResult{
                    .success = false,
                    .@"error" = try self.allocator.dupe(u8, "Generated content too short"),
                },
            };
        }

        // Create post
        const post_id = self.moltbook_client.createPost(content, null) catch |err| {
            return types.AutonomousResult{
                .CREATE_POST = types.CreatePostResult{
                    .success = false,
                    .@"error" = try std.fmt.allocPrint(self.allocator, "Failed to create post: {}", .{err}),
                },
            };
        };

        // Post created successfully - update state
            // Update state
            try self.state_store.updateLastPost(now);
            state.total_posts += 1;

            // Log as discovery
            const discovery = types.Discovery{
                .timestamp = now,
                .type = .conversation,
                .content = try self.allocator.dupe(u8, content[0..@min(200, content.len)]),
                .post_id = try self.allocator.dupe(u8, post_id),
                .reason = try self.allocator.dupe(u8, "Created original post"),
            };
            try state.addDiscovery(discovery);

            try self.state_store.save();

            return types.AutonomousResult{
                .CREATE_POST = types.CreatePostResult{
                    .success = true,
                    .post_id = try self.allocator.dupe(u8, post_id),
                    .content = try self.allocator.dupe(u8, content),
                },
            };








    }

    /// Execute SEARCH_TOPICS action
    fn executeSearchTopics(self: *AutonomousAgent) !types.AutonomousResult {
        var result = types.SearchTopicsResult.init(self.allocator, "test");
        errdefer result.deinit(self.allocator);

        var state = &self.state_store.state;
        const now = std.time.timestamp() * 1000;

        // Pick a random search topic
        const search_topic = SEARCH_TOPICS[@as(usize, @intFromFloat(randomFloat() * SEARCH_TOPICS.len))];
        result.search_topic = try self.allocator.dupe(u8, search_topic);

        std.log.info("Searching for: {s}", .{search_topic});

        // Search for posts
        const posts = self.moltbook_client.searchPosts(search_topic, 10) catch |err| {
            const err_msg = try std.fmt.allocPrint(self.allocator, "Error searching: {}", .{err});
            try result.errors.append(self.allocator, err_msg);
            return types.AutonomousResult{ .SEARCH_TOPICS = result };
        };
        defer {
            for (posts) |*p| p.deinit(self.allocator);
            self.allocator.free(posts);
        }

        result.posts_found = std.math.lossyCast(u32, posts.len);

        // Filter out seen posts
        var new_posts = try std.ArrayList(*const types.MoltbookPost).initCapacity(self.allocator, 0);
        defer new_posts.deinit(self.allocator);

        for (posts) |*post| {
            if (!state.hasSeenPost(post.id)) {
                try new_posts.append(self.allocator, post);
            }
        }

        std.log.info("Found {d} new posts for \"{s}\"", .{ new_posts.items.len, search_topic });

        // Mark as seen
        for (new_posts.items) |post| {
            try state.markPostSeen(post.id);
        }

        // Evaluate and upvote interesting posts (no comments on search to save time)
        const posts_to_evaluate = @min(3, new_posts.items.len);
        for (new_posts.items[0..posts_to_evaluate]) |post| {
            if (std.mem.eql(u8, post.author.id, self.moltbook_client.agent_id)) {
                continue;
            }

            var evaluation = try self.evaluatePost();
            defer evaluation.deinit(self.allocator);

            if (evaluation.interesting and evaluation.score >= 6) {
                // Upvote high-quality search results
                if (!state.hasUpvotedPost(post.id)) {
                    const upvote_success = self.moltbook_client.upvotePost(post.id) catch false;




                    if (upvote_success) {
                        result.upvotes += 1;
                        try state.markPostUpvoted(post.id);
                    }
                }

                // Log as discovery
                const discovery = types.Discovery{
                    .timestamp = now,
                    .type = .good_post,
                    .username = try self.allocator.dupe(u8, post.author.username),
                    .content = try self.allocator.dupe(u8, post.content[0..@min(200, post.content.len)]),
                    .post_id = try self.allocator.dupe(u8, post.id),
                    .reason = try std.fmt.allocPrint(self.allocator, "Found via search \"{s}\": {s}", .{ search_topic, evaluation.reason }),
                };
                try state.addDiscovery(discovery);
                result.discoveries += 1;
            }
        }

        try self.state_store.save();

        return types.AutonomousResult{ .SEARCH_TOPICS = result };
    }

    /// Check if a post has unreplied comments
    fn hasUnrepliedComments(self: *AutonomousAgent, post_id: []const u8) !bool {
        const comments = try self.moltbook_client.getComments(post_id, .new);
        defer self.allocator.free(comments);

        const unreplied = try self.findUnrepliedComments(comments);
        return unreplied.len > 0;
    }

    /// Find unreplied comments
    fn findUnrepliedComments(self: *AutonomousAgent, comments: []types.MoltbookComment) ![]types.MoltbookComment {
        var state = &self.state_store.state;
        const agent_id = self.moltbook_client.agent_id;

        var unreplied = try std.ArrayList(types.MoltbookComment).initCapacity(self.allocator, 0);

        for (comments) |comment| {
            // Skip our own comments
            if (std.mem.eql(u8, comment.author.id, agent_id)) continue;

            // Skip if already marked as replied in state
            if (state.hasRepliedToComment(comment.id)) continue;

            // Include if it's a top-level comment (no parent_id)
            if (comment.parent_id == null) {
                try unreplied.append(self.moltbook_client.allocator, comment);
            }
        }

        return try unreplied.toOwnedSlice(self.moltbook_client.allocator);
    }

    /// Generate a reply to a comment
    fn generateReply(self: *AutonomousAgent) ![]const u8 {
        // TODO: Implement LLM-based reply generation
        // For now, return a simple reply
        return try self.allocator.dupe(u8, "Thanks for your comment!");
    }

    /// Evaluate a post
    fn evaluatePost(self: *AutonomousAgent) !types.PostEvaluation {
        // TODO: Implement LLM-based post evaluation
        // For now, return a simple evaluation
        return types.PostEvaluation{
            .interesting = false,
            .score = 0,
            .reason = try self.allocator.dupe(u8, "Evaluation not implemented"),
            .action = .skip,
        };
    }

    /// Generate a comment for a post
    fn generateComment(self: *AutonomousAgent) ![]const u8 {
        // TODO: Implement LLM-based comment generation
        // For now, return a simple comment
        return try self.allocator.dupe(u8, "Interesting post!");
    }

    /// Generate a post
    fn generatePost(self: *AutonomousAgent, idea: ?[]const u8) ![]const u8 {
        // TODO: Implement LLM-based post generation
        // For now, return a simple post
        if (idea) |i| {
            return try std.fmt.allocPrint(self.allocator, "About {s}: This is a test post.", .{i});
        } else {
            return try self.allocator.dupe(u8, "This is a test post about something interesting.");
        }
    }

    /// Generate a random float between 0 and 1
    fn randomFloat() f32 {
        return @as(f32, @floatFromInt(std.crypto.random.int(u32))) / @as(f32, @floatFromInt(std.math.maxInt(u32)));

    }
};

// ============================================================================
// Tests
// ============================================================================

test "AutonomousAgent init" {
    const allocator = std.testing.allocator;
    _ = allocator;
    // Test requires StateStore, MoltbookClient, and NIMClient instances
    // This test would need mock implementations
}

test "SEARCH_TOPICS constant" {
    try std.testing.expectEqual(@as(usize, 8), AutonomousAgent.SEARCH_TOPICS.len);
    try std.testing.expectEqualStrings("neutrino physics", AutonomousAgent.SEARCH_TOPICS[0]);
    try std.testing.expectEqualStrings("zig programming", AutonomousAgent.SEARCH_TOPICS[1]);
}
