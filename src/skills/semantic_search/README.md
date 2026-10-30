# Semantic Search

## Overview

Command skill for local semantic memory search using Ollama embeddings: index build, query search, and model info are simulated with fixed sample chunks and scores. Config controls Ollama URL, embedding model, embeddings file path, and result count. Details in [./SKILL.md](./SKILL.md).

## Interface

- `skill.zig:skill` — exported skill struct with default Ollama URL, model `nomic-embed-text`, embeddings path, and `top_results = 5`.
- `skill.zig:skill.init` — no-op.
- `skill.zig:skill.execute` — requires `ctx.command`; routes `embed-index`, `embed-search`, `embed-model`, `help`; `embed-search` requires `ctx.args` as query string.
- `skill.zig:skill.deinit` — no-op.
- `skill.zig:skill.getMetadata` — name `semantic-search`, category `search`, triggers for search/embed/memory-related mentions and commands.

## Invariants

- `skill.zig:parseConfig` — optional JSON overrides `ollama_url`, `embedding_model`, `embeddings_file`, `top_results` (integer cast via `std.math.cast`).
- `skill.zig:handleIndex` — prints fixed chunk counts and writes narrative path `cfg.embeddings_file`; does not read filesystem.
- `skill.zig:handleSearch` — prints exactly `cfg.top_results` as match count header but always emits five hard-coded result lines.
- `skill.zig:handleModel` — reports current model from config and static list of alternative models.

## Side Effects

- `skill.zig:skill.execute` — returns allocated success messages only; no HTTP to Ollama and no write to `embeddings_file` in code.
- None — no `ctx.respond` in this module.

## Verification

- Run: `zig build test`
