//! Shared reporting harness for the non-unit test suites.
//!
//! Every suite in this directory — load, stress, chaos, sync, bench, and the
//! custom unit-test runner — emits the same JSON document under
//! `reports/<suite>.json`, so one tool can read all six. The shape is:
//!
//! ```json
//! {
//!   "schema": "memweave.testreport/v1",
//!   "kind": "load",
//!   "suite": "load",
//!   "status": "pass",
//!   "started_at_unix_ms": 1757203200000,
//!   "duration_ms": 1843.2,
//!   "environment": { "zig_version": "0.16.0", "os": "linux", ... },
//!   "parameters": { "seed": 6148914691236517205, "units": 2000, ... },
//!   "totals": { "cases": 7, "passed": 7, "failed": 0, "skipped": 0 },
//!   "cases": [
//!     { "name": "...", "status": "pass", "duration_ms": 12.4,
//!       "metrics": [ { "name": "ops_per_sec", "value": 8123.4, "unit": "ops/s" } ] }
//!   ]
//! }
//! ```
//!
//! Metrics are a flat `{name, value, unit}` list rather than a free-form
//! object on purpose: it keeps the schema stable across suites, so a
//! regression tracker can diff `bench.json` against a previous run without
//! knowing anything about which benchmarks exist.
//!
//! `parameters` is the one part that varies, so `Document` is generic over
//! it — each suite declares its own strongly typed params struct, and the
//! seed that reproduces a failure is always in the file.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const schema_version = "memweave.testreport/v1";

pub const Status = enum { pass, fail, skip };

/// One measurement. `unit` is free text ("ops/s", "ms", "bytes", "count",
/// "ratio") and exists so a reader never has to guess at scale.
pub const Metric = struct {
    name: []const u8,
    value: f64,
    unit: []const u8,
};

pub const Case = struct {
    name: []const u8,
    status: Status,
    duration_ms: f64 = 0,
    /// Why it failed, or what it covered. Shown next to the name in the
    /// terminal summary.
    detail: []const u8 = "",
    metrics: []const Metric = &.{},
};

pub const Environment = struct {
    zig_version: []const u8,
    os: []const u8,
    arch: []const u8,
    optimize: []const u8,
    single_threaded: bool,
    cpu_count: u32,
};

pub const Totals = struct {
    cases: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,
};

pub fn Document(comptime Params: type) type {
    return struct {
        schema: []const u8 = schema_version,
        kind: []const u8,
        suite: []const u8,
        library: []const u8 = "memweave-zig",
        status: Status,
        started_at_unix_ms: i64,
        duration_ms: f64,
        environment: Environment,
        parameters: Params,
        totals: Totals,
        cases: []const Case,
    };
}

pub fn environment() Environment {
    return .{
        .zig_version = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .optimize = @tagName(builtin.mode),
        .single_threaded = builtin.single_threaded,
        .cpu_count = @intCast(std.Thread.getCpuCount() catch 1),
    };
}

// ---------------------------------------------------------------------------
// Builder
// ---------------------------------------------------------------------------

