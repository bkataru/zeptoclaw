//! SQLite container for whatsmeow-compatible tables (device, sessions, lid_map).
//!
//! Uses `@cImport` of vendored `sqlite3.h`. Parent must wire amalgamation in
//! `build.zig` on the zeptoclaw module (`mod`) — same flags on every root that
//! imports this file (exe + `addTest`):
//!
//! ```zig
//! // vendor/sqlite amalgamation (no system sqlite3.h on this host)
//! mod.addIncludePath(b.path("vendor/sqlite"));
//! mod.addCSourceFile(.{
//!     .file = b.path("vendor/sqlite/sqlite3.c"),
//!     .flags = &.{
//!         "-DSQLITE_OMIT_LOAD_EXTENSION",
//!         "-DSQLITE_THREADSAFE=1",
//!         "-DSQLITE_DEFAULT_MEMSTATUS=0",
//!         "-DSQLITE_DQS=0",
//!     },
//! });
//! mod.link_libc = true;
//! ```
//!
//! Zig 0.16 optional translate-c (if in-file `@cImport` is retired):
//! `b.addTranslateC(.{ .root_source_file = b.path("vendor/sqlite/sqlite3.h"), ... })`
//! then `mod.addImport("sqlite3", sqlite_c.createModule())`.

const std = @import("std");
const schema = @import("schema.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    InvalidLength,
    DeviceIdMustBeSet,
    NotOpen,
    OutOfMemory,
};

fn sqliteStatic() c.sqlite3_destructor_type {
    return null;
}

pub const PreKeyRecord = struct {
    id: u32,
    priv_key: [32]u8,
    pub_key: [32]u8,
    uploaded: bool,
};

/// Row matching `whatsmeow_device`. Identity / noise / adv keys are 32 bytes;
/// signed-pre-key signature is 64 bytes (schema CHECKs).
pub const Device = struct {
    allocator: std.mem.Allocator,
    /// When true, string/blob slices are owned by `allocator` and `deinit` frees them.
    owned: bool = false,
    jid: []const u8 = "",
    lid: ?[]const u8 = null,
    facebook_uuid: ?[]const u8 = null,
    registration_id: u32 = 0,
    noise_key: [32]u8 = [_]u8{0} ** 32,
    identity_key: [32]u8 = [_]u8{0} ** 32,
    signed_pre_key: [32]u8 = [_]u8{0} ** 32,
    signed_pre_key_id: u32 = 1,
    signed_pre_key_sig: [64]u8 = [_]u8{0} ** 64,
    adv_key: [32]u8 = [_]u8{0} ** 32,
    adv_details: []const u8 = "",
    adv_account_sig: [64]u8 = [_]u8{0} ** 64,
    adv_account_sig_key: [32]u8 = [_]u8{0} ** 32,
    adv_device_sig: [64]u8 = [_]u8{0} ** 64,
    platform: []const u8 = "",
    business_name: []const u8 = "",
    push_name: []const u8 = "",
    lid_migration_ts: i64 = 0,
    companion_meta_nonce: []const u8 = "",

    pub fn deinit(self: *Device) void {
        if (!self.owned) return;
        self.allocator.free(self.jid);
        if (self.lid) |s| self.allocator.free(s);
        if (self.facebook_uuid) |s| self.allocator.free(s);
        self.allocator.free(self.adv_details);
        self.allocator.free(self.platform);
        self.allocator.free(self.business_name);
        self.allocator.free(self.push_name);
        self.allocator.free(self.companion_meta_nonce);
        self.owned = false;
        self.jid = "";
        self.lid = null;
        self.facebook_uuid = null;
        self.adv_details = "";
        self.platform = "";
        self.business_name = "";
        self.push_name = "";
        self.companion_meta_nonce = "";
    }
};

