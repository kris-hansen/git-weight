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
# cd out first: removing a directory tree that contains the shell's own
# working directory fails with EPERM on some platforms (macOS runners).
trap 'cd /; rm -rf "$FIXTURES"' EXIT

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

# lfs_candidate: the 3 MB database/prod.sql fixture blob is a candidate
# (.sql is a curated dump extension); the small README blob is not.
"$GW" largest --limit 100 --json > "$FIXTURES/largest.json"
python3 - "$FIXTURES/largest.json" <<'PYEOF'
import json, sys

blobs = json.load(open(sys.argv[1]))["blobs"]
by_path = {b["path"]: b for b in blobs}
sql = by_path.get("database/prod.sql")
if sql is None or sql.get("lfs_candidate") is not True:
    print(f"FAIL: prod.sql lfs_candidate: {sql}", file=sys.stderr)
    sys.exit(1)
readme = by_path.get("README.md")
if readme is None or readme.get("lfs_candidate") is not False:
    print(f"FAIL: README.md lfs_candidate: {readme}", file=sys.stderr)
    sys.exit(1)
print("ok: largest --json lfs_candidate (prod.sql true, README.md false)")
PYEOF
"$GW" largest | grep -q "Git LFS candidate" \
    || fail "largest human output missing LFS hint"
echo "ok: largest human output hints at LFS candidates"

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
# Full oids as keys: 7-hex prefixes collide often enough at this object
# count (birthday paradox) to flake the check.
oid_paths = {}
for line in out.splitlines():
    parts = line.split(" ", 1)
    if len(parts) == 2:
        oid_paths[parts[0]] = parts[1]
missing = 0
for b in blobs:
    p = b["path"]
    if p is None or oid_paths.get(b["oid"]) != p:
        missing += 1
        if missing <= 3:
            print(f"bad path: {b['oid'][:7]} tool={p} oracle={oid_paths.get(b['oid'])}",
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
"$GW" summary --repo "$REPO" --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['objects']['blob']['count'] == 0
print('ok: empty repo')"

# --- fixture: sha256 object format ---------------------------------------------
# Guarded: git gained --object-format=sha256 in 2.29, but some distro builds
# lack it. Skips cleanly when unsupported.
REPO="$FIXTURES/sha256"
if git init -q -b main --object-format=sha256 "$REPO" 2>/dev/null; then
    cd "$REPO"
    git config user.email test@example.com
    git config user.name Test
    head -c 1000000 /dev/urandom > big.bin
    echo small > README.md
    git add -A && git commit -qm one
    head -c 500000 /dev/urandom > historical.bin
    git add -A && git commit -qm two
    git rm -q historical.bin
    git commit -qm "remove historical.bin"
    git tag -a v1.0 -m "release"
    git gc -q

    # Pack idx parsing (32-byte oids, 64-byte checksum trailer): counts and
    # logical sizes must match the oracle.
    "$GW" objects --json > "$FIXTURES/sha256_objects.json"
    python3 - "$FIXTURES/sha256_objects.json" <<'PYEOF'
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
        print(f"FAIL sha256 {t}: oracle {o}, got {got}", file=sys.stderr)
        sys.exit(1)
print("ok: sha256 objects match git cat-file oracle (packed)")
PYEOF

    # explain by path, full 64-hex oid, and prefix all resolve.
    "$GW" explain README.md --json > "$FIXTURES/sha256_explain.json"
    python3 - "$FIXTURES/sha256_explain.json" <<'PYEOF'
import json, sys

d = json.load(open(sys.argv[1]))
if d["type"] != "blob" or not d["reachable"]:
    print(f"FAIL: sha256 explain README.md: {d}", file=sys.stderr)
    sys.exit(1)
if "refs/heads/main" not in d["retained_by"] or "refs/tags/v1.0" not in d["retained_by"]:
    print(f"FAIL: sha256 retained_by: {d['retained_by']}", file=sys.stderr)
    sys.exit(1)
if d["introduced"] is None:
    print(f"FAIL: sha256 introduced missing: {d}", file=sys.stderr)
    sys.exit(1)
print("ok: sha256 explain by path (json)")
PYEOF

    README_OID=$(git rev-parse 'HEAD:README.md')
    case "$README_OID" in
        ????????????????????????????????????????????????????????????????*) ;;
        *) fail "sha256 repo did not produce a 64-hex oid: $README_OID" ;;
    esac
    "$GW" explain "$README_OID" --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['logical_bytes'] == 6, d
