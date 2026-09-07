//! A tiny, allocation-free YAML subset parser that runs entirely at
//! **comptime**.
//!
//! The behaviour factory (`factory.zig`) reads every `manifest.yml`,
//! `config.yml` and `schema.yml` through this parser while the compiler is
//! still running, so the documents become Zig types with zero runtime cost
//! and zero runtime parsing. That constraint is what dictates the design:
//! no allocator, no `std.ArrayList`, no error unions — malformed input is a
//! `@compileError` pointing at the offending construct, exactly like a
//! syntax error in hand-written Zig.
//!
//! Supported subset (deliberately small — behaviour descriptors are
//! configuration, not a programming language):
//!
//!   * block mappings          `key: value` / nested `key:` + indented block
//!   * block sequences         `- item` (scalar items only)
//!   * flow sequences          `[a, b, "c"]`
//!   * block literals          `key: |` and `key: |-`
//!   * scalars                 plain, `"double quoted"`, `'single quoted'`
//!   * nulls                   `null`, `~`, or an empty value
//!   * comments                `#` to end of line (outside quotes)
//!
//! Deliberately unsupported: anchors/aliases, tags, multi-document streams,
//! flow mappings (`{a: 1}`), `- key: value` inline mappings, and folded
//! scalars (`>`). Behaviour descriptors that need a list of records use a
//! mapping keyed by record name instead, which is more greppable anyway
//! (see `schema.yml`'s `invariants:`).
//!
//! Indentation must be spaces; tabs are rejected outright.

const std = @import("std");

pub const Value = union(enum) {
    scalar: Scalar,
    mapping: []const Pair,
    sequence: []const Value,

    pub const null_value: Value = .{ .scalar = .{ .text = "" } };

    /// The pairs of a mapping. `@compileError` if this is not a mapping.
    pub fn asMapping(comptime self: Value) []const Pair {
        return switch (self) {
            .mapping => |m| m,
            else => @compileError("yaml: expected a mapping"),
        };
    }

    /// The items of a sequence. A lone scalar is *not* auto-wrapped; an
    /// explicit null (an omitted value) reads as the empty sequence so that
    /// `composes:` and friends can be written as `composes:` with nothing
    /// after it.
    pub fn asSequence(comptime self: Value) []const Value {
        return switch (self) {
            .sequence => |s| s,
            .scalar => |s| if (s.isNull()) &.{} else @compileError("yaml: expected a sequence, found scalar '" ++ s.text ++ "'"),
            else => @compileError("yaml: expected a sequence"),
        };
    }

    pub fn asScalar(comptime self: Value) Scalar {
        return switch (self) {
            .scalar => |s| s,
            else => @compileError("yaml: expected a scalar"),
        };
    }

    pub fn isNull(comptime self: Value) bool {
        return self == .scalar and self.scalar.isNull();
    }

    /// Look up `key` in a mapping, or `null` when absent. Returns `null`
    /// (rather than erroring) for a non-mapping so callers can probe
    /// optional structure without pre-checking the shape.
    pub fn get(comptime self: Value, comptime key: []const u8) ?Value {
        if (self != .mapping) return null;
        for (self.mapping) |pair| {
            if (std.mem.eql(u8, pair.key, key)) return pair.value;
        }
        return null;
    }

    /// `get` with a `@compileError` when the key is missing. `what`
    /// describes the enclosing document for the message.
    pub fn require(comptime self: Value, comptime key: []const u8, comptime what: []const u8) Value {
        return self.get(key) orelse @compileError("yaml: " ++ what ++ " is missing required key '" ++ key ++ "'");
    }

    /// String value of `key`, or `fallback` when absent or null.
    pub fn stringOr(comptime self: Value, comptime key: []const u8, comptime fallback: []const u8) []const u8 {
        const v = self.get(key) orelse return fallback;
        const s = v.asScalar();
        return if (s.isNull()) fallback else s.text;
    }

    /// Sequence of strings at `key`, or the empty slice when absent.
    pub fn stringsOr(comptime self: Value, comptime key: []const u8) []const []const u8 {
        const v = self.get(key) orelse return &.{};
        comptime var out: []const []const u8 = &.{};
        for (v.asSequence()) |item| out = out ++ [_][]const u8{item.asScalar().text};
        return out;
    }
};

