# Credentials

## Generate the two keys first

The repository key signs APT metadata; the package key signs `.dsc`/`.changes`
files. They should be separate keys:

```sh
./admin/generate-debian-keys.sh \
  --repo-uid 'NanoKVM APT Repository <repo@your-domain>' \
  --package-uid 'Your Name <you@your-domain>' \
  --out-dir ./debian-keys
```

The script prompts for one passphrase per key, creates two separate GnuPG
homes, and writes:

```text
debian-keys/repo-private.asc      repository private key
debian-keys/repo-public.asc/.gpg  repository public key
debian-keys/repo-revoke.asc       repository revocation certificate
debian-keys/package-private.asc   package private key
debian-keys/package-public.asc    package public key
debian-keys/package-revoke.asc    package revocation certificate
debian-keys/key-info.txt          fingerprints and paths
```

Use the repository UID on the APT key and the package UID that matches the
`Maintainer` field in `debian/changelog`. Store both private keys, both
revocation certificates, and both passphrases offline. Never commit
`debian-keys/`.

Then point the JSON at the private key files:

```json
"DEB_REPO_SIGNING_PRIVATE_KEY_FILE": "../debian-keys/repo-private.asc",
"DEB_PACKAGE_SIGNING_PRIVATE_KEY_FILE": "../debian-keys/package-private.asc"
```

`set-credentials.sh` embeds both keys and removes the `_FILE` entries before
uploading the JSON.

There are two supported credential layouts:

1. **One `DEB_CREDENTIALS` secret** containing base64 JSON. This is the single
   file you asked for. The reusable workflow decodes it at publish time.
2. **Separate organization variables/secrets.** This is the native GitHub
   per-field layout; the loader script in this directory can populate it from a
   local dotenv file.

Both are optional fallbacks for each other. Values in `DEB_CREDENTIALS` win;
separate variables/secrets fill in anything the JSON does not contain.

## Single JSON secret

`credentials.json.example` is the template:

```sh
cp admin/credentials.json.example admin/credentials.json
chmod 600 admin/credentials.json
$EDITOR admin/credentials.json
```

Keep the signing keys in separate files and point
`DEB_REPO_SIGNING_PRIVATE_KEY_FILE` and `DEB_PACKAGE_SIGNING_PRIVATE_KEY_FILE`
at them; the helper embeds both and removes the
`_FILE` key before uploading the JSON. The generator above already writes the
two private key files; no manual export is needed.

Preview, then store the secret:

```sh
./admin/set-credentials.sh --dry-run
./admin/set-credentials.sh
```

By default the secret is stored at organization level for `slopization` and
granted to:

```text
lt6911-of-debian,firmware-cnm-wave420l,u-boot-cv181x-debian
```

Override with `--org`/`--repos`, or set one repository with
`--repo slopization/lt6911-of-debian`. The script base64-encodes the JSON and
sends it to `gh` through stdin; it never prints values.

The JSON is a flat object whose keys are the environment variable names:

```json
{
  "DEB_S3_BUCKET": "my-bucket",
  "DEB_S3_PREFIX": "debian/nanokvm",
  "DEB_S3_CODENAME": "trixie",
  "DEB_S3_COMPONENT": "main",
  "DEB_S3_REGION": "auto",
  "DEB_S3_ENDPOINT": "https://<account_id>.r2.cloudflarestorage.com",
  "DEB_S3_FORCE_PATH_STYLE": "0",
  "DEB_S3_SIGN_KEY": "",
  "DEB_S3_CLEAN": "1",
  "DEB_S3_ORIGIN": "",
  "DEB_S3_SUITE": "",
  "DEB_S3_PRESERVE_VERSIONS": "0",
  "DEB_S3_LOCK": "",
  "DEB_S3_FAIL_IF_EXISTS": "0",
  "DEB_S3_VISIBILITY": "",
  "DEB_S3_USE_SESSION_TOKEN": "0",
  "DEB_S3_GPG_PROVIDER": "",
  "AWS_ACCESS_KEY_ID": "...",
  "AWS_SECRET_ACCESS_KEY": "...",
  "AWS_SESSION_TOKEN": "",
  "DEB_REPO_SIGNING_PRIVATE_KEY": "-----BEGIN PGP PRIVATE KEY BLOCK-----\n...",
  "DEB_REPO_SIGNING_PASSPHRASE": "",
  "DEB_PACKAGE_SIGNING_PRIVATE_KEY": "-----BEGIN PGP PRIVATE KEY BLOCK-----\n...",
  "DEB_PACKAGE_SIGNING_PASSPHRASE": "",
  "DEB_PACKAGE_SIGN_KEY": ""
}
```

The publish callers pass `DEB_CREDENTIALS: ${{ secrets.DEB_CREDENTIALS }}` to the
shared workflow. The workflow writes the decoded values to the step
environment, masks the actual secrets, and checks whether a signing key is
present before trying to load it.

The JSON form needs no organization variables at all. Keep the existing
per-repository values only if you want a fallback during the transition.

If all three packages share the same bucket and signing key but use different
`DEB_S3_PREFIX` values, keep one JSON and set `s3-prefix` in each publish
caller. `s3-bucket` is available for the same reason. These inputs override the
JSON after it is loaded.

## Alternative: separate organization fields

If you prefer GitHub's native per-field settings, `credentials.env.example` is
a dotenv template; `load-org-credentials.sh` reads it and stores each value as
an organization variable or secret:

```sh
cp admin/credentials.env.example admin/credentials.env
chmod 600 admin/credentials.env
$EDITOR admin/credentials.env
./admin/load-org-credentials.sh --dry-run
./admin/load-org-credentials.sh
```

Organization **variables**:

```text
DEB_S3_BUCKET DEB_S3_PREFIX DEB_S3_CODENAME DEB_S3_COMPONENT
DEB_S3_REGION DEB_S3_ENDPOINT DEB_S3_FORCE_PATH_STYLE DEB_S3_SIGN_KEY
DEB_S3_CLEAN DEB_S3_ORIGIN DEB_S3_SUITE DEB_S3_PRESERVE_VERSIONS
DEB_S3_LOCK DEB_S3_FAIL_IF_EXISTS DEB_S3_VISIBILITY
DEB_S3_USE_SESSION_TOKEN DEB_S3_GPG_PROVIDER
```

Organization **secrets**:

```text
AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
DEB_REPO_SIGNING_PRIVATE_KEY DEB_REPO_SIGNING_PASSPHRASE
DEB_PACKAGE_SIGNING_PRIVATE_KEY DEB_PACKAGE_SIGNING_PASSPHRASE
```

## Remove old per-repository copies

Repository-level variables and secrets take precedence over organization-level
ones. If you move to organization-level values, delete the old per-repository
copies or they will keep shadowing the shared configuration. The single
`DEB_CREDENTIALS` secret does not have this problem because it is read
explicitly by the workflow.

```sh
for repo in lt6911-of-debian firmware-cnm-wave420l u-boot-cv181x-debian; do
  gh variable list --repo "slopization/$repo"
  gh secret list --repo "slopization/$repo"
done
```

## Notes

- GitHub has no file upload or multi-field credential form. This helper is the
  bridge between one local file and GitHub's one-value-per-secret storage.
- Empty values are skipped. Delete an organization variable or secret manually
  if you need to remove one that was previously set.
- Keep `admin/credentials.json`, `admin/credentials.env`, and the private key
  file out of git; `.gitignore` covers them.
- If your bucket is AWS S3 rather than Cloudflare R2, consider replacing the
  long-lived AWS keys with GitHub OIDC role assumption later.
