# Worker notes

The worker is a NIM-capable OpenAI-compatible router with KV state (`BARVIS_STATE` / `ZEPTOCLAW_STATE` share one namespace). Heartbeat scripts live beside `worker.ts`.

Local gateway remains source of truth for WhatsApp. Treat this directory as failover and public routing, not the agent loop.
