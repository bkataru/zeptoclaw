const std = @import("std");
const builtin = @import("builtin");

/// Memory: Caller owns `{HOME}/{rel}`.
pub fn homeJoin(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const home = getEnvVarOwned(allocator, "HOME") catch try allocator.dupe(u8, ".");
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, rel });
}

/// Memory: Caller owns returned slice; call `allocator.free()` to free.
pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    if (comptime @hasDecl(std.process, "getEnvVarOwned")) {
        return try std.process.getEnvVarOwned(allocator, key);
    } else {
        const key_z = try allocator.dupeZ(u8, key);
        defer allocator.free(key_z);
        if (std.c.getenv(key_z.ptr)) |val| {
            return try allocator.dupe(u8, std.mem.span(val));
        }
        return error.EnvironmentVariableNotFound;
    }
}

pub fn getSelfExeDir(allocator: std.mem.Allocator) ![]u8 {
    // Zig 0.16: executableDirPathAlloc(io, allocator). Older: selfExeDirPath.
    if (comptime @hasDecl(std.process, "executableDirPathAlloc")) {
        return try std.process.executableDirPathAlloc(getIo(), allocator);
    }
    if (comptime @hasDecl(std.process, "selfExeDirPath")) {
        return try std.process.selfExeDirPath(allocator);
    }
    // Fallback: read /proc/self/exe (Linux)
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const len_raw = std.c.readlink("/proc/self/exe", &buf, buf.len);
    if (len_raw < 0) return try allocator.dupe(u8, ".");
    const len: usize = @intCast(len_raw);
    const exe_path = buf[0..len];
    return try allocator.dupe(u8, std.fs.path.dirname(exe_path) orelse ".");
}

/// Memory: Caller owns returned slice; call `freeArgs(allocator, args)` to free.
pub fn getArgsAlloc(allocator: std.mem.Allocator) ![][:0]const u8 {
    if (comptime @hasDecl(std.process, "argsAlloc")) {
        return try std.process.argsAlloc(allocator);
    }
    return try allocator.alloc([:0]const u8, 0);
}

/// Memory: Callee takes ownership of `args` and frees it.
pub fn freeArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) void {
    if (comptime @hasDecl(std.process, "argsFree")) {
        std.process.argsFree(allocator, args);
        return;
    }
    allocator.free(args);
}

pub fn timestamp() i64 {
    if (comptime @hasDecl(std.time, "timestamp")) {
        return std.time.timestamp();
    } else {
        var ts: std.posix.timespec = undefined;
        _ = std.c.clock_gettime(@as(std.c.clockid_t, @enumFromInt(0)), &ts);
        return @as(i64, ts.sec);
    }
}

pub const Dir = struct {
    io: std.Io,
    dir: std.Io.Dir,
    pub fn openFile(self: Dir, path: []const u8, opts: std.Io.Dir.OpenFileOptions) !std.Io.File {
        return try self.dir.openFile(self.io, path, opts);
    }
    pub fn createFile(self: Dir, path: []const u8, opts: std.Io.Dir.CreateFileOptions) !std.Io.File {
        return try self.dir.createFile(self.io, path, opts);
    }
    pub fn makePath(self: Dir, path: []const u8) !void {
        try self.dir.createDir(self.io, path, .default_dir);
    }
    pub fn makeOpenPath(self: Dir, path: []const u8, opts: anytype) !std.Io.Dir {
        _ = opts;
        // Handle absolute paths (common for sessions_dir)
        if (path.len > 0 and path[0] == '/') {
            std.Io.Dir.createDirAbsolute(self.io, path, .default_dir) catch |e| { if (e != error.PathAlreadyExists) return e; };
            return try std.Io.Dir.openDirAbsolute(self.io, path, .{});
        }
        self.dir.createDir(self.io, path, .default_dir) catch |e| { if (e != error.PathAlreadyExists) return e; };
        return try self.dir.openDir(self.io, path, .{});
    }
    pub fn readFileAlloc(self: Dir, allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
        const file = try self.dir.openFile(self.io, path, .{ .mode = .read_only });
        defer file.close(self.io);
        var reader = file.reader(self.io, &[_]u8{});
        const data = try reader.interface.allocRemaining(allocator, .limited(max));
        return data;
    }
};

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn getIo() std.Io {
    return io();
}

pub fn cwd() Dir {
    const _io = io();
    return .{ .io = _io, .dir = std.Io.Dir.cwd() };
}

pub fn streamWriteAll(stream: std.Io.net.Stream, data: []const u8) !void {
    const _io_val = getIo();
    var buf: [4096]u8 = undefined;
    var writer = stream.writer(_io_val, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}
