#!/usr/bin/env bash
# Reports every installed PHP version on this server to
# $N8N_BASE/webhook/hosting-fleet-php-versions, with the fleet token.
#
# Covers all three layouts we run, so one script works everywhere:
#   /usr/bin/phpX.Y                       Ubuntu/Debian (distro or Sury)
#   /opt/cpanel/ea-phpXX/root/usr/bin/php cPanel EasyApache
#   /opt/alt/phpXX/usr/bin/php            CloudLinux alt-php
# CloudLinux's internal PHP and Imunify's bundled PHP are skipped, as no
# customer site runs on them. A server with no PHP sends an empty list, which
# the matrix shows as "confirmed, no PHP installed".
#
# N8N_BASE and FLEET_TOKEN come from /netmatters/fleet-agent/fleet-agent.conf.
#
# Usage: report-php-versions.sh [--dry-run]

set -euo pipefail

# shellcheck disable=SC1091
. /netmatters/fleet-agent/fleet-agent.conf
WEBHOOK_URL="${N8N_BASE%/}/webhook/hosting-fleet-php-versions"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

fpm_restarted_for() {
  local unit="$1"
  if systemctl list-unit-files "${unit}.service" >/dev/null 2>&1 \
      && systemctl is-enabled "$unit" >/dev/null 2>&1; then
    systemctl show "$unit" --property=ActiveEnterTimestamp --value 2>/dev/null || true
  fi
}

entries=()
add_entry() {
  local bin="$1" pkg="$2" unit="$3" line version compiled fpm
  line="$("$bin" -v 2>/dev/null | head -1)"
  version="$(echo "$line" | grep -oP '(?<=PHP )[0-9.]+' || true)"
  compiled="$(echo "$line" | grep -oP '(?<=built: )[^)]+' || true)"
  fpm="$(fpm_restarted_for "$unit")"
  entries+=("$(printf '{"version":"%s","compiled":"%s","fpm_restarted":"%s","package":"%s"}' \
    "${version:-unknown}" "${compiled:-unknown}" "${fpm:-no fpm service found}" "$pkg")")
}

for bin in /usr/bin/php[0-9]*.[0-9]*; do
  [ -x "$bin" ] || continue
  bn="$(basename "$bin")"
  [[ "$bn" =~ ^php([0-9]+\.[0-9]+)$ ]] || continue
  v="${BASH_REMATCH[1]}"
  add_entry "$bin" "" "php${v}-fpm"
done

for bin in /opt/cpanel/ea-php*/root/usr/bin/php /opt/alt/php*/usr/bin/php; do
  [ -x "$bin" ] || continue
  case "$bin" in
    /opt/cpanel/ea-php*) pkg="$(echo "$bin" | sed -E 's#^/opt/cpanel/(ea-php[^/]+)/.*#\1#')" ;;
    /opt/alt/php*)       pkg="$(echo "$bin" | sed -E 's#^/opt/alt/(php[^/]+)/.*#\1#')" ;;
  esac
  case "$pkg" in
    php-internal|*imunify*) continue ;;
  esac
  add_entry "$bin" "$pkg" "${pkg}-php-fpm"
done

php_json="$(IFS=,; echo "${entries[*]+"${entries[*]}"}")"
payload="$(printf '{"hostname":"%s","php":[%s]}' "$HOSTNAME_FQDN" "$php_json")"

if [ "${1:-}" = "--dry-run" ]; then
  echo "Would POST to $WEBHOOK_URL:"
  echo "$payload"
  exit 0
fi

curl -fsS --max-time 60 -X POST "$WEBHOOK_URL" -H "X-Fleet-Token: $FLEET_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$payload"
echo
