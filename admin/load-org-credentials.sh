#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

org="slopization"
file="${script_dir}/credentials.env"
repos="lt6911-of-debian,firmware-cnm-wave420l,u-boot-cv181x-debian"
dry_run=false
allow_incomplete=false

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Read one dotenv-style credentials file and store the values as organization
variables and secrets in GitHub. Nothing is printed except names and status.

Options:
  --org ORG              Organization name (default: slopization)
  --file FILE            Credentials file (default: admin/credentials.env)
  --repos REPO1,REPO2    Repositories allowed to read the secrets
                         (default: the three Debian package repositories)
  --dry-run              Print what would be set, without changing GitHub
  --allow-incomplete     Do not fail when required credentials are missing
  -h, --help             Show this help
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

while (($#)); do
	case "$1" in
		--org)
			org="$2"
			shift 2
			;;
		--file)
			file="$2"
			shift 2
			;;
		--repos)
			repos="$2"
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

[[ -f "$file" ]] || die "credentials file not found: $file"
[[ -n "$org" ]] || die "--org is required"
[[ -n "$repos" ]] || die "--repos is required"

file_dir=$(CDPATH='' cd -- "$(dirname -- "$file")" && pwd)
file="${file_dir}/$(basename -- "$file")"

if command -v stat >/dev/null 2>&1; then
	mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || true)
	if [[ -n "$mode" && "$mode" != "600" && "$mode" != "400" ]]; then
		printf 'warning: %s is readable by group/other (mode %s); chmod 600 is recommended\n' "$file" "$mode" >&2
	fi
fi

variable_names=(
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
)

secret_names=(
	AWS_ACCESS_KEY_ID
	AWS_SECRET_ACCESS_KEY
	AWS_SESSION_TOKEN
	DEB_REPO_SIGNING_PRIVATE_KEY
	DEB_REPO_SIGNING_PASSPHRASE
)

declare -A allowed=()
for name in "${variable_names[@]}" "${secret_names[@]}"; do
	allowed["$name"]=1
done
allowed["DEB_REPO_SIGNING_PRIVATE_KEY_FILE"]=1

declare -A values=()

while IFS= read -r line || [[ -n "$line" ]]; do
	line=${line%$'\r'}
	[[ "$line" =~ ^[[:space:]]*$ ]] && continue
	[[ "$line" =~ ^[[:space:]]*# ]] && continue

	line="${line#"${line%%[![:space:]]*}"}"
	line="${line%"${line##*[![:space:]]}"}"
	[[ "$line" == export[[:space:]]* ]] && line=${line#export}
	line="${line#"${line%%[![:space:]]*}"}"

	[[ "$line" == *=* ]] || die "invalid line (expected KEY=VALUE): $line"

	key=${line%%=*}
	value=${line#*=}
	key=${key//[[:space:]]/}
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"

	if [[ ${#value} -ge 2 ]]; then
		if [[ "$value" == \"*\" ]]; then
			value=${value:1:${#value}-2}
		elif [[ "$value" == \'*\' ]]; then
			value=${value:1:${#value}-2}
		fi
	fi

	[[ -n "$key" ]] || die "empty key in $file"
	[[ -n "${allowed[$key]:-}" ]] || die "unknown credential name: $key"
	values["$key"]=$value
done <"$file"

key_file=${values[DEB_REPO_SIGNING_PRIVATE_KEY_FILE]:-}
inline_key=${values[DEB_REPO_SIGNING_PRIVATE_KEY]:-}
if [[ -n "$key_file" && -n "$inline_key" ]]; then
	die "set only one of DEB_REPO_SIGNING_PRIVATE_KEY and DEB_REPO_SIGNING_PRIVATE_KEY_FILE"
fi

if [[ -n "$key_file" ]]; then
	[[ "$key_file" == /* ]] || key_file="${file_dir}/${key_file}"
	[[ -f "$key_file" ]] || die "signing key file not found: $key_file"
	values[DEB_REPO_SIGNING_PRIVATE_KEY]=$(base64 <"$key_file" | tr -d '\n')
fi

missing=()
for name in DEB_S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
	if [[ -z "${values[$name]:-}" ]]; then
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
	printf 'dry run: no GitHub changes will be made\n'
else
	command -v gh >/dev/null 2>&1 || die "gh is required"
	gh auth status >/dev/null 2>&1 || die "gh is not authenticated"
fi

for name in "${variable_names[@]}"; do
	value=${values[$name]:-}
	if [[ -z "$value" ]]; then
		printf 'skip variable %s (empty)\n' "$name"
		continue
	fi
	if [[ "$dry_run" == true ]]; then
		printf 'would set variable %s\n' "$name"
	else
		gh variable set "$name" --org "$org" --repos "$repos" --body "$value"
	fi
done

for name in "${secret_names[@]}"; do
	value=${values[$name]:-}
	if [[ -z "$value" ]]; then
		printf 'skip secret %s (empty)\n' "$name"
		continue
	fi
	if [[ "$dry_run" == true ]]; then
		printf 'would set secret %s\n' "$name"
	else
		printf '%s' "$value" | gh secret set "$name" --org "$org" --repos "$repos"
	fi
done
