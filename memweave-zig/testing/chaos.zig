//! Chaos: break the environment underneath the library and see what leaks out.
//!
//! Stress escalates *legitimate* pressure. Chaos removes guarantees the code
//! never gets to assume in production either — memory that runs out at an
//! arbitrary moment, input that is not what the type says it is, an
//! allocator with a different strategy than the one it was tested on.
//!
//! Four independent kinds of chaos:
//!
//!   1. **Fault injection.** Every allocation a unit performs is failed in
//!      turn, one run per allocation index. Three things must hold at every
//!      index: the call either succeeds or returns `error.OutOfMemory` and
//!      nothing else; a run that had a failure injected must not report
//!      success (a swallowed OOM means a partial result was returned as if
//!      it were complete); and every byte allocated before the failure must
//!      still be freed on the way out.
//!
//!   2. **Input fuzzing.** Random sizes, random shapes, random chunk budgets.
//!      The structural invariants in `workload.chunkInvariants` must hold on
//!      every one, and the same input must always digest to the same value.
//!
//!   3. **Allocator substitution.** The same unit run through an arena, a
//!      general-purpose allocator and a fixed buffer must produce byte-identical
//!      digests. A difference would mean a result depends on allocation
//!      addresses or on the allocator's reuse pattern.
//!
//!   4. **Configuration fuzzing.** Random configurations — most of them
//!      invalid — are fed to the generated `Memory.validate()` and compared
//!      against an oracle written by hand from the constraints in the
//!      behaviour schemas. This is the factory's validator checked against
//!      an independent reading of the same rules.

const std = @import("std");
const memweave = @import("memweave");
const report = @import("report.zig");
const workload = @import("workload.zig");
const store_workload = @import("store.zig");

const chunking = memweave.chunking;
const forger = memweave.forger;

const Tunables = struct {
    /// Small on purpose: fault injection runs the unit once per allocation,
    /// so the document size sets the size of the whole case.
    injection_doc_bytes: usize = 2 * 1024,
    fuzz_iterations: usize = 400,
    fuzz_max_bytes: usize = 32 * 1024,
    config_iterations: usize = 5000,
    /// Tiny: the storage unit is re-run once per allocation it makes, and a
    /// database round trip per chunk makes that count climb fast.
    store_injection_doc_bytes: usize = 512,
    query_fuzz_iterations: usize = 300,
};

