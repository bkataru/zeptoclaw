//! media.zig — WhatsApp E2E-encrypted media: key derivation, authenticated
//! decrypt/encrypt, download/upload URL construction, and fetch/upload behind
//! an injectable transport.
//!
//! Wire scheme (pinned against the installed WhatsApp web + whatsmeow sources;
//! verified byte-for-byte against WhatsApp web by the node fixtures in the tests):
//!
//! * Keys (WhatsApp web `getMediaKeys`/lib `hkdf`, whatsmeow `getMediaKeys`):
//!   okm = HKDF-SHA256(ikm = media_key[32], salt = 32 zero bytes,
//!   info = Kind.infoString(), L = 112);
//!   iv = okm[0..16], cipher_key = okm[16..48], mac_key = okm[48..80],
//!   ref_key = okm[80..112].
//!   WhatsApp web consumes only the first 80 bytes; ref_key is whatsmeow's fourth
//!   slice. WhatsApp web passes an empty salt to WebCrypto HKDF and whatsmeow a
//!   nil salt to Go HKDF — both normalize to the HMAC all-zero key block, so
//!   the 32-zero-byte salt used here is byte-identical (asserted empty-salt
//!   vs 32-zero-salt equality during fixture generation).
//!
//! * Standard media ciphertext (WhatsApp web `encryptedStream` /
//!   `downloadEncryptedContent`, whatsmeow `Upload`/`downloadAndDecrypt`):
//!   blob = AES-256-CBC(cipher_key, iv, PKCS7(plaintext)) ||
//!   HMAC-SHA256(mac_key, iv || ciphertext)[0..10].
//!   The IV is *not* prefixed on the wire — it comes from the derived keys,
//!   so encryption is deterministic and re-encrypting a downloaded file
//!   reproduces the stored blob byte-for-byte. Decryption verifies the
//!   truncated MAC (constant time) before PKCS7-unpadding (whatsmeow's
//!   `validateMedia` order).
//!
//! * Second, AEAD path discovered (NOT used for standard media transfer):
//!   media-retry notifications only (WhatsApp web `encryptMediaRetryRequest` /
//!   `decryptMediaRetryData`): retry_key = HKDF-SHA256(media_key, zero salt,
//!   info "WhatsApp Media Retry Notification", L = 32), then AES-256-GCM
//!   with a fresh random 12-byte IV (sent separately as `<enc_iv>`), AAD =
//!   stanza id, 16-byte tag suffixed on the ciphertext (`aesEncryptGCM` in
//!   WhatsApp web Utils/crypto.js). Not implemented here.
//!
//! * Download URL (WhatsApp web `downloadContentFromMessage`): a url already
//!   prefixed `https://mmg.whatsapp.net/` is used verbatim; otherwise the
//!   directPath must start with '/' and gets `https://mmg.whatsapp.net`
//!   prepended. No auth params — directPath carries its own query.
//!   (whatsmeow additionally appends `&hash=..&mms-type=..&__wa-mms=` and
//!   retries over media-conn hosts; that is server-side bookkeeping — the
//!   plain WhatsApp web form is authoritative here.)
//!
//! * Upload (whatsmeow `rawUpload`, upload.go): POST
//!   `https://{hostname}/mms/{mmsType}/{token}?auth={auth}&token={token}`
//!   where token = base64url(file_enc_sha256) WITH '=' padding (Go
//!   base64.URLEncoding), query values percent-escaped Go
//!   url.Values.Encode() style (auth sorts before token), the raw token kept
//!   literal in the path. Body = the encrypted blob; the response is JSON
//!   `{"url":...,"direct_path":...}` on modern servers (WhatsApp web and every
//!   fetched whatsmeow revision decode JSON; the older
//!   `<upload><url>..</url><direct_path>..</direct_path></upload>` XML form
//!   is still parsed too — `upload` sniffs by first byte). WhatsApp web strips
//!   the '=' padding from the token instead
//!   (`encodeBase64EncodedStringForUpload`); the servers accept both.

const std = @import("std");

const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Aes256 = std.crypto.core.aes.Aes256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

/// Truncated HMAC length appended to media ciphertext (whatsmeow
/// `mediaHMACLength`, WhatsApp web `hmac.digest().slice(0, 10)`).
pub const media_hmac_length: usize = 10;
/// HKDF expansion length (WhatsApp web `hkdf(buffer, 112, ...)`, whatsmeow
/// `hkdfutil.SHA256(mediaKey, nil, info, 112)`).
pub const hkdf_expand_length: usize = 112;
/// Default media download host (WhatsApp web `DEF_HOST`).
pub const mmg_host: []const u8 = "mmg.whatsapp.net";

/// Media classes with their per-type key/info strings.
pub const Kind = enum {
    image,
    video,
    audio,
    ptt,
    document,
    sticker,

    /// HKDF info string. WhatsApp web `hkdfInfoKey` = `WhatsApp ${
    /// MEDIA_HKDF_KEY_MAPPING[type] } Keys` (Defaults/index.js: audio/ptt ->
    /// "Audio", image/sticker -> "Image", video -> "Video", document ->
    /// "Document"); identical to whatsmeow's MediaType constants.
    pub fn infoString(self: Kind) []const u8 {
        return switch (self) {
            .image, .sticker => "WhatsApp Image Keys",
            .video => "WhatsApp Video Keys",
            .audio, .ptt => "WhatsApp Audio Keys",
            .document => "WhatsApp Document Keys",
        };
    }

    /// MMS path segment for uploads and whatsmeow-style downloads.
    /// WhatsApp web MEDIA_PATH_MAP: sticker -> /mms/image; ptt voice notes are
    /// uploaded with mediaType 'audio' (Utils/messages.js keeps 'ptt' only
    /// as an AudioMessage flag). whatsmeow mediaTypeToMMSType: image/audio/
    /// video/document map 1:1, StickerMessage uses MediaImage ("image"),
    /// voice notes MediaAudio ("audio").
    pub fn mmsType(self: Kind) []const u8 {
        return switch (self) {
            .image, .sticker => "image",
            .video => "video",
            .audio, .ptt => "audio",
            .document => "document",
        };
    }
};

