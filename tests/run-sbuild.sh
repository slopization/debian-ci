#!/usr/bin/env bash
# Offline command-contract tests; no network, namespaces, chroot, or real build.
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
helper=$(realpath "$script_dir/../scripts/run-sbuild.sh")
root=$(mktemp -d "${TMPDIR:-/tmp}/debian-ci-sbuild-tests.XXXXXXXX")
trap 'printf "Test fixtures retained at %s\n" "$root"' EXIT
mkdir -p "$root/bin"
export TEST_ROOT="$root"
export PATH="$root/bin:$PATH"
# One dispatcher provides fake external commands while retaining real shell,
# realpath, mkdir and artifact collection behavior.
cat >"$root/bin/fake" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${0##*/}" in
  dpkg) printf 'amd64\n' ;;
  getsubids) : ;;
  curl) printf 'debian-archive-keyring_1_all.deb\n' ;;
  dpkg-deb) : ;;
  mmdebstrap) printf '%s\n' "$*" >>"$TEST_ROOT/bootstrap" ;;
  script) bash -c "$2" ;;
  sbuild)
    printf '%s\n' "$*" >>"$TEST_ROOT/commands"
    out=''
    while (($#)); do
      case "$1" in --build-dir) out=$2; shift 2 ;; *) shift ;; esac
    done
    mkdir -p "$out/nested"
    touch "$out/nested/kernel_riscv64.deb" "$out/nested/linux-source_all.deb" \
      "$out/nested/kernel.udeb" "$out/kernel.changes" "$out/kernel.buildinfo" "$out/kernel.build" \
      "$out/kernel_2026-10-21T01:02:03Z.build"
    exit "${FAKE_STATUS:-0}"
    ;;
esac
EOF
chmod +x "$root/bin/fake"
for command in dpkg getsubids curl dpkg-deb mmdebstrap script sbuild; do
  ln -s fake "$root/bin/$command"
done
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run() {
  local name=$1
  shift
  mkdir -p "$root/$name/source"
  touch "$root/$name/source/kernel.dsc" "$root/$name/source/kernel.orig.tar.xz" \
    "$root/$name/source/kernel.debian.tar.xz"
  HOME="$root/$name/home" bash "$helper" --dsc "$root/$name/source/kernel.dsc" \
    --artifact-dir "$root/$name/artifacts" "$@"
}
run native
grep -q -- '--build amd64 --host amd64 --arch-all' "$root/commands" || fail 'native full build changed'
run cross --host-arch riscv64
grep -q -- '--build amd64 --host riscv64 --arch-all' "$root/commands" || fail 'cross build must retain all packages'
! grep -q -- '--arch riscv64' "$root/commands" || fail 'cross build incorrectly uses foreign chroot'
grep -q -- 'trixie-amd64.tar' "$root/bootstrap" || fail 'native chroot missing'
! grep -q -- 'trixie-riscv64.tar' "$root/bootstrap" || fail 'foreign chroot created'
for file in kernel_riscv64.deb linux-source_all.deb kernel.udeb kernel.changes kernel.buildinfo kernel.build kernel_2026-10-21T01-02-03Z.build kernel.dsc kernel.orig.tar.xz kernel.debian.tar.xz; do
  [[ -f "$root/cross/artifacts/$file" ]] || fail "missing artifact: $file"
done
if FAKE_STATUS=23 run failed --host-arch riscv64; then
  fail 'sbuild error swallowed'
else
  [[ $? == 23 ]] || fail 'sbuild status not preserved'
fi
[[ -f "$root/failed/artifacts/kernel.build" && -f "$root/failed/artifacts/kernel.dsc" ]] || fail 'failed build artifacts lost'
if run invalid --host-arch 'riscv64;false'; then fail 'invalid host accepted'; fi
printf 'PASS: native, cross arch+all, native chroot, artifact collection, failure status, invalid host\n'
