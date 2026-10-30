# Web App QA & Troubleshooting

## Overview

Native ZeptoClaw skill module for web-app debugging workflows: headless screenshot planning, CDN header checks, and SRI integrity verification. Message content drives slash commands; JSON config supplies Chrome paths, screenshot output directory, viewport, and virtual time budget. See [./SKILL.md](./SKILL.md) for operational runbooks and Chrome flags.

## Interface

- `skill.zig:skill` — Public skill module struct exported to the skill loader.
- `skill.zig:skill.init` — Accepts allocator and config JSON; no global initialization (config is parsed per execution).
- `skill.zig:skill.execute` — Reads message from `ExecutionContext`, parses config, dispatches `/web-screenshot`, `/web-check-cdn`, or `/web-check-sri`; returns empty success when no command prefix matches.
- `skill.zig:skill.deinit` — No-op teardown; no global resources to free.
- `skill.zig:skill.getMetadata` — Returns `SkillMetadata` with id `web-qa`, name `Web App QA & Troubleshooting`, version `1.0.0`, and `enabled = true`.

## Invariants

- `skill.zig:skill.execute` — Missing message content yields `SkillResult.errorResponse` with `"No message content"`.
- `skill.zig:skill.execute` — Non-matching messages yield `SkillResult.successResponse` with an empty string body.
- `skill.zig:skill.parseConfig` — When `ctx.config` is not a JSON object, defaults apply: Windows Chrome path, `/mnt/c/Users/user/Pictures/Screenshots`, viewport `1920x1080`, `virtual_time_budget` 8000 ms.
- `skill.zig:handleScreenshot` — Empty URL after `/web-screenshot` responds with usage text and returns an error result with the same message.
- `skill.zig:handleCheckCDN` — Empty URL after `/web-check-cdn` responds with usage text and returns an error result.
- `skill.zig:handleCheckSRI` — Requires two space-separated tokens after the command; otherwise usage error via respond + error result.

## Side Effects

- `skill.zig:skill.execute` — Allocates error/success responses through `SkillResult` and the context allocator.
- `skill.zig:handleScreenshot` — Calls `compat.timestamp()` for filename, allocates path strings, `ctx.respond` with formatted status (implementation comment: real run would invoke headless Chrome).
- `skill.zig:handleCheckCDN` — `ctx.respond` with stub CDN header diagnostics (no network I/O in this file).
- `skill.zig:handleCheckSRI` — `ctx.respond` with stub SRI hash comparison output.
- `skill.zig:skill.getMetadata` — Initializes metadata object hash map with `std.heap.page_allocator`.

## Verification

- Run: `zig build test`
