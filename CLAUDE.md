# CLAUDE.md - AeroCheck app

iPad-first iPhone/iPad app (Swift/SwiftUI, iOS 17.0 floor) that walks a pilot through the 16 checklist
phases while recording the GPS track. The WT9 Dynamic is bundled and free; the other aircraft come from
the API with a subscription. UI in English and French.

This file keeps what the code won't tell you: rules, traps, decisions and non-obvious locations. The
aircraft roster, the API and its versioning rule, and the 16-phase list live in the ecosystem
`CLAUDE.md` one folder up (`../CLAUDE.md`, outside this repo).

## Build & Run

```bash
open AeroCheck.xcodeproj    # run scheme: AéroCheck (with the accent)
```

- Tests live on the `AeroCheckTests` scheme. The app scheme has no test action, so a plain `build`
  never compiles the tests.
- Toolchain: Xcode 26 or later (iOS 26+ SDK), because the Companion files `import WiFiAware`
  unconditionally. Simulators currently run iOS 27.0 (Xcode 27). A development team must be set.

Simulator rules (read them before any `xcodebuild` or `simctl`):

- NEVER use the author's own simulator, `iPad Air 11-inch (M4)` `A7A5FC41-C92E-48EE-9A06-0E833852F3D5`:
  no installs, no scenes, no tests.
- Always target a simulator by `id=<UDID>`, never `name=`: `name=iPad Air 11-inch (M4)` resolves to the
  author's one.
- Unit tests run on a throwaway simulator, created for the run and deleted after it.

The safe recipe (run both `xcodebuild` steps in the background):

```bash
UDID=$(xcrun simctl create "AeroCheck Tmp tests" com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M4)
xcodebuild build-for-testing -scheme AeroCheckTests -destination "platform=iOS Simulator,id=$UDID"
xcodebuild test-without-building -scheme AeroCheckTests -destination "platform=iOS Simulator,id=$UDID" \
  -collect-test-diagnostics never          # one class: -only-testing:AeroCheckTests/ObstacleTests
xcrun simctl shutdown "$UDID"; xcrun simctl delete "$UDID"
```

Without `-collect-test-diagnostics never`, a failing test makes xcodebuild collect a sysdiagnose for
minutes, which looks like a hang. Never stop xcodebuild with `kill -9` (SIGINT/SIGTERM let it tear its
own session down).

`scripts/run-tests.sh [simulator] [TestClass] [--keep-install]` wraps the same two steps with a watchdog
each and a clean reinstall of the host app (its data is kept aside and put back; permission answers are
asked again). Two catches: with no simulator argument it targets `iPad Air 11-inch (M4)`, i.e. the
author's simulator, and its preflight runs `killall SWBBuildService XCBBuildService` UNCONDITIONALLY,
which breaks every other build on the Mac (Xcode's included). From a session, only run it with a
throwaway's UDID and nothing else building; otherwise use the recipe above.

Two failures look like a hung test run. Tell them apart by where the log stops:

1. During the build (no "Testing started"): the build service has wedged (`xcodebuild` waits in
   `waitForBuildWithBuildLog:` on an idle `SWBBuildService`). `killall SWBBuildService XCBBuildService`
   (when nothing else is building) and retry. Sample `xcodebuild`, not the app: an app left on the
   simulator is a red herring here.
2. "Testing started", no test case, then after ~5 min "The test runner hung before establishing
   connection": the host app was launched without the XCTest bundle (`ps eww <pid>` shows no
   XCTestBundleInject). Rebooting doesn't fix it; `xcrun simctl uninstall <UDID> com.fetzu.aerocheck`
   does (the app's data is not the cause).

StoreKit testing: `AeroCheck/Configuration.storekit` is in the project but NOT referenced by any
shared scheme. Select it under Edit Scheme › Run › Options › StoreKit Configuration; that edits the
tracked `AéroCheck.xcscheme`, so don't commit the change unless asked. Developer Options (with the debug
log viewer): tap the version five times in Settings › About.

## Project Structure

Directories, plus the files you would not find by name. The project uses classic Xcode groups, not
synchronized folders: a new source file needs four `project.pbxproj` entries (PBXBuildFile,
PBXFileReference, the group's children, the target's Sources phase), with ids you have grep-checked as
unused. A colliding id silently drops ANOTHER file from the build, and the errors point at that file.

