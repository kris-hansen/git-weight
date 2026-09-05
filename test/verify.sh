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

# --- unreachable objects ------------------------------------------------------
cd "$FIXTURES/packed"
head -c 700000 /dev/urandom | git hash-object -w --stdin > "$FIXTURES/dangling_oid"

"$GW" unreachable --json > "$FIXTURES/unreachable.json"
python3 - "$FIXTURES/unreachable.json" <<'PYEOF'
import json, subprocess, sys

ours = json.load(open(sys.argv[1]))["unreachable"]
if ours["count"] < 1 or ours["logical_bytes"] < 700000:
    print(f"FAIL: dangling blob not reported: {ours}", file=sys.stderr)
    sys.exit(1)

# Oracle: every object minus those reachable from any ref.
all_ids = set(subprocess.check_output(
    ["git", "cat-file", "--batch-all-objects",
     "--batch-check=%(objectname)"]).decode().split())
reachable = set(
    l.split(" ", 1)[0]
    for l in subprocess.check_output(
        ["git", "rev-list", "--objects", "--all"]).decode().splitlines())
for line in subprocess.check_output(
        ["git", "for-each-ref", "refs/tags",
         "--format=%(objectname) %(objecttype)"]).decode().splitlines():
    oid, t = line.split()
    if t == "tag":
        reachable.add(oid)
expected = len(all_ids - reachable)
if ours["count"] != expected:
    print(f"FAIL: oracle unreachable count {expected}, got {ours['count']}",
          file=sys.stderr)
    sys.exit(1)
print(f"ok: unreachable count matches oracle ({expected})")
PYEOF

# --- refs unique weight --------------------------------------------------------
"$GW" refs --json > "$FIXTURES/refs.json"
python3 - "$FIXTURES/refs.json" <<'PYEOF'
import json, sys

refs = {r["full_name"]: r for r in json.load(open(sys.argv[1]))["refs"]}
if "refs/heads/main" not in refs or refs["refs/heads/main"]["name"] != "main":
    print(f"FAIL: main missing from refs output: {refs}", file=sys.stderr)
    sys.exit(1)
# The 500KB current model.bin blob is retained by main alone.
if refs["refs/heads/main"]["unique_bytes"] < 500000:
    print(f"FAIL: main unique_bytes {refs['refs/heads/main']['unique_bytes']}",
          file=sys.stderr)
    sys.exit(1)
# prod.sql is in main's history too, so v1.0 only uniquely retains the
# (small) annotated tag object.
if "refs/tags/v1.0" not in refs or refs["refs/tags/v1.0"]["unique_bytes"] <= 0:
    print(f"FAIL: v1.0 missing or zero weight: {refs}", file=sys.stderr)
    sys.exit(1)
print("ok: refs unique weights on packed fixture")
PYEOF

# A tag whose tip is not in any branch's history uniquely retains its data.
REPO="$FIXTURES/tagunique"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main
git config user.email test@example.com
git config user.name Test
echo readme > README.md
git add -A && git commit -qm base
git checkout -q --orphan archive
rm -f README.md
head -c 3000000 /dev/urandom > big.bin
git add -A && git commit -qm archived
git tag -a v9.9 -m "archive"
git checkout -q main
git branch -qD archive

"$GW" refs --json > "$FIXTURES/refs_tagunique.json"
python3 - "$FIXTURES/refs_tagunique.json" <<'PYEOF'
import json, subprocess, sys

refs = {r["full_name"]: r for r in json.load(open(sys.argv[1]))["refs"]}
tag = refs.get("refs/tags/v9.9")
if tag is None or tag["name"] != "v9.9":
    print(f"FAIL: v9.9 missing: {refs}", file=sys.stderr)
    sys.exit(1)
if tag["unique_bytes"] < 3000000:
    print(f"FAIL: v9.9 unique_bytes {tag['unique_bytes']} < 3000000",
          file=sys.stderr)
    sys.exit(1)
