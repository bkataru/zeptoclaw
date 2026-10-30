# tools

## Overview

Standalone WhatsApp native-client CLI utilities built on `zeptoclaw`’s WhatsApp native stack. `wa_pair.zig` runs an interactive pairing loop (QR, reconnect, inbound message logging) into a separate sqlite auth directory from the live gateway. `wa_send.zig` sends one outbound text using an existing paired store, using a background poll thread so IQ responses can complete.

## Interface

- `wa_pair.zig:main` — Entry point for `zeptoclaw-wa-pair [auth-dir]`; defaults auth dir to `~/.zeptoclaw/sessions/whatsapp-native`.
- `wa_send.zig:main` — Entry point for `zeptoclaw-wa-send <db-path> <to-jid> <text>`; requires three arguments after the program name.

## Invariants

- `wa_pair.zig:main` — Default auth directory is distinct from the gateway session dir (`whatsapp-native` vs `whatsapp`) so pairing does not overwrite the live gateway store.
- `wa_pair.zig:main` — On `disconnected` with `logged_out`, the process returns without reconnecting.
- `wa_pair.zig:main` — QR display uses only the first ref when multiple QR codes are pending (server rotation).
- `wa_send.zig:main` — `sendText` is invoked from main while a dedicated thread runs `poll()` (matches gateway reader/agent split).
- `wa_send.zig:main` — Waits up to ~30s (200 ms steps) for `.connected` before failing with `error.Timeout`.

## Side Effects

- `wa_pair.zig:main` — Creates auth directory tree, opens/creates sqlite store at `{auth-dir}/store.db`, connects to WhatsApp, prints QR and messages to stderr, reconnects with exponential backoff up to 60s.
- `wa_send.zig:main` — Opens sqlite store, connects, spawns poll thread, sends one message, sleeps 8s for ack observation, disconnects and joins thread; prints usage or errors to stderr.

## Verification

- Run: `zig build test`
