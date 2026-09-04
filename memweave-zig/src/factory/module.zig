//! The behaviour factory: three YAML documents in, one Zig module out.
//!
//! `Module(name, sources, Resolve)` reads a behaviour folder's
//! `manifest.yml` + `config.yml` + `schema.yml` at **comptime** and returns a
//! namespace containing, among other things, a `Config` struct type that
//! exists nowhere in the source tree — its fields, their types and their
//! default values are all derived from the descriptors.
//!
//! Division of labour between the three documents:
//!
//!   * `schema.yml`   — the *shape and rules*: fields, types, per-field
//!                      constraints, cross-field invariants. Generates the
//!                      struct layout and the body of `validate()`.
//!   * `config.yml`   — *this deployment's values*. Overrides schema
//!                      defaults, and is the reason two projects embedding
//!                      the same behaviour get two different modules.
//!   * `manifest.yml` — *identity*: name, version, stability, composition,
//!                      Python parity. Cross-checked against the schema.
//!
//! Everything is resolved while the compiler runs, so the result costs
//! exactly what the hand-written struct cost: no parser, no descriptor
//! strings and no reflection survive into the binary unless something
//! actually reads them (`spec`, `manifest` and `describe()` are there for
//! tooling that wants to).
//!
//! Composition is a first-class field type. A `behavior<cache>` field takes
//! the type of the `cache` behaviour's own generated `Config`, resolved
//! through the `Resolve` callback the registry supplies — which is how a
//! composite such as `memory` is assembled from leaves without restating a
//! single field.

const std = @import("std");
const yaml = @import("yaml.zig");
const schema_mod = @import("schema.zig");
const manifest_mod = @import("manifest.zig");
const errors = @import("../errors.zig");

pub const Schema = schema_mod.Schema;
pub const Manifest = manifest_mod.Manifest;

/// The raw contents of one behaviour folder. `manifest`/`config`/`schema`
/// are normally produced by `@embedFile`, so the descriptors are real files
/// on disk that a human (or another tool) can read and diff.
pub const Sources = struct {
    manifest: []const u8,
    config: []const u8,
    schema: []const u8,
    /// Optional companion namespace holding the behaviour's hand-written
    /// pure operations (`ops.zig`). Derived values that are computation
    /// rather than configuration live here — the factory generates data and
    /// rules, never algorithms.
    ops: type = struct {},
};

