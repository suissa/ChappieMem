//! The work every suite runs.
//!
//! One place defines what "a unit of work" means, so load, stress, chaos,
//! sync and bench all exercise the same code and their numbers are
//! comparable. A unit drives every pure module the library currently
//! exposes — chunking, hashing, MMR re-ranking, temporal decay, vector
//! normalization, config validation — over one document.
//!
//! The unit returns a **digest**: a 64-bit fold of everything it computed.
//! That single number is what makes the other suites possible. The same
//! document must always produce the same digest, so a mismatch is proof of a
//! real defect and needs no golden file to detect:
//!
//!   * in `sync`, a digest that differs between threads means shared mutable
//!     state or a data race;
//!   * in `chaos`, a digest that survives injected allocation failure means
//!     an error path silently returned partial results;
//!   * in `load`, a digest that drifts over a long run means state leaking
//!     between iterations.
//!
//! The corpus is generated once, up front, from a seed, and is immutable
//! afterwards — which is also precisely the shape `sync` needs in order to
//! attribute any divergence to the library rather than to the fixture.

const std = @import("std");
const memweave = @import("memweave");

const chunking = memweave.chunking;
const hashing = memweave.hashing;
const mmr = memweave.mmr;
const decay = memweave.decay;
const vectors = memweave.vectors;
const types = memweave.types;
const forger = memweave.forger;

/// Chunking parameters used by every suite, taken from the shipped profile
/// so the workload tracks the library's real defaults.
pub const chunk_tokens: u32 = (forger.ChunkingConfig{}).tokens;
pub const chunk_overlap: u32 = (forger.ChunkingConfig{}).overlap;

/// Fixed seed for the per-unit digest. Not a knob: changing it changes every
/// digest at once, which would defeat the point of comparing them.
pub const unit_seed: u64 = 0x4D454D5745415645; // "MEMWEAVE"

/// Embedding width for the vector-normalization step. Small enough that a
/// unit stays dominated by chunking, which is the expensive part.
pub const embedding_dim: usize = 256;

// ---------------------------------------------------------------------------
// Digest
// ---------------------------------------------------------------------------

/// Order-sensitive fold of everything a unit computes.
pub const Digest = struct {
    hasher: std.hash.Wyhash,

    pub fn init(seed: u64) Digest {
        return .{ .hasher = std.hash.Wyhash.init(seed) };
    }

    pub fn bytes(self: *Digest, b: []const u8) void {
        self.hasher.update(b);
    }

    pub fn int(self: *Digest, v: anytype) void {
        self.hasher.update(std.mem.asBytes(&@as(u64, @intCast(v))));
    }

    /// Floats fold by bit pattern. NaN is canonicalized so a payload
    /// difference can never masquerade as a real divergence — none of the
    /// operations here should produce NaN in the first place.
    pub fn float(self: *Digest, v: f64) void {
        const canonical: u64 = if (std.math.isNan(v)) 0x7FF8_0000_0000_0000 else @bitCast(v);
        self.hasher.update(std.mem.asBytes(&canonical));
    }

    pub fn final(self: *Digest) u64 {
        return self.hasher.final();
    }
};

// ---------------------------------------------------------------------------
// Corpus
// ---------------------------------------------------------------------------

pub const Document = struct {
    name: []const u8,
    text: []const u8,
};

/// A deterministic set of markdown-ish documents. Identical seed and shape
/// give byte-identical documents on any machine.
pub const Corpus = struct {
    gpa: std.mem.Allocator,
    docs: []Document,

    pub fn generate(
        gpa: std.mem.Allocator,
        seed: u64,
        count: usize,
        avg_bytes: usize,
    ) !Corpus {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        const docs = try gpa.alloc(Document, count);
        errdefer gpa.free(docs);

        var made: usize = 0;
        errdefer for (docs[0..made]) |d| {
            gpa.free(d.name);
            gpa.free(d.text);
        };

        while (made < count) : (made += 1) {
            // Sizes vary by ±50% so the latency distribution has a real
            // spread rather than a single spike.
            const spread = avg_bytes / 2;
            const size = avg_bytes - spread + rand.uintLessThan(usize, @max(1, spread * 2));
            const name = try std.fmt.allocPrint(gpa, "memory/2024-{d:0>2}-{d:0>2}-note-{d}.md", .{
                1 + rand.uintLessThan(u32, 12),
                1 + rand.uintLessThan(u32, 28),
                made,
            });
            errdefer gpa.free(name);
            docs[made] = .{ .name = name, .text = try markdownDoc(gpa, rand, size) };
        }

        return .{ .gpa = gpa, .docs = docs };
    }

    pub fn deinit(self: *Corpus) void {
        for (self.docs) |d| {
            self.gpa.free(d.name);
            self.gpa.free(d.text);
        }
        self.gpa.free(self.docs);
    }

    pub fn totalBytes(self: Corpus) usize {
        var n: usize = 0;
        for (self.docs) |d| n += d.text.len;
        return n;
    }
};

