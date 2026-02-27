const std = @import("std");
const provider_pool = @import("provider_pool.zig");
const health_tracker = @import("health_tracker.zig");

/// Selection strategy for model selection
pub const SelectionStrategy = enum {
    priority_only, // Only use priority, ignore health
    health_aware, // Consider both priority and health
    health_first, // Prioritize health over priority
    round_robin, // Rotate through available models
    random, // Random selection from available models
};

/// Fallback router for intelligent model selection
pub const FallbackRouter = struct {
    allocator: std.mem.Allocator,
    pool: *provider_pool.ModelPool,
    health_tracker: *health_tracker.HealthTracker,
    strategy: SelectionStrategy,
    round_robin_index: usize = 0,
    primary_model: []const u8,
    fallback_models: [][]const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        pool: *provider_pool.ModelPool,
        health_tracker: *health_tracker.HealthTracker,
        primary_model: []const u8,
        fallback_models: [][]const u8,
    ) !FallbackRouter {
        // Validate that primary model exists
        if (pool.getModel(primary_model) == null) {
            std.log.warn("Primary model '{s}' not found in pool, using default", .{primary_model});
        }

        // Validate fallback models
        for (fallback_models) |model_id| {
            if (pool.getModel(model_id) == null) {
                std.log.warn("Fallback model '{s}' not found in pool", .{model_id});
            }
        }

        return .{
            .allocator = allocator,
            .pool = pool,
            .health_tracker = health_tracker,
            .strategy = .health_aware,
            .primary_model = try allocator.dupe(u8, primary_model),
            .fallback_models = try allocator.dupe([]const u8, fallback_models),
        };
    }

    /// Select the best model for a request
    pub fn selectModel(self: *FallbackRouter) !*provider_pool.ModelMetadata {
        const models = try self.pool.getTextModels();
        defer self.allocator.free(models);

        return switch (self.strategy) {
            .priority_only => self.selectByPriority(models),
            .health_aware => self.selectHealthAware(models),
            .health_first => self.selectHealthFirst(models),
            .round_robin => self.selectRoundRobin(models),
            .random => self.selectRandom(models),
        };
    }

    /// Select model by priority only (ignore health)
    fn selectByPriority(self: *FallbackRouter, models: []const *provider_pool.ModelMetadata) !*provider_pool.ModelMetadata {
        // Try primary model first
        if (self.pool.getModel(self.primary_model)) |model| {
            return model;
        }

        // Try fallback models in order
        for (self.fallback_models) |model_id| {
            if (self.pool.getModel(model_id)) |model| {
                return model;
            }
        }

        // Fall back to any available model by priority
        const sorted = try self.pool.getModelsByPriority();
        defer self.allocator.free(sorted);

        for (sorted) |model| {
            if (!model.supports_vision) {
                return model;
            }
        }

        return error.NoAvailableModels;
    }

    /// Select model considering both priority and health
    fn selectHealthAware(self: *FallbackRouter, models: []const *provider_pool.ModelMetadata) !*provider_pool.ModelMetadata {
        // Get available models (not in cooldown and healthy)
        const available = try self.health_tracker.getAvailableModels(models);
        defer self.allocator.free(available);

        if (available.len == 0) {
            return error.NoAvailableModels;
        }

        // Try primary model first if available
        for (available) |model| {
            if (std.mem.eql(u8, model.id, self.primary_model)) {
                return model;
            }
        }

        // Try fallback models in order if available
        for (self.fallback_models) |model_id| {
            for (available) |model| {
                if (std.mem.eql(u8, model.id, model_id)) {
                    return model;
                }
            }
        }

        // Select best available model by priority
        var best_model: ?*provider_pool.ModelMetadata = null;
        var best_priority: u8 = 255;

        for (available) |model| {
            const priority = @intFromEnum(model.priority);
            if (priority < best_priority) {
                best_priority = priority;
                best_model = model;
            }
        }

        return best_model orelse error.NoAvailableModels;
    }

    /// Select model prioritizing health over priority
    fn selectHealthFirst(self: *FallbackRouter, models: []const *provider_pool.ModelMetadata) !*provider_pool.ModelMetadata {
        // Get models sorted by health score
        const sorted = try self.health_tracker.getModelsByHealth(models);
        defer self.allocator.free(sorted);

        // Find the first healthy model
        for (sorted) |model| {
            if (self.health_tracker.isModelAvailable(model.id)) {
                return model;
            }
        }

        return error.NoAvailableModels;
    }

    /// Select model using round-robin
    fn selectRoundRobin(self: *FallbackRouter, models: []const *provider_pool.ModelMetadata) !*provider_pool.ModelMetadata {
        const available = try self.health_tracker.getAvailableModels(models);
        defer self.allocator.free(available);

        if (available.len == 0) {
            return error.NoAvailableModels;
        }

        // Select current index and increment
        const model = available[self.round_robin_index % available.len];
        self.round_robin_index += 1;

        return model;
    }

    /// Select model randomly from available models
    fn selectRandom(self: *FallbackRouter, models: []const *provider_pool.ModelMetadata) !*provider_pool.ModelMetadata {
        const available = try self.health_tracker.getAvailableModels(models);
        defer self.allocator.free(available);

        if (available.len == 0) {
            return error.NoAvailableModels;
        }

        // Generate random index
        const random_value = std.crypto.random.intRangeLessThan(usize, available.len);
        return available[random_value];
    }

    /// Record a successful request
    pub fn recordSuccess(self: *FallbackRouter, model_id: []const u8, latency_ms: f64) !void {
        try self.health_tracker.recordSuccess(model_id, latency_ms);
    }

    /// Record a failed request
    pub fn recordFailure(self: *FallbackRouter, model_id: []const u8, error_type: health_tracker.ModelError) !void {
        try self.health_tracker.recordFailure(model_id, error_type);
    }

    /// Set selection strategy
    pub fn setStrategy(self: *FallbackRouter, strategy: SelectionStrategy) void {
        self.strategy = strategy;
    }

    /// Get current selection strategy
    pub fn getStrategy(self: *FallbackRouter) SelectionStrategy {
        return self.strategy;
    }

    /// Get statistics about the router
    pub fn getStats(self: *FallbackRouter) !RouterStats {
        const models = try self.pool.getTextModels();
        defer self.allocator.free(models);

        var total_requests: u64 = 0;
        var total_successes: u64 = 0;
        var total_failures: u64 = 0;
        var available_count: usize = 0;
        var cooldown_count: usize = 0;

        for (models) |model| {
            if (self.health_tracker.getHealth(model.id)) |health| {
                total_requests += health.total_requests;
                total_successes += health.success_count;
                total_failures += health.failure_count;

                if (self.health_tracker.isModelAvailable(model.id)) {
                    available_count += 1;
                } else {
                    cooldown_count += 1;
                }
            } else {
                available_count += 1; // No history = available
            }
        }

        return .{
            .total_models = models.len,
            .available_models = available_count,
            .cooldown_models = cooldown_count,
            .total_requests = total_requests,
            .total_successes = total_successes,
            .total_failures = total_failures,
            .success_rate = if (total_requests > 0)
                @as(f32, @floatFromInt(total_successes)) / @as(f32, @floatFromInt(total_requests))
            else
                0.0,
        };
    }

    /// Reset router state
    pub fn reset(self: *FallbackRouter) void {
        self.round_robin_index = 0;
        self.health_tracker.clear();
    }

    /// Deinitialize the router
    pub fn deinit(self: *FallbackRouter) void {
        self.allocator.free(self.primary_model);
        for (self.fallback_models) |model| {
            self.allocator.free(model);
        }
        self.allocator.free(self.fallback_models);
    }
};

