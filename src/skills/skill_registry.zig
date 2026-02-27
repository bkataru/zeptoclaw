//! Skill Registry
//! Manages skill registration, lookup, and enable/disable

const std = @import("std");
const types = @import("types.zig");

const Skill = types.Skill;
const SkillMetadata = types.SkillMetadata;
const SkillError = types.SkillError;

/// SkillRegistry manages all registered skills
pub const SkillRegistry = struct {
    allocator: std.mem.Allocator,
    skills: std.StringHashMap(Skill),
    enabled_skills: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) SkillRegistry {
        return .{
            .allocator = allocator,
            .skills = std.StringHashMap(Skill).init(allocator),
            .enabled_skills = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *SkillRegistry) void {
        var iter = self.skills.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.skills.deinit();
        self.enabled_skills.deinit();
    }

    /// Register a skill
    pub fn register(self: *SkillRegistry, skill: Skill) !void {
        const skill_id = try self.allocator.dupe(u8, skill.metadata.id);
        errdefer self.allocator.free(skill_id);

        var skill_copy = try skill.dupe(self.allocator);
        errdefer skill_copy.deinit(self.allocator);

        try self.skills.put(skill_id, skill_copy);

        // Enable by default
        if (skill.metadata.enabled) {
            try self.enable(skill.metadata.id);
        }
    }

    /// Unregister a skill
    pub fn unregister(self: *SkillRegistry, skill_id: []const u8) !void {
        const skill = self.skills.fetchRemove(skill_id) orelse return SkillError.SkillNotFound;

        @constCast(&skill.value).deinit(self.allocator);
        self.allocator.free(skill.key);

        _ = self.enabled_skills.remove(skill_id);
    }

    /// Get a skill by ID
    pub fn get(self: *SkillRegistry, skill_id: []const u8) ?*Skill {
        return self.skills.getPtr(skill_id);
    }

    /// Get skill metadata by ID
    pub fn getMetadata(self: *SkillRegistry, skill_id: []const u8) ?SkillMetadata {
        const skill = self.get(skill_id) orelse return null;
        return skill.metadata;
    }

    /// Check if a skill is enabled
    pub fn isEnabled(self: *SkillRegistry, skill_id: []const u8) bool {
        return self.enabled_skills.contains(skill_id);
    }

    /// Enable a skill
    pub fn enable(self: *SkillRegistry, skill_id: []const u8) !void {
        if (self.get(skill_id) == null) {
            return SkillError.SkillNotFound;
        }

        const id_copy = try self.allocator.dupe(u8, skill_id);
        errdefer self.allocator.free(id_copy);

        try self.enabled_skills.put(id_copy, {});
    }

    /// Disable a skill
    pub fn disable(self: *SkillRegistry, skill_id: []const u8) !void {
        if (self.get(skill_id) == null) {
            return SkillError.SkillNotFound;
        }

        const entry = self.enabled_skills.fetchRemove(skill_id);
        if (entry) |e| {
            self.allocator.free(e.key);
        }
    }

    /// Get all registered skills
    pub fn getAll(self: *SkillRegistry) ![]SkillMetadata {
        const skills = try self.allocator.alloc(SkillMetadata, self.skills.count());
        var i: usize = 0;
        var iter = self.skills.iterator();
        while (iter.next()) |entry| : (i += 1) {
            skills[i] = try entry.value_ptr.metadata.dupe(self.allocator);
        }
        return skills;
    }

    /// Get all enabled skills
    pub fn getEnabled(self: *SkillRegistry) ![]SkillMetadata {
        var skill_count: usize = 0;
        var iter = self.skills.iterator();
        while (iter.next()) |entry| {
            if (self.isEnabled(entry.value_ptr.metadata.id)) {
                skill_count += 1;
            }
        }

        const skills = try self.allocator.alloc(SkillMetadata, skill_count);
        var i: usize = 0;
        iter = self.skills.iterator();
        while (iter.next()) |entry| {
            if (self.isEnabled(entry.value_ptr.metadata.id)) {
                skills[i] = try entry.value_ptr.metadata.dupe(self.allocator);
                i += 1;
            }
        }
        return skills;
    }

    /// Find skills by trigger type
    pub fn findByTriggerType(self: *SkillRegistry, trigger_type: types.TriggerType) ![]SkillMetadata {
        var skill_count: usize = 0;
        var iter = self.skills.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.triggers.items) |trigger| {
                if (trigger.trigger_type == trigger_type and self.isEnabled(entry.value_ptr.metadata.id)) {
                    skill_count += 1;
                    break;
                }
            }
        }

        const skills = try self.allocator.alloc(SkillMetadata, skill_count);
        var i: usize = 0;
        iter = self.skills.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.triggers.items) |trigger| {
                if (trigger.trigger_type == trigger_type and self.isEnabled(entry.value_ptr.metadata.id)) {
                    skills[i] = try entry.value_ptr.metadata.dupe(self.allocator);
                    i += 1;
                    break;
                }
            }
        }
        return skills;
    }

    /// Get skill count
    pub fn count(self: *SkillRegistry) usize {
        return self.skills.count();
    }

    /// Get enabled skill count
    pub fn enabledCount(self: *SkillRegistry) usize {
        return self.enabled_skills.count();
    }

    /// Load skills from a loader
    pub fn loadFromLoader(self: *SkillRegistry, loader: anytype) !void {
        const skills = try loader.loadAll();
        defer {
            for (skills.items) |*skill| skill.deinit(self.allocator);
            skills.deinit();
        }

        for (skills.items) |skill| {
            try self.register(skill);
        }
    }

    /// Export registry state as JSON
    pub fn exportState(self: *SkillRegistry) !std.json.Value {
        var skills_array = std.ArrayList(std.json.Value).initCapacity(self.allocator, 0) catch unreachable;
        defer skills_array.deinit();

        var iter = self.skills.iterator();
        while (iter.next()) |entry| {
            var skill_obj = std.StringHashMap(std.json.Value).init(self.allocator);
            defer skill_obj.deinit();

            try skill_obj.put("id", std.json.Value{ .string = entry.value_ptr.metadata.id });
            try skill_obj.put("name", std.json.Value{ .string = entry.value_ptr.metadata.name });
            try skill_obj.put("enabled", std.json.Value{ .bool = self.isEnabled(entry.value_ptr.metadata.id) });

            if (entry.value_ptr.metadata.version) |v| {
                try skill_obj.put("version", std.json.Value{ .string = v });
            }

            try skills_array.append(std.json.Value{ .object = skill_obj });
        }

        return std.json.Value{ .array = skills_array };
    }
};

