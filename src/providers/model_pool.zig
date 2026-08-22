const std = @import("std");
const provider_pool = @import("provider_pool.zig");

/// Re-export of provider_pool for compatibility (model_pool alias).
/// Memory: See `provider_pool.zig` for ownership details.

/// ModelPool alias - see provider_pool.ModelPool
/// Memory: Owns duped strings in models and map; call `deinit()` to free. Getters return caller-owned slices.
pub const ModelPool = provider_pool.ModelPool;

/// ModelMetadata alias - see provider_pool.ModelMetadata
/// Memory: Owns `id`, `name`, `provider`, `base_url`, `description`; call `deinit(allocator)` to free.
pub const ModelMetadata = provider_pool.ModelMetadata;

/// PriorityTier alias - values only, no allocation.
/// Memory: No allocation; copy by value.
pub const PriorityTier = provider_pool.PriorityTier;

/// ApiType alias - values only, no allocation.
/// Memory: No allocation; copy by value.
pub const ApiType = provider_pool.ApiType;