const words = [_][]const u8{
    "memory",    "context",  "retrieval", "embedding", "chunk",   "vector",   "index",
    "workspace", "decay",    "rerank",    "hybrid",    "sqlite",  "markdown", "token",
    "overlap",   "snippet",  "evergreen", "flush",     "profile", "schema",   "behaviour",
    "cascade",   "manifest", "comptime",  "allocator", "digest",  "corpus",   "threshold",
};

/// A document with the structural variety a real markdown corpus has:
/// headings, prose, lists, fenced code, blank lines, a very long line, and
/// some multi-byte text.
fn markdownDoc(gpa: std.mem.Allocator, rand: std.Random, target_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "# ");
    try appendWords(gpa, &out, rand, 4);
    try out.appendSlice(gpa, "\n\n");

    while (out.items.len < target_bytes) {
        switch (rand.uintLessThan(u8, 10)) {
            0 => {
                try out.appendSlice(gpa, "## ");
                try appendWords(gpa, &out, rand, 3);
                try out.appendSlice(gpa, "\n\n");
            },
            1 => {
                // A fenced code block — no blank lines, so it stresses the
                // chunker's line-budget accounting rather than its splitting.
                try out.appendSlice(gpa, "```zig\n");
                var i: usize = 0;
                while (i < 4) : (i += 1) {
                    try out.appendSlice(gpa, "    const ");
                    try appendWords(gpa, &out, rand, 1);
                    try out.appendSlice(gpa, " = 42;\n");
                }
                try out.appendSlice(gpa, "```\n\n");
            },
            2 => {
                var i: usize = 0;
                while (i < 3 + rand.uintLessThan(usize, 4)) : (i += 1) {
                    try out.appendSlice(gpa, "- ");
                    try appendWords(gpa, &out, rand, 5 + rand.uintLessThan(usize, 6));
                    try out.append(gpa, '\n');
                }
                try out.append(gpa, '\n');
            },
            3 => {
                // One line far longer than any chunk budget, which forces the
                // fixed-size pre-split path.
                try appendWords(gpa, &out, rand, 400);
                try out.appendSlice(gpa, "\n\n");
            },
            4 => {
                // Multi-byte text: the chunker splits on byte budgets, so
                // this is where a naive change would corrupt a code point.
                try out.appendSlice(gpa, "Nota — acentuação, emoji 🧠, e ideogramas 記憶.\n\n");
            },
            else => {
                try appendWords(gpa, &out, rand, 12 + rand.uintLessThan(usize, 30));
                try out.appendSlice(gpa, "\n\n");
            },
        }
    }

    return out.toOwnedSlice(gpa);
}

fn appendWords(gpa: std.mem.Allocator, out: *std.ArrayList(u8), rand: std.Random, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, words[rand.uintLessThan(usize, words.len)]);
    }
}

// ---------------------------------------------------------------------------
// Adversarial inputs
// ---------------------------------------------------------------------------

pub const Adversary = enum {
    /// Not a single newline: the whole document is one line.
    no_newlines,
    /// Nothing but newlines: every line is empty.
    all_newlines,
    /// Uniformly random bytes, including NUL and invalid UTF-8.
    random_bytes,
    /// The same line repeated, which is the worst case for MMR's pairwise
    /// similarity and for overlap accounting.
    repeated_line,
    /// Windows line endings throughout.
    crlf,
    /// Dense multi-byte text, so byte budgets land mid-code-point.
    multibyte,

    pub fn all() []const Adversary {
        return &.{ .no_newlines, .all_newlines, .random_bytes, .repeated_line, .crlf, .multibyte };
    }
};