/// Accumulates cases, then writes the document.
///
/// Everything handed to `record` is copied into the builder's own arena, so
/// callers can pass stack buffers and formatted strings without thinking
/// about lifetimes — the usual shape is a loop that formats a case name per
/// iteration.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    io: Io,
    kind: []const u8,
    suite: []const u8,
    arena_state: std.heap.ArenaAllocator,
    cases: std.ArrayList(Case),
    started_wall: Io.Timestamp,
    started_mono: Io.Timestamp,

    pub fn init(gpa: std.mem.Allocator, io: Io, kind: []const u8, suite: []const u8) Builder {
        return .{
            .gpa = gpa,
            .io = io,
            .kind = kind,
            .suite = suite,
            .arena_state = .init(gpa),
            .cases = .empty,
            .started_wall = .now(io, .real),
            .started_mono = .now(io, .awake),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.cases.deinit(self.gpa);
        self.arena_state.deinit();
    }

    /// Scratch allocator whose lifetime matches the report. Useful for
    /// building case names before recording them.
    pub fn arena(self: *Builder) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn fmt(self: *Builder, comptime template: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.arena(), template, args);
    }

    /// Record one case, deep-copying its strings and metrics.
    pub fn record(self: *Builder, case: Case) !void {
        const a = self.arena();
        const metrics = try a.alloc(Metric, case.metrics.len);
        for (case.metrics, metrics) |src, *dst| dst.* = .{
            .name = try a.dupe(u8, src.name),
            .value = src.value,
            .unit = try a.dupe(u8, src.unit),
        };
        try self.cases.append(self.gpa, .{
            .name = try a.dupe(u8, case.name),
            .status = case.status,
            .duration_ms = case.duration_ms,
            .detail = try a.dupe(u8, case.detail),
            .metrics = metrics,
        });
        const mark: []const u8 = switch (case.status) {
            .pass => "ok  ",
            .fail => "FAIL",
            .skip => "skip",
        };
        std.debug.print("  {s} {s}\n", .{ mark, case.name });
        if (case.status == .fail and case.detail.len > 0) {
            std.debug.print("       {s}\n", .{case.detail});
        }
    }

    /// Convenience for the common "assert a condition, record the outcome"
    /// shape: passes when `ok`, fails with `detail` otherwise.
    pub fn check(
        self: *Builder,
        name: []const u8,
        ok: bool,
        detail: []const u8,
        duration_ms: f64,
        metrics: []const Metric,
    ) !void {
        try self.record(.{
            .name = name,
            .status = if (ok) .pass else .fail,
            .duration_ms = duration_ms,
            .detail = if (ok) "" else detail,
            .metrics = metrics,
        });
    }

    /// Serialize to `<out_dir>/<suite>.json` and return whether every case
    /// passed. Creates `out_dir` if it does not exist.
    pub fn finish(self: *Builder, params: anytype, out_dir: []const u8) !bool {
        var totals: Totals = .{};
        for (self.cases.items) |c| {
            totals.cases += 1;
            switch (c.status) {
                .pass => totals.passed += 1,
                .fail => totals.failed += 1,
                .skip => totals.skipped += 1,
            }
        }
        const passed = totals.failed == 0;

        const elapsed_ns = self.started_mono.durationTo(Io.Timestamp.now(self.io, .awake)).nanoseconds;
        const doc: Document(@TypeOf(params)) = .{
            .kind = self.kind,
            .suite = self.suite,
            .status = if (passed) .pass else .fail,
            .started_at_unix_ms = @intCast(@divTrunc(self.started_wall.nanoseconds, std.time.ns_per_ms)),
            .duration_ms = nsToMs(elapsed_ns),
            .environment = environment(),
            .parameters = params,
            .totals = totals,
            .cases = self.cases.items,
        };

        const json = try std.json.Stringify.valueAlloc(self.gpa, doc, .{ .whitespace = .indent_2 });
        defer self.gpa.free(json);

        const dir = Io.Dir.cwd();
        dir.createDirPath(self.io, out_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const path = try std.fmt.allocPrint(self.arena(), "{s}/{s}.json", .{ out_dir, self.suite });
        try dir.writeFile(self.io, .{ .sub_path = path, .data = json });

        std.debug.print("{s}: {s} — {d} cases, {d} failed, {d:.1}ms -> {s}\n", .{
            self.suite,
            if (passed) "PASS" else "FAIL",
            totals.cases,
            totals.failed,
            nsToMs(elapsed_ns),
            path,
        });
        return passed;
    }
};

// ---------------------------------------------------------------------------
// Timing and statistics
// ---------------------------------------------------------------------------

pub fn nsToMs(ns: anytype) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

