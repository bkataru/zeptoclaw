# config

## Overview

Loads and merges ZeptoClaw runtime settings from OpenClaw-shaped JSON files, environment variables, and optional CLI overrides. `migration_config.zig` defines the OpenClaw JSON schema, the flattened `ZeptoClawConfig`, and `ConfigLoader` with priority CLI > env > file > defaults. `validator.zig` provides aggregate validation (bitfield results and optional process exit) for any config-shaped struct via `anytype`.

## Interface

- `migration_config.zig:DEFAULT_VISION_MODEL` — Default multimodal model id used when vision model is absent in file config or env.
- `migration_config.zig:ConfigSource` — Enum tagging which layer won the merge: `cli`, `env`, `file`, or `default`.
- `migration_config.zig:OpenClawConfig` — JSON-deserializable OpenClaw-compatible config tree (meta, env, models, agents, gateway, skills, channels, tools, hooks, diagnostics, update, auth, messages, commands, plugins).
- `migration_config.zig:ZeptoClawConfig` — Owned runtime config (API key, models, gateway, workspace, WhatsApp fields, `source`); `deinit` frees allocator-owned slices.
- `migration_config.zig:ConfigLoader` — Loader with `CliArgs`, `init`, `load`, `loadForPairing`, and `mergeConfigs`.
- `validator.zig:ValidationResult` — Packed struct of validation failure flags; `hasErrors` and `errorCount` inspect the bitfield.
- `validator.zig:printErrorMessages` — Writes human-readable lines for each set flag in a `ValidationResult`.
- `validator.zig:validate` — Returns a `ValidationResult` for a config-like `anytype` without exiting.
- `validator.zig:validateOrExit` — Runs `validate` and exits the process with code 1 on failure after printing messages.

## Invariants

- `migration_config.zig:ConfigLoader` — Full `load` calls `validateConfig`, which requires non-empty `api_key` and `primary_model`, `gateway_port` in 1–65535, positive `nim_timeout_ms`, `max_concurrent`, `max_iterations`, `max_tokens`, non-empty `workspace`, and `temperature` in 0.0–1.0 inclusive.
- `migration_config.zig:ConfigLoader` — `loadForPairing` merges file/default config only (no env, no API-key validation) so WhatsApp QR pairing works without `NVIDIA_API_KEY`.
- `migration_config.zig:ConfigLoader` — Env model fields override file only when `NVIDIA_MODEL` was explicitly set (`env_model_explicit`); the vision model overrides on its own gate (`env_vision_explicit`, set when `NVIDIA_VISION_MODEL` is present) and never drags primary/fallbacks/budget/timeout along. API key and gateway/infra fields still prefer env when present.
- `migration_config.zig:ConfigLoader` — Default config file probe order: home `.zeptoclaw/config.json`, then legacy `.openclaw/openclaw.json` paths, then cwd `./zeptoclaw.json` and `./config.json`.
- `validator.zig:validate` — Same shape checks as loader validation for core fields; `temperature` allowed 0.0–2.0 inclusive; WhatsApp `whatsapp_debounce_ms` must be 0 or ≥ 100; `whatsapp_media_max_mb` must be > 0.

## Side Effects

- `migration_config.zig:ConfigLoader` — `load` / `loadFromFile` / `loadFileDefault` read config JSON from disk; `loadFromEnv` reads process environment variables; merge and load paths allocate duplicated strings owned by the returned `ZeptoClawConfig`.
- `migration_config.zig:ZeptoClawConfig` — `deinit` frees all allocator-owned fields on the config.
- `validator.zig:printErrorMessages` — Writes formatted lines to the supplied writer (errors on write are swallowed).
- `validator.zig:validateOrExit` — Prints to stderr via `std.debug` and calls `std.process.exit(1)` when validation fails.

## Verification

- Run: `zig build test`
