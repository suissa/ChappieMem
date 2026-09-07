const std = @import("std");

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
    mod.addImport("sqlite", sqlite_dep.module("sqlite"));

    const tests = b.addTest(.{
        .root_module = mod,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
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
    vector_integration_mod.addImport("sqlite", sqlite_dep.module("sqlite"));
    vector_integration_mod.addImport("memweave", mod);
    vector_integration_mod.addImport("vector_test_options", vector_test_options.createModule());

    const vector_tests = b.addTest(.{
        .root_module = vector_integration_mod,
    });
    const run_vector_tests = b.addRunArtifact(vector_tests);

    const vector_test_step = b.step("test-vector", "Run sqlite-vec integration tests");
    vector_test_step.dependOn(&run_vector_tests.step);
}
