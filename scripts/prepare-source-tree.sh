#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

source_dir=""
recipe_dir=""
workspace=""
suite=""
tag=""
output_file=""
while (($#)); do
	case "$1" in
		--source) source_dir="$2"; shift 2 ;;
		--recipe) recipe_dir="$2"; shift 2 ;;
		--workspace) workspace="$2"; shift 2 ;;
		--suite) suite="$2"; shift 2 ;;
		--tag) tag="$2"; shift 2 ;;
		--output-file) output_file="$2"; shift 2 ;;
		*) die "unknown argument: $1" ;;
	esac
done

[[ -n "$source_dir" && -n "$recipe_dir" && -n "$workspace" ]] || die "--source, --recipe and --workspace are required"
source_dir=$(realpath -e -- "$source_dir")
recipe_dir=$(realpath -e -- "$recipe_dir")
workspace=$(realpath -m -- "$workspace")
[[ "$suite" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || die "invalid --suite"
[[ ! -e "$workspace" ]] || die "workspace must not already exist: $workspace"
[[ -d "$recipe_dir/debian" && ! -L "$recipe_dir/debian" ]] || die "recipe must contain a real debian/ directory"
[[ -f "$recipe_dir/debian/changelog" && ! -L "$recipe_dir/debian/changelog" ]] || die "recipe must contain a real debian/changelog"
[[ -f "$recipe_dir/debian/source/format" ]] || die "recipe must declare 3.0 (quilt)"
[[ "$(<"$recipe_dir/debian/source/format")" == '3.0 (quilt)' ]] || die "only 3.0 (quilt) recipes are supported"
if git -C "$source_dir" cat-file -e HEAD:debian 2>/dev/null; then
	die "source repository must not contain debian/; move packaging to the recipe repository"
fi
# git archive does not include submodule content. Reject rather than silently
# producing an incomplete source package; vendor dependencies in the source repo.
if git -C "$source_dir" ls-tree -r HEAD | grep '^160000 ' >/dev/null; then
	die "source submodules are not supported; vendor required sources before building"
fi

source_sha=$(git -C "$source_dir" rev-parse HEAD)
source_date=$(git -C "$source_dir" show -s --format=%ct HEAD)
short_sha=${source_sha:0:12}
old_version=$(cd "$recipe_dir" && package_full_version)
source_pkg=$(cd "$recipe_dir" && package_source_name)
[[ "$source_pkg" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "invalid source package name"
epoch=""
if [[ "$old_version" == *:* ]]; then
	epoch="${old_version%%:*}:"
fi
if [[ -n "$tag" ]]; then
	upstream_version=${tag#v}
	[[ "$upstream_version" =~ ^[0-9][A-Za-z0-9.+~\-]*$ ]] || die "tag must be a Debian-compatible version, optionally prefixed with v: $tag"
else
	upstream_version=${old_version#"$epoch"}
	upstream_version=${upstream_version%-*}
	# Do not accumulate snapshot suffixes if a snapshot recipe is pinned.
	upstream_version=$(printf '%s' "$upstream_version" | sed -E 's/\+git[0-9]{8}\.[0-9a-f]+$//')
	upstream_version+="+git$(date -u -d "@$source_date" +%Y%m%d).$short_sha"
fi
full_version="${epoch}${upstream_version}-1"
dpkg --validate-version "$full_version" || die "invalid generated Debian version: $full_version"

parent_dir=$(dirname -- "$workspace")
orig="${parent_dir}/${source_pkg}_${upstream_version}.orig.tar.xz"
[[ ! -e "$orig" ]] || die "orig tarball already exists: $orig"
mkdir -p "$workspace"
# Both the orig and unpacked tree are the same committed snapshot, without .git.
# git archive uses the commit timestamp and xz has no embedded wall-clock time.
git -C "$source_dir" archive --format=tar --prefix="${source_pkg}-${upstream_version}/" HEAD | xz -T1 > "$orig"
tar -xJf "$orig" --strip-components=1 -C "$workspace"
cp -a "$recipe_dir/debian" "$workspace/debian"

# The version bump exists only in this disposable build tree. In particular,
# neither checkout is modified and no recipe branch, tag, or PR is created.
{
	printf '%s (%s) %s; urgency=medium\n\n' "$source_pkg" "$full_version" "$suite"
	printf '  * Build source commit %s with the pinned Debian recipe.\n\n' "$source_sha"
	printf ' -- Debian CI <debian-ci@users.noreply.github.com>  %s\n\n' "$(LC_ALL=C date -u -R -d "@$source_date")"
	cat "$recipe_dir/debian/changelog"
} > "$workspace/debian/changelog"

write_output "$output_file" workspace "$workspace"
write_output "$output_file" full_version "$full_version"
write_output "$output_file" upstream_version "$upstream_version"
write_output "$output_file" source_sha "$source_sha"
write_output "$output_file" orig "$orig"
printf 'Building %s %s for %s (source %s)\n' "$source_pkg" "$full_version" "$suite" "$source_sha"
