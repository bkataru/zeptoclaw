const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const utcp_dep = b.dependency("utcp", .{ .target = target, .optimize = optimize });
    const utcp_mod = utcp_dep.module("utcp");

    const mcp_dep = b.dependency("mcp", .{ .target = target, .optimize = optimize });
    const mcp_mod = mcp_dep.module("mcp");

    const raikage_dep = b.dependency("raikage", .{ .target = target, .optimize = optimize });
    const raikage_mod = raikage_dep.module("raikage");

    const hf_hub_dep = b.dependency("hf_hub_zig", .{ .target = target, .optimize = optimize });
    const hf_hub_mod = hf_hub_dep.module("hf-hub");

    const niza_dep = b.dependency("niza", .{ .target = target, .optimize = optimize });
    const niza_mod = niza_dep.module("niza");

    const zenmap_dep = b.dependency("zenmap", .{ .target = target, .optimize = optimize });
    const zenmap_mod = zenmap_dep.module("zenmap");

    const zeitgeist_dep = b.dependency("zeitgeist", .{ .target = target, .optimize = optimize });
    const zeitgeist_mod = zeitgeist_dep.module("zeitgeist");

    const comprezz_dep = b.dependency("comprezz", .{ .target = target, .optimize = optimize });
    const comprezz_mod = comprezz_dep.module("comprezz");

    // Barvis-Zig module
    // Barvis-Zig module
const mod = b.addModule("zeptoclaw", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "utcp", .module = utcp_mod },
            .{ .name = "mcp", .module = mcp_mod },
            .{ .name = "raikage", .module = raikage_mod },
            .{ .name = "hf_hub", .module = hf_hub_mod },
            .{ .name = "niza", .module = niza_mod },
            .{ .name = "zenmap", .module = zenmap_mod },
            .{ .name = "zeitgeist", .module = zeitgeist_mod },
            .{ .name = "comprezz", .module = comprezz_mod },
        },
    });

    // Main executable module
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
      .{ .name = "zeptoclaw", .module = mod },
            .{ .name = "utcp", .module = utcp_mod },
            .{ .name = "mcp", .module = mcp_mod },
            .{ .name = "raikage", .module = raikage_mod },
            .{ .name = "hf_hub", .module = hf_hub_mod },
            .{ .name = "niza", .module = niza_mod },
            .{ .name = "zenmap", .module = zenmap_mod },
            .{ .name = "zeitgeist", .module = zeitgeist_mod },
            .{ .name = "comprezz", .module = comprezz_mod },
        },
    });

    const exe = b.addExecutable(.{
      .name = "zeptoclaw",
        .root_module = main_mod,
    });

    b.installArtifact(exe);

    // Run command
    const run_step = b.step("run", "Run Barvis agent");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
