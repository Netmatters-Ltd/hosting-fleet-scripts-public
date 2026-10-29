#!/usr/bin/env bash
# Takes over from the older Forge recipe, which wrote
# /netmatters/patches/exportVersions.sh and ran it from root's crontab at a
# random time, leaving /etc/cron.d/netmatters-patch-versions as the only
# schedule.
set -euo pipefail
root="${APPLY_ROOT:-/}"; root="${root%/}"
chmod 0755 "$root/netmatters/patches/report-patch-versions.sh"
[ "${FLEET_TEST:-0}" = "1" ] && exit 0
current="$(crontab -l 2>/dev/null || true)"
if printf '%s\n' "$current" | grep -q '/netmatters/patches/exportVersions\.sh'; then
  printf '%s\n' "$current" > "/netmatters/fleet-agent/state/root-crontab.patch-versions.$(date +%Y%m%d%H%M%S).bak"
  printf '%s\n' "$current" | { grep -v '/netmatters/patches/exportVersions\.sh' || true; } | crontab -  # release-check: destructive-ok (drops only the old patch job, backup taken above)
  echo "Removed the old patch versions job from root's crontab"
fi
rm -f /netmatters/patches/exportVersions.sh  # release-check: destructive-ok (old script this release replaces)