pub const Pair = struct {
    key: []const u8,
    value: Value,
};

pub const Scalar = struct {
    text: []const u8,
    /// Quoted scalars are always strings: `"null"` is the three-letter word,
    /// `"true"` is not a boolean, and `"7"` is not a number.
    quoted: bool = false,

    pub fn isNull(comptime self: Scalar) bool {
        if (self.quoted) return false;
        return self.text.len == 0 or
            std.mem.eql(u8, self.text, "null") or
            std.mem.eql(u8, self.text, "~");
    }

    pub fn asBool(comptime self: Scalar) ?bool {
        if (self.quoted) return null;
        if (std.mem.eql(u8, self.text, "true")) return true;
        if (std.mem.eql(u8, self.text, "false")) return false;
        return null;
    }

    /// Parses the scalar as a float, accepting integer spellings too
    /// (`0`, `1e-6`, `-0.5`). `null` when it is not numeric.
    pub fn asFloat(comptime self: Scalar) ?f64 {
        if (self.quoted or self.text.len == 0) return null;
        return std.fmt.parseFloat(f64, self.text) catch null;
    }

    pub fn asInt(comptime self: Scalar) ?i128 {
        if (self.quoted or self.text.len == 0) return null;
        return std.fmt.parseInt(i128, self.text, 10) catch null;
    }
};

/// Parse a whole document. The result is a `Value` whose slices all point
/// into compile-time memory derived from `src`.
pub fn parse(comptime src: []const u8) Value {
    @setEvalBranchQuota(2_000_000);
    const lines = comptime scan(src);
    comptime var idx: usize = 0;
    const first = comptime nextContent(lines, 0) orelse return .{ .mapping = &.{} };
    idx = first;
    return comptime parseBlock(lines, &idx, lines[first].indent);
}

// ---------------------------------------------------------------------------
// Line scanning
// ---------------------------------------------------------------------------

const Line = struct {
    indent: usize,
    /// Indentation removed, trailing comment removed, right-trimmed.
    content: []const u8,
    /// The original line (minus `\r`), needed verbatim by block literals
    /// where `#` is ordinary text and trailing spaces may matter.
    raw: []const u8,
    blank: bool,
};

fn scan(comptime src: []const u8) []const Line {
    comptime var lines: []const Line = &.{};
    comptime var it = std.mem.splitScalar(u8, src, '\n');
    inline while (comptime it.next()) |line| {
        const raw = comptime trimRight(line);
        comptime var indent: usize = 0;
        inline while (indent < raw.len and raw[indent] == ' ') {
            indent += 1;
        }
        if (indent < raw.len and raw[indent] == '\t') {
            @compileError("yaml: tab indentation is not supported, use spaces: '" ++ raw ++ "'");
        }
        const content = comptime trimRight(stripComment(raw[indent..]));
        lines = lines ++ [_]Line{.{
            .indent = indent,
            .content = content,
            .raw = raw,
            .blank = content.len == 0,
        }};
    }
    return lines;
}