/// Build the dynamic module for one behaviour.
///
/// `Resolve` is a `fn (comptime []const u8) type` that maps a behaviour name
/// to its module — normally `registry.Behavior`, passed in rather than
/// imported so the factory stays independent of any particular catalogue.
pub fn Module(
    comptime behavior_name: []const u8,
    comptime sources: Sources,
    comptime Resolve: anytype,
) type {
    @setEvalBranchQuota(4_000_000);

    const man = comptime manifest_mod.parse(sources.manifest, behavior_name);
    const sch = comptime schema_mod.parse(sources.schema, behavior_name);
    const overrides = comptime parseConfigDoc(sources.config, behavior_name, sch);
    comptime checkComposition(man, sch, behavior_name);

    return struct {
        /// Folder name, and the key this behaviour is registered under.
        pub const name = behavior_name;
        pub const manifest = man;
        /// The parsed `schema.yml`. Plain data, usable at runtime by tooling
        /// that wants to explain or serialize the configuration.
        pub const spec = sch;
        /// The values `config.yml` layered on top of the schema defaults,
        /// kept for provenance ("where did this default come from?").
        pub const profile = overrides;

        /// The generated configuration struct. Field order matches
        /// `schema.yml`; every default is the schema default with the
        /// `config.yml` override already folded in.
        pub const Config = StructType(behavior_name, sch, overrides, Resolve);

        /// `Config{}` — the fully defaulted configuration for this profile.
        /// Referencing this is a compile error if any field lacks a default.
        pub const defaults: Config = .{};

        /// The behaviour's hand-written pure operations, if it has any.
        pub const ops = sources.ops;

        /// Layer a YAML mapping of overrides on top of an existing `Config`.
        /// Comptime only — this is how a composite behaviour pushes values
        /// down into a composed one.
        pub fn withOverridesOn(comptime base: Config, comptime node: yaml.Value) Config {
            comptime var cfg = base;
            inline for (sch.fields) |f| {
                if (comptime node.get(f.name)) |child| {
                    @field(cfg, f.name) = comptime coerce(
                        @FieldType(Config, f.name),
                        f,
                        child,
                        behavior_name,
                        Resolve,
                    );
                }
            }
            return cfg;
        }

        /// `withOverridesOn(defaults, node)`.
        pub fn withOverrides(comptime node: yaml.Value) Config {
            return withOverridesOn(defaults, node);
        }

        /// Check every per-field constraint, cascade into composed
        /// behaviours, then check the cross-field invariants.
        ///
        /// Mirrors the Python `__post_init__` contract: nested configs are
        /// validated before the enclosing one's own rules, and every failure
        /// surfaces as `error.ConfigError`.
        pub fn validate(cfg: Config) errors.ConfigError!void {
            inline for (sch.fields) |f| {
                if (comptime f.type_spec.kind == .behavior) {
                    try Resolve(f.type_spec.behavior).validate(@field(cfg, f.name));
                } else {
                    try checkConstraints(f, @field(cfg, f.name));
                }
            }
            inline for (sch.invariants) |inv| {
                try checkInvariant(inv, cfg);
            }
        }

        /// Names of the composed behaviours, in field order.
        pub const composes: []const []const u8 = blk: {
            var out: []const []const u8 = &.{};
            for (sch.fields) |f| {
                if (f.type_spec.kind == .behavior) out = out ++ [_][]const u8{f.type_spec.behavior};
            }
            break :blk out;
        };

        /// Human-readable dump of the behaviour: identity, then one line per
        /// field with its type, current default and constraints. Used by
        /// tooling ("explain this config") and by the tests as a compact
        /// assertion that the descriptors really drove the generated type.
        pub fn describe(writer: anytype) !void {
            try writer.print("behavior {s} v{s} ({s})\n", .{ man.name, man.version, @tagName(man.stability) });
            if (man.summary.len > 0) try writer.print("  {s}\n", .{man.summary});
            inline for (sch.fields) |f| {
                try writer.print("  - {s}: {s}", .{ f.name, comptime describeType(f) });
                if (comptime f.type_spec.kind != .behavior) {
                    try writer.print(" = ", .{});
                    try printValue(writer, @field(defaults, f.name));
                }
                inline for (f.constraints) |c| {
                    try writer.print(" [{s}]", .{comptime describeConstraint(c)});
                }
                try writer.print("\n", .{});
            }
            inline for (sch.invariants) |inv| {
                try writer.print("  ! {s}\n", .{inv.name});
            }
        }

        comptime {
            // Touching `Config` here makes descriptor errors surface as soon
            // as the module is referenced, not lazily on first field access.
            _ = Config;
        }
    };
}

// ---------------------------------------------------------------------------
// config.yml
// ---------------------------------------------------------------------------

/// Parse `config.yml` and return its `spec.values` mapping, after checking
/// that the behaviour name matches and that every key exists in the schema.
/// A typo in a config file is a compile error, not a silently ignored key.
fn parseConfigDoc(
    comptime src: []const u8,
    comptime behavior_name: []const u8,
    comptime sch: Schema,
) yaml.Value {
    const doc = comptime yaml.parse(src);
    const what = "config.yml for '" ++ behavior_name ++ "'";

    const kind = comptime doc.stringOr("kind", "");
    if (!std.mem.eql(u8, kind, "BehaviorConfig")) {
        @compileError(what ++ ": expected 'kind: BehaviorConfig', found '" ++ kind ++ "'");
    }

    const metadata = comptime doc.require("metadata", what);
    const target = comptime metadata.require("behavior", what).asScalar().text;
    if (!std.mem.eql(u8, target, behavior_name)) {
        @compileError(what ++ ": 'metadata.behavior' is '" ++ target ++ "' but the behaviour directory is '" ++ behavior_name ++ "'");
    }

    const spec = comptime doc.get("spec") orelse return .{ .mapping = &.{} };
    const values = comptime spec.get("values") orelse return .{ .mapping = &.{} };
    if (values.isNull()) return .{ .mapping = &.{} };

    for (values.asMapping()) |pair| {
        if (sch.find(pair.key) == null) {
            @compileError(what ++ ": key '" ++ pair.key ++ "' is not declared in schema.yml");
        }
    }
    return values;
}