```
AeroCheck/                app target
  AeroCheckApp.swift      entry point: environment injection, root theme and colour-scheme wiring
  Localization.swift      the L10n statics (strings in Localizable.xcstrings, EN/FR)
  Views/                  screens; Views/Settings/ = the Settings sub-pages
  Models/                 AppState, Flight, FlightPlan, FlightThread, checklist and OpenAIP models
  Services/               managers, data services, and PURE planners (…Planner, ThreadTaskEngine)
  Components/             DesignSystem.swift, Typography.swift, ChecklistView.swift
  Resources/              wt9-dynamic-bundled(-fr).json = the free aircraft's source of truth; B612 fonts
Shared/                   at the REPO ROOT; compiled into the app and the Watch and/or Widget targets
AeroCheckWidget/          widgets and the Live Activity (FlightLiveActivity.swift)
AeroCheckWatch/           the Watch app
AeroCheckTests/           unit tests, one <Feature>Tests.swift per feature; TestDatastore.swift
ci_scripts/               Xcode Cloud: ci_post_clone.sh (secrets), ci_pre_xcodebuild.sh (build number), ci_post_xcodebuild.sh (What to Test)
TestFlight/               What to Test for the next release tag, EN + FR (ci_post_xcodebuild.sh)
```

Owners and rules that aren't obvious from the names:

- `ContentView` routes to `GroundView` on the ground (tabs Today · Plan · Logbook · Aircraft · Settings;
  `appState.groundTab` switches tab from anywhere; Today is `HomeView`) and to `FlightView` in flight.
- `FlightView` + `Cockpit.swift` = the Cockpit, on iPad AND iPhone: `CockpitLayout` (wide / narrow /
  columns) arranges the same zones, and the page follows the phase (`CockpitPaneRule`: CHECKLIST or
  MAP; ROUTE, `CockpitRoutePage.swift`, is the pilot's pick only). There is no separate iPhone HUD.
  Under every page sits the act band (`CockpitActBand.swift`, 6.2): four slots whose frames come from the
  width alone (`ActBandLayout`) and whose roles come from the page and the flight (`ActBandRoles`). What a
  button there owns for every page (MARK's and the reset's UNDO, the Divert sheet, the routes cover, the
  leg ROUTE asks MAP to show) is `CockpitNavState`, in the environment; never put a thumb row back into a
  page.
- `NavigationView.swift` holds `NavigationMapView` (embedded in the Cockpit and in Plan › Map) and
  `MapPreset`. Its `chrome` says whose it is: `.plan` keeps every piece of its own chrome (side column on
  its side, Routes at its foot, the legs and frequencies panel); `.cockpit(layout)` has no thumb row, no
  side column and no legs panel (its card and NOW | NEXT open ROUTE), and beside the phone's column on
  its side it is the chart alone.
- Frequencies: the rules are `PhaseFrequencyPlanner` (`Services/PhaseFrequencyPlanner.swift`, pure:
  nearest 6 fields within 40 nm, the area FIS, CTRs within 25 nm). In flight `CockpitRadio` is the ONE
  source (NOW/NEXT for the map, ROUTE's RADIO, the Watch's list), recomputed on every page by
  `CockpitRadioFollower`; Plan › Map calls the planner itself and syncs the Watch only there.
- `FlightLauncher` is the ONE flight-start sequence (buttons, widget, deep link): checklist load →
  entitlement / permission / active-flight guards → start → GPS. Never start a flight around it.
- Waypoint ATOs come from the GPS track (`WaypointPassage`: abeam within 2.5 NM, forward only).
  `LocationManager.processLocation` catches the active plan up every 15 s in flight, whatever screen
  is showing (`FlightPlanManager.catchUpWaypointPassages`); END FLIGHT backfills the rest. Only the
  flight's own plan (`Flight.flightPlanId`) gets times: never a plan left armed through circuits or a
  flight started without it. END FLIGHT (`settleFlownPlan`) writes into, attaches and deactivates only
  that plan, and ABANDON FLIGHT (`abandonFlownPlan`) deactivates only that plan; any other stays armed,
  untouched. The departure takes the takeoff time and the destination the landing time, never a
  proximity; nothing is marked while diverting; the new leg's timer starts at the passage. Each mark
  past the departure raises `FlightPlanManager.autoMarkNotice`, offered back on the checklist pane and
  on the map (`NavUndoToast`: outlined UNDO, where MARK's and the leg-timer reset's are filled; all
  20 pt, 78 pt). A waypoint taken back (UNDO, RESUME LEG) is left to MARK:
  `FlightPlan.takenBackWaypointIds` survives a relaunch, and no track fill (in flight, END FLIGHT, the
  Flight Log) gives it a time. UNDO keeps a departure marked in the same run.
- `FlightEventDetector` (take-off, touch-and-go, go-around, full stop) is a port of the Python prototype in
  `../CLAUDE/review/flight-events/` and pinned to it by `AeroCheckTests/FlightEventFixtures/` and
  `testFullCorpusMatchesPythonReferee`: change the prototype first, run `cue_referee.py` / `make_fixtures.py`,
  then port. The cues that time the check slot (`Models/FlightCues.swift`: 500 ft, level-off, descent,
  approach, circuit) only read its state and never write to it; they never tick an item or change the phase.
  A detected landing moves the Cockpit only on the pilot's answer: the landed card to AFTER LANDING, the
  circuits' full-stop card to TAXI.
- `WidgetBridge` publishes the owned-aircraft list to the widget through the App Group
  `group.com.fetzu.aerocheck`; the widget renders only those and launches through `FlightLauncher`.
  `Models/FlightActivityAttributes.swift` is compiled into the widget too (Live Activity).
- `ActiveChecklist` owns the resolved checklist and speeds of the active aircraft (there are no global
  checklist statics any more). In flight that is the flight's own aircraft (`AppState.flightAircraft`,
  taken at START FLIGHT and restored from the crash checkpoint), never the selection: iCloud syncs
  `selectedAircraft` / `selectedRemoteAircraftId`, so another device can change them mid-flight. Read
  `activeChecklist` / `activeAircraftIsPremium` for anything about the flight in progress.
