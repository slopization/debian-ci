# GitHub App → recipe CI, hosted on Cloudflare Workers

All maintained App code/configuration lives here in the shared CI repository.
Runtime dependencies: none (WebCrypto + fetch). Build tools are pinned in
[package.json](package.json) and [lockfile](package-lock.json).

## Naming and routing

Source repositories use plain names; recipes must be exactly `<source>-debian`
in the same owner/installation. Recipe names are derived, not taken from webhooks.
The allowlist in [Cloudflare config](cloudflare.config.ts) currently contains:

- `slopization/lt6911-of` → `slopization/lt6911-of-debian`
- `slopization/firmware-cnm-wave420l` → `slopization/firmware-cnm-wave420l-debian`
- `slopization/u-boot-cv181x` → `slopization/u-boot-cv181x-debian`
- `slopization/linux-cv181x-sodoport` → `slopization/linux-cv181x-sodoport-debian`

The original three accept `master` and version tags matching `v[0-9]...`.
Kernel accepts ONLY `cv181x`; its topic/master/tag events are ignored (`tags:false`).
Deleted refs,
other branches/events, and unlisted repos are ignored. The pushed object SHA is
resolved through GitHub's Git API (including nested annotated tags), never by a
mutable tag name. The App dispatches only the recipe's `build.yml` on `main`,
with source repository/SHA/raw tag inputs. It cannot choose a publish workflow.
The manually pinned recipe SHA stays in each recipe caller, not the webhook.

## Deployment state

Endpoint: https://debian-ci-webhook.djdisodo.workers.dev/webhook

[Health](https://debian-ci-webhook.djdisodo.workers.dev/health) reports
`configured:true`. Existing private org App **dpkg-ci**, ID **5406166**, was
registered manually and authenticated; webhook/Cloudflare credentials are set.
Real GitHub ping redelivery succeeded with HTTP200 and unsigned requests are
rejected. Installation **173637858** is active in slopization, selected-repo mode,
with the original three source repos plus the kernel source and kernel recipe
(five selected). Existing bot Apps were not modified.
The GitHub picker omitted those repos; user authorized a temporary .github
selection, then authenticated repository-access API calls added sources and
removed .github. No all-repo grant was used.

The kernel fork and dependency-grouped source topics were published as requested.
Original three package repos, kernel recipe changes, and shared CI remain unpushed;
shared CI v2 and new recipe main branches are not published. Worker deployment
c855745f-dbb6-4fd3-ac3a-c53fe99ac801 includes kernel branch filtering, verified live.
Add the original three future recipe repos before activating their builds. Kernel
source/recipe access is already granted, but kernel CI also awaits code publication.

For an already registered App, the [configuration helper](configure-app.mjs)
authenticates the key, generates/reuses a private webhook secret, verifies hook
settings, and saves ignored mode-0600 Cloudflare credentials:

```sh
node configure-app.mjs APP_ID /local/path/to/private-key.pem
cf deploy --secrets-file "$PWD/.setup/app-secrets.json"
```

## Register a fresh App only (not needed for existing dpkg-ci)

From this directory, run:

```sh
node setup.mjs https://debian-ci-webhook.djdisodo.workers.dev
```

Open http://127.0.0.1:8788/ while signed into GitHub. With remote SSH, forward
port 8788 first. Review/register the private `slopization-debian-ci` organization
App. Permissions are only Contents read and Actions write; subscription is push.
The local callback verifies one-time state, exchanges the manifest code, converts
the RSA private key to PKCS#8, and writes mode-0600 files in ignored `.setup/`.
It never prints credentials. Do not paste the key into chat or commit it.

The helper stops after registration. Install the App on the required source AND
recipe repos (create/publish recipes first with explicit permission).
A private App can be installed only in its owning organization. The App does not
need access to unrelated repos or the existing org bot credentials.

Once registration has produced the private secrets file:

```sh
cf deploy --secrets-file "$PWD/.setup/app-secrets.json"
curl --fail https://debian-ci-webhook.djdisodo.workers.dev/health
```

Expect `configured:true`. This confirms bindings, not a successful GitHub build.
Then verify a real source delivery dispatches a recipe build, with no publication.
Public source checkouts need no extra CI secret; private sources require a
read-only `SOURCE_READ_TOKEN` in the recipe caller. The Worker's installation
token is never sent as a workflow input.

## Security and delivery behavior

- HMAC-SHA256 is checked over exact raw bytes before parsing; bodies capped at 1 MiB.
- An installation token is scoped to the source/recipe pair and needed permissions.
- Per-delivery SQLite Durable Objects serialize duplicate/concurrent requests;
  successful delivery markers expire after seven days. Failures remain retryable.
- A timeout after GitHub accepts dispatch can still produce an ambiguous outcome;
  no cross-service exactly-once guarantee is claimed.
- GitHub does **not** automatically redeliver failed webhooks. Inspect App delivery
  history and manually redeliver failures after fixing the cause. Large push
  payloads exceeding the cap need a manual recipe build.
- Publishing is separate and manual-only. The App has no S3/GPG credentials.
- Do not expose a public setup/credential callback on the Worker; registration is
  local-only. `.setup/`, local env files, private keys, and generated output are ignored.

## Local checks

```sh
npm ci --no-audit --no-fund
npm test
npm run build
cf deploy --dry-run
```

The [47 tests](worker.test.mjs) mock GitHub requests and cover signatures, routing,
JWTs, tag peeling, deduplication, and failures. App authentication, scoped source
access, real GitHub ping delivery, and an [existing firmware workflow run](https://github.com/slopization/firmware-cnm-wave420l/actions/runs/39551646321)
were verified live without pushing. That run passed sbuild/firmware validation
and uploaded an artifact as dpkg-ci[bot]. The new recipe-based dispatch path is
still unpublished and untested end-to-end; APT publication was not triggered.

References: [Cloudflare native config](https://developers.cloudflare.com/cf/projects/cloudflare-config/),
[GitHub App manifests](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest),
[webhook delivery handling](https://docs.github.com/en/webhooks/using-webhooks/handling-webhook-deliveries).
