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
}
