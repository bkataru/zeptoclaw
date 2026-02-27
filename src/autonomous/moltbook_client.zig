const std = @import("std");
const types = @import("types.zig");

/// Moltbook API client
pub const MoltbookClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    client: std.http.Client,
    agent_id: []const u8,
    agent_name: []const u8,
    monitored_posts: std.ArrayList([]const u8),

    const DEFAULT_BASE_URL = "https://www.moltbook.com/api/v1";

    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        agent_id: []const u8,
        agent_name: []const u8,
        monitored_posts: []const []const u8,
    ) !MoltbookClient {
        var monitored_posts_list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
        for (monitored_posts) |post_id| {
            try monitored_posts_list.append(allocator, try allocator.dupe(u8, post_id));
        }

        return .{
            .allocator = allocator,
            .api_key = api_key,
            .base_url = DEFAULT_BASE_URL,
            .client = std.http.Client{ .allocator = allocator },
            .agent_id = agent_id,
            .agent_name = agent_name,
            .monitored_posts = monitored_posts_list,
        };
    }

    pub fn deinit(self: *MoltbookClient) void {
        for (self.monitored_posts.items) |post_id| {
            self.allocator.free(post_id);
        }
        self.monitored_posts.deinit(self.allocator);
        self.client.deinit();
    }

    /// Fetch feed posts
    pub fn fetchFeed(
        self: *MoltbookClient,
        sort: FeedSort,
        limit: u32,
    ) ![]types.MoltbookPost {
        const sort_str = sort.toString();
        var url_buf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buf,
            "{s}/posts?sort={s}&limit={d}",
            .{ self.base_url, sort_str, limit },
        );

        var response = try self.makeRequest("GET", url, null);
        defer response.deinit(self.allocator);

        if (response.status_code != 200) {
            return error.MoltbookApiError;
        }

        const FeedResponse = struct {
            posts: []types.MoltbookPost,
        };

        const parsed = std.json.parseFromSlice(
            FeedResponse,
            self.allocator,
            response.body,
            .{},
        ) catch |err| {
            std.log.err("Failed to parse feed response: {}", .{err});
            return error.ParseError;
        };
        defer parsed.deinit();

        return parsed.value.posts;
    }

    /// Search for posts
    pub fn searchPosts(
        self: *MoltbookClient,
        query: []const u8,
        limit: u32,
    ) ![]types.MoltbookPost {
        var url_buf: [1024]u8 = undefined;
        // Skip URL escaping for now
const url = try std.fmt.bufPrint(&url_buf, "{s}/search?q={s}&limit={d}", .{ self.base_url, query, limit });


        var response = try self.makeRequest("GET", url, null);
        defer response.deinit(self.allocator);

        if (response.status_code != 200) {
            return error.MoltbookApiError;
        }

        const SearchResponse = struct {
            posts: []types.MoltbookPost,
        };

        const parsed = std.json.parseFromSlice(
            SearchResponse,
            self.allocator,
            response.body,
            .{},
        ) catch |err| {
            std.log.err("Failed to parse search response: {}", .{err});
            return error.ParseError;
        };
        defer parsed.deinit();

        return parsed.value.posts;
    }

    /// Get a specific post
    pub fn getPost(self: *MoltbookClient, post_id: []const u8) !types.MoltbookPost {
        var url_buf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buf,
            "{s}/posts/{s}",
            .{ self.base_url, post_id },
        );

        var response = try self.makeRequest("GET", url, null);
        defer response.deinit(self.allocator);

        if (response.status_code != 200) {
            return error.MoltbookApiError;
        }

        const PostResponse = struct {
            post: types.MoltbookPost,
        };

        const parsed = std.json.parseFromSlice(
            PostResponse,
            self.allocator,
            response.body,
            .{},
        ) catch |err| {
            std.log.err("Failed to parse post response: {}", .{err});
            return error.ParseError;
        };
        defer parsed.deinit();

        return parsed.value.post;
    }

    /// Get comments for a post
    pub fn getComments(
        self: *MoltbookClient,
        post_id: []const u8,
        sort: CommentSort,
    ) ![]types.MoltbookComment {
        const sort_str = sort.toString();
        var url_buf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buf,
            "{s}/posts/{s}/comments?sort={s}",
            .{ self.base_url, post_id, sort_str },
        );

        var response = try self.makeRequest("GET", url, null);
        defer response.deinit(self.allocator);

        if (response.status_code != 200) {
            return error.MoltbookApiError;
        }

        const CommentsResponse = struct {
            comments: []types.MoltbookComment,
        };

        const parsed = std.json.parseFromSlice(
            CommentsResponse,
            self.allocator,
            response.body,
            .{},
        ) catch |err| {
            std.log.err("Failed to parse comments response: {}", .{err});
            return error.ParseError;
        };
        defer parsed.deinit();

        return parsed.value.comments;
    }

    /// Create a post
    pub fn createPost(
        self: *MoltbookClient,
        content: []const u8,
        submolt: ?[]const u8,
    ) ![]const u8 {





// Manually create JSON for CreatePostRequest
const body_str = if (submolt) |s|
try std.fmt.allocPrint(self.allocator, "{{\"content\":\"{s}\",\"submolt\":\"{s}\"}}", .{content, s})
else
try std.fmt.allocPrint(self.allocator, "{{\"content\":\"{s}\",\"submolt\":null}}", .{content});














        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/posts",
            .{self.base_url},
        );
        defer self.allocator.free(url);

        var response = try self.makeRequest("POST", url, body_str);
        defer response.deinit(self.allocator);

        if (response.status_code != 201 and response.status_code != 200) {
            std.log.err("Failed to create post: status {}", .{response.status_code});
            return error.MoltbookApiError;
        }

        const CreatePostResponse = struct {
            post: struct {
                id: []const u8,
            },
        };

        const parsed = std.json.parseFromSlice(
            CreatePostResponse,
            self.allocator,
            response.body,
            .{},
        ) catch |err| {
            std.log.err("Failed to parse create post response: {}", .{err});
            return error.ParseError;
        };
        defer parsed.deinit();

        return try self.allocator.dupe(u8, parsed.value.post.id);
    }

    /// Create a comment on a post
    pub fn createComment(
        self: *MoltbookClient,
        post_id: []const u8,
        content: []const u8,
        parent_id: ?[]const u8,
    ) !bool {










        // Manually create JSON
const body_str = if (parent_id) |pid|
try std.fmt.allocPrint(self.allocator, "{{\"content\":\"{s}\",\"parent_id\":\"{s}\"}}", .{content, pid})
else
try std.fmt.allocPrint(self.allocator, "{{\"content\":\"{s}\",\"parent_id\":null}}", .{content});









        var url_buf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buf,
            "{s}/posts/{s}/comments",
            .{ self.base_url, post_id },
        );

        var response = try self.makeRequest("POST", url, body_str);
        defer response.deinit(self.allocator);

        return response.status_code == 201 or response.status_code == 200;
    }

    /// Upvote a post
    pub fn upvotePost(self: *MoltbookClient, post_id: []const u8) !bool {
        var url_buf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buf,
            "{s}/posts/{s}/upvote",
            .{ self.base_url, post_id },
        );

        var response = try self.makeRequest("POST", url, null);
        defer response.deinit(self.allocator);

        return response.status_code == 200 or response.status_code == 201;
    }

    /// Upvote a comment
    pub fn upvoteComment(self: *MoltbookClient, comment_id: []const u8) !bool {
        var url_buf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buf,
            "{s}/comments/{s}/upvote",
            .{ self.base_url, comment_id },
        );

        var response = try self.makeRequest("POST", url, null);
        defer response.deinit(self.allocator);

        return response.status_code == 200 or response.status_code == 201;
    }

    /// Get monitored posts
    pub fn getMonitoredPosts(self: *const MoltbookClient) []const []const u8 {
        return self.monitored_posts.items;
    }

    /// Add a monitored post
    pub fn addMonitoredPost(self: *MoltbookClient, post_id: []const u8) !void {
        const post_id_copy = try self.allocator.dupe(u8, post_id);
        try self.monitored_posts.append(self.allocator, post_id_copy);
    }

    /// Make an HTTP request to Moltbook API
    fn makeRequest(
        self: *MoltbookClient,
        method: []const u8,
        url: []const u8,
        body: ?[]const u8,
    ) !HttpResponse {
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;

        var headers = std.ArrayList(std.http.Header).initCapacity(self.allocator, 0) catch unreachable;
        defer headers.deinit(self.allocator);

        try headers.append(self.allocator, .{ .name = "Authorization", .value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key}) });
        try headers.append(self.allocator, .{ .name = "Content-Type", .value = "application/json" });

        const http_method = if (std.mem.eql(u8, method, "GET"))
            std.http.Method.GET
        else if (std.mem.eql(u8, method, "POST"))
            std.http.Method.POST
        else if (std.mem.eql(u8, method, "PUT"))
            std.http.Method.PUT
        else if (std.mem.eql(u8, method, "DELETE"))
            std.http.Method.DELETE
        else
            return error.InvalidMethod;

        var req = try self.client.request(http_method, uri, .{
            .extra_headers = headers.items,
        });
        defer req.deinit();

        if (body) |b| {
try req.sendBodyComplete(@constCast(b));
        } else {
try req.sendBodyComplete("");
        }

        var redirect_buffer: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        var transfer_buffer: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buffer);

        const response_body = try reader.allocRemaining(self.allocator, .limited(1024 * 1024)); // Max 1MB

        return HttpResponse{
            .status_code = @intFromEnum(response.head.status),
            .body = response_body,
        };
    }
};

