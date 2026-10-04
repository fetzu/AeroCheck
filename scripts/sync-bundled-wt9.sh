#!/bin/bash
#
# Copy the WT9's checklists into the app's bundle from the checklists repository, their source of truth.
#
# The app bundles the free aircraft so it works offline and before the first API call; the API serves
# the checklists repository's copy, and the app takes it over the bundled one whenever its `version` is
# the same or newer. So the bundle is only a snapshot, and it should be the repository's as it ships.
# Run before every release (and after any WT9 change there), then commit the two files if they changed.
#
# Reads origin/main of the checklists repository, never its working copy: a local edit or another
# branch there is not what the API serves. Usage, from this repository's root:
#   scripts/sync-bundled-wt9.sh [path to AeroCheck-checklists]   (default ../AeroCheck-checklists)

set -euo pipefail

CHECKLISTS=${1:-../AeroCheck-checklists}
SOURCE=checklists/wt9-dynamic/current
TARGET=AeroCheck/Resources

if [ ! -d "${TARGET}" ]; then
  echo "Run from the app repository's root." >&2
  exit 1
fi

git -C "${CHECKLISTS}" fetch -q origin main
git -C "${CHECKLISTS}" show "origin/main:${SOURCE}/F-HVXA_en.json" > "${TARGET}/wt9-dynamic-bundled.json"
git -C "${CHECKLISTS}" show "origin/main:${SOURCE}/F-HVXA_fr.json" > "${TARGET}/wt9-dynamic-bundled-fr.json"

if git diff --quiet -- "${TARGET}/wt9-dynamic-bundled.json" "${TARGET}/wt9-dynamic-bundled-fr.json"; then
  echo "The bundled WT9 is already the checklists repository's ($(git -C "${CHECKLISTS}" rev-parse --short origin/main))."
else
  git --no-pager diff --stat -- "${TARGET}/wt9-dynamic-bundled.json" "${TARGET}/wt9-dynamic-bundled-fr.json"
  echo "Updated from the checklists repository's $(git -C "${CHECKLISTS}" rev-parse --short origin/main): run the tests, then commit both files."
fi
