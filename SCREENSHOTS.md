# Screenshots: how the website and App Store images are made

Every image under `public/assets/screenshot/v6/` and every App Store screenshot is a real capture of the app in a
deterministic state, taken from the iOS Simulator. Nothing is mocked in Figma; when the app changes, the shots are
recaptured. Since 6.6.0 a release's recapture is one unattended run that ends with a report of the slots that changed,
so it is a review of what changed rather than an evening of tapping.

## When to recapture

- **At every release.** Run the screenshot run from the release's tag (below) and read its report: it compares every
  slot with the previous set, so "did this release change a screen the site or the store shows?" is answered by the
  run itself. The Cockpit (`cockpit`, `cockpitmap`, `vspeeds`, `landscape`) changes most.
- `CAPTURED_FROM` in `src/lib/shots.ts` names the app version the set was captured from, or checked against when a
  release changed none of its screens (6.3.0). A build warns (`[shots] The screenshots were captured from …`) once the
  latest GitHub release is a newer minor version. The run's promote step sets it.
- Capture from the release's tag, never from a branch: the site shows what users install.
- Check the iPhone as closely as the iPad: its Cockpit differs (one-line words-only buttons since 6.2.0, LEGS | RADIO on
  ROUTE, a page per block on the flight page since 6.6.0), and the site shows it in front of the iPad.

## The list: `scripts/shots.json`

The manifest is the one list of the screenshots, for both sets: each shot's key and label (the website's `shot(key)`
reads them in `src/lib/shots.ts`), its scene, its launch settings, the gesture that follows the scene, its devices, its
App Store slot, whether the site shows it, how long to let it settle, and the areas the comparison blanks (a running
timer). Its `about` explains the fields. The three simulators cover both sets: the App Store's 13-inch iPad, the
website's iPad Air 11-inch, and an iPhone 17 for both (1206 × 2622 is the App Store's required medium display; the
website takes it at 800 px wide). The App Store's Apple Watch set (since 6.6.0 in the run again; the 6.1 set before)
comes from a Watch Ultra 3 paired with an iPhone 17. English, French and German, each with its own set.

The app side is DEBUG only, compiled out of Release builds:

- **The scenes** (`AeroCheck/Services/MarketingLocationProvider.swift`, `MarketingScene` + `MarketingSceneInjector`):
  launched with `AEROCHECK_SCENE=<key>`, the app drives itself into that state, a followed flight on the next 1 August,
  the Cockpit in cruise, a route on the map. A scene sets model state only.
- **The capture clock**, `AEROCHECK_CLOCK=09:41` (6.4.3): the app's own times agree with the status bar's 9:41.
- **The weather fixture**, `AEROCHECK_WEATHER=fixture` (6.6.0): every weather request answered from files in the app's
  container, never the network, so the weather blocks and the leg times change only when the app's weather code does.
  The files are a made-up fair day with one SIGMET, dated to the capture day by the run. A URL the fixture has no
  answer for is a 404 and a line in the report.
- **The ready signal** (6.6.0): a Darwin notification, `com.fetzu.aerocheck.debug.sceneReady`, once a scene is in or a
  dry run's autopilot holds. The tour waits for it instead of a fixed time.
- **The map settled** (6.6.0): with `AEROCHECK_MAP_SETTLE=1`, `com.fetzu.aerocheck.debug.mapSettled` every half
  second while each chart map in view has kept its camera for 1.5 s with all its tiles. The map shots' `mapSettled`
  step waits for it instead of 15 s.
- **Accessibility identifiers** for what a gesture taps: `cockpit.vspeeds`, `strip.speed` (GS on the iPhone),
  `cockpit.list` and `checklist.currentItem`, `today.route`, `flightPage.block.<kind>`, `logbook.flight`, `tab.<tab>`.
- **The Watch's page** (6.6.0): `AEROCHECK_WATCH_PAGE=0…2` opens the Watch app on the navigation, flight or
  frequencies page. The cruise scenes tell a paired Watch about their flight, as a flight start does.