# Oracle lower bound: blobs reachable only via the tag.
out = subprocess.check_output(
    ["git", "rev-list", "--objects", "refs/tags/v9.9",
     "--not", "refs/heads/main"]).decode().splitlines()
oids = [l.split(" ", 1)[0] for l in out]
if oids:
    sizes = subprocess.check_output(
        ["git", "cat-file", "--batch-check=%(objectsize)"],
        input="\n".join(oids).encode()).decode().split()
    oracle = sum(int(s) for s in sizes)
    if tag["unique_bytes"] < oracle:
        print(f"FAIL: v9.9 unique {tag['unique_bytes']} < oracle {oracle}",
              file=sys.stderr)
        sys.exit(1)
print("ok: tag uniquely retains its history (v9.9 >= 3 MB)")
PYEOF

# --- explain by path -----------------------------------------------------------
cd "$FIXTURES/packed"
"$GW" explain database/prod.sql --json > "$FIXTURES/explain.json"
python3 - "$FIXTURES/explain.json" <<'PYEOF'
import json, sys

d = json.load(open(sys.argv[1]))
def check(cond, msg):
    if not cond:
        print(f"FAIL: {msg}: {d}", file=sys.stderr)
        sys.exit(1)
check(d["type"] == "blob", "type")
check(d["logical_bytes"] == 3000000, "logical_bytes")
check(d["reachable"] is True, "reachable")
check(d["reachable_from_head"] is False, "reachable_from_head")
check("refs/tags/v1.0" in d["retained_by"], "retained_by")
check(d["introduced"] is not None and d["deleted"] is not None, "history")
check(d["introduced"]["commit"] != d["deleted"]["commit"], "distinct commits")
print("ok: explain database/prod.sql --json")
PYEOF

"$GW" explain database/prod.sql | grep -q "refs/tags/v1.0" \
    || fail "explain human output missing refs/tags/v1.0"
echo "ok: explain human output lists retaining tag"

# --- explain by object id -------------------------------------------------------
PROD_OID=$(git rev-parse 'v1.0:database/prod.sql')
"$GW" explain "$PROD_OID" --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['logical_bytes'] == 3000000, d
print('ok: explain by full oid')"
SHORT_OID=$(printf '%s' "$PROD_OID" | cut -c1-8)
"$GW" explain "$SHORT_OID" --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['logical_bytes'] == 3000000, d
print('ok: explain by abbreviated oid')"

# --- summary completion ----------------------------------------------------------
"$GW" --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'unreachable_bytes' in d, d.keys()
print('ok: summary json has unreachable_bytes')"
"$GW" | grep -q "Largest contributor:" || fail "summary missing Largest contributor"
"$GW" | grep -q "git weight explain" || fail "summary missing explain hint"
echo "ok: summary shows largest contributor hint"

# --- explain error cases ----------------------------------------------------------
set +e
"$GW" explain does/not/exist >/dev/null 2>&1
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail "expected non-zero exit for unknown path"
echo "ok: explain unknown path exits non-zero: $CODE"

set +e
"$GW" explain >/dev/null 2>&1
CODE=$?
set -e
[ "$CODE" -eq 2 ] || fail "expected exit 2 for explain without target, got $CODE"
echo "ok: explain without target exits 2"

# --- changed command -------------------------------------------------------------
REPO="$FIXTURES/changed"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main
git config user.email test@example.com
git config user.name Test
mkdir -p services/api services/web
head -c 10000 /dev/urandom > services/api/file
head -c 10000 /dev/urandom > services/web/file
git add -A && git commit -qm c1
head -c 12000 /dev/urandom > services/api/file
git add -A && git commit -qm c2

