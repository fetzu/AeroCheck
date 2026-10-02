#!/bin/bash
#
# Ground replays: flies the UI tests' scenarios (AeroCheckUITests, scripts/flightsim) on a throwaway
# simulator, and writes what each device-check step came to (pass / fail / observed) with its
# screenshots into an output folder:
#
#   <out>/results.json            one entry per step id, the tests, the run
#   <out>/screenshots/*.png       "<page>-<step id>-<short>.png" (they show checklist text: keep them private)
#   <out>/<test>.xcresult, logs
#
# usage: scripts/ground-replay.sh [--iphone] [--only <Class/testMethod>]... [--out <dir>] [--keep-simulator]
#   --only    a subset, e.g. --only ChecksInFlightUITests/testCrossCountryEveryCheckOnTime (repeatable)
#   --iphone  an iPhone 17 instead of the iPad Air 11-inch (M4); without --only, the phone's own steps
#   --out     default: $TMPDIR/aerocheck-ground-replay/<date-time>
#
# The simulator is created for the run ("AeroCheck Tmp replay-<n> <date>") and deleted after it. Never
# the author's own simulator, never a destination by name.

set -u
cd "$(dirname "$0")/.."
REPO=$(pwd)

ONLY=()
DEVICE_TYPE="iPad Air 11-inch (M4)"
OUT=""
KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --only) ONLY+=("$2"); shift 2 ;;
        --iphone) DEVICE_TYPE="iPhone 17"; shift ;;
        --out) OUT="$2"; shift 2 ;;
        --keep-simulator) KEEP=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done

STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${OUT:-"${TMPDIR:-/tmp}/aerocheck-ground-replay/$STAMP"}
mkdir -p "$OUT/screenshots" "$OUT/logs"
DD="$OUT/DerivedData"

