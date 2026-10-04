# CLAUDE.md - AeroCheck app

The iPad-first iOS app (Swift/SwiftUI, plus a widget and a Watch app). Read the ecosystem file first, `../CLAUDE.md` (outside this repo): layout, branches and deploys, the iOS 17 target, Watch ≠ Companion, the roster, the cross-repo order, the release checklist, the terms. This one has what the code here won't tell you; README.md is for humans.

## Rules

- Stage files by name, never `git add -A` or `git add .`: a build rewrites `AeroCheck/Localizable.xcstrings` (reformatted, sometimes keys pruned). Restore it (`git checkout <ref> -- AeroCheck/Localizable.xcstrings`) unless you meant to change it, and check that `git show --numstat HEAD` lists only your files.
- No secret in tracked source, and never print one (see Secrets).
- iOS 17.0 floor (watchOS 10.0) on a newer SDK: gate every newer API (`@available`, `if #available`), keep a 17.0 path, never raise the floor.
- A `#if DEBUG` symbol is used only from `#if DEBUG` code: Debug and both test schemes define DEBUG, the Release archive Xcode Cloud builds doesn't, so a leak passes every local check and breaks the upload. After touching DEBUG-only code: `xcodebuild build -scheme "AéroCheck" -configuration Release -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO`.
- Log through `AppLog` (`Shared/AppLog.swift`), never `print()`. `debugLine` is private; `publicLine` only for text with no identifier, coordinate, credential or user content (SA-20).
- A new field in a persisted model (`AppSettings`, `Flight`, `FlightPlan`, `FlightThread`, `Trip` and their nested structs) is Optional or goes through the hand-written `init(from:)` (`decodeIfPresent … ?? default`): a synthesized non-optional field makes every older file fail to decode, silently.
- Tests build `AppState`, the managers and the data services only through `AeroCheckTests/TestDatastore.swift` (`makeTestDatastore()`, `makeTestAppState(…)`, …): the test host IS the app, so `.shared`, `UserDefaults.standard` and the Keychain are the simulator app's real data.
- Tests are grouped by feature (`<Feature>Tests.swift`), never named after a review or a phase. Commits are conventional (`feat:`, `fix:`, `docs:`, …).

## Build and test

```bash
open AeroCheck.xcodeproj    # run scheme: AéroCheck (with the accent)
```

Schemes: `AéroCheck` (its test action has no testables: a build never compiles the tests), `AeroCheckTests`, `AeroCheckUITests` (ground replays). Xcode 26 or later, since the Companion files `import WiFiAware` unconditionally.

