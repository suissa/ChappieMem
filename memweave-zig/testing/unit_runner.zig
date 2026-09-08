//! Custom unit-test runner: runs the real `test` blocks, emits `unit.json`.
//!
//! The suite is not duplicated here. Every `test` in `src/` — the parity
//! assertions, the factory's descriptor tests, the algorithm ports — is what
//! this runs, via `builtin.test_functions`. The only thing it adds over the
//! stock runner is a machine-readable report in the same schema the other
//! five suites emit, so all six can be read by one tool.
//!
//! Wired in `build.zig` as the test step's `test_runner`, in `.simple` mode:
//! the binary runs the tests when spawned and exits, rather than speaking
//! `std.zig.Server` back to the build system.
//!
//! Per test it reproduces the stock runner's lifecycle — a fresh
//! `std.testing.allocator` and `std.testing.io` for each one, and a leak
//! check afterwards — so a test that leaks is reported as a leak rather than
//! poisoning whichever test happens to run next.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const report = @import("report.zig");

const Params = struct {
    out_dir: []const u8,
    /// Present so a filtered run is never mistaken for a full green one.
    filtered: bool,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var out_dir: []const u8 = "reports";
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--out=")) out_dir = arg["--out=".len..];
        // Anything else is the build system's business, not ours.
    }

    var builder = report.Builder.init(gpa, io, "unit", "unit");
    defer builder.deinit();

    const tests = builtin.test_functions;
    std.debug.print("unit: {d} tests\n", .{tests.len});

    var leaked_tests: u32 = 0;
    var failed: u32 = 0;

    for (tests) |test_fn| {
        // Same per-test setup the stock runner performs, so leak attribution
        // is per test rather than cumulative.
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.minimal.args),
            .environ = init.minimal.environ,
        });
        testing.log_level = .warn;
        testing.environ = init.minimal.environ;

        const sw = report.Stopwatch.begin(io);
        const outcome = test_fn.func();
        const duration_ms = sw.elapsedMs();

        testing.io_instance.deinit();
        const leaked = testing.allocator_instance.deinit() == .leak;
        if (leaked) leaked_tests += 1;

        var status: report.Status = .pass;
        var detail: []const u8 = "";
        if (outcome) |_| {
            if (leaked) {
                status = .fail;
                detail = "test leaked memory from std.testing.allocator";
            }
        } else |err| switch (err) {
            error.SkipZigTest => status = .skip,
            else => {
                status = .fail;
                detail = try builder.fmt("returned {s}", .{@errorName(err)});
            },
        }
        if (status == .fail) failed += 1;

        try builder.record(.{
            .name = test_fn.name,
            .status = status,
            .duration_ms = duration_ms,
            .detail = detail,
            .metrics = &.{
                .{ .name = "leaked", .value = if (leaked) 1 else 0, .unit = "count" },
            },
        });
    }

    // An aggregate assertion, so a reader who only looks at case names still
    // sees the leak verdict for the run as a whole.
    try builder.check(
        "no unit test leaked memory",
        leaked_tests == 0,
        try builder.fmt("{d} test(s) leaked", .{leaked_tests}),
        0,
        &.{.{ .name = "leaking_tests", .value = @floatFromInt(leaked_tests), .unit = "count" }},
    );

    const passed = try builder.finish(Params{
        .out_dir = out_dir,
        .filtered = false,
    }, out_dir);

    if (!passed) std.process.exit(1);
}
