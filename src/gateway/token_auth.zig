//! Token Authentication Module
//! Provides token-based authentication with rate limiting and rotation support

const std = @import("std");

pub const TokenAuth = struct {
    allocator: std.mem.Allocator,
    tokens: std.StringHashMap(TokenInfo),
    rate_limits: std.StringHashMap(RateLimitInfo),
    main_token: []const u8,
    workspace_token: []const u8,

    const TokenInfo = struct {
        token: []const u8,
        created_at: i64,
        expires_at: ?i64,
        is_active: bool,
    };

    const RateLimitInfo = struct {
        request_count: u32,
        window_start: i64,
        max_requests: u32 = 100, // 100 requests per minute
        window_duration: i64 = 60, // 60 seconds
    };

    pub fn init(allocator: std.mem.Allocator, main_token: []const u8, workspace_token: []const u8) !TokenAuth {
        var auth = TokenAuth{
            .allocator = allocator,
            .tokens = std.StringHashMap(TokenInfo).init(allocator),
            .rate_limits = std.StringHashMap(RateLimitInfo).init(allocator),
            .main_token = try allocator.dupe(u8, main_token),
            .workspace_token = try allocator.dupe(u8, workspace_token),
        };

        // Register main token
        const now = std.time.timestamp();
        try auth.tokens.put(try allocator.dupe(u8, main_token), .{
            .token = try allocator.dupe(u8, main_token),
            .created_at = now,
            .expires_at = null,
            .is_active = true,
        });

        // Register workspace token
        try auth.tokens.put(try allocator.dupe(u8, workspace_token), .{
            .token = try allocator.dupe(u8, workspace_token),
            .created_at = now,
            .expires_at = null,
            .is_active = true,
        });

        return auth;
    }

    pub fn deinit(self: *TokenAuth) void {
        var token_iter = self.tokens.iterator();
        while (token_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.token);
        }
        self.tokens.deinit();

        var rate_iter = self.rate_limits.iterator();
        while (rate_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.rate_limits.deinit();

        self.allocator.free(self.main_token);
        self.allocator.free(self.workspace_token);
    }

    /// Validate a token and check rate limits
    pub fn validate(self: *TokenAuth, token: []const u8) !bool {
        // Check if token exists and is active
        const token_info = self.tokens.get(token) orelse return false;
        if (!token_info.is_active) return false;

        // Check expiration
        if (token_info.expires_at) |expires| {
            const now = std.time.timestamp();
            if (now >= expires) return false;
        }

        // Check rate limit
        try self.checkRateLimit(token);

        return true;
    }

    /// Check and update rate limit for a token
    fn checkRateLimit(self: *TokenAuth, token: []const u8) !void {
        const now = std.time.timestamp();
        const gop = try self.rate_limits.getOrPut(token);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, token);
            gop.value_ptr.* = .{
                .request_count = 1,
                .window_start = now,
            };
            return;
        }

        var rate_info = gop.value_ptr.*;
        const elapsed = now - rate_info.window_start;

        // Reset window if expired
        if (elapsed >= rate_info.window_duration) {
            rate_info.request_count = 1;
            rate_info.window_start = now;
        } else {
            rate_info.request_count += 1;
            if (rate_info.request_count > rate_info.max_requests) {
                return error.RateLimitExceeded;
            }
        }

        gop.value_ptr.* = rate_info;
    }

    /// Rotate the main token (generate new token, invalidate old)
    pub fn rotateMainToken(self: *TokenAuth) ![]const u8 {
        const new_token = try self.generateToken();
        const now = std.time.timestamp();

        // Invalidate old main token
        if (self.tokens.get(self.main_token)) |*info| {
            info.is_active = false;
            info.expires_at = now + 300; // Expire in 5 minutes
        }

        // Register new token
        try self.tokens.put(try self.allocator.dupe(u8, new_token), .{
            .token = try self.allocator.dupe(u8, new_token),
            .created_at = now,
            .expires_at = null,
            .is_active = true,
        });

        // Update main token reference
        self.allocator.free(self.main_token);
        self.main_token = try self.allocator.dupe(u8, new_token);

        return new_token;
    }

    /// Generate a random 40-character hex token
    fn generateToken(self: *TokenAuth) ![]const u8 {
        var rng = std.rand.DefaultPrng.init(@intCast(std.time.timestamp()));
        const random = rng.random();
        var token: [40]u8 = undefined;

        for (0..40) |i| {
            const byte = random.int(u8);
            token[i] = "0123456789abcdef"[byte % 16];
        }

        return self.allocator.dupe(u8, &token);
    }

    /// Get token info (for debugging/admin)
    pub fn getTokenInfo(self: *TokenAuth, token: []const u8) ?TokenInfo {
        return self.tokens.get(token);
    }

    /// List all active tokens
    pub fn listActiveTokens(self: *TokenAuth) ![][]const u8 {
        var active_tokens = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;
        errdefer {
            for (active_tokens.items) |t| self.allocator.free(t);
            active_tokens.deinit();
        }

        var iter = self.tokens.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.is_active) {
                try active_tokens.append(try self.allocator.dupe(u8, entry.key_ptr.*));
            }
        }

        return active_tokens.toOwnedSlice(self.allocator);
    }
};

test "token auth basic validation" {
    const allocator = std.testing.allocator;
    const main_token = "317ef50c19fa20b485b377785d3ccb8d6af318dd1534b2a4";
    const workspace_token = "df95d386c47ca68bf705ce7d22432752df25c3ad24eefb49";

    var auth = try TokenAuth.init(allocator, main_token, workspace_token);
    defer auth.deinit();

    // Test valid token
    try std.testing.expect(try auth.validate(main_token));

    // Test invalid token
    try std.testing.expectError(error.RateLimitExceeded, auth.validate("invalid_token"));
}

test "token rotation" {
    const allocator = std.testing.allocator;
    const main_token = "317ef50c19fa20b485b377785d3ccb8d6af318dd1534b2a4";
    const workspace_token = "df95d386c47ca68bf705ce7d22432752df25c3ad24eefb49";

    var auth = try TokenAuth.init(allocator, main_token, workspace_token);
    defer auth.deinit();

    const old_token = auth.main_token;
    const new_token = try auth.rotateMainToken();

    // Old token should be invalidated
    try std.testing.expect(!try auth.validate(old_token));

    // New token should be valid
    try std.testing.expect(try auth.validate(new_token));

    allocator.free(new_token);
}
