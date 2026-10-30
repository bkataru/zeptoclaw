# discovery

## Overview

ZeptoClaw skill that persists “interesting finds” in a JSON file (default `memory/interesting-finds.json`): add, list, search, mark shared, delete, and stats. Global `config` and `data` are loaded in `init` and mutated across commands. See [./SKILL.md](./SKILL.md).

## Interface

- `skill.zig:skill` — Skill struct holding module-level `config` and optional `data`.
- `skill.zig:init` — Parses JSON config (`data_file`, `max_finds`, `auto_share_threshold`), duplicates `data_file` when overridden, then calls `loadData`.
- `skill.zig:execute` — Routes `add`, `list`, `search`, `mark-shared`, `delete`, `stats`, or `help`; returns `SkillResult` with messages (`data` null).
- `skill.zig:deinit` — Frees all loaded finds and custom `data_file` string if not the default path.
- `skill.zig:getMetadata` — Returns `sdk.SkillMetadata` name `discovery`, category `productivity`, command triggers `discovery`, `finds`, `interesting`, plus pattern triggers for interesting/found/discovered wording.

## Invariants

- `skill.zig:loadData` — Missing file creates empty finds with config copied from module `config`; existing file must have `finds` array and `config` object.
- `skill.zig:handleAdd` — Prunes oldest entries when count exceeds `max_finds`; new finds get a random hex UUID and ISO-like UTC timestamp from `compat.timestamp()`.
- `skill.zig:handleList` — Optional `ctx.flags` containing substring `unshared` filters to non-shared finds.
- `skill.zig:execute` — Assumes `data` is non-null after successful `init`.

## Side Effects

- `skill.zig:loadData` — Reads expanded `data_file` (up to 1 MiB) or initializes empty state.
- `skill.zig:saveData` — Creates parent directories and overwrites `data_file` with JSON after add, mark-shared, and delete.
- `skill.zig:handleAdd` — Uses `std.crypto.random` for UUID nibbles.

## Verification

- Run: `zig build test`
