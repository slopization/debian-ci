#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

kind=""
artifact_dir=""
firmware_path=""
firmware_sha256=""
forbid_filename=""

while (($#)); do
	case "$1" in
		--kind)
			kind="$2"
			shift 2
			;;
		--artifact-dir)
			artifact_dir="$2"
			shift 2
			;;
		--firmware-path)
			firmware_path="$2"
			shift 2
			;;
		--firmware-sha256)
			firmware_sha256="$2"
			shift 2
			;;
		--forbid-filename)
			forbid_filename="$2"
			shift 2
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
done

[[ -n "$kind" ]] || die "--kind is required"
[[ -d "$artifact_dir" ]] || die "invalid --artifact-dir: $artifact_dir"

case "$kind" in
	none)
		exit 0
		;;
	dkms | firmware) ;;
	*)
		die "unsupported validation profile: $kind"
		;;
esac

if [[ "$kind" == "firmware" ]]; then
	[[ "$firmware_path" == /* ]] || die "--firmware-path must be an absolute path inside the package"
	[[ "$firmware_sha256" =~ ^[0-9a-f]{64}$ ]] || die "--firmware-sha256 must be a lowercase SHA-256"
fi

mapfile -t debs < <(find "$artifact_dir" -maxdepth 1 -type f -name '*.deb' | sort)
[[ ${#debs[@]} -gt 0 ]] || die "no .deb files found in $artifact_dir"

payload_root=$(mktemp -d)
contents_file=$(mktemp)
cleanup() {
	rm -rf "$payload_root"
	rm -f "$contents_file"
}
trap cleanup EXIT

for deb in "${debs[@]}"; do
	printf '==> %s\n' "$deb"
	dpkg-deb --info "$deb"
	dpkg-deb --contents "$deb" >"$contents_file"
	payload_dir="${payload_root}/$(basename "$deb")"
	mkdir -p "$payload_dir"
	dpkg-deb --extract "$deb" "$payload_dir"

	case "$kind" in
		dkms)
			grep -q '/usr/src/' "$contents_file" || die "package does not install files under /usr/src/: $deb"
			grep -q '/dkms.conf$' "$contents_file" || die "package has no dkms.conf: $deb"

			installed_dkms_conf=$(find "$payload_dir/usr/src" -type f -name dkms.conf -print -quit)
			[[ -n "$installed_dkms_conf" ]] || die "installed DKMS configuration is missing: $deb"

			bash -n "$installed_dkms_conf"
			if grep -q '#MODULE_VERSION#' "$installed_dkms_conf"; then
				die "DKMS package version placeholder was not replaced: $deb"
			fi
			if ! grep -Eq '^MAKE\[[0-9]+\]="make -C \$\{kernel_source_dir\} M=' "$installed_dkms_conf"; then
				die "DKMS build does not invoke Kbuild directly: $deb"
			fi
			;;
		firmware)
			firmware="${payload_dir}${firmware_path}"
			[[ -f "$firmware" ]] || die "firmware payload is missing: $firmware_path ($deb)"

			actual_hash=$(sha256sum "$firmware" | awk '{print $1}')
			[[ "$actual_hash" == "$firmware_sha256" ]] ||
				die "firmware hash mismatch for ${firmware_path}: ${actual_hash}"

			if [[ -n "$forbid_filename" ]]; then
				forbidden=$(find "$payload_dir" -type f -name "$forbid_filename" -print -quit)
				[[ -z "$forbidden" ]] ||
					die "package contains the forbidden filename ${forbid_filename}: ${forbidden}"
			fi
			;;
	esac
done

printf 'validated %d package(s) with profile %s\n' "${#debs[@]}" "$kind"