/// Keys derived from a 32-byte media key.
pub const Keys = struct {
    iv: [16]u8,
    cipher_key: [32]u8,
    mac_key: [32]u8,
    ref_key: [32]u8,
};

pub fn deriveKeys(kind: Kind, media_key: *const [32]u8) Keys {
    var salt: [32]u8 = undefined;
    @memset(&salt, 0);
    const prk = Hkdf.extract(&salt, media_key[0..]);
    var okm: [hkdf_expand_length]u8 = undefined;
    Hkdf.expand(&okm, kind.infoString(), prk);
    var k: Keys = undefined;
    @memcpy(k.iv[0..], okm[0..16]);
    @memcpy(k.cipher_key[0..], okm[16..48]);
    @memcpy(k.mac_key[0..], okm[48..80]);
    @memcpy(k.ref_key[0..], okm[80..112]);
    return k;
}

/// Decrypt an encrypted media blob (ciphertext || 10-byte HMAC). The
/// returned slice is allocated with `alloc`; caller frees.
pub fn decryptMedia(alloc: std.mem.Allocator, keys: Keys, blob: []const u8) ![]u8 {
    if (blob.len <= media_hmac_length) return error.BlobTooShort;
    const ciphertext = blob[0 .. blob.len - media_hmac_length];
    const mac = blob[blob.len - media_hmac_length ..];
    if (ciphertext.len % 16 != 0) return error.BadCiphertextLength;
    if (!checkMac(keys, ciphertext, mac)) return error.BadMac;
    return cbcDecryptPkcs7(alloc, keys.cipher_key, keys.iv, ciphertext);
}

/// Encrypt `plaintext` into an upload-ready blob (deterministic: the IV is
/// derived from the media key, matching whatsmeow `Upload` and WhatsApp web
/// `encryptedStream` for a fixed key). The returned slice is allocated with
/// `alloc`; caller frees.
pub fn encryptMedia(alloc: std.mem.Allocator, keys: Keys, plaintext: []const u8) ![]u8 {
    const pad: u8 = @intCast(16 - (plaintext.len % 16));
    const out = try alloc.alloc(u8, plaintext.len + pad + media_hmac_length);
    errdefer alloc.free(out);
    @memcpy(out[0..plaintext.len], plaintext);
    @memset(out[plaintext.len..][0..pad], pad);
    const ciphertext = out[0 .. plaintext.len + pad];
    const ctx = Aes256.initEnc(keys.cipher_key);
    var prev = keys.iv;
    var i: usize = 0;
    while (i < ciphertext.len) : (i += 16) {
        var block: [16]u8 = undefined;
        @memcpy(&block, ciphertext[i .. i + 16]);
        for (0..16) |j| block[j] ^= prev[j];
        var enc_block: [16]u8 = undefined;
        ctx.encrypt(&enc_block, &block);
        @memcpy(ciphertext[i .. i + 16], &enc_block);
        prev = enc_block;
    }
    appendMac(keys, ciphertext, out[plaintext.len + pad ..]);
    return out;
}

fn appendMac(keys: Keys, ciphertext: []const u8, dest: []u8) void {
    var h = Hmac.init(&keys.mac_key);
    h.update(keys.iv[0..]);
    h.update(ciphertext);
    var full: [32]u8 = undefined;
    h.final(&full);
    @memcpy(dest[0..media_hmac_length], full[0..media_hmac_length]);
}

fn checkMac(keys: Keys, ciphertext: []const u8, mac: []const u8) bool {
    if (mac.len != media_hmac_length) return false;
    var h = Hmac.init(&keys.mac_key);
    h.update(keys.iv[0..]);
    h.update(ciphertext);
    var full: [32]u8 = undefined;
    h.final(&full);
    return std.crypto.timing_safe.eql(
        [media_hmac_length]u8,
        full[0..media_hmac_length].*,
        mac[0..media_hmac_length].*,
    );
}

fn cbcDecryptPkcs7(alloc: std.mem.Allocator, key: [32]u8, iv: [16]u8, ciphertext: []const u8) ![]u8 {
    if (ciphertext.len == 0 or ciphertext.len % 16 != 0) return error.BadCiphertextLength;
    const buf = try alloc.dupe(u8, ciphertext);
    defer alloc.free(buf);
    const ctx = Aes256.initDec(key);
    var prev = iv;
    var i: usize = 0;
    while (i < buf.len) : (i += 16) {
        const ct_block = buf[i .. i + 16][0..16].*;
        var dec: [16]u8 = undefined;
        ctx.decrypt(&dec, &ct_block);
        for (0..16) |j| buf[i + j] = dec[j] ^ prev[j];
        prev = ct_block;
    }
    const pad = buf[buf.len - 1];
    if (pad == 0 or pad > 16 or pad > buf.len) return error.BadPadding;
    var p: usize = buf.len - pad;
    while (p < buf.len) : (p += 1) {
        if (buf[p] != pad) return error.BadPadding;
    }
    return alloc.dupe(u8, buf[0 .. buf.len - pad]);
}

/// Build the download URL exactly as WhatsApp web `downloadContentFromMessage`:
/// absolute `https://mmg.whatsapp.net/...` urls pass through, a leading-'/'
/// directPath gets the host prefix. `kind` does not affect the URL (the
/// server routes on the path itself) but is kept for call symmetry with
/// `download`. Caller frees the result.
pub fn buildDownloadUrl(alloc: std.mem.Allocator, direct_path_or_url: []const u8, kind: Kind) ![]u8 {
    _ = kind;
    const prefix = "https://" ++ mmg_host ++ "/";
    if (std.mem.startsWith(u8, direct_path_or_url, prefix)) return alloc.dupe(u8, direct_path_or_url);
    if (direct_path_or_url.len == 0 or direct_path_or_url[0] != '/') return error.InvalidDownloadTarget;
    return std.fmt.allocPrint(alloc, "https://{s}{s}", .{ mmg_host, direct_path_or_url });
}

