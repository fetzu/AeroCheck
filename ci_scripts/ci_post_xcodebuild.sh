#!/bin/sh
#
# Xcode Cloud post-build script.
#
# Writes TestFlight's "What to Test" for the build Xcode Cloud is about to upload.
# Xcode Cloud reads TestFlight/WhatToTest.<locale>.txt, next to the Xcode project,
# when it distributes a build (Apple, "Including notes for testers with a beta
# release of your app"), and every tester of that build sees the text.
#
#   A release tag (the "Beta · tags" workflow, CI_TAG set): the notes committed in
#   TestFlight/, written for that release before it was tagged. Their first line
#   names the version. If a file doesn't name this tag, it is an older release's,
#   and that language gets the pull requests merged since the previous tag instead.
#
#   Anything else (the main workflow, for the internal group): the last pull
#   requests merged, in English for both languages, since the internal testers
#   read the repository's language.
#
# It never fails the build: notes are not worth losing an upload over.

set -u

# Only an archive on its way to TestFlight needs notes.
if [ -z "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]; then
    echo "ci_post_xcodebuild: not an App Store build, no notes for testers"
    exit 0
fi

REPO="${CI_PRIMARY_REPOSITORY_PATH:-$PWD}"
DIR="$REPO/TestFlight"
LOCALES="en-US fr-FR"
MAX_LINES=25   # well under TestFlight's 4,000 characters
mkdir -p "$DIR" || exit 0

# Xcode Cloud clones shallow: fetch enough history (and the tags) to list what changed.
git -C "$REPO" fetch --quiet --tags --deepen 200 2>/dev/null || true

# One line per first-parent commit of the given range: "• <title> (#N)". A GitHub
# merge commit's subject is "Merge pull request #N from <branch>"; the pull
# request's title is the first line of its body.
changes() {
    git -C "$REPO" log --first-parent --format='%s%x1f%b%x1e' "$@" 2>/dev/null | awk '
        BEGIN { RS = "\036"; FS = "\037" }
        {
            subject = $1; sub(/^\n+/, "", subject)
            body = $2; sub(/^\n+/, "", body); split(body, lines, "\n")
            if (subject == "") next
            if (match(subject, /^Merge pull request #[0-9]+/)) {
                number = substr(subject, 21, RLENGTH - 20)
                title = (lines[1] != "") ? lines[1] : subject
                print "• " title " (#" number ")"
            } else if (subject !~ /^Merge /) {
                print "• " subject
            }
        }' | head -n "$MAX_LINES"
}

write_all() {   # $1 = the text, for every language
    for locale in $LOCALES; do
        printf '%s\n' "$1" > "$DIR/WhatToTest.$locale.txt"
    done
}

SHORT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "?")

if [ -n "${CI_TAG:-}" ]; then
    PREVIOUS=$(git -C "$REPO" describe --tags --abbrev=0 "$CI_TAG^" 2>/dev/null || echo "")
    for locale in $LOCALES; do
        FILE="$DIR/WhatToTest.$locale.txt"
        if [ -f "$FILE" ] && head -n 1 "$FILE" | grep -qwF "$CI_TAG"; then
            echo "ci_post_xcodebuild: $locale notes for $CI_TAG, as committed"
            continue
        fi
        echo "ci_post_xcodebuild: WARNING the committed $locale notes don't name $CI_TAG; listing the changes instead"
        if [ -n "$PREVIOUS" ]; then
            LIST=$(changes "$PREVIOUS..HEAD")
            HEADER="$CI_TAG: the changes since $PREVIOUS"
        else
            LIST=$(changes -n 10)
            HEADER="$CI_TAG: the latest changes"
        fi
        printf '%s\n\n%s\n' "$HEADER" "$LIST" > "$FILE"
    done
else
    LIST=$(changes -n 8)
    write_all "$(printf 'main at %s, build %s. Merged recently:\n\n%s' "$SHORT" "${CI_BUILD_NUMBER:-?}" "$LIST")"
    echo "ci_post_xcodebuild: notes for main at $SHORT"
fi

for locale in $LOCALES; do
    echo "ci_post_xcodebuild: WhatToTest.$locale.txt is $(wc -c < "$DIR/WhatToTest.$locale.txt" | tr -d ' ') bytes"
done
exit 0
