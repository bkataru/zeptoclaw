# OpenClaw to ZeptoClaw file copy

## Overview

Optional. Copies credentials, sessions, memory, and webhook secrets from `~/.openclaw` to `~/.zeptoclaw`. `migrate-all.sh` runs the four step scripts in a fixed order; each step is also runnable on its own. Scripts use hard-coded paths under `/home/user/.openclaw` and `/home/user/zeptoclaw/` (see side effects).

The current gateway session store is `~/.zeptoclaw/sessions/whatsapp/native.sqlite`, not `~/.zeptoclaw/credentials/`.

## Interface

### `migrate-all.sh`

- `migrate-all.sh` — master entrypoint; parses CLI flags then runs child migrations in order.
- `migrate-all.sh:--dry-run` — prints which child scripts would run without invoking them.
- `migrate-all.sh:--force` — skips the check that `/home/user/.openclaw` exists before running children.

### `migrate-credentials.sh`

- `migrate-credentials.sh` — copies WhatsApp credential files from OpenClaw `credentials/` into ZeptoClaw `credentials/whatsapp/`, excluding `.webhook-secret` paths.

### `migrate-sessions.sh`

- `migrate-sessions.sh` — copies session artifacts (JSON, DB, logs, and other files) from OpenClaw `agents/main/sessions/` into ZeptoClaw `sessions/`.

### `migrate-memory.sh`

- `migrate-memory.sh` — recursively copies OpenClaw `workspace/memory/` into ZeptoClaw `memory/`.

### `migrate-secrets.sh`

- `migrate-secrets.sh` — copies OpenClaw `.webhook-secret` to ZeptoClaw `secrets/webhook-secret`, generates `secrets/webhook-secret.new`, and sets mode `600` on both when the source file exists.

## Invariants

- `migrate-all.sh:set -e` — any failing command in the master script aborts the run.
- `migrate-all.sh` — without `--force`, exits with status 1 when `/home/user/.openclaw` is not a directory.
- `migrate-all.sh` — unknown CLI options print an error and exit 1.
- `migrate-all.sh:SCRIPTS` — child order is credentials, sessions, memory, then secrets.
- `migrate-all.sh:--dry-run` — does not execute child scripts; only logs intended invocations.
- `migrate-credentials.sh:set -e` — aborts on command failure.
- `migrate-credentials.sh` — exits 1 when `/home/user/.openclaw/credentials` is missing.
- `migrate-credentials.sh` — skips paths whose names match `.webhook-secret` (handled by `migrate-secrets.sh`).
- `migrate-sessions.sh:set -e` — aborts on command failure.
- `migrate-sessions.sh` — exits 1 when `/home/user/.openclaw/agents/main/sessions` is missing.
- `migrate-memory.sh:set -e` — aborts on command failure.
- `migrate-memory.sh` — exits 1 when `/home/user/.openclaw/workspace/memory` is missing.
- `migrate-secrets.sh:set -e` — aborts on command failure.
- `migrate-secrets.sh` — when `/home/user/.openclaw/.webhook-secret` is absent, prints a warning and does not treat that as a hard failure (no `exit 1` on missing secret).

## Side Effects

- `migrate-all.sh` — when not dry-run, invokes `bash` on each child script under the script directory.
- `migrate-all.sh` — prints post-migration reminders referencing `/home/user/zeptoclaw/`.
- `migrate-credentials.sh` — `mkdir -p` on `/home/user/zeptoclaw/credentials/whatsapp` and `cp` of `*.json`, `*.env`, and other regular files from `/home/user/.openclaw/credentials`.
- `migrate-sessions.sh` — `mkdir -p` on `/home/user/zeptoclaw/sessions` and `cp` of session files into that tree (may overwrite same-named targets).
- `migrate-memory.sh` — `mkdir -p` on `/home/user/zeptoclaw/memory` and `cp -rv` of `/home/user/.openclaw/workspace/memory/.` into it.
- `migrate-secrets.sh` — `mkdir -p` on `/home/user/zeptoclaw/secrets`; may `cp` webhook secret, write `webhook-secret.new` via `openssl rand -hex 32` or `/dev/urandom` fallback, and `chmod 600` on secret files.

## Verification

These are shell scripts, not the Zig test suite.

- Run: `./migrate-all.sh --dry-run` from `scripts/migrate`.
- Run: `zig build test` for the repository.
