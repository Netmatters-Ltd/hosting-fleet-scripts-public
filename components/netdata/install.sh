#!/usr/bin/env bash
# Installs the Netdata agent and claims it to our Netdata Cloud space with
# NETDATA_CLAIM_TOKEN and NETDATA_CLAIM_ROOMS from fleet-agent.conf
# (NETDATA_CLAIM_URL is optional, default https://app.netdata.cloud).
#
# Only on servers that don't have Netdata yet. A server that already runs it
# is left exactly as it is: Netdata keeps itself up to date.
#
# The installer is Netdata's kickstart, downloaded at install time, so the
# release checksum doesn't cover it. It installs Netdata's signed packages
# where it can.
set -euo pipefail
[ "${FLEET_TEST:-0}" = "1" ] && exit 0

if command -v netdata >/dev/null 2>&1 || [ -x /opt/netdata/bin/netdata ]; then
  echo "Netdata is already installed, leaving it as it is"
  exit 0
fi

# shellcheck disable=SC1090
. "${FLEET_CONF:-/netmatters/fleet-agent/fleet-agent.conf}"
[ -n "${NETDATA_CLAIM_TOKEN:-}" ] && [ -n "${NETDATA_CLAIM_ROOMS:-}" ] ||
  { echo "NETDATA_CLAIM_TOKEN and NETDATA_CLAIM_ROOMS must be set in fleet-agent.conf" >&2; exit 1; }

kickstart="$(mktemp)"
trap 'rm -f "$kickstart"' EXIT  # release-check: destructive-ok (mktemp file)
curl -fsSL --proto '=https' --max-time 120 -o "$kickstart" https://get.netdata.cloud/kickstart.sh
sh "$kickstart" --non-interactive --stable-channel \
  --claim-token "$NETDATA_CLAIM_TOKEN" \
  --claim-rooms "$NETDATA_CLAIM_ROOMS" \
  --claim-url "${NETDATA_CLAIM_URL:-https://app.netdata.cloud}"
