# Fix seven open zeptoclaw defects before Barvis runs

* **Author:** bkataru
* **Status:** Draft
* **Date:** 2026-10-31

## Overview

Terms used below: NIM is the NVIDIA inference HTTP API (`integrate.api.nvidia.com`) that `NIMClient` calls for chat; "parked model deadline" is the per-request wall-clock timeout (`timeout_ms`, default 300000 ms = 300 s) after which a model call is abandoned; a "stuck turn" is a WhatsApp turn still running past `turn_watch.zig`'s `DEFAULT_WARN_AFTER_S` (600 s), which only logs a warning; the seen ledger `gateway-inbound-ledger.json` records wire message ids (`seen_messages`/`seen_order`, capped at 2000, FIFO eviction) plus content fingerprints, and is used only by the live inbound path.

One gateway binary fixes seven bugs in how zeptoclaw handles WhatsApp turns, model calls, shutdown, and startup output. The checks for all seven are offline. The WhatsApp gateway (Barvis) stays stopped, with the host unit's `ExecStart=/bin/false`, until all seven are in one binary.

## The Problem

Seven defects, each tracked as an open issue. Problem items 1-7 map to tracker issues #1, #2, #3, #4, #5, #15, and #16; "#6/#7/#8 stay parked" in Non-Goals refers to separate tracker issues, not to items 6-7 here.

1. **Stale replay.** Pending-turn rows in `pending-turns.jsonl` carry no timestamp. Every WhatsApp connect, including a reconnect inside the same process, starts another replay thread, and replay answers every row without consulting the seen ledger. A message that was already answered can be answered again.
2. **Stacked permanent retries.** Three nested loops each allow three attempts on a permanently rejected payload, so one rejected request can occupy a turn for nine model calls.
3. **Oversized request.** Message counts are capped, but the bytes in one request are not. A single large tool result can push the serialized request past what the model rejects.
4. **Slow SIGTERM.** Shutdown only sets a flag. The accept loop notices it only when accept fails, the WhatsApp reader stops on a different flag, backoff sleeps run up to 180 s, and a model call at its deadline detaches. Stopping the gateway can take minutes.
5. **Token in the startup banner.** The banner prints the gateway auth token twice. The process already refuses to start without a token.
6. **Vision env var.** `NVIDIA_VISION_MODEL` is applied only inside the block that also replaces the primary model, the fallbacks, the image model, the completion budget, and the timeout, so setting the vision variable alone does not work.
7. **Model pointer left on a fallback.** After an auth failure the model client is not restored to the model it was constructed with, so later requests run on a fallback.

## Goals

* Pending rows get a one-time enqueue timestamp (unix seconds) that survives file rewrites. Replay checks the age before running each row: a row with a missing or future time, or one at or older than 600 seconds, is deleted and the model is not called; a young row is answered. Replay of one row is single-flight. A produced reply is still sent; skipping a row does not write the seen ledger.
* One permanent-error budget of 3 per text turn. Outer loops do not spend it again. Media tools keep their own 3 tries and return the failure as tool text. Timeout, 429, 5xx, and network errors stay unbounded and must return promptly when shutdown is set. HTTP 401 spends the text budget and the client is put back on its constructed model.
* The serialized request is trimmed in memory to 32 KB before it is sent. The system prompt, the current user message, and each tool call with its result are kept or dropped together; if that protected prefix alone is over 32 KB it is sent anyway. No extra model call, no journal rewrite.
* SIGTERM unblocks the accept loop, the WhatsApp socket, and model waits within 5 seconds. A reply already produced is sent and its row removed; an unproduced reply keeps its pending row with its original time. The host unit is not edited.
* The startup banner says a token is configured and does not print it.
* `NVIDIA_VISION_MODEL`, when set, replaces only the vision model. Primary, fallbacks, completion budget, and timeout stay on the file unless `NVIDIA_MODEL` is set.
* Every return from the chat call restores the model the client was constructed with, including auth failure.

## Non-Goals

* Issues #6, #7, and #8 stay parked as already decided; #9 through #14 stay closed.
* Barvis does not start; the host `ExecStart=/bin/false` pin is not restored in this pass.
* A skipped pending row is not written to the seen ledger (`gateway-inbound-ledger.json`), so a later live redelivery can still be answered.
* Old journal lines that already contain the token are not scrubbed.
* The private Barvis incident is a note for #1, not a second implementation.

