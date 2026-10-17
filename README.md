# debian-ci

Shared GitHub Actions workflow and shell helpers for the Debian package
repositories under `slopization/`.

The package repositories keep only:

- their Debian source tree (`debian/` plus the package sources);
- their `README.md`;
- two small caller workflows in `.github/workflows/`.

Everything else — installing the build tooling, creating the sbuild chroot,
building the source package, building the binaries, validating the payload,
signing, and publishing to `deb-s3` — lives here.

## Caller workflows

Build on every push (and pull request), never publish:

```yaml
name: build

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  build:
    uses: slopization/debian-ci/.github/workflows/package.yml@v1
    with:
      mode: native
      validate: dkms
```

Publish only when a maintainer presses **Run workflow**:

```yaml
name: publish

on:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  publish:
    uses: slopization/debian-ci/.github/workflows/package.yml@v1
    with:
      mode: native
      validate: dkms
      publish: true
    secrets:
      DEB_REPO_SIGNING_PRIVATE_KEY: ${{ secrets.DEB_REPO_SIGNING_PRIVATE_KEY }}
      DEB_REPO_SIGNING_PASSPHRASE: ${{ secrets.DEB_REPO_SIGNING_PASSPHRASE }}
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_SESSION_TOKEN: ${{ secrets.AWS_SESSION_TOKEN }}
```

There is no branch that publishes automatically. Publishing is a manual
`workflow_dispatch` run on `main`; the workflow rebuilds the current `main`
and then signs/publishes. No `concurrency` lock or other publish gate is
defined here.

## Modes

| `mode` | Use for | What CI does |
| --- | --- | --- |
| `native` | `3.0 (native)` packages | `dpkg-source -b` in the checkout, then sbuild |
| `gbp` | recipe-only `3.0 (quilt)` packages | `uscan` + `gbp import-orig` into a temporary worktree, then sbuild |

`gbp` mode never pushes branches or tags. It uses private scratch branches
(`ci/build`, `ci/upstream`) and a `ci/upstream/*` tag inside the ephemeral
worktree only. The package repository can therefore stay a one-branch recipe
repository.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `mode` | `native` | `native` or `gbp` |
| `validate` | `none` | `none`, `dkms`, or `firmware` |
| `firmware-path` | | Absolute firmware path inside the package |
| `firmware-sha256` | | Expected lowercase SHA-256 |
| `forbid-filename` | | Basename that must not appear in the payload |
| `publish` | `false` | Sign and publish with deb-s3 |
| `suite` | `trixie` | sbuild/mmdebstrap suite |
| `mirror` | `http://deb.debian.org/debian` | Debian mirror |
| `artifact-name` | `<repo>-<sha>` | Uploaded artifact name |

Publishing reads the caller repository's variables (`vars.DEB_S3_*`) and the
secrets passed by the caller (`AWS_*`, `DEB_REPO_SIGNING_*`). Variables are
resolved against the caller repository, so each package repository keeps its
own publish configuration. Organization-level variables are inherited too, if
you later move the repositories into an organization.

## How the CI checkout works

The reusable workflow checks out the caller's package repository into `pkg/`
and then checks out **its own** repository into `.ci/` using
`job.workflow_repository` and `job.workflow_sha`. That means the scripts always
match the exact commit of the workflow that was called — there is no second
ref to keep in sync.

`.ci/` is outside `pkg/`, so it cannot leak into a native source tarball.

## Versioning

Callers pin `@v1`. Keep `v1` as a moving tag for backwards-compatible changes,
or protect it and cut immutable `v1.x.y` tags for each release. Because the
workflow checks out its own SHA, a caller that pins a commit or immutable tag
runs exactly the scripts from that commit.

The shared repository must be public (or readable by the caller repositories'
`GITHUB_TOKEN`) for the self-checkout to work. All three current package
repositories are public.

## Local checks

```sh
shellcheck -x scripts/*.sh
actionlint
```

The scripts are also usable locally. Run `prepare-gbp-tree.sh` from the recipe
checkout; pass `--workspace /tmp/build` and `--download-dir /tmp`.
