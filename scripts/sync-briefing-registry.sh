#!/bin/bash
#
# Copy the briefing registry the app ships with from the production API, the one the App Store build reads.
#
# The app reads /data/briefing/v1/briefing.json and keeps the last download; until its first download (a first
# launch offline) it reads AeroCheck/Resources/briefing-registry.json, so that copy should be the registry as it
# ships. Run before every release, beside scripts/sync-bundled-wt9.sh, then commit the file if it changed.
#
# The API answers only an app client: the script sends APP_CLIENT_SECRET from the untracked Secrets.xcconfig and
# never prints it. Usage, from this repository's root:
#   scripts/sync-briefing-registry.sh [API host]   (default api.aerocheck.app)

set -euo pipefail

HOST=${1:-api.aerocheck.app}
TARGET=AeroCheck/Resources/briefing-registry.json
SECRETS=Secrets.xcconfig

if [ ! -f "${TARGET}" ] || [ ! -f "${SECRETS}" ]; then
  echo "Run from the app repository's root, with Secrets.xcconfig in place." >&2
  exit 1
fi

SECRET=$(sed -n 's/^APP_CLIENT_SECRET[[:space:]]*=[[:space:]]*//p' "${SECRETS}" | tr -d '\r' | sed 's/[[:space:]]*$//')
if [ -z "${SECRET}" ]; then
  echo "No APP_CLIENT_SECRET in ${SECRETS}." >&2
  exit 1
fi

TMP=$(mktemp)
trap 'rm -f "${TMP}"' EXIT
STATUS=$(curl -s -o "${TMP}" -w '%{http_code}' -H "X-AeroCheck-Client: ${SECRET}" \
  "https://${HOST}/data/briefing/v1/briefing.json")
if [ "${STATUS}" != "200" ]; then
  echo "The API answered ${STATUS}; ${TARGET} left as it was." >&2
  exit 1
fi

# A registry the app can read: schema 1 and its countries.
python3 - "${TMP}" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("v") == 1, "schema"
assert len(data.get("countries", {})) >= 40, "countries"
EOF

cp "${TMP}" "${TARGET}"
if git diff --quiet -- "${TARGET}"; then
  echo "The shipped briefing registry is already ${HOST}'s."
else
  git --no-pager diff --stat -- "${TARGET}"
  echo "Updated from ${HOST}: run BriefingRegistryTests (every link on an allowed domain), then commit the file."
fi