- Never use the author's simulator, `iPad Air 11-inch (M4)` `A7A5FC41-C92E-48EE-9A06-0E833852F3D5`: no installs, no scenes, no tests.
- Target simulators by `id=<UDID>`, never `name=` (`name=iPad Air 11-inch (M4)` is the author's).
- Unit tests run on a throwaway, deleted after the run. Run both steps in the background; stop them with SIGINT/SIGTERM, never `kill -9`.

```bash
UDID=$(xcrun simctl create "AeroCheck Tmp tests" com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4)
xcodebuild build-for-testing -scheme AeroCheckTests -destination "platform=iOS Simulator,id=$UDID"
xcodebuild test-without-building -scheme AeroCheckTests -destination "platform=iOS Simulator,id=$UDID" \
  -collect-test-diagnostics never          # one class: -only-testing:AeroCheckTests/ObstacleTests
xcrun simctl shutdown "$UDID"; xcrun simctl delete "$UDID"
```

- Without `-collect-test-diagnostics never`, a failure makes xcodebuild collect a sysdiagnose for minutes after "Executed N tests", which looks like a hang.
- Run the changed test classes first; read a crash before running again, never loop (each test-host crash pops a report on the author's screen).
- `scripts/run-tests.sh [simulator] [TestClass] [--keep-install]` wraps the same steps with watchdogs and a clean reinstall of the host app. Two catches: without a simulator it targets the author's by name, and its preflight runs `killall SWBBuildService XCBBuildService` unconditionally, breaking every other build on the Mac. Only with a throwaway's UDID and nothing else building.
- A run that stops before "Testing started" has a wedged build service (`xcodebuild` waits in `waitForBuildWithBuildLog:`): sample `xcodebuild`, not the app, then `killall SWBBuildService XCBBuildService` once nothing else builds. "Testing started", no test case, then "The test runner hung before establishing connection": the host app launched without XCTest; `xcrun simctl uninstall <UDID> com.fetzu.aerocheck` fixes it, a reboot doesn't.

Ground replays (in-flight behaviour is tested on the ground, never in flight): `scripts/ground-replay.sh [--only ChecksInFlightUITests/testCrossCountryEveryCheckOnTime] [--iphone]` runs `AeroCheckUITests` on a throwaway and writes `results.json` (pass, fail or observed per device-check step) and screenshots to `$TMPDIR/aerocheck-ground-replay/<date>`. The screenshots show checklist text: never attach them to anything public.
- The DEBUG harness (`Services/GroundReplay.swift`, `AEROCHECK_REPLAY=<scenario JSON>`, `AEROCHECK_REPLAY_SPEED` default 10) feeds the track through `LocationManager.feedReplayFix` on a virtual clock: anything a flight times reads `FlightClock.now`, never `Date()`.
- UI tests read accessibility identifiers, never colours or words; read once and tap where seen (`CockpitPilot.snap`, `tapNow`), since at 10× a toast can go between two queries. The page picker's identifiers are still `pane.*`.
- `scripts/flightsim/make_scenario.py` regenerates the scenarios after a change to the detector or the cues (referee: `../CLAUDE/review/flight-events`).

Captures: the DEBUG hooks `AEROCHECK_SCENE` (the marketing scenes, recipe in SCREENSHOTS.md on the `website` branch), `AEROCHECK_PANE`, `AEROCHECK_STATUS` and `AEROCHECK_ORIENTATION=landscape` (which blurs scroll views: an artefact of the hook, not the app). Look at every capture before trusting it.

Also: `AeroCheck/Configuration.storekit` is in no shared scheme, and selecting it edits the tracked `AéroCheck.xcscheme` (don't commit that). Developer Options: tap the version five times in Settings › About. Adding or editing a curated authority link (border pack, thread tasks): run `scripts/check-links.sh` (a 403 is bot blocking, not a dead link). CodeQL (`.github/workflows/codeql.yml`) builds with the `macos-26` image's older Xcode: a long SwiftUI modifier chain can fail to type-check there only, so a red "Analyze Swift" is real. Its `swift/cleartext-transmission` alerts are false positives (`APIConfig.endpoint(forKey:)` takes https or localhost only): dismiss them.

## Project

Classic Xcode groups, not synchronized folders: a new source file needs four `project.pbxproj` entries (PBXBuildFile, PBXFileReference, the group's children, the target's Sources phase) with ids checked unused (`grep -c <id>` gives 0). A colliding id silently drops ANOTHER file from the build, and the errors point at that file.

- `Shared/` (repo root) is compiled into the app and the Watch and/or widget: `AppLog`, `DesignTokens`, the Watch and Companion wire models.
- `WidgetBridge` publishes the owned aircraft to the widget through the App Group `group.com.fetzu.aerocheck`; the widget launches through `FlightLauncher`.
- The WT9 exists three times. The checklists repo's F-HVXA files are the source of truth (the API serves them). `Resources/wt9-dynamic-bundled(-fr).json` is their snapshot (`BundledChecklistService`, used offline and until the API's copy of the same or a newer `version` replaces it), copied by `scripts/sync-bundled-wt9.sh`, never edited here. `Models/WT9ChecklistData.swift` is the fallback when the JSON doesn't resolve, held to it by `testBundledWT9SwiftStaticsMatchBundledJSON`. A WT9 change starts in the checklists repo.

## Architecture

- `AppState` is `@MainActor @Observable`, NOT an `ObservableObject` (bind with `Bindable(appState).property`); the other managers are `ObservableObject`s read through `@EnvironmentObject`.
- `AppState` is being taken apart: clusters move into facade structs (`NavigationMapState`, `FlightTiming`, `ChecklistProgress`), pure rules into testable types (`ChecklistHighlighting`, `FlightClock`). Follow that, don't add loose properties.
- Never delete a settings field (those retired in 6.0 and 6.0.1 are still decoded and synced). A field an older build can't round-trip bumps `AppSettings.currentSchemaVersion`, joins `AppSettings.protectedFields` and is always encoded, `nil` included (`SettingsSyncTests`).
- `FlightPlan ==` compares ids only: never use it to detect an edit.
- An armed plan is the pilot's intent: it survives backgrounding and relaunch, and expires by age only (`expireStaleActivation`, 72 h, once at launch with no flight running), never on `scenePhase`; one with no `activatedAt` never expires.
- GPS (`LocationManager`): on the ground no hardware distance filter. Every fix updates the status (green needs a satellite fix, `isSatelliteFix`), and only fixes 5 m from the last one reach `processLocation` (`passesGroundFilter`), the detector's input. No `requestLocation()` probes.
- Logbook times: a duration is the difference of the times as written, each truncated to the minute (`Flight.loggedMinutes` and its siblings), never a rounded `duration`: pilots copy these into their logbooks. Take-off and landing are re-measured from the GPS track at END FLIGHT (`TrackTimes`, GPS altitude, not the barometer); the nav log's Time OFF / ON are those, never the engine.
- Landing fees are links to each operator's own page, never amounts (the server's rule too).
- iCloud (`SyncManager`, CKSyncEngine) validates inbound records and MERGES them (newer `modifiedAt` for metadata, the richer side for tracks and landings).
- `FlightLauncher` is the one flight-start sequence (buttons, widget, deep link): never start a flight around it.
- In flight the checklist is the flight's own aircraft (`AppState.flightAircraft`, taken at START FLIGHT), never the selection, which iCloud can change mid-flight: read `activeChecklist` / `activeAircraftIsPremium`.
- `learningMode == true` shows every check (default since 6.0); the Settings switch is its inverse, "Memory test".
- `AirportType.fixedWing` keeps heliports, seaplane bases, balloonports and closed fields out of planning; the nav map's airport layer has its own list.
- The Companion iPhone's NAV screen draws the phone Cockpit's ROUTE and act band from the iPad's stream (`CompanionNavScreen.swift`): a new figure goes on the wire as an optional field an older build ignores.

## The Cockpit

The author flies with the iPad on a kneeboard, in portrait: judge in-flight UI there first.
- Fixed layout: every value keeps its place in every phase; the phase's items are highlighted in place, never moved up or dimmed. Nothing resizes live: reserve the room of what comes and goes (`.opacity(0)`, the widest value hidden) and put flags, toasts and banners in overlays.
- Sizes come from `CockpitType` and `CockpitTarget` (`Components/Typography.swift`): on the kneeboard, text read in flight at least 20 pt, controls at least 78 pt, the act band's buttons 104; the phone has its own (`CockpitScale`). Ground screens: `.scaledFont(…)`, 44 pt targets.
- A device's main thread has 1 MB of stack (the simulator 8), and a big inline `body` overflows it (EXC_BAD_ACCESS code=2 when a map opens, on the device only). Wrap large subtrees in `SeparateView { … }`, prefer small view structs, never grow `NavigationView` or `FlightView` bodies inline. `ViewStackBudgetTests` guards it.
- `CockpitLayout` (`Cockpit.swift`: `.wide`, `.narrow`, `.columns` for a phone on its side) lays out the read band, the page and the act band. CHECKLIST and MAP follow the phase (`CockpitPageRule`), ROUTE is the pilot's pick, and a pick holds until the suggestion changes. `CockpitColumnFitTests` adds up the `.columns` side column against an iPhone 17e.
- The act band's frames come from the width alone (`ActBandLayout`), its roles from the page and the flight (`ActBandRoles`); on the phone `ActFace` sets the words (broken between words, never cut). What a band button owns for every page (UNDO, Divert, the routes) is `CockpitNavState`: never put a thumb row back into a page.
- `NavigationMapView`'s `chrome` says whose map it is: `.plan` (Plan › Map, `mapArea`) or `.cockpit(layout)` (`cockpitMapArea` only: the chart and `CockpitChartChrome`). In-flight changes go to the latter: Plan › Map is never shown in flight. MAP's status slot shows the highest pending state only (`CockpitStatusRule`).
- OFF ROUTE and the radio follow every fix on every page (`CockpitMapFollower`, `CockpitRadioFollower`). `CockpitRadio` is the ONE in-flight source of frequencies (read band, ROUTE, Watch, Companion); its rules are the pure `PhaseFrequencyPlanner`, which Plan › Map calls itself.
- Waypoint times come from the GPS track (`WaypointPassage`), caught up every 15 s whatever the screen and backfilled at END FLIGHT; the departure takes the take-off and the destination the landing as soon as each is known (`followTakeoff`, `followLanding`: landed at the route's end, nothing is left to MARK). Only the flight's own plan (`Flight.flightPlanId`) gets times, and END or ABANDON FLIGHT touches that plan only. A waypoint taken back (UNDO, RESUME LEG) gets a time from MARK only (`FlightPlan.takenBackWaypointIds`).
- One undo offer at a time, whatever made it (MARK, the leg-timer reset, a waypoint's automatic mark, a check or FREDA done): `UndoOfferRule` shows the newest, for six seconds from when it was made, on any page; an older one never comes back, and a view never counts its own six seconds.
- After a relaunch in flight, `LocationManager` lets a new detector catch up with the restored track before its first fix, its cues and events held back: a detector started from scratch reads the next fast fixes near a field as a take-off and wipes the restored cues.
- `FlightEventDetector` is a port of the Python prototype in `../CLAUDE/review/flight-events/`, pinned by `testFullCorpusMatchesPythonReferee`: change the prototype first, regenerate the fixtures (`cue_referee.py`, `make_fixtures.py`), then port. The cues (`Models/FlightCues.swift`) only read it; nothing detected ticks an item or changes the phase without the pilot's answer.
- Deliberately NO estimated airspeed and NO stall warning: no pitot or AoA source, and the MeteoSwiss surface wind says nothing about the air aloft.

## Aeronautical data

Community sources, credited in About › Data sources, never presented as official: OpenAIP first, OurAirports the fallback, open flightmaps (OFM) for the gaps, "indicative" and next to a link to the official chart.
- OpenAIP's per-country exports are keyless, from `s3.openaip.net` (`OpenAIPConfig.geoJSONExportHost`, pinned), with the keyed core API as the fallback. The old `storage.googleapis.com` bucket is Requester Pays: don't go back to it.
- Runways: `AirportDataMergeEngine` pairs the sources' runways by designator, then by the strip (`physicalMatch`), names them by majority (OurAirports breaks a tie), and `RunwayDesignatorOverrides` has the last word (its header says how it is kept).
- OFM data comes only from `aerocheck.app/data/ofm/v1/` (allow-list, size cap, SHA-256 from `index.json`), written by `scripts/vfrdata/` on the `website` branch: a schema change starts there, additive within v1.
- `VFRMapLayer` (`VFRProcedureMapLayer.swift`) draws the procedures on all three maps: don't fork it. Its overlays are their own classes, never a bare `MKPolyline`; each map asks `VFRMapLayer.renderer(for:palette:)` first, and removals are narrowed to their own class (a blanket "remove every `MKPolyline`" wipes the procedures). No `lineDashPattern` for them: MapKit cuts dashes per zoom.
- `ReportingPointCatalog` is the only reader of reporting points; an OpenAIP `_id` any build saved must keep resolving.
- `OfficialChartService` gives a link, never a chart, opened only on its publisher's domain (`OfficialChartRegistry.publisherDomains`): a new country or domain needs an app release.

## iOS 17 target, newer SDK

- Liquid Glass is iOS 26+: `.floatingChromeBackground(cornerRadius:)` / `.floatingChromeCapsule()` fall back to `.regularMaterial`.
- An `@EnvironmentObject` type can't be `@available(iOS 26)`, so `CompanionConnectivityManager` exists on 17 and is INERT there: every `WiFiAware` / `NetworkListener` call sits behind `#available(iOS 26)`. Keep those gates.
- `WiFiAware` and `DeviceDiscoveryUI` are weak-linked (`OTHER_LDFLAGS`); a hard link crashes at launch below 26.
- A malformed `WiFiAwareServices` Info.plist entry traps, uncatchably: `._udp`, and Publishable/Subscribable as dictionaries, not Bools (`CompanionServiceContractTests`).

## Design System

- `Components/DesignSystem.swift`, `Shared/DesignTokens.swift`. `ThemePreference` resolves into a `CockpitThemeMode`, read as `@Environment(\.cockpitTheme)`, and in-flight views paint with its semantic tokens, never hard-coded colours; `\.isNightMode` derives from the same setting.
- The in-flight colour contract (after FAA AC 25-11B): red for warnings only, amber for cautions only, green for normal/done, magenta (`route`) for the active route, cyan (`action`) for anything touchable, white for data; gold is the ground's brand and reads as a caution in flight. Apart from `route` and `action`, every `.day` token equals its legacy value: keep it so.
- The ground screens keep the legacy `Color` statics on purpose, and the `MKMapView` delegates can't reach `@Environment`. Do NOT "fix" the split by making the legacy statics theme-aware. They already resolve through a runtime override (`AmbientPalette`) whose invalidation needs `.id(ambient.revision)` at the root (`AeroCheckApp.swift`), and that re-creates the view tree and drops every transient `@State`: fine for a rare manual toggle, not for `.auto` flipping to night mid-approach. `AmbientPalette` backs a hidden theme: never name or describe it in docs, commits or PRs (see the note in memory).
- `.preferredColorScheme(.dark)` reaches the whole WINDOW, even from an embedded view: set it only on a view presented on its own, `nil` when embedded (`isEmbedded`), or Auto resolves to night in daylight.
- The bundled B612 Mono is PATCHED (punctuation centred): run `scripts/center-b612-mono-punctuation.py` on any upstream file, never fix it per call site (`TypographyTests`).
- Settings UI is the Settings kit (`SettingsPage`, `SettingsGroup`, `Settings…Row`). A custom `ButtonStyle` reads `@Environment(\.isEnabled)` itself to dim. Keep an edited view's accessibility.

## Flight Thread

The thread carries the admin around a flight (PLAN, PREPARE, CLOSE); FLY, the 16-phase flight, stays untouched.
- A thread is OPTIONAL and stays so: a flight without one starts and ends as it always did. END FLIGHT resolves it (`threadToCloseOut(…)`) BEFORE `deactivateFlightPlan()`; `nil` means nothing below runs, and `FlightLauncher`'s guards never depend on one.
- `ThreadTaskEngine` is pure. A task stores a key, never words (`ThreadTaskPresentation`), and `ThreadTaskKey`'s raw value is persisted: add a case, never rename one.
- The close-flight-plan reminder is the one that matters (Zurich RCC alerts 30 min after the ETA): only when "flight plan filed" was ticked, red, no auto-dismiss. `NotificationService` sends it and a T−24 h nudge, nothing else.
- Reminders and links, never integrations: skybriefing and DABS are opened, then ticked.
- `FlightThreadManager` takes `defaults:` (the test host shares the app's bundle id).

## Permissions

A missing usage description is a CRASH, not a denied permission, and the simulator may never run the API that needs it (4.4.0 shipped that for the barometer). A privacy-protected API needs its key AND a row in `AeroCheckTests/PrivacyUsageDescriptionTests.swift`, in the same change. The location keys are build settings (`INFOPLIST_KEY_*`), the others in `AeroCheck/Info.plist`.

## Exports

- Nav log: a row is the leg ENDING at that waypoint (`FlightPlan.legArriving(at:)`); the route is never truncated (more sheets, headers repeated); Wind/GS print what the EET was computed with (`FlightPlan.legPlanning(from:)`).
- The PDFs (nav log, logbook extract) have hand-tuned columns and fixed sizes: a test can't see a clipped heading. After any change, render one and look at the pages.
- GPX import: AeroCheck's `<ele>` is the planned altitude, SkyDemon's is terrain (the plan is `<skd:level>`, the level of the leg STARTING at the point, stored where that leg ends); anyone else's is not a plan.

## Localization

- User-facing strings go through `L10n` (`Localization.swift`) into `AeroCheck/Localizable.xcstrings` (EN/FR); the Watch app has its own catalog.
- A count is a catalog plural (`%lld flights`), never a hand-made "s". A key never carries positional specifiers (`%1$@` goes in the French value). `String(localized:)` groups an interpolated number by region ("3'500"): format a figure apart when it must stay plain.
- Aviation abbreviations (kt, ft, NM, MSL, GPS, FREQ…) are not translated.
- One vocabulary: a Flight is one take-off to landing; a Trip is several flights in a row; a Route is a reusable path with no date; the Nav log is the printout; the ATC flight plan is what you file and close with ATC. Never "flight plan" alone (the printed nav log keeps the paper form's title).

## Secrets (the OpenAIP API key and the client secrets)

- Values live in the untracked `Secrets.xcconfig` (`cp Secrets.example.xcconfig Secrets.xcconfig`; the template says where each comes from), which `Config.xcconfig` includes with `#include?`; Info.plist hands them to `OpenAIPConfig` and `APIConfig`. Never reintroduce a literal key or print a value. An embedded key is extractable anyway: keep it out of the public source, rotate it if it leaks.
- Xcode Cloud writes the file in `ci_scripts/ci_post_clone.sh`, which must write every key the app reads (a missing one silently disables a feature in shipped builds). Environment variables are per workflow: a new workflow needs them set again.
- Empty values build and run: without `OPENAIP_API_KEY` the keyed requests (airspace tiles, the core API) get 401 and the airspace stays empty; an empty `APP_CLIENT_SECRET` gets 403 from `/airfields` wherever the server's list is set, so the landing-fee links silently vanish.
- Debug and TestFlight builds talk to `API_BASE_URL_SANDBOX`, App Store builds to production (`APIConfig.usesSandboxEndpoint`). For the server's `npm run dev`, set `API_BASE_URL_SANDBOX = http:/$()/localhost:8787` in `Config.xcconfig` itself, uncommitted: `//` would start a comment, and `Secrets.xcconfig` can't override it (`Config.xcconfig` sets the URLs after the include).
- `ElevationService` calls Open-Meteo's elevation API directly, unkeyed: an author decision (2026-09-27). Don't re-raise it.

## Versioning and releases

The app's part of the root file's release checklist:
- `MARKETING_VERSION` is bumped by hand once per release, in all 8 build configurations: `sed -i '' -E 's/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = X.Y.Z;/g' AeroCheck.xcodeproj/project.pbxproj`
- `CURRENT_PROJECT_VERSION` is NEVER edited by hand: `ci_scripts/ci_pre_xcodebuild.sh` writes Xcode Cloud's counter (one per app, shared by every workflow) into all 8 configurations. The checked-in value stays `1`.
- Xcode Cloud: "TestFlight (Alpha testing)" builds every push to `main` for the internal group; "TestFlight (Beta testing)" builds every tag for the internal and external Beta groups. The App Store gets the tag's beta build.
- Before EVERY tag, run `scripts/sync-bundled-wt9.sh` (commit the two files if they changed), and commit the testers' notes for `X.Y.Z` in `TestFlight/WhatToTest.en-US.txt` and `.fr-FR.txt`, the first line naming the version (what's new and what to try, short): `ci_scripts/ci_post_xcodebuild.sh` keeps them only then, and otherwise lists the pull requests since the previous tag. Then tag `X.Y.Z` on `main` and publish the GitHub release (it rebuilds the website's changelog). In the beta build's log, check `written to 8 build configurations` (another count means a target lost coverage and the upload will be refused) and `notes for X.Y.Z, as committed` for both languages.
