# Complexity scoring in GitHub Actions

`git-weight` has two complementary scores:

- `git-weight pr` measures the **changed work** between two commits. It counts
  additions, removals, changed files, branching changes, and observable
  complexity signals. Use it to give reviewers context about a PR.
- `git-weight complexity` measures the **active source tree at one commit**.
  Use it to track a repository snapshot over time, compare repositories under
  the same score version, and see whether complexity sprawl is increasing or
  decreasing. Deleted source no longer contributes to later snapshots.

Both commands are read-only and emit a single JSON line with `--json`. Their
`total_points` are **different units**: do not divide PR points by repository
points. To estimate a PR's effect on the repository, compare two
`complexity.total_points` snapshots and report the net change (and, if useful,
the percentage of the base snapshot). A PR can have substantial work points
while reducing the repository's active complexity.

## Minimal local use

```sh
# Current committed tree; uncommitted files are not included.
git-weight complexity --json

# A historical snapshot, if the commit or tag is still available locally.
git-weight complexity --rev v1.2.0 --json

# On a PR branch, use the merge base to avoid counting unrelated main changes.
base=$(git merge-base origin/main HEAD)
git-weight pr --base "$base" --to HEAD --json
git-weight complexity --rev "$base" --json
git-weight complexity --rev HEAD --json
```

`pr` defaults to `origin/main` (then `main`) and `HEAD`, but it does **not**
calculate the merge base itself. Explicit refs are preferable in CI.

## Copyable workflow

Save this as `.github/workflows/git-weight.yml` in the repository being scored.
It scores an open PR against its merge base, records snapshots before and after
the proposed change, and records the landed repository snapshot on every push
to `main`. On a normal single-PR merge, the push step also scores the actual
landed diff between the previous and new `main` commits.

```yaml
name: Git weight

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  score:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false

      - name: Install pinned git-weight release
        env:
          VERSION: v0.7.3
        run: |
          set -euo pipefail
          base="https://github.com/kris-hansen/git-weight/releases/download/${VERSION}"
          curl -fsSL --retry 3 "$base/git-weight-linux-amd64.tar.gz" \
            -o "$RUNNER_TEMP/git-weight-linux-amd64.tar.gz"
          curl -fsSL --retry 3 "$base/checksums.txt" \
            -o "$RUNNER_TEMP/checksums.txt"
          (cd "$RUNNER_TEMP" &&
            grep ' git-weight-linux-amd64.tar.gz$' checksums.txt | sha256sum -c -)
          tar -xzf "$RUNNER_TEMP/git-weight-linux-amd64.tar.gz" \
            -C "$RUNNER_TEMP" git-weight
          mkdir -p "$RUNNER_TEMP/bin"
          install -m 0755 "$RUNNER_TEMP/git-weight" "$RUNNER_TEMP/bin/git-weight"
          echo "$RUNNER_TEMP/bin" >> "$GITHUB_PATH"
          "$RUNNER_TEMP/bin/git-weight" --version

      - name: Score proposed PR
        if: github.event_name == 'pull_request'
        env:
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: |
          set -euo pipefail
          git cat-file -e "${BASE_SHA}^{commit}"
          git cat-file -e "${HEAD_SHA}^{commit}"
          merge_base=$(git merge-base "$BASE_SHA" "$HEAD_SHA")
          git-weight pr --base "$merge_base" --to "$HEAD_SHA" --json
          git-weight complexity --rev "$merge_base" --json
          git-weight complexity --rev "$HEAD_SHA" --json

      - name: Score landed main
        if: github.event_name == 'push'
        env:
          BEFORE_SHA: ${{ github.event.before }}
          AFTER_SHA: ${{ github.sha }}
        run: |
          set -euo pipefail
          git-weight complexity --rev "$AFTER_SHA" --json
          # On a normal merge push, this measures what actually landed.
          # A push containing multiple PRs is one combined change here.
          git cat-file -e "${BEFORE_SHA}^{commit}"
          git-weight pr --base "$BEFORE_SHA" --to "$AFTER_SHA" --json
          git-weight complexity --rev "$BEFORE_SHA" --json
```

`fetch-depth: 0` matters: shallow clones may omit the merge base or historical
commits. On `pull_request`, checkout normally points to GitHub's synthetic merge
commit; the workflow deliberately uses the event's PR head SHA instead. The PR
head is a parent of that synthetic commit. For fork PRs, the job needs only
read access; it does not execute code from the PR or use write credentials.
If your checkout policy differs, fetch the PR head ref before scoring.

The `push` event's `before` SHA is the previous branch tip for a normal push.
It may be unavailable after a force push or branch creation; in those cases,
skip the landed `pr` comparison and keep the `complexity` snapshot. Save full
base, head, pre-merge, and landed SHAs if you need later historical backfills:
squash/rebase merges can replace PR commits, and deleted branch objects may be
pruned. The CLI does not fetch GitHub PR metadata itself.

## Read and retain the results

- Each `--json` invocation writes one compact event to stdout. GitHub stores
  those lines in the job log. A log pipeline (for example, Datadog) must be
  configured separately to ingest GitHub Actions logs; printing JSON alone
  does not send telemetry to an external service.
- Record `score_version`, repository, commit SHA, event/PR ID, stage
  (`pre`, `post`, or `snapshot`), and timestamp with each event. The CLI
  provides score version and commit SHA; your pipeline supplies the rest.
- Compare only reports with the same score version. For trend charts, plot
  repository `total_points`, `structural_points`, source lines, and
  `structural_points_per_kloc` separately. Absolute points largely reflect
  size; density helps reveal sprawl without hiding the size baseline.
- For an individual PR, compare the two repository snapshots to find net
  stock change. The PR report measures changed work and is useful for review,
  but is not itself the delta in repository complexity.

`git-weight pr --max-points N` is an optional gate: it exits 6 when its PR
`total_points` exceeds `N`. Start by observing and calibrating against your own
history. Static signals cannot tell whether complexity is justified; reviewers
must make that judgment. `git-weight complexity` has no threshold flag in
v0.7.3; evaluate its JSON externally if you want a repository-level policy.

See the [scoring formulas and limitations](../README.md#pr-complexity-experimental)
in the README. The scores are proxies for observable code properties, not
measures of engineer productivity or semantic difficulty.
