#!/usr/bin/env bash
# Compare every screenshot in public/assets/screenshot/v6 with the one aerocheck.app serves, after a deploy.
#
# The page asks for each image with a hash of its contents (`?v=…`, src/lib/shots.ts), so a visitor gets a
# recaptured image at once. This checks the other end: that the site serves the files this checkout has.
# A mismatch right after a push means the deploy hasn't finished (or failed); later, that the repo moved on.
#
# Usage, from the website's root:
#   scripts/check-live-screenshots.sh [https://aerocheck.app]
set -euo pipefail

SITE="${1:-https://aerocheck.app}"
ROOT="public/assets/screenshot/v6"
[ -d "$ROOT" ] || { echo "Run from the website's root." >&2; exit 2; }

TMP="$(mktemp -d)"
trap '/bin/rm -rf "$TMP"' EXIT

same=0; differ=0
for FILE in "$ROOT"/*/*.jpg; do
  REL="${FILE#public}"
  # A query of our own, so no cache between here and the site answers with an older copy.
  if ! curl -fsS -o "$TMP/live.jpg" "$SITE$REL?check=$(date +%s)"; then
    echo "✗ $REL: not served"; differ=$((differ + 1)); continue
  fi
  if cmp -s "$FILE" "$TMP/live.jpg"; then
    same=$((same + 1))
  else
    echo "✗ $REL: the site serves another image"; differ=$((differ + 1))
  fi
done
echo "$same served as in this checkout, $differ not."
[ "$differ" -eq 0 ]
