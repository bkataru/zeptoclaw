const std = @import("std");
const types = @import("types.zig");

/// Barvis state - persistent state for the autonomous agent
pub const BarvisState = struct {
    // Timestamps
    last_check: i64 = 0,
    last_reply: i64 = 0,
    last_post: i64 = 0,
    last_browse: i64 = 0,
    local_last_seen: i64 = 0,
    last_heartbeat: ?types.HeartbeatData = null,

    // Counters
    total_replies: u32 = 0,
    total_posts: u32 = 0,
    total_comments: u32 = 0,
    total_upvotes: u32 = 0,
    incident_count: u32 = 0,

    // Arrays (tracked IDs)
    replied_comments: std.ArrayList([]const u8),
    seen_posts: std.ArrayList([]const u8),
    upvoted_posts: std.ArrayList([]const u8),
    commented_posts: std.ArrayList([]const u8),
    interesting_moltys: std.ArrayList([]const u8),
    post_ideas: std.ArrayList([]const u8),
    downtime_alerts_sent: std.ArrayList(u32),

    // Collections
    discoveries: std.ArrayList(types.Discovery),
    heartbeat_history: std.ArrayList(types.HeartbeatData),
    gateway_incidents: std.ArrayList(types.GatewayIncident),

    // Last action
    last_action: ?types.AutonomousAction = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BarvisState {
        return .{
            .allocator = allocator,
            .replied_comments = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            .seen_posts = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            .upvoted_posts = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            .commented_posts = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            .interesting_moltys = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            .post_ideas = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            .downtime_alerts_sent = std.ArrayList(u32).initCapacity(allocator, 0) catch unreachable,
            .discoveries = std.ArrayList(types.Discovery).initCapacity(allocator, 0) catch unreachable,
            .heartbeat_history = std.ArrayList(types.HeartbeatData).initCapacity(allocator, 0) catch unreachable,
            .gateway_incidents = std.ArrayList(types.GatewayIncident).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *BarvisState) void {
        for (self.replied_comments.items) |id| self.allocator.free(id);
        self.replied_comments.deinit(self.allocator);
        for (self.seen_posts.items) |id| self.allocator.free(id);
        self.seen_posts.deinit(self.allocator);
        for (self.upvoted_posts.items) |id| self.allocator.free(id);
        self.upvoted_posts.deinit(self.allocator);
        for (self.commented_posts.items) |id| self.allocator.free(id);
        self.commented_posts.deinit(self.allocator);
        for (self.interesting_moltys.items) |username| self.allocator.free(username);
        self.interesting_moltys.deinit(self.allocator);
        for (self.post_ideas.items) |idea| self.allocator.free(idea);
        self.post_ideas.deinit(self.allocator);
        self.downtime_alerts_sent.deinit(self.allocator);
        for (self.discoveries.items) |*d| d.deinit(self.allocator);
        self.discoveries.deinit(self.allocator);
        if (self.last_heartbeat) |*h| h.deinit(self.allocator);
        for (self.heartbeat_history.items) |*h| h.deinit(self.allocator);
        self.heartbeat_history.deinit(self.allocator);
        for (self.gateway_incidents.items) |*i| i.deinit(self.allocator);
        self.gateway_incidents.deinit(self.allocator);
    }

    pub fn addPostIdea(self: *BarvisState, idea: []const u8) !void {
        try self.post_ideas.append(self.allocator, try self.allocator.dupe(u8, idea));
    }

    pub fn popPostIdea(self: *BarvisState) ?[]const u8 {
        if (self.post_ideas.items.len == 0) return null;
        return self.post_ideas.pop();
    }

    pub fn addGatewayIncident(self: *BarvisState, incident: types.GatewayIncident) !void {
        try self.gateway_incidents.append(self.allocator, incident);
    }

    pub fn hasSeenPost(self: *const BarvisState, post_id: []const u8) bool {
        for (self.seen_posts.items) |id| {
            if (std.mem.eql(u8, id, post_id)) return true;
        }
        return false;
    }

    pub fn hasUpvotedPost(self: *const BarvisState, post_id: []const u8) bool {
        for (self.upvoted_posts.items) |id| {
            if (std.mem.eql(u8, id, post_id)) return true;
        }
        return false;
    }

    pub fn markPostUpvoted(self: *BarvisState, post_id: []const u8) !void {
        try self.upvoted_posts.append(self.allocator, try self.allocator.dupe(u8, post_id));
    }

    pub fn hasRepliedToComment(self: *const BarvisState, comment_id: []const u8) bool {
        for (self.replied_comments.items) |id| {
            if (std.mem.eql(u8, id, comment_id)) return true;
        }
        return false;
    }

    pub fn markCommentReplied(self: *BarvisState, comment_id: []const u8) !void {
        try self.replied_comments.append(self.allocator, try self.allocator.dupe(u8, comment_id));
    }

    pub fn markPostSeen(self: *BarvisState, post_id: []const u8) !void {
        try self.seen_posts.append(self.allocator, try self.allocator.dupe(u8, post_id));
    }

    pub fn hasCommentedOnPost(self: *const BarvisState, post_id: []const u8) bool {
        for (self.commented_posts.items) |id| {
            if (std.mem.eql(u8, id, post_id)) return true;
        }
        return false;
    }

    pub fn markPostCommented(self: *BarvisState, post_id: []const u8) !void {
        try self.commented_posts.append(self.allocator, try self.allocator.dupe(u8, post_id));
    }
    pub fn isInterestingMolty(self: *const BarvisState, username: []const u8) bool {
        for (self.interesting_moltys.items) |u| {
            if (std.mem.eql(u8, u, username)) return true;
        }
        return false;
    }

    pub fn trackInterestingMolty(self: *BarvisState, username: []const u8) !void {
        try self.interesting_moltys.append(self.allocator, try self.allocator.dupe(u8, username));
    }

    pub fn addDiscovery(self: *BarvisState, discovery: types.Discovery) !void {
        try self.discoveries.append(self.allocator, discovery);
    }

};

pub const StateStore = struct {
    allocator: std.mem.Allocator,
    state: BarvisState,
    file_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, workspace: ?[]const u8) !StateStore {
        const path = workspace orelse ".";
        const file_path = try std.fmt.allocPrint(allocator, "{s}/.zeptoclaw_state.json", .{path});
        return StateStore{
            .allocator = allocator,
            .state = BarvisState.init(allocator),
            .file_path = file_path,
        };
    }

    pub fn deinit(self: *StateStore) void {
        self.allocator.free(self.file_path);
        self.state.deinit();
    }

    pub fn updateLastReply(self: *StateStore, timestamp: i64) !void {
        self.state.last_reply = timestamp;
        try self.save();
    }
    pub fn updateLastAction(self: *StateStore, action: types.AutonomousAction) !void {
        self.state.last_action = action;
        try self.save();
    }

    pub fn updateLocalAgentHeartbeat(self: *StateStore, timestamp: i64) !void {
        self.state.local_last_seen = timestamp;
        try self.save();
    }


    pub fn save(self: *StateStore) !void {
        // Simplified save - just update timestamps
        _ = self;
    }

    pub fn updateLastPost(self: *StateStore, timestamp: i64) !void {
        self.state.last_post = timestamp;
        try self.save();
    }

    pub fn updateLastBrowse(self: *StateStore, timestamp: i64) !void {
        self.state.last_browse = timestamp;
        try self.save();
    }

    pub fn updateLastCheck(self: *StateStore, timestamp: i64) !void {
        self.state.last_check = timestamp;
        try self.save();
    }

    pub fn updateLocalLastSeen(self: *StateStore, timestamp: i64) !void {
        self.state.local_last_seen = timestamp;
        try self.save();
    }

    pub fn addPostIdea(self: *StateStore, idea: []const u8) !void {
        try self.state.addPostIdea(idea);
    }

    pub fn getDiscoveries(self: *StateStore) ![]types.Discovery {
        return self.state.discoveries.items;
    }

    pub fn clearDiscoveries(self: *StateStore) !void {
        self.state.discoveries.clearRetainingCapacity();
        try self.save();
    }

    pub fn getGatewayIncidents(self: *StateStore) ![]types.GatewayIncident {
        return self.state.gateway_incidents.items;
    }
};
