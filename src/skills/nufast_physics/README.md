# NuFast Physics

## Overview

Command-driven skill that documents and simulates NuFast neutrino-oscillation library workflows (Rust release build, Zig optimized build, tests, benchmarks, WASM). Handlers print illustrative command output rather than invoking `cargo` or `zig`. Triggers and physics context are described in [./SKILL.md](./SKILL.md).

## Interface

- `skill.zig:skill` — exported skill struct with nested `Config` defaults (`repo_path`, `zig_path`, `wasm_output`).
- `skill.zig:skill.init` — no-op; config parsed per execution.
- `skill.zig:skill.execute` — requires `ctx.command`; routes `nufast-build`, `nufast-test`, `nufast-bench`, `nufast-wasm`, and `help`; returns `error.NoCommand` or `error.UnknownCommand` for other input.
- `skill.zig:skill.getMetadata` — returns metadata name `nufast-physics`, category `physics`, author, mention/command/pattern triggers for nufast and neutrino-related text.

## Invariants

- `skill.zig:skill.execute` — command matching is exact equality via `std.mem.eql(u8, command, ...)`.
- `skill.zig:parseConfig` — merges optional JSON object fields `repo_path`, `zig_path`, `wasm_output` over struct defaults.
- `skill.zig:handleBuild` — includes `cfg.zig_path` in printed `cd` line; other handlers ignore `cfg` where marked unused.
- `skill.zig:handleTest` / `handleBench` / `handleWasm` / `handleHelp` — success responses use hard-coded benchmark and test counts, not live process output.

## Side Effects

- `skill.zig:skill.execute` — allocates response strings via `ArrayList` and returns `SkillResult` with `success = true` and owned message slice; does not run external build tools.
- None — no `ctx.respond` calls; message is only in returned `SkillResult`.

## Verification

- Run: `zig build test`
