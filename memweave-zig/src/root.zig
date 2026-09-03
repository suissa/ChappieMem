//! memweave-zig — a from-scratch Zig 0.16 port of the Python `memweave`
//! library (agent memory over Markdown files + a SQLite index).
//!
//! This is the public module surface, mirroring `memweave/__init__.py`'s
//! `__all__`. Phase 1 covers configuration, result types, the error set,
//! and the pure, I/O-free algorithm modules (chunking, hashing, temporal
//! decay, MMR re-ranking, vector normalization). The SQLite-backed storage
//! layer, the search pipeline, the embedding provider, the `MemWeave`
//! orchestrator, and the CLI land in later phases — see
//! `docs/IMPLEMENTATION.md` (Zig port section) for the full roadmap.

pub const errors = @import("errors.zig");
pub const types = @import("types.zig");
pub const config = @import("config.zig");
pub const chunking = @import("chunking.zig");
pub const hashing = @import("hashing.zig");
pub const decay = @import("decay.zig");
pub const mmr = @import("mmr.zig");
pub const vectors = @import("vectors.zig");

test {
    // Pull every submodule's tests into this root so `zig build test`
    // (rooted at this file, see build.zig) covers the whole tree.
    _ = errors;
    _ = types;
    _ = config;
    _ = chunking;
    _ = hashing;
    _ = decay;
    _ = mmr;
    _ = vectors;
}
