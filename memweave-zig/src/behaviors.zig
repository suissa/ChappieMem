//! The behaviour catalogue.
//!
//! One entry per folder under `src/behaviors/`. Adding a behaviour means
//! adding the folder and one line here — this table is the only place that
//! names a descriptor path, which keeps the wiring greppable instead of
//! hiding it behind computed `@embedFile` paths.
//!
//! `Behavior(name)` is also the resolver the factory uses for composition:
//! it is passed to itself, so a `behavior<hybrid>` field in `query`'s schema
//! resolves through the same table as a top-level lookup.

const std = @import("std");
const factory = @import("factory.zig");

const Entry = struct {
    name: []const u8,
    sources: factory.Sources,
};

const catalog = [_]Entry{
    .{ .name = "embedding", .sources = .{
        .manifest = @embedFile("behaviors/embedding/manifest.yml"),
        .config = @embedFile("behaviors/embedding/config.yml"),
        .schema = @embedFile("behaviors/embedding/schema.yml"),
    } },
    .{ .name = "chunking", .sources = .{
        .manifest = @embedFile("behaviors/chunking/manifest.yml"),
        .config = @embedFile("behaviors/chunking/config.yml"),
        .schema = @embedFile("behaviors/chunking/schema.yml"),
        .ops = @import("behaviors/chunking/ops.zig"),
    } },
    .{ .name = "hybrid", .sources = .{
        .manifest = @embedFile("behaviors/hybrid/manifest.yml"),
        .config = @embedFile("behaviors/hybrid/config.yml"),
        .schema = @embedFile("behaviors/hybrid/schema.yml"),
    } },
    .{ .name = "mmr", .sources = .{
        .manifest = @embedFile("behaviors/mmr/manifest.yml"),
        .config = @embedFile("behaviors/mmr/config.yml"),
        .schema = @embedFile("behaviors/mmr/schema.yml"),
    } },
    .{ .name = "temporal_decay", .sources = .{
        .manifest = @embedFile("behaviors/temporal_decay/manifest.yml"),
        .config = @embedFile("behaviors/temporal_decay/config.yml"),
        .schema = @embedFile("behaviors/temporal_decay/schema.yml"),
    } },
    .{ .name = "query", .sources = .{
        .manifest = @embedFile("behaviors/query/manifest.yml"),
        .config = @embedFile("behaviors/query/config.yml"),
        .schema = @embedFile("behaviors/query/schema.yml"),
    } },
    .{ .name = "cache", .sources = .{
        .manifest = @embedFile("behaviors/cache/manifest.yml"),
        .config = @embedFile("behaviors/cache/config.yml"),
        .schema = @embedFile("behaviors/cache/schema.yml"),
    } },
    .{ .name = "sync", .sources = .{
        .manifest = @embedFile("behaviors/sync/manifest.yml"),
        .config = @embedFile("behaviors/sync/config.yml"),
        .schema = @embedFile("behaviors/sync/schema.yml"),
    } },
    .{ .name = "flush", .sources = .{
        .manifest = @embedFile("behaviors/flush/manifest.yml"),
        .config = @embedFile("behaviors/flush/config.yml"),
        .schema = @embedFile("behaviors/flush/schema.yml"),
    } },
    .{ .name = "vector", .sources = .{
        .manifest = @embedFile("behaviors/vector/manifest.yml"),
        .config = @embedFile("behaviors/vector/config.yml"),
        .schema = @embedFile("behaviors/vector/schema.yml"),
    } },
    .{ .name = "memory", .sources = .{
        .manifest = @embedFile("behaviors/memory/manifest.yml"),
        .config = @embedFile("behaviors/memory/config.yml"),
        .schema = @embedFile("behaviors/memory/schema.yml"),
        .ops = @import("behaviors/memory/ops.zig"),
    } },
};

/// Every registered behaviour name, in catalogue order.
pub const names: []const []const u8 = blk: {
    var out: []const []const u8 = &.{};
    for (catalog) |e| out = out ++ [_][]const u8{e.name};
    break :blk out;
};

/// The generated module for one behaviour. Instantiating the same name twice
/// yields the same type, so `Behavior("hybrid").Config` is one type whether
/// it is reached directly or through `query`'s composition.
pub fn Behavior(comptime name: []const u8) type {
    return factory.Module(name, sourcesFor(name), Behavior);
}

fn sourcesFor(comptime name: []const u8) factory.Sources {
    for (catalog) |e| {
        if (std.mem.eql(u8, e.name, name)) return e.sources;
    }
    @compileError("no behaviour named '" ++ name ++ "' under src/behaviors/");
}

test {
    // Pull in each behaviour's hand-written ops tests.
    _ = @import("behaviors/chunking/ops.zig");
    _ = @import("behaviors/memory/ops.zig");
}

test "every catalogued behaviour builds, validates its own defaults and agrees with its manifest" {
    inline for (names) |name| {
        const B = Behavior(name);
        try std.testing.expectEqualStrings(name, B.manifest.name);
        try B.validate(B.defaults);

        // The manifest's composition list and the schema's behavior<> fields
        // are checked against each other at build time; this asserts the
        // resolved side is reachable too.
        inline for (B.composes) |child| {
            try std.testing.expect(comptime B.manifest.composesBehavior(child));
            _ = Behavior(child).Config;
        }
    }
}

test "a composed field's type is the composed behaviour's own Config" {
    try std.testing.expect(@FieldType(Behavior("query").Config, "hybrid") == Behavior("hybrid").Config);
    try std.testing.expect(@FieldType(Behavior("memory").Config, "query") == Behavior("query").Config);
}
