#!/usr/bin/env bash
# Every server reports, including ones with no PHP (they send an empty list).
set -euo pipefail
root="${APPLY_ROOT:-/}"; root="${root%/}"
chmod 0755 "$root/netmatters/php-audit/report-php-versions.sh"