/// A pathological document of roughly `target_bytes`. Caller owns it.
pub fn adversarialDoc(
    gpa: std.mem.Allocator,
    rand: std.Random,
    kind: Adversary,
    target_bytes: usize,
) ![]u8 {
    switch (kind) {
        .no_newlines => {
            const buf = try gpa.alloc(u8, target_bytes);
            for (buf) |*c| c.* = 'a' + @as(u8, @intCast(rand.uintLessThan(u8, 26)));
            return buf;
        },
        .all_newlines => {
            const buf = try gpa.alloc(u8, target_bytes);
            @memset(buf, '\n');
            return buf;
        },
        .random_bytes => {
            const buf = try gpa.alloc(u8, target_bytes);
            rand.bytes(buf);
            return buf;
        },
        .repeated_line => {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            while (out.items.len < target_bytes) {
                try out.appendSlice(gpa, "the same line over and over again\n");
            }
            return out.toOwnedSlice(gpa);
        },
        .crlf => {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            while (out.items.len < target_bytes) {
                try out.appendSlice(gpa, "a line that ends the Windows way\r\n");
            }
            return out.toOwnedSlice(gpa);
        },
        .multibyte => {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            while (out.items.len < target_bytes) {
                try out.appendSlice(gpa, "記憶の断片 — 🧠🧩🔍 acentuação\n");
            }
            return out.toOwnedSlice(gpa);
        },
    }
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

/// The individual steps, exposed separately so `bench` can time each one and
/// `chaos` can inject failure into each one independently.
pub const ops = struct {
    /// Split the document and fold the chunk boundaries and texts.
    pub fn chunk(gpa: std.mem.Allocator, text: []const u8, d: *Digest) !void {
        const chunks = try chunking.chunkMarkdown(gpa, text, chunk_tokens, chunk_overlap);
        defer chunking.freeChunks(gpa, chunks);

        d.int(chunks.len);
        for (chunks) |c| {
            d.int(c.start_line);
            d.int(c.end_line);
            d.bytes(c.text);
        }
    }

    /// Content hash of the document plus a chunk id per chunk.
    pub fn identify(gpa: std.mem.Allocator, path: []const u8, text: []const u8, d: *Digest) !void {
        const content_hash = hashing.sha256Text(text);
        d.bytes(&content_hash);

        const chunks = try chunking.chunkMarkdown(gpa, text, chunk_tokens, chunk_overlap);
        defer chunking.freeChunks(gpa, chunks);

        for (chunks) |c| {
            const id = try hashing.makeChunkId(gpa, "workspace", path, c.start_line, c.end_line, &content_hash, "text-embedding-3-small");
            d.bytes(&id);
        }

        const provider = try hashing.makeProviderKey(gpa, "litellm", "text-embedding-3-small", null);
        d.bytes(&provider);
    }

    /// Re-rank the document's own chunks as if they were search hits. This
    /// is the quadratic step, and the one that allocates most per candidate.
    pub fn rerank(gpa: std.mem.Allocator, path: []const u8, text: []const u8, d: *Digest) !void {
        const chunks = try chunking.chunkMarkdown(gpa, text, chunk_tokens, chunk_overlap);
        defer chunking.freeChunks(gpa, chunks);

        const candidates = @min(chunks.len, 24);
        const rows = try gpa.alloc(types.RawSearchRow, candidates);
        defer gpa.free(rows);

        for (rows, chunks[0..candidates], 0..) |*row, c, i| {
            row.* = .{
                .chunk_id = path,
                .path = path,
                .source = "workspace",
                .start_line = c.start_line,
                .end_line = c.end_line,
                .text = c.text,
                // A descending, deterministic relevance ladder.
                .score = 1.0 - (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(candidates + 1))),
            };
        }

        const ranked = try mmr.mmrRerank(gpa, rows, (forger.MMRConfig{}).lambda_param);
        defer gpa.free(ranked);

        for (ranked) |r| {
            d.int(r.start_line);
            d.int(r.end_line);
            d.float(r.score);
        }
    }

    /// Date extraction and the exponential age penalty.
    pub fn age(path: []const u8, d: *Digest) void {
        const now: decay.Date = .{ .year = 2026, .month = 9, .day = 7 };
        const half_life = (forger.TemporalDecayConfig{}).half_life_days;

        d.int(@intFromBool(decay.isEvergreenPath(path)));
        if (decay.parseDateFromPath(path)) |file_date| {
            const age_days = decay.ageInDays(file_date, now);
            d.float(age_days);
            d.float(decay.calculateDecayMultiplier(age_days, half_life));
            d.float(decay.applyDecayToScore(0.87, age_days, half_life));
        } else {
            d.int(0);
        }
    }

    /// Derive an embedding from the document bytes and normalize it, the way
    /// the indexer will before handing vectors to sqlite-vec.
    pub fn normalize(gpa: std.mem.Allocator, text: []const u8, dim: usize, d: *Digest) !void {
        const vec = try gpa.alloc(f32, dim);
        defer gpa.free(vec);

        // A cheap deterministic projection of the text into `dim` buckets.
        @memset(vec, 0);
        for (text, 0..) |byte, i| {
            vec[i % dim] += @as(f32, @floatFromInt(byte % 17)) - 8.0;
        }

        vectors.normalizeEmbedding(vec);
        for (vec) |v| d.float(v);
    }

    /// Validate the full composed configuration, cascading through every
    /// behaviour the factory generated.
    pub fn validateConfig(d: *Digest) void {
        const cfg: forger.MemoryConfig = .{};
        if (forger.Memory.validate(cfg)) {
            d.int(1);
        } else |_| {
            d.int(0);
        }
        // A configuration that must be rejected, so the digest also covers
        // the failure path.
        if (forger.Memory.validate(.{ .chunking = .{ .tokens = 4, .overlap = 9 } })) {
            d.int(2);
        } else |_| {
            d.int(3);
        }
    }
};

