#!/usr/bin/env bash
# New Debian and Ubuntu servers that don't have fail2ban yet. Existing servers
# are never changed: a server only counts as new if it was set up in the last
# 30 days, worked out from the oldest of /etc/machine-id and the SSH host keys
# (both are created when a server is first built, including from a cloud
# image, and don't normally change afterwards).
#
# Also applies, whatever the server's age, where:
#   - this component installed fail2ban earlier, so its settings stay in place
#   - fleet-agent.conf has FAIL2BAN_INSTALL=yes, to opt an older server in
#
# Never applies where fail2ban was already installed some other way, on
# cPanel, CSF or Imunify360 servers (they have their own brute force
# protection), in containers, or without apt.
# shellcheck disable=SC1090
. "${FLEET_CONF:-/netmatters/fleet-agent/fleet-agent.conf}"
MAX_AGE_DAYS=30

command -v apt-get >/dev/null 2>&1 || exit 1  # release-check: portable-ok (guard)
[ -d /usr/local/cpanel ] || [ -d /etc/csf ] || [ -d /etc/sysconfig/imunify360 ] && exit 1
command -v imunify360-agent >/dev/null 2>&1 && exit 1
if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container >/dev/null 2>&1; then
  exit 1
fi

[ -f /netmatters/fail2ban/installed-by-fleet ] && exit 0
command -v fail2ban-client >/dev/null 2>&1 && exit 1
[ "${FAIL2BAN_INSTALL:-}" = "yes" ] && exit 0

oldest=""
for f in /etc/machine-id /etc/ssh/ssh_host_*_key; do
  [ -e "$f" ] || continue
  t="$(stat -c %Y "$f")"
  if [ -z "$oldest" ] || [ "$t" -lt "$oldest" ]; then oldest="$t"; fi
done
# Can't tell how old the server is, so treat it as existing
[ -n "$oldest" ] || exit 1
age_days=$(( ($(date +%s) - oldest) / 86400 ))
echo "Server set up about $age_days day(s) ago (new means under $MAX_AGE_DAYS)"
[ "$age_days" -lt "$MAX_AGE_DAYS" ]
