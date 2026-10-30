# skills

## Overview

Core ZeptoClaw skills framework: shared types and errors (`types.zig`), disk loading from `SKILL.md` (`skill_loader.zig`), registration and enablement (`skill_registry.zig`), message/cron/event trigger matching (`triggers.zig`), runtime context and tool access for handlers (`execution_context.zig`), and the developer-facing SDK re-exports plus builders (`skill_sdk.zig`). Individual command modules live in child directories; each ships its own `skill.zig` and operator docs in `SKILL.md`.

## Interface

- `execution_context.zig:ExecutionContext` — Per-invocation context: message, session, JSON config, tools, and `respond` callback.
- `execution_context.zig:LogLevel` — Skill log severity enum (`debug`, `info`, `warn`, `err`).
- `execution_context.zig:ToolRegistry` — Named tool definitions and mock `call` dispatch.
- `execution_context.zig:ToolDefinition` — Tool name, description, JSON parameters, and handler fn.
- `execution_context.zig:SkillResult` — Success/error/stop result with optional response text and `should_continue`.
- `skill_loader.zig:SkillLoader` — Search paths, load directories with `SKILL.md`, parse metadata/triggers/config.
- `skill_registry.zig:SkillRegistry` — Register, enable/disable, lookup, and export skills loaded from disk or code.
- `skill_sdk.zig:SkillMetadata` — Re-export of `types.SkillMetadata` for skill authors.
- `skill_sdk.zig:Trigger` — Re-export of `types.Trigger`.
- `skill_sdk.zig:TriggerType` — Re-export of `types.TriggerType`.
- `skill_sdk.zig:ConfigSchema` — Re-export of `types.ConfigSchema`.
- `skill_sdk.zig:ConfigField` — Re-export of `types.ConfigField`.
- `skill_sdk.zig:FieldType` — Re-export of `types.FieldType`.
- `skill_sdk.zig:ExecutionContext` — Re-export of `execution_context.ExecutionContext`.
- `skill_sdk.zig:SkillResult` — Re-export of `execution_context.SkillResult`.
- `skill_sdk.zig:Skill` — Runtime skill vtable: `init`, `execute`, `deinit`, `getMetadata`.
- `skill_sdk.zig:SkillBuilder` — Fluent builder for metadata, triggers, and config schema → `types.Skill`.
- `skill_sdk.zig:SkillHelpers` — Trigger factories, arg splitting, and response formatting helpers.
- `triggers.zig:TriggerMatcher` — Mention, command, and wildcard pattern matching on message text.
- `triggers.zig:TriggerScheduler` — Cron-style `shouldFire` for scheduled triggers.
- `triggers.zig:TriggerEvent` — Event-type equality for event triggers.
- `types.zig:SkillMetadata` — Parsed `SKILL.md` identity fields and enable flag.
- `types.zig:TriggerType` — Activation kind enum and string conversion.
- `types.zig:Trigger` — Trigger payload (pattern, cron, or event type).
- `types.zig:ConfigSchema` — Map of configuration field names to `ConfigField`.
- `types.zig:ConfigField` — Single config field type, description, required/default.
- `types.zig:FieldType` — Config value type enum and string parsing.
- `types.zig:Skill` — Loaded skill record: metadata, triggers, schema, and directory path.
- `types.zig:SkillError` — Shared error set for registry, load, and execution failures.

### Bundled skills

