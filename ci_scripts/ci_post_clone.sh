#!/bin/sh
#
# Xcode Cloud post-clone script.
#
# Xcode Cloud builds from a fresh clone of the GitHub repo, where Secrets.xcconfig
# is absent (it's gitignored and never committed). This script materializes it from
# the OPENAIP_API_KEY *secret* environment variable defined in the Xcode Cloud
# workflow, so the build picks up the OpenAIP key via Config.xcconfig's
# `#include? "Secrets.xcconfig"`.
#
# No secret is committed to the repo or printed to the build log (printf writes to
# the file, not stdout; Xcode Cloud also masks secret env vars in logs).
#
# If OPENAIP_API_KEY is not set, the build still succeeds with an empty key — the
# OpenAIP airspace/CTR features simply don't render (graceful fallback).

set -eu

SECRETS_FILE="${CI_PRIMARY_REPOSITORY_PATH:-$PWD}/Secrets.xcconfig"

if [ -n "${OPENAIP_API_KEY:-}" ]; then
    printf 'OPENAIP_API_KEY = %s\n' "$OPENAIP_API_KEY" > "$SECRETS_FILE"
    echo "ci_post_clone: wrote Secrets.xcconfig (OPENAIP_API_KEY is set)"
else
    echo "ci_post_clone: OPENAIP_API_KEY not set — skipping Secrets.xcconfig; OpenAIP features will be disabled in this build"
fi