/// Feed sort options
pub const FeedSort = enum {
    hot,
    new,
    top,

    pub fn toString(self: FeedSort) []const u8 {
        return switch (self) {
            .hot => "hot",
            .new => "new",
            .top => "top",
        };
    }
};

/// Comment sort options
pub const CommentSort = enum {
    new,
    top,

    pub fn toString(self: CommentSort) []const u8 {
        return switch (self) {
            .new => "new",
            .top => "top",
        };
    }
};

/// HTTP response
const HttpResponse = struct {
    status_code: u16,
    body: []const u8,

    pub fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FeedSort toString" {
    try std.testing.expectEqualStrings("hot", FeedSort.hot.toString());
    try std.testing.expectEqualStrings("new", FeedSort.new.toString());
    try std.testing.expectEqualStrings("top", FeedSort.top.toString());
}

test "CommentSort toString" {
    try std.testing.expectEqualStrings("new", CommentSort.new.toString());
    try std.testing.expectEqualStrings("top", CommentSort.top.toString());
}

test "MoltbookClient init and deinit" {
    const allocator = std.testing.allocator;
    const monitored_posts = [_][]const u8{ "post1", "post2" };

    var client = try MoltbookClient.init(
        allocator,
        "test-api-key",
        "test-agent-id",
        "test-agent-name",
        &monitored_posts,
    );
    defer client.deinit();

    try std.testing.expectEqual(@as(usize, 2), client.monitored_posts.items.len);
}

test "MoltbookClient addMonitoredPost" {
    const allocator = std.testing.allocator;
    var client = try MoltbookClient.init(
        allocator,
        "test-api-key",
        "test-agent-id",
        "test-agent-name",
        &[_][]const u8{},
    );
    defer client.deinit();

    try client.addMonitoredPost("post1");
    try client.addMonitoredPost("post2");

    try std.testing.expectEqual(@as(usize, 2), client.monitored_posts.items.len);
    try std.testing.expectEqualStrings("post1", client.monitored_posts.items[0]);
    try std.testing.expectEqualStrings("post2", client.monitored_posts.items[1]);
}
