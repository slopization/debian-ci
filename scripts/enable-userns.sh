#!/usr/bin/env bash
set -euo pipefail

current_user=$(id -un)

alloc_subid() {
	local file="$1"

	[[ -f "$file" ]] || sudo touch "$file"

	awk -F: 'BEGIN { max = 100000 } NF >= 3 { end = $2 + $3; if (end > max) max = end } END { print max + 65536 }' "$file"
}

if ! command -v getsubids >/dev/null 2>&1; then
	sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y uidmap
fi

if ! getsubids "$current_user" >/dev/null 2>&1; then
	next_subuid=$(alloc_subid /etc/subuid)
	printf '%s:%s:65536\n' "$current_user" "$next_subuid" | sudo tee -a /etc/subuid >/dev/null
fi

if ! getsubids -g "$current_user" >/dev/null 2>&1; then
	next_subgid=$(alloc_subid /etc/subgid)
	printf '%s:%s:65536\n' "$current_user" "$next_subgid" | sudo tee -a /etc/subgid >/dev/null
fi

if [[ -e /proc/sys/kernel/unprivileged_userns_clone ]]; then
	sudo sysctl -w kernel.unprivileged_userns_clone=1 >/dev/null
fi
