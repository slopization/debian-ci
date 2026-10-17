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

Publishing reads `DEB_CREDENTIALS` (base64 JSON) when present, then falls back
to `vars.DEB_S3_*` and the individual `AWS_*` / `DEB_REPO_SIGNING_*` secrets.
Variables resolve from the caller repository and then its organization; one
organization-level secret can serve all three repositories. See
`admin/README.md`.

## Credentials

The preferred layout is one `DEB_CREDENTIALS` secret containing base64 JSON.
GitHub has no file-upload or multi-field credential form; this is the single
pasteable blob that gets closest to a credential file.

```sh
cp admin/credentials.json.example admin/credentials.json
chmod 600 admin/credentials.json
$EDITOR admin/credentials.json
./admin/set-credentials.sh --dry-run
./admin/set-credentials.sh
```

The JSON is a flat object keyed by environment variable name and covers
`DEB_S3_*`, the AWS values, and the repository signing key/passphrase. The
publish callers pass it as `DEB_CREDENTIALS`; the workflow decodes it, masks the
actual secrets, and exports the values to the remaining steps. Individual
organization/repository variables and secrets still work as fallbacks for keys
missing from the JSON.

`admin/credentials.json.example` is the template. The signing key can stay in a
separate file referenced by `DEB_REPO_SIGNING_PRIVATE_KEY_FILE`; the helper
embeds it and removes the `_FILE` key before uploading.

The native per-field alternative is documented in `admin/README.md`.

If the bucket is AWS S3 rather than Cloudflare R2, GitHub OIDC role assumption
can replace the long-lived AWS keys later.

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