pub const Container = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    path: []const u8,

    /// Memory: caller owns the Container (duped `path` + sqlite handle); call `deinit`.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) Error!Container {
        const path_z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
        defer allocator.free(path_z);

        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path_z.ptr, &db);
        if (rc != c.SQLITE_OK or db == null) {
            if (db) |handle| _ = c.sqlite3_close(handle);
            return error.OpenFailed;
        }
        const handle = db.?;
        errdefer _ = c.sqlite3_close(handle);

        _ = c.sqlite3_busy_timeout(handle, 5000);
        _ = c.sqlite3_extended_result_codes(handle, 1);

        var self = Container{
            .allocator = allocator,
            .db = handle,
            .path = allocator.dupe(u8, path) catch return error.OutOfMemory,
        };
        errdefer allocator.free(self.path);

        for (schema.pragmatic_pragmas) |pragma| {
            try self.exec(pragma);
        }
        try self.exec(schema.latest_schema);
        return self;
    }

    /// Flush WAL into the main db so a kill/restart still sees the device row.
    /// `:memory:` and non-WAL opens are a no-op.
    pub fn checkpoint(self: *Container) void {
        self.exec("PRAGMA wal_checkpoint(TRUNCATE)") catch {};
    }

    pub fn deinit(self: *Container) void {
        self.checkpoint();
        _ = c.sqlite3_close(self.db);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn putDevice(self: *Container, dev: Device) Error!void {
        if (dev.jid.len == 0) return error.DeviceIdMustBeSet;
        const stmt = try self.prepare(sql_put_device);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, dev.jid);
        try bindTextOpt(stmt, 2, dev.lid);
        try bindTextOpt(stmt, 3, dev.facebook_uuid);
        try bindI64(stmt, 4, @as(i64, dev.registration_id));
        try bindBlob(stmt, 5, &dev.noise_key);
        try bindBlob(stmt, 6, &dev.identity_key);
        try bindBlob(stmt, 7, &dev.signed_pre_key);
        try bindI64(stmt, 8, @as(i64, dev.signed_pre_key_id));
        try bindBlob(stmt, 9, &dev.signed_pre_key_sig);
        try bindBlob(stmt, 10, &dev.adv_key);
        try bindBlob(stmt, 11, dev.adv_details);
        try bindBlob(stmt, 12, &dev.adv_account_sig);
        try bindBlob(stmt, 13, &dev.adv_account_sig_key);
        try bindBlob(stmt, 14, &dev.adv_device_sig);
        try bindText(stmt, 15, dev.platform);
        try bindText(stmt, 16, dev.business_name);
        try bindText(stmt, 17, dev.push_name);
        try bindI64(stmt, 18, dev.lid_migration_ts);
        try bindText(stmt, 19, dev.companion_meta_nonce);
        try stepDone(self.db, stmt);
    }

    /// Memory: on success, caller owns the Device; call `Device.deinit`.
    pub fn getDevice(self: *Container, jid: []const u8) Error!?Device {
        const stmt = try self.prepare(sql_get_device);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, jid);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        return try scanDevice(self.allocator, stmt);
    }

    /// Memory: on success, caller owns the Device; call `Device.deinit`.
    pub fn getAnyDevice(self: *Container) Error!?Device {
        const stmt = try self.prepare(sql_any_device);
        defer _ = c.sqlite3_finalize(stmt);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        return try scanDevice(self.allocator, stmt);
    }

    pub fn putIdentity(self: *Container, our_jid: []const u8, their_id: []const u8, identity: [32]u8) Error!void {
        const stmt = try self.prepare(sql_put_identity);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, our_jid);
        try bindText(stmt, 2, their_id);
        try bindBlob(stmt, 3, &identity);
        try stepDone(self.db, stmt);
    }

    pub fn getIdentity(self: *Container, our_jid: []const u8, their_id: []const u8) Error!?[32]u8 {
        const stmt = try self.prepare(sql_get_identity);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, our_jid);
        try bindText(stmt, 2, their_id);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        return try columnArray(stmt, 0, 32);
    }

    pub fn putSession(self: *Container, our_jid: []const u8, their_id: []const u8, session: []const u8) Error!void {
        const stmt = try self.prepare(sql_put_session);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, our_jid);
        try bindText(stmt, 2, their_id);
        try bindBlob(stmt, 3, session);
        try stepDone(self.db, stmt);
    }

    /// Memory: caller frees the returned slice with `allocator.free`.
    pub fn getSession(self: *Container, our_jid: []const u8, their_id: []const u8) Error!?[]u8 {
        const stmt = try self.prepare(sql_get_session);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, our_jid);
        try bindText(stmt, 2, their_id);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) {
            return self.allocator.dupe(u8, "") catch return error.OutOfMemory;
        }
        return try columnBlobDupe(self.allocator, stmt, 0);
    }

    pub fn deleteSession(self: *Container, our_jid: []const u8, their_id: []const u8) Error!void {
        const stmt = try self.prepare(sql_delete_session);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, our_jid);
        try bindText(stmt, 2, their_id);
        try stepDone(self.db, stmt);
    }
    /// Delete a device row; FK cascade drops its sessions/keys. Checkpoint so
    /// a kill/restart can't resurrect the dead device via getAnyDevice.
    pub fn deleteDevice(self: *Container, jid: []const u8) Error!void {
        const stmt = try self.prepare(sql_delete_device);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, jid);
        try stepDone(self.db, stmt);
        self.checkpoint();
    }

    pub fn putSenderKey(self: *Container, our_jid: []const u8, chat_id: []const u8, sender_id: []const u8, record: []const u8) Error!void {
        const stmt = try self.prepare(sql_put_sender_key);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, our_jid);
        try bindText(stmt, 2, chat_id);
        try bindText(stmt, 3, sender_id);
        try bindBlob(stmt, 4, record);
        try stepDone(self.db, stmt);
    }

    /// Memory: caller frees the returned slice with `allocator.free`.
    pub fn getSenderKey(self: *Container, our_jid: []const u8, chat_id: []const u8, sender_id: []const u8) Error!?[]u8 {
        const stmt = try self.prepare(sql_get_sender_key);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, our_jid);
        try bindText(stmt, 2, chat_id);
        try bindText(stmt, 3, sender_id);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        return try columnBlobDupe(self.allocator, stmt, 0);
    }

    pub fn deleteSenderKey(self: *Container, our_jid: []const u8, chat_id: []const u8, sender_id: []const u8) Error!void {
        const stmt = try self.prepare(sql_delete_sender_key);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, our_jid);
        try bindText(stmt, 2, chat_id);
        try bindText(stmt, 3, sender_id);
        try stepDone(self.db, stmt);
    }

    pub fn putLidMap(self: *Container, lid: []const u8, pn: []const u8) Error!void {
        {
            const del = try self.prepare(sql_delete_lid_by_pn);
            defer _ = c.sqlite3_finalize(del);
            try bindText(del, 1, lid);
            try bindText(del, 2, pn);
            try stepDone(self.db, del);
        }
        const stmt = try self.prepare(sql_put_lid);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, lid);
        try bindText(stmt, 2, pn);
        try stepDone(self.db, stmt);
    }

    /// Memory: caller frees the returned slice with `allocator.free`.
    pub fn getPnForLid(self: *Container, lid: []const u8) Error!?[]u8 {
        return self.queryOneText(sql_pn_for_lid, lid);
    }

    /// Memory: caller frees the returned slice with `allocator.free`.
    pub fn getLidForPn(self: *Container, pn: []const u8) Error!?[]u8 {
        return self.queryOneText(sql_lid_for_pn, pn);
    }

    pub fn putPreKeys(self: *Container, our_jid: []const u8, recs: []const PreKeyRecord) Error!void {
        for (recs) |rec| {
            const stmt = try self.prepare(sql_put_prekey);
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, our_jid);
            try bindI64(stmt, 2, @as(i64, rec.id));
            try bindBlob(stmt, 3, &rec.priv_key);
            try bindBlob(stmt, 4, &rec.pub_key);
            try bindI64(stmt, 5, if (rec.uploaded) 1 else 0);
            try stepDone(self.db, stmt);
        }
    }

    pub fn getPreKey(self: *Container, our_jid: []const u8, id: u32) Error!?PreKeyRecord {
        const stmt = try self.prepare(sql_get_prekey);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, our_jid);
        try bindI64(stmt, 2, @as(i64, id));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        return try scanPreKey(stmt);
    }

    pub fn removePreKey(self: *Container, our_jid: []const u8, id: u32) Error!void {
        const stmt = try self.prepare(sql_delete_prekey);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, our_jid);
        try bindI64(stmt, 2, @as(i64, id));
        try stepDone(self.db, stmt);
    }

    /// Memory: caller frees the returned slice with `allocator.free`.
    pub fn getUnuploadedPreKeys(self: *Container, allocator: std.mem.Allocator, our_jid: []const u8, limit: usize) Error![]PreKeyRecord {
        const stmt = try self.prepare(sql_unuploaded_prekeys);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, our_jid);
        try bindI64(stmt, 2, @as(i64, @intCast(limit)));
        var list: std.ArrayList(PreKeyRecord) = .empty;
        errdefer list.deinit(allocator);
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.StepFailed;
            try list.append(allocator, try scanPreKey(stmt));
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn markPreKeysUploaded(self: *Container, our_jid: []const u8, up_to_id: u32) Error!void {
        const stmt = try self.prepare(sql_mark_prekeys);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, our_jid);
        try bindI64(stmt, 2, @as(i64, up_to_id));
        try stepDone(self.db, stmt);
    }

    pub fn countPreKeys(self: *Container, our_jid: []const u8) Error!u32 {
        const stmt = try self.prepare(sql_count_prekeys);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, our_jid);
        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        const n = c.sqlite3_column_int64(stmt, 0);
        if (n < 0 or n > std.math.maxInt(u32)) return error.InvalidLength;
        return @intCast(n);
    }

    pub fn nextPreKeyId(self: *Container, our_jid: []const u8) Error!u32 {
        const stmt = try self.prepare(sql_max_prekey);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, our_jid);
        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) return 1;
        const max_id = c.sqlite3_column_int64(stmt, 0);
        if (max_id < 0) return 1;
        const next = max_id + 1;
        if (next < 0 or next > std.math.maxInt(u32)) return error.InvalidLength;
        return @intCast(next);
    }

    fn queryOneText(self: *Container, sql: [:0]const u8, arg: []const u8) Error!?[]u8 {
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, arg);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        return try columnTextDupe(self.allocator, stmt, 0);
    }

    fn exec(self: *Container, sql: []const u8) Error!void {
        const z = self.allocator.dupeZ(u8, sql) catch return error.OutOfMemory;
        defer self.allocator.free(z);
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, z.ptr, null, null, &errmsg);
        defer if (errmsg != null) c.sqlite3_free(errmsg);
        if (rc != c.SQLITE_OK) return error.ExecFailed;
    }

    fn prepare(self: *Container, sql: [:0]const u8) Error!*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return error.PrepareFailed;
        return stmt.?;
    }
};