/// Monotonic stopwatch. `std.time.Timer` is gone in Zig 0.16; timing now
/// comes off the `Io` clock.
pub const Stopwatch = struct {
    io: Io,
    start: Io.Timestamp,

    pub fn begin(io: Io) Stopwatch {
        return .{ .io = io, .start = .now(io, .awake) };
    }

    pub fn elapsedNs(self: Stopwatch) u64 {
        const d = self.start.durationTo(Io.Timestamp.now(self.io, .awake)).nanoseconds;
        return if (d < 0) 0 else @intCast(d);
    }

    pub fn elapsedMs(self: Stopwatch) f64 {
        return nsToMs(self.elapsedNs());
    }

    pub fn restart(self: *Stopwatch) u64 {
        const ns = self.elapsedNs();
        self.start = .now(self.io, .awake);
        return ns;
    }
};

pub const Stats = struct {
    count: u64 = 0,
    min_ns: u64 = 0,
    p50_ns: u64 = 0,
    p90_ns: u64 = 0,
    p99_ns: u64 = 0,
    max_ns: u64 = 0,
    mean_ns: f64 = 0,

    /// The seven latency metrics, in milliseconds, ready to hand to
    /// `Builder.record`.
    pub fn metrics(self: Stats) [7]Metric {
        return .{
            .{ .name = "samples", .value = @floatFromInt(self.count), .unit = "count" },
            .{ .name = "latency_min_ms", .value = nsToMs(self.min_ns), .unit = "ms" },
            .{ .name = "latency_p50_ms", .value = nsToMs(self.p50_ns), .unit = "ms" },
            .{ .name = "latency_p90_ms", .value = nsToMs(self.p90_ns), .unit = "ms" },
            .{ .name = "latency_p99_ms", .value = nsToMs(self.p99_ns), .unit = "ms" },
            .{ .name = "latency_max_ms", .value = nsToMs(self.max_ns), .unit = "ms" },
            .{ .name = "latency_mean_ms", .value = self.mean_ns / @as(f64, std.time.ns_per_ms), .unit = "ms" },
        };
    }
};

/// A growable set of latency samples. Sorting happens once, in `stats()`.
pub const Samples = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(u64) = .empty,

    pub fn init(gpa: std.mem.Allocator) Samples {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Samples) void {
        self.items.deinit(self.gpa);
    }

    pub fn add(self: *Samples, ns: u64) !void {
        try self.items.append(self.gpa, ns);
    }

    pub fn stats(self: *Samples) Stats {
        if (self.items.items.len == 0) return .{};
        std.mem.sort(u64, self.items.items, {}, std.sort.asc(u64));
        const s = self.items.items;

        var total: u128 = 0;
        for (s) |v| total += v;

        return .{
            .count = s.len,
            .min_ns = s[0],
            .p50_ns = percentile(s, 50),
            .p90_ns = percentile(s, 90),
            .p99_ns = percentile(s, 99),
            .max_ns = s[s.len - 1],
            .mean_ns = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(s.len)),
        };
    }
};

/// Nearest-rank percentile over an already-sorted slice.
fn percentile(sorted: []const u64, p: u64) u64 {
    std.debug.assert(sorted.len > 0);
    const rank = (p * sorted.len + 99) / 100; // ceil(p/100 * n)
    const idx = @min(sorted.len, @max(1, rank)) - 1;
    return sorted[idx];
}

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------

/// Options every suite understands.
///
/// `--scale` is what makes these runnable both locally and in CI: it
/// multiplies every workload size, so `--scale=0.1` turns a two-minute soak
/// of the load suite into a twelve-second smoke test without changing which
/// assertions run.
const NoExtra = struct {};

