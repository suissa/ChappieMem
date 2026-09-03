//! Markdown chunking algorithm, ported line-for-line from
//! `memweave/chunking/markdown.py::chunk_markdown`.
//!
//! Line-boundary chunker with backward overlap: never splits mid-line
//! except for lines longer than `max_chars`, which are pre-split into
//! fixed-size segments. See the Python module's docstring for the full
//! algorithm write-up; this port follows it exactly, including the
//! `+1`-per-entry budget accounting (an intentional approximation of the
//! `"\n".join` separator cost, kept for parity) and the fact that an empty
//! `content` string still yields exactly one chunk with empty text —
//! confirmed against the real Python implementation, not just its
//! (slightly stale) docstring, by running `chunk_markdown("")` directly.
//!
//! Unlike Python, Zig has no default parameter values: callers must always
//! pass `chunk_tokens`/`chunk_overlap` explicitly (e.g. from
//! `config.ChunkingConfig{}.tokens` / `.overlap`).

const std = @import("std");

/// A single chunk produced by `chunkMarkdown`. `text` is heap-allocated
/// with the allocator passed to `chunkMarkdown` and owned by the caller —
/// free it (and the returned slice) via `freeChunks`.
pub const MarkdownChunk = struct {
    /// 1-indexed first line of this chunk in the source file.
    start_line: u32,
    /// 1-indexed last line of this chunk in the source file.
    end_line: u32,
    /// Raw chunk text (lines joined with '\n'). Owned by the caller.
    text: []const u8,
};

const Entry = struct {
    /// View into the original `content`; never owned/copied.
    text: []const u8,
    line_no: u32,
};

/// Split markdown text into overlapping chunks for embedding.
///
/// Character budgets: `max_chars = max(32, chunk_tokens * 4)`,
/// `overlap_chars = chunk_overlap * 4` (1 token ≈ 4 chars).
///
/// Caller owns the returned slice and every `.text` field within it —
/// see `freeChunks`.
pub fn chunkMarkdown(
    allocator: std.mem.Allocator,
    content: []const u8,
    chunk_tokens: u32,
    chunk_overlap: u32,
) ![]MarkdownChunk {
    const max_chars: u32 = @max(32, chunk_tokens * 4);
    const overlap_chars: u32 = chunk_overlap * 4;

    var chunks: std.ArrayList(MarkdownChunk) = .empty;
    errdefer {
        for (chunks.items) |c| allocator.free(c.text);
        chunks.deinit(allocator);
    }

    var current: std.ArrayList(Entry) = .empty;
    defer current.deinit(allocator);
    var current_chars: u32 = 0;

    // Mirrors Python's `content.split("\n")`: always at least one piece,
    // including a trailing empty piece if `content` ends with '\n'.
    var it = std.mem.splitScalar(u8, content, '\n');
    var line_no: u32 = 0;
    while (it.next()) |raw_line| {
        line_no += 1;

        if (raw_line.len == 0) {
            try processSegment(allocator, "", line_no, max_chars, overlap_chars, &current, &current_chars, &chunks);
            continue;
        }

        var start: usize = 0;
        while (start < raw_line.len) {
            const end = @min(start + max_chars, raw_line.len);
            try processSegment(allocator, raw_line[start..end], line_no, max_chars, overlap_chars, &current, &current_chars, &chunks);
            start = end;
        }
    }

    try flushCurrent(allocator, &current, &chunks);
    return chunks.toOwnedSlice(allocator);
}

/// Convenience wrapper mirroring `chunk_text` — chunk texts only, no line
/// numbers. Caller owns the returned slice and every string within it.
pub fn chunkText(
    allocator: std.mem.Allocator,
    content: []const u8,
    chunk_tokens: u32,
    chunk_overlap: u32,
) ![][]const u8 {
    const chunks = try chunkMarkdown(allocator, content, chunk_tokens, chunk_overlap);
    defer allocator.free(chunks);

    const texts = try allocator.alloc([]const u8, chunks.len);
    for (chunks, 0..) |c, i| texts[i] = c.text;
    return texts;
}

/// Frees every `.text` field then the slice itself. Use for values
/// returned by `chunkMarkdown`.
pub fn freeChunks(allocator: std.mem.Allocator, chunks: []MarkdownChunk) void {
    for (chunks) |c| allocator.free(c.text);
    allocator.free(chunks);
}

fn processSegment(
    allocator: std.mem.Allocator,
    segment: []const u8,
    line_no: u32,
    max_chars: u32,
    overlap_chars: u32,
    current: *std.ArrayList(Entry),
    current_chars: *u32,
    chunks: *std.ArrayList(MarkdownChunk),
) !void {
    // Each segment contributes (len + 1) chars to the budget — the "+1"
    // accounts for the '\n' that joining will add between lines.
    const line_size: u32 = @intCast(segment.len + 1);

    if (current_chars.* + line_size > max_chars and current.items.len > 0) {
        try flushCurrent(allocator, current, chunks);
        carryOverlap(current, overlap_chars, current_chars);
    }

    try current.append(allocator, .{ .text = segment, .line_no = line_no });
    current_chars.* += line_size;
}

