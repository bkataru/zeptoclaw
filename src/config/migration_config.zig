const std = @import("std");

/// Configuration source priority: CLI > env > file > defaults
pub const ConfigSource = enum {
    cli,
    env,
    file,
    default,
};

/// OpenClaw-compatible configuration structure
pub const OpenClawConfig = struct {
    meta: Meta,
    env: Env,
    models: Models,
    agents: Agents,
    gateway: Gateway,
    skills: Skills,
    channels: Channels,
    tools: Tools,
    hooks: Hooks,
    diagnostics: Diagnostics,
    update: Update,
    auth: Auth,
    messages: Messages,
    commands: Commands,
    plugins: Plugins,

    pub const Meta = struct {
        lastTouchedVersion: ?[]const u8 = null,
        lastTouchedAt: ?[]const u8 = null,
    };

    pub const Env = struct {
        NVIDIA_API_KEY: ?[]const u8 = null,
    };

    pub const Models = struct {
        mode: []const u8 = "merge",
        providers: std.json.Value = .null,
    };

    pub const Agents = struct {
        defaults: AgentDefaults,
        list: []Agent = &.{},

        pub const AgentDefaults = struct {
            model: ModelConfig,
            imageModel: ImageModelConfig,
            models: std.json.Value = .null,
            workspace: []const u8 = "/tmp/zeptoclaw",
            compaction: Compaction,
            maxConcurrent: u32 = 4,
            subagents: Subagents,

            pub const ModelConfig = struct {
                primary: []const u8,
                fallbacks: []const []const u8 = &.{},
            };

            pub const ImageModelConfig = struct {
                primary: []const u8,
                fallbacks: []const []const u8 = &.{},
            };

            pub const Compaction = struct {
                mode: []const u8 = "safeguard",
            };

            pub const Subagents = struct {
                maxConcurrent: u32 = 8,
            };
        };

        pub const Agent = struct {
            id: []const u8,
            groupChat: ?GroupChat = null,

            pub const GroupChat = struct {
                mentionPatterns: []const []const u8 = &.{},
            };
        };
    };

    pub const Gateway = struct {
        port: u32 = 18789,
        mode: []const u8 = "local",
        bind: []const u8 = "lan",
        controlUi: ControlUi,
        auth: AuthConfig,
        tailscale: Tailscale,

        pub const ControlUi = struct {
            enabled: bool = true,
            allowInsecureAuth: bool = false,
        };

        pub const AuthConfig = struct {
            mode: []const u8 = "token",
            token: ?[]const u8 = null,
        };

        pub const Tailscale = struct {
            mode: []const u8 = "off",
            resetOnExit: bool = false,
        };
    };

    pub const Skills = struct {
        load: Load,
        install: Install,
        entries: std.json.Value = .null,

        pub const Load = struct {
            extraDirs: []const []const u8 = &.{},
        };

        pub const Install = struct {
            nodeManager: []const u8 = "bun",
        };
    };

    pub const Channels = struct {
        whatsapp: ?WhatsApp = null,

        pub const WhatsApp = struct {
            dmPolicy: []const u8 = "allowlist",
            allowFrom: []const []const u8 = &.{},
            groupPolicy: []const u8 = "allowlist",
        };
    };

    pub const Tools = struct {
        web: Web,

        pub const Web = struct {
            search: struct { enabled: bool = false },
            fetch: struct { enabled: bool = true },
        };
    };

    pub const Hooks = struct {
        internal: Internal,

        pub const Internal = struct {
            enabled: bool = true,
            entries: std.json.Value = .null,
        };
    };

    pub const Diagnostics = struct {
        enabled: bool = true,
        cacheTrace: CacheTrace,

        pub const CacheTrace = struct {
            enabled: bool = true,
            includeMessages: bool = true,
            includePrompt: bool = true,
            includeSystem: bool = true,
        };
    };

    pub const Update = struct {
        channel: []const u8 = "dev",
        checkOnStart: bool = true,
    };

    pub const Auth = struct {
        profiles: std.json.Value = .null,
    };

    pub const Messages = struct {
        ackReactionScope: []const u8 = "group-mentions",
    };

    pub const Commands = struct {
        native: []const u8 = "auto",
        nativeSkills: []const u8 = "auto",
    };

    pub const Plugins = struct {
        entries: std.json.Value = .null,
    };
};

