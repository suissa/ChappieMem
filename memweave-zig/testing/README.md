# Test suites

Six suites, each answering a different question, each writing
`reports/<name>.json` in one shared schema.

| suite | question | `zig build …` | report |
| --- | --- | --- | --- |
| **unit** | Is each piece correct in isolation? | `test` | `reports/unit.json` |
| **load** | Does it stay correct at sustained volume? | `load` | `reports/load.json` |
| **stress** | Where does it break, and does it break cleanly? | `stress` | `reports/stress.json` |
| **chaos** | What happens when the environment misbehaves? | `chaos` | `reports/chaos.json` |
| **sync** | Is it safe from more than one thread? | `sync` | `reports/sync.json` |
| **bench** | How long does each operation take? | `bench` | `reports/bench.json` |

`zig build verify` runs all six.

## Running them

```sh
zig build verify                        # everything
zig build load                          # one suite
zig build chaos -- --scale=0.1          # a tenth of the volume, all the assertions
zig build sync  -- --threads=16
zig build bench -- --seed=0x1234 --out=/tmp/reports
zig build -Dperf-optimize=ReleaseFast bench
```

Every suite understands `--seed`, `--scale`, `--threads` and `--out`, plus
its own tunables (`--max-p99-ms`, `--max-doc-bytes`, `--fuzz-iterations`, …);
run one with a bad flag to see its full list.

`--scale` multiplies every workload size while leaving the set of assertions
untouched, so a CI smoke run and a full local run test exactly the same
things at different volumes.

`--seed` is recorded in every report. A failure is reproducible verbatim by
re-running with the seed the report names.

## Why the suites are built in ReleaseSafe

`stress` and `chaos` are only meaningful while the safety checks that catch
undefined behaviour are still compiled in, and the cost is small on this
workload. Override with `-Dperf-optimize=ReleaseFast` when you want
benchmark numbers without them. Every report records the mode it was built
in, so a number is never ambiguous.

## The report schema

```json
{
  "schema": "memweave.testreport/v1",
  "kind": "load",
  "suite": "load",
  "status": "pass",
  "started_at_unix_ms": 1757203200000,
  "duration_ms": 7760.0,
  "environment": { "zig_version": "0.16.0", "os": "linux", "arch": "x86_64",
                   "optimize": "ReleaseSafe", "single_threaded": false, "cpu_count": 4 },
  "parameters": { "seed": 11400714819323198485, "units": 3000, "…": "…" },
  "totals": { "cases": 6, "passed": 6, "failed": 0, "skipped": 0 },
  "cases": [
    { "name": "…", "status": "pass", "duration_ms": 12.4, "detail": "",
      "metrics": [ { "name": "ops_per_sec", "value": 8123.4, "unit": "ops/s" } ] }
  ]
}
```

Metrics are a flat `{name, value, unit}` list rather than a free-form object,
so a regression tracker can diff two `bench.json` files without knowing which
benchmarks exist. `parameters` is the one part that varies per suite.

## How they fit together

`workload.zig` defines a **unit of work**: chunk, hash, identify, re-rank,
decay, normalize and validate, over one document. It returns a 64-bit
**digest** of everything it computed.

That digest is what makes the other suites possible. The same document must
always produce the same number, so a mismatch is proof of a defect without
any golden file:

- in **sync**, a digest that differs between threads means shared mutable
  state;
- in **chaos**, a digest that survives an injected allocation failure means
  an error path returned a partial result as if it were complete;
- in **load**, a digest that drifts over three thousand iterations means
  state leaking between them.

`store.zig` does the same for everything that needs a database. Its unit
indexes one document, reads it back, searches it, exercises the embedding
cache and the meta table, then **deletes every row it created and asserts the
store is empty again** — so the digest is independent of how many units ran
before it, and the delete paths get exercised as hard as the insert paths.
Two decisions make a database digest stable: no value ever comes from the
wall clock, and with one document's chunks in the index at a time, FTS5's
BM25 statistics are a function of that document alone.

Vector search is not covered by these suites: it needs the `sqlite-vec`
loadable extension, which `zig build test-vector` covers against a real
extension in CI.

`report.zig` is the shared harness — the JSON document, latency percentiles,
argument parsing — and has its own unit tests, run as part of `zig build test`.

## unit

Not a second copy of the test suite: `unit_runner.zig` is a custom
`test_runner` that runs the real `test` blocks in `src/`, and adds a
machine-readable report in the same schema as the other five. It reproduces
the stock runner's per-test lifecycle (a fresh `std.testing.allocator` and
`std.testing.io` each time, leak-checked afterwards), so a leak is attributed
to the test that caused it.

## load

Three thousand units over a 96-document corpus. Asserts invariance rather
than speed: every unit reproduces its reference digest, outstanding bytes
return exactly to the baseline after each unit (a one-byte per-iteration leak
fails immediately, naming the iteration), and the allocator reports no leaks.
Throughput and latency percentiles are recorded; p99 is held to a
deliberately loose ceiling that catches a catastrophe without flaking on a
shared runner.

