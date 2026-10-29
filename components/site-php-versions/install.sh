#!/usr/bin/env bash
# Takes over from the older one-line installer, whose config file and
# /etc/cron.d/report-site-php-versions are no longer used.
set -euo pipefail
root="${APPLY_ROOT:-/}"; root="${root%/}"
chmod 0755 "$root/netmatters/php-audit/report-site-php-versions-nginx.sh"
[ "${FLEET_TEST:-0}" = "1" ] && exit 0
rm -f /netmatters/php-audit/config /etc/cron.d/report-site-php-versions  # release-check: destructive-ok (old config and cron file this release replaces)