const sql_put_device: [:0]const u8 =
    \\INSERT INTO whatsmeow_device (
    \\  jid, lid, facebook_uuid, registration_id,
    \\  noise_key, identity_key, signed_pre_key, signed_pre_key_id, signed_pre_key_sig,
    \\  adv_key, adv_details, adv_account_sig, adv_account_sig_key, adv_device_sig,
    \\  platform, business_name, push_name, lid_migration_ts, companion_meta_nonce
    \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
    \\ON CONFLICT (jid) DO UPDATE SET
    \\  lid=excluded.lid,
    \\  facebook_uuid=excluded.facebook_uuid,
    \\  registration_id=excluded.registration_id,
    \\  noise_key=excluded.noise_key,
    \\  identity_key=excluded.identity_key,
    \\  signed_pre_key=excluded.signed_pre_key,
    \\  signed_pre_key_id=excluded.signed_pre_key_id,
    \\  signed_pre_key_sig=excluded.signed_pre_key_sig,
    \\  adv_key=excluded.adv_key,
    \\  adv_details=excluded.adv_details,
    \\  adv_account_sig=excluded.adv_account_sig,
    \\  adv_account_sig_key=excluded.adv_account_sig_key,
    \\  adv_device_sig=excluded.adv_device_sig,
    \\  platform=excluded.platform,
    \\  business_name=excluded.business_name,
    \\  push_name=excluded.push_name,
    \\  lid_migration_ts=excluded.lid_migration_ts,
    \\  companion_meta_nonce=excluded.companion_meta_nonce
;

const sql_get_device: [:0]const u8 =
    \\SELECT jid, lid, facebook_uuid, registration_id,
    \\  noise_key, identity_key, signed_pre_key, signed_pre_key_id, signed_pre_key_sig,
    \\  adv_key, adv_details, adv_account_sig, adv_account_sig_key, adv_device_sig,
    \\  platform, business_name, push_name, lid_migration_ts, companion_meta_nonce
    \\FROM whatsmeow_device WHERE jid=?1
;

const sql_any_device: [:0]const u8 =
    \\SELECT jid, lid, facebook_uuid, registration_id,
    \\  noise_key, identity_key, signed_pre_key, signed_pre_key_id, signed_pre_key_sig,
    \\  adv_key, adv_details, adv_account_sig, adv_account_sig_key, adv_device_sig,
    \\  platform, business_name, push_name, lid_migration_ts, companion_meta_nonce
    \\FROM whatsmeow_device LIMIT 1
;

const sql_put_identity: [:0]const u8 =
    \\INSERT INTO whatsmeow_identity_keys (our_jid, their_id, identity) VALUES (?1, ?2, ?3)
    \\ON CONFLICT (our_jid, their_id) DO UPDATE SET identity=excluded.identity
;

const sql_get_identity: [:0]const u8 =
    \\SELECT identity FROM whatsmeow_identity_keys WHERE our_jid=?1 AND their_id=?2
;

const sql_put_session: [:0]const u8 =
    \\INSERT INTO whatsmeow_sessions (our_jid, their_id, session) VALUES (?1, ?2, ?3)
    \\ON CONFLICT (our_jid, their_id) DO UPDATE SET session=excluded.session
;

const sql_get_session: [:0]const u8 =
    \\SELECT session FROM whatsmeow_sessions WHERE our_jid=?1 AND their_id=?2
;

const sql_delete_session: [:0]const u8 =
    \\DELETE FROM whatsmeow_sessions WHERE our_jid=?1 AND their_id=?2
;
const sql_delete_device: [:0]const u8 =
    \\DELETE FROM whatsmeow_device WHERE jid=?1
;
const sql_put_sender_key: [:0]const u8 =
    \\INSERT INTO whatsmeow_sender_keys (our_jid, chat_id, sender_id, sender_key) VALUES (?1, ?2, ?3, ?4)
    \\ON CONFLICT (our_jid, chat_id, sender_id) DO UPDATE SET sender_key=excluded.sender_key
;

const sql_get_sender_key: [:0]const u8 =
    \\SELECT sender_key FROM whatsmeow_sender_keys WHERE our_jid=?1 AND chat_id=?2 AND sender_id=?3
;

const sql_delete_sender_key: [:0]const u8 =
    \\DELETE FROM whatsmeow_sender_keys WHERE our_jid=?1 AND chat_id=?2 AND sender_id=?3
;

const sql_delete_lid_by_pn: [:0]const u8 =
    \\DELETE FROM whatsmeow_lid_map WHERE (lid<>?1 AND pn=?2)
;

const sql_put_lid: [:0]const u8 =
    \\INSERT INTO whatsmeow_lid_map (lid, pn) VALUES (?1, ?2)
    \\ON CONFLICT (lid) DO UPDATE SET pn=excluded.pn WHERE whatsmeow_lid_map.pn<>excluded.pn
;

const sql_pn_for_lid: [:0]const u8 = "SELECT pn FROM whatsmeow_lid_map WHERE lid=?1";
const sql_lid_for_pn: [:0]const u8 = "SELECT lid FROM whatsmeow_lid_map WHERE pn=?1";

const sql_put_prekey: [:0]const u8 =
    \\INSERT INTO whatsmeow_pre_keys (jid, key_id, key, pub, uploaded) VALUES (?1, ?2, ?3, ?4, ?5)
    \\ON CONFLICT (jid, key_id) DO UPDATE SET key=excluded.key, pub=excluded.pub, uploaded=excluded.uploaded
;
const sql_get_prekey: [:0]const u8 =
    \\SELECT key_id, key, pub, uploaded FROM whatsmeow_pre_keys WHERE jid=?1 AND key_id=?2
;
const sql_delete_prekey: [:0]const u8 =
    \\DELETE FROM whatsmeow_pre_keys WHERE jid=?1 AND key_id=?2
;
const sql_unuploaded_prekeys: [:0]const u8 =
    \\SELECT key_id, key, pub, uploaded FROM whatsmeow_pre_keys WHERE jid=?1 AND uploaded=0 ORDER BY key_id LIMIT ?2
;
const sql_mark_prekeys: [:0]const u8 =
    \\UPDATE whatsmeow_pre_keys SET uploaded=1 WHERE jid=?1 AND key_id<=?2
;
const sql_count_prekeys: [:0]const u8 =
    \\SELECT COUNT(*) FROM whatsmeow_pre_keys WHERE jid=?1
;
const sql_max_prekey: [:0]const u8 =
    \\SELECT MAX(key_id) FROM whatsmeow_pre_keys WHERE jid=?1
;

fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, s: []const u8) Error!void {
    const rc = c.sqlite3_bind_text(stmt, idx, if (s.len == 0) "" else s.ptr, @intCast(s.len), sqliteStatic());
    if (rc != c.SQLITE_OK) return error.BindFailed;
}

