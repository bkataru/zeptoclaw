# Deploy ZeptoClaw

## Build

```bash
cd zeptoclaw
zig build
ls zig-out/bin
```

Need Zig **0.16.0**. WhatsApp needs Node on `PATH` or `ZEPTO_NODE`.

## Environment

Keep secrets in systemd or `~/.config/zeptoclaw/env` (`chmod 600`). Do not put live keys in git.

| Variable | Required | Notes |
|----------|----------|--------|
| `NVIDIA_API_KEY` | yes | NIM |
| `NVIDIA_MODEL` | no | default `thinkingmachines/inkling` |
| `GATEWAY_AUTH_TOKEN` | recommended | HTTP auth; config `gateway.auth.token` also works |
| `ZEPTO_NODE` | if `node` missing | absolute path to Node |
| `ZEPTO_CRON_SECS` | no | `0` or unset = no heartbeat turns |
| `ZEPTO_EXEC_APPROVE` | no | `1` allows all `exec` tools |
| `WHATSAPP_AUTH_DIR` | no | default `sessions/whatsapp` |

WhatsApp allowlist is **config**, not env: `channels.whatsapp.allowFrom` and `dmPolicy` (`allowlist` recommended).

## systemd --user

Copy the template and add env on the **local** unit, not in the repo file:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/zeptoclaw-gateway.service ~/.config/systemd/user/
# edit Environment=NVIDIA_API_KEY=... GATEWAY_AUTH_TOKEN=... PATH=...
systemctl --user daemon-reload
systemctl --user enable --now zeptoclaw-gateway.service
journalctl --user -u zeptoclaw-gateway.service -f
```

If `systemctl --user restart` hangs, kill then start:

```bash
systemctl --user kill zeptoclaw-gateway.service
pkill -9 -f zeptoclaw-gateway
pkill -9 -f baileys_wrapper
systemctl --user start zeptoclaw-gateway.service
```

Expect `connection status=connected` then inbound logs. First connect after an empty ledger may process unseen history once.

## Optional services

`zeptoclaw-webhook` (9000) and `zeptoclaw-shell2http` (9001) have templates in `systemd/`. Heartbeat/watchdog timers are optional.

## OpenClaw data

If you still have `~/.openclaw`, `scripts/migrate/` copies credentials/sessions/memory into `~/.zeptoclaw`. WhatsApp Baileys auth used by this tree is `sessions/whatsapp/` in the repo working directory (gitignored).

## Cloudflare worker

See `cloudflare-worker/README.md`. Secrets go through `wrangler secret put`, never commits.

## After Zig changes

```bash
zig build
zig build test --summary all
# then restart the user unit as above
```