/// ZeptoClaw configuration structure
pub const ZeptoClawConfig = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    primary_model: []const u8,
    fallback_models: [][]const u8,
    image_model: []const u8,
    max_iterations: u32,
    temperature: f32,
    max_tokens: u32,
    nim_timeout_ms: u32 = 30000,
    gateway_port: u32,
    gateway_mode: []const u8,
    gateway_bind: []const u8,
    gateway_auth_token: ?[]const u8,
    gateway_control_ui_enabled: bool = true,
    gateway_allow_insecure_auth: bool = false,
    workspace: []const u8,
    max_concurrent: u32,
    source: ConfigSource,
    // WhatsApp configuration
    whatsapp_enabled: bool = false,
    whatsapp_auth_dir: []const u8,
    whatsapp_dm_policy: []const u8,
    whatsapp_allow_from: [][]const u8,
    whatsapp_group_policy: []const u8,
    whatsapp_media_max_mb: u32 = 50,
    whatsapp_debounce_ms: u32 = 0,
    whatsapp_send_read_receipts: bool = true,
    whatsapp_group_require_mention: bool = true,
    whatsapp_group_activation_commands: [][]const u8,

    pub fn deinit(self: *ZeptoClawConfig) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.primary_model);
        for (self.fallback_models) |model| {
            self.allocator.free(model);
        }
        self.allocator.free(self.fallback_models);
        self.allocator.free(self.image_model);
        self.allocator.free(self.gateway_mode);
        self.allocator.free(self.gateway_bind);
        self.allocator.free(self.workspace);
        if (self.gateway_auth_token) |token| {
            self.allocator.free(token);
        }
        // Free WhatsApp config
        self.allocator.free(self.whatsapp_auth_dir);
        self.allocator.free(self.whatsapp_dm_policy);
        self.allocator.free(self.whatsapp_group_policy);
        for (self.whatsapp_allow_from) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(self.whatsapp_allow_from);
        for (self.whatsapp_group_activation_commands) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(self.whatsapp_group_activation_commands);
    }
};

