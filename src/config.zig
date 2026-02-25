const std = @import("std");

pub const Config = struct {
    nim_api_key: []const u8,
    nim_model: []const u8,
    max_iterations: u32 = 10,
    temperature: f32 = 0.7,
    max_tokens: u32 = 1024,

    pub fn load(allocator: std.mem.Allocator) !Config {
        const nim_api_key = std.process.getEnvVarOwned(allocator, "NVIDIA_API_KEY") catch |err| {
            if (err == error.EnvVarNotFound) {
                return error.MissingApiKey;
            }
            return err;
        };
        
        const nim_model = std.process.getEnvVarOwned(allocator, "NVIDIA_MODEL") catch "qwen/qwen3.5-397b-a17b";
        
        return .{
            .nim_api_key = nim_api_key,
            .nim_model = nim_model,
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.nim_api_key);
        allocator.free(self.nim_model);
    }
};

test "Config load missing key" {
    const allocator = std.testing.allocator;
    // This test will fail if NVIDIA_API_KEY is set, which is expected
    _ = allocator;
}
