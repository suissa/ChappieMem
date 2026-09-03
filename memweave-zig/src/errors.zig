//! Error sets mirroring the Python `memweave.exceptions` hierarchy.
//!
//! Zig error sets are flat (no inheritance), so the Python exception tree
//!
//!   MemWeaveError
//!   ├── ConfigError
//!   ├── StorageError
//!   ├── IndexError
//!   │   └── EmbeddingError
//!   ├── SearchError
//!   │   └── StrategyError
//!   └── FlushError
//!
//! is expressed here as one error per leaf/branch name, composed into
//! superset error sets with `||` so that a function which in Python would
//! `raise IndexError` (catchable by a broader `except IndexError`) can
//! return the composed `IndexError` set here, and callers that only care
//! about the narrower `EmbeddingError` can still narrow via `switch`.

pub const ConfigError = error{ConfigError};
pub const StorageError = error{StorageError};

/// A sub-case of `IndexError` in Python (`EmbeddingError(IndexError)`).
pub const EmbeddingError = error{EmbeddingError};

/// Superset: anything that in Python would be caught by `except IndexError`,
/// including `EmbeddingError`.
pub const IndexError = EmbeddingError || error{IndexError};

/// A sub-case of `SearchError` in Python (`StrategyError(SearchError)`).
pub const StrategyError = error{StrategyError};

/// Superset: anything that in Python would be caught by `except SearchError`,
/// including `StrategyError`.
pub const SearchError = StrategyError || error{SearchError};

pub const FlushError = error{FlushError};

/// Superset of every error above — the Zig equivalent of `except MemWeaveError`.
pub const MemWeaveError = ConfigError || StorageError || IndexError || SearchError || FlushError;

test "error sets compose as supersets" {
    const std = @import("std");

    const embed_err: EmbeddingError = error.EmbeddingError;
    const as_index: IndexError = embed_err;
    try std.testing.expect(as_index == error.EmbeddingError);

    const strategy_err: StrategyError = error.StrategyError;
    const as_search: SearchError = strategy_err;
    try std.testing.expect(as_search == error.StrategyError);

    const cfg_err: ConfigError = error.ConfigError;
    const as_mem_weave: MemWeaveError = cfg_err;
    try std.testing.expect(as_mem_weave == error.ConfigError);
}
