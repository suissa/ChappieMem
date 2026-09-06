//! Parameterized CRUD operations on all tables, ported from
//! `memweave/storage/sqlite_store.py`.
//!
//! `Store` wraps an already-open `sqlite.Db` and never closes it — the
//! caller owns the connection lifecycle, matching `SQLiteStore`. Every
//! read method that returns strings/slices takes an explicit `allocator`;
//! the caller owns and frees the result.
//!
//! zig-sqlite's `Db` has no built-in transaction batching (unlike Python's
//! sqlite3/aiosqlite, which implicitly opens a transaction before the first
//! DML statement). `Store` reproduces the same "writes are buffered until
//! `commit()`/`rollback()`" contract explicitly: the first write after
//! construction or after a commit/rollback issues `BEGIN`, and `commit()`/
//! `rollback()` issue `COMMIT`/`ROLLBACK`.

const std = @import("std");
const sqlite = @import("sqlite");
const errors = @import("../errors.zig");

pub const FileRecord = struct {
    path: []const u8,
    source: []const u8,
    hash: []const u8,
    mtime: f64,
    size: i64,
};

pub const ChunkRecord = struct {
    id: []const u8,
    path: []const u8,
    source: []const u8,
    start_line: i64,
    end_line: i64,
    hash: []const u8,
    model: []const u8,
    text: []const u8,
    /// Owned by the caller; `null` if no embedding has been computed yet.
    embedding: ?[]f32,
    updated_at: i64,
};

pub const MetaEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const HashEmbedding = struct {
    hash: []const u8,
    embedding: []f32,
};

/// Column shape shared by every `chunks` row query. Named (rather than an
/// inline anonymous struct at each call site) because Zig gives each
/// anonymous struct literal its own distinct nominal type even when
/// structurally identical — two separately-written `struct { ... }`
/// literals with the same fields are NOT interchangeable.
const ChunkRow = struct {
    id: []const u8,
    path: []const u8,
    source: []const u8,
    start_line: i64,
    end_line: i64,
    hash: []const u8,
    model: []const u8,
    text: []const u8,
    embedding: ?[]const u8,
    updated_at: i64,
};

/// Encode a float slice as a JSON array string, e.g. `[0.1,0.2,0.3]`
/// (mirrors storing `json.dumps(embedding)`). Hand-rolled instead of using
/// `std.json` to keep this module's surface small and fully self-tested.
fn encodeEmbeddingJson(allocator: std.mem.Allocator, values: []const f32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '[');
    for (values, 0..) |v, i| {
        if (i != 0) try buf.append(allocator, ',');
        var num_buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&num_buf, "{d}", .{v});
        try buf.appendSlice(allocator, s);
    }
    try buf.append(allocator, ']');

    return buf.toOwnedSlice(allocator);
}

/// Decode a JSON array string produced by `encodeEmbeddingJson` back into a
/// float slice (mirrors `json.loads(...)` on a stored embedding column).
fn decodeEmbeddingJson(allocator: std.mem.Allocator, json: []const u8) ![]f32 {
    var values: std.ArrayList(f32) = .empty;
    errdefer values.deinit(allocator);

    const trimmed = std.mem.trim(u8, json, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        return error.InvalidEmbeddingJson;
    }
    const inner = trimmed[1 .. trimmed.len - 1];
    if (inner.len == 0) return values.toOwnedSlice(allocator);

    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |piece| {
        const p = std.mem.trim(u8, piece, " \t\r\n");
        const v = try std.fmt.parseFloat(f32, p);
        try values.append(allocator, v);
    }
    return values.toOwnedSlice(allocator);
}

