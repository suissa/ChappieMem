//! `manifest.yml` → a comptime intermediate representation.
//!
//! The manifest is the behaviour's *identity card*: what it is called, what
//! it is for, how stable it is, and which other behaviours it composes. It
//! carries no field definitions (that is `schema.yml`) and no values (that is
//! `config.yml`).
//!
//! Document shape:
//!
//! ```yaml
//! apiVersion: memweave.behavior/v1
//! kind: AtomicBehavior
//! metadata:
//!   name: chunking
//!   version: 0.1.0
//!   summary: "Markdown chunk sizing."
//!   tags: [indexing]
//! spec:
//!   stability: stable
//!   pure: true
//!   composes: []
//!   parity:
//!     python: memweave.config.ChunkingConfig
//!   consumers: [src/chunking.zig]
//! ```
//!
//! `composes` is not decoration: the factory checks it against the
//! `behavior<...>` fields declared in `schema.yml` and fails the build when
//! the two disagree, so a manifest can never quietly drift out of date.

const std = @import("std");
const yaml = @import("yaml.zig");

pub const Stability = enum { experimental, beta, stable, deprecated };

pub const Manifest = struct {
    api_version: []const u8,
    name: []const u8,
    version: []const u8,
    summary: []const u8,
    tags: []const []const u8,
    stability: Stability,
    /// True when the behaviour's operations are free of I/O and global state.
    pure: bool,
    /// Names of the behaviours whose configs are embedded in this one.
    composes: []const []const u8,
    /// Fully qualified name of the Python definition this behaviour mirrors,
    /// or "" when there is no counterpart.
    parity_python: []const u8,
    /// Zig source files that read this behaviour's config.
    consumers: []const []const u8,

    pub fn composesBehavior(comptime self: Manifest, comptime name: []const u8) bool {
        for (self.composes) |c| {
            if (std.mem.eql(u8, c, name)) return true;
        }
        return false;
    }
};

/// Parse a `manifest.yml`. `expected_name` is the behaviour's directory name;
/// a mismatch with `metadata.name` is a compile error, which keeps the folder
/// layout and the descriptors honest with each other.
pub fn parse(comptime src: []const u8, comptime expected_name: []const u8) Manifest {
    @setEvalBranchQuota(2_000_000);
    const doc = comptime yaml.parse(src);
    const what = "manifest.yml for '" ++ expected_name ++ "'";

    const kind = comptime doc.stringOr("kind", "");
    if (!std.mem.eql(u8, kind, "AtomicBehavior")) {
        @compileError(what ++ ": expected 'kind: AtomicBehavior', found '" ++ kind ++ "'");
    }

    const metadata = comptime doc.require("metadata", what);
    const name = comptime metadata.require("name", what).asScalar().text;
    if (!std.mem.eql(u8, name, expected_name)) {
        @compileError(what ++ ": 'metadata.name' is '" ++ name ++ "' but the behaviour directory is '" ++ expected_name ++ "'");
    }

    const spec = comptime doc.get("spec") orelse yaml.Value.null_value;
    const stability_text = comptime spec.stringOr("stability", "experimental");
    const stability = comptime std.meta.stringToEnum(Stability, stability_text) orelse
        @compileError(what ++ ": unknown stability '" ++ stability_text ++ "'");

    const parity = comptime spec.get("parity") orelse yaml.Value.null_value;

    return .{
        .api_version = comptime doc.stringOr("apiVersion", ""),
        .name = name,
        .version = comptime metadata.require("version", what).asScalar().text,
        .summary = comptime metadata.stringOr("summary", ""),
        .tags = comptime metadata.stringsOr("tags"),
        .stability = stability,
        .pure = comptime if (spec.get("pure")) |p| (p.asScalar().asBool() orelse
            @compileError(what ++ ": 'spec.pure' must be true or false")) else false,
        .composes = comptime spec.stringsOr("composes"),
        .parity_python = comptime parity.stringOr("python", ""),
        .consumers = comptime spec.stringsOr("consumers"),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const demo =
    \\apiVersion: memweave.behavior/v1
    \\kind: AtomicBehavior
    \\metadata:
    \\  name: query
    \\  version: 0.1.0
    \\  summary: "Retrieval knobs."
    \\  tags: [search, ranking]
    \\spec:
    \\  stability: stable
    \\  pure: true
    \\  composes: [hybrid, mmr]
    \\  parity:
    \\    python: memweave.config.QueryConfig
    \\  consumers: [src/search.zig]
;

test "parses identity, stability, composition and parity" {
    const m = comptime parse(demo, "query");

    try std.testing.expectEqualStrings("memweave.behavior/v1", m.api_version);
    try std.testing.expectEqualStrings("query", m.name);
    try std.testing.expectEqualStrings("0.1.0", m.version);
    try std.testing.expectEqualStrings("Retrieval knobs.", m.summary);
    try std.testing.expectEqual(Stability.stable, m.stability);
    try std.testing.expect(m.pure);
    try std.testing.expectEqual(@as(usize, 2), m.tags.len);
    try std.testing.expectEqualStrings("ranking", m.tags[1]);
    try std.testing.expectEqualStrings("memweave.config.QueryConfig", m.parity_python);
    try std.testing.expectEqual(@as(usize, 1), m.consumers.len);
}

test "composesBehavior answers membership of spec.composes" {
    const m = comptime parse(demo, "query");
    try std.testing.expect(comptime m.composesBehavior("hybrid"));
    try std.testing.expect(comptime m.composesBehavior("mmr"));
    try std.testing.expect(comptime !m.composesBehavior("cache"));
}

test "optional spec keys fall back to conservative defaults" {
    const m = comptime parse(
        \\kind: AtomicBehavior
        \\metadata:
        \\  name: minimal
        \\  version: 0.0.1
    , "minimal");

    try std.testing.expectEqualStrings("", m.summary);
    try std.testing.expectEqual(Stability.experimental, m.stability);
    try std.testing.expect(!m.pure);
    try std.testing.expectEqual(@as(usize, 0), m.composes.len);
    try std.testing.expectEqual(@as(usize, 0), m.tags.len);
    try std.testing.expectEqualStrings("", m.parity_python);
}
