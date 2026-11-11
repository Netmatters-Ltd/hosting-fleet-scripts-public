#!/usr/bin/env bash
# Installs the Acronis Cyber Protect agent and registers it to the customer's
# Acronis tenant, once this server passes the checks below. Run nightly by
# cron through nm-run, so the install happens out of hours.
#
# The component only applies where ACRONIS_TOKEN is set, Acronis isn't
# already installed, and the server is an x86_64 machine rather than a
# container (see applies.sh). This script then checks:
#   - disk:   under 90% used and at least 2 GB free where Acronis installs
#             (/usr/lib, /var/lib) and in /netmatters, where the installer
#             is downloaded and unpacked instead of /tmp
#   - ports:  the Acronis data centre is reachable on 443, and CSF (where it's
#             running) allows TCP out on 443, 8443, 7770-7800, 44445, 55556
#   - build:  gcc, make, perl, kernel headers for the running kernel and,
#             on kernels 4.15+ built with the ORC unwinder, the libelf headers. On RHEL family systems the
#             installer adds these itself, so they aren't checked there.
#   - size:   at least 2 CPU cores and 4 GB RAM (3.5 GiB reported), and
#             available RAM of at least 1 GB per TB of used disk (Acronis
#             needs about 1 GB of RAM per 1 TB of backup)
#
# Anything that fails is posted to n8n as "blocked", which raises an Admin
# task, and nothing is installed. Once installed it posts "installed" (or
# "failed" with the log), so someone can apply the protection plan.
#
# Settings, from /netmatters/fleet-agent/fleet-agent.conf:
#   ACRONIS_TOKEN          registration token from the customer's tenant
#   ACRONIS_URL            data centre, default https://eu-cloud.acronis.com
#   ACRONIS_DOWNLOAD_URL   optional, the installer link if the default
#                          doesn't suit this tenant
#   N8N_BASE, FLEET_TOKEN  posts to $N8N_BASE/webhook/hosting-fleet-acronis
#
# Usage: install-acronis.sh [--check]
#   --check   run the checks and print the results; installs and posts nothing

set -uo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# shellcheck disable=SC1090
. "${FLEET_CONF:-/netmatters/fleet-agent/fleet-agent.conf}"
ACRONIS_URL="${ACRONIS_URL:-https://eu-cloud.acronis.com}"
ACRONIS_URL="${ACRONIS_URL%/}"
ACRONIS_DOWNLOAD_URL="${ACRONIS_DOWNLOAD_URL:-$ACRONIS_URL/bc/api/ams/links/agents/redirect?language=multi&channel=CURRENT&system=linux&architecture=64&productType=enterprise}"
WEBHOOK_URL="${N8N_BASE%/}/webhook/hosting-fleet-acronis"
WORK=/netmatters/acronis
INSTALL_LOG="$WORK/last-install.log"

REQUIRED_PORTS="443 8443 7770-7800 44445 55556"
MIN_CORES=2
MIN_MEM_KB=3670016          # 3.5 GiB, what a "4 GB" server reports
MAX_DISK_PCT=90
MIN_FREE_KB=2097152         # 2 GB

if [ -z "${ACRONIS_TOKEN:-}" ]; then
  echo "ACRONIS_TOKEN is not set, nothing to do"; exit 0
fi
if [ -d /usr/lib/Acronis ]; then
  echo "Acronis is already installed, leaving it as it is"; exit 0
fi

problems=()
problem() { problems+=("$*"); echo "BLOCKED: $*"; }

post() {
  local status="$1" details="$2" tail=""
  [ "$CHECK_ONLY" = "1" ] && return 0
  [ -f "$INSTALL_LOG" ] && [ "$status" = "failed" ] && tail="$(tail -n 40 "$INSTALL_LOG" | tail -c 4000)"
  curl -fsS --proto '=https' --retry 3 --max-time 60 -X POST "$WEBHOOK_URL" -H "X-Fleet-Token: $FLEET_TOKEN" \
    --data-urlencode "hostname=$(hostname)" \
    --data-urlencode "fqdn=$(hostname -f 2>/dev/null || hostname)" \
    --data-urlencode "status=$status" \
    --data-urlencode "details=$details" \
    --data-urlencode "log_tail=$tail" >/dev/null || echo "Could not post to n8n"
}

# ---- Disk: where the agent installs, and /netmatters, where the installer
# is downloaded and unpacked (TMPDIR points there, so /tmp isn't used) ----
check_disk() {
  local seen=" " path line pct avail mnt
  for path in /usr/lib /var/lib /netmatters; do
    line="$(df -P -k "$path" 2>/dev/null | awk 'NR==2')"
    [ -n "$line" ] || continue
    mnt="$(awk '{print $6}' <<< "$line")"
    [[ "$seen" == *" $mnt "* ]] && continue
    seen="$seen$mnt "
    pct="$(awk '{gsub("%", "", $5); print $5}' <<< "$line")"
    avail="$(awk '{print $4}' <<< "$line")"
    if [ "$pct" -ge "$MAX_DISK_PCT" ]; then
      problem "Disk: $mnt is ${pct}% used (limit ${MAX_DISK_PCT}%)"
    elif [ "$avail" -lt "$MIN_FREE_KB" ]; then
      problem "Disk: $mnt has $((avail / 1024)) MB free (Acronis needs 2 GB)"
    fi
  done
}

