//! Skill SDK
//! Template and documentation for skill developers

const std = @import("std");
const types = @import("types.zig");
const execution_context = @import("execution_context.zig");

const SkillMetadata = types.SkillMetadata;
const Trigger = types.Trigger;
const TriggerType = types.TriggerType;
const ConfigSchema = types.ConfigSchema;
const ConfigField = types.ConfigField;
const FieldType = types.FieldType;
const ExecutionContext = execution_context.ExecutionContext;
const SkillResult = execution_context.SkillResult;

/// Skill is the interface that all skills must implement
pub const Skill = struct {
    /// Initialize the skill
    init: *const fn (allocator: std.mem.Allocator, config: std.json.Value) anyerror!void,

    /// Execute the skill
    execute: *const fn (ctx: *ExecutionContext) anyerror!SkillResult,

    /// Cleanup the skill
    deinit: *const fn (allocator: std.mem.Allocator) void,

    /// Get skill metadata
    getMetadata: *const fn () SkillMetadata,
};

/// SkillBuilder helps build skill definitions
pub const SkillBuilder = struct {
    allocator: std.mem.Allocator,
    metadata: SkillMetadata,
    triggers: std.ArrayList(Trigger),
    config_schema: ConfigSchema,

    pub fn init(allocator: std.mem.Allocator, id: []const u8, name: []const u8, description: []const u8) !SkillBuilder {
        return .{
            .allocator = allocator,
            .metadata = SkillMetadata{
                .id = id,
                .name = name,
                .version = null,
                .description = description,
                .homepage = null,
                .metadata = .null,
                .enabled = true,
            },
            .triggers = try std.ArrayList(Trigger).initCapacity(allocator, 0),
            .config_schema = ConfigSchema.init(allocator),
        };
    }

    pub fn deinit(self: *SkillBuilder) void {
        self.metadata.deinit(self.allocator);
        for (self.triggers.items) |*t| t.deinit(self.allocator);
        self.triggers.deinit();
        self.config_schema.deinit();
    }

    pub fn version(self: *SkillBuilder, version: []const u8) !*SkillBuilder {
        self.metadata.version = try self.allocator.dupe(u8, version);
        return self;
    }

    pub fn homepage(self: *SkillBuilder, homepage: []const u8) !*SkillBuilder {
        self.metadata.homepage = try self.allocator.dupe(u8, homepage);
        return self;
    }

    pub fn addTrigger(self: *SkillBuilder, trigger_type: TriggerType, pattern: []const u8) !*SkillBuilder {
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

        try self.triggers.append(trigger);
        return self;
    }

    pub fn addConfigField(self: *SkillBuilder, name: []const u8, field_type: FieldType, description: []const u8) !*SkillBuilder {
        const field = ConfigField{
            .field_type = field_type,
            .description = try self.allocator.dupe(u8, description),
            .required = false,
            .default_value = null,
        };

        try self.config_schema.fields.put(try self.allocator.dupe(u8, name), field);
        return self;
    }

    pub fn build(self: *SkillBuilder) !types.Skill {
        return types.Skill{
            .metadata = try self.metadata.dupe(self.allocator),
            .triggers = self.triggers,
            .config_schema = self.config_schema,
            .path = try self.allocator.dupe(u8, ""),
        };
    }
};

