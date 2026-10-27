#!/usr/bin/env bash
# Runs a Lynis audit and posts the report to n8n
# at $N8N_BASE/webhook/hosting-fleet-lynis, with the fleet token. Run monthly by
# /etc/cron.d/netmatters-lynis-audit through nm-run.
set -euo pipefail
# shellcheck disable=SC1091
. /netmatters/fleet-agent/fleet-agent.conf
lynis="$(command -v lynis)" || { echo "Lynis is not installed" >&2; exit 1; }
"$lynis" audit system --cronjob --quiet
curl -fsS --retry 3 --max-time 120 -X POST -H "X-Fleet-Token: $FLEET_TOKEN" \
  -F "file=@/var/log/lynis-report.dat" "${N8N_BASE%/}/webhook/hosting-fleet-lynis"
