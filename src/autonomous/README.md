# autonomous

## Overview

This directory implements a Moltbook-oriented autonomous agent: shared action and API types, JSON persistence for agent state, HTTP access to the Moltbook API, client-side rate limits, and an `AutonomousAgent` that picks and runs actions (reply, browse, post, search). The module root `autonomous.zig` re-exports the main types and submodules for callers outside this folder.

## Interface

- `agent_framework.zig:AutonomousAgent` — Agent struct holding borrowed `StateStore`, `MoltbookClient`, embedded `RateLimiter`, and `nim_client`; exposes `init`, `selectNextAction`, `executeAction`, and `shouldWorkerTakeOver`.
- `autonomous.zig:types` — Re-export of the `types.zig` module.
- `autonomous.zig:state_store` — Re-export of the `state_store.zig` module.
- `autonomous.zig:moltbook_client` — Re-export of the `moltbook_client.zig` module.
- `autonomous.zig:rate_limiter` — Re-export of the `rate_limiter.zig` module.
- `autonomous.zig:agent_framework` — Re-export of the `agent_framework.zig` module.
- `autonomous.zig:AutonomousAction` — Alias of `types.AutonomousAction`.
- `autonomous.zig:AutonomousAgent` — Alias of `agent_framework.AutonomousAgent`.
- `autonomous.zig:BarvisState` — Alias of `state_store.BarvisState`.
- `autonomous.zig:StateStore` — Alias of `state_store.StateStore`.
- `autonomous.zig:MoltbookClient` — Alias of `moltbook_client.MoltbookClient`.
- `autonomous.zig:RateLimiter` — Alias of `rate_limiter.RateLimiter`.
- `autonomous.zig:RateLimitStatus` — Alias of `rate_limiter.RateLimitStatus`.
- `moltbook_client.zig:MoltbookClient` — HTTP client for Moltbook (`init`, `deinit`, feed/search/post/comment/upvote APIs, monitored post list).
- `moltbook_client.zig:FeedSort` — Feed ordering enum (`hot`, `new`, `top`) with `toString`.
- `moltbook_client.zig:CommentSort` — Comment ordering enum (`new`, `top`) with `toString`.
- `rate_limiter.zig:RateLimiter` — In-memory post/comment cooldowns and daily comment cap (`canPost`, `canComment`, `recordPost`, `recordComment`, `getStatus`, etc.).
- `rate_limiter.zig:RateLimitStatus` — Snapshot struct returned by `RateLimiter.getStatus`.
- `state_store.zig:BarvisState` — In-memory autonomous state (timestamps, counters, ID lists, discoveries, heartbeats, incidents) with query/mark helpers and `init`/`deinit`.
- `state_store.zig:StateStore` — Wraps `BarvisState` and `file_path` (`{workspace}/.zeptoclaw_state.json`); timestamp updates, `save`, discovery/incident accessors.
- `state_store.zig:init` — `StateStore.init`: allocates store and state file path under the given workspace (default `"."`).
- `state_store.zig:deinit` — `StateStore.deinit`: frees file path and `BarvisState` allocations.
- `types.zig:AutonomousAction` — Action enum (`REPLY_COMMENTS`, `BROWSE_FEED`, `CREATE_POST`, `SEARCH_TOPICS`, `IDLE`) with `toString` and `fromString`.
- `types.zig:DiscoveryType` — Discovery category enum with `toString`.
- `types.zig:Discovery` — Timestamped discovery record with owned string fields and `deinit`.
- `types.zig:MoltbookPost` — Parsed post with nested author/submolt and `deinit`.
- `types.zig:MoltbookUser` — Parsed user with `deinit`.
- `types.zig:MoltbookSubmolt` — Parsed submolt with `deinit`.
- `types.zig:MoltbookComment` — Parsed comment with optional parent/replies and `deinit`.
- `types.zig:PostEvaluation` — LLM-style evaluation placeholder (score, reason, `PostAction`, optional comment idea) with `deinit`.
- `types.zig:PostAction` — Recommended action enum (`upvote`, `comment`, `skip`, `follow_author`) with `toString`.
- `types.zig:HeartbeatData` — Local-agent heartbeat fields with `deinit`.
- `types.zig:GatewayIncident` — Gateway incident record with `deinit`.
- `types.zig:AutonomousResult` — Tagged union of per-action result structs with `deinit`.
- `types.zig:ReplyCommentsResult` — Result payload for `REPLY_COMMENTS` with `init`/`deinit`.
- `types.zig:BrowseFeedResult` — Result payload for `BROWSE_FEED` with `init`/`deinit`.
- `types.zig:CreatePostResult` — Result payload for `CREATE_POST` with `deinit`.
- `types.zig:SearchTopicsResult` — Result payload for `SEARCH_TOPICS` with `init`/`deinit`.
- `types.zig:IdleResult` — Result payload for `IDLE` with `deinit`.