/// Helper functions for skill developers
pub const SkillHelpers = struct {
    /// Create a simple command trigger
    pub fn commandTrigger(allocator: std.mem.Allocator, command: []const u8) !Trigger {
        return Trigger{
            .trigger_type = .command,
            .pattern = try allocator.dupe(u8, command),
            .cron_expr = null,
            .event_type = null,
        };
    }

    /// Create a simple mention trigger
    pub fn mentionTrigger(allocator: std.mem.Allocator, mention: []const u8) !Trigger {
        return Trigger{
            .trigger_type = .mention,
            .pattern = try allocator.dupe(u8, mention),
            .cron_expr = null,
            .event_type = null,
        };
    }

    /// Create a simple pattern trigger
    pub fn patternTrigger(allocator: std.mem.Allocator, pattern: []const u8) !Trigger {
        return Trigger{
            .trigger_type = .pattern,
            .pattern = try allocator.dupe(u8, pattern),
            .cron_expr = null,
            .event_type = null,
        };
    }

    /// Create a simple scheduled trigger
    pub fn scheduledTrigger(allocator: std.mem.Allocator, cron_expr: []const u8) !Trigger {
        return Trigger{
            .trigger_type = .scheduled,
            .pattern = null,
            .cron_expr = try allocator.dupe(u8, cron_expr),
            .event_type = null,
        };
    }

    /// Create a simple event trigger
    pub fn eventTrigger(allocator: std.mem.Allocator, event_type: []const u8) !Trigger {
        return Trigger{
            .trigger_type = .event,
            .pattern = null,
            .cron_expr = null,
            .event_type = try allocator.dupe(u8, event_type),
        };
    }

    /// Parse command arguments
    pub fn parseCommandArgs(allocator: std.mem.Allocator, args: []const u8) !std.ArrayList([]const u8) {
        var result = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        errdefer {
            for (result.items) |arg| allocator.free(arg);
            result.deinit();
        }

        var iter = std.mem.splitScalar(u8, args, ' ');
        while (iter.next()) |arg| {
            if (arg.len > 0) {
                try result.append(try allocator.dupe(u8, arg));
            }
        }

        return result;
    }

    /// Format a response
    pub fn formatResponse(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(allocator, fmt, args);
    }
};

// ============================================================================
// SKILL DEVELOPER GUIDE
// ============================================================================

// This section provides documentation for skill developers.
// In a real implementation, this would be extracted to markdown documentation.

//
// # Creating a Skill
//
// A skill is a Zig module that implements the Skill interface.
//
// ## Basic Structure
//
// ```zig
// const std = @import("std");
// const sdk = @import("skill_sdk");
//
// pub const skill = struct {
//     // Skill state (optional)
//     var state: ?State = null;
//
//     pub fn init(allocator: std.mem.Allocator, config: std.json.Value) !void {
//         // Initialize skill state
//         state = State{
//             // ... initialize fields
//         };
//     }
//
//     pub fn execute(ctx: *sdk.ExecutionContext) !sdk.SkillResult {
//         // Get message content
//         const message = ctx.getMessageContent() orelse return sdk.SkillResult.errorResponse(
//             ctx.allocator,
//             "No message content"
//         );
//
//         // Process message
//         const response = try processMessage(ctx.allocator, message);
//
//         // Send response
//         try ctx.respond(response);
//
//         return sdk.SkillResult.successResponse(ctx.allocator, response);
//     }
//
//     pub fn deinit(allocator: std.mem.Allocator) void {
//         // Cleanup skill state
//         if (state) |*s| {
//             // ... cleanup
//             state = null;
//         }
//     }
//
//     pub fn getMetadata() sdk.SkillMetadata {
//         return sdk.SkillMetadata{
//             .id = "my-skill",
//             .name = "My Skill",
//             .version = "1.0.0",
//             .description = "A sample skill",
//             .homepage = null,
//             .metadata = .null,
//             .enabled = true,
//         };
//     }
// };
// ```
//
// ## SKILL.md Format
//
// Every skill must have a SKILL.md file in its directory:
//
// ```markdown
// ---
// name: my-skill
// version: 1.0.0
// description: A sample skill
// homepage: https://example.com
// metadata: {"key": "value"}
// ---
//
// # My Skill
//
// Description of what this skill does.
//
// ## Triggers
// command: /myskill
// mention: @myskill
// pattern: myskill.*
//
// ## Configuration
// api_key (string): The API key for the service
// timeout (integer): Request timeout in seconds
// ```
//
// ## Trigger Types
//
// ### Command Triggers
// Activated when a message starts with a command (e.g., `/help`)
//
// ### Mention Triggers
// Activated when the agent is mentioned (e.g., `@agent help`)
//
// ### Pattern Triggers
// Activated when a message matches a pattern (supports `*` wildcard)
//
// ### Scheduled Triggers
// Activated on a schedule (cron format: `minute hour day month weekday`)
//
// ### Event Triggers
// Activated on system events (startup, shutdown, error)
//
// ## Using the Execution Context
//
// The execution context provides:
//
// - `getMessageContent()`: Get the triggering message
// - `getMessageRole()`: Get the message role (user, assistant, etc.)
// - `getConfig(key)`: Get skill configuration
// - `getConfigString(key)`: Get string configuration value
// - `getConfigInt(key)`: Get integer configuration value
// - `getConfigBool(key)`: Get boolean configuration value
// - `callTool(name, args)`: Call a tool
// - `respond(message)`: Send a response
// - `log(level, message)`: Log a message
//
// ## Skill Results
//
// Skills return a `SkillResult`:
//
// - `successResponse(allocator, message)`: Success with response
// - `errorResponse(allocator, error)`: Error with message
// - `stop(allocator, message)`: Success and stop processing
//
// ## Best Practices
//
// 1. Always handle errors gracefully
// 2. Use the context's allocator for temporary allocations
// 3. Log important events using `ctx.log()`
// 4. Clean up resources in `deinit()`
// 5. Keep skills focused on a single responsibility
// 6. Document your skill's triggers and configuration
// 7. Test your skill with various inputs
//
// ## Example: Echo Skill
//
// ```zig
// const std = @import("std");
// const sdk = @import("skill_sdk");
//
// pub const skill = struct {
//     pub fn init(allocator: std.mem.Allocator, config: std.json.Value) !void {
//         _ = allocator;
//         _ = config;
//     }
//
//     pub fn execute(ctx: *sdk.ExecutionContext) !sdk.SkillResult {
//         const message = ctx.getMessageContent() orelse {
//             return sdk.SkillResult.errorResponse(ctx.allocator, "No message");
//         };
//
//         const response = try std.fmt.allocPrint(
//             ctx.allocator,
//             "Echo: {s}",
//             .{message}
//         );
//
//         try ctx.respond(response);
//         return sdk.SkillResult.successResponse(ctx.allocator, response);
//     }
//
//     pub fn deinit(allocator: std.mem.Allocator) void {
//         _ = allocator;
//     }
//
//     pub fn getMetadata() sdk.SkillMetadata {
//         return sdk.SkillMetadata{
//             .id = "echo",
//             .name = "Echo",
//             .version = "1.0.0",
//             .description = "Echoes back messages",
//             .homepage = null,
//             .metadata = .null,
//             .enabled = true,
//         };
//     }
// };
// ```

