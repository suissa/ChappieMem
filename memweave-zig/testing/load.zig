//! Load: does the library stay correct and predictable under sustained volume?
//!
//! A load test is not a benchmark. `bench` answers "how fast is one call";
//! this answers "does anything change when you make three thousand of them".
//! The interesting failures here are the ones a single call can never
//! reveal: a result that drifts as state accumulates, memory that creeps up
//! a few bytes per iteration, a tail latency that only appears once the
//! allocator's free lists are fragmented.
//!
//! So the assertions are about *invariance*, not speed:
//!
//!   * every unit reproduces the digest its document produced on the very
//!     first pass — the run cannot silently change its own answers;
//!   * outstanding bytes return exactly to the baseline after every unit —
//!     the workload is allocation-neutral, so a per-iteration leak of even
//!     one byte fails immediately, naming the iteration;
//!   * the allocator reports no leaks once everything is torn down.
//!
//! Throughput and the latency distribution are recorded, and p99 is held to
//! a deliberately loose ceiling (`--max-p99-ms`) — tight enough to catch a
//! pathological regression, loose enough not to flake on a shared CI runner.
//! For real numbers, read `reports/bench.json` instead.

const std = @import("std");
const report = @import("report.zig");
const workload = @import("workload.zig");

const Tunables = struct {
    docs: usize = 96,
    avg_doc_bytes: usize = 6 * 1024,
    units: usize = 3000,
    /// Loose on purpose: this is a "something is catastrophically wrong"
    /// tripwire, not a performance target.
    max_p99_ms: f64 = 250,
};