const Params = struct {
    seed: u64,
    scale: f64,
    injection_doc_bytes: usize,
    injection_points: usize,
    fuzz_iterations: usize,
    fuzz_max_bytes: usize,
    config_iterations: usize,
    store_injection_doc_bytes: usize,
    store_injection_points: usize,
    query_fuzz_iterations: usize,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var tunables: Tunables = .{};
    const options = try report.Options.parseWith(args, &tunables);

    const fuzz_iterations = options.sized(tunables.fuzz_iterations);
    const config_iterations = options.sized(tunables.config_iterations);

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();

    var builder = report.Builder.init(init.gpa, io, "chaos", "chaos");
    defer builder.deinit();

    var prng = std.Random.DefaultPrng.init(options.seed);
    const rand = prng.random();

    std.debug.print("chaos: seed 0x{X}\n", .{options.seed});

    // ---- 1. Allocation-failure injection ----------------------------------

    const injection_doc: workload.Document = .{
        .name = "memory/2025-03-14-chaos.md",
        .text = try workload.adversarialDoc(gpa, rand, .repeated_line, tunables.injection_doc_bytes),
    };

    // How many allocations does one clean run make? That is the number of
    // injection points.
    var probe = std.testing.FailingAllocator.init(gpa, .{});
    const clean_digest = try workload.runUnit(probe.allocator(), injection_doc);
    const injection_points = probe.alloc_index;

    var wrong_error: usize = 0;
    var swallowed: usize = 0;
    var leaked_runs: usize = 0;
    var completed: usize = 0;

    const inject_sw = report.Stopwatch.begin(io);
    var point: usize = 0;
    while (point < injection_points) : (point += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = point });

        if (workload.runUnit(failing.allocator(), injection_doc)) |digest| {
            completed += 1;
            // Reaching the end after a failure was induced means an error
            // path returned a partial result instead of propagating.
            if (failing.has_induced_failure) swallowed += 1;
            if (digest != clean_digest) swallowed += 1;
        } else |err| {
            if (err != error.OutOfMemory) wrong_error += 1;
        }

        if (failing.allocated_bytes != failing.freed_bytes) leaked_runs += 1;
    }
    const inject_ms = inject_sw.elapsedMs();

    try builder.check(
        "injected allocation failure always surfaces as error.OutOfMemory",
        wrong_error == 0,
        try builder.fmt("{d} run(s) returned an error other than OutOfMemory", .{wrong_error}),
        inject_ms,
        &.{
            .{ .name = "injection_points", .value = @floatFromInt(injection_points), .unit = "count" },
            .{ .name = "runs_completed", .value = @floatFromInt(completed), .unit = "count" },
        },
    );

    try builder.check(
        "no run swallows an injected failure and reports success",
        swallowed == 0,
        try builder.fmt("{d} run(s) returned a result despite a failed allocation", .{swallowed}),
        0,
        &.{.{ .name = "swallowed", .value = @floatFromInt(swallowed), .unit = "count" }},
    );

    try builder.check(
        "every allocation made before a failure is freed on the way out",
        leaked_runs == 0,
        try builder.fmt("{d} of {d} injection points leaked", .{ leaked_runs, injection_points }),
        0,
        &.{.{ .name = "leaking_runs", .value = @floatFromInt(leaked_runs), .unit = "count" }},
    );

    // ---- 1b. Fault injection per public entry point ------------------------
    //
    // The composite unit above catches cross-operation interactions; this
    // catches the ones a single call owns. Each entry point is driven on its
    // own so a leak is attributed to a function rather than to "somewhere in
    // the unit".

    try injectInto(&builder, gpa, io, "chunking.chunkMarkdown", entryChunkMarkdown);
    try injectInto(&builder, gpa, io, "chunking.chunkText", entryChunkText);
    try injectInto(&builder, gpa, io, "hashing.makeChunkId", entryMakeChunkId);
    try injectInto(&builder, gpa, io, "hashing.makeProviderKey", entryMakeProviderKey);
    try injectInto(&builder, gpa, io, "mmr.tokenizeForMmr", entryTokenize);
    try injectInto(&builder, gpa, io, "mmr.mmrRerank", entryRerank);

    // ---- 2. Input fuzzing --------------------------------------------------

    var invariant_violation: ?[]const u8 = null;
    var unstable_digest: usize = 0;
    var fuzz_bytes: usize = 0;

    const fuzz_sw = report.Stopwatch.begin(io);
    var iteration: usize = 0;
    while (iteration < fuzz_iterations) : (iteration += 1) {
        const kind = workload.Adversary.all()[rand.uintLessThan(usize, workload.Adversary.all().len)];
        const size = 1 + rand.uintLessThan(usize, options.sized(tunables.fuzz_max_bytes));
        const tokens = 1 + rand.uintLessThan(u32, 2048);
        // Keep the overlap legal: the chunker does not validate its own
        // arguments, and an illegal overlap is the config layer's business.
        const overlap = rand.uintLessThan(u32, tokens);

        const doc = try workload.adversarialDoc(gpa, rand, kind, size);
        defer gpa.free(doc);
        fuzz_bytes += doc.len;

        const chunks = try chunking.chunkMarkdown(gpa, doc, tokens, overlap);
        defer chunking.freeChunks(gpa, chunks);

        if (invariant_violation == null) {
            if (workload.chunkInvariants(chunks, doc, tokens, overlap)) |violation| {
                invariant_violation = try builder.fmt(
                    "{s} at iteration {d}: {s} doc of {d} bytes, tokens={d} overlap={d}",
                    .{ violation, iteration, @tagName(kind), doc.len, tokens, overlap },
                );
            }
        }

        // The same input must always chunk to the same output.
        const again = try chunking.chunkMarkdown(gpa, doc, tokens, overlap);
        defer chunking.freeChunks(gpa, again);
        if (!sameChunks(chunks, again)) unstable_digest += 1;
    }
    const fuzz_ms = fuzz_sw.elapsedMs();

    try builder.check(
        "chunk invariants hold on randomized malformed input",
        invariant_violation == null,
        invariant_violation orelse "",
        fuzz_ms,
        &.{
            .{ .name = "iterations", .value = @floatFromInt(fuzz_iterations), .unit = "count" },
            .{ .name = "bytes_fuzzed", .value = @floatFromInt(fuzz_bytes), .unit = "bytes" },
        },
    );

    try builder.check(
        "chunking is deterministic: identical input, identical output",
        unstable_digest == 0,
        try builder.fmt("{d} input(s) chunked differently on a second pass", .{unstable_digest}),
        0,
        &.{},
    );

    // ---- 3. Allocator substitution ----------------------------------------

    const substitution_doc: workload.Document = .{
        .name = "memory/2025-07-21-substitution.md",
        .text = try workload.adversarialDoc(gpa, rand, .repeated_line, 8 * 1024),
    };

    const gpa_digest = try workload.runUnit(gpa, substitution_doc);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const arena_digest = try workload.runUnit(arena_state.allocator(), substitution_doc);
    arena_state.deinit();

    const scratch = try gpa.alloc(u8, 8 * 1024 * 1024);
    var fba_state = std.heap.FixedBufferAllocator.init(scratch);
    const fba_digest = try workload.runUnit(fba_state.allocator(), substitution_doc);
    gpa.free(scratch);

    try builder.check(
        "the digest does not depend on which allocator computed it",
        gpa_digest == arena_digest and gpa_digest == fba_digest,
        try builder.fmt("gpa=0x{X} arena=0x{X} fixed_buffer=0x{X}", .{ gpa_digest, arena_digest, fba_digest }),
        0,
        &.{.{ .name = "allocators_compared", .value = 3, .unit = "count" }},
    );

    // ---- 4. Configuration fuzzing ------------------------------------------
    //
    // The generated validator versus a hand-written reading of the same
    // schemas. Disagreement in either direction is a failure: a config the
    // oracle accepts and the validator rejects is a false alarm; the reverse
    // is a rule that silently stopped being enforced.

    var false_accepts: usize = 0;
    var false_rejects: usize = 0;
    var valid_seen: usize = 0;

    const config_sw = report.Stopwatch.begin(io);
    var c: usize = 0;
    while (c < config_iterations) : (c += 1) {
        const cfg = randomConfig(rand);
        const accepted = if (forger.Memory.validate(cfg)) true else |_| false;
        const oracle = oracleAccepts(cfg);

        if (accepted) valid_seen += 1;
        if (accepted and !oracle) false_accepts += 1;
        if (!accepted and oracle) false_rejects += 1;
    }
    const config_ms = config_sw.elapsedMs();

    try builder.check(
        "the generated validator agrees with a hand-written reading of the schemas",
        false_accepts == 0 and false_rejects == 0,
        try builder.fmt("{d} config(s) wrongly accepted, {d} wrongly rejected", .{ false_accepts, false_rejects }),
        config_ms,
        &.{
            .{ .name = "configs_tried", .value = @floatFromInt(config_iterations), .unit = "count" },
            .{ .name = "configs_accepted", .value = @floatFromInt(valid_seen), .unit = "count" },
            .{ .name = "false_accepts", .value = @floatFromInt(false_accepts), .unit = "count" },
            .{ .name = "false_rejects", .value = @floatFromInt(false_rejects), .unit = "count" },
        },
    );

    // A fuzzer that never generates a valid config would pass the case above
    // while testing nothing, so assert it explored both outcomes.
    try builder.check(
        "config fuzzing reached both valid and invalid configurations",
        valid_seen > 0 and valid_seen < config_iterations,
        try builder.fmt("{d} of {d} configurations were accepted", .{ valid_seen, config_iterations }),
        0,
        &.{},
    );

    // ---- 5. Storage under fault injection ----------------------------------
    //
    // Each run gets its own database, so a failure injected mid-transaction
    // cannot poison the next attempt. What is being asserted is the same as
    // for the pure paths: the error is `OutOfMemory`, and the Zig-side
    // allocations are all released. SQLite's own C allocations are outside
    // this allocator and outside what a Zig test can inject into.

    const store_doc: workload.Document = .{
        .name = "memory/2025-06-06-chaos.md",
        .text = try workload.adversarialDoc(gpa, rand, .repeated_line, tunables.store_injection_doc_bytes),
    };

    var store_probe = std.testing.FailingAllocator.init(gpa, .{});
    _ = try store_workload.runIsolatedStoreUnit(store_probe.allocator(), store_doc, 0);
    const store_points = store_probe.alloc_index;

    var store_wrong_error: usize = 0;
    var store_leaks: usize = 0;
    var store_first_leak: ?usize = null;

    const store_sw = report.Stopwatch.begin(io);
    var sp: usize = 0;
    while (sp < store_points) : (sp += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = sp });
        if (store_workload.runIsolatedStoreUnit(failing.allocator(), store_doc, 0)) |_| {} else |err| {
            // The storage layer collapses its failures into StorageError and
            // SearchError, so those are legitimate outcomes here alongside
            // OutOfMemory — what would not be is a crash or a wrong answer.
            switch (err) {
                error.OutOfMemory, error.StorageError, error.SearchError => {},
                else => store_wrong_error += 1,
            }
        }
        if (failing.allocated_bytes != failing.freed_bytes) {
            store_leaks += 1;
            if (store_first_leak == null) store_first_leak = sp;
        }
    }

    try builder.check(
        "the storage unit unwinds cleanly at every allocation failure",
        store_leaks == 0 and store_wrong_error == 0,
        try builder.fmt("{d}/{d} points leaked (first at {?d}), {d} returned an unexpected error", .{
            store_leaks, store_points, store_first_leak, store_wrong_error,
        }),
        store_sw.elapsedMs(),
        &.{
            .{ .name = "injection_points", .value = @floatFromInt(store_points), .unit = "count" },
            .{ .name = "leaking_points", .value = @floatFromInt(store_leaks), .unit = "count" },
        },
    );

    // ---- 6. Query fuzzing ---------------------------------------------------
    //
    // FTS5 has a query language of its own, so every byte a user can type is
    // an input to a parser. Random bytes, random operators and random quoting
    // must all come back as results or as an error — never as a crash, and
    // never as a different answer for the same input.

    {
        var db = try store_workload.openMemoryDb();
        defer db.deinit();
        var store = store_workload.Store.init(&db);

        const indexed: workload.Document = .{
            .name = "memory/2025-06-07-fuzz.md",
            .text = try workload.adversarialDoc(gpa, rand, .repeated_line, 16 * 1024),
        };
        defer gpa.free(indexed.text);
        // Index without the delete phase, so there is something to search.
        _ = try store_workload.runStoreUnit(gpa, &db, &store, indexed, 0);
        _ = try store_workload.runStoreUnit(gpa, &db, &store, indexed, 0);

        const iterations = options.sized(tunables.query_fuzz_iterations);
        var query_errors: usize = 0;
        var unstable_queries: usize = 0;

        const query_sw = report.Stopwatch.begin(io);
        var q: usize = 0;
        while (q < iterations) : (q += 1) {
            const query = try randomQuery(gpa, rand);
            defer gpa.free(query);

            const first = memweave.search.keyword.search(gpa, &db, query, store_workload.model, 10, null) catch {
                query_errors += 1;
                continue;
            };
            defer gpa.free(first);

            const second = memweave.search.keyword.search(gpa, &db, query, store_workload.model, 10, null) catch {
                query_errors += 1;
                continue;
            };
            defer gpa.free(second);

            if (!sameRows(first, second)) unstable_queries += 1;
        }

        try builder.check(
            "randomized queries never crash the FTS5 path",
            true,
            "",
            query_sw.elapsedMs(),
            &.{
                .{ .name = "queries", .value = @floatFromInt(iterations), .unit = "count" },
                .{ .name = "queries_erroring", .value = @floatFromInt(query_errors), .unit = "count" },
            },
        );

        try builder.check(
            "the same query against the same index returns the same rows",
            unstable_queries == 0,
            try builder.fmt("{d} quer(ies) returned different rows on a second run", .{unstable_queries}),
            0,
            &.{},
        );
    }

    gpa.free(store_doc.text);

    // ---- Teardown ----------------------------------------------------------

    gpa.free(injection_doc.text);
    gpa.free(substitution_doc.text);
    const leaked = gpa_state.deinit() == .leak;
    try builder.check("the allocator reports no leaks", !leaked, "allocator detected leaked memory", 0, &.{});

    const passed = try builder.finish(Params{
        .seed = options.seed,
        .scale = options.scale,
        .injection_doc_bytes = tunables.injection_doc_bytes,
        .injection_points = injection_points,
        .fuzz_iterations = fuzz_iterations,
        .fuzz_max_bytes = options.sized(tunables.fuzz_max_bytes),
        .config_iterations = config_iterations,
        .store_injection_doc_bytes = tunables.store_injection_doc_bytes,
        .store_injection_points = store_points,
        .query_fuzz_iterations = options.sized(tunables.query_fuzz_iterations),
    }, options.out_dir);

    if (!passed) std.process.exit(1);
}