test "SkillBuilder basic" {
    const allocator = std.testing.allocator;

    var builder = try SkillBuilder.init(allocator, "test-skill", "Test Skill", "A test skill");
    defer builder.deinit();

    try builder.version("1.0.0");
    try builder.homepage("https://example.com");
    try builder.addTrigger(.command, "/test");
    try builder.addTrigger(.mention, "@test");
    try builder.addConfigField("api_key", .string, "API key");

    const skill = try builder.build();
    defer skill.deinit(allocator);

    try std.testing.expectEqualStrings("test-skill", skill.metadata.id);
    try std.testing.expectEqualStrings("Test Skill", skill.metadata.name);
    try std.testing.expectEqualStrings("1.0.0", skill.metadata.version.?);
    try std.testing.expectEqual(@as(usize, 2), skill.triggers.items.len);
    try std.testing.expectEqual(@as(usize, 1), skill.config_schema.fields.count());
}

test "SkillHelpers commandTrigger" {
    const allocator = std.testing.allocator;

    const trigger = try SkillHelpers.commandTrigger(allocator, "/test");
    defer trigger.deinit(allocator);

    try std.testing.expectEqual(TriggerType.command, trigger.trigger_type);
    try std.testing.expectEqualStrings("/test", trigger.pattern.?);
}

test "SkillHelpers parseCommandArgs" {
    const allocator = std.testing.allocator;

    const args = try SkillHelpers.parseCommandArgs(allocator, "arg1 arg2 arg3");
    defer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit();
    }

    try std.testing.expectEqual(@as(usize, 3), args.items.len);
    try std.testing.expectEqualStrings("arg1", args.items[0]);
    try std.testing.expectEqualStrings("arg2", args.items[1]);
    try std.testing.expectEqualStrings("arg3", args.items[2]);
}

test "SkillHelpers formatResponse" {
    const allocator = std.testing.allocator;

    const response = try SkillHelpers.formatResponse(allocator, "Hello, {s}!", .{"World"});
    defer allocator.free(response);

    try std.testing.expectEqualStrings("Hello, World!", response);
}