## stress

Escalates five dimensions until each hits a documented limit: document size
doubling to 16 MiB, degenerate chunk budgets (a 1-token chunk, an overlap one
below the chunk size, a chunk larger than the document), adversarial
document shapes, MMR candidate count through the quadratic step, and a hard
memory ceiling. At every step the chunk invariants must hold, MMR must return
a permutation of its input, and exhaustion must surface as
`error.OutOfMemory` rather than a crash.

It also indexes and searches documents up to 512 KiB, and throws hostile FTS5
query syntax at the search path — unterminated quotes, unbalanced parentheses,
bare operators, an embedded NUL, a 4 KiB query — which must all be neutralized
rather than propagated.

One case guards the over-long-line boundary. Pre-splitting gives every
segment of one source line the same line range, so the first segment keeps
the legacy chunk id and later occurrences add a stable ordinal to the hash
input. The test requires one distinct id and one stored row per chunk. This
keeps ordinary and first-occurrence ids compatible while preventing SQLite
`INSERT OR REPLACE` from silently discarding later segments.

## chaos

Four independent kinds of chaos:

1. **Fault injection.** Every allocation is failed in turn, one run per
   index — both across the whole unit and per public entry point, so a leak
   is attributed to a function. Three things must hold at every index: the
   error is `OutOfMemory` and nothing else, no run reports success after a
   failure was induced, and every byte allocated before the failure is freed.
2. **Input fuzzing.** Random sizes, shapes and chunk budgets against the
   structural invariants, plus a determinism check.
3. **Allocator substitution.** The same unit through an arena, a
   general-purpose allocator and a fixed buffer must digest identically.
4. **Configuration fuzzing.** Random configurations — a valid baseline with
   one field pushed just past its limit, half the time — compared against an
   oracle transcribed by hand from `src/behaviors/*/schema.yml`. This is the
   generated validator checked against an independent reading of the same
   rules, in both directions.
5. **Storage fault injection.** The whole index-search-delete cycle, run once
   per allocation it makes, each on its own database so a failure injected
   mid-transaction cannot poison the next attempt. SQLite's own C allocations
   are outside what a Zig allocator can inject into; the Zig side must still
   release everything.
6. **Query fuzzing.** FTS5 has a query language, so every byte a user can type
   is input to a parser. Random bytes, operators and quoting must come back as
   results or as an error — never a crash, and never a different answer for
   the same input.

This suite found three real memory-safety bugs on the out-of-memory paths of
`src/mmr.zig` and `src/chunking.zig`; each now has a regression test next to
the code it covers.

## sync

Establishes digests on one thread, then recomputes them from many at once.
Three arrangements, because they fail differently: private arenas per thread
(anything that breaks is state inside the library), one shared thread-safe
allocator (contention and interleaved alloc/free traffic), every thread on
the same document at once (the sharpest test for accidental writes to shared
data), and one in-memory database per thread running the storage unit. Thread
counts double from 1 to twice the CPU count, so the suite also runs
oversubscribed.

Sharing one `sqlite.Db` across threads is deliberately *not* tested: a
connection is per-user by the library's contract, and a test for the misuse
would pin behaviour nobody should rely on.

Scaling numbers are recorded but never asserted: on a shared runner the
thread count bears no relation to the cores actually available, so a speedup
target would measure the runner rather than the library.

## bench

The one suite that measures rather than asserts — the only failure is an
operation that errors out. A benchmark that fails on a threshold is one whose
threshold gets loosened until it means nothing; deciding whether a number got
worse belongs to whoever diffs two `bench.json` files.

Two details decide whether the numbers are worth reading. Cheap operations
are timed in **batches**, because reading the monotonic clock costs more than
some of them take, and every result is consumed via `doNotOptimizeAway` with
an input that varies per call — a constant argument lets the optimizer hoist
the whole batch loop and report an impressive zero. The timed bodies run on
`std.heap.smp_allocator` rather than the `DebugAllocator` used for fixtures:
against the debug allocator, `chunkMarkdown` on 1 KiB measured 92 µs, of
which 86 µs was the allocator.

## In CI

`.github/workflows/zig.yml` runs the suites in a `memweave-zig-suites` job:

```yaml
- run: zig build verify -- --scale=0.1 --seed=0x5EED0C1
```

Every assertion executes, with a tenth of the work, and the reports are
uploaded as build artifacts. The seed is fixed, so a CI failure reproduces
locally verbatim with the same `--seed`.

## Adding a suite

1. Write `testing/<name>.zig` with a `pub fn main(init: std.process.Init)`.
2. Build a `report.Builder`, record cases with `check`/`record`, and end with
   `builder.finish(params, options.out_dir)`.
3. Add one line to `suites` in `build.zig`.

It gets a `zig build <name>` step, joins `zig build verify`, and writes
`reports/<name>.json` in the same schema as the rest.
