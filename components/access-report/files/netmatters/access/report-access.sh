#!/usr/bin/env bash
# Reports who can get into this server, and with what rights, to
# $N8N_BASE/webhook/hosting-fleet-access with the fleet token:
#   - users who can log in, have SSH keys, have sudo rights, are in an admin
#     group (sudo, wheel, admin, docker, lxd) or have UID 0
#   - each user's password state (set, locked, none or blank - never the
#     hash), account expiry and last login where the system records it
#   - every SSH key they have: type, size, SHA256 fingerprint, comment and
#     any restrictions (from=, command= and so on)
#   - their effective sudo rules, as sudo itself works them out
#   - the SSH server settings that decide how people can log in
#   - a checksum of each sudoers file, so changes show up
#
# Sends a plain tab-separated file (field "report") rather than JSON, as
# not every server has jq or python3. One record per line, first column is
# the record type:
#   sshd     setting  value
#   user     name  uid  gid  home  shell  can_login  password  password_changed  expires  groups  last_login
#   key      user  file  line  type  bits  fingerprint  comment  options
#   sudo     user  nopasswd  rule
#   group    name  members
#   sudoers  file  sha256
#   note     message
#
# N8N_BASE and FLEET_TOKEN come from /netmatters/fleet-agent/fleet-agent.conf.
#
# Usage: report-access.sh [--dry-run]
#   --dry-run   print the report instead of sending it

set -uo pipefail
export LC_ALL=C

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

if [ "$(id -u)" -ne 0 ]; then
  [ "$DRY_RUN" = "1" ] || { echo "Run as root." >&2; exit 1; }
  echo "Not root: passwords, sudo rules and other users' keys will be missing." >&2
fi

CONF="${FLEET_CONF:-/netmatters/fleet-agent/fleet-agent.conf}"
if [ -r "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
elif [ "$DRY_RUN" = "0" ]; then
  echo "$CONF not found." >&2; exit 1
fi
N8N_BASE="${N8N_BASE:-}" FLEET_TOKEN="${FLEET_TOKEN:-}"
WEBHOOK_URL="${N8N_BASE%/}/webhook/hosting-fleet-access"
ADMIN_GROUPS="sudo wheel admin docker lxd"

work="$(mktemp -d /tmp/nm-access-report.XXXXXXXX)"
trap 'rm -rf "/tmp/nm-access-report.${work##*.}"' EXIT  # release-check: destructive-ok (our mktemp folder)
OUT="$work/report.tsv"
: > "$OUT"

# Writes one tab-separated record, with tabs and line breaks in values
# turned into spaces so every record stays on one line
rec() {
  local f line="" sep=""
  for f in "$@"; do
    f="${f//$'\t'/ }"; f="${f//$'\n'/ }"; f="${f//$'\r'/ }"
    line="$line$sep$f"; sep=$'\t'
  done
  printf '%s\n' "$line" >> "$OUT"
}

days_to_date() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 0
  date -u -d "@$(( $1 * 86400 ))" +%Y-%m-%d 2>/dev/null
}

echo "# netmatters access report v1" >> "$OUT"

# ---- SSH server settings ----
SSHD="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"
key_patterns=".ssh/authorized_keys .ssh/authorized_keys2"
if [ -x "$SSHD" ]; then
  # sshd -T needs this on socket-activated Debian/Ubuntu if nobody has
  # connected since boot
  [ "$(id -u)" -eq 0 ] && [ -f /etc/debian_version ] && [ ! -d /run/sshd ] && install -d -m 0755 /run/sshd
  if sshd_t="$(timeout 20 "$SSHD" -T 2>/dev/null)" && [ -n "$sshd_t" ]; then
    while read -r k v; do
      case "$k" in
        permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|\
challengeresponseauthentication|permitemptypasswords|authorizedkeysfile|authorizedkeyscommand|\
authorizedkeyscommanduser|allowusers|allowgroups|denyusers|denygroups|port|maxauthtries)
          rec sshd "$k" "$v" ;;
      esac
    done <<< "$sshd_t"
    akf="$(awk '$1 == "authorizedkeysfile" {$1 = ""; sub(/^ /, ""); print; exit}' <<< "$sshd_t")"
    [ -n "$akf" ] && key_patterns="$akf"
  else
    rec note "sshd -T failed, so SSH settings are missing and keys were read from the default places"
  fi
else
  rec note "OpenSSH server not installed"
fi

