# Credentials

There are two supported layouts:

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

Keep the signing key in a separate file and point
`DEB_REPO_SIGNING_PRIVATE_KEY_FILE` at it; the helper embeds it and removes the
`_FILE` key before uploading the JSON:

```sh
gpg --armor --export-secret-keys "$key_id" > admin/repository-signing-private.asc
chmod 600 admin/repository-signing-private.asc
```

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
  "DEB_REPO_SIGNING_PASSPHRASE": ""
}
```

The publish callers pass `DEB_CREDENTIALS: ${{ secrets.DEB_CREDENTIALS }}` to the
shared workflow. The workflow writes the decoded values to the step
environment, masks the actual secrets, and checks whether a signing key is
present before trying to load it.

The JSON form needs no organization variables at all. Keep the existing
per-repository values only if you want a fallback during the transition.

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