/// Minimal HTTP vtable the parent backs with its own socket/TLS stack.
/// Contract: implementations return the response body as a slice whose
/// memory is owned by the transport (valid at least until the next call to
/// the same transport) — this module never frees it and never retains it
/// past the call that returned it. Implementations MUST return an error for
/// non-2xx responses (whatsmeow treats a non-200 upload as failure;
/// WhatsApp web lets axios throw).
pub const Transport = struct {
    ptr: *anyopaque,
    getFn: *const fn (ptr: *anyopaque, url: []const u8) anyerror![]const u8,
    postFn: *const fn (ptr: *anyopaque, url: []const u8, body: []const u8) anyerror![]const u8,

    pub fn get(self: Transport, url: []const u8) anyerror![]const u8 {
        return self.getFn(self.ptr, url);
    }

    pub fn post(self: Transport, url: []const u8, body: []const u8) anyerror![]const u8 {
        return self.postFn(self.ptr, url, body);
    }
};

/// Fetch + decrypt in one call. Caller frees the result.
pub fn download(
    alloc: std.mem.Allocator,
    kind: Kind,
    media_key: *const [32]u8,
    direct_path_or_url: []const u8,
    transport: Transport,
) ![]u8 {
    const url = try buildDownloadUrl(alloc, direct_path_or_url, kind);
    defer alloc.free(url);
    const blob = try transport.get(url);
    const keys = deriveKeys(kind, media_key);
    return decryptMedia(alloc, keys, blob);
}

/// Upload URL per whatsmeow `rawUpload`. `file_enc_sha256` must be 32
/// bytes. Caller frees the result.
pub fn buildUploadUrl(
    alloc: std.mem.Allocator,
    kind: Kind,
    file_enc_sha256: []const u8,
    auth: []const u8,
    hostname: []const u8,
) ![]u8 {
    if (file_enc_sha256.len != 32) return error.BadHashLength;
    const token = try encodeB64UrlPadded(alloc, file_enc_sha256);
    defer alloc.free(token);
    const q_auth = try queryEscape(alloc, auth);
    defer alloc.free(q_auth);
    const q_token = try queryEscape(alloc, token);
    defer alloc.free(q_token);
    // url.Values.Encode() sorts keys: auth before token.
    return std.fmt.allocPrint(
        alloc,
        "https://{s}/mms/{s}/{s}?auth={s}&token={s}",
        .{ hostname, kind.mmsType(), token, q_auth, q_token },
    );
}

/// POST an already-encrypted blob (`encryptMedia` output) and parse the
/// server response. `file_enc_sha256` (32 bytes) is the SHA-256 of
/// `enc_file`; it forms the path/query token. Caller frees fields via
/// `UploadResult.deinit`.
pub fn upload(
    alloc: std.mem.Allocator,
    kind: Kind,
    enc_file: []const u8,
    file_enc_sha256: []const u8,
    transport: Transport,
    auth: []const u8,
    hostname: []const u8,
) !UploadResult {
    const url = try buildUploadUrl(alloc, kind, file_enc_sha256, auth, hostname);
    defer alloc.free(url);
    const body = try transport.post(url, enc_file);
    return parseUploadResponse(alloc, body);
}

pub const UploadResult = struct {
    /// An absent field is the empty string; at least one of the two is
    /// always non-empty (else parsing errors). Both fields are allocated
    /// with the allocator passed to the parser.
    url: []const u8,
    direct_path: []const u8,

    pub fn deinit(self: *UploadResult, alloc: std.mem.Allocator) void {
        alloc.free(self.url);
        alloc.free(self.direct_path);
    }
};

/// Sniff the upload response: JSON (current servers — WhatsApp web and all
/// fetched whatsmeow revisions decode JSON) or the older XML form.
pub fn parseUploadResponse(alloc: std.mem.Allocator, body: []const u8) !UploadResult {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '{') return parseUploadJson(alloc, trimmed);
    return parseUploadXml(alloc, trimmed);
}

/// Parse `{"url":"...","direct_path":"...", ...}` (extra fields ignored).
pub fn parseUploadJson(alloc: std.mem.Allocator, json: []const u8) !UploadResult {
    var res = UploadResult{ .url = "", .direct_path = "" };
    errdefer {
        if (res.url.len != 0) alloc.free(res.url);
        if (res.direct_path.len != 0) alloc.free(res.direct_path);
    }
    if (try jsonStringForKey(alloc, json, "url")) |u| res.url = u;
    if (try jsonStringForKey(alloc, json, "direct_path")) |d| res.direct_path = d;
    if (res.url.len == 0 and res.direct_path.len == 0) return error.NoUploadResult;
    if (res.url.len == 0) res.url = try alloc.dupe(u8, "");
    if (res.direct_path.len == 0) res.direct_path = try alloc.dupe(u8, "");
    return res;
}

/// Parse the classic upload response. Supports both child-text form
/// `<upload><url>..</url><direct_path>..</direct_path></upload>` (optionally
/// wrapped, e.g. in `<response>`) and attribute form
/// `<upload url=".." direct_path=".."/>` (also `direct-path=".."`).
pub fn parseUploadXml(alloc: std.mem.Allocator, xml_text: []const u8) !UploadResult {
    var res = UploadResult{ .url = "", .direct_path = "" };
    errdefer {
        if (res.url.len != 0) alloc.free(res.url);
        if (res.direct_path.len != 0) alloc.free(res.direct_path);
    }

    // Locate the <upload ...> start tag.
    var pos: usize = 0;
    var tag_start: usize = undefined;
    while (std.mem.indexOfPos(u8, xml_text, pos, "<upload")) |at| {
        pos = at + 1;
        const after = at + "<upload".len;
        const c: u8 = if (after < xml_text.len) xml_text[after] else '>';
        if (c != ' ' and c != '>' and c != '/' and c != '\t' and c != '\r' and c != '\n') continue;
        tag_start = after;
        break;
    } else return error.MalformedUploadResponse;

    // Scan to the end of the start tag, honouring quoted attribute values.
    var i = tag_start;
    var tag_end: usize = undefined;
    var self_closing = false;
    var quote: u8 = 0;
    while (i < xml_text.len) : (i += 1) {
        const c = xml_text[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '>') {
            tag_end = i;
            self_closing = i > tag_start and xml_text[i - 1] == '/';
            break;
        }
    } else return error.MalformedUploadResponse;

    // Attributes on the <upload> tag.
    const tag_text = xml_text[tag_start..tag_end];
    if (xmlAttr(tag_text, "url")) |v| res.url = try xmlUnescape(alloc, v);
    if (try xmlAttrAny(alloc, tag_text, &.{ "direct_path", "direct-path" })) |d| res.direct_path = d;

    // Child elements <url>text</url> / <direct_path>text</direct_path>.
    if (!self_closing) {
        const close_at = std.mem.indexOfPos(u8, xml_text, tag_end + 1, "</upload>") orelse
            return error.MalformedUploadResponse;
        const inner = xml_text[tag_end + 1 .. close_at];
        if (res.url.len == 0) {
            if (xmlChildText(inner, "url")) |t| res.url = try xmlUnescape(alloc, t);
        }
        if (res.direct_path.len == 0) {
            if (xmlChildText(inner, "direct_path")) |t| res.direct_path = try xmlUnescape(alloc, t);
        }
    }

    if (res.url.len == 0 and res.direct_path.len == 0) return error.NoUploadResult;
    if (res.url.len == 0) res.url = try alloc.dupe(u8, "");
    if (res.direct_path.len == 0) res.direct_path = try alloc.dupe(u8, "");
    return res;
}

