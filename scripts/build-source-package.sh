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
		--workspace)
			workspace="$2"
			shift 2
			;;
		--output-file)
			output_file="$2"
			shift 2
			;;
		*)
			die "unknown argument: $1"
			;;
	esac
done

[[ -n "$workspace" ]] || die "--workspace is required"
[[ -d "$workspace/debian" ]] || die "no debian/ directory in $workspace"

cd "$workspace"

# CI always starts from a fresh checkout (or a fresh gbp worktree), so there is
# no need to run debian/rules clean here. Keeping it out also avoids touching
# the source tree that gbp just committed.
dpkg-source -b .

source_pkg=$(package_source_name)
full_version=$(package_full_version)
upstream_version=$(package_upstream_version)
parent_dir=$(dirname -- "$workspace")
dsc="${parent_dir}/${source_pkg}_${full_version}.dsc"

[[ -f "$dsc" ]] || die "missing generated dsc: $dsc"

shopt -s nullglob
tarballs=(
	"${parent_dir}/${source_pkg}_${full_version}.tar.xz"
	"${parent_dir}/${source_pkg}_${full_version}.debian.tar.xz"
	"${parent_dir}/${source_pkg}_${upstream_version}.orig.tar.xz"
	"${parent_dir}/${source_pkg}_${upstream_version}.orig-"*.tar.xz
)
[[ ${#tarballs[@]} -gt 0 ]] || die "source package produced no tarballs next to $dsc"

write_output "$output_file" dsc "$dsc"
write_output "$output_file" source_pkg "$source_pkg"
write_output "$output_file" full_version "$full_version"
write_output "$output_file" upstream_version "$upstream_version"
write_output "$output_file" source_parent "$parent_dir"
