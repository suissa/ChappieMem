# Atomic behaviours

Each folder here is one **atomic behaviour** — a single decision the system
makes, described by data rather than code. `src/factory.zig` reads those
descriptors while the compiler runs and emits a Zig module for each one, which
`src/forger.zig` re-exports as `forger.EmbeddingConfig`, `forger.MemoryConfig`
and the rest — types that exist nowhere in the source tree.

`src/config.zig` still declares the same eleven structs by hand. It is kept
deliberately, as an independent second opinion: the parity tests at the bottom
of `forger.zig` walk both sides with reflection and fail the build if a
descriptor drifts from the hand-written reference.

## The three files

```
chunking/
  manifest.yml   identity   — name, version, stability, composition, parity
  schema.yml     rules      — fields, types, constraints, invariants
  config.yml     values     — what this profile actually wants
  ops.zig        (optional) hand-written pure derivations
```

They are split three ways because they change for different reasons and by
different people:

| file | answers | changes when |
| --- | --- | --- |
| `manifest.yml` | *what is this?* | a behaviour is promoted, renamed or recomposed |
| `schema.yml` | *what is legal?* | the algorithm's contract changes |
| `config.yml` | *what do we want?* | a deployment is tuned |

That is what makes a behaviour swappable: point the factory at a different
`config.yml` and you get a different module out, with the same rules still
enforced. The factory generates **data and rules only** — never algorithms.
Computation stays hand-written in `ops.zig` (or in a top-level module such as
`src/chunking.zig`) and is reached through `Behavior.ops`.

## manifest.yml

```yaml
apiVersion: memweave.behavior/v1
kind: AtomicBehavior
metadata:
  name: chunking          # must equal the folder name
  version: 0.1.0
  summary: "How markdown files are split into searchable pieces."
  tags: [indexing, text]
spec:
  stability: stable       # experimental | beta | stable | deprecated
  pure: true              # free of I/O and global state
  composes: []            # behaviours embedded in this one
  parity:
    python: memweave.config.ChunkingConfig
  consumers: [src/chunking.zig]
```

`composes` is not decoration: it is checked against the `behavior<...>` fields
in `schema.yml`, and a disagreement fails the build.

## schema.yml

```yaml
apiVersion: memweave.behavior/v1
kind: BehaviorSchema
spec:
  fields:
    tokens:
      type: u32
      doc: "Target chunk size in tokens."
      constraints:
        gte: 1
    overlap:
      type: u32
  invariants:
    overlap_fits_in_chunk:
      rule: lt
      left: overlap
      right: tokens
      doc: "An overlap as large as the chunk would make every chunk identical."
```

**Types** (a leading `?` makes any of them optional):
`bool` · `u8`…`u64` · `i8`…`i64` · `f32` · `f64` · `string` · `list<string>` ·
`behavior<name>`.

**Constraints** (per field): `gt` · `gte` · `lt` · `lte` · `not_empty` ·
`min_len` · `max_len` · `one_of`. On an optional field they apply only to a
present value, so `?u32` with `gte: 1` reads as "unlimited when null".

**Invariants** (across fields): `lt` · `lte` · `sum_eq`. They run after every
per-field constraint.

A field may carry a `default:` here, but in the shipped behaviours the values
all live in `config.yml`. A field with neither has no struct default, so
callers are forced to supply it.

## config.yml

```yaml
apiVersion: memweave.behavior/v1
kind: BehaviorConfig
metadata:
  behavior: chunking      # must equal the folder name
  profile: default
  doc: "Sized for text-embedding-3-small, whose window is 8191 tokens."
spec:
  values:
    tokens: 400
    overlap: 80
```

Values layer over schema defaults, and a composite's `config.yml` can reach
into a composed behaviour:

```yaml
spec:
  values:
    mmr:
      enabled: true
```

A key that is not declared in `schema.yml` is a compile error, so a typo in a
profile can never be silently ignored.

## Composition

`behavior<name>` is the composition primitive. `query/schema.yml` declares

```yaml
    hybrid:
      type: behavior<hybrid>
```

and the generated `QueryConfig.hybrid` *is* `HybridConfig` — one type, whether
reached directly or through composition. Validation cascades automatically, so
`Memory.validate(cfg)` reaches `query → hybrid` without anyone writing the
cascade.

`memory` is the root composite: `embedding`, `chunking`, `query`, `cache`,
`sync`, `flush`, `vector`.

## Using a behaviour

```zig
const forger = @import("forger.zig");

const cfg = forger.ChunkingConfig{ .tokens = 512 };   // profile defaults + override
try forger.Chunking.validate(cfg);                    // generated from schema.yml
const budget = forger.Chunking.ops.maxChars(cfg);     // hand-written derivation
```

The behaviour module is the namespace and the `Config` struct is plain data,
so what used to be a method is now a call on the module:

| hand-written (`config.zig`) | forged (`forger.zig`) |
| --- | --- |
| `cfg.validate()` | `Chunking.validate(cfg)` |
| `cfg.maxChars()` | `Chunking.ops.maxChars(cfg)` |

Each module also exposes `manifest`, `spec` (the parsed schema, usable at
runtime), `defaults`, `composes`, `withOverrides()` and `describe()`.

## Adding a behaviour

1. Create the folder with the three `.yml` files (and `ops.zig` if it has
   derivations).
2. Add one line to the catalogue in `src/behaviors.zig`.
3. Re-export it from `src/forger.zig` if the library's public surface needs it.

Everything else — the struct, the defaults, the validator, the cascade — is
generated. `zig build test` walks the whole catalogue and checks that every
behaviour builds, validates its own defaults, and agrees with its manifest.
