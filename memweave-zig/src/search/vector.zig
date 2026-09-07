//! sqlite-vec cosine similarity search, ported from
//! `memweave/search/vector.py`.
//!
//! sqlite-vec remains an optional runtime dependency. The extension is loaded
//! into an already-open SQLite connection, then this module probes
//! `vec_version()` before every vector search. Embeddings are bound as raw
//! little-endian FLOAT32 blobs, matching sqlite-vec's canonical format.

const std = @import("std");
const sqlite = @import("sqlite");
const types = @import("../types.zig");
const errors = @import("../errors.zig");

pub const VectorError = errors.SearchError || error{
    MissingQueryVector,
    VectorSearchUnavailable,
};

const VecRow = struct {
    id: []const u8,
    path: []const u8,
    source: []const u8,
    start_line: i64,
    end_line: i64,
    text: []const u8,
    dist: f64,
};

/// Serialize FLOAT32 values in sqlite-vec's raw little-endian blob format.
/// This deliberately does not reinterpret the source slice as bytes: doing so
/// would inherit host endianness. sqlite-vec's wire/storage format is explicitly
/// little-endian, so encoding the IEEE-754 bits byte-by-byte is deterministic.
pub fn serializeFloat32(allocator: std.mem.Allocator, vec: []const f32) ![]u8 {
    const out = try allocator.alloc(u8, vec.len * 4);
    for (vec, 0..) |value, i| {
        const bits: u32 = @bitCast(value);
        const off = i * 4;
        out[off] = @truncate(bits);
        out[off + 1] = @truncate(bits >> 8);
        out[off + 2] = @truncate(bits >> 16);
        out[off + 3] = @truncate(bits >> 24);
    }
    return out;
}

/// Load a sqlite-vec-compatible extension into `db`, then immediately disable
/// further extension loading again. This mirrors the Python lifecycle's
/// `enable_load_extension(true) -> load_extension(...) -> false` sequence.
///
/// The path need not be zero-terminated; this function creates the temporary
/// C string required by SQLite.
pub fn loadExtension(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    path: []const u8,
) VectorError!void {
    const z_path = allocator.dupeZ(u8, path) catch return error.SearchError;
    defer allocator.free(z_path);

    const c = sqlite.c;
    if (c.sqlite3_enable_load_extension(db.db, 1) != c.SQLITE_OK) {
        return error.VectorSearchUnavailable;
    }
    defer _ = c.sqlite3_enable_load_extension(db.db, 0);

    // The extension's default entry point is used. We do not request an error
    // string here because the public Zig error is intentionally stable and does
    // not expose sqlite-vec implementation details.
    if (c.sqlite3_load_extension(db.db, z_path.ptr, null, null) != c.SQLITE_OK) {
        return error.VectorSearchUnavailable;
    }
}

/// Probe the same sqlite-vec function used by the Python implementation.
pub fn isAvailable(db: *sqlite.Db) bool {
    const len = db.one(
        i64,
        "SELECT length(vec_version())",
        .{},
        .{},
    ) catch return false;
    return (len orelse 0) > 0;
}

/// Run cosine similarity search against `chunks_vec` and hydrate metadata from
/// `chunks`. `query` is intentionally unused; it is kept in the signature so
/// this function has the same strategy shape as the Python `VectorSearch`.
pub fn search(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    query: []const u8,
    query_vec: ?[]const f32,
    model: []const u8,
    limit: i64,
    source_filter: ?[]const u8,
) VectorError![]types.RawSearchRow {
    _ = query;
    const vec = query_vec orelse return error.MissingQueryVector;
    if (!isAvailable(db)) return error.VectorSearchUnavailable;

    const blob_bytes = serializeFloat32(allocator, vec) catch return error.SearchError;
    defer allocator.free(blob_bytes);
    const blob = sqlite.Blob{ .data = blob_bytes };

    const rows: []VecRow = if (source_filter) |sf| blk: {
        var stmt = db.prepare(
            "SELECT c.id, c.path, c.source, c.start_line, c.end_line, c.text," ++
                " vec_distance_cosine(v.embedding, ?{blob}) AS dist" ++
                " FROM chunks_vec v JOIN chunks c ON c.id = v.id" ++
                " WHERE c.model = ?{[]const u8} AND c.source = ?{[]const u8}" ++
                " ORDER BY dist ASC LIMIT ?{i64}",
        ) catch return error.SearchError;
        defer stmt.deinit();
        break :blk stmt.all(VecRow, allocator, .{}, .{ blob, model, sf, limit }) catch return error.SearchError;
    } else blk: {
        var stmt = db.prepare(
            "SELECT c.id, c.path, c.source, c.start_line, c.end_line, c.text," ++
                " vec_distance_cosine(v.embedding, ?{blob}) AS dist" ++
                " FROM chunks_vec v JOIN chunks c ON c.id = v.id" ++
                " WHERE c.model = ?{[]const u8}" ++
                " ORDER BY dist ASC LIMIT ?{i64}",
        ) catch return error.SearchError;
        defer stmt.deinit();
        break :blk stmt.all(VecRow, allocator, .{}, .{ blob, model, limit }) catch return error.SearchError;
    };
    defer allocator.free(rows);

    var out = allocator.alloc(types.RawSearchRow, rows.len) catch return error.SearchError;
    for (rows, 0..) |r, i| {
        const score = 1.0 - r.dist;
        out[i] = .{
            .chunk_id = r.id,
            .path = r.path,
            .source = r.source,
            .start_line = @intCast(r.start_line),
            .end_line = @intCast(r.end_line),
            .text = r.text,
            .score = score,
            .vector_score = score,
            .text_score = null,
        };
    }
    return out;
}

test "serializeFloat32 emits deterministic little-endian IEEE-754 bytes" {
    const values = [_]f32{ 1.0, -2.5 };
    const encoded = try serializeFloat32(std.testing.allocator, &values);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x00, 0x80, 0x3f,
        0x00, 0x00, 0x20, 0xc0,
    }, encoded);
}

test "vector search distinguishes missing query vector from unavailable sqlite-vec" {
    var db = try sqlite.Db.init(.{
        .mode = .{ .Memory = {} },
        .open_flags = .{ .write = true, .create = true },
    });
    defer db.deinit();

    try std.testing.expectError(
        error.MissingQueryVector,
        search(std.testing.allocator, &db, "q", null, "model", 10, null),
    );

    const vec = [_]f32{ 1.0, 0.0 };
    try std.testing.expectError(
        error.VectorSearchUnavailable,
        search(std.testing.allocator, &db, "q", &vec, "model", 10, null),
    );
}
