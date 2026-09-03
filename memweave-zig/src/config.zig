//! Configuration structs mirroring the Python `memweave.config` module.
//!
//! Each struct carries the same defaults as its Python dataclass and a
//! `validate()` that enforces the same conditions as the matching
//! `__post_init__` (Python raises `ValueError`; here we return
//! `errors.ConfigError`). Nested configs cascade validation the same way
//! `MemoryConfig.__post_init__` implicitly does by constructing nested
//! dataclasses (whose own `__post_init__` runs first).
//!
//! JSON (de)serialization (`to_dict`/`from_dict` in Python) is intentionally
//! omitted here — deferred to the phase that adds config persistence.

const std = @import("std");
const errors = @import("errors.zig");

pub const EmbeddingConfig = struct {
    model: []const u8 = "text-embedding-3-small",
    api_base: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    timeout: f64 = 60.0,
    batch_size: u32 = 64,

    pub fn validate(self: EmbeddingConfig) errors.ConfigError!void {
        if (self.timeout <= 0) return error.ConfigError;
        if (self.batch_size == 0) return error.ConfigError;
    }
};

pub const ChunkingConfig = struct {
    tokens: u32 = 400,
    overlap: u32 = 80,

    pub fn validate(self: ChunkingConfig) errors.ConfigError!void {
        if (self.tokens == 0) return error.ConfigError;
        if (self.overlap >= self.tokens) return error.ConfigError;
    }

    /// 1 token ≈ 4 chars.
    pub fn maxChars(self: ChunkingConfig) u32 {
        return @max(32, self.tokens * 4);
    }

    pub fn overlapChars(self: ChunkingConfig) u32 {
        return self.overlap * 4;
    }
};

pub const HybridConfig = struct {
    vector_weight: f64 = 0.7,
    text_weight: f64 = 0.3,
    candidate_multiplier: u32 = 4,

    pub fn validate(self: HybridConfig) errors.ConfigError!void {
        if (self.vector_weight < 0.0 or self.vector_weight > 1.0) return error.ConfigError;
        if (self.text_weight < 0.0 or self.text_weight > 1.0) return error.ConfigError;
        if (@abs(self.vector_weight + self.text_weight - 1.0) > 1e-6) return error.ConfigError;
        if (self.candidate_multiplier == 0) return error.ConfigError;
    }
};

pub const MMRConfig = struct {
    enabled: bool = false,
    lambda_param: f64 = 0.7,

    pub fn validate(self: MMRConfig) errors.ConfigError!void {
        if (self.lambda_param < 0.0 or self.lambda_param > 1.0) return error.ConfigError;
    }
};

pub const TemporalDecayConfig = struct {
    enabled: bool = false,
    half_life_days: f64 = 30.0,

    pub fn validate(self: TemporalDecayConfig) errors.ConfigError!void {
        if (self.half_life_days <= 0) return error.ConfigError;
    }
};

pub const QueryConfig = struct {
    strategy: []const u8 = "hybrid",
    max_results: u32 = 6,
    min_score: f64 = 0.35,
    snippet_max_chars: u32 = 700,
    hybrid: HybridConfig = .{},
    mmr: MMRConfig = .{},
    temporal_decay: TemporalDecayConfig = .{},

    pub fn validate(self: QueryConfig) errors.ConfigError!void {
        if (self.max_results == 0) return error.ConfigError;
        if (self.min_score < 0.0 or self.min_score > 1.0) return error.ConfigError;
        if (self.snippet_max_chars == 0) return error.ConfigError;
        try self.hybrid.validate();
        try self.mmr.validate();
        try self.temporal_decay.validate();
    }
};

pub const CacheConfig = struct {
    enabled: bool = true,
    /// `null` = unlimited; otherwise LRU eviction by `updated_at` once exceeded.
    max_entries: ?u32 = null,

    pub fn validate(self: CacheConfig) errors.ConfigError!void {
        if (self.max_entries) |n| {
            if (n == 0) return error.ConfigError;
        }
    }
};

pub const SyncConfig = struct {
    on_search: bool = true,
    watch: bool = false,
    watch_debounce_ms: u32 = 1500,
    interval_minutes: u32 = 0,
};

pub const default_flush_system_prompt =
    \\Pre-compaction memory flush.
    \\Store durable memories only in memory/YYYY-MM-DD.md (create memory/ if needed).
    \\Treat workspace bootstrap/reference files such as MEMORY.md as read-only during this flush; never overwrite, replace, or edit them.
    \\If memory/YYYY-MM-DD.md already exists, APPEND new content only and do not overwrite existing entries.
    \\Do NOT create timestamped variant files (e.g., YYYY-MM-DD-HHMM.md); always use the canonical YYYY-MM-DD.md filename.
    \\If nothing to store, reply with @@SILENT_REPLY@@.