// ---------------------------------------------------------------- plumbing

fn encodeB64UrlPadded(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    const enc = std.base64.url_safe.Encoder;
    const out = try alloc.alloc(u8, enc.calcSize(src.len));
    errdefer alloc.free(out);
    _ = enc.encode(out, src);
    return out;
}

/// Go `url.QueryEscape` / JS `encodeURIComponent` equivalent for the
/// base64/auth character set: unreserved [A-Za-z0-9-_.~] pass through,
/// space becomes '+', everything else %XX (upper-case hex).
fn queryEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, s.len);
    errdefer out.deinit(alloc);
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(alloc, c),
            ' ' => try out.append(alloc, '+'),
            else => {
                try out.append(alloc, '%');
                var buf: [2]u8 = undefined;
                _ = std.fmt.bufPrint(&buf, "{X:0>2}", .{c}) catch unreachable;
                try out.appendSlice(alloc, &buf);
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Find attribute `name` in start-tag text; returns the raw (still escaped)
/// value.
fn xmlAttr(tag: []const u8, comptime name: []const u8) ?[]const u8 {
    return xmlAttrRaw(tag, &.{name});
}

/// Find the first attribute matching any of `names` (comptime list);
/// percent-… no, XML-unescape the winner.
fn xmlAttrAny(
    alloc: std.mem.Allocator,
    tag: []const u8,
    comptime names: []const []const u8,
) !?[]u8 {
    if (xmlAttrRaw(tag, names)) |v| return try xmlUnescape(alloc, v);
    return null;
}

fn xmlAttrRaw(tag: []const u8, comptime names: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) {
        const name_start = i;
        while (i < tag.len and (std.ascii.isAlphanumeric(tag[i]) or tag[i] == '_' or tag[i] == '-')) i += 1;
        if (i == name_start) {
            i += 1; // skip junk (spaces, '/', '=') one byte at a time
            continue;
        }
        const key = tag[name_start..i];
        var j = i;
        while (j < tag.len and std.ascii.isWhitespace(tag[j])) j += 1;
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and std.ascii.isWhitespace(tag[j])) j += 1;
        if (j >= tag.len or (tag[j] != '"' and tag[j] != '\'')) continue;
        const q = tag[j];
        const val_start = j + 1;
        const val_end = std.mem.indexOfScalarPos(u8, tag, val_start, q) orelse return null;
        inline for (names) |n| {
            if (std.mem.eql(u8, key, n)) return tag[val_start..val_end];
        }
        i = val_end + 1;
    }
    return null;
}

fn xmlChildText(region: []const u8, comptime name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, region, pos, "<" ++ name)) |at| {
        pos = at + 1;
        const after = at + name.len + 1;
        const c: u8 = if (after < region.len) region[after] else '>';
        if (c != '>' and c != ' ' and c != '/' and c != '\t' and c != '\r' and c != '\n') continue;
        const gt = std.mem.indexOfScalarPos(u8, region, after, '>') orelse return null;
        const close = std.mem.indexOfPos(u8, region, gt + 1, "</" ++ name ++ ">") orelse return null;
        return region[gt + 1 .. close];
    }
    return null;
}

/// XML character-data/attribute unescaping: &amp; &lt; &gt; &quot; &apos;,
/// &#NUM; and &#xHEX;. Unknown entities are passed through literally.
fn xmlUnescape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, s.len);
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c != '&') {
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, s, i + 1, ';') orelse {
            try out.append(alloc, c);
            i += 1;
            continue;
        };
        const ent = s[i + 1 .. semi];
        if (std.mem.eql(u8, ent, "amp")) {
            try out.append(alloc, '&');
        } else if (std.mem.eql(u8, ent, "lt")) {
            try out.append(alloc, '<');
        } else if (std.mem.eql(u8, ent, "gt")) {
            try out.append(alloc, '>');
        } else if (std.mem.eql(u8, ent, "quot")) {
            try out.append(alloc, '"');
        } else if (std.mem.eql(u8, ent, "apos")) {
            try out.append(alloc, '\'');
        } else if (std.mem.startsWith(u8, ent, "#x") or std.mem.startsWith(u8, ent, "#X")) {
            const cp = std.fmt.parseInt(u21, ent[2..], 16) catch {
                try out.append(alloc, c);
                i += 1;
                continue;
            };
            try appendCodepoint(&out, alloc, cp);
        } else if (ent.len > 1 and ent[0] == '#') {
            const cp = std.fmt.parseInt(u21, ent[1..], 10) catch {
                try out.append(alloc, c);
                i += 1;
                continue;
            };
            try appendCodepoint(&out, alloc, cp);
        } else {
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        i = semi + 1;
    }
    return out.toOwnedSlice(alloc);
}

