//! Maximal Marginal Relevance (MMR) re-ranking, ported from
//! `memweave/search/mmr.py`.
//!
//! MMR balances relevance with diversity: at each step, the algorithm
//! selects the candidate that maximizes
//!
//!     MMR = λ × normalized_relevance − (1−λ) × max_jaccard_similarity_to_selected
//!
//! Reference: Carbonell & Goldstein, "The Use of MMR, Diversity-Based
//! Reranking" (1998).
//!
//! Only the pure algorithm (`mmr_rerank` and its helpers) is ported here;
//! the `MMRReranker` `PostProcessor` wrapper is a search-pipeline concern
//! deferred to a later phase.

const std = @import("std");
const types = @import("types.zig");

fn isWordByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn toLowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

/// A deduplicated set of lowercase tokens, owned by the allocator passed
/// to `tokenizeForMmr`. Free with `deinit`.
pub const TokenSet = struct {
    tokens: [][]const u8,

    pub fn deinit(self: *TokenSet, allocator: std.mem.Allocator) void {
        for (self.tokens) |t| allocator.free(t);
        allocator.free(self.tokens);
        self.tokens = &[_][]const u8{};
    }

    pub fn contains(self: TokenSet, token: []const u8) bool {
        for (self.tokens) |t| {
            if (std.mem.eql(u8, t, token)) return true;
        }
        return false;
    }
};

/// Extract lowercase alphanumeric+underscore tokens from text, mirroring
/// `tokenize_for_mmr` (`[a-z0-9_]+` over `text.lower()`, deduplicated).
pub fn tokenizeForMmr(allocator: std.mem.Allocator, text: []const u8) !TokenSet {
    var tokens: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (tokens.items) |t| allocator.free(t);
        tokens.deinit(allocator);
    }

    var i: usize = 0;
    while (i < text.len) {
        if (!isWordByte(text[i])) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < text.len and isWordByte(text[j])) : (j += 1) {}

        const raw = text[i..j];
        const lowered = try allocator.alloc(u8, raw.len);
        for (raw, 0..) |c, k| lowered[k] = toLowerAscii(c);

        var dup = false;
        for (tokens.items) |t| {
            if (std.mem.eql(u8, t, lowered)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            allocator.free(lowered);
        } else {
            try tokens.append(allocator, lowered);
        }
        i = j;
    }

    return TokenSet{ .tokens = try tokens.toOwnedSlice(allocator) };
}

/// `|A ∩ B| / |A ∪ B|`. Both empty → 1.0 (identical empty sets). One
/// empty → 0.0 (no overlap possible).
pub fn jaccardSimilarity(a: TokenSet, b: TokenSet) f64 {
    if (a.tokens.len == 0 and b.tokens.len == 0) return 1.0;
    if (a.tokens.len == 0 or b.tokens.len == 0) return 0.0;

    var intersection: usize = 0;
    for (a.tokens) |t| {
        if (b.contains(t)) intersection += 1;
    }
    const uni = a.tokens.len + b.tokens.len - intersection;
    if (uni == 0) return 0.0;
    return @as(f64, @floatFromInt(intersection)) / @as(f64, @floatFromInt(uni));
}

/// `λ × relevance − (1−λ) × max_similarity`.
pub fn computeMmrScore(relevance: f64, max_similarity: f64, lam: f64) f64 {
    return lam * relevance - (1.0 - lam) * max_similarity;
}

fn scoreDesc(_: void, a: types.RawSearchRow, b: types.RawSearchRow) bool {
    return a.score > b.score;
}

/// Re-rank rows using Maximal Marginal Relevance, mirroring `mmr_rerank`.
///
/// Early exits: `rows.len <= 1` → unchanged copy; `lam` clamped to
/// `[0,1]`, and `== 1.0` → pure score-descending order (diversity
/// computation skipped entirely). Otherwise: greedy incremental selection,
/// each step picking the remaining candidate with the highest MMR score
/// (ties broken by higher raw score).
///
/// Caller owns the returned slice (`allocator.free` it); the row *values*
/// are copies (cheap — `RawSearchRow` holds slices, not owned buffers), so
/// no per-row cleanup is needed beyond freeing the returned slice itself.
pub fn mmrRerank(allocator: std.mem.Allocator, rows: []const types.RawSearchRow, lam: f64) ![]types.RawSearchRow {
    if (rows.len <= 1) {
        const out = try allocator.alloc(types.RawSearchRow, rows.len);
        @memcpy(out, rows);
        return out;
    }

    const clamped_lam = std.math.clamp(lam, 0.0, 1.0);

    if (clamped_lam == 1.0) {
        const out = try allocator.alloc(types.RawSearchRow, rows.len);
        @memcpy(out, rows);
        std.mem.sort(types.RawSearchRow, out, {}, scoreDesc);
        return out;
    }

    const token_sets = try allocator.alloc(TokenSet, rows.len);
    defer {
        for (token_sets) |*ts| ts.deinit(allocator);
        allocator.free(token_sets);
    }
    for (rows, 0..) |r, idx| {
        token_sets[idx] = try tokenizeForMmr(allocator, r.text);
    }

    var max_score = rows[0].score;
    var min_score = rows[0].score;
    for (rows) |r| {
        if (r.score > max_score) max_score = r.score;
        if (r.score < min_score) min_score = r.score;
    }
    const score_range = max_score - min_score;

    var remaining: std.ArrayList(usize) = .empty;
    defer remaining.deinit(allocator);
    for (0..rows.len) |idx| try remaining.append(allocator, idx);

    var selected: std.ArrayList(usize) = .empty;
    defer selected.deinit(allocator);

    while (remaining.items.len > 0) {
        var best_pos: usize = 0;
        var best_mmr: f64 = -std.math.inf(f64);
        var best_score: f64 = -std.math.inf(f64);

        for (remaining.items, 0..) |cand_idx, pos| {
            const norm_rel = if (score_range == 0.0) 1.0 else (rows[cand_idx].score - min_score) / score_range;

            var max_sim: f64 = 0.0;
            for (selected.items) |sel_idx| {
                const sim = jaccardSimilarity(token_sets[cand_idx], token_sets[sel_idx]);
                if (sim > max_sim) max_sim = sim;
            }

            const mmr = computeMmrScore(norm_rel, max_sim, clamped_lam);
            if (mmr > best_mmr or (mmr == best_mmr and rows[cand_idx].score > best_score)) {
                best_mmr = mmr;
                best_score = rows[cand_idx].score;
                best_pos = pos;
            }
        }

        const chosen = remaining.orderedRemove(best_pos);
        try selected.append(allocator, chosen);
    }

    const out = try allocator.alloc(types.RawSearchRow, rows.len);
    for (selected.items, 0..) |idx, i| out[i] = rows[idx];
    return out;
}

