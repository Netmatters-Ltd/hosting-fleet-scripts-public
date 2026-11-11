#!/usr/bin/env bash
# Nothing to set up beyond the script's permissions. The report runs daily
# from /etc/cron.d/netmatters-access-report through nm-run.
set -euo pipefail
root="${APPLY_ROOT:-/}"; root="${root%/}"
chmod 0755 "$root/netmatters/access/report-access.sh"