fn appendCodepoint(out: *std.ArrayList(u8), alloc: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.appendSlice(alloc, "\u{FFFD}");
        return;
    };
    try out.appendSlice(alloc, buf[0..n]);
}

fn skipJsonWs(s: []const u8, i: *usize) void {
    while (i.* < s.len) : (i.* += 1) {
        switch (s[i.*]) {
            ' ', '\t', '\r', '\n' => {},
            else => return,
        }
    }
}

/// Find `"key"` followed by a colon and a JSON string; returns the decoded
/// value. `"key":null` and an absent key are both treated as absent.
fn jsonStringForKey(alloc: std.mem.Allocator, json: []const u8, comptime key: []const u8) !?[]u8 {
    const needle = "\"" ++ key ++ "\"";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, json, pos, needle)) |at| {
        pos = at + needle.len;
        var i = at + needle.len;
        skipJsonWs(json, &i);
        if (i >= json.len or json[i] != ':') continue;
        i += 1;
        skipJsonWs(json, &i);
        if (i >= json.len) continue;
        if (json[i] == '"') return try parseJsonString(alloc, json, i);
        if (std.mem.startsWith(u8, json[i..], "null")) continue; // absent field
        return error.MalformedUploadResponse; // non-string value where a string is expected
    }
    return null;
}

fn parseJsonString(alloc: std.mem.Allocator, json: []const u8, open: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i = open + 1;
    while (i < json.len) {
        const c = json[i];
        switch (c) {
            '"' => return out.toOwnedSlice(alloc),
            '\\' => {
                if (i + 1 >= json.len) break;
                const e = json[i + 1];
                i += 2;
                switch (e) {
                    '"' => try out.append(alloc, '"'),
                    '\\' => try out.append(alloc, '\\'),
                    '/' => try out.append(alloc, '/'),
                    'b' => try out.append(alloc, 8),
                    'f' => try out.append(alloc, 12),
                    'n' => try out.append(alloc, '\n'),
                    'r' => try out.append(alloc, '\r'),
                    't' => try out.append(alloc, '\t'),
                    'u' => {
                        if (i + 4 > json.len) return error.MalformedUploadResponse;
                        const cp = std.fmt.parseInt(u16, json[i..][0..4], 16) catch
                            return error.MalformedUploadResponse;
                        i += 4;
                        var code: u21 = cp;
                        if (cp >= 0xD800 and cp <= 0xDBFF) {
                            // surrogate pair
                            if (i + 6 > json.len or json[i] != '\\' or json[i + 1] != 'u')
                                return error.MalformedUploadResponse;
                            const lo = std.fmt.parseInt(u16, json[i + 2 ..][0..4], 16) catch
                                return error.MalformedUploadResponse;
                            if (lo < 0xDC00 or lo > 0xDFFF) return error.MalformedUploadResponse;
                            code = 0x10000 + ((@as(u21, cp) - 0xD800) << 10) + (@as(u21, lo) - 0xDC00);
                            i += 6;
                        } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
                            return error.MalformedUploadResponse;
                        }
                        try appendCodepoint(&out, alloc, code);
                    },
                    else => return error.MalformedUploadResponse,
                }
            },
            else => {
                try out.append(alloc, c);
                i += 1;
            },
        }
    }
    return error.MalformedUploadResponse; // unterminated string
}

// ------------------------------------------------------------------- tests

test "Kind info + mms strings" {
    try std.testing.expectEqualStrings("WhatsApp Image Keys", Kind.image.infoString());
    try std.testing.expectEqualStrings("WhatsApp Video Keys", Kind.video.infoString());
    try std.testing.expectEqualStrings("WhatsApp Audio Keys", Kind.audio.infoString());
    try std.testing.expectEqualStrings("WhatsApp Audio Keys", Kind.ptt.infoString());
    try std.testing.expectEqualStrings("WhatsApp Document Keys", Kind.document.infoString());
    try std.testing.expectEqualStrings("WhatsApp Image Keys", Kind.sticker.infoString());
    try std.testing.expectEqualStrings("image", Kind.image.mmsType());
    try std.testing.expectEqualStrings("video", Kind.video.mmsType());
    try std.testing.expectEqualStrings("audio", Kind.audio.mmsType());
    try std.testing.expectEqualStrings("audio", Kind.ptt.mmsType());
    try std.testing.expectEqualStrings("document", Kind.document.mmsType());
    try std.testing.expectEqualStrings("image", Kind.sticker.mmsType());
}

fn hexNibble(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    const lo = c | 0x20;
    std.debug.assert(lo >= 'a' and lo <= 'f');
    return lo - 'a' + 10;
}

fn hx(comptime s: []const u8) [s.len / 2]u8 {
    std.debug.assert(s.len % 2 == 0);
    var out: [s.len / 2]u8 = undefined;
    @setEvalBranchQuota(100000);
    for (&out, 0..) |*b, i| {
        b.* = (hexNibble(s[i * 2]) << 4) | hexNibble(s[i * 2 + 1]);
    }
    return out;
}

fn unhex(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, s.len / 2);
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i + 2 <= s.len) : (i += 2) {
        try out.append(alloc, std.fmt.parseInt(u8, s[i..][0..2], 16) catch return error.BadHex);
    }
    return out.toOwnedSlice(alloc);
}

// Fixtures below were produced by /tmp/mediavec/gen.mjs against the
// installed WhatsApp web multi-device (getMediaKeys + encryptedStream-style
// aes-256-cbc + HMAC(macKey, iv||ct)[0..10]). media_key = 32 * kind-byte.
const Fixture = struct {
    kind: Kind,
    expanded: [hkdf_expand_length]u8,
    blobs: [3][]const u8, // {100-byte pt, 16-byte pt, empty pt}
};

const pt100 = "030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bcc3cad1d8dfe6edf4fb020910171e252c333a41484f565d646b727980878e959ca3aab1b8";
const pt16 = "30313233343536373839616263646566";
const pt0 = "";