fn flushCurrent(
    allocator: std.mem.Allocator,
    current: *std.ArrayList(Entry),
    chunks: *std.ArrayList(MarkdownChunk),
) !void {
    if (current.items.len == 0) return;

    const first_line_no = current.items[0].line_no;
    const last_line_no = current.items[current.items.len - 1].line_no;

    var total: usize = 0;
    for (current.items, 0..) |e, i| {
        total += e.text.len;
        if (i + 1 < current.items.len) total += 1; // '\n' separator
    }

    const text = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (current.items, 0..) |e, i| {
        @memcpy(text[pos .. pos + e.text.len], e.text);
        pos += e.text.len;
        if (i + 1 < current.items.len) {
            text[pos] = '\n';
            pos += 1;
        }
    }

    try chunks.append(allocator, .{ .start_line = first_line_no, .end_line = last_line_no, .text = text });
}

/// Retain the tail of `current` up to `overlap_chars` worth of content as
/// the seed for the next chunk (walking backward, inclusive of whichever
/// entry crosses the budget). Recomputes `current_chars` for the kept
/// entries, matching Python's `carry_overlap`.
fn carryOverlap(current: *std.ArrayList(Entry), overlap_chars: u32, current_chars: *u32) void {
    if (overlap_chars == 0 or current.items.len == 0) {
        current.clearRetainingCapacity();
        current_chars.* = 0;
        return;
    }

    var acc: u32 = 0;
    var keep_from: usize = current.items.len;
    var i: usize = current.items.len;
    while (i > 0) {
        i -= 1;
        acc += @intCast(current.items[i].text.len + 1);
        keep_from = i;
        if (acc >= overlap_chars) break;
    }

    const kept_len = current.items.len - keep_from;
    if (keep_from > 0) {
        std.mem.copyForwards(Entry, current.items[0..kept_len], current.items[keep_from..]);
    }
    current.shrinkRetainingCapacity(kept_len);

    var sum: u32 = 0;
    for (current.items) |e| sum += @intCast(e.text.len + 1);
    current_chars.* = sum;
}

// ── Tests — golden values obtained by running the real
// `memweave.chunking.markdown.chunk_markdown` in this same session, not
// just reasoning about the Python source. ──────────────────────────────

test "empty content yields exactly one chunk with empty text" {
    const chunks = try chunkMarkdown(std.testing.allocator, "", 400, 80);
    defer freeChunks(std.testing.allocator, chunks);

    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqual(@as(u32, 1), chunks[0].start_line);
    try std.testing.expectEqual(@as(u32, 1), chunks[0].end_line);
    try std.testing.expectEqualStrings("", chunks[0].text);
}

test "short two-line document fits in a single chunk" {
    const chunks = try chunkMarkdown(std.testing.allocator, "Hello world\nSecond line.", 100, 0);
    defer freeChunks(std.testing.allocator, chunks);

    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqual(@as(u32, 1), chunks[0].start_line);
    try std.testing.expectEqual(@as(u32, 2), chunks[0].end_line);
    try std.testing.expectEqualStrings("Hello world\nSecond line.", chunks[0].text);
}

test "long document splits into overlapping chunks matching the Python reference" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var i: u32 = 1;
    while (i <= 29) : (i += 1) {
        if (i > 1) try buf.append(std.testing.allocator, '\n');
        var tmp: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(&tmp, "Line {d}", .{i});
        try buf.appendSlice(std.testing.allocator, line);
    }

    // tokens=8 -> max_chars=32, overlap=2 -> overlap_chars=8
    const chunks = try chunkMarkdown(std.testing.allocator, buf.items, 8, 2);
    defer freeChunks(std.testing.allocator, chunks);

    try std.testing.expectEqual(@as(usize, 11), chunks.len);

    const expected_starts = [_]u32{ 1, 3, 5, 7, 10, 13, 16, 19, 22, 25, 28 };
    const expected_ends = [_]u32{ 4, 6, 8, 10, 13, 16, 19, 22, 25, 28, 29 };
    for (chunks, 0..) |c, idx| {
        try std.testing.expectEqual(expected_starts[idx], c.start_line);
        try std.testing.expectEqual(expected_ends[idx], c.end_line);
    }

    try std.testing.expectEqualStrings("Line 1\nLine 2\nLine 3\nLine 4", chunks[0].text);
    try std.testing.expectEqualStrings("Line 3\nLine 4\nLine 5\nLine 6", chunks[1].text);
    try std.testing.expectEqualStrings("Line 28\nLine 29", chunks[10].text);
}

test "a single line longer than max_chars is split into fixed-size segments" {
    const long_line = "a" ** 50;
    // tokens=1 -> max_chars=32 (floor)
    const chunks = try chunkMarkdown(std.testing.allocator, long_line, 1, 0);
    defer freeChunks(std.testing.allocator, chunks);

    try std.testing.expectEqual(@as(usize, 2), chunks.len);
    try std.testing.expectEqual(@as(u32, 1), chunks[0].start_line);
    try std.testing.expectEqual(@as(u32, 1), chunks[0].end_line);
    try std.testing.expectEqualStrings("a" ** 32, chunks[0].text);
    try std.testing.expectEqual(@as(u32, 1), chunks[1].start_line);
    try std.testing.expectEqualStrings("a" ** 18, chunks[1].text);
}

test "chunkText returns texts only, in the same order as chunkMarkdown" {
    const texts = try chunkText(std.testing.allocator, "a\nb", 100, 0);
    defer {
        for (texts) |t| std.testing.allocator.free(t);
        std.testing.allocator.free(texts);
    }
    try std.testing.expectEqual(@as(usize, 1), texts.len);
    try std.testing.expectEqualStrings("a\nb", texts[0]);
}

test "max_chars floors at 32 even for a tiny token budget" {
    const chunks = try chunkMarkdown(std.testing.allocator, "hi", 1, 0);
    defer freeChunks(std.testing.allocator, chunks);
    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqualStrings("hi", chunks[0].text);
}
