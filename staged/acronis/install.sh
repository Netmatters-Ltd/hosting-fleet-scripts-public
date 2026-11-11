#!/usr/bin/env bash
# Nothing is installed at release time. The Acronis installer builds a kernel
# module, which can run past the agent's 10 minute limit, so the nightly cron
# job (netmatters-acronis) does the install out of hours.
set -euo pipefail
root="${APPLY_ROOT:-/}"; root="${root%/}"
chmod 0755 "$root/netmatters/acronis/install-acronis.sh"
