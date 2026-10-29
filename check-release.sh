#!/usr/bin/env bash
# Checks every component before make-release.sh builds it, so nothing that
# would break on part of the estate, or quietly destroy something, gets
# released. make-release.sh runs it; run it on its own while you work.
#
# Everything we ship must work on the oldest servers we manage: Ubuntu 14.04
# and CentOS 7 (bash 4.2, systemd 219, curl 7.29, GNU tar 1.26, python 3.4).
#
# A line that trips a check is allowed only with a marker comment on that
# same line, so the pull request shows the reviewer exactly what was waved
# through:
#   # release-check: destructive-ok   deletes, overwrites, stops or restarts
#                                     something on the server
#   # release-check: portable-ok      only runs where it's safe (guarded by
#                                     command -v, a path check, applies.sh)
#   # release-check: download-ok      runs code fetched at install time,
#                                     which the release checksum doesn't cover
# A line that needs more than one lists them all, e.g.
#   # release-check: portable-ok, destructive-ok (why)
#
# Usage: ./check-release.sh
set -uo pipefail
cd "$(dirname "$0")"
export LC_ALL=C

# Each entry: extended regex <TAB> why it's a problem. Matched against code
# with any trailing " # comment" removed; whole-line comments are skipped.
PORTABILITY=(
  $'\\b(apt|apt-get|aptitude|dpkg|add-apt-repository|update-rc\\.d)\\b\tDebian/Ubuntu only'
  $'\\b(yum|dnf|rpm|chkconfig)\\b\tCentOS/RHEL only'
  $'\\b(adduser|deluser|addgroup|delgroup)\\b\tbehaves differently on Ubuntu and CentOS, use useradd/groupadd'
  $'\\b(netstat|ifconfig|route)\\b\tnet-tools is not installed by default, use ss or ip'
  $'\\bip (-j|-json|--json)\\b\tiproute on CentOS 7 has no JSON output'
  $'\\bjq\\b\tjq is not installed by default'
  $'(^|[^-[:alnum:]_/.])python( |$|\\))|/python[[:space:]]|python2\\b|#!.*\\bpython$\tbare python is python 2 on CentOS 7 and missing on new Ubuntu, use python3'
  $'systemctl[^|;&]*--value\\b\tsystemctl --value needs systemd 230+, CentOS 7 has 219'
  $'curl[^|;&]*--(retry-all-errors|retry-connrefused|fail-with-body|json)\\b\tcurl option is newer than CentOS 7\'s curl 7.29'
  $'tar[^|;&]*--sort\\b\ttar --sort needs GNU tar 1.28, CentOS 7 has 1.26'
  $'\\b(declare|local|typeset) -n\\b\tnamerefs need bash 4.3, CentOS 7 has 4.2'
  $'\\$\\{[A-Za-z_][A-Za-z0-9_]*\\[-[0-9]\tnegative array index needs bash 4.3'
  $'\\bwait -n\\b\twait -n needs bash 4.3'
  $'\\b(mapfile|readarray) [^|;&]*-d\\b\tmapfile -d needs bash 4.4'
  $'\\$\\{[A-Za-z_][A-Za-z0-9_]*(\\[[^]]*\\])?@[QEPAa]\\}\t${var@Q} needs bash 4.4'
  $'inherit_errexit\tinherit_errexit needs bash 4.4'
  $'\\b(EPOCHSECONDS|EPOCHREALTIME|SRANDOM)\\b\tneeds bash 5'
  $'(^|[^[:alnum:]_])f"[^"]*\\{|(^|[^[:alnum:]_])f\'[^\']*\\{\tpython f-strings need 3.6, Ubuntu 14.04/16.04 have 3.4/3.5'
  $'subprocess\\.run\\b|capture_output=|text=True\tneeds python 3.5+/3.7+, use subprocess.check_output'
)
DESTRUCTIVE=(
  $'\\brm\\b\tdeletes files'
  $'\\bmv\\b\tcan overwrite files'
  $'-delete\\b\tdeletes files'
  $'\\bsed\\b[^|;&]*[[:space:]]-[a-zA-Z]*i\tedits a file in place'
  $'\\btruncate\\b|\\bshred\\b\tempties or destroys files'
  $'(^|[^>&0-9])>>?[[:space:]]*"?/(etc|usr|var|boot|lib|lib64|bin|sbin|root|home|opt|srv)\\b\twrites over or into a system file'
  $'\\bcrontab[[:space:]]+(-r|-[[:space:]]*$|-[[:space:]]*[;|&)])\treplaces or removes a crontab'
  $'\\bsystemctl[[:space:]]+(stop|disable|mask|kill|restart|try-restart|reload-or-restart|isolate)\\b\tstops, restarts or disables a service'
  $'\\bservice[[:space:]]+[^[:space:]]+[[:space:]]+(stop|restart)\\b\tstops or restarts a service'
  $'\\b(kill|killall|pkill)\\b\tkills processes'
  $'\\b(reboot|shutdown|halt|poweroff)\\b|\\binit[[:space:]]+[06]\\b\treboots or shuts down the server'
  $'(^|[;&|({][[:space:]]*|\\$\\([[:space:]]*|^[[:space:]]*)(userdel|groupdel|usermod|passwd|chpasswd)\\b\tchanges or removes accounts'
  $'\\b(apt|apt-get|yum|dnf)\\b[^|;&]*[[:space:]](remove|purge|erase|autoremove|upgrade|dist-upgrade|update)\\b|\\brpm[[:space:]]+-e\\b|\\bdpkg[[:space:]]+(-r|-P|--remove|--purge)\\b\tremoves or upgrades packages'
  $'\\b(iptables|ip6tables|nft|firewall-cmd|ufw)\\b\tchanges the firewall'
  $'\\b(mkfs[.a-z0-9]*|fdisk|parted|wipefs|dd)\\b\ttouches disks or file systems'
  $'\\b(setenforce|sysctl[[:space:]]+-w)\\b\tchanges kernel or SELinux settings'
  $'\\bchattr\\b\tchanges file attributes'
  $'os\\.(remove|unlink|rmdir)\\b|shutil\\.rmtree\\b\tdeletes files (python)'
)

