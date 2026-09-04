//! Configuration — assembled by the behaviour factory rather than declared.
//!
//! Every struct below used to be hand-written here, each with its own
//! `validate()` transcribing the matching Python `__post_init__`. They are
//! now generated: `src/behaviors/<name>/` holds one folder per atomic
//! behaviour with `manifest.yml` (identity), `schema.yml` (shape and rules)
//! and `config.yml` (this profile's values), and `factory.zig` turns that
//! trio into a Zig module at comptime. See `src/behaviors/README.md` for the
//! full rationale and `src/factory.zig` for the mechanism.
//!
//! What this file is now: the facade. It names the behaviours the library
//! ships with and re-exports their generated types under the same names the
//! rest of the codebase (and the Python original) already uses.
//!
//! Two things moved, both because a generated struct type has fields but no
//! methods:
//!
//!   * `cfg.validate()`  →  `Chunking.validate(cfg)`
//!   * `cfg.maxChars()`  →  `Chunking.ops.maxChars(cfg)`
//!
//! The behaviour module is the namespace; the `Config` struct is plain data.
//!
//! JSON (de)serialization (`to_dict`/`from_dict` in Python) is still absent —
//! deferred to the phase that adds config persistence — but `Behavior.spec`
//! now carries the field list, types and constraints at runtime, which is
//! most of what that phase needs.

const std = @import("std");
const behaviors = @import("behaviors.zig");
const errors = @import("errors.zig");

// -- The behaviour modules ---------------------------------------------------
//
// Each is a namespace: `.Config` (the generated struct), `.defaults`,
// `.validate()`, `.spec`, `.manifest`, `.describe()`, and `.ops` where the
// behaviour has hand-written derivations.

pub const Embedding = behaviors.Behavior("embedding");
pub const Chunking = behaviors.Behavior("chunking");
pub const Hybrid = behaviors.Behavior("hybrid");
pub const MMR = behaviors.Behavior("mmr");
pub const TemporalDecay = behaviors.Behavior("temporal_decay");
pub const Query = behaviors.Behavior("query");
pub const Cache = behaviors.Behavior("cache");
pub const Sync = behaviors.Behavior("sync");
pub const Flush = behaviors.Behavior("flush");
pub const Vector = behaviors.Behavior("vector");
pub const Memory = behaviors.Behavior("memory");

// -- Config types ------------------------------------------------------------
//
// Same names as the hand-written structs they replace, so callers and the
// Python parity mapping are unchanged.

pub const EmbeddingConfig = Embedding.Config;
pub const ChunkingConfig = Chunking.Config;
pub const HybridConfig = Hybrid.Config;
pub const MMRConfig = MMR.Config;
pub const TemporalDecayConfig = TemporalDecay.Config;
pub const QueryConfig = Query.Config;
pub const CacheConfig = Cache.Config;
pub const SyncConfig = Sync.Config;
pub const FlushConfig = Flush.Config;
pub const VectorConfig = Vector.Config;
pub const MemoryConfig = Memory.Config;

// -- Shipped defaults --------------------------------------------------------
//
// These now read out of the generated profiles instead of being declared
// twice. `src/behaviors/flush/config.yml` is the single source of truth for
// the flush prompt.

pub const default_flush_system_prompt = Flush.defaults.system_prompt;
pub const default_bootstrap_files = Memory.defaults.bootstrap_files;
pub const default_evergreen_patterns = Memory.defaults.evergreen_patterns;

// -- Tests -------------------------------------------------------------------
//
// These are the same assertions the hand-written structs carried, re-pointed
// at the generated modules: the port's parity with Python is what is being
// checked, not the factory's plumbing (that is tested in `src/factory/`).

test "EmbeddingConfig defaults are valid" {
    try Embedding.validate(.{});
}

test "EmbeddingConfig carries the profile's model and batching" {
    const cfg = EmbeddingConfig{};
    try std.testing.expectEqualStrings("text-embedding-3-small", cfg.model);
    try std.testing.expectEqual(@as(f64, 60.0), cfg.timeout);
    try std.testing.expectEqual(@as(u32, 64), cfg.batch_size);
    try std.testing.expect(cfg.api_base == null);
    try std.testing.expect(cfg.api_key == null);
}

test "EmbeddingConfig rejects non-positive timeout and batch_size" {
    try std.testing.expectError(error.ConfigError, Embedding.validate(.{ .timeout = 0 }));
    try std.testing.expectError(error.ConfigError, Embedding.validate(.{ .timeout = -1 }));
    try std.testing.expectError(error.ConfigError, Embedding.validate(.{ .batch_size = 0 }));
}

