# Cloudflare worker

Optional OpenAI-compatible router in front of NIM / the local gateway. Secrets: `wrangler secret put NVIDIA_API_KEY` (and Moltbook if used). KV bindings are in `wrangler.toml` (`BARVIS_STATE` and `ZEPTOCLAW_STATE` share one namespace).

```bash
cd cloudflare-worker
npx wrangler deploy
```

Not required for local WhatsApp (`zeptoclaw-gateway`). Do not commit API keys.

Implementation details for shared helpers and types: [./src/README.md](./src/README.md).

## Overview

Cloudflare Worker (`wrangler.toml:main` → `worker.ts`) that exposes OpenAI-compatible chat and model listing against NVIDIA Integrate, tracks optional model health in KV, and runs Moltbook heartbeat, state, autonomous, and gateway-incident endpoints. Cron (`wrangler.toml:triggers.crons`, every 30 minutes) invokes autonomous behavior when the local agent has not heartbeated within `LOCAL_AGENT_TIMEOUT_MS` from `src/utils.ts`. Vars for Moltbook identity and monitored posts live in `wrangler.toml:[vars]`.

## Interface

- `worker.ts:default` — Worker module with `fetch(request, env)` HTTP routing and `scheduled(event, env, ctx)` cron handler.
- `worker.ts:fetch` — `GET /health`, `GET /v1/models`, `POST /v1/chat/completions`, `POST /v1/chat/council`, `POST /reset`, `POST /heartbeat`, `GET /state`, Moltbook/autonomous/discovery/gateway paths as implemented in `worker.ts`.
- `worker.ts:scheduled` — When `shouldWorkerTakeOver` is true, may post downtime alerts and calls `executeAutonomousAction`.
- `wrangler.toml:kv_namespaces` — Bindings `BARVIS_STATE` and `ZEPTOCLAW_STATE` (same KV id).
- `wrangler.toml:[vars]` — `MOLTBOOK_AGENT_NAME`, `MOLTBOOK_AGENT_ID`, `MOLTBOOK_MONITORED_POSTS`.
- `package.json:scripts.dev` — `wrangler dev`.
- `package.json:scripts.deploy` — `wrangler deploy`.
- `package.json:scripts.tail` — `wrangler tail`.
- `package.json:scripts.typecheck` — `tsc --noEmit`.

## Invariants

- `worker.ts:shouldWorkerTakeOver` — Worker autonomous mode when `(Date.now() - state.local_last_seen) > LOCAL_AGENT_TIMEOUT_MS` (`src/utils.ts:LOCAL_AGENT_TIMEOUT_MS`).
- `worker.ts:getBarvisState` — KV key `"state"` on `env.BARVIS_STATE` merged over `getDefaultBarvisState()` from `src/utils.ts`.
- `worker.ts:routeRequest` — Tries up to `MAX_RETRIES` healthy models; on total exhaustion resets cooldowns and returns `all_models_exhausted`; uses `calculateCooldown` / `COOLDOWN_*` from `src/utils.ts` on failures.
- `worker.ts:scheduled` — Skips autonomous work when local agent is still active (`shouldWorkerTakeOver` false).
- `wrangler.toml:main` — Entry file is `worker.ts`; `compatibility_date` is `2026-01-01`.

## Side Effects

- `worker.ts:updateBarvisState` — Writes JSON to `env.BARVIS_STATE` key `"state"`.
- `worker.ts:updateModelHealth` — Updates in-memory cache; optional `env.MODEL_HEALTH.put` with 24h TTL when binding present.
- `worker.ts:callNvidiaAPI` — `POST` to `https://integrate.api.nvidia.com/v1/chat/completions` with `env.NVIDIA_API_KEY`.
- `worker.ts:fetchMoltbookComments` / `postMoltbookReply` / feed and post helpers — HTTP to `MOLTBOOK_API_BASE` with `env.MOLTBOOK_API_KEY` when Moltbook routes run.
- `worker.ts:scheduled` — May `createMoltbookPost` for downtime alerts and mutates state via `updateBarvisState`; runs `executeAutonomousAction` (Moltbook engagement).

## Verification

- Run: `npm run typecheck` (`./test.sh` only checks file presence and string greps in sources; it does not exercise worker behavior).