# (a) changed/unchanged directories, cross-checked with git diff --quiet.
"$GW" changed services/api --base HEAD~1 --json > "$FIXTURES/changed_api.json"
"$GW" changed services/web --base HEAD~1 --json > "$FIXTURES/changed_web.json"
python3 - "$FIXTURES/changed_api.json" "$FIXTURES/changed_web.json" <<'PYEOF'
import json, subprocess, sys

api = json.load(open(sys.argv[1]))
web = json.load(open(sys.argv[2]))
if api["changed"] is not True or web["changed"] is not False:
    print(f"FAIL: api={api['changed']} web={web['changed']}", file=sys.stderr)
    sys.exit(1)
for path, want in (("services/api", 1), ("services/web", 0)):
    r = subprocess.run(
        ["git", "diff", "--quiet", "HEAD~1", "HEAD", "--", path])
    if r.returncode != want:
        print(f"FAIL: oracle diff --quiet {path} = {r.returncode}",
              file=sys.stderr)
        sys.exit(1)
print("ok: changed detection matches git diff --quiet oracle")
PYEOF

# (b) tree hashes match git rev-parse.
python3 - "$FIXTURES/changed_api.json" <<'PYEOF'
import json, subprocess, sys

d = json.load(open(sys.argv[1]))
base = subprocess.check_output(
    ["git", "rev-parse", "HEAD~1:services/api"]).decode().strip()
to = subprocess.check_output(
    ["git", "rev-parse", "HEAD:services/api"]).decode().strip()
if d["base"]["tree"] != base or d["to"]["tree"] != to:
    print(f"FAIL: trees {d['base']['tree']}/{d['to']['tree']} != "
          f"{base}/{to}", file=sys.stderr)
    sys.exit(1)
print("ok: changed tree hashes match git rev-parse oracle")
PYEOF

# (c) default refs are HEAD~1 and HEAD.
"$GW" changed services/api --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['changed'] is True, d
assert d['base']['ref'] == 'HEAD~1' and d['to']['ref'] == 'HEAD', d
print('ok: changed default refs')"

# (e) file path comparison (blob oids).
"$GW" changed services/api/file --base HEAD~1 --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['changed'] is True, d
assert d['base']['tree'] != d['to']['tree'], d
print('ok: changed file path')"

# (d) a newly added directory is absent on the base side.
mkdir -p services/new
head -c 5000 /dev/urandom > services/new/file
git add -A && git commit -qm c3
"$GW" changed services/new --base HEAD~1 --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['changed'] is True, d
assert d['base']['tree'] is None, d
assert d['to']['tree'] is not None, d
print('ok: changed new directory (base absent)')"

# (f) --exit-code mirrors git diff --exit-code.
set +e
"$GW" changed services/new --base HEAD~1 --exit-code >/dev/null 2>&1
CODE=$?
set -e
[ "$CODE" -eq 1 ] || fail "expected exit 1 for changed path, got $CODE"
set +e
"$GW" changed services/web --base HEAD~1 --exit-code >/dev/null 2>&1
CODE=$?
set -e
[ "$CODE" -eq 0 ] || fail "expected exit 0 for unchanged path, got $CODE"
echo "ok: changed --exit-code (1 changed, 0 unchanged)"

# (g) error cases.
set +e
"$GW" changed does/not/exist --base HEAD~1 >/dev/null 2>&1
CODE=$?
set -e
[ "$CODE" -eq 1 ] || fail "expected exit 1 for missing path, got $CODE"
set +e
"$GW" changed --base bogusref services/api >/dev/null 2>&1
CODE=$?
set -e
[ "$CODE" -eq 2 ] || fail "expected exit 2 for unresolvable base, got $CODE"
set +e
"$GW" changed >/dev/null 2>&1
CODE=$?
set -e
[ "$CODE" -eq 2 ] || fail "expected exit 2 for changed without path, got $CODE"
echo "ok: changed error exit codes (1 missing path, 2 bad ref, 2 no path)"

echo "ALL INTEGRATION CHECKS PASSED"
