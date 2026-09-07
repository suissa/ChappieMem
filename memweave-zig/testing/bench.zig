//! Bench: how long does each operation actually take?
//!
//! This is the one suite that measures rather than asserts. A benchmark that
//! fails the build on a threshold is a benchmark that gets its threshold
//! loosened until it stops meaning anything, so the only failure here is an
//! operation that errors out. The verdict on whether a number got worse
//! belongs to whoever diffs `reports/bench.json` between two commits — which
//! is exactly what the shared report schema is for.
//!
//! Two details that decide whether the numbers are worth reading:
//!
//!   * **Batching.** Reading the monotonic clock costs on the order of a
//!     hundred nanoseconds, which is more than some of these operations take.
//!     Cheap operations are therefore timed in batches and the cost divided
//!     out, so the clock is measured once per batch instead of once per call.
//!   * **`doNotOptimizeAway`.** Every result is consumed, or an optimizer
//!     that can see the result is unused will delete the work and report an
//!     impressive zero.
//!
//! Built in ReleaseSafe by default, like the other measured suites — safety
//! checks stay compiled in, which costs a little and is worth it everywhere
//! else. Pass `-Dperf-optimize=ReleaseFast` for numbers without them; every
//! report records the mode it was built in.

const std = @import("std");
const memweave = @import("memweave");
const report = @import("report.zig");
const workload = @import("workload.zig");

const chunking = memweave.chunking;
const hashing = memweave.hashing;
const mmr = memweave.mmr;
const decay = memweave.decay;
const vectors = memweave.vectors;
const types = memweave.types;
const forger = memweave.forger;

const Tunables = struct {
    /// Timed samples per benchmark. Each sample may itself be a batch.
    iterations: usize = 120,
    small_bytes: usize = 1024,
    medium_bytes: usize = 16 * 1024,
    large_bytes: usize = 256 * 1024,
    embedding_dim: usize = 1536,
};

