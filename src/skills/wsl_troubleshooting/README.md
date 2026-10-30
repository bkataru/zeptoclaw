# WSL2 Troubleshooting

## Overview

Native ZeptoClaw skill module for WSL2 operational checks and guided fixes: DNS resolv.conf workflow, systemd status summary, network diagnostics, and restart instructions. Commands are prefix-based on incoming message text; distro name, DNS servers, and systemd enable flag come from per-execution JSON config. See [./SKILL.md](./SKILL.md) for documented fixes and environment notes.

## Interface

- `skill.zig:skill` — Public skill module struct exported to the skill loader.
- `skill.zig:skill.init` — Accepts allocator and config JSON; no global state (config parsed per execution).
- `skill.zig:skill.execute` — Dispatches `/wsl-dns-fix`, `/wsl-systemd-check`, `/wsl-network-check`, or `/wsl-restart`; empty success when no prefix matches.
- `skill.zig:skill.deinit` — No-op; no global resources to free.
- `skill.zig:skill.getMetadata` — Returns metadata id `wsl-troubleshooting`, name `WSL2 Troubleshooting`, version `1.0.0`, `enabled = true`.

## Invariants

- `skill.zig:skill.execute` — Missing message content returns `SkillResult.errorResponse` with `"No message content"`.
- `skill.zig:skill.execute` — Unrecognized commands return `SkillResult.successResponse` with an empty string.
- `skill.zig:parseConfig` — Non-object config defaults to distro `Ubuntu`, DNS `8.8.8.8,1.1.1.1`, `enable_systemd = true`.
- `skill.zig:parseConfig` — Object fields `wsl_distro`, `dns_servers`, and `enable_systemd` override defaults when present with correct JSON types.
- `skill.zig:handleDNSFix` — Response text embeds configured `dns_servers` and instructs `wsl --shutdown` (stub; comment notes real impl would apply fix).

## Side Effects

- `skill.zig:skill.execute` — Parses config on each call; handlers allocate formatted responses and call `ctx.respond`.
- `skill.zig:handleDNSFix` — Emits scripted DNS-fix steps without modifying `/etc/resolv.conf` in code.
- `skill.zig:handleSystemdCheck` — Emits static service names and “Running” status using `cfg.wsl_distro`.
- `skill.zig:handleNetworkCheck` — Emits sample IPs, port forwards, and DNS status using `cfg.dns_servers`.
- `skill.zig:handleRestart` — Emits PowerShell `wsl --shutdown` guidance for `cfg.wsl_distro` without invoking WSL APIs.
- `skill.zig:skill.getMetadata` — Metadata object hash map allocated with `std.heap.page_allocator`.

## Verification

- Run: `zig build test`
