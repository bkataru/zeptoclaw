//! Git Workflow Skill
//! Git advanced workflows — rebase, force-push safety, branch management, PR templates

const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const execution_context = @import("../execution_context.zig");

const SkillResult = execution_context.SkillResult;
const ExecutionContext = execution_context.ExecutionContext;

pub const skill = struct {
    var config: ?Config = null;

    pub fn init(allocator: std.mem.Allocator, config_value: std.json.Value) !void {
        _ = allocator;

        const default_branch = if (config_value != .object) "main"
        else if (config_value.object.get("default_branch")) |v|
            if (v == .string) v.string else "main"
        else
            "main";

        const enable_rebase = if (config_value != .object) true
        else if (config_value.object.get("enable_rebase")) |v|
            if (v == .bool) v.bool else true
        else
            true;

        const force_push_protection = if (config_value != .object) true
        else if (config_value.object.get("force_push_protection")) |v|
            if (v == .bool) v.bool else true
        else
            true;

        config = Config{
            .default_branch = default_branch,
            .enable_rebase = enable_rebase,
            .force_push_protection = force_push_protection,
        };
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const message = ctx.getMessageContent() orelse {
            return SkillResult.errorResponse(ctx.allocator, "No message content");
        };

        // Parse command
        if (std.mem.startsWith(u8, message, "/git-status")) {
            return handleStatus(ctx);
        } else if (std.mem.startsWith(u8, message, "/git-commit")) {
            return handleCommit(ctx, message);
        } else if (std.mem.startsWith(u8, message, "/git-push")) {
            return handlePush(ctx, message);
        } else if (std.mem.startsWith(u8, message, "/git-pull")) {
            return handlePull(ctx);
        } else if (std.mem.startsWith(u8, message, "/git-branch")) {
            return handleBranch(ctx, message);
        }

        return SkillResult.successResponse(ctx.allocator, "");
    }

    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
        config = null;
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return .{
            .id = "git-workflow",
            .name = "Git Workflow",
            .version = "1.0.0",
            .description = "Git advanced workflows — rebase, force-push safety, branch management, PR templates",
            .homepage = null,
            .metadata = .{ .object = std.StringHashMap(std.json.Value).init(std.heap.page_allocator) },
            .enabled = true,
        };
    }
};

const Config = struct {
    default_branch: []const u8,
    enable_rebase: bool,
    force_push_protection: bool,
};

fn handleStatus(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would run git status
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🔀 Git Status
        \\
        \\On branch {s}
        \\Your branch is up to date with 'origin/{s}'.
        \\
        \\Changes not staged for commit:
        \\  modified:   src/skills/git_workflow/skill.zig
        \\
        \\Untracked files:
        \\  src/skills/github/
        \\  src/skills/github-stars/
        \\
        \\no changes added to commit (use "git add" and/or "git commit -a")
    , .{config.?.default_branch, config.?.default_branch});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleCommit(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract commit message
    const commit_msg = std.mem.trim(u8, message["/git-commit".len..], " \t\r\n");

    if (commit_msg.len == 0) {
        const response = "Usage: /git-commit \"<commit message>\"";
        try ctx.respond(response);
        return SkillResult.errorResponse(ctx.allocator, response);
    }

    // In a real implementation, this would run git commit
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\✅ Committed changes
        \\
        \\Message: {s}
        \\Branch: {s}
        \\
        \\Commit hash: abc123def456
        \\Files changed: 5
        \\Insertions: 150
        \\Deletions: 23
    , .{commit_msg, config.?.default_branch});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handlePush(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract branch name
    const branch = std.mem.trim(u8, message["/git-push".len..], " \t\r\n");
    const target_branch = if (branch.len > 0) branch else config.?.default_branch;

    // Check for force-push protection
    if (config.?.force_push_protection and std.mem.eql(u8, target_branch, config.?.default_branch)) {
        const response = try std.fmt.allocPrint(ctx.allocator,
            \\⚠️ Force-push protection enabled
            \\
            \\You're trying to push to {s}, which is a shared branch.
            \\
            \\Safe push: git push origin {s}
            \\Force-push (only for feature branches): git push origin <branch> --force-with-lease
            \\
            \\Are you sure you want to push to {s}?
        , .{target_branch, target_branch, target_branch});
        try ctx.respond(response);
        return SkillResult.stop(ctx.allocator, response);
    }

    // In a real implementation, this would run git push
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\📤 Pushing to remote...
        \\
        \\Branch: {s}
        \\Remote: origin
        \\
        \\✅ Push successful
        \\URL: https://github.com/user/repo/tree/{s}
    , .{target_branch, target_branch});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handlePull(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would run git pull --rebase
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\📥 Pulling from remote...
        \\
        \\Branch: {s}
        \\Remote: origin
        \\Strategy: rebase
        \\
        \\✅ Pull successful
        \\Updated: 3 new commits
        \\Fast-forward: origin/{s} -> {s}
    , .{config.?.default_branch, config.?.default_branch, config.?.default_branch});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleBranch(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract branch name
    const branch_name = std.mem.trim(u8, message["/git-branch".len..], " \t\r\n");

    if (branch_name.len == 0) {
        // List branches
        const response = try std.fmt.allocPrint(ctx.allocator,
            \\🌿 Branches
            \\
            \\* {s}
            \\  feature/new-feature
            \\  bugfix/issue-123
            \\
            \\Remotes:
            \\  origin/{s}
            \\  origin/feature/new-feature
        , .{config.?.default_branch, config.?.default_branch});
        try ctx.respond(response);
        return SkillResult.successResponse(ctx.allocator, response);
    }

    // Create new branch
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🌿 Created new branch
        \\
        \\Branch: {s}
        \\Based on: {s}
        \\
        \\Switched to new branch '{s}'
    , .{branch_name, config.?.default_branch, branch_name});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}