test "SkillRegistry init and deinit" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expectEqual(@as(usize, 0), registry.enabledCount());
}

test "SkillRegistry register and get" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator);
    defer registry.deinit();

    const skill = createTestSkill(allocator);

    try registry.register(skill);
    // Don't deinit skill since registry now owns a copy

    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectEqual(@as(usize, 1), registry.enabledCount());

    const retrieved = registry.get("test-skill");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("test-skill", retrieved.?.metadata.id);
}

test "SkillRegistry enable and disable" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator);
    defer registry.deinit();

    const skill = createTestSkill(allocator);

    try registry.register(skill);
    // Don't deinit skill since registry now owns a copy

    try std.testing.expect(registry.isEnabled("test-skill"));

    try registry.disable("test-skill");
    try std.testing.expect(!registry.isEnabled("test-skill"));
    try std.testing.expectEqual(@as(usize, 0), registry.enabledCount());

    try registry.enable("test-skill");
    try std.testing.expect(registry.isEnabled("test-skill"));
    try std.testing.expectEqual(@as(usize, 1), registry.enabledCount());
}

test "SkillRegistry getAll" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator);
    defer registry.deinit();

    const skill1 = createTestSkill(allocator);
    const skill2 = createTestSkill2(allocator);

    try registry.register(skill1);
    try registry.register(skill2);
    // Don't deinit skills since registry now owns copies

    const all = try registry.getAll();
    defer {
        for (all) |*m| m.deinit(allocator);
        allocator.free(all);
    }

    try std.testing.expectEqual(@as(usize, 2), all.len);
}

test "SkillRegistry getEnabled" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator);
    defer registry.deinit();

    const skill1 = createTestSkill(allocator);
    const skill2 = createTestSkill2(allocator);

    try registry.register(skill1);
    try registry.register(skill2);
    // Don't deinit skills since registry now owns copies

    try registry.disable("test-skill");

    const enabled = try registry.getEnabled();
    defer {
        for (enabled) |*m| m.deinit(allocator);
        allocator.free(enabled);
    }

    try std.testing.expectEqual(@as(usize, 1), enabled.len);
    try std.testing.expectEqualStrings("test-skill-2", enabled[0].id);
}

test "SkillRegistry unregister" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator);
    defer registry.deinit();

    const skill = createTestSkill(allocator);

    try registry.register(skill);
    // Don't deinit skill since registry now owns a copy
    try std.testing.expectEqual(@as(usize, 1), registry.count());

    try registry.unregister("test-skill");
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expect(registry.get("test-skill") == null);
}

// Test helpers
fn createTestSkill(allocator: std.mem.Allocator) Skill {
    const triggers = std.ArrayList(types.Trigger){};

    const metadata = SkillMetadata{
        .id = "test-skill",
        .name = "Test Skill",
        .version = null,
        .description = "A test skill",
        .homepage = null,
        .metadata = .null,
        .enabled = true,
    };

    return Skill{
        .metadata = metadata,
        .triggers = triggers,
        .config_schema = types.ConfigSchema.init(allocator),
        .path = allocator.dupe(u8, "/test/path") catch unreachable,
    };
}

fn createTestSkill2(allocator: std.mem.Allocator) Skill {
    const triggers = std.ArrayList(types.Trigger){};

    const metadata = SkillMetadata{
        .id = "test-skill-2",
        .name = "Test Skill 2",
        .version = null,
        .description = "Another test skill",
        .homepage = null,
        .metadata = .null,
        .enabled = true,
    };

    return Skill{
        .metadata = metadata,
        .triggers = triggers,
        .config_schema = types.ConfigSchema.init(allocator),
        .path = allocator.dupe(u8, "/test/path2") catch unreachable,
    };
}
