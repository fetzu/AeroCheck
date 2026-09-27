#!/usr/bin/env bash
# Capture the website / App Store screenshots from the iOS Simulator, one scene at a time.
#
# The app ships a DEBUG-only scene injector: launching it with AEROCHECK_SCENE=<key> drives it into a
# deterministic state (a followed flight, the Cockpit in cruise, …) about 4–5 s after launch. This script
# does the simctl side — boot, install, status bar, launch, wait, screenshot, rotate, convert — and
# names the output after the website's shot key so it drops straight into src/lib/shots.ts.
#
# Read SCREENSHOTS.md first: some shots need a gesture between launch and capture.
#
# Usage:
#   scripts/capture-screenshots.sh --app <path/to/AeroCheck.app> --device "iPad Air 11-inch (M4)" \
#       --scenes cruise,cruisemap,homeflight [--pause] [--wait 12] [--out public/assets/screenshot/v6]
#   scripts/capture-screenshots.sh --app … --device "iPhone 17" --scenes cruisemap \
#       --orientation landscapeLeft --as landscape
#
#   --device       simulator name (a name containing "iPad" is an iPad); iPad output goes to <out>/ipad,
#                  iPhone to <out>/iphone. Since 6.0 both
#                  are captured in PORTRAIT: the Cockpit is flown on an iPad in portrait on a kneeboard.
#   --orientation  iPhone only: portrait (default), landscapeLeft or landscapeRight. The app's DEBUG hook
#                  turns its window for real, whichever way the simulator is held.
#   --as KEY       write the shot under KEY instead of the scene's own shot key (one scene): the same
#                  scene makes `cockpit` and, with a tap on V-SPEEDS, `vspeeds`; `cruisemap` on its side
#                  makes `landscape`.
#   --rotate       App Store iPad in landscape only: simctl writes the portrait framebuffer, so a landscape
#                  capture needs a software rotate, 90 or 270 depending on the way the sim is held.
#   --pause        stop before each screenshot so you can perform the scene's gesture (see SCREENSHOTS.md)
#   --native   write full-resolution PNGs instead of downscaled JPEGs. Use this for App Store
#              Connect, which accepts only exact device sizes and rejects anything else. The
#              WEBSITE wants the downscaled default; the store wants this.
#   --wait         seconds to let the injector settle (default 12: the first launch after an install can
#                  skip its scene, so the script launches every scene twice)
set -euo pipefail

APP=""; DEVICE=""; SCENES=""; ROTATE=""; PAUSE=0; WAIT=12; NATIVE=0; OUT="public/assets/screenshot/v6"
ORIENTATION="portrait"; AS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --scenes) SCENES="$2"; shift 2 ;;
    --rotate) ROTATE="$2"; shift 2 ;;
    --pause) PAUSE=1; shift ;;
    --native) NATIVE=1; shift ;;
    --wait) WAIT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --orientation) ORIENTATION="$2"; shift 2 ;;
    --as) AS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$APP" ] && [ -n "$DEVICE" ] && [ -n "$SCENES" ] || { sed -n '2,25p' "$0"; exit 2; }

BUNDLE="com.fetzu.aerocheck"
# Matched anywhere in the name, so a dedicated capture simulator ("AeroCheck Dev Check iPad") counts.
case "$DEVICE" in
  *iPad*) KIND="ipad";  MAXW=1600 ;;
  *)     KIND="iphone"; MAXW=800 ;;
esac
mkdir -p "$OUT/$KIND" /tmp/ac_shots

echo "▶ booting $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator 2>/dev/null || true   # the window is a convenience; simctl captures without it
xcrun simctl bootstatus "$DEVICE" -b >/dev/null

echo "▶ installing $APP"
xcrun simctl install "$DEVICE" "$APP"
# Location before launch, so no permission dialog lands in the shot.
xcrun simctl privacy "$DEVICE" grant location-always "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl location "$DEVICE" set 47.3497,7.0278   # LSZQ Bressaucourt
# Clean marketing chrome, cellular ON (a Wi-Fi-only iPad has no GPS → no green fix).
xcrun simctl status_bar "$DEVICE" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularMode active --cellularBars 4 --dataNetwork lte --operatorName " "

# The website names images by SHOT key; the injector names states by SCENE key. Map the difference
# here rather than renaming by hand after every run. A scene missing from the map keeps its own name.
shot_key() {
  if [ -n "$AS" ]; then echo "$AS"; return; fi
  case "$1" in
    cruise|cruisehud)          echo "cockpit" ;;
    cruisemap)                 echo "cockpitmap" ;;
    homeflight|homeflighttoday) echo "today" ;;
    conflicts|planconflicts)   echo "route" ;;
    flightlog|flightlogdetail) echo "log" ;;
    *)                         echo "$1" ;;
  esac
}

IFS=',' read -ra LIST <<< "$SCENES"
for SCENE in "${LIST[@]}"; do
  KEY="$(shot_key "$SCENE")"
  echo "▶ scene: $SCENE"
  # Twice: the first launch after an install, or after a flight left running, can skip the scene.
  for _ in 1 2; do
    xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
    sleep 1
    if [ "$KIND" = "iphone" ]; then
      SIMCTL_CHILD_AEROCHECK_ORIENTATION="$ORIENTATION" SIMCTL_CHILD_AEROCHECK_SCENE="$SCENE" \
        xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null
    else
      SIMCTL_CHILD_AEROCHECK_SCENE="$SCENE" xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null
    fi
    sleep "$WAIT"
  done
  if [ "$PAUSE" = "1" ]; then
    read -r -p "   perform the gesture for '$SCENE' (see SCREENSHOTS.md), then press Return… " _
  fi
  RAW="/tmp/ac_shots/${KIND}_${KEY}.png"
  # --mask=ignored: a landscape iPhone capture otherwise comes out with the Dynamic Island in it.
  xcrun simctl io "$DEVICE" screenshot --mask=ignored "$RAW" >/dev/null
  if [ "$KIND" = "ipad" ] && [ -n "$ROTATE" ]; then
    sips -r "$ROTATE" "$RAW" >/dev/null
  fi
  if [ "$NATIVE" = "1" ]; then
    # App Store Connect matches dimensions EXACTLY against the device size class, so this path
    # must not resample. Copy the rotated framebuffer through untouched.
    DEST="$OUT/$KIND/$KEY.png"
    cp "$RAW" "$DEST"
  else
    DEST="$OUT/$KIND/$KEY.jpg"
    # iPad: cap the long side (1112 × 1600 in portrait); iPhone: cap the WIDTH (800 in portrait, 1600
    # on its side). A -Z on a portrait phone would shrink the height, not the width.
    if [ "$KIND" = "ipad" ]; then
      sips -Z "$MAXW" -s format jpeg -s formatOptions 86 "$RAW" --out "$DEST" >/dev/null
    else
      WIDTH="$MAXW"; case "$ORIENTATION" in landscape*) WIDTH=1600 ;; esac
      sips --resampleWidth "$WIDTH" -s format jpeg -s formatOptions 86 "$RAW" --out "$DEST" >/dev/null
    fi
  fi
  echo "   → $DEST ($(sips -g pixelWidth -g pixelHeight "$DEST" | awk '/pixel/ {printf "%s ", $2}'))"
done
echo "✓ done. Now: check each image (the ring at 10/12, GPS green, no alert over the screen), run 'npm run build' and check no [shots] warning remains."
