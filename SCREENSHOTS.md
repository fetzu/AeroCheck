# Screenshots — how the website and App Store images are made

Every image under `public/assets/screenshot/v5/` is a real capture of the app in a deterministic
state, taken from the iOS Simulator. Nothing is mocked in Figma; when the app changes, the shots are
recaptured. This is the recipe. It takes about twenty minutes for a full set.

## The idea

The app has a **DEBUG-only scene injector** (`AeroCheck/Services/MarketingLocationProvider.swift`,
`MarketingScene` + `MarketingSceneInjector`). Launch the app with the environment variable
`AEROCHECK_SCENE=<key>` and, about five seconds later, it has driven itself into that scene — a
followed flight prepared to 10/12, the HUD in cruise, a nav plan armed. It is compiled out of Release
builds entirely, so it can never ship.

Website copy refers to screenshots by **shot key** (`src/lib/shots.ts`). The scene keys below are
the injector's; the script names files after the shot key, which for the 5.0 scenes is the same word.

| Shot key | Scene key | What it shows | Gesture after inject |
|---|---|---|---|
| `flight` | `flight` | A followed flight LSZQ → LFSB on the next 1 August, 10/12 prepared, opened on its own screen | none |
| `prepare` | `prepare` | The same flight, scrolled to PREPARE (customs / border pack row visible) | swipe up once |
| `closeout` | `closeout` | Vol d'Alpes (a real flight) in CLOSE, the red close-your-flight-plan card at the top | none |
| `homeflight` | `homeflight` | Home with today's flight as the hero, aircraft in the strip | none |
| `hudhero` / `hud` | `cruise` | Cruise, fuel-quantity step, instrument strip lit | none (both names, same full screen) |
| `nav` | `nav` | LSZQ→LSGC→LSGN→LSZB armed, bottom bar expanded | tap the bar's centre handle to expand; Track Vector + Flight Planning must be ON in Settings |
| `airspace` | `conflicts` | Geneva → Samedan, the full airspace-conflict list | open the route, then the conflicts list |
| `planning` | `plan` | Map-first builder, Jura → Engadin, route profile | expand the profile (chevron) |
| `log` | `flightlog` | Flight detail of Vol d'Alpes, track + altitude profile | set the year filter to All time, tap Vol d'Alpes |

Two rules that are not negotiable:

- **iPad is captured in LANDSCAPE, iPhone in PORTRAIT.** The site's device frames depend on it.
- **Scene keys and shot keys are not always the same word.** They match for the 5.0 scenes and differ
  for the older ones (`cruise`→`hud`, `conflicts`→`airspace`, `plan`→`planning`, `flightlog`→`log`).
  The script maps them, so pass the SCENE key and it writes the SHOT filename; `hud-hero.jpg` is
  copied from the same iPad capture.
- **Every scene clears all flight threads first, and turns circuit mode ON.** Both are deliberate: a
  single leftover thread scheduled today takes over Home's hero, which silently turns the `home` and
  `conflicts` shots into a flight card instead of what they are meant to show; and CIRCUITS is gated
  behind a setting, so with it off the button simply is not in the picture.
- **The scene launch bypasses the safety gate and onboarding.** A scene key means "show me the app",
  so the injector accepts both on launch. A fresh simulator container therefore needs no tapping.
- **The demo flight is dated 1 August** (computed as the *next* 1 August at inject time, so it is
  never in the past) and prepared to **10 of 12** — a readiness ring must never show a count that
  reads as a date. 9/11 was caught on a hero shot once. Adding a task to Plan or Prepare moves the
  denominator, so re-check the ring in the captured image every time, not just the tick set.

## 1 · Build the app

From a checkout of the app repo on the branch that carries the scenes you need (the 5.0 scenes are
on `feat/marketing-scenes-v5` until merged):

```bash
cp ../AeroCheck/Secrets.xcconfig .   # gitignored; only needed for OpenAIP layers in nav shots
xcodebuild -scheme "AéroCheck" \
  -destination "platform=iOS Simulator,name=iPad Air 11-inch (M4)" \
  -derivedDataPath /tmp/ac_dd build
```

The universal `.app` is at `/tmp/ac_dd/Build/Products/Debug-iphonesimulator/AeroCheck.app` — install
the same file on both simulators. Simulators used: **iPad Air 11-inch (M4)** and **iPhone 17**
(`xcrun simctl list devices available` — names go stale between Xcode releases).

## 2 · Capture

