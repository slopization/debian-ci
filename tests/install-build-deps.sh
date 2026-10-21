#!/usr/bin/env bash
# Offline installer selection test: never invokes real sudo or apt.
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
helper=$(realpath "$script_dir/../scripts/install-build-deps.sh")
root=$(mktemp -d "${TMPDIR:-/tmp}/debian-ci-install-tests.XXXXXXXX")
trap 'printf "Test fixtures retained at %s\n" "$root"' EXIT
mkdir -p "$root/bin"
export TEST_ROOT="$root"
export PATH="$root/bin:$PATH"
cat >"$root/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_ROOT/commands"
if [[ "$1" == tee ]]; then
  cat >"$TEST_ROOT/repository"
fi
EOF
cat >"$root/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$TEST_SBUILD_VERSION"
EOF
chmod +x "$root/bin/sudo" "$root/bin/dpkg-query"
# Substitute only os-release, leaving the production helper without a test API.
source() {
  [[ "$1" == /etc/os-release ]] || return 1
  # shellcheck disable=SC1090
  builtin source "$TEST_ROOT/os-release"
}
export -f source
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run() {
  printf 'ID=%s\nVERSION_ID=%s\n' "$1" "$2" >"$root/os-release"
  : >"$root/commands"
  : >"$root/repository"
  TEST_SBUILD_VERSION="$3" bash "$helper"
}
run ubuntu 24.04 '0.88.3ubuntu2~bpo24.04.1'
grep -Fxq 'deb http://archive.ubuntu.com/ubuntu noble-backports main universe' "$root/repository" || fail 'missing official backports source'
grep -q 'sbuild/noble-backports libsbuild-perl/noble-backports' "$root/commands" || fail 'backport packages not explicitly selected'
grep -Fxq 'apt-get update' "$root/commands" || fail 'package index not refreshed'
for platform in 'ubuntu 26.04' 'debian 13'; do
  read -r distro release <<<"$platform"
  run "$distro" "$release" '0.89.3'
  [[ ! -s "$root/repository" ]] || fail 'unnecessary backports source added'
  grep -q 'sbuild$' "$root/commands" || fail 'default sbuild package not installed'
  ! grep -q 'noble-backports' "$root/commands" || fail 'backports used on another release'
done
if run ubuntu 24.04 '0.85.10ubuntu0.2' >"$root/old-version.log" 2>&1; then
  fail 'old ABI-incompatible sbuild accepted'
fi
grep -q 'sbuild >= 0.88.3 required' "$root/old-version.log" || fail 'missing clear version error'
printf 'PASS: Noble official backports, newer Ubuntu/Debian defaults, old-version rejection\n'