The gestures are the **screenshot tour**'s, a UI test that drives the installed app by its bundle id and taps by
identifier (the author's decision of 24 Oct 2026, over scene options that would open those states from inside the
views). It lives with the run in `CLAUDE/tools/shots/` (the private AeroCheck-tools repository), not in this repository.

## The rules that are not negotiable

- **Every shot at 9:41.** The status bar says 9:41, so the app's times must too: the capture clock, `09:41`, and
  `09:25` for the dry run, so its first final comes near 9:41. A build before 6.4.3 has no such clock. The exception is
  the Watch: watchOS has no status bar override, so its shots show the time of the capture, and its phone runs on the
  wall clock for a flight time that agrees with it (the 6.1 set read 18:05). The comparison masks those times.
- **Both devices in PORTRAIT.** The Cockpit is built for an iPad in portrait on a kneeboard, and the site shows the iPad
  with the iPhone in front of it. The one exception is `landscape`, the phone on its side (`AEROCHECK_ORIENTATION` turns
  the app's window for real; an iPad refuses it).
- **Fresh simulators only.** Every scene cancels a running flight, clears all flight threads, sets circuit mode, and the
  map scenes change the map's layers: the right conditions for a picture and the wrong thing to do to a simulator
  someone uses. The run makes its own throwaways and deletes them; never run a scene on your own simulator.
- **A clean status bar.** No location arrow (it shows for some seconds after a launch) and no Live Activity in the
  iPhone's island: the run takes the screenshot again until it is clean, and lists any it couldn't clean.
- **The demo flight is dated 1 August** (the *next* 1 August at inject time, so never in the past), and a readiness ring
  must never show a count that reads as a date (9/11 was caught on a hero shot; 10/12 was signed off). Adding a task
  to Plan or Prepare moves the denominator, so read the ring in the report.
- **Read the report before anything is promoted**: GPS green, no alert over the screen, the aircraft and its track
  vector pointing the same way on the map, and every changed region the report boxes.

## The run

From the workspace, once the release is tagged (Debug build of the tag, throwaway simulators, about half an hour with
the Watch, nobody at the Mac):

```bash
CLAUDE/tools/shots/shots.sh run 6.6.0
```

It builds the tag (Debug, with the app's untracked `Secrets.xcconfig`) and the tour. Then a template simulator per
model, booted once until its first boot's work has settled and the app installed: a fresh simulator's first boot loads
the Mac for minutes, and three of them side by side made every shot three to five times slower. Then one round per
language: a clone of each template with the language and region written before it boots, `CLAUDE/tools/sim-seed.sh`
(the aeronautical data snapshot, LSZQ, the 9:41 status bar), the day's weather fixture in the app's container, and the
tour through the manifest's shots, the three devices side by side. Then it converts every capture (below) and compares
each slot with the previous set: the newest `Marketing/AppStore/<version>/screenshots` before this one (for a device
that set lacks, the newest that has it), and this branch's images. The throwaways are deleted at the end, a failure
included (`--keep` keeps them).

The Watch has no tour. After each language's round, a clone of the iPhone's template is paired with a clone of the
Watch's, the phone opens the shots' scene, and the Watch app is opened on each shot's page; the screenshot waits until
the Watch shows the flight (its page dots) and is still. The phone hands the flight over through WatchConnectivity,
which takes some seconds and sometimes never comes: the run opens the scene again then.

The report, `CLAUDE/shots/<version>-<date>/report/index.html`: the slots that changed first, each with the previous
image, the new one and the changes boxed in red, described by where they are on the screen; a contact sheet per set
(`contact-appstore.jpg`, `contact-website.jpg`); the tour's failures and the status bars it couldn't clean. A change is
never a bare pixel count: below the status bar, with the manifest's live areas blanked, the differing pixels are grouped
into regions and each is boxed, so a ring at 10/12 instead of 14/16 shows at once whatever its size (6.5.0 kept two
slots whose real changes were 280 and 494 pixels). The status bar's time is compared on its own, as the bar's date
changes every day: "9:41 AM" for "09:41" (an English simulator in a US region) is a change.

Then, after reading it:

```bash
CLAUDE/tools/shots/shots.sh promote CLAUDE/shots/<version>-<date> --website-worktree <a worktree of this branch>
```

The App Store set goes to `Marketing/AppStore/<version>/screenshots/` (`<x.y>` for a `.0` release), every slot, the
unchanged ones as the previous file, with a README that says which slots are new: only those need replacing in App
Store Connect. On the website only the changed images are replaced, and `CAPTURED_FROM` is set; commit them with the
`website:` prefix (below). Other options: `--app <path.app>` (a build of your own), `--ref <git ref>`, `--languages`,
`--devices`, `--only key1,key2`, `--manifest`, `--previous-appstore`, `--previous-website`.

The conversions, as the sets before were made: the App Store's PNG as captured, its alpha channel removed, JPEG 95
(4:4:4) for anything over 4.8 MB (App Store Connect refuses about 5 MB); the website's JPEG 86 with `sips`, the iPad's
long side at 1600, the iPhone 800 px wide (1600 on its side). English at `v6/{ipad,iphone}/`, French and German at
`v6/fr/…` and `v6/de/…`; `shot(key, lang)` falls back to English for a file a language doesn't have. The story frames
(`v6/story/`) stay English and are not part of the run (below).

## One shot by hand

For a quick look or a single image, `scripts/capture-screenshots.sh` takes shots of the manifest one at a time on a
simulator you name by UDID, from a Debug build:

```bash
cp ../AeroCheck/Secrets.xcconfig .   # in an app worktree: gitignored, for the airspace download and the weather
xcodebuild -scheme "AéroCheck" -destination "generic/platform=iOS Simulator" -derivedDataPath /tmp/ac_dd build
U=$(../CLAUDE/tools/sim-seed.sh new look ipad) && ../CLAUDE/tools/sim-seed.sh "$U" --app /tmp/ac_dd/Build/Products/Debug-iphonesimulator/AeroCheck.app
scripts/capture-screenshots.sh --app /tmp/ac_dd/Build/Products/Debug-iphonesimulator/AeroCheck.app --device "$U" \
  --shots cockpit,today,circuits
```

A shot with a gesture needs `--pause` (it waits for Return while you do it), or the tour. `--lang fr` launches the app in
French; `--native` writes full-size PNGs for the store. It uses live weather: the fixture is the run's. Don't build with
`CODE_SIGNING_ALLOWED=NO`: without entitlements CloudKit throws and the app quits at launch.

## Wire and verify

1. Every key in `scripts/shots.json` with `"website": true` is a `shot(key)` in `src/lib/shots.ts`, at
   `v6/<device>/<key>.jpg`. A new key, until captured, goes in `PLACEHOLDERS`.
2. `npm run build`: it must print **no** `[shots]` warning (no PLACEHOLDER, no "captured from").
3. `npm run dev`, open `/`, `/de/` and `/fr/`, check the hero cycle and every row, at desktop and phone width.
4. Commit with the `website:` prefix. Pushing `website` deploys.
5. After the deploy (about a minute), `scripts/check-live-screenshots.sh`: every image served as in the checkout.

The page asks for each image with a hash of its contents (`/assets/…/cockpit.jpg?v=1a2b3c4d`, from `src/lib/shots.ts`
at build time), so a recaptured image is a new URL and nobody keeps an old one. Until 6.2.0 the URLs never changed and
Cloudflare let browsers keep an image for 4 hours: the day the 6.2.0 set went live, a visitor who had seen the page that
morning still saw the 6.0 iPhone. Keep the file names; the hash does the rest. An unchanged slot keeps its file, so its
URL doesn't change either.

## The story page (/flight)

The eight iPad images under `public/assets/screenshot/v6/story/` (`route`, `prepare`, `lineup`, `automark`, `alps`,
`approach`, `closeout`, `log`, keyed in `STORY` in `src/lib/shots.ts`) come from one real flight, Bressaucourt to Samedan
in F-HVXA on 23 Sep 2026 (its export, `AeroCheck_20260923_1033_F-HVXA.json`), replayed on the Dev Check iPad through
the app's ground replay (`AEROCHECK_REPLAY`, 5×) and flown as a pilot would: the flight planned for today, its tasks
ticked to 10 of 12, every check worked, ENGINE START and the line-up held by the scenario. The scenario lists no
aerodromes, so the replay keeps the simulator's own airport data and the frequencies show (a DEBUG harness change made
for these captures). The logbook frame comes from a second, untouched run at 30×. Captured on 18 Oct 2026 for the
6.4.0 site; the page's times are the Cockpit's flight clock in each frame.

`automark` was recaptured on 22 Oct 2026 from the `6.4.3` tag, for the radio's NOW and NEXT of 6.4.2 and 6.4.3: the
same scenario at 2× (so the six seconds of BENOT's UNDO last three on the wall clock), flown by a temporary UI test on
`CockpitPilot` (every check worked, NEXT tapped each time a call came due, the cruise check left open on CHECKLIST,
shots taken while BENOT's mark offers UNDO). The replay's clock does not take the capture clock (`AEROCHECK_CLOCK`);
a local change, never committed, started it at 09:16 so the frame reads 9:38 under the status bar's 9:41. The other
frames are still the 18 Oct run's, whose longer ground holds put the line-up at 00:18 on the flight clock.

## App Store

**Exact sizes.** App Store Connect matches screenshot dimensions EXACTLY against a device size class and rejects
anything else with "The dimensions of one or more screenshots are wrong" (the error lists the sizes it wants). Two slots
are required, the 13-inch iPad and the iPhone with Dynamic Island (medium display); the others are optional and scaled
from these. As listed on Apple's
[screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
on 18 Oct 2026:

| Purpose | Device | Output |
|---|---|---|
| Website | iPad Air 11-inch (M4) | 1640 × 2360 portrait, not an App Store size |
| Website and App Store, required | iPhone 17 (Dynamic Island, medium display) | 1206 × 2622 (1179 × 2556 also accepted) |
| App Store, required | iPad Pro 13-inch (M4, as the 6.5.0 set; any 13-inch) | 2064 × 2752 portrait |
| App Store, optional | iPhone 17 Pro Max (Dynamic Island, large display, "6.9-inch") | 1320 × 2868 |
| App Store, for the Watch app | Apple Watch Ultra 3 (49 mm) | 422 × 514 |

The 6.1 to 6.4 store sets were captured for the large display (`iphone-6.9`); since 6.5.0 the iPhone set is
`iphone-6.3`. Do NOT rescale between the iPhone classes: their aspect ratios differ (1206 × 2622 is 0.4600,
1320 × 2868 is 0.4603, 1284 × 2778 is 0.4622) and resampling distorts. From April 2027 an app built with the iOS 27.1
SDK or later also needs iPhone Duo screenshots (outer display 1398 × 2034, inner display 2007 × 2853): a device in the
manifest. Check the page again when the version is opened; Apple has changed the slots before. At most 10 per device
and language. The sets as submitted are kept outside the repos, in `Marketing/AppStore/<version>/`.

## Adding a shot

1. If it needs a state of its own: a case in `MarketingScene`, documented on the case, a launch key in `ContentView`'s
   DEBUG `.task` (the `switch key` block), and its injection in `MarketingSceneInjector` (reuse `makeDemoPlan`, `tick`,
   `importMarketingFlights`). Model state only.
2. If it needs a gesture: an accessibility identifier on what it taps, and the steps in the manifest.
3. An entry in `scripts/shots.json`: key, label, scene, steps, `appstore` slot and/or `"website": true`.
4. Until captured, the key in `PLACEHOLDERS`. Run the run (`--only <key>` for a first look), then remove it.
