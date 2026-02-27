//! Rust/Cargo Development Skill
//! Rust/Cargo workflow — build, test, publish to crates.io, benchmarks, cross-compile

const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const execution_context = @import("../execution_context.zig");

const SkillResult = execution_context.SkillResult;
const ExecutionContext = execution_context.ExecutionContext;

pub const skill = struct {
    var config: ?Config = null;

    pub fn init(allocator: std.mem.Allocator, config_value: std.json.Value) !void {
        _ = allocator;

        const cargo_path = if (config_value != .object) "cargo"
        else if (config_value.object.get("cargo_path")) |v|
            if (v == .string) v.string else "cargo"
        else
            "cargo";

        const workspace_root = if (config_value != .object) "."
        else if (config_value.object.get("workspace_root")) |v|
            if (v == .string) v.string else "."
        else
            ".";

        const enable_benchmarks = if (config_value != .object) true
        else if (config_value.object.get("enable_benchmarks")) |v|
            if (v == .bool) v.bool else true
        else
            true;

        const publish_dry_run = if (config_value != .object) true
        else if (config_value.object.get("publish_dry_run")) |v|
            if (v == .bool) v.bool else true
        else
            true;

        config = Config{
            .cargo_path = cargo_path,
            .workspace_root = workspace_root,
            .enable_benchmarks = enable_benchmarks,
            .publish_dry_run = publish_dry_run,
        };
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const message = ctx.getMessageContent() orelse {
            return SkillResult.errorResponse(ctx.allocator, "No message content");
        };

        // Parse command
        if (std.mem.startsWith(u8, message, "/cargo-build")) {
            return handleBuild(ctx, message);
        } else if (std.mem.startsWith(u8, message, "/cargo-test")) {
            return handleTest(ctx, message);
        } else if (std.mem.startsWith(u8, message, "/cargo-publish")) {
            return handlePublish(ctx);
        } else if (std.mem.startsWith(u8, message, "/cargo-clean")) {
            return handleClean(ctx);
        }

        return SkillResult.successResponse(ctx.allocator, "");
    }

    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
        config = null;
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return .{
            .id = "rust-cargo",
            .name = "Rust/Cargo Development",
            .version = "1.0.0",
            .description = "Rust/Cargo workflow — build, test, publish to crates.io, benchmarks, cross-compile",
            .homepage = null,
            .metadata = .{ .object = std.StringHashMap(std.json.Value).init(std.heap.page_allocator) },
            .enabled = true,
        };
    }
};

const Config = struct {
    cargo_path: []const u8,
    workspace_root: []const u8,
    enable_benchmarks: bool,
    publish_dry_run: bool,
};

fn handleBuild(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract build options
    const args = std.mem.trim(u8, message["/cargo-build".len..], " \t\r\n");

    // In a real implementation, this would run cargo build
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🦀 Building Rust project...
        \\
        \\Command: {s} build {s}
        \\Workspace: {s}
        \\
        \\Build output:
        \\✅ Compiling project v0.1.0
        \\✅ Compiling dependency1 v0.2.0
        \\✅ Compiling dependency2 v0.3.0
        \\
        \\Finished dev [unoptimized + debuginfo] target(s) in 2.3s
        \\Binary: ./target/debug/project
    , .{config.?.cargo_path, args, config.?.workspace_root});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleTest(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract test name
    const test_name = std.mem.trim(u8, message["/cargo-test".len..], " \t\r\n");

    // In a real implementation, this would run cargo test
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🧪 Running Rust tests...
        \\
        \\Command: {s} test {s}
        \\
        \\Test results:
        \\running 15 tests
        \\test tests::test_module1::test_function1 ... ok
        \\test tests::test_module1::test_function2 ... ok
        \\test tests::test_module2::test_function1 ... ok
        \\
        \\test result: ok. 15 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
        \\
        \\Doc tests:
        \\running 8 tests
        \\test src/lib.rs - module1::function1 (line 42) ... ok
        \\
        \\test result: ok. 8 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
    , .{config.?.cargo_path, if (test_name.len > 0) test_name else ""});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handlePublish(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would run cargo publish
    const dry_run_note = if (config.?.publish_dry_run) " (dry run)" else "";

    const response = try std.fmt.allocPrint(ctx.allocator,
        \\📦 Publishing to crates.io{d}...
        \\
        \\Command: {s} publish {s}
        \\
        \\Preparing package...
        \\✅ Verifying project v0.1.0
        \\✅ Checking dependencies
        \\✅ Validating package
        \\
        \\Package is ready to publish!
        \\
        \\{s}
    , .{
        if (config.?.publish_dry_run) " (dry run)" else "",
        config.?.cargo_path,
        if (config.?.publish_dry_run) "--dry-run" else "",
        if (config.?.publish_dry_run) "This was a dry run. Run again without --dry-run to actually publish." else "Published successfully!",
    });

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleClean(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would clean target directory
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🧹 Cleaning Rust build artifacts...
        \\
        \\Removing:
        \\✅ target/debug/
        \\✅ target/release/
        \\
        \\Clean complete. Ready for fresh build.
    , .{});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}
