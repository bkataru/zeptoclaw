const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Load zeitgeist from vendor path
    const zeitgeist_mod = b.addModule("zeitgeist", .{
        .root_source_file = b.path("vendor/zeitgeist/src/lib/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Zeptoclaw module
    const mod = b.addModule("zeptoclaw", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("zeitgeist", zeitgeist_mod);

    // Main executable
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("zeptoclaw", mod);
    main_mod.addImport("zeitgeist", zeitgeist_mod);

    const exe = b.addExecutable(.{
        .name = "zeptoclaw",
        .root_module = main_mod,
    });

    b.installArtifact(exe);

    // Run command
    const run_step = b.step("run", "Run Zeptoclaw agent");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

// Tests
    const test_step = b.step("test", "Run tests");

    const mod_test = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_test = b.addRunArtifact(mod_test);
    test_step.dependOn(&run_mod_test.step);

    const exe_test = b.addTest(.{
        .root_module = main_mod,
    });
    const run_exe_test = b.addRunArtifact(exe_test);
    test_step.dependOn(&run_exe_test.step);

    // Integration tests (optional, requires NVIDIA_API_KEY)
    const integration_test_mod = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_test_mod.addImport("zeptoclaw", mod);
    integration_test_mod.addImport("zeitgeist", zeitgeist_mod);

    const run_integration_test = b.addRunArtifact(integration_test_mod);
    test_step.dependOn(&run_integration_test.step);
}
