#!/bin/bash
#
# Runs the AeroCheck unit tests, with a preflight cleanup that prevents the most common
# local failure mode: a hang in which the build succeeds, the app launches on the simulator,
# and then ZERO test cases ever start.
#
# Cause: a SIGKILLed `xcodebuild test` orphans the host-side /usr/libexec/testmanagerd, which
# keeps holding the test session. Every later run then builds and launches fine and waits forever
# for a test bundle the stale broker never hands over. Sampling the app shows it idle in a normal
# CFRunLoop rather than deadlocked — that "idle, not blocked" signature means the harness is stuck,
# not the app.
#
# Neither `simctl shutdown all` nor killing CoreSimulatorService touches testmanagerd, so those
# resets appear to work once and then the hang returns. Killing testmanagerd is the actual fix.
#
# Usage:
#   scripts/run-tests.sh                      # default destination
#   scripts/run-tests.sh "iPhone 17"          # another simulator by name
#   scripts/run-tests.sh "" ObstacleTests     # filter to one test class (target prefix optional)
#
# Never stop this script (or xcodebuild) with `kill -9` — that is what creates the orphan in the
# first place. Ctrl-C sends SIGINT, which xcodebuild cleans up after correctly.

set -uo pipefail

DEVICE="${1:-iPad Air 11-inch (M4)}"
[ -z "$DEVICE" ] && DEVICE="iPad Air 11-inch (M4)"
ONLY_TESTING="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$SCRIPT_DIR/../AeroCheck.xcodeproj"
SCHEME="AeroCheckTests"
LOG="${TMPDIR:-/tmp}/aerocheck-tests.log"

echo "==> Preflight: clearing stale test state"

# SIGTERM, never -9: let xcodebuild tear its own session down.
if pgrep -f "xcodebuild test -scheme $SCHEME" >/dev/null 2>&1; then
  echo "    stopping a previous xcodebuild test run"
  pkill -f "xcodebuild test -scheme $SCHEME" 2>/dev/null
  sleep 2
fi

# Kill the BUILD SERVICE. This is the one that matters.
#
# The observed hang is `xcodebuild` blocked in `waitForBuildWithBuildLog:` waiting on
# SWBBuildService, while SWBBuildService sits idle in `read` with no lock contention — a lost
# message between the two. The build simply never completes, so the log stops at whatever step it
# reached and no test case ever starts.
#
# Diagnosing this means sampling `xcodebuild` itself (`sample <pid>`), NOT the app. An app process
# left running on the simulator is a red herring: it is usually a leftover from a previous run, and
# sampling it shows an ordinary idle run loop, which reads convincingly like "the test bundle was
# never injected" when the truth is that the build never finished.
#
# xcodebuild spawns a fresh service when the old one is gone, so killing it is the fix.
echo "    clearing stale build service and leftover simulator app processes"
pkill -f "AeroCheck.app/AeroCheck" 2>/dev/null   # leftover host app from a previous run
killall SWBBuildService XCBBuildService 2>/dev/null
# Precautionary, not proven to matter: testmanagerd brokers the test session, and clearing it is
# cheap. Do not read this as a diagnosis — the build service above is the demonstrated cause.
killall -9 testmanagerd 2>/dev/null
sleep 2

# Booting explicitly, and waiting for ready, keeps boot from racing test-bundle injection.
# The device is NOT force-rebooted: an earlier version of this script did that on the theory that a
# stale runtime-side testmanagerd was to blame. That theory was wrong, and the reboot cost ~15 s a run.
if ! xcrun simctl list devices booted | grep -qF "$DEVICE"; then
  echo "==> Booting $DEVICE"
  xcrun simctl boot "$DEVICE" >/dev/null 2>&1
fi
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1

echo "==> Testing on $DEVICE${ONLY_TESTING:+ (only: $ONLY_TESTING)}"

ARGS=(test -scheme "$SCHEME" -project "$PROJECT" -destination "platform=iOS Simulator,name=$DEVICE")
if [ -n "$ONLY_TESTING" ]; then
  # -only-testing wants Target/Class; accept a bare class name and prefix the test target.
  case "$ONLY_TESTING" in
    */*) ARGS+=(-only-testing:"$ONLY_TESTING") ;;
    *)   ARGS+=(-only-testing:"AeroCheckTests/$ONLY_TESTING") ;;
  esac
fi

xcodebuild "${ARGS[@]}" > "$LOG" 2>&1
STATUS=$?

echo
grep -E "error:|XCTAssert.*failed|Executed [0-9]+ tests, with|TEST SUCCEEDED|TEST FAILED" "$LOG" | tail -20

if [ "$STATUS" -ne 0 ] && ! grep -q "TEST FAILED" "$LOG"; then
  # Non-zero without a test verdict usually means the run never reached the tests at all.
  echo
  echo "!! xcodebuild exited $STATUS with no test verdict. Last log lines:"
  tail -15 "$LOG"
  echo
  echo "   If it hung with no test cases started, re-run this script — the preflight above"
  echo "   clears the orphaned testmanagerd that causes it."
fi

echo
echo "Full log: $LOG"
exit "$STATUS"
