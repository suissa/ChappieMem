//! SQLite schema creation and versioning, ported from
//! `memweave/storage/schema.py`.
//!
//! `ensureSchema` is idempotent (every statement is `CREATE ... IF NOT
//! EXISTS`) and safe to call on every startup. `chunks_vec` (the sqlite-vec
//! ANN table) is deferred to a later phase — it requires an extension to be
//! loaded first, and this port doesn't wire that up yet.

const std = @import("std");
const sqlite = @import("sqlite");
const errors = @import("../errors.zig");

pub const schema_version: i64 = 1;

const create_meta =
    \\CREATE TABLE IF NOT EXISTS meta (
    \\    key   TEXT PRIMARY KEY,
    \\    value TEXT NOT NULL
    \\);
;

const create_files =
    \\CREATE TABLE IF NOT EXISTS files (
    \\    path   TEXT PRIMARY KEY,
    \\    source TEXT NOT NULL DEFAULT 'memory',
    \\    hash   TEXT NOT NULL,
    \\    mtime  REAL NOT NULL,
    \\    size   INTEGER NOT NULL
    \\);
;

const create_chunks =
    \\CREATE TABLE IF NOT EXISTS chunks (
    \\    id         TEXT PRIMARY KEY,
    \\    path       TEXT NOT NULL,
    \\    source     TEXT NOT NULL DEFAULT 'memory',
    \\    start_line INTEGER NOT NULL,
    \\    end_line   INTEGER NOT NULL,
    \\    hash       TEXT NOT NULL,
    \\    model      TEXT NOT NULL,
    \\    text       TEXT NOT NULL,
    \\    embedding  TEXT,
    \\    updated_at INTEGER NOT NULL
    \\);
;

// `text` is the only FTS-indexed column; everything else is UNINDEXED —
// stored for retrieval without a JOIN, but excluded from the full-text index.
const create_chunks_fts =
    \\CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    \\    text,
    \\    id         UNINDEXED,
    \\    path       UNINDEXED,
    \\    source     UNINDEXED,
    \\    model      UNINDEXED,
    \\    start_line UNINDEXED,
    \\    end_line   UNINDEXED
    \\);
;

// Primary key is (provider, model, provider_key, hash): provider/model are
// human-readable, provider_key fingerprints the full model config (model +
// api_base) so different endpoints never share cache entries, and hash is
// the SHA-256 of the chunk's text. updated_at drives LRU eviction.
const create_embedding_cache =
    \\CREATE TABLE IF NOT EXISTS embedding_cache (
    \\    provider     TEXT NOT NULL,
    \\    model        TEXT NOT NULL,
    \\    provider_key TEXT NOT NULL,
    \\    hash         TEXT NOT NULL,
    \\    embedding    TEXT NOT NULL,
    \\    dims         INTEGER,
    \\    updated_at   INTEGER NOT NULL,
    \\    PRIMARY KEY (provider, model, provider_key, hash)
    \\);
;

const create_indices =
    \\CREATE INDEX IF NOT EXISTS idx_embedding_cache_updated_at ON embedding_cache(updated_at);
    \\CREATE INDEX IF NOT EXISTS idx_chunks_path ON chunks(path);
    \\CREATE INDEX IF NOT EXISTS idx_chunks_source ON chunks(source);
    \\CREATE INDEX IF NOT EXISTS idx_chunks_hash ON chunks(hash);
;

/// Create all base tables and indices if they do not already exist, then
/// record `schema_version` in `meta` (mirrors `ensure_schema`).
pub fn ensureSchema(db: *sqlite.Db) errors.StorageError!void {
    db.execMulti(create_meta, .{}) catch return error.StorageError;
    db.execMulti(create_files, .{}) catch return error.StorageError;
    db.execMulti(create_chunks, .{}) catch return error.StorageError;
    db.execMulti(create_chunks_fts, .{}) catch return error.StorageError;
    db.execMulti(create_embedding_cache, .{}) catch return error.StorageError;
    db.execMulti(create_indices, .{}) catch return error.StorageError;

    // The `value` column has TEXT affinity, so binding an integer here
    // stores its text representation — matching Python's `str(SCHEMA_VERSION)`.
    db.exec(
        "INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', ?{i64})",
        .{},
        .{schema_version},
    ) catch return error.StorageError;
}

/// Return the stored schema version from `meta`, or 0 if unset (mirrors
/// `get_schema_version`).
pub fn getSchemaVersion(db: *sqlite.Db) i64 {
    const value = db.one(
        i64,
        "SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'schema_version'",
        .{},
        .{},
    ) catch return 0;
    return value orelse 0;
}

test "ensureSchema is idempotent and sets schema_version" {
    var db = try sqlite.Db.init(.{
        .mode = .{ .Memory = {} },
        .open_flags = .{ .write = true, .create = true },
    });
    defer db.deinit();

    try ensureSchema(&db);
    try ensureSchema(&db);

    try std.testing.expectEqual(@as(i64, schema_version), getSchemaVersion(&db));
}

test "getSchemaVersion returns 0 on a fresh database with no meta table" {
    var db = try sqlite.Db.init(.{
        .mode = .{ .Memory = {} },
        .open_flags = .{ .write = true, .create = true },
    });
    defer db.deinit();

    try std.testing.expectEqual(@as(i64, 0), getSchemaVersion(&db));
}
