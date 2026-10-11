# Screenshots — how the website and App Store images are made

Every image under `public/assets/screenshot/v6/` is a real capture of the app in a deterministic
state, taken from the iOS Simulator. Nothing is mocked in Figma; when the app changes, the shots are
recaptured. This is the recipe. It takes about an hour for a full set, the gestures included.

## When to recapture

- **At every release that changes a screen the site shows.** Before tagging (or right after), compare
  the release's changes with the table below; the Cockpit (`cockpit`, `cockpitmap`, `vspeeds`,
  `landscape`) changes most. The 6.2.0 Cockpit, for instance, changed every in-flight shot.
- `CAPTURED_FROM` in `src/lib/shots.ts` names the app version the set was captured from. A build warns
  (`[shots] The screenshots were captured from …`) once the latest GitHub release is a newer minor
  version. Recapture what changed, then set it to the new version, even when only some shots changed.
- Capture from the release's tag, never from a branch: the site shows what users install.
- Recapture both devices, and check the iPhone as closely as the iPad: its Cockpit differs (one-line
  words-only buttons since 6.2.0, LEGS | RADIO on ROUTE), and the site shows it in front of the iPad.

## The idea

The app has a **DEBUG-only scene injector** (`AeroCheck/Services/MarketingLocationProvider.swift`,
`MarketingScene` + `MarketingSceneInjector`). Launch the app with the environment variable
`AEROCHECK_SCENE=<key>` and, a few seconds later, it has driven itself into that scene — a followed
flight prepared to 10/12, the Cockpit in cruise, a route on the map. It is compiled out of Release
builds entirely, so it can never ship.

Website copy refers to screenshots by **shot key** (`src/lib/shots.ts`). The script maps scene keys to
shot keys; `--as` names a shot that shares a scene with another.

| Shot key | Scene key | What it shows | After the scene |
|---|---|---|---|
| `cockpit` | `cruiseroute` | The Cockpit in cruise with a route (LSGC NEXT), Fuel quantity framed (4/5), the strip lit | none; iPhone: a slow drag on the list so its first row shows whole (a short drag is a tap, and ticks an item) |
| `cockpitmap` | `cruisemap` | The Cockpit on its map: LSGC next, the aircraft on the LSZQ → LSGC leg | none |
| `vspeeds` | `cruiseroute` | V-SPEEDS open over the Cockpit (the table on iPad, the list on iPhone) | tap V-SPEEDS on the iPad, GS on the iPhone (`--as vspeeds --pause`) |
| `today` | `homeflight` | Today, with today's flight at 14:00 as the next flight | none |
| `flight` | `flight` | A followed flight LSZQ → LFSB on the next 1 August, 10/12, on its own page | none |
| `prepare` | `prepare` | The same flight, the PREPARE chapter unfolded (border crossings, ATC flight plan) | tap "6 done"; on iPhone scroll so the tasks fill the screen |
| `closeout` | `closeout` | Vol d'Alpes (a real flight) in CLOSE, the red close-your-ATC-flight-plan card | none |
| `route` | `conflicts` | The route editor: Geneva → Samedan over the ICAO chart, the profile, the leg table, the conflicts count | tap Today's ROUTE strip, then the route; close the "Airspace data missing" banner with its ×; needs airspace data (below) |
| `log` | `flightlog` | Vol d'Alpes in the logbook: track, altitude profile | Logbook tab, tap Vol d'Alpes |
| `landscape` | `cruisemap` | The iPhone on its side: the Cockpit's column, the map at full height | iPhone only: `--orientation landscapeLeft --as landscape` |
| `circuits` | `nav` | Plan › Map close in on LSZQ: its traffic circuit at 2900 ft, the W and E arrival sectors, runway 07/25 | Plan › Map; Map sheet: National map, Airspace off, Traffic circuits and Arrival & departure routes on; the magnifying glass, "LSZQ"; close the airport callout; iPad: tap "2900 ft" for its callout and pan it clear of the controls (`--as circuits --pause`) |

The rules that are not negotiable:

- **Both devices in PORTRAIT.** The Cockpit is built for an iPad in portrait on a kneeboard, and the
  site shows the iPad with the iPhone in front of it. The one exception is `landscape`, the phone on
  its side.
- **Use a simulator kept for captures.** Every scene cancels a running flight, clears all flight
  threads, turns circuit mode on, and the map scene turns the OpenAIP layers off. Those are the
  right conditions for a picture and the wrong thing to do to a simulator you use.
- **"Flight Restored" over the in-flight shots.** The script launches each scene twice; the second
  launch restores the flight the first one started, and its alert can cover the Cockpit (it did on
  most 6.2.0 in-flight shots). Close it (iPad about (410, 642) pt, iPhone about (201, 496)) and take
  the screenshot again, with the script's `sips` settings.
- **The scene launch bypasses the safety gate and onboarding.** A fresh container needs no tapping.
- **The VFR procedures need the server's current files**: a capture simulator's open flightmaps
  data from before 7 Oct 2026 has no sector letters, so the `circuits` shot shows no W and E badges.
  Refresh it in Settings › Data & Storage › VFR procedures › Refresh.
