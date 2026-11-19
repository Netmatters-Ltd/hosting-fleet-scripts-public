#!/usr/bin/env bash
# Sets the script's permissions and makes the folder for rollback copies.
# dpkg-repack isn't installed here: without it, nm-safe-update.sh uses the apt
# cache or apt-get download for rollback copies, and refuses any update it
# can't make one for.
set -euo pipefail
root="${APPLY_ROOT:-/}"; root="${root%/}"
chmod 0755 "$root/netmatters/updates/nm-safe-update.sh"
chmod 0644 "$root/netmatters/fleet-agent/on-demand/update-php" "$root/netmatters/fleet-agent/on-demand/update-nginx"
mkdir -p "$root/netmatters/updates"
chmod 0700 "$root/netmatters/updates"
exit 0
