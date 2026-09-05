//! Weighted merge of vector + keyword search results, ported from
//! `memweave/search/hybrid.py`'s `merge_hybrid_results`.
//!
//! `combined_score = vector_weight * vector_score + text_weight * text_score`,
//! with a missing component (a chunk found by only one backend) treated as
//! 0. This module covers only the merge — it has no SQLite dependency.
//! `VectorSearch`/`HybridSearch.search()` themselves need the `sqlite-vec`
//! extension, which isn't wired into this Zig port yet (a separate,
//! substantial C-extension integration), so they're deferred to a later
//! phase. `KeywordSearch.search()` (search/keyword.zig) already exists and
//! can be fed into this function directly once vector search lands.

const std = @import("std");
const types = @import("../types.zig");

const MergeEntry = struct {
    row: types.RawSearchRow,
    vector_score: f64,
    text_score: f64,
};

/// Merge vector and keyword results into a single ranked list (mirrors
/// `merge_hybrid_results`).
///
/// Algorithm:
/// 1. Seed entries from `vector_rows`, keyed by `chunk_id`, in order.
/// 2. Walk `keyword_rows`: an existing chunk_id gets its text_score filled
///    in (preferring the keyword row's snippet when non-empty — FTS5
///    snippets tend to be more relevant to the query terms); a new
///    chunk_id is appended with vector_score 0.
/// 3. Compute `combined = vector_weight * vs + text_weight * ts` for every
///    entry.
/// 4. Stable-sort by combined score descending (ties keep the insertion
///    order above, matching Python's stable `list.sort`).
/// 5. Truncate to `limit` if given.
///
/// Returns a caller-owned slice.
pub fn mergeHybridResults(
    allocator: std.mem.Allocator,
    vector_rows: []const types.RawSearchRow,
    keyword_rows: []const types.RawSearchRow,
    vector_weight: f64,
    text_weight: f64,
    limit: ?usize,
) ![]types.RawSearchRow {
    // A linear scan to find an existing chunk_id (rather than a hash map)
    // is fine here: result sizes are small (bounded by
    // limit * candidate_multiplier), and it keeps this module's Zig-API
    // surface small and fully self-tested, same tradeoff made in
    // keyword.zig's extractKeywords dedup.
    var entries: std.ArrayList(MergeEntry) = .empty;
    defer entries.deinit(allocator);

    for (vector_rows) |row| {
        const vs = row.vector_score orelse row.score;
        const existing_idx = for (entries.items, 0..) |e, idx| {
            if (std.mem.eql(u8, e.row.chunk_id, row.chunk_id)) break idx;
        } else null;
        if (existing_idx) |idx| {
            entries.items[idx] = .{ .row = row, .vector_score = vs, .text_score = 0.0 };
        } else {
            try entries.append(allocator, .{ .row = row, .vector_score = vs, .text_score = 0.0 });
        }
    }

    for (keyword_rows) |row| {
        const ts = row.text_score orelse row.score;
        const existing_idx = for (entries.items, 0..) |e, idx| {
            if (std.mem.eql(u8, e.row.chunk_id, row.chunk_id)) break idx;
        } else null;
        if (existing_idx) |idx| {
            const existing = entries.items[idx];
            const preferred_row = if (row.text.len != 0) row else existing.row;
            entries.items[idx] = .{ .row = preferred_row, .vector_score = existing.vector_score, .text_score = ts };
        } else {
            try entries.append(allocator, .{ .row = row, .vector_score = 0.0, .text_score = ts });
        }
    }

    var result = try allocator.alloc(types.RawSearchRow, entries.items.len);
    errdefer allocator.free(result);
    for (entries.items, 0..) |e, i| {
        const combined = vector_weight * e.vector_score + text_weight * e.text_score;
        result[i] = .{
            .chunk_id = e.row.chunk_id,
            .path = e.row.path,
            .source = e.row.source,
            .start_line = e.row.start_line,
            .end_line = e.row.end_line,
            .text = e.row.text,
            .score = combined,
            .vector_score = e.vector_score,
            .text_score = e.text_score,
        };
    }

    // Stable insertion sort by score descending. `std.sort`'s pdq-family
    // sorts aren't guaranteed stable, and matching Python's stable
    // `list.sort` tie-breaking (insertion order above) matters here;
    // result sizes are small (bounded by limit * candidate_multiplier), so
    // the O(n^2) cost is a non-issue.
    var i: usize = 1;
    while (i < result.len) : (i += 1) {
        const key = result[i];
        var j: usize = i;
        while (j > 0 and result[j - 1].score < key.score) : (j -= 1) {
            result[j] = result[j - 1];
        }
        result[j] = key;
    }

    if (limit) |l| {
        if (l < result.len) {
            const truncated = try allocator.alloc(types.RawSearchRow, l);
            @memcpy(truncated, result[0..l]);
            allocator.free(result);
            return truncated;
        }
    }
    return result;
}

