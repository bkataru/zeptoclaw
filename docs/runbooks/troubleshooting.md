# Troubleshooting

## Gateway will not start

- `NVIDIA_API_KEY` missing -> config load fails.
- Zig 0.15 vs 0.16 mismatch -> rebuild with 0.16.0.
- `OutOfMemory` on WhatsApp connect -> spawn used `compat.getIo()`; current code must use a dedicated `std.Io.Threaded`.

## Connected but no replies

- Trigger word **barvis** missing (groups / unsubscribed chats).
- Replay: same body in the same chat within 3 minutes, or same wire id in the ledger.
- Poll thread died: look for missing `inbound` after a native `connected` log.
- Allowlist: group JID not in `allowFrom`; LID peer digits not matching.

## Send hangs

Check the journal for native encrypt/usync errors. A peer device that cannot decrypt will send `<receipt type=retry>`; the client resends up to 5 times, then that message id is dropped.

## WhatsApp `Bad MAC`

Signal session desync. Usually recoverable through retry-receipt recovery in `sendText`. Re-pair only if it keeps failing past 5 auto-resends for the same message (new `sessions/whatsapp` after backup).

## Logs

```bash
journalctl --user -u zeptoclaw-gateway.service -n 100 --no-pager
```

Do not paste full chat bodies or tokens into issues.