test "ChunkingConfig defaults are valid and derive char budgets" {
    const c = ChunkingConfig{};
    try Chunking.validate(c);
    try std.testing.expectEqual(@as(u32, 400), c.tokens);
    try std.testing.expectEqual(@as(u32, 80), c.overlap);
    try std.testing.expectEqual(@as(u32, 1600), Chunking.ops.maxChars(c));
    try std.testing.expectEqual(@as(u32, 320), Chunking.ops.overlapChars(c));
}

test "ChunkingConfig max_chars floors at 32" {
    const c = ChunkingConfig{ .tokens = 1, .overlap = 0 };
    try std.testing.expectEqual(@as(u32, 32), Chunking.ops.maxChars(c));
}

test "ChunkingConfig rejects overlap >= tokens and zero tokens" {
    try std.testing.expectError(error.ConfigError, Chunking.validate(.{ .tokens = 0 }));
    try std.testing.expectError(error.ConfigError, Chunking.validate(.{ .tokens = 10, .overlap = 10 }));
    try std.testing.expectError(error.ConfigError, Chunking.validate(.{ .tokens = 10, .overlap = 11 }));
}

test "HybridConfig defaults are valid; weights must sum to 1.0" {
    try Hybrid.validate(.{});
    try std.testing.expectError(error.ConfigError, Hybrid.validate(.{ .vector_weight = 0.5, .text_weight = 0.3 }));
    try std.testing.expectError(error.ConfigError, Hybrid.validate(.{ .vector_weight = 1.5, .text_weight = -0.5 }));
    try std.testing.expectError(error.ConfigError, Hybrid.validate(.{ .candidate_multiplier = 0 }));
    // within tolerance
    try Hybrid.validate(.{ .vector_weight = 0.7000001, .text_weight = 0.2999999 });
}

test "MMRConfig lambda_param must be in [0,1]" {
    try MMR.validate(.{});
    try MMR.validate(.{ .lambda_param = 0.0 });
    try MMR.validate(.{ .lambda_param = 1.0 });
    try std.testing.expectError(error.ConfigError, MMR.validate(.{ .lambda_param = -0.1 }));
    try std.testing.expectError(error.ConfigError, MMR.validate(.{ .lambda_param = 1.1 }));
}

test "TemporalDecayConfig half_life_days must be positive" {
    try TemporalDecay.validate(.{});
    try std.testing.expectEqual(@as(f64, 30.0), (TemporalDecayConfig{}).half_life_days);
    try std.testing.expectError(error.ConfigError, TemporalDecay.validate(.{ .half_life_days = 0 }));
    try std.testing.expectError(error.ConfigError, TemporalDecay.validate(.{ .half_life_days = -1 }));
}

test "QueryConfig defaults are valid and cascade to nested configs" {
    try Query.validate(.{});
    try std.testing.expectError(error.ConfigError, Query.validate(.{ .max_results = 0 }));
    try std.testing.expectError(error.ConfigError, Query.validate(.{ .min_score = 1.5 }));
    try std.testing.expectError(error.ConfigError, Query.validate(.{ .snippet_max_chars = 0 }));
    try std.testing.expectError(error.ConfigError, Query.validate(.{ .mmr = .{ .lambda_param = 2.0 } }));
}

test "QueryConfig composes the ranking behaviours with their own profiles" {
    const cfg = QueryConfig{};
    try std.testing.expectEqualStrings("hybrid", cfg.strategy);
    try std.testing.expectEqual(@as(u32, 6), cfg.max_results);
    try std.testing.expectEqual(@as(f64, 0.7), cfg.hybrid.vector_weight);
    try std.testing.expectEqual(false, cfg.mmr.enabled);
    try std.testing.expectEqual(@as(f64, 30.0), cfg.temporal_decay.half_life_days);
}

test "CacheConfig max_entries null is unlimited and always valid" {
    try Cache.validate(.{});
    try std.testing.expect((CacheConfig{}).max_entries == null);
    try Cache.validate(.{ .max_entries = 1 });
    try std.testing.expectError(error.ConfigError, Cache.validate(.{ .max_entries = 0 }));
}

test "SyncConfig defaults sync on search only" {
    const cfg = SyncConfig{};
    try std.testing.expectEqual(true, cfg.on_search);
    try std.testing.expectEqual(false, cfg.watch);
    try std.testing.expectEqual(@as(u32, 1500), cfg.watch_debounce_ms);
    try std.testing.expectEqual(@as(u32, 0), cfg.interval_minutes);
}

