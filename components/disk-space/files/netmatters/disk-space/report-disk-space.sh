#!/usr/bin/env bash
# Measures disk usage per customer folder on this server and POSTs it to n8n
# as a tab-separated `du` file (field "csv") plus the hostname.
#
# Settings, from /netmatters/fleet-agent/fleet-agent.conf (and the older
# /netmatters/disk-space/config if present):
#   N8N_BASE                n8n address; posts to $N8N_BASE/webhook/hosting-fleet-disk-space
#   FLEET_TOKEN             sent as X-Fleet-Token
#   DISK_PATHS              space-separated folders or globs to measure instead
#                           of discovering them
#
# Which folders are measured, first match wins:
#   1. DISK_PATHS
#   2. cPanel: every account in /var/cpanel/users, at its real home directory
#   3. Forge: each site folder under /home/forge
#   4. Anything else: the home directory of every normal login user
# The last part of each path must be the account or site name, as n8n
# matches on it.
#
# Usage: report-disk-space.sh [--dry-run]

set -euo pipefail

# shellcheck disable=SC1091
. /netmatters/fleet-agent/fleet-agent.conf
# DISK_PATHS from the older per-script config still applies; its n8n
# address and auth header don't
DISK_PATHS="${DISK_PATHS:-}"
OLD_CONFIG=/netmatters/disk-space/config
if [ -r "$OLD_CONFIG" ] && [ -z "$DISK_PATHS" ]; then
  # shellcheck disable=SC1090
  DISK_PATHS="$(. "$OLD_CONFIG"; printf '%s' "${DISK_PATHS:-}")"
fi
WEBHOOK_URL="${N8N_BASE%/}/webhook/hosting-fleet-disk-space"

# ---- Work out which folders to measure ----
paths=()
source_desc=""
add_path() {
  local p
  p="$(readlink -f -- "$1" 2>/dev/null || true)"
  [ -n "$p" ] && [ -d "$p" ] && [ "$p" != "/" ] && paths+=("$p")
}

if [ -n "$DISK_PATHS" ]; then
  source_desc="DISK_PATHS"
  for pattern in $DISK_PATHS; do   # unquoted on purpose, so globs expand
    add_path "$pattern"
  done
elif [ -d /var/cpanel/users ]; then
  source_desc="cPanel accounts"
  for f in /var/cpanel/users/*; do
    user="$(basename "$f")"
    [ "$user" = "system" ] && continue
    home="$(getent passwd "$user" | cut -d: -f6)"
    [ -n "$home" ] && add_path "$home"
  done
elif [ -d /home/forge ]; then
  source_desc="Forge sites"
  for d in /home/forge/*/; do
    add_path "$d"
  done
else
  source_desc="login users"
  uid_min="$(awk '/^UID_MIN/ {print $2}' /etc/login.defs 2>/dev/null)"
  uid_max="$(awk '/^UID_MAX/ {print $2}' /etc/login.defs 2>/dev/null)"
  while IFS=: read -r _ _ uid _ _ home _; do
    [ "$uid" -ge "${uid_min:-1000}" ] && [ "$uid" -le "${uid_max:-60000}" ] || continue
    add_path "$home"
  done < <(getent passwd)
fi

# One entry per real folder, even if two accounts share one
mapfile -t paths < <(printf '%s\n' "${paths[@]+"${paths[@]}"}" | sed '/^$/d' | sort -u)
if [ "${#paths[@]}" -eq 0 ]; then
  echo "No folders found to measure (looked at: $source_desc) - set DISK_PATHS." >&2
  exit 1
fi

# ---- Measure (sizes in MB; files vanishing mid-run aren't fatal) ----
report="$(mktemp)"
trap 'rm -f "$report"' EXIT
nice_cmd=(nice -n 19)
command -v ionice >/dev/null 2>&1 && nice_cmd+=(ionice -c3)
"${nice_cmd[@]}" du -sm -- "${paths[@]}" > "$report" 2>/dev/null || true
if [ ! -s "$report" ]; then
  echo "du returned nothing for ${#paths[@]} folder(s) - nothing to report." >&2
  exit 1
fi

if [ "${1:-}" = "--dry-run" ]; then
  echo "Hostname: $(hostname)"
  echo "Folders from: $source_desc (${#paths[@]})"
  echo "Would POST to: $WEBHOOK_URL"
  echo "MB	path"
  cat "$report"
  exit 0
fi

cp "$report" /netmatters/disk-space/last-report.tsv 2>/dev/null || true

curl -fsS --retry 3 --max-time 120 -X POST "$WEBHOOK_URL" -H "X-Fleet-Token: $FLEET_TOKEN" \
  -F "csv=@$report" \
  -F "hostname=$(hostname)"
echo