/// Configuration loader with support for JSON, env vars, and CLI
pub const ConfigLoader = struct {
    allocator: std.mem.Allocator,

    pub const CliArgs = struct {
        api_key: ?[]const u8 = null,
        model: ?[]const u8 = null,
        config_file: ?[]const u8 = null,
    };
    pub fn init(allocator: std.mem.Allocator) ConfigLoader {
        return .{ .allocator = allocator };
    }

    /// Load configuration from all sources with priority: CLI > env > file > defaults
    pub fn load(self: *ConfigLoader, cli_args: ?CliArgs) !ZeptoClawConfig {
        // Try to load from config file first
        // Try to load from config file first
        var file_config: ?ZeptoClawConfig = null;
        if (cli_args) |args| {
            if (args.config_file) |config_path| {
                file_config = try self.loadFromFile(config_path);
            }
        } else {
            // Try default config paths
            const default_paths = [_][]const u8{
                "/home/user/.openclaw/openclaw.json",
                "/home/user/.zeptoclaw/config.json",
                "./zeptoclaw.json",
            };
            for (default_paths) |path| {
                if (std.fs.cwd().openFile(path, .{})) |file| {
                    file.close();
                    file_config = try self.loadFromFile(path);
                    break;
                } else |_| continue;
            }
        }

        // Load from environment variables
        var env_config = try self.loadFromEnv();
        errdefer {
            if (file_config) |*fc| fc.deinit();
            env_config.deinit();
        }
        // Merge configurations with priority: CLI > env > file > defaults
        const result = try self.mergeConfigs(file_config, env_config, cli_args);
        // Deinit intermediate configs after successful merge
        if (file_config) |*fc| {
            fc.deinit();
        }
        env_config.deinit();
        return result;
    }

    /// Load configuration from OpenClaw-compatible JSON file
    fn loadFromFile(self: *ConfigLoader, path: []const u8) !ZeptoClawConfig {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        _ = try file.readAll(buffer);

        // Parse JSON
        const parsed = try std.json.parseFromSlice(OpenClawConfig, self.allocator, buffer, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const openclaw = parsed.value;

        // Extract API key from env section or use default
        const api_key = if (openclaw.env.NVIDIA_API_KEY) |key|
            try self.allocator.dupe(u8, key)
        else
            return error.MissingApiKey;

        // Extract primary model and fallbacks
        const primary_model = try self.allocator.dupe(u8, openclaw.agents.defaults.model.primary);

        var fallback_models_array = try self.allocator.alloc([]const u8, openclaw.agents.defaults.model.fallbacks.len); for (openclaw.agents.defaults.model.fallbacks, 0..) |fallback, i| { fallback_models_array[i] = try self.allocator.dupe(u8, fallback); } const fallback_models = fallback_models_array;


        // Extract image model
        const image_model = try self.allocator.dupe(u8, openclaw.agents.defaults.imageModel.primary);

        // Extract gateway config
        const gateway_mode = try self.allocator.dupe(u8, openclaw.gateway.mode);
        const gateway_bind = try self.allocator.dupe(u8, openclaw.gateway.bind);
        const gateway_auth_token = if (openclaw.gateway.auth.token) |token|
            try self.allocator.dupe(u8, token)
        else
            null;

        // Extract workspace
        const workspace = try self.allocator.dupe(u8, openclaw.agents.defaults.workspace);

        // Extract WhatsApp configuration
        const whatsapp_enabled = openclaw.channels.whatsapp != null;
        const whatsapp_auth_dir = try self.allocator.dupe(u8, "/home/user/zeptoclaw/sessions/whatsapp");
        const whatsapp_dm_policy = if (openclaw.channels.whatsapp) |wh|
            try self.allocator.dupe(u8, wh.dmPolicy)
        else
            try self.allocator.dupe(u8, "pairing");
        const whatsapp_group_policy = if (openclaw.channels.whatsapp) |wh|
            try self.allocator.dupe(u8, wh.groupPolicy)
        else
            try self.allocator.dupe(u8, "allowlist");
        var whatsapp_allow_from = try self.allocator.alloc([]const u8, if (openclaw.channels.whatsapp) |wh| wh.allowFrom.len else 0); if (openclaw.channels.whatsapp) |wh| { for (wh.allowFrom, 0..) |item, i| { whatsapp_allow_from[i] = try self.allocator.dupe(u8, item); } } var whatsapp_group_activation_commands = try self.allocator.alloc([]const u8, 1); whatsapp_group_activation_commands[0] = try self.allocator.dupe(u8, "/start");

        return .{
            .allocator = self.allocator,
            .api_key = api_key,
            .primary_model = primary_model,
            .fallback_models = fallback_models,
            .image_model = image_model,
            .max_iterations = 10,
            .temperature = 0.7,
            .max_tokens = 1024,
            .gateway_port = openclaw.gateway.port,
            .gateway_mode = gateway_mode,
            .gateway_bind = gateway_bind,
            .gateway_auth_token = gateway_auth_token,
            .gateway_control_ui_enabled = openclaw.gateway.controlUi.enabled,
            .gateway_allow_insecure_auth = openclaw.gateway.controlUi.allowInsecureAuth,
            .workspace = workspace,
            .max_concurrent = openclaw.agents.defaults.maxConcurrent,
            .source = .file,
            .whatsapp_enabled = whatsapp_enabled,
            .whatsapp_auth_dir = whatsapp_auth_dir,
            .whatsapp_dm_policy = whatsapp_dm_policy,
            .whatsapp_allow_from = whatsapp_allow_from,
            .whatsapp_group_policy = whatsapp_group_policy,
            .whatsapp_media_max_mb = 50,
            .whatsapp_debounce_ms = 0,
            .whatsapp_send_read_receipts = true,
            .whatsapp_group_require_mention = true,
            .whatsapp_group_activation_commands = whatsapp_group_activation_commands,
        };
    }

    /// Load configuration from environment variables
    fn loadFromEnv(self: *ConfigLoader) !ZeptoClawConfig {
        const api_key = std.process.getEnvVarOwned(self.allocator, "NVIDIA_API_KEY") catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return error.MissingApiKey;
            }
            return err;
        };

        const model = std.process.getEnvVarOwned(self.allocator, "NVIDIA_MODEL") catch
            try self.allocator.dupe(u8, "qwen/qwen3.5-397b-a17b");

        const image_model = std.process.getEnvVarOwned(self.allocator, "NVIDIA_IMAGE_MODEL") catch
            try self.allocator.dupe(u8, "stable-diffusion-3.5-large");

        const gateway_port_str = std.process.getEnvVarOwned(self.allocator, "GATEWAY_PORT") catch "18789";
        const gateway_port = std.fmt.parseInt(u32, gateway_port_str, 10) catch 18789;
        if (gateway_port_str[0] != '1') { // Not a literal
            self.allocator.free(gateway_port_str);
        }

        const gateway_mode = std.process.getEnvVarOwned(self.allocator, "GATEWAY_MODE") catch
            try self.allocator.dupe(u8, "local");

        const gateway_bind = std.process.getEnvVarOwned(self.allocator, "GATEWAY_BIND") catch
            try self.allocator.dupe(u8, "lan");

        const gateway_auth_token = std.process.getEnvVarOwned(self.allocator, "GATEWAY_AUTH_TOKEN") catch |err| blk: {
            break :blk if (err == error.EnvVarNotFound) null else return err;
        };

        const workspace = std.process.getEnvVarOwned(self.allocator, "WORKSPACE") catch
            try self.allocator.dupe(u8, "/tmp/zeptoclaw");
        // WhatsApp configuration from environment
        const whatsapp_enabled_str = std.process.getEnvVarOwned(self.allocator, "WHATSAPP_ENABLED") catch "false";
        const whatsapp_enabled = std.mem.eql(u8, whatsapp_enabled_str, "true") or std.mem.eql(u8, whatsapp_enabled_str, "1");
        if (whatsapp_enabled_str[0] != 'f' and whatsapp_enabled_str[0] != '0') {
            self.allocator.free(whatsapp_enabled_str);
        }
        const whatsapp_auth_dir = std.process.getEnvVarOwned(self.allocator, "WHATSAPP_AUTH_DIR") catch
            try self.allocator.dupe(u8, "/home/user/zeptoclaw/sessions/whatsapp");
        const whatsapp_dm_policy = std.process.getEnvVarOwned(self.allocator, "WHATSAPP_DM_POLICY") catch
            try self.allocator.dupe(u8, "pairing");
        const whatsapp_group_policy = std.process.getEnvVarOwned(self.allocator, "WHATSAPP_GROUP_POLICY") catch
            try self.allocator.dupe(u8, "allowlist");
        const whatsapp_media_max_mb_str = std.process.getEnvVarOwned(self.allocator, "WHATSAPP_MEDIA_MAX_MB") catch "50";
        const whatsapp_media_max_mb = std.fmt.parseInt(u32, whatsapp_media_max_mb_str, 10) catch 50;
        if (whatsapp_media_max_mb_str[0] != '5') {
            self.allocator.free(whatsapp_media_max_mb_str);
        }
        const whatsapp_debounce_ms_str = std.process.getEnvVarOwned(self.allocator, "WHATSAPP_DEBOUNCE_MS") catch "0";
        const whatsapp_debounce_ms = std.fmt.parseInt(u32, whatsapp_debounce_ms_str, 10) catch 0;
        if (whatsapp_debounce_ms_str[0] != '0') {
            self.allocator.free(whatsapp_debounce_ms_str);
        }
        const whatsapp_send_read_receipts_str = std.process.getEnvVarOwned(self.allocator, "WHATSAPP_SEND_READ_RECEIPTS") catch "true";
        const whatsapp_send_read_receipts = std.mem.eql(u8, whatsapp_send_read_receipts_str, "true") or std.mem.eql(u8, whatsapp_send_read_receipts_str, "1");
        if (whatsapp_send_read_receipts_str[0] != 't' and whatsapp_send_read_receipts_str[0] != '1') {
            self.allocator.free(whatsapp_send_read_receipts_str);
        }
        const whatsapp_group_require_mention_str = std.process.getEnvVarOwned(self.allocator, "WHATSAPP_GROUP_REQUIRE_MENTION") catch "true";
        const whatsapp_group_require_mention = std.mem.eql(u8, whatsapp_group_require_mention_str, "true") or std.mem.eql(u8, whatsapp_group_require_mention_str, "1");
        if (whatsapp_group_require_mention_str[0] != 't' and whatsapp_group_require_mention_str[0] != '1') {
            self.allocator.free(whatsapp_group_require_mention_str);
        }
        var whatsapp_allow_from = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        var whatsapp_group_activation_commands = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        try whatsapp_group_activation_commands.append(self.allocator, try self.allocator.dupe(u8, "/start"));

        return .{
            .allocator = self.allocator,
            .api_key = api_key,
            .primary_model = model,
            .fallback_models = &.{},
            .image_model = image_model,
            .max_iterations = 10,
            .temperature = 0.7,
            .max_tokens = 1024,
            .gateway_port = gateway_port,
            .gateway_mode = gateway_mode,
            .gateway_bind = gateway_bind,
            .gateway_auth_token = gateway_auth_token,
            .gateway_control_ui_enabled = true,
            .gateway_allow_insecure_auth = false,
            .workspace = workspace,
            .max_concurrent = 4,
            .source = .env,
            .whatsapp_enabled = whatsapp_enabled,
            .whatsapp_auth_dir = whatsapp_auth_dir,
            .whatsapp_dm_policy = whatsapp_dm_policy,
            .whatsapp_allow_from = try whatsapp_allow_from.toOwnedSlice(self.allocator),
            .whatsapp_group_policy = whatsapp_group_policy,
            .whatsapp_media_max_mb = whatsapp_media_max_mb,
            .whatsapp_debounce_ms = whatsapp_debounce_ms,
            .whatsapp_send_read_receipts = whatsapp_send_read_receipts,
            .whatsapp_group_require_mention = whatsapp_group_require_mention,
            .whatsapp_group_activation_commands = try whatsapp_group_activation_commands.toOwnedSlice(self.allocator),
        };
    }

    /// Merge configurations with priority: CLI > env > file > defaults
    pub fn mergeConfigs(self: *ConfigLoader,
        file_config: ?ZeptoClawConfig,
        env_config: ?ZeptoClawConfig,
        cli_args: ?CliArgs,
    ) !ZeptoClawConfig {
        // Start with defaults
        var result = ZeptoClawConfig{
            .allocator = self.allocator,
            .api_key = try self.allocator.dupe(u8, ""),
            .primary_model = try self.allocator.dupe(u8, "qwen/qwen3.5-397b-a17b"),
            .fallback_models = &.{},
            .image_model = try self.allocator.dupe(u8, "stable-diffusion-3.5-large"),
            .max_iterations = 10,
            .temperature = 0.7,
            .max_tokens = 1024,
            .gateway_port = 18789,
            .gateway_mode = try self.allocator.dupe(u8, "local"),
            .gateway_bind = try self.allocator.dupe(u8, "lan"),
            .gateway_auth_token = null,
            .gateway_control_ui_enabled = true,
            .gateway_allow_insecure_auth = false,
            .workspace = try self.allocator.dupe(u8, "/tmp/zeptoclaw"),
            .max_concurrent = 4,
            .source = .default,
            .whatsapp_enabled = false,
            .whatsapp_auth_dir = try self.allocator.dupe(u8, "/home/user/zeptoclaw/sessions/whatsapp"),
            .whatsapp_dm_policy = try self.allocator.dupe(u8, "pairing"),
            .whatsapp_allow_from = &.{},
            .whatsapp_group_policy = try self.allocator.dupe(u8, "allowlist"),
            .whatsapp_media_max_mb = 50,
            .whatsapp_debounce_ms = 0,
            .whatsapp_send_read_receipts = true,
            .whatsapp_group_require_mention = true,
            .whatsapp_group_activation_commands = &.{},
        };
        if (file_config) |fc| {
            const mutable_fc = fc;
            self.allocator.free(result.api_key);
            self.allocator.free(result.primary_model);
            self.allocator.free(result.image_model);
            self.allocator.free(result.gateway_mode);
            self.allocator.free(result.gateway_bind);
            self.allocator.free(result.workspace);
            if (result.gateway_auth_token) |token| self.allocator.free(token);
            // Free WhatsApp defaults
            self.allocator.free(result.whatsapp_auth_dir);
            self.allocator.free(result.whatsapp_dm_policy);
            self.allocator.free(result.whatsapp_group_policy);

            result.api_key = try self.allocator.dupe(u8, mutable_fc.api_key);
            result.primary_model = try self.allocator.dupe(u8, mutable_fc.primary_model);
            result.fallback_models = try self.dupeSlice(mutable_fc.fallback_models);
            result.image_model = try self.allocator.dupe(u8, mutable_fc.image_model);
            result.gateway_port = mutable_fc.gateway_port;
            result.gateway_mode = try self.allocator.dupe(u8, mutable_fc.gateway_mode);
            result.gateway_bind = try self.allocator.dupe(u8, mutable_fc.gateway_bind);
            result.gateway_auth_token = if (mutable_fc.gateway_auth_token) |token|
                try self.allocator.dupe(u8, token)
            else
                null;
            result.gateway_control_ui_enabled = mutable_fc.gateway_control_ui_enabled;
            result.gateway_allow_insecure_auth = mutable_fc.gateway_allow_insecure_auth;
            result.workspace = try self.allocator.dupe(u8, mutable_fc.workspace);
            result.max_concurrent = mutable_fc.max_concurrent;
            result.source = .file;
            // WhatsApp config from file
            result.whatsapp_enabled = mutable_fc.whatsapp_enabled;
            result.whatsapp_auth_dir = try self.allocator.dupe(u8, mutable_fc.whatsapp_auth_dir);
            result.whatsapp_dm_policy = try self.allocator.dupe(u8, mutable_fc.whatsapp_dm_policy);
            result.whatsapp_allow_from = try self.dupeSlice(mutable_fc.whatsapp_allow_from);
            result.whatsapp_group_policy = try self.allocator.dupe(u8, mutable_fc.whatsapp_group_policy);
            result.whatsapp_media_max_mb = mutable_fc.whatsapp_media_max_mb;
            result.whatsapp_debounce_ms = mutable_fc.whatsapp_debounce_ms;
            result.whatsapp_send_read_receipts = mutable_fc.whatsapp_send_read_receipts;
            result.whatsapp_group_require_mention = mutable_fc.whatsapp_group_require_mention;
            result.whatsapp_group_activation_commands = try self.dupeSlice(mutable_fc.whatsapp_group_activation_commands);
        }
        // Apply env config if available (overrides file)
        if (env_config) |ec| {
            self.allocator.free(result.api_key);
            self.allocator.free(result.primary_model);
            self.allocator.free(result.image_model);
            self.allocator.free(result.gateway_mode);
            self.allocator.free(result.gateway_bind);
            self.allocator.free(result.workspace);
            if (result.gateway_auth_token) |token| self.allocator.free(token);
            // Free WhatsApp config from file
            self.allocator.free(result.whatsapp_auth_dir);
            self.allocator.free(result.whatsapp_dm_policy);
            self.allocator.free(result.whatsapp_group_policy);
            for (result.whatsapp_allow_from) |item| {
                self.allocator.free(item);
            }
            self.allocator.free(result.whatsapp_allow_from);
            for (result.whatsapp_group_activation_commands) |item| {
                self.allocator.free(item);
            }
            self.allocator.free(result.whatsapp_group_activation_commands);

            result.api_key = try self.allocator.dupe(u8, ec.api_key);
            result.primary_model = try self.allocator.dupe(u8, ec.primary_model);
            result.fallback_models = try self.dupeSlice(ec.fallback_models);
            result.image_model = try self.allocator.dupe(u8, ec.image_model);
            result.gateway_port = ec.gateway_port;
            result.gateway_mode = try self.allocator.dupe(u8, ec.gateway_mode);
            result.gateway_bind = try self.allocator.dupe(u8, ec.gateway_bind);
            result.gateway_auth_token = if (ec.gateway_auth_token) |token|
                try self.allocator.dupe(u8, token)
            else
                null;
            result.gateway_control_ui_enabled = ec.gateway_control_ui_enabled;
            result.gateway_allow_insecure_auth = ec.gateway_allow_insecure_auth;
            result.workspace = try self.allocator.dupe(u8, ec.workspace);
            result.max_concurrent = ec.max_concurrent;
            result.source = .env;
            // WhatsApp config from env
            result.whatsapp_enabled = ec.whatsapp_enabled;
            result.whatsapp_auth_dir = try self.allocator.dupe(u8, ec.whatsapp_auth_dir);
            result.whatsapp_dm_policy = try self.allocator.dupe(u8, ec.whatsapp_dm_policy);
            result.whatsapp_allow_from = try self.dupeSlice(ec.whatsapp_allow_from);
            result.whatsapp_group_policy = try self.allocator.dupe(u8, ec.whatsapp_group_policy);
            result.whatsapp_media_max_mb = ec.whatsapp_media_max_mb;
            result.whatsapp_debounce_ms = ec.whatsapp_debounce_ms;
            result.whatsapp_send_read_receipts = ec.whatsapp_send_read_receipts;
            result.whatsapp_group_require_mention = ec.whatsapp_group_require_mention;
            result.whatsapp_group_activation_commands = try self.dupeSlice(ec.whatsapp_group_activation_commands);

            // Note: We don't deinit ec here because it's a const reference
        }
        // Apply CLI args (highest priority)

        // Apply CLI args (highest priority)
        if (cli_args) |args| {
            if (args.api_key) |key| {
                self.allocator.free(result.api_key);
                result.api_key = try self.allocator.dupe(u8, key);
            }
            if (args.model) |model| {
                self.allocator.free(result.primary_model);
                result.primary_model = try self.allocator.dupe(u8, model);
            }
            result.source = .cli;
        }

        return result;
    }

    fn dupeSlice(self: *ConfigLoader, slice: [][]const u8) ![][]const u8 {
        const result = try self.allocator.alloc([]const u8, slice.len);
        for (slice, 0..) |item, i| {
            result[i] = try self.allocator.dupe(u8, item);
        }
        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ConfigLoader initialization" {
    const allocator = std.testing.allocator;
    const loader = ConfigLoader.init(allocator);
    _ = loader;
}
test "ConfigLoader loadFromEnv with missing API key" {
    const allocator = std.testing.allocator;
    var loader = ConfigLoader.init(allocator);

    // This should fail if NVIDIA_API_KEY is not set
    const result = loader.loadFromEnv();
try std.testing.expectError(error.MissingApiKey, result);
}

test "ConfigLoader mergeConfigs with defaults" {
    const allocator = std.testing.allocator;
    var loader = ConfigLoader.init(allocator);

    var result = try loader.mergeConfigs(null, null, null);
    defer result.deinit();

    try std.testing.expectEqual(ConfigSource.default, result.source);
    try std.testing.expectEqualStrings("qwen/qwen3.5-397b-a17b", result.primary_model);
    try std.testing.expectEqual(@as(u32, 18789), result.gateway_port);
}
