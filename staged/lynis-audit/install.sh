#!/usr/bin/env bash
# Replaces the older root crontab entry (marked "netmatters-lynis-audit")
# with the release-managed /etc/cron.d/netmatters-lynis-audit.
set -euo pipefail
root="${APPLY_ROOT:-/}"; root="${root%/}"
chmod 0755 "$root/netmatters/lynis/run-lynis-audit.sh"
[ "${FLEET_TEST:-0}" = "1" ] && exit 0
current="$(crontab -l 2>/dev/null || true)"
if printf '%s\n' "$current" | grep -q 'netmatters-lynis-audit'; then
  printf '%s\n' "$current" > "/netmatters/fleet-agent/state/root-crontab.lynis.$(date +%Y%m%d%H%M%S).bak"
  # Drops the job line and Ansible's "#Ansible: netmatters-lynis-audit" comment
  printf '%s\n' "$current" | { grep -v 'netmatters-lynis-audit' || true; } | crontab -
  echo "Removed the old Lynis job from root's crontab"
fi
