//! The storage- and search-backed half of the workload.
//!
//! `workload.zig` covers the pure modules — chunking, hashing, ranking,
//! decay, vectors, config. This covers everything that needs a database:
//! the SQLite schema, the `Store` CRUD surface, the embedding cache, FTS5
//! keyword search, score-threshold post-processing, and the hybrid merge.
//!
//! Same contract as the pure workload, so the five measured suites treat
//! both the same way: a **unit** returns a digest, and the same input must
//! always produce the same number.
//!
//! Getting a stable digest out of a database takes two decisions:
//!
//!   * **No clock, anywhere.** Every `mtime`, `size` and `updated_at` is
//!     derived from the document's index, never from the wall clock, so two
//!     runs a second apart write identical rows.
//!   * **The unit is its own inverse.** It indexes one document, reads it
//!     back, searches it, then deletes every row it created and asserts the
//!     store is empty again. That keeps the digest independent of how many
//!     units ran before it — and means the delete paths are exercised as
//!     hard as the insert paths, which is where storage layers usually rot.
//!
//! The second point is also what makes BM25 scores foldable: with only one
//! document's chunks in the index at a time, FTS5's corpus statistics are a
//! function of that document alone.
//!
//! Vector search is not covered here. It needs the `sqlite-vec` loadable
//! extension, which is not present in an ordinary build; `zig build
//! test-vector` covers it against a real extension in CI.

const std = @import("std");
const sqlite = @import("sqlite");
const memweave = @import("memweave");
const workload = @import("workload.zig");

pub const Store = memweave.storage.store.Store;
const schema = memweave.storage.schema;
const files = memweave.storage.files;
const keyword = memweave.search.keyword;
const postprocessor = memweave.search.postprocessor;
const hybrid = memweave.search.hybrid;
const chunking = memweave.chunking;
const hashing = memweave.hashing;
const types = memweave.types;
const forger = memweave.forger;

pub const model = "text-embedding-3-small";
pub const provider = "litellm";
/// Small on purpose: cached embeddings are JSON-encoded, so a realistic
/// 1536-wide vector would make the cache rows dominate every measurement.
pub const embedding_dim: usize = 32;

/// Fixed queries, drawn from the corpus vocabulary so they actually match.
/// The last two are deliberately fruitless — an empty result set is a path
/// worth folding into the digest too.
pub const queries = [_][]const u8{
    "memory context",
    "embedding vector index",
    "chunk overlap snippet",
    "schema behaviour cascade",
    "zzzz nonexistent",
    "the and of",
};

/// A fresh in-memory database with the schema applied. Caller owns it.
pub fn openMemoryDb() !sqlite.Db {
    var db = try sqlite.Db.init(.{
        .mode = .{ .Memory = {} },
        .open_flags = .{ .write = true, .create = true },
    });
    errdefer db.deinit();
    try schema.ensureSchema(&db);
    return db;
}

/// Deterministic stand-in for a file's modification time.
fn mtimeFor(index: usize) f64 {
    return 1_700_000_000.0 + @as(f64, @floatFromInt(index));
}

fn updatedAtFor(index: usize) i64 {
    return 1_700_000_000 + @as(i64, @intCast(index));
}

/// A cheap deterministic projection of a chunk's text into `embedding_dim`
/// buckets, normalized the way the indexer will before storing it.
fn embeddingFor(gpa: std.mem.Allocator, text: []const u8) ![]f32 {
    const vec = try gpa.alloc(f32, embedding_dim);
    @memset(vec, 0);
    for (text, 0..) |byte, i| {
        vec[i % embedding_dim] += @as(f32, @floatFromInt(byte % 17)) - 8.0;
    }
    memweave.vectors.normalizeEmbedding(vec);
    return vec;
}