- **The demo flight is dated 1 August** (the *next* 1 August at inject time, so never in the past) and
  prepared to **10 of 12** — a readiness ring must never show a count that reads as a date. Adding a
  task to Plan or Prepare moves the denominator, so check the ring in every captured image.
- **Check each image before you keep it**: GPS green (a scene's simulated fix records, as a real one
  does; red means an old build), no "Flight Restored" or permission alert over the screen (dismiss it
  and capture again), the aircraft and its track vector pointing the same way on the map.

## 1 · Build the app

From a checkout of the app repo's `main` (the 6.0 scenes, `cruisemap` and the capture fixes, are
merged), in a worktree of its own so your working copy is left alone:

```bash
cp ../AeroCheck/Secrets.xcconfig .   # gitignored; needed for the airspace download (route shot)
xcodebuild -scheme "AéroCheck" -destination "generic/platform=iOS Simulator" \
  -derivedDataPath /tmp/ac_dd build
```

The universal `.app` is at `/tmp/ac_dd/Build/Products/Debug-iphonesimulator/AeroCheck.app` — install
the same file on both simulators: an **iPad Air 11-inch (M4)** and an **iPhone 17**, each a copy kept
for captures (`xcrun simctl create "Capture iPad" <iPad Air 11-inch (M4) type> <runtime>`). Give them
names of their own: `--device` with a stock name like "iPad Air 11-inch (M4)" picks whichever
simulator has it, which may be the one you use every day. A name containing "iPad" is captured as an
iPad. Don't build with `CODE_SIGNING_ALLOWED=NO`: without entitlements CloudKit throws and the app
quits at launch.

## 2 · Capture

```bash
APP=/tmp/ac_dd/Build/Products/Debug-iphonesimulator/AeroCheck.app
# Each device: the scenes without a gesture, then the ones with one (--pause stops before each shot).
scripts/capture-screenshots.sh --app $APP --device "Capture iPad" \
  --scenes cruiseroute,cruisemap,homeflight,flight,closeout
scripts/capture-screenshots.sh --app $APP --device "Capture iPad" --scenes cruiseroute --as vspeeds --pause
scripts/capture-screenshots.sh --app $APP --device "Capture iPad" --scenes nav --as circuits --pause
scripts/capture-screenshots.sh --app $APP --device "Capture iPad" --scenes prepare,conflicts,flightlog --pause

scripts/capture-screenshots.sh --app $APP --device "Capture iPhone" \
  --scenes cruiseroute,cruisemap,homeflight,flight,closeout
scripts/capture-screenshots.sh --app $APP --device "Capture iPhone" --scenes cruiseroute --as vspeeds --pause
scripts/capture-screenshots.sh --app $APP --device "Capture iPhone" --scenes nav --as circuits --pause
scripts/capture-screenshots.sh --app $APP --device "Capture iPhone" --scenes prepare,conflicts,flightlog --pause
scripts/capture-screenshots.sh --app $APP --device "Capture iPhone" --scenes cruisemap \
  --orientation landscapeLeft --as landscape
```

What the script does per scene: launch with `SIMCTL_CHILD_AEROCHECK_SCENE=<key>` (twice: the first
launch after an install can skip its scene) → wait → optional pause → `simctl io screenshot
--mask=ignored` → JPEG, the iPad at 1112 × 1600, the iPhone 800 px wide (1600 on its side), quality 86
→ `public/assets/screenshot/v6/{ipad,iphone}/<key>.jpg`.

Things that bite:

- **The iPhone's orientation comes from the app, not the simulator.** `AEROCHECK_ORIENTATION` turns
  the app's window for real (DEBUG hook), whichever way the simulator is held, so nothing needs
  rotating by hand. An iPad refuses it: keep the iPad simulator in portrait.
- **Without `--mask=ignored`**, a landscape capture can come out with the Dynamic Island drawn in.
- **The status bar override** sets 9:41 and full bars. The app's own clocks (flight time, ETA) use the
  real time: capture in the daytime, or the map's ETA reads 0:50.