# Where a user's keys are, from AuthorizedKeysFile (%h home, %u user, %% %)
key_files_for() {
  local user="$1" home="$2" p
  [ "$key_patterns" = "none" ] && return 0
  for p in $key_patterns; do
    [ "$p" = "none" ] && continue
    p="${p//%%/$'\001'}"; p="${p//%h/$home}"; p="${p//%u/$user}"; p="${p//$'\001'/%}"
    case "$p" in /*) ;; *) p="$home/$p" ;; esac
    printf '%s\n' "$p"
  done
}

# ---- SSH keys ----
# Records each key in a file. The key itself is the "type AAAA..." pair;
# anything before it is restrictions, anything after it is the comment.
KEY_RE='^(.*[[:space:]])?((ssh|ecdsa|sk)-[^[:space:]]+)[[:space:]]+(AAAA[A-Za-z0-9+/=]+)([[:space:]]+(.*))?$'
count_keys=0
read_keys() {
  local user="$1" file="$2" n=0 line opts type blob comment fp_line bits fp
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" =~ $KEY_RE ]]; then
      opts="${BASH_REMATCH[1]}"; type="${BASH_REMATCH[2]}"; blob="${BASH_REMATCH[4]}"; comment="${BASH_REMATCH[6]}"
      opts="${opts%"${opts##*[![:space:]]}"}"; opts="${opts#"${opts%%[![:space:]]*}"}"
      printf '%s %s\n' "$type" "$blob" > "$work/key.pub"
      fp_line="$(ssh-keygen -E sha256 -lf "$work/key.pub" 2>/dev/null || ssh-keygen -lf "$work/key.pub" 2>/dev/null)"
      bits="$(awk '{print $1}' <<< "$fp_line")"; fp="$(awk '{print $2}' <<< "$fp_line")"
      rec key "$user" "$file" "$n" "$type" "$bits" "${fp:-unreadable}" "$comment" "$opts"
      count_keys=$((count_keys + 1))
    else
      rec note "$file line $n is not a key this report understands"
    fi
  done < "$file"
}

# ---- Sudo rules, as sudo itself resolves them ----
HAVE_SUDO=0
command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ] && HAVE_SUDO=1
[ "$HAVE_SUDO" = "1" ] || rec note "sudo rules not checked (sudo not installed, or not run as root)"
sudo_rules() {
  local user="$1"
  [ "$HAVE_SUDO" = "1" ] || return 0
  # Only the indented lines after "may run the following commands"
  timeout 15 sudo -n -l -U "$user" 2>/dev/null |
    awk '/may run the following commands/ {on = 1; next} on && /^[[:space:]]+[^[:space:]]/ {sub(/^[[:space:]]+/, ""); print}'
}

LASTLOG=""
command -v lastlog >/dev/null 2>&1 && LASTLOG=lastlog
[ -z "$LASTLOG" ] && command -v lastlog2 >/dev/null 2>&1 && LASTLOG=lastlog2
last_login() {
  local l
  [ -n "$LASTLOG" ] || return 0
  l="$(timeout 10 "$LASTLOG" -u "$1" 2>/dev/null | awk 'NR == 2')"
  case "$l" in *"Never logged in"*) echo never ;; *) echo "$l" | tr -s ' ' | cut -d' ' -f2- ;; esac
}

# ---- Users ----
count_users=0
while IFS=: read -r user _ uid gid _ home shell; do
  [ -n "$user" ] || continue
  case "$shell" in
    ""|*/nologin|*/false|/bin/sync|/sbin/shutdown|/sbin/halt|*/noshell) can_login=no ;;  # release-check: destructive-ok (login shell names only, nothing is shut down)
    *) can_login=yes ;;
  esac
  groups="$(id -Gn "$user" 2>/dev/null | tr ' ' ',')"
  in_admin=no
  for g in $ADMIN_GROUPS; do
    [[ ",$groups," == *",$g,"* ]] && in_admin=yes
  done
  key_files=()
  while IFS= read -r f; do
    [ -s "$f" ] && key_files+=("$f")
  done < <(key_files_for "$user" "$home")
  rules="$(sudo_rules "$user")"

  # Ordinary service accounts with none of these aren't access, so skip them
  if [ "$can_login" = "no" ] && [ "$uid" != "0" ] && [ "$in_admin" = "no" ] &&
     [ "${#key_files[@]}" -eq 0 ] && [ -z "$rules" ]; then
    continue
  fi

  password="unknown" changed="" expires=""
  if shadow="$(getent shadow "$user" 2>/dev/null)" && [ -n "$shadow" ]; then
    IFS=: read -r _ hash lastchg _ _ _ _ expire _ <<< "$shadow"
    case "$hash" in
      "") password=blank ;;
      "*"|"!"|"!!"|"!*"|"*LK*") password=none ;;
      "!"*) password=locked ;;
      *) password=set ;;
    esac
    changed="$(days_to_date "$lastchg")"
    expires="$(days_to_date "$expire")"
    unset hash
  fi

  rec user "$user" "$uid" "$gid" "$home" "$shell" "$can_login" "$password" "$changed" "$expires" "$groups" "$(last_login "$user")"
  count_users=$((count_users + 1))
  for f in "${key_files[@]+"${key_files[@]}"}"; do
    read_keys "$user" "$f"
  done
  if [ -n "$rules" ]; then
    while IFS= read -r r; do
      [[ "$r" == *NOPASSWD* ]] && np=yes || np=no
      rec sudo "$user" "$np" "$r"
    done <<< "$rules"
  fi
done < <(getent passwd)

# ---- Admin groups, including members who aren't real logins ----
for g in $ADMIN_GROUPS; do
  line="$(getent group "$g" 2>/dev/null)" || continue
  rec group "$g" "$(cut -d: -f4 <<< "$line")"
done

# ---- Sudoers files, so a change to any of them shows up ----
for sf in /etc/sudoers /etc/sudoers.d/*; do
  [ -f "$sf" ] && [ -r "$sf" ] || continue
  rec sudoers "$sf" "$(sha256sum "$sf" | awk '{print $1}')"
done

if [ -f /etc/os-release ]; then
  OS_VERSION="$(. /etc/os-release && echo "$PRETTY_NAME")"
else
  OS_VERSION="$(uname -sr)"
fi
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

if [ "$DRY_RUN" = "1" ]; then
  echo "Would POST to $WEBHOOK_URL"
  echo "hostname=$(hostname) fqdn=$HOSTNAME_FQDN os_version=$OS_VERSION"
  echo "$count_users user(s), $count_keys key(s)"
  echo
  cat "$OUT"
  exit 0
fi

curl -fsS --proto '=https' --retry 3 --max-time 120 -X POST "$WEBHOOK_URL" -H "X-Fleet-Token: $FLEET_TOKEN" \
  -F "report=@$OUT;type=text/plain" \
  -F "hostname=$(hostname)" \
  -F "fqdn=$HOSTNAME_FQDN" \
  -F "os_version=$OS_VERSION"
echo
