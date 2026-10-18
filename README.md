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

Build on every push to `main`, never publish:

```yaml
name: build

on:
  push:
    branches: [main]
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
    if: github.ref == 'refs/heads/main'
    uses: slopization/debian-ci/.github/workflows/package.yml@v1
    with:
      mode: native
      validate: dkms
      publish: true
    secrets:
      DEB_CREDENTIALS: ${{ secrets.DEB_CREDENTIALS }}
      # Optional per-field fallbacks:
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
| `s3-bucket` | | Optional per-repository `DEB_S3_BUCKET` override |
| `s3-prefix` | | Optional per-repository `DEB_S3_PREFIX` override |

Publishing reads `DEB_CREDENTIALS` (base64 JSON) when present, then falls back
to `vars.DEB_S3_*` and the individual `AWS_*` / `DEB_REPO_SIGNING_*` secrets.
Variables resolve from the caller repository and then its organization; one
organization-level secret can serve all three repositories. See
`admin/README.md`.

## Credentials

One organization secret, `DEB_CREDENTIALS`, contains base64 of a minimal JSON
file. It covers only publishing:

```json
{
  "DEB_S3_BUCKET": "my-bucket",
  "DEB_S3_PREFIX": "debian/nanokvm",
  "DEB_S3_REGION": "auto",
  "DEB_S3_ENDPOINT": "https://<account_id>.r2.cloudflarestorage.com",
  "AWS_ACCESS_KEY_ID": "...",
  "AWS_SECRET_ACCESS_KEY": "...",
  "DEB_REPO_SIGNING_PRIVATE_KEY": "-----BEGIN PGP PRIVATE KEY BLOCK-----\n...",
  "DEB_REPO_SIGNING_PASSPHRASE": "...",
  "DEB_PACKAGE_SIGNING_PRIVATE_KEY": "-----BEGIN PGP PRIVATE KEY BLOCK-----\n...",
  "DEB_PACKAGE_SIGNING_PASSPHRASE": "..."
}
```

The codename is intentionally absent: CI is expected to build branches named
`debian/<codename>` and use `<codename>` as the APT suite. The branch workflow
is not implemented yet.

The package signing key is included for future `.dsc`/`.changes` signing. CI
currently uses only the repository key; keep an offline copy of the package key
for local `debsign`.

Generate the keys, put both inline keys in `admin/credentials.json`, and store
the secret:

```sh
./admin/generate-debian-keys.sh \
  --repo-uid 'NanoKVM APT Repository <repo@your-domain>' \
  --package-uid 'Your Name <you@your-domain>'

./admin/set-credentials.sh --dry-run
./admin/set-credentials.sh
```

See `admin/README.md` for the field list and the manual `base64 | gh secret set`
form.

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