## Invariants

- `agent_framework.zig:AutonomousAgent` — Doc comment: borrows `state_store` and `moltbook_client` pointers and `allocator`; does not deallocate store or client on agent teardown.
- `agent_framework.zig:AutonomousAgent` — `selectNextAction` checks monitored posts for unreplied comments first, then post cooldown (4 h) with queued ideas, then browse cooldown (25 min), then 30% random `SEARCH_TOPICS`, else defaults to `BROWSE_FEED`.
- `agent_framework.zig:AutonomousAgent` — `shouldWorkerTakeOver` is true when `now - local_last_seen` exceeds one hour (`LOCAL_AGENT_TIMEOUT_MS`).
- `agent_framework.zig:AutonomousAgent` — `executeAction` always calls `state_store.updateLastAction` after running the action switch (including `IDLE`).
- `agent_framework.zig:AutonomousAgent` — `evaluatePost`, `generateReply`, `generateComment`, and `generatePost` are stub implementations (TODO LLM); browse/search behavior depends on these stubs today.
- `rate_limiter.zig:RateLimiter` — Post spacing uses 30-minute cooldown; comments use 20-second cooldown and max 50 comments per calendar day bucket.
- `state_store.zig:BarvisState` — Doc comment: all strings in array lists are owned by `BarvisState` until `deinit`.
- `state_store.zig:StateStore` — `save` writes JSON via a temp file then `rename` to `file_path`; backup path is prepared but backup copy is documented as no-op on 0.16.
- `moltbook_client.zig:MoltbookClient` — Default API base is `https://www.moltbook.com/api/v1`; requests send `Authorization: Bearer {api_key}` and JSON content type.
- `types.zig:AutonomousResult` — Union tag set matches `AutonomousAction` variants one-to-one.

## Side Effects

- `agent_framework.zig:AutonomousAgent` — `executeReplyComments`, `executeBrowseFeed`, `executeCreatePost`, and `executeSearchTopics` call Moltbook APIs via `moltbook_client`, mutate `BarvisState` counters/lists, and invoke `state_store.save` (and timestamp updaters where applicable).
- `agent_framework.zig:AutonomousAgent` — Action selection and execution emit scoped log lines (`std.log` / `log.info`).
- `moltbook_client.zig:MoltbookClient` — `makeRequest` performs HTTP GET/POST/PUT/DELETE with up to 1 MiB response bodies; mutating APIs return parsed IDs or booleans from status codes.
- `moltbook_client.zig:MoltbookClient` — `deinit` frees monitored post IDs and tears down `std.http.Client`.
- `state_store.zig:StateStore` — `save` creates/writes `.zeptoclaw_state.json` (via temp + rename) under the configured workspace path.
- `state_store.zig:StateStore` — `updateLastReply`, `updateLastAction`, `updateLocalAgentHeartbeat`, `updateLastPost`, `updateLastBrowse`, `updateLastCheck`, `updateLocalLastSeen`, and `clearDiscoveries` persist through `save`.
- `rate_limiter.zig:RateLimiter` — `canComment`, `recordComment`, `remainingCommentsToday`, and `getStatus` may reset the daily comment counter when the day bucket advances (`resetDayIfNeeded`).

## Verification

- Run: `zig build test`
