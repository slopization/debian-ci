#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

workspace=""
generated_branch="ci/build"
upstream_branch="ci/upstream"
download_dir=""
output_file=""

while (($#)); do
	case "$1" in
		--workspace)
			workspace="$2"
			shift 2
			;;
		--generated-branch)
			generated_branch="$2"
			shift 2
			;;
		--upstream-branch)
			upstream_branch="$2"
			shift 2
			;;
		--download-dir)
			download_dir="$2"
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

# Run this from the recipe checkout so repo_root() points at the package repo,
# not at a CI checkout placed next to it.
repo=$(repo_root)
[[ -d "$repo/debian" ]] || die "missing debian/ directory in $repo; run from the recipe checkout"

ensure_git_identity

download_dir=${download_dir:-"$(dirname -- "$workspace")"}
mkdir -p "$download_dir"

# The generated branches and tags are scratch space for this build only. Use a
# private ci/ namespace so a maintainer's own branches and upstream tags are
# never modified, and remove leftovers from a previous run.
while IFS= read -r tag; do
	git tag -d "$tag" >/dev/null
done < <(git tag -l 'ci/upstream/*')
git branch -D "$upstream_branch" >/dev/null 2>&1 || true
git branch -D "$generated_branch" >/dev/null 2>&1 || true

git worktree remove --force "$workspace" >/dev/null 2>&1 || true
rm -rf "$workspace"
git worktree add --force -B "$generated_branch" "$workspace" HEAD >/dev/null

ensure_empty_branch "$upstream_branch"

cd "$workspace"

source_pkg=$(package_source_name)
full_version=$(package_full_version)
upstream_version=$(package_upstream_version)
distribution=$(package_distribution)

uscan --check-dirname-level 0 --download-current-version --rename --destdir "$download_dir"

main_orig="${download_dir}/${source_pkg}_${upstream_version}.orig.tar.xz"
opensbi_orig="${download_dir}/${source_pkg}_${upstream_version}.orig-opensbi.tar.xz"
[[ -f "$main_orig" ]] || die "missing main orig tarball: $main_orig"
[[ -f "$opensbi_orig" ]] || die "missing component orig tarball: $opensbi_orig"

gbp import-orig \
	--no-interactive \
	--no-pristine-tar \
	--debian-branch="$generated_branch" \
	--upstream-branch="$upstream_branch" \
	--upstream-tag='ci/upstream/%(version)s' \
	--upstream-version "$upstream_version" \
	"$main_orig"

write_output "$output_file" workspace "$workspace"
write_output "$output_file" download_dir "$download_dir"
write_output "$output_file" source_pkg "$source_pkg"
write_output "$output_file" upstream_version "$upstream_version"
write_output "$output_file" full_version "$full_version"
write_output "$output_file" distribution "$distribution"
write_output "$output_file" main_orig "$main_orig"
write_output "$output_file" component_orig "$opensbi_orig"
write_output "$output_file" generated_branch "$generated_branch"
write_output "$output_file" upstream_branch "$upstream_branch"
