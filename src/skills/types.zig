//! Skills System Base Types
//! Core data structures for the ZeptoClaw skills system

const std = @import("std");

/// SkillMetadata contains parsed information from SKILL.md
pub const SkillMetadata = struct {
    id: []const u8,
    name: []const u8,
    version: ?[]const u8 = null,
    description: []const u8,
    homepage: ?[]const u8 = null,
    metadata: std.json.Value = .null,
    enabled: bool = true,

    pub fn deinit(self: *const SkillMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.version) |v| allocator.free(v);
        allocator.free(self.description);
        if (self.homepage) |h| allocator.free(h);
        // metadata is a JSON value that may contain allocated strings
        // For simplicity, we don't deep-free metadata here
    }

    pub fn dupe(self: SkillMetadata, allocator: std.mem.Allocator) !SkillMetadata {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .name = try allocator.dupe(u8, self.name),
            .version = if (self.version) |v| try allocator.dupe(u8, v) else null,
            .description = try allocator.dupe(u8, self.description),
            .homepage = if (self.homepage) |h| try allocator.dupe(u8, h) else null,
            .metadata = self.metadata,
            .enabled = self.enabled,
        };
    }
};

/// TriggerType defines how a skill can be activated
pub const TriggerType = enum {
    mention,   // @agent or !agent mentions
    command,   // /command style commands
    pattern,   // Regex pattern matching
    scheduled, // Cron-like scheduling
    event,     // System events (startup, shutdown, error)

    pub fn toString(self: TriggerType) []const u8 {
        return switch (self) {
            .mention => "mention",
            .command => "command",
            .pattern => "pattern",
            .scheduled => "scheduled",
            .event => "event",
        };
    }

    pub fn fromString(s: []const u8) ?TriggerType {
        return if (std.mem.eql(u8, s, "mention"))
            .mention
        else if (std.mem.eql(u8, s, "command"))
            .command
        else if (std.mem.eql(u8, s, "pattern"))
            .pattern
        else if (std.mem.eql(u8, s, "scheduled"))
            .scheduled
        else if (std.mem.eql(u8, s, "event"))
            .event
        else
            null;
    }
};

/// Trigger defines when a skill should be activated
pub const Trigger = struct {
    trigger_type: TriggerType,
    pattern: ?[]const u8 = null, // For command, pattern, mention
    cron_expr: ?[]const u8 = null, // For scheduled triggers
    event_type: ?[]const u8 = null, // For event triggers

    pub fn deinit(self: *const Trigger, allocator: std.mem.Allocator) void {
        if (self.pattern) |p| allocator.free(p);
        if (self.cron_expr) |c| allocator.free(c);
        if (self.event_type) |e| allocator.free(e);
    }

    pub fn dupe(self: Trigger, allocator: std.mem.Allocator) !Trigger {
        return .{
            .trigger_type = self.trigger_type,
            .pattern = if (self.pattern) |p| try allocator.dupe(u8, p) else null,
            .cron_expr = if (self.cron_expr) |c| try allocator.dupe(u8, c) else null,
            .event_type = if (self.event_type) |e| try allocator.dupe(u8, e) else null,
        };
    }
};

/// ConfigSchema defines the configuration structure for a skill
pub const ConfigSchema = struct {
    fields: std.StringHashMap(ConfigField),

    pub fn init(allocator: std.mem.Allocator) ConfigSchema {
        return .{
            .fields = std.StringHashMap(ConfigField).init(allocator),
        };
    }

    pub fn deinit(self: *ConfigSchema) void {
        var iter = self.fields.iterator();
        while (iter.next()) |entry| {
            self.fields.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.fields.allocator);
        }
        self.fields.deinit();
    }
};

/// ConfigField defines a single configuration field
pub const ConfigField = struct {
    field_type: FieldType,
    description: []const u8,
    required: bool = false,
    default_value: ?std.json.Value = null,

    pub fn deinit(self: *ConfigField, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
        if (self.default_value) |dv| {
            // Don't deep-free JSON values for simplicity
            _ = dv;
        }
    }
};

/// FieldType defines the type of a configuration field
pub const FieldType = enum {
    string,
    integer,
    float,
    boolean,
    array,
    object,

    pub fn toString(self: FieldType) []const u8 {
        return switch (self) {
            .string => "string",
            .integer => "integer",
            .float => "float",
            .boolean => "boolean",
            .array => "array",
            .object => "object",
        };
    }

    pub fn fromString(s: []const u8) ?FieldType {
        return if (std.mem.eql(u8, s, "string"))
            .string
        else if (std.mem.eql(u8, s, "integer") or std.mem.eql(u8, s, "int"))
            .integer
        else if (std.mem.eql(u8, s, "float") or std.mem.eql(u8, s, "number"))
            .float
        else if (std.mem.eql(u8, s, "boolean") or std.mem.eql(u8, s, "bool"))
            .boolean
        else if (std.mem.eql(u8, s, "array") or std.mem.eql(u8, s, "list"))
            .array
        else if (std.mem.eql(u8, s, "object") or std.mem.eql(u8, s, "map"))
            .object
        else
            null;
    }
};

