#!/usr/bin/env bash
set -euo pipefail

# Publishing has a separate workflow and never installs tools in build jobs.
packages=(
	curl
	dpkg-dev
	git
	jq
	mmdebstrap
	sbuild
	xz-utils
)

sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
