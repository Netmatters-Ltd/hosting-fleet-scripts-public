#!/usr/bin/env bash
# Servers whose fleet-agent.conf has KERNELCARE_KEY, and that aren't
# containers (KernelCare patches the host's kernel, which a container can't).
# shellcheck disable=SC1090
. "${FLEET_CONF:-/netmatters/fleet-agent/fleet-agent.conf}"
[ -n "${KERNELCARE_KEY:-}" ] || exit 1
if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container >/dev/null 2>&1; then
  exit 1
fi
exit 0
