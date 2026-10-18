#!/usr/bin/env bash
set -euo pipefail

out_dir="${PWD}/debian-keys"
repo_uid="NanoKVM APT Repository <repo@example.invalid>"
package_uid=""
algorithm="ed25519"
expire="2y"
repo_passphrase_file=""
package_passphrase_file=""
repo_no_passphrase=false
package_no_passphrase=false
force=false

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Generate two independent OpenPGP keys:

  repository key  signs APT Release/InRelease metadata (deb-s3 --sign)
  package key     signs .dsc/.changes files (debsign, dpkg-buildpackage -k)

Both keys are created with sign-only usage in separate GnuPG homes. Private
keys and revocation certificates are written to --out-dir; nothing is uploaded.

Options:
  --out-dir DIR                  Output directory (default: ./debian-keys)
  --repo-uid UID                 Repository key UID
                                 (default: NanoKVM APT Repository <repo@example.invalid>)
  --package-uid UID              Package key UID
                                 (default: git user.name + user.email)
  --algorithm ed25519|rsa4096    Key algorithm (default: ed25519)
  --expire DURATION              GnuPG expiry, e.g. 2y, 5y (default: 2y)
  --repo-passphrase-file FILE    Read the repository key passphrase from FILE
  --package-passphrase-file FILE Read the package key passphrase from FILE
  --repo-no-passphrase           Create the repository key without a passphrase
  --package-no-passphrase        Create the package key without a passphrase
  --force                        Allow using a non-empty output directory
  -h, --help                     Show this help

Without a passphrase file or --*-no-passphrase, the script prompts. Store both
passphrases and the revocation certificates offline; do not commit them.
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

while (($#)); do
	case "$1" in
		--out-dir)
			out_dir="$2"
			shift 2
			;;
		--repo-uid)
			repo_uid="$2"
			shift 2
			;;
		--package-uid)
			package_uid="$2"
			shift 2
			;;
		--algorithm)
			algorithm="$2"
			shift 2
			;;
		--expire)
			expire="$2"
			shift 2
			;;
		--repo-passphrase-file)
			repo_passphrase_file="$2"
			shift 2
			;;
		--package-passphrase-file)
			package_passphrase_file="$2"
			shift 2
			;;
		--repo-no-passphrase)
			repo_no_passphrase=true
			shift
			;;
		--package-no-passphrase)
			package_no_passphrase=true
			shift
			;;
		--force)
			force=true
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

command -v gpg >/dev/null 2>&1 || die "gpg is required"

case "$algorithm" in
	ed25519 | rsa4096) ;;
	*) die "--algorithm must be ed25519 or rsa4096" ;;
esac

if [[ "$repo_uid" == *example.invalid* ]]; then
	printf 'warning: replace the placeholder repository UID with a real one\n' >&2
fi

if [[ -z "$package_uid" ]]; then
	name=$(git config --get user.name 2>/dev/null || true)
	email=$(git config --get user.email 2>/dev/null || true)
	if [[ -n "$name" && -n "$email" ]]; then
		package_uid="${name} <${email}>"
	fi
fi
[[ -n "$package_uid" ]] || die "--package-uid is required"

if [[ -e "$out_dir" && -n "$(ls -A "$out_dir" 2>/dev/null)" && "$force" != true ]]; then
	die "$out_dir is not empty; use --force or choose another --out-dir"
fi
mkdir -p "$out_dir"
chmod 700 "$out_dir"
out_dir=$(CDPATH='' cd -- "$out_dir" && pwd)

repo_home="${out_dir}/gnupg-repo"
package_home="${out_dir}/gnupg-package"
mkdir -p "$repo_home" "$package_home"
chmod 700 "$repo_home" "$package_home"

temp_files=()
cleanup() {
	for file in "${temp_files[@]}"; do
		rm -f "$file"
	done
}
trap cleanup EXIT

prompt_passphrase() {
	local label="$1"
	local first=""
	local second=""

	[[ -t 0 ]] || die "no TTY for ${label} passphrase; use --${label}-passphrase-file or --${label}-no-passphrase"
	read -r -s -p "${label} key passphrase (empty for none): " first
	printf '\n' >&2
	read -r -s -p "Repeat ${label} key passphrase: " second
	printf '\n' >&2
	[[ "$first" == "$second" ]] || die "${label} passphrases do not match"

	local file
	file=$(mktemp)
	temp_files+=("$file")
	printf '%s' "$first" >"$file"
	chmod 600 "$file"
	printf '%s\n' "$file"
}

