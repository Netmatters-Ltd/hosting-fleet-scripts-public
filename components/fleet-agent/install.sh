#!/usr/bin/env bash
# Sets up the fleet agent after its files are copied: permissions, log
# folder, command links and the 15-minute timer. Safe to run any number of
# times.
set -euo pipefail
root="${APPLY_ROOT:-/}"; root="${root%/}"

bin="$root/netmatters/fleet-agent/bin"
chmod 0755 "$bin/nm-fleet-agent" "$bin/nm-run"
chmod 0644 "$root/etc/systemd/system/nm-fleet-agent.service" "$root/etc/systemd/system/nm-fleet-agent.timer"
mkdir -p "$root/netmatters/logs"
# Keep the commands on root's PATH
mkdir -p "$root/usr/local/sbin"
ln -sfn /netmatters/fleet-agent/bin/nm-fleet-agent "$root/usr/local/sbin/nm-fleet-agent"
ln -sfn /netmatters/fleet-agent/bin/nm-run "$root/usr/local/sbin/nm-run"

[ "${FLEET_TEST:-0}" = "1" ] && exit 0

# The agent refuses to run if anyone but root could change these
chown root:root "$root/netmatters" "$root/netmatters/fleet-agent" "$bin"
chmod go-w "$root/netmatters" "$root/netmatters/fleet-agent" "$bin"

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl enable nm-fleet-agent.timer >/dev/null 2>&1
  systemctl start nm-fleet-agent.timer
  rm -f /etc/cron.d/nm-fleet-agent-fallback
else
  # No systemd: run from cron instead. Not "netmatters-" prefixed, so the
  # agent's own cron clean-up leaves it alone.
  printf '*/15 * * * * root /netmatters/fleet-agent/bin/nm-fleet-agent --timer >/dev/null 2>&1\n' > /etc/cron.d/nm-fleet-agent-fallback
  chmod 0644 /etc/cron.d/nm-fleet-agent-fallback
fi