print('ok: sha256 explain by full oid')"
    SHORT_OID=$(printf '%s' "$README_OID" | cut -c1-8)
    "$GW" explain "$SHORT_OID" --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['logical_bytes'] == 6, d
print('ok: sha256 explain by abbreviated oid')"

    "$GW" largest --limit 5 --json | python3 -c "
import json, sys
blobs = json.load(sys.stdin)['blobs']
assert blobs[0]['logical_bytes'] == 1000000, blobs
assert any(b['status'] == 'historical' for b in blobs), blobs
print('ok: sha256 largest (packed)')"
else
    echo "skip: git lacks --object-format=sha256"
fi

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

# --- explain remediation playbook ------------------------------------------------
cd "$FIXTURES/packed"

# Historical blob: history-rewrite verdict with exact filter-repo/BFG commands.
"$GW" explain database/prod.sql --json > "$FIXTURES/explain_remediation.json"
python3 - "$FIXTURES/explain_remediation.json" <<'PYEOF'
import json, sys

r = json.load(open(sys.argv[1]))["remediation"]
check = lambda cond, msg: (print(f"FAIL: {msg}: {r}", file=sys.stderr), sys.exit(1)) if not cond else None
check(r["verdict"] == "history_rewrite", "verdict")
check(set(r) == {"verdict", "commands", "caveat", "lfs"}, "remediation keys")
cmds = {c["tool"]: c["command"] for c in r["commands"]}
check("git-filter-repo" in cmds, "filter-repo command present")
check("--invert-paths --path 'database/prod.sql'" in cmds["git-filter-repo"], "filter-repo args")
check(cmds.get("BFG Repo-Cleaner") == "bfg --delete-files prod.sql", "bfg command")
check(r["caveat"] is not None and "rewrites history" in r["caveat"].lower(), "caveat")
check("lfs" in r, "lfs field present")
print("ok: explain remediation for historical blob (json)")
PYEOF
"$GW" explain database/prod.sql | grep -q "git filter-repo --invert-paths --path 'database/prod.sql'" \
    || fail "explain human output missing filter-repo command"
"$GW" explain database/prod.sql | grep -q "bfg --delete-files prod.sql" \
    || fail "explain human output missing bfg command"
"$GW" explain database/prod.sql | grep -qi "rewrites history" \
    || fail "explain human output missing rewrite caveat"
echo "ok: explain remediation human output (historical)"

# Unreachable blob: gc verdict with reflog expire + aggressive gc.
DANGLING=$(cat "$FIXTURES/dangling_oid")
"$GW" explain "$DANGLING" --json > "$FIXTURES/explain_gc.json"
python3 - "$FIXTURES/explain_gc.json" <<'PYEOF'
import json, sys

r = json.load(open(sys.argv[1]))["remediation"]
check = lambda cond, msg: (print(f"FAIL: {msg}: {r}", file=sys.stderr), sys.exit(1)) if not cond else None
check(r["verdict"] == "gc", "verdict")
check(len(r["commands"]) == 1, "one command")
check("git reflog expire --expire=now --all && git gc --prune=now --aggressive"
      == r["commands"][0]["command"], "gc command")
check(r["caveat"] is None, "no caveat for gc")
check(r["lfs"] is None, "no lfs for unreachable")
print("ok: explain remediation for unreachable blob (json)")
PYEOF
"$GW" explain "$DANGLING" | grep -q "git gc --prune=now --aggressive" \
    || fail "explain human output missing gc command"
echo "ok: explain remediation human output (unreachable)"

