//! SHA-256 hashing helpers, ported from `memweave/_internal/hashing.py`.
//!
//! All hex digests are 64-character lowercase strings, matching Python's
//! `hashlib.sha256(...).hexdigest()`.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

const hex_digits = "0123456789abcdef";

fn hexEncode(bytes: []const u8, out: []u8) void {
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_digits[b >> 4];
        out[i * 2 + 1] = hex_digits[b & 0x0f];
    }
}

/// SHA-256 hex digest of raw bytes (mirrors `sha256_bytes`).
pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    var out: [64]u8 = undefined;
    hexEncode(&digest, &out);
    return out;
}

/// SHA-256 hex digest of a UTF-8 string (mirrors `sha256_text`).
/// Zig `[]const u8` is already raw bytes, so this is `sha256Hex` by another name.
pub fn sha256Text(text: []const u8) [64]u8 {
    return sha256Hex(text);
}

/// SHA-256 hex digest of a file on disk (mirrors `sha256_file`). `path` is
/// resolved via the current working directory, matching callers that
/// already hold an absolute path. `allocator` is used only to buffer the
/// file's contents for hashing; freed before returning.
pub fn sha256File(allocator: std.mem.Allocator, path: []const u8) ![64]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buf);

    const data = try reader.interface.readAlloc(allocator, 1024 * 1024 * 1024);
    defer allocator.free(data);

    return sha256Hex(data);
}

/// Deterministic, stable chunk ID from its metadata (mirrors `make_chunk_id`).
///
/// `key = "{source}:{path}:{start_line}:{end_line}:{content_hash}:{model}"`,
/// then SHA-256 hex of that key. Caller-provided `allocator` is used only to
/// build the intermediate composite key string; freed before returning.
pub fn makeChunkId(
    allocator: std.mem.Allocator,
    source: []const u8,
    path: []const u8,
    start_line: u32,
    end_line: u32,
    content_hash: []const u8,
    model: []const u8,
) ![64]u8 {
    const key = try std.fmt.allocPrint(allocator, "{s}:{s}:{d}:{d}:{s}:{s}", .{
        source, path, start_line, end_line, content_hash, model,
    });
    defer allocator.free(key);
    return sha256Hex(key);
}

/// Provider config fingerprint for the embedding cache (mirrors `make_provider_key`).
///
/// `key = "{provider}:{model}:{api_base or ''}"`, then SHA-256 hex.
pub fn makeProviderKey(
    allocator: std.mem.Allocator,
    provider: []const u8,
    model: []const u8,
    api_base: ?[]const u8,
) ![64]u8 {
    const key = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{
        provider, model, api_base orelse "",
    });
    defer allocator.free(key);
    return sha256Hex(key);
}

// ── Tests — golden values computed via Python's `hashlib.sha256` on the
// exact same inputs, to guarantee byte-for-byte parity with the Python
// implementation rather than trusting the Zig port's own math. ────────────

test "sha256Hex of empty bytes matches hashlib.sha256(b'').hexdigest()" {
    const digest = sha256Hex("");
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &digest,
    );
}

test "sha256Text('hello') matches hashlib.sha256(b'hello').hexdigest()" {
    const digest = sha256Text("hello");
    try std.testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        &digest,
    );
}

test "makeChunkId matches Python make_chunk_id for the same inputs" {
    const digest = try makeChunkId(
        std.testing.allocator,
        "memory",
        "memory/2026-01-01.md",
        1,
        10,
        "abc123",
        "text-embedding-3-small",
    );
    try std.testing.expectEqualStrings(
        "15b1286ec9e31e74667fae919db0972cd103f095cf8f307234a3535dd9f99ad9",
        &digest,
    );
}

test "makeChunkId is deterministic: same inputs, same id" {
    const a = try makeChunkId(std.testing.allocator, "memory", "memory/x.md", 1, 5, "hash1", "model-a");
    const b = try makeChunkId(std.testing.allocator, "memory", "memory/x.md", 1, 5, "hash1", "model-a");
    try std.testing.expectEqualStrings(&a, &b);
}

test "makeChunkId changes when content_hash changes" {
    const a = try makeChunkId(std.testing.allocator, "memory", "memory/x.md", 1, 5, "hash1", "model-a");
    const b = try makeChunkId(std.testing.allocator, "memory", "memory/x.md", 1, 5, "hash2", "model-a");
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "makeProviderKey with null api_base matches Python make_provider_key(..., None)" {
    const digest = try makeProviderKey(std.testing.allocator, "litellm", "text-embedding-3-small", null);
    try std.testing.expectEqualStrings(
        "48aa8796ab4097866b0e9049aaf1027ff0f8d46f959553ac9f526311f3224b4d",
        &digest,
    );
}

test "makeProviderKey with an api_base matches Python make_provider_key(..., url)" {
    const digest = try makeProviderKey(
        std.testing.allocator,
        "litellm",
        "nomic-embed-text",
        "http://localhost:11434",
    );
    try std.testing.expectEqualStrings(
        "200bd39c16c1a9cc46c670a406e5fa43d9be405d645b82a18c36d38161e3f33a",
        &digest,
    );
}

test "makeProviderKey gives different keys for different endpoints of the same model" {
    const k1 = try makeProviderKey(std.testing.allocator, "litellm", "nomic-embed-text", null);
    const k2 = try makeProviderKey(std.testing.allocator, "litellm", "nomic-embed-text", "http://localhost:11434");
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "sha256File hashes a temp file's contents" {
    // Write directly into the test's own working directory instead of
    // `std.testing.tmpDir` — its backing directory name (`zig-cache/` vs.
    // `.zig-cache/`) has changed across Zig versions and isn't worth
    // depending on here. `std.Io.Dir.cwd()` methods need an explicit `Io`,
    // same pattern zig-sqlite's build/Preprocessor.zig uses for file I/O.
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const path = "hashing_test_sha256file_tmp.txt";
    {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);

        var write_buf: [64]u8 = undefined;
        var w = file.writer(io, &write_buf);
        try w.interface.writeAll("hello");
    }

    const digest = try sha256File(std.testing.allocator, path);
    try std.testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        &digest,
    );
}
