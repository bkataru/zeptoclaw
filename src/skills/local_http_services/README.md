# Local HTTP Services

## Overview

ZeptoClaw skill that maps chat slash commands to placeholder reports mimicking local webhook and Shell2HTTP health and system probes (uptime, memory, disk, timers, git status, journal). Configuration selects ports and enable flags per execution. See [./SKILL.md](./SKILL.md).

## Interface

- `skill.zig:skill` — Exported skill module struct.
- `skill.zig:skill.init` — No-op initializer.
- `skill.zig:skill.execute` — Requires message content; handles `/http-health`, `/http-uptime`, `/http-memory`, `/http-disk`, `/http-timers`, `/http-git-status`, `/http-journal`; otherwise empty success.
- `skill.zig:skill.deinit` — No-op.
- `skill.zig:skill.getMetadata` — Metadata `id` `local-http-services`, version `1.0.0`, enabled.

## Invariants

- `skill.zig:skill.execute` — Returns error result when message content is missing.
- `skill.zig:parseConfig` — Defaults: `webhook_port` 9000, `shell2http_port` 9001, `webhook_secret_path` `~/.zeptoclaw/.webhook-secret`, `enable_webhook` and `enable_shell2http` true.
- `skill.zig:handleHealth` — Formatted status references configured webhook and Shell2HTTP ports (does not perform HTTP in current code).
- `skill.zig:handleJournal` — Empty service name after prefix yields usage error via `SkillResult.errorResponse`.
- `skill.zig:handleUptime`, `handleMemory`, `handleDisk`, `handleTimers`, `handleGitStatus` — Static placeholder text (comments note real implementation would query HTTP endpoints).

## Side Effects

- `skill.zig:skill.execute` — Calls `ctx.respond` with allocated formatted strings for handled commands.
- `skill.zig:leakedHome` — May allocate default secret path via page allocator.

## Verification

- Run: `zig build test`
