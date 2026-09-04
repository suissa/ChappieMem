//! Result types mirroring the Python `memweave.types` module.
//!
//! Ownership convention: every `[]const u8` field is owned by whoever
//! constructed the value (typically an arena allocator scoped to one
//! `search()`/`index()`/`files()` call in later phases). These structs are
//! plain data — Zig has no `frozen`/immutable qualifier, so treat instances
//! as read-only after construction, matching the Python
//! `@dataclass(frozen=True, slots=True)` intent.

/// One item returned by `search()`.
pub const SearchResult = struct {
    path: []const u8,
    start_line: u32,
    end_line: u32,
    score: f64,
    snippet: []const u8,
    source: []const u8,
    vector_score: ?f64 = null,
    text_score: ?f64 = null,
};

/// Summary returned by `index()` / `add()`.
pub const IndexResult = struct {
    files_scanned: u32,
    files_indexed: u32,
    files_skipped: u32,
    files_deleted: u32,
    chunks_created: u32,
    embeddings_cached: u32,
    embeddings_computed: u32,
    duration_ms: f64,
};

/// One item returned by `files()`.
pub const FileInfo = struct {
    path: []const u8,
    size: u64,
    hash: []const u8,
    mtime: f64,
    chunks: u32,
    is_evergreen: bool,
    source: []const u8,
};

/// Snapshot returned by `status()`.
pub const StoreStatus = struct {
    files: u32,
    chunks: u32,
    dirty: bool,
    workspace_dir: []const u8,
    db_path: []const u8,
    search_mode: SearchMode,
    provider: []const u8,
    model: ?[]const u8,
    fts_available: bool,
    vector_available: bool,
    cache_entries: u32,
    cache_max_entries: ?u32,
    watcher_active: bool,
};

pub const SearchMode = enum {
    hybrid,
    fts_only,
    vector_only,
    unavailable,
};

/// Internal pipeline type — a scored chunk before hydration into a
/// `SearchResult`. Not returned to library users.
pub const ScoredChunk = struct {
    chunk_id: []const u8,
    score: f64,
    vector_score: ?f64 = null,
    text_score: ?f64 = null,
};

/// Internal pipeline type — what a `SearchStrategy` returns, before
/// post-processing and hydration into a `SearchResult`.
pub const RawSearchRow = struct {
    chunk_id: []const u8,
    path: []const u8,
    source: []const u8,
    start_line: u32,
    end_line: u32,
    text: []const u8,
    score: f64,
    vector_score: ?f64 = null,
    text_score: ?f64 = null,
};
