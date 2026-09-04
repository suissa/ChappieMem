//! `schema.yml` → a comptime intermediate representation.
//!
//! A schema describes the *shape and rules* of one atomic behaviour: its
//! fields, their types, their defaults, the per-field constraints and the
//! cross-field invariants. It says nothing about which values a particular
//! deployment wants — that is `config.yml`'s job — and nothing about the
//! behaviour's identity — that is `manifest.yml`'s job.
//!
//! Document shape:
//!
//! ```yaml
//! apiVersion: memweave.behavior/v1
//! kind: BehaviorSchema
//! spec:
//!   fields:
//!     tokens:
//!       type: u32
//!       default: 400
//!       doc: "Target chunk size in tokens."
//!       constraints:
//!         gte: 1
//!   invariants:
//!     overlap_fits_in_chunk:
//!       rule: lt
//!       left: overlap
//!       right: tokens
//!       doc: "..."
//! ```
//!
//! Type grammar (a leading `?` makes any of them optional):
//!
//!   `bool` · `u8`…`u64` · `i8`…`i64` · `f32` · `f64` · `string` ·
//!   `list<string>` · `behavior<name>`
//!
//! `behavior<name>` is the composition primitive: the field's type is the
//! `Config` of another atomic behaviour, resolved through the registry, so a
//! composite such as `memory` is assembled from leaves rather than
//! re-declaring their fields.

const std = @import("std");
const yaml = @import("yaml.zig");

pub const Kind = enum { bool, int, float, string, string_list, behavior };

pub const TypeSpec = struct {
    kind: Kind,
    /// `?T` — the generated field is `?T` and constraints only apply to a
    /// present payload, mirroring "unlimited when null" semantics.
    optional: bool = false,
    signed: bool = false,
    bits: u16 = 0,
    /// Name of the composed behaviour when `kind == .behavior`.
    behavior: []const u8 = "",
};

/// A single-field rule. Numeric bounds are carried as `f64` and compared in
/// the field's own type at generation time, so `gte: 1` reads naturally for
/// both `u32` and `f64` fields.
pub const Constraint = union(enum) {
    gt: f64,
    gte: f64,
    lt: f64,
    lte: f64,
    /// Strings: length > 0. Lists: at least one element.
    not_empty,
    min_len: usize,
    max_len: usize,
    /// Strings only: the value must equal one of these.
    one_of: []const []const u8,
};

pub const Field = struct {
    name: []const u8,
    type_spec: TypeSpec,
    doc: []const u8 = "",
    /// `false` when `schema.yml` declared no `default:` key at all. Such a
    /// field becomes a struct field without a default value, so callers are
    /// forced to supply it — distinct from `default: null`, which gives an
    /// optional field the default `null`.
    has_default: bool = false,
    default: yaml.Value = yaml.Value.null_value,
    constraints: []const Constraint = &.{},
};

pub const SumEq = struct {
    fields: []const []const u8,
    value: f64,
    epsilon: f64,
};

pub const Ordered = struct {
    left: []const u8,
    right: []const u8,
};

/// Cross-field rules, checked after every per-field constraint.
pub const Rule = union(enum) {
    /// `|Σ fields − value| <= epsilon`.
    sum_eq: SumEq,
    /// `left < right`.
    lt: Ordered,
    /// `left <= right`.
    lte: Ordered,
};

pub const Invariant = struct {
    name: []const u8,
    doc: []const u8 = "",
    rule: Rule,
};