# Current blob with a known-binary extension: LFS migration suggestion.
"$GW" explain assets/demo.mov --json | python3 -c "
import json, sys
r = json.load(sys.stdin)['remediation']
assert r['verdict'] == 'none', r
assert r['lfs'] is not None, r
assert r['lfs']['pattern'] == '*.mov', r
assert r['lfs']['command'] == \"git lfs migrate import --include='*.mov' --everything\", r
print('ok: explain lfs recommendation for current blob (json)')"
"$GW" explain assets/demo.mov | grep -qF "git lfs migrate import --include='*.mov' --everything" \
    || fail "explain human output missing lfs migrate suggestion"
echo "ok: explain lfs recommendation human output (current)"

# --- summary completion ----------------------------------------------------------
"$GW" --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert 'unreachable_bytes' in d, d.keys()
print('ok: summary json has unreachable_bytes')"
"$GW" | grep -q "Largest contributor:" || fail "summary missing Largest contributor"
"$GW" | grep -q "git-weight explain" || fail "summary missing explain hint"
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

# --- check: CI threshold gating ---------------------------------------------------
cd "$FIXTURES/packed"

# (a) generous limits pass with exit 0.
set +e
"$GW" check --max-size 1GB --max-historical 10MB --max-unreachable 10MB --max-blob 10MB >/dev/null 2>&1
CODE=$?
set -e
[ "$CODE" -eq 0 ] || fail "expected exit 0 for generous limits, got $CODE"
echo "ok: check passes with generous limits (exit 0)"

# (b) tiny limits fail with exit 6.
set +e
"$GW" check --max-size 1KB >/dev/null 2>&1
CODE=$?
set -e
[ "$CODE" -eq 6 ] || fail "expected exit 6 for exceeded threshold, got $CODE"
echo "ok: check fails with tiny limits (exit 6)"

# (c) human output lists thresholds and the verdict.
"$GW" check --max-size 1KB 2>/dev/null | grep -q "max-size" || fail "check human output missing threshold row"
"$GW" check --max-size 1KB 2>/dev/null | grep -q "Verdict: FAIL" || fail "check human output missing FAIL verdict"
"$GW" check --max-blob 10MB 2>/dev/null | grep -q "Verdict: ok" || fail "check human output missing ok verdict"
echo "ok: check human output (thresholds + verdict)"

# (d) JSON shape, with actuals cross-checked against the oracle. A failing
# check exits 6 in JSON mode too.
set +e
"$GW" check --max-size 1GB --max-blob 1KB --json > "$FIXTURES/check.json"
CODE=$?
set -e
[ "$CODE" -eq 6 ] || fail "expected exit 6 for failing check --json, got $CODE"
python3 - "$FIXTURES/check.json" <<'PYEOF'
import json, subprocess, sys

d = json.load(open(sys.argv[1]))
check = lambda cond, msg: (print(f"FAIL: {msg}: {d}", file=sys.stderr), sys.exit(1)) if not cond else None
check("repository" in d and "git_dir" in d["repository"], "repository identity")
ts = {t["name"]: t for t in d["thresholds"]}
check(set(ts) == {"max-size", "max-blob"}, "threshold names")
for t in ts.values():
    check(set(t) == {"name", "limit", "actual", "ok"}, "threshold keys")
    check(t["ok"] == (t["actual"] <= t["limit"]), "ok semantics")
check(ts["max-size"]["ok"] is True, "max-size should pass at 1GB")
# Largest blob oracle: the 3 MB database/prod.sql from the fixture.
check(ts["max-blob"]["actual"] == 3000000, "max-blob actual")
check(ts["max-blob"]["ok"] is False, "max-blob should fail at 1KB")
check(d["ok"] is False, "overall ok")
print("ok: check --json shape and values")
PYEOF

# (e) missing thresholds are invalid arguments.
set +e
"$GW" check >/dev/null 2>&1
CODE=$?
set -e
[ "$CODE" -eq 2 ] || fail "expected exit 2 for check without thresholds, got $CODE"
set +e
"$GW" check --max-size >/dev/null 2>&1
CODE=$?
set -e
[ "$CODE" -eq 2 ] || fail "expected exit 2 for --max-size without value, got $CODE"
echo "ok: check error exit codes (2 no thresholds, 2 missing value)"

