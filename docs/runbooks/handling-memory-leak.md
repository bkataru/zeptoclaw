# Memory / crash notes

Known classes (fixed in current Zig):

- UAF in WhatsApp handler: slices passed into `NIMClient.chat` / `runTurn` must outlive the call. Hoist workspace/history buffers to the `blk` that owns the turn; `defer` after the call.
- RPC deadlock: never call `sendMessage` on the stdout reader thread.
- Stdout spin: skip non-JSON lines without skipping the newline advance.

Debug a hang with `journalctl` plus `pgrep -af 'zeptoclaw-gateway|baileys_wrapper'`. A live Node with no Zig `inbound` lines means the reader died or JSON parse failed.