const Params = struct {
    seed: u64,
    scale: f64,
    iterations: usize,
    small_bytes: usize,
    medium_bytes: usize,
    large_bytes: usize,
    embedding_dim: usize,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var tunables: Tunables = .{};
    const options = try report.Options.parseWith(args, &tunables);
    const iterations = options.sized(tunables.iterations);

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();

    var builder = report.Builder.init(init.gpa, io, "bench", "bench");
    defer builder.deinit();

    var prng = std.Random.DefaultPrng.init(options.seed);
    const rand = prng.random();

    std.debug.print("bench: {d} samples per benchmark (seed 0x{X})\n", .{ iterations, options.seed });

    // ---- Fixtures ---------------------------------------------------------

    var corpus = try workload.Corpus.generate(gpa, options.seed, 3, tunables.medium_bytes);
    const small = try workload.adversarialDoc(gpa, rand, .repeated_line, options.sized(tunables.small_bytes));
    const medium = try workload.adversarialDoc(gpa, rand, .repeated_line, options.sized(tunables.medium_bytes));
    const large = try workload.adversarialDoc(gpa, rand, .repeated_line, options.sized(tunables.large_bytes));

    const rows = try gpa.alloc(types.RawSearchRow, 100);
    for (rows, 0..) |*row, i| row.* = .{
        .chunk_id = "chunk",
        .path = "memory/2025-02-02-note.md",
        .source = "workspace",
        .start_line = @intCast(i + 1),
        .end_line = @intCast(i + 2),
        .text = medium[0..@min(medium.len, 512 + i)],
        .score = 1.0 - @as(f64, @floatFromInt(i)) / 101.0,
    };

    const embedding = try gpa.alloc(f32, options.sized(tunables.embedding_dim));
    for (embedding, 0..) |*v, i| v.* = @floatFromInt((i % 97) + 1);

    // ---- Chunking ---------------------------------------------------------

    inline for (.{
        .{ "chunking.chunkMarkdown small", "small" },
        .{ "chunking.chunkMarkdown medium", "medium" },
        .{ "chunking.chunkMarkdown large", "large" },
    }) |spec| {
        const doc = if (comptime std.mem.eql(u8, spec[1], "small"))
            small
        else if (comptime std.mem.eql(u8, spec[1], "medium")) medium else large;

        try measure(&builder, io, gpa, spec[0], doc.len, iterations, 1, doc, struct {
            fn run(a: std.mem.Allocator, text: []const u8, _: usize) !void {
                const chunks = try chunking.chunkMarkdown(a, text, workload.chunk_tokens, workload.chunk_overlap);
                defer chunking.freeChunks(a, chunks);
                std.mem.doNotOptimizeAway(chunks.len);
            }
        }.run);
    }

    try measure(&builder, io, gpa, "chunking.chunkText medium", medium.len, iterations, 1, medium, struct {
        fn run(a: std.mem.Allocator, text: []const u8, _: usize) !void {
            const texts = try chunking.chunkText(a, text, workload.chunk_tokens, workload.chunk_overlap);
            defer {
                for (texts) |t| a.free(t);
                a.free(texts);
            }
            std.mem.doNotOptimizeAway(texts.len);
        }
    }.run);

    // ---- Hashing ----------------------------------------------------------

    try measure(&builder, io, gpa, "hashing.sha256Text small", small.len, iterations, 20, small, struct {
        fn run(_: std.mem.Allocator, text: []const u8, _: usize) !void {
            std.mem.doNotOptimizeAway(hashing.sha256Text(text));
        }
    }.run);

    try measure(&builder, io, gpa, "hashing.sha256Text medium", medium.len, iterations, 5, medium, struct {
        fn run(_: std.mem.Allocator, text: []const u8, _: usize) !void {
            std.mem.doNotOptimizeAway(hashing.sha256Text(text));
        }
    }.run);

    try measure(&builder, io, gpa, "hashing.makeChunkId", 0, iterations, 200, {}, struct {
        fn run(a: std.mem.Allocator, _: void, _: usize) !void {
            std.mem.doNotOptimizeAway(try hashing.makeChunkId(
                a,
                "workspace",
                "memory/2025-02-02-note.md",
                1,
                42,
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                "text-embedding-3-small",
            ));
        }
    }.run);

    try measure(&builder, io, gpa, "hashing.makeProviderKey", 0, iterations, 200, {}, struct {
        fn run(a: std.mem.Allocator, _: void, _: usize) !void {
            std.mem.doNotOptimizeAway(try hashing.makeProviderKey(a, "litellm", "text-embedding-3-small", null));
        }
    }.run);

    // ---- Ranking ----------------------------------------------------------

    try measure(&builder, io, gpa, "mmr.tokenizeForMmr medium", medium.len, iterations, 1, medium, struct {
        fn run(a: std.mem.Allocator, text: []const u8, _: usize) !void {
            var set = try mmr.tokenizeForMmr(a, text);
            defer set.deinit(a);
            std.mem.doNotOptimizeAway(set.tokens.len);
        }
    }.run);

    inline for (.{ 24, 100 }) |candidates| {
        try measure(
            &builder,
            io,
            gpa,
            std.fmt.comptimePrint("mmr.mmrRerank {d} candidates", .{candidates}),
            0,
            iterations,
            1,
            @as([]const types.RawSearchRow, rows[0..candidates]),
            struct {
                fn run(a: std.mem.Allocator, input: []const types.RawSearchRow, _: usize) !void {
                    const ranked = try mmr.mmrRerank(a, input, 0.7);
                    defer a.free(ranked);
                    std.mem.doNotOptimizeAway(ranked.len);
                }
            }.run,
        );
    }

    // ---- Scoring and vectors ----------------------------------------------

    try measure(&builder, io, gpa, "decay.calculateDecayMultiplier", 0, iterations, 5000, {}, struct {
        fn run(_: std.mem.Allocator, _: void, i: usize) !void {
            // The age varies per call: with a constant argument the whole
            // batch loop folds to a single computation and the benchmark
            // reports zero.
            std.mem.doNotOptimizeAway(decay.calculateDecayMultiplier(@floatFromInt(i % 512), 30.0));
        }
    }.run);

    try measure(&builder, io, gpa, "decay.parseDateFromPath", 0, iterations, 2000, {}, struct {
        fn run(_: std.mem.Allocator, _: void, i: usize) !void {
            const paths = [_][]const u8{
                "memory/2025-02-02-note.md",
                "memory/1999-12-31-old.md",
                "MEMORY.md",
                "memory/not-a-date.md",
            };
            std.mem.doNotOptimizeAway(decay.parseDateFromPath(paths[i % paths.len]));
        }
    }.run);

    try measure(
        &builder,
        io,
        gpa,
        "vectors.normalizeEmbedding",
        embedding.len * @sizeOf(f32),
        iterations,
        50,
        embedding,
        struct {
            fn run(_: std.mem.Allocator, v: []f32, _: usize) !void {
                vectors.normalizeEmbedding(v);
                std.mem.doNotOptimizeAway(v[0]);
            }
        }.run,
    );

    // ---- Configuration -----------------------------------------------------

    try measure(&builder, io, gpa, "forger.Memory.validate (full cascade)", 0, iterations, 5000, {}, struct {
        fn run(_: std.mem.Allocator, _: void, i: usize) !void {
            // Vary a field so the cascade is actually walked each time
            // instead of being folded away at compile time.
            var cfg: forger.MemoryConfig = .{};
            cfg.query.max_results = @intCast(1 + (i % 32));
            std.mem.doNotOptimizeAway(forger.Memory.validate(cfg));
        }
    }.run);

    // ---- The composite unit ------------------------------------------------

    try measure(&builder, io, gpa, "workload.runUnit (whole pipeline)", corpus.docs[0].text.len, iterations, 1, corpus.docs[0], struct {
        fn run(a: std.mem.Allocator, doc: workload.Document, _: usize) !void {
            std.mem.doNotOptimizeAway(try workload.runUnit(a, doc));
        }
    }.run);

    // ---- Teardown ----------------------------------------------------------

    corpus.deinit();
    gpa.free(small);
    gpa.free(medium);
    gpa.free(large);
    gpa.free(rows);
    gpa.free(embedding);
    const leaked = gpa_state.deinit() == .leak;
    try builder.check("the allocator reports no leaks", !leaked, "allocator detected leaked memory", 0, &.{});

    const passed = try builder.finish(Params{
        .seed = options.seed,
        .scale = options.scale,
        .iterations = iterations,
        .small_bytes = small.len,
        .medium_bytes = medium.len,
        .large_bytes = large.len,
        .embedding_dim = embedding.len,
    }, options.out_dir);

    if (!passed) std.process.exit(1);
}