const fixtures = [_]Fixture{
    .{
        .kind = .image,
        .expanded = hx("c3994d20d318005274c80ebc6e20b29b85948aeaa63e60cdf785c365ac057f150d47cb99ac8ed9c6b6ea6fe1e13f5a4c93ee1e1836fe3c24a01193b97e8001f2f1acad6d2e667cf9e9f2017b4a601dd5ae9723ea0811063aebc1c0e166cc9879045a15e4b9d5602e0724abcd10cea12b"),
        .blobs = .{
            "0177d61d0fcace6afdd931ef457bb694226eac2ca89ef97055c04255e5fc3eae82989426d83ef40bb5fb789177dcb8acdd5ded2e474dac10174362644eae6a20a8e759ce620e8028bc0417f2a55da7b9d4e92b184ea47f1c6cddedb020ae6d5861071b60e59848454248f85ed5f0a6461803c2425f7a8bf32ab1",
            "dfeaa75f3d35fbc61d8fe9c661be58f675f63be7d8925821987bf38c8a1cc9d818993f9e9c7a5e75bdcf",
            "521b75e66a5eefddf3e410b2eb69ef34ff4476bcb3d67442ac8c",
        },
    },
    .{
        .kind = .video,
        .expanded = hx("dac77bbf5b45666965010ca70dd3c4f204ba5ba4ea7788630d850136da3129ab90257dc5f520ba28334b780302360497c819d9ca551d38ed71c2e7cf07287a529011c1cb5f85b602b21eacc5a7771c555c03830d8bb14dcc9877adebe35f14c592ea0da5736875b4c8ce8fa500faaae6"),
        .blobs = .{
            "06c0932c7d25269a59225642dd2d186ba2b61c03989edc5fadaac68aee03c286e3cee815875f8346fb258e443897d9a1f2eee8eb32d6e1799359fe9769fae74820a371bac431647630cbff797a97eaa48f45ac4fc6bfe0a787eed96ec7d2c614e8c029865fc126ee329e652b120a5377da2250711f138c88a6a9",
            "c3a63537f0521647c8d1b4fb09370d211cd053230febcea1f9ae7ee1354ab259b7243cfc1e2acf5647bd",
            "aee142d30256efc3c7361cd7d4d979bf3934c0a3258354d6886b",
        },
    },
    .{
        .kind = .audio,
        .expanded = hx("c97362abeca1d9de50a8577fc7be8fd523e7e152728459d0aa244bfb38c33ebf4a16206619c6a05cfde93140a9bf2469a3d7f65caa451d5df2e95a7d3ff34297bfaebd19b542eacd452658a18c5162dd4a347dcd6f49bf9466b9f6c0d9067c3a0b40203fabd6b7cdb3019f361a891cd1"),
        .blobs = .{
            "579cbbb6deb5096bf45d36aeeb7485e4a66e2744691c920c53b4a3fc89d18a140d135f250cc666aab8bc0c2e21cddb279f1c67cd8474c709b5ae3ef684baf66dc71d1eae23dcdc3ddfe4d060de5c0662a041ea86887bac13f5d1f81894b7e71ec19b59d142cecf1f90374a5084a64207ae739dedc3315a52988d",
            "482414d2b4dac24463d911b46441550fc425b0589bc8b454066f6946a741cd99b4ca63e0209108d85a85",
            "121d7281c72eb6a82660e0800d5bce87ab64340cabaa87200293",
        },
    },
    .{
        .kind = .ptt,
        .expanded = hx("7c8aff41dbdb556dfb2e90ac6b1ea917c86a14ae7cbc4dc8297dab76129b6063f0e68318da9a5b92ac26ece39c0c598393aad5946cd90911ecb47f9e77dcf593c7cb560f1164fc9e2a1d1bc824e37ece18c68b2faa19fe3bae9628ad9887f4ead9c011ab7ddb0d8637a9264d04e6377e"),
        .blobs = .{
            "a607c3e6c4fad94d1d73148c0cb90f5cce53fb670c06198109ddeebd026e561e01c93f6404b04b0b7ca57f72840edc4a490e0a769b1a7b3e9fac4d31e81f339ac5a8302653cf0abb16a879ed7972ee40565f0cb4c9468b09d4c8b5e9a43bee1705a895152e5b3599bd05b32f8d666dfb5f40347724fda407be08",
            "479604038782ba2024f45b7c84c5af9633888887f69ef1940d496f66eea62f7a7187edde63a033795a3f",
            "6af2ec47e9113db099d8ce1ac519dd415a5efab2776a7c8d2c95",
        },
    },
    .{
        .kind = .document,
        .expanded = hx("5b7f2acd0c4ee70f9f7c2c7d1a679746965cd7bb049ce1ee478f27a3150ff848e3a8137b9a3fa227ca5793022412e8c6a0e84c5cd2c2a5e4331f148fd482cbca769efabb0ea621d6317b8fa8a33ebafb8fbeb3eaf3cf622ae067f4b628b9912600860d64d95edc1feea546bfaa62b02f"),
        .blobs = .{
            "787ce60b8f56a3f693b1d1a7d0bb495c6d9c5f29bcb89c0b72e0cad45f52c0dfa7463e61cc43f668c029deb0a3028b4d6710784e01ebfe053d6b1321738173c3ed44facc79a1120943d33cf737875b386100e63c90a3cffcbb37e6898ca74cb1eecf319abd44ca11068942212cc211404e10335bd521e353f30a",
            "dd8ec1e50e6c26b5e5957ebafdb8931c0664f7abace657dad7fb79dbbf534bbf14350256167305ce0c1e",
            "881657b77bb4a6cf079895731d7ddea418d51ca2ace29df99cc3",
        },
    },
    .{
        .kind = .sticker,
        .expanded = hx("bd5e77abc3ff1afc0d9409500a3514c7022b5ba4df60f00b7444df58fc562ce5a788d399170519b947cd54ee636bcbbebc3fca2fae5ce0714feaccf1e07aca0bc3f184a318526f85dc8b21b35eb9e250c24f081211a118d03222302ff6d0d7355b96b85cf48ccdbd3861723e84ca0efe"),
        .blobs = .{
            "8f40162ebc98fa53cb30dbd7216147ab8c14157b59cc6b368d231ebdf2317a2189434a1de68aae0523b8af47ea2951c211d9bbc6b5a2cd717f1027edead6f80ad7a03070591d99504504095c1f6be43381518e29b4143c6d2255d8c0b96146dde0b67efebd001c0726e56e8aeca56638561d52b62da3d315149d",
            "635ee84efcc401a38b97abc31a8a75bb51ae90341a0459aac47faf7432cc07ab87e4cbbad90baf9a4edb",
            "3836720cd802c42631be93f3b9218449e7c7cd74026cc6104484",
        },
    },
};