fn bindTextOpt(stmt: *c.sqlite3_stmt, idx: c_int, s: ?[]const u8) Error!void {
    if (s) |v| return bindText(stmt, idx, v);
    if (c.sqlite3_bind_null(stmt, idx) != c.SQLITE_OK) return error.BindFailed;
}

fn bindBlob(stmt: *c.sqlite3_stmt, idx: c_int, bytes: []const u8) Error!void {
    // A null pointer is SQL NULL (NOT NULL fail). Empty blob needs a non-null ptr + n=0.
    const empty: [1]u8 = .{0};
    const ptr: *const anyopaque = if (bytes.len == 0) &empty else bytes.ptr;
    const rc = c.sqlite3_bind_blob(stmt, idx, ptr, @intCast(bytes.len), sqliteStatic());
    if (rc != c.SQLITE_OK) return error.BindFailed;
}

fn bindI64(stmt: *c.sqlite3_stmt, idx: c_int, value: i64) Error!void {
    if (c.sqlite3_bind_int64(stmt, idx, value) != c.SQLITE_OK) return error.BindFailed;
}

fn stepDone(db: *c.sqlite3, stmt: *c.sqlite3_stmt) Error!void {
    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) {
        _ = c.sqlite3_errcode(db);
        return error.StepFailed;
    }
}

