const std = @import("std");
const ConfigLoader = @import("migration_config.zig").ConfigLoader;
const ZeptoClawConfig = @import("migration_config.zig").ZeptoClawConfig;
const ConfigSource = @import("migration_config.zig").ConfigSource;

test "ConfigLoader.load file not found - no leak" {
    const allocator = std.testing.allocator;
    var loader = ConfigLoader.init(allocator);

    const result = loader.load(.{ .config_file = "nonexistent_file_xyz.json" });
    try std.testing.expectError(error.FileNotFound, result);
}

test "ConfigLoader.load invalid JSON - no leak" {
    const allocator = std.testing.allocator;
    var loader = ConfigLoader.init(allocator);

    const temp_dir = std.fs.cwd();
    const config_path = "test_invalid_config.json";

    const malformed_json = "{\"invalid\": json}";
    const file = try temp_dir.createFile(config_path, .{});
    file.writeAll(malformed_json) catch @panic("cannot write test file");
    file.close();

    const result = loader.load(.{ .config_file = config_path });
    try std.testing.expectError(error.SyntaxError, result);

    temp_dir.deleteFile(config_path) catch {};
}

test "ConfigLoader.load allocation failure - no leak" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const inner_allocator = gpa.allocator();

    const temp_dir = std.fs.cwd();
    const config_path = "test_oom_config.json";

    const json_content = "{\"env\":{\"NVIDIA_API_KEY\":\"test-key\"},\"agents\":{\"defaults\":{\"model\":{\"primary\":\"model\"},\"imageModel\":{\"primary\":\"image\"},\"workspace\":\"/tmp\"}},\"gateway\":{\"port\":18789,\"mode\":\"local\",\"bind\":\"lan\"}}";
    const file = try temp_dir.createFile(config_path, .{});
    file.writeAll(json_content) catch @panic("cannot write test file");
    file.close();

    var failing_allocator = std.testing.FailingAllocator.init(inner_allocator, .{ .fail_index = 1 });
    var loader = ConfigLoader.init(failing_allocator.allocator());

    const result = loader.load(.{ .config_file = config_path });
    try std.testing.expectError(error.OutOfMemory, result);

    temp_dir.deleteFile(config_path) catch {};
    _ = gpa.deinit();
}

test "ConfigLoader.load missing API key" {
    const allocator = std.testing.allocator;
    var loader = ConfigLoader.init(allocator);

    // Test that missing API key returns proper error
    const result = loader.load(null);
    try std.testing.expectError(error.MissingApiKey, result);
}

test "ConfigLoader.load config path is a directory - error" {
    const allocator = std.testing.allocator;
    var loader = ConfigLoader.init(allocator);

    const temp_dir = std.fs.cwd();
    const dir_path = "test_dir_for_config";
    // Create a temporary directory
    temp_dir.makeDir(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    defer temp_dir.deleteDir(dir_path) catch {};

    const result = loader.load(.{ .config_file = dir_path });
    try std.testing.expectError(error.IsDir, result);
}
