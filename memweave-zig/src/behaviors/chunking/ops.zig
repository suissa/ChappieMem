//! Derived values for the `chunking` behaviour.
//!
//! The factory generates data and rules; computation stays hand-written and
//! lives here. These mirror the `max_chars` / `overlap_chars` properties on
//! the Python `ChunkingConfig` dataclass.
//!
//! `cfg` is `anytype` because the config struct does not exist until the
//! factory builds it — these functions are structurally typed against
//! whatever the `chunking` profile generated.

const std = @import("std");

/// Character budget per chunk, on the usual 1 token ≈ 4 chars rule, floored
/// at 32 so a tiny `tokens` setting still leaves room for a line.
pub fn maxChars(cfg: anytype) u32 {
    return @max(32, cfg.tokens * 4);
}

/// Character budget for the backward overlap.
pub fn overlapChars(cfg: anytype) u32 {
    return cfg.overlap * 4;
}

test "maxChars and overlapChars convert tokens on the 1:4 rule" {
    const cfg = .{ .tokens = 400, .overlap = 80 };
    try std.testing.expectEqual(@as(u32, 1600), maxChars(cfg));
    try std.testing.expectEqual(@as(u32, 320), overlapChars(cfg));
}

test "maxChars floors at 32" {
    try std.testing.expectEqual(@as(u32, 32), maxChars(.{ .tokens = 1, .overlap = 0 }));
}
