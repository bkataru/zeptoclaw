# Worker notes

NIM-capable OpenAI-compatible router. KV: `BARVIS_STATE` / `ZEPTOCLAW_STATE` share one namespace. Heartbeat scripts sit beside `worker.ts`.

Local `zeptoclaw-gateway` is the source of truth for WhatsApp. This directory is failover and public routing, not `runTurn`.
