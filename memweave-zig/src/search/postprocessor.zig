//! Search result post-processors, ported from `memweave/search/postprocessor.py`.
//!
//! Python composes post-processors through a duck-typed `PostProcessor`
//! protocol pipeline. Zig has no equivalent runtime-polymorphism idiom
//! worth reaching for here, so each processor is just a plain function over
//! `[]RawSearchRow` — callers compose the pipeline by calling them in
//! sequence. `MMRReranker`/`TemporalDecayProcessor`-equivalent behavior is
//! already available directly as `mmr.mmrRerank` and the `decay.zig`
//! functions from Phase 1; no separate adapter wrapper is needed here.

const std = @import("std");
const types = @import("../types.zig");

/// Filter out rows whose score falls below `min_score` (mirrors
/// `ScoreThreshold.apply`). Returns a caller-owned slice; the input slice
/// is not modified or freed.
pub fn scoreThreshold(
    allocator: std.mem.Allocator,
    rows: []const types.RawSearchRow,
    min_score: f64,
) ![]types.RawSearchRow {
    var out: std.ArrayList(types.RawSearchRow) = .empty;
    errdefer out.deinit(allocator);

    for (rows) |row| {
        if (row.score >= min_score) try out.append(allocator, row);
    }
    return out.toOwnedSlice(allocator);
}

test "scoreThreshold keeps only rows at or above the minimum score" {
    const rows = [_]types.RawSearchRow{
        .{ .chunk_id = "a", .path = "p", .source = "memory", .start_line = 1, .end_line = 1, .text = "", .score = 0.9 },
        .{ .chunk_id = "b", .path = "p", .source = "memory", .start_line = 1, .end_line = 1, .text = "", .score = 0.35 },
        .{ .chunk_id = "c", .path = "p", .source = "memory", .start_line = 1, .end_line = 1, .text = "", .score = 0.1 },
    };

    const kept = try scoreThreshold(std.testing.allocator, &rows, 0.35);
    defer std.testing.allocator.free(kept);

    try std.testing.expectEqual(@as(usize, 2), kept.len);
    try std.testing.expectEqualStrings("a", kept[0].chunk_id);
    try std.testing.expectEqualStrings("b", kept[1].chunk_id);
}

test "scoreThreshold returns an empty slice when nothing passes" {
    const rows = [_]types.RawSearchRow{
        .{ .chunk_id = "a", .path = "p", .source = "memory", .start_line = 1, .end_line = 1, .text = "", .score = 0.1 },
    };

    const kept = try scoreThreshold(std.testing.allocator, &rows, 0.5);
    defer std.testing.allocator.free(kept);

    try std.testing.expectEqual(@as(usize, 0), kept.len);
}
