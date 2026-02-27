const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const SkillResult = sdk.SkillResult;
const ExecutionContext = sdk.ExecutionContext;

pub const skill = struct {
    var config: Config = .{};

    const Config = struct {
        user_name: []const u8 = "Baala",
        focus_protection: bool = true,
        auto_chunk: bool = true,
        brevity_mode: bool = true,
        memory_file: []const u8 = "memory/YYYY-MM-DD.md",
    };

    pub fn init(allocator: Allocator, config_value: std.json.Value) !void {
        _ = allocator;

        if (config_value == .object) {
            if (config_value.object.get("user_name")) |v| {
                if (v == .string) {
                    config.user_name = try allocator.dupe(u8, v.string);
                }
            }
            if (config_value.object.get("focus_protection")) |v| {
                if (v == .bool) {
                    config.focus_protection = v.bool;
                }
            }
            if (config_value.object.get("auto_chunk")) |v| {
                if (v == .bool) {
                    config.auto_chunk = v.bool;
                }
            }
            if (config_value.object.get("brevity_mode")) |v| {
                if (v == .bool) {
                    config.brevity_mode = v.bool;
                }
            }
            if (config_value.object.get("memory_file")) |v| {
                if (v == .string) {
                    config.memory_file = try allocator.dupe(u8, v.string);
                }
            }
        }
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const command = ctx.command orelse return error.NoCommand;

        if (std.mem.eql(u8, command, "breakdown")) {
            return handleBreakdown(ctx);
        } else if (std.mem.eql(u8, command, "chunk")) {
            return handleBreakdown(ctx);
        } else if (std.mem.eql(u8, command, "focus")) {
            return handleFocus(ctx);
        } else if (std.mem.eql(u8, command, "simplify")) {
            return handleSimplify(ctx);
        } else if (std.mem.eql(u8, command, "help")) {
            return handleHelp(ctx);
        } else {
            return error.UnknownCommand;
        }
    }

    fn handleBreakdown(ctx: *ExecutionContext) !SkillResult {
        const task = ctx.args orelse return error.MissingArgument;

        // Analyze the task and break it down
        var steps = std.ArrayList([]const u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer {
            for (steps.items) |step| {
                ctx.allocator.free(step);
            }
            steps.deinit();
        }

        // Simple heuristic-based breakdown
        if (std.mem.indexOf(u8, task, "CI") != null or std.mem.indexOf(u8, task, "ci") != null) {
            try steps.append(try ctx.allocator.dupe(u8, "Create .github/workflows directory"));
            try steps.append(try ctx.allocator.dupe(u8, "Write basic test workflow (copy from template)"));
            try steps.append(try ctx.allocator.dupe(u8, "Push and verify it runs"));
            try steps.append(try ctx.allocator.dupe(u8, "Add build step"));
            try steps.append(try ctx.allocator.dupe(u8, "Add release step (later)"));
        } else if (std.mem.indexOf(u8, task, "deploy") != null) {
            try steps.append(try ctx.allocator.dupe(u8, "Build the project"));
            try steps.append(try ctx.allocator.dupe(u8, "Test the build locally"));
            try steps.append(try ctx.allocator.dupe(u8, "Deploy to production"));
            try steps.append(try ctx.allocator.dupe(u8, "Verify deployment"));
        } else if (std.mem.indexOf(u8, task, "test") != null) {
            try steps.append(try ctx.allocator.dupe(u8, "Write test case"));
            try steps.append(try ctx.allocator.dupe(u8, "Run test"));
            try steps.append(try ctx.allocator.dupe(u8, "Fix any failures"));
            try steps.append(try ctx.allocator.dupe(u8, "Commit test"));
        } else if (std.mem.indexOf(u8, task, "document") != null or std.mem.indexOf(u8, task, "docs") != null) {
            try steps.append(try ctx.allocator.dupe(u8, "Open the documentation file"));
            try steps.append(try ctx.allocator.dupe(u8, "Write one sentence describing what it does"));
            try steps.append(try ctx.allocator.dupe(u8, "Add usage example"));
            try steps.append(try ctx.allocator.dupe(u8, "Review and refine"));
        } else {
            // Generic breakdown
            try steps.append(try ctx.allocator.dupe(u8, "Identify the first small step"));
            try steps.append(try ctx.allocator.dupe(u8, "Do that step"));
            try steps.append(try ctx.allocator.dupe(u8, "Identify the next step"));
            try steps.append(try ctx.allocator.dupe(u8, "Repeat until done"));
        }

        // Format response
        var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer response.deinit();

        try response.writer().print("Task: \"{s}\"\n\n", .{task});
        try response.writer().print("Break down:\n", .{});

        for (steps.items, 0..) |step, i| {
            try response.writer().print("{d}. [ ] {s}\n", .{ i + 1, step });
        }

        try response.writer().print("\nStart with step 1?\n", .{});

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleFocus(ctx: *ExecutionContext) !SkillResult {
        const task = ctx.args orelse return error.MissingArgument;

        // Find the tiniest first step
        var first_step: []const u8 = undefined;

        if (std.mem.indexOf(u8, task, "document") != null or std.mem.indexOf(u8, task, "docs") != null) {
            first_step = "Open README.md and write one sentence describing what it does";
        } else if (std.mem.indexOf(u8, task, "test") != null) {
            first_step = "Write one simple test case";
        } else if (std.mem.indexOf(u8, task, "deploy") != null) {
            first_step = "Run the build command";
        } else if (std.mem.indexOf(u8, task, "fix") != null) {
            first_step = "Identify the exact error message";
        } else {
            first_step = "Open the relevant file and read it";
        }

        var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer response.deinit();

        try response.writer().print("Focus mode: \"{s}\"\n\n", .{task});
        try response.writer().print("Tiniest first step (5 min):\n", .{});
        try response.writer().print("→ {s}\n\n", .{first_step});
        try response.writer().print("Ready?\n", .{});

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleSimplify(ctx: *ExecutionContext) !SkillResult {
        const task = ctx.args orelse return error.MissingArgument;

        var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer response.deinit();

        try response.writer().print("Simplified:\n", .{});

        // Simple pattern matching for common scenarios
        if (std.mem.indexOf(u8, task, "SSL") != null or std.mem.indexOf(u8, task, "ssl") != null) {
            try response.writer().print("1. Deploy to Vercel (handles SSL)\n", .{});
            try response.writer().print("2. Add Vercel Analytics (monitoring)\n", .{});
            try response.writer().print("3. Enable auto-scaling (Vercel default)\n\n", .{});
            try response.writer().print("One command: `vercel --prod`\n\n", .{});
            try response.writer().print("Ready to deploy?\n", .{});
        } else if (std.mem.indexOf(u8, task, "CI") != null or std.mem.indexOf(u8, task, "ci") != null) {
            try response.writer().print("1. Create .github/workflows/ci.yml\n", .{});
            try response.writer().print("2. Copy from GitHub Actions template\n", .{});
            try response.writer().print("3. Push to trigger\n\n", .{});
            try response.writer().print("I can create the file for you. Ready?\n", .{});
        } else {
            try response.writer().print("1. What's the main goal?\n", .{});
            try response.writer().print("2. What's blocking you?\n", .{});
            try response.writer().print("3. What's the smallest step forward?\n\n", .{});
            try response.writer().print("Let's just do step 3. That's it.\n", .{});
        }

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    fn handleHelp(ctx: *ExecutionContext) !SkillResult {
        var response = std.ArrayList(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer response.deinit();

        try response.writer().print("ADHD-Friendly Workflow Commands:\n\n", .{});
        try response.writer().print("breakdown <task>  - Break down a large task into small steps\n", .{});
        try response.writer().print("chunk <task>      - Alias for breakdown\n", .{});
        try response.writer().print("focus <task>      - Enter focus mode for a task\n", .{});
        try response.writer().print("simplify <task>   - Simplify a complex task\n\n", .{});
        try response.writer().print("Core Principles:\n", .{});
        try response.writer().print("• Break it down — Big tasks paralyze. Small steps flow.\n", .{});
        try response.writer().print("• Reduce friction — Every extra step is a dropout point.\n", .{});
        try response.writer().print("• Externalize memory — Write everything down.\n", .{});
        try response.writer().print("• Capture momentum — When flow happens, protect it.\n", .{});
        try response.writer().print("• Acknowledge struggle — Writing is harder than coding.\n", .{});

        return SkillResult{
            .success = true,
            .message = response.toOwnedSlice(),
            .data = null,
        };
    }

    pub fn deinit(allocator: Allocator) void {
        if (config.user_name.len > 0 and !std.mem.eql(u8, config.user_name, "Baala")) {
            allocator.free(config.user_name);
        }
        if (config.memory_file.len > 0 and !std.mem.eql(u8, config.memory_file, "memory/YYYY-MM-DD.md")) {
            allocator.free(config.memory_file);
        }
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return sdk.SkillMetadata{
            .name = "adhd-workflow",
            .version = "1.0.0",
            .description = "ADHD-friendly task execution — break down work, reduce friction, maintain focus.",
            .author = "Baala Kataru",
            .category = "workflow",
            .triggers = &[_]types.Trigger{
                .{
                    .trigger_type = .mention,
                    .patterns = &[_][]const u8{ "adhd", "overwhelmed", "stuck", "can't focus" },
                },
                .{
                    .trigger_type = .command,
                    .commands = &[_][]const u8{ "breakdown", "chunk", "focus", "simplify" },
                },
                .{
                    .trigger_type = .pattern,
                    .patterns = &[_][]const u8{ ".*too big.*", ".*overwhelm.*", ".*don't know where to start.*", ".*paralyzed.*" },
                },
            },
        };
    }
};