test "VectorConfig defaults to enabled with auto-detection" {
    const cfg = VectorConfig{};
    try std.testing.expectEqual(true, cfg.enabled);
    try std.testing.expect(cfg.extension_path == null);
}

test "FlushConfig defaults are valid" {
    try Flush.validate(.{});
    try std.testing.expectError(error.ConfigError, Flush.validate(.{ .max_tokens = 0 }));
    try std.testing.expectError(error.ConfigError, Flush.validate(.{ .temperature = 3.0 }));
    try std.testing.expectError(error.ConfigError, Flush.validate(.{ .temperature = -0.1 }));
}

test "FlushConfig default system prompt matches the documented contract" {
    const prompt = (FlushConfig{}).system_prompt;
    try std.testing.expectEqualStrings(default_flush_system_prompt, prompt);
    try std.testing.expect(std.mem.startsWith(u8, prompt, "Pre-compaction memory flush.\n"));
    try std.testing.expect(std.mem.endsWith(u8, prompt, "If nothing to store, reply with @@SILENT_REPLY@@."));
    try std.testing.expect(std.mem.indexOf(u8, prompt, "memory/YYYY-MM-DD.md") != null);
}

test "MemoryConfig defaults are valid and resolve derived paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cfg = MemoryConfig{ .workspace_dir = "/tmp/project" };
    try Memory.validate(cfg);

    const db_path = try Memory.ops.resolvedDbPath(cfg, allocator);
    const expected_db_path = try std.fs.path.join(allocator, &[_][]const u8{ "/tmp/project", ".memweave", "index.sqlite" });
    try std.testing.expectEqualStrings(expected_db_path, db_path);

    const mem_dir = try Memory.ops.memoryDir(cfg, allocator);
    const expected_mem_dir = try std.fs.path.join(allocator, &[_][]const u8{ "/tmp/project", "memory" });
    try std.testing.expectEqualStrings(expected_mem_dir, mem_dir);
}

test "MemoryConfig db_path override wins over the derived default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cfg = MemoryConfig{ .workspace_dir = "/tmp/project", .db_path = "/tmp/custom.sqlite" };
    const db_path = try Memory.ops.resolvedDbPath(cfg, allocator);
    try std.testing.expectEqualStrings("/tmp/custom.sqlite", db_path);
}

test "MemoryConfig evergreen_patterns and bootstrap_files defaults" {
    const cfg = MemoryConfig{};
    try std.testing.expectEqual(@as(usize, 2), cfg.evergreen_patterns.len);
    try std.testing.expectEqualStrings("MEMORY.md", cfg.evergreen_patterns[0]);
    try std.testing.expectEqualStrings("memory.md", cfg.evergreen_patterns[1]);
    try std.testing.expectEqual(@as(usize, 1), cfg.bootstrap_files.len);
    try std.testing.expectEqualStrings("MEMORY.md", cfg.bootstrap_files[0]);
    try std.testing.expectEqual(@as(usize, 0), cfg.extra_paths.len);
    try std.testing.expectEqualStrings("UTC", cfg.timezone);
    try std.testing.expectEqualStrings("~/.memweave/default", cfg.workspace_dir);
}

test "MemoryConfig validation cascades into every composed behaviour" {
    try std.testing.expectError(error.ConfigError, Memory.validate(.{ .embedding = .{ .batch_size = 0 } }));
    try std.testing.expectError(error.ConfigError, Memory.validate(.{ .chunking = .{ .tokens = 10, .overlap = 10 } }));
    try std.testing.expectError(error.ConfigError, Memory.validate(.{ .query = .{ .min_score = 2.0 } }));
    try std.testing.expectError(error.ConfigError, Memory.validate(.{ .cache = .{ .max_entries = 0 } }));
    try std.testing.expectError(error.ConfigError, Memory.validate(.{ .flush = .{ .max_tokens = 0 } }));
    // Two levels down: query -> hybrid.
    try std.testing.expectError(
        error.ConfigError,
        Memory.validate(.{ .query = .{ .hybrid = .{ .vector_weight = 0.5, .text_weight = 0.4 } } }),
    );
}

test "validate() returns the same error set the hand-written configs did" {
    const E = @typeInfo(@typeInfo(@TypeOf(Memory.validate)).@"fn".return_type.?).error_union.error_set;
    try std.testing.expectEqual(errors.ConfigError, E);
}