;

pub const FlushConfig = struct {
    enabled: bool = true,
    model: []const u8 = "gpt-4o-mini",
    max_tokens: u32 = 1024,
    temperature: f64 = 0.0,
    system_prompt: []const u8 = default_flush_system_prompt,

    pub fn validate(self: FlushConfig) errors.ConfigError!void {
        if (self.max_tokens == 0) return error.ConfigError;
        if (self.temperature < 0.0 or self.temperature > 2.0) return error.ConfigError;
    }
};

pub const VectorConfig = struct {
    enabled: bool = true,
    /// `null` = auto-detect the sqlite-vec loadable extension.
    extension_path: ?[]const u8 = null,
};

pub const default_evergreen_patterns = [_][]const u8{ "MEMORY.md", "memory.md" };
pub const default_bootstrap_files = [_][]const u8{"MEMORY.md"};

pub const MemoryConfig = struct {
    workspace_dir: []const u8 = "~/.memweave/default",
    /// `null` → `resolvedDbPath()` falls back to `workspace_dir/.memweave/index.sqlite`.
    db_path: ?[]const u8 = null,
    timezone: []const u8 = "UTC",

    embedding: EmbeddingConfig = .{},
    chunking: ChunkingConfig = .{},
    query: QueryConfig = .{},
    cache: CacheConfig = .{},
    sync: SyncConfig = .{},
    flush: FlushConfig = .{},
    vector: VectorConfig = .{},

    progress: bool = true,
    extra_paths: []const []const u8 = &.{},
    bootstrap_files: []const []const u8 = &default_bootstrap_files,
    evergreen_patterns: []const []const u8 = &default_evergreen_patterns,

    pub fn validate(self: MemoryConfig) errors.ConfigError!void {
        try self.embedding.validate();
        try self.chunking.validate();
        try self.query.validate();
        try self.cache.validate();
        try self.flush.validate();
    }

    /// `db_path` if set, else `workspace_dir/.memweave/index.sqlite`.
    ///
    /// Path joining (and `~` expansion, done by Python's `Path.expanduser()`
    /// in `__post_init__`) needs an allocator and real filesystem context —
    /// deferred to the storage-layer phase. Caller owns the returned slice.
    pub fn resolvedDbPath(self: MemoryConfig, allocator: std.mem.Allocator) ![]u8 {
        if (self.db_path) |p| return allocator.dupe(u8, p);
        return std.fs.path.join(allocator, &.{ self.workspace_dir, ".memweave", "index.sqlite" });
    }

    /// `workspace_dir/memory`. Caller owns the returned slice.
    pub fn memoryDir(self: MemoryConfig, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.workspace_dir, "memory" });
    }
};

test "EmbeddingConfig defaults are valid" {
    try (EmbeddingConfig{}).validate();
}

test "EmbeddingConfig rejects non-positive timeout and batch_size" {
    try std.testing.expectError(error.ConfigError, (EmbeddingConfig{ .timeout = 0 }).validate());
    try std.testing.expectError(error.ConfigError, (EmbeddingConfig{ .timeout = -1 }).validate());
    try std.testing.expectError(error.ConfigError, (EmbeddingConfig{ .batch_size = 0 }).validate());
}

test "ChunkingConfig defaults are valid and derive char budgets" {
    const c = ChunkingConfig{};
    try c.validate();
    try std.testing.expectEqual(@as(u32, 1600), c.maxChars());
    try std.testing.expectEqual(@as(u32, 320), c.overlapChars());
}

test "ChunkingConfig max_chars floors at 32" {
    const c = ChunkingConfig{ .tokens = 1, .overlap = 0 };
    try std.testing.expectEqual(@as(u32, 32), c.maxChars());
}

test "ChunkingConfig rejects overlap >= tokens and zero tokens" {
    try std.testing.expectError(error.ConfigError, (ChunkingConfig{ .tokens = 0 }).validate());
    try std.testing.expectError(error.ConfigError, (ChunkingConfig{ .tokens = 10, .overlap = 10 }).validate());
    try std.testing.expectError(error.ConfigError, (ChunkingConfig{ .tokens = 10, .overlap = 11 }).validate());
}