// ---------------------------------------------------------------------------
// Per-entry-point fault injection
// ---------------------------------------------------------------------------

const sample_text =
    \\# memory
    \\
    \\context retrieval embedding chunk vector index workspace decay rerank
    \\hybrid sqlite markdown token overlap snippet evergreen flush profile
    \\
    \\- schema behaviour cascade manifest comptime allocator digest corpus
    \\- memory context retrieval embedding chunk vector index workspace
;

fn entryChunkMarkdown(gpa: std.mem.Allocator) !void {
    const chunks = try chunking.chunkMarkdown(gpa, sample_text, 40, 8);
    chunking.freeChunks(gpa, chunks);
}

fn entryChunkText(gpa: std.mem.Allocator) !void {
    const texts = try chunking.chunkText(gpa, sample_text, 40, 8);
    for (texts) |t| gpa.free(t);
    gpa.free(texts);
}

fn entryMakeChunkId(gpa: std.mem.Allocator) !void {
    _ = try memweave.hashing.makeChunkId(gpa, "workspace", "memory/2025-01-01-a.md", 1, 9, "deadbeef", "text-embedding-3-small");
}

fn entryMakeProviderKey(gpa: std.mem.Allocator) !void {
    _ = try memweave.hashing.makeProviderKey(gpa, "litellm", "text-embedding-3-small", "http://localhost:11434");
}

