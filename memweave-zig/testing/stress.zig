//! Stress: how does the library behave as pressure escalates past what any
//! reasonable workload would ask of it?
//!
//! Load asks "is it still correct at volume". Stress asks "where does it
//! break, and does it break *cleanly*". Every case here escalates one
//! dimension until it hits a documented limit, and the assertion is always
//! the same shape: the structural invariants must still hold, and running
//! out of resources must surface as `error.OutOfMemory` rather than as a
//! crash, a truncated result, or a silent wrong answer.
//!
//! Five dimensions are pushed:
//!
//!   1. document size, doubling to `--max-doc-bytes`;
//!   2. chunk budgets, including the degenerate ones (a 1-token chunk, an
//!      overlap one token below the chunk size, a chunk larger than the
//!      whole document);
//!   3. document *shape* — no newlines at all, nothing but newlines, random
//!      bytes, dense multi-byte text, CRLF;
//!   4. MMR candidate count, which is the quadratic step;
//!   5. available memory, capped hard so the allocator starts refusing.
//!
//! The chunk invariants asserted at every step are the ones that hold for
//! any input: at least one chunk, line numbers starting at 1, each chunk's
//! range non-empty and non-decreasing, consecutive chunks leaving no gap in
//! line coverage, and the last chunk ending on the document's last line.

const std = @import("std");
const memweave = @import("memweave");
const report = @import("report.zig");
const workload = @import("workload.zig");
const store_workload = @import("store.zig");

const chunking = memweave.chunking;
const mmr = memweave.mmr;
const types = memweave.types;

const Tunables = struct {
    min_doc_bytes: usize = 4 * 1024,
    max_doc_bytes: usize = 16 * 1024 * 1024,
    adversarial_bytes: usize = 512 * 1024,
    max_candidates: usize = 512,
    /// Byte ceiling for the "runs out of memory cleanly" case.
    memory_limit_bytes: usize = 64 * 1024,
    /// Largest document pushed through a real index-and-search cycle.
    max_indexed_bytes: usize = 512 * 1024,
};

