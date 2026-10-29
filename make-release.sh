#!/usr/bin/env bash
# Builds the release tarball for the release number in LATEST, byte for byte
# the same on any Linux machine with GNU tar, and prints its SHA-256.
#
# GitHub Actions runs this to publish each release. Approvers run it too, on
# the reviewed commit, and paste the checksum THEY get into the n8n approval
# form. Never copy the checksum from GitHub: the two must come from
# separate builds for the double check to mean anything.
#
# Usage: ./make-release.sh [output-dir]      (default: dist)
set -euo pipefail
cd "$(dirname "$0")"
export LC_ALL=C

tar --version 2>/dev/null | head -1 | grep -q 'GNU tar' || { echo "GNU tar is required (run on Linux or WSL)." >&2; exit 1; }

rel="$(tr -d '[:space:]' < LATEST)"
[[ "$rel" =~ ^[0-9]+$ ]] || { echo "LATEST must contain a single release number." >&2; exit 1; }
inner="$(sed -n 's/.*"release"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' release.json | head -1)"
[ "$inner" = "$rel" ] || { echo "release.json says release ${inner:-none} but LATEST says $rel." >&2; exit 1; }

for d in components/*/; do
  n="$(basename "$d")"
  [[ "$n" =~ ^[a-z0-9-]+$ ]] || { echo "Invalid component name: $n" >&2; exit 1; }
  if [ -d "$d/cron" ]; then
    for f in "$d"/cron/*; do
      [[ "$(basename "$f")" =~ ^[a-z0-9-]+$ ]] || { echo "Invalid cron file name: $f" >&2; exit 1; }
    done
  fi
done
if grep -rIlE $'\r$' release.json components >/dev/null; then
  echo "Some files have Windows line endings (CRLF). Fix them before releasing." >&2; exit 1
fi
# Ubuntu and CentOS safe, and nothing destructive unless marked
bash ./check-release.sh

out="${1:-dist}"
mkdir -p "$out"
name="release-$rel.tar"

# Copy to a scratch folder and fix every mode, so permissions from the
# checkout (umask, Windows file systems) can't change the result. Components
# set real file modes in their install.sh.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R release.json components "$stage/"
find "$stage" -type d -exec chmod 0755 {} +
find "$stage" -type f -exec chmod 0644 {} +

# Uncompressed on purpose: gzip output can differ between versions, tar
# output with these options doesn't.
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner --format=gnu \
    -C "$stage" -cf "$out/$name" release.json components

( cd "$out" && sha256sum "$name" > "$name.sha256" )
echo "Release $rel"
cat "$out/$name.sha256"
