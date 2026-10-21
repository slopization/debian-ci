#!/usr/bin/env bash
set -euo pipefail

# Publishing has a separate workflow and never installs tools in build jobs.
packages=(
	curl
	dpkg-dev
	git
	jq
	mmdebstrap
	xz-utils
)

# Noble's release sbuild copies its host apt solver into the Debian chroot,
# where libapt's ABI differs. The official backport copies only the portable
# Perl cross resolver and uses the chroot's own apt-utils solver instead.
# shellcheck source=/etc/os-release
source /etc/os-release
if [[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]]; then
	printf '%s\n' 'deb http://archive.ubuntu.com/ubuntu noble-backports main universe' |
		sudo tee /etc/apt/sources.list.d/debian-ci-backports.list >/dev/null
	packages+=(sbuild/noble-backports libsbuild-perl/noble-backports)
else
	packages+=(sbuild)
fi

sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
version=$(dpkg-query -W -f='${Version}' sbuild)
if ! dpkg --compare-versions "$version" ge 0.88.3; then
	printf 'error: sbuild >= 0.88.3 required for portable cross resolution; installed %s\n' "$version" >&2
	exit 1
fi
