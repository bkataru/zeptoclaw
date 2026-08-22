# Cloudflare worker

Optional OpenAI-compatible router in front of NIM / the local gateway. Secrets: `wrangler secret put NVIDIA_API_KEY` (and Moltbook if used). KV bindings are in `wrangler.toml` (`BARVIS_STATE` and `ZEPTOCLAW_STATE` share one namespace).

```bash
cd cloudflare-worker
npx wrangler deploy
```

Not required for local WhatsApp (`zeptoclaw-gateway`). Do not commit API keys.