pub const Store = struct {
    db: *sqlite.Db,
    in_transaction: bool = false,

    pub fn init(db: *sqlite.Db) Store {
        return .{ .db = db };
    }

    fn beginWrite(self: *Store) errors.StorageError!void {
        if (self.in_transaction) return;
        self.db.exec("BEGIN", .{}, .{}) catch return error.StorageError;
        self.in_transaction = true;
    }

    // ── Meta table ───────────────────────────────────────────────────────

    pub fn setMeta(self: *Store, key: []const u8, value: []const u8) errors.StorageError!void {
        try self.beginWrite();
        self.db.exec(
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?{[]const u8}, ?{[]const u8})",
            .{},
            .{ key, value },
        ) catch return error.StorageError;
    }

    pub fn getMeta(self: *Store, allocator: std.mem.Allocator, key: []const u8) errors.StorageError!?[]const u8 {
        return self.db.oneAlloc(
            []const u8,
            allocator,
            "SELECT value FROM meta WHERE key = ?{[]const u8}",
            .{},
            .{key},
        ) catch return error.StorageError;
    }

    pub fn getAllMeta(self: *Store, allocator: std.mem.Allocator) errors.StorageError![]MetaEntry {
        var stmt = self.db.prepare("SELECT key, value FROM meta") catch return error.StorageError;
        defer stmt.deinit();
        return stmt.all(MetaEntry, allocator, .{}, .{}) catch return error.StorageError;
    }

    // ── Files table ──────────────────────────────────────────────────────

    pub fn upsertFile(self: *Store, path: []const u8, source: []const u8, hash: []const u8, mtime: f64, size: i64) errors.StorageError!void {
        try self.beginWrite();
        self.db.exec(
            \\INSERT OR REPLACE INTO files (path, source, hash, mtime, size)
            \\VALUES (?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{f64}, ?{i64})
        ,
            .{},
            .{ path, source, hash, mtime, size },
        ) catch return error.StorageError;
    }

    pub fn getFile(self: *Store, allocator: std.mem.Allocator, path: []const u8) errors.StorageError!?FileRecord {
        return self.db.oneAlloc(
            FileRecord,
            allocator,
            "SELECT path, source, hash, mtime, size FROM files WHERE path = ?{[]const u8}",
            .{},
            .{path},
        ) catch return error.StorageError;
    }

    pub fn deleteFile(self: *Store, path: []const u8) errors.StorageError!void {
        try self.beginWrite();
        self.db.exec("DELETE FROM files WHERE path = ?{[]const u8}", .{}, .{path}) catch return error.StorageError;
    }

    pub fn listFiles(self: *Store, allocator: std.mem.Allocator, source: ?[]const u8) errors.StorageError![]FileRecord {
        if (source) |s| {
            var stmt = self.db.prepare(
                "SELECT path, source, hash, mtime, size FROM files WHERE source = ?{[]const u8}",
            ) catch return error.StorageError;
            defer stmt.deinit();
            return stmt.all(FileRecord, allocator, .{}, .{s}) catch return error.StorageError;
        }
        var stmt = self.db.prepare(
            "SELECT path, source, hash, mtime, size FROM files",
        ) catch return error.StorageError;
        defer stmt.deinit();
        return stmt.all(FileRecord, allocator, .{}, .{}) catch return error.StorageError;
    }

    // ── Chunks table ─────────────────────────────────────────────────────

    pub fn upsertChunk(
        self: *Store,
        allocator: std.mem.Allocator,
        id: []const u8,
        path: []const u8,
        source: []const u8,
        start_line: i64,
        end_line: i64,
        hash: []const u8,
        model: []const u8,
        text: []const u8,
        embedding: ?[]const f32,
        updated_at: i64,
    ) errors.StorageError!void {
        try self.beginWrite();

        const embedding_json: ?[]const u8 = if (embedding) |e|
            encodeEmbeddingJson(allocator, e) catch return error.StorageError
        else
            null;
        defer if (embedding_json) |j| allocator.free(j);

        self.db.exec(
            \\INSERT OR REPLACE INTO chunks
            \\    (id, path, source, start_line, end_line, hash, model, text, embedding, updated_at)
            \\VALUES (?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{i64}, ?{i64}, ?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{?[]const u8}, ?{i64})
        ,
            .{},
            .{ id, path, source, start_line, end_line, hash, model, text, embedding_json, updated_at },
        ) catch return error.StorageError;
    }

    fn rowToChunk(allocator: std.mem.Allocator, row: ChunkRow) errors.StorageError!ChunkRecord {
        const embedding: ?[]f32 = if (row.embedding) |e|
            decodeEmbeddingJson(allocator, e) catch return error.StorageError
        else
            null;
        return .{
            .id = row.id,
            .path = row.path,
            .source = row.source,
            .start_line = row.start_line,
            .end_line = row.end_line,
            .hash = row.hash,
            .model = row.model,
            .text = row.text,
            .embedding = embedding,
            .updated_at = row.updated_at,
        };
    }

    pub fn getChunk(self: *Store, allocator: std.mem.Allocator, chunk_id: []const u8) errors.StorageError!?ChunkRecord {
        const row = self.db.oneAlloc(
            ChunkRow,
            allocator,
            \\SELECT id, path, source, start_line, end_line, hash, model, text, embedding, updated_at
            \\FROM chunks WHERE id = ?{[]const u8}
        ,
            .{},
            .{chunk_id},
        ) catch return error.StorageError;
        const r = row orelse return null;
        return try rowToChunk(allocator, r);
    }

    pub fn getChunksByPath(self: *Store, allocator: std.mem.Allocator, path: []const u8) errors.StorageError![]ChunkRecord {
        var stmt = self.db.prepare(
            \\SELECT id, path, source, start_line, end_line, hash, model, text, embedding, updated_at
            \\FROM chunks WHERE path = ?{[]const u8}
            \\ORDER BY start_line
        ) catch return error.StorageError;
        defer stmt.deinit();

        const rows = stmt.all(ChunkRow, allocator, .{}, .{path}) catch return error.StorageError;
        defer allocator.free(rows);

        var out = allocator.alloc(ChunkRecord, rows.len) catch return error.StorageError;
        for (rows, 0..) |r, i| out[i] = try rowToChunk(allocator, r);
        return out;
    }

    pub fn deleteChunksByPath(self: *Store, path: []const u8) errors.StorageError!i64 {
        try self.beginWrite();
        self.db.exec("DELETE FROM chunks WHERE path = ?{[]const u8}", .{}, .{path}) catch return error.StorageError;
        return @intCast(self.db.rowsAffected());
    }

    pub fn countChunks(self: *Store) errors.StorageError!i64 {
        const count = self.db.one(i64, "SELECT COUNT(*) FROM chunks", .{}, .{}) catch return error.StorageError;
        return count orelse 0;
    }

    // ── FTS table ────────────────────────────────────────────────────────

    /// FTS5 virtual tables support neither `ON CONFLICT DO UPDATE` nor
    /// `INSERT OR REPLACE`; simulate an upsert with delete-then-insert,
    /// same as the Python original.
    pub fn upsertFts(
        self: *Store,
        text: []const u8,
        chunk_id: []const u8,
        path: []const u8,
        source: []const u8,
        start_line: i64,
        end_line: i64,
        model: []const u8,
    ) errors.StorageError!void {
        try self.beginWrite();
        self.db.exec("DELETE FROM chunks_fts WHERE id = ?{[]const u8}", .{}, .{chunk_id}) catch return error.StorageError;
        self.db.exec(
            \\INSERT INTO chunks_fts (text, id, path, source, model, start_line, end_line)
            \\VALUES (?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{i64}, ?{i64})
        ,
            .{},
            .{ text, chunk_id, path, source, model, start_line, end_line },
        ) catch return error.StorageError;
    }

    pub fn deleteFtsByPath(self: *Store, path: []const u8) errors.StorageError!void {
        try self.beginWrite();
        self.db.exec("DELETE FROM chunks_fts WHERE path = ?{[]const u8}", .{}, .{path}) catch return error.StorageError;
    }

    // ── Embedding cache ──────────────────────────────────────────────────

    pub fn upsertEmbedding(
        self: *Store,
        allocator: std.mem.Allocator,
        provider: []const u8,
        model: []const u8,
        provider_key: []const u8,
        hash: []const u8,
        embedding: []const f32,
        dims: i64,
        updated_at: i64,
    ) errors.StorageError!void {
        try self.beginWrite();

        const embedding_json: []const u8 = encodeEmbeddingJson(allocator, embedding) catch return error.StorageError;
        defer allocator.free(embedding_json);

        self.db.exec(
            \\INSERT OR REPLACE INTO embedding_cache
            \\    (provider, model, provider_key, hash, embedding, dims, updated_at)
            \\VALUES (?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{i64}, ?{i64})
        ,
            .{},
            .{ provider, model, provider_key, hash, embedding_json, dims, updated_at },
        ) catch return error.StorageError;
    }

    pub fn getEmbedding(
        self: *Store,
        allocator: std.mem.Allocator,
        provider: []const u8,
        model: []const u8,
        provider_key: []const u8,
        hash: []const u8,
    ) errors.StorageError!?[]f32 {
        const json = self.db.oneAlloc(
            []const u8,
            allocator,
            \\SELECT embedding FROM embedding_cache
            \\WHERE provider = ?{[]const u8} AND model = ?{[]const u8} AND provider_key = ?{[]const u8} AND hash = ?{[]const u8}
        ,
            .{},
            .{ provider, model, provider_key, hash },
        ) catch return error.StorageError;
        const j = json orelse return null;
        defer allocator.free(j);
        return decodeEmbeddingJson(allocator, j) catch return error.StorageError;
    }

    /// Batch-lookup cached embeddings for multiple chunk hashes.
    ///
    /// The Python original issues one query with a dynamic `IN (...)`
    /// clause; that requires binding a runtime-sized parameter list, which
    /// zig-sqlite's typed-placeholder API isn't a good fit for. This calls
    /// `getEmbedding` per hash instead — same externally observable result
    /// (a hash → vector map covering only cache hits), N queries instead of
    /// one. Revisit if cache-lookup batch size becomes a real bottleneck.
    pub fn getEmbeddingsBulk(
        self: *Store,
        allocator: std.mem.Allocator,
        provider: []const u8,
        model: []const u8,
        provider_key: []const u8,
        hashes: []const []const u8,
    ) errors.StorageError![]HashEmbedding {
        var out: std.ArrayList(HashEmbedding) = .empty;
        errdefer out.deinit(allocator);

        for (hashes) |hash| {
            if (try self.getEmbedding(allocator, provider, model, provider_key, hash)) |vec| {
                out.append(allocator, .{ .hash = hash, .embedding = vec }) catch return error.StorageError;
            }
        }
        return out.toOwnedSlice(allocator) catch return error.StorageError;
    }

    pub fn countCacheEntries(self: *Store) errors.StorageError!i64 {
        const count = self.db.one(i64, "SELECT COUNT(*) FROM embedding_cache", .{}, .{}) catch return error.StorageError;
        return count orelse 0;
    }

    /// LRU eviction: delete the oldest embeddings for `(provider, model)`
    /// beyond `max_entries`. Returns the number of rows deleted.
    pub fn pruneCache(self: *Store, provider: []const u8, model: []const u8, max_entries: i64) errors.StorageError!i64 {
        const current = (self.db.one(
            i64,
            "SELECT COUNT(*) FROM embedding_cache WHERE provider = ?{[]const u8} AND model = ?{[]const u8}",
            .{},
            .{ provider, model },
        ) catch return error.StorageError) orelse 0;

        if (current <= max_entries) return 0;
        const to_delete = current - max_entries;

        try self.beginWrite();
        self.db.exec(
            \\DELETE FROM embedding_cache
            \\WHERE (provider, model, provider_key, hash) IN (
            \\    SELECT provider, model, provider_key, hash
            \\    FROM embedding_cache
            \\    WHERE provider = ?{[]const u8} AND model = ?{[]const u8}
            \\    ORDER BY updated_at ASC
            \\    LIMIT ?{i64}
            \\)
        ,
            .{},
            .{ provider, model, to_delete },
        ) catch return error.StorageError;

        return to_delete;
    }

    pub fn clearCache(self: *Store) errors.StorageError!i64 {
        const count = (self.db.one(i64, "SELECT COUNT(*) FROM embedding_cache", .{}, .{}) catch return error.StorageError) orelse 0;
        try self.beginWrite();
        self.db.exec("DELETE FROM embedding_cache", .{}, .{}) catch return error.StorageError;
        return count;
    }

    // ── Transactions ─────────────────────────────────────────────────────

    pub fn commit(self: *Store) errors.StorageError!void {
        if (!self.in_transaction) return;
        self.db.exec("COMMIT", .{}, .{}) catch return error.StorageError;
        self.in_transaction = false;
    }

    pub fn rollback(self: *Store) errors.StorageError!void {
        if (!self.in_transaction) return;
        self.db.exec("ROLLBACK", .{}, .{}) catch return error.StorageError;
        self.in_transaction = false;
    }
};

