#!/usr/bin/env bash
# nm-safe-update.sh: upgrades one family of packages (PHP or nginx) on an
# Ubuntu/Debian nginx server without breaking the websites on it.
#
#   1. Works out which installed packages in the family have an update, and
#      simulates the upgrade. Refuses, changing nothing, if the package
#      manager would install anything new, remove anything, or touch any
#      package outside the family.
#   2. Saves a copy of every package it will replace (apt cache, then the
#      repository, then dpkg-repack). Refuses if it can't, so there is always
#      a way back. Also saves /etc/nginx and /etc/php exactly as they are.
#      Their SHA-256s go in manifest.sha256 and are checked before a
#      rollback uses them.
#   3. Records which services are running, checks the current config passes
#      its test, and requests every site nginx serves locally (bypassing DNS
#      and any CDN, with a unique query string so no page cache answers),
#      noting which ones are healthy.
#   4. Upgrades with automatic service restarts blocked, so the old processes
#      keep serving. Tests the new config (nginx -t, php-fpmX.Y -t) and only
#      then restarts: PHP-FPM gets a graceful reload, nginx a restart.
#   5. Requests every site again. If a healthy site now fails (5xx or no
#      answer), a service is down, or any step fails, it reinstalls the saved
#      packages, puts /etc/nginx and /etc/php back exactly as they were
#      (keeping the changed copies in the rollback folder), restarts,
#      rechecks and holds the packages (apt-mark hold) so nothing upgrades
#      them again until someone has looked.
#
#   6. After any run that changed packages (an upgrade, or a rollback), sends
#      the server's package list to n8n with the patch-versions report, so
#      the asset data shows what's really installed. A failed report is
#      logged but doesn't change the result.
#
# Servers with Apache installed are refused: PHP may run through Apache
# there, which this script neither restarts nor checks.
#
# Usage:
#   nm-safe-update.sh --profile php|nginx [--dry-run] [--yes]
#                     [--max-sites N] [--allow-unchecked]
#   nm-safe-update.sh --prune
#
#   --dry-run          show what would happen, change nothing (apart from
#                      refreshing the package lists)
#   --yes              don't ask before upgrading (for unattended use)
#   --max-sites N      check at most N sites (default 40)
#   --allow-unchecked  carry on when no site could be checked beforehand
#   --prune            only tidy up old rollback copies and logs (below)
#
# Once the upgrade starts, Ctrl-C, TERM and a dropped SSH session are all
# ignored until it has finished or rolled back. Run it in tmux or screen if
# the connection is unreliable; the log carries on either way.
#
# Tidying up only happens with --prune, run by hand (automatic clear-down is
# off for now):
#   - rollback copies older than 30 days are removed, or 90 days for runs
#     that rolled back (someone will want to look at those)
#   - the newest 3 per profile are always kept, whatever their age
#   - a log over 5 MB is cut down to its last 2,000 lines
#
# Exit codes:
#   0  upgraded and every check passed, or nothing to do
#   1  refused or stopped before changing anything
#   2  a check failed and the rollback worked; packages are held
#   3  a check failed and the rollback did NOT work - look at the server now
#
# Log: /netmatters/logs/safe-update-<profile>.log (appended)
# Rollback copies: /netmatters/updates/rollback/<profile>-<time>/

set -u -o pipefail
export LC_ALL=C
# Our own files (log, rollback copies, checksums) are root-only. apt and dpkg
# run through as_pkg with the usual 022, because package scripts inherit the
# umask and files they create (PHP-FPM config links, session folders, logs)
# must stay readable by the web server.
umask 077
as_pkg() { ( umask 022; "$@" ); }

PROFILE="" DRY_RUN=0 ASSUME_YES=0 MAX_SITES=40 ALLOW_UNCHECKED=0 PRUNE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --max-sites) MAX_SITES="${2:-}"; shift 2 ;;
    --allow-unchecked) ALLOW_UNCHECKED=1; shift ;;
    --prune) PRUNE_ONLY=1; PROFILE=prune; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Package families. A profile only ever upgrades installed packages whose