/// The manifest's `composes:` list and the schema's `behavior<...>` fields
/// must describe the same set, in the same order.
fn checkComposition(comptime man: Manifest, comptime sch: Schema, comptime behavior_name: []const u8) void {
    const what = "behavior '" ++ behavior_name ++ "'";
    comptime var found: []const []const u8 = &.{};
    for (sch.fields) |f| {
        if (f.type_spec.kind != .behavior) continue;
        if (std.mem.eql(u8, f.type_spec.behavior, behavior_name)) {
            @compileError(what ++ ": field '" ++ f.name ++ "' composes the behaviour with itself");
        }
        if (!man.composesBehavior(f.type_spec.behavior)) {
            @compileError(what ++ ": schema.yml composes '" ++ f.type_spec.behavior ++
                "' but manifest.yml's 'spec.composes' does not list it");
        }
        found = found ++ [_][]const u8{f.type_spec.behavior};
    }
    for (man.composes) |c| {
        comptime var seen = false;
        for (found) |g| {
            if (std.mem.eql(u8, c, g)) seen = true;
        }
        if (!seen) {
            @compileError(what ++ ": manifest.yml lists '" ++ c ++ "' in 'spec.composes' but no schema.yml field has type 'behavior<" ++ c ++ ">'");
        }
    }
}

// ---------------------------------------------------------------------------
// Type generation
// ---------------------------------------------------------------------------