```bash
# iPad — rotate the simulator to landscape FIRST (Device ▸ Rotate Left with Simulator frontmost, or
# the ⌘← shortcut). The first run tells you which rotation is upright; use it for the rest.
scripts/capture-screenshots.sh --app /tmp/ac_dd/Build/Products/Debug-iphonesimulator/AeroCheck.app \
  --device "iPad Air 11-inch (M4)" --scenes flight,homeflight --rotate 90

# The one scene with a gesture: --pause stops before each screenshot.
scripts/capture-screenshots.sh --app … --device "iPad Air 11-inch (M4)" --scenes prepare --rotate 90 --pause

# iPhone — portrait, no rotation.
scripts/capture-screenshots.sh --app … --device "iPhone 17" --scenes flight,closeout,homeflight
scripts/capture-screenshots.sh --app … --device "iPhone 17" --scenes prepare --pause
```

What the script does per scene: terminate → launch with `SIMCTL_CHILD_AEROCHECK_SCENE=<key>` (the
`SIMCTL_CHILD_` prefix is how simctl passes an environment variable into the app) → wait → optional
pause → `simctl io screenshot` → rotate (iPad) → JPEG at ≤1600 px (iPad) / ≤800 px wide (iPhone),
quality 90 → `public/assets/screenshot/v5/{ipad,iphone}/<key>.jpg`.

Things that bite:

- `simctl io screenshot` **always writes the portrait framebuffer** for iPad, whatever the screen
  shows — hence `--rotate`. Whether 90 or 270 is upright depends on which landscape the simulator is
  in. Check the first shot of a run and keep that value — but **re-check after every reboot**: a
  simulator that shuts down comes back in whatever orientation it feels like, including portrait, and
  a portrait iPad shot is silently wrong rather than obviously upside down.
- **Booting the second simulator shuts the first one down.** Finish one device before starting the
  other, and expect to rotate the iPad back to landscape when you return to it.
- The status-bar override sets **9:41** and full bars; the full-screen Nav map draws its own clock and
  ignores it — accept that.
- A fresh iPhone container has **no airport/airspace data**. Scenes that need it (nav, planning) look
  wrong until you download Switzerland under Settings ▸ Data & Storage, or copy the iPad container's
  `OpenAIPData`/`AirportData` folders across (`xcrun simctl get_app_container <dev> com.fetzu.aerocheck data`).
- The injector **deletes and re-creates** its own demo flights and routes on every run (labels
  `LSZQ → LFSB` and `LSGS → LSZQ`), so repeated runs do not pile duplicates into Upcoming or Saved
  routes. It never touches flights or routes it did not create.
- `homeflight` schedules the flight for **today 14:00**, which is what makes it Home's hero; `flight`
  and `prepare` use the next 1 August. Both are the same route.

## 3 · Wire and verify

1. Open `src/lib/shots.ts`. Every key you just captured: delete it from `PLACEHOLDERS`, and point its
   `SHOTS` entry at the new file (the 5.0 entries already do; only the set membership changes).
2. `npm run build` — it must print **no** `[shots] PLACEHOLDER` warning. A warning means a key is still
   pointing at a stand-in image; the site must not ship like that.
3. `npm run dev`, open `/` and `/fr/`, toggle iPad ↔ iPhone, check every row and the hero cycle.
4. Commit with the `website:` prefix. Pushing `website` deploys.

## App Store

**Different simulators.** App Store Connect matches screenshot dimensions EXACTLY against a device
size class and rejects anything else with "The dimensions of one or more screenshots are wrong". The
devices the website uses are not accepted sizes:

| Purpose | Device | Output |
|---|---|---|
| Website | iPad Air 11-inch (M4) | 2360 × 1640 — **not** an App Store size |
| Website | iPhone 17 | 1206 × 2622 — **not** an App Store size |
| App Store | iPad Pro 13-inch (M5) | 2752 × 2064 landscape (2064 × 2752 portrait) |
| App Store | iPhone 17 Pro Max (6.9") | 1320 × 2868 |

Pass `--native` to write full-resolution PNGs instead of downscaled JPEGs, and `--out` somewhere
outside `public/` so the website's own images are not overwritten:

```bash
scripts/capture-screenshots.sh --app … --device "iPhone 17 Pro Max" \
  --scenes flight,closeout,homeflight,cruise --native --out /tmp/appstore
scripts/capture-screenshots.sh --app … --device "iPad Pro 13-inch (M5)" \
  --scenes homeflight,flight,closeout,cruise --rotate 270 --native --out /tmp/appstore
```

Then drive `prepare` and `nav` by hand on each device, as above. Order for both, first three visible
without scrolling: **flight · hud · nav · closeout · prepare · homeflight**, then `planning` and
`log` as optional 7 and 8. Re-check the accepted sizes when you open the version; Apple has changed
them before.

**A fresh simulator has no aeronautical data**, which shows as a red "No data" chip on Home and an
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