# names match its pattern.
case "$PROFILE" in
  prune) FAMILY='' ;;
  php)   FAMILY='^(php|php[0-9]+\.[0-9]+)(-.+)?$' ;;
  nginx) FAMILY='^(nginx|nginx-.+|libnginx-mod-.+)$' ;;
  *) echo "Usage: $0 --profile php|nginx [--dry-run] [--yes] [--max-sites N] [--allow-unchecked], or $0 --prune" >&2; exit 1 ;;
esac
[[ "$MAX_SITES" =~ ^[0-9]+$ ]] || { echo "--max-sites must be a number" >&2; exit 1; }

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR=/netmatters/logs
LOG="$LOG_DIR/safe-update-$PROFILE.log"
ROLLBACK_BASE=/netmatters/updates/rollback
ROLLBACK_DIR="$ROLLBACK_BASE/$PROFILE-$STAMP"
POLICY=/usr/sbin/policy-rc.d
ETC=/etc
CONFIG_DIRS=(nginx php)   # under /etc, backed up and restored as a whole
POLICY_OURS=0
RESTARTED=0   # set once services have been restarted onto the new packages

KEEP_DAYS=30
KEEP_DAYS_ROLLED_BACK=90
KEEP_NEWEST=3
LOG_MAX_BYTES=5242880
LOG_KEEP_LINES=2000

