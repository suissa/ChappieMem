//! Pure path/label helpers for memory file discovery, ported from
//! `memweave/storage/files.py`.
//!
//! Filesystem-scanning functions from the Python module (`list_memory_files`,
//! `build_file_entry`) are deferred to the indexer slice, where directory
//! walking is actually exercised end-to-end — porting them in isolation here
//! would mean guessing at `std.Io.Dir` recursive-iteration semantics with no
//! caller to prove them against. This file covers the pure string/path logic
//! only.

const std = @import("std");

/// Matches dated daily log files: `YYYY-MM-DD.md`. Files NOT matching this
/// pattern are considered evergreen (no temporal decay).
fn isDatedFilename(filename: []const u8) bool {
    if (filename.len != "YYYY-MM-DD.md".len) return false;
    const digits_ok = std.ascii.isDigit(filename[0]) and std.ascii.isDigit(filename[1]) and
        std.ascii.isDigit(filename[2]) and std.ascii.isDigit(filename[3]) and
        filename[4] == '-' and
        std.ascii.isDigit(filename[5]) and std.ascii.isDigit(filename[6]) and
        filename[7] == '-' and
        std.ascii.isDigit(filename[8]) and std.ascii.isDigit(filename[9]);
    if (!digits_ok) return false;
    return std.mem.eql(u8, filename[10..], ".md");
}

/// Determine the logical source label for a file (mirrors
/// `get_source_from_path`). `rel_to_memory` is the file's path already made
/// relative to `workspace_dir` (forward-slash separated, POSIX-style) — pass
/// `null` if the file is not under `workspace_dir/memory/`.
///
/// - Not under `memory/` → `"external"`.
/// - Directly inside `memory/` (no sub-directory) → `"memory"`.
/// - Otherwise → the name of the immediate sub-directory.
pub fn sourceFromRelativePath(rel_to_memory: ?[]const u8) []const u8 {
    const rel = rel_to_memory orelse return "external";
    const slash = std.mem.indexOfScalar(u8, rel, '/') orelse return "memory";
    return rel[0..slash];
}

/// Return `true` if this file is exempt from temporal decay scoring
/// (mirrors `is_evergreen`).
///
/// A file is evergreen if its filename matches one of `evergreen_patterns`
/// (e.g. `MEMORY.md`), or if its filename does not match the dated pattern
/// `YYYY-MM-DD.md` (reference docs are implicitly evergreen). Only dated
/// files like `2026-03-21.md` are subject to decay.
pub fn isEvergreen(filename: []const u8, evergreen_patterns: []const []const u8) bool {
    for (evergreen_patterns) |pattern| {
        if (std.mem.eql(u8, filename, pattern)) return true;
    }
    return !isDatedFilename(filename);
}

test "sourceFromRelativePath: file directly under memory/" {
    try std.testing.expectEqualStrings("memory", sourceFromRelativePath("2026-03-21.md"));
}

test "sourceFromRelativePath: file under a memory/ sub-directory" {
    try std.testing.expectEqualStrings("sessions", sourceFromRelativePath("sessions/s1.md"));
    try std.testing.expectEqualStrings("researcher", sourceFromRelativePath("researcher/analysis.md"));
}

test "sourceFromRelativePath: outside workspace/memory" {
    try std.testing.expectEqualStrings("external", sourceFromRelativePath(null));
}

test "isEvergreen: explicit pattern match" {
    try std.testing.expect(isEvergreen("MEMORY.md", &.{"MEMORY.md"}));
}

test "isEvergreen: non-dated filename is evergreen by convention" {
    try std.testing.expect(isEvergreen("architecture.md", &.{"MEMORY.md"}));
}

test "isEvergreen: dated daily log is subject to decay" {
    try std.testing.expect(!isEvergreen("2026-03-21.md", &.{"MEMORY.md"}));
}

test "isEvergreen: malformed near-dated names are still evergreen" {
    try std.testing.expect(isEvergreen("2026-3-21.md", &.{}));
    try std.testing.expect(isEvergreen("2026-03-21.markdown", &.{}));
    try std.testing.expect(isEvergreen("22026-03-21.md", &.{}));
}
