//! Skills Loader
//! Loads skills from disk and parses SKILL.md metadata

const std = @import("std");
const types = @import("types.zig");

const SkillMetadata = types.SkillMetadata;
const Skill = types.Skill;
const Trigger = types.Trigger;
const TriggerType = types.TriggerType;
const ConfigSchema = types.ConfigSchema;
const ConfigField = types.ConfigField;
const FieldType = types.FieldType;
const SkillError = types.SkillError;

/// SkillLoader loads skills from disk
pub const SkillLoader = struct {
    allocator: std.mem.Allocator,
    skill_paths: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) SkillLoader {
        return .{
            .allocator = allocator,
            .skill_paths = std.ArrayList([]const u8){},
        };
    }

    pub fn deinit(self: *SkillLoader) void {
        for (self.skill_paths.items) |path| {
            self.allocator.free(path);
        }
        self.skill_paths.deinit(self.allocator);
    }

    /// Add a skill search path
    pub fn addSkillPath(self: *SkillLoader, path: []const u8) !void {
        const duped = try self.allocator.dupe(u8, path);
        try self.skill_paths.append(self.allocator, duped);
    }

    /// Load all skills from configured paths
    pub fn loadAll(self: *SkillLoader) !std.ArrayList(Skill) {
        var skills = std.ArrayList(Skill){};
        errdefer {
            for (skills.items) |*skill| skill.deinit(self.allocator);
            skills.deinit(self.allocator);
        }

        for (self.skill_paths.items) |path| {
            const dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
                std.log.warn("Failed to open skill path {s}: {}", .{ path, err });
                continue;
            };
            defer dir.close();

            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind == .directory) {
                    const skill_path = try std.fs.path.join(self.allocator, &.{ path, entry.name });
                    defer self.allocator.free(skill_path);

                    if (try self.loadSkill(skill_path)) |skill| {
                        try skills.append(self.allocator, skill);
                    } else |err| {
                        std.log.warn("Failed to load skill from {s}: {}", .{ skill_path, err });
                    }
                }
            }
        }

        return skills;
    }

    /// Load a single skill from a directory
    pub fn loadSkill(self: *SkillLoader, skill_dir: []const u8) !?Skill {
        const skill_md_path = try std.fs.path.join(self.allocator, &.{ skill_dir, "SKILL.md" });
        defer self.allocator.free(skill_md_path);

        const file = std.fs.openFileAbsolute(skill_md_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return null; // Not a valid skill directory
            }
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // Max 1MB
        defer self.allocator.free(content);

        var metadata = try self.parseSkillMetadata(content, skill_dir);
        errdefer metadata.deinit(self.allocator);

        var triggers = try self.parseTriggers(content);
        errdefer {
            for (triggers.items) |*t| t.deinit(self.allocator);
            triggers.deinit(self.allocator);
        }

        var config_schema = try self.parseConfigSchema(content);
        errdefer config_schema.deinit();

        return Skill{
            .metadata = metadata,
            .triggers = triggers,
            .config_schema = config_schema,
            .path = try self.allocator.dupe(u8, skill_dir),
        };
    }

    /// Parse skill metadata from SKILL.md frontmatter
    fn parseSkillMetadata(self: *SkillLoader, content: []const u8, skill_dir: []const u8) !SkillMetadata {
        // Extract frontmatter (between --- markers)
        const frontmatter_start = std.mem.indexOf(u8, content, "---") orelse return error.InvalidSkillMetadata;
        const frontmatter_end = std.mem.indexOfPos(u8, content, frontmatter_start + 3, "---") orelse return error.InvalidSkillMetadata;

        const frontmatter = content[frontmatter_start + 3 .. frontmatter_end];

        // Parse YAML frontmatter
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, frontmatter, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const obj = parsed.value.object;

        // Extract required fields
        const name = obj.get("name") orelse return error.InvalidSkillMetadata;
        const description = obj.get("description") orelse return error.InvalidSkillMetadata;

        if (name != .string or description != .string) {
            return error.InvalidSkillMetadata;
        }

        // Extract optional fields
        const version = if (obj.get("version")) |v|
            if (v == .string) try self.allocator.dupe(u8, v.string) else null
        else
            null;

        const homepage = if (obj.get("homepage")) |h|
            if (h == .string) try self.allocator.dupe(u8, h.string) else null
        else
            null;

        const metadata_val = obj.get("metadata") orelse .null;

        // Generate ID from skill directory name
        const dir_name = std.fs.path.basename(skill_dir);
        const id = try self.allocator.dupe(u8, dir_name);

        return SkillMetadata{
            .id = id,
            .name = try self.allocator.dupe(u8, name.string),
            .version = version,
            .description = try self.allocator.dupe(u8, description.string),
            .homepage = homepage,
            .metadata = metadata_val,
            .enabled = true,
        };
    }

    /// Parse triggers from SKILL.md content
    fn parseTriggers(self: *SkillLoader, content: []const u8) !std.ArrayList(Trigger) {
        var triggers = std.ArrayList(Trigger){};

        // Look for trigger definitions in the content
        // Format: "## Triggers" followed by trigger definitions
        const triggers_section = self.findSection(content, "Triggers") orelse {
            // No triggers section, return empty list
            return triggers;
        };

        // Parse trigger definitions
        var lines = std.mem.splitScalar(u8, triggers_section, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Parse trigger format: "type: pattern"
            if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
                const trigger_type_str = trimmed[0..colon_idx];
                const pattern = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t");

                if (TriggerType.fromString(trigger_type_str)) |trigger_type| {
                    var trigger = Trigger{
                        .trigger_type = trigger_type,
                        .pattern = null,
                        .cron_expr = null,
                        .event_type = null,
                    };

                    switch (trigger_type) {
                        .mention, .command, .pattern => {
                            trigger.pattern = try self.allocator.dupe(u8, pattern);
                        },
                        .scheduled => {
                            trigger.cron_expr = try self.allocator.dupe(u8, pattern);
                        },
                        .event => {
                            trigger.event_type = try self.allocator.dupe(u8, pattern);
                        },
                    }

                    try triggers.append(self.allocator, trigger);
                }
            }
        }

        return triggers;
    }

    /// Parse config schema from SKILL.md content
    fn parseConfigSchema(self: *SkillLoader, content: []const u8) !ConfigSchema {
        var schema = ConfigSchema.init(self.allocator);

        // Look for config section
        const config_section = self.findSection(content, "Configuration") orelse {
            // No config section, return empty schema
            return schema;
        };

        // Parse config field definitions
        var lines = std.mem.splitScalar(u8, config_section, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Parse field format: "name (type): description"
            if (std.mem.indexOf(u8, trimmed, "(")) |open_paren| {
                if (std.mem.indexOf(u8, trimmed, ")")) |close_paren| {
                    const field_name = std.mem.trim(u8, trimmed[0..open_paren], " \t");
                    const type_str = trimmed[open_paren + 1 .. close_paren];
                    const description = if (std.mem.indexOf(u8, trimmed, ":")) |colon|
                        std.mem.trim(u8, trimmed[colon + 1 ..], " \t")
                    else
                        "";

                    if (FieldType.fromString(type_str)) |field_type| {
                        const field = ConfigField{
                            .field_type = field_type,
                            .description = try self.allocator.dupe(u8, description),
                            .required = false,
                            .default_value = null,
                        };
                        try schema.fields.put(try self.allocator.dupe(u8, field_name), field);
                    }
                }
            }
        }

        return schema;
    }

    /// Find a section in markdown content
    fn findSection(self: *SkillLoader, content: []const u8, section_name: []const u8) ?[]const u8 {
        _ = self;

        const header = std.fmt.allocPrint(std.heap.page_allocator, "## {s}", .{section_name}) catch return null;
        defer std.heap.page_allocator.free(header);

        const start = std.mem.indexOf(u8, content, header) orelse return null;

        // Find the end of the section (next ## or end of file)
        var end = start + header.len;
        while (end < content.len) : (end += 1) {
            if (end + 1 < content.len and content[end] == '\n' and content[end + 1] == '#') {
                break;
            }
        }

        return content[start + header.len .. end];
    }
};

