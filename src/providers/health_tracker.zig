const std = @import("std");
const provider_pool = @import("provider_pool.zig");

/// Error type for model failures
pub const ModelError = enum {
    rate_limit_429,
    server_error_5xx,
    timeout,
    authentication_error,
    invalid_response,
    network_error,
    unknown,

    pub fn fromHttpStatus(status: u16) ModelError {
        return switch (status) {
            429 => .rate_limit_429,
            401, 403 => .authentication_error,
            500...599 => .server_error_5xx,
            else => .unknown,
        };
    }
};

/// Cooldown duration for different error types (in seconds)
pub const CooldownDuration = struct {
    rate_limit_429: u64 = 600, // 10 minutes
    server_error_5xx: u64 = 60, // 1 minute
    timeout: u64 = 120, // 2 minutes (exponential backoff)
    authentication_error: u64 = 300, // 5 minutes
    invalid_response: u64 = 30, // 30 seconds
    network_error: u64 = 60, // 1 minute
    unknown: u64 = 30, // 30 seconds

    pub fn getDuration(self: CooldownDuration, error_type: ModelError) u64 {
        return switch (error_type) {
            .rate_limit_429 => self.rate_limit_429,
            .server_error_5xx => self.server_error_5xx,
            .timeout => self.timeout,
            .authentication_error => self.authentication_error,
            .invalid_response => self.invalid_response,
            .network_error => self.network_error,
            .unknown => self.unknown,
        };
    }
};

/// Health status of a model
pub const HealthStatus = enum {
    healthy,
    degraded,
    unhealthy,
    cooldown,

    pub fn fromScore(score: f32) HealthStatus {
        if (score >= 0.8) return .healthy;
        if (score >= 0.5) return .degraded;
        if (score >= 0.0) return .unhealthy;
        return .cooldown;
    }
};

/// Model health statistics
pub const ModelHealth = struct {
    model_id: []const u8,
    success_count: u64 = 0,
    failure_count: u64 = 0,
    total_requests: u64 = 0,
    last_success_time: i64 = 0,
    last_failure_time: i64 = 0,
    last_error: ?ModelError = null,
    cooldown_until: i64 = 0,
    consecutive_failures: u64 = 0,
    health_score: f32 = 1.0, // 0.0 to 1.0
    average_latency_ms: f64 = 0.0,

    pub fn init(model_id: []const u8) ModelHealth {
        return .{
            .model_id = model_id,
        };
    }

    /// Calculate health score based on success rate and recent failures
    pub fn calculateHealthScore(self: *ModelHealth) void {
        if (self.total_requests == 0) {
            self.health_score = 1.0;
            return;
        }

        const success_rate = @as(f32, @floatFromInt(self.success_count)) / @as(f32, @floatFromInt(self.total_requests));

        // Penalize consecutive failures heavily
        const consecutive_penalty = @as(f32, @floatFromInt(self.consecutive_failures)) * 0.1;

        // Calculate final score
        self.health_score = success_rate - consecutive_penalty;
        if (self.health_score < 0.0) self.health_score = 0.0;
        if (self.health_score > 1.0) self.health_score = 1.0;
    }

    /// Record a successful request
    pub fn recordSuccess(self: *ModelHealth, latency_ms: f64, current_time: i64) void {
        self.success_count += 1;
        self.total_requests += 1;
        self.last_success_time = current_time;
        self.consecutive_failures = 0;
        self.last_error = null;

        // Update average latency (exponential moving average)
        if (self.average_latency_ms == 0.0) {
            self.average_latency_ms = latency_ms;
        } else {
            self.average_latency_ms = 0.9 * self.average_latency_ms + 0.1 * latency_ms;
        }

        self.calculateHealthScore();
    }

    /// Record a failed request
    pub fn recordFailure(self: *ModelHealth, error_type: ModelError, current_time: i64, cooldown_duration: CooldownDuration) void {
        self.failure_count += 1;
        self.total_requests += 1;
        self.last_failure_time = current_time;
        self.last_error = error_type;
        self.consecutive_failures += 1;

        // Set cooldown based on error type
        const duration = cooldown_duration.getDuration(error_type);
        self.cooldown_until = current_time + @as(i64, duration);

        self.calculateHealthScore();
    }

    /// Check if model is in cooldown
    pub fn isInCooldown(self: *ModelHealth, current_time: i64) bool {
        return current_time < self.cooldown_until;
    }

    /// Get remaining cooldown time in seconds
    pub fn getRemainingCooldown(self: *ModelHealth, current_time: i64) i64 {
        const remaining = self.cooldown_until - current_time;
        return if (remaining > 0) remaining else 0;
    }

    /// Get health status
    pub fn getHealthStatus(self: *ModelHealth) HealthStatus {
        return HealthStatus.fromScore(self.health_score);
    }
};

