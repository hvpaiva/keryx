# Maintenance

## Release infrastructure

Four settings outside the repository protect a release.

- The `main` ruleset takes changes only through pull requests, with the CI checks passing on a
  branch up to date with `main` and every commit signed. It refuses force pushes and deletion, and
  nobody bypasses it. Pull requests merge as merge commits, so signed commits reach `main`
  unchanged.
- The `tags` ruleset lets only repository administrators create, move or delete `v*` tags.
- The `release` environment accepts only `v*` tags.
- The RubyGems trusted publisher names repository `hvpaiva/keryx`, workflow `release.yml` and
  environment `release`. Change it on RubyGems whenever one of them changes.

## Release

`bin/release` releases the version that `lib/keryx/version.rb` names and never changes it. It needs
a clean `main` that matches `origin/main`, `gh` signed in, and git set up to sign commits and tags,
since it signs both whatever the configuration says.

```sh
bin/release prepare
```

This dates the `## [Unreleased]` section of `CHANGELOG.md` with the version in UTC, commits it on
a `release/vX.Y.Z` branch and opens the pull request. Like `bin/release tag`, it first fetches
`main` and every tag of origin into the clone, and it refuses a version that `CHANGELOG.md` on
`origin/main` already dates or that has a tag in the clone or on origin. Once CI passes and the
pull request merges, update `main` and tag it.

```sh
git pull
bin/release tag
```

This signs `vX.Y.Z` on `main` and pushes it, and the [release workflow](../.github/workflows/release.yml)
takes over. The workflow publishes what `bin/release notes VERSION` prints, the `CHANGELOG.md`
section of VERSION, as the release notes, and `bin/release -h` prints the usage.

1. It runs CI on the tagged commit.
2. It checks that the tag is on `main`, matches `lib/keryx/version.rb` and has a section in
   `CHANGELOG.md`.
3. It builds the gem once from the checkout, since the gem packages tracked files only, records
   its SHA-256 and attests its provenance.
4. In the `release` environment, it pushes the gem to RubyGems with a short-lived credential from
   trusted publishing.
5. It creates the GitHub release with the changelog section, the gem and `SHA256SUMS`.

No release job installs the bundle. Building and pushing a gem need only RubyGems, so no
development gem runs next to the credential. `rake release` and Bundler's `release:guard_clean`,
`release:source_control_push` and `release:rubygem_push`, which would tag and push the gem from your
machine, refuse.

## Rehearse

```sh
gh workflow run release.yml --ref main
```

A manual run goes through CI and the build, and stops before the attestation, which would record an
unpublished gem in Sigstore's public log for good. It cannot check the trusted publisher either,
and since it runs on a branch rather than a tag, it skips the checks of step 2 as well.

## Recover

If a command of `bin/release prepare` fails, it names the command after what git or gh printed,
and the clone stays where it stopped. Fix the cause and run `bin/release prepare` again, on the
release branch it left you on or on a clean `main`. It goes on from there: it reuses the release
branch, commits the dated changelog unless the branch holds that commit already, pushes the branch
unless origin has it, and opens the pull request unless one is open. It refuses a release branch
that holds anything besides that commit, one that origin holds at another commit, and one that
`origin/main` moved past, since its changelog would miss what merged in between. To start over,
discard the dated changelog with `git restore CHANGELOG.md` if the commit never happened,
switch to `main` and pull, delete the branch with `git branch -D release/vX.Y.Z`, and if it reached
origin, close its pull request and delete it there with `git push origin --delete release/vX.Y.Z`.

If `bin/release tag` signs the tag but cannot push it, the tag stays in your clone and the next
run refuses it. Delete it with `git tag -d vX.Y.Z` and run `bin/release tag` again, which signs it
anew on the `main` it checked.

If the workflow fails before the gem reaches RubyGems, fix the cause and re-run the failed jobs.
When the tagged commit itself is wrong, an administrator deletes the tag on origin. Your clone keeps
its copy, since `bin/release` fetches tags without pruning them, so delete it there too with
`git tag -d vX.Y.Z` before `bin/release tag` runs again once the fix is on `main`.

RubyGems never accepts the same version twice. If only the GitHub release failed, re-run that job
alone.

## Verify a download

Download the gem and `SHA256SUMS` from the GitHub release.

```sh
sha256sum --check SHA256SUMS
gh attestation verify keryx-X.Y.Z.gem --repo hvpaiva/keryx
```

On macOS, use `shasum -a 256 --check SHA256SUMS`.
