# Drift report

Checked the README contracts added or corrected on 2026-10-30 against the Zig and TypeScript they cite. A cited `file:symbol` was treated as drift only when the symbol is missing or the sentence states behavior the body does not have. Public symbols omitted from the owning README were also searched; none were missing.

## Reconciliation (2026-10-31)

- `http_utils.zig:validateWebhookToken`: fixed in code — the compare now runs in constant time (`constantTimeEql`), so the constant-time wording in `src/services/README.md` is accurate.
- `src/channels/whatsapp/native/README.md`: bullets that carried a source-file section banner now state each symbol's behavior (or keep their content with the banner removed).

## src/services/README.md

- `http_utils.zig:validateWebhookToken` is described as a constant-time compare. The body calls `std.mem.eql`. The comment above that call says "constant-time", and the comment above the function says the check is a simple string comparison, not an HMAC. The implementation is ordinary equality.

## src/channels/whatsapp/native/README.md

- Several Interface bullets attach a section banner to the next `pub` symbol instead of that symbol's behavior.
- `jid.zig:atIndex` is described as LID versus phone Signal addressing. The function returns the index of `@`, or null.
- `noise_crypto.zig:noise_start_pattern` is described as "WhatsApp Noise constants". The declaration is the protocol-name string `Noise_XX_25519_AESGCM_SHA256` plus four zero bytes. The following constants (`wa_magic_value`, `dict_version`, `wa_conn_header`, and the rest of that block) are labeled only "constant" plus the name.
- `noise_crypto.zig:sha256` is described as "Low-level crypto helpers". The function hashes its input with SHA-256 and returns 32 bytes.

## Other generated contracts

No drift detected in the checks that were run. Every column-0 `pub` in those directories is named in that directory's README, every `file:symbol` citation resolves to a real declaration, and these tables match the code: `http_server.zig:routeRequest`, `shell2http_endpoints.zig:endpoints`, and `webhook_endpoints.zig:endpoints`. `migration_config.zig` rejects temperature outside 0.0–1.0 and `validator.zig:validate` allows 0.0–2.0, which is what `src/config/README.md` says. Function bodies outside `native/` and `http_utils.zig:validateWebhookToken` were not compared sentence by sentence.
