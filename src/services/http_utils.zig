//! HTTP Server Utilities
//! Common types and authentication helpers for ZeptoClaw HTTP services

const std = @import("std");

pub const log = std.log.scoped(.http_server);

// ============================================================================
// HTTP Response Types
// ============================================================================

pub const HttpResponse = struct {
    status: u16 = 200,
    content_type: []const u8 = "text/plain",
    body: []const u8 = "",
    owned: bool = false, // Track if body needs to be freed

    pub fn json(allocator: std.mem.Allocator, data: anytype) !HttpResponse {
        const body = try std.json.stringifyAlloc(allocator, data, .{ .whitespace = .indent_2 });
        return .{
            .status = 200,
            .content_type = "application/json",
            .body = body,
            .owned = true,
        };
    }

    pub fn text(allocator: std.mem.Allocator, msg: []const u8) !HttpResponse {
        const body = try allocator.dupe(u8, msg);
        return .{
            .status = 200,
            .content_type = "text/plain",
            .body = body,
            .owned = true,
        };
    }

    pub fn textOwned(body: []const u8) HttpResponse {
        return .{
            .status = 200,
            .content_type = "text/plain",
            .body = body,
            .owned = true,
        };
    }

    pub fn errorResponse(allocator: std.mem.Allocator, status: u16, msg: []const u8) !HttpResponse {
        const body = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{msg});
        return .{
            .status = status,
            .content_type = "application/json",
            .body = body,
            .owned = true,
        };
    }

    pub fn unauthorized(allocator: std.mem.Allocator, msg: []const u8) !HttpResponse {
        return errorResponse(allocator, 401, msg);
    }

    pub fn notFound(allocator: std.mem.Allocator) !HttpResponse {
        return errorResponse(allocator, 404, "Not found");
    }

    pub fn badRequest(allocator: std.mem.Allocator, msg: []const u8) !HttpResponse {
        return errorResponse(allocator, 400, msg);
    }

    pub fn internalError(allocator: std.mem.Allocator, msg: []const u8) !HttpResponse {
        return errorResponse(allocator, 500, msg);
    }

    pub fn deinit(self: HttpResponse, allocator: std.mem.Allocator) void {
        if (self.owned and self.body.len > 0) {
            allocator.free(self.body);
        }
    }
};

// ============================================================================
// Authentication
// ============================================================================

pub const AuthError = error{
    MissingHeader,
    InvalidFormat,
    InvalidCredentials,
    InvalidToken,
};

/// Validate Basic Auth header (username:password)
pub fn validateBasicAuth(header: ?[]const u8, expected_username: []const u8, expected_password: []const u8) AuthError!void {
    if (header == null) return error.MissingHeader;

    const auth_header = header.?;

    // Check for "Basic " prefix
    if (!std.mem.startsWith(u8, auth_header, "Basic ")) {
        return error.InvalidFormat;
    }

    // Decode base64
    const encoded = auth_header["Basic ".len..];
    var decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(encoded) catch return error.InvalidFormat;
    var decoded = std.heap.page_allocator.alloc(u8, decoded_len) catch return error.InvalidFormat;
    defer std.heap.page_allocator.free(decoded);
    _ = decoder.decode(decoded, encoded) catch return error.InvalidFormat;

    // Split username:password
    const colon_idx = std.mem.indexOfScalar(u8, decoded, ':') orelse return error.InvalidFormat;
    const username = decoded[0..colon_idx];
    const password = decoded[colon_idx + 1 ..];

    // Validate credentials
    if (!std.mem.eql(u8, username, expected_username)) {
        return error.InvalidCredentials;
    }
    if (!std.mem.eql(u8, password, expected_password)) {
        return error.InvalidCredentials;
    }
}

/// Validate HMAC token (simple string comparison for webhook tokens)
/// Note: OpenClaw uses direct string comparison, not actual HMAC
pub fn validateWebhookToken(header: ?[]const u8, expected_token: []const u8) AuthError!void {
    if (header == null) return error.MissingHeader;

    const token = header.?;

    // Use constant-time comparison to prevent timing attacks
    if (!std.mem.eql(u8, token, expected_token)) {
        return error.InvalidToken;
    }
}

// ============================================================================
// Command Execution
// ============================================================================

pub const CommandResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,

    pub fn deinit(self: CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Execute a command safely with whitelisted arguments
pub fn executeCommand(allocator: std.mem.Allocator, argv: []const []const u8, working_dir: ?[]const u8) !CommandResult {
    // Validate command is absolute path (security)
    if (argv.len == 0) return error.EmptyCommand;
    if (!std.fs.path.isAbsolute(argv[0])) {
        return error.InvalidCommandPath;
    }

    var result = CommandResult{
        .stdout = "",
        .stderr = "",
        .exit_code = 0,
    };

    const process_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = working_dir,
        .max_output_bytes = 1024 * 1024, // 1MB limit
    }) catch |err| {
        log.err("Failed to execute command: {s} - {}", .{argv[0], err});
        return err;
    };

    result.stdout = process_result.stdout;
    result.stderr = process_result.stderr;
    result.exit_code = switch (process_result.term) {
        .Exited => |code| code,
        else => 1,
    };

    return result;

}

