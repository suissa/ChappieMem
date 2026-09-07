const std = @import("std");

/// The measured suites. Each is `testing/<name>.zig` with a `main`, gets its
/// own `zig build <name>` step, and writes `reports/<name>.json`.
const suites = [_]Suite{
    .{ .name = "load", .description = "Sustained-volume load test -> reports/load.json" },
    .{ .name = "stress", .description = "Escalating-pressure stress test -> reports/stress.json" },
    .{ .name = "chaos", .description = "Fault-injection and fuzzing chaos test -> reports/chaos.json" },
    .{ .name = "sync", .description = "Concurrency and thread-safety test -> reports/sync.json" },
    .{ .name = "bench", .description = "Micro-benchmarks -> reports/bench.json" },
};

const Suite = struct {
    name: []const u8,
    description: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `fts5` defaults to `false` in zig-sqlite's own build.zig — chunks_fts
    // (a `CREATE VIRTUAL TABLE ... USING fts5(...)`, see storage/schema.zig)
    // needs the module compiled in, so request it explicitly here.
    const sqlite_dep = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
        .fts5 = true,
    });

    const mod = b.addModule("memweave", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wireSqlite(mod, sqlite_dep);

    // ---- Unit tests -------------------------------------------------------
    //
    // The stock test runner is replaced by one that emits the same JSON
    // report as the measured suites. It runs the same `test` blocks either
    // way; see testing/unit_runner.zig.

    const tests = b.addTest(.{
        .root_module = mod,
        .test_runner = .{ .path = b.path("testing/unit_runner.zig"), .mode = .simple },
    });

    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    // Writing the report is the point, so never skip the run as up-to-date.
    run_tests.has_side_effects = true;

    const test_step = b.step("test", "Run unit tests -> reports/unit.json");
    test_step.dependOn(&run_tests.step);

    // Real sqlite-vec integration is a separate step so ordinary unit tests
    // remain zero-infrastructure. CI downloads a pinned official sqlite-vec
    // loadable extension and passes its path with -Dsqlite-vec-extension=...
    const sqlite_vec_extension = b.option(
        []const u8,
        "sqlite-vec-extension",
        "Path to a sqlite-vec loadable extension for `zig build test-vector`",
    ) orelse "";

    const vector_test_options = b.addOptions();
    vector_test_options.addOption([]const u8, "sqlite_vec_extension", sqlite_vec_extension);

    const vector_integration_mod = b.addModule("memweave-vector-integration", .{
        .root_source_file = b.path("src/search/vector_integration.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wireSqlite(vector_integration_mod, sqlite_dep);
    vector_integration_mod.addImport("memweave", mod);
    vector_integration_mod.addImport("vector_test_options", vector_test_options.createModule());

    const vector_tests = b.addTest(.{
        .root_module = vector_integration_mod,
    });
    const run_vector_tests = b.addRunArtifact(vector_tests);

    const vector_test_step = b.step("test-vector", "Run sqlite-vec integration tests");
    vector_test_step.dependOn(&run_vector_tests.step);

    // ---- Measured suites --------------------------------------------------
    //
    // ReleaseSafe by default rather than ReleaseFast: stress and chaos are
    // only meaningful while the safety checks that catch undefined behaviour
    // are still compiled in, and the difference on this workload is small.
    // Override with -Dperf-optimize=ReleaseFast for pure benchmarking; every
    // report records the mode it was built in.

    const perf_optimize = b.option(
        std.builtin.OptimizeMode,
        "perf-optimize",
        "Optimize mode for the load/stress/chaos/sync/bench suites (default: ReleaseSafe)",
    ) orelse .ReleaseSafe;

    // SQLite has to be built at the same optimize mode as whatever links it:
    // the C sources are instrumented per mode, and a Debug `libsqlite.a`
    // linked into a ReleaseSafe binary fails with undefined `__ubsan_handle_*`
    // symbols. `b.dependency` caches per option set, so this is the same
    // build as above whenever the two modes coincide.
    const perf_sqlite_dep = b.dependency("sqlite", .{
        .target = target,
        .optimize = perf_optimize,
        .fts5 = true,
    });

    // The same library, compiled at `perf_optimize` instead. It goes through
    // `wireSqlite` like the public module does, so the two cannot drift apart
    // when the library gains a dependency.
    const perf_lib = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = perf_optimize,
        .link_libc = true,
    });
    wireSqlite(perf_lib, perf_sqlite_dep);

    const verify_step = b.step("verify", "Run every suite -> reports/*.json");
    verify_step.dependOn(&run_tests.step);

    for (suites) |suite| {
        const suite_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("testing/{s}.zig", .{suite.name})),
            .target = target,
            .optimize = perf_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "memweave", .module = perf_lib },
                // The storage suites open their own in-memory databases, so
                // they need the SQLite bindings directly and not only
                // through the library.
                .{ .name = "sqlite", .module = perf_sqlite_dep.module("sqlite") },
            },
        });

        const exe = b.addExecutable(.{
            .name = suite.name,
            .root_module = suite_mod,
        });

        const run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        // `zig build load -- --scale=0.1 --seed=7` forwards to the suite.
        if (b.args) |args| run.addArgs(args);

        const step = b.step(suite.name, suite.description);
        step.dependOn(&run.step);
        verify_step.dependOn(&run.step);
    }

    // ---- The harness's own tests -----------------------------------------
    //
    // report.zig has real logic in it (percentiles, argument parsing); it is
    // tested like anything else rather than trusted.

    const harness_mod = b.createModule(.{
        .root_source_file = b.path("testing/report.zig"),
        .target = target,
        .optimize = optimize,
    });
    const harness_tests = b.addTest(.{ .root_module = harness_mod });
    const run_harness_tests = b.addRunArtifact(harness_tests);
    test_step.dependOn(&run_harness_tests.step);
}

/// Give a module the vendored SQLite. Called for every module that roots at
/// `src/root.zig` — the public one, the one the measured suites link against,
/// and the vector-integration one — so a change here reaches all of them
/// instead of whichever the author remembered.
fn wireSqlite(mod: *std.Build.Module, sqlite_dep: *std.Build.Dependency) void {
    mod.addImport("sqlite", sqlite_dep.module("sqlite"));
}