fn keyByteFor(k: Kind) u8 {
    return switch (k) {
        .image => 0x11,
        .video => 0x22,
        .audio => 0x33,
        .ptt => 0x44,
        .document => 0x55,
        .sticker => 0x66,
    };
}

test "deriveKeys matches WhatsApp web HKDF expansion" {
    for (&fixtures) |f| {
        var mk: [32]u8 = undefined;
        @memset(&mk, keyByteFor(f.kind));
        const k = deriveKeys(f.kind, &mk);
        try std.testing.expectEqualSlices(u8, f.expanded[0..16], k.iv[0..]);
        try std.testing.expectEqualSlices(u8, f.expanded[16..48], k.cipher_key[0..]);
        try std.testing.expectEqualSlices(u8, f.expanded[48..80], k.mac_key[0..]);
        try std.testing.expectEqualSlices(u8, f.expanded[80..112], k.ref_key[0..]);
    }
}

test "decrypt/encrypt round-trip vs WhatsApp web blobs" {
    const alloc = std.testing.allocator;
    const pts = [_][]const u8{ pt100, pt16, pt0 };
    for (&fixtures) |f| {
        var mk: [32]u8 = undefined;
        @memset(&mk, keyByteFor(f.kind));
        const k = deriveKeys(f.kind, &mk);
        for (f.blobs, &pts) |blob_hex, pt_hex| {
            const blob = try unhex(alloc, blob_hex);
            defer alloc.free(blob);
            const want = try unhex(alloc, pt_hex);
            defer alloc.free(want);
            const got = try decryptMedia(alloc, k, blob);
            defer alloc.free(got);
            try std.testing.expectEqualSlices(u8, want, got);
            const re = try encryptMedia(alloc, k, want);
            defer alloc.free(re);
            try std.testing.expectEqualSlices(u8, blob, re); // byte-identical (deterministic IV)
        }
    }
}

test "decrypt rejects tampered blobs" {
    const alloc = std.testing.allocator;
    const blob = try unhex(alloc, fixtures[0].blobs[1]); // 16-byte pt -> 32 ct + 10 mac
    defer alloc.free(blob);
    var mk: [32]u8 = undefined;
    @memset(&mk, keyByteFor(.image));
    const k = deriveKeys(.image, &mk);

    // correct first
    const okp = try decryptMedia(alloc, k, blob);
    alloc.free(okp);

    var t1 = try alloc.dupe(u8, blob);
    defer alloc.free(t1);
    t1[t1.len - 1] ^= 0x01; // flipped mac byte
    try std.testing.expectError(error.BadMac, decryptMedia(alloc, k, t1));

    var t2 = try alloc.dupe(u8, blob);
    defer alloc.free(t2);
    t2[3] ^= 0x80; // flipped ciphertext byte
    try std.testing.expectError(error.BadMac, decryptMedia(alloc, k, t2));

    // only the 10-byte mac, no ciphertext
    try std.testing.expectError(error.BlobTooShort, decryptMedia(alloc, k, blob[0..10]));
    // ciphertext truncated to 15 bytes: not a multiple of 16
    try std.testing.expectError(error.BadCiphertextLength, decryptMedia(alloc, k, blob[0..25]));
}

test "buildDownloadUrl vs WhatsApp web" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: ?[]const u8 }{
        .{
            .in = "/v/t2.00271818/L/0/8f3a2b1c2d3e4f50?ant=0&m=AZq7H_gB0ijFecjFMlCJbBOmK6U&sub=8B0E5F6A7D8C9BAABCDEF0123456789ABCDEF012",
            .want = "https://mmg.whatsapp.net/v/t2.00271818/L/0/8f3a2b1c2d3e4f50?ant=0&m=AZq7H_gB0ijFecjFMlCJbBOmK6U&sub=8B0E5F6A7D8C9BAABCDEF0123456789ABCDEF012",
        },
        .{
            .in = "/v/t62/88.49089-24/xyz%3D==?m=foo-bar_baz&hash=abc%2Bdef",
            .want = "https://mmg.whatsapp.net/v/t62/88.49089-24/xyz%3D==?m=foo-bar_baz&hash=abc%2Bdef",
        },
        // downloadContentFromMessage passes an already-mmg url through
        .{ .in = "https://mmg.whatsapp.net/v/t2.00271818/already-full", .want = "https://mmg.whatsapp.net/v/t2.00271818/already-full" },
        .{ .in = "http://evil.example/x", .want = null },
        .{ .in = "", .want = null },
    };
    for (&cases) |c| {
        if (c.want) |want| {
            const got = try buildDownloadUrl(alloc, c.in, .image);
            defer alloc.free(got);
            try std.testing.expectEqualStrings(want, got);
        } else {
            try std.testing.expectError(error.InvalidDownloadTarget, buildDownloadUrl(alloc, c.in, .video));
        }
    }
}

test "buildUploadUrl matches whatsmeow rawUpload" {
    const alloc = std.testing.allocator;
    // whatsmeow: token = base64.URLEncoding (padded); query = url.Values
    // {auth, token}.Encode() -> sorted, Go QueryEscape (%XX upper hex).
    const hash = hx("fbfffebf0104070a0d101316191c1f2225282b2e3134373a3d404346494c4f52");
    const got = try buildUploadUrl(alloc, .image, &hash, "ab+cd/ef=g==", "rupload.example");
    defer alloc.free(got);
    try std.testing.expectEqualStrings(
        "https://rupload.example/mms/image/-__-vwEEBwoNEBMWGRwfIiUoKy4xNDc6PUBDRklMT1I=?auth=ab%2Bcd%2Fef%3Dg%3D%3D&token=-__-vwEEBwoNEBMWGRwfIiUoKy4xNDc6PUBDRklMT1I%3D",
        got,
    );
    // mms segment follows Kind.mmsType
    const got2 = try buildUploadUrl(alloc, .ptt, &hash, "", "h.example");
    defer alloc.free(got2);
    try std.testing.expect(std.mem.startsWith(u8, got2, "https://h.example/mms/audio/"));
    try std.testing.expectError(error.BadHashLength, buildUploadUrl(alloc, .image, hash[0..31], "", "h.example"));
}

