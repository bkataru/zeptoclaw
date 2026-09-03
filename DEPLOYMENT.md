# Deploy ZeptoClaw

## Build

```bash
cd zeptoclaw
zig build
ls zig-out/bin
```

Zig **0.16.0**. WhatsApp uses the native Zig client; pair with `zeptoclaw whatsapp pair`.

## Live directories

| Path | What |
|------|------|
| `~/.zeptoclaw/workspace` | Persona, daily journals, `MEMORY.md` |
| `~/.zeptoclaw/sessions/whatsapp` | Native session store (`native.sqlite`) |
| `~/.zeptoclaw/config.json` | Policy (allowlist, port, model). No live tokens in git |
| `~/.config/zeptoclaw/nim.env` | NVIDIA key for memory oneshots (`chmod 600`) |
| `~/.config/systemd/user/zeptoclaw-gateway.service` | Live unit: NVIDIA + `GATEWAY_AUTH_TOKEN` |

## Environment

Keep secrets in systemd or `chmod 600` env files. Do not put live keys in git.

| Variable | Required | Notes |
|----------|----------|--------|
| `NVIDIA_API_KEY` | yes | NIM (gateway and memory jobs) |
| `NVIDIA_MODEL` | no | default `nvidia/nemotron-3-ultra-550b-a55b` |
| `GATEWAY_AUTH_TOKEN` | recommended | HTTP auth; config `gateway.auth.token` also works |
| `ZEPTO_CRON_SECS` | no | `0` or unset = no heartbeat turns on the chat path |
| `ZEPTO_MEMORY_SECS` | no | default 1800; `0` disables 30-min `memory update` child |
| `ZEPTO_EXEC_APPROVE` | no | `1` allows all `exec` tools |
| `WHATSAPP_AUTH_DIR` | no | default `~/.zeptoclaw/sessions/whatsapp` |

`exec` only runs on an operator `fromMe` WhatsApp DM. A partner DM cannot invoke it.

WhatsApp allowlist is config, not env: `channels.whatsapp.allowFrom` and `dmPolicy` (`allowlist` recommended).

## systemd --user

Copy templates and add env on the **local** unit, not in the repo file:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/zeptoclaw-gateway.service ~/.config/systemd/user/
cp contrib/systemd/barvis-memory-update.service contrib/systemd/barvis-memory-update.timer ~/.config/systemd/user/
# edit Environment=NVIDIA_API_KEY=... GATEWAY_AUTH_TOKEN=... PATH=...
systemctl --user daemon-reload
systemctl --user enable --now zeptoclaw-gateway.service
systemctl --user enable --now barvis-memory-update.timer
journalctl --user -u zeptoclaw-gateway.service -f
```

If `systemctl --user restart` hangs, kill then start:

```bash
systemctl --user kill zeptoclaw-gateway.service
pkill -9 -f zeptoclaw-gateway
systemctl --user start zeptoclaw-gateway.service
```

Expect `connection status=connected` then inbound logs. First connect after an empty ledger may process unseen history once.

`barvis-memory-update.timer` runs `zeptoclaw memory compact` every 2 hours. Journal ingest is the gateway child `zeptoclaw memory update` (`ZEPTO_MEMORY_SECS`). See `docs/memory.md`.

`POST /reload` on the gateway HTTP port reloads `allowFrom`, `dmPolicy`, and `groupPolicy` from `~/.zeptoclaw/config.json`. Allowlist changes no longer need a `systemctl --user restart`.

## Optional services

`zeptoclaw-webhook` (9000) and `zeptoclaw-shell2http` (9001) have templates in `systemd/`. Heartbeat/watchdog timers are optional. `whatsapp-responder.timer` is leftover; live replies come from the gateway.

## WhatsApp (native)

The gateway uses a Signal/whatsmeow-style Zig client. Pair a device with `zeptoclaw-wa-pair` (terminal QR) or `zeptoclaw whatsapp pair`. Identity is `{auth_dir}/native.sqlite`.

Text DM and group send/receive, inbound media, outbound media, presence, reactions, polls, and read receipts all go through the native client.

If a peer device's Signal session desyncs, force a fresh handshake with `zeptoclaw-wa-send`. Stop the gateway first: it holds an exclusive sqlite lock on the native session store.

```bash
systemctl --user stop zeptoclaw-gateway.service
zeptoclaw-wa-send <db-path> <to-jid> <text>
systemctl --user start zeptoclaw-gateway.service
```

## OpenClaw data

`scripts/migrate/` copies credentials/sessions/memory from `~/.openclaw` into `~/.zeptoclaw`. Do not treat `~/.openclaw/workspace` as the live tree.

## Cloudflare worker

See `cloudflare-worker/README.md`. Secrets via `wrangler secret put`, never commits.

## After Zig changes

```bash
zig build
zig build test --summary all
# then kill + start the user unit as above
```
