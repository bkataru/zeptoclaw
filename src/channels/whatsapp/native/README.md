# WhatsApp Native (Zig whatsmeow port)

Target: replace Baileys JS bridge with pure Zig.

Source: tulir/whatsmeow (Go, MPL-2.0) cloned to /tmp/whatsmeow.
Reference: WhiskeySockets/Baileys src/channels/whatsapp/baileys_wrapper.js 710 lines.

## Mapping

| whatsmeow | ZeptoClaw Zig | Status |
|-----------|---------------|--------|
| binary/attrs.go, encoder.go, decoder.go, node.go | binary.zig | todo |
| binary/proto/* | proto.zig (zig-protobuf) | todo |
| handshake.go (NOISE_XX) | handshake.zig (std.crypto + noise) | todo |
| socket/noisehandshake.go, noisesocket.go, framesocket.go | socket.zig | todo |
| qrchan.go, pair.go | pair.zig | todo |
| client.go (1066 lines) | client.zig | todo |
| store/sqlstore | store.zig (sqlite) | todo |
| appstate/* | appstate.zig | defer |

## Build

BUILD:0 on 0.16.0 via `zig build` — native module compiles to no-op until wired.

## CLI

`zeptoclaw whatsapp pair` / `zeptoclaw channels login` already dispatch via
src/channels/whatsapp/pairing.zig (BUILD:0, hides node). Native backend swaps
behind same WhatsAppChannel interface — no CLI change.
