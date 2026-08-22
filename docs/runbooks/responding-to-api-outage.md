# NVIDIA NIM outage

Symptoms: `[agent] NIM chat failed`, empty WhatsApp replies, gateway still `connected`.

1. Confirm NIM: `curl -sS -H "Authorization: Bearer $NVIDIA_API_KEY" https://integrate.api.nvidia.com/v1/models`
2. Confirm local key: systemd `Environment=` vs shell `export`.
3. Cloudflare worker (`cloudflare-worker/`) can sit in front as a backup router; it is not required for WhatsApp.
4. Rate limit: NIM client pads ~1.6s between calls. Bursts of history replay can look like an outage.

No need to restart WhatsApp for a pure NIM failure; inbound still journals.