# --- dupes: duplicate content detection (spec §36) -------------------------------
REPO="$FIXTURES/dupes"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main
git config user.email test@example.com
git config user.name Test
head -c 100000 /dev/urandom > shared.bin
mkdir -p keep bak
cp shared.bin keep/copy.bin
cp shared.bin bak/old.bin
git add -A && git commit -qm "add copies"
git rm -q -r bak
git commit -qm "remove bak"

# A blob living at 3 paths across HEAD+history: one group, sorted paths,
# wasted = size * (count - 1).
SHARED_OID=$(git rev-parse HEAD:shared.bin)
"$GW" dupes --json > "$FIXTURES/dupes.json"
python3 - "$FIXTURES/dupes.json" "$SHARED_OID" <<'PYEOF'
import json, subprocess, sys

d = json.load(open(sys.argv[1]))
gs = d["dupes"]
if len(gs) != 1:
    print(f"FAIL: expected 1 group, got {gs}", file=sys.stderr)
    sys.exit(1)
g = gs[0]
if g["oid"] != sys.argv[2]:
    print(f"FAIL: oid {g['oid']} != {sys.argv[2]}", file=sys.stderr)
    sys.exit(1)
if g["size"] != 100000 or g["path_count"] != 3 or g["wasted_bytes"] != 200000:
    print(f"FAIL: bad group: {g}", file=sys.stderr)
    sys.exit(1)
if g["paths"] != sorted(g["paths"]) or set(g["paths"]) != {
        "shared.bin", "keep/copy.bin", "bak/old.bin"}:
    print(f"FAIL: bad paths: {g['paths']}", file=sys.stderr)
    sys.exit(1)
if g["truncated"] is not False or d["total_wasted_bytes"] != 200000:
    print(f"FAIL: bad flags: {d}", file=sys.stderr)
    sys.exit(1)
# Oracle: every listed path existed at some point (git log name-only lists
# paths touched by any commit; rev-list --objects collapses duplicate oids
# to a single path, so it cannot serve here).
out = subprocess.check_output(
    ["git", "log", "--all", "--pretty=format:", "--name-only"]).decode()
have = {p for p in out.splitlines() if p}
for p in g["paths"]:
    if p not in have:
        print(f"FAIL: path {p} never existed", file=sys.stderr)
        sys.exit(1)
print("ok: dupes group (oid, size, 3 sorted paths, wasted bytes)")
PYEOF

# --current counts only HEAD paths; --historical excludes blobs still at HEAD.
"$GW" dupes --current --json | python3 -c "
import json, sys
g = json.load(sys.stdin)['dupes'][0]
assert g['path_count'] == 2 and g['wasted_bytes'] == 100000, g
assert g['paths'] == ['keep/copy.bin', 'shared.bin'], g
print('ok: dupes --current limits to HEAD paths')"
"$GW" dupes --historical --json | python3 -c "
import json, sys
assert json.load(sys.stdin)['dupes'] == [], 'blob still at HEAD, no historical groups'
print('ok: dupes --historical empty for current blob')"

# A fully removed dupe pair shows up under --historical.
head -c 50000 /dev/urandom > gone.bin
mkdir -p dup
cp gone.bin dup/x.bin
cp gone.bin dup/y.bin
git add -A && git commit -qm "add gone pair"
git rm -q -r dup gone.bin
git commit -qm "remove gone pair"
"$GW" dupes --historical --json | python3 -c "
import json, sys
gs = json.load(sys.stdin)['dupes']
assert len(gs) == 1 and gs[0]['size'] == 50000 and gs[0]['path_count'] == 3, gs
assert gs[0]['wasted_bytes'] == 100000, gs
assert sorted(gs[0]['paths']) == ['dup/x.bin', 'dup/y.bin', 'gone.bin'], gs
print('ok: dupes --historical finds fully removed dupe group')"