- `ChecklistProgress` (in `AppState.swift`): phase, highlight, deferred items (DEFER, or NEXT with items
  still open) and deferred checks (a phase jumped over on the phase bar); both follow the pilot until
  checked.
- `learningMode` is stored INVERTED: `true` = every check shown (the default since 6.0), `false` = the
  "Memory test" that hides memorisable checks.
- `WindDataService`: MeteoSwiss surface wind for the briefings, Switzerland only; the station is chosen
  by distance AND altitude delta. There is deliberately NO estimated-airspeed readout and NO stall
  annunciation: the app has no pitot or AoA source, and surface wind says nothing about air at altitude.
- `OpenAIPDataService.airspaceProfileBlocks` + `ElevationService` draw the airspace conflicts and the
  terrain clearance on the route profile.
- `AirportDataService` is lazy: `await ensureLoaded()` before querying it.
- `AirportType.fixedWing` (`Models/Airport.swift`) keeps heliports, seaplane bases, balloonports and
  closed fields out of the planning pickers (builder search and map, snapping, stops, diverts). The nav
  map's airport layer has its own literal list in `NavigationView`.

## Aeronautical data

Community sources, credited in About › Data sources, never presented as official: OpenAIP is primary,
OurAirports the fallback, open flightmaps (OFM) fills gaps and is always "indicative" next to a link to
the official chart.

- OpenAIP's keyless per-country exports come from `s3.openaip.net` (`OpenAIPConfig.geoJSONExportHost`),
  pinned (a redirect elsewhere is refused), in their own session (300 s: Germany's obstacles are
  ~21.6 MB). The old `storage.googleapis.com/29f98e10-…` bucket is Requester Pays and refuses anonymous
  reads; don't go back to it. The keyed core API stays as the fallback (the host allows 20 requests/s).
- `RunwayDesignatorOverrides`: designators set by hand (LSGC 05/23, LSPM 10/28), applied after the
  OurAirports/OpenAIP merge. The merge never joins on designators: it matches runways physically, takes
  the majority, OurAirports breaks ties. Checked each quarter with the landing-fee links: re-read each
  entry's source, bump `checked`, drop the entries both sources have caught up with. Each entry has a
  test in `OpenAIPAirportMergeTests`.
- `OFMDataService`: circuits, VFR arrival/departure routes and sectors, reporting points and runway
  designators, read from `aerocheck.app/data/ofm/v1/` only (allow-list, 4 MB per file, SHA-256 from
  `index.json`). The app never calls OFM: the files come from the weekly `vfr-data.yml` job on `main`,
  which runs `scripts/vfrdata/` on the `website` branch, so a schema change starts there (additive
  within v1). Stale by AIRAC cycle, not by age (`DataSet.refreshWhenAging`). OFM ids aren't unique: a
  procedure's `id` is `<country>:<kind>:<OFM id>`, `ofmId` keeps OFM's for the error report.