const schema = @import("schema.zig");

fn testDb() !sqlite.Db {
    var db = try sqlite.Db.init(.{
        .mode = .{ .Memory = {} },
        .open_flags = .{ .write = true, .create = true },
    });
    try schema.ensureSchema(&db);
    return db;
}

test "encodeEmbeddingJson / decodeEmbeddingJson round-trip" {
    const values = [_]f32{ 0.5, -1.25, 3.0 };
    const json = try encodeEmbeddingJson(std.testing.allocator, &values);
    defer std.testing.allocator.free(json);

    const decoded = try decodeEmbeddingJson(std.testing.allocator, json);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(values.len, decoded.len);
    for (values, decoded) |a, b| try std.testing.expectEqual(a, b);
}

test "decodeEmbeddingJson handles an empty array" {
    const decoded = try decodeEmbeddingJson(std.testing.allocator, "[]");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "Store: meta set/get round-trip and missing key returns null" {
    var db = try testDb();
    defer db.deinit();
    var store = Store.init(&db);

    try store.setMeta("last_sync_at", "1742000000");
    try store.commit();

    const value = try store.getMeta(std.testing.allocator, "last_sync_at");
    defer if (value) |v| std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("1742000000", value.?);

    const missing = try store.getMeta(std.testing.allocator, "does_not_exist");
    try std.testing.expectEqual(@as(?[]const u8, null), missing);
}

test "Store: file upsert/get/list/delete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var db = try testDb();
    defer db.deinit();
    var store = Store.init(&db);

    try store.upsertFile("memory/2026-03-21.md", "memory", "abc123", 1742000000.0, 4096);
    try store.upsertFile("memory/sessions/s1.md", "sessions", "def456", 1742000001.0, 128);
    try store.commit();

    const file = try store.getFile(allocator, "memory/2026-03-21.md");
    try std.testing.expect(file != null);
    try std.testing.expectEqualStrings("memory", file.?.source);
    try std.testing.expectEqualStrings("abc123", file.?.hash);
    try std.testing.expectEqual(@as(f64, 1742000000.0), file.?.mtime);
    try std.testing.expectEqual(@as(i64, 4096), file.?.size);

    const all_files = try store.listFiles(allocator, null);
    try std.testing.expectEqual(@as(usize, 2), all_files.len);

    const session_files = try store.listFiles(allocator, "sessions");
    try std.testing.expectEqual(@as(usize, 1), session_files.len);
    try std.testing.expectEqualStrings("memory/sessions/s1.md", session_files[0].path);

    try store.deleteFile("memory/2026-03-21.md");
    try store.commit();
    const gone = try store.getFile(allocator, "memory/2026-03-21.md");
    try std.testing.expectEqual(@as(?FileRecord, null), gone);
}