pub const Options = struct {
    /// Recorded in every report, so a failure is reproducible verbatim.
    seed: u64 = 0x9E3779B97F4A7C15,
    scale: f64 = 1.0,
    /// 0 means "one per logical CPU".
    threads: u32 = 0,
    out_dir: []const u8 = "reports",

    pub fn parse(args: []const [:0]const u8) !Options {
        var none: NoExtra = .{};
        return parseWith(args, &none);
    }

    /// `parse` plus suite-specific flags.
    ///
    /// `extra` is a pointer to a struct whose fields *are* the flag list:
    /// a field `max_p99_ms: f64` accepts `--max-p99-ms=12.5`. Keeping the
    /// flags and the parameters that end up in the JSON report as one struct
    /// means a suite cannot accept an option it then forgets to record.
    pub fn parseWith(args: []const [:0]const u8, extra: anytype) !Options {
        const Extra = @TypeOf(extra.*);
        var self: Options = .{};

        for (args[@min(1, args.len)..]) |arg| {
            if (value(arg, "--seed=")) |v| {
                self.seed = try std.fmt.parseUnsigned(u64, v, 0);
                continue;
            } else if (value(arg, "--scale=")) |v| {
                self.scale = try std.fmt.parseFloat(f64, v);
                if (!(self.scale > 0)) return error.InvalidScale;
                continue;
            } else if (value(arg, "--threads=")) |v| {
                self.threads = try std.fmt.parseUnsigned(u32, v, 10);
                continue;
            } else if (value(arg, "--out=")) |v| {
                self.out_dir = v;
                continue;
            }

            var matched = false;
            inline for (@typeInfo(Extra).@"struct".fields) |field| {
                if (value(arg, "--" ++ comptime dashed(field.name) ++ "=")) |v| {
                    @field(extra, field.name) = try parseField(field.type, v);
                    matched = true;
                }
            }
            if (!matched) {
                std.debug.print("unknown argument '{s}'\n", .{arg});
                printUsage(Extra);
                return error.InvalidArgument;
            }
        }
        return self;
    }

    fn parseField(comptime T: type, text: []const u8) !T {
        if (T == []const u8) return text;
        return switch (@typeInfo(T)) {
            .int => try std.fmt.parseUnsigned(T, text, 0),
            .float => try std.fmt.parseFloat(T, text),
            .bool => std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1"),
            else => @compileError("unsupported option type " ++ @typeName(T)),
        };
    }

    fn printUsage(comptime Extra: type) void {
        std.debug.print("usage: [--seed=N] [--scale=F] [--threads=N] [--out=DIR]", .{});
        inline for (@typeInfo(Extra).@"struct".fields) |field| {
            std.debug.print(" [--{s}=V]", .{comptime dashed(field.name)});
        }
        std.debug.print("\n", .{});
    }

    fn dashed(comptime name: []const u8) []const u8 {
        comptime var out: [name.len]u8 = undefined;
        inline for (name, 0..) |c, i| out[i] = if (c == '_') '-' else c;
        const frozen = out;
        return &frozen;
    }

    /// `n` scaled by `--scale`, never below 1 — a scaled-down run must still
    /// execute every case, just with less volume.
    pub fn sized(self: Options, n: usize) usize {
        const scaled = @as(f64, @floatFromInt(n)) * self.scale;
        if (scaled < 1) return 1;
        return @intFromFloat(scaled);
    }

    pub fn threadCount(self: Options) u32 {
        if (self.threads > 0) return self.threads;
        return @intCast(std.Thread.getCpuCount() catch 1);
    }

    fn value(arg: []const u8, prefix: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, arg, prefix)) return null;
        return arg[prefix.len..];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "percentiles use nearest-rank over the sorted samples" {
    var s = Samples.init(std.testing.allocator);
    defer s.deinit();
    // Deliberately out of order: stats() must sort.
    for ([_]u64{ 100, 10, 50, 90, 20, 80, 30, 70, 40, 60 }) |v| try s.add(v);

    const st = s.stats();
    try std.testing.expectEqual(@as(u64, 10), st.count);
    try std.testing.expectEqual(@as(u64, 10), st.min_ns);
    try std.testing.expectEqual(@as(u64, 50), st.p50_ns);
    try std.testing.expectEqual(@as(u64, 90), st.p90_ns);
    try std.testing.expectEqual(@as(u64, 100), st.p99_ns);
    try std.testing.expectEqual(@as(u64, 100), st.max_ns);
    try std.testing.expectEqual(@as(f64, 55), st.mean_ns);
}