/// Router statistics
pub const RouterStats = struct {
    total_models: usize,
    available_models: usize,
    cooldown_models: usize,
    total_requests: u64,
    total_successes: u64,
    total_failures: u64,
    success_rate: f32,
};

// ============================================================================
// Tests
// ============================================================================

test "FallbackRouter initialization" {
    const allocator = std.testing.allocator;
    var pool = try provider_pool.ModelPool.init(allocator);
    defer pool.deinit();

    var tracker = health_tracker.HealthTracker.init(allocator);
    defer tracker.deinit();

    const primary = "nvidia-nim/qwen/qwen3.5-397b-a17b";
    const fallbacks = [_][]const u8{
        "nvidia-nim/z-ai/glm4.7",
        "nvidia-nim/minimaxai/minimax-m2.1",
    };

    var router = try FallbackRouter.init(allocator, &pool, &tracker, primary, &fallbacks);
    defer router.deinit();

    try std.testing.expectEqual(SelectionStrategy.health_aware, router.getStrategy());
}

test "FallbackRouter selectModel priority_only" {
    const allocator = std.testing.allocator;
    var pool = try provider_pool.ModelPool.init(allocator);
    defer pool.deinit();

    var tracker = health_tracker.HealthTracker.init(allocator);
    defer tracker.deinit();

    const primary = "nvidia-nim/qwen/qwen3.5-397b-a17b";
    const fallbacks = [_][]const u8{
        "nvidia-nim/z-ai/glm4.7",
    };

    var router = try FallbackRouter.init(allocator, &pool, &tracker, primary, &fallbacks);
    defer router.deinit();

    router.setStrategy(.priority_only);

    const model = try router.selectModel();
    try std.testing.expectEqualStrings(primary, model.id);
}

test "FallbackRouter selectModel health_aware" {
    const allocator = std.testing.allocator;
    var pool = try provider_pool.ModelPool.init(allocator);
    defer pool.deinit();

    var tracker = health_tracker.HealthTracker.init(allocator);
    defer tracker.deinit();

    const primary = "nvidia-nim/qwen/qwen3.5-397b-a17b";
    const fallbacks = [_][]const u8{
        "nvidia-nim/z-ai/glm4.7",
    };

    var router = try FallbackRouter.init(allocator, &pool, &tracker, primary, &fallbacks);
    defer router.deinit();

    router.setStrategy(.health_aware);

    // Primary model should be selected initially
    const model1 = try router.selectModel();
    try std.testing.expectEqualStrings(primary, model1.id);

    // Mark primary as failed
    try router.recordFailure(primary, .rate_limit_429);

    // Fallback should be selected now
    const model2 = try router.selectModel();
    try std.testing.expectEqualStrings(fallbacks[0], model2.id);
}