test "Store: chunk upsert/get/getByPath/delete round-trips the embedding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var db = try testDb();
    defer db.deinit();
    var store = Store.init(&db);

    const embedding = [_]f32{ 0.1, 0.2, 0.3 };
    try store.upsertChunk(
        allocator,
        "chunk-1",
        "memory/2026-03-21.md",
        "memory",
        1,
        10,
        "hash-1",
        "text-embedding-3-small",
        "hello world",
        &embedding,
        1742000000,
    );
    try store.upsertChunk(
        allocator,
        "chunk-2",
        "memory/2026-03-21.md",
        "memory",
        11,
        20,
        "hash-2",
        "text-embedding-3-small",
        "second chunk",
        null,
        1742000001,
    );
    try store.commit();

    const chunk = try store.getChunk(allocator, "chunk-1");
    try std.testing.expect(chunk != null);
    try std.testing.expectEqualStrings("hello world", chunk.?.text);
    try std.testing.expect(chunk.?.embedding != null);
    try std.testing.expectEqual(@as(usize, 3), chunk.?.embedding.?.len);
    try std.testing.expectEqual(@as(f32, 0.2), chunk.?.embedding.?[1]);

    const no_embedding_chunk = try store.getChunk(allocator, "chunk-2");
    try std.testing.expect(no_embedding_chunk != null);
    try std.testing.expectEqual(@as(?[]f32, null), no_embedding_chunk.?.embedding);

    const by_path = try store.getChunksByPath(allocator, "memory/2026-03-21.md");
    try std.testing.expectEqual(@as(usize, 2), by_path.len);
    try std.testing.expectEqualStrings("chunk-1", by_path[0].id);
    try std.testing.expectEqualStrings("chunk-2", by_path[1].id);

    try std.testing.expectEqual(@as(i64, 2), try store.countChunks());

    const deleted = try store.deleteChunksByPath("memory/2026-03-21.md");
    try store.commit();
    try std.testing.expectEqual(@as(i64, 2), deleted);
    try std.testing.expectEqual(@as(i64, 0), try store.countChunks());
}