fn columnTextDupe(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, col: c_int) Error![]u8 {
    const ptr = c.sqlite3_column_text(stmt, col);
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (ptr == null or n == 0) return allocator.dupe(u8, "") catch return error.OutOfMemory;
    const bytes: [*]const u8 = @ptrCast(ptr);
    return allocator.dupe(u8, bytes[0..n]) catch return error.OutOfMemory;
}

fn columnTextOpt(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, col: c_int) Error!?[]u8 {
    if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
    return try columnTextDupe(allocator, stmt, col);
}

fn columnBlobDupe(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, col: c_int) Error![]u8 {
    const ptr = c.sqlite3_column_blob(stmt, col);
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (ptr == null or n == 0) return allocator.dupe(u8, "") catch return error.OutOfMemory;
    const bytes: [*]const u8 = @ptrCast(ptr);
    return allocator.dupe(u8, bytes[0..n]) catch return error.OutOfMemory;
}

fn columnArray(stmt: *c.sqlite3_stmt, col: c_int, comptime N: usize) Error![N]u8 {
    const ptr = c.sqlite3_column_blob(stmt, col);
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (ptr == null or n != N) return error.InvalidLength;
    var out: [N]u8 = undefined;
    const bytes: [*]const u8 = @ptrCast(ptr);
    @memcpy(&out, bytes[0..N]);
    return out;
}

