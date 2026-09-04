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

## WhatsApp `Bad MAC` or 401 logout

Signal session desync. Retry-receipt recovery in `sendText` fixes most cases. Re-pair only if one message keeps failing past 5 auto-resends (new `sessions/whatsapp` after backup). A 401 logout starts QR re-pair on its own; scan the new code with the phone.

## Logs

```bash
journalctl --user -u zeptoclaw-gateway.service -n 100 --no-pager
```

Do not paste full chat bodies or tokens into issues.