test "FallbackRouter recordSuccess and recordFailure" {
    const allocator = std.testing.allocator;
    var pool = try provider_pool.ModelPool.init(allocator);
    defer pool.deinit();

    var tracker = health_tracker.HealthTracker.init(allocator);
    defer tracker.deinit();

    const primary = "nvidia-nim/qwen/qwen3.5-397b-a17b";
    const fallbacks = [_][]const u8{};

    var router = try FallbackRouter.init(allocator, &pool, &tracker, primary, &fallbacks);
    defer router.deinit();

    try router.recordSuccess(primary, 100.0);

    const health = tracker.getHealth(primary);
    try std.testing.expect(health != null);
    try std.testing.expectEqual(@as(u64, 1), health.?.success_count);

    try router.recordFailure(primary, .rate_limit_429);

    const health2 = tracker.getHealth(primary);
    try std.testing.expect(health2 != null);
    try std.testing.expectEqual(@as(u64, 1), health2.?.failure_count);
}

test "FallbackRouter getStats" {
    const allocator = std.testing.allocator;
    var pool = try provider_pool.ModelPool.init(allocator);
    defer pool.deinit();

    var tracker = health_tracker.HealthTracker.init(allocator);
    defer tracker.deinit();

    const primary = "nvidia-nim/qwen/qwen3.5-397b-a17b";
    const fallbacks = [_][]const u8{};

    var router = try FallbackRouter.init(allocator, &pool, &tracker, primary, &fallbacks);
    defer router.deinit();

    try router.recordSuccess(primary, 100.0);
    try router.recordSuccess(primary, 150.0);
    try router.recordFailure(primary, .rate_limit_429);

    const stats = try router.getStats();
    try std.testing.expectEqual(@as(u64, 3), stats.total_requests);
    try std.testing.expectEqual(@as(u64, 2), stats.total_successes);
    try std.testing.expectEqual(@as(u64, 1), stats.total_failures);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6667), stats.success_rate, 0.01);
}

test "FallbackRouter round_robin" {
    const allocator = std.testing.allocator;
    var pool = try provider_pool.ModelPool.init(allocator);
    defer pool.deinit();

    var tracker = health_tracker.HealthTracker.init(allocator);
    defer tracker.deinit();

    const primary = "nvidia-nim/qwen/qwen3.5-397b-a17b";
    const fallbacks = [_][]const u8{
        "nvidia-nim/z-ai/glm4.7",
        "nvidia-nim/minimaxai/minimax-m2.1",
    };

    var router = try FallbackRouter.init(allocator, &pool, &tracker, primary, &fallbacks);
    defer router.deinit();

    router.setStrategy(.round_robin);

    // Get multiple models and verify rotation
    const model1 = try router.selectModel();
    const model2 = try router.selectModel();
    const model3 = try router.selectModel();

    // Models should be different (assuming all are available)
    try std.testing.expect(!std.mem.eql(u8, model1.id, model2.id));
}

test "FallbackRouter reset" {
    const allocator = std.testing.allocator;
    var pool = try provider_pool.ModelPool.init(allocator);
    defer pool.deinit();

    var tracker = health_tracker.HealthTracker.init(allocator);
    defer tracker.deinit();

    const primary = "nvidia-nim/qwen/qwen3.5-397b-a17b";
    const fallbacks = [_][]const u8{};

    var router = try FallbackRouter.init(allocator, &pool, &tracker, primary, &fallbacks);
    defer router.deinit();

    try router.recordFailure(primary, .rate_limit_429);
    try std.testing.expect(!tracker.isModelAvailable(primary));

    router.reset();
    try std.testing.expect(tracker.isModelAvailable(primary));
    try std.testing.expectEqual(@as(usize, 0), router.round_robin_index);
}

test "FallbackRouter setStrategy and getStrategy" {
    const allocator = std.testing.allocator;
    var pool = try provider_pool.ModelPool.init(allocator);
    defer pool.deinit();

    var tracker = health_tracker.HealthTracker.init(allocator);
    defer tracker.deinit();

    const primary = "nvidia-nim/qwen/qwen3.5-397b-a17b";
    const fallbacks = [_][]const u8{};

    var router = try FallbackRouter.init(allocator, &pool, &tracker, primary, &fallbacks);
    defer router.deinit();

    router.setStrategy(.priority_only);
    try std.testing.expectEqual(SelectionStrategy.priority_only, router.getStrategy());

    router.setStrategy(.health_first);
    try std.testing.expectEqual(SelectionStrategy.health_first, router.getStrategy());

    router.setStrategy(.random);
    try std.testing.expectEqual(SelectionStrategy.random, router.getStrategy());
}
