#!/bin/bash
#
# Runs the AeroCheck unit tests on ONE simulator, in two phases with a watchdog each, so a run either
# gives a test verdict or stops with a one-line reason. It never waits open-ended.
#
# Two different failures look like "the tests hang". Tell them apart by WHERE the log stops:
#
# 1. The log stops DURING THE BUILD (no "Testing started"): the build service has wedged.
#    `xcodebuild` blocks in `waitForBuildWithBuildLog:` waiting on SWBBuildService, which sits idle in
#    `read` with no lock contention: a lost message between the two, so the build never completes.
#    Diagnose by sampling `xcodebuild`, not the app. Fix: `killall SWBBuildService XCBBuildService`
#    (xcodebuild spawns a fresh one). A freshly spawned service can wedge too, so the build phase has a
#    log-growth watchdog and retries once.
#
# 2. "Testing started", then NO test case, then after ~5 min "The test runner hung before establishing
#    connection": the host app was launched WITHOUT the XCTest bundle. Seen on 2026-09-27 after several
#    `simctl install` / launch rounds on the same simulator: the host app's main thread was idle and no
#    XCTest image was loaded (`ps eww <pid>` had no XCTestBundleInject). Restarting testmanagerd did
#    nothing; rebooting the simulator only changed the error to "Application launch ... did not return a
#    process handle nor launch error. No such process". `simctl uninstall` fixed it at once, and the old
#    app data put back into the fresh install still ran fine: it was the app's installation on that
#    simulator, not its data and not the code. So before the test phase this script keeps the app's data
#    aside, uninstalls the app, and puts the data back afterwards (--keep-install skips that), and the
#    test phase stops if no test case has started within $AEROCHECK_TEST_START_TIMEOUT seconds (90).
#
# In case 1 an app process left on the simulator IS a red herring (a leftover from an earlier run whose
# idle run loop looks like a missing test bundle). In case 2 it is the real cause; the watchdog message
# says which it is ("XCTest injected: no").
#
# Usage:
#   scripts/run-tests.sh                               # default simulator
#   scripts/run-tests.sh "iPhone 17"                   # another simulator, by name or UDID
#   scripts/run-tests.sh "" ObstacleTests              # one test class (target prefix optional)
#   scripts/run-tests.sh --keep-install "iPhone 17"    # don't reinstall the host app first
#
# A name can match several simulators (the same model on two runtimes, or a copy): the script picks a
# booted one first and prints its UDID. Pass the UDID to choose. Everything the script terminates,
# uninstalls or restores is scoped to that one UDID; other simulators are never touched. The build
# service is the exception: it is shared by every xcodebuild and Xcode on the Mac.
#
# Reinstalling the host app resets that simulator's permission answers for it (location, notifications):
# the app asks again on its next launch. Documents, Library and the app group are put back as they
# were; the keychain is not affected by an uninstall.
#
# Exit codes: 0 all passed · 1 test failures · 2 usage or no such simulator · 3 build failed ·
# 4 build stalled twice · 5 tests never started.
#
# Never stop this script (or xcodebuild) with `kill -9`, and never run it from a shell that might be
# killed: a dying process group takes xcodebuild with it and leaves debris behind. Ctrl-C (SIGINT) and
# SIGTERM are handled: xcodebuild is stopped cleanly and the app data is put back.

set -uo pipefail

KEEP_INSTALL=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --keep-install) KEEP_INSTALL=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
DEVICE="${POSITIONAL[0]:-}"
[ -z "$DEVICE" ] && DEVICE="iPad Air 11-inch (M4)"
ONLY_TESTING="${POSITIONAL[1]:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$SCRIPT_DIR/../AeroCheck.xcodeproj"
SCHEME="AeroCheckTests"
BUNDLE_ID="com.fetzu.aerocheck"
APP_GROUP="group.com.fetzu.aerocheck"
LOG="${TMPDIR:-/tmp}/aerocheck-tests.log"
BUILD_LOG="${TMPDIR:-/tmp}/aerocheck-tests-build.log"
START_TIMEOUT="${AEROCHECK_TEST_START_TIMEOUT:-90}"

