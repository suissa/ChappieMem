//! Sync: is the library safe to use from more than one thread at a time?
//!
//! Every public function here takes its allocator as a parameter and touches
//! no global mutable state — which is a *claim*, not a proof. This suite is
//! the proof, and it works by exploiting the one property the workload
//! guarantees: a document always digests to the same value.
//!
//! Establish those digests on a single thread, then recompute them from many
//! threads at once. Any shared mutable state — a cached buffer, a static
//! scratch area, a lazily initialized global — shows up as a digest that
//! disagrees with the reference. There is no sampling and no heuristic: a
//! single mismatch fails the run and names the thread and iteration.
//!
//! Three arrangements, because they fail differently:
//!
//!   1. **Private allocators.** Each thread gets its own arena. Anything
//!      that breaks here is state inside the library itself.
//!   2. **One shared allocator.** All threads hammer a single thread-safe
//!      allocator, so the run is dominated by lock contention and by
//!      interleaved alloc/free traffic — the arrangement most likely to
//!      expose a use-after-free or a cross-thread aliasing bug.
//!   3. **The same document, everywhere, at once.** Every thread reads the
//!      identical bytes and the identical comptime configuration in lockstep,
//!      which is the sharpest test for accidental writes to shared data.
//!
//! Scaling numbers are recorded but never asserted: on a shared CI runner
//! the thread count bears no relation to the cores actually available, so a
//! speedup target would measure the runner, not the library.

const std = @import("std");
const report = @import("report.zig");
const workload = @import("workload.zig");

const Tunables = struct {
    docs: usize = 48,
    avg_doc_bytes: usize = 4 * 1024,
    /// Units each thread runs, per arrangement.
    iterations_per_thread: usize = 120,
    /// Thread counts are doubled from 1 up to this multiple of the CPU count,
    /// so the suite also runs oversubscribed.
    max_oversubscription: u32 = 2,
};

const Params = struct {
    seed: u64,
    scale: f64,
    docs: usize,
    avg_doc_bytes: usize,
    iterations_per_thread: usize,
    cpu_count: u32,
    max_threads: u32,
    single_thread_ops_per_sec: f64,
};

/// What one worker needs. Everything behind a `*const` is shared and must
/// stay read-only for the whole run — that is the property under test.
const Worker = struct {
    corpus: *const workload.Corpus,
    reference: []const u64,
    iterations: usize,
    thread_index: usize,
    /// Null means "use the shared allocator instead of a private arena".
    shared: ?std.mem.Allocator,
    backing: std.mem.Allocator,

    mismatches: *std.atomic.Value(u64),
    completed: *std.atomic.Value(u64),
    failures: *std.atomic.Value(u64),
    /// When set, every iteration runs this one document rather than walking
    /// the corpus.
    pinned_doc: ?usize,

    fn run(self: Worker) void {
        var arena_state: ?std.heap.ArenaAllocator =
            if (self.shared == null) std.heap.ArenaAllocator.init(self.backing) else null;
        defer if (arena_state) |*a| a.deinit();

        var i: usize = 0;
        while (i < self.iterations) : (i += 1) {
            const index = self.pinned_doc orelse
                ((self.thread_index + i) % self.corpus.docs.len);

            const gpa = if (self.shared) |s| s else arena_state.?.allocator();
            const digest = workload.runUnit(gpa, self.corpus.docs[index]) catch {
                _ = self.failures.fetchAdd(1, .monotonic);
                continue;
            };
            if (digest != self.reference[index]) {
                _ = self.mismatches.fetchAdd(1, .monotonic);
            }
            _ = self.completed.fetchAdd(1, .monotonic);

            // An arena would otherwise grow without bound across iterations;
            // resetting keeps the private-allocator arrangement honest about
            // per-unit allocation.
            if (arena_state) |*a| _ = a.reset(.retain_capacity);
        }
    }
};

