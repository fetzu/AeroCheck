#!/usr/bin/env bash
# Capture website / App Store screenshots from the iOS Simulator by hand, one shot at a time, from the manifest.
#
# scripts/shots.json is the one list of the screenshots: each shot's scene (the app's DEBUG scene injector,
# AEROCHECK_SCENE), its launch settings, its gesture, devices, languages and outputs. A release's whole set is one
# unattended run of the screenshot tour (CLAUDE/tools/shots/shots.sh, outside this repo), which also compares every slot
# with the previous set. This script is for a quick look or a single image: launch, wait, screenshot, convert.
#
# Read SCREENSHOTS.md first.
#
# Usage:
#   scripts/capture-screenshots.sh --app <path/to/AeroCheck.app> --device <UDID> --shots cockpit,today [--lang fr]
#       [--native] [--pause] [--wait 12] [--out public/assets/screenshot/v6]
#
#   --device   the simulator's UDID (a name can resolve to someone's own simulator). A simulator whose name contains
#              "iPad" is captured as an iPad: <out>/ipad, else <out>/iphone (<out>/<lang>/… for French and German).
#   --shots    shot keys of the manifest. A shot with a gesture (its "steps") needs --pause: do the gesture by hand,
#              then press Return; without it the script says so and skips the shot.
#   --lang     en (default), fr or de: the app's language at launch (the manifest's launch arguments). For the
#              system's own language too, switch the simulator first (SCREENSHOTS.md).
#   --native   full-resolution PNGs without alpha instead of downscaled JPEGs: App Store Connect accepts exact device
#              sizes only. Use with --out somewhere outside public/.
#   --wait     seconds to let the injector settle (default 12: the first launch after an install can skip its scene, so
#              the script launches every shot twice), plus the shot's own settle from the manifest.
set -euo pipefail

APP=""; DEVICE=""; SHOTS=""; PAUSE=0; WAIT=12; NATIVE=0; OUT="public/assets/screenshot/v6"; LANG_KEY="en"
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --shots) SHOTS="$2"; shift 2 ;;
    --lang) LANG_KEY="$2"; shift 2 ;;
    --pause) PAUSE=1; shift ;;
    --native) NATIVE=1; shift ;;
    --wait) WAIT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$APP" ] && [ -n "$DEVICE" ] && [ -n "$SHOTS" ] || { sed -n '2,25p' "$0"; exit 2; }
[[ "$DEVICE" =~ ^[0-9A-Fa-f-]{36}$ ]] || { echo "--device takes a UDID, not a name" >&2; exit 2; }

MANIFEST="$(cd "$(dirname "$0")" && pwd)/shots.json"
BUNDLE="com.fetzu.aerocheck"
NAME=$(xcrun simctl list devices | grep "($DEVICE)" | head -1 || true)
[ -n "$NAME" ] || { echo "no simulator $DEVICE" >&2; exit 2; }
case "$NAME" in
  *iPad*) KIND="ipad";  MAXW=$(jq -r '.sets.website.ipadLongSide' "$MANIFEST") ;;
  *)      KIND="iphone"; MAXW=$(jq -r '.sets.website.iphoneWidth' "$MANIFEST") ;;
esac
QUALITY=$(jq -r '.sets.website.quality' "$MANIFEST")
DEST_DIR="$OUT/$KIND"; [ "$LANG_KEY" = en ] || DEST_DIR="$OUT/$LANG_KEY/$KIND"
mkdir -p "$DEST_DIR" /tmp/ac_shots

echo "▶ booting $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
echo "▶ installing $APP"
xcrun simctl install "$DEVICE" "$APP"
# Location before launch, so no permission dialog lands in the shot.
xcrun simctl privacy "$DEVICE" grant location-always "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl location "$DEVICE" set 47.3497,7.0278   # LSZQ Bressaucourt
# Clean marketing chrome, cellular ON (a Wi-Fi-only iPad has no GPS → no green fix).
xcrun simctl status_bar "$DEVICE" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularMode active --cellularBars 4 --dataNetwork lte --operatorName " "