test "an empty sample set yields zeroed stats rather than a crash" {
    var s = Samples.init(std.testing.allocator);
    defer s.deinit();
    const st = s.stats();
    try std.testing.expectEqual(@as(u64, 0), st.count);
    try std.testing.expectEqual(@as(u64, 0), st.p99_ns);
}

test "a single sample is every percentile" {
    var s = Samples.init(std.testing.allocator);
    defer s.deinit();
    try s.add(42);
    const st = s.stats();
    try std.testing.expectEqual(@as(u64, 42), st.min_ns);
    try std.testing.expectEqual(@as(u64, 42), st.p50_ns);
    try std.testing.expectEqual(@as(u64, 42), st.max_ns);
}

test "Options parses every flag and rejects nonsense" {
    const args = [_][:0]const u8{ "suite", "--seed=7", "--scale=0.25", "--threads=3", "--out=/tmp/r" };
    const o = try Options.parse(&args);
    try std.testing.expectEqual(@as(u64, 7), o.seed);
    try std.testing.expectEqual(@as(f64, 0.25), o.scale);
    try std.testing.expectEqual(@as(u32, 3), o.threadCount());
    try std.testing.expectEqualStrings("/tmp/r", o.out_dir);

    try std.testing.expectError(error.InvalidArgument, Options.parse(&[_][:0]const u8{ "s", "--nope" }));
    try std.testing.expectError(error.InvalidScale, Options.parse(&[_][:0]const u8{ "s", "--scale=0" }));
}

test "sized() scales volume but never below one" {
    const o: Options = .{ .scale = 0.1 };
    try std.testing.expectEqual(@as(usize, 100), o.sized(1000));
    try std.testing.expectEqual(@as(usize, 1), o.sized(5));
    try std.testing.expectEqual(@as(usize, 1), o.sized(0));

    const full: Options = .{};
    try std.testing.expectEqual(@as(usize, 1000), full.sized(1000));
}

test "suite-specific flags come from the extra struct's field names" {
    const Extra = struct {
        max_p99_ms: f64 = 50,
        docs: u32 = 64,
        label: []const u8 = "",
    };
    var extra: Extra = .{};
    const o = try Options.parseWith(&[_][:0]const u8{
        "suite", "--scale=2", "--max-p99-ms=12.5", "--docs=8", "--label=quick",
    }, &extra);

    try std.testing.expectEqual(@as(f64, 2), o.scale);
    try std.testing.expectEqual(@as(f64, 12.5), extra.max_p99_ms);
    try std.testing.expectEqual(@as(u32, 8), extra.docs);
    try std.testing.expectEqualStrings("quick", extra.label);

    // Unmentioned flags keep their declared defaults.
    var untouched: Extra = .{};
    _ = try Options.parseWith(&[_][:0]const u8{"suite"}, &untouched);
    try std.testing.expectEqual(@as(f64, 50), untouched.max_p99_ms);

    // A flag the extra struct does not declare is still an error.
    var reject: Extra = .{};
    try std.testing.expectError(
        error.InvalidArgument,
        Options.parseWith(&[_][:0]const u8{ "suite", "--nope=1" }, &reject),
    );
}

test "hex and decimal seeds both parse" {
    const hex = try Options.parse(&[_][:0]const u8{ "s", "--seed=0xdeadbeef" });
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), hex.seed);
    const dec = try Options.parse(&[_][:0]const u8{ "s", "--seed=123" });
    try std.testing.expectEqual(@as(u64, 123), dec.seed);
}
