# providers

## Overview

The `src/providers` package implements LLM provider integration for Zeptoclaw: shared chat/request types, a catalog of model metadata with priority tiers, per-model health and cooldown tracking, fallback routing across primary and alternate models, an HTTP client for NVIDIA NIM chat completions (with pacing, retries, and fallback rotation), and a separate streaming NIM client for Server-Sent Events. `model_pool.zig` re-exports `provider_pool` symbols for compatibility.

## Interface

- `fallback_router.zig:SelectionStrategy` — Enum of model selection modes: `priority_only`, `health_aware`, `health_first`, `round_robin`, and `random`.
- `fallback_router.zig:FallbackRouter` — Router that borrows a `ModelPool` and `HealthTracker`, owns duped primary/fallback model id strings, and selects models according to `strategy`.
- `fallback_router.zig:RouterStats` — Aggregate counts and success rate returned by `FallbackRouter.getStats`.
- `health_tracker.zig:ModelError` — Failure categories for health recording; `fromHttpStatus` maps HTTP status codes to variants.
- `health_tracker.zig:CooldownDuration` — Default cooldown seconds per `ModelError`; `getDuration` selects the value for a given error.
- `health_tracker.zig:HealthStatus` — `healthy`, `degraded`, `unhealthy`, or `cooldown` derived from score via `fromScore`.
- `health_tracker.zig:ModelHealth` — Per-model counters, cooldown deadline, health score, and latency EMA; updated via `recordSuccess`, `recordFailure`, and `calculateHealthScore`.
- `health_tracker.zig:HealthTracker` — String-keyed map of `ModelHealth`; exposes availability filtering and health-sorted model lists.
- `model_pool.zig:ModelPool` — Alias of `provider_pool.ModelPool`.
- `model_pool.zig:ModelMetadata` — Alias of `provider_pool.ModelMetadata`.
- `model_pool.zig:PriorityTier` — Alias of `provider_pool.PriorityTier`.
- `model_pool.zig:ApiType` — Alias of `provider_pool.ApiType`.
- `nim.zig:nextBackoff` — Doubles global NIM backoff seconds, clamped between 2 and 180.
- `nim.zig:decayBackoff` — Halves global NIM backoff toward the minimum after success.
- `nim.zig:sleepAfterFailure` — Applies jittered sleep from global backoff, then increases backoff via `nextBackoff` (no-op in tests).
- `nim.zig:noteSuccess` — Decays global backoff and adjusts minimum inter-request gap after a successful NIM call.
- `nim.zig:NIMClient` — HTTP chat client for NVIDIA integrate API; holds config-borrowed key/model, optional `fallback_models`, and enforces RPM pacing plus retry/rotation in `chatWithTools`.
- `nim.zig:deinit` — Frees `NIMClient` HTTP client resources (borrowed key/model/base_url unchanged).
- `nim.zig:tryParseCompletion` — Parses JSON bytes into `types.ChatCompletionResponse` with unknown fields ignored.
- `provider_pool.zig:PriorityTier` — Five-tier priority enum; `fromInt` maps 1–5 or defaults invalid values to `tier_5`.
- `provider_pool.zig:ApiType` — `openai_completions`, `openai_chat`, or `custom`; `toString` yields API label strings.
- `provider_pool.zig:ModelMetadata` — Owned metadata strings plus capability and rate-limit fields; freed with `deinit`.
- `provider_pool.zig:ModelPool` — Initialized catalog (default Inkling text model plus one vision/image model); lookup and filtered/sorted views by priority, tier, text, or image.
- `stream_nim.zig:StreamNIMClient` — Streaming chat completions over SSE to a fixed NVIDIA chat URL; optional cancel token.
- `types.zig:MessageRole` — Conversation roles with `toString` and `fromString`.
- `types.zig:FunctionCall` — Named function invocation payload with `deinit` and `dupe`.
- `types.zig:ToolCall` — Tool call id/type plus nested `FunctionCall`; `deinit` and `dupe`.
- `types.zig:ToolDefinition` — Tool schema for the LLM; owned name/description, borrowed JSON `parameters`.
- `types.zig:Message` — Chat message with optional content, media data URLs, and tool fields; `deinit`, `dupe`, `hasToolCalls`, and `user` constructor.
- `types.zig:Choice` — Completion choice with nested `Message` and optional `finish_reason`.
- `types.zig:Usage` — Token count summary (value type, no allocation).
- `types.zig:ChatCompletionResponse` — Parsed completion with owned id, model, and choices.
- `types.zig:ChatCompletionRequest` — Outbound completion request with owned model, messages, and optional tools.
- `types.zig:ProviderError` — Error set for network, auth, rate limit, invalid response, parse, and timeout failures.
- `types.zig:LLMProvider` — Vtable-style interface with a single `chat` function pointer.

## Invariants