/// Execute a command and return the output as a string
pub fn executeCommandSimple(allocator: std.mem.Allocator, argv: []const []const u8, working_dir: ?[]const u8) ![]const u8 {
    const result = try executeCommand(allocator, argv, working_dir);

    // Return stdout, or stderr if stdout is empty and there's an error
    if (result.exit_code == 0 or result.stdout.len > 0) {
        // Free stderr since we're returning stdout
        allocator.free(result.stderr);
        return result.stdout;
    }
    // Free stdout since we're returning stderr
    allocator.free(result.stdout);
    return result.stderr;
}


// ============================================================================
// HTTP Request Parsing
// ============================================================================

pub const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,

    pub fn getHeader(self: *const HttpRequest, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    pub fn deinit(self: *HttpRequest, allocator: std.mem.Allocator) void {
        self.headers.deinit();
        allocator.free(self.body);
    }
};

/// Parse a simple HTTP request (for custom server implementations)
pub fn parseHttpRequest(allocator: std.mem.Allocator, data: []const u8) !HttpRequest {
    if (data.len == 0) return error.InvalidRequest;
    var lines = std.mem.splitScalar(u8, data, '\n');

    // Parse request line: METHOD PATH VERSION
    const request_line = lines.first();
    if (request_line.len == 0) return error.InvalidRequest;
    var request_parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = request_parts.first();
    if (method.len == 0) return error.InvalidRequest;
    const path = request_parts.next() orelse return error.InvalidRequest;
    _ = request_parts.next(); // Skip HTTP version

    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer headers.deinit();

    // Parse headers
    while (lines.next()) |line| {
        if (line.len == 0) break; // Empty line marks end of headers

        const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon_idx];
        var value = line[colon_idx + 1 ..];

        // Trim leading whitespace from value
        while (value.len > 0 and std.ascii.isWhitespace(value[0])) {
            value = value[1..];
        }

        // Trim trailing whitespace
        while (value.len > 0 and std.ascii.isWhitespace(value[value.len - 1])) {
            value = value[0 .. value.len - 1];
        }

        try headers.put(name, try allocator.dupe(u8, value));
    }

    // The rest is the body
    const body_start = lines.index orelse data.len;
    const body = if (body_start < data.len)
        try allocator.dupe(u8, data[body_start..])
    else
        try allocator.dupe(u8, "");

    return HttpRequest{
        .method = try allocator.dupe(u8, method),
        .path = try allocator.dupe(u8, path),
        .headers = headers,
        .body = body,
    };
}

// ============================================================================
// Configuration
// ============================================================================

pub const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9000,

    pub fn address(self: *const ServerConfig) !std.net.Address {
        return std.net.Address.parseIp(self.host, self.port);
    }
};

pub fn loadWebhookSecret(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.HomeNotFound,
        else => return err,
    };
    defer allocator.free(home);

    const secret_path = try std.fmt.allocPrint(allocator, "{s}/.zeptoclaw/.webhook-secret", .{home});
    defer allocator.free(secret_path);

    const secret = try std.fs.cwd().readFileAlloc(allocator, secret_path, 1024);

    // Trim newline
    const trimmed = std.mem.trim(u8, secret, &std.ascii.whitespace);
    if (trimmed.len < secret.len) {
        // Need to create a new allocation with the trimmed content
        const new_secret = try allocator.dupe(u8, trimmed);
        allocator.free(secret);
        return new_secret;
    }

    return secret;
}


// ============================================================================
// Tests
// ============================================================================

// Tests
// ============================================================================

test "validateBasicAuth - valid credentials" {
    const username = "testuser";
    const password = "testpass";
    const credentials = try std.fmt.allocPrint(std.testing.allocator, "{s}:{s}", .{ username, password });
    defer std.testing.allocator.free(credentials);

    const encoded = std.base64.standard.Encoder.encode(&std.heap.page_allocator, credentials) catch unreachable;
    defer std.heap.page_allocator.free(encoded);

    const header = try std.fmt.allocPrint(std.testing.allocator, "Basic {s}", .{encoded});
    defer std.testing.allocator.free(header);

    try validateBasicAuth(header, username, password);
}

test "validateBasicAuth - invalid credentials" {
    const header = "Basic dGVzdHVzZXI6d3JvbmdwYXNz"; // testuser:wrongpass
    try std.testing.expectError(error.InvalidCredentials, validateBasicAuth(header, "testuser", "testpass"));
}

test "validateWebhookToken - valid token" {
    const token = "714096ee11b030c51a65c0e8b0dc6c567c0f507bc7c03284540465385f11bec6";
    try validateWebhookToken(token, token);
}

test "validateWebhookToken - invalid token" {
    try std.testing.expectError(
        error.InvalidToken,
        validateWebhookToken("wrongtoken", "714096ee11b030c51a65c0e8b0dc6c567c0f507bc7c03284540465385f11bec6"),
    );
}
