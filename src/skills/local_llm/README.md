# Local LLM

## Overview

ZeptoClaw skill for local LLM workflows (Ollama-oriented): listing models, run/chat/pull placeholders, RAM/task recommendations, and RAM estimation from model name heuristics. Commands use `ctx.command` (`list`, `run`, `chat`, `pull`, `recommend`, `estimate`, `help`). See [./SKILL.md](./SKILL.md).

## Interface

- `skill.zig:skill` — Exported skill module struct (includes private `Config` and command handlers).
- `skill.zig:skill.init` — No-op initializer.
- `skill.zig:skill.execute` — Parses config then dispatches commands; unknown command returns `error.UnknownCommand`; missing command returns `error.NoCommand`.
- `skill.zig:skill.deinit` — No-op.
- `skill.zig:skill.getMetadata` — Metadata name `local-llm`, category `ai`, triggers `llm`, `ollama`, `local-llm`, and Ollama/GGUF/quantization patterns.

## Invariants

- `skill.zig:parseConfig` — Defaults: `ollama_host` `http://localhost:11434`, `default_model` `qwen3:4b`, `num_threads` 6, `num_ctx` 4096; overridden from JSON object fields when present.
- `skill.zig:handleRun` — Requires args with model and prompt (first token model, rest prompt); uses `default_model` if first token missing; empty prompt returns failure message.
- `skill.zig:handleChat` — Uses `ctx.args` as model name or falls back to `default_model`.
- `skill.zig:handlePull` — Requires `ctx.args` as model name.
- `skill.zig:handleRecommend` — Parses optional `--ram` and `--task` from `ctx.flags`; RAM buckets select hard-coded model lists; task string substrings select task-specific lists.
- `skill.zig:handleEstimate` — Parses model from first arg; optional `--ctx` in remainder; parameter size inferred from model name substrings; estimates Q4_K_M size and context overhead using `cfg.num_ctx` unless overridden.
- `skill.zig:handleList` — Returns static catalog text (not live Ollama API).

## Side Effects

- `skill.zig:skill.execute` — Allocates response strings on `ctx.allocator` for all command handlers; no HTTP or subprocess calls in current implementation.

## Verification

- Run: `zig build test`
