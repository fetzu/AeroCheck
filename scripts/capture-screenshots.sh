#!/usr/bin/env bash
# Capture the website / App Store screenshots from the iOS Simulator, one scene at a time.
#
# The app ships a DEBUG-only scene injector: launching it with AEROCHECK_SCENE=<key> drives it into a
# deterministic state (a followed flight, the HUD in cruise, …) about 4–5 s after launch. This script
# does the simctl side — boot, install, status bar, launch, wait, screenshot, rotate, convert — and
# names the output after the website's shot key so it drops straight into src/lib/shots.ts.
#
# Read SCREENSHOTS.md first: two scenes need a gesture between launch and capture, and the iPad
# rotation direction has to be eyeballed once per session.
#
# Usage:
#   scripts/capture-screenshots.sh --app <path/to/AeroCheck.app> --device "iPad Air 11-inch (M4)" \
#       --scenes flight,homeflight [--rotate 90|270] [--pause] [--wait 6] [--out public/assets/screenshot/v5]
#
#   --device   simulator name; iPad output goes to <out>/ipad, iPhone to <out>/iphone
#   --rotate   iPad only. simctl always writes the PORTRAIT framebuffer, so a landscape capture needs a
#              software rotate — and the correct value FLIPS with which landscape the sim is in. Run one
#              scene, look at it, then use whichever of 90/270 is upright for the rest of the session.
#   --pause    stop before each screenshot so you can perform the scene's gesture (see SCREENSHOTS.md)
#   --native   write full-resolution PNGs instead of downscaled JPEGs. Use this for App Store
#              Connect, which accepts only exact device sizes and rejects anything else. The
#              WEBSITE wants the downscaled default; the store wants this.
#   --wait     seconds to let the injector settle (default 6; the HUD/nav scenes want 8)
set -euo pipefail

APP=""; DEVICE=""; SCENES=""; ROTATE=""; PAUSE=0; WAIT=6; NATIVE=0; OUT="public/assets/screenshot/v5"
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
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$APP" ] && [ -n "$DEVICE" ] && [ -n "$SCENES" ] || { sed -n '2,25p' "$0"; exit 2; }

BUNDLE="com.fetzu.aerocheck"
case "$DEVICE" in
  iPad*) KIND="ipad";  MAXW=1600 ;;
  *)     KIND="iphone"; MAXW=800 ;;
esac
mkdir -p "$OUT/$KIND" /tmp/ac_shots

echo "▶ booting $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator
xcrun simctl bootstatus "$DEVICE" -b >/dev/null

echo "▶ installing $APP"
xcrun simctl install "$DEVICE" "$APP"
# Location before launch, so no permission dialog lands in the shot.
xcrun simctl privacy "$DEVICE" grant location-always "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl location "$DEVICE" set 47.3497,7.0278   # LSZQ Bressaucourt
# Clean marketing chrome, cellular ON (a Wi-Fi-only iPad has no GPS → no green fix).
xcrun simctl status_bar "$DEVICE" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularMode active --cellularBars 4 --dataNetwork lte --operatorName " "

# The website names images by SHOT key; the injector names states by SCENE key. They match for the
# 5.0 scenes and differ for the older ones, so map the difference here rather than renaming by hand
# after every run. A scene missing from the map keeps its own name.
shot_key() {
  case "$1" in
    cruise|cruisehud)        echo "hud" ;;
    conflicts|planconflicts) echo "airspace" ;;
    plan|planbuilder)        echo "planning" ;;
    flightlog|flightlogdetail) echo "log" ;;
    home2aircraft)           echo "home" ;;
    *)                       echo "$1" ;;
  esac
}

IFS=',' read -ra LIST <<< "$SCENES"
for SCENE in "${LIST[@]}"; do
  KEY="$(shot_key "$SCENE")"
  echo "▶ scene: $SCENE"
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  sleep 1
  SIMCTL_CHILD_AEROCHECK_SCENE="$SCENE" xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null
  sleep "$WAIT"
  if [ "$PAUSE" = "1" ]; then
    read -r -p "   perform the gesture for '$SCENE' (see SCREENSHOTS.md), then press Return… " _
  fi
  RAW="/tmp/ac_shots/${KIND}_${KEY}.png"
  xcrun simctl io "$DEVICE" screenshot "$RAW" >/dev/null
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
    # iPad: cap the long side; iPhone: cap the WIDTH only (a -Z on portrait shrinks the height, not the width).
    if [ "$KIND" = "ipad" ]; then
      sips -Z "$MAXW" -s format jpeg -s formatOptions 90 "$RAW" --out "$DEST" >/dev/null
    else
      sips --resampleWidth "$MAXW" -s format jpeg -s formatOptions 90 "$RAW" --out "$DEST" >/dev/null
    fi
  fi
  # The hero carousel reads `hudhero`, which is the same full HUD screen under another name.
  if [ "$KEY" = "hud" ] && [ "$KIND" = "ipad" ] && [ "$NATIVE" != "1" ]; then cp "$DEST" "$OUT/$KIND/hud-hero.jpg"; fi
  echo "   → $DEST ($(sips -g pixelWidth -g pixelHeight "$DEST" | awk '/pixel/ {printf "%s ", $2}'))"
done
echo "✓ done. Now: remove the captured keys from PLACEHOLDERS in src/lib/shots.ts, run 'npm run build' and check no [shots] warning remains."
