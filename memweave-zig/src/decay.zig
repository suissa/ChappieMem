//! Temporal decay math, ported from `memweave/search/temporal_decay.py`.
//!
//! Only the pure, I/O-free helpers are ported in this phase:
//! `to_decay_lambda`, `calculate_decay_multiplier`, `apply_decay_to_score`,
//! `parse_date_from_path`, `is_evergreen_path`, `age_in_days`. The
//! mtime-fallback date extraction (`_extract_date`, async, needs a
//! filesystem `stat()`) and the row-list pipeline (`apply_temporal_decay`,
//! `TemporalDecayProcessor`) are deferred to the storage/search phases,
//! which is where real file I/O enters this port.
//!
//! Decay formula:
//!   λ = ln(2) / half_life_days
//!   multiplier = exp(−λ × age_days)
//!   decayed_score = original_score × multiplier

const std = @import("std");

pub const Date = struct {
    year: i32,
    month: u8, // 1-12
    day: u8, // 1-31

    /// Days since 1970-01-01 (proleptic Gregorian). Used only to compute
    /// day-count *differences* between two dates — the absolute epoch
    /// doesn't matter for that, only that the arithmetic is correct.
    pub fn toEpochDays(self: Date) i64 {
        return daysFromCivil(self.year, self.month, self.day);
    }
};

/// Howard Hinnant's well-known `days_from_civil` algorithm
/// (http://howardhinnant.github.io/date_algorithms.html), public domain,
/// used by libc++ and many other date libraries.
fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    var y: i64 = year;
    const m: i64 = month;
    const d: i64 = day;

    if (m <= 2) y -= 1;

    const era: i64 = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const mp: i64 = if (m > 2) m - 3 else m + 9; // [0, 11]
    const doy: i64 = @divTrunc(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// `λ = ln(2) / half_life_days`. Returns 0 for non-finite or non-positive
/// input (no-decay fallback, no error).
pub fn toDecayLambda(half_life_days: f64) f64 {
    if (!std.math.isFinite(half_life_days) or half_life_days <= 0) return 0.0;
    return std.math.ln(@as(f64, 2.0)) / half_life_days;
}

/// `exp(−λ × age_days)`, `age_days` clamped to `>= 0`. Returns `1.0` when
/// decay is disabled (`λ <= 0`) or `age_days` is non-finite.
pub fn calculateDecayMultiplier(age_days: f64, half_life_days: f64) f64 {
    const lam = toDecayLambda(half_life_days);
    const clamped_age = @max(0.0, age_days);
    if (lam <= 0 or !std.math.isFinite(clamped_age)) return 1.0;
    return std.math.exp(-lam * clamped_age);
}

/// `score * calculateDecayMultiplier(age_days, half_life_days)`.
pub fn applyDecayToScore(score: f64, age_days: f64, half_life_days: f64) f64 {
    return score * calculateDecayMultiplier(age_days, half_life_days);
}

/// `max(0, (now - file_date).days)`.
pub fn ageInDays(file_date: Date, now: Date) f64 {
    const delta = now.toEpochDays() - file_date.toEpochDays();
    return @max(0.0, @as(f64, @floatFromInt(delta)));
}

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

fn parseDigits(s: []const u8) ?u32 {
    var val: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + (c - '0');
    }
    return val;
}

fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) @as(u8, 29) else 28,
        else => 0,
    };
}

/// Matches a fixed `YYYY-MM-DD.md` (exactly 13 bytes) suffix, validating
/// the date is real (rejects e.g. month 99, Feb 30).
fn matchDateSuffix(s: []const u8) ?Date {
    if (s.len != 13) return null;
    if (s[4] != '-' or s[7] != '-') return null;
    if (!std.mem.eql(u8, s[10..13], ".md")) return null;

    const year_u = parseDigits(s[0..4]) orelse return null;
    const month_u = parseDigits(s[5..7]) orelse return null;
    const day_u = parseDigits(s[8..10]) orelse return null;

    if (month_u < 1 or month_u > 12) return null;
    const month: u8 = @intCast(month_u);
    const year: i32 = @intCast(year_u);
    if (day_u < 1 or day_u > daysInMonth(year, month)) return null;

    return Date{ .year = year, .month = month, .day = @intCast(day_u) };
}