## Open Questions

* None. The RFC (`docs/designs/seven-open-defects.md`) decided all of them.

## Critical User Journeys (CUJs)

### CUJ 1: Crash mid-reply, gateway restarted

* **Given**: a pending row exists in `pending-turns.jsonl` with `at` set, and the process was killed before the reply was sent.
* **When**: WhatsApp reconnects and `status=connected` fires.
* **Then**: if the row is younger than 600 s, replay runs it once (single-flight), the produced reply is sent, and the row is acked. If `at` is missing/future or the row is 600 s or older, the row is deleted and the model is not called.

### CUJ 2: Model rejects the payload (4xx)

* **Given**: a turn whose request is permanently rejected by NIM.
* **When**: `chatWithTools` exhausts its 3 permanent attempts.
* **Then**: the turn ends after 3 model calls total (no outer loop retries), the client is back on its constructed model, and the error surfaces to the caller.

### CUJ 3: Operator stops the service

* **Given**: the gateway is running with an in-flight model call and a reconnect backoff sleep.
* **When**: SIGTERM arrives.
* **Then**: within 5 s the accept loop, WhatsApp reader, backoff sleeps, and model wait all return; a reply already produced is sent and its row acked.

## Non-Functional Requirements

* **Security & Privacy:** the startup banner never prints token values; skipped replay rows are not written to the seen ledger (accepted gap, documented).
* **Rollout & Rollback:** the pending-file `at` field is ignored by the previous binary, so downgrade is safe; the host unit pin keeping Barvis stopped is untouched in this pass.

## Technical Plan (Architecture)

The seven fixes touch seven production files plus their tests and READMEs. No new component is added; each fix lands in the code that already owns the behavior.

### #1 Stale replay — `src/channels/whatsapp/pending.zig`, `src/gateway/gateway_server.zig`

`PendingTurn` gains an `at: ?i64` field (unix seconds). `encodeLine` writes it once at enqueue; because the writer rebuilds every line from a fixed field set, an existing row's `at` is preserved across the `enqueueAt`/`ackAt` rewrites. `loadFrom` parses it; a missing or non-integer field reads as null. The old binary ignores the unknown field, so a downgrade is safe.

`replayPendingTurns` (gateway_server.zig:281), spawned from `whatsappOnConnection` on every `.connected` (gateway_server.zig:320), checks each row's age before running it: missing, non-finite, or future `at`, or `now - at >= 600`, means the row is deleted via `pending.ack` and the model is never called. The 600 s window is a new constant, deliberately separate from the 3-minute content fingerprint in `inbound.zig` and from the stuck-turn warning default (`turn_watch.zig` `DEFAULT_WARN_AFTER_S = 600`). A young row is answered as today, and a produced reply is still sent before the row is acked.

Single-flight: a mutex-guarded in-flight id set in `replayPendingTurns` guarantees one execution per row id across the threads that concurrent reconnects can spawn (a duplicate id already in the set is skipped). The pending file's `enqueueAt`/`ackAt` read-modify-write cycles are additionally put under one mutex so concurrent replay threads and the live inbound path cannot interleave rewrites. Skipping a row never writes to the seen ledger (`gateway-inbound-ledger.json`); the gap where a later live redelivery of a skipped id can still be answered is accepted.

```text
connected event ──► spawn replay thread (per connect)
                        │
                        ▼
              for each row: lock single-flight
                        │
              age check: at missing/future/≥600s? ──yes──► ack (delete row), no model call
                        │no
                        ▼
              run turn; produced reply is sent; then ack
```

### #2 Stacked permanent retries — `src/agent/loop.zig`, `src/providers/nim.zig`