DOWNLOADS=(
  $'\\b(curl|wget)\\b[^#]*\\|[[:space:]]*(sudo[[:space:]]+)?(ba|da|z)?sh\\b\tpipes a download into a shell'
  $'\\b(curl|wget)\\b[^#]*(&&|;)[[:space:]]*(sudo[[:space:]]+)?(ba|da|z)?sh[[:space:]]\tdownloads a script and runs it'
)

fail=0
problem() { printf '%s\n    %s\n' "$1" "$2" >&2; fail=1; }

# Lines of $file, with comments stripped, that match $re and lack $marker
scan() {
  local file="$1" marker="$2" kind="$3"; shift 3
  local entry re why n line code
  for entry in "$@"; do
    re="${entry%%$'\t'*}"; why="${entry#*$'\t'}"
    while IFS= read -r n; do
      line="$(sed -n "${n}p" "$file")"
      [[ "$line" =~ ^[[:space:]]*# ]] && [ "$n" != 1 ] && continue
      [[ "$line" == *"release-check:"*"$marker"* ]] && continue
      code="$line"; [ "$n" != 1 ] && code="${line%%[[:space:]]#[[:space:]]*}"
      printf '%s\n' "$code" | grep -qE -- "$re" || continue
      problem "$file:$n: $kind: $why (mark with '# release-check: $marker' if intended)" "${line#"${line%%[![:space:]]*}"}"
    done < <(grep -nE -- "$re" "$file" | cut -d: -f1)
  done
}

# Shell scripts: install.sh, applies.sh, and anything shipped with a shell
# shebang. Python files shipped as-is are scanned too.
mapfile -t scripts < <(
  find components -type f \( -name install.sh -o -name applies.sh \) | sort
  find components -path '*/files/*' -type f | sort | while IFS= read -r f; do
    head -c 64 "$f" | head -1 | grep -qE '^#!' && printf '%s\n' "$f"
  done
)

for f in "${scripts[@]}"; do
  first="$(head -1 "$f")"
  case "$first" in
    '#!/usr/bin/env bash'|'#!/bin/bash') bash -n "$f" 2>/dev/null || problem "$f: bash syntax error" "$(bash -n "$f" 2>&1 | head -1)" ;;
    '#!/usr/bin/env python3'|'#!/usr/bin/python3') ;;
    *) problem "$f:1: shebang must be bash or python3 (/bin/sh is dash on Ubuntu, so bash syntax breaks there)" "$first" ;;
  esac
  scan "$f" portable-ok portability "${PORTABILITY[@]}"
  scan "$f" destructive-ok destructive "${DESTRUCTIVE[@]}"
  scan "$f" download-ok unchecked-download "${DOWNLOADS[@]}"
done

# Cron files: well formed, run as root, and only call scripts this release ships
for f in components/*/cron/*; do
  [ -f "$f" ] || continue
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[A-Z_]+= ]] && continue
    read -r -a w <<< "$line"
    if [ "${#w[@]}" -lt 7 ] || [ "${w[5]}" != root ]; then
      problem "$f:$n: cron line needs 5 time fields, then root, then the command" "$line"; continue
    fi
    for word in "${w[@]:6}"; do
      case "$word" in
        /netmatters/*)
          ls components/*/files"$word" >/dev/null 2>&1 || problem "$f:$n: $word is not shipped by any component in this release" "$line" ;;
      esac
    done
  done < "$f"
done

if [ "$fail" -ne 0 ]; then
  echo "Release checks failed. Fix the lines above, or mark them if they're intended." >&2
  exit 1
fi
echo "Release checks passed (${#scripts[@]} scripts, Ubuntu 14.04+ and CentOS 7+)."