/// One storage unit of work: index a document, read it back, search it,
/// exercise the embedding cache and the meta table, then delete everything
/// it wrote and confirm the store is empty again.
///
/// `store` must be empty on entry, and is empty again on return.
pub fn runStoreUnit(
    gpa: std.mem.Allocator,
    db: *sqlite.Db,
    store: *Store,
    doc: workload.Document,
    index: usize,
) !u64 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d = workload.Digest.init(workload.unit_seed);

    // ---- Index -------------------------------------------------------------

    const content_hash = hashing.sha256Text(doc.text);
    const source = files.sourceFromRelativePath(doc.name);
    // The embedding cache is keyed by (provider, model, provider_key, hash):
    // the provider fingerprint identifies the configuration that produced
    // the vector, and the hash identifies the text it was produced from.
    const provider_key_bytes = try hashing.makeProviderKey(arena, provider, model, null);
    const provider_key = try arena.dupe(u8, &provider_key_bytes);
    d.bytes(source);
    d.int(@intFromBool(files.isEvergreen(doc.name, (forger.MemoryConfig{}).evergreen_patterns)));

    try store.upsertFile(doc.name, source, &content_hash, mtimeFor(index), @intCast(doc.text.len));

    const chunks = try chunking.chunkMarkdown(gpa, doc.text, workload.chunk_tokens, workload.chunk_overlap);
    defer chunking.freeChunks(gpa, chunks);

    // A chunk id is derived from (source, path, start_line, end_line,
    // content_hash, model) — see `hashing.makeChunkId`, which mirrors
    // Python's. Two chunks that cover the same line range therefore get the
    // same id and collapse into one row on `INSERT OR REPLACE`. That happens
    // whenever a single line exceeds the chunk budget: the chunker pre-splits
    // it into segments that all carry that line's number. So the row count to
    // expect is the number of *distinct* ids, not the number of chunks.
    // `stress` measures how far the two diverge.
    var distinct_ids: usize = 0;
    const ids = try arena.alloc([]const u8, chunks.len);

    for (chunks, 0..) |c, i| {
        const id = try hashing.makeChunkId(arena, source, doc.name, c.start_line, c.end_line, &content_hash, model);
        const chunk_id = try arena.dupe(u8, &id);
        ids[i] = chunk_id;
        if (!containsId(ids[0..i], chunk_id)) distinct_ids += 1;
        const embedding = try embeddingFor(arena, c.text);
        const chunk_hash_bytes = hashing.sha256Text(c.text);
        const chunk_hash = try arena.dupe(u8, &chunk_hash_bytes);

        try store.upsertChunk(
            arena,
            chunk_id,
            doc.name,
            source,
            c.start_line,
            c.end_line,
            &content_hash,
            model,
            c.text,
            embedding,
            updatedAtFor(index + i),
        );
        try store.upsertFts(c.text, chunk_id, doc.name, source, c.start_line, c.end_line, model);
        try store.upsertEmbedding(
            arena,
            provider,
            model,
            provider_key,
            chunk_hash,
            embedding,
            @intCast(embedding.len),
            updatedAtFor(index + i),
        );
    }
    try store.commit();

    // ---- Read back ---------------------------------------------------------

    const file = try store.getFile(arena, doc.name);
    if (file == null) return error.FileMissingAfterInsert;
    d.bytes(file.?.path);
    d.bytes(file.?.source);
    d.bytes(file.?.hash);
    d.float(file.?.mtime);
    d.int(file.?.size);

    const listed = try store.listFiles(arena, null);
    d.int(listed.len);

    const stored_chunks = try store.getChunksByPath(arena, doc.name);
    d.int(stored_chunks.len);
    d.int(distinct_ids);
    if (stored_chunks.len != distinct_ids) return error.ChunkCountMismatch;
    for (stored_chunks) |c| {
        d.bytes(c.id);
        d.int(c.start_line);
        d.int(c.end_line);
        d.bytes(c.text);
        d.int(if (c.embedding) |e| e.len else 0);
        if (c.embedding) |e| {
            for (e) |v| d.float(v);
        }
    }
    d.int(try store.countChunks());

    // Every chunk id must resolve on its own too, not only through the path
    // index — a broken primary key would otherwise hide behind the query above.
    for (stored_chunks) |c| {
        const one = try store.getChunk(arena, c.id);
        if (one == null) return error.ChunkNotFoundById;
        d.bytes(one.?.id);
    }

    // ---- Embedding cache ---------------------------------------------------

    d.int(try store.countCacheEntries());
    if (stored_chunks.len > 0) {
        const hashes = try arena.alloc([]const u8, stored_chunks.len);
        for (stored_chunks, hashes) |c, *slot| {
            const h = hashing.sha256Text(c.text);
            slot.* = try arena.dupe(u8, &h);
        }

        const cached = try store.getEmbedding(arena, provider, model, provider_key, hashes[0]);
        d.int(if (cached) |c| c.len else 0);
        if (cached) |c| {
            for (c) |v| d.float(v);
        }

        // A hash that was never cached must miss rather than return a
        // neighbouring vector.
        const absent_hash: []const u8 = "0" ** 64;
        const miss = try store.getEmbedding(arena, provider, model, provider_key, absent_hash);
        d.int(@intFromBool(miss != null));

        const bulk = try store.getEmbeddingsBulk(arena, provider, model, provider_key, hashes);
        d.int(bulk.len);

        // Prune to one entry, then confirm the count followed.
        const pruned = try store.pruneCache(provider, model, 1);
        try store.commit();
        d.int(pruned);
        d.int(try store.countCacheEntries());
    }

    // ---- Meta --------------------------------------------------------------

    try store.setMeta("last_indexed_path", doc.name);
    try store.commit();
    const meta = try store.getMeta(arena, "last_indexed_path");
    d.bytes(meta orelse "");
    const all_meta = try store.getAllMeta(arena);
    d.int(all_meta.len);

    // ---- Search ------------------------------------------------------------

    for (queries) |query| {
        const rows = try keyword.search(arena, db, query, model, 10, null);
        d.int(rows.len);
        for (rows) |r| {
            d.bytes(r.chunk_id);
            d.int(r.start_line);
            d.int(r.end_line);
            d.float(r.score);
        }

        const kept = try postprocessor.scoreThreshold(arena, rows, (forger.QueryConfig{}).min_score);
        d.int(kept.len);

        // Merge the keyword rows against a synthetic vector side, so the
        // hybrid path is folded in without needing the sqlite-vec extension.
        const hybrid_cfg = (forger.HybridConfig{});
        const merged = try hybrid.mergeHybridResults(
            arena,
            try syntheticVectorRows(arena, rows),
            rows,
            hybrid_cfg.vector_weight,
            hybrid_cfg.text_weight,
            (forger.QueryConfig{}).max_results,
        );
        d.int(merged.len);
        for (merged) |r| d.float(r.score);
    }

    // ---- Delete, and confirm the store is empty again -----------------------

    const deleted = try store.deleteChunksByPath(doc.name);
    try store.deleteFtsByPath(doc.name);
    try store.deleteFile(doc.name);
    try store.commit();
    d.int(deleted);

    const remaining = try store.countChunks();
    if (remaining != 0) return error.StoreNotEmptyAfterDelete;
    if (try store.getFile(arena, doc.name) != null) return error.FileSurvivedDelete;
    d.int(remaining);

    // The cache is deliberately *not* cleared by deleting chunks — it is
    // keyed by provider and model, and survives re-indexing. Clear it here so
    // the next unit starts from the same state.
    _ = try store.clearCache();
    try store.commit();

    return d.final();
}

