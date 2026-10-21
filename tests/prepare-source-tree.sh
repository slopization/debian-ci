#!/usr/bin/env bash
# Offline integration tests; fixtures are deliberately retained for inspection.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
scripts_dir=$(realpath "$script_dir/../scripts")
for tool in git dpkg dpkg-source dpkg-parsechangelog tar xz sha256sum shellcheck; do
	command -v "$tool" >/dev/null || { printf 'Missing test dependency: %s\n' "$tool" >&2; exit 1; }
done
shellcheck -x "$0" "$scripts_dir/lib.sh" "$scripts_dir/prepare-source-tree.sh" "$scripts_dir/build-source-package.sh"

root=$(mktemp -d "${TMPDIR:-/tmp}/debian-ci-source-tests.XXXXXXXX")
trap 'printf "Test fixtures retained at %s\n" "$root"' EXIT
export LC_ALL=C TZ=UTC
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME='Source Test' GIT_AUTHOR_EMAIL='test@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_AUTHOR_DATE='2024-01-02T03:04:05Z'
export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
unset SOURCE_DATE_EPOCH

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
equal() { [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"; }
field() { sed -n "s/^$2=//p" "$1"; }
version() { (cd "$1" && dpkg-parsechangelog --show-field Version); }
pass() { printf 'PASS: %s\n' "$*"; }
fingerprint() {
	(
		cd "$1"
		git rev-parse HEAD
		git show-ref
		git status --porcelain=v1 --untracked-files=all
		git diff --binary HEAD
		git worktree list --porcelain
		git ls-files --cached --others --exclude-standard -z | sort -zu | xargs -0 sha256sum
	) | sha256sum
}
prepare() {
	local name=$1 recipe=$2
	shift 2
	mkdir -p "$root/$name"
	bash "$scripts_dir/prepare-source-tree.sh" --source "$source" --recipe "$recipe" \
		--workspace "$root/$name/tree" --suite trixie --output-file "$root/$name/prepare.out" "$@"
}
build_extract() {
	local name=$1
	bash "$scripts_dir/build-source-package.sh" --workspace "$root/$name/tree" --output-file "$root/$name/build.out"
	local dsc
	dsc=$(field "$root/$name/build.out" dsc)
	[[ -f "$dsc" ]] || fail "missing dsc for $name"
	dpkg-source --no-check -x "$dsc" "$root/$name/extracted" >"$root/$name/extract.log" 2>&1 || {
		printf 'Extraction failed; inspect %s\n' "$root/$name/extract.log" >&2
		fail "dpkg-source extraction for $name"
	}
	equal "$(<"$root/$name/extracted/hello.txt")" 'hello patched' "quilt patch for $name"
	[[ ! -e "$root/$name/extracted/untracked.txt" ]] || fail 'untracked source leaked into package'
}
reject() {
	local name=$1 expected=$2
	shift 2
	if bash "$scripts_dir/prepare-source-tree.sh" "$@" >"$root/$name.log" 2>&1; then
		fail "$name unexpectedly succeeded"
	fi
	grep -Fq -- "$expected" "$root/$name.log" || fail "$name failed for wrong reason (see $root/$name.log)"
	pass "$name rejected"
}

source="$root/source"
recipe="$root/recipe"
mkdir -p "$source" "$recipe/debian/source" "$recipe/debian/patches"
git -C "$source" init -q
printf 'hello original\n' >"$source/hello.txt"
git -C "$source" add hello.txt
git -C "$source" commit -qm 'Fixture upstream'
sha=$(git -C "$source" rev-parse HEAD)
snapshot="1.2.3+git20240102.${sha:0:12}"
# Neither a dirty tracked file nor an untracked file may enter the archive.
printf 'dirty checkout, not committed\n' >"$source/hello.txt"
printf 'untracked checkout data\n' >"$source/untracked.txt"
cat >"$recipe/debian/changelog" <<'EOF'
fixture (1.2.3-7) unstable; urgency=medium

  * Fixture recipe.

 -- Source Test <test@example.invalid>  Tue, 02 Jan 2024 03:04:05 +0000
EOF
cat >"$recipe/debian/control" <<'EOF'
Source: fixture
Section: misc
Priority: optional
Maintainer: Source Test <test@example.invalid>
Standards-Version: 4.7.0

Package: fixture
Architecture: all
Description: offline fixture
 A tiny source package used only for integration tests.
EOF
printf '3.0 (quilt)\n' >"$recipe/debian/source/format"
printf '#!/usr/bin/make -f\n%%:\n\t@true\n' >"$recipe/debian/rules"
chmod +x "$recipe/debian/rules"
printf 'fix-hello.patch\n' >"$recipe/debian/patches/series"
cat >"$recipe/debian/patches/fix-hello.patch" <<'EOF'
Description: demonstrate quilt application
Author: Source Test <test@example.invalid>
Forwarded: not-needed
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-hello original
+hello patched
EOF
git -C "$recipe" init -q
git -C "$recipe" add debian
git -C "$recipe" commit -qm 'Fixture recipe'
printf 'local recipe note\n' >"$recipe/local-note.txt"
source_before=$(fingerprint "$source")
recipe_before=$(fingerprint "$recipe")

prepare snapshot-a "$recipe"
equal "$(version "$root/snapshot-a/tree")" "$snapshot-1" 'snapshot version'
equal "$(field "$root/snapshot-a/prepare.out" source_sha)" "$sha" 'reported source SHA'
equal "$(field "$root/snapshot-a/prepare.out" upstream_version)" "$snapshot" 'reported upstream version'
equal "$(field "$root/snapshot-a/prepare.out" workspace)" "$root/snapshot-a/tree" 'reported workspace'
equal "$(<"$root/snapshot-a/tree/hello.txt")" 'hello original' 'committed source snapshot'
[[ ! -e "$root/snapshot-a/tree/.git" && ! -e "$root/snapshot-a/tree/untracked.txt" ]] || fail 'checkout metadata leaked into snapshot'
equal "$(cd "$root/snapshot-a/tree" && dpkg-parsechangelog --show-field Distribution)" trixie 'suite'
grep -Fq "$sha" "$root/snapshot-a/tree/debian/changelog" || fail 'changelog lacks source SHA'
grep -Fq 'Tue, 02 Jan 2024 03:04:05 +0000' "$root/snapshot-a/tree/debian/changelog" || fail 'changelog lacks commit date'
prepare snapshot-b "$recipe"
cmp "$root/snapshot-a/tree/debian/changelog" "$root/snapshot-b/tree/debian/changelog" || fail 'changelog is not deterministic'
orig_a=$(field "$root/snapshot-a/prepare.out" orig)
orig_b=$(field "$root/snapshot-b/prepare.out" orig)
equal "$(sha256sum <"$orig_a")" "$(sha256sum <"$orig_b")" 'repeat orig tar hash'
pass 'committed snapshots, deterministic orig hashes and changelog'
build_extract snapshot-a
build_extract snapshot-b
equal "$(sha256sum <"$root/snapshot-a/fixture_${snapshot}-1.debian.tar.xz")" \
	"$(sha256sum <"$root/snapshot-b/fixture_${snapshot}-1.debian.tar.xz")" 'repeat Debian tar hash'
equal "$(field "$root/snapshot-a/build.out" full_version)" "$snapshot-1" 'build full version'
equal "$(field "$root/snapshot-a/build.out" source_pkg)" fixture 'build source name'
pass 'source builds, deterministic Debian tar hashes and quilt extraction'

prepare tagged "$recipe" --tag v2.4.0
equal "$(version "$root/tagged/tree")" '2.4.0-1' 'v tag version'
build_extract tagged
pass 'v-prefixed release tag'

mkdir "$root/epoch-recipe"
cp -a "$recipe/debian" "$root/epoch-recipe/debian"
sed -i '1s/(1.2.3-7)/(2:1.2.3-7)/' "$root/epoch-recipe/debian/changelog"
prepare epoch "$root/epoch-recipe"
equal "$(version "$root/epoch/tree")" "2:$snapshot-1" 'epoch snapshot version'
build_extract epoch
equal "$(field "$root/epoch/build.out" dsc)" "$root/epoch/fixture_${snapshot}-1.dsc" 'epoch-free dsc filename'
equal "$(field "$root/epoch/build.out" upstream_version)" "$snapshot" 'epoch-free upstream output'
prepare epoch-tag "$root/epoch-recipe" --tag v3.0
equal "$(version "$root/epoch-tag/tree")" '2:3.0-1' 'epoch tag version'
build_extract epoch-tag
pass 'epoch preserved in versions and omitted from artifact filenames'

# Reusing a snapshot recipe must not stack +git suffixes.
mkdir "$root/pinned-recipe"
cp -a "$recipe/debian" "$root/pinned-recipe/debian"
sed -i '1s/1.2.3-7/1.2.3+git20200101.abcdef123456-9/' "$root/pinned-recipe/debian/changelog"
prepare pinned "$root/pinned-recipe"
equal "$(version "$root/pinned/tree")" "$snapshot-1" 'snapshot suffix replacement'
pass 'pinned snapshot suffix replacement'

reject invalid-tag 'tag must be a Debian-compatible version' --source "$source" --recipe "$recipe" --workspace "$root/rejected-tag" --suite trixie --tag vbad
reject invalid-suite 'invalid --suite' --source "$source" --recipe "$recipe" --workspace "$root/rejected-suite" --suite '../bad'
mkdir "$root/existing"
printf 'keep me\n' >"$root/existing/sentinel"
reject existing-workspace 'workspace must not already exist' --source "$source" --recipe "$recipe" --workspace "$root/existing" --suite trixie
equal "$(<"$root/existing/sentinel")" 'keep me' 'existing workspace unchanged'
mkdir "$root/native-recipe"
cp -a "$recipe/debian" "$root/native-recipe/debian"
printf '3.0 (native)\n' >"$root/native-recipe/debian/source/format"
reject native-recipe 'only 3.0 (quilt)' --source "$source" --recipe "$root/native-recipe" --workspace "$root/rejected-native" --suite trixie

git clone -q --no-hardlinks "$source" "$root/with-debian"
mkdir "$root/with-debian/debian"
printf 'forbidden\n' >"$root/with-debian/debian/marker"
git -C "$root/with-debian" add debian
git -C "$root/with-debian" commit -qm 'Forbidden source packaging'
reject source-with-debian 'source repository must not contain debian/' --source "$root/with-debian" --recipe "$recipe" --workspace "$root/rejected-debian" --suite trixie

git clone -q --no-hardlinks "$source" "$root/with-submodule"
# A local gitlink exercises submodule rejection without network or submodule setup.
git -C "$root/with-submodule" update-index --add --cacheinfo "160000,$sha,vendor"
git -C "$root/with-submodule" commit -qm 'Forbidden gitlink'
reject source-submodule 'source submodules are not supported' --source "$root/with-submodule" --recipe "$recipe" --workspace "$root/rejected-submodule" --suite trixie
for name in tag suite native debian submodule; do
	[[ ! -e "$root/rejected-$name" ]] || fail "$name rejection created a workspace"
done

equal "$(fingerprint "$source")" "$source_before" 'source checkout unchanged'
equal "$(fingerprint "$recipe")" "$recipe_before" 'recipe checkout unchanged'
pass 'source and recipe checkouts, refs and dirty files remain unchanged'
printf 'All prepare-source-tree/build-source-package tests passed.\n'