The permanent budget is owned by the turn, not per loop. Three nested loops each allow 3 permanent attempts today: `NIMClient.chatWithTools` (internal budget), `Agent.chatUntilDone` (`bad` up to `MAX_PERMANENT_RETRIES` = 3, loop.zig:299), and `handleWhatsAppTurn`'s `while (true)` with `bad_turns >= 3` (gateway_server.zig:727-806) — worst case 3x3x3 = 27 model calls. After the fix there is one budget of 3: `chatWithTools` abandons after its own 3, `chatUntilDone` returns the first permanent error instead of retrying, and the gateway `bad_turns` loop is removed so `handleWhatsAppTurn` makes a single `runTurn` call. Transient errors (timeout, 429, 5xx, network) stay unbounded in both loops, and `sleepAfterFailure` returns early once shutdown is set. Media tools (`see_image`/`hear_audio`/`watch_video` in `core_tools.zig`) build their own `NIMClient` and call `chatWithRetry`, keeping their separate 3-attempt budget and returning failures as tool text, so one media rejection never spends the text turn's budget.

### #3 Oversized request — `src/providers/nim.zig`

`chatWithTools` serializes the request into an `Allocating` writer (nim.zig:245-473). Before sending, the serialized body is trimmed in memory to at most 32768 bytes: walk the `messages` array from the end and drop trailing messages as units until the re-serialized size fits; a unit is one message, and a `tool_calls` message is dropped together with every later `tool` message whose `tool_call_id` it carries. The protected prefix — the system message plus everything through the last `user` message (the current user message, identified by role) — is never dropped; if that prefix alone exceeds 32768 bytes the body is sent as-is. Journals, `MEMORY.md`, and transcripts are not rewritten, and no summarizing model call is made.

### #4 Slow SIGTERM — `src/gateway/http_server.zig`, `src/gateway/gateway_server.zig`, `src/channels/whatsapp/whatsapp_channel.zig`, `src/providers/nim.zig`

`sigHandler` (gateway_server.zig:137) sets `shutdown_requested` and then makes the per-layer stop calls explicitly: `HttpServer.stop()` (which now also closes the listener, so the blocking `accept` at `http_server.zig:98` wakes immediately), `WhatsAppChannel.disconnect()` (sets the reader stop flag so `nativeLoop` exits its poll loop and `sleepInterruptible` at whatsapp_channel.zig:450 returns early, ending reconnect backoff — 2 s doubling, 60 s cap — at once), and `nim.setShutdown()` on the shared client, which `sleepAfterFailure` (nim.zig:49) and `postOnceWithDeadline` (nim.zig:548) check on every sleep/poll slice and return early on. No provider-layer code reads gateway globals; the flag travels only through these calls. The two backoff caps are different clocks: NIM retry backoff caps at 180 s (`NIM_BACKOFF_MAX_S`, nim.zig:29), WhatsApp reconnect backoff at 60 s. Net effect: every wait returns within 5 s of SIGTERM. A reply already produced is sent and its pending row acked; an unproduced reply leaves the row with its original `at` (the unconditional `pending.ack` at gateway_server.zig:311 moves into the produced-reply path). The host unit file is not edited.

### #5 Token in the banner — `src/gateway/gateway_server.zig`

Lines 1244-1245 print the main and workspace gateway auth tokens verbatim (main token authenticates operator requests; the workspace token is its alias for workspace-scoped calls; both hold the same secret here). They now print a configured/placeholder line ("Main Token: configured (64 hex chars)" style) without the value. Startup already fails closed when the token is missing (gateway_server.zig:1007-1011).

### #15 Vision env var — `src/config/migration_config.zig`

The env merge (migration_config.zig:666-685) currently replaces primary, fallbacks, image model, vision model, max_tokens, and timeout together, gated on `env_model_explicit` (set only when `NVIDIA_MODEL` is present). The vision assignment moves out of that block into its own `if (NVIDIA_VISION_MODEL set)` gate that touches only `result.vision_model`.

### #16 Model pointer after auth failure — `src/providers/nim.zig`

`chatWithTools` restores `setModel(primary)` on success and on abandon (nim.zig:490, 505), but not on every error return path — in particular not when a 401 arrives on the first attempt. Every return from the chat call now restores the constructed model first.

### Verification approach

All seven are checkable offline: unit tests for the age rule, the single-flight lock, the 32 KB trim boundaries, and the env merge; `zig build test` as the gate. No live NIM or WhatsApp calls.

## Alternatives Considered