fn containsId(seen: []const []const u8, id: []const u8) bool {
    for (seen) |s| {
        if (std.mem.eql(u8, s, id)) return true;
    }
    return false;
}

/// How many chunks a document produces, and how many distinct ids those
/// chunks carry. The two differ exactly when a line exceeds the chunk budget.
pub const IdCollisions = struct {
    chunks: usize,
    distinct_ids: usize,

    pub fn collapsed(self: IdCollisions) usize {
        return self.chunks - self.distinct_ids;
    }
};

/// Count how many of a document's chunks would collapse into each other on
/// insert, without touching a database.
pub fn idCollisions(gpa: std.mem.Allocator, doc: workload.Document) !IdCollisions {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const content_hash = hashing.sha256Text(doc.text);
    const source = files.sourceFromRelativePath(doc.name);

    const chunks = try chunking.chunkMarkdown(gpa, doc.text, workload.chunk_tokens, workload.chunk_overlap);
    defer chunking.freeChunks(gpa, chunks);

    const ids = try arena.alloc([]const u8, chunks.len);
    var distinct: usize = 0;
    for (chunks, 0..) |c, i| {
        const id = try hashing.makeChunkId(arena, source, doc.name, c.start_line, c.end_line, &content_hash, model);
        ids[i] = try arena.dupe(u8, &id);
        if (!containsId(ids[0..i], ids[i])) distinct += 1;
    }
    return .{ .chunks = chunks.len, .distinct_ids = distinct };
}

/// The keyword rows presented as if a vector branch had returned them, so
/// `mergeHybridResults` has two genuinely different sides to reconcile.
///
/// The order is reversed and the scores inverted, which makes the merge do
/// real work — chunk ids overlap, so it has to combine rather than
/// concatenate, and the two rankings disagree, so the combined sort is
/// observable.
fn syntheticVectorRows(
    arena: std.mem.Allocator,
    rows: []const types.RawSearchRow,
) ![]types.RawSearchRow {
    const out = try arena.alloc(types.RawSearchRow, rows.len);
    for (rows, 0..) |row, i| {
        out[rows.len - 1 - i] = .{
            .chunk_id = row.chunk_id,
            .path = row.path,
            .source = row.source,
            .start_line = row.start_line,
            .end_line = row.end_line,
            .text = row.text,
            .score = 1.0 - row.score,
            .vector_score = 1.0 - row.score,
        };
    }
    return out;
}

/// Convenience for suites that just want "a fresh store, one unit, torn
/// down" — the shape `chaos` needs for fault injection.
pub fn runIsolatedStoreUnit(gpa: std.mem.Allocator, doc: workload.Document, index: usize) !u64 {
    var db = try openMemoryDb();
    defer db.deinit();
    var store = Store.init(&db);
    return runStoreUnit(gpa, &db, &store, doc, index);
}
