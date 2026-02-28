//! Session Store Module
//! Manages active sessions with persistence to disk

const std = @import("std");

pub const SessionStore = struct {
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(Session),
    sessions_dir: []const u8,
    sessions_file: []const u8,

    pub const Session = struct {
        id: []const u8,
        created_at: i64,
        last_activity: i64,
        user: []const u8,
        channel: []const u8,
        message_count: u32,
        status: SessionStatus,
        metadata: std.StringHashMap([]const u8),

        pub const SessionStatus = enum {
            active,
            idle,
            terminated,
        };
    };

    pub fn init(allocator: std.mem.Allocator, sessions_dir: []const u8) !SessionStore {
        // Ensure sessions directory exists
        _ = try std.fs.cwd().makeOpenPath(sessions_dir, .{});
        const sessions_file = try std.fmt.allocPrint(allocator, "{s}/sessions.json", .{sessions_dir});

        var store = SessionStore{
            .allocator = allocator,
            .sessions = std.StringHashMap(Session).init(allocator),
            .sessions_dir = try allocator.dupe(u8, sessions_dir),
            .sessions_file = sessions_file,
        };

        // Load existing sessions from disk
        try store.load();

        return store;
    }

    pub fn deinit(self: *SessionStore) void {
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.deinitSession(entry.value_ptr);
        }
        self.sessions.deinit();
        self.allocator.free(self.sessions_dir);
        self.allocator.free(self.sessions_file);
    }

    fn deinitSession(self: *SessionStore, session: *Session) void {
        self.allocator.free(session.id);
        self.allocator.free(session.user);
        self.allocator.free(session.channel);

        var meta_iter = session.metadata.iterator();
        while (meta_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        session.metadata.deinit();
    }

    /// Create a new session
    pub fn createSession(self: *SessionStore, id: []const u8, user: []const u8, channel: []const u8) !void {
        const now = std.time.timestamp();

        var metadata = std.StringHashMap([]const u8).init(self.allocator);
        try metadata.put("created_by", try self.allocator.dupe(u8, "gateway"));

        const session = Session{
            .id = try self.allocator.dupe(u8, id),
            .created_at = now,
            .last_activity = now,
            .user = try self.allocator.dupe(u8, user),
            .channel = try self.allocator.dupe(u8, channel),
            .message_count = 0,
            .status = .active,
            .metadata = metadata,
        };

        try self.sessions.put(try self.allocator.dupe(u8, id), session);
        try self.save();
    }

    /// Get a session by ID
    pub fn getSession(self: *SessionStore, id: []const u8) ?*Session {
        return self.sessions.getPtr(id);
    }

    /// Update session activity
    pub fn updateActivity(self: *SessionStore, id: []const u8, message_count_delta: u32) !void {
        if (self.sessions.getPtr(id)) |session| {
            session.last_activity = std.time.timestamp();
            session.message_count += message_count_delta;
            session.status = .active;
            try self.save();
        }
    }

    /// Terminate a session
    pub fn terminateSession(self: *SessionStore, id: []const u8) !bool {
        if (self.sessions.getPtr(id)) |session| {
            session.status = .terminated;
            session.last_activity = std.time.timestamp();
            try self.save();
            return true;
        }
        return false;
    }

    /// List all active sessions
    pub fn listActiveSessions(self: *SessionStore) ![]Session {
        var active = try std.ArrayList(Session).initCapacity(self.allocator, 0);
        errdefer active.deinit(self.allocator);

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.status == .active) {
                // Create a shallow copy for the list
                try active.append(self.allocator, entry.value_ptr.*);
            }
        }

        return try active.toOwnedSlice(self.allocator);
    }

    /// List all sessions (including terminated)
    pub fn listAllSessions(self: *SessionStore) ![]Session {
        var all = try std.ArrayList(Session).initCapacity(self.allocator, 0);
        errdefer all.deinit(self.allocator);

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            try all.append(self.allocator, entry.value_ptr.*);
        }

        return try all.toOwnedSlice(self.allocator);
    }

    /// Save sessions to disk
    fn save(self: *SessionStore) !void {
        const file = try std.fs.cwd().createFile(self.sessions_file, .{ .truncate = true });
        defer file.close();

const writer = file.deprecatedWriter();

        try writer.writeAll("{\n \"sessions\": [\n");

        var first = true;
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            if (!first) {
                try writer.writeAll(",\n");
            }
            first = false;

            const session = entry.value_ptr.*;
            try writer.print("    {{\n", .{});
            try writer.print("      \"id\": \"{s}\",\n", .{session.id});
            try writer.print("      \"created_at\": {d},\n", .{session.created_at});
            try writer.print("      \"last_activity\": {d},\n", .{session.last_activity});
            try writer.print("      \"user\": \"{s}\",\n", .{session.user});
            try writer.print("      \"channel\": \"{s}\",\n", .{session.channel});
            try writer.print("      \"message_count\": {d},\n", .{session.message_count});
            try writer.print("      \"status\": \"{s}\"\n", .{@tagName(session.status)});
            try writer.writeAll(" }");
        }

        try writer.writeAll("\n ]\n}\n");
    }

    /// Load sessions from disk
    fn load(self: *SessionStore) !void {
        const file = std.fs.cwd().openFile(self.sessions_file, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // No existing sessions file, that's fine
                return;
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // Max 1MB
        defer self.allocator.free(content);

        // Parse JSON (simplified - in production, use proper JSON parser)
        // For now, we'll just create a placeholder session if file exists
        // TODO: Implement proper JSON parsing
    }

    /// Clean up old terminated sessions (older than 24 hours)
    pub fn cleanupOldSessions(self: *SessionStore) !usize {
        const now = std.time.timestamp();
        const cutoff = now - (24 * 60 * 60); // 24 hours ago

        var to_remove = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer {
            for (to_remove.items) |id| self.allocator.free(id);
            to_remove.deinit(self.allocator);
        }

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            const session = entry.value_ptr.*;
            if (session.status == .terminated and session.last_activity < cutoff) {
                try to_remove.append(self.allocator, try self.allocator.dupe(u8, session.id));
            }
        }

        for (to_remove.items) |id| {
            if (self.sessions.fetchRemove(id)) |entry| {
                self.allocator.free(entry.key);
                self.deinitSession(&entry.value);
            }
        }

        if (to_remove.items.len > 0) {
            try self.save();
        }

        return to_remove.items.len;
    }

    /// Get session statistics
    pub fn getStats(self: *SessionStore) !SessionStats {
        var stats = SessionStats{
            .total_sessions = 0,
            .active_sessions = 0,
            .idle_sessions = 0,
            .terminated_sessions = 0,
            .total_messages = 0,
        };

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            const session = entry.value_ptr.*;
            stats.total_sessions += 1;
            stats.total_messages += session.message_count;

            switch (session.status) {
                .active => stats.active_sessions += 1,
                .idle => stats.idle_sessions += 1,
                .terminated => stats.terminated_sessions += 1,
            }
        }

        return stats;
    }

    pub const SessionStats = struct {
        total_sessions: usize,
        active_sessions: usize,
        idle_sessions: usize,
        terminated_sessions: usize,
        total_messages: u32,
    };
};

