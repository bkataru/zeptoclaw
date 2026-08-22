const std = @import("std");

/// Priority tier for model selection
pub const PriorityTier = enum(u8) {
    tier_1 = 1, // Highest priority - best models
    tier_2 = 2, // High priority - excellent models
    tier_3 = 3, // Medium priority - good models
    tier_4 = 4, // Low priority - fallback models
    tier_5 = 5, // Lowest priority - last resort

    pub fn fromInt(value: u8) PriorityTier {
        return switch (value) {
            1 => .tier_1,
            2 => .tier_2,
            3 => .tier_3,
            4 => .tier_4,
            5 => .tier_5,
            else => .tier_5,
        };
    }
};

/// API type for the model
pub const ApiType = enum {
    openai_completions,
    openai_chat,
    custom,

    pub fn toString(self: ApiType) []const u8 {
        return switch (self) {
            .openai_completions => "openai-completions",
            .openai_chat => "openai-chat",
            .custom => "custom",
        };
    }
};

/// Model metadata
/// Model metadata (owned strings).
/// Memory: Owns `id`, `name`, `provider`, `base_url`, `description`; call `deinit(allocator)` to free. Other fields are values.
pub const ModelMetadata = struct {
    id: []const u8,
    name: []const u8,
    provider: []const u8,
    base_url: []const u8,
    api_type: ApiType,
    priority: PriorityTier,
    context_window: u32,
    max_tokens: u32,
    rate_limit_rpm: u32, // Requests per minute
    rate_limit_tpm: u32, // Tokens per minute
    supports_streaming: bool,
    supports_function_calling: bool,
    supports_vision: bool,
    description: []const u8,

    /// Memory: Frees owned `id`, `name`, `provider`, `base_url`, `description`.
    pub fn deinit(self: *ModelMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.provider);
        allocator.free(self.base_url);
        allocator.free(self.description);
    }
};