// ── Tests — golden values obtained by running the real
// `memweave.search.mmr` module directly in this same session. ───────────

test "jaccardSimilarity: empty/empty=1.0, one-empty=0.0, partial overlap" {
    var empty1 = try tokenizeForMmr(std.testing.allocator, "");
    defer empty1.deinit(std.testing.allocator);
    var empty2 = try tokenizeForMmr(std.testing.allocator, "!!! ...");
    defer empty2.deinit(std.testing.allocator);
    var a = try tokenizeForMmr(std.testing.allocator, "a");
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(f64, 1.0), jaccardSimilarity(empty1, empty2));
    try std.testing.expectEqual(@as(f64, 0.0), jaccardSimilarity(a, empty1));

    var ab = try tokenizeForMmr(std.testing.allocator, "a b");
    defer ab.deinit(std.testing.allocator);
    var bc = try tokenizeForMmr(std.testing.allocator, "b c");
    defer bc.deinit(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3333333333333333), jaccardSimilarity(ab, bc), 1e-12);
}

test "computeMmrScore matches lam*relevance - (1-lam)*similarity" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.4099999999999999), computeMmrScore(0.8, 0.5, 0.7), 1e-12);
    try std.testing.expectEqual(@as(f64, 0.8), computeMmrScore(0.8, 0.5, 1.0));
    try std.testing.expectEqual(@as(f64, -0.5), computeMmrScore(0.8, 0.5, 0.0));
}

test "tokenizeForMmr lowercases and dedups alphanumeric+underscore runs" {
    var ts = try tokenizeForMmr(std.testing.allocator, "PostgreSQL connection_pooling! 123");
    defer ts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), ts.tokens.len);
    try std.testing.expect(ts.contains("postgresql"));
    try std.testing.expect(ts.contains("connection_pooling"));
    try std.testing.expect(ts.contains("123"));
}

fn row(chunk_id: []const u8, text: []const u8, score: f64) types.RawSearchRow {
    return .{
        .chunk_id = chunk_id,
        .path = "x.md",
        .source = "memory",
        .start_line = 1,
        .end_line = 1,
        .text = text,
        .score = score,
    };
}

test "mmrRerank lam=1.0 is pure score-descending order" {
    const rows = [_]types.RawSearchRow{
        row("1", "apple banana cherry", 0.9),
        row("2", "apple banana cherry duplicate", 0.85),
        row("3", "completely different unique words here", 0.5),
    };
    const out = try mmrRerank(std.testing.allocator, &rows, 1.0);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("1", out[0].chunk_id);
    try std.testing.expectEqualStrings("2", out[1].chunk_id);
    try std.testing.expectEqualStrings("3", out[2].chunk_id);
}

test "mmrRerank lam=0.0 prefers the distinct row second, not the near-duplicate" {
    const rows = [_]types.RawSearchRow{
        row("1", "apple banana cherry", 0.9),
        row("2", "apple banana cherry duplicate", 0.85),
        row("3", "completely different unique words here", 0.5),
    };
    const out = try mmrRerank(std.testing.allocator, &rows, 0.0);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("1", out[0].chunk_id);
    try std.testing.expectEqualStrings("3", out[1].chunk_id);
    try std.testing.expectEqualStrings("2", out[2].chunk_id);
}

test "mmrRerank clamps lam below 0 the same as lam=0.0" {
    const rows = [_]types.RawSearchRow{
        row("1", "apple banana cherry", 0.9),
        row("2", "apple banana cherry duplicate", 0.85),
        row("3", "completely different unique words here", 0.5),
    };
    const out = try mmrRerank(std.testing.allocator, &rows, -1.0);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("1", out[0].chunk_id);
    try std.testing.expectEqualStrings("3", out[1].chunk_id);
    try std.testing.expectEqualStrings("2", out[2].chunk_id);
}

test "mmrRerank: single row and empty input pass through unchanged" {
    const one = [_]types.RawSearchRow{row("1", "hello", 0.5)};
    const out1 = try mmrRerank(std.testing.allocator, &one, 0.5);
    defer std.testing.allocator.free(out1);
    try std.testing.expectEqual(@as(usize, 1), out1.len);

    const out2 = try mmrRerank(std.testing.allocator, &.{}, 0.5);
    defer std.testing.allocator.free(out2);
    try std.testing.expectEqual(@as(usize, 0), out2.len);
}
