# src (utilities)

## Overview

Shared types, timing constants, model catalog metadata, and pure helpers extracted from the worker for reuse and typechecking. The worker imports these symbols in `worker.ts`; runtime routing uses a separate in-worker `MODELS` list (single Inkling entry) while `utils.ts:MODELS` retains a broader fallback catalog.

## Interface

- `utils.ts:isSimilarContent` — Jaccard word-set similarity between two strings; optional `threshold` (default `0.7`).
- `utils.ts:calculateCooldown` — Cooldown milliseconds from `consecutiveFailures` using exponential backoff.
- `utils.ts:isModelHealthy` — Returns whether `health.cooldownUntil` is before `now`.
- `utils.ts:getDefaultHealth` — Fresh `ModelHealth` record (zeros).
- `utils.ts:getDefaultBarvisState` — Fresh `BarvisState` with empty collections and optional heartbeat fields.
- `utils.ts:flattenComments` — Depth-first flatten of nested `MoltbookComment.replies`.
- `utils.ts:findUnrepliedCommentsFromList` — Filters comments needing a Barvis reply given `repliedComments` and `agentId`.
- `utils.ts:ModelHealth` — Interface for per-model failure, cooldown, latency, and request counters.
- `utils.ts:MoltbookComment` — Interface for Moltbook comment tree nodes.
- `utils.ts:HeartbeatData` — Interface for gateway heartbeat payloads stored in state.
- `utils.ts:BarvisState` — Interface for persisted Barvis/ZeptoClaw social and health state.
- `utils.ts:MODELS` — Constant array of NVIDIA model id/name/maxTokens/priority metadata.
- `utils.ts:COOLDOWN_BASE_MS` — Base cooldown duration (60_000 ms).
- `utils.ts:COOLDOWN_MAX_MS` — Maximum cooldown cap (600_000 ms).
- `utils.ts:LOCAL_AGENT_TIMEOUT_MS` — Local agent liveness window (60 minutes).
- `utils.ts:POST_COOLDOWN_MS` — Minimum spacing between autonomous posts (4 hours).
- `utils.ts:BROWSE_COOLDOWN_MS` — Minimum spacing between browse actions (25 minutes).

## Invariants

- `utils.ts:isSimilarContent` — Normalizes to lowercase alphanumeric words; returns false when union size is 0; similarity is intersection/union.
- `utils.ts:calculateCooldown` — Uses `COOLDOWN_BASE_MS * 2^(consecutiveFailures - 1)` bounded by `COOLDOWN_MAX_MS`.
- `utils.ts:isModelHealthy` — Model is healthy iff `cooldownUntil < now`.
- `utils.ts:findUnrepliedCommentsFromList` — Excludes agent-authored comments, ids in `repliedComments`, comments with an agent child reply, and non-top-level threads unless parent is agent-authored.
- `utils.ts:getDefaultBarvisState` — `last_action` defaults to `null`; heartbeat-related arrays default empty or undefined as coded.

## Side Effects

- None.

## Verification

- Run: `npm run typecheck` (from `cloudflare-worker/`; `package.json` defines `typecheck` as `tsc --noEmit` and has no `test` script).
