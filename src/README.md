# src

## Overview

Zig sources for the ZeptoClaw process. `main.zig` dispatches the CLI. `root.zig` re-exports the packages below so `zig build test` compiles their tests. `build.zig` (repository root) turns these files into the installed binaries.

## Interface

Column-0 public declarations in this directory:

- `compat.zig:homeJoin`, `getEnvVarOwned`, `getSelfExeDir`, `getArgsAlloc`, `freeArgs`, `timestamp`, `Dir`, `io`, `getIo`, `fillRandom`, `randomInt`, `cwd`, `streamWriteAll`, `osEnviron`, `threadedIoWithOsEnviron`, `runParentEnv` — process, path, and child-spawn helpers. `runParentEnv` runs a child with the parent environment.
- `config.zig:Config` — legacy wrapper. Methods on that struct: `load`, `loadForPairing`, `loadWithArgs`, `loadFromFile`, `deinit`, `getPrimaryModel`, `getFallbackModels`, `getImageModel`, `getVisionModel`, `isFromFile`, `isFromEnv`, `isFromCli`.
- `config.zig:ConfigSource`, `ConfigLoader`, `ZeptoClawConfig`, `OpenClawConfig` — re-exports of `config/migration_config.zig`.
- `fuzz_mutate.zig:builtin_seeds`, `runHavoc` — seeded havoc mutations for parser exercises.
- `main.zig:main` — `whatsapp pair` and `channels login` call `pairing.runPairing`; `memory update`/`rewrite` and `memory compact`/`compress` call the memory jobs; `fuzz` calls `runHavoc`; otherwise `Config.load` and the interactive agent.
- `root.zig:providers`, `agent`, `channels`, `config`, `validator`, `compat`, `openclaw_compat`, `fuzz_mutate`, `autonomous`, `gateway`, `skills` — package re-exports.
- `root.zig:printAnotherMessage`, `add` — test helpers.

Child contracts:

- [agent](./agent/README.md) — NIM tool-use loop, workspace tools, IST journals, transcripts, cron.
- [autonomous](./autonomous/README.md) — Moltbook action loop, HTTP client, rate limit, JSON state.
- [channels](./channels/README.md) — terminal REPL and the WhatsApp channel.
- [config](./config/README.md) — OpenClaw-shaped JSON load and validation.
- [gateway](./gateway/README.md) — HTTP gateway, token auth, session store, turn watchdog.
- [openclaw_compat](./openclaw_compat/README.md) — legacy path and allowlist helpers, no npm runtime.
- [providers](./providers/README.md) — NIM client, health, and fallback routing.
- [services](./services/README.md) — webhook server and Shell2HTTP monitor.
- [skills](./skills/README.md) — skill loader, registry, and bundled skills.
- [tools](./tools/README.md) — `wa_pair` and `wa_send` CLIs.

## Invariants

- `main.zig:main` — `fuzz` uses `compat.timestamp` as the seed and defaults to 50000 iterations.
- `config.zig:loadForPairing` — pairing load does not require `NVIDIA_API_KEY`.
- `root.zig` — the `is_test` block imports modules so their tests run under `zig build test`.

## Side Effects

- `main.zig:main` — may pair WhatsApp, rewrite memory files, run fuzz, or start the interactive agent.
- `fuzz_mutate.zig:runHavoc` — writes and reads `/tmp/zeptoclaw-fuzz-pending.jsonl` and runs in-memory parsers.
- `compat.zig:runParentEnv` — spawns a child process.
- `config.zig:Config.load` — reads environment and config files; `deinit` frees the owned strings.

## Verification

- Run: `zig build test`