fn StructType(
    comptime behavior_name: []const u8,
    comptime sch: Schema,
    comptime overrides: yaml.Value,
    comptime Resolve: anytype,
) type {
    comptime var names: [sch.fields.len][]const u8 = undefined;
    comptime var types: [sch.fields.len]type = undefined;
    comptime var attrs: [sch.fields.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (sch.fields, 0..) |f, i| {
        const T = FieldType(f, Resolve);
        names[i] = f.name;
        types[i] = T;
        attrs[i] = .{ .default_value_ptr = comptime defaultPtr(T, f, overrides, behavior_name, Resolve) };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

fn FieldType(comptime f: schema_mod.Field, comptime Resolve: anytype) type {
    const base = switch (f.type_spec.kind) {
        .bool => bool,
        .int => @Int(if (f.type_spec.signed) .signed else .unsigned, f.type_spec.bits),
        .float => if (f.type_spec.bits == 32) f32 else f64,
        .string => []const u8,
        .string_list => []const []const u8,
        .behavior => Resolve(f.type_spec.behavior).Config,
    };
    return if (f.type_spec.optional) ?base else base;
}

/// The merged default for one field: the schema's `default:`, with
/// `config.yml`'s value layered on top. Composed behaviours always get a
/// default (their own profile), so only leaf fields can be "required".
fn defaultPtr(
    comptime T: type,
    comptime f: schema_mod.Field,
    comptime overrides: yaml.Value,
    comptime behavior_name: []const u8,
    comptime Resolve: anytype,
) ?*const anyopaque {
    if (f.type_spec.kind == .behavior) {
        const M = Resolve(f.type_spec.behavior);
        // Three layers, innermost first: the composed behaviour's own
        // profile, then anything this schema pins, then anything this
        // profile pins.
        const from_schema = if (f.has_default) M.withOverrides(f.default) else M.defaults;
        const merged = if (overrides.get(f.name)) |node|
            M.withOverridesOn(from_schema, node)
        else
            from_schema;
        return @ptrCast(&@as(T, merged));
    }

    const node = if (overrides.get(f.name)) |n|
        n
    else if (f.has_default)
        f.default
    else
        return null; // no default anywhere: the field is required

    return @ptrCast(&@as(T, coerce(T, f, node, behavior_name, Resolve)));
}

/// YAML node → a value of the generated field's exact Zig type.
fn coerce(
    comptime T: type,
    comptime f: schema_mod.Field,
    comptime node: yaml.Value,
    comptime behavior_name: []const u8,
    comptime Resolve: anytype,
) T {
    const what = "behavior '" ++ behavior_name ++ "', field '" ++ f.name ++ "'";

    if (@typeInfo(T) == .optional) {
        if (node.isNull()) return null;
        return coerce(@typeInfo(T).optional.child, f, node, behavior_name, Resolve);
    }

    return switch (f.type_spec.kind) {
        .bool => node.asScalar().asBool() orelse
            @compileError(what ++ ": expected true or false"),
        .int => blk: {
            const n = node.asScalar().asInt() orelse
                @compileError(what ++ ": expected an integer");
            if (n < 0 and !f.type_spec.signed) {
                @compileError(what ++ ": negative value in an unsigned field");
            }
            break :blk @intCast(n);
        },
        .float => @floatCast(node.asScalar().asFloat() orelse
            @compileError(what ++ ": expected a number")),
        .string => blk: {
            const s = node.asScalar();
            if (s.isNull()) @compileError(what ++ ": expected a string, found null");
            break :blk s.text;
        },
        .string_list => blk: {
            comptime var out: []const []const u8 = &.{};
            for (node.asSequence()) |item| {
                const s = item.asScalar();
                if (s.isNull()) @compileError(what ++ ": list contains a null entry");
                out = out ++ [_][]const u8{s.text};
            }
            break :blk out;
        },
        .behavior => Resolve(f.type_spec.behavior).withOverrides(node),
    };
}

// ---------------------------------------------------------------------------
// Generated validation
// ---------------------------------------------------------------------------

fn checkConstraints(comptime f: schema_mod.Field, value: anytype) errors.ConfigError!void {
    if (comptime f.constraints.len == 0) return;

    const V = @TypeOf(value);
    if (comptime @typeInfo(V) == .optional) {
        // A null optional carries no value to constrain — "unlimited when
        // null" semantics, matching the Python `int | None` fields.
        if (value) |inner| return checkConstraints(f, inner);
        return;
    }

    inline for (f.constraints) |c| {
        switch (c) {
            .gt => |bound| if (!(asF64(value) > bound)) return error.ConfigError,
            .gte => |bound| if (!(asF64(value) >= bound)) return error.ConfigError,
            .lt => |bound| if (!(asF64(value) < bound)) return error.ConfigError,
            .lte => |bound| if (!(asF64(value) <= bound)) return error.ConfigError,
            .not_empty => if (lengthOf(f, value) == 0) return error.ConfigError,
            .min_len => |n| if (lengthOf(f, value) < n) return error.ConfigError,
            .max_len => |n| if (lengthOf(f, value) > n) return error.ConfigError,
            .one_of => |allowed| {
                comptime std.debug.assert(f.type_spec.kind == .string);
                var ok = false;
                inline for (allowed) |a| {
                    if (std.mem.eql(u8, value, a)) ok = true;
                }
                if (!ok) return error.ConfigError;
            },
        }
    }
}

fn checkInvariant(comptime inv: schema_mod.Invariant, cfg: anytype) errors.ConfigError!void {
    switch (inv.rule) {
        .sum_eq => |r| {
            var sum: f64 = 0;
            inline for (r.fields) |fname| sum += asF64(@field(cfg, fname));
            if (@abs(sum - r.value) > r.epsilon) return error.ConfigError;
        },
        .lt => |r| if (!(asF64(@field(cfg, r.left)) < asF64(@field(cfg, r.right)))) return error.ConfigError,
        .lte => |r| if (!(asF64(@field(cfg, r.left)) <= asF64(@field(cfg, r.right)))) return error.ConfigError,
    }
}

fn asF64(value: anytype) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError("numeric constraint applied to a non-numeric field"),
    };
}

fn lengthOf(comptime f: schema_mod.Field, value: anytype) usize {
    return switch (f.type_spec.kind) {
        .string, .string_list => value.len,
        else => @compileError("length constraint applied to '" ++ f.name ++ "', which is neither a string nor a list"),
    };
}

// ---------------------------------------------------------------------------
// describe() helpers
// ---------------------------------------------------------------------------

fn describeType(comptime f: schema_mod.Field) []const u8 {
    @setEvalBranchQuota(10_000);
    const base = switch (f.type_spec.kind) {
        .bool => "bool",
        .int => (if (f.type_spec.signed) "i" else "u") ++ comptime digits(f.type_spec.bits),
        .float => "f" ++ comptime digits(f.type_spec.bits),
        .string => "string",
        .string_list => "list<string>",
        .behavior => "behavior<" ++ f.type_spec.behavior ++ ">",
    };
    return if (f.type_spec.optional) "?" ++ base else base;
}

fn digits(comptime n: u16) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

fn describeConstraint(comptime c: schema_mod.Constraint) []const u8 {
    return switch (c) {
        .gt => |v| "gt " ++ std.fmt.comptimePrint("{d}", .{v}),
        .gte => |v| "gte " ++ std.fmt.comptimePrint("{d}", .{v}),
        .lt => |v| "lt " ++ std.fmt.comptimePrint("{d}", .{v}),
        .lte => |v| "lte " ++ std.fmt.comptimePrint("{d}", .{v}),
        .not_empty => "not_empty",
        .min_len => |v| "min_len " ++ std.fmt.comptimePrint("{d}", .{v}),
        .max_len => |v| "max_len " ++ std.fmt.comptimePrint("{d}", .{v}),
        .one_of => |vs| blk: {
            comptime var out: []const u8 = "one_of";
            for (vs) |v| out = out ++ " " ++ v;
            break :blk out;
        },
    };
}

fn printValue(writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    if (comptime @typeInfo(T) == .optional) {
        if (value) |inner| return printValue(writer, inner);
        return writer.print("null", .{});
    }
    if (comptime T == []const u8) return writer.print("\"{s}\"", .{value});
    if (comptime T == []const []const u8) {
        try writer.print("[", .{});
        for (value, 0..) |item, i| {
            if (i > 0) try writer.print(", ", .{});
            try writer.print("\"{s}\"", .{item});
        }
        return writer.print("]", .{});
    }
    return writer.print("{any}", .{value});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// These exercise the generator against inline fixture descriptors rather than
// the real behaviour folders, so the factory's contract is pinned
// independently of whatever `src/behaviors/` currently ships.

const test_widget_manifest =
    \\apiVersion: memweave.behavior/v1
    \\kind: AtomicBehavior
    \\metadata:
    \\  name: widget
    \\  version: 1.2.3
    \\  summary: "A fixture behaviour exercising the whole schema vocabulary."
    \\  tags: [fixture]
    \\spec:
    \\  stability: beta
    \\  pure: true
    \\  parity:
    \\    python: tests.Widget
;

const test_widget_schema =
    \\kind: BehaviorSchema
    \\spec:
    \\  fields:
    \\    label:
    \\      type: string
    \\      doc: "Display name."
    \\      constraints:
    \\        not_empty: true
    \\    mode:
    \\      type: string
    \\      constraints:
    \\        one_of: [fast, thorough]
    \\    width:
    \\      type: u32
    \\      constraints:
    \\        gte: 1
    \\    height:
    \\      type: u32
    \\    ratio:
    \\      type: f64
    \\      constraints:
    \\        gte: 0
    \\        lte: 1
    \\    offset:
    \\      type: i32
    \\    enabled:
    \\      type: bool
    \\    budget:
    \\      type: ?u32
    \\      default: null
    \\      constraints:
    \\        gte: 1
    \\    aliases:
    \\      type: list<string>
    \\      constraints:
    \\        max_len: 3
    \\  invariants:
    \\    width_fits_height:
    \\      rule: lte
    \\      left: width
    \\      right: height
;

const test_widget_config =
    \\kind: BehaviorConfig
    \\metadata:
    \\  behavior: widget
    \\  profile: default
    \\spec:
    \\  values:
    \\    label: "primary"
    \\    mode: fast
    \\    width: 10
    \\    height: 20
    \\    ratio: 0.5
    \\    offset: -3
    \\    enabled: true
    \\    aliases: [a, b]
;

/// Same schema, a different profile — the point of splitting values out of
/// the schema in the first place.
const test_widget_alt_config =
    \\kind: BehaviorConfig
    \\metadata:
    \\  behavior: widget
    \\  profile: wide
    \\spec:
    \\  values:
    \\    label: "wide"
    \\    mode: thorough
    \\    width: 100
    \\    height: 400
    \\    ratio: 0.9
    \\    offset: 0
    \\    enabled: false
    \\    budget: 64
    \\    aliases: []
;

const test_panel_manifest =
    \\kind: AtomicBehavior
    \\metadata:
    \\  name: panel
    \\  version: 0.1.0
    \\spec:
    \\  composes: [widget]
;

const test_panel_schema =
    \\kind: BehaviorSchema
    \\spec:
    \\  fields:
    \\    title:
    \\      type: string
    \\    widget:
    \\      type: behavior<widget>
    \\    columns:
    \\      type: u8
;

/// Pins one value inside the composed behaviour and leaves the rest of
/// `widget`'s profile alone.
const test_panel_config =
    \\kind: BehaviorConfig
    \\metadata:
    \\  behavior: panel
    \\spec:
    \\  values:
    \\    title: "dashboard"
    \\    columns: 3
    \\    widget:
    \\      width: 12
;

fn TestBehavior(comptime name: []const u8) type {
    return Module(name, testSources(name), TestBehavior);
}

fn testSources(comptime name: []const u8) Sources {
    if (std.mem.eql(u8, name, "widget")) return .{
        .manifest = test_widget_manifest,
        .config = test_widget_config,
        .schema = test_widget_schema,
    };
    if (std.mem.eql(u8, name, "panel")) return .{
        .manifest = test_panel_manifest,
        .config = test_panel_config,
        .schema = test_panel_schema,
    };
    @compileError("unknown fixture behaviour '" ++ name ++ "'");
}

const Widget = TestBehavior("widget");
const Panel = TestBehavior("panel");

test "the generated struct's fields follow schema.yml in name, order and type" {
    const fields = @typeInfo(Widget.Config).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 9), fields.len);

    try std.testing.expectEqualStrings("label", fields[0].name);
    try std.testing.expectEqual([]const u8, fields[0].type);
    try std.testing.expectEqual(u32, fields[2].type);
    try std.testing.expectEqual(f64, fields[4].type);
    try std.testing.expectEqual(i32, fields[5].type);
    try std.testing.expectEqual(bool, fields[6].type);
    try std.testing.expectEqual(?u32, fields[7].type);
    try std.testing.expectEqual([]const []const u8, fields[8].type);
}