fn scanDevice(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) Error!Device {
    var dev = Device{ .allocator = allocator, .owned = true };
    errdefer dev.deinit();
    dev.jid = try columnTextDupe(allocator, stmt, 0);
    dev.lid = try columnTextOpt(allocator, stmt, 1);
    dev.facebook_uuid = try columnTextOpt(allocator, stmt, 2);
    const rid = c.sqlite3_column_int64(stmt, 3);
    if (rid < 0 or rid > std.math.maxInt(u32)) return error.InvalidLength;
    dev.registration_id = @intCast(rid);
    dev.noise_key = try columnArray(stmt, 4, 32);
    dev.identity_key = try columnArray(stmt, 5, 32);
    dev.signed_pre_key = try columnArray(stmt, 6, 32);
    const spk_id = c.sqlite3_column_int64(stmt, 7);
    if (spk_id < 0 or spk_id > 16777215) return error.InvalidLength;
    dev.signed_pre_key_id = @intCast(spk_id);
    dev.signed_pre_key_sig = try columnArray(stmt, 8, 64);
    dev.adv_key = try columnArray(stmt, 9, 32);
    dev.adv_details = try columnBlobDupe(allocator, stmt, 10);
    dev.adv_account_sig = try columnArray(stmt, 11, 64);
    dev.adv_account_sig_key = try columnArray(stmt, 12, 32);
    dev.adv_device_sig = try columnArray(stmt, 13, 64);
    dev.platform = try columnTextDupe(allocator, stmt, 14);
    dev.business_name = try columnTextDupe(allocator, stmt, 15);
    dev.push_name = try columnTextDupe(allocator, stmt, 16);
    dev.lid_migration_ts = c.sqlite3_column_int64(stmt, 17);
    dev.companion_meta_nonce = try columnTextDupe(allocator, stmt, 18);
    return dev;
}

fn scanPreKey(stmt: *c.sqlite3_stmt) Error!PreKeyRecord {
    const id64 = c.sqlite3_column_int64(stmt, 0);
    if (id64 < 0 or id64 > std.math.maxInt(u32)) return error.InvalidLength;
    return .{
        .id = @intCast(id64),
        .priv_key = try columnArray(stmt, 1, 32),
        .pub_key = try columnArray(stmt, 2, 32),
        .uploaded = c.sqlite3_column_int64(stmt, 3) != 0,
    };
}

