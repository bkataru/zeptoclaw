const std = @import("std");
const root = @import("../../root.zig");
const git_workflow = root.skills.git_workflow;
const ExecutionContext = root.skills.execution_context.ExecutionContext;
const ToolRegistry = root.skills.execution_context.ToolRegistry;
const Message = root.providers.types.Message;
const SkillResult = root.skills.execution_context.SkillResult;

test "git_workflow: init with default config" {
    const allocator = std.testing.allocator;
    const config_value = std.json.Value{ .null = {} };

    try git_workflow.skill.init(allocator, config_value);
    defer git_workflow.skill.deinit(allocator);

    // Smoke test: init doesn't crash
}

test "git_workflow: init with custom config" {
    const allocator = std.testing.allocator;

    var obj = std.StringArrayHashMap(std.json.Value).init(allocator);
    defer obj.deinit();
    try obj.put("default_branch", std.json.Value{ .string = "develop" });
    try obj.put("enable_rebase", std.json.Value{ .bool = false });
    try obj.put("force_push_protection", std.json.Value{ .bool = false });
    const config_value = std.json.Value{ .object = obj };

    try git_workflow.skill.init(allocator, config_value);
    defer git_workflow.skill.deinit(allocator);
}

test "git_workflow: /git-status returns status" {
    const allocator = std.testing.allocator;

    try git_workflow.skill.init(allocator, std.json.Value{ .null = {} });
    defer git_workflow.skill.deinit(allocator);

    const skill_metadata = git_workflow.skill.getMetadata();

    var message = Message{
        .role = .user,
        .content = try allocator.dupe(u8, "/git-status"),
        .tool_call_id = null,
        .tool_calls = null,
    };
    defer message.deinit(allocator);

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var ctx = ExecutionContext.init(
        allocator,
        skill_metadata,
        message,
        "test-session",
        .{ .null = {} },
        &tool_registry,
        testSendResponse,
    );

    var result = try git_workflow.skill.execute(&ctx);
    defer result.deinit(allocator);

    try std.testing.expectEqual(true, result.success);
    try std.testing.expect(result.response != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Git Status") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "On branch main") != null);
    try std.testing.expectEqual(true, result.should_continue);
}

test "git_workflow: /git-commit with empty message returns error" {
    const allocator = std.testing.allocator;

    try git_workflow.skill.init(allocator, std.json.Value{ .null = {} });
    defer git_workflow.skill.deinit(allocator);

    const skill_metadata = git_workflow.skill.getMetadata();

    var message = Message{
        .role = .user,
        .content = try allocator.dupe(u8, "/git-commit"),
        .tool_call_id = null,
        .tool_calls = null,
    };
    defer message.deinit(allocator);

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var ctx = ExecutionContext.init(
        allocator,
        skill_metadata,
        message,
        "test-session",
        .{ .null = {} },
        &tool_registry,
        testSendResponse,
    );

    var result = try git_workflow.skill.execute(&ctx);
    defer result.deinit(allocator);

    try std.testing.expectEqual(false, result.success);
    try std.testing.expect(result.error_message != null);
    try std.testing.expectEqualStrings("Usage: /git-commit \"<commit message>\"", result.error_message.?);
    try std.testing.expectEqual(true, result.should_continue);
    try std.testing.expect(result.response == null);
}

test "git_workflow: /git-commit with message returns success" {
    const allocator = std.testing.allocator;

    try git_workflow.skill.init(allocator, std.json.Value{ .null = {} });
    defer git_workflow.skill.deinit(allocator);

    const skill_metadata = git_workflow.skill.getMetadata();

    var message = Message{
        .role = .user,
        .content = try allocator.dupe(u8, "/git-commit Fix bug in parser"),
        .tool_call_id = null,
        .tool_calls = null,
    };
    defer message.deinit(allocator);

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var ctx = ExecutionContext.init(
        allocator,
        skill_metadata,
        message,
        "test-session",
        .{ .null = {} },
        &tool_registry,
        testSendResponse,
    );

    var result = try git_workflow.skill.execute(&ctx);
    defer result.deinit(allocator);

    try std.testing.expectEqual(true, result.success);
    try std.testing.expect(result.response != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Committed changes") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Fix bug in parser") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Branch: main") != null);
    try std.testing.expectEqual(true, result.should_continue);
}

test "git_workflow: /git-push to default branch with force protection should stop" {
    const allocator = std.testing.allocator;

    try git_workflow.skill.init(allocator, std.json.Value{ .null = {} });
    defer git_workflow.skill.deinit(allocator);

    const skill_metadata = git_workflow.skill.getMetadata();

    var message = Message{
        .role = .user,
        .content = try allocator.dupe(u8, "/git-push"),
        .tool_call_id = null,
        .tool_calls = null,
    };
    defer message.deinit(allocator);

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var ctx = ExecutionContext.init(
        allocator,
        skill_metadata,
        message,
        "test-session",
        .{ .null = {} },
        &tool_registry,
        testSendResponse,
    );

    var result = try git_workflow.skill.execute(&ctx);
    defer result.deinit(allocator);

    try std.testing.expectEqual(true, result.success);
    try std.testing.expect(result.response != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Force-push protection enabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "shared branch") != null);
    try std.testing.expectEqual(false, result.should_continue);
}

