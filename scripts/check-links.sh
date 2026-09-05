#!/bin/bash
#
# Fetch every authority URL the app hands to a pilot, and report the ones that are broken.
#
# This exists because two of them shipped dead. The border pack and the thread's task links
# deliberately store a LINK instead of restating the rule, so the link is the content — and a dead
# one looks perfectly fine in code review, failing only in the pilot's hand during flight prep.
# `BorderCrossingTests.testEverySourceIsAGovernmentHost` guards the host; only a real request
# guards reachability, and a unit test must not make one.
#
# Not part of the test suite on purpose: it needs the network, and a government site being briefly
# down should never fail a build. Run it when adding or editing a curated URL, and periodically.
#
#   scripts/check-links.sh
#
# Exit status is the number of broken links, so CI could gate on it later if that becomes useful.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SOURCES=(
    "AeroCheck/Models/BorderCrossing.swift"
    "AeroCheck/Views/FlightThreadView.swift"
)

# Some authorities (legifrance.gouv.fr among them) refuse a scripted request with 403 while serving
# a browser perfectly well. That is bot protection, not a dead page, so it is reported separately
# rather than counted as a failure — a 403 here needs a human to open it once, not a code change.
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36'

urls=$(grep -ohE 'https://[^"]+' "${SOURCES[@]}" | sort -u)
broken=0
blocked=0
ok=0

echo "Checking $(echo "$urls" | wc -l | tr -d ' ') curated URLs…"
echo

while IFS= read -r url; do
    [ -z "$url" ] && continue
    code=$(curl -sSL -o /dev/null -w '%{http_code}' -m 30 -A "$UA" "$url" 2>/dev/null)
    case "$code" in
        2*)
            ok=$((ok + 1))
            ;;
        403|429)
            blocked=$((blocked + 1))
            printf '  \033[33m%s\033[0m  %s  (bot protection — open it in a browser to confirm)\n' "$code" "$url"
            ;;
        *)
            broken=$((broken + 1))
            printf '  \033[31m%s\033[0m  %s\n' "${code:-000}" "$url"
            ;;
    esac
done <<< "$urls"

echo
echo "$ok reachable, $blocked blocked to scripts, $broken broken."
[ "$broken" -gt 0 ] && echo "A broken link is a pilot with no way to check the rule. Fix before shipping."
exit "$broken"
