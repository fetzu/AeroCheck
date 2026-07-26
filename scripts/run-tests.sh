#!/bin/bash
#
# Runs the AeroCheck unit tests, with a preflight cleanup and a stall watchdog for the most common
# local failure mode: a run that hangs with ZERO test cases started.
#
# Cause: SWBBuildService wedges. `xcodebuild` blocks in `waitForBuildWithBuildLog:` waiting on it,
# while the service sits idle in `read` with no lock contention — a lost message between the two, so
# the BUILD never completes and tests never begin.
#
# Diagnose by sampling `xcodebuild` itself, never the app. A leftover app process on the simulator is
# a red herring: sampling it shows an ordinary idle CFRunLoop, which reads convincingly like "the test
# bundle was never injected" when in fact the build never finished.
#
# The preflight below clears a wedged service before starting, but a FRESHLY spawned one can wedge
# too — so the watchdog further down detects the stall and retries. `testmanagerd` and simulator
# reboots are NOT the fix; earlier versions of this script claimed they were and were wrong.
#
# Usage:
#   scripts/run-tests.sh                      # default destination
#   scripts/run-tests.sh "iPhone 17"          # another simulator by name
#   scripts/run-tests.sh "" ObstacleTests     # filter to one test class (target prefix optional)
#
# Never stop this script (or xcodebuild) with `kill -9`, and never run it from a foreground shell
# that might be killed — a dying process group takes xcodebuild with it and leaves debris behind.
# Ctrl-C sends SIGINT, which xcodebuild cleans up after correctly.

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

# Run under a stall watchdog.
#
# SWBBuildService can wedge mid-build: xcodebuild blocks in `waitForBuildWithBuildLog:` while the
# service sits idle in `read`, so the build never completes and NO test case ever starts. It happens
# to a freshly-spawned service too, so clearing one beforehand reduces it but cannot prevent it.
#
# Detection is simple and reliable: if the log stops growing while zero test cases have started, the
# build is stuck. (Once tests are running a quiet log is normal, so the check is disabled from then
# on.) On a stall we kill the run, clear the build service, and retry once.
STALL_CHECK_SECONDS=10
STALL_LIMIT=4          # ~40 s of no output and no tests started

run_once() {
  xcodebuild "${ARGS[@]}" > "$LOG" 2>&1 &
  local pid=$! last=0 stalls=0 now
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$STALL_CHECK_SECONDS"
    # Once any test case has started the build is past; let it run to completion.
    if grep -q "Test Case" "$LOG" 2>/dev/null; then
      wait "$pid"; return $?
    fi
    now=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    if [ "$now" -eq "$last" ]; then stalls=$((stalls + 1)); else stalls=0; fi
    last=$now
    if [ "$stalls" -ge "$STALL_LIMIT" ]; then
      echo "    !! build stalled (no output, no tests started) — killing and clearing build service"
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      killall SWBBuildService XCBBuildService 2>/dev/null
      sleep 2
      return 99
    fi
  done
  wait "$pid"; return $?
}

run_once
STATUS=$?
if [ "$STATUS" -eq 99 ]; then
  echo "==> Retrying after the stall"
  run_once
  STATUS=$?
  [ "$STATUS" -eq 99 ] && echo "!! stalled twice — this is the SWBBuildService wedge, not your code"
fi

echo
grep -E "error:|XCTAssert.*failed|Executed [0-9]+ tests, with|TEST SUCCEEDED|TEST FAILED" "$LOG" | tail -20

if [ "$STATUS" -ne 0 ] && ! grep -q "TEST FAILED" "$LOG"; then
  # Non-zero without a test verdict usually means the run never reached the tests at all.
  echo
  echo "!! xcodebuild exited $STATUS with no test verdict. Last log lines:"
  tail -15 "$LOG"
  echo
  echo "   If it hung with no test cases started, that is the SWBBuildService wedge — the"
  echo "   watchdog above retries once automatically; run again if it hit the limit twice."
fi

echo
echo "Full log: $LOG"
exit "$STATUS"
