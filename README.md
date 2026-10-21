# debian-ci

Shared Debian builds plus a small [Cloudflare GitHub App](github-app/README.md).
Source repositories contain no Debian packaging or Debian CI callers.

```text
source push/tag → App Worker → recipe workflow_dispatch → reusable build
manual recipe publish workflow → existing build artifact → APT repository
```

## Repositories and inputs

Source names are plain; recipes are exactly `<source>-debian` under the same
owner. Both the Worker and reusable build enforce this pairing. Source changes
are Git commits; Debian-only patches live in the recipe's `debian/patches/`.
Recipes use `3.0 (quilt)`. Submodules are rejected; vendor required dependencies.

Install the [build caller](examples/build.yml) and [manual publisher](examples/publish.yml)
in each **recipe repository**, on its default branch. The App dispatches the
recipe build with the immutable source commit; the recipe caller allowlists its
source repo and manually pins an exact recipe packaging SHA. That SHA can precede
caller-only commits, avoiding a self-referencing pin.

The [reusable build](.github/workflows/package.yml) accepts:

| Input | Required/default |
| --- | --- |
| `source-repository` | Required `owner/name`, allowlisted by caller |
| `source-sha` | Required full lowercase 40-character commit SHA |
| `source-tag` | Empty for snapshots; verified raw tag for releases |
| `recipe-repository` | Required `<source-repository>-debian`, equal to caller repo |
| `recipe-sha` | Required manually configured full packaging commit SHA |
| `suite` | `trixie` |
| `host-arch` | `native`; use `riscv64` for the kernel |
| `artifact-name` | `debs-<source-sha>-<suite>` |

Public checkouts need no extra secret. Optional read-only `SOURCE_READ_TOKEN`
and `RECIPE_READ_TOKEN` support private repos; never pass publication secrets to
builds. The App installation token is not a workflow input.

CI exports source, overlays the pinned recipe, creates an orig/quilt source
package, builds binaries in sbuild/unshare/mmdebstrap, and uploads artifacts.
Cross-builds keep a native build chroot and use `--build <native> --host <target>
--arch-all`, including architecture-independent outputs in the same build.
Ubuntu 24.04 uses the official Noble backport of sbuild (>=0.88.3), avoiding
host/chroot APT solver ABI mismatches. Log timestamps are normalized for GitHub
artifact filename restrictions. Only the temporary changelog changes:

- Tag `v1.2.3` → `1.2.3-1`.
- Snapshots → `<recipe-upstream>+gitYYYYMMDD.<12-source-hash>-1`, source UTC date.
- Epochs preserved in versions, omitted from filenames.

Package-specific payload checks belong in recipes. Available source files, logs,
and binaries are retained even after binary build failures; only successful
builds carry publication provenance. CI never commits, pushes, or updates pins.

## Manual publication

The [publisher](.github/workflows/publish.yml) rejects non-`workflow_dispatch`
callers and App/bot actors; publication requires a human actor. Inputs: successful recipe `build-run-id`, exact `artifact-name`, and
optional `suite` (trixie). It checks the build's recipe repository/run/suite
provenance and publishes those existing binaries, without rebuilding. The
workflow run's head SHA belongs to the recipe; it is not the source SHA.

Pass only org secret `DEB_CREDENTIALS` (base64 flat JSON) to publishing, and set
repo variable `DEB_S3_COMPONENT`. Bucket/prefix/storage/signing settings stay in
JSON. App/Worker credentials are separate and never used by the publisher.
Existing [admin helpers](admin/README.md) are retained; old caller examples there
are not the current API.

## Checks and activation

```sh
shellcheck -x scripts/*.sh tests/*.sh
bash tests/prepare-source-tree.sh
bash tests/run-sbuild.sh
bash tests/install-build-deps.sh
node --test github-app/worker.test.mjs
actionlint -ignore 'property "workflow_repository" is not defined' \
  -ignore 'property "workflow_sha" is not defined' .github/workflows/*.yml examples/*.yml
```

See [App setup](github-app/README.md) and the [kernel recipe](https://github.com/slopization/linux-cv181x-sodoport-debian).
Shared CI is published. Use the fixed `v2.0.1` release or an immutable CI commit;
initial `v2` is retained for audit but has the old cross-resolver/artifact-log bugs.
Neither `v1` nor existing release refs are moved. GitHub.com's [workflow identity contexts](https://github.blog/changelog/2026-09-03-github-actions-early-september-2026-updates/)
keep the workflow and helper checkout at the same revision; GHES is not supported
by that mechanism. The [kernel cross-build](https://github.com/slopization/linux-cv181x-sodoport-debian/actions/runs/39569419468)
passed through the live Worker/App using v2.0.1 and a pinned recipe. Package
architectures, source/recipe provenance, checksums, RISC-V header tools and their
runtime dependencies were verified. Only aggregate source `cv181x` is watched;
topic branches and kernel tags do not build automatically. No APT publication
was triggered. Hardware boot testing remains separate.
