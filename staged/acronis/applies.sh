#!/usr/bin/env bash
# Servers whose fleet-agent.conf has ACRONIS_TOKEN (the registration token for
# the customer's own Acronis tenant, so only servers that have backup), that
# don't have Acronis yet, aren't containers and are x86_64.
#
# Every rule here skips quietly. The rules that need someone to act (disk,
# ports, build packages, CPU and RAM) are checked by install-acronis.sh,
# which raises an Admin task through n8n.
# shellcheck disable=SC1090
. "${FLEET_CONF:-/netmatters/fleet-agent/fleet-agent.conf}"
[ -n "${ACRONIS_TOKEN:-}" ] || exit 1
[ -d /usr/lib/Acronis ] && exit 1
[ "$(uname -m)" = "x86_64" ] || exit 1
if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container >/dev/null 2>&1; then
  exit 1
fi
exit 0