/// Health tracker for monitoring model health
pub const HealthTracker = struct {
    allocator: std.mem.Allocator,
    health_map: std.StringHashMap(ModelHealth),
    cooldown_duration: CooldownDuration,

    pub fn init(allocator: std.mem.Allocator) HealthTracker {
        return .{
            .allocator = allocator,
            .health_map = std.StringHashMap(ModelHealth).init(allocator),
            .cooldown_duration = .{},
        };
    }

    /// Get or create health entry for a model
    pub fn getOrCreateHealth(self: *HealthTracker, model_id: []const u8) !*ModelHealth {
        const entry = try self.health_map.getOrPut(model_id);
        if (!entry.found_existing) {
            const model_id_copy = try self.allocator.dupe(u8, model_id);
            entry.value_ptr.* = ModelHealth.init(model_id_copy);
        }
        return entry.value_ptr;
    }

    /// Record a successful request
    pub fn recordSuccess(self: *HealthTracker, model_id: []const u8, latency_ms: f64) !void {
        const current_time = std.time.timestamp();
        const health = try self.getOrCreateHealth(model_id);
        health.recordSuccess(latency_ms, current_time);
    }

    /// Record a failed request
    pub fn recordFailure(self: *HealthTracker, model_id: []const u8, error_type: ModelError) !void {
        const current_time = std.time.timestamp();
        const health = try self.getOrCreateHealth(model_id);
        health.recordFailure(error_type, current_time, self.cooldown_duration);
    }

    /// Check if model is healthy and available
    pub fn isModelAvailable(self: *HealthTracker, model_id: []const u8) bool {
        const health = self.health_map.get(model_id) orelse return true; // No history = available
        const current_time = std.time.timestamp();

        // Check cooldown
        if (health.isInCooldown(current_time)) {
            return false;
        }

        // Check health status
        const status = health.getHealthStatus();
        return status != .unhealthy and status != .cooldown;
    }

    /// Get health for a model
    pub fn getHealth(self: *HealthTracker, model_id: []const u8) ?*ModelHealth {
        return self.health_map.get(model_id);
    }

    /// Get all available models (not in cooldown and healthy)
    pub fn getAvailableModels(self: *HealthTracker, models: []const *provider_pool.ModelMetadata) ![]*provider_pool.ModelMetadata {
        var available = std.ArrayList(*provider_pool.ModelMetadata).initCapacity(self.allocator, 0) catch unreachable;

        for (models) |model| {
            if (self.isModelAvailable(model.id)) {
                try available.append(self.allocator, model);
            }
        }

        return available.toOwnedSlice(self.allocator);
    }

    /// Get models sorted by health score (best first)
    pub fn getModelsByHealth(self: *HealthTracker, models: []const *provider_pool.ModelMetadata) ![]*provider_pool.ModelMetadata {
        const sorted = try self.allocator.alloc(*provider_pool.ModelMetadata, models.len);
        for (models, 0..) |model, i| {
            sorted[i] = model;
        }

        // Sort by health score (descending)
        std.sort.insertion(*provider_pool.ModelMetadata, sorted, self, struct {
            fn lessThan(ctx: *HealthTracker, a: *provider_pool.ModelMetadata, b: *provider_pool.ModelMetadata) bool {
                const health_a = ctx.health_map.get(a.id);
                const health_b = ctx.health_map.get(b.id);

                const score_a = if (health_a) |h| h.health_score else 1.0;
                const score_b = if (health_b) |h| h.health_score else 1.0;

                return score_a > score_b;
            }
        }.lessThan);

        return sorted;
    }

    /// Reset health for a model (useful for testing or manual intervention)
    pub fn resetHealth(self: *HealthTracker, model_id: []const u8) !void {
        if (self.health_map.getEntry(model_id)) |entry| {
            self.allocator.free(entry.value_ptr.model_id);
            _ = self.health_map.remove(model_id);
        }
    }

    /// Clear all health data
    pub fn clear(self: *HealthTracker) void {
        var iter = self.health_map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.model_id);
        }
        self.health_map.clearRetainingCapacity();
    }

    /// Deinitialize the health tracker
    pub fn deinit(self: *HealthTracker) void {
        var iter = self.health_map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.model_id);
        }
        self.health_map.deinit();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "HealthTracker initialization" {
    const allocator = std.testing.allocator;
    var tracker = HealthTracker.init(allocator);
    defer tracker.deinit();
}

test "HealthTracker recordSuccess" {
    const allocator = std.testing.allocator;
    var tracker = HealthTracker.init(allocator);
    defer tracker.deinit();

    try tracker.recordSuccess("test-model", 100.0);

    const health = tracker.getHealth("test-model");
    try std.testing.expect(health != null);
    try std.testing.expectEqual(@as(u64, 1), health.?.success_count);
    try std.testing.expectEqual(@as(u64, 1), health.?.total_requests);
    try std.testing.expectEqual(@as(f32, 1.0), health.?.health_score);
}

test "HealthTracker recordFailure" {
    const allocator = std.testing.allocator;
    var tracker = HealthTracker.init(allocator);
    defer tracker.deinit();

    try tracker.recordFailure("test-model", .rate_limit_429);

    const health = tracker.getHealth("test-model");
    try std.testing.expect(health != null);
    try std.testing.expectEqual(@as(u64, 1), health.?.failure_count);
    try std.testing.expectEqual(@as(u64, 1), health.?.total_requests);
    try std.testing.expectEqual(ModelError.rate_limit_429, health.?.last_error.?);
    try std.testing.expect(health.?.isInCooldown(std.time.timestamp()));
}