/// One unit of work: every operation, over one document, folded into a
/// digest. Frees everything it allocates, including on the error path — that
/// is what makes the chaos suite's leak assertions meaningful.
pub fn runUnit(gpa: std.mem.Allocator, doc: Document) !u64 {
    var d = Digest.init(unit_seed);
    try ops.chunk(gpa, doc.text, &d);
    try ops.identify(gpa, doc.name, doc.text, &d);
    try ops.rerank(gpa, doc.name, doc.text, &d);
    ops.age(doc.name, &d);
    try ops.normalize(gpa, doc.text, embedding_dim, &d);
    ops.validateConfig(&d);
    return d.final();
}

/// Digest of the whole corpus: every unit, folded in order. The number every
/// suite compares against.
pub fn runCorpus(gpa: std.mem.Allocator, corpus: Corpus) !u64 {
    var d = Digest.init(0);
    for (corpus.docs) |doc| d.int(try runUnit(gpa, doc));
    return d.final();
}

// ---------------------------------------------------------------------------
// Invariants
// ---------------------------------------------------------------------------
//
// Properties that must hold for any input, shared by the suites that assert
// them: `stress` checks them as it escalates, `chaos` checks them on random
// and malformed input.

/// Structural properties that hold for *any* input, at any chunk budget.
/// Returns a description of the first violation, or null when the output is
/// well formed.
pub fn chunkInvariants(
    chunks: []const chunking.MarkdownChunk,
    source: []const u8,
    tokens: u32,
    overlap: u32,
) ?[]const u8 {
    if (chunks.len == 0) return "no chunks produced (even empty content must yield one)";
    if (chunks[0].start_line != 1) return "the first chunk does not start at line 1";

    // `content.split("\n")` always yields at least one piece.
    var line_count: u32 = 1;
    for (source) |c| {
        if (c == '\n') line_count += 1;
    }

    // Ceiling on a single chunk, derived from the algorithm rather than
    // guessed. `processSegment` appends unconditionally, so a chunk is at
    // most: whatever `carryOverlap` retained (it stops as soon as the
    // accumulator reaches `overlap_chars`, and the entry that crosses that
    // line is kept whole, so at most `overlap_chars + max_entry`), plus the
    // one entry appended afterwards. An entry is at most `max_chars + 1`
    // because over-long lines are pre-split to `max_chars`.
    const max_chars: usize = @max(32, @as(usize, tokens) * 4);
    const overlap_chars: usize = @as(usize, overlap) * 4;
    const max_entry = max_chars + 1;
    const chunk_ceiling = overlap_chars + 2 * max_entry;

    var previous = chunks[0];
    for (chunks, 0..) |c, i| {
        if (c.end_line < c.start_line) return "a chunk ends before it starts";
        if (c.start_line == 0) return "line numbers are 1-indexed, found 0";
        if (c.end_line > line_count) return "a chunk ends past the last line of the document";
        if (c.text.len > chunk_ceiling) return "a chunk exceeds the derived size ceiling";
        if (i > 0) {
            if (c.start_line < previous.start_line) return "chunk start lines are not non-decreasing";
            if (c.end_line < previous.end_line) return "chunk end lines are not non-decreasing";
            if (c.start_line > previous.end_line + 1) return "consecutive chunks leave a gap in line coverage";
        }
        previous = c;
    }

    if (previous.end_line != line_count) return "the last chunk does not end on the document's last line";
    return null;
}

pub fn widestChunk(chunks: []const chunking.MarkdownChunk) usize {
    var widest: usize = 0;
    for (chunks) |c| widest = @max(widest, c.text.len);
    return widest;
}

/// Re-ranking must return exactly the rows it was given, in some order.
/// Rows are identified by `start_line`, which the caller makes unique.
pub fn permutationViolation(
    gpa: std.mem.Allocator,
    input: []const types.RawSearchRow,
    output: []const types.RawSearchRow,
) !?[]const u8 {
    if (input.len != output.len) return "re-ranking changed the number of rows";

    const seen = try gpa.alloc(bool, input.len);
    defer gpa.free(seen);
    @memset(seen, false);

    for (output) |row| {
        if (row.start_line == 0 or row.start_line > input.len) return "re-ranking invented a row";
        const idx = row.start_line - 1;
        if (seen[idx]) return "re-ranking duplicated a row";
        seen[idx] = true;
    }
    for (seen) |s| {
        if (!s) return "re-ranking dropped a row";
    }
    return null;
}
