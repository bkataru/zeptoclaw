const std = @import("std");

/// Validation result - bitfield indicating which validations failed
/// Each field corresponds to a validation error
pub const ValidationResult = packed struct {
    missing_api_key: bool = false,
    missing_primary_model: bool = false,
    invalid_gateway_port: bool = false,
    invalid_timeout: bool = false,
    invalid_max_concurrent: bool = false,
    invalid_max_iterations: bool = false,
    invalid_temperature: bool = false,
    invalid_max_tokens: bool = false,
    invalid_workspace: bool = false,
    invalid_whatsapp_media_max_mb: bool = false,
    invalid_whatsapp_debounce_ms: bool = false,

    /// Returns true if any validation failed
    pub fn hasErrors(self: *const ValidationResult) bool {
        const bytes: [*]const u8 = @ptrCast(self);
        for (bytes[0..@sizeOf(ValidationResult)]) |b| {
            if (b != 0) return true;
        }
        return false;
    }

    /// Returns the count of validation errors
    pub fn errorCount(self: *const ValidationResult) usize {
        var count: usize = 0;
        const bytes: [*]const u8 = @ptrCast(self);
        for (bytes[0..@sizeOf(ValidationResult)]) |b| {
            count += @popCount(b);
        }
        return count;
    }
};

/// Print human-readable validation error messages
pub fn printErrorMessages(writer: anytype, result: *const ValidationResult) void {
    if (result.missing_api_key) writer.print(" - API key is required (set NVIDIA_API_KEY)\n", .{}) catch {};
    if (result.missing_primary_model) writer.print(" - Primary model is required (set NVIDIA_MODEL)\n", .{}) catch {};
    if (result.invalid_gateway_port) writer.print(" - Gateway port must be between 1 and 65535\n", .{}) catch {};
    if (result.invalid_timeout) writer.print(" - NIM timeout must be greater than 0\n", .{}) catch {};
    if (result.invalid_max_concurrent) writer.print(" - Max concurrent requests must be greater than 0\n", .{}) catch {};
    if (result.invalid_max_iterations) writer.print(" - Max iterations must be greater than 0\n", .{}) catch {};
    if (result.invalid_temperature) writer.print(" - Temperature must be between 0.0 and 2.0\n", .{}) catch {};
    if (result.invalid_max_tokens) writer.print(" - Max tokens must be greater than 0\n", .{}) catch {};
    if (result.invalid_workspace) writer.print(" - Workspace path is required\n", .{}) catch {};
    if (result.invalid_whatsapp_media_max_mb) writer.print(" - WhatsApp media max MB must be greater than 0\n", .{}) catch {};
    if (result.invalid_whatsapp_debounce_ms) writer.print(" - WhatsApp debounce ms must be 0 or >= 100\n", .{}) catch {};
}

/// Validate a configuration struct and return result with all errors.
/// Uses field access via anytype to avoid module boundary issues.
pub fn validate(cfg: anytype) ValidationResult {
    var result: ValidationResult = .{};

    // Required fields: non-empty strings
    if (cfg.api_key.len == 0) {
        result.missing_api_key = true;
    }
    if (cfg.primary_model.len == 0) {
        result.missing_primary_model = true;
    }

    // gateway_port: 1-65535
    if (cfg.gateway_port < 1 or cfg.gateway_port > 65535) {
        result.invalid_gateway_port = true;
    }

    // Positive integer validations
    if (cfg.nim_timeout_ms == 0) {
        result.invalid_timeout = true;
    }
    if (cfg.max_concurrent == 0) {
        result.invalid_max_concurrent = true;
    }
    if (cfg.max_iterations == 0) {
        result.invalid_max_iterations = true;
    }
    if (cfg.max_tokens == 0) {
        result.invalid_max_tokens = true;
    }

    // Temperature range: 0.0 to 2.0 (inclusive)
    if (cfg.temperature < 0.0 or cfg.temperature > 2.0) {
        result.invalid_temperature = true;
    }

    // Workspace must be non-empty (path existence checked elsewhere)
    if (cfg.workspace.len == 0) {
        result.invalid_workspace = true;
    }

    // WhatsApp validations
    if (cfg.whatsapp_media_max_mb == 0) {
        result.invalid_whatsapp_media_max_mb = true;
    }
    if (cfg.whatsapp_debounce_ms > 0 and cfg.whatsapp_debounce_ms < 100) {
        result.invalid_whatsapp_debounce_ms = true;
    }

    return result;
}

/// Convenience function: validate and exit on failure.
/// Used at startup to ensure config is valid.
pub fn validateOrExit(cfg: anytype) void {
    const result = validate(cfg);

    if (result.hasErrors()) {
        std.debug.print("Configuration validation failed with {} error{}:\n", .{result.errorCount(), if (result.errorCount() == 1) "" else "s"});
        printErrorMessages(std.debug.writer(), &result);
        std.process.exit(1);
    }
}
