# git-weight

## 1. Overview

`git-weight` is a fast, standalone command-line utility for analyzing the physical and logical storage footprint of a Git repository.

Its primary purpose is to answer:

**“What is weighing down this Git repository?”**

The tool inspects the Git object database, packfiles, references, and history to identify the blobs, paths, commits, branches, and tags responsible for repository size.

The emphasis is on **storage forensics**, not general repository health.

`git-weight` should help users determine:

- what consumes repository space
- whether that data is current or historical
- what references keep historical data alive
- how much physical packfile space those objects actually consume
- what could plausibly be reclaimed

The reference implementation is written in Zig and distributed as a single native executable.

Because the binary is named:

```text
git-weight
```

Git can invoke it naturally as:

```bash
git weight
```

when `git-weight` is available on `$PATH`.

---

## 2. Positioning

`git-weight` is not intended to duplicate tools such as `git-sizer`.

The core distinction is:

**`git-sizer` identifies structural characteristics that may make a repository difficult to work with.**

**`git-weight` explains where repository storage is going and why that storage is still retained.**

The product should be understood as:

> **Fast Git repository storage forensics.**

A more approachable description:

> **Find out what’s weighing down your Git repository.**

---

## 3. Goals

The project should:

- Explain where repository disk usage comes from.
- Identify the largest blobs in repository history.
- Map large Git objects back to filenames.
- Distinguish current files from historical files.
- Identify refs retaining large historical objects.
- Separate logical object size from physical packed size.
- Identify unreachable objects.
- Estimate reclaimable storage.
- Operate efficiently on very large repositories.
- Avoid requiring Python, Node.js, Ruby, JVM, or other runtimes.
- Avoid requiring the Git executable for normal operation.
- Support interactive use and automation.
- Support macOS, Linux, and Windows.
- Produce deterministic machine-readable output.

The long-term objective is for `git-weight` to parse Git storage formats directly.

---

## 4. Non-Goals

Initial releases will not:

- rewrite Git history
- delete Git objects
- modify refs
- run garbage collection
- invoke `git filter-repo`
- migrate files to Git LFS
- alter the working tree
- upload repository data anywhere
- act as a complete Git implementation

`git-weight` is a read-only forensic tool.

---

# 5. Primary User Experience

The preferred invocation is:

```bash
git weight
```

Direct execution is equivalent:

```bash
git-weight
```

The tool discovers the repository containing the current directory and prints a concise diagnostic report.

Example:

```text
Repository: my-project

Repository weight
  Total .git size             2.74 GB
  Object database             2.66 GB
  Working tree                83.4 MB

Objects
  Blobs                       2.51 GB
  Trees                       92.1 MB
  Commits                     18.7 MB
  Tags                        312 KB

Storage
  Packfiles                   2.61 GB
  Loose objects               48.3 MB

Largest contributors

  SIZE       PATH                         STATUS
  731 MB     database/prod.sql            historical
  418 MB     models/model.bin             current
  192 MB     assets/demo.mov              historical
  88 MB      test/fixtures/archive.zip    historical

Potential cleanup
  Historical deleted files    1.01 GB
  Unreachable objects         143 MB

Largest contributor:
  database/prod.sql

Run:

  git weight explain database/prod.sql
```

---

# 6. Core Commands

## 6.1 `git weight`

Displays the high-level repository report.

```bash
git weight
```

Equivalent to:

```bash
git weight summary
```

Optional repository:

```bash
git weight /path/to/repository
```

---

## 6.2 `git weight largest`

Lists the largest blobs in repository history.

```bash
git weight largest
```

Example:

```text
SIZE       OBJECT        PATH
731 MB     81f43dc...    database/prod.sql
418 MB     a921ab7...    models/model.bin
192 MB     f91c228...    assets/demo.mov
```

Options:

```bash
git weight largest --limit 50
git weight largest --min-size 10MB
git weight largest --current
git weight largest --historical
```

Default limit:

```text
20
```

---

## 6.3 `git weight explain`

Explains why a path or object contributes to repository weight.

Examples:

```bash
git weight explain database/prod.sql
```

or:

```bash
git weight explain 81f43dc
```

Example output:

```text
database/prod.sql

Blob
  Object       81f43dc821...
  Logical size 731.4 MB
  Packed size  612.8 MB

History
  Introduced   2019-03-11
  Commit       9ac810e
  Author       Alice Example

  Deleted      2019-03-12
  Commit       c203d9a

References retaining this object

  refs/tags/v1.0
  refs/heads/release-2019

Reachability

  Reachable     yes
  From HEAD     no

Estimated reclaimable storage

  612.8 MB if all retaining refs and history are rewritten
```

This command is central to the product.

It should answer:

**“Why is this still here?”**

---

## 6.4 `git weight refs`

Shows refs responsible for retaining historical weight.

```bash
git weight refs
```

Example:

```text
REFERENCE                 UNIQUE WEIGHT
main                      488 MB
release-2024              121 MB
release-2019              812 MB
v1.0                      731 MB
```

The purpose is to identify old branches and tags retaining large historical objects.

Because exact attribution can be expensive, this command may provide either exact or approximate results depending on repository size and analysis mode.

---

## 6.5 `git weight objects`

Displays low-level object statistics.

```bash
git weight objects
```

Example:

```text
TYPE       COUNT        LOGICAL SIZE
blob       1,829,112    2.51 GB
tree         382,104    92.1 MB
commit        89,221    18.7 MB
tag              184    312 KB
```

---

## 6.6 `git weight packs`

Displays packfile statistics.

```bash
git weight packs
```

Example:

```text
PACK                          OBJECTS     PHYSICAL SIZE
pack-a2f...pack               812,221     1.91 GB
pack-c91...pack               430,114     701 MB
```

Future versions may additionally report:

- delta depth
- compression efficiency
- large delta bases
- duplicate content
- pack fragmentation
- repack opportunities

---

## 6.7 `git weight unreachable`

Displays unreachable objects.

```bash
git weight unreachable
```

Example:

```text
Unreachable objects

Count            41,902
Logical size     221 MB
Physical size    143 MB

Likely reclaimable after garbage collection:
143 MB
```

This command should clearly distinguish between:

- storage reclaimable via normal Git GC
- storage requiring history rewriting

---

# 7. Terminology

`git-weight` should use consistent terminology.

## Weight

General user-facing term for repository storage footprint.

## Logical size

The full reconstructed Git object size.

Example:

```text
Logical size: 500 MB
```

## Physical size

The actual amount of storage consumed in a packfile or loose object representation.

Example:

```text
Physical size: 41 MB
```

## Current

An object/path reachable from the tree at `HEAD`.

## Historical

An object that exists in reachable history but is not present in the current `HEAD` tree.

## Unreachable

An object that is not reachable from any relevant Git ref.

## Reclaimable

Storage that could plausibly be removed either by garbage collection or history rewriting.

---

# 8. Global Options

```text
--json
--no-color
--verbose
--quiet
--repo PATH
--threads N
--limit N
--min-size SIZE
--version
--help
```

Human-readable sizes should support:

```text
KB
MB
GB
KiB
MiB
GiB
```

Input should be case-insensitive.

---

# 9. JSON Output

Every diagnostic command should support:

```bash
git weight --json
```

Example:

```json
{
  "repository": {
    "path": "/home/user/project",
    "git_dir": "/home/user/project/.git"
  },
  "weight": {
    "git_bytes": 2942054932,
    "object_bytes": 2856150021,
    "working_tree_bytes": 87432192
  },
  "objects": {
    "blob": {
      "count": 1829112,
      "logical_bytes": 2695097344
    },
    "tree": {
      "count": 382104,
      "logical_bytes": 96573842
    },
    "commit": {
      "count": 89221,
      "logical_bytes": 19623021
    }
  }
}
```

The JSON schema should remain backward compatible within a major release.

---

# 10. Repository Discovery

When invoked without an explicit path, `git-weight` should walk upward from the current working directory looking for either:

```text
.git/
```

or a Git worktree pointer:

```text
.git
```

The tool should support:

- normal repositories
- bare repositories
- linked Git worktrees
- submodules

Repository discovery should not require invoking Git.

---

# 11. Git Data Model

The implementation must understand the four fundamental Git object types:

```text
blob
tree
commit
tag
```