say()  { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
stop() { say "STOPPED: $*"; say "Nothing was changed."; exit 1; }

# Removes old rollback copies and trims long logs. Folder names are checked
# against the exact pattern this script creates, and the age comes from the
# time in the name, so nothing else in the folder is ever touched.
prune() {
  local cutoff cutoff_rb prof name stamp n f
  cutoff="$(date -u -d "-$KEEP_DAYS days" +%Y%m%dT%H%M%SZ)" || return 0
  cutoff_rb="$(date -u -d "-$KEEP_DAYS_ROLLED_BACK days" +%Y%m%dT%H%M%SZ)" || return 0
  if [ -d "$ROLLBACK_BASE" ]; then
    for prof in php nginx; do
      n=0
      while read -r name; do
        n=$((n + 1))
        [ "$n" -le "$KEEP_NEWEST" ] && continue
        stamp="${name#*-}"
        if [ -d "$ROLLBACK_BASE/$name/changed-config" ]; then
          [[ "$stamp" < "$cutoff_rb" ]] || continue
        else
          [[ "$stamp" < "$cutoff" ]] || continue
        fi
        rm -rf "/netmatters/updates/rollback/${name:?}" && say "Removed old rollback copies: $name"  # release-check: destructive-ok (our own rollback folders past their keep time)
      done < <(ls -1 "$ROLLBACK_BASE" 2>/dev/null | grep -E "^$prof-[0-9]{8}T[0-9]{6}Z\$" | sort -r)
    done
  fi
  for f in "$LOG_DIR"/safe-update-*.log; do
    [ -f "$f" ] || continue
    if [ "$(stat -c %s "$f")" -gt "$LOG_MAX_BYTES" ]; then
      # Rewritten in place (not replaced), so a run writing to it keeps its handle
      tail -n "$LOG_KEEP_LINES" "$f" > "$f.trim" && cat "$f.trim" > "$f"
      rm -f "$f.trim"  # release-check: destructive-ok (our own temporary file)
      say "Trimmed $(basename "$f") to its last $LOG_KEEP_LINES lines"
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Checks before anything else
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
mkdir -p "$LOG_DIR"

# A dropped SSH session sends HUP, and writing to a terminal that has gone
# gives PIPE. Neither may stop the script, least of all half way through an
# upgrade, so both are ignored throughout. tee ignores them too and, with -p,
# keeps writing the log after the terminal has gone.
trap '' HUP PIPE
start_log() {
  if tee -p --version >/dev/null 2>&1; then
    exec > >(trap '' HUP PIPE INT TERM; exec tee -p -a "$LOG") 2>&1
  else
    exec > >(trap '' HUP PIPE INT TERM; exec tee -a "$LOG") 2>&1
  fi
}

if [ "$PRUNE_ONLY" = "1" ]; then
  start_log
  exec 7>/run/nm-safe-update.lock
  flock -n 7 || { say "Another nm-safe-update is running; not tidying up now."; exit 0; }
  prune
  exit 0
fi
start_log
echo
say "== nm-safe-update profile=$PROFILE dry_run=$DRY_RUN on $(hostname -f 2>/dev/null || hostname)"

[ -d /usr/local/cpanel ] && stop "cPanel server. cPanel manages ea-php and its services itself; not supported yet."
command -v apt-get >/dev/null 2>&1 || stop "Not an apt-based server."  # release-check: portable-ok (guard)
command -v dpkg-query >/dev/null 2>&1 || stop "dpkg-query not found."  # release-check: portable-ok (Debian/Ubuntu only; applies.sh and the apt check above)
command -v nginx >/dev/null 2>&1 || stop "nginx not found. This script is for nginx servers."
# PHP may run through Apache (mod_php, or behind nginx), which this script
# neither restarts nor checks
if dpkg-query -W -f='${db:Status-Status}' apache2 2>/dev/null | grep -qx installed || systemctl is-active --quiet apache2; then  # release-check: portable-ok (Debian/Ubuntu only; applies.sh and the apt check above)
  stop "Apache is installed. PHP may be served through Apache here, which this script doesn't handle yet."
fi

exec 7>/run/nm-safe-update.lock
flock -n 7 || stop "Another nm-safe-update is running."
# Clearing down old rollback copies at the start of each run is off for now;
# run --prune by hand to tidy up
# [ "$DRY_RUN" = "1" ] || prune

# ---------------------------------------------------------------------------
# 1. What would change
# ---------------------------------------------------------------------------
say "Refreshing package lists"
as_pkg apt-get update -qq >/dev/null 2>&1 || say "WARNING: apt-get update reported errors, carrying on with the lists we have"  # release-check: portable-ok, destructive-ok (refreshes package lists only)

family=()
while read -r pkg status; do
  [ "$status" = "installed" ] || continue
  [[ "$pkg" =~ $FAMILY ]] && family+=("$pkg")
done < <(dpkg-query -W -f='${Package} ${db:Status-Status}\n' 2>/dev/null)  # release-check: portable-ok (Debian/Ubuntu only; applies.sh and the apt check above)
[ "${#family[@]}" -gt 0 ] || { say "No $PROFILE packages installed. Nothing to do."; exit 0; }

sim="$(apt-get -s -o Debug::NoLocking=1 install --only-upgrade "${family[@]}" 2>&1)" || stop "The upgrade simulation failed: $sim"  # release-check: portable-ok (simulation only, changes nothing)

# Inst name [old] (new ...)   - an upgrade
# Inst name (new ...)         - a new package
# Remv name [old]             - a removal
upg_names=() upg_old=() upg_new=() problems=()
# In a variable: bash misreads this pattern written inline after =~
UPGRADE_RE='^\[([^]]+)\] \(([^ ]+)'
while read -r kind name rest; do
  case "$kind" in
    Inst)
      if [[ "$rest" =~ $UPGRADE_RE ]]; then
        old="${BASH_REMATCH[1]}" new="${BASH_REMATCH[2]}"
        if [[ "$name" =~ $FAMILY ]]; then
          upg_names+=("$name"); upg_old+=("$old"); upg_new+=("$new")
        else
          problems+=("would also upgrade $name ($old -> $new), which isn't a $PROFILE package")
        fi
      else
        problems+=("would install a new package: $name ${rest%% *}")
      fi ;;
    Remv) problems+=("would remove $name") ;;
  esac
done <<< "$sim"

if [ "${#problems[@]}" -gt 0 ]; then
  say "The upgrade would go beyond $PROFILE packages:"
  printf '    %s\n' "${problems[@]}"
  stop "Handle this server by hand, or wait until the dependency is updated separately."
fi
[ "${#upg_names[@]}" -gt 0 ] || { say "All $PROFILE packages are up to date. Nothing to do."; exit 0; }

say "Will upgrade ${#upg_names[@]} package(s):"
for i in "${!upg_names[@]}"; do
  printf '    %-40s %s -> %s\n' "${upg_names[$i]}" "${upg_old[$i]}" "${upg_new[$i]}"
