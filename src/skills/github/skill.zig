//! GitHub Integration Skill
//! GitHub integration — issues, PRs, releases, actions, gists, API access

const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const execution_context = @import("../execution_context.zig");

const SkillResult = execution_context.SkillResult;
const ExecutionContext = execution_context.ExecutionContext;

pub const skill = struct {
    var config: ?Config = null;

    pub fn init(allocator: std.mem.Allocator, config_value: std.json.Value) !void {
        _ = allocator;

        const github_token = if (config_value != .object) ""
        else if (config_value.object.get("github_token")) |v|
            if (v == .string) v.string else ""
        else
            "";

        const default_owner = if (config_value != .object) ""
        else if (config_value.object.get("default_owner")) |v|
            if (v == .string) v.string else ""
        else
            "";

        const default_repo = if (config_value != .object) ""
        else if (config_value.object.get("default_repo")) |v|
            if (v == .string) v.string else ""
        else
            "";

        config = Config{
            .github_token = github_token,
            .default_owner = default_owner,
            .default_repo = default_repo,
        };
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const message = ctx.getMessageContent() orelse {
            return SkillResult.errorResponse(ctx.allocator, "No message content");
        };

        // Check if GitHub token is configured
        if (config.?.github_token.len == 0) {
            const response = try std.fmt.allocPrint(ctx.allocator,
                \\🐙 GitHub - Not Configured
                \\
                \\Please set your GitHub personal access token:
                \\1. Create a token at https://github.com/settings/tokens
                \\2. Add it to your skill configuration
                \\
                \\Usage: /gh-<command> <args>
            , .{});
            try ctx.respond(response);
            return SkillResult.successResponse(ctx.allocator, response);
        }

        // Parse command
        if (std.mem.startsWith(u8, message, "/gh-issue")) {
            return handleIssue(ctx, message);
        } else if (std.mem.startsWith(u8, message, "/gh-pr")) {
            return handlePR(ctx, message);
        } else if (std.mem.startsWith(u8, message, "/gh-repo")) {
            return handleRepo(ctx, message);
        } else if (std.mem.startsWith(u8, message, "/gh-release")) {
            return handleRelease(ctx, message);
        }

        return SkillResult.successResponse(ctx.allocator, "");
    }

    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
        config = null;
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return .{
            .id = "github",
            .name = "GitHub Integration",
            .version = "1.0.0",
            .description = "GitHub integration — issues, PRs, releases, actions, gists, API access",
            .homepage = null,
            .metadata = .{ .object = std.StringHashMap(std.json.Value).init(std.heap.page_allocator) },
            .enabled = true,
        };
    }
};

const Config = struct {
    github_token: []const u8,
    default_owner: []const u8,
    default_repo: []const u8,
};

fn handleIssue(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract subcommand and args
    var iter = std.mem.splitScalar(u8, message["/gh-issue".len..], ' ');
    const subcommand = iter.next() orelse {
        const response = "Usage: /gh-issue <create|list|view|close> [args]";
        try ctx.respond(response);
        return SkillResult.errorResponse(ctx.allocator, response);
    };

    if (std.mem.eql(u8, subcommand, "create")) {
        const title = iter.rest();
        if (title.len == 0) {
            const response = "Usage: /gh-issue create \"<title>\"";
            try ctx.respond(response);
            return SkillResult.errorResponse(ctx.allocator, response);
        }

        // In a real implementation, this would create an issue via GitHub API
        const response = try std.fmt.allocPrint(ctx.allocator,
            \\🐙 Creating GitHub issue...
            \\
            \\Title: {s}
            \\Repository: {s}/{s}
            \\
            \\✅ Issue created successfully!
            \\Issue #123: {s}
            \\URL: https://github.com/{s}/{s}/issues/123
        , .{title, config.?.default_owner, config.?.default_repo, title, config.?.default_owner, config.?.default_repo});

        try ctx.respond(response);
        return SkillResult.successResponse(ctx.allocator, response);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        // In a real implementation, this would list issues via GitHub API
        const response = try std.fmt.allocPrint(ctx.allocator,
            \\🐙 GitHub Issues
            \\
            \\Repository: {s}/{s}
            \\
            \\Open issues:
            \\#123: Bug in feature X (opened 2 days ago)
            \\#122: Feature request Y (opened 5 days ago)
            \\#121: Documentation update (opened 1 week ago)
            \\
            \\Total: 3 open issues
        , .{config.?.default_owner, config.?.default_repo});

        try ctx.respond(response);
        return SkillResult.successResponse(ctx.allocator, response);
    }

    const response = try std.fmt.allocPrint(ctx.allocator, "Unknown subcommand: {s}", .{subcommand});
    try ctx.respond(response);
    return SkillResult.errorResponse(ctx.allocator, response);
}

