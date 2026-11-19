#!/usr/bin/env bash
# Ubuntu/Debian servers running nginx, without cPanel, unless fleet-agent.conf
# has FLEET_UPDATES=0. Updates only ever run when someone presses Update PHP
# or Update nginx, so this is opt-out rather than opt-in. nm-safe-update.sh
# makes its own checks again (Apache, config tests, sites) on every run.
# shellcheck disable=SC1090
. "${FLEET_CONF:-/netmatters/fleet-agent/fleet-agent.conf}"
[ "${FLEET_UPDATES:-1}" = "0" ] && exit 1
[ -d /usr/local/cpanel ] && exit 1
command -v apt-get >/dev/null 2>&1 || exit 1  # release-check: portable-ok (guard)
command -v nginx >/dev/null 2>&1 || exit 1
exit 0
