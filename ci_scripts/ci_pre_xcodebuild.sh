#!/bin/sh
#
# Xcode Cloud pre-build script.
#
# Sets the build number (CFBundleVersion) from Xcode Cloud's own counter.
#
# The two version fields do different jobs and are managed differently:
#
#   MARKETING_VERSION       — CFBundleShortVersionString, SemVer, e.g. 5.0.0.
#                             Human-facing, edited by hand once per release.
#   CURRENT_PROJECT_VERSION — CFBundleVersion. NOT a version: an opaque token
#                             whose only contract is that it increases. Set here,
#                             never by hand, and never reset between releases.
#
# Resetting it per release is allowed by App Store Connect but buys nothing, and
# it creates a trap: upload 5.0.0 build 3, ship 5.0.1 as build 1, then need
# another 5.0.0 build and you have to remember where that train was. A counter
# that only ever goes up means the question never comes up.
#
# The number is rewritten in project.pbxproj rather than injected through an
# xcconfig because Config.xcconfig is the base configuration of the app target
# ONLY. An xcconfig would bump the app and leave the widget and the Watch app
# behind, and an embedded bundle whose CFBundleVersion does not match its host
# app is refused at upload. Rewriting every occurrence covers all targets, and
# covers a target added later without anyone remembering this file exists.
#
# NOTE: only ONE Xcode Cloud workflow may upload. CI_BUILD_NUMBER is per-workflow
# and each new workflow starts its own count at 1, which would regress the build
# number and have the upload refused.

set -eu

PROJECT="${CI_PRIMARY_REPOSITORY_PATH:-$PWD}/AeroCheck.xcodeproj/project.pbxproj"

# Outside Xcode Cloud there is no counter to read: leave the checked-in default
# alone so a local build still builds.
if [ -z "${CI_BUILD_NUMBER:-}" ]; then
    echo "ci_pre_xcodebuild: CI_BUILD_NUMBER not set — keeping the build number from the project"
    exit 0
fi

# Refuse anything that is not a plain integer rather than writing a build number
# that App Store Connect will reject at the end of a long build.
case "$CI_BUILD_NUMBER" in
    ''|*[!0-9]*)
        echo "ci_pre_xcodebuild: CI_BUILD_NUMBER '$CI_BUILD_NUMBER' is not an integer" >&2
        exit 1
        ;;
esac

if [ ! -f "$PROJECT" ]; then
    echo "ci_pre_xcodebuild: no project file at $PROJECT" >&2
    exit 1
fi

sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = ${CI_BUILD_NUMBER};/g" "$PROJECT"

# Say what was written, and how many targets got it: a count that suddenly drops
# means a target stopped being covered.
COUNT=$(grep -c "CURRENT_PROJECT_VERSION = ${CI_BUILD_NUMBER};" "$PROJECT")
echo "ci_pre_xcodebuild: build number ${CI_BUILD_NUMBER} written to ${COUNT} build configurations"