# All of them, in the order of priority, when no --only. On the phone, the steps that are the phone's
# (the kneeboard ones assume the iPad's layout).
if [ ${#ONLY[@]} -eq 0 ] && [ "$DEVICE_TYPE" = "iPhone 17" ]; then
    ONLY=(
        WaypointMarkingUITests/testReportingPointOnThePhone
    )
fi
if [ ${#ONLY[@]} -eq 0 ]; then
    ONLY=(
        ChecksInFlightUITests/testCrossCountryEveryCheckOnTime
        ChecksInFlightUITests/testClimbCheckLeftOpenThenNotSure
        ChecksInFlightUITests/testFredaMissedInCruise
        ChecksInFlightUITests/testDescentAbandoned
        ChecksInFlightUITests/testLandedCardUnanswered
        CircuitsUITests/testCircuitsWithStopAndGo
        FlightTimingUITests/testReadyForLineUpAnchorsTheETOs
        FlightTimingUITests/testPhaseBarJumpLetsTheTakeoffAnchorTheETOs
        WaypointMarkingUITests/testRouteWithReportingPoints
        WaypointMarkingUITests/testCircuitsLeaveTheArmedRouteAlone
        WaypointMarkingUITests/testDivertThenResumeRoute
    )
fi

# The throwaway, on the newest iOS runtime.
RUNTIME=$(xcrun simctl list runtimes available | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS-[0-9-]*' | sort -V | tail -1)
N=1
while xcrun simctl list devices | grep -q "AeroCheck Tmp replay-$N $(date +%Y%m%d)"; do N=$((N + 1)); done
NAME="AeroCheck Tmp replay-$N $(date +%Y%m%d)"
UDID=$(xcrun simctl create "$NAME" "$DEVICE_TYPE" "$RUNTIME") || { echo "could not create a simulator" >&2; exit 1; }
echo "simulator: $NAME ($UDID), $RUNTIME"
cleanup() {
    xcrun simctl shutdown "$UDID" > /dev/null 2>&1
    if [ $KEEP -eq 0 ]; then
        xcrun simctl delete "$UDID" > /dev/null 2>&1 && echo "simulator deleted"
        /bin/rm -rf "$DD"
    fi
}
trap cleanup EXIT
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1

echo "building..."
if ! xcodebuild build-for-testing -scheme AeroCheckUITests -destination "platform=iOS Simulator,id=$UDID" \
        -derivedDataPath "$DD" > "$OUT/logs/build.log" 2>&1; then
    grep -E "error:" "$OUT/logs/build.log" | sort -u | head -20
    echo "build failed: $OUT/logs/build.log" >&2
    exit 1
fi
APP=$(find "$DD/Build/Products" -maxdepth 2 -name AeroCheck.app -path "*iphonesimulator*" | head -1)

for TEST in "${ONLY[@]}"; do
    TAG=$(echo "$TEST" | tr '/' '-')
    echo "flying $TEST..."
    # A clean install each time, location always allowed: no prompt over the Cockpit, and none of the
    # "launch did not return a process handle" a reused install can bring.
    xcrun simctl uninstall "$UDID" com.fetzu.aerocheck > /dev/null 2>&1
    xcrun simctl install "$UDID" "$APP"
    xcrun simctl privacy "$UDID" grant location-always com.fetzu.aerocheck > /dev/null 2>&1
    xcodebuild test-without-building -scheme AeroCheckUITests -destination "platform=iOS Simulator,id=$UDID" \
        -derivedDataPath "$DD" -collect-test-diagnostics never -resultBundlePath "$OUT/$TAG.xcresult" \
        -only-testing:"AeroCheckUITests/$TEST" > "$OUT/logs/$TAG.log" 2>&1
    echo "  $(grep -E "Test Case .*(passed|failed)" "$OUT/logs/$TAG.log" | tail -1 | sed -E 's/.*(passed|failed)/\1/')"
    mkdir -p "$OUT/attachments/$TAG"
    xcrun xcresulttool export attachments --path "$OUT/$TAG.xcresult" --output-path "$OUT/attachments/$TAG" > /dev/null 2>&1
done

# results.json: the steps of every test, merged by id (a step flown in several tests is as good as its
# weakest: fail, then observed, then pass), the screenshots under their step names.
python3 - "$OUT" "$NAME" "$UDID" "$(git rev-parse --short HEAD)" "$(xcodebuild -version | head -1)" <<'PY'
import json, os, shutil, sys, glob
out, name, udid, commit, xcode = sys.argv[1:6]
rank = {'fail': 0, 'observed': 1, 'pass': 2}
steps, tests = {}, []
for d in sorted(glob.glob(os.path.join(out, 'attachments', '*'))):
    manifest = os.path.join(d, 'manifest.json')
    if not os.path.exists(manifest):
        continue
    for entry in json.load(open(manifest)):
        for a in entry['attachments']:
            label = a['suggestedHumanReadableName'].rsplit('_0_', 1)[0]
            ext = os.path.splitext(a['exportedFileName'])[1]
            src = os.path.join(d, a['exportedFileName'])
            if ext == '.png' and label[:3].isdigit():
                shutil.copy(src, os.path.join(out, 'screenshots', label + ext))
            if ext == '.json' and label.startswith('steps-'):
                run = json.load(open(src))
                tests.append(dict(test=run['test'], scenario=run['scenario'], page=run['page'],
                                  harness=run.get('harness', [])))
                for st in run['steps']:
                    merged = steps.setdefault(st['id'], dict(status=st['status'], notes=[], screenshots=[], tests=[]))
                    if rank[st['status']] < rank[merged['status']]:
                        merged['status'] = st['status']
                    merged['notes'] += [f"[{run['scenario']}] {n}" for n in st['notes']]
                    merged['screenshots'] += [f"screenshots/{s}.png" for s in st['screenshots']]
                    merged['tests'].append(run['test'])
for log in sorted(glob.glob(os.path.join(out, 'logs', '*.log'))):
    for line in open(log, errors='replace').read().splitlines():
        if line.startswith("Test Case '-[") and (' passed (' in line or ' failed (' in line):
            name_ = line.split("'")[1].replace('[AeroCheckUITests.', '[')
            for t in tests:
                if t['test'] == name_:
                    t['result'] = 'passed' if ' passed (' in line else 'failed'
                    t['duration'] = line.rsplit('(', 1)[1].split(' ')[0]
counts = {k: sum(1 for s in steps.values() if s['status'] == k) for k in rank}
result = dict(run=dict(simulator=name, udid=udid, commit=commit, xcode=xcode), summary=counts,
              tests=tests, steps=dict(sorted(steps.items())))
json.dump(result, open(os.path.join(out, 'results.json'), 'w'), indent=1, ensure_ascii=False)
print(f"steps: {counts['pass']} pass, {counts['fail']} fail, {counts['observed']} observed")
for sid, s in sorted(steps.items()):
    print(f"  {sid:12} {s['status']}")
PY
echo "results: $OUT/results.json"