const Params = struct {
    seed: u64,
    scale: f64,
    docs: usize,
    avg_doc_bytes: usize,
    corpus_bytes: usize,
    units: usize,
    max_p99_ms: f64,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var tunables: Tunables = .{};
    const options = try report.Options.parseWith(args, &tunables);

    const docs = options.sized(tunables.docs);
    const units = options.sized(tunables.units);

    var gpa_state: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    const gpa = gpa_state.allocator();

    var builder = report.Builder.init(init.gpa, io, "load", "load");
    defer builder.deinit();

    std.debug.print("load: {d} units over {d} documents (seed 0x{X})\n", .{ units, docs, options.seed });

    // ---- Fixture ----------------------------------------------------------

    // Deliberately no `defer` on the fixtures: they have to be freed
    // *before* the allocator's leak check below, so teardown is explicit and
    // ordered rather than unwound at scope exit.
    var corpus = try workload.Corpus.generate(gpa, options.seed, docs, tunables.avg_doc_bytes);

    const corpus_bytes = corpus.totalBytes();
    try builder.check(
        "corpus generated",
        corpus.docs.len == docs and corpus_bytes > 0,
        "corpus is empty",
        0,
        &.{
            .{ .name = "documents", .value = @floatFromInt(corpus.docs.len), .unit = "count" },
            .{ .name = "corpus_bytes", .value = @floatFromInt(corpus_bytes), .unit = "bytes" },
        },
    );

    // ---- Reference pass ---------------------------------------------------
    //
    // One clean pass to establish what each document *should* digest to.
    // Everything after this compares against it.

    const reference = try gpa.alloc(u64, corpus.docs.len);

    const ref_sw = report.Stopwatch.begin(io);
    for (corpus.docs, reference) |doc, *slot| slot.* = try workload.runUnit(gpa, doc);
    try builder.check(
        "reference pass computed a digest per document",
        true,
        "",
        ref_sw.elapsedMs(),
        &.{.{ .name = "digests", .value = @floatFromInt(reference.len), .unit = "count" }},
    );

    // Outstanding bytes with only the corpus and the reference array alive.
    // Every unit must return here.
    const baseline_bytes = gpa_state.total_requested_bytes;

    // ---- Sustained load ---------------------------------------------------

    var latencies = report.Samples.init(init.gpa);
    defer latencies.deinit();

    var peak_bytes: usize = baseline_bytes;
    var digest_mismatch_at: ?usize = null;
    var leak_at: ?usize = null;
    var leak_bytes: usize = 0;

    const load_sw = report.Stopwatch.begin(io);
    var i: usize = 0;
    while (i < units) : (i += 1) {
        const index = i % corpus.docs.len;

        const unit_sw = report.Stopwatch.begin(io);
        const digest = try workload.runUnit(gpa, corpus.docs[index]);
        try latencies.add(unit_sw.elapsedNs());

        if (digest != reference[index] and digest_mismatch_at == null) {
            digest_mismatch_at = i;
        }

        const in_use = gpa_state.total_requested_bytes;
        peak_bytes = @max(peak_bytes, in_use);
        if (in_use != baseline_bytes and leak_at == null) {
            leak_at = i;
            leak_bytes = in_use - baseline_bytes;
        }
    }
    const load_ms = load_sw.elapsedMs();

    // ---- Verdicts ---------------------------------------------------------

    try builder.check(
        "every unit reproduces its reference digest under sustained volume",
        digest_mismatch_at == null,
        try builder.fmt("digest changed at unit {?d}", .{digest_mismatch_at}),
        load_ms,
        &.{.{ .name = "units", .value = @floatFromInt(units), .unit = "count" }},
    );

    try builder.check(
        "outstanding bytes return to the baseline after every unit",
        leak_at == null,
        try builder.fmt("unit {?d} left {d} bytes outstanding", .{ leak_at, leak_bytes }),
        0,
        &.{
            .{ .name = "baseline_bytes", .value = @floatFromInt(baseline_bytes), .unit = "bytes" },
            .{ .name = "peak_bytes", .value = @floatFromInt(peak_bytes), .unit = "bytes" },
            .{ .name = "peak_over_baseline_bytes", .value = @floatFromInt(peak_bytes - baseline_bytes), .unit = "bytes" },
        },
    );

    const stats = latencies.stats();
    const seconds = load_ms / 1000.0;
    const ops_per_sec = if (seconds > 0) @as(f64, @floatFromInt(units)) / seconds else 0;
    const bytes_processed = @as(f64, @floatFromInt(corpus_bytes)) *
        (@as(f64, @floatFromInt(units)) / @as(f64, @floatFromInt(corpus.docs.len)));

    var throughput_metrics: [10]report.Metric = undefined;
    throughput_metrics[0] = .{ .name = "ops_per_sec", .value = ops_per_sec, .unit = "ops/s" };
    throughput_metrics[1] = .{
        .name = "megabytes_per_sec",
        .value = if (seconds > 0) bytes_processed / seconds / (1024 * 1024) else 0,
        .unit = "MiB/s",
    };
    throughput_metrics[2] = .{ .name = "wall_ms", .value = load_ms, .unit = "ms" };
    for (stats.metrics(), 3..) |m, slot| throughput_metrics[slot] = m;

    try builder.check(
        "p99 latency stays under the ceiling",
        report.nsToMs(stats.p99_ns) <= tunables.max_p99_ms,
        try builder.fmt("p99 {d:.2}ms exceeds the {d:.2}ms ceiling", .{
            report.nsToMs(stats.p99_ns),
            tunables.max_p99_ms,
        }),
        0,
        &throughput_metrics,
    );

    // ---- Teardown ---------------------------------------------------------
    //
    // Freed before the leak check so the corpus and the reference array are
    // not themselves reported as leaks.

    corpus.deinit();
    gpa.free(reference);

    const leaked = gpa_state.deinit() == .leak;
    try builder.check("the allocator reports no leaks", !leaked, "allocator detected leaked memory", 0, &.{});

    const passed = try builder.finish(Params{
        .seed = options.seed,
        .scale = options.scale,
        .docs = docs,
        .avg_doc_bytes = tunables.avg_doc_bytes,
        .corpus_bytes = corpus_bytes,
        .units = units,
        .max_p99_ms = tunables.max_p99_ms,
    }, options.out_dir);

    if (!passed) std.process.exit(1);
}
