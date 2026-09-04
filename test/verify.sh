#!/bin/sh
# Integration verification for git-weight.
#
# Generates fixture repositories, then compares git-weight output against
# Git plumbing (the test oracle; the shipping binary never invokes git).
#
# Usage: test/verify.sh [path-to-git-weight-binary]

set -eu

GW="${1:-$(dirname "$0")/../zig-out/bin/git-weight}"
# Resolve to an absolute path: the script cd's into fixtures below.
case "$GW" in
    /*) ;;
    *) GW="$(cd "$(dirname "$GW")" && pwd)/$(basename "$GW")" ;;
esac
[ -x "$GW" ] || { echo "git-weight binary not found: $GW" >&2; exit 1; }
FIXTURES="$(mktemp -d)"
trap 'rm -rf "$FIXTURES"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- fixture: packed repo with deleted + current large blobs -----------------
REPO="$FIXTURES/packed"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main
git config user.email test@example.com
git config user.name Test
mkdir -p database models assets
head -c 3000000 /dev/urandom > database/prod.sql
head -c 2000000 /dev/urandom > models/model.bin
head -c 1000000 /dev/urandom > assets/demo.mov
echo small > README.md
git add -A && git commit -qm "add files"
git tag -a v1.0 -m "release"
git rm -q database/prod.sql
git commit -qm "remove prod.sql"
head -c 500000 /dev/urandom > models/model.bin
git add -A && git commit -qm "change model"
git gc -q
git prune

# Per-type counts and logical sizes must match git cat-file exactly.
"$GW" objects --json > "$FIXTURES/objects.json"
python3 - "$FIXTURES/objects.json" <<'PYEOF'
import json, subprocess, sys

ours = json.load(open(sys.argv[1]))["objects"]
out = subprocess.check_output(
    ["git", "cat-file", "--batch-all-objects",
     "--batch-check=%(objecttype) %(objectsize)"]).decode()
oracle = {}
for line in out.splitlines():
    t, size = line.split()
    e = oracle.setdefault(t, [0, 0])
    e[0] += 1
    e[1] += int(size)

for t in ("blob", "tree", "commit", "tag"):
    o = oracle.get(t, [0, 0])
    got = ours[t]
    if got["count"] != o[0] or got["logical_bytes"] != o[1]:
        fail = f"{t}: oracle count/size {o}, got {got}"
        print("FAIL: " + fail, file=sys.stderr)
        sys.exit(1)
print("ok: object counts and logical sizes match git cat-file oracle")
PYEOF

# Every reported blob size must match the oracle.
"$GW" largest --limit 100 --json > "$FIXTURES/largest.json"
python3 - "$FIXTURES/largest.json" <<'PYEOF'
import json, subprocess, sys

blobs = json.load(open(sys.argv[1]))["blobs"]
ours = {b["oid"][:7]: b["logical_bytes"] for b in blobs}
out = subprocess.check_output(
    ["git", "cat-file", "--batch-all-objects",
     "--batch-check=%(objectname) %(objecttype) %(objectsize)"]).decode()
n = 0
for line in out.splitlines():
    oid, t, size = line.split()
    if t != "blob":
        continue
    n += 1
    if ours.get(oid[:7]) != int(size):
        print(f"FAIL: blob {oid}: oracle {size}, got {ours.get(oid[:7])}",
              file=sys.stderr)
        sys.exit(1)
print(f"ok: {n} per-blob logical sizes match oracle (delta resolution)")
PYEOF

# current/historical classification must match git ls-tree at HEAD.
"$GW" largest --limit 100 --json > "$FIXTURES/largest.json"
python3 - "$FIXTURES/largest.json" <<'PYEOF'
import json, subprocess, sys

blobs = json.load(open(sys.argv[1]))["blobs"]
out = subprocess.check_output(
    ["git", "ls-tree", "-r", "HEAD"]).decode()
current = set()
for line in out.splitlines():
    # "100644 blob <oid>\t<path>"
    current.add(line.split()[2][:7])
for b in blobs:
    want = "current" if b["oid"][:7] in current else "historical"
    if b["status"] != want:
        print(f"FAIL: {b['path']}: want {want}, got {b['status']}",
              file=sys.stderr)
        sys.exit(1)
print("ok: current/historical classification matches git ls-tree HEAD")
PYEOF

# Representative paths must exist at some point in history.
python3 - "$FIXTURES/largest.json" <<'PYEOF'
import json, subprocess, sys

blobs = json.load(open(sys.argv[1]))["blobs"]
hist_paths = set()
for ref in subprocess.check_output(["git", "for-each-ref", "--format=%(refname)"]).decode().split():
    out = subprocess.check_output(["git", "ls-tree", "-r", ref]).decode()
    for line in out.splitlines():
        hist_paths.add(line.split()[3])
for b in blobs:
    if b["path"] is not None and b["path"] not in hist_paths:
        print(f"FAIL: path {b['path']} never existed in history",
              file=sys.stderr)
        sys.exit(1)
print("ok: representative paths exist in history")
PYEOF

# --- fixture: delta-heavy repo ------------------------------------------------
REPO="$FIXTURES/delta"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main
git config user.email test@example.com
git config user.name Test
python3 -c "
import random
random.seed(42)
lines = ['line %06d %s' % (i, ''.join(random.choice('abcdefgh') for _ in range(60))) for i in range(20000)]
open('big.txt', 'w').write('\n'.join(lines) + '\n')"
git add -A && git commit -qm c0
for i in 1 2 3 4 5; do
    python3 -c "
import random
random.seed($i)
lines = open('big.txt').read().splitlines()
for _ in range(50):
    lines[random.randrange(len(lines))] = 'changed $i ' + ''.join(random.choice('xyz') for _ in range(50))
open('big.txt', 'w').write('\n'.join(lines) + '\n')"
    git commit -qm "c$i" -a
done
git gc -q

DELTA_COUNT=$(git verify-pack -v .git/objects/pack/*.idx 2>/dev/null | awk 'length($1) == 40 && NF == 7' | wc -l)
echo "delta-heavy fixture: $DELTA_COUNT delta objects"
[ "$DELTA_COUNT" -gt 0 ] || fail "fixture did not produce delta objects"

"$GW" objects --json > "$FIXTURES/delta_objects.json"
python3 - "$FIXTURES/delta_objects.json" <<'PYEOF'
import json, subprocess, sys

ours = json.load(open(sys.argv[1]))["objects"]
out = subprocess.check_output(
    ["git", "cat-file", "--batch-all-objects",
     "--batch-check=%(objecttype) %(objectsize)"]).decode()
oracle = {}
for line in out.splitlines():
    t, size = line.split()
    e = oracle.setdefault(t, [0, 0])
    e[0] += 1
    e[1] += int(size)
for t in ("blob", "tree", "commit"):
    o = oracle.get(t, [0, 0])
    got = ours[t]
    if got["count"] != o[0] or got["logical_bytes"] != o[1]:
        print(f"FAIL {t}: oracle {o}, got {got}", file=sys.stderr)
        sys.exit(1)
print("ok: delta-heavy logical sizes match oracle")
PYEOF

# --- fixture: delta'd trees (many commits modifying subsets of files) -------
REPO="$FIXTURES/trees"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main
git config user.email test@example.com
git config user.name Test
python3 - <<'PYEOF'
import os, random, subprocess
random.seed(7)
p = subprocess.Popen(["git", "fast-import", "--quiet"], stdin=subprocess.PIPE)
out = p.stdin
for c in range(300):
    out.write(b"commit refs/heads/main\n")
    out.write(f"committer T <t@t> {1700000000+c*60} +0000\n".encode())
    msg = f"commit {c}\n"
    out.write(f"data {len(msg)}\n".encode() + msg.encode())
    for f in sorted(random.sample(range(40), 8)):
        content = os.urandom(random.choice([300, 2000, 8000]))
        path = f"src/file{f:03d}.bin"
        out.write(f"M 100644 inline {path}\n".encode())
        out.write(f"data {len(content)}\n".encode() + content + b"\n")
    out.write(b"\n")
out.close()
p.wait()
assert p.returncode == 0
PYEOF
git gc -q

TREE_DELTAS=$(git verify-pack -v .git/objects/pack/*.idx 2>/dev/null | awk 'length($1) == 40 && $2 == "tree" && NF == 7' | wc -l)
echo "tree-delta fixture: $TREE_DELTAS delta'd trees"
[ "$TREE_DELTAS" -gt 0 ] || fail "fixture did not produce delta'd trees"

# Every blob must map to a path from the git rev-list oracle.
"$GW" largest --limit 100000 --json > "$FIXTURES/trees_largest.json"
python3 - "$FIXTURES/trees_largest.json" <<'PYEOF'
import json, subprocess, sys

blobs = json.load(open(sys.argv[1]))["blobs"]
out = subprocess.check_output(
    ["git", "rev-list", "--objects", "--all"]).decode(errors="replace")
oid_paths = {}
for line in out.splitlines():
    parts = line.split(" ", 1)
    if len(parts) == 2:
        oid_paths[parts[0][:7]] = parts[1]
missing = 0
for b in blobs:
    p = b["path"]
    if p is None or oid_paths.get(b["oid"][:7]) != p:
        missing += 1
        if missing <= 3:
            print(f"bad path: {b['oid'][:7]} tool={p} oracle={oid_paths.get(b['oid'][:7])}",
                  file=sys.stderr)
if missing:
    print(f"FAIL: {missing} blobs with missing/incorrect path", file=sys.stderr)
    sys.exit(1)
print(f"ok: {len(blobs)} blob paths match git rev-list oracle (delta'd trees)")
PYEOF

# --- fixture: loose-only and empty repos --------------------------------------
REPO="$FIXTURES/loose"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main
git config user.email test@example.com
git config user.name Test
head -c 1000000 /dev/urandom > big.bin
git add -A && git commit -qm one
"$GW" largest --limit 1 --json | python3 -c "
import json, sys
b = json.load(sys.stdin)['blobs'][0]
assert b['logical_bytes'] == 1000000, b
assert b['status'] == 'current', b
print('ok: loose-only repo')"
echo "ok: loose-only repo"

REPO="$FIXTURES/empty"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main
"$GW" --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['objects']['blob']['count'] == 0
print('ok: empty repo')"

# --- bare repository and linked worktree --------------------------------------
cd "$FIXTURES/packed"
git clone -q --bare . "$FIXTURES/bare.git"
cd "$FIXTURES/bare.git"
"$GW" largest --limit 1 --json | python3 -c "
import json, sys
assert json.load(sys.stdin)['blobs'][0]['logical_bytes'] == 3000000
print('ok: bare repository')"

cd "$FIXTURES/packed"
git branch -q side HEAD~1
git worktree add -q "$FIXTURES/wt" side
cd "$FIXTURES/wt"
"$GW" largest --limit 1 --json | python3 -c "
import json, sys
assert json.load(sys.stdin)['blobs'][0]['logical_bytes'] == 3000000
print('ok: linked worktree')"

# --- error cases --------------------------------------------------------------
cd "$FIXTURES"
mkdir notrepo && cd notrepo
set +e
"$GW" >/dev/null 2>&1
CODE=$?
set -e
[ "$CODE" -eq 3 ] || fail "expected exit 3 outside a repo, got $CODE"
echo "ok: exit code outside repo: $CODE (expected 3)"

echo "ALL INTEGRATION CHECKS PASSED"