/// Skill represents a loaded skill with its metadata and triggers
pub const Skill = struct {
    metadata: SkillMetadata,
    triggers: std.ArrayList(Trigger),
    config_schema: ConfigSchema,
    path: []const u8, // Path to skill directory

    pub fn deinit(self: *Skill, allocator: std.mem.Allocator) void {
        self.metadata.deinit(allocator);
        for (self.triggers.items) |*trigger| trigger.deinit(allocator);
        self.triggers.deinit(allocator);
        self.config_schema.deinit();
        allocator.free(self.path);
    }

    pub fn dupe(self: Skill, allocator: std.mem.Allocator) !Skill {
        var triggers = std.ArrayList(Trigger){};
        errdefer {
            for (triggers.items) |*t| t.deinit(allocator);
            triggers.deinit(allocator);
        }

        for (self.triggers.items) |trigger| {
            try triggers.append(allocator, try trigger.dupe(allocator));
        }

        return .{
            .metadata = try self.metadata.dupe(allocator),
            .triggers = triggers,
            .config_schema = self.config_schema, // Shallow copy for now
            .path = try allocator.dupe(u8, self.path),
        };
    }
};

/// SkillError represents errors in the skills system
pub const SkillError = error{
    SkillNotFound,
    InvalidSkillMetadata,
    InvalidTrigger,
    InvalidConfig,
    LoadFailed,
    ParseError,
    ExecutionFailed,
    DependencyNotFound,
};

test "TriggerType conversion" {
    try std.testing.expectEqualStrings("mention", TriggerType.toString(.mention));
    try std.testing.expectEqualStrings("command", TriggerType.toString(.command));
    try std.testing.expectEqualStrings("pattern", TriggerType.toString(.pattern));
    try std.testing.expectEqualStrings("scheduled", TriggerType.toString(.scheduled));
    try std.testing.expectEqualStrings("event", TriggerType.toString(.event));

    try std.testing.expectEqual(TriggerType.mention, TriggerType.fromString("mention").?);
    try std.testing.expectEqual(TriggerType.command, TriggerType.fromString("command").?);
    try std.testing.expectEqual(@as(?TriggerType, null), TriggerType.fromString("invalid"));
}

test "FieldType conversion" {
    try std.testing.expectEqualStrings("string", FieldType.toString(.string));
    try std.testing.expectEqualStrings("integer", FieldType.toString(.integer));
    try std.testing.expectEqualStrings("float", FieldType.toString(.float));
    try std.testing.expectEqualStrings("boolean", FieldType.toString(.boolean));
    try std.testing.expectEqualStrings("array", FieldType.toString(.array));
    try std.testing.expectEqualStrings("object", FieldType.toString(.object));
}

test "SkillMetadata dupe" {
    const allocator = std.testing.allocator;

    const original = SkillMetadata{
        .id = "test-skill",
        .name = "Test Skill",
        .version = "1.0.0",
        .description = "A test skill",
        .homepage = "https://example.com",
        .metadata = .null,
        .enabled = true,
    };

    const duplicated = try original.dupe(allocator);
    defer duplicated.deinit(allocator);

    try std.testing.expectEqualStrings(original.id, duplicated.id);
    try std.testing.expectEqualStrings(original.name, duplicated.name);
    try std.testing.expectEqualStrings(original.version.?, duplicated.version.?);
    try std.testing.expectEqual(original.enabled, duplicated.enabled);
}

test "Trigger dupe" {
    const allocator = std.testing.allocator;

    const original = Trigger{
        .trigger_type = .command,
        .pattern = "/test",
        .cron_expr = null,
        .event_type = null,
    };

    const duplicated = try original.dupe(allocator);
    defer duplicated.deinit(allocator);

    try std.testing.expectEqual(original.trigger_type, duplicated.trigger_type);
    try std.testing.expectEqualStrings(original.pattern.?, duplicated.pattern.?);
}

test "ConfigSchema init and deinit" {
    const allocator = std.testing.allocator;

    var schema = ConfigSchema.init(allocator);
    defer schema.deinit();

    try std.testing.expectEqual(@as(usize, 0), schema.fields.count());
}