These come from the RFC's "Alternatives Weighed"; each was rejected during brainstorm and stays rejected here.

### One shared module for all seven changes

* **Reason for rejection:** the token line, the vision flag, and the model-pointer restore share no data with the pending queue; one module would couple unrelated concerns.

### A skip flag or a second queue inside the pending file

* **Reason for rejection:** the writer rebuilds each line from a fixed field set and drops unknown fields, and the previous binary would replay a flag it does not understand. Deleting the row is the only skip the old binary also honors.

### Treating a missing timestamp as "now"

* **Reason for rejection:** the stopped process's backlog would be answered on the first connect.

### An age window of a few minutes

* **Reason for rejection:** shorter than one parked model deadline (300 s), so a crash during a normal slow reply would delete the recovery the pending file exists to provide.

### Removing a young row on SIGTERM

* **Reason for rejection:** a cancelled young turn stays, and the next connect answers it if it is still inside 600 s. A kill from outside cannot do better.

### Writing the skipped id into the seen ledger

* **Reason for rejection:** deleting the pending row is the whole skip; a later live redelivery can still be answered, including after the 2000-id cap drops an older id.

### Reusing the three-minute content fingerprint as the age rule

* **Reason for rejection:** it matches the same text under a new message id; replay does not read it.

### Putting the permanent budget on the model client, or letting one media rejection spend the text turn's three

* **Reason for rejection:** media builds a new client and returns the failure as tool text; the budget belongs to the turn.

### Calling the model to summarize history, or trimming by dropping the oldest message

* **Reason for rejection:** one spends the deadline; the other drops the system prompt and can split a tool call from its result.

### Editing the host unit

* **Reason for rejection:** that pin is what keeps Barvis stopped.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

Every file below is touched by the plan. No production code goes into this document; APIs and behavior only.

### Target Files to Modify

#### 1. `src/channels/whatsapp/pending.zig` (Modify)

* **What changes:** `PendingTurn` gains `at: ?i64` (unix seconds, written once at enqueue). `encodeLine` gains an `at: ?i64` parameter and emits `"at":<n>` (omitted when null); `loadFrom` parses it back, treating missing/non-integer as null. `enqueueAt`/`ackAt` take a shared mutex around their load-modify-write. `enqueueAt`/`ackAt` rebuild lines from the fixed field set, so an existing row's `at` survives rewrites. New const `REPLAY_MAX_AGE_S: i64 = 600`.
* **Why:** the pending file is the crash record; without a timestamp replay cannot tell a fresh row from a stale one, and rows are currently replayed forever.
* **Tests:** round-trip with/without `at`; rewrite preserves `at`; parse of an old-format line (no `at`) yields null.

#### 2. `src/gateway/gateway_server.zig` (Modify)

* **What changes:** (a) #2 — the `while (true)`/`bad_turns` retry loop around `agent.runTurn` (lines 727-806) is removed; one `runTurn` call per turn. (b) #1 — `replayPendingTurns` (line 281) checks each row's age before running it (`at` null/future/`now-at >= 600` → `pending.ack` and skip, model never called), runs each row under a mutex-guarded in-flight id set, and acks a row only after a produced reply is sent (the unconditional `pending.ack` at line 311 moves into that path). (c) #4 — `sigHandler` additionally calls `server.stop()`, `whatsapp_channel.disconnect()`, and `nim.setShutdown()`. (d) #5 — banner lines 1244-1245 print "configured" instead of the token values.
* **Why:** #1 single-flight + age rule, and #5 token not printed at startup.
* **Tests:** age-rule unit tests against a temp pending file; banner text contains no token.

#### 3. `src/providers/nim.zig` (Modify)

* **What changes:** (a) #3 — after building the request body in `chatWithTools` (writer at line 245), trim the in-memory JSON to at most 32768 bytes before `postOnceWithDeadline` (line 483): drop trailing messages as units (a `tool_calls` message together with its `tool` results), never the protected prefix (system message + everything through the last `user` message), which is sent even if it alone exceeds the cap; (b) #4 — `NIMClient` gains a shutdown flag set once via `setShutdown()`; `postOnceWithDeadline` (line 548) and `sleepAfterFailure` (line 49) return early when it is set; (c) #16 — every return path of `chatWithTools` restores `setModel(primary)` first, including the first-attempt 401.
* **Why:** byte cap on the request, prompt shutdown of model waits, and no lingering fallback model.
* **Tests:** trim boundary tests (exactly 32 KB, prefix-over-cap, tool pair kept together); shutdown flag short-circuits the waits.