done

# ---------------------------------------------------------------------------
# 2. Services and config, before
# ---------------------------------------------------------------------------
fpm_services=()
for unit in /lib/systemd/system/php*-fpm.service /etc/systemd/system/php*-fpm.service; do
  [ -f "$unit" ] || continue
  svc="$(basename "$unit" .service)"
  systemctl is-active --quiet "$svc" && fpm_services+=("$svc")
done
# De-duplicate (a unit can be in both folders)
if [ "${#fpm_services[@]}" -gt 0 ]; then
  mapfile -t fpm_services < <(printf '%s\n' "${fpm_services[@]}" | sort -u)
fi
nginx_active=0; systemctl is-active --quiet nginx && nginx_active=1
say "Running before: nginx=$([ $nginx_active = 1 ] && echo active || echo inactive) php-fpm=${fpm_services[*]:-none}"
[ "$nginx_active" = "1" ] || stop "nginx isn't running before the upgrade; fix that first."

# php8.2-fpm -> /usr/sbin/php-fpm8.2
fpm_binary() { local v="${1#php}"; v="${v%-fpm}"; echo "/usr/sbin/php-fpm$v"; }

config_tests() {
  local ok=0 svc bin
  nginx -t >/dev/null 2>&1 || { say "nginx -t FAILED:"; nginx -t 2>&1 | sed 's/^/    /'; ok=1; }
  for svc in "${fpm_services[@]+"${fpm_services[@]}"}"; do
    bin="$(fpm_binary "$svc")"
    [ -x "$bin" ] || continue
    "$bin" -t >/dev/null 2>&1 || { say "$bin -t FAILED:"; "$bin" -t 2>&1 | sed 's/^/    /'; ok=1; }
  done
  return $ok
}
config_tests || stop "The current config already fails its test; fix that before upgrading."

# ---------------------------------------------------------------------------
# 3. Sites, before
# ---------------------------------------------------------------------------
# First name of each server_name in nginx's full config, skipping catch-alls,
# wildcards, regexes and IP addresses
sites=()
while read -r n; do
  sites+=("$n")
done < <(nginx -T 2>/dev/null | grep -v '^[[:space:]]*#' | grep -oE '(^|[[:space:];{])server_name[[:space:]]+[^;[:space:]]+' | awk '{ print $NF }' |
         grep -Ev '^(_|localhost|default|\*.*|~.*|.*\*|[0-9.]+|\[.*\])$' | sort -u | head -n "$MAX_SITES")

# Prints "<scheme> <http code>" for a site, asking nginx on this server
# directly. A unique query string and no-cache headers keep page caches
# (nginx FastCGI cache, WordPress cache files) from answering for PHP.
probe() {
  local n="$1" scheme="${2:-}" code q
  q="nm_check=$(date +%s)$RANDOM"
  local -a nocache=(-H 'Cache-Control: no-cache' -H 'Pragma: no-cache')
  if [ -z "$scheme" ] || [ "$scheme" = https ]; then
    code="$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 "${nocache[@]}" --resolve "$n:443:127.0.0.1" "https://$n/?$q" 2>/dev/null)"
    if [ "$scheme" = https ] || [ "${code:-000}" != "000" ]; then echo "https ${code:-000}"; return; fi
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 10 "${nocache[@]}" --resolve "$n:80:127.0.0.1" "http://$n/?$q" 2>/dev/null)"
  echo "http ${code:-000}"
}
is_up() { [[ "$1" =~ ^[1-4][0-9][0-9]$ ]]; }

check_names=() check_scheme=() check_before=()
for n in "${sites[@]+"${sites[@]}"}"; do
  read -r scheme code < <(probe "$n")
  if is_up "$code"; then
    check_names+=("$n"); check_scheme+=("$scheme"); check_before+=("$code")
  else
    say "    not checked: $n ($scheme $code before the upgrade)"
  fi
done
say "Sites healthy before: ${#check_names[@]} of ${#sites[@]} found"
if [ "${#check_names[@]}" -eq 0 ] && [ "$ALLOW_UNCHECKED" = "0" ]; then
  stop "No site could be checked, so a broken site wouldn't be noticed. Use --allow-unchecked to carry on anyway."
