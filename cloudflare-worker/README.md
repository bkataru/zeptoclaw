# Cloudflare worker

Optional backup router in front of NIM / the local gateway. Secrets: `wrangler secret put NVIDIA_API_KEY` (and Moltbook if used). KV bindings are in `wrangler.toml`.

```bash
cd cloudflare-worker
npx wrangler deploy
```

This worker is not required for local WhatsApp. Do not commit API keys or `package-lock.json` churn without a reason.