/// The allocator the timed bodies run on.
///
/// Deliberately not the `DebugAllocator` the fixtures use: its per-free
/// `@memset(undefined)` and bookkeeping cost more than some of the
/// operations being measured, so benchmarking against it would mostly
/// report the allocator. Leak coverage for these paths is `chaos`'s job,
/// exhaustively; here the point is the library's own cost.
const bench_allocator = std.heap.smp_allocator;

/// Time `body` and record it as one case.
///
/// `batch` is how many invocations share a single clock reading — set it
/// above 1 for anything faster than a microsecond, or the timer dominates
/// what you are trying to measure. `bytes_per_op` of 0 means throughput in
/// bytes is meaningless for this operation and is left out of the report.
fn measure(
    builder: *report.Builder,
    io: std.Io,
    gpa: std.mem.Allocator,
    name: []const u8,
    bytes_per_op: usize,
    iterations: usize,
    batch: usize,
    ctx: anytype,
    comptime body: fn (std.mem.Allocator, @TypeOf(ctx), usize) anyerror!void,
) !void {
    // Warm the caches and the allocator's free lists so the first sample is
    // not an outlier that skews the minimum.
    const warmup = @max(1, @min(20, iterations / 10));
    var w: usize = 0;
    while (w < warmup) : (w += 1) {
        body(bench_allocator, ctx, w) catch |err| {
            try builder.check(name, false, @errorName(err), 0, &.{});
            return;
        };
    }

    var samples = report.Samples.init(gpa);
    defer samples.deinit();

    const sw_total = report.Stopwatch.begin(io);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const sw = report.Stopwatch.begin(io);
        var b: usize = 0;
        while (b < batch) : (b += 1) {
            body(bench_allocator, ctx, i * batch + b) catch |err| {
                try builder.check(name, false, @errorName(err), 0, &.{});
                return;
            };
        }
        try samples.add(sw.elapsedNs() / batch);
    }
    const total_ms = sw_total.elapsedMs();

    const stats = samples.stats();
    const ns_per_op: f64 = @floatFromInt(stats.p50_ns);
    const ops_per_sec = if (ns_per_op > 0) @as(f64, std.time.ns_per_s) / ns_per_op else 0;

    var metrics: [7]report.Metric = undefined;
    var count: usize = 0;
    metrics[count] = .{ .name = "ns_per_op", .value = ns_per_op, .unit = "ns" };
    count += 1;
    metrics[count] = .{ .name = "ops_per_sec", .value = ops_per_sec, .unit = "ops/s" };
    count += 1;
    metrics[count] = .{ .name = "ns_per_op_min", .value = @floatFromInt(stats.min_ns), .unit = "ns" };
    count += 1;
    metrics[count] = .{ .name = "ns_per_op_p99", .value = @floatFromInt(stats.p99_ns), .unit = "ns" };
    count += 1;
    metrics[count] = .{ .name = "samples", .value = @floatFromInt(stats.count), .unit = "count" };
    count += 1;
    metrics[count] = .{ .name = "batch", .value = @floatFromInt(batch), .unit = "count" };
    count += 1;
    if (bytes_per_op > 0) {
        metrics[count] = .{
            .name = "megabytes_per_sec",
            .value = ops_per_sec * @as(f64, @floatFromInt(bytes_per_op)) / (1024 * 1024),
            .unit = "MiB/s",
        };
        count += 1;
    }

    try builder.record(.{
        .name = name,
        .status = .pass,
        .duration_ms = total_ms,
        .metrics = metrics[0..count],
    });
}
