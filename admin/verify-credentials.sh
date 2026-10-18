#!/usr/bin/env bash
set -euo pipefail

json=$1
jq -e 'has("DEB_S3_BUCKET") and has("AWS_ACCESS_KEY_ID") and has("AWS_SECRET_ACCESS_KEY") and has("DEB_REPO_SIGNING_PRIVATE_KEY")' "$json" >/dev/null

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

test_key() {
	local name="$1"
	local key="$2" pass="$3" home="$tmp/$name" fpr
	mkdir -p "$home"
	chmod 700 "$home"
	if grep -q 'BEGIN PGP PRIVATE KEY' <<<"$key"; then
		printf '%s\n' "$key" >"$home/key"
	else
		printf '%s' "$key" | base64 -d >"$home/key"
	fi
	GNUPGHOME="$home" gpg --batch --import "$home/key" >/dev/null 2>&1
	fpr=$(GNUPGHOME="$home" gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')
	printf '%s' "$pass" >"$home/pass"
	printf 'verify\n' >"$home/data"
	GNUPGHOME="$home" gpg --batch --pinentry-mode loopback --passphrase-file "$home/pass" \
		--local-user "$fpr" --detach-sign -o "$home/data.sig" "$home/data" 2>/dev/null
	GNUPGHOME="$home" gpg --batch --verify "$home/data.sig" "$home/data" 2>/dev/null
	echo "$fpr"
}

repo_fpr=$(test_key repo \
	"$(jq -r '."DEB_REPO_SIGNING_PRIVATE_KEY"' "$json")" \
	"$(jq -r '."DEB_REPO_SIGNING_PASSPHRASE" // ""' "$json")")
printf 'repo key ok: %s\n' "$repo_fpr"

pkg_key=$(jq -r '."DEB_PACKAGE_SIGNING_PRIVATE_KEY" // empty' "$json")
if [[ -n "$pkg_key" ]]; then
	pkg_fpr=$(test_key package "$pkg_key" \
		"$(jq -r '."DEB_PACKAGE_SIGNING_PASSPHRASE" // ""' "$json")")
	printf 'package key ok: %s\n' "$pkg_fpr"
fi

bucket=$(jq -r '."DEB_S3_BUCKET"' "$json")
region=$(jq -r '."DEB_S3_REGION" // "us-east-1"' "$json")
endpoint=$(jq -r '."DEB_S3_ENDPOINT" // ""' "$json")
endpoint=${endpoint%/}
url="${endpoint:-https://s3.${region}.amazonaws.com}/${bucket}"

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
AWS_ACCESS_KEY_ID=$(jq -r '."AWS_ACCESS_KEY_ID"' "$json")
AWS_SECRET_ACCESS_KEY=$(jq -r '."AWS_SECRET_ACCESS_KEY"' "$json")
session=$(jq -r '."AWS_SESSION_TOKEN" // ""' "$json")
headers=()
[[ -z "$session" ]] || headers=(-H "x-amz-security-token: $session")

curl -fsSI --aws-sigv4 "aws:amz:${region}:s3" \
	--user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
	"${headers[@]}" "$url" >/dev/null
printf 's3 ok: %s\n' "$url"