- **A fresh container has no aeronautical data.** Airport data (NOW / NEXT frequencies) and airspace
  (the route editor's conflicts) come from Settings ▸ Data & Storage, or the route editor's "Download
  data" banner, or are copied from a container that has them: terminate the app, then copy
  `Library/Application Support/OpenAIPData/` between the two `xcrun simctl get_app_container <udid>
  com.fetzu.aerocheck data` folders. Airspace alone gives the route shot its conflicts (18 on Geneva →
  Samedan); the banner may keep offering the other layers, so dismiss it with its × before the shot.
  The in-flight map shots want no OpenAIP layers; the `cruisemap` scene turns them off.
- **`--pause` needs a terminal**: it waits for Return. Driven from a script or an agent, launch the
  scene the same way (twice, 12 s each), do the gesture with the simulator tools, then take and convert
  the screenshot with the same `simctl io … --mask=ignored` and `sips` settings as the script.
- The injector **deletes and re-creates** its own demo flights and routes on every run, so repeated
  runs do not pile duplicates into Upcoming or Routes. It never touches flights or routes it did not
  create.

## 3 · Wire and verify

1. Every key in `src/lib/shots.ts` points at `v6/<device>/<key>.jpg`; a new key needs an entry there
   (and, until captured, a place in `PLACEHOLDERS`).
2. Set `CAPTURED_FROM` in `src/lib/shots.ts` to the app version you captured from.
3. `npm run build` — it must print **no** `[shots]` warning (no PLACEHOLDER, no "captured from").
4. `npm run dev`, open `/` and `/fr/`, check the hero cycle and every row, at desktop and phone width.
5. Commit with the `website:` prefix. Pushing `website` deploys.
6. After the deploy (about a minute), `scripts/check-live-screenshots.sh`: every image served as in
   the checkout.

The page asks for each image with a hash of its contents (`/assets/…/cockpit.jpg?v=1a2b3c4d`, from
`src/lib/shots.ts` at build time), so a recaptured image is a new URL and nobody keeps an old one.
Until 6.2.0 the URLs never changed and Cloudflare let browsers keep an image for 4 hours: the day the
6.2.0 set went live, a visitor who had seen the page that morning still saw the 6.0 iPhone. Keep the
file names; the hash does the rest.

## App Store

**Different simulators.** App Store Connect matches screenshot dimensions EXACTLY against a device
size class and rejects anything else with "The dimensions of one or more screenshots are wrong". The
devices the website uses are not accepted sizes:

| Purpose | Device | Output |
|---|---|---|
| Website | iPad Air 11-inch (M4) | 1640 × 2360 portrait — **not** an App Store size |
| Website | iPhone 17 | 1206 × 2622 — **not** an App Store size |
| App Store | iPad Pro 13-inch (M5) | 2752 × 2064 landscape (2064 × 2752 portrait) |
| App Store | iPhone 14 Plus (6.5") | 1284 × 2778 |
| App Store | iPhone 17 Pro Max (6.9") | 1320 × 2868 |

> **Check which iPhone slot App Store Connect is actually asking for before capturing.** There are
> two, and they take different sizes. 6.9" wants 1320 × 2868; 6.5" wants 1242 × 2688 or
> 1284 × 2778. A 6.9" image is rejected by the 6.5" slot and vice versa, with the same unhelpful
> "The dimensions of one or more screenshots are wrong" — the error does list the sizes it wants, so
> read them and match. Do NOT rescale between the two: their aspect ratios differ (0.4603 vs 0.4622)
> and resampling distorts. Capture on a simulator whose native size is the one you need. The 6.5"
> devices are old enough that one may not exist yet:
> `xcrun simctl create "AeroCheck 6.5in" com.apple.CoreSimulator.SimDeviceType.iPhone-14-Plus <runtime>`.

Pass `--native` to write full-resolution PNGs instead of downscaled JPEGs, and `--out` somewhere
outside `public/` so the website's own images are not overwritten:

```bash
scripts/capture-screenshots.sh --app … --device "iPhone 17 Pro Max" \
  --scenes flight,closeout,homeflight,cruise --native --out /tmp/appstore
scripts/capture-screenshots.sh --app … --device "iPad Pro 13-inch (M5)" \
  --scenes homeflight,flight,closeout,cruise --rotate 270 --native --out /tmp/appstore
```

Then drive the gesture shots by hand on each device, as above. Re-check the accepted sizes when you
open the version; Apple has changed them before. The website's iPad is in portrait since 6.0; whether
the store's iPad set follows is decided when the listing is updated.

**A fresh simulator has no aeronautical data**, which shows as a red "No data" chip on Today and an
empty map. Downloading it through the app takes minutes; copying it from a simulator that already
has it takes seconds. The five folders are under
`<container>/Library/Application Support/`: `AirportData`, `OpenAIPData`, `OpenAIPNavaidData`,
`OpenAIPObstacleData`, `OpenAIPReportingPointData`. Resolve the container with
`xcrun simctl get_app_container <udid> com.fetzu.aerocheck data` — **and check it is non-empty before
using it in a path**, because it returns nothing for a shut-down device and an unguarded `rm -rf
"$EMPTY/..."` then points at your home directory.

## Adding a scene

1. Add a case to `MarketingScene` with a one-line `detail`, and a launch key in `ContentView`'s DEBUG
   `.task` (the `switch key` block).
2. Implement it in `MarketingSceneInjector`. Reuse the helpers: `makeDemoPlan`, `tick`,
   `importMarketingFlights`, `coordinate(_:airportDataService:)`. Set model state only — a scene that
   needs a gesture documents it in the table above rather than reaching into view state.
3. Add the shot key to `SHOTS` (and, until captured, to `PLACEHOLDERS`).
4. Add a row to the table above. Capture. Remove from `PLACEHOLDERS`.