test "Store: FTS upsert replaces the previous row for the same chunk id" {
    var db = try testDb();
    defer db.deinit();
    var store = Store.init(&db);

    try store.upsertFts("first version", "chunk-1", "memory/x.md", "memory", 1, 5, "text-embedding-3-small");
    try store.upsertFts("second version", "chunk-1", "memory/x.md", "memory", 1, 5, "text-embedding-3-small");
    try store.commit();

    const count = try db.one(i64, "SELECT COUNT(*) FROM chunks_fts WHERE id = ?", .{}, .{"chunk-1"});
    try std.testing.expectEqual(@as(?i64, 1), count);

    try store.deleteFtsByPath("memory/x.md");
    try store.commit();
    const after_delete = try db.one(i64, "SELECT COUNT(*) FROM chunks_fts WHERE id = ?", .{}, .{"chunk-1"});
    try std.testing.expectEqual(@as(?i64, 0), after_delete);
}

test "Store: embedding cache set/get, bulk lookup, count, and clear" {
    var db = try testDb();
    defer db.deinit();
    var store = Store.init(&db);

    const v1 = [_]f32{ 1.0, 2.0 };
    const v2 = [_]f32{ 3.0, 4.0 };
    try store.upsertEmbedding(std.testing.allocator, "litellm", "text-embedding-3-small", "key-1", "hash-1", &v1, 2, 1000);
    try store.upsertEmbedding(std.testing.allocator, "litellm", "text-embedding-3-small", "key-1", "hash-2", &v2, 2, 1001);
    try store.commit();

    const cached = try store.getEmbedding(std.testing.allocator, "litellm", "text-embedding-3-small", "key-1", "hash-1");
    defer if (cached) |c| std.testing.allocator.free(c);
    try std.testing.expect(cached != null);
    try std.testing.expectEqual(@as(f32, 2.0), cached.?[1]);

    const miss = try store.getEmbedding(std.testing.allocator, "litellm", "text-embedding-3-small", "key-1", "hash-missing");
    try std.testing.expectEqual(@as(?[]f32, null), miss);

    const bulk = try store.getEmbeddingsBulk(
        std.testing.allocator,
        "litellm",
        "text-embedding-3-small",
        "key-1",
        &.{ "hash-1", "hash-2", "hash-missing" },
    );
    defer {
        for (bulk) |entry| std.testing.allocator.free(entry.embedding);
        std.testing.allocator.free(bulk);
    }
    try std.testing.expectEqual(@as(usize, 2), bulk.len);

    try std.testing.expectEqual(@as(i64, 2), try store.countCacheEntries());

    const cleared = try store.clearCache();
    try std.testing.expectEqual(@as(i64, 2), cleared);
    try std.testing.expectEqual(@as(i64, 0), try store.countCacheEntries());
}

test "Store: pruneCache evicts the oldest entries beyond max_entries" {
    var db = try testDb();
    defer db.deinit();
    var store = Store.init(&db);

    const v = [_]f32{1.0};
    try store.upsertEmbedding(std.testing.allocator, "litellm", "m", "key", "hash-1", &v, 1, 100);
    try store.upsertEmbedding(std.testing.allocator, "litellm", "m", "key", "hash-2", &v, 1, 200);
    try store.upsertEmbedding(std.testing.allocator, "litellm", "m", "key", "hash-3", &v, 1, 300);
    try store.commit();

    const deleted = try store.pruneCache("litellm", "m", 2);
    try store.commit();
    try std.testing.expectEqual(@as(i64, 1), deleted);
    try std.testing.expectEqual(@as(i64, 2), try store.countCacheEntries());

    // The oldest entry (hash-1, updated_at=100) should be the one evicted.
    const oldest_gone = try store.getEmbedding(std.testing.allocator, "litellm", "m", "key", "hash-1");
    try std.testing.expectEqual(@as(?[]f32, null), oldest_gone);
}
