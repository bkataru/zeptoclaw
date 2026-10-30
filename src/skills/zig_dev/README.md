# Zig Development

## Overview

Native ZeptoClaw skill module for Zig workflow helpers: build, test, documentation generation, and clean artifacts. Slash commands in message content select the handler; JSON config sets Zig binary path, optimize mode, target triple, and WASM enable flag. Responses are formatted stubs (comments note real runs would invoke `zig build` and related commands). See [./SKILL.md](./SKILL.md) for project conventions and command reference.

## Interface

- `skill.zig:skill` — Public skill module struct exported to the skill loader.
- `skill.zig:skill.init` — No global initialization; ignores allocator and config at init time.
- `skill.zig:skill.execute` — Routes `/zig-build`, `/zig-test`, `/zig-docs`, and `/zig-clean`; empty success when no command matches.
- `skill.zig:skill.deinit` — No-op teardown.
- `skill.zig:skill.getMetadata` — Returns id `zig-dev`, name `Zig Development`, version `1.0.0`, `enabled = true`.

## Invariants

- `skill.zig:skill.execute` — Absent message content yields error result `"No message content"`.
- `skill.zig:skill.execute` — Non-command messages yield empty success response.
- `skill.zig:skill.parseConfig` — Defaults: `zig_path` `"zig"`, `optimize_mode` `"ReleaseFast"`, `target_triple` `"native"`, `enable_wasm = true` when config is not a JSON object or keys are missing or wrong type.
- `skill.zig:handleBuild` — Trims optional arguments after `/zig-build` into the printed command line.
- `skill.zig:handleTest` — Uses trimmed pattern after `/zig-test` or empty string in the formatted test command.
- `skill.zig:handleClean` — Does not read config; fixed artifact paths `zig-cache/` and `zig-out/` in the response text.

## Side Effects

- `skill.zig:handleBuild` — `ctx.respond` with stub build success output referencing `cfg.zig_path`, args, `target_triple`, and `optimize_mode`.
- `skill.zig:handleTest` — `ctx.respond` with stub test summary using `cfg.zig_path` and optional pattern.
- `skill.zig:handleDocs` — `ctx.respond` with stub docs paths under `./zig-out/docs/`.
- `skill.zig:handleClean` — `ctx.respond` with stub removal listing for cache and output dirs (no filesystem deletes in code).
- `skill.zig:skill.getMetadata` — Metadata hash map initialized on `std.heap.page_allocator`.

## Verification

- Run: `zig build test`
