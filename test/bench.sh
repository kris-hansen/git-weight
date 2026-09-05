#!/bin/sh
# Benchmark git-weight against alternative tools (git plumbing, git-sizer).
#
# Usage: test/bench.sh REPO_DIR LABEL PATH [heavy]
#   REPO_DIR  repository to benchmark in
#   LABEL     short label for result files (e.g. comanda)
#   PATH      a tracked file path, used for explain/changed benchmarks
#   heavy     optional: include very slow alternatives (git fsck)
#
# Results land in bench-results/<LABEL>-*.json and a summary table is
# printed at the end (requires hyperfine, git-sizer, python3).

set -eu

REPO="$1"
LABEL="$2"
BPATH="$3"
TIER="${4:-light}"

GW="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/git-weight"
OUT="$(cd "$(dirname "$0")/.." && pwd)/bench-results"
mkdir -p "$OUT"

[ -x "$GW" ] || { echo "git-weight binary not found: $GW" >&2; exit 1; }
command -v hyperfine >/dev/null || { echo "hyperfine not installed" >&2; exit 1; }
command -v git-sizer >/dev/null || { echo "git-sizer not installed" >&2; exit 1; }

cd "$REPO"

if [ "$TIER" = heavy ]; then
    HF="hyperfine --warmup 1 --runs 3"
elif [ "$TIER" = huge ]; then
    HF="hyperfine --warmup 0 --runs 2"
else
    HF="hyperfine --warmup 2 --min-runs 10"
fi

bench() {
    name="$1"; shift
    echo "== $LABEL: $name"
    # shellcheck disable=SC2086
    $HF --export-json "$OUT/$LABEL-$name.json" "$@"
}

# Full-repository analysis: git-sizer is the closest competing tool.
bench summary \
    -n git-weight "$GW summary" \
    -n git-sizer "git-sizer --no-progress"

# Largest blobs in history: the classic rev-list | cat-file pipeline.
bench largest \
    -n git-weight "$GW largest" \
    -n git-plumbing "git rev-list --objects --all | git cat-file --batch-check='%(objectname) %(objecttype) %(objectsize)' | awk '\$2==\"blob\"' | sort -k3 -rn | head -20"

# Packfile statistics.
bench packs \
    -n git-weight "$GW packs" \
    -n git-plumbing "git verify-pack -v .git/objects/pack/*.idx >/dev/null"

# CI change detection (git diff --quiet answers via exit code; 1 = changed).
bench changed \
    -n git-weight "$GW changed '$BPATH'" \
    -n git-plumbing "git diff --quiet HEAD~1 HEAD -- '$BPATH' || [ \$? -eq 1 ]"

# Explain a path: nearest plumbing approximation is walking all commits
# touching the path.
bench explain \
    -n git-weight "$GW explain '$BPATH'" \
    -n git-plumbing "git log --all --format=%H -- '$BPATH' >/dev/null"

if [ "$TIER" = heavy ]; then
    bench unreachable \
        -n git-weight "$GW unreachable" \
        -n git-plumbing "git fsck --unreachable 2>/dev/null"
fi

python3 - "$LABEL" "$OUT" <<'EOF'
import glob, json, sys

label, out = sys.argv[1], sys.argv[2]
print(f"\n### {label}\n")
print("| benchmark | tool | mean | min | max | speedup |")
print("|---|---|---|---|---|---|")
for f in sorted(glob.glob(f"{out}/{label}-*.json")):
    bench = f.rsplit("/", 1)[1][len(label) + 1 : -5]
    results = json.load(open(f))["results"]
    for r in results:
        r["tool"] = r.get("name") or r["command"]
    gw = next((r["mean"] for r in results if r["tool"] == "git-weight"), None)
    for r in results:
        speedup = ""
        if gw and r["tool"] != "git-weight":
            speedup = f"git-weight {r['mean']/gw:.1f}x faster" if r["mean"] > gw else f"git-weight {gw/r['mean']:.1f}x SLOWER"
        print(f"| {bench} | {r['tool']} | {r['mean']*1000:.0f} ms | {r['min']*1000:.0f} ms | {r['max']*1000:.0f} ms | {speedup} |")
EOF
