#!/usr/bin/env bash
set -euo pipefail

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

package_source_name() {
	dpkg-parsechangelog --show-field Source
}

package_full_version() {
	dpkg-parsechangelog --show-field Version
}

package_upstream_version() {
	package_full_version | sed 's/^[0-9]*://; s/-[^-]*$//'
}

write_output() {
	local output_file="$1" key="$2" value="$3"
	if [[ -n "$output_file" ]]; then
		printf '%s=%s\n' "$key" "$value" >>"$output_file"
	fi
}