fi

if [ "$DRY_RUN" = "1" ]; then
  say "Dry run: stopping here. Nothing was changed."
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Rollback copies
# ---------------------------------------------------------------------------
mkdir -p "$ROLLBACK_DIR"
chmod 0700 "$ROLLBACK_BASE" "$ROLLBACK_DIR"
arch_of() { dpkg-query -W -f='${Architecture}' "$1" 2>/dev/null; }  # release-check: portable-ok (Debian/Ubuntu only; applies.sh and the apt check above)
save_copy() {
  local name="$1" ver="$2" arch file
  arch="$(arch_of "$name")"
  # apt's cache names files with ':' in the version as %3a
  file="/var/cache/apt/archives/${name}_${ver//:/%3a}_${arch}.deb"  # release-check: portable-ok (Debian/Ubuntu only; applies.sh and the apt check above)
  if [ -f "$file" ]; then cp "$file" "$ROLLBACK_DIR/" && return 0; fi
  ( cd "$ROLLBACK_DIR" && apt-get download -qq "$name=$ver" >/dev/null 2>&1 ) && return 0  # release-check: portable-ok (only on apt servers)
  if command -v dpkg-repack >/dev/null 2>&1; then  # release-check: portable-ok (Debian/Ubuntu only; applies.sh and the apt check above)
    # 022 so the folders it builds into the package aren't root-only
    ( cd "$ROLLBACK_DIR" && as_pkg dpkg-repack "$name" >/dev/null 2>&1 ) && return 0  # release-check: portable-ok (Debian/Ubuntu only; applies.sh and the apt check above)
  fi
  return 1
}
missing=()
for i in "${!upg_names[@]}"; do
  if save_copy "${upg_names[$i]}" "${upg_old[$i]}"; then
    printf '%s %s %s\n' "${upg_names[$i]}" "${upg_old[$i]}" "${upg_new[$i]}" >> "$ROLLBACK_DIR/manifest"
  else
    missing+=("${upg_names[$i]} ${upg_old[$i]}")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  say "Couldn't save a rollback copy of:"
  printf '    %s\n' "${missing[@]}"
  stop "Install dpkg-repack (apt-get install dpkg-repack) so the installed versions can be saved, then run again."  # release-check: portable-ok (Debian/Ubuntu only; applies.sh and the apt check above)
fi
# The config folders exactly as they are, with owners, modes and links
config_present=()
for d in "${CONFIG_DIRS[@]}"; do [ -d "$ETC/$d" ] && config_present+=("$d"); done
[ "${#config_present[@]}" -gt 0 ] || stop "Neither $ETC/nginx nor $ETC/php exists."
if ! tar -C "$ETC" -cpf "$ROLLBACK_DIR/configs.tar" "${config_present[@]}"; then
  stop "Couldn't back up ${config_present[*]} from $ETC"
fi
printf '%s\n' "${config_present[@]}" > "$ROLLBACK_DIR/configs.list"

# Checksums of the copies, checked again before a rollback uses them
if ! ( cd "$ROLLBACK_DIR" && sha256sum -- *.deb configs.tar > manifest.sha256 ); then
  stop "Couldn't record checksums of the rollback copies in $ROLLBACK_DIR"
fi
say "Rollback copies saved in $ROLLBACK_DIR ($(grep -c '\.deb$' "$ROLLBACK_DIR/manifest.sha256") package(s), plus ${config_present[*]} config; checksums in manifest.sha256)"

if [ "$ASSUME_YES" = "0" ]; then
  if [ -t 0 ]; then
    read -r -p "Upgrade these packages now? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || stop "Not confirmed."
  else
    stop "Not run from a terminal; add --yes to upgrade without asking."
  fi
fi