const Params = struct {
    seed: u64,
    scale: f64,
    min_doc_bytes: usize,
    max_doc_bytes: usize,
    adversarial_bytes: usize,
    max_candidates: usize,
    memory_limit_bytes: usize,
    largest_document_handled_bytes: usize,
    most_candidates_handled: usize,
    max_indexed_bytes: usize,
    largest_indexed_bytes: usize,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var tunables: Tunables = .{};
    const options = try report.Options.parseWith(args, &tunables);

    const max_doc_bytes = options.sized(tunables.max_doc_bytes);
    const adversarial_bytes = options.sized(tunables.adversarial_bytes);
    const max_candidates = options.sized(tunables.max_candidates);

    var gpa_state: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const gpa = gpa_state.allocator();

    var builder = report.Builder.init(init.gpa, io, "stress", "stress");
    defer builder.deinit();

    var prng = std.Random.DefaultPrng.init(options.seed);
    const rand = prng.random();

    std.debug.print("stress: up to {d} KiB documents, {d} candidates (seed 0x{X})\n", .{
        max_doc_bytes / 1024,
        max_candidates,
        options.seed,
    });

    var largest_handled: usize = 0;
    var most_candidates: usize = 0;

    // ---- 1. Document size --------------------------------------------------

    var size = tunables.min_doc_bytes;
    while (size <= max_doc_bytes) : (size *= 2) {
        const doc = try workload.adversarialDoc(gpa, rand, .repeated_line, size);
        defer gpa.free(doc);

        const before = gpa_state.total_requested_bytes;
        const sw = report.Stopwatch.begin(io);
        const chunks = try chunking.chunkMarkdown(gpa, doc, workload.chunk_tokens, workload.chunk_overlap);
        const elapsed_ms = sw.elapsedMs();
        defer chunking.freeChunks(gpa, chunks);

        const peak = gpa_state.total_requested_bytes - before;
        const violation = workload.chunkInvariants(chunks, doc, workload.chunk_tokens, workload.chunk_overlap);
        if (violation == null) largest_handled = @max(largest_handled, doc.len);

        try builder.check(
            try builder.fmt("chunking holds its invariants at {d} KiB", .{doc.len / 1024}),
            violation == null,
            violation orelse "",
            elapsed_ms,
            &.{
                .{ .name = "document_bytes", .value = @floatFromInt(doc.len), .unit = "bytes" },
                .{ .name = "chunks", .value = @floatFromInt(chunks.len), .unit = "count" },
                .{ .name = "widest_chunk_bytes", .value = @floatFromInt(workload.widestChunk(chunks)), .unit = "bytes" },
                .{ .name = "chunk_bytes", .value = @floatFromInt(peak), .unit = "bytes" },
                .{
                    .name = "expansion_ratio",
                    .value = @as(f64, @floatFromInt(peak)) / @as(f64, @floatFromInt(doc.len)),
                    .unit = "ratio",
                },
            },
        );
    }

    // ---- 2. Degenerate chunk budgets --------------------------------------

    // Freed explicitly at the end, before the leak check — see load.zig.
    const budget_doc = try workload.adversarialDoc(gpa, rand, .repeated_line, 256 * 1024);

    const budgets = [_]struct { tokens: u32, overlap: u32, why: []const u8 }{
        .{ .tokens = 1, .overlap = 0, .why = "smallest possible budget (max_chars floors at 32)" },
        .{ .tokens = 2, .overlap = 1, .why = "overlap one below a tiny chunk" },
        .{ .tokens = 400, .overlap = 399, .why = "maximum legal overlap" },
        .{ .tokens = 1_000_000, .overlap = 0, .why = "chunk larger than the whole document" },
        .{ .tokens = 400, .overlap = 0, .why = "no overlap at all" },
    };

    for (budgets) |budget| {
        const sw = report.Stopwatch.begin(io);
        const chunks = try chunking.chunkMarkdown(gpa, budget_doc, budget.tokens, budget.overlap);
        const elapsed_ms = sw.elapsedMs();
        defer chunking.freeChunks(gpa, chunks);

        const violation = workload.chunkInvariants(chunks, budget_doc, budget.tokens, budget.overlap);
        try builder.check(
            try builder.fmt("tokens={d} overlap={d}: {s}", .{ budget.tokens, budget.overlap, budget.why }),
            violation == null,
            violation orelse "",
            elapsed_ms,
            &.{
                .{ .name = "chunks", .value = @floatFromInt(chunks.len), .unit = "count" },
                .{ .name = "tokens", .value = @floatFromInt(budget.tokens), .unit = "count" },
                .{ .name = "overlap", .value = @floatFromInt(budget.overlap), .unit = "count" },
            },
        );
    }

    // ---- 3. Adversarial document shapes ------------------------------------

    for (workload.Adversary.all()) |kind| {
        const doc = try workload.adversarialDoc(gpa, rand, kind, adversarial_bytes);
        defer gpa.free(doc);

        const sw = report.Stopwatch.begin(io);
        const chunks = try chunking.chunkMarkdown(gpa, doc, workload.chunk_tokens, workload.chunk_overlap);
        const elapsed_ms = sw.elapsedMs();
        defer chunking.freeChunks(gpa, chunks);

        const violation = workload.chunkInvariants(chunks, doc, workload.chunk_tokens, workload.chunk_overlap);
        try builder.check(
            try builder.fmt("survives a {s} document of {d} KiB", .{ @tagName(kind), doc.len / 1024 }),
            violation == null,
            violation orelse "",
            elapsed_ms,
            &.{
                .{ .name = "document_bytes", .value = @floatFromInt(doc.len), .unit = "bytes" },
                .{ .name = "chunks", .value = @floatFromInt(chunks.len), .unit = "count" },
            },
        );
    }

    // ---- 4. MMR candidate escalation ---------------------------------------
    //
    // Every candidate carries identical text, which is the worst case for
    // the pairwise Jaccard similarity the algorithm computes. The invariant
    // is that re-ranking is a *permutation*: same rows out as in, reordered.

    var candidates: usize = 8;
    while (candidates <= max_candidates) : (candidates *= 2) {
        const rows = try gpa.alloc(types.RawSearchRow, candidates);
        defer gpa.free(rows);
        for (rows, 0..) |*row, i| row.* = .{
            .chunk_id = "chunk",
            .path = "memory/2024-01-01-note.md",
            .source = "workspace",
            .start_line = @intCast(i + 1),
            .end_line = @intCast(i + 1),
            .text = "memory context retrieval embedding chunk vector index",
            .score = 1.0 - (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(candidates + 1))),
        };

        const sw = report.Stopwatch.begin(io);
        const ranked = try mmr.mmrRerank(gpa, rows, 0.5);
        const elapsed_ms = sw.elapsedMs();
        defer gpa.free(ranked);

        const violation = try workload.permutationViolation(gpa, rows, ranked);
        if (violation == null) most_candidates = @max(most_candidates, candidates);

        try builder.check(
            try builder.fmt("MMR re-ranks {d} identical candidates as a permutation", .{candidates}),
            violation == null,
            violation orelse "",
            elapsed_ms,
            &.{
                .{ .name = "candidates", .value = @floatFromInt(candidates), .unit = "count" },
                .{
                    .name = "us_per_candidate",
                    .value = elapsed_ms * 1000.0 / @as(f64, @floatFromInt(candidates)),
                    .unit = "us",
                },
            },
        );
    }

    // ---- 4b. Storage and search under escalating pressure -------------------

    var largest_indexed: usize = 0;
    {
        var db = try store_workload.openMemoryDb();
        defer db.deinit();
        var store = store_workload.Store.init(&db);

        var indexed_size: usize = 8 * 1024;
        const max_indexed = options.sized(tunables.max_indexed_bytes);
        while (indexed_size <= max_indexed) : (indexed_size *= 2) {
            const doc: workload.Document = .{
                .name = "memory/2025-08-08-stress.md",
                .text = try workload.adversarialDoc(gpa, rand, .repeated_line, indexed_size),
            };
            defer gpa.free(doc.text);

            const sw = report.Stopwatch.begin(io);
            const digest = store_workload.runStoreUnit(gpa, &db, &store, doc, 0) catch |err| {
                try builder.check(
                    try builder.fmt("indexes and searches a {d} KiB document", .{indexed_size / 1024}),
                    false,
                    try builder.fmt("returned {s}", .{@errorName(err)}),
                    sw.elapsedMs(),
                    &.{},
                );
                continue;
            };
            largest_indexed = @max(largest_indexed, indexed_size);

            try builder.check(
                try builder.fmt("indexes and searches a {d} KiB document", .{indexed_size / 1024}),
                true,
                "",
                sw.elapsedMs(),
                &.{
                    .{ .name = "document_bytes", .value = @floatFromInt(indexed_size), .unit = "bytes" },
                    .{ .name = "digest", .value = @floatFromInt(digest % 1_000_000), .unit = "count" },
                },
            );
        }

        // Chunk ids are derived from the chunk's line range, so a line
        // longer than the chunk budget produces several chunks that all
        // claim the same range — and therefore the same id. On insert they
        // collapse into one row and the rest of the line is silently lost
        // from the index.
        //
        // This mirrors Python's `make_chunk_id` exactly, so it is a faithful
        // port of an upstream limitation rather than a defect introduced
        // here. The case is written to *document* it: it asserts the loss is
        // real and reports its size, so a future fix to the id derivation
        // shows up as this case changing rather than as a silent behaviour
        // change.
        {
            const long_line: workload.Document = .{
                .name = "memory/2025-08-10-one-long-line.md",
                .text = try workload.adversarialDoc(gpa, rand, .no_newlines, 64 * 1024),
            };
            defer gpa.free(long_line.text);

            const collisions = try store_workload.idCollisions(gpa, long_line);
            try builder.check(
                "documented: chunk ids collide when one line exceeds the chunk budget",
                collisions.chunks > 1 and collisions.distinct_ids == 1,
                try builder.fmt(
                    "expected many chunks collapsing to a single id, got {d} chunks and {d} ids",
                    .{ collisions.chunks, collisions.distinct_ids },
                ),
                0,
                &.{
                    .{ .name = "chunks_produced", .value = @floatFromInt(collisions.chunks), .unit = "count" },
                    .{ .name = "distinct_chunk_ids", .value = @floatFromInt(collisions.distinct_ids), .unit = "count" },
                    .{ .name = "chunks_lost_on_insert", .value = @floatFromInt(collisions.collapsed()), .unit = "count" },
                },
            );

            // A normal document, by contrast, must not lose anything.
            const ordinary: workload.Document = .{
                .name = "memory/2025-08-11-ordinary.md",
                .text = try workload.adversarialDoc(gpa, rand, .repeated_line, 64 * 1024),
            };
            defer gpa.free(ordinary.text);

            const ordinary_collisions = try store_workload.idCollisions(gpa, ordinary);
            try builder.check(
                "a document of ordinary lines loses no chunks to id collisions",
                ordinary_collisions.collapsed() == 0,
                try builder.fmt("{d} of {d} chunks collapsed", .{
                    ordinary_collisions.collapsed(),
                    ordinary_collisions.chunks,
                }),
                0,
                &.{
                    .{ .name = "chunks_produced", .value = @floatFromInt(ordinary_collisions.chunks), .unit = "count" },
                    .{ .name = "chunks_lost_on_insert", .value = @floatFromInt(ordinary_collisions.collapsed()), .unit = "count" },
                },
            );
        }

        // Queries that are hostile rather than merely large: FTS5 has its own
        // query syntax, so anything a user types has to be neutralized before
        // it reaches MATCH. A crash or a syntax error escaping to the caller
        // would both be failures.
        const hostile = [_][]const u8{
            "\"unterminated quote",
            "memory AND (context OR",
            "* NEAR/2 *",
            "col:value ^caret",
            "-negated \"phrase\"",
            "a" ** 4096,
            "",
            "   ",
            "\x00embedded nul",
            "😀 🧠 記憶",
        };

        const doc: workload.Document = .{
            .name = "memory/2025-08-09-queries.md",
            .text = try workload.adversarialDoc(gpa, rand, .repeated_line, 64 * 1024),
        };
        defer gpa.free(doc.text);
        _ = try store_workload.runStoreUnit(gpa, &db, &store, doc, 0);

        var hostile_failures: usize = 0;
        var first_hostile: []const u8 = "";
        const hostile_sw = report.Stopwatch.begin(io);
        for (hostile) |query| {
            if (memweave.search.keyword.search(gpa, &db, query, store_workload.model, 10, null)) |rows| {
                gpa.free(rows);
            } else |err| {
                hostile_failures += 1;
                if (first_hostile.len == 0) {
                    first_hostile = try builder.fmt("query {d} returned {s}", .{ hostile_failures, @errorName(err) });
                }
            }
        }

        try builder.check(
            "hostile FTS5 query syntax is neutralized rather than propagated",
            hostile_failures == 0,
            first_hostile,
            hostile_sw.elapsedMs(),
            &.{.{ .name = "queries", .value = @floatFromInt(hostile.len), .unit = "count" }},
        );
    }

    // ---- 5. Memory exhaustion ----------------------------------------------
    //
    // Cap the allocator well below what a unit needs and assert the library
    // refuses cleanly. A crash, a hang, or a successful return would all be
    // failures.

    const oom_doc: workload.Document = .{
        .name = "memory/2024-05-05-oom.md",
        .text = try workload.adversarialDoc(gpa, rand, .repeated_line, 256 * 1024),
    };

    const restore_limit = gpa_state.requested_memory_limit;
    gpa_state.requested_memory_limit = gpa_state.total_requested_bytes + tunables.memory_limit_bytes;
    const oom_result = workload.runUnit(gpa, oom_doc);
    gpa_state.requested_memory_limit = restore_limit;

    if (oom_result) |_| {
        try builder.check(
            "a hard memory ceiling produces error.OutOfMemory",
            false,
            "the unit completed despite the memory ceiling — the ceiling was too generous to be a real test",
            0,
            &.{},
        );
    } else |err| {
        try builder.check(
            "a hard memory ceiling produces error.OutOfMemory",
            err == error.OutOfMemory,
            try builder.fmt("expected error.OutOfMemory, got {s}", .{@errorName(err)}),
            0,
            &.{.{
                .name = "memory_limit_bytes",
                .value = @floatFromInt(tunables.memory_limit_bytes),
                .unit = "bytes",
            }},
        );
    }

    // The allocator must be usable again after refusing — a ceiling is not a
    // poison pill.
    const recovered = workload.runUnit(gpa, oom_doc);
    try builder.check(
        "the allocator recovers once the ceiling is lifted",
        recovered != error.OutOfMemory,
        "the unit still failed after the memory ceiling was lifted",
        0,
        &.{},
    );

    // ---- Teardown ----------------------------------------------------------

    gpa.free(oom_doc.text);
    gpa.free(budget_doc);
    const leaked = gpa_state.deinit() == .leak;
    try builder.check("the allocator reports no leaks", !leaked, "allocator detected leaked memory", 0, &.{});

    const passed = try builder.finish(Params{
        .seed = options.seed,
        .scale = options.scale,
        .min_doc_bytes = tunables.min_doc_bytes,
        .max_doc_bytes = max_doc_bytes,
        .adversarial_bytes = adversarial_bytes,
        .max_candidates = max_candidates,
        .memory_limit_bytes = tunables.memory_limit_bytes,
        .largest_document_handled_bytes = largest_handled,
        .most_candidates_handled = most_candidates,
        .max_indexed_bytes = options.sized(tunables.max_indexed_bytes),
        .largest_indexed_bytes = largest_indexed,
    }, options.out_dir);

    if (!passed) std.process.exit(1);
}