fn entryTokenize(gpa: std.mem.Allocator) !void {
    var set = try memweave.mmr.tokenizeForMmr(gpa, sample_text);
    set.deinit(gpa);
}

fn entryRerank(gpa: std.mem.Allocator) !void {
    var rows: [8]memweave.types.RawSearchRow = undefined;
    for (&rows, 0..) |*row, i| row.* = .{
        .chunk_id = "chunk",
        .path = "memory/2025-01-01-a.md",
        .source = "workspace",
        .start_line = @intCast(i + 1),
        .end_line = @intCast(i + 2),
        .text = sample_text[i .. sample_text.len - i],
        .score = 1.0 - @as(f64, @floatFromInt(i)) / 10.0,
    };
    const ranked = try memweave.mmr.mmrRerank(gpa, &rows, 0.6);
    gpa.free(ranked);
}

/// Fail every allocation `entry` makes, one index per run, and require that
/// each run either succeeds or returns `error.OutOfMemory` — and that every
/// byte it allocated before failing is freed again.
fn injectInto(
    builder: *report.Builder,
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    comptime entry: fn (std.mem.Allocator) anyerror!void,
) !void {
    var probe = std.testing.FailingAllocator.init(gpa, .{});
    try entry(probe.allocator());
    const points = probe.alloc_index;

    var leaks: usize = 0;
    var wrong_error: usize = 0;
    var first_leak: ?usize = null;

    const sw = report.Stopwatch.begin(io);
    var point: usize = 0;
    while (point < points) : (point += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = point });
        if (entry(failing.allocator())) |_| {} else |err| {
            if (err != error.OutOfMemory) wrong_error += 1;
        }
        if (failing.allocated_bytes != failing.freed_bytes) {
            leaks += 1;
            if (first_leak == null) first_leak = point;
        }
    }

    try builder.check(
        try builder.fmt("{s} unwinds cleanly at every allocation failure", .{name}),
        leaks == 0 and wrong_error == 0,
        try builder.fmt("{d}/{d} points leaked (first at {?d}), {d} returned the wrong error", .{
            leaks, points, first_leak, wrong_error,
        }),
        sw.elapsedMs(),
        &.{
            .{ .name = "injection_points", .value = @floatFromInt(points), .unit = "count" },
            .{ .name = "leaking_points", .value = @floatFromInt(leaks), .unit = "count" },
        },
    );
}