/// Extract `YYYY-MM-DD` from a dated memory-file path — mirrors
/// `parse_date_from_path`. Matches `memory/YYYY-MM-DD.md` and one level of
/// subdirectory (`memory/<subdir>/YYYY-MM-DD.md`); `/` and `\` are
/// accepted interchangeably as path separators (matching Python's
/// backslash-to-forward-slash normalization before regex matching).
pub fn parseDateFromPath(path: []const u8) ?Date {
    if (path.len < 7) return null;

    var i: usize = 0;
    while (i + 7 <= path.len) : (i += 1) {
        if (!(i == 0 or isSep(path[i - 1]))) continue;
        if (!std.mem.eql(u8, path[i .. i + 6], "memory")) continue;
        if (!isSep(path[i + 6])) continue;

        const rest = path[i + 7 ..];
        if (matchDateSuffix(rest)) |date| return date;

        // Optional single subdirectory: memory/<subdir>/YYYY-MM-DD.md
        if (rest.len > 13) {
            const prefix = rest[0 .. rest.len - 13];
            const suffix = rest[rest.len - 13 ..];
            if (prefix.len > 0 and isSep(prefix[prefix.len - 1])) {
                const subdir = prefix[0 .. prefix.len - 1];
                if (subdir.len > 0 and std.mem.indexOfAny(u8, subdir, "/\\") == null) {
                    if (matchDateSuffix(suffix)) |date| return date;
                }
            }
        }
    }
    return null;
}

fn lstripDotSep(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == '.' or s[i] == '/' or s[i] == '\\')) : (i += 1) {}
    return s[i..];
}

fn startsWithMemorySep(s: []const u8) bool {
    return s.len >= 7 and std.mem.eql(u8, s[0..6], "memory") and isSep(s[6]);
}

/// Whether a path is "evergreen" (immune to decay) — mirrors
/// `is_evergreen_path`: `MEMORY.md`/`memory.md` (after stripping leading
/// `.`/`/`/`\` characters), or any non-dated file under `memory/` at any
/// depth. Dated files under `memory/` are NOT evergreen.
pub fn isEvergreenPath(file_path: []const u8) bool {
    const stripped = lstripDotSep(file_path);

    if (std.mem.eql(u8, stripped, "MEMORY.md") or std.mem.eql(u8, stripped, "memory.md")) {
        return true;
    }
    if (!startsWithMemorySep(stripped)) return false;

    return parseDateFromPath(file_path) == null;
}

// ── Tests — golden values obtained by running the real
// `memweave.search.temporal_decay` module directly in this same session. ──

test "toDecayLambda matches ln(2)/half_life_days; 0 for non-positive input" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.023104906018664842), toDecayLambda(30.0), 1e-12);
    try std.testing.expectEqual(@as(f64, 0.0), toDecayLambda(0));
    try std.testing.expectEqual(@as(f64, 0.0), toDecayLambda(-1));
    try std.testing.expectEqual(@as(f64, 0.0), toDecayLambda(std.math.inf(f64)));
    try std.testing.expectEqual(@as(f64, 0.0), toDecayLambda(std.math.nan(f64)));
}

test "calculateDecayMultiplier at age 0 / one half-life / two half-lives" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), calculateDecayMultiplier(0, 30), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), calculateDecayMultiplier(30, 30), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), calculateDecayMultiplier(60, 30), 1e-9);
}

test "calculateDecayMultiplier clamps negative age to 0 and disables decay at half_life<=0" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), calculateDecayMultiplier(-5, 30), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), calculateDecayMultiplier(30, 0), 1e-12);
}

test "calculateDecayMultiplier is negligible far past the half-life" {
    try std.testing.expect(calculateDecayMultiplier(10000, 30) < 1e-50);
    try std.testing.expectApproxEqAbs(@as(f64, 4.535948468269696e-101), calculateDecayMultiplier(10000, 30), 1e-110);
}

