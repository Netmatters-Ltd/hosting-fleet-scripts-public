#!/usr/bin/env bash
# Installs fail2ban from the distribution's packages and makes sure the SSH
# jail is running. applies.sh decides which servers get it (new servers only,
# see there).
#
# Our settings go in /etc/fail2ban/jail.d/netmatters.conf, never in jail.conf
# or jail.local:
#   - the sshd jail is switched on
#   - where there's no /var/log/auth.log (Debian 12+ has no rsyslog by
#     default), the sshd jail reads the systemd journal instead
#   - where there's nftables but no iptables (Debian 13 default), bans use
#     nftables
#
# Safe to run again: it only installs if fail2ban is missing, and only
# restarts fail2ban if our settings file changed. If fail2ban was installed
# some other way, it's left exactly as it is.
set -euo pipefail
[ "${FLEET_TEST:-0}" = "1" ] && exit 0

MARKER=/netmatters/fail2ban/installed-by-fleet
DROPIN=/etc/fail2ban/jail.d/netmatters.conf
# Wait for unattended-upgrades on a new server instead of failing (apt 1.9.11+,
# older apt ignores it), and stop package prompts waiting for an answer
APT=(apt-get -o DPkg::Lock::Timeout=240)  # release-check: portable-ok (applies.sh only allows apt servers)
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

if command -v fail2ban-client >/dev/null 2>&1 && [ ! -f "$MARKER" ]; then
  echo "fail2ban was installed some other way, leaving it as it is"
  exit 0
fi

if ! command -v fail2ban-client >/dev/null 2>&1; then
  "${APT[@]}" update -qq || echo "Package list refresh had errors, trying the install anyway"  # release-check: destructive-ok (refreshes package lists only)
  # Install fail2ban and its dependencies only: stop if it would upgrade or
  # remove anything already installed
  plan="$("${APT[@]}" install -s fail2ban)"
  if grep -qE '^(Remv |Inst [^ ]+ \[)' <<<"$plan"; then
    echo "Installing fail2ban would change other packages, so stopping:" >&2
    grep -E '^(Inst|Remv) ' <<<"$plan" >&2
    exit 1
  fi
  "${APT[@]}" install -y -q fail2ban
  mkdir -p /netmatters/fail2ban
  date -u +%Y-%m-%dT%H:%M:%SZ > "$MARKER"
  echo "fail2ban installed"
fi

# ---- Our settings ----
default_section="" sshd_extra=""
if command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then  # release-check: destructive-ok (only checks which firewall tool exists)
  default_section=$'[DEFAULT]\nbanaction = nftables\nbanaction_allports = nftables[type=allports]\n\n'
fi
if [ ! -e /var/log/auth.log ]; then
  sshd_extra=$'backend = systemd\n'
  # The journal backend needs this module, a Recommends that may be missing
  if ! dpkg -s python3-systemd >/dev/null 2>&1; then  # release-check: portable-ok (apt servers only)
    "${APT[@]}" install -y -q python3-systemd
  fi
fi
wanted="$(printf '# Managed by the Netmatters fleet agent (fail2ban component).\n# Put your own changes in jail.local, not here.\n\n%s[sshd]\nenabled = true\n%s' "$default_section" "$sshd_extra")"

changed=0
if [ ! -f "$DROPIN" ] || [ "$(cat "$DROPIN")" != "$wanted" ]; then
  printf '%s\n' "$wanted" > "$DROPIN.new"
  chmod 0644 "$DROPIN.new"
  mv "$DROPIN.new" "$DROPIN"  # release-check: destructive-ok (our own settings file)
  changed=1
  echo "Wrote $DROPIN"
fi

if ! fail2ban-client -t >/dev/null 2>&1; then
  echo "fail2ban config check failed:" >&2
  fail2ban-client -t >&2 || true
  exit 1
fi

systemctl enable fail2ban >/dev/null 2>&1 || true
if [ "$changed" = "1" ] || ! systemctl is-active --quiet fail2ban; then
  systemctl restart fail2ban  # release-check: destructive-ok (fail2ban we installed, to load our settings)
fi

# The sshd jail can take a few seconds to come up
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if fail2ban-client status sshd >/dev/null 2>&1; then
    echo "fail2ban is running with the sshd jail"
    fail2ban-client status sshd || true
    exit 0
  fi
  sleep 2
done
echo "fail2ban is installed but the sshd jail isn't running:" >&2
systemctl status fail2ban --no-pager -l >&2 || true
exit 1