test "config.yml values become the generated struct's defaults" {
    const cfg = Widget.Config{};
    try std.testing.expectEqualStrings("primary", cfg.label);
    try std.testing.expectEqual(@as(u32, 10), cfg.width);
    try std.testing.expectEqual(@as(f64, 0.5), cfg.ratio);
    try std.testing.expectEqual(@as(i32, -3), cfg.offset);
    try std.testing.expectEqual(true, cfg.enabled);
    try std.testing.expect(cfg.budget == null);
    try std.testing.expectEqual(@as(usize, 2), cfg.aliases.len);
    try std.testing.expectEqualStrings("b", cfg.aliases[1]);
}

test "a second config.yml over the same schema yields a differently defaulted module" {
    const Wide = Module("widget", .{
        .manifest = test_widget_manifest,
        .config = test_widget_alt_config,
        .schema = test_widget_schema,
    }, TestBehavior);

    const wide = Wide.Config{};
    try std.testing.expectEqualStrings("wide", wide.label);
    try std.testing.expectEqual(@as(u32, 100), wide.width);
    try std.testing.expectEqual(@as(?u32, 64), wide.budget);
    try std.testing.expectEqual(@as(usize, 0), wide.aliases.len);

    // Same shape, same rules — only the values moved.
    try Wide.validate(.{});
    try std.testing.expectEqual(
        @typeInfo(Widget.Config).@"struct".fields.len,
        @typeInfo(Wide.Config).@"struct".fields.len,
    );
}