- `VFRProcedureMapLayer.swift` (`VFRMapLayer`) is the one implementation for all three maps (both nav
  representables and the route builder): don't fork it per map. Overlays are their own classes
  (`VFRCircuitOverlay`, `VFRRouteOverlay`, `VFRDashOverlay`, `VFRSectorOverlay`), never a bare
  `MKPolyline`, and each map asks `VFRMapLayer.renderer(for:palette:)` before its generic `MKPolyline`
  branch. Removals are narrowed to their own class: the builder's route is `RouteLinePolyline`
  (`RouteBuilderMapView.removeRouteOverlays`), the Swiss map's layer switch removes only the track
  (`SwissMapView.removeTrackForRecolour`); a blanket "remove every `MKPolyline`" wipes the procedures.
  `sync` diffs by id and returns early on an unchanged signature (every GPS tick). No `lineDashPattern`
  and no renderer that draws its own tiles: MapKit rasterizes both and magnifies them past its last
  tile level, so dashes and arrowheads are cut per zoom (`VFRMapLayer.Zoom`).
- `ReportingPointCatalog` is the only reader of reporting points (maps, builder search and snap,
  briefing, the `sourceId` lookups): OpenAIP first and unchanged, plus the OFM points that neither the
  extractor nor the device's own OpenAIP data match. OFM ids are `ofm:<OFM id>`; an OpenAIP `_id` saved
  by any build must keep resolving. Outside the catalog, `OpenAIPReportingPointDataService` is for
  downloads only.
- `OfficialChartService` reads `aerocheck.app/data/charts/v1/charts.json` (same job,
  `charts_registry.py`) the way `AirfieldTariffService` reads the tariffs: disk cache, a week, silent
  failure. A link, never a chart: the app downloads and shows none. A link opens only on its
  publisher's domain (`OfficialChartRegistry.publisherDomains`), so a new country or a publisher's new
  domain needs an app release. No Italy: ENAV forbids deep links.

## Architecture

- `AppState` is `@MainActor @Observable`, NOT an `ObservableObject`: views read it with
  `@Environment(AppState.self)` and bind with `Bindable(appState).property`, and re-render only for the
  properties they read. Every other manager (`SubscriptionManager`, `LocationManager`,
  `FlightPlanManager`, `FlightThreadManager`, …) is an `ObservableObject` read via `@EnvironmentObject`.
- `AppState` is being decomposed: cohesive clusters move into facade structs (`NavigationMapState`,
  `FlightTiming`, `ChecklistProgress`) behind thin forwarding accessors, and pure rules into testable
  types (`ChecklistHighlighting`, `FlightClock`). Follow that pattern instead of adding loose properties.
- Persisted models (`AppSettings`, `Flight`, `FlightPlan`) decode through hand-written `init(from:)`: a
  new field goes there as `decodeIfPresent … ?? default` (a synthesized non-optional field makes every
  older file fail to decode). Never delete a settings field: the ones retired in 6.0 (circuit mode, keep
  screen on, step-by-step) and 6.0.1 (waypoint proximity) are still decoded and synced for older builds.
  A settings field an older build can't round-trip also bumps `AppSettings.currentSchemaVersion`,
  joins `AppSettings.protectedFields`, and is encoded whatever its value (no `nil` left out). An older
  build relays a newer record with the newer stamp, so ingest tells it apart by the missing key, and
  sends the merged record back (`SettingsSyncTests`).
- `FlightPlan ==` compares ids only: never use it to detect an edit (it once silently dropped every
  saved-plan change).
- iCloud sync (`SyncManager`, CKSyncEngine): inbound records are validated (unknown schema, oversized or
  non-finite coordinates are rejected; numbers are clamped) and MERGED, not overwritten: the newer
  `modifiedAt` wins for metadata, append-only data (track, landings) keeps the richer side, and
  `serverRecordChanged` merges and re-queues. Conflicts surface through `AppState.syncConflictNotice`.

Watch ≠ Companion, two separate stacks: the Watch app uses WatchConnectivity
(`Services/WatchConnectivityManager.swift` ↔ `AeroCheckWatch/`, models in
`Shared/WatchConnectivityData.swift`); Companion mode pairs iPad (master) and iPhone (viewer) over Wi-Fi
Aware (`CompanionConnectivityManager`, `Views/Companion*`, `Shared/CompanionConnectivityData.swift`).

## iOS 17 target, newer SDK

The deployment target is iOS 17.0 (watchOS 10.0) and the SDK is newer, so any un-gated newer symbol is a
hard compile error. Gate with `@available` / `if #available` and keep a 17.0 path; don't raise the floor.

