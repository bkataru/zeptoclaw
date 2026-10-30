# Knowledge Base

## Overview

ZeptoClaw skill for searching and displaying notes from an Obsidian/Zettelkasten vault using a JSON vault index. Commands are routed via `ctx.command` (`index`, `search`, `show`, `list`, `tree`, `help`). See [./SKILL.md](./SKILL.md) for operator documentation.

## Interface

- `skill.zig:skill` — Exported skill module struct.
- `skill.zig:skill.init` — No-op initializer.
- `skill.zig:skill.execute` — Dispatches on `ctx.command`; unknown commands return `error.UnknownCommand`; missing command returns `error.NoCommand`.
- `skill.zig:skill.deinit` — No-op.
- `skill.zig:skill.getMetadata` — Metadata name `knowledge-base`, category `search`, command triggers `kb`, `knowledge`, `vault`, `obsidian`, and regex patterns for knowledge base / Obsidian / vault / zettelkasten.

## Invariants

- `skill.zig:parseConfig` — Defaults: `vault_path` `/mnt/c/Users/user/Documents/Obsidian Vault/`, `index_path` `memory/vault-index.json`, `auto_index` false.
- `skill.zig:loadIndex` — On missing index file, returns an empty in-memory index with `vault_path` from config rather than failing.
- `skill.zig:loadIndex` — Valid index JSON must be an object with `vaultPath` and `files` array; malformed index returns parse/validation errors.
- `skill.zig:handleIndex` — Returns a success message stating indexing is not fully implemented (placeholder counts).
- `skill.zig:handleSearch` — Requires `ctx.args`; substring-matches query against file path, name, folder, and header text.
- `skill.zig:handleShow` — Joins `vault_path` and args, expands path, reads note file up to 1 MiB into the result message.
- `skill.zig:handleList` — Optional `--folder <name>` in `ctx.flags` filters by `file.folder`; paths sorted before listing.
- `skill.zig:handleTree` — Builds folder-grouped tree output from indexed files; empty folder label shown as `(root)`.

## Side Effects

- `skill.zig:loadIndex` — Reads `cfg.index_path` from the current working directory via `compat.cwd().openFile`.
- `skill.zig:handleShow` — Opens and reads vault note files from disk.
- `skill.zig:handleSearch` — Allocates match lists and response buffers on `ctx.allocator`.
- `skill.zig:handleTree` — Allocates hash map and sorted folder/file lists for formatted output.

## Verification

- Run: `zig build test`