test "per-field constraints are enforced by the generated validate()" {
    try Widget.validate(.{});
    try std.testing.expectError(error.ConfigError, Widget.validate(.{ .label = "" }));
    try std.testing.expectError(error.ConfigError, Widget.validate(.{ .mode = "sideways" }));
    try std.testing.expectError(error.ConfigError, Widget.validate(.{ .width = 0 }));
    try std.testing.expectError(error.ConfigError, Widget.validate(.{ .ratio = 1.5 }));
    try std.testing.expectError(error.ConfigError, Widget.validate(.{ .aliases = &.{ "a", "b", "c", "d" } }));
}

test "constraints on an optional field only apply when it has a value" {
    try Widget.validate(.{ .budget = null });
    try Widget.validate(.{ .budget = 1 });
    try std.testing.expectError(error.ConfigError, Widget.validate(.{ .budget = 0 }));
}

test "cross-field invariants run after the per-field constraints" {
    try Widget.validate(.{ .width = 20, .height = 20 });
    try std.testing.expectError(error.ConfigError, Widget.validate(.{ .width = 21, .height = 20 }));
}

test "a composed field takes the composed behaviour's type and profile" {
    try std.testing.expectEqual(Widget.Config, @FieldType(Panel.Config, "widget"));

    const cfg = Panel.Config{};
    try std.testing.expectEqualStrings("dashboard", cfg.title);
    try std.testing.expectEqual(@as(u8, 3), cfg.columns);
    // Pinned by panel's own config.yml...
    try std.testing.expectEqual(@as(u32, 12), cfg.widget.width);
    // ...while everything else still comes from widget's profile.
    try std.testing.expectEqualStrings("primary", cfg.widget.label);
    try std.testing.expectEqual(@as(u32, 20), cfg.widget.height);
}