test "applyDecayToScore multiplies score by the decay multiplier" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), applyDecayToScore(0.8, 30, 30), 1e-9);
}

test "daysFromCivil matches known reference points" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 11017), daysFromCivil(2000, 3, 1));
    try std.testing.expectEqual(@as(i64, 20540), daysFromCivil(2026, 3, 28));
    try std.testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    try std.testing.expectEqual(@as(i64, -135140), daysFromCivil(1600, 1, 1));
    try std.testing.expectEqual(@as(i64, 157054), daysFromCivil(2400, 1, 1));
    try std.testing.expectEqual(@as(i64, -719162), daysFromCivil(1, 1, 1));
    try std.testing.expectEqual(@as(i64, 11016), daysFromCivil(2000, 2, 29)); // leap day
}

test "ageInDays matches (now - file_date).days, clamped to 0 for future dates" {
    try std.testing.expectEqual(@as(f64, 0.0), ageInDays(.{ .year = 2026, .month = 1, .day = 1 }, .{ .year = 2026, .month = 1, .day = 1 }));
    try std.testing.expectEqual(@as(f64, 0.0), ageInDays(.{ .year = 2026, .month = 1, .day = 5 }, .{ .year = 2026, .month = 1, .day = 1 }));
    try std.testing.expectEqual(@as(f64, 10.0), ageInDays(.{ .year = 2026, .month = 1, .day = 1 }, .{ .year = 2026, .month = 1, .day = 11 }));
    try std.testing.expectEqual(@as(f64, 30.0), ageInDays(.{ .year = 2026, .month = 3, .day = 28 }, .{ .year = 2026, .month = 4, .day = 27 }));
}

test "parseDateFromPath extracts YYYY-MM-DD from dated memory paths" {
    const d1 = parseDateFromPath("memory/2026-03-28.md").?;
    try std.testing.expectEqual(@as(i32, 2026), d1.year);
    try std.testing.expectEqual(@as(u8, 3), d1.month);
    try std.testing.expectEqual(@as(u8, 28), d1.day);

    const d2 = parseDateFromPath("memory/sessions/2026-03-28.md").?;
    try std.testing.expectEqual(@as(i32, 2026), d2.year);
    try std.testing.expectEqual(@as(u8, 3), d2.month);
    try std.testing.expectEqual(@as(u8, 28), d2.day);

    const d3 = parseDateFromPath("memory\\2026-03-28.md").?; // backslash separator
    try std.testing.expectEqual(@as(u8, 28), d3.day);

    const d4 = parseDateFromPath("./memory/2026-03-28.md").?;
    try std.testing.expectEqual(@as(u8, 28), d4.day);

    const d5 = parseDateFromPath("/abs/path/memory/2026-03-28.md").?;
    try std.testing.expectEqual(@as(u8, 28), d5.day);
}

test "parseDateFromPath returns null for non-dated, non-memory, or invalid paths" {
    try std.testing.expect(parseDateFromPath("MEMORY.md") == null);
    try std.testing.expect(parseDateFromPath("memory/MEMORY.md") == null);
    try std.testing.expect(parseDateFromPath("sessions/2026-03-28.md") == null); // outside memory/
    try std.testing.expect(parseDateFromPath("memory/2026-99-28.md") == null); // invalid month
    try std.testing.expect(parseDateFromPath("") == null);
    try std.testing.expect(parseDateFromPath("memory/a/b/2026-03-28.md") == null); // two subdirs
}

test "isEvergreenPath: bootstrap files, non-dated memory/ files, and negatives" {
    try std.testing.expect(isEvergreenPath("MEMORY.md"));
    try std.testing.expect(isEvergreenPath("./MEMORY.md"));
    try std.testing.expect(isEvergreenPath("memory/architecture.md"));
    try std.testing.expect(isEvergreenPath("memory/sessions/foo.md"));
    try std.testing.expect(!isEvergreenPath("memory/2026-03-28.md"));
    try std.testing.expect(!isEvergreenPath("sessions/foo.md"));
}