/// A query built from bytes a user could plausibly type, weighted towards
/// the ones FTS5 gives meaning to.
fn randomQuery(gpa: std.mem.Allocator, rand: std.Random) ![]u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789 \"'*()^:-+ ANDORNOT\t\n\\/{}[]<>=~!@#$%&|;,.?";
    const len = 1 + rand.uintLessThan(usize, 64);
    const out = try gpa.alloc(u8, len);
    for (out) |*c| c.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
    return out;
}

fn sameRows(a: []const memweave.types.RawSearchRow, b: []const memweave.types.RawSearchRow) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.chunk_id, y.chunk_id)) return false;
        if (x.start_line != y.start_line or x.end_line != y.end_line) return false;
        if (x.score != y.score) return false;
    }
    return true;
}

fn sameChunks(a: []const chunking.MarkdownChunk, b: []const chunking.MarkdownChunk) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.start_line != y.start_line or x.end_line != y.end_line) return false;
        if (!std.mem.eql(u8, x.text, y.text)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Configuration fuzzing
// ---------------------------------------------------------------------------

/// A configuration for the fuzzer: a valid baseline, then — half the time —
/// exactly one field pushed out of range.
///
/// Drawing every field independently would be useless here: the weights have
/// to sum to 1.0, so an independent draw is invalid with probability ~1 and
/// the fuzzer would never once exercise the accept path. Mutating a single
/// field of a valid config instead means every run lands just on one side of
/// exactly one rule, which is where validators actually go wrong.
fn randomConfig(rand: std.Random) forger.MemoryConfig {
    var cfg = validConfig(rand);
    if (rand.boolean()) corruptOneField(rand, &cfg);
    return cfg;
}

/// Every field drawn from inside its declared range, including sitting
/// exactly on the boundaries the constraints turn on.
fn validConfig(rand: std.Random) forger.MemoryConfig {
    const vector_weight = pick(rand, &.{ 0.0, 0.5, 0.7, 1.0, rand.float(f64) });
    return .{
        .embedding = .{
            .timeout = pick(rand, &.{ 0.001, 1.0, 60.0, 3600.0 }),
            .batch_size = 1 + rand.uintLessThan(u32, 64),
        },
        .chunking = chunking: {
            const tokens = 1 + rand.uintLessThan(u32, 512);
            break :chunking .{ .tokens = tokens, .overlap = rand.uintLessThan(u32, tokens) };
        },
        .query = .{
            .max_results = 1 + rand.uintLessThan(u32, 32),
            .min_score = pick(rand, &.{ 0.0, 0.35, 1.0, rand.float(f64) }),
            .snippet_max_chars = 1 + rand.uintLessThan(u32, 4096),
            .hybrid = .{
                .vector_weight = vector_weight,
                .text_weight = 1.0 - vector_weight,
                .candidate_multiplier = 1 + rand.uintLessThan(u32, 8),
            },
            .mmr = .{ .lambda_param = pick(rand, &.{ 0.0, 0.7, 1.0, rand.float(f64) }) },
            .temporal_decay = .{ .half_life_days = pick(rand, &.{ 0.001, 30.0, 365.0 }) },
        },
        .cache = .{
            .max_entries = if (rand.boolean()) null else 1 + rand.uintLessThan(u32, 1000),
        },
        .flush = .{
            .max_tokens = 1 + rand.uintLessThan(u32, 4096),
            .temperature = pick(rand, &.{ 0.0, 1.0, 2.0, rand.float(f64) * 2.0 }),
        },
    };
}

/// Push exactly one field just past its limit. Each mutation is the smallest
/// step that should flip the verdict, so an off-by-one in either the
/// generated validator or the oracle shows up immediately.
fn corruptOneField(rand: std.Random, cfg: *forger.MemoryConfig) void {
    switch (rand.uintLessThan(u8, 12)) {
        0 => cfg.embedding.timeout = pick(rand, &.{ 0.0, -1.0 }),
        1 => cfg.embedding.batch_size = 0,
        2 => cfg.chunking.tokens = 0,
        // Overlap exactly equal to the chunk is the boundary case: the rule
        // is `overlap < tokens`, not `<=`.
        3 => cfg.chunking.overlap = cfg.chunking.tokens,
        4 => cfg.query.max_results = 0,
        5 => cfg.query.min_score = pick(rand, &.{ -0.000001, 1.000001, 2.0 }),
        6 => cfg.query.snippet_max_chars = 0,
        // Breaks the sum_eq invariant without leaving either weight's range.
        7 => cfg.query.hybrid.text_weight = std.math.clamp(cfg.query.hybrid.text_weight + 0.1, 0.0, 1.0),
        8 => cfg.query.mmr.lambda_param = pick(rand, &.{ -0.000001, 1.000001 }),
        9 => cfg.query.temporal_decay.half_life_days = pick(rand, &.{ 0.0, -30.0 }),
        10 => cfg.cache.max_entries = 0,
        else => cfg.flush.temperature = pick(rand, &.{ -0.000001, 2.000001 }),
    }
}

fn pick(rand: std.Random, choices: []const f64) f64 {
    return choices[rand.uintLessThan(usize, choices.len)];
}

/// The constraints and invariants declared across `src/behaviors/*/schema.yml`,
/// transcribed by hand. Deliberately written from the schemas rather than
/// from `module.zig`, so the two are independent readings of the same rules.
fn oracleAccepts(cfg: forger.MemoryConfig) bool {
    // embedding
    if (!(cfg.embedding.timeout > 0)) return false;
    if (cfg.embedding.batch_size < 1) return false;

    // chunking
    if (cfg.chunking.tokens < 1) return false;
    if (!(cfg.chunking.overlap < cfg.chunking.tokens)) return false;

    // query
    if (cfg.query.max_results < 1) return false;
    if (!(cfg.query.min_score >= 0 and cfg.query.min_score <= 1)) return false;
    if (cfg.query.snippet_max_chars < 1) return false;

    // query.hybrid
    const h = cfg.query.hybrid;
    if (!(h.vector_weight >= 0 and h.vector_weight <= 1)) return false;
    if (!(h.text_weight >= 0 and h.text_weight <= 1)) return false;
    if (@abs(h.vector_weight + h.text_weight - 1.0) > 0.000001) return false;
    if (h.candidate_multiplier < 1) return false;

    // query.mmr
    if (!(cfg.query.mmr.lambda_param >= 0 and cfg.query.mmr.lambda_param <= 1)) return false;

    // query.temporal_decay
    if (!(cfg.query.temporal_decay.half_life_days > 0)) return false;

    // cache — null means unlimited, which is always valid
    if (cfg.cache.max_entries) |n| {
        if (n < 1) return false;
    }

    // flush
    if (cfg.flush.max_tokens < 1) return false;
    if (!(cfg.flush.temperature >= 0 and cfg.flush.temperature <= 2)) return false;

    return true;
}
