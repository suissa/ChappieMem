# Implementation notes: Zig 0.16 CI for `zig-sqlite`

This document explains what was implemented to bring the vendored
[`zig-sqlite`](../zig-sqlite) library up to Zig 0.16 and get it validated by
GitHub Actions, plus the follow-up hardening pass. It covers two merged pull
requests:

- **PR #1** — [Add root-level GitHub Actions workflow to validate zig-sqlite on Zig 0.16](https://github.com/suissa/ChappieMem/pull/1)
- **PR #2** — [Harden CI and clean up dead tooling for a state-of-the-art setup](https://github.com/suissa/ChappieMem/pull/2)

## Background

`zig-sqlite/` is a vendored copy of a thin Zig wrapper around SQLite. Its
`build.zig` was already written against Zig 0.16 APIs (`std.Io.Threaded`,
unmanaged `ArrayList`, `b.addLibrary` with `root_module`), but nothing in the
repository actually verified that on every change:

- `zig-sqlite/.github/workflows/main.yml` existed, but GitHub Actions only
  discovers workflows under `.github/workflows/` **at the repository root**.
  A workflow file nested inside a subdirectory is inert — it never runs. So
  despite looking like a working CI setup, this code had never actually been
  built or tested by GitHub Actions.
- `build.zig.zon` declared `.minimum_zig_version = "0.14.0"`, which
  understated the real requirement.

## PR #1 — Getting real CI validation in place

### 1. Root-level workflow (`.github/workflows/zig.yml`)

Created a new workflow at the repository root (the only place GitHub Actions
will pick it up) with two jobs:

- **`lint`** — runs `zig fmt --check .` inside `zig-sqlite/`.
- **`test`** — runs `zig build test -Dci=true -Din_memory=true --summary all`
  across a matrix of `ubuntu-24.04`, `windows-latest`, and `macos-latest`,
  using Zig `0.16.0` via `mlugg/setup-zig@v2`. The ubuntu leg also installs
  `qemu-user-binfmt` and passes `-fqemu -fwine` so the build's cross-target
  test matrix (see `ci_targets` in `zig-sqlite/build.zig`) can execute
  non-native targets.

Triggers: `push`/`pull_request` on `main`, scoped to `zig-sqlite/**` and the
workflow file itself, plus `workflow_dispatch` for manual runs.

The dead `zig-sqlite/.github/workflows/main.yml` was removed since it was
fully superseded by the root-level workflow.

### 2. `build.zig.zon` version bump

`minimum_zig_version` was updated from `0.14.0` to `0.16.0` to match the
0.16-only APIs the build script already depends on.

### 3. Real bug found and fixed: missing package-fetch tmp dir

The first real GitHub Actions run (not a local guess — this was diagnosed
from actual CI logs) failed identically on all three platforms:

```
zig-sqlite/build.zig.zon:8:20: error: failed to create temporary zip file: FileNotFound
            .url = "https://www.sqlite.org/2025/sqlite-amalgamation-3490200.zip",
```

Zig's package fetcher stages downloaded archives (like the SQLite
amalgamation zip) under `$ZIG_GLOBAL_CACHE_DIR/tmp`, which does not exist by
default on a fresh runner. The fix was a step that creates it before the
build runs:

```yaml
- name: Ensure zig package-fetch tmp dir exists
  shell: bash
  run: mkdir -p "$ZIG_GLOBAL_CACHE_DIR/tmp"
```

After this fix, all jobs (`lint`, and `test` on all three OSes) passed.

## PR #2 — Hardening and cleanup

Once the base setup was proven green, a follow-up pass made the CI
configuration more robust and removed dead weight:

### CI hardening (both `zig.yml` and `ci.yml`)

- **Least-privilege permissions**: added `permissions: contents: read` at
  the workflow level (neither workflow needs to write to the repo or open
  PRs/issues).
- **Concurrency groups**: added/scoped a `concurrency` group keyed on
  `github.workflow` + `github.ref` so superseded runs on the same branch are
  cancelled instead of piling up.
- **Job timeouts**: added `timeout-minutes` to every job (10–20 minutes
  depending on the job) so a hung step can't silently burn CI minutes.

### Removed a broken cache step

The original `zig.yml` had an `actions/cache` step targeting
`zig-sqlite/zig-cache` and `~/.cache/zig`. Neither path is where `zig build`
actually writes: `mlugg/setup-zig` points `ZIG_GLOBAL_CACHE_DIR` /
`ZIG_LOCAL_CACHE_DIR` at a cache directory under the repo root and already
caches it, keyed on the Zig version. The custom step was always a cache
miss (confirmed via CI logs — "Cache directory is 0 bytes") and was
removed as dead weight.

### `.github/dependabot.yml`

Added a Dependabot configuration to keep dependencies patched automatically:

- `github-actions` ecosystem, weekly, all updates grouped into a single PR.
- `pip` ecosystem (covers the Poetry-managed `pyproject.toml`/`poetry.lock`),
  weekly, all updates grouped into a single PR.

### Removed legacy `zigmod` files

`zig-sqlite/zig.mod` and `zig-sqlite/zigmod.lock` were leftovers from the
old `zigmod` package manager, fully superseded by `build.zig.zon` and Zig's
built-in package manager. They were unreferenced anywhere in the build
(confirmed by grep) and were removed. (They also had a stale SQLite version
pinned, `3480000` vs. the `3490200` amalgamation `build.zig.zon` actually
uses — further evidence they were unmaintained.)

### Pinned the dev toolchain version

`zig-sqlite/mise.toml` had `zig = "latest"`, which drifts over time and can
diverge from what CI actually tests against. Pinned to `zig = "0.16.0"` to
match `build.zig.zon` and the CI workflow.

### README badge

Added a `Zig` CI badge to the top of `README.md`, pointing at
`suissa/ChappieMem`'s own `zig.yml` workflow (the pre-existing `CI`/`codecov`
badges point at a different fork's repository and were left untouched, since
fixing that was out of scope for this change).

## Final state

| File | Change |
|---|---|
| `.github/workflows/zig.yml` | New. Lints and tests `zig-sqlite` on Zig 0.16 across Linux/macOS/Windows. |
| `.github/workflows/ci.yml` | Hardened with `permissions`, `concurrency`, `timeout-minutes` (Python lint/test job, pre-existing, unrelated logic unchanged). |
| `.github/dependabot.yml` | New. Weekly, grouped updates for GitHub Actions and pip. |
| `zig-sqlite/build.zig.zon` | `minimum_zig_version` bumped to `0.16.0`. |
| `zig-sqlite/mise.toml` | `zig` pinned to `0.16.0` (was `"latest"`). |
| `zig-sqlite/.github/workflows/main.yml` | Removed (dead — GitHub Actions never read it from this path). |
| `zig-sqlite/zig.mod`, `zig-sqlite/zigmod.lock` | Removed (unused legacy `zigmod` metadata). |
| `README.md` | Added a `Zig` CI badge. |

Every change above was validated by real GitHub Actions runs (not just
static review) before merging — including the tmp-dir bug, which only
surfaced once the workflow actually executed on GitHub's runners.

## How to verify locally

```sh
cd zig-sqlite
zig fmt --check .
mkdir -p "$(zig env | grep -o '"global_cache_dir":"[^"]*"' | cut -d'"' -f4)/tmp"  # only needed on a fresh cache
zig build test -Dci=true -Din_memory=true --summary all
```

Requires Zig `0.16.0` (see `zig-sqlite/mise.toml` — `mise install` will pick
it up automatically if you use [mise](https://mise.jdx.dev/)).
