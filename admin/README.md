# Credentials

The CI uses one organization secret:

```text
DEB_CREDENTIALS = base64(the JSON file)
```

The JSON contains only what the publish step uses. The APT codename is **not**
stored here: CI will derive it from the branch name, where `debian/foo` builds
and publishes codename `foo`. That branch logic is not wired yet; this file
only defines the credential format.

The package signing key is included for future `.dsc`/`.changes` signing. CI
currently uses only the repository key, but the package key is stored in the
same secret so it is ready when that step is added.

## Minimal JSON

`admin/credentials.json` is the ready-to-edit scaffold (gitignored).

| Key | Required | Notes |
|---|---|---|
| `DEB_S3_BUCKET` | yes | Repository bucket |
| `DEB_S3_PREFIX` | no | Repo path inside the bucket; empty means bucket root |
| `DEB_S3_REGION` | yes for R2 | `auto` for R2, real region for AWS |
| `DEB_S3_ENDPOINT` | yes for R2 | `https://<account>.r2.cloudflarestorage.com`; empty for AWS |
| `AWS_ACCESS_KEY_ID` | yes | R2 or AWS access key |
| `AWS_SECRET_ACCESS_KEY` | yes | R2 or AWS secret |
| `DEB_REPO_SIGNING_PRIVATE_KEY` | yes | ASCII-armored repository private key |
| `DEB_REPO_SIGNING_PASSPHRASE` | no | Empty if the key has no passphrase |
| `DEB_PACKAGE_SIGNING_PRIVATE_KEY` | no | ASCII-armored package private key |
| `DEB_PACKAGE_SIGNING_PASSPHRASE` | no | Empty if the key has no passphrase |

Deliberately omitted:

- `DEB_S3_CODENAME` — derived from `debian/<codename>` branches.
- `DEB_S3_COMPONENT` — defaults to `main`.
- `DEB_S3_VISIBILITY`, `DEB_S3_LOCK`, `DEB_S3_USE_SESSION_TOKEN` — the publish
  script uses R2-friendly defaults for a custom endpoint.
- `DEB_S3_CLEAN`, `DEB_S3_PRESERVE_VERSIONS`, `DEB_S3_FAIL_IF_EXISTS` — defaults
  are already the intended behavior.
- `DEB_S3_SIGN_KEY` — with one imported repository key, the fingerprint is
  selected automatically.
- `AWS_SESSION_TOKEN` — not needed for long-lived R2/AWS keys.

## Repository key

Generate both keys:

```sh
./admin/generate-debian-keys.sh \
  --repo-uid 'NanoKVM APT Repository <repo@your-domain>' \
  --package-uid 'Your Name <you@your-domain>' \
  --out-dir ./debian-keys
```

Put the contents of `repo-private.asc` and `package-private.asc` into the
two inline key fields. The JSON strings must escape newlines as `\n`. Using
`jq` is safer than editing by hand:

```sh
jq --rawfile repo debian-keys/repo-private.asc \
   --rawfile pkg debian-keys/package-private.asc \
  '.DEB_REPO_SIGNING_PRIVATE_KEY = $repo
   | .DEB_PACKAGE_SIGNING_PRIVATE_KEY = $pkg' \
  admin/credentials.json > admin/credentials.filled.json
mv admin/credentials.filled.json admin/credentials.json
```

The package key signs `.dsc`/`.changes` with `debsign`, not the APT repository
metadata. CI does not use it yet; keep the offline copy for local signing.

Public key for clients: `debian-keys/repo-public.gpg` or `.asc`.

## Store the secret

Verify the filled file first (GPG signing plus an authenticated S3 HEAD):

```sh
./admin/verify-credentials.sh admin/credentials.json
```

Then store it:

```sh
jq -e . admin/credentials.json >/dev/null
./admin/set-credentials.sh --dry-run
./admin/set-credentials.sh
```

The helper base64-encodes the whole JSON and stores it as `DEB_CREDENTIALS` at
organization level (default `slopization`). By default it is available to every
repository in the org; pass `--repos` to restrict it to specific ones.

To do it manually:

```sh
base64 < admin/credentials.json | tr -d '\n' > admin/credentials.b64
gh secret set DEB_CREDENTIALS --org slopization < admin/credentials.b64
```

Do not commit `admin/credentials.json` or `admin/credentials.b64`.

## Notes

- The `set-credentials.sh` helper also supports `*_PRIVATE_KEY_FILE` fields, but
  the scaffold intentionally uses the inline key form.
- If packages share one bucket and need different prefixes, leave
  `DEB_S3_PREFIX` empty and set `s3-prefix` in each publish caller.
- For AWS S3 instead of R2, leave `DEB_S3_ENDPOINT` empty and set the real
  `DEB_S3_REGION`.
- If you later use AWS S3, GitHub OIDC can replace the static AWS keys.
