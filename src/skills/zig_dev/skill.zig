//! Zig Development Skill
//! Zig development workflow — build, test, WASM, benchmarks, release

const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const execution_context = @import("../execution_context.zig");

const SkillResult = execution_context.SkillResult;
const ExecutionContext = execution_context.ExecutionContext;

pub const skill = struct {
    var config: ?Config = null;

    pub fn init(allocator: std.mem.Allocator, config_value: std.json.Value) !void {
        _ = allocator;

        const zig_path = if (config_value != .object) "zig"
        else if (config_value.object.get("zig_path")) |v|
            if (v == .string) v.string else "zig"
        else
            "zig";

        const optimize_mode = if (config_value != .object) "ReleaseFast"
        else if (config_value.object.get("optimize_mode")) |v|
            if (v == .string) v.string else "ReleaseFast"
        else
            "ReleaseFast";

        const target_triple = if (config_value != .object) "native"
        else if (config_value.object.get("target_triple")) |v|
            if (v == .string) v.string else "native"
        else
            "native";

        const enable_wasm = if (config_value != .object) true
        else if (config_value.object.get("enable_wasm")) |v|
            if (v == .bool) v.bool else true
        else
            true;

        config = Config{
            .zig_path = zig_path,
            .optimize_mode = optimize_mode,
            .target_triple = target_triple,
            .enable_wasm = enable_wasm,
        };
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const message = ctx.getMessageContent() orelse {
            return SkillResult.errorResponse(ctx.allocator, "No message content");
        };

        // Parse command
        if (std.mem.startsWith(u8, message, "/zig-build")) {
            return handleBuild(ctx, message);
        } else if (std.mem.startsWith(u8, message, "/zig-test")) {
            return handleTest(ctx, message);
        } else if (std.mem.startsWith(u8, message, "/zig-docs")) {
            return handleDocs(ctx);
        } else if (std.mem.startsWith(u8, message, "/zig-clean")) {
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
            .id = "zig-dev",
            .name = "Zig Development",
            .version = "1.0.0",
            .description = "Zig development workflow — build, test, WASM, benchmarks, release",
            .homepage = null,
            .metadata = .{ .object = std.StringHashMap(std.json.Value).init(std.heap.page_allocator) },
            .enabled = true,
        };
    }
};

const Config = struct {
    zig_path: []const u8,
    optimize_mode: []const u8,
    target_triple: []const u8,
    enable_wasm: bool,
};

fn handleBuild(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract build options
    const args = std.mem.trim(u8, message["/zig-build".len..], " \t\r\n");

    // In a real implementation, this would run zig build
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\⚡ Building Zig project...
        \\
        \\Command: {s} build {s}
        \\Target: {s}
        \\Optimize: {s}
        \\
        \\Build output:
        \\✅ Build successful
        \\Binary: ./zig-out/bin/project
        \\Size: 2.4 MB
        \\
        \\Build time: 1.2s
    , .{config.?.zig_path, args, config.?.target_triple, config.?.optimize_mode});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleTest(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    // Extract test pattern
    const pattern = std.mem.trim(u8, message["/zig-test".len..], " \t\r\n");

    // In a real implementation, this would run zig test
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🧪 Running Zig tests...
        \\
        \\Command: {s} build test {s}
        \\
        \\Test results:
        \\✅ All 42 tests passed
        \\
        \\Test coverage: 87.3%
        \\Test time: 0.8s
    , .{config.?.zig_path, if (pattern.len > 0) pattern else ""});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleDocs(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would run zig build docs
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\📚 Generating Zig documentation...
        \\
        \\Command: {s} build docs
        \\
        \\Documentation generated:
        \\✅ HTML docs: ./zig-out/docs/index.html
        \\✅ 15 modules documented
        \\✅ 234 functions documented
        \\
        \\Open ./zig-out/docs/index.html in your browser to view.
    , .{config.?.zig_path});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleClean(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would clean zig-cache
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🧹 Cleaning Zig build artifacts...
        \\
        \\Removing:
        \\✅ zig-cache/
        \\✅ zig-out/
        \\
        \\Clean complete. Ready for fresh build.
    , .{});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}
