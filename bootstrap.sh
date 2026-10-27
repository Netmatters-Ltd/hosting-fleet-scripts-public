#!/usr/bin/env bash
# Installs the fleet agent on a server for the first time. Read this before
# running it: it's the one step that isn't covered by the double checksum,
# so it asks YOU for the checksum shown on the n8n Fleet Status page and
# checks the download against both that and GitHub's.
#
# Usage (as root):
#   bash bootstrap.sh [--token TOKEN] [--n8n URL] <release-number> <sha256-from-n8n-status-page>
#
# The token and n8n address can also come from FLEET_TOKEN and N8N_BASE. Any
# that are missing are asked for. The token is never kept in this repository.
#
# It only installs the agent itself. It then runs the agent once, and the
# agent installs the full release through the normal checked route.
set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-Netmatters-Ltd/hosting-fleet-scripts-public}"
CONF=/netmatters/fleet-agent/fleet-agent.conf
usage="Usage: bash bootstrap.sh [--token TOKEN] [--n8n URL] <release-number> <sha256-from-n8n-status-page>"

token="${FLEET_TOKEN:-}"; n8n="${N8N_BASE:-}"
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --token) token="${2:-}"; shift 2 ;;
    --n8n) n8n="${2:-}"; shift 2 ;;
    -*) echo "$usage" >&2; exit 1 ;;
    *) args+=("$1"); shift ;;
  esac
done
rel="${args[0]:-}"; expected="$(printf '%s' "${args[1]:-}" | tr 'A-F' 'a-f')"
[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
[[ "$rel" =~ ^[0-9]+$ ]] && [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { echo "$usage" >&2; exit 1; }
for cmd in curl sha256sum tar flock timeout; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd is required." >&2; exit 1; }
done

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
name="release-$rel.tar"
base="https://github.com/$GITHUB_REPO/releases/download/r$rel"
curl -fsSL --proto '=https' -o "$work/$name" "$base/$name"
gh_sum="$(curl -fsSL --proto '=https' "$base/$name.sha256" | awk 'NR==1 {print tolower($1)}')"
actual="$(sha256sum "$work/$name" | awk '{print $1}')"

echo "Downloaded:  $actual"
echo "GitHub says: $gh_sum"
echo "You entered: $expected"
if [ "$actual" != "$gh_sum" ] || [ "$actual" != "$expected" ]; then
  echo "Checksums do not match. Nothing installed." >&2; exit 1
fi

mkdir "$work/unpacked"
tar -xf "$work/$name" -C "$work/unpacked" --no-same-owner
agent="$work/unpacked/components/fleet-agent"
[ -d "$agent" ] || { echo "Release $rel has no fleet-agent component." >&2; exit 1; }

# Config: written by hand once, never by a release
if [ ! -f "$CONF" ]; then
  [ -n "$n8n" ] || read -r -p "n8n address (https://...): " n8n
  [ -n "$token" ] || { read -r -s -p "Fleet token: " token; echo; }
  [[ "$n8n" =~ ^https://[^[:space:]]+$ ]] || { echo "The n8n address must start with https://" >&2; exit 1; }
  [ -n "$token" ] || { echo "The token can't be empty." >&2; exit 1; }
  mkdir -p /netmatters/fleet-agent
  chown root:root /netmatters /netmatters/fleet-agent; chmod go-w /netmatters /netmatters/fleet-agent
  umask 077
  printf 'N8N_BASE=%q\nGITHUB_REPO=%q\nFLEET_TOKEN=%q\n' "${n8n%/}" "$GITHUB_REPO" "$token" > "$CONF"
  chown root:root "$CONF"; chmod 0600 "$CONF"
  echo "Wrote $CONF. Add any per-server settings (see bootstrap.md) before the first release that needs them."
else
  echo "Keeping existing $CONF"
fi

( cd "$agent/files" && tar -cf - . ) | tar -xf - -C / --no-same-owner --no-overwrite-dir --touch
( cd "$agent" && RELEASE="$rel" COMPONENT=fleet-agent bash ./install.sh )

echo "Agent installed. Running it once now:"
/netmatters/fleet-agent/bin/nm-fleet-agent --now || true
/netmatters/fleet-agent/bin/nm-fleet-agent --status