- Liquid Glass (`.glassEffect`) is iOS 26+: use `DesignSystem.floatingChromeBackground(cornerRadius:)` /
  `floatingChromeCircle()`, which fall back to `.regularMaterial` on 17.
- Companion is iOS 26+. A type injected as `@EnvironmentObject` can't be `@available(iOS 26)` (every
  view holding it would become 26-only), so `CompanionConnectivityManager` exists on 17 but is INERT: it
  stores the version-agnostic `CompanionPairedDevice` and gates every `WiFiAware` / `NetworkListener`
  call behind `#available(iOS 26)`. Keep those gates.
- `WiFiAware` and `DeviceDiscoveryUI` are linked with `-weak_framework` (`OTHER_LDFLAGS`); a hard link
  crashes at launch below 26.
- A malformed `WiFiAwareServices` Info.plist entry traps, uncatchably: the service name must be `._udp`
  (`companionWiFiAwareServiceName`) and Publishable/Subscribable must be dictionaries, not Bools.
  `CompanionServiceContractTests` lock both.

## Design System

The cockpit design language lives in `Components/DesignSystem.swift` + `Shared/DesignTokens.swift`.
The user picks a `ThemePreference` (auto / day / sunlight / night; `auto` follows the system appearance,
and the opt-in sunlight boost only ever escalates a DAY palette), resolved into a `CockpitThemeMode`
palette and injected as `@Environment(\.cockpitTheme)`. Views should read semantic tokens (`action`,
`onTarget`, surfaces, text, chrome) rather than hard-coded colours.

Adoption is deliberate and partial; know which side of the line you are on:

- Migrated: the in-flight surfaces (`NavigationView`, `FlightView`, `ChecklistView`) read
  `\.cockpitTheme` and paint with tokens. They are what you read in glare, so Sunlight does something there.
- Not migrated, on purpose: ground screens (Home, Settings, Flight Log, planning, onboarding, paywall)
  keep the legacy `Color` statics (nobody reads them at 5000 ft in sunlight; migrate opportunistically),
  and the `MKMapView` delegate code in the `UIViewRepresentable`s (`NativeMapViewUIKit`, `SwissMapView`,
  `FlightMiniMap`) can't reach `@Environment` at all. Theming those means threading the palette into the
  `Coordinator` from `updateUIView` (~50 sites, a separate and riskier job).
- The in-flight colour contract (6.0, after FAA AC 25-11B): red for warnings only, amber for cautions
  only, green for normal/done, magenta (`route`) for the active route, cyan (`action`) for anything the
  pilot can touch, white for data. Aviation gold stays the brand colour on the ground screens; in flight
  it read as a caution. Apart from `route` and `action`, every `.day` token equals its legacy value:
  keep it that way for new tokens. Night keeps its red family (`route` is a dim rose). The map delegates
  use fixed colours (`UIColor.flownTrack`, a white ownship, a magenta route).
- Do NOT "fix" the split by making the legacy statics theme-aware. They already resolve through a
  runtime override (`AmbientPalette`) whose invalidation needs `.id(ambient.revision)` at the root
  (`AeroCheckApp.swift`), and that re-creates the view tree and drops every transient `@State`. Fine for
  a rare manual toggle, not for `.auto` flipping to night mid-approach and closing the open sheets.
  `AmbientPalette` backs a hidden theme: never name or describe it in docs, commits or PRs (see the note
  in memory).
- `\.isNightMode` and `\.cockpitTheme` both derive from `AppSettings.themePreference`
  (`effectiveNightMode` / `cockpitThemeMode`), so a site using either agrees with one using the other.

`.preferredColorScheme(.dark)` reaches the whole WINDOW, even from an embedded view. Set it only on a
view presented on its own (cover, sheet) and pass `nil` when embedded (`SettingsView` and
`FlightPlanningView` take `isEmbedded`, `FlightLogView` its mode, `NavigationMapView` `showsCloseButton`).
When the 6.0 tab bar embedded those views with a hard `.dark`, the root could no longer read the device's
appearance and Auto resolved to night in daylight.

- Typography (6.0): B612 everywhere in the app (`Font.aero` mirrors `Font.system`; the widget, the Watch
  and the nav log PDF keep the system font). Anything read in flight uses a `CockpitType` size and a
  `CockpitTarget` (thumb 104, control 64 on the kneeboard; smaller on the phone via `CockpitScale`).
  Ground screens use `.scaledFont(size:weight:design:relativeTo:)` for Dynamic Type; in-flight
  instrumentation keeps fixed sizes on purpose (UX-24). 44 pt minimum targets elsewhere.