test "validation cascades into composed behaviours" {
    try Panel.validate(.{});
    try std.testing.expectError(error.ConfigError, Panel.validate(.{ .widget = .{ .mode = "sideways" } }));
}

test "withOverrides layers a YAML mapping onto the profile defaults" {
    const cfg = comptime Widget.withOverrides(yaml.parse(
        \\width: 7
        \\label: "override"
    ));
    try std.testing.expectEqual(@as(u32, 7), cfg.width);
    try std.testing.expectEqualStrings("override", cfg.label);
    // Untouched fields keep the profile's values.
    try std.testing.expectEqual(@as(u32, 20), cfg.height);
}

test "manifest, schema and composition survive to runtime for tooling" {
    try std.testing.expectEqualStrings("widget", Widget.name);
    try std.testing.expectEqualStrings("1.2.3", Widget.manifest.version);
    try std.testing.expectEqual(manifest_mod.Stability.beta, Widget.manifest.stability);
    try std.testing.expectEqualStrings("tests.Widget", Widget.manifest.parity_python);

    try std.testing.expectEqual(@as(usize, 9), Widget.spec.fields.len);
    try std.testing.expectEqualStrings("Display name.", Widget.spec.fields[0].doc);
    try std.testing.expectEqual(@as(usize, 0), Widget.composes.len);

    try std.testing.expectEqual(@as(usize, 1), Panel.composes.len);
    try std.testing.expectEqualStrings("widget", Panel.composes[0]);
}

test "describe() renders identity, fields with their live defaults, and invariants" {
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try Widget.describe(&writer);
    const text = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, text, "behavior widget v1.2.3 (beta)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- label: string = \"primary\" [not_empty]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- budget: ?u32 = null [gte 1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- aliases: list<string> = [\"a\", \"b\"] [max_len 3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "! width_fits_height") != null);
}

test "describe() names composed behaviours by their behaviour type" {
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try Panel.describe(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "- widget: behavior<widget>") != null);
}
