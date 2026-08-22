# NVIDIA NIM outage

Symptoms: NIM chat failed, empty or delayed WhatsApp replies, gateway still `connected`.

1. Confirm NIM: `curl -sS -H "Authorization: Bearer $NVIDIA_API_KEY" https://integrate.api.nvidia.com/v1/models`
2. Confirm local key: systemd `Environment=` vs `~/.config/zeptoclaw/nim.env` vs shell `export`.
3. Cloudflare worker (`cloudflare-worker/`) can sit in front as a backup router; it is not required for WhatsApp.
4. Rate limit: the chat path retries forever on 429/timeout/network. Memory ingest/compact run in **other processes** so they do not share that backoff clock (they still share account quota).

No need to restart WhatsApp for a pure NIM failure; inbound still journals to the daily file.