# --min-size and --limit behave.
"$GW" dupes --min-size 1MB --json | python3 -c "
import json, sys
assert json.load(sys.stdin)['dupes'] == []
print('ok: dupes --min-size filters small groups')"
"$GW" dupes --limit 1 --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert len(d['dupes']) == 1
assert d['total_wasted_bytes'] == d['dupes'][0]['wasted_bytes']
print('ok: dupes --limit')"
"$GW" dupes | grep -q "Total reclaimable" || fail "dupes human output missing total"
echo "ok: dupes human output"

# --- growth: repository growth by month (spec §36) ------------------------------
REPO="$FIXTURES/growth"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main
git config user.email test@example.com
git config user.name Test
commit_at() {
    # commit_at <date> <file> <size>
    export GIT_COMMITTER_DATE="$1T12:00:00+00:00" GIT_AUTHOR_DATE="$1T12:00:00+00:00"
    head -c "$3" /dev/urandom > "$2"
    git add -A && git commit -qm "add $2"
    unset GIT_COMMITTER_DATE GIT_AUTHOR_DATE
}
commit_at 2020-01-15 jan.bin 1000000
commit_at 2020-03-15 mar.bin 2000000
# A modification in April replaces jan.bin: only the new blob counts.
commit_at 2020-04-10 jan.bin 4000000
commit_at 2021-02-15 feb.bin 8000000

"$GW" growth --json > "$FIXTURES/growth.json"
python3 - "$FIXTURES/growth.json" <<'PYEOF'
import json, sys

d = json.load(open(sys.argv[1]))
buckets = {b["month"]: b for b in d["buckets"]}
want = {
    "2020-01": (1000000, 1000000),
    "2020-03": (2000000, 3000000),
    "2020-04": (4000000, 7000000),
    "2021-02": (8000000, 15000000),
}
if set(buckets) != set(want):
    print(f"FAIL: months {sorted(buckets)} != {sorted(want)}", file=sys.stderr)
    sys.exit(1)
for m, (intro, cum) in want.items():
    b = buckets[m]
    if b["introduced_bytes"] != intro or b["cumulative_bytes"] != cum:
        print(f"FAIL: {m}: got {b}, want intro={intro} cum={cum}", file=sys.stderr)
        sys.exit(1)
if d["total_introduced_bytes"] != 15000000:
    print(f"FAIL: total {d['total_introduced_bytes']}", file=sys.stderr)
    sys.exit(1)
print("ok: growth buckets (introduced + cumulative by month)")
PYEOF

"$GW" growth --months 2 --json | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert [b['month'] for b in d['buckets']] == ['2020-04', '2021-02'], d
assert d['total_introduced_bytes'] == 15000000, d
print('ok: growth --months 2 (last buckets, full total)')"
"$GW" growth | grep -q "CUMULATIVE" || fail "growth human output missing table"
echo "ok: growth human output"

# check --max-growth gates on the most recent month (2021-02: 8 MB).
set +e
"$GW" check --max-growth 3MB >/dev/null 2>&1
CODE=$?
set -e
[ "$CODE" -eq 6 ] || fail "expected exit 6 for --max-growth 3MB, got $CODE"
set +e
"$GW" check --max-growth 10MB >/dev/null 2>&1
CODE=$?
set -e
[ "$CODE" -eq 0 ] || fail "expected exit 0 for --max-growth 10MB, got $CODE"
echo "ok: check --max-growth exit codes (6 over, 0 under)"
"$GW" check --max-growth 3MB --json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
ts = {t['name']: t for t in d['thresholds']}
assert set(ts) == {'max-growth'}, d
assert ts['max-growth']['actual'] == 8000000 and ts['max-growth']['ok'] is False, d
assert d['ok'] is False
print('ok: check --max-growth --json (actual = latest month)')"

# --- deep pack stats (spec §6.6) -------------------------------------------------
cd "$FIXTURES/delta"

# Per-pack delta stats must match the git verify-pack oracle.
"$GW" packs --json > "$FIXTURES/packs.json"
python3 - "$FIXTURES/packs.json" <<PYEOF
import json, sys

d = json.load(open(sys.argv[1]))
packs = d["packs"]
if len(packs) != 1:
    print(f"FAIL: expected 1 pack, got {len(packs)}", file=sys.stderr)
    sys.exit(1)