test "session store basic operations" {
    const allocator = std.testing.allocator;
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var store = try SessionStore.init(allocator, tmp_dir.path);
    defer store.deinit();

    // Create a session
    try store.createSession("test-session-1", "user1", "cli");

    // Get the session
    const session = store.getSession("test-session-1");
    try std.testing.expect(session != null);
    try std.testing.expectEqualStrings("test-session-1", session.?.id);
    try std.testing.expectEqual(@as(u32, 0), session.?.message_count);

    // Update activity
    try store.updateActivity("test-session-1", 5);
    try std.testing.expectEqual(@as(u32, 5), store.getSession("test-session-1").?.message_count);

    // Terminate session
    const terminated = try store.terminateSession("test-session-1");
    try std.testing.expect(terminated);
    try std.testing.expectEqual(SessionStore.Session.SessionStatus.terminated, store.getSession("test-session-1").?.status);
}

test "session store list sessions" {
    const allocator = std.testing.allocator;
    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var store = try SessionStore.init(allocator, tmp_dir.path);
    defer store.deinit();

    try store.createSession("session-1", "user1", "cli");
    try store.createSession("session-2", "user2", "cli");
    try store.createSession("session-3", "user1", "api");

    const active = try store.listActiveSessions();
    defer allocator.free(active);
    try std.testing.expectEqual(@as(usize, 3), active.len);

    try store.terminateSession("session-2");

    const active_after = try store.listActiveSessions();
    defer allocator.free(active_after);
    try std.testing.expectEqual(@as(usize, 2), active_after.len);
}