Initial support should include SHA-1 repositories.

The internal abstraction should allow later support for SHA-256 repositories.

Object IDs should therefore not be represented internally as fixed 20-byte values.

Suggested abstraction:

```zig
const ObjectId = struct {
    algorithm: HashAlgorithm,
    bytes: []const u8,
};
```

---

# 12. Storage Formats

Git objects may exist as:

1. loose objects
2. packed objects

Both should eventually be supported natively.

---

# 13. Loose Object Support

Loose objects are stored under:

```text
.git/objects/ab/cdef...
```

They contain a zlib-compressed Git object.

The uncompressed form is:

```text
<type> <size>\0<payload>
```

Example:

```text
blob 1234\0...
```

The implementation should:

1. enumerate loose objects
2. decompress object headers
3. determine object type
4. determine logical size
5. parse payloads only when required

Objects should not normally be fully loaded into memory.

---

# 14. Packfile Support

Native packfile support is a major technical component of the project.

Relevant files:

```text
*.pack
*.idx
```

The index provides object identifiers and offsets into the packfile.

The pack contains compressed objects and delta objects.

The implementation must eventually support:

```text
OBJ_COMMIT
OBJ_TREE
OBJ_BLOB
OBJ_TAG
OBJ_OFS_DELTA
OBJ_REF_DELTA
```

For summary analysis, the tool should avoid reconstructing delta objects unless required.

---

# 15. Pack Index Parsing

The `.idx` parser should support Git pack index version 2.

Required information:

- fanout table
- object IDs
- CRC32 values
- 32-bit offsets
- large 64-bit offsets

The index should normally be memory mapped.

A repository containing millions of objects should not require millions of heap allocations.

---

# 16. Path Resolution

Git blobs do not contain filenames.

Mapping:

```text
blob → filename
```

requires traversing tree objects.

The same blob may appear at multiple paths.

The relationship is therefore:

```text
ObjectId → []Path
```

The implementation should avoid retaining unnecessary duplicate path strings.

Path interning or arena allocation is recommended.

---

# 17. Historical Path Resolution

The same object may appear:

- in multiple commits
- under multiple filenames
- across multiple branches
- across tags

For:

```bash
git weight largest
```

a representative path is sufficient.

For:

```bash
git weight explain
```

the tool should perform deeper historical analysis.

This keeps the default scan fast.

---

# 18. Reachability

The tool should distinguish:

```text
reachable
unreachable
```

Git objects.

Relevant refs include:

```text
refs/heads/*
refs/tags/*
refs/remotes/*
HEAD
```

Unreachable objects may remain physically present until garbage collection removes them.

Example:

```text
Unreachable objects

Count       41,902
Logical     221 MB
Physical    143 MB
```

---

# 19. Current vs Historical Weight

This distinction is a core product feature.

Example:

```text
731 MB     database/prod.sql     historical
418 MB     model.bin             current
```

A current blob is reachable from the tree at `HEAD`.

A historical blob exists in reachable history but not in the current tree.

This immediately tells the user whether a large object belongs to the active codebase or is merely being retained by history.

---

# 20. Reclaimability Analysis

`git-weight` should distinguish two major categories.

## Garbage-collectable weight

Unreachable objects that may be removed through standard Git maintenance.

Example:

```text
143 MB potentially reclaimable via git gc
```

## History-retained weight

Reachable objects retained by branches, tags, or commit history.

Example:

```text
613 MB retained by historical references
```

These objects generally require:

- ref deletion
- history rewriting
- filter-repo
- repository migration

The tool should explain this difference clearly.

---

# 21. Performance Requirements

The tool should be designed for repositories containing:

```text
10M+ Git objects
100GB+ object databases
multi-GB packfiles
```

Performance goals:

- use memory mapping for pack indexes
- avoid per-object heap allocation
- stream decompression
- defer object reconstruction
- parallelize independent work
- keep the default report significantly cheaper than full forensic analysis

A useful aspirational target is:

```text
1 million objects analyzed in seconds, not minutes
```

on contemporary hardware.

Performance benchmarks should eventually be part of CI.

---

# 22. Concurrency

Parallel work candidates include:

- loose-object scanning
- pack index scanning
- object header decompression
- tree traversal
- working-tree size calculation

Concurrency should use a bounded worker pool.

Default:

```text
threads = detected CPU count
```

Override:

```bash
git weight --threads 8
```

The implementation should not create a task or allocation for every Git object.

---

# 23. Memory Management

One of the project's technical objectives is to use Zig's explicit memory model effectively.

Preferred patterns:

- memory-mapped indexes
- arenas for repository-lifetime metadata
- bounded buffers
- streaming decompression
- compact metadata arrays
- integer offsets where possible
- zero-copy parsing where safe

Example metadata structure:

```zig
const ObjectMeta = struct {
    offset: u64,
    size: u64,
    pack_id: u32,
    object_type: ObjectType,
    flags: u8,
};
```

Millions of Git objects should not translate to millions of general-purpose heap allocations.

---

# 24. Architecture

Suggested layout:

```text
src/
  main.zig

  cli/
    args.zig
    output.zig
    json.zig

  git/
    repository.zig
    refs.zig

    object.zig
    object_id.zig

    loose.zig

    pack/
      index.zig
      pack.zig
      delta.zig

    commit.zig
    tree.zig
    blob.zig
    tag.zig

  analysis/
    summary.zig
    largest.zig
    explain.zig
    reachability.zig
    paths.zig
    refs.zig
    reclaim.zig

  platform/
    mmap.zig
    filesystem.zig
```

The Git parsing layer should not depend on CLI presentation code.

This allows the core to become a reusable Zig package later.

---

# 25. Error Handling

Errors should be concise and actionable.

Example:

```text
error: not inside a Git repository
```

Corrupt repository structures should identify the source where possible.

Example:

```text
error: invalid pack index

file:
  .git/objects/pack/pack-81fc2.idx

reason:
  fanout table is not monotonic
```

Verbose mode may expose additional diagnostic detail.

---

# 26. Safety

The tool must be read-only.

It must never:

- modify packfiles
- modify refs
- run garbage collection
- delete loose objects
- rewrite commits

Future destructive functionality, if ever introduced, must be explicitly separated from normal analysis.

The default command should always be safe to run against production or important repositories.

---

# 27. v0.1 Scope

The first useful release should remain intentionally focused.

## Required

- repository discovery
- `.git` disk size
- working-tree disk size
- loose-object scanning
- pack index parsing
- packfile metadata
- object counts
- largest blob identification
- representative blob-to-path resolution
- current vs historical status
- human-readable output
- JSON output
- macOS support
- Linux support

Commands:

```bash
git weight
git weight largest
git weight largest --limit 50
git weight --json
```

---

# 28. v0.2 Scope

Add:

- native pack object reading
- object decompression
- delta resolution
- exact logical blob sizes
- deeper historical path resolution
- `git weight explain`
- Windows support

---

# 29. v0.3 Scope

Add:

- reachability analysis
- unreachable object reporting
- branch and tag retention analysis
- `git weight refs`
- physical versus logical contribution
- reclaimability estimates
- performance improvements for very large repositories

---

# 30. v1.0 Definition

`git-weight` reaches 1.0 when it can reliably answer:

1. How much does this repository weigh?
2. What objects consume the storage?
3. Which files do those objects correspond to?
4. Are those files current or historical?
5. When were they introduced?
6. Which refs keep them alive?
7. How much physical disk space do they actually consume?
8. Which storage is garbage-collectable?
9. Which storage requires history rewriting to reclaim?

All of this should work without requiring Git itself.

---

# 31. CLI Grammar

```text
git weight [PATH] [OPTIONS]

git weight summary [PATH]
git weight largest [PATH]
git weight explain <PATH|OBJECT>
git weight objects [PATH]
git weight packs [PATH]
git weight refs [PATH]
git weight unreachable [PATH]
```

Common options:

```text
--json
--limit N
--min-size SIZE
--threads N
--no-color
--verbose
--quiet
```

---

# 32. Exit Codes

Suggested:

```text
0    success
1    general error
2    invalid arguments
3    repository not found
4    unsupported Git format
5    corrupt repository
```

Automation should be able to depend on these values.

---

# 33. Testing Strategy

