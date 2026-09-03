# NVIDIA NIM outage

Symptoms: `[agent] NIM chat failed`, empty or delayed WhatsApp replies, gateway still `connected`.

1. Confirm NIM: `curl -sS -H "Authorization: Bearer $NVIDIA_API_KEY" https://integrate.api.nvidia.com/v1/models`
2. Confirm local key: systemd `Environment=` vs `~/.config/zeptoclaw/nim.env` vs shell `export`.
3. Read the `[nim] HTTP` journal line. It names the status, the model, and the first bytes of the error body. A 400 names a bad request shape. A 503 names an overloaded model. Act on the status, not on the retry count.
4. Cloudflare worker (`cloudflare-worker/`) can sit in front as a backup router; it is not required for WhatsApp.
5. Chat path: `chatWithTools` retries forever on `RateLimit` / `Timeout` / `Network`. Any other error gets 3 tries, then the turn answers with a fallback echo instead of silence. Memory `update`/`compact` run in other processes so they do not share that backoff clock. They still share account quota.
6. Tool output enters the next request verbatim. Non-UTF-8 bytes in it (bad filenames from `ls`) make NVIDIA reject the request with a 400. The gateway scrubs tool output to U+FFFD first. If a 400 names `ToolMessageContent`, check the `[nim] req msg` shape lines before you blame the schema.

No need to restart WhatsApp for a pure NIM failure. Inbound still journals to `memory/YYYY-MM-DD.md`.
