const std = @import("std");

/// Port of whatsmeow/store/sqlstore/upgrades/00-latest-schema.sql (v0→v15)
/// Postgres types normalised to SQLite: bytea→BLOB, uuid→TEXT
/// Incremental upgrades 03–15 are folded into this single schema for greenfield DBs.
pub const latest_schema =
    \\CREATE TABLE IF NOT EXISTS whatsmeow_version (version INTEGER PRIMARY KEY);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_device (
    \\  jid TEXT PRIMARY KEY,
    \\  lid TEXT,
    \\  facebook_uuid TEXT,
    \\  registration_id INTEGER NOT NULL CHECK (registration_id >= 0 AND registration_id < 4294967296),
    \\  noise_key    BLOB NOT NULL CHECK (length(noise_key) = 32),
    \\  identity_key BLOB NOT NULL CHECK (length(identity_key) = 32),
    \\  signed_pre_key     BLOB NOT NULL CHECK (length(signed_pre_key) = 32),
    \\  signed_pre_key_id  INTEGER NOT NULL CHECK (signed_pre_key_id >= 0 AND signed_pre_key_id < 16777216),
    \\  signed_pre_key_sig BLOB NOT NULL CHECK (length(signed_pre_key_sig) = 64),
    \\  adv_key             BLOB NOT NULL,
    \\  adv_details         BLOB NOT NULL,
    \\  adv_account_sig     BLOB NOT NULL CHECK (length(adv_account_sig) = 64),
    \\  adv_account_sig_key BLOB NOT NULL CHECK (length(adv_account_sig_key) = 32),
    \\  adv_device_sig      BLOB NOT NULL CHECK (length(adv_device_sig) = 64),
    \\  platform      TEXT NOT NULL DEFAULT '',
    \\  business_name TEXT NOT NULL DEFAULT '',
    \\  push_name     TEXT NOT NULL DEFAULT '',
    \\  lid_migration_ts BIGINT NOT NULL DEFAULT 0,
    \\  companion_meta_nonce TEXT NOT NULL DEFAULT ''
    \\);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_identity_keys (
    \\  our_jid  TEXT, their_id TEXT, identity BLOB NOT NULL CHECK (length(identity)=32),
    \\  PRIMARY KEY (our_jid, their_id),
    \\  FOREIGN KEY (our_jid) REFERENCES whatsmeow_device(jid) ON DELETE CASCADE ON UPDATE CASCADE
    \\);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_pre_keys (
    \\  jid TEXT, key_id INTEGER CHECK (key_id>=0 AND key_id<16777216), key BLOB NOT NULL CHECK(length(key)=32), pub BLOB NOT NULL CHECK(length(pub)=32), uploaded INTEGER NOT NULL,
    \\  PRIMARY KEY (jid, key_id), FOREIGN KEY (jid) REFERENCES whatsmeow_device(jid) ON DELETE CASCADE ON UPDATE CASCADE
    \\);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_sessions (
    \\  our_jid TEXT, their_id TEXT, session BLOB,
    \\  PRIMARY KEY (our_jid, their_id), FOREIGN KEY (our_jid) REFERENCES whatsmeow_device(jid) ON DELETE CASCADE ON UPDATE CASCADE
    \\);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_sender_keys (
    \\  our_jid TEXT, chat_id TEXT, sender_id TEXT, sender_key BLOB NOT NULL,
    \\  PRIMARY KEY (our_jid, chat_id, sender_id), FOREIGN KEY (our_jid) REFERENCES whatsmeow_device(jid) ON DELETE CASCADE ON UPDATE CASCADE
    \\);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_app_state_sync_keys (
    \\  jid TEXT, key_id BLOB, key_data BLOB NOT NULL, timestamp INTEGER NOT NULL, fingerprint BLOB NOT NULL,
    \\  PRIMARY KEY (jid, key_id), FOREIGN KEY (jid) REFERENCES whatsmeow_device(jid) ON DELETE CASCADE ON UPDATE CASCADE
    \\);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_app_state_version (
    \\  jid TEXT, name TEXT, version INTEGER NOT NULL, hash BLOB NOT NULL CHECK(length(hash)=128),
    \\  PRIMARY KEY (jid, name), FOREIGN KEY (jid) REFERENCES whatsmeow_device(jid) ON DELETE CASCADE ON UPDATE CASCADE
    \\);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_app_state_mutation_macs (
    \\  jid TEXT, name TEXT, version INTEGER, index_mac BLOB CHECK(length(index_mac)=32), value_mac BLOB NOT NULL CHECK(length(value_mac)=32),
    \\  PRIMARY KEY (jid, name, version, index_mac), FOREIGN KEY (jid, name) REFERENCES whatsmeow_app_state_version(jid, name) ON DELETE CASCADE ON UPDATE CASCADE
    \\);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_contacts (
    \\  our_jid TEXT, their_jid TEXT, first_name TEXT, full_name TEXT, push_name TEXT, business_name TEXT, redacted_phone TEXT,
    \\  PRIMARY KEY (our_jid, their_jid), FOREIGN KEY (our_jid) REFERENCES whatsmeow_device(jid) ON DELETE CASCADE ON UPDATE CASCADE
    \\);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_chat_settings (
    \\  our_jid TEXT, chat_jid TEXT, muted_until INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (our_jid, chat_jid), FOREIGN KEY (our_jid) REFERENCES whatsmeow_device(jid) ON DELETE CASCADE ON UPDATE CASCADE
    \\);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_message_secrets (
    \\  our_jid TEXT, chat_jid TEXT, sender_jid TEXT, message_id TEXT, key BLOB NOT NULL,
    \\  PRIMARY KEY (our_jid, chat_jid, sender_jid, message_id), FOREIGN KEY (our_jid) REFERENCES whatsmeow_device(jid) ON DELETE CASCADE ON UPDATE CASCADE
    \\);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_privacy_tokens (
    \\  our_jid TEXT, their_jid TEXT, token BLOB NOT NULL, timestamp INTEGER NOT NULL, sender_timestamp INTEGER,
    \\  PRIMARY KEY (our_jid, their_jid)
    \\);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_nct_salt (our_jid TEXT PRIMARY KEY, salt BLOB NOT NULL, FOREIGN KEY (our_jid) REFERENCES whatsmeow_device(jid) ON DELETE CASCADE ON UPDATE CASCADE);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_lid_map (lid TEXT PRIMARY KEY, pn TEXT UNIQUE NOT NULL);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_event_buffer (
    \\  our_jid TEXT NOT NULL, ciphertext_hash BLOB NOT NULL CHECK(length(ciphertext_hash)=32), plaintext BLOB, server_timestamp INTEGER NOT NULL, insert_timestamp INTEGER NOT NULL,
    \\  PRIMARY KEY (our_jid, ciphertext_hash), FOREIGN KEY (our_jid) REFERENCES whatsmeow_device(jid) ON DELETE CASCADE ON UPDATE CASCADE
    \\);
    \\CREATE TABLE IF NOT EXISTS whatsmeow_retry_buffer (
    \\  our_jid TEXT NOT NULL, chat_jid TEXT NOT NULL, message_id TEXT NOT NULL, format TEXT NOT NULL, plaintext BLOB NOT NULL, timestamp INTEGER NOT NULL,
    \\  PRIMARY KEY (our_jid, chat_jid, message_id), FOREIGN KEY (our_jid) REFERENCES whatsmeow_device(jid) ON DELETE CASCADE ON UPDATE CASCADE
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_whatsmeow_privacy_tokens_our_jid_timestamp ON whatsmeow_privacy_tokens (our_jid, timestamp);
    \\CREATE INDEX IF NOT EXISTS whatsmeow_retry_buffer_timestamp_idx ON whatsmeow_retry_buffer (our_jid, timestamp);
;

pub const pragmatic_pragmas = [_][]const u8{
    "PRAGMA foreign_keys=ON",
    "PRAGMA journal_mode=WAL",
    "PRAGMA synchronous=NORMAL",
};

test "schema contains 18 tables" {
    try std.testing.expect(std.mem.indexOf(u8, latest_schema, "whatsmeow_device") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest_schema, "whatsmeow_lid_map") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest_schema, "whatsmeow_event_buffer") != null);
}
