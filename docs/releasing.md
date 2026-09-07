# Releasing git-weight

The pipeline follows Comanda's GitHub-release + separate Homebrew-tap model.
GitHub Actions builds Zig binaries directly, since this project does not use Go.

## One-time setup

1. The public [`kris-hansen/homebrew-git-weight`](https://github.com/kris-hansen/homebrew-git-weight)
   tap has been created and initialized with a README. To recreate it if needed
   (the tap checkout requires an existing default branch):

   ```sh
   gh repo create kris-hansen/homebrew-git-weight --public --add-readme \
     --description 'Homebrew tap for git-weight'
   ```

2. Create a fine-grained GitHub personal access token scoped to that tap with
   **Contents: read and write**. Add it to **git-weight**, using the same secret
   name as Comanda:

   ```sh
   gh secret set TAP_GITHUB_TOKEN --repo kris-hansen/git-weight
   ```

   This prompts for the token; do not commit it. GitHub's built-in `GITHUB_TOKEN`
   publishes releases in git-weight but cannot push to the separate tap.
   Comanda's existing secret cannot be read back or copied through GitHub's API.

3. Merge/push the workflow and release scripts to `main`. Ensure GitHub Actions
   is enabled and the CI workflow passes. No release occurs on a normal branch push.

## Publish a version

Update `.version` in `build.zig.zon` for source builds, then commit it before tagging:

```sh
git tag -a v0.4.0 -m 'Release v0.4.0'
git push origin v0.4.0
```

The release tag is authoritative for packaged binaries: the workflow passes
`-Dversion=0.4.0` to Zig and checks the resulting `--version` output. Tags must
use `vMAJOR.MINOR.PATCH` or a prerelease such as `v0.5.0-rc.1`.

You can also run **Actions → Release → Run workflow** with an existing tag.
The workflow resolves that tag to a commit before building; the selected workflow
branch is not used as the binary's source.

For each release, Actions:

1. Validates the tag and checks that stable releases have a tap token.
2. Runs unit tests and Git-oracle integration checks on native macOS and Linux
   runners for both Intel and ARM64.
3. Builds with Zig 0.16.0, `ReleaseFast`, and baseline CPU instructions. macOS
   binaries target macOS 14+; Linux binaries use musl for portable static linking.
4. Publishes four `git-weight-{darwin,linux}-{amd64,arm64}.tar.gz` archives,
   `checksums.txt`, and the generated `git-weight.rb` formula in a GitHub release.
   Every archive contains the binary, LICENSE, and README.
5. For stable versions, commits `Formula/git-weight.rb` to the tap using
   `TAP_GITHUB_TOKEN`. Prereleases never change the stable Homebrew formula.

After the first stable release:

```sh
brew install kris-hansen/git-weight/git-weight
brew test kris-hansen/git-weight/git-weight
git weight --version
```

Users update with `brew update && brew upgrade git-weight`.

## Recovery

If the tap update fails after publication, fix the tap/token issue and use
**Re-run failed jobs**. The tap job downloads the formula from the published
release, so it uses exactly the hashes of the original archives. Re-running
that job is safe when the formula is already current.

Publishing intentionally refuses to overwrite an existing release. If uploading
fails and leaves an unpublished draft, delete that draft before retrying the
publish job. Do not replace published assets; ship a new version instead.
Dispatch releases in version order: manually releasing an older stable tag also
updates the tap to that older version. Only one release workflow runs at a time.

## Local validation

```sh
zig build test
zig build -Doptimize=ReleaseFast -Dversion=0.4.0
sh test/verify.sh
python3 -m unittest discover -s test -p 'test_release.py'
```

With all four archives in `dist/`, generate the exact release metadata locally:

```sh
python3 scripts/release.py package v0.4.0 dist
ruby -c dist/git-weight.rb
```

The build matrix uses [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
The generated formula uses Homebrew's [platform-specific dependencies and URLs](https://docs.brew.sh/Formula-Cookbook).