#### 4. `src/agent/loop.zig` (Modify)

* **What changes:** #2 — `chatUntilDone` (line 299) returns the first permanent (non-transient) error from `chatWithTools` instead of spending its own `MAX_PERMANENT_RETRIES` on top; transient errors stay unbounded and observe shutdown.
* **Why:** one permanent budget of 3 for the text turn, owned by the turn.
* **Tests:** permanent error from the client ends the loop after one call; transient errors still retry.

#### 5. `src/gateway/http_server.zig` (Modify)

* **What changes:** #4 — `stop()` (line 116) also closes the listener so a blocked `accept` in `start` (line 98) wakes immediately; `sigHandler` calls `stop()` explicitly, and the accept loop already breaks on `shutdown_requested`.
* **Why:** accept must not wait for the next connection to notice SIGTERM.
* **Tests:** start/stop with a pending accept returns promptly.

#### 6. `src/channels/whatsapp/whatsapp_channel.zig` (Modify)

* **What changes:** #4 — `disconnect()` (called by `sigHandler`) sets the reader stop flag so `nativeLoop` exits its poll loop, and `sleepInterruptible` (line 450) returns early when that flag is set, ending reconnect backoff (2 s doubling, 60 s cap) at once.
* **Why:** the WhatsApp socket and its backoff currently stop on a different flag that shutdown never sets.
* **Tests:** sleepInterruptible returns true immediately with shutdown set.

#### 7. `src/config/migration_config.zig` (Modify)

* **What changes:** #15 — in the env merge (lines 666-685), the `result.vision_model = ec.vision_model` assignment moves out of the `env_model_explicit` block into its own gate on `NVIDIA_VISION_MODEL` being set.
* **Why:** setting the vision var alone must not drag primary/fallbacks/budget/timeout along.
* **Tests:** env with only `NVIDIA_VISION_MODEL` set changes vision only; `NVIDIA_MODEL` set still overrides the model fields.

### Documentation Files to Update

#### 8. `src/channels/whatsapp/README.md` (Modify)

* `pending.zig:PendingTurn` bullet gains the `at` field; `enqueueAt`/`loadFrom` bullets mention timestamp preservation; add the 600 s replay age rule and single-flight note.

#### 9. `src/providers/README.md` (Modify)

* `chatWithTools` bullet: 32 KB in-memory trim; shutdown-observing waits; model restored on every return. `chatWithRetry` bullet stays (media tools keep their own budget).

#### 10. `src/agent/README.md` (Modify)

* `chatUntilDone` bullet: permanent errors end the turn after the client's budget; transient retry forever.

#### 11. `src/gateway/README.md` (Modify)

* Shutdown section: listener close on `stop`, reader/shutdown flag, ≤5 s unblock. Banner bullet: token shown as configured, not printed.

#### 12. `src/config/README.md` (Modify)

* Env-override bullet: `NVIDIA_VISION_MODEL` applies alone; model fields still gated on `NVIDIA_MODEL`.

#### 13. `README.md` (Modify)

* "Bounded permanent retries" bullet (line 52) and pending-turns bullet (line 84) updated to the single 3-budget and 600 s age rule; replay wording (line 425) updated.

#### 14. `docs/whatsapp.md` (Modify)

* Replay section: age rule, single-flight, skip-does-not-write-ledger.

### Verification Plan

* **Build/tests:** `zig build test --summary all` — full suite green (README "Build Status" baseline: 485 pass, 3 skip without `NVIDIA_API_KEY`, plus the new tests above).
* **Offline checks:** age rule, single-flight, trim boundaries, env merge, banner text — all unit tests, no live NIM/WhatsApp.
* **Manual:** none required; Barvis stays stopped until the user re-enables the host unit.

--------------------------------------------------------------------------------

<!-- Provenance: Indicates initial structural drafting via EGM. -->

*Drafted with EGM*