p = packs[0]
if p["delta_count"] != $DELTA_COUNT:
    print(f"FAIL: delta_count {p['delta_count']} != oracle $DELTA_COUNT",
          file=sys.stderr)
    sys.exit(1)
if p["max_delta_depth"] < 1 or p["mean_delta_depth"] < 1:
    print(f"FAIL: bad delta depths: {p}", file=sys.stderr)
    sys.exit(1)
if p["delta_physical_bytes"] == 0 or p["delta_physical_bytes"] >= p["pack_bytes"]:
    print(f"FAIL: bad delta physical bytes: {p}", file=sys.stderr)
    sys.exit(1)
if p["delta_logical_bytes"] <= p["delta_physical_bytes"]:
    print(f"FAIL: delta logical should exceed physical: {p}", file=sys.stderr)
    sys.exit(1)
# Existing fields must be unchanged.
if set(("name", "objects", "pack_bytes")) - set(p):
    print(f"FAIL: missing base pack fields: {p}", file=sys.stderr)
    sys.exit(1)
s = d["summary"]
if s["pack_count"] != 1 or s["total_delta_count"] != $DELTA_COUNT:
    print(f"FAIL: bad summary: {s}", file=sys.stderr)
    sys.exit(1)
if s["repack_hint"] is not None:
    print(f"FAIL: single healthy pack should not hint repack: {s}", file=sys.stderr)
    sys.exit(1)
print("ok: packs --json delta stats match verify-pack oracle")
PYEOF
"$GW" packs | grep -q "Delta compression" || fail "packs human output missing delta section"
"$GW" packs | grep -q "Pack fragmentation" || fail "packs human output missing fragmentation section"
echo "ok: packs human output (delta + fragmentation sections)"

# Fragmentation: many small packs trigger the repack hint. Packs are built
# with one `git pack-objects` call per blob: modern `git repack` consolidates
# incremental packs on its own schedule (observed mid-test on git 2.55 CI),
# which would make this fixture's layout nondeterministic.
REPO="$FIXTURES/multipack"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main
git config user.email test@example.com
git config user.name Test
for i in 1 2 3 4 5; do
    head -c 200000 /dev/urandom > "blob$i.bin"
done
git add -A
git commit -qm "blobs"
for i in 1 2 3 4 5; do
    oid=$(git rev-parse "HEAD:blob$i.bin")
    echo "$oid" | git pack-objects -q .git/objects/pack/pack > /dev/null
done
PACK_N=$(ls .git/objects/pack/*.pack | wc -l | tr -d ' ')
[ "$PACK_N" -ge 4 ] || fail "multipack fixture has $PACK_N packs"
# Diagnostic: the pack directory listing, for forensics when platform git
# versions lay out packs differently than this script expects.
ls -la .git/objects/pack/ || true
"$GW" packs --json > "$FIXTURES/multipack.json"
python3 - "$FIXTURES/multipack.json" "$PACK_N" <<'PYEOF'
import json, sys

d = json.load(open(sys.argv[1]))
s = d["summary"]
if s["pack_count"] != int(sys.argv[2]):
    print(f"FAIL: pack_count {s['pack_count']} != {sys.argv[2]}", file=sys.stderr)
    sys.exit(1)
if not s["repack_hint"] or "repack" not in s["repack_hint"]:
    print(f"FAIL: expected repack hint for fragmented packs: {s}", file=sys.stderr)
    sys.exit(1)
if s["smallest_pack"]["bytes"] > s["largest_pack"]["bytes"]:
    print(f"FAIL: smallest > largest: {s}", file=sys.stderr)
    sys.exit(1)
print(f"ok: fragmentation summary ({s['pack_count']} packs, repack hint)")
PYEOF
PACKS_HUMAN=$("$GW" packs) || fail "packs command exited non-zero"
if ! printf '%s\n' "$PACKS_HUMAN" | grep -q "hint: "; then
    printf '%s\n' "$PACKS_HUMAN"
    ls -la .git/objects/pack/ || true
    fail "packs human output missing repack hint"
fi
echo "ok: packs human repack hint"

echo "ALL INTEGRATION CHECKS PASSED"