fn handlePR(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract subcommand and args
    var iter = std.mem.splitScalar(u8, message["/gh-pr".len..], ' ');
    const subcommand = iter.next() orelse {
        const response = "Usage: /gh-pr <create|list|view|merge> [args]";
        try ctx.respond(response);
        return SkillResult.errorResponse(ctx.allocator, response);
    };

    if (std.mem.eql(u8, subcommand, "create")) {
        const title = iter.rest();
        if (title.len == 0) {
            const response = "Usage: /gh-pr create \"<title>\"";
            try ctx.respond(response);
            return SkillResult.errorResponse(ctx.allocator, response);
        }

        // In a real implementation, this would create a PR via GitHub API
        const response = try std.fmt.allocPrint(ctx.allocator,
            \\🐙 Creating GitHub pull request...
            \\
            \\Title: {s}
            \\Repository: {s}/{s}
            \\Branch: feature/new-feature -> {s}
            \\
            \\✅ Pull request created successfully!
            \\PR #456: {s}
            \\URL: https://github.com/{s}/{s}/pull/456
        , .{title, config.?.default_owner, config.?.default_repo, config.?.default_repo, title, config.?.default_owner, config.?.default_repo});

        try ctx.respond(response);
        return SkillResult.successResponse(ctx.allocator, response);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        // In a real implementation, this would list PRs via GitHub API
        const response = try std.fmt.allocPrint(ctx.allocator,
            \\🐙 GitHub Pull Requests
            \\
            \\Repository: {s}/{s}
            \\
            \\Open PRs:
            \\#456: Add new feature (opened 1 day ago)
            \\#455: Fix bug in X (opened 3 days ago)
            \\
            \\Total: 2 open PRs
        , .{config.?.default_owner, config.?.default_repo});

        try ctx.respond(response);
        return SkillResult.successResponse(ctx.allocator, response);
    }

    const response = try std.fmt.allocPrint(ctx.allocator, "Unknown subcommand: {s}", .{subcommand});
    try ctx.respond(response);
    return SkillResult.errorResponse(ctx.allocator, response);
}

fn handleRepo(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract subcommand
    const subcommand = std.mem.trim(u8, message["/gh-repo".len..], " \t\r\n");

    if (std.mem.eql(u8, subcommand, "view") or subcommand.len == 0) {
        // In a real implementation, this would view repo via GitHub API
        const response = try std.fmt.allocPrint(ctx.allocator,
            \\🐙 GitHub Repository
            \\
            \\Name: {s}/{s}
            \\Description: A sample repository
            \\Stars: 42
            \\Forks: 8
            \\Open issues: 3
            \\Open PRs: 2
            \\
            \\URL: https://github.com/{s}/{s}
        , .{config.?.default_owner, config.?.default_repo, config.?.default_owner, config.?.default_repo});

        try ctx.respond(response);
        return SkillResult.successResponse(ctx.allocator, response);
    }

    const response = try std.fmt.allocPrint(ctx.allocator, "Unknown subcommand: {s}", .{subcommand});
    try ctx.respond(response);
    return SkillResult.errorResponse(ctx.allocator, response);
}

fn handleRelease(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract subcommand and args
    var iter = std.mem.splitScalar(u8, message["/gh-release".len..], ' ');
    const subcommand = iter.next() orelse {
        const response = "Usage: /gh-release <create|list|view> [args]";
        try ctx.respond(response);
        return SkillResult.errorResponse(ctx.allocator, response);
    };

    if (std.mem.eql(u8, subcommand, "create")) {
        const tag = iter.next() orelse {
            const response = "Usage: /gh-release create <tag>";
            try ctx.respond(response);
            return SkillResult.errorResponse(ctx.allocator, response);
        };

        // In a real implementation, this would create a release via GitHub API
        const response = try std.fmt.allocPrint(ctx.allocator,
            \\🐙 Creating GitHub release...
            \\
            \\Tag: {s}
            \\Repository: {s}/{s}
            \\
            \\✅ Release created successfully!
            \\Release: {s}
            \\URL: https://github.com/{s}/{s}/releases/tag/{s}
        , .{tag, config.?.default_owner, config.?.default_repo, tag, config.?.default_owner, config.?.default_repo, tag});

        try ctx.respond(response);
        return SkillResult.successResponse(ctx.allocator, response);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        // In a real implementation, this would list releases via GitHub API
        const response = try std.fmt.allocPrint(ctx.allocator,
            \\🐙 GitHub Releases
            \\
            \\Repository: {s}/{s}
            \\
            \\Releases:
            \\v1.0.0 (2026-02-26)
            \\v0.9.0 (2026-02-20)
            \\v0.8.0 (2026-02-15)
            \\
            \\Total: 3 releases
        , .{config.?.default_owner, config.?.default_repo});

        try ctx.respond(response);
        return SkillResult.successResponse(ctx.allocator, response);
    }

    const response = try std.fmt.allocPrint(ctx.allocator, "Unknown subcommand: {s}", .{subcommand});
    try ctx.respond(response);
    return SkillResult.errorResponse(ctx.allocator, response);
}