/// Index of the next line that carries content, or `null` at end of input.
fn nextContent(comptime lines: []const Line, comptime from: usize) ?usize {
    comptime var i = from;
    inline while (i < lines.len) : (i += 1) {
        if (!lines[i].blank) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Block parsing
// ---------------------------------------------------------------------------

fn parseBlock(comptime lines: []const Line, comptime idx: *usize, comptime indent: usize) Value {
    const i = nextContent(lines, idx.*) orelse return Value.null_value;
    return if (isSequenceItem(lines[i].content))
        parseSequence(lines, idx, indent)
    else
        parseMapping(lines, idx, indent);
}

fn isSequenceItem(comptime content: []const u8) bool {
    if (content.len == 0 or content[0] != '-') return false;
    return content.len == 1 or content[1] == ' ';
}

fn parseMapping(comptime lines: []const Line, comptime idx: *usize, comptime indent: usize) Value {
    comptime var pairs: []const Pair = &.{};
    inline while (comptime nextContent(lines, idx.*)) |i| {
        const line = lines[i];
        if (line.indent < indent) break;
        if (line.indent > indent) {
            @compileError("yaml: unexpected indentation at '" ++ line.content ++ "'");
        }
        const colon = comptime findKeyColon(line.content) orelse
            @compileError("yaml: expected 'key: value' at '" ++ line.content ++ "'");
        const key = comptime parseScalar(trimRight(line.content[0..colon])).text;
        const rest = comptime trimLeft(line.content[colon + 1 ..]);
        idx.* = i + 1;
        const value = comptime parseValueAfterKey(lines, idx, indent, i, rest);
        pairs = pairs ++ [_]Pair{.{ .key = key, .value = value }};
    }
    return .{ .mapping = pairs };
}

fn parseSequence(comptime lines: []const Line, comptime idx: *usize, comptime indent: usize) Value {
    comptime var items: []const Value = &.{};
    inline while (comptime nextContent(lines, idx.*)) |i| {
        const line = lines[i];
        if (line.indent < indent) break;
        if (line.indent > indent or !isSequenceItem(line.content)) {
            @compileError("yaml: expected a '- ' sequence item at '" ++ line.content ++ "'");
        }
        const rest = comptime trimLeft(line.content[1..]);
        if (rest.len == 0) {
            @compileError("yaml: nested blocks under '-' are not supported, use a keyed mapping instead");
        }
        idx.* = i + 1;
        items = items ++ [_]Value{comptime parseInline(rest)};
    }
    return .{ .sequence = items };
}

fn parseValueAfterKey(
    comptime lines: []const Line,
    comptime idx: *usize,
    comptime indent: usize,
    comptime key_line: usize,
    comptime rest: []const u8,
) Value {
    if (rest.len > 0 and rest[0] == '|') {
        return .{ .scalar = .{ .text = parseBlockLiteral(lines, idx, indent, rest), .quoted = true } };
    }
    if (rest.len > 0) return parseInline(rest);

    // Empty value: either a nested block on the following lines, or null.
    const j = nextContent(lines, idx.*) orelse return Value.null_value;
    if (lines[j].indent <= indent) return Value.null_value;
    _ = key_line;
    idx.* = j;
    return parseBlock(lines, idx, lines[j].indent);
}

/// `|` keeps one trailing newline (clip), `|-` strips it. `|+` (keep) is
/// rejected — behaviour prompts never need it and silent surprises in
/// embedded text are worse than a compile error.
fn parseBlockLiteral(
    comptime lines: []const Line,
    comptime idx: *usize,
    comptime indent: usize,
    comptime header: []const u8,
) []const u8 {
    const chomp_strip = comptime std.mem.eql(u8, header, "|-");
    if (!chomp_strip and !std.mem.eql(u8, header, "|")) {
        @compileError("yaml: unsupported block scalar header '" ++ header ++ "' (only '|' and '|-')");
    }

    // The block's own indentation is set by its first non-blank line.
    const first = comptime nextContent(lines, idx.*) orelse return "";
    if (lines[first].indent <= indent) return "";
    const block_indent = lines[first].indent;

    comptime var out: []const u8 = "";
    comptime var i = idx.*;
    comptime var pending_blanks: usize = 0;
    comptime var wrote_any = false;
    inline while (i < lines.len) : (i += 1) {
        const line = lines[i];
        const is_blank_raw = comptime trimRight(line.raw).len == 0;
        if (is_blank_raw) {
            pending_blanks += 1;
            continue;
        }
        if (line.indent < block_indent) break;
        inline while (pending_blanks > 0) : (pending_blanks -= 1) out = out ++ "\n";
        if (wrote_any) out = out ++ "\n";
        out = out ++ line.raw[block_indent..];
        wrote_any = true;
    }
    idx.* = i - pending_blanks;
    return if (chomp_strip) out else out ++ "\n";
}

/// A value written on the same line as its key or `-`: a flow sequence or a
/// scalar.
fn parseInline(comptime text: []const u8) Value {
    if (text.len > 0 and text[0] == '[') return parseFlowSequence(text);
    return .{ .scalar = parseScalar(text) };
}

fn parseFlowSequence(comptime text: []const u8) Value {
    if (text[text.len - 1] != ']') {
        @compileError("yaml: unterminated flow sequence '" ++ text ++ "'");
    }
    const inner = comptime trim(text[1 .. text.len - 1]);
    if (inner.len == 0) return .{ .sequence = &.{} };

    comptime var items: []const Value = &.{};
    comptime var start: usize = 0;
    comptime var i: usize = 0;
    comptime var quote: u8 = 0;
    inline while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (quote != 0) {
            if (c == '\\' and quote == '"') {
                i += 1;
            } else if (c == quote) {
                quote = 0;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == ',') {
            items = items ++ [_]Value{.{ .scalar = parseScalar(trim(inner[start..i])) }};
            start = i + 1;
        }
    }
    items = items ++ [_]Value{.{ .scalar = parseScalar(trim(inner[start..])) }};
    return .{ .sequence = items };
}

fn parseScalar(comptime text: []const u8) Scalar {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
        return .{ .text = unescapeDouble(text[1 .. text.len - 1]), .quoted = true };
    }
    if (text.len >= 2 and text[0] == '\'' and text[text.len - 1] == '\'') {
        return .{ .text = unescapeSingle(text[1 .. text.len - 1]), .quoted = true };
    }
    return .{ .text = text, .quoted = false };
}

fn unescapeDouble(comptime text: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    comptime var i: usize = 0;
    inline while (i < text.len) : (i += 1) {
        if (text[i] != '\\' or i + 1 == text.len) {
            out = out ++ text[i .. i + 1];
            continue;
        }
        i += 1;
        out = out ++ switch (text[i]) {
            'n' => "\n",
            't' => "\t",
            'r' => "\r",
            '0' => "\x00",
            '\\' => "\\",
            '"' => "\"",
            else => @compileError("yaml: unsupported escape '\\" ++ text[i .. i + 1] ++ "'"),
        };
    }
    return out;
}

/// In single-quoted YAML the only escape is `''` for a literal quote.
fn unescapeSingle(comptime text: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    comptime var i: usize = 0;
    inline while (i < text.len) : (i += 1) {
        if (text[i] == '\'' and i + 1 < text.len and text[i + 1] == '\'') i += 1;
        out = out ++ text[i .. i + 1];
    }
    return out;
}

// ---------------------------------------------------------------------------
// Lexical helpers
// ---------------------------------------------------------------------------

/// Position of the `:` that separates a key from its value: the first colon
/// outside quotes that is followed by a space or ends the line.
fn findKeyColon(comptime content: []const u8) ?usize {
    comptime var i: usize = 0;
    comptime var quote: u8 = 0;
    inline while (i < content.len) : (i += 1) {
        const c = content[i];
        if (quote != 0) {
            if (c == '\\' and quote == '"') {
                i += 1;
            } else if (c == quote) {
                quote = 0;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == ':' and (i + 1 == content.len or content[i + 1] == ' ')) {
            return i;
        }
    }
    return null;
}

/// Drop a trailing `# comment`. A `#` only starts a comment at the start of
/// the line or after whitespace, and never inside quotes — so
/// `url: http://x/#frag` and `default: "# heading"` survive intact.
fn stripComment(comptime content: []const u8) []const u8 {
    comptime var i: usize = 0;
    comptime var quote: u8 = 0;
    inline while (i < content.len) : (i += 1) {
        const c = content[i];
        if (quote != 0) {
            if (c == '\\' and quote == '"') {
                i += 1;
            } else if (c == quote) {
                quote = 0;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '#' and (i == 0 or content[i - 1] == ' ' or content[i - 1] == '\t')) {
            return content[0..i];
        }
    }
    return content;
}

fn trimRight(comptime s: []const u8) []const u8 {
    comptime var end = s.len;
    inline while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) {
        end -= 1;
    }
    return s[0..end];
}

fn trimLeft(comptime s: []const u8) []const u8 {
    comptime var start: usize = 0;
    inline while (start < s.len and (s[start] == ' ' or s[start] == '\t')) {
        start += 1;
    }
    return s[start..];
}

fn trim(comptime s: []const u8) []const u8 {
    return trimLeft(trimRight(s));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parses a flat mapping with scalars, comments and quoting" {
    const doc = comptime parse(
        \\# leading comment
        \\name: chunking      # trailing comment
        \\enabled: true
        \\tokens: 400
        \\ratio: 0.7
        \\missing: null
        \\empty:
        \\quoted: "null"
        \\hashy: "# not a comment"
    );

    try std.testing.expectEqualStrings("chunking", comptime doc.require("name", "doc").asScalar().text);
    try std.testing.expectEqual(true, comptime doc.require("enabled", "doc").asScalar().asBool().?);
    try std.testing.expectEqual(@as(i128, 400), comptime doc.require("tokens", "doc").asScalar().asInt().?);
    try std.testing.expectEqual(@as(f64, 0.7), comptime doc.require("ratio", "doc").asScalar().asFloat().?);
    try std.testing.expect(comptime doc.require("missing", "doc").isNull());
    try std.testing.expect(comptime doc.require("empty", "doc").isNull());
    // A quoted "null" is the string, not the null value.
    try std.testing.expect(comptime !doc.require("quoted", "doc").isNull());
    try std.testing.expectEqualStrings("# not a comment", comptime doc.require("hashy", "doc").asScalar().text);
}

test "parses nested mappings to arbitrary depth" {
    const doc = comptime parse(
        \\spec:
        \\  parity:
        \\    python: memweave.config.ChunkingConfig
        \\  pure: true
    );
    const spec = comptime doc.require("spec", "doc");
    const parity = comptime spec.require("parity", "spec");
    try std.testing.expectEqualStrings(
        "memweave.config.ChunkingConfig",
        comptime parity.require("python", "parity").asScalar().text,
    );
    try std.testing.expectEqual(true, comptime spec.require("pure", "spec").asScalar().asBool().?);
}

test "parses block and flow sequences of scalars" {
    const doc = comptime parse(
        \\tags: [indexing, "text chunks", 3]
        \\composes:
        \\  - query
        \\  - cache
        \\empty_flow: []
        \\absent:
    );
    const tags = comptime doc.require("tags", "doc").asSequence();
    try std.testing.expectEqual(@as(usize, 3), tags.len);
    try std.testing.expectEqualStrings("indexing", comptime tags[0].asScalar().text);
    try std.testing.expectEqualStrings("text chunks", comptime tags[1].asScalar().text);

    const composes = comptime doc.stringsOr("composes");
    try std.testing.expectEqual(@as(usize, 2), composes.len);
    try std.testing.expectEqualStrings("query", composes[0]);
    try std.testing.expectEqualStrings("cache", composes[1]);

    try std.testing.expectEqual(@as(usize, 0), comptime doc.require("empty_flow", "doc").asSequence().len);
    // An omitted sequence reads as empty rather than exploding.
    try std.testing.expectEqual(@as(usize, 0), comptime doc.require("absent", "doc").asSequence().len);
}

test "block literals: '|-' strips the trailing newline, '|' keeps one" {
    const doc = comptime parse(
        \\stripped: |-
        \\  first line
        \\  second # line
        \\
        \\clipped: |
        \\  only line
        \\after: done
    );
    try std.testing.expectEqualStrings(
        "first line\nsecond # line",
        comptime doc.require("stripped", "doc").asScalar().text,
    );
    try std.testing.expectEqualStrings("only line\n", comptime doc.require("clipped", "doc").asScalar().text);
    try std.testing.expectEqualStrings("done", comptime doc.require("after", "doc").asScalar().text);
}

test "block literals preserve interior blank lines" {
    const doc = comptime parse(
        \\prompt: |-
        \\  one
        \\
        \\  two
        \\next: x
    );
    try std.testing.expectEqualStrings("one\n\ntwo", comptime doc.require("prompt", "doc").asScalar().text);
    try std.testing.expectEqualStrings("x", comptime doc.require("next", "doc").asScalar().text);
}

test "escapes inside quoted scalars" {
    const doc = comptime parse(
        \\dq: "a\nb\\c\"d"
        \\sq: 'it''s fine'
    );
    try std.testing.expectEqualStrings("a\nb\\c\"d", comptime doc.require("dq", "doc").asScalar().text);
    try std.testing.expectEqualStrings("it's fine", comptime doc.require("sq", "doc").asScalar().text);
}

test "quoted scalars are never booleans, numbers or nulls" {
    const doc = comptime parse(
        \\a: "true"
        \\b: "42"
    );
    try std.testing.expect(comptime doc.require("a", "doc").asScalar().asBool() == null);
    try std.testing.expect(comptime doc.require("b", "doc").asScalar().asInt() == null);
}

test "get returns null for absent keys and non-mappings" {
    const doc = comptime parse("a: 1");
    try std.testing.expect(comptime doc.get("nope") == null);
    try std.testing.expect(comptime doc.require("a", "doc").get("nope") == null);
}