test "HealthTracker isModelAvailable" {
    const allocator = std.testing.allocator;
    var tracker = HealthTracker.init(allocator);
    defer tracker.deinit();

    // New model should be available
    try std.testing.expect(tracker.isModelAvailable("new-model"));

    // After success, should still be available
    try tracker.recordSuccess("new-model", 100.0);
    try std.testing.expect(tracker.isModelAvailable("new-model"));

    // After failure, should be in cooldown
    try tracker.recordFailure("new-model", .rate_limit_429);
    try std.testing.expect(!tracker.isModelAvailable("new-model"));
}

test "HealthTracker getAvailableModels" {
    const allocator = std.testing.allocator;
    var tracker = HealthTracker.init(allocator);
    defer tracker.deinit();

    var pool = try provider_pool.ModelPool.init(allocator);
    defer pool.deinit();

    const models = try pool.getTextModels();
    defer allocator.free(models);

    // All models should be available initially
    const available = try tracker.getAvailableModels(models);
    defer allocator.free(available);
    try std.testing.expectEqual(models.len, available.len);

    // Mark one model as failed
    try tracker.recordFailure(models[0].id, .rate_limit_429);

    // One less model should be available
    const available2 = try tracker.getAvailableModels(models);
    defer allocator.free(available2);
    try std.testing.expectEqual(models.len - 1, available2.len);
}

test "HealthTracker resetHealth" {
    const allocator = std.testing.allocator;
    var tracker = HealthTracker.init(allocator);
    defer tracker.deinit();

    try tracker.recordFailure("test-model", .rate_limit_429);
    try std.testing.expect(!tracker.isModelAvailable("test-model"));

    try tracker.resetHealth("test-model");
    try std.testing.expect(tracker.isModelAvailable("test-model"));
}

test "HealthTracker clear" {
    const allocator = std.testing.allocator;
    var tracker = HealthTracker.init(allocator);
    defer tracker.deinit();

    try tracker.recordSuccess("model1", 100.0);
    try tracker.recordFailure("model2", .rate_limit_429);

    tracker.clear();

    try std.testing.expect(tracker.getHealth("model1") == null);
    try std.testing.expect(tracker.getHealth("model2") == null);
}

test "ModelHealth calculateHealthScore" {
    var health = ModelHealth.init("test");

    // Perfect score
    health.success_count = 10;
    health.total_requests = 10;
    health.calculateHealthScore();
    try std.testing.expectEqual(@as(f32, 1.0), health.health_score);

    // 50% success rate
    health.success_count = 5;
    health.total_requests = 10;
    health.calculateHealthScore();
    try std.testing.expectEqual(@as(f32, 0.5), health.health_score);

    // With consecutive failures
    health.success_count = 8;
    health.total_requests = 10;
    health.consecutive_failures = 3;
    health.calculateHealthScore();
    try std.testing.expect(health.health_score < 0.5);
}

test "ModelError fromHttpStatus" {
    try std.testing.expectEqual(ModelError.rate_limit_429, ModelError.fromHttpStatus(429));
    try std.testing.expectEqual(ModelError.authentication_error, ModelError.fromHttpStatus(401));
    try std.testing.expectEqual(ModelError.authentication_error, ModelError.fromHttpStatus(403));
    try std.testing.expectEqual(ModelError.server_error_5xx, ModelError.fromHttpStatus(500));
    try std.testing.expectEqual(ModelError.server_error_5xx, ModelError.fromHttpStatus(503));
    try std.testing.expectEqual(ModelError.unknown, ModelError.fromHttpStatus(404));
}

test "CooldownDuration getDuration" {
    const cooldown = CooldownDuration{};

    try std.testing.expectEqual(@as(u64, 600), cooldown.getDuration(.rate_limit_429));
    try std.testing.expectEqual(@as(u64, 60), cooldown.getDuration(.server_error_5xx));
    try std.testing.expectEqual(@as(u64, 120), cooldown.getDuration(.timeout));
    try std.testing.expectEqual(@as(u64, 300), cooldown.getDuration(.authentication_error));
}

test "HealthStatus fromScore" {
    try std.testing.expectEqual(HealthStatus.healthy, HealthStatus.fromScore(0.9));
    try std.testing.expectEqual(HealthStatus.healthy, HealthStatus.fromScore(0.8));
    try std.testing.expectEqual(HealthStatus.degraded, HealthStatus.fromScore(0.7));
    try std.testing.expectEqual(HealthStatus.degraded, HealthStatus.fromScore(0.5));
    try std.testing.expectEqual(HealthStatus.unhealthy, HealthStatus.fromScore(0.3));
    try std.testing.expectEqual(HealthStatus.unhealthy, HealthStatus.fromScore(0.0));
    try std.testing.expectEqual(HealthStatus.cooldown, HealthStatus.fromScore(-0.1));
}