/// Model pool containing all available models
/// Pool of available models (owns metadata strings and map).
/// Memory: Owns duped strings in `models` and `model_map` keys; call `deinit()` to free. Getters returning slices allocate caller-owned slices of borrowed pointers.
pub const ModelPool = struct {
    allocator: std.mem.Allocator,
    models: []ModelMetadata,
    model_map: std.StringHashMap(usize), // Maps model ID to index in models array

    /// Initialize the model pool with single model: thinkingmachines/inkling
    /// Memory: Caller owns returned ModelPool; call `deinit()` to free owned models and map. Allocates for initial models.
    pub fn init(allocator: std.mem.Allocator) !ModelPool {
        var pool = ModelPool{
            .allocator = allocator,
            .models = &.{},
            .model_map = std.StringHashMap(usize).init(allocator),
        };

        // Single model: thinkingmachines/inkling on NVIDIA NIM
        try pool.addModel(.{
            .id = "thinkingmachines/inkling",
            .name = "Inkling",
            .provider = "nvidia-nim",
            .base_url = "https://integrate.api.nvidia.com/v1",
            .api_type = .openai_chat,
            .priority = .tier_1,
            .context_window = 32768,
            .max_tokens = 8192,
            .rate_limit_rpm = 40,
            .rate_limit_tpm = 100000,
            .supports_streaming = true,
            .supports_function_calling = true,
            .supports_vision = false,
            .description = "Inkling by Thinking Machines - single fleet model",
        });

        // Image model (kept for completeness but not used as LLM fallback)
        try pool.addModel(.{
            .id = "nvidia-nim/stabilityai/stable-diffusion-3.5-large",
            .name = "Stable Diffusion 3.5 Large",
            .provider = "nvidia-nim",
            .base_url = "https://integrate.api.nvidia.com/v1",
            .api_type = .custom,
            .priority = .tier_1,
            .context_window = 77,
            .max_tokens = 77,
            .rate_limit_rpm = 40,
            .rate_limit_tpm = 100000,
            .supports_streaming = false,
            .supports_function_calling = false,
            .supports_vision = true,
            .description = "Stable Diffusion 3.5 Large - High-quality image generation",
        });

        return pool;
    }

    /// Add a model to the pool
    fn addModel(self: *ModelPool, metadata: ModelMetadata) !void {
        const index = self.models.len;
        const new_models = try self.allocator.realloc(self.models, index + 1);
        new_models[index] = .{
            .id = try self.allocator.dupe(u8, metadata.id),
            .name = try self.allocator.dupe(u8, metadata.name),
            .provider = try self.allocator.dupe(u8, metadata.provider),
            .base_url = try self.allocator.dupe(u8, metadata.base_url),
            .api_type = metadata.api_type,
            .priority = metadata.priority,
            .context_window = metadata.context_window,
            .max_tokens = metadata.max_tokens,
            .rate_limit_rpm = metadata.rate_limit_rpm,
            .rate_limit_tpm = metadata.rate_limit_tpm,
            .supports_streaming = metadata.supports_streaming,
            .supports_function_calling = metadata.supports_function_calling,
            .supports_vision = metadata.supports_vision,
            .description = try self.allocator.dupe(u8, metadata.description),
        };
        self.models = new_models;
        try self.model_map.put(metadata.id, index);
    }

    /// Get model by ID
    pub fn getModel(self: *ModelPool, model_id: []const u8) ?*ModelMetadata {
        const index = self.model_map.get(model_id) orelse return null;
        return &self.models[index];
    }

    /// Get all models sorted by priority
    /// Memory: Caller owns returned slice of borrowed `*ModelMetadata` sorted by priority; free with `allocator.free()`. Elements are borrowed from pool.
    pub fn getModelsByPriority(self: *ModelPool) ![]*ModelMetadata {
        const sorted = try self.allocator.alloc(*ModelMetadata, self.models.len);
        for (self.models, 0..) |*model, i| {
            sorted[i] = model;
        }

        // Sort by priority (lower number = higher priority)
        std.sort.insertion(*ModelMetadata, sorted, {}, struct {
            fn lessThan(_: void, a: *ModelMetadata, b: *ModelMetadata) bool {
                return @intFromEnum(a.priority) < @intFromEnum(b.priority);
            }
        }.lessThan);

        return sorted;
    }

    /// Get models by priority tier
    /// Memory: Caller owns returned slice of borrowed `*ModelMetadata` filtered by tier; free with `allocator.free()`. Elements are borrowed.
    pub fn getModelsByTier(self: *ModelPool, tier: PriorityTier) ![]*ModelMetadata {
        var count: usize = 0;
        for (self.models) |*model| {
            if (model.priority == tier) count += 1;
        }

        const result = try self.allocator.alloc(*ModelMetadata, count);
        var index: usize = 0;
        for (self.models) |*model| {
            if (model.priority == tier) {
                result[index] = model;
                index += 1;
            }
        }

        return result;
    }

    /// Get all text models (excluding image models)
    /// Memory: Caller owns returned slice of borrowed `*ModelMetadata` filtered to non-vision; free with `allocator.free()`. Elements are borrowed.
    pub fn getTextModels(self: *ModelPool) ![]*ModelMetadata {
        var count: usize = 0;
        for (self.models) |*model| {
            if (!model.supports_vision) count += 1;
        }

        const result = try self.allocator.alloc(*ModelMetadata, count);
        var index: usize = 0;
        for (self.models) |*model| {
            if (!model.supports_vision) {
                result[index] = model;
                index += 1;
            }
        }

        return result;
    }

    /// Get all image models
    /// Memory: Caller owns returned slice of borrowed `*ModelMetadata` filtered to vision; free with `allocator.free()`. Elements are borrowed.
    pub fn getImageModels(self: *ModelPool) ![]*ModelMetadata {
        var count: usize = 0;
        for (self.models) |*model| {
            if (model.supports_vision) count += 1;
        }

        const result = try self.allocator.alloc(*ModelMetadata, count);
        var index: usize = 0;
        for (self.models) |*model| {
            if (model.supports_vision) {
                result[index] = model;
                index += 1;
            }
        }

        return result;
    }

    /// Deinitialize the model pool
    /// Memory: Frees all owned `ModelMetadata` strings, `models` array, and `model_map`.
    pub fn deinit(self: *ModelPool) void {
        for (self.models) |*model| {
            model.deinit(self.allocator);
        }
        self.allocator.free(self.models);
        self.model_map.deinit();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ModelPool initialization" {
    const allocator = std.testing.allocator;
    var pool = try ModelPool.init(allocator);
    defer pool.deinit();

    // Check that we have 2 models (1 LLM + 1 image)
    try std.testing.expectEqual(@as(usize, 2), pool.models.len);

    // Check that we can find a specific model
    const model = pool.getModel("thinkingmachines/inkling");
    try std.testing.expect(model != null);
    try std.testing.expectEqualStrings("Inkling", model.?.name);
    try std.testing.expectEqual(PriorityTier.tier_1, model.?.priority);
}

test "ModelPool getModelsByPriority" {
    const allocator = std.testing.allocator;
    var pool = try ModelPool.init(allocator);
    defer pool.deinit();

    const sorted = try pool.getModelsByPriority();
    defer allocator.free(sorted);

    // Check that models are sorted by priority
    try std.testing.expectEqual(PriorityTier.tier_1, sorted[0].priority);
}

test "ModelPool getModelsByTier" {
    const allocator = std.testing.allocator;
    var pool = try ModelPool.init(allocator);
    defer pool.deinit();

    const tier1 = try pool.getModelsByTier(.tier_1);
    defer allocator.free(tier1);

    // Tier 1 should have 2 models (1 text + 1 image)
    try std.testing.expectEqual(@as(usize, 2), tier1.len);

    for (tier1) |model| {
        try std.testing.expectEqual(PriorityTier.tier_1, model.priority);
    }
}

test "ModelPool getTextModels" {
    const allocator = std.testing.allocator;
    var pool = try ModelPool.init(allocator);
    defer pool.deinit();

    const text_models = try pool.getTextModels();
    defer allocator.free(text_models);

    try std.testing.expectEqual(@as(usize, 1), text_models.len);

    for (text_models) |model| {
        try std.testing.expect(!model.supports_vision);
    }
}

test "ModelPool getImageModels" {
    const allocator = std.testing.allocator;
    var pool = try ModelPool.init(allocator);
    defer pool.deinit();

    const image_models = try pool.getImageModels();
    defer allocator.free(image_models);

    // Should have 1 image model
    try std.testing.expectEqual(@as(usize, 1), image_models.len);

    for (image_models) |model| {
        try std.testing.expect(model.supports_vision);
    }
}

test "PriorityTier fromInt" {
    try std.testing.expectEqual(PriorityTier.tier_1, PriorityTier.fromInt(1));
    try std.testing.expectEqual(PriorityTier.tier_2, PriorityTier.fromInt(2));
    try std.testing.expectEqual(PriorityTier.tier_3, PriorityTier.fromInt(3));
    try std.testing.expectEqual(PriorityTier.tier_4, PriorityTier.fromInt(4));
    try std.testing.expectEqual(PriorityTier.tier_5, PriorityTier.fromInt(5));
    try std.testing.expectEqual(PriorityTier.tier_5, PriorityTier.fromInt(99)); // Invalid defaults to tier_5
}

test "ApiType toString" {
    try std.testing.expectEqualStrings("openai-completions", ApiType.openai_completions.toString());
    try std.testing.expectEqualStrings("openai-chat", ApiType.openai_chat.toString());
    try std.testing.expectEqualStrings("custom", ApiType.custom.toString());
}