# --- The destination, as one UDID --------------------------------------------------------------

resolve_udid() {
  local want="$1"
  if [[ "$want" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    xcrun simctl list devices available | grep -qi "($want)" && echo "$want" | tr 'a-f' 'A-F'
    return
  fi
  # "    iPad Air 11-inch (M4) (A7A5FC41-…) (Booted)" → "name|UDID|state"; exact name, booted first.
  xcrun simctl list devices available \
    | sed -nE 's/^ +(.+) \(([0-9A-F-]{36})\) \(([A-Za-z]+)\).*$/\1|\2|\3/p' \
    | awk -F'|' -v n="$want" '$1 == n { print ($3 == "Booted" ? 0 : 1) "|" $2 }' \
    | sort -s -t'|' -k1,1 | cut -d'|' -f2
}

MATCHES=$(resolve_udid "$DEVICE")
UDID=$(echo "$MATCHES" | head -1)
if [ -z "$UDID" ]; then
  echo "!! No available simulator named or identified \"$DEVICE\"."
  echo "   xcrun simctl list devices available"
  exit 2
fi
if [ "$(echo "$MATCHES" | grep -c .)" -gt 1 ]; then
  echo "    note: $(echo "$MATCHES" | grep -c .) simulators are named \"$DEVICE\"; using $UDID (booted first). Pass a UDID to choose."
fi
DEST="platform=iOS Simulator,id=$UDID"
NAME=$(xcrun simctl list devices | sed -nE "s/^ +(.+) \($UDID\) .*$/\1/p" | head -1)

# --- Preflight -----------------------------------------------------------------------------------

echo "==> Preflight on ${NAME:-$DEVICE} ($UDID)"

# SIGTERM, never -9: let xcodebuild tear its own session down. Only runs aimed at this simulator.
if pgrep -f "xcodebuild .*-scheme $SCHEME .*id=$UDID" >/dev/null 2>&1; then
  echo "    stopping a previous run on this simulator"
  pkill -TERM -f "xcodebuild .*-scheme $SCHEME .*id=$UDID" 2>/dev/null
  sleep 3
fi

# The build service: the one that matters for case 1 (see the header). Shared by every build on the
# Mac, Xcode's included; xcodebuild spawns a fresh one.
killall SWBBuildService XCBBuildService 2>/dev/null
# A host app left running from an earlier run, on THIS simulator only.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
sleep 1

# Booting explicitly, and waiting for ready, keeps boot from racing test-bundle injection. The device
# is not force-rebooted: a reboot did not fix either failure and costs ~15 s a run.
if ! xcrun simctl list devices booted | grep -q "($UDID)"; then
  echo "==> Booting ${NAME:-$DEVICE}"
  xcrun simctl boot "$UDID" >/dev/null 2>&1
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1

# --- Stopping cleanly ------------------------------------------------------------------------------

XCB_PID=""
KEEP_DIR=""
APP_PATH=""

put_app_data_back() {
  [ -n "$KEEP_DIR" ] && [ -d "$KEEP_DIR" ] || return 0
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  if ! xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data >/dev/null 2>&1; then
    # The test phase never got as far as installing the host: install the build to hold the data.
    [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ] && xcrun simctl install "$UDID" "$APP_PATH" >/dev/null 2>&1
  fi
  local data group
  if data=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null) \
     && [[ "$data" == */data/Containers/Data/Application/* ]]; then
    local d
    for d in Documents Library; do
      if [ -d "$KEEP_DIR/$d" ]; then rm -rf "${data:?}/$d" && ditto "$KEEP_DIR/$d" "$data/$d"; fi
    done
    if [ -d "$KEEP_DIR/group" ] && group=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" "$APP_GROUP" 2>/dev/null) \
       && [[ "$group" == */data/Containers/Shared/AppGroup/* ]]; then
      find "$group" -mindepth 1 -maxdepth 1 -exec rm -rf {} + && ditto "$KEEP_DIR/group" "$group"
    fi
    echo "    app data put back"
    rm -rf "$KEEP_DIR"; KEEP_DIR=""
  else
    echo "!! Could not put the app data back: the app isn't installed. It is kept in $KEEP_DIR"
  fi
}

on_signal() {
  echo
  echo "!! Interrupted: stopping xcodebuild"
  [ -n "$XCB_PID" ] && kill -TERM "$XCB_PID" 2>/dev/null && wait "$XCB_PID" 2>/dev/null
  put_app_data_back
  exit 130
}
trap on_signal INT TERM

# --- Phase 1: build --------------------------------------------------------------------------------

# Log-growth watchdog: a build that prints nothing for ~40 s has wedged (case 1). Stop it, clear the
# build service, retry once.
STALL_CHECK_SECONDS=10
STALL_LIMIT=4

build_once() {
  xcodebuild build-for-testing -scheme "$SCHEME" -project "$PROJECT" -destination "$DEST" > "$BUILD_LOG" 2>&1 &
  XCB_PID=$!
  local last=0 stalls=0 now
  while kill -0 "$XCB_PID" 2>/dev/null; do
    sleep "$STALL_CHECK_SECONDS"
    now=$(wc -c < "$BUILD_LOG" 2>/dev/null || echo 0)
    if [ "$now" -eq "$last" ]; then stalls=$((stalls + 1)); else stalls=0; fi
    last=$now
    if [ "$stalls" -ge "$STALL_LIMIT" ]; then
      echo "    !! build stalled (no output for $((STALL_LIMIT * STALL_CHECK_SECONDS)) s): stopping it and clearing the build service"
      kill -TERM "$XCB_PID" 2>/dev/null; wait "$XCB_PID" 2>/dev/null; XCB_PID=""
      killall SWBBuildService XCBBuildService 2>/dev/null
      sleep 2
      return 99
    fi
  done
  wait "$XCB_PID"; local status=$?; XCB_PID=""
  return $status
}

echo "==> Building for testing"
build_once; STATUS=$?
if [ "$STATUS" -eq 99 ]; then
  echo "==> Retrying the build after the stall"
  build_once; STATUS=$?
fi
if [ "$STATUS" -eq 99 ]; then
  echo "!! The build stalled twice: the build service wedge (case 1 in the header), not your code. Log: $BUILD_LOG"
  exit 4
fi
if [ "$STATUS" -ne 0 ] || ! grep -q "TEST BUILD SUCCEEDED" "$BUILD_LOG"; then
  grep -E "error:" "$BUILD_LOG" | sort -u | head -20
  echo "!! The build failed. Log: $BUILD_LOG"
  exit 3
fi

# The host app's path, to hold the data again if a run stops before the test phase installs it.
APP_PATH=$(perl -e 'alarm shift; exec @ARGV' 60 xcodebuild -showBuildSettings -scheme "$SCHEME" \
    -project "$PROJECT" -destination "$DEST" 2>/dev/null \
  | sed -nE 's/^ *TEST_HOST = (.*\.app)\/.*$/\1/p' | head -1)

# --- A clean host app (case 2) ---------------------------------------------------------------------

reinstall_host() {
  local data group
  if ! data=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null); then
    return 0    # not installed: the test phase installs it fresh
  fi
  KEEP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aerocheck-test-appdata.XXXXXX")
  local ok=1 d
  for d in Documents Library; do
    if [ -d "$data/$d" ]; then ditto "$data/$d" "$KEEP_DIR/$d" || ok=0; fi
  done
  if group=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" "$APP_GROUP" 2>/dev/null) && [ -d "$group" ]; then
    ditto "$group" "$KEEP_DIR/group" || ok=0
  fi
  if [ "$ok" -ne 1 ]; then
    echo "    !! could not copy the app data aside: leaving the app installed"
    rm -rf "$KEEP_DIR"; KEEP_DIR=""
    return 1
  fi
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" && echo "    host app uninstalled (its data is kept aside and put back after the run)"
}

if [ "$KEEP_INSTALL" -eq 0 ]; then
  reinstall_host
fi

# --- Phase 2: test ---------------------------------------------------------------------------------

ARGS=(test-without-building -scheme "$SCHEME" -project "$PROJECT" -destination "$DEST"
      -collect-test-diagnostics never)
if [ -n "$ONLY_TESTING" ]; then
  # -only-testing wants Target/Class; accept a bare class name and prefix the test target.
  case "$ONLY_TESTING" in
    */*) ARGS+=(-only-testing:"$ONLY_TESTING") ;;
    *)   ARGS+=(-only-testing:"AeroCheckTests/$ONLY_TESTING") ;;
  esac
fi

NOT_STARTED_REASON=""
test_once() {
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  xcodebuild "${ARGS[@]}" > "$LOG" 2>&1 &
  XCB_PID=$!
  local waited=0 host injected
  while kill -0 "$XCB_PID" 2>/dev/null; do
    sleep 5; waited=$((waited + 5))
    # Once a test case has started, the run is past both failures: let it finish.
    if grep -q "Test Case '" "$LOG" 2>/dev/null; then
      wait "$XCB_PID"; local status=$?; XCB_PID=""
      return $status
    fi
    if [ "$waited" -ge "$START_TIMEOUT" ]; then
      host=$(pgrep -f "Devices/$UDID/.*AeroCheck\.app/AeroCheck" | head -1)
      if [ -n "$host" ]; then
        injected=no
        ps eww -p "$host" 2>/dev/null | grep -q "XCTestBundleInject" && injected=yes
        NOT_STARTED_REASON="no test case started ${START_TIMEOUT} s after the test phase began (host app pid $host, XCTest injected: $injected)"
      else
        NOT_STARTED_REASON="no test case started ${START_TIMEOUT} s after the test phase began (no host app running)"
      fi
      kill -TERM "$XCB_PID" 2>/dev/null; wait "$XCB_PID" 2>/dev/null; XCB_PID=""
      return 98
    fi
  done
  wait "$XCB_PID"; local status=$?; XCB_PID=""
  # Ended before any test case: the launch itself failed ("did not return a process handle", …).
  if [ "$status" -ne 0 ] && ! grep -q "Test Case '" "$LOG"; then
    NOT_STARTED_REASON="the test phase ended before any test case: $(grep -A2 'Testing failed:' "$LOG" | sed -n 2p | tr -s ' \t' ' ' | cut -c1-220)"
    return 98
  fi
  return $status
}

echo "==> Testing on ${NAME:-$DEVICE}${ONLY_TESTING:+ (only: $ONLY_TESTING)}"
test_once; STATUS=$?
if [ "$STATUS" -eq 98 ] && [ "$KEEP_INSTALL" -eq 1 ]; then
  # The known fix for case 2 is a fresh install: try it once.
  echo "    !! $NOT_STARTED_REASON"
  echo "==> Reinstalling the host app and retrying once"
  reinstall_host
  test_once; STATUS=$?
fi

put_app_data_back

if [ "$STATUS" -eq 98 ]; then
  echo
  echo "!! Tests never started: $NOT_STARTED_REASON."
  echo "   \"XCTest injected: no\" is case 2 in this script's header. Log: $LOG"
  exit 5
fi

echo
grep -E ": error: -\[" "$LOG" | sort -u | head -20
grep -E "Executed [0-9]+ tests, with" "$LOG" | tail -1
grep -E "TEST EXECUTE (SUCCEEDED|FAILED)" "$LOG" | tail -1
echo
echo "Full log: $LOG"
[ "$STATUS" -eq 0 ] && exit 0 || exit 1
