# Releasing Kodo

Kodo follows the release-PR model used by Textbin and Shosai. Conventional PR
titles drive the next semantic version and changelog; maintainers review and
merge a generated release PR instead of creating tags or releases manually.

## One-time repository setup

Create and install a GitHub App for this repository with these permissions:

- Contents: read and write
- Pull requests: read and write

Create a GitHub Actions environment named `RELEASE` and add these secrets:

```text
RELEASE_APP_ID
RELEASE_APP_PRIVATE_KEY
```

The installation token is required because branch and tag pushes made with the
normal `GITHUB_TOKEN` do not trigger the downstream workflows in the release
chain.

Protect `main`, require pull requests, allow only squash merges, and configure
the squash commit subject to use the PR title. Require the stable **Validate
title** check so Conventional Commit calculation sees the reviewed title on
`main`.

Protect `release/next` so only the release App can force-push it. Protect `v*`
tags so only the App can create them and nobody can update or delete them.
Require the stable **CLI release gate** and **Server release gate** checks.
After the first image is published, make the `chaba-dev/kodo` package public in
GitHub package settings if it should be available without authentication.

## Automated flow

Every push to `main` refreshes one PR from `release/next`:

1. The latest reachable `v*` tag and Conventional Commit subjects determine the
   next stable SemVer version. Before the first tag, the checked-in synchronized
   version is used.
2. `mix.exs`, the Cargo workspace version, `Cargo.lock`, and `CHANGELOG.md` are
   updated together in `chore(release): vMAJOR.MINOR.PATCH`.
3. The release PR dry-runs all CLI archives, the shell installer, checksums, and
   both server image architectures. Packaged programs must report the PR
   version.
4. Merging the internal `release/next` PR creates an immutable tag at its merge
   commit after revalidating the title and both version sources.
5. The tag rebuilds final CLI artifacts, creates the GitHub Release and notes,
   then publishes the multi-architecture GHCR image from that immutable source.
6. The image receives exact-version and commit-SHA tags. Only the newest
   applicable stable release advances the major, minor, and `latest` aliases.
   GitHub OIDC records a provenance attestation for the image manifest.

Exact-version and full commit-SHA image tags are write-once. A publication
rerun reuses and re-attests their existing digest; it fails if either tag is
missing or if they disagree. Only the floating aliases may move. The Dockerfile
also pins its multi-architecture builder and runtime base image manifests.

Final artifacts are deliberately rebuilt from the tag; release-PR artifacts
are evidence for review, not publication inputs.

```text
main changes
    -> release/next PR
    -> vMAJOR.MINOR.PATCH tag
    -> GitHub Release with CLI archives, installer, checksums, and notes
    -> ghcr.io/chaba-dev/kodo (linux/amd64 and linux/arm64)
```

## Published CLI platforms

| Platform | Rust target | Archive |
|---|---|---|
| Linux x86-64 | `x86_64-unknown-linux-gnu` | `.tar.xz` |
| Linux ARM64 | `aarch64-unknown-linux-gnu` | `.tar.xz` |
| macOS Apple Silicon | `aarch64-apple-darwin` | `.tar.xz` |

Linux artifacts are built natively on Ubuntu 22.04 runners and require glibc
2.34 or newer. This is the MVP portability floor; use a source build on older
distributions.

Windows is not a release target because the confined process runner currently
uses Unix process groups and signals.

## Server image

The image starts `/app/bin/kodo start` as an unprivileged user. Supply the
production settings documented in the [operations guide](operations.org),
including `DATABASE_URL`, `SECRET_KEY_BASE`, `KODO_ARTIFACT_REVISION`, and the
monotonic `KODO_DEPLOYMENT_GENERATION`. Run migrations before starting the new
server revision:

```sh
docker run --rm \
  -e DATABASE_URL \
  -e SECRET_KEY_BASE \
  -e KODO_ARTIFACT_REVISION \
  -e KODO_DEPLOYMENT_GENERATION \
  ghcr.io/chaba-dev/kodo:MAJOR.MINOR.PATCH /app/bin/migrate
```

Use an exact version or digest in production. Floating aliases are convenience
references and are not immutable deployment identities.

## Local preview

The Nix development shell includes git-cliff. Preview the generated changelog
and next bump with:

```sh
make changelog
git cliff --bumped-version
```

Discard the rewritten changelog if the command was only a preview.
