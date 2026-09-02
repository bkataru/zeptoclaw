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
    mod.link_libc = true;
    // vendor/sqlite amalgamation (no system sqlite3.h on this host)
    mod.addIncludePath(b.path("vendor/sqlite"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_DQS=0",
        },
    });

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

    exe.root_module.link_libc = true;
    b.installArtifact(exe);
    // Webhook server executable
    const webhook_server_mod = b.createModule(.{
        .root_source_file = b.path("src/services/webhook_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    webhook_server_mod.addImport("zeptoclaw", mod);

    const webhook_server_exe = b.addExecutable(.{
        .name = "zeptoclaw-webhook",
        .root_module = webhook_server_mod,
    });
    webhook_server_exe.root_module.link_libc = true;
    b.installArtifact(webhook_server_exe);

    // Shell2HTTP server executable
    const shell2http_server_mod = b.createModule(.{
        .root_source_file = b.path("src/services/shell2http_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    shell2http_server_mod.addImport("zeptoclaw", mod);

    const shell2http_server_exe = b.addExecutable(.{
        .name = "zeptoclaw-shell2http",
        .root_module = shell2http_server_mod,
    });
    shell2http_server_exe.root_module.link_libc = true;
    b.installArtifact(shell2http_server_exe);

    // Gateway server executable
    const gateway_server_mod = b.createModule(.{
        .root_source_file = b.path("src/gateway/gateway_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    gateway_server_mod.addImport("zeptoclaw", mod);
    gateway_server_mod.addImport("zeitgeist", zeitgeist_mod);

    const gateway_server_exe = b.addExecutable(.{
        .name = "zeptoclaw-gateway",
        .root_module = gateway_server_mod,
    });
    gateway_server_exe.root_module.link_libc = true;
    b.installArtifact(gateway_server_exe);

    // WhatsApp native pairing tool (terminal QR)
    const wa_pair_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/wa_pair.zig"),
        .target = target,
        .optimize = optimize,
    });
    wa_pair_mod.addImport("zeptoclaw", mod);
    const wa_pair_exe = b.addExecutable(.{
        .name = "zeptoclaw-wa-pair",
        .root_module = wa_pair_mod,
    });
    wa_pair_exe.root_module.link_libc = true;
    b.installArtifact(wa_pair_exe);

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

    const integration_test_mod = b.createModule(.{
        .root_source_file = b.path("src/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_test_mod.addImport("zeptoclaw", mod);
    integration_test_mod.addImport("zeitgeist", zeitgeist_mod);
    integration_test_mod.link_libc = true;
    const integration_test_test = b.addTest(.{
        .root_module = integration_test_mod,
    });
    const run_integration_test = b.addRunArtifact(integration_test_test);
    test_step.dependOn(&run_integration_test.step);
}
