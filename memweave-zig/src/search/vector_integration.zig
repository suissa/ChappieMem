//! End-to-end sqlite-vec validation. This file is intentionally not imported
//! by `src/root.zig`; it is run only by the `test-vector` build step, which
//! receives the path to a real sqlite-vec loadable extension from CI.

const std = @import("std");
const sqlite = @import("sqlite");
const memweave = @import("memweave");
const options = @import("vector_test_options");

const Fixture = struct {
    id: []const u8,
    path: []const u8,
    source: []const u8,
    text: []const u8,
    vec: [3]f32,
};

fn insertFixture(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    row: Fixture,
    model: []const u8,
) !void {
    db.exec(
        "INSERT INTO chunks (id, path, source, start_line, end_line, hash, model, text, embedding, updated_at)" ++
            " VALUES (?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{i64}, ?{i64}, ?{[]const u8}, ?{[]const u8}, ?{[]const u8}, NULL, ?{i64})",
        .{},
        .{ row.id, row.path, row.source, @as(i64, 1), @as(i64, 3), "hash", model, row.text, @as(i64, 1) },
    );

    db.exec(
        "INSERT INTO chunks_fts (text, id, path, source, model, start_line, end_line)" ++
            " VALUES (?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{[]const u8}, ?{i64}, ?{i64})",
        .{},
        .{ row.text, row.id, row.path, row.source, model, @as(i64, 1), @as(i64, 3) },
    );

    const bytes = try memweave.search.vector.serializeFloat32(allocator, &row.vec);
    defer allocator.free(bytes);
    const blob = sqlite.Blob{ .data = bytes };
    db.exec(
        "INSERT INTO chunks_vec (id, embedding) VALUES (?{[]const u8}, ?{blob})",
        .{},
        .{ row.id, blob },
    );
}

test "real sqlite-vec supports vector and hybrid search" {
    if (options.sqlite_vec_extension.len == 0) {
        return error.MissingSqliteVecExtension;
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var db = try sqlite.Db.init(.{
        .mode = .{ .Memory = {} },
        .open_flags = .{ .write = true, .create = true },
    });
    defer db.deinit();

    try memweave.search.vector.loadExtension(
        allocator,
        &db,
        options.sqlite_vec_extension,
    );
    try std.testing.expect(memweave.search.vector.isAvailable(&db));

    try memweave.storage.schema.ensureSchema(&db);
    try std.testing.expect(memweave.storage.schema.ensureVectorTable(&db, 3));

    const model: []const u8 = "fixture-model";
    const fixtures = [_]Fixture{
        .{
            .id = "c1",
            .path = "memory/a.md",
            .source = "memory",
            .text = "PostgreSQL database connection pooling",
            .vec = .{ 1.0, 0.0, 0.0 },
        },
        .{
            .id = "c2",
            .path = "memory/b.md",
            .source = "memory",
            .text = "PostgreSQL database tuning",
            .vec = .{ 0.8, 0.6, 0.0 },
        },
        .{
            .id = "c3",
            .path = "sessions/c.md",
            .source = "sessions",
            .text = "notes about cats and unrelated topics",
            .vec = .{ 0.0, 1.0, 0.0 },
        },
    };
    for (fixtures) |row| try insertFixture(allocator, &db, row, model);

    const query_vec = [_]f32{ 1.0, 0.0, 0.0 };
    const vector_rows = try memweave.search.vector.search(
        allocator,
        &db,
        "ignored by vector search",
        &query_vec,
        model,
        10,
        null,
    );
    try std.testing.expectEqual(@as(usize, 3), vector_rows.len);
    try std.testing.expectEqualStrings("c1", vector_rows[0].chunk_id);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), vector_rows[0].score, 1e-6);
    try std.testing.expectEqualStrings("c2", vector_rows[1].chunk_id);
    try std.testing.expect(vector_rows[0].vector_score != null);
    try std.testing.expect(vector_rows[0].text_score == null);

    const memory_only = try memweave.search.vector.search(
        allocator,
        &db,
        "ignored",
        &query_vec,
        model,
        10,
        "memory",
    );
    try std.testing.expectEqual(@as(usize, 2), memory_only.len);
    for (memory_only) |row| try std.testing.expectEqualStrings("memory", row.source);

    const hybrid_rows = try memweave.search.hybrid.search(
        allocator,
        &db,
        "PostgreSQL",
        &query_vec,
        model,
        2,
        "memory",
        .{},
    );
    try std.testing.expectEqual(@as(usize, 2), hybrid_rows.len);
    try std.testing.expectEqualStrings("c1", hybrid_rows[0].chunk_id);
    for (hybrid_rows) |row| {
        try std.testing.expect(row.vector_score != null);
        try std.testing.expect(row.text_score != null);
    }
}
