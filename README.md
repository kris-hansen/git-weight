# git-weight

**Find out what's weighing down your Git repository.**

`git-weight` is a fast, standalone CLI for Git repository storage forensics.
It parses Git storage formats directly — packfiles, pack indexes, loose
objects, refs — with no dependency on the Git executable, Python, or any
other runtime. It is a read-only tool: it never modifies packs, refs, or the
working tree.

Unlike `git-sizer` (which identifies structural characteristics that make a
repository awkward to work with), `git-weight` explains where repository
storage is going and why that storage is still retained.

## Install

Build from source with [Zig](https://ziglang.org) 0.16+:

```sh
zig build -Doptimize=ReleaseFast
```

The binary is named `git-weight`, so Git can invoke it as a subcommand when
it is on your `$PATH`:

```sh
git weight          # same as git-weight
```

## Usage

```text
git weight [COMMAND] [PATH] [OPTIONS]

Commands:
  summary    High-level repository report (default)
  largest    Largest blobs in repository history
  objects    Per-type object counts and logical sizes
  packs      Packfile statistics

Options:
  --json             Machine-readable JSON output
  --limit N          Maximum entries to list (default 20)
  --min-size SIZE    Only include blobs at least SIZE (e.g. 10MB, 500KiB)
  --threads N        Worker thread count (accepted; v0.1 runs single-threaded)
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
```

### Terminology

| Term        | Meaning                                                        |
|-------------|----------------------------------------------------------------|
| Logical size | Full reconstructed Git object size                            |
| Physical size | Actual storage consumed in a packfile or loose object file    |
| Current     | Object reachable from the tree at `HEAD`                       |
| Historical  | Object in reachable history, but not in the current `HEAD` tree|
| Unreachable | Object not reachable from any ref (v0.3)                       |

## Exit codes

| Code | Meaning               |
|------|-----------------------|
| 0    | success               |
| 1    | general error         |
| 2    | invalid arguments     |
| 3    | repository not found  |
| 4    | unsupported Git format|
| 5    | corrupt repository    |

## Development

```sh
zig build          # debug build
zig build test     # unit tests
test/verify.sh     # integration checks against Git plumbing (uses git as a test oracle)
```

## Status and roadmap

**v0.1** (current): repository discovery (normal, bare, linked worktrees),
loose-object scanning, pack index v2 parsing, pack entry metadata, native
zlib streaming, OFS/REF delta resolution for exact logical sizes, object
counts, largest-blob identification with representative paths and
current/historical status, human-readable and JSON output, macOS/Linux.

Planned:

- **v0.2**: `git weight explain`, deeper historical path resolution, Windows support
- **v0.3**: reachability analysis, `refs` and `unreachable` commands, physical
  vs logical contribution, reclaimability estimates, worker-pool parallelism
- **v1.0**: full "why is this still here?" story per spec

See `spec.md` (in the project repository) for the full product definition.

## License

MIT
