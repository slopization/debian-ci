#!/usr/bin/env bash
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

dsc=""
artifact_dir=""
host_arch=native
while (($#)); do
	case "$1" in
		--dsc) dsc="$2"; shift 2 ;;
		--artifact-dir) artifact_dir="$2"; shift 2 ;;
		--host-arch) host_arch="$2"; shift 2 ;;
		*) die "unknown argument: $1" ;;
	esac
done
[[ -f "$dsc" && -n "$artifact_dir" ]] || die "--dsc and --artifact-dir are required"
dsc=$(realpath -e "$dsc")
artifact_dir=$(realpath -m "$artifact_dir")
source_dir=$(dirname -- "$dsc")
build_dir="$source_dir/sbuild-out"
suite=${SBUILD_SUITE:-trixie}
[[ "$suite" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || die "invalid suite"
arch=$(dpkg --print-architecture)
[[ "$host_arch" != native ]] || host_arch="$arch"
[[ "$host_arch" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid host architecture"
chroot="$HOME/.cache/sbuild/$suite-$arch.tar"
mkdir -p "$build_dir" "$artifact_dir" "$(dirname -- "$chroot")"

# Always retain source files and logs, including failed sbuild runs. dpkg's
# filenames already omit epochs; never use the changelog version as a filename.
collect_artifacts() {
	local file
	shopt -s nullglob globstar
	for file in "$source_dir"/*.dsc "$source_dir"/*.tar.* \
		"$build_dir"/**/*.deb "$build_dir"/**/*.udeb \
		"$build_dir"/**/*.changes "$build_dir"/**/*.buildinfo "$build_dir"/**/*.build; do
		[[ ! -f "$file" ]] || cp -L --preserve=mode,timestamps "$file" "$artifact_dir/"
	done
}
trap collect_artifacts EXIT

getsubids "$(id -un)" >/dev/null
getsubids -g "$(id -un)" >/dev/null
# Ubuntu's archive keyring can predate the target Debian release. Fetch the
# current Debian keyring over HTTPS rather than disabling signature validation.
keyring_dir=$(mktemp -d)
index=https://deb.debian.org/debian/pool/main/d/debian-archive-keyring/
package=$(curl -fsSL "$index" | grep -oE 'debian-archive-keyring_[^"<>]+_all\.deb' | sort -uV | tail -n 1)
[[ -n "$package" ]] || die "cannot locate Debian archive keyring"
curl -fsSL "$index$package" -o "$keyring_dir/keyring.deb"
dpkg-deb -x "$keyring_dir/keyring.deb" "$keyring_dir"
mmdebstrap --variant=buildd --keyring "$keyring_dir/usr/share/keyrings/debian-archive-keyring.gpg" \
	"$suite" "$chroot" http://deb.debian.org/debian

# Keep the chroot native; --arch would set BOTH build and host architectures.
# Cross builds default to arch-any only in sbuild. Explicit --arch-all also
# produces the kernel's linux-source package in this same invocation (-b),
# retaining separate -arch/-indep debhelper targets and their build dependencies.
# A PTY avoids sbuild/unshare terminal issues on hosted Ubuntu and under act.
printf -v command '%q ' sbuild --batch --chroot-mode=unshare --chroot "$chroot" \
	--dist "$suite" --build "$arch" --host "$host_arch" --arch-all --build-dir "$build_dir" \
	--no-run-lintian --no-run-autopkgtest --no-run-piuparts "$dsc"
script -qefc "$command" /dev/null
shopt -s nullglob globstar
binaries=("$build_dir"/**/*.deb)
((${#binaries[@]})) || die "sbuild produced no .deb files"
