# Troubleshooting

## Gateway will not start

- `NVIDIA_API_KEY` missing -> config load fails.
- Zig 0.15 vs 0.16 mismatch -> rebuild with 0.16.0.
- `OutOfMemory` on WhatsApp connect -> spawn used `compat.getIo()`; current code must use a dedicated `std.Io.Threaded`.

## Connected but no replies

- Trigger word **barvis** missing (groups / unsubscribed chats).
- Replay: same body in the same chat within 3 minutes, or same Baileys id in the ledger.
- Reader thread died: look for `parseMessage failed` or missing `inbound` after Node `[zepto] emit`.
- Allowlist: group JID not in `allowFrom`; LID peer digits not matching.

## `RpcTimeout` on send

Zig waited ~30s for a JSON-RPC ACK to `sendMessage`. Causes: Baileys hang (LID), stderr pipe full (fixed by drain), RPC `id` type mismatch (string vs number). Node times out `sendMessage` at 20s. Check journal for `RpcTimeout waiting for rpc id=`.

## WhatsApp `Bad MAC`

Signal session desync. Usually recoverable; if persistent, re-pair (new `sessions/whatsapp` after backup).

In native mode (`channels.whatsapp.native`), a Bad MAC or decrypt failure now usually self-heals through the automatic retry-receipt recovery in `sendText`. Re-pair only if it keeps failing past 5 auto-resends for the same message. This fix does not apply to Baileys mode.

## Logs

```bash
journalctl --user -u zeptoclaw-gateway.service -n 100 --no-pager
```

Do not paste full chat bodies or tokens into issues.