Testing should use generated repositories and representative real-world repositories.

Unit tests should cover:

- object ID parsing
- loose object parsing
- pack index parsing
- pack headers
- variable-length integers
- delta instructions
- tree parsing
- commit parsing
- size formatting
- repository discovery
- reachability

Fixture repositories should include:

- empty repository
- single commit
- loose objects
- packed repository
- delta-heavy pack
- large blobs
- deleted large blobs
- tags retaining historical blobs
- branches retaining historical blobs
- unreachable objects
- worktrees
- bare repositories
- SHA-256 repositories when supported

During development and CI, results may be compared against Git plumbing commands such as:

```bash
git count-objects
git cat-file
git rev-list
git verify-pack
```

Git may be used as a test oracle even though the shipping binary should not depend on it.

---

# 34. Benchmarking

Benchmark repositories should include approximately:

```text
10K objects
100K objects
1M objects
10M objects
```

Metrics:

```text
wall-clock time
peak RSS
objects/sec
bytes/sec
CPU utilization
```

Performance regressions should eventually fail CI beyond defined thresholds.

---

# 35. Distribution

Primary executable:

```text
git-weight
```

This enables:

```bash
git weight
```

## Homebrew

```bash
brew install git-weight
```

## Direct release artifacts

```text
git-weight-linux-x86_64
git-weight-linux-aarch64
git-weight-macos-x86_64
git-weight-macos-aarch64
git-weight-windows-x86_64.exe
```

## Source build

```bash
zig build -Doptimize=ReleaseFast
```

The binary should have no runtime dependency beyond normal OS facilities.

---

# 36. Potential Future Features

## Repository growth

```bash
git weight growth
```

Example:

```text
2020      80 MB
2021     122 MB
2022     918 MB   model.bin introduced
2023     1.1 GB
2024     2.7 GB   prod.sql introduced
```

---

## Commit contribution

```bash
git weight commits
```

Identify commits responsible for the largest increases in repository weight.

---

## CI regression detection

```bash
git weight check --max-growth 10MB
```

Fail CI if a pull request introduces excessive repository growth.

---

## File-type analysis

```bash
git weight types
```

Example:

```text
.bin       1.31 GB
.sql       731 MB
.mov       328 MB
.zip       229 MB
.png       142 MB
```

---

## LFS recommendations

Identify files that are strong Git LFS candidates.

Example:

```text
Git LFS candidates

models/*.bin     1.31 GB
assets/*.mov      328 MB
archives/*.zip    229 MB
```

---

## Duplicate content

Identify large blobs referenced under multiple paths or historically duplicated with different object identities where detectable.

---

# 37. Design Principle

The key product principle is:

**Do not merely report Git internals. Explain repository weight.**

Git already exposes low-level plumbing.

The value of `git-weight` is converting this:

```text
pack-872dea78e.idx
OBJ_REF_DELTA
81f43dc821...
```

into this:

```text
Your repository weighs 2.7 GB primarily because a
731 MB SQL dump was committed in 2019.

The file was deleted the following day, but tag v1.0
still retains the history containing it.

Its logical size is 731 MB and its current packed
storage contribution is approximately 613 MB.

Removing it requires rewriting the history retained
by v1.0. It cannot be reclaimed by normal garbage
collection.
```

That explanation is the product.

---

# 38. Initial Engineering Milestone

The first engineering milestone should be:

```bash
git weight largest
```

against a real packed repository.

It must return:

```text
object ID
logical size
representative path
current/historical status
```

for the 20 largest blobs.

The implementation should:

- parse pack indexes natively
- avoid shelling out to Git
- remain memory efficient on large repositories
- establish baseline benchmarks against equivalent Git plumbing commands

If this command is fast and correct on repositories containing millions of objects, `git-weight` has already become a useful open-source tool rather than merely a Zig exercise.

---

# 39. Project Identity

Project name:

```text
git-weight
```

Primary CLI:

```bash
git weight
```

Suggested tagline:

> **Find out what’s weighing down your Git repository.**

Technical tagline:

> **Fast Git repository storage forensics.**

Suggested repository description:

> A fast Zig CLI for understanding where Git repository storage goes, what keeps it alive, and what can be reclaimed.