resolve_passphrase_file() {
	local label="$1"
	local file="$2"
	local no_pass="$3"
	local prompted=""

	if [[ -n "$file" ]]; then
		[[ -f "$file" ]] || die "${label} passphrase file not found: $file"
		printf '%s\n' "$file"
		return
	fi
	if [[ "$no_pass" == true ]]; then
		prompted=$(mktemp)
		temp_files+=("$prompted")
		: >"$prompted"
		chmod 600 "$prompted"
		printf '%s\n' "$prompted"
		return
	fi
	prompt_passphrase "$label"
}

repo_pass_file=$(resolve_passphrase_file repo "$repo_passphrase_file" "$repo_no_passphrase")
package_pass_file=$(resolve_passphrase_file package "$package_passphrase_file" "$package_no_passphrase")

generate_key() {
	local label="$1"
	local home="$2"
	local uid="$3"
	local pass_file="$4"
	local private_out="$5"
	local public_asc_out="$6"
	local public_gpg_out="$7"
	local revoke_out="$8"
	local fpr=""

	printf 'Generating %s key: %s\n' "$label" "$uid" >&2
	gpg --batch --homedir "$home" --pinentry-mode loopback \
		--passphrase-file "$pass_file" \
		--quick-gen-key "$uid" "$algorithm" sign "$expire"

	fpr=$(gpg --batch --homedir "$home" --list-secret-keys --with-colons |
		awk -F: '/^fpr:/ { print $10; exit }')
	[[ -n "$fpr" ]] || die "could not determine ${label} key fingerprint"

	umask 077
	gpg --batch --homedir "$home" --pinentry-mode loopback \
		--passphrase-file "$pass_file" \
		--armor --export-secret-keys "$fpr" >"$private_out"
	gpg --batch --homedir "$home" --armor --export "$fpr" >"$public_asc_out"
	gpg --batch --homedir "$home" --export "$fpr" >"$public_gpg_out"
	[[ -s "$private_out" ]] || die "failed to export ${label} private key"
	[[ -s "$public_asc_out" && -s "$public_gpg_out" ]] || die "failed to export ${label} public key"
	chmod 600 "$private_out"
	chmod 644 "$public_asc_out" "$public_gpg_out"

	if [[ -f "${home}/openpgp-revocs.d/${fpr}.rev" ]]; then
		cp "${home}/openpgp-revocs.d/${fpr}.rev" "$revoke_out"
		chmod 600 "$revoke_out"
	fi

	printf '%s\n' "$fpr"
}

repo_fpr=$(generate_key \
	"repository" "$repo_home" "$repo_uid" "$repo_pass_file" \
	"${out_dir}/repo-private.asc" "${out_dir}/repo-public.asc" \
	"${out_dir}/repo-public.gpg" "${out_dir}/repo-revoke.asc")

package_fpr=$(generate_key \
	"package" "$package_home" "$package_uid" "$package_pass_file" \
	"${out_dir}/package-private.asc" "${out_dir}/package-public.asc" \
	"${out_dir}/package-public.gpg" "${out_dir}/package-revoke.asc")

cat >"${out_dir}/key-info.txt" <<EOF
repository key
  uid:         ${repo_uid}
  fingerprint: ${repo_fpr}
  private:     repo-private.asc
  public:      repo-public.asc / repo-public.gpg
  revocation:  repo-revoke.asc

package key
  uid:         ${package_uid}
  fingerprint: ${package_fpr}
  private:     package-private.asc
  public:      package-public.asc / package-public.gpg
  revocation:  package-revoke.asc
EOF
chmod 600 "${out_dir}/key-info.txt"

cat <<EOF

Generated in ${out_dir}

Next steps:
  DEB_S3_SIGN_KEY=${repo_fpr}
  DEB_REPO_SIGNING_PRIVATE_KEY=<contents of ${out_dir}/repo-private.asc>
  DEB_REPO_SIGNING_PASSPHRASE=<repository key passphrase>

  DEBSIGN_KEYID=${package_fpr}
  debsign -k ${package_fpr} <changes-file>

For the single DEB_CREDENTIALS JSON, point
  DEB_REPO_SIGNING_PRIVATE_KEY_FILE
at ${out_dir}/repo-private.asc and
  DEB_PACKAGE_SIGNING_PRIVATE_KEY_FILE
at ${out_dir}/package-private.asc; admin/set-credentials.sh embeds both.
Set DEB_PACKAGE_SIGN_KEY to the package fingerprint if you later sign packages
in CI.

Store both private keys, both revocation certificates, and the passphrases
offline. Do not commit ${out_dir}/.
EOF