test "HybridConfig defaults are valid; weights must sum to 1.0" {
    try (HybridConfig{}).validate();
    try std.testing.expectError(error.ConfigError, (HybridConfig{ .vector_weight = 0.5, .text_weight = 0.3 }).validate());
    try std.testing.expectError(error.ConfigError, (HybridConfig{ .vector_weight = 1.5, .text_weight = -0.5 }).validate());
    try std.testing.expectError(error.ConfigError, (HybridConfig{ .candidate_multiplier = 0 }).validate());
    // within tolerance
    try (HybridConfig{ .vector_weight = 0.7000001, .text_weight = 0.2999999 }).validate();
}

test "MMRConfig lambda_param must be in [0,1]" {
    try (MMRConfig{}).validate();
    try (MMRConfig{ .lambda_param = 0.0 }).validate();
    try (MMRConfig{ .lambda_param = 1.0 }).validate();
    try std.testing.expectError(error.ConfigError, (MMRConfig{ .lambda_param = -0.1 }).validate());
    try std.testing.expectError(error.ConfigError, (MMRConfig{ .lambda_param = 1.1 }).validate());
}

test "TemporalDecayConfig half_life_days must be positive" {
    try (TemporalDecayConfig{}).validate();
    try std.testing.expectError(error.ConfigError, (TemporalDecayConfig{ .half_life_days = 0 }).validate());
    try std.testing.expectError(error.ConfigError, (TemporalDecayConfig{ .half_life_days = -1 }).validate());
}

test "QueryConfig defaults are valid and cascade to nested configs" {
    try (QueryConfig{}).validate();
    try std.testing.expectError(error.ConfigError, (QueryConfig{ .max_results = 0 }).validate());
    try std.testing.expectError(error.ConfigError, (QueryConfig{ .min_score = 1.5 }).validate());
    try std.testing.expectError(error.ConfigError, (QueryConfig{ .snippet_max_chars = 0 }).validate());
    try std.testing.expectError(error.ConfigError, (QueryConfig{ .mmr = .{ .lambda_param = 2.0 } }).validate());
}

test "CacheConfig max_entries null is unlimited and always valid" {
    try (CacheConfig{}).validate();
    try (CacheConfig{ .max_entries = 1 }).validate();
    try std.testing.expectError(error.ConfigError, (CacheConfig{ .max_entries = 0 }).validate());
}

test "FlushConfig defaults are valid" {
    try (FlushConfig{}).validate();
    try std.testing.expectError(error.ConfigError, (FlushConfig{ .max_tokens = 0 }).validate());
    try std.testing.expectError(error.ConfigError, (FlushConfig{ .temperature = 3.0 }).validate());
    try std.testing.expectError(error.ConfigError, (FlushConfig{ .temperature = -0.1 }).validate());
}

test "FlushConfig default system prompt matches the documented contract" {
    const prompt = (FlushConfig{}).system_prompt;
    try std.testing.expect(std.mem.startsWith(u8, prompt, "Pre-compaction memory flush.\n"));
    try std.testing.expect(std.mem.endsWith(u8, prompt, "If nothing to store, reply with @@SILENT_REPLY@@."));
    try std.testing.expect(std.mem.indexOf(u8, prompt, "memory/YYYY-MM-DD.md") != null);
}

test "MemoryConfig defaults are valid and resolve derived paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cfg = MemoryConfig{ .workspace_dir = "/tmp/project" };
    try cfg.validate();

    const db_path = try cfg.resolvedDbPath(allocator);
    try std.testing.expectEqualStrings("/tmp/project/.memweave/index.sqlite", db_path);

    const mem_dir = try cfg.memoryDir(allocator);
    try std.testing.expectEqualStrings("/tmp/project/memory", mem_dir);
}

test "MemoryConfig db_path override wins over the derived default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cfg = MemoryConfig{ .workspace_dir = "/tmp/project", .db_path = "/tmp/custom.sqlite" };
    const db_path = try cfg.resolvedDbPath(allocator);
    try std.testing.expectEqualStrings("/tmp/custom.sqlite", db_path);
}

test "MemoryConfig evergreen_patterns and bootstrap_files defaults" {
    const cfg = MemoryConfig{};
    try std.testing.expectEqual(@as(usize, 2), cfg.evergreen_patterns.len);
    try std.testing.expectEqualStrings("MEMORY.md", cfg.evergreen_patterns[0]);
    try std.testing.expectEqualStrings("memory.md", cfg.evergreen_patterns[1]);
    try std.testing.expectEqual(@as(usize, 1), cfg.bootstrap_files.len);
    try std.testing.expectEqualStrings("MEMORY.md", cfg.bootstrap_files[0]);
}