pub const Schema = struct {
    api_version: []const u8,
    fields: []const Field,
    invariants: []const Invariant,

    pub fn find(comptime self: Schema, comptime name: []const u8) ?Field {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

/// Parse a `schema.yml`. `origin` (usually the behaviour name) only shows up
/// in compile error messages.
pub fn parse(comptime src: []const u8, comptime origin: []const u8) Schema {
    @setEvalBranchQuota(2_000_000);
    const doc = comptime yaml.parse(src);
    const what = "schema.yml for '" ++ origin ++ "'";

    const kind = comptime doc.stringOr("kind", "");
    if (!std.mem.eql(u8, kind, "BehaviorSchema")) {
        @compileError(what ++ ": expected 'kind: BehaviorSchema', found '" ++ kind ++ "'");
    }

    const spec = comptime doc.require("spec", what);
    const fields = comptime parseFields(spec.require("fields", what), origin);
    const invariants = comptime parseInvariants(spec.get("invariants") orelse yaml.Value.null_value, fields, origin);

    return .{
        .api_version = comptime doc.stringOr("apiVersion", ""),
        .fields = fields,
        .invariants = invariants,
    };
}

fn parseFields(comptime node: yaml.Value, comptime origin: []const u8) []const Field {
    comptime var fields: []const Field = &.{};
    for (node.asMapping()) |pair| {
        const what = "schema.yml for '" ++ origin ++ "', field '" ++ pair.key ++ "'";
        const body = pair.value;
        if (body != .mapping) @compileError(what ++ ": expected a mapping of field properties");

        const type_text = comptime body.require("type", what).asScalar().text;
        fields = fields ++ [_]Field{.{
            .name = pair.key,
            .type_spec = comptime parseTypeSpec(type_text, what),
            .doc = comptime body.stringOr("doc", ""),
            .has_default = comptime body.get("default") != null,
            .default = comptime body.get("default") orelse yaml.Value.null_value,
            .constraints = comptime parseConstraints(body.get("constraints") orelse yaml.Value.null_value, what),
        }};
    }
    if (fields.len == 0) @compileError("schema.yml for '" ++ origin ++ "': 'spec.fields' is empty");
    return fields;
}

fn parseTypeSpec(comptime text: []const u8, comptime what: []const u8) TypeSpec {
    const optional = text.len > 0 and text[0] == '?';
    const base = if (optional) text[1..] else text;

    if (std.mem.eql(u8, base, "bool")) return .{ .kind = .bool, .optional = optional };
    if (std.mem.eql(u8, base, "string")) return .{ .kind = .string, .optional = optional };
    if (std.mem.eql(u8, base, "list<string>")) return .{ .kind = .string_list, .optional = optional };

    if (std.mem.startsWith(u8, base, "behavior<") and std.mem.endsWith(u8, base, ">")) {
        const name = base["behavior<".len .. base.len - 1];
        if (name.len == 0) @compileError(what ++ ": 'behavior<>' needs a behaviour name");
        if (optional) @compileError(what ++ ": optional composed behaviours are not supported");
        return .{ .kind = .behavior, .behavior = name };
    }

    if (base.len >= 2 and (base[0] == 'u' or base[0] == 'i')) {
        if (std.fmt.parseInt(u16, base[1..], 10)) |bits| {
            return .{ .kind = .int, .optional = optional, .signed = base[0] == 'i', .bits = bits };
        } else |_| {}
    }
    if (std.mem.eql(u8, base, "f32")) return .{ .kind = .float, .optional = optional, .bits = 32 };
    if (std.mem.eql(u8, base, "f64")) return .{ .kind = .float, .optional = optional, .bits = 64 };

    @compileError(what ++ ": unknown type '" ++ text ++ "'");
}

fn parseConstraints(comptime node: yaml.Value, comptime what: []const u8) []const Constraint {
    if (node.isNull()) return &.{};
    comptime var out: []const Constraint = &.{};
    for (node.asMapping()) |pair| {
        const op = pair.key;
        const c: Constraint = if (std.mem.eql(u8, op, "gt"))
            .{ .gt = requireFloat(pair.value, what, op) }
        else if (std.mem.eql(u8, op, "gte"))
            .{ .gte = requireFloat(pair.value, what, op) }
        else if (std.mem.eql(u8, op, "lt"))
            .{ .lt = requireFloat(pair.value, what, op) }
        else if (std.mem.eql(u8, op, "lte"))
            .{ .lte = requireFloat(pair.value, what, op) }
        else if (std.mem.eql(u8, op, "not_empty"))
            .not_empty
        else if (std.mem.eql(u8, op, "min_len"))
            .{ .min_len = @intFromFloat(requireFloat(pair.value, what, op)) }
        else if (std.mem.eql(u8, op, "max_len"))
            .{ .max_len = @intFromFloat(requireFloat(pair.value, what, op)) }
        else if (std.mem.eql(u8, op, "one_of"))
            .{ .one_of = stringsOf(pair.value, what, op) }
        else
            @compileError(what ++ ": unknown constraint '" ++ op ++ "'");
        out = out ++ [_]Constraint{c};
    }
    return out;
}

fn parseInvariants(
    comptime node: yaml.Value,
    comptime fields: []const Field,
    comptime origin: []const u8,
) []const Invariant {
    if (node.isNull()) return &.{};
    comptime var out: []const Invariant = &.{};
    for (node.asMapping()) |pair| {
        const what = "schema.yml for '" ++ origin ++ "', invariant '" ++ pair.key ++ "'";
        const body = pair.value;
        const rule_name = comptime body.require("rule", what).asScalar().text;

        const rule: Rule = if (std.mem.eql(u8, rule_name, "sum_eq")) blk: {
            const names = comptime stringsOf(body.require("fields", what), what, "fields");
            if (names.len < 2) @compileError(what ++ ": 'sum_eq' needs at least two fields");
            for (names) |n| requireNumericField(fields, n, what);
            break :blk .{ .sum_eq = .{
                .fields = names,
                .value = comptime requireFloat(body.require("value", what), what, "value"),
                .epsilon = comptime if (body.get("epsilon")) |e| requireFloat(e, what, "epsilon") else 1e-9,
            } };
        } else if (std.mem.eql(u8, rule_name, "lt") or std.mem.eql(u8, rule_name, "lte")) blk: {
            const left = comptime body.require("left", what).asScalar().text;
            const right = comptime body.require("right", what).asScalar().text;
            requireNumericField(fields, left, what);
            requireNumericField(fields, right, what);
            const ordered: Ordered = .{ .left = left, .right = right };
            break :blk if (std.mem.eql(u8, rule_name, "lt")) .{ .lt = ordered } else .{ .lte = ordered };
        } else @compileError(what ++ ": unknown rule '" ++ rule_name ++ "'");

        out = out ++ [_]Invariant{.{
            .name = pair.key,
            .doc = comptime body.stringOr("doc", ""),
            .rule = rule,
        }};
    }
    return out;
}

fn requireNumericField(comptime fields: []const Field, comptime name: []const u8, comptime what: []const u8) void {
    for (fields) |f| {
        if (!std.mem.eql(u8, f.name, name)) continue;
        if (f.type_spec.kind != .int and f.type_spec.kind != .float) {
            @compileError(what ++ ": field '" ++ name ++ "' is not numeric");
        }
        if (f.type_spec.optional) {
            @compileError(what ++ ": field '" ++ name ++ "' is optional and cannot take part in a cross-field rule");
        }
        return;
    }
    @compileError(what ++ ": references unknown field '" ++ name ++ "'");
}

fn requireFloat(comptime node: yaml.Value, comptime what: []const u8, comptime key: []const u8) f64 {
    return node.asScalar().asFloat() orelse
        @compileError(what ++ ": '" ++ key ++ "' must be a number");
}

fn stringsOf(comptime node: yaml.Value, comptime what: []const u8, comptime key: []const u8) []const []const u8 {
    comptime var out: []const []const u8 = &.{};
    for (node.asSequence()) |item| {
        const s = item.asScalar();
        if (s.isNull()) @compileError(what ++ ": '" ++ key ++ "' contains a null entry");
        out = out ++ [_][]const u8{s.text};
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const demo_schema =
    \\apiVersion: memweave.behavior/v1
    \\kind: BehaviorSchema
    \\spec:
    \\  fields:
    \\    tokens:
    \\      type: u32
    \\      default: 400
    \\      doc: "Target chunk size in tokens."
    \\      constraints:
    \\        gte: 1
    \\    overlap:
    \\      type: u32
    \\      default: 80
    \\    ratio:
    \\      type: f64
    \\      default: 0.7
    \\      constraints:
    \\        gte: 0
    \\        lte: 1
    \\    label:
    \\      type: string
    \\      default: "hybrid"
    \\      constraints:
    \\        not_empty: true
    \\        one_of: [hybrid, vector]
    \\    max_entries:
    \\      type: ?u32
    \\      default: null
    \\    patterns:
    \\      type: list<string>
    \\      default: ["MEMORY.md"]
    \\    nested:
    \\      type: behavior<cache>
    \\  invariants:
    \\    overlap_fits_in_chunk:
    \\      rule: lt
    \\      left: overlap
    \\      right: tokens
    \\      doc: "Overlap must be smaller than the chunk itself."
;

test "parses field types, defaults, docs and constraints in declaration order" {
    const s = comptime parse(demo_schema, "demo");

    try std.testing.expectEqual(@as(usize, 7), s.fields.len);
    try std.testing.expectEqualStrings("tokens", s.fields[0].name);
    try std.testing.expectEqualStrings("overlap", s.fields[1].name);

    const tokens = comptime s.find("tokens").?;
    try std.testing.expectEqual(Kind.int, tokens.type_spec.kind);
    try std.testing.expectEqual(@as(u16, 32), tokens.type_spec.bits);
    try std.testing.expect(!tokens.type_spec.signed);
    try std.testing.expectEqualStrings("Target chunk size in tokens.", tokens.doc);
    try std.testing.expectEqual(@as(usize, 1), tokens.constraints.len);
    try std.testing.expectEqual(@as(f64, 1), tokens.constraints[0].gte);

    const max_entries = comptime s.find("max_entries").?;
    try std.testing.expect(max_entries.type_spec.optional);
    try std.testing.expectEqual(Kind.int, max_entries.type_spec.kind);

    const patterns = comptime s.find("patterns").?;
    try std.testing.expectEqual(Kind.string_list, patterns.type_spec.kind);

    const nested = comptime s.find("nested").?;
    try std.testing.expectEqual(Kind.behavior, nested.type_spec.kind);
    try std.testing.expectEqualStrings("cache", nested.type_spec.behavior);
}

test "parses string constraints including one_of" {
    const s = comptime parse(demo_schema, "demo");
    const label = comptime s.find("label").?;
    try std.testing.expectEqual(@as(usize, 2), label.constraints.len);
    try std.testing.expectEqual(Constraint.not_empty, label.constraints[0]);
    try std.testing.expectEqual(@as(usize, 2), label.constraints[1].one_of.len);
    try std.testing.expectEqualStrings("vector", label.constraints[1].one_of[1]);
}

test "parses cross-field invariants" {
    const s = comptime parse(demo_schema, "demo");
    try std.testing.expectEqual(@as(usize, 1), s.invariants.len);
    try std.testing.expectEqualStrings("overlap_fits_in_chunk", s.invariants[0].name);
    try std.testing.expectEqualStrings("overlap", s.invariants[0].rule.lt.left);
    try std.testing.expectEqualStrings("tokens", s.invariants[0].rule.lt.right);
}

test "sum_eq invariants carry fields, target and epsilon" {
    const s = comptime parse(
        \\kind: BehaviorSchema
        \\spec:
        \\  fields:
        \\    vector_weight:
        \\      type: f64
        \\      default: 0.7
        \\    text_weight:
        \\      type: f64
        \\      default: 0.3
        \\  invariants:
        \\    weights_sum_to_one:
        \\      rule: sum_eq
        \\      fields: [vector_weight, text_weight]
        \\      value: 1.0
        \\      epsilon: 0.000001
    , "demo");

    const rule = s.invariants[0].rule.sum_eq;
    try std.testing.expectEqual(@as(usize, 2), rule.fields.len);
    try std.testing.expectEqual(@as(f64, 1.0), rule.value);
    try std.testing.expectEqual(@as(f64, 1e-6), rule.epsilon);
}

test "an absent 'default:' key is distinct from 'default: null'" {
    const s = comptime parse(demo_schema, "demo");
    try std.testing.expect(comptime s.find("tokens").?.has_default);
    try std.testing.expect(comptime s.find("max_entries").?.has_default);
    try std.testing.expect(comptime s.find("max_entries").?.default.isNull());
    // `nested:` declares only a type, so it has no schema-level default.
    try std.testing.expect(comptime !s.find("nested").?.has_default);
}

test "type grammar covers signed, unsigned, float, bool and optional forms" {
    const s = comptime parse(
        \\kind: BehaviorSchema
        \\spec:
        \\  fields:
        \\    a:
        \\      type: i64
        \\    b:
        \\      type: f32
        \\    c:
        \\      type: bool
        \\    d:
        \\      type: ?string
    , "demo");

    try std.testing.expect(s.fields[0].type_spec.signed);
    try std.testing.expectEqual(@as(u16, 64), s.fields[0].type_spec.bits);
    try std.testing.expectEqual(Kind.float, s.fields[1].type_spec.kind);
    try std.testing.expectEqual(@as(u16, 32), s.fields[1].type_spec.bits);
    try std.testing.expectEqual(Kind.bool, s.fields[2].type_spec.kind);
    try std.testing.expect(s.fields[3].type_spec.optional);
    try std.testing.expectEqual(Kind.string, s.fields[3].type_spec.kind);
}
