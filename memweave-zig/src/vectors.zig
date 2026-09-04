//! Embedding vector utilities, ported from `memweave/embedding/vectors.py`.
//!
//! Vector similarity search itself is handled by sqlite-vec (a later
//! phase); this module only covers L2 normalization, applied before
//! storing embeddings so that cosine-distance queries need no extra
//! normalization step at query time.

const std = @import("std");

/// L2-normalize a vector to unit length, in place.
///
/// After normalization, `||v|| == 1.0`. If the vector is all zeros (zero
/// norm), it is left unchanged rather than dividing by zero — the caller
/// must handle that edge case (typically by discarding the chunk), mirroring
/// `normalize_embedding`'s "return vec unchanged if the norm is zero".
pub fn normalizeEmbedding(v: []f32) void {
    var sum_sq: f64 = 0.0;
    for (v) |x| sum_sq += @as(f64, x) * @as(f64, x);
    const norm = std.math.sqrt(sum_sq);
    if (norm == 0.0) return;

    for (v) |*x| x.* = @floatCast(@as(f64, x.*) / norm);
}

test "normalizeEmbedding([3,4]) matches the documented [0.6, 0.8] example" {
    var v = [_]f32{ 3.0, 4.0 };
    normalizeEmbedding(&v);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), v[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), v[1], 1e-6);
}

test "normalizeEmbedding result has unit L2 norm" {
    var v = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    normalizeEmbedding(&v);
    var sum_sq: f64 = 0.0;
    for (v) |x| sum_sq += @as(f64, x) * @as(f64, x);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sum_sq, 1e-6);
}

test "normalizeEmbedding leaves an all-zero vector unchanged" {
    var v = [_]f32{ 0.0, 0.0, 0.0 };
    normalizeEmbedding(&v);
    try std.testing.expectEqual(@as(f32, 0.0), v[0]);
    try std.testing.expectEqual(@as(f32, 0.0), v[1]);
    try std.testing.expectEqual(@as(f32, 0.0), v[2]);
}
