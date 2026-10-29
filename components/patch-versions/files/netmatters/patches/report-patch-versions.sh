#!/usr/bin/env bash
# Reports this server's installed packages and pending updates to
# $N8N_BASE/webhook/hosting-fleet-patch-versions, with the fleet token.
#
# Sends the same form fields as the older exportVersions.sh, so the n8n
# workflow reads both:
#   installed          file: yum list installed, or apt list --installed
#   type               yum or apt
#   hostname, os_version
#   kernelcare         kcarectl --uname, blank without KernelCare
#   whmversion         cPanel version, blank on servers without cPanel
#   updates_available  comma-separated package names with an update waiting
#
# N8N_BASE and FLEET_TOKEN come from /netmatters/fleet-agent/fleet-agent.conf.
#
# Usage: report-patch-versions.sh [--dry-run]

set -euo pipefail

# shellcheck disable=SC1091
. /netmatters/fleet-agent/fleet-agent.conf
WEBHOOK_URL="${N8N_BASE%/}/webhook/hosting-fleet-patch-versions"
INSTALLED=/netmatters/patches/installed.txt

if [ -f /etc/os-release ]; then
  OS_VERSION="$(. /etc/os-release && echo "$PRETTY_NAME")"
else
  OS_VERSION="$(uname -sr)"
fi

KCARE_STATUS=""
if command -v kcarectl >/dev/null 2>&1; then
  KCARE_STATUS="$(kcarectl --uname 2>/dev/null || true)"
fi

WHM_VERSION=""
[ -f /usr/local/cpanel/version ] && WHM_VERSION="$(cat /usr/local/cpanel/version)"

if command -v yum >/dev/null 2>&1; then  # release-check: portable-ok (guard)
  TYPE=yum  # release-check: portable-ok (form value)
  # check-update exits 100 when updates are waiting
  UPDATES_AVAILABLE="$(yum check-update -q 2>/dev/null | awk '/^[a-zA-Z0-9]/ {print $1}' | paste -sd, - || true)"  # release-check: portable-ok (only where yum exists)
  yum list installed > "$INSTALLED"  # release-check: portable-ok (only where yum exists)
elif command -v apt-get >/dev/null 2>&1; then  # release-check: portable-ok (guard)
  TYPE=apt  # release-check: portable-ok (form value)
  # Refreshes the package lists only, nothing is installed or upgraded
  apt-get update -qq >/dev/null || true  # release-check: portable-ok, destructive-ok (refreshes package lists only)
  UPDATES_AVAILABLE="$(apt list --upgradable 2>/dev/null | awk -F/ 'NR > 1 {print $1}' | paste -sd, - || true)"  # release-check: portable-ok (only where apt exists)
  apt list --installed > "$INSTALLED" 2>/dev/null  # release-check: portable-ok (only where apt exists)
else
  echo "No supported package manager found, nothing to report." >&2
  exit 1
fi

if [ "${1:-}" = "--dry-run" ]; then
  echo "Would POST to $WEBHOOK_URL:"
  echo "type=$TYPE"
  echo "hostname=$(hostname)"
  echo "os_version=$OS_VERSION"
  echo "kernelcare=$KCARE_STATUS"
  echo "whmversion=$WHM_VERSION"
  echo "updates_available=$UPDATES_AVAILABLE"
  echo "installed=@$INSTALLED ($(wc -l < "$INSTALLED") lines)"
  exit 0
fi

curl -fsS --retry 3 --max-time 120 -X POST "$WEBHOOK_URL" -H "X-Fleet-Token: $FLEET_TOKEN" \
  -F "installed=@$INSTALLED;type=text/plain" \
  -F "type=$TYPE" \
  -F "hostname=$(hostname)" \
  -F "os_version=$OS_VERSION" \
  -F "kernelcare=$KCARE_STATUS" \
  -F "whmversion=$WHM_VERSION" \
  -F "updates_available=$UPDATES_AVAILABLE"
echo
