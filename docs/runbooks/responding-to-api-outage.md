# NVIDIA NIM outage

Symptoms: `[agent] NIM chat failed`, empty or delayed WhatsApp replies, gateway still `connected`.

1. Confirm NIM: `curl -sS -H "Authorization: Bearer $NVIDIA_API_KEY" https://integrate.api.nvidia.com/v1/models`
2. Confirm local key: systemd `Environment=` vs `~/.config/zeptoclaw/nim.env` vs shell `export`.
3. Cloudflare worker (`cloudflare-worker/`) can sit in front as a backup router; it is not required for WhatsApp.
4. Chat path: `chatWithTools` retries forever on `RateLimit` / `Timeout` / `Network`. Memory `update`/`compact` run in other processes so they do not share that backoff clock. They still share account quota.

No need to restart WhatsApp for a pure NIM failure. Inbound still journals to `memory/YYYY-MM-DD.md`.