const Outcome = struct {
    mismatches: u64,
    failures: u64,
    completed: u64,
    expected: u64,
    wall_ms: f64,

    fn opsPerSec(self: Outcome) f64 {
        const seconds = self.wall_ms / 1000.0;
        if (seconds <= 0) return 0;
        return @as(f64, @floatFromInt(self.completed)) / seconds;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var tunables: Tunables = .{};
    const options = try report.Options.parseWith(args, &tunables);

    const docs = options.sized(tunables.docs);
    const iterations = options.sized(tunables.iterations_per_thread);

    // Thread-safe on purpose: arrangement 2 shares this across every worker.
    var gpa_state: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    const gpa = gpa_state.allocator();

    var builder = report.Builder.init(init.gpa, io, "sync", "sync");
    defer builder.deinit();

    const cpu_count: u32 = @intCast(std.Thread.getCpuCount() catch 1);
    const max_threads = if (options.threads > 0)
        options.threads
    else
        @max(2, cpu_count * tunables.max_oversubscription);

    std.debug.print("sync: up to {d} threads on {d} CPUs, {d} iterations each (seed 0x{X})\n", .{
        max_threads,
        cpu_count,
        iterations,
        options.seed,
    });

    // ---- Reference --------------------------------------------------------

    var corpus = try workload.Corpus.generate(gpa, options.seed, docs, tunables.avg_doc_bytes);
    const reference = try gpa.alloc(u64, corpus.docs.len);

    for (corpus.docs, reference) |doc, *slot| slot.* = try workload.runUnit(gpa, doc);
    try builder.check(
        "single-threaded reference digests computed",
        true,
        "",
        0,
        &.{.{ .name = "documents", .value = @floatFromInt(reference.len), .unit = "count" }},
    );

    // ---- 1. Private allocators --------------------------------------------

    var single_thread_ops: f64 = 0;
    var threads: u32 = 1;
    while (threads <= max_threads) : (threads *= 2) {
        const outcome = try runArrangement(gpa, io, .{
            .corpus = &corpus,
            .reference = reference,
            .iterations = iterations,
            .threads = threads,
            .shared = null,
            .pinned_doc = null,
        });
        if (threads == 1) single_thread_ops = outcome.opsPerSec();

        try recordArrangement(&builder, "private arenas", threads, outcome, single_thread_ops);
    }

    // ---- 2. One shared, thread-safe allocator -----------------------------

    threads = 2;
    while (threads <= max_threads) : (threads *= 2) {
        const outcome = try runArrangement(gpa, io, .{
            .corpus = &corpus,
            .reference = reference,
            .iterations = iterations,
            .threads = threads,
            .shared = gpa,
            .pinned_doc = null,
        });
        try recordArrangement(&builder, "one shared allocator", threads, outcome, single_thread_ops);
    }

    // ---- 3. Every thread on the same document -----------------------------

    if (corpus.docs.len > 0) {
        const outcome = try runArrangement(gpa, io, .{
            .corpus = &corpus,
            .reference = reference,
            .iterations = iterations,
            .threads = max_threads,
            .shared = null,
            .pinned_doc = 0,
        });
        try recordArrangement(&builder, "same document on every thread", max_threads, outcome, single_thread_ops);
    }

    // ---- Teardown ---------------------------------------------------------

    corpus.deinit();
    gpa.free(reference);
    const leaked = gpa_state.deinit() == .leak;
    try builder.check("the allocator reports no leaks", !leaked, "allocator detected leaked memory", 0, &.{});

    const passed = try builder.finish(Params{
        .seed = options.seed,
        .scale = options.scale,
        .docs = docs,
        .avg_doc_bytes = tunables.avg_doc_bytes,
        .iterations_per_thread = iterations,
        .cpu_count = cpu_count,
        .max_threads = max_threads,
        .single_thread_ops_per_sec = single_thread_ops,
    }, options.out_dir);

    if (!passed) std.process.exit(1);
}

const Arrangement = struct {
    corpus: *const workload.Corpus,
    reference: []const u64,
    iterations: usize,
    threads: u32,
    shared: ?std.mem.Allocator,
    pinned_doc: ?usize,
};

fn runArrangement(gpa: std.mem.Allocator, io: std.Io, arrangement: Arrangement) !Outcome {
    var mismatches: std.atomic.Value(u64) = .init(0);
    var completed: std.atomic.Value(u64) = .init(0);
    var failures: std.atomic.Value(u64) = .init(0);

    const handles = try gpa.alloc(std.Thread, arrangement.threads);
    defer gpa.free(handles);

    const sw = report.Stopwatch.begin(io);
    for (handles, 0..) |*handle, index| {
        handle.* = try std.Thread.spawn(.{}, Worker.run, .{Worker{
            .corpus = arrangement.corpus,
            .reference = arrangement.reference,
            .iterations = arrangement.iterations,
            .thread_index = index,
            .shared = arrangement.shared,
            .backing = gpa,
            .mismatches = &mismatches,
            .completed = &completed,
            .failures = &failures,
            .pinned_doc = arrangement.pinned_doc,
        }});
    }
    for (handles) |handle| handle.join();

    return .{
        .mismatches = mismatches.load(.seq_cst),
        .failures = failures.load(.seq_cst),
        .completed = completed.load(.seq_cst),
        .expected = @as(u64, arrangement.threads) * arrangement.iterations,
        .wall_ms = sw.elapsedMs(),
    };
}

fn recordArrangement(
    builder: *report.Builder,
    arrangement: []const u8,
    threads: u32,
    outcome: Outcome,
    single_thread_ops: f64,
) !void {
    const clean = outcome.mismatches == 0 and outcome.failures == 0 and
        outcome.completed == outcome.expected;

    try builder.check(
        try builder.fmt("{d} threads, {s}: identical digests and no lost work", .{ threads, arrangement }),
        clean,
        try builder.fmt("{d} digest mismatch(es), {d} error(s), {d} of {d} units completed", .{
            outcome.mismatches,
            outcome.failures,
            outcome.completed,
            outcome.expected,
        }),
        outcome.wall_ms,
        &.{
            .{ .name = "threads", .value = @floatFromInt(threads), .unit = "count" },
            .{ .name = "units_completed", .value = @floatFromInt(outcome.completed), .unit = "count" },
            .{ .name = "digest_mismatches", .value = @floatFromInt(outcome.mismatches), .unit = "count" },
            .{ .name = "ops_per_sec", .value = outcome.opsPerSec(), .unit = "ops/s" },
            .{
                .name = "speedup_vs_single_thread",
                .value = if (single_thread_ops > 0) outcome.opsPerSec() / single_thread_ops else 0,
                .unit = "ratio",
            },
        },
    );
}