test "git_workflow: /git-push to feature branch with force protection should succeed" {
    const allocator = std.testing.allocator;

    try git_workflow.skill.init(allocator, std.json.Value{ .null = {} });
    defer git_workflow.skill.deinit(allocator);

    const skill_metadata = git_workflow.skill.getMetadata();

    var message = Message{
        .role = .user,
        .content = try allocator.dupe(u8, "/git-push feature/new-feature"),
        .tool_call_id = null,
        .tool_calls = null,
    };
    defer message.deinit(allocator);

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var ctx = ExecutionContext.init(
        allocator,
        skill_metadata,
        message,
        "test-session",
        .{ .null = {} },
        &tool_registry,
        testSendResponse,
    );

    var result = try git_workflow.skill.execute(&ctx);
    defer result.deinit(allocator);

    try std.testing.expectEqual(true, result.success);
    try std.testing.expect(result.response != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Pushing to remote") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "feature/new-feature") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Push successful") != null);
    try std.testing.expectEqual(true, result.should_continue);
}

test "git_workflow: /git-push without force protection on default branch should succeed" {
    const allocator = std.testing.allocator;

    var obj = std.StringArrayHashMap(std.json.Value).init(allocator);
    defer obj.deinit();
    try obj.put("force_push_protection", std.json.Value{ .bool = false });
    const config_value = std.json.Value{ .object = obj };

    try git_workflow.skill.init(allocator, config_value);
    defer git_workflow.skill.deinit(allocator);

    const skill_metadata = git_workflow.skill.getMetadata();

    var message = Message{
        .role = .user,
        .content = try allocator.dupe(u8, "/git-push"),
        .tool_call_id = null,
        .tool_calls = null,
    };
    defer message.deinit(allocator);

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var ctx = ExecutionContext.init(
        allocator,
        skill_metadata,
        message,
        "test-session",
        .{ .null = {} },
        &tool_registry,
        testSendResponse,
    );

    var result = try git_workflow.skill.execute(&ctx);
    defer result.deinit(allocator);

    try std.testing.expectEqual(true, result.success);
    try std.testing.expect(result.response != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Pushing to remote") != null);
    try std.testing.expectEqual(true, result.should_continue);
}

test "git_workflow: /git-pull returns success" {
    const allocator = std.testing.allocator;

    try git_workflow.skill.init(allocator, std.json.Value{ .null = {} });
    defer git_workflow.skill.deinit(allocator);

    const skill_metadata = git_workflow.skill.getMetadata();

    var message = Message{
        .role = .user,
        .content = try allocator.dupe(u8, "/git-pull"),
        .tool_call_id = null,
        .tool_calls = null,
    };
    defer message.deinit(allocator);

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var ctx = ExecutionContext.init(
        allocator,
        skill_metadata,
        message,
        "test-session",
        .{ .null = {} },
        &tool_registry,
        testSendResponse,
    );

    var result = try git_workflow.skill.execute(&ctx);
    defer result.deinit(allocator);

    try std.testing.expectEqual(true, result.success);
    try std.testing.expect(result.response != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Pulling from remote") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "rebase") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Pull successful") != null);
    try std.testing.expectEqual(true, result.should_continue);
}