# ---------------------------------------------------------------------------
# 5. Upgrade with restarts blocked
# ---------------------------------------------------------------------------
# policy-rc.d exit 101 tells package scripts not to start, stop or restart
# services, so the running nginx and PHP-FPM keep serving the old code until
# the new config has passed its test. needrestart (Ubuntu 22.04+) is told to
# only list, not restart.
block_restarts() {
  if [ -e "$POLICY" ] && [ "$POLICY_OURS" = "0" ]; then
    say "A $POLICY already exists; leaving it alone, so package scripts may restart services themselves."
    return 0
  fi
  printf '#!/bin/sh\n# nm-safe-update: blocks service restarts during an upgrade\nexit 101\n' > "$POLICY"  # release-check: destructive-ok (temporary, removed by allow_restarts)
  chmod 0755 "$POLICY"
  POLICY_OURS=1
}
allow_restarts() {
  if [ "$POLICY_OURS" = "1" ] && grep -q 'nm-safe-update' "$POLICY" 2>/dev/null; then
    rm -f "$POLICY"  # release-check: destructive-ok (only our own temporary policy-rc.d)
  fi
  POLICY_OURS=0
}
trap allow_restarts EXIT

APT_ENV=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1)
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

restart_services() {
  local ok=0 svc
  for svc in "${fpm_services[@]+"${fpm_services[@]}"}"; do
    # Reload re-executes the PHP-FPM master gracefully: running requests finish
    systemctl reload "$svc" || systemctl restart "$svc" || { say "Couldn't reload or restart $svc"; ok=1; }  # release-check: destructive-ok (graceful reload of PHP-FPM after its config test passed)
  done
  if [ "$1" = "with-nginx" ]; then
    # A new nginx binary or module only loads on a restart
    systemctl restart nginx || { say "Couldn't restart nginx"; ok=1; }  # release-check: destructive-ok (nginx restart after nginx -t passed)
  else
    systemctl reload nginx || ok=1
  fi
  sleep 3
  systemctl is-active --quiet nginx || { say "nginx isn't running"; ok=1; }
  for svc in "${fpm_services[@]+"${fpm_services[@]}"}"; do
    systemctl is-active --quiet "$svc" || { say "$svc isn't running"; ok=1; }
  done
  return $ok
}

nginx_changed=without-nginx
for n in "${upg_names[@]}"; do [[ "$n" =~ ^(nginx|nginx-.+|libnginx-mod-.+)$ ]] && nginx_changed=with-nginx; done

site_checks() {
  local i code scheme bad=0 tries
  for i in "${!check_names[@]}"; do
    for tries in 1 2 3; do
      read -r scheme code < <(probe "${check_names[$i]}" "${check_scheme[$i]}")
      is_up "$code" && break
      sleep 3
    done
    if is_up "$code"; then
      say "    ok:     ${check_names[$i]} (${check_before[$i]} -> $code)"
    else
      say "    BROKEN: ${check_names[$i]} (${check_before[$i]} -> $code)"; bad=1
    fi
  done
  return $bad
}

# Puts each saved config folder back exactly as it was. The backup is
# unpacked next to it first, then swapped in with two renames, so a folder is
# never half restored. The changed copies are kept in the rollback folder.
restore_configs() {
  local d tmp="$ETC/.nm-restore-$STAMP"
  mkdir -p "$tmp" "$ROLLBACK_DIR/changed-config" || return 1
  tar -C "$tmp" -xpf "$ROLLBACK_DIR/configs.tar" || { say "Couldn't unpack the config backup"; return 1; }
  while read -r d; do
    [[ "$d" =~ ^[a-z0-9]+$ ]] && [ -d "$tmp/$d" ] || { say "Config backup has no $d"; return 1; }
    if [ -e "$ETC/$d" ]; then
      mv "$ETC/$d" "$ROLLBACK_DIR/changed-config/$d" || { say "Couldn't move $ETC/$d aside"; return 1; }  # release-check: destructive-ok (kept in the rollback folder)
    fi
    if ! mv "$tmp/$d" "$ETC/$d"; then  # release-check: destructive-ok (restores the backup taken before the upgrade)
      mv "$ROLLBACK_DIR/changed-config/$d" "$ETC/$d"  # release-check: destructive-ok (puts the changed copy back rather than leave no config)
      say "Couldn't restore $ETC/$d; left the changed copy in place"; return 1
    fi
    say "Restored $ETC/$d (the changed copy is in $ROLLBACK_DIR/changed-config/$d)"
  done < "$ROLLBACK_DIR/configs.list"
  rmdir "$tmp" 2>/dev/null
  return 0
}