- The bundled B612 Mono is PATCHED: upstream draws `: ; . , ' ·` at the left of the cell ("00: 44"),
  ours centres them with the advances unchanged (`scripts/center-b612-mono-punctuation.py`, recorded
  in `Resources/FONTLOG-B612.txt`). An upstream file dropped in as-is brings the bug back
  (`TypographyTests` catches it); run the script on it. Never fix it per call site.
- Settings UI: always the Settings kit (`SettingsPage` / `SettingsGroup` / `Settings*Row`).
- A custom `ButtonStyle` must read `@Environment(\.isEnabled)` itself to dim when `.disabled()`.
- Accessibility (VoiceOver labels, Dynamic Type, WCAG contrast, 44 pt targets, Reduce Motion) is
  first-class on the redesigned screens: preserve it when editing a view.

## Flight Thread (v5.0.0)

The app follows a flight through four chapters, PLAN → PREPARE → FLY → CLOSE. FLY is the existing
16-phase flight and is deliberately untouched; the thread only carries the admin work around it, and
every item is a check.

A thread is OPTIONAL and must stay that way: START FLIGHT works with no thread in sight, and a flight
without one ends exactly as it always did. `FlightView`'s END FLIGHT resolves the thread with
`threadToCloseOut(flightId:planId:)` BEFORE `deactivateFlightPlan()` (afterwards there is no plan left to
resolve from); `nil` means nothing below it runs. Resolving at END rather than linking at START is what
lets a widget- or deep-link-launched flight close out correctly without touching `FlightLauncher`'s
guards.

- `ThreadTaskEngine` is pure (`Context` in, `[ThreadTask]` out, no services). Regeneration is
  non-destructive: tasks match on `key#subject`, so a tick survives a route edit. Auto tasks are ALWAYS
  recomputed, so a fuel row can never keep claiming a stale computation.
- Tasks store a key, never copy: `ThreadTaskPresentation` resolves title, hint, icon and links at render
  time, so a persisted thread is language-agnostic and rewording needs no migration.
- The close-flight-plan reminder is the load-bearing feature. It exists only when the pilot ticked
  "flight plan filed" (`FlightThread.hasOpenFlightPlan`), which keeps circuits and unfiled flights
  silent. Zurich RCC is alerted 30 min after the ETA, hence red, no auto-dismiss, and the FIC number as
  the primary action. `NotificationService` sends two reminders only: that one and a T−24 h preparation
  nudge.
- Profiles: `.full` for cross-country, `.local` for circuits (weather, DABS, logbook, debrief).
- Reminders and links, not integrations: skybriefing and DABS are opened, then ticked, so nothing breaks
  when an upstream changes its interface.
