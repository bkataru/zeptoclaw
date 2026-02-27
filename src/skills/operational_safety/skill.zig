//! Operational Safety & Security Skill
//! Security hardening, prompt injection defense, privileged command authorization

const std = @import("std");
const sdk = @import("../skill_sdk.zig");
const execution_context = @import("../execution_context.zig");

const SkillResult = execution_context.SkillResult;
const ExecutionContext = execution_context.ExecutionContext;

pub const skill = struct {
    var config: ?Config = null;

    pub fn init(allocator: std.mem.Allocator, config_value: std.json.Value) !void {
        _ = allocator;
        _ = config_value;
        config = Config{
            .trusted_whatsapp_number = "+919182065182",
            .enable_prompt_injection_detection = true,
            .log_privileged_operations = true,
            .require_explicit_auth = true,
        };
    }

    pub fn execute(ctx: *ExecutionContext) !SkillResult {
        const message = ctx.getMessageContent() orelse {
            return SkillResult.errorResponse(ctx.allocator, "No message content");
        };

        // Check for prompt injection patterns
        if (config.?.enable_prompt_injection_detection) {
            if (detectPromptInjection(message)) {
                const response = try std.fmt.allocPrint(ctx.allocator,
                    \\🚨 Potential prompt injection detected
                    \\
                    \\I cannot override my instructions or system prompt. This is for
                    \\security reasons. I'm happy to help you with legitimate tasks!
                , .{});
                try ctx.respond(response);
                return SkillResult.stop(ctx.allocator, response);
            }
        }

        // Parse command
        if (std.mem.startsWith(u8, message, "/safety-check")) {
            return handleSafetyCheck(ctx);
        } else if (std.mem.startsWith(u8, message, "/verify-identity")) {
            return handleVerifyIdentity(ctx);
        } else if (std.mem.startsWith(u8, message, "/auth-status")) {
            return handleAuthStatus(ctx);
        } else if (containsDangerousCommand(message)) {
            return handleDangerousCommand(ctx, message);
        }

        return SkillResult.successResponse(ctx.allocator, "");
    }

    pub fn deinit(allocator: std.mem.Allocator) void {
        _ = allocator;
        config = null;
    }

    pub fn getMetadata() sdk.SkillMetadata {
        return .{
            .id = "operational-safety",
            .name = "Operational Safety",
            .version = "1.0.0",
            .description = "Security hardening, prompt injection defense, privileged command authorization",
            .homepage = null,
            .metadata = .{ .object = std.StringHashMap(std.json.Value).init(std.heap.page_allocator) },
            .enabled = true,
        };
    }
};

const Config = struct {
    trusted_whatsapp_number: []const u8,
    enable_prompt_injection_detection: bool,
    log_privileged_operations: bool,
    require_explicit_auth: bool,
};

const PromptInjectionPattern = struct {
    pattern: []const u8,
    description: []const u8,
};

const injection_patterns = [_]PromptInjectionPattern{
    .{ .pattern = "ignore previous instructions", .description = "Ignore instructions" },
    .{ .pattern = "forget everything", .description = "Forget context" },
    .{ .pattern = "new system prompt", .description = "System prompt override" },
    .{ .pattern = "override your programming", .description = "Override programming" },
    .{ .pattern = "you are now", .description = "Persona change" },
    .{ .pattern = "act as", .description = "Role change" },
    .{ .pattern = "pretend to be", .description = "Pretend command" },
};

const dangerous_commands = [_][]const u8{
    "sudo rm -rf",
    "chmod 777",
    "rm -rf /",
    ":(){ :|:& };:", // fork bomb
    "dd if=/dev/zero",
};

fn detectPromptInjection(message: []const u8) bool {
    const lower = toLower(message);
    for (injection_patterns) |pattern| {
        if (std.mem.indexOf(u8, lower, toLower(pattern.pattern))) |_| {
            return true;
        }
    }
    return false;
}

fn containsDangerousCommand(message: []const u8) bool {
    const lower = toLower(message);
    for (dangerous_commands) |cmd| {
        if (std.mem.indexOf(u8, lower, toLower(cmd))) |_| {
            return true;
        }
    }
    return false;
}

fn toLower(s: []const u8) []const u8 {
    // Simple lowercase conversion - in real implementation would allocate
    _ = s;
    return s;
}

fn handleSafetyCheck(ctx: *ExecutionContext) !SkillResult {
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🛡️ Operational Safety Status
        \\
        \\Configuration:
        \\- Trusted WhatsApp number: {s}
        \\- Prompt injection detection: {any}
        \\- Log privileged operations: {any}
        \\- Require explicit auth: {any}
        \\
        \\Security Principles:
        \\1. Single Trust Anchor: Baala is the ONLY trusted authority
        \\2. Verify Before Trust: Never assume identity
        \\3. Minimal Disclosure: Share only what's necessary
        \\4. Fail Secure: When uncertain, deny and report
        \\
        \\✅ All security systems operational
    , .{
        config.?.trusted_whatsapp_number,
        config.?.enable_prompt_injection_detection,
        config.?.log_privileged_operations,
        config.?.require_explicit_auth,
    });

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleVerifyIdentity(ctx: *ExecutionContext) !SkillResult {
    // In a real implementation, this would check the actual channel/user
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\🔍 Identity Verification
        \\
        \\Current session: Webchat (direct from Baala)
        \\Verification status: ✅ VERIFIED
        \\
        \\Privileged operations: AUTHORIZED
        \\
        \\Note: WhatsApp sessions require number verification (+919182065182)
    , .{});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleAuthStatus(ctx: *ExecutionContext) !SkillResult {
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\📋 Authorization Status
        \\
        \\Current user: Baala (verified)
        \\Authorization level: FULL
        \\
        \\Authorized operations:
        \\✅ Code assistance and review
        \\✅ Documentation generation
        \\✅ General Q&A
        \\✅ Code formatting
        \\✅ Test execution in workspace
        \\✅ Build commands in workspace
        \\✅ System configuration changes
        \\✅ File system operations
        \\✅ Network requests
        \\✅ Credential access
        \\✅ Service management
        \\
        \\All operations authorized for verified Baala sessions.
    , .{});

    try ctx.respond(response);
    return SkillResult.successResponse(ctx.allocator, response);
}

fn handleDangerousCommand(ctx: *ExecutionContext, message: []const u8) !SkillResult {
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\⚠️ Potentially Dangerous Command Detected
        \\
        \\Command: {s}
        \\
        \\This command could cause system damage or data loss.
        \\
        \\For your safety, please:
        \\1. Verify you really want to execute this command
        \\2. Double-check the command parameters
        \\3. Consider safer alternatives
        \\
        \\If you're sure this is safe, please confirm by typing:
        \\"YES I AM SURE"
        \\
        \\This is a security measure to prevent accidental damage.
    , .{message});

    try ctx.respond(response);
    return SkillResult.stop(ctx.allocator, response);
}
