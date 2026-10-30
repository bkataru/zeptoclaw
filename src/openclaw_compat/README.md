# openclaw_compat

## Overview

File-format and path bridge from legacy OpenClaw layouts to ZeptoClaw without importing the npm OpenClaw runtime. `openclaw.zig` resolves config and workspace locations (Zepto primary, OpenClaw legacy), exposes systemd/journal helpers for gateway services, maps legacy HTTP gateway path aliases, and normalizes phone allowlist matching for config parity.

## Interface

- `openclaw.zig:primary_config_home_rel` — Home-relative Zepto config path list (`.zeptoclaw/config.json`).
- `openclaw.zig:cwd_config_paths` — Cwd-relative config filenames (`./zeptoclaw.json`, `./config.json`).
- `openclaw.zig:legacy_config_home_rel` — Legacy OpenClaw JSON paths under home.
- `openclaw.zig:dirExists` — Returns whether a path is an existing directory (absolute or relative; empty path is false).
- `openclaw.zig:resolveWorkspaceDir` — Returns owned path to existing `~/.zeptoclaw/workspace` or falls back to `~/.openclaw/workspace`.
- `openclaw.zig:findExistingConfig` — Returns owned path to first existing config file (Zepto home, then cwd, then legacy home) or null.
- `openclaw.zig:getHomeDir` — Returns owned `HOME` environment value.
- `openclaw.zig:primary_gateway_service` — Systemd unit name `zeptoclaw-gateway.service`.
- `openclaw.zig:legacy_gateway_service` — Legacy unit name `openclaw-gateway.service`.
- `openclaw.zig:gatewayServiceVariants` — Ordered pair of service names to try (primary then legacy).
- `openclaw.zig:journalGatewayArgs` — Fixed argv slice for `journalctl --user -u <service> -n 50`.
- `openclaw.zig:legacyCredentialsDir` — Owned `~/.openclaw/credentials` path.
- `openclaw.zig:primaryCredentialsDir` — Owned `~/.zeptoclaw/credentials` path.
- `openclaw.zig:legacySessionsDir` — Owned legacy agent sessions directory path.
- `openclaw.zig:primarySessionsDir` — Owned `~/.zeptoclaw/sessions` path.
- `openclaw.zig:isLegacyGatewayAlias` — True for `/gateway/health`, `/gateway/state`, `/gateway/status`.
- `openclaw.zig:canonicalizeGatewayPath` — Maps legacy `/gateway/*` paths to `/health`, `/state`, `/status`; other paths unchanged.
- `openclaw.zig:normalizeE164Digits` — Allocates digits-only string from an E.164-like input (non-digits stripped).
- `openclaw.zig:isAllowFromMatch` — True if candidate E.164 digits match any `allow_from` entry (digits-only compare).

## Invariants

- `openclaw.zig:findExistingConfig` — Search order prefers Zepto home config, then cwd configs, then legacy home configs.
- `openclaw.zig:resolveWorkspaceDir` — Prefers `~/.zeptoclaw/workspace` when that directory exists; otherwise returns path to `~/.openclaw/workspace` (even if missing).
- `openclaw.zig:dirExists` — Must not panic on relative paths (uses cwd `openDir`, not absolute-only APIs).
- `openclaw.zig:canonicalizeGatewayPath` — Legacy alias paths map one-to-one to canonical gateway routes documented in source comments.

## Side Effects

- `openclaw.zig:dirExists` — Opens and closes a directory handle via the process IO interface.
- `openclaw.zig:findExistingConfig` — Opens candidate config files for existence checks; allocates and returns an owned path (caller must free) or frees failed probe paths.
- `openclaw.zig:resolveWorkspaceDir` — Allocates workspace path strings; may free an unused Zepto candidate before returning legacy path.
- `openclaw.zig:normalizeE164Digits` — Allocates a new slice on the supplied allocator.
- `openclaw.zig:getHomeDir` and path helper functions — Read `HOME` and allocate formatted path strings.

## Verification

- Run: `zig build test`
