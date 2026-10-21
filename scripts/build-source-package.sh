#!/usr/bin/env bash
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

workspace=""
output_file=""
while (($#)); do
	case "$1" in
		--workspace) workspace="$2"; shift 2 ;;
		--output-file) output_file="$2"; shift 2 ;;
		*) die "unknown argument: $1" ;;
	esac
done
[[ -d "$workspace/debian" ]] || die "--workspace must contain debian/"
cd "$workspace"
# Quilt patches remain in debian/patches; dpkg-source applies them on extraction.
dpkg-source -b .
version=$(package_full_version)
dsc="$(dirname -- "$PWD")/$(package_source_name)_${version#*:}.dsc"
[[ -f "$dsc" ]] || die "missing generated dsc: $dsc"
write_output "$output_file" dsc "$dsc"
write_output "$output_file" source_pkg "$(package_source_name)"
write_output "$output_file" full_version "$version"
write_output "$output_file" upstream_version "$(package_upstream_version)"