fn testRow(chunk_id: []const u8, text: []const u8, score: f64, vector_score: ?f64, text_score: ?f64) types.RawSearchRow {
    return .{
        .chunk_id = chunk_id,
        .path = "p",
        .source = "memory",
        .start_line = 1,
        .end_line = 5,
        .text = text,
        .score = score,
        .vector_score = vector_score,
        .text_score = text_score,
    };
}

test "mergeHybridResults matches the Python docstring example" {
    const vec_rows = [_]types.RawSearchRow{testRow("id1", "vec text", 0.9, 0.9, null)};
    const kw_rows = [_]types.RawSearchRow{
        testRow("id1", "kw text", 0.6, null, 0.6),
        testRow("id2", "kw text 2", 0.8, null, 0.8),
    };

    const merged = try mergeHybridResults(std.testing.allocator, &vec_rows, &kw_rows, 0.7, 0.3, null);
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqualStrings("id1", merged[0].chunk_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.81), merged[0].score, 1e-12);
    try std.testing.expectEqualStrings("kw text", merged[0].text);
    try std.testing.expectEqualStrings("id2", merged[1].chunk_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.24), merged[1].score, 1e-12);
}

test "mergeHybridResults keeps the existing snippet when the keyword row's text is empty" {
    const vec_rows = [_]types.RawSearchRow{testRow("id1", "vector snippet", 0.9, 0.9, null)};
    const kw_rows = [_]types.RawSearchRow{testRow("id1", "", 0.6, null, 0.6)};

    const merged = try mergeHybridResults(std.testing.allocator, &vec_rows, &kw_rows, 0.7, 0.3, null);
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.81), merged[0].score, 1e-12);
    try std.testing.expectEqualStrings("vector snippet", merged[0].text);
}

test "mergeHybridResults treats a vector-only match with default weights" {
    const vec_rows = [_]types.RawSearchRow{testRow("idA", "t", 0.5, 0.5, null)};

    const merged = try mergeHybridResults(std.testing.allocator, &vec_rows, &.{}, 0.7, 0.3, null);
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.35), merged[0].score, 1e-12);
    try std.testing.expectEqual(@as(?f64, 0.5), merged[0].vector_score);
    try std.testing.expectEqual(@as(?f64, 0.0), merged[0].text_score);
}

test "mergeHybridResults truncates to limit after sorting" {
    const vec_rows = [_]types.RawSearchRow{
        testRow("id1", "t", 0.1, 0.1, null),
        testRow("id2", "t", 0.2, 0.2, null),
        testRow("id3", "t", 0.3, 0.3, null),
        testRow("id4", "t", 0.4, 0.4, null),
        testRow("id5", "t", 0.5, 0.5, null),
    };

    const merged = try mergeHybridResults(std.testing.allocator, &vec_rows, &.{}, 0.7, 0.3, 2);
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqualStrings("id5", merged[0].chunk_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.35), merged[0].score, 1e-12);
    try std.testing.expectEqualStrings("id4", merged[1].chunk_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.27999999999999997), merged[1].score, 1e-12);
}

test "mergeHybridResults honors custom weights" {
    const vec_rows = [_]types.RawSearchRow{testRow("id1", "t", 1.0, 1.0, null)};
    const kw_rows = [_]types.RawSearchRow{testRow("id1", "kw", 1.0, null, 1.0)};

    const merged = try mergeHybridResults(std.testing.allocator, &vec_rows, &kw_rows, 0.4, 0.6, null);
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), merged[0].score, 1e-12);
}
