//! Derived paths for the `memory` behaviour.
//!
//! These mirror the properties the Python `MemoryConfig` dataclass exposes.
//! They need an allocator, so unlike the generated data they cannot be
//! comptime constants — path joining is the caller's to own and free.
//!
//! `~` expansion (Python's `Path.expanduser()` in `__post_init__`) needs real
//! filesystem context and lands with the storage layer; these functions join
//! paths verbatim.

const std = @import("std");

/// `db_path` when the profile pins one, otherwise
/// `workspace_dir/.memweave/index.sqlite`. Caller owns the returned slice.
pub fn resolvedDbPath(cfg: anytype, allocator: std.mem.Allocator) ![]u8 {
    if (cfg.db_path) |p| return allocator.dupe(u8, p);
    return std.fs.path.join(allocator, &.{ cfg.workspace_dir, ".memweave", "index.sqlite" });
}

/// `workspace_dir/memory`, where dated memory files are written. Caller owns
/// the returned slice.
pub fn memoryDir(cfg: anytype, allocator: std.mem.Allocator) ![]u8 {
    return std.fs.path.join(allocator, &.{ cfg.workspace_dir, "memory" });
}

test "resolvedDbPath derives the index path from the workspace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cfg = .{ .workspace_dir = "/tmp/project", .db_path = @as(?[]const u8, null) };
    const expected = try std.fs.path.join(allocator, &.{ "/tmp/project", ".memweave", "index.sqlite" });
    try std.testing.expectEqualStrings(expected, try resolvedDbPath(cfg, allocator));
}

test "resolvedDbPath honours an explicit db_path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cfg = .{ .workspace_dir = "/tmp/project", .db_path = @as(?[]const u8, "/tmp/custom.sqlite") };
    try std.testing.expectEqualStrings("/tmp/custom.sqlite", try resolvedDbPath(cfg, allocator));
}

test "memoryDir joins workspace_dir with memory/" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cfg = .{ .workspace_dir = "/tmp/project" };
    const expected = try std.fs.path.join(allocator, &.{ "/tmp/project", "memory" });
    try std.testing.expectEqualStrings(expected, try memoryDir(cfg, allocator));
}
