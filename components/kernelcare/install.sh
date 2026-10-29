#!/usr/bin/env bash
# Installs KernelCare and registers it with KERNELCARE_KEY from
# fleet-agent.conf, then applies the latest live kernel patches.
#
# Only on servers that don't have KernelCare yet. A server that already runs
# it (including ones set up by hand before the fleet agent) is left exactly
# as it is, so a re-run never re-registers or changes anything.
#
# The installer is CloudLinux's, downloaded at install time, so the release
# checksum doesn't cover it. It adds CloudLinux's signed package repository
# and installs the kernelcare package from it.
set -euo pipefail
[ "${FLEET_TEST:-0}" = "1" ] && exit 0

if command -v kcarectl >/dev/null 2>&1; then
  echo "KernelCare is already installed, leaving it as it is"
  kcarectl --info || true
  exit 0
fi

# shellcheck disable=SC1090
. "${FLEET_CONF:-/netmatters/fleet-agent/fleet-agent.conf}"
[ -n "${KERNELCARE_KEY:-}" ] || { echo "KERNELCARE_KEY is not set in fleet-agent.conf" >&2; exit 1; }

curl -fsSL --proto '=https' --max-time 120 https://kernelcare.com/installer | bash  # release-check: download-ok (CloudLinux's installer, kept out of our repo)
kcarectl --register "$KERNELCARE_KEY"
kcarectl --info
sleep 5
kcarectl --update
