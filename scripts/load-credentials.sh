#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

credential_names=(
	DEB_S3_BUCKET
	DEB_S3_PREFIX
	DEB_S3_CODENAME
	DEB_S3_COMPONENT
	DEB_S3_REGION
	DEB_S3_ENDPOINT
	DEB_S3_FORCE_PATH_STYLE
	DEB_S3_SIGN_KEY
	DEB_S3_CLEAN
	DEB_S3_ORIGIN
	DEB_S3_SUITE
	DEB_S3_PRESERVE_VERSIONS
	DEB_S3_LOCK
	DEB_S3_FAIL_IF_EXISTS
	DEB_S3_VISIBILITY
	DEB_S3_USE_SESSION_TOKEN
	DEB_S3_GPG_PROVIDER
	AWS_ACCESS_KEY_ID
	AWS_SECRET_ACCESS_KEY
	AWS_SESSION_TOKEN
	DEB_REPO_SIGNING_PRIVATE_KEY
	DEB_REPO_SIGNING_PASSPHRASE
)

secret_names=(
	AWS_ACCESS_KEY_ID
	AWS_SECRET_ACCESS_KEY
	AWS_SESSION_TOKEN
	DEB_REPO_SIGNING_PRIVATE_KEY
	DEB_REPO_SIGNING_PASSPHRASE
)

is_known_name() {
	local candidate="$1"
	local name

	for name in "${credential_names[@]}"; do
		if [[ "$name" == "$candidate" ]]; then
			return 0
		fi
	done

	return 1
}

is_secret_name() {
	local candidate="$1"
	local name

	for name in "${secret_names[@]}"; do
		if [[ "$name" == "$candidate" ]]; then
			return 0
		fi
	done

	return 1
}

mask_value() {
	local value="$1"
	local line

	if [[ "$value" != *$'\n'* ]]; then
		printf '::add-mask::%s\n' "$value"
		return
	fi

	while IFS= read -r line; do
		if [[ -n "$line" ]]; then
			printf '::add-mask::%s\n' "$line"
		fi
	done <<<"$value"
}

write_env() {
	local key="$1"
	local value="$2"
	local delimiter

	delimiter="DEB_CREDENTIALS_${RANDOM}_${RANDOM}_$(date +%s%N)"
	{
		printf '%s<<%s\n' "$key" "$delimiter"
		printf '%s\n' "$value"
		printf '%s\n' "$delimiter"
	} >>"$GITHUB_ENV"
}

[[ -n "${GITHUB_ENV:-}" ]] || die "GITHUB_ENV is required"

declare -A loaded=()
json_file=""

cleanup() {
	if [[ -n "$json_file" ]]; then
		rm -f "$json_file"
	fi
}
trap cleanup EXIT

if [[ -n "${DEB_CREDENTIALS_B64:-}" ]]; then
	command -v base64 >/dev/null 2>&1 || die "base64 is required"
	if ! command -v jq >/dev/null 2>&1; then
		sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
		sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq
	fi

	json_file=$(mktemp)
	chmod 600 "$json_file"
	if ! printf '%s' "$DEB_CREDENTIALS_B64" | base64 -d >"$json_file"; then
		die "DEB_CREDENTIALS is not valid base64"
	fi
	jq -e 'type == "object" and all(.[]; type == "string" or type == "number" or type == "boolean")' \
		"$json_file" >/dev/null 2>&1 ||
		die "DEB_CREDENTIALS must decode to a flat JSON object of string/number/boolean values"

	while IFS=$'\t' read -r key value_b64; do
		is_known_name "$key" || die "unknown credential key in DEB_CREDENTIALS: $key"
		value=$(printf '%s' "$value_b64" | base64 -d)
		if [[ -n "$value" ]]; then
			loaded["$key"]=$value
		fi
	done < <(jq -r 'to_entries[] | "\(.key)\t\(.value | tostring | @base64)"' "$json_file")
fi

for name in "${credential_names[@]}"; do
	if [[ -n "${loaded[$name]:-}" ]]; then
		continue
	fi

	fallback_var="FALLBACK_${name}"
	fallback_value=${!fallback_var:-}
	if [[ -n "$fallback_value" ]]; then
		loaded["$name"]=$fallback_value
	fi
done

for name in "${credential_names[@]}"; do
	value=${loaded[$name]:-}
	if [[ -z "$value" ]]; then
		continue
	fi

	if is_secret_name "$name"; then
		mask_value "$value"
	fi
	write_env "$name" "$value"
done

has_signing_key=false
if [[ -n "${loaded[DEB_REPO_SIGNING_PRIVATE_KEY]:-}" ]]; then
	has_signing_key=true
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	printf 'has_signing_key=%s\n' "$has_signing_key" >>"$GITHUB_OUTPUT"
fi

printf 'loaded %d credential value(s); signing key: %s\n' "${#loaded[@]}" "$has_signing_key"