rollback() {
  say "== Rolling back to the saved packages"
  if ! ( cd "$ROLLBACK_DIR" && sha256sum --quiet -c manifest.sha256 ); then
    say "ROLLBACK FAILED: the saved copies in $ROLLBACK_DIR don't match their checksums, so nothing was put back"
    return 1
  fi
  block_restarts
  if ! as_pkg "${APT_ENV[@]}" dpkg -i --force-confold "$ROLLBACK_DIR"/*.deb; then  # release-check: portable-ok (Debian/Ubuntu only; applies.sh and the apt check above)
    allow_restarts
    say "ROLLBACK FAILED: dpkg couldn't reinstall the saved packages from $ROLLBACK_DIR"  # release-check: portable-ok (Debian/Ubuntu only; applies.sh and the apt check above)
    return 1
  fi
  if ! restore_configs; then
    allow_restarts
    say "ROLLBACK FAILED: the old packages are back but the config couldn't be restored"
    return 1
  fi
  allow_restarts
  config_tests || { say "ROLLBACK FAILED: the old config doesn't pass its test now"; return 1; }
  if [ "$RESTARTED" = "1" ]; then
    restart_services "$nginx_changed" || { say "ROLLBACK FAILED: services didn't come back"; return 1; }
  else
    # Nothing was restarted, so the old processes never stopped serving
    say "Services were never restarted onto the new packages; leaving them running"
  fi
  site_checks || { say "ROLLBACK FAILED: sites are still broken after the rollback"; return 1; }
  # Stop anything (including unattended-upgrades) upgrading them again until someone has looked
  apt-mark hold "${upg_names[@]}" >/dev/null && say "Held: ${upg_names[*]} (apt-mark unhold them once fixed)"  # release-check: portable-ok (apt servers only)
  return 0
}

# Sends the package list to n8n (the fleet's patch-versions report). Never
# changes the result of the run.
PATCH_REPORT=/netmatters/patches/report-patch-versions.sh
report_patches() {
  if [ ! -x "$PATCH_REPORT" ]; then
    say "Patch report not sent: $PATCH_REPORT isn't installed (fleet agent release 3 or later)"
    return 0
  fi
  say "Sending the updated package list (patch-versions report)"
  if as_pkg timeout 300 "$PATCH_REPORT" >/dev/null 2>&1; then
    say "Patch report sent"
  else
    say "WARNING: the patch report didn't send; the asset data will catch up at the next daily run"
  fi
  return 0
}

fail() {
  say "FAILED: $*"
  if rollback; then
    say "Rolled back to the previous versions, and the sites checked out."
    report_patches
    exit 2
  fi
  say "LOOK AT THIS SERVER NOW. Rollback copies are in $ROLLBACK_DIR"
  report_patches
  exit 3
}

pins=()
for i in "${!upg_names[@]}"; do pins+=("${upg_names[$i]}=${upg_new[$i]}"); done

# From here until the run has finished or rolled back, Ctrl-C and TERM (the
# fleet agent's time limit sends TERM) are ignored, as stopping part way
# through would leave half-upgraded packages. apt and dpkg inherit this.
trap '' INT TERM
say "== Upgrading (service restarts blocked)"
block_restarts
as_pkg "${APT_ENV[@]}" apt-get "${APT_OPTS[@]}" install --only-upgrade "${pins[@]}" || { allow_restarts; fail "apt-get couldn't upgrade the packages"; }  # release-check: portable-ok, destructive-ok (upgrades only the packages simulated and listed above)
allow_restarts

say "== Testing the new config before restarting anything"
config_tests || fail "the new config doesn't pass its test (the old processes are still serving)"

say "== Restarting services"
RESTARTED=1
restart_services "$nginx_changed" || fail "services didn't come back after the restart"

say "== Checking the sites again"
site_checks || fail "one or more sites broke after the upgrade"

say "== Done: ${#upg_names[@]} $PROFILE package(s) upgraded and every check passed."
say "Rollback copies kept in $ROLLBACK_DIR"
report_patches
exit 0