test "git_workflow: /git-branch without args lists branches" {
    const allocator = std.testing.allocator;

    try git_workflow.skill.init(allocator, std.json.Value{ .null = {} });
    defer git_workflow.skill.deinit(allocator);

    const skill_metadata = git_workflow.skill.getMetadata();

    var message = Message{
        .role = .user,
        .content = try allocator.dupe(u8, "/git-branch"),
        .tool_call_id = null,
        .tool_calls = null,
    };
    defer message.deinit(allocator);

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var ctx = ExecutionContext.init(
        allocator,
        skill_metadata,
        message,
        "test-session",
        .{ .null = {} },
        &tool_registry,
        testSendResponse,
    );

    var result = try git_workflow.skill.execute(&ctx);
    defer result.deinit(allocator);

    try std.testing.expectEqual(true, result.success);
    try std.testing.expect(result.response != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "* main") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "feature/new-feature") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Remotes") != null);
    try std.testing.expectEqual(true, result.should_continue);
}

test "git_workflow: /git-branch with arg creates branch" {
    const allocator = std.testing.allocator;

    try git_workflow.skill.init(allocator, std.json.Value{ .null = {} });
    defer git_workflow.skill.deinit(allocator);

    const skill_metadata = git_workflow.skill.getMetadata();

    var message = Message{
        .role = .user,
        .content = try allocator.dupe(u8, "/git-branch feature/test-branch"),
        .tool_call_id = null,
        .tool_calls = null,
    };
    defer message.deinit(allocator);

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var ctx = ExecutionContext.init(
        allocator,
        skill_metadata,
        message,
        "test-session",
        .{ .null = {} },
        &tool_registry,
        testSendResponse,
    );

    var result = try git_workflow.skill.execute(&ctx);
    defer result.deinit(allocator);

    try std.testing.expectEqual(true, result.success);
    try std.testing.expect(result.response != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Created new branch") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "feature/test-branch") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Based on: main") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.response.?, "Switched to new branch 'feature/test-branch'") != null);
    try std.testing.expectEqual(true, result.should_continue);
}

test "git_workflow: unknown message returns empty success" {
    const allocator = std.testing.allocator;

    try git_workflow.skill.init(allocator, std.json.Value{ .null = {} });
    defer git_workflow.skill.deinit(allocator);

    const skill_metadata = git_workflow.skill.getMetadata();

    var message = Message{
        .role = .user,
        .content = try allocator.dupe(u8, "/unknown-command"),
        .tool_call_id = null,
        .tool_calls = null,
    };
    defer message.deinit(allocator);

    var tool_registry = ToolRegistry.init(allocator);
    defer tool_registry.deinit();

    var ctx = ExecutionContext.init(
        allocator,
        skill_metadata,
        message,
        "test-session",
        .{ .null = {} },
        &tool_registry,
        testSendResponse,
    );

    var result = try git_workflow.skill.execute(&ctx);
    defer result.deinit(allocator);

    try std.testing.expectEqual(true, result.success);
    try std.testing.expect(result.response != null);
    try std.testing.expectEqualStrings("", result.response.?);
    try std.testing.expectEqual(true, result.should_continue);
}

test "git_workflow: getMetadata returns correct values" {
    const allocator = std.testing.allocator;
    _ = allocator;

    const metadata = git_workflow.skill.getMetadata();

    try std.testing.expectEqualStrings("git-workflow", metadata.id);
    try std.testing.expectEqualStrings("Git Workflow", metadata.name);
    try std.testing.expectEqualStrings("1.0.0", metadata.version.?);
    try std.testing.expectEqualStrings("Git advanced workflows — rebase, force-push safety, branch management, PR templates", metadata.description);
    try std.testing.expect(metadata.homepage == null);
    try std.testing.expect(metadata.enabled);
}

// Test helper
fn testSendResponse(ctx: *ExecutionContext, response: []const u8) anyerror!void {
    _ = ctx;
    _ = response;
}
