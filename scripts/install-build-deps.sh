#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

mode=${CI_MODE:-native}
publish=${CI_PUBLISH:-false}

case "$mode" in
	native | gbp) ;;
	*) die "unsupported CI_MODE: $mode" ;;
esac

packages=(
	curl
	debootstrap
	devscripts
	mmdebstrap
	sbuild
)

if [[ "$mode" == "gbp" ]]; then
	packages+=(git-buildpackage)
fi

if [[ "$publish" == "true" ]]; then
	packages+=(gnupg ruby)
fi

sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"

if [[ "$publish" == "true" ]]; then
	sudo gem install --no-document deb-s3
fi
