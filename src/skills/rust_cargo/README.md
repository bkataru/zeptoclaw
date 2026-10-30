# Rust Cargo

## Overview

Message-prefix skill for Rust/Cargo workflows: simulated build, test, publish, and clean operations driven by slash commands in message content. Config selects cargo binary path, workspace root, benchmark flag, and publish dry-run default. See [./SKILL.md](./SKILL.md) for operator documentation.

## Interface

- `skill.zig:skill` — exported Rust/Cargo development skill struct.
- `skill.zig:skill.init` — no-op; config parsed per execution.
- `skill.zig:skill.execute` — requires message content; handles prefixes `/cargo-build`, `/cargo-test`, `/cargo-publish`, `/cargo-clean`; otherwise returns empty success.
- `skill.zig:skill.deinit` — no-op.
- `skill.zig:skill.getMetadata` — id `rust-cargo`, version `1.0.0`, description covers build, test, publish, benchmarks, cross-compile (handlers implement build/test/publish/clean only).

## Invariants

- `skill.zig:parseConfig` — defaults `cargo_path = "cargo"`, `workspace_root = "."`, `enable_benchmarks = true`, `publish_dry_run = true` when JSON fields absent or wrong type.
- `skill.zig:handleBuild` — trailing message text after `/cargo-build` is passed as extra cargo build arguments in the formatted output.
- `skill.zig:handleTest` — optional filter suffix after `/cargo-test`; empty suffix still prints generic test run.
- `skill.zig:handlePublish` — appends `--dry-run` to printed command when `publish_dry_run` is true.
- `skill.zig:handleClean` — fixed narrative about removing `target/debug/` and `target/release/` without invoking cargo.

## Side Effects

- `skill.zig:skill.execute` — `ctx.respond` with allocated stub build/test/publish/clean transcripts; no subprocess execution.
- `skill.zig:skill.getMetadata` — metadata map uses `std.heap.page_allocator`.

## Verification

- Run: `zig build test`