test "parseUploadJson" {
    const alloc = std.testing.allocator;
    var r = try parseUploadJson(alloc, "{\"url\":\"https://mmg.whatsapp.net/v/t2/x?auth=A%3DB&h=abc\",\"direct_path\":\"/v/t2/x?auth=A%3DB&h=abc\",\"handle\":\"H\",\"object_id\":\"O\"}");
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings("https://mmg.whatsapp.net/v/t2/x?auth=A%3DB&h=abc", r.url);
    try std.testing.expectEqualStrings("/v/t2/x?auth=A%3DB&h=abc", r.direct_path);

    var r2 = try parseUploadJson(alloc, "{ \"url\" : \"http:\\/\\/a\\\"b\", \"direct_path\": null }");
    defer r2.deinit(alloc);
    try std.testing.expectEqualStrings("http://a\"b", r2.url);
    try std.testing.expectEqualStrings("", r2.direct_path);

    try std.testing.expectError(error.NoUploadResult, parseUploadJson(alloc, "{\"handle\":\"x\"}"));
    try std.testing.expectError(error.MalformedUploadResponse, parseUploadJson(alloc, "{\"url\":5}"));
    try std.testing.expectError(error.MalformedUploadResponse, parseUploadJson(alloc, "{\"url\":\"oops"));
}

test "parseUploadXml (whatsmeow-era shapes)" {
    const alloc = std.testing.allocator;
    var r = try parseUploadXml(alloc,
        \\ <upload><url>https://mmg.whatsapp.net/v/t2/x?auth=A%3DB&amp;h=abc</url><direct_path>/v/t2/x?auth=A%3DB&amp;h=abc</direct_path></upload>
    );
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings("https://mmg.whatsapp.net/v/t2/x?auth=A%3DB&h=abc", r.url);
    try std.testing.expectEqualStrings("/v/t2/x?auth=A%3DB&h=abc", r.direct_path);

    // attribute form, wrapped, dash key, numeric entities
    var r2 = try parseUploadXml(alloc, "<response><upload url=\"https://x/a?b=1&amp;c=&#50;\" direct-path=\"/v/a?b=1&c=&#x32;\"/></response>");
    defer r2.deinit(alloc);
    try std.testing.expectEqualStrings("https://x/a?b=1&c=2", r2.url);
    try std.testing.expectEqualStrings("/v/a?b=1&c=2", r2.direct_path);

    try std.testing.expectError(error.MalformedUploadResponse, parseUploadXml(alloc, "<foo>bar</foo>"));
    try std.testing.expectError(error.NoUploadResult, parseUploadXml(alloc, "<upload />"));
}

const MockCtx = struct {
    alloc: std.mem.Allocator,
    last_url: []const u8 = "",
    last_body: []const u8 = "",
    resp: []const u8 = "",
};

fn mockGet(ptr: *anyopaque, url: []const u8) anyerror![]const u8 {
    const m: *MockCtx = @ptrCast(@alignCast(ptr));
    if (m.last_url.len != 0) m.alloc.free(m.last_url);
    m.last_url = try m.alloc.dupe(u8, url);
    return m.resp;
}

fn mockPost(ptr: *anyopaque, url: []const u8, body: []const u8) anyerror![]const u8 {
    const m: *MockCtx = @ptrCast(@alignCast(ptr));
    if (m.last_url.len != 0) m.alloc.free(m.last_url);
    m.last_url = try m.alloc.dupe(u8, url);
    if (m.last_body.len != 0) m.alloc.free(m.last_body);
    m.last_body = try m.alloc.dupe(u8, body);
    return m.resp;
}

test "download end-to-end through transport" {
    const alloc = std.testing.allocator;
    const blob = try unhex(alloc, fixtures[0].blobs[0]);
    defer alloc.free(blob);
    var ctx = MockCtx{ .alloc = alloc, .resp = blob };
    defer if (ctx.last_url.len != 0) alloc.free(ctx.last_url);
    const t = Transport{ .ptr = &ctx, .getFn = mockGet, .postFn = mockPost };
    var mk: [32]u8 = undefined;
    @memset(&mk, keyByteFor(.image));
    const got = try download(alloc, .image, &mk, "/v/t2.00271818/x?m=abc", t);
    defer alloc.free(got);
    const want = try unhex(alloc, pt100);
    defer alloc.free(want);
    try std.testing.expectEqualSlices(u8, want, got);
    try std.testing.expectEqualStrings("https://mmg.whatsapp.net/v/t2.00271818/x?m=abc", ctx.last_url);
}

test "upload end-to-end through transport" {
    const alloc = std.testing.allocator;
    var ctx = MockCtx{ .alloc = alloc, .resp = "{\"url\":\"https://mmg.whatsapp.net/u\",\"direct_path\":\"/v/u\"}" };
    defer if (ctx.last_url.len != 0) alloc.free(ctx.last_url);
    defer if (ctx.last_body.len != 0) alloc.free(ctx.last_body);
    const t = Transport{ .ptr = &ctx, .getFn = mockGet, .postFn = mockPost };
    const hash = hx("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    const enc_file = "dummyencryptedblobbytes";
    var r = try upload(alloc, .sticker, enc_file, &hash, t, "AUTH", "rupload.whatsapp.net");
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings(
        "https://rupload.whatsapp.net/mms/image/AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=?auth=AUTH&token=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8%3D",
        ctx.last_url,
    );
    try std.testing.expectEqualStrings(enc_file, ctx.last_body);
    try std.testing.expectEqualStrings("https://mmg.whatsapp.net/u", r.url);
    try std.testing.expectEqualStrings("/v/u", r.direct_path);
}
