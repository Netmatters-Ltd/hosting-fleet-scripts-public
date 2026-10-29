#!/usr/bin/env bash
# Takes over from the old n8n-served installer and the hand-added crontab
# one-liner, leaving /etc/cron.d/netmatters-disk-space as the only schedule.
set -euo pipefail
root="${APPLY_ROOT:-/}"; root="${root%/}"
chmod 0755 "$root/netmatters/disk-space/report-disk-space.sh"
[ "${FLEET_TEST:-0}" = "1" ] && exit 0
rm -f /etc/cron.d/report-disk-space
current="$(crontab -l 2>/dev/null || true)"
# The old one-liner ran du and posted to the webhook's UUID path
pattern='server_space\.log|du .*/webhook/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
if printf '%s\n' "$current" | grep -qE "$pattern"; then
  printf '%s\n' "$current" > "/netmatters/fleet-agent/state/root-crontab.disk-space.$(date +%Y%m%d%H%M%S).bak"
  printf '%s\n' "$current" | { grep -vE "$pattern" || true; } | crontab -
  echo "Removed the old disk space one-liner from root's crontab"
fi