- [`./adhd_workflow/README.md`](./adhd_workflow/README.md) — ZeptoClaw skill module that turns overwhelming tasks into short, actionable text responses.
- [`./dirmacs_docs/README.md`](./dirmacs_docs/README.md) — ZeptoClaw skill for searching and listing a JSON documentation index for DirMacs projects.
- [`./discovery/README.md`](./discovery/README.md) — ZeptoClaw skill that persists “interesting finds” in a JSON file (default `memory/interesting-finds.json`): add, list, search, mark shared, delete, and stats.
- [`./gateway_watchdog/README.md`](./gateway_watchdog/README.md) — ZeptoClaw skill that answers slash-style messages about gateway session health (status, check, logs, threshold).
- [`./git_workflow/README.md`](./git_workflow/README.md) — ZeptoClaw skill that interprets chat messages starting with `/git-status`, `/git-commit`, `/git-push`, `/git-pull`, and `/git-branch`.
- [`./github/README.md`](./github/README.md) — ZeptoClaw skill for GitHub-themed slash commands (`/gh-issue`, `/gh-pr`, `/gh-repo`, `/gh-release`) when a `github_token` is present in config.
- [`./github_stars/README.md`](./github_stars/README.md) — ZeptoClaw skill that exposes slash commands to search, summarize, and sync a local index of GitHub starred repositories.
- [`./knowledge_base/README.md`](./knowledge_base/README.md) — ZeptoClaw skill for searching and displaying notes from an Obsidian/Zettelkasten vault using a JSON vault index.
- [`./local_http_services/README.md`](./local_http_services/README.md) — ZeptoClaw skill that maps chat slash commands to placeholder reports mimicking local webhook and Shell2HTTP health and system probes.
- [`./local_llm/README.md`](./local_llm/README.md) — ZeptoClaw skill for local LLM workflows (Ollama-oriented): listing models, run/chat/pull placeholders, RAM/task recommendations, and RAM estimation from model name heuristics.
- [`./memory_tree_search/README.md`](./memory_tree_search/README.md) — ZeptoClaw skill for vectorless, tree-oriented search over agent memory files (`MEMORY.md`, dated notes, relationships JSON).
- [`./moltbook/README.md`](./moltbook/README.md) — ZeptoClaw skill for the Moltbook agent social network: post, comment, upvote, feed, and profile slash commands with API key gating.
- [`./moltbook_heartbeat/README.md`](./moltbook_heartbeat/README.md) — ZeptoClaw skill module for automated Moltbook engagement: scheduled heartbeats, comment checks, Cloudflare worker pings, and slash-command diagnostics.
- [`./nufast_physics/README.md`](./nufast_physics/README.md) — Command-driven skill that documents and simulates NuFast neutrino-oscillation library workflows (Rust release build, Zig optimized build, tests, benchmarks, WASM).
- [`./operational_safety/README.md`](./operational_safety/README.md) — Message-based security skill: prompt-injection heuristics, dangerous-shell substring checks, and slash commands for safety status and identity/auth reporting.
- [`./planckeon_sites/README.md`](./planckeon_sites/README.md) — Command skill for Planckeon static-site workflows: Zola build/serve simulation and GitHub Pages deploy narrative.
- [`./rust_cargo/README.md`](./rust_cargo/README.md) — Message-prefix skill for Rust/Cargo workflows: simulated build, test, publish, and clean operations driven by slash commands in message content.
- [`./semantic_search/README.md`](./semantic_search/README.md) — Command skill for local semantic memory search using Ollama embeddings: index build, query search, and model info are simulated with fixed sample chunks and scores.
- [`./web_qa/README.md`](./web_qa/README.md) — Native ZeptoClaw skill module for web-app debugging workflows: headless screenshot planning, CDN header checks, and SRI integrity verification.
- [`./wsl_troubleshooting/README.md`](./wsl_troubleshooting/README.md) — Native ZeptoClaw skill module for WSL2 operational checks and guided fixes: DNS resolv.conf workflow, systemd status summary, network diagnostics, and restart instructions.
- [`./zig_dev/README.md`](./zig_dev/README.md) — Native ZeptoClaw skill module for Zig workflow helpers: build, test, documentation generation, and clean artifacts.

## Invariants

- `skill_loader.zig:SkillLoader.loadSkill` — Returns `null` when `SKILL.md` is missing; otherwise requires valid frontmatter with string `name` and `description`.
- `skill_loader.zig:SkillLoader.parseSkillMetadata` — Skill `id` is the basename of the skill directory, not the frontmatter name.
- `skill_registry.zig:SkillRegistry.register` — Inserts a duplicated skill; enables it when `metadata.enabled` is true.
- `skill_registry.zig:SkillRegistry.enable` / `disable` — Return `SkillError.SkillNotFound` when the id is not registered.
- `skill_registry.zig:SkillRegistry.findByTriggerType` — Only includes skills that are enabled and declare at least one matching trigger type.
- `triggers.zig:TriggerMatcher.matches` — `scheduled` and `event` trigger types return errors from message matching (use scheduler/event helpers instead).
- `triggers.zig:TriggerMatcher.matchCommand` — Command pattern must match at the start of trimmed message text.
- `types.zig:TriggerType.fromString` — Accepts only `mention`, `command`, `pattern`, `scheduled`, and `event`.
- `types.zig:Skill.dupe` — Deep-copies metadata and triggers; config schema is shallow-copied.

## Side Effects

- `skill_loader.zig:SkillLoader.loadAll` / `loadSkill` — Reads skill directories and `SKILL.md` from disk (warns and skips on open/parse failures).
- `skill_loader.zig:SkillLoader.findSection` — Allocates section header strings via page allocator when parsing markdown sections.
- `skill_registry.zig:SkillRegistry.loadFromLoader` — Loads all skills from a loader then registers each (loader list freed after register).
- `skill_registry.zig:SkillRegistry.exportState` — Allocates JSON array of skill id/name/enabled/version.
- `execution_context.zig:ExecutionContext.log` — Prints to stderr via `std.log.print`.
- `execution_context.zig:ExecutionContext.respond` — Invokes injected `send_response` callback.
- `execution_context.zig:ToolRegistry.call` — Allocates a formatted mock tool response string.
- `skill_sdk.zig:SkillBuilder.build` — Transfers ownership of triggers and schema into a new `types.Skill`; resets builder lists.

## Verification

- Run: `zig build test`