# ---- Ports ----
# True if CSF's TCP_OUT list covers the port (single ports or a:b ranges)
csf_allows() {
  local want="$1" list="$2" item lo hi
  for item in ${list//,/ }; do
    if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
      lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
      [ "$want" -ge "$lo" ] && [ "$want" -le "$hi" ] && return 0
    elif [ "$item" = "$want" ]; then
      return 0
    fi
  done
  return 1
}

check_ports() {
  local host="${ACRONIS_URL#https://}" spec p lo hi missing=()
  host="${host%%/*}"
  if ! timeout 10 bash -c "exec 3<>/dev/tcp/$host/443" 2>/dev/null; then
    problem "Ports: can't connect to $host on 443"
  fi

  # CSF is what usually blocks these on cPanel servers
  if [ -f /etc/csf/csf.conf ] && [ ! -f /etc/csf/csf.disable ]; then
    local tcp_out
    tcp_out="$(sed -n 's/^[[:space:]]*TCP_OUT[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' /etc/csf/csf.conf | head -1)"
    for spec in $REQUIRED_PORTS; do
      if [[ "$spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
        for ((p = lo; p <= hi; p++)); do
          csf_allows "$p" "$tcp_out" || { missing+=("$spec"); break; }
        done
      else
        csf_allows "$spec" "$tcp_out" || missing+=("$spec")
      fi
    done
    [ "${#missing[@]}" -eq 0 ] || problem "Ports: CSF TCP_OUT doesn't allow ${missing[*]}"
  fi
}

# ---- Build packages for the kernel module ----
check_build() {
  local kernel missing=() major minor
  if [ -f /etc/redhat-release ]; then
    echo "RHEL family: the installer adds its own build packages"; return 0
  fi
  kernel="$(uname -r)"
  command -v gcc >/dev/null 2>&1 || missing+=("gcc")
  command -v make >/dev/null 2>&1 || missing+=("make")
  command -v perl >/dev/null 2>&1 || missing+=("perl")
  [ -e "/lib/modules/$kernel/build" ] || missing+=("kernel headers for $kernel (linux-headers-$kernel)")
  # libelf is only needed for kernels 4.15+ built with the ORC unwinder. If
  # the kernel config can't be read, assume it is.
  major="${kernel%%.*}"; minor="${kernel#*.}"; minor="${minor%%.*}"
  if [ "$major" -gt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -ge 15 ]; }; then
    if [ ! -r "/boot/config-$kernel" ] || grep -q '^CONFIG_UNWINDER_ORC=y' "/boot/config-$kernel"; then
      [ -e /usr/include/libelf.h ] || [ -e /usr/include/gelf.h ] || missing+=("libelf-dev")
    fi
  fi
  [ "${#missing[@]}" -eq 0 ] || problem "Build packages missing: $(IFS=,; echo "${missing[*]}" | sed 's/,/, /g')"
}

# ---- CPU and RAM ----
check_size() {
  local cores mem_total mem_avail used_kb need_kb
  cores="$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)"
  mem_total="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  mem_avail="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  # Older kernels (Ubuntu 14.04) have no MemAvailable
  [ -n "$mem_avail" ] || mem_avail="$(awk '/^(MemFree|Buffers|Cached):/ {s += $2} END {print s}' /proc/meminfo)"
  # Used space on local disks, each device counted once
  used_kb="$(df -P -l -k -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null |
    awk 'NR > 1 && !seen[$1]++ {s += $3} END {print s + 0}')"
  need_kb=$((used_kb / 1024))   # 1 GB of RAM per 1 TB of data

  [ "$cores" -ge "$MIN_CORES" ] || problem "Size: $cores CPU core(s), needs at least $MIN_CORES"
  [ "$mem_total" -ge "$MIN_MEM_KB" ] ||
    problem "Size: $((mem_total / 1024)) MB RAM, needs at least 4 GB"
  [ "$mem_avail" -ge "$need_kb" ] ||
    problem "Size: $((mem_avail / 1024)) MB RAM available, needs $((need_kb / 1024)) MB for $((used_kb / 1024 / 1024)) GB of data (1 GB per TB)"
}

check_disk
check_ports
check_build
check_size

if [ "${#problems[@]}" -gt 0 ]; then
  post blocked "$(printf '%s\n' "${problems[@]}")"
  exit 0
fi
echo "All checks passed"
[ "$CHECK_ONLY" = "1" ] && exit 0

# ---- Install ----
mkdir -p "$WORK/tmp"
chmod 0700 "$WORK/tmp"
export TMPDIR="$WORK/tmp"
# The installer adds packages itself. Stop package prompts (such as
# needrestart's "pending kernel upgrade" box) waiting for an answer.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
installer="$WORK/Cyber_Protection_Agent_for_Linux_x86_64.bin"
selinux_before="$(getenforce 2>/dev/null || echo none)"
: > "$INSTALL_LOG"

{
  echo "Downloading the installer"
  curl -fsSL --proto '=https' --max-time 600 -o "$installer" "$ACRONIS_DOWNLOAD_URL" &&
    chmod 0700 "$installer" &&
    echo "Running the installer" &&
    timeout 3600 "$installer" -a --rain="$ACRONIS_URL" --token="$ACRONIS_TOKEN" < /dev/null  # release-check: download-ok (Acronis's installer, kept out of our repo)
} >> "$INSTALL_LOG" 2>&1
rc=$?
rm -f "$installer"  # release-check: destructive-ok (our own downloaded installer)

if [ "$rc" -ne 0 ] || [ ! -d /usr/lib/Acronis ]; then
  post failed "Installer exited with $rc. Full log on the server: $INSTALL_LOG"
  exit 1
fi

details="Installed and registered. Apply the protection plan in the Acronis portal."
selinux_after="$(getenforce 2>/dev/null || echo none)"
if [ "$selinux_before" != "$selinux_after" ]; then
  details="$details SELinux changed from $selinux_before to $selinux_after during the install, check this is OK for this server."
fi
post installed "$details"
echo "$details"
