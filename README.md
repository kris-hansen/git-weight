# git-weight

**Find out what's weighing down your Git repository.**

`git-weight` is a fast, standalone CLI for Git repository storage forensics. It parses Git storage formats directly — packfiles, pack indexes, loose objects, refs — with no dependency on the Git executable, Python, or any other runtime. It is a read-only tool: it never modifies packs, refs, or the working tree.

Unlike `git-sizer` (which identifies structural characteristics that make a repository awkward to work with), `git-weight` explains where repository storage is going and why that storage is still retained.

## Install

Build from source with [Zig](https://ziglang.org) 0.16+:

```sh
zig build -Doptimize=ReleaseFast
```

The binary is named `git-weight`, so Git can invoke it as a subcommand when it is on your `$PATH`:

```sh
git weight          # same as git-weight
```

## Usage

```text
git weight [COMMAND] [PATH] [OPTIONS]

Commands:
  summary      High-level repository report (default)
  largest      Largest blobs in repository history
  objects      Per-type object counts and logical sizes
  packs        Packfile statistics
  explain      Explain why a path or object contributes to repository weight
  refs         Refs retaining historical weight
  unreachable  Unreachable objects reclaimable via git gc
  changed      Whether a path changed between two revisions (CI)

Options:
  --json             Machine-readable JSON output
  --limit N          Maximum entries to list (default 20; applies to largest/refs)
  --min-size SIZE    Only include blobs at least SIZE (e.g. 10MB, 500KiB)
  --threads N        Worker thread count (accepted; currently single-threaded)
  --base REF         Base revision for 'changed' (default HEAD~1)
  --to REF           Target revision for 'changed' (default HEAD)
  --exit-code        For 'changed': exit 1 when changed, 0 when unchanged
  --current          Only blobs present in the tree at HEAD
  --historical       Only blobs not present in the tree at HEAD
  --no-color         Disable colored output
  --verbose          Additional diagnostics on stderr
  --quiet            Suppress non-essential output
  --repo PATH        Repository path (equivalent to positional PATH)
  --version          Print version and exit
  --help             Print help and exit
```

Example:

```text
$ git weight

Repository: my-project

Repository weight
  Total .git size             6.23 MB
  Object database             6.20 MB
  Working tree                1.43 MB

Objects
  Blobs                       6.20 MB
  Trees                       490 B
  Commits                     489 B
  Tags                        112 B

Storage
  Packfiles                   6.20 MB
  Loose objects               0 B

Largest contributors

  SIZE       PATH                         STATUS
  2.86 MB    database/prod.sql            historical
  1.91 MB    models/model.bin             historical
  977 KB     assets/demo.mov              current
  488 KB     models/model.bin             current

Potential cleanup
  Historical deleted files    4.77 MB
  Unreachable objects         0 B

Largest contributor:
  database/prod.sql

Run:

  git weight explain database/prod.sql
```

### Change detection for CI

`git weight changed` compares the tree (or blob) hash of a path between two revisions — a native, `git`-free `git diff --quiet` for automation:

```sh
# Rebuild services/api only if it changed since the base branch.
if git weight changed services/api --base origin/main --exit-code; then
    echo "no changes under services/api"
else
    echo "services/api changed — running build"
fi
```

`--base` defaults to `HEAD~1` and `--to` to `HEAD`; both accept ref names, full hex oids, and ancestry suffixes (`~N`, `^N`, e.g. `HEAD~2^1`). Annotated tags are peeled to their commits. With `--json`, each side is reported as `{"ref": ..., "commit": ..., "tree": ...}`, where `tree` holds the subtree or blob oid at the path (null when the path is absent on that side).

### Terminology

| Term        | Meaning                                                        |
|-------------|----------------------------------------------------------------|
| Logical size | Full reconstructed Git object size                            |
| Physical size | Actual storage consumed in a packfile or loose object file    |
| Current     | Object reachable from the tree at `HEAD`                       |
| Historical  | Object in reachable history, but not in the current `HEAD` tree|
| Unreachable | Object not reachable from any ref                             |

## Exit codes

| Code | Meaning               |
|------|-----------------------|
| 0    | success               |
| 1    | general error         |
| 2    | invalid arguments     |
| 3    | repository not found  |
| 4    | unsupported Git format|
| 5    | corrupt repository    |

## Performance

git-weight aims to be the fastest way to interrogate a Git repository. It reads packfiles, indexes, loose objects, and refs directly — no `git` subprocess, no runtime — memory-mapped I/O, memoized delta-chain resolution, a delta-base payload cache, and lazy indexing so cheap commands (`changed`) never pay for a full object scan.

Benchmarks with [hyperfine](https://github.com/sharkdp/hyperfine) (mean of 10+ runs; 2 runs for the huge repo), Apple Silicon, `zig build -Doptimize=ReleaseFast`. Reproduce with `test/bench.sh REPO LABEL PATH`.

**comanda** — 22MB `.git`, 6.6k objects, 544 refs:

| benchmark | alternative | git-weight | result |
|---|---|---|---|
| `summary` | git-sizer (229ms) | 154ms | **1.5× faster** |
| `changed` | `git diff --quiet` (11ms) | 8ms | **1.4× faster** |
| `packs` | `git verify-pack` (143ms) | 17ms | **8.2× faster** |
| `unreachable` | `git fsck --unreachable` (229ms) | 129ms | **1.8× faster** |

**homebrew-core** — 949MB `.git`, 2.5M objects, 595k commits:

| benchmark | alternative | git-weight | result |
|---|---|---|---|
| `summary` | git-sizer (165s) | 121s | **1.4× faster** |
| `changed` | `git diff --quiet` (16ms) | 9ms | **1.7× faster** |
| `packs` | `git verify-pack` (71s) | 388ms | **184× faster** |

Known gaps: `largest` trails the `git rev-list --objects --all | git cat-file --batch-check` pipeline (~2–3× on large repos) and `explain` trails `git log --all -- <path>` — though both plumbing commands compute strictly less (no physical sizes, retention, or reachability). Closing those is the roadmap:

- **v1.0 worker-pool parallelism** — git-sizer already parallelizes; git-weight is currently single-threaded (`--threads` is accepted but ignored).
- **Zero-copy payload reads** — borrowed cache entries instead of copy-on-hit.
- **System zlib option** — the pure-Zig inflater trades a little speed for zero dependencies.

Performance is a feature: every command reports per-phase timings and peak RSS with `--verbose`, and regressions are meant to be caught with `test/bench.sh`.

## Development

```sh
zig build          # debug build
zig build test     # unit tests
test/verify.sh     # integration checks against Git plumbing (uses git as a test oracle)
test/bench.sh REPO LABEL PATH [heavy|huge]  # benchmark against git plumbing and git-sizer (needs hyperfine, git-sizer)
```

## Status and roadmap

**v0.3** (current): repository discovery (normal, bare, linked worktrees), loose-object scanning, pack index v2 parsing, pack entry metadata, native zlib streaming, OFS/REF delta resolution for exact logical sizes, physical (on-disk) sizes per object, reachability analysis, `explain` (per-object history: introduced/deleted commits, retaining refs, reclaimable estimate), `refs` (unique weight per ref) and `unreachable` commands, `changed` (tree/blob change detection between revisions, for CI), human-readable and JSON output, macOS/Linux.

Known limitations:

- Single-threaded (`--threads` is accepted but ignored)
- SHA-256 repositories are not yet supported
- Windows is not yet supported

Planned:

- **v1.0**: worker-pool parallelism, SHA-256 support, full "why is this still here?" story per spec

See `spec.md` (in the project repository) for the full product definition.

## License

MIT