- `FlightThreadManager` mirrors `FlightPlanManager` (ObservableObject + `@Published`, injectable
  `defaults:` because the test host shares the app's bundle id, dirty-diffed off-main file writes).
  `context(for:profile:)` is `@MainActor` (the border test reads `CountryBoundaries.shared`); the
  `countries:` overload is `nonisolated` and is what the tests drive.

## Permissions (Info.plist)

- `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`
- `NSMotionUsageDescription`: CoreMotion `CMAltimeter`, started with GPS tracking by
  `LocationManager.beginTrackingNow()` (barometric altitude for the flight-event detector)
- `NSPhotoLibraryAddUsageDescription`: saving flight-log share cards to Photos
- `UIBackgroundModes: [location, remote-notification]`

A missing usage description is a CRASH, not a denied permission: iOS kills the process, uncatchably, the
first time the protected API runs. 4.4.0 shipped exactly that (`BarometricAltitudeService` without
`NSMotionUsageDescription`, so every barometer-equipped device died on the first START FLIGHT), and it
survived review because the simulator has no barometer, so the protected call never runs there or in the
tests. `AeroCheckTests/PrivacyUsageDescriptionTests.swift` locks the keys: adding a privacy-protected API
means adding its key AND a row there in the same change. The app target sets both
`INFOPLIST_FILE = AeroCheck/Info.plist` and `GENERATE_INFOPLIST_FILE = YES`, so a key lives either in the
file or in an `INFOPLIST_KEY_*` build setting (the location keys are build settings, the rest are in the
file).

Entitlements are in `AéroCheck.entitlements` (repo root): iCloud/CloudKit, the App Group above, Wi-Fi
Aware (Publish + Subscribe) for Companion, `aps-environment`.

## Export Formats

- GPX 1.1 with a custom `pc:` namespace for flight metadata; JSON (full flight, ISO 8601 dates); ZIP for
  batches; GPX routes for MFDs (Dynon, Garmin).
- Nav log (PDF A4/A5, Excel): each row is the leg ENDING at that waypoint (the Nav view's
  `legArriving(at:)` convention). The route is never truncated: it flows onto further sheets with the
  column headers repeated, and fuel, times and debriefing move to the last sheet when they don't fit.
  Freq/C/S, airspace remarks and the Radio box come from `RouteRadioPlanner` (OpenAIP airspace at the
  planned altitude, else the Swiss FIS sector; aerodromes matched by position). Wind/GS print what the
  EET was computed with (`FlightPlan.legPlanning(from:)`).
- GPX import: what `<ele>` means depends on the creator. AeroCheck's own files: the planned altitude.
  SkyDemon: terrain; the plan is `<skd:level>` (level of the leg STARTING at the point, stored on the
  waypoint where that leg ends; endpoint aerodromes keep field elevation), idents in `<sym>`. Any other
  source: `<ele>` is not read as a plan, and the builder offers "Set altitudes" instead.

## Localization and logging

- Every user-facing string goes through `L10n.*` (`Localization.swift`); translations live in
  `Localizable.xcstrings` (EN/FR). Builds reformat that file and `xcuserstate` is tracked: NEVER
  `git add -A` / `git add .` in this repo, stage files by name.
- The Watch app has its own catalog, `AeroCheckWatch/Localizable.xcstrings` (EN/FR): its strings never
  go in the app's. `LocalizationCatalogTests` reads the French of the Watch app the phone app embeds.
- A count goes through a plural in the catalog (`%lld flights`: one/other), never a hand-made "s".
- Aviation abbreviations (kt, ft, NM, MSL, GPS, FREQ…) are not translated (ICAO).
- One vocabulary (6.0 · P8): a *Flight* is one take-off to landing, planned (Plan) or flown (Logbook); a
  *Trip* is several flights in a row; a *Route* is a reusable path with no date; the *Nav log* is the
  printout; the *ATC flight plan* is what you file and close with ATC. Never "flight plan" on its own.
  The printed nav log keeps its form title ("AVIS DE VOL – PLAN DE VOL DE NAVIGATION"): it mirrors the
  paper form.
- Logging goes through `AppLog` (`Shared/AppLog.swift`, one `os.Logger` per category), never `print()`.
  `debugLine` logs as private; `publicLine` only for text with no identifier, coordinate, credential or
  user content (SA-20).

## Tests

- Group tests by feature: add to the existing `<Feature>Tests.swift` or create a new one, never a file
  named after a review or a phase.
- The test host IS the app, so `DataPersistenceManager.shared` and `UserDefaults.standard` are the
  simulator app's real data (a test run once wiped a real trip). Build `AppState`, `FlightThreadManager`,
  `FlightPlanManager`, `AircraftDataService` or `SubscriptionManager` only through the
  `TestDatastore.swift` helpers (`makeTestDatastore()`, `makeTestDefaults()`, …).

Ground replays (the in-flight checks without flying): `scripts/ground-replay.sh [--only
ChecksInFlightUITests/testCrossCountryEveryCheckOnTime] [--iphone]` (`--iphone` alone: the phone's own
steps) creates a throwaway simulator, runs the `AeroCheckUITests` scheme and writes `results.json` (each
device-check step id: pass, fail, or observed when only a person can judge it) and the screenshots
`<page>-<step id>-<short>.png` to `$TMPDIR/aerocheck-ground-replay/<date>`, then deletes the simulator.
The screenshots show checklist text: never attach them to anything public.

- How: DEBUG `Services/GroundReplay.swift`, launched by `AEROCHECK_REPLAY=<scenario JSON>`
  (`AEROCHECK_REPLAY_SPEED`, default 10; `AEROCHECK_REPLAY_RESUME=1` after a relaunch), feeds the track
  through `LocationManager.feedReplayFix` (the device's own path) on a virtual clock, waits at the
  scenario's holds (ENGINE START, READY FOR LINE UP) for the UI test, injects the scenario's aerodromes
  and arms its route. Release builds compile none of it.
- Anything a flight times reads `FlightClock.now`, never `Date()`, or a replay puts it on another clock
  than the track, the detector and the slot. Undo windows count `FlightClock.pilotSeconds(since:)`.
- A UI test reads accessibility identifiers, never colours or words that change with the language: the
  check slot's identifier carries its tone and action (`checkSlot.due.confirmFromMemory`). It reads an
  element in one query (`CockpitPilot.snap`) and taps it where it was seen (`tapNow`): at 10x a toast or
  a card can go between two queries, and a failed read or tap fails the test.
- Scenarios: `scripts/flightsim/make_scenario.py` (Python, standard library) generates them into
  `AeroCheckUITests/Scenarios` and writes what the detector's referee (`../CLAUDE/review/flight-events`,
  or `AEROCHECK_REFEREE=<dir>`) expects of each. Regenerate them after a change to the detector or the
  cues. `GroundReplayTests` replays the same flights through the whole chain without a view, in a second.

## Secrets / API keys (OpenAIP key and client secrets)

- No secret in tracked source, ever, and never print one. The values live in the untracked
  `Secrets.xcconfig` (`cp Secrets.example.xcconfig Secrets.xcconfig`, then fill it in; the template says
  where each value comes from), which `Config.xcconfig` (the app target's base configuration)
  `#include?`s; they reach the code through Info.plist (`OpenAIPConfig`, `APIConfig`). Xcode Cloud writes
  the file in `ci_scripts/ci_post_clone.sh`. A client-embedded key is extractable anyway: what matters is
  keeping it out of the public source and rotating it if it leaks. Never reintroduce a literal key.
- Empty values still build and run: no OpenAIP overlay, a harmless missing weather header, but an empty
  `APP_CLIENT_SECRET` gets 403 from production's `/airfields` routes, so landing fees silently vanish.
- The API endpoint is picked at runtime (`APIConfig.usesSandboxEndpoint`): Debug builds and TestFlight
  (sandbox receipt) talk to `API_BASE_URL_SANDBOX`, only App Store builds to production. To aim a local
  build at `npm run dev`, override `API_BASE_URL_SANDBOX` in `Secrets.xcconfig`.
- `ElevationService` calls `api.open-meteo.com/v1/elevation` directly, unkeyed, not through the weather
  worker. That is a deliberate choice (author decision 2026-09-27), not an oversight: the app itself is
  free, the subscription only unlocks premium aircraft checklists, and Open-Meteo elevation is not
  paywalled content worth routing through licensed infrastructure. Don't re-raise it in review.

## Versioning and releases

- `MARKETING_VERSION` (SemVer, `CFBundleShortVersionString`) is bumped by hand once per release, in all 8
  build configurations:
  `sed -i '' -E 's/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = X.Y.Z;/g' AeroCheck.xcodeproj/project.pbxproj`
- `CURRENT_PROJECT_VERSION` (`CFBundleVersion`) is NEVER edited by hand: Xcode Cloud's
  `ci_scripts/ci_pre_xcodebuild.sh` writes its counter into all 8 configurations (app, widget and Watch
  must match, hence `project.pbxproj` and not an xcconfig; the script says why). The checked-in default
  stays `1` and the number is never reset. Xcode Cloud keeps ONE counter per app, shared by every
  workflow (confirmed by the first tag build, Oct 2026), so two workflows can both upload.
- **TestFlight:** two Xcode Cloud workflows. "CI/CD for TestFlight (Internal Testing)" builds every push to
  `main` for the internal (alpha) group; "Beta · tags" builds every release tag for the internal group and
  the external Beta group (Beta App Review). The App Store gets the tag's beta build. Environment variables
  (the three secrets of `ci_post_clone.sh`) belong to each workflow: a new workflow needs them set again.
- **What to Test:** `ci_scripts/ci_post_xcodebuild.sh` writes `TestFlight/WhatToTest.<locale>.txt`, which Xcode
  Cloud shows the testers of the build. A main build lists the last pull requests merged. A tag build keeps
  the notes committed in `TestFlight/`, if their first line names the tag; otherwise it lists the pull
  requests since the previous tag and warns in the log.
- To release: before tagging, commit the beta testers' notes for `X.Y.Z` in `TestFlight/WhatToTest.en-US.txt`
  and `.fr-FR.txt` (first line names the version; what's new and what to try, short). Then tag `X.Y.Z` on
  `main` and publish the GitHub release (that rebuilds the website changelog). In the beta build's Xcode
  Cloud log, check `written to 8 build configurations` (any other count means a target stopped being
  covered and the upload will be refused) and `notes for X.Y.Z, as committed` for both languages.
