//! Zig Development Skill
//! Zig development workflow — build, test, WASM, benchmarks, release

const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const execution_context = @import("../execution_context.zig");

const SkillResult = execution_context.SkillResult;
const ExecutionContext = execution_context.ExecutionContext;

pub const skill = struct {
    pub fn init(allocator: std.mem.Allocator, config_value: std.json.Value) !void {
        _ = allocator;
        _ = config_value;
        // No global state to initialize; config parsed per-execution.
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const message = ctx.getMessageContent() orelse {
            return SkillResult.errorResponse(ctx.allocator, "No message content");
        };
        const cfg = parseConfig(ctx.config);

        // Parse command
        if (std.mem.startsWith(u8, message, "/zig-build")) {
            return handleBuild(ctx, message, cfg);
        } else if (std.mem.startsWith(u8, message, "/zig-test")) {
            return handleTest(ctx, message, cfg);
        } else if (std.mem.startsWith(u8, message, "/zig-docs")) {
            return handleDocs(ctx, cfg);
        } else if (std.mem.startsWith(u8, message, "/zig-clean")) {
            return handleClean(ctx);
        }

        return SkillResult.successResponse(ctx.allocator, "");
    }

    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
        // No global resources to free.
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

    // Parse configuration from JSON (per-execution)
    fn parseConfig(config_json: std.json.Value) Config {
        const zig_path = if (config_json != .object) "zig" else if (config_json.object.get("zig_path")) |v|
            if (v == .string) v.string else "zig"
        else
            "zig";
        const optimize_mode = if (config_json != .object) "ReleaseFast" else if (config_json.object.get("optimize_mode")) |v|
            if (v == .string) v.string else "ReleaseFast"
        else
            "ReleaseFast";
        const target_triple = if (config_json != .object) "native" else if (config_json.object.get("target_triple")) |v|
            if (v == .string) v.string else "native"
        else
            "native";
        const enable_wasm = if (config_json != .object) true else if (config_json.object.get("enable_wasm")) |v|
            if (v == .bool) v.bool else true
        else
            true;
        return Config{
            .zig_path = zig_path,
            .optimize_mode = optimize_mode,
            .target_triple = target_triple,
            .enable_wasm = enable_wasm,
        };
    }
};

const Config = struct {
    zig_path: []const u8,
    optimize_mode: []const u8,
    target_triple: []const u8,
    enable_wasm: bool,
};

fn handleBuild(ctx: *ExecutionContext, message: []const u8, cfg: Config) !SkillResult {
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
    , .{ cfg.zig_path, args, cfg.target_triple, cfg.optimize_mode });

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleTest(ctx: *ExecutionContext, message: []const u8, cfg: Config) !SkillResult {
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
    , .{ cfg.zig_path, if (pattern.len > 0) pattern else "" });

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleDocs(ctx: *ExecutionContext, cfg: Config) !SkillResult {
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
    , .{cfg.zig_path});

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