read -ra LAUNCH <<< "$(jq -r --arg l "$LANG_KEY" '.languages[$l].launch | join(" ")' "$MANIFEST")"

IFS=',' read -ra LIST <<< "$SHOTS"
for KEY in "${LIST[@]}"; do
  SHOT=$(jq -c --arg k "$KEY" '.shots[] | select(.key == $k)' "$MANIFEST")
  [ -n "$SHOT" ] || { echo "✗ $KEY: not in scripts/shots.json"; continue; }
  STEPS=$(jq -r --arg kind "$KIND" '(.steps // {}) | (.[$kind] // .all // []) | join(", ")' <<< "$SHOT")
  if [ -n "$STEPS" ] && [ "$PAUSE" = 0 ]; then
    echo "✗ $KEY needs a gesture ($STEPS): --pause, or the screenshot tour"; continue
  fi
  ORIENTATION=$(jq -r '.orientation // "portrait"' <<< "$SHOT")
  SETTLE=$(jq -r '.settle // 3' <<< "$SHOT")
  # The launch environment: the manifest's, the shot's scene and its own settings, each as SIMCTL_CHILD_.
  ENV=()
  while IFS='=' read -r k v; do [ -n "$k" ] && ENV+=("SIMCTL_CHILD_$k=$v"); done < <(
    jq -r --argjson shot "$SHOT" --arg kind "$KIND" --arg o "$ORIENTATION" \
      '.environment + (if $shot.scene then {AEROCHECK_SCENE: $shot.scene} else {} end)
       + (if $kind == "iphone" then {AEROCHECK_ORIENTATION: $o} else {} end) + ($shot.env // {})
       | to_entries[] | "\(.key)=\(.value)"' "$MANIFEST")
  echo "▶ $KEY"
  # Twice: the first launch after an install, or after a flight left running, can skip the scene.
  for _ in 1 2; do
    xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
    sleep 1
    env "${ENV[@]}" xcrun simctl launch "$DEVICE" "$BUNDLE" "${LAUNCH[@]}" >/dev/null
    sleep "$WAIT"
  done
  sleep "$SETTLE"
  if [ "$PAUSE" = "1" ]; then
    read -r -p "   do the gesture for '$KEY' (${STEPS:-none}), then press Return… " _
  fi
  RAW="/tmp/ac_shots/${KIND}_${KEY}.png"
  # --mask=ignored: a landscape iPhone capture otherwise comes out with the Dynamic Island in it.
  xcrun simctl io "$DEVICE" screenshot --mask=ignored "$RAW" >/dev/null
  if [ "$NATIVE" = "1" ]; then
    # App Store Connect matches dimensions EXACTLY against the device size class: never resample.
    DEST="$DEST_DIR/$KEY.png"
    magick "$RAW" -alpha off -define png:color-type=2 "$DEST"
  else
    DEST="$DEST_DIR/$KEY.jpg"
    # iPad: cap the long side (1112 × 1600 in portrait); iPhone: cap the WIDTH (800 in portrait, 1600 on its side).
    if [ "$KIND" = "ipad" ]; then
      sips -Z "$MAXW" -s format jpeg -s formatOptions "$QUALITY" "$RAW" --out "$DEST" >/dev/null
    else
      WIDTH="$MAXW"; case "$ORIENTATION" in landscape*) WIDTH=$(jq -r '.sets.website.landscapeWidth' "$MANIFEST") ;; esac
      sips --resampleWidth "$WIDTH" -s format jpeg -s formatOptions "$QUALITY" "$RAW" --out "$DEST" >/dev/null
    fi
  fi
  echo "   → $DEST ($(sips -g pixelWidth -g pixelHeight "$DEST" | awk '/pixel/ {printf "%s ", $2}'))"
done
echo "✓ done. Look at each image (GPS green, no alert over the screen, no location arrow in the status bar), set"
echo "  CAPTURED_FROM in src/lib/shots.ts, run 'npm run build' (no [shots] warning), and after the deploy"
echo "  scripts/check-live-screenshots.sh."
