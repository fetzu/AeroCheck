#!/bin/sh
#
# Xcode Cloud post-clone script.
#
# Xcode Cloud builds from a fresh clone of the GitHub repo, where Secrets.xcconfig
# is absent (it's gitignored and never committed). This script materializes it from
# the *secret* environment variables defined in the Xcode Cloud workflow, so the
# build picks them up via Config.xcconfig's `#include? "Secrets.xcconfig"`:
#
#   OPENAIP_API_KEY        — OpenAIP airspace tiles / CTR REST
#   WEATHER_CLIENT_SECRET  — X-AeroCheck-Client header for wx.aerocheck.app
#
# No secret is committed to the repo or printed to the build log (printf writes to
# the file, not stdout; Xcode Cloud also masks secret env vars in logs).
#
# Either may be absent and the build still succeeds: an empty OpenAIP key simply
# means the airspace/CTR features don't render, and an empty weather secret is
# fine because the worker fails open when its own list is unset.

set -eu

SECRETS_FILE="${CI_PRIMARY_REPOSITORY_PATH:-$PWD}/Secrets.xcconfig"

# Truncate once, then append each secret that is set, so the two are independent:
# providing only one must not drop the other.
: > "$SECRETS_FILE"

if [ -n "${OPENAIP_API_KEY:-}" ]; then
    printf 'OPENAIP_API_KEY = %s\n' "$OPENAIP_API_KEY" >> "$SECRETS_FILE"
    echo "ci_post_clone: OPENAIP_API_KEY is set"
else
    echo "ci_post_clone: OPENAIP_API_KEY not set — OpenAIP features will be disabled in this build"
fi

if [ -n "${WEATHER_CLIENT_SECRET:-}" ]; then
    printf 'WEATHER_CLIENT_SECRET = %s\n' "$WEATHER_CLIENT_SECRET" >> "$SECRETS_FILE"
    echo "ci_post_clone: WEATHER_CLIENT_SECRET is set"
else
    echo "ci_post_clone: WEATHER_CLIENT_SECRET not set — weather requests will omit the client header"
fi
