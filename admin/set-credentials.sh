#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

json_file="${script_dir}/credentials.json"
org="slopization"
repos="lt6911-of-debian,firmware-cnm-wave420l,u-boot-cv181x-debian"
repo=""
dry_run=false
allow_incomplete=false

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Validate one JSON credential file, base64-encode it, and store it as the
DEB_CREDENTIALS secret. The workflow decodes it at publish time.

Options:
  --json FILE            Credentials JSON (default: admin/credentials.json)
  --org ORG              Organization target (default: slopization)
  --repos REPO1,REPO2    Repositories allowed to read the organization secret
  --repo OWNER/REPO      Store a repository-level secret instead of an org one
  --dry-run              Validate and print key names only
  --allow-incomplete     Do not fail when required values are missing
  -h, --help             Show this help
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

while (($#)); do
	case "$1" in
		--json)
			json_file="$2"
			shift 2
			;;
		--org)
			org="$2"
			shift 2
			;;
		--repos)
			repos="$2"
			shift 2
			;;
		--repo)
			repo="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		--allow-incomplete)
			allow_incomplete=true
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
done

[[ -f "$json_file" ]] || die "JSON file not found: $json_file"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v base64 >/dev/null 2>&1 || die "base64 is required"

if [[ -n "$repo" && "$repo" != */* ]]; then
	die "--repo must be OWNER/REPO"
fi
if [[ -z "$repo" && -z "$org" ]]; then
	die "--repo or --org is required"
fi

json_dir=$(CDPATH='' cd -- "$(dirname -- "$json_file")" && pwd)
json_file="${json_dir}/$(basename -- "$json_file")"

jq -e 'type == "object" and all(.[]; type == "string" or type == "number" or type == "boolean")' \
	"$json_file" >/dev/null 2>&1 ||
	die "credentials JSON must be a flat object of string/number/boolean values"

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

declare -A allowed=()
for name in "${credential_names[@]}"; do
	allowed["$name"]=1
done
allowed["DEB_REPO_SIGNING_PRIVATE_KEY_FILE"]=1

while IFS= read -r key; do
	[[ -n "$key" ]] || continue
	[[ -n "${allowed[$key]:-}" ]] || die "unknown credential name: $key"
done < <(jq -r 'keys[]' "$json_file")

key_file=$(jq -r '.["DEB_REPO_SIGNING_PRIVATE_KEY_FILE"] // empty' "$json_file")
inline_key=$(jq -r '.["DEB_REPO_SIGNING_PRIVATE_KEY"] // empty' "$json_file")
if [[ -n "$key_file" && -n "$inline_key" ]]; then
	die "set only one of DEB_REPO_SIGNING_PRIVATE_KEY and DEB_REPO_SIGNING_PRIVATE_KEY_FILE"
fi

umask 077
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
normalized="${work_dir}/credentials.json"

if [[ -n "$key_file" ]]; then
	[[ "$key_file" == /* ]] || key_file="${json_dir}/${key_file}"
	[[ -f "$key_file" ]] || die "signing key file not found: $key_file"
	jq --rawfile key "$key_file" \
		'del(."DEB_REPO_SIGNING_PRIVATE_KEY_FILE") | ."DEB_REPO_SIGNING_PRIVATE_KEY" = $key' \
		"$json_file" >"$normalized"
else
	jq 'del(."DEB_REPO_SIGNING_PRIVATE_KEY_FILE")' "$json_file" >"$normalized"
fi

missing=()
for name in DEB_S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
	value=$(jq -r --arg name "$name" '.[$name] // empty' "$normalized")
	if [[ -z "$value" ]]; then
		missing+=("$name")
	fi
done
if ((${#missing[@]})); then
	message="missing required credential(s): ${missing[*]}"
	if [[ "$allow_incomplete" == true ]]; then
		printf 'warning: %s\n' "$message" >&2
	else
		die "$message (use --allow-incomplete to continue)"
	fi
fi

if [[ "$dry_run" == true ]]; then
	printf 'dry run: would store DEB_CREDENTIALS for '
	if [[ -n "$repo" ]]; then
		printf 'repository %s\n' "$repo"
	else
		printf 'organization %s (repos: %s)\n' "$org" "$repos"
	fi
	printf 'keys: '
	jq -r 'keys | join(", ")' "$normalized"
	exit 0
fi

command -v gh >/dev/null 2>&1 || die "gh is required"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated"

encoded="${work_dir}/credentials.b64"
base64 <"$normalized" | tr -d '\n' >"$encoded"

if [[ -n "$repo" ]]; then
	gh secret set DEB_CREDENTIALS --repo "$repo" <"$encoded"
else
	gh secret set DEB_CREDENTIALS --org "$org" --repos "$repos" <"$encoded"
fi