test "SkillLoader init and deinit" {
    const allocator = std.testing.allocator;
    var loader = SkillLoader.init(allocator);
    defer loader.deinit();

    try std.testing.expectEqual(@as(usize, 0), loader.skill_paths.items.len);
}

test "SkillLoader addSkillPath" {
    const allocator = std.testing.allocator;
    var loader = SkillLoader.init(allocator);
    defer loader.deinit();

    try loader.addSkillPath("/test/path");
    try std.testing.expectEqual(@as(usize, 1), loader.skill_paths.items.len);
    try std.testing.expectEqualStrings("/test/path", loader.skill_paths.items[0]);
}

test "parseSkillMetadata with valid frontmatter" {
    const allocator = std.testing.allocator;
    var loader = SkillLoader.init(allocator);
    defer loader.deinit();

    const content = "---\n{\"name\": \"test-skill\", \"version\": \"1.0.0\", \"description\": \"A test skill\", \"homepage\": \"https://example.com\"}\n---\n# Test Skill\nThis is a test skill.\n";

    const metadata = try loader.parseSkillMetadata(content, "/path/to/test-skill");
    defer metadata.deinit(allocator);

    try std.testing.expectEqualStrings("test-skill", metadata.id);
    try std.testing.expectEqualStrings("test-skill", metadata.name);
    try std.testing.expectEqualStrings("1.0.0", metadata.version.?);
    try std.testing.expectEqualStrings("A test skill", metadata.description);
    try std.testing.expectEqualStrings("https://example.com", metadata.homepage.?);
    try std.testing.expectEqual(true, metadata.enabled);
}

test "parseTriggers with valid triggers" {
    const allocator = std.testing.allocator;
    var loader = SkillLoader.init(allocator);
    defer loader.deinit();

    const content =
        \\## Triggers
        \\command: /test
        \\mention: @agent
        \\pattern: regex.*
        \\scheduled: 0 * * * *
        \\event: startup
    ;

    var triggers = try loader.parseTriggers(content);
    defer {
        for (triggers.items) |*t| t.deinit(allocator);
        triggers.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 5), triggers.items.len);
    try std.testing.expectEqual(TriggerType.command, triggers.items[0].trigger_type);
    try std.testing.expectEqualStrings("/test", triggers.items[0].pattern.?);
    try std.testing.expectEqual(TriggerType.mention, triggers.items[1].trigger_type);
    try std.testing.expectEqual(TriggerType.scheduled, triggers.items[3].trigger_type);
    try std.testing.expectEqualStrings("0 * * * *", triggers.items[3].cron_expr.?);
}

test "parseConfigSchema with valid config" {
    const allocator = std.testing.allocator;
    var loader = SkillLoader.init(allocator);
    defer loader.deinit();

    const content =
        \\## Configuration
        \\api_key (string): The API key for the service
        \\timeout (integer): Request timeout in seconds
        \\enabled (boolean): Whether the feature is enabled
    ;

    var schema = try loader.parseConfigSchema(content);
    defer schema.deinit();

    try std.testing.expectEqual(@as(usize, 3), schema.fields.count());
    try std.testing.expect(schema.fields.get("api_key") != null);
    try std.testing.expect(schema.fields.get("timeout") != null);
    try std.testing.expect(schema.fields.get("enabled") != null);
}