- `fallback_router.zig:FallbackRouter.init` — Logs warnings when primary or fallback ids are missing from the pool but still constructs the router; default strategy is `health_aware`.
- `fallback_router.zig:FallbackRouter.selectModel` — Dispatches on `strategy`; returns `error.NoAvailableModels` when no candidate satisfies the active strategy (e.g. empty available set under `health_aware`).
- `fallback_router.zig:FallbackRouter.selectByPriority` — Skips vision models when falling back to highest-priority pool entry.
- `fallback_router.zig:FallbackRouter.getStats` — Models with no health history count as available in stats aggregation.
- `health_tracker.zig:ModelHealth.calculateHealthScore` — Score is success rate minus 0.1 per consecutive failure, clamped to [0, 1]; zero requests yields score 1.0.
- `health_tracker.zig:HealthStatus.fromScore` — Thresholds: ≥0.8 healthy, ≥0.5 degraded, ≥0.0 unhealthy, below 0 cooldown.
- `health_tracker.zig:HealthTracker.isModelAvailable` — Unknown models are available; cooldown or `unhealthy`/`cooldown` status makes a model unavailable.
- `health_tracker.zig:ModelHealth.recordFailure` — Sets `cooldown_until` from `CooldownDuration.getDuration` for the error type.
- `provider_pool.zig:ModelPool.init` — Seeds exactly two models: `thinkingmachines/inkling` (text) and Stable Diffusion 3.5 Large (vision).
- `provider_pool.zig:ModelPool.getTextModels` — Excludes entries with `supports_vision == true`.
- `nim.zig:NIMClient.isTransientErr` — Only `Timeout`, `RateLimit`, and `Network` are transient; auth and invalid response are not.
- `nim.zig:NIMClient.statusToProviderError` — Maps 401 to auth, 429 to rate limit, 5xx class to `Network`, other non-OK to `InvalidResponse`.
- `nim.zig:NIMClient.chatWithTools` — On success calls `setModel(primary)` to restore the configured primary model id for subsequent requests.
- `nim.zig:NIMClient.rotateModel` — After exhausting `fallback_models`, resets model to `primary` and clears rotation index (per-request recovery).
- `nim.zig:NIMClient.chatWithRetry` — Loops forever: transient errors retry without cap; non-transient errors increment a counter and return after `MAX_PERMANENT_ATTEMPTS` (3).
- `nim.zig:NIMClient.chatWithTools` — Retries transient failures without permanent cap; non-transient failures rotate model then abandon after 3 permanent failures, restoring `primary` before return; every second transient attempt may rotate model.
- `stream_nim.zig:StreamNIMClient.streamCompletion` — Non-OK HTTP status maps to `Auth`, `RateLimit`, or `InvalidResponse`; cancel token load `true` yields `Cancelled`.
- `types.zig:MessageRole.fromString` — Matching is case-sensitive; unknown strings return null.

## Side Effects

- `fallback_router.zig:FallbackRouter.init` — Allocates dupes of primary and fallback model id strings; emits `std.log.warn` for missing pool entries.
- `fallback_router.zig:FallbackRouter.selectModel` — Allocates and frees temporary slices from pool and health tracker queries.
- `fallback_router.zig:FallbackRouter.recordSuccess` / `recordFailure` — Mutates borrowed `HealthTracker` state.
- `fallback_router.zig:FallbackRouter.reset` — Clears health tracker and zeroes round-robin index.
- `fallback_router.zig:FallbackRouter.deinit` — Frees owned primary and fallback strings.
- `health_tracker.zig:HealthTracker.recordSuccess` / `recordFailure` — Inserts map entries with duped `model_id` keys; reads wall time via `compat.timestamp`.
- `health_tracker.zig:HealthTracker.getAvailableModels` / `getModelsByHealth` — Allocate caller-owned slices of borrowed `*ModelMetadata`.
- `health_tracker.zig:HealthTracker.resetHealth` / `clear` / `deinit` — Free owned model id strings and map storage.
- `provider_pool.zig:ModelPool.init` / `addModel` — Allocates owned metadata strings and hash map entries (addModel is private but used at init).
- `provider_pool.zig:ModelPool.deinit` — Frees all model strings and the model map.
- `provider_pool.zig:ModelPool.getModelsByPriority` / `getModelsByTier` / `getTextModels` / `getImageModels` — Allocate caller-owned pointer slices.
- `nim.zig:sleepAfterFailure` / `noteSuccess` / `paceForRpm` — Mutate global `g_nim_backoff_s`, `g_nim_min_gap_s`, and `g_nim_last_s` under `g_nim_pace_mu`; sleep via `nanosleep`.
- `nim.zig:NIMClient.chatWithTools` — Performs HTTP POST to `base_url`; logs info on success and warn on retry; calls `sleepAfterFailure` and may `setModel` for rotation or restore.
- `nim.zig:NIMClient.postOnceWithDeadline` — Spawns a worker thread, may detach on timeout (logged warn); allocates worker context and body copy.
- `nim.zig:NIMClient.postOnce` — Network I/O, logs HTTP error bodies, allocates and parses response into caller-owned `ChatCompletionResponse`.
- `nim.zig:deinit` — Destroys embedded `std.http.Client`.
- `stream_nim.zig:StreamNIMClient.streamCompletion` — HTTP POST with SSE read loop; invokes `onChunk` per delta; allocates JSON parse buffers.
- `stream_nim.zig:StreamNIMClient.deinit` — Destroys HTTP client.
- `types.zig` — `deinit`/`dupe` methods on message and completion types allocate and free allocator-owned strings and nested structures.

## Verification

- Run: `zig build test`