fn fillByte(comptime N: usize, value: u8) [N]u8 {
    var out: [N]u8 = undefined;
    @memset(&out, value);
    return out;
}

test "sqlite in-memory put/get device" {
    const alloc = std.testing.allocator;
    var store = try Container.open(alloc, ":memory:");
    defer store.deinit();

    try std.testing.expectEqualStrings(":memory:", store.path);

    var noise = fillByte(32, 0x11);
    var ident = fillByte(32, 0x22);
    var spk = fillByte(32, 0x33);
    var sig = fillByte(64, 0x44);
    var adv = fillByte(32, 0x55);
    noise[0] = 0xA1;
    ident[31] = 0xB2;
    spk[15] = 0xC3;

    const put = Device{
        .allocator = alloc,
        .jid = "1234567890:0@s.whatsapp.net",
        .lid = "216638251077681@lid",
        .registration_id = 42,
        .noise_key = noise,
        .identity_key = ident,
        .signed_pre_key = spk,
        .signed_pre_key_id = 1,
        .signed_pre_key_sig = sig,
        .adv_key = adv,
        .push_name = "barvis",
    };
    try store.putDevice(put);

    var got = (try store.getDevice(put.jid)) orelse return error.TestUnexpectedResult;
    defer got.deinit();
    try std.testing.expect(got.owned);
    try std.testing.expectEqualStrings(put.jid, got.jid);
    try std.testing.expectEqualStrings(put.lid.?, got.lid.?);
    try std.testing.expectEqual(@as(u32, 42), got.registration_id);
    try std.testing.expectEqualSlices(u8, &noise, &got.noise_key);
    try std.testing.expectEqualSlices(u8, &ident, &got.identity_key);
    try std.testing.expectEqualSlices(u8, &spk, &got.signed_pre_key);
    try std.testing.expectEqualSlices(u8, &sig, &got.signed_pre_key_sig);
    try std.testing.expectEqualSlices(u8, &adv, &got.adv_key);
    try std.testing.expectEqual(@as(usize, 32), got.noise_key.len);
    try std.testing.expectEqual(@as(usize, 32), got.identity_key.len);
    try std.testing.expectEqual(@as(usize, 32), got.signed_pre_key.len);
    try std.testing.expectEqual(@as(usize, 32), got.adv_key.len);
    try std.testing.expectEqualStrings("barvis", got.push_name);
    try std.testing.expect((try store.getDevice("missing@s.whatsapp.net")) == null);
}

test "sqlite session roundtrip" {
    const alloc = std.testing.allocator;
    var store = try Container.open(alloc, ":memory:");
    defer store.deinit();

    const our = "1234567890:0@s.whatsapp.net";
    const their = "216638251077681.0";
    const put_dev = Device{
        .allocator = alloc,
        .jid = our,
        .registration_id = 1,
        .noise_key = fillByte(32, 1),
        .identity_key = fillByte(32, 2),
        .signed_pre_key = fillByte(32, 3),
        .signed_pre_key_sig = fillByte(64, 4),
        .adv_key = fillByte(32, 5),
    };
    try store.putDevice(put_dev);

    const blob = "signal-session-bytes";
    try store.putSession(our, their, blob);
    const got = (try store.getSession(our, their)) orelse return error.TestUnexpectedResult;
    defer alloc.free(got);
    try std.testing.expectEqualStrings(blob, got);

    try store.putSession(our, their, "rewritten");
    const got2 = (try store.getSession(our, their)) orelse return error.TestUnexpectedResult;
    defer alloc.free(got2);
    try std.testing.expectEqualStrings("rewritten", got2);

    try store.deleteSession(our, their);
    try std.testing.expect((try store.getSession(our, their)) == null);
}

test "sqlite lid map" {
    const alloc = std.testing.allocator;
    var store = try Container.open(alloc, ":memory:");
    defer store.deinit();

    try store.putLidMap("216638251077681", "917019895010");
    const pn = (try store.getPnForLid("216638251077681")) orelse return error.TestUnexpectedResult;
    defer alloc.free(pn);
    try std.testing.expectEqualStrings("917019895010", pn);
    const lid = (try store.getLidForPn("917019895010")) orelse return error.TestUnexpectedResult;
    defer alloc.free(lid);
    try std.testing.expectEqualStrings("216638251077681", lid);

    try store.putLidMap("999", "917019895010");
    const lid2 = (try store.getLidForPn("917019895010")) orelse return error.TestUnexpectedResult;
    defer alloc.free(lid2);
    try std.testing.expectEqualStrings("999", lid2);
    try std.testing.expect((try store.getPnForLid("216638251077681")) == null);
}

test "sqlite getAnyDevice and identity keys" {
    const alloc = std.testing.allocator;
    var store = try Container.open(alloc, ":memory:");
    defer store.deinit();
    const jid = "1:0@s.whatsapp.net";
    try store.putDevice(.{
        .allocator = alloc,
        .jid = jid,
        .registration_id = 9,
        .noise_key = fillByte(32, 1),
        .identity_key = fillByte(32, 2),
        .signed_pre_key = fillByte(32, 3),
        .signed_pre_key_sig = fillByte(64, 4),
        .adv_key = fillByte(32, 5),
    });
    var any = (try store.getAnyDevice()) orelse return error.TestUnexpectedResult;
    defer any.deinit();
    try std.testing.expectEqualStrings(jid, any.jid);
    const ident = fillByte(32, 0xAB);
    try store.putIdentity(jid, "1555.0", ident);
    const got = (try store.getIdentity(jid, "1555.0")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &ident, &got);
}

fn dummyDevice(alloc: std.mem.Allocator, jid: []const u8) Device {
    return .{
        .allocator = alloc,
        .jid = jid,
        .registration_id = 1,
        .noise_key = fillByte(32, 1),
        .identity_key = fillByte(32, 2),
        .signed_pre_key = fillByte(32, 3),
        .signed_pre_key_sig = fillByte(64, 4),
        .adv_key = fillByte(32, 5),
    };
}

test "sqlite prekeys put count unuploaded mark get remove next" {
    const alloc = std.testing.allocator;
    var store = try Container.open(alloc, ":memory:");
    defer store.deinit();
    const jid = "me@s.whatsapp.net";
    try store.putDevice(dummyDevice(alloc, jid));

    try std.testing.expectEqual(@as(u32, 1), try store.nextPreKeyId(jid));

    var recs: [30]PreKeyRecord = undefined;
    for (&recs, 0..) |*rec, i| {
        var priv = fillByte(32, @intCast(i + 1));
        var pubk = fillByte(32, @intCast(i + 50));
        priv[0] = @intCast(i);
        pubk[0] = @intCast(100 + i);
        rec.* = .{
            .id = @intCast(i + 1),
            .priv_key = priv,
            .pub_key = pubk,
            .uploaded = false,
        };
    }
    try store.putPreKeys(jid, &recs);
    try std.testing.expectEqual(@as(u32, 30), try store.countPreKeys(jid));

    const unup = try store.getUnuploadedPreKeys(alloc, jid, 100);
    defer alloc.free(unup);
    try std.testing.expectEqual(@as(usize, 30), unup.len);

    try store.markPreKeysUploaded(jid, 30);
    const unup2 = try store.getUnuploadedPreKeys(alloc, jid, 100);
    defer alloc.free(unup2);
    try std.testing.expectEqual(@as(usize, 0), unup2.len);

    const got = (try store.getPreKey(jid, 7)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 7), got.id);
    try std.testing.expectEqualSlices(u8, &recs[6].priv_key, &got.priv_key);
    try std.testing.expectEqualSlices(u8, &recs[6].pub_key, &got.pub_key);
    try std.testing.expect(got.uploaded);

    try store.removePreKey(jid, 7);
    try std.testing.expect((try store.getPreKey(jid, 7)) == null);
    try std.testing.expectEqual(@as(u32, 31), try store.nextPreKeyId(jid));
}

test "sqlite session blob roundtrip owned copy" {
    const alloc = std.testing.allocator;
    var store = try Container.open(alloc, ":memory:");
    defer store.deinit();
    const our = "me@s.whatsapp.net";
    try store.putDevice(dummyDevice(alloc, our));

    const blob = "\x01serialized-session-blob\x00\xff";
    try store.putSession(our, "them.0", blob);
    const got = (try store.getSession(our, "them.0")) orelse return error.TestUnexpectedResult;
    defer alloc.free(got);
    try std.testing.expectEqualSlices(u8, blob, got);
    const got2 = (try store.getSession(our, "them.0")) orelse return error.TestUnexpectedResult;
    defer alloc.free(got2);
    got[0] = 0;
    try std.testing.expectEqual(blob[0], got2[0]);
}
