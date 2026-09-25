# CLAUDE.md - AeroCheck Project

## Project Overview

iPhone/iPad app for pilot students. Guides pilots through flight checklists while recording GPS tracks and flight data. Supports multiple aircraft with a freemium model: free bundled aircraft (WT9 Dynamic) and 13 premium aircraft via subscription.

- **Target:** iOS/iPadOS 17.0+ (iPhone and iPad, iPad-first; optimized for iPad Air 11" and larger)
- **Tech:** Swift 5.9+, SwiftUI, CoreLocation, MapKit, WidgetKit, StoreKit 2, CloudKit, WiFiAware (iOS 26+, Companion mode)
- **UI:** v4 cockpit design language. Selectable theme engine (`ThemePreference`: auto / day / sunlight / night) resolving to `CockpitThemeMode` palettes via `@Environment(\.cockpitTheme)`; Liquid Glass map chrome on iOS 26+ with a 17.0 material fallback. Accessibility pass (VoiceOver, Dynamic Type, WCAG contrast, 44pt targets, Reduce Motion).
- **Languages:** English, French (full UI localization, not just checklist content)

> **As of v4.0.0** (released 2026-06-17) — the biggest overhaul yet: a ground-up iPad-first UI/UX revamp (rebuilt Home, in-flight HUD, Navigation, Flight Log, Settings, onboarding), a map-first flight-plan builder, and Companion mode (iPad ↔ iPhone second screen over Wi-Fi Aware). See the repo's v4.0.0 GitHub release for the user-facing changelog.

## Build & Run

```bash
# Open in Xcode
open AeroCheck.xcodeproj

# Build: Cmd + R (requires connected iPad or simulator)
# Archive: Product → Archive

# Run scheme: AéroCheck (with accent). Tests are on a separate scheme — the app
# scheme has no test action, so a plain `build` never compiles tests.

# Preferred: wraps xcodebuild with a preflight cleanup (see the note below).
scripts/run-tests.sh                      # full suite
scripts/run-tests.sh "iPhone 17"          # another simulator
scripts/run-tests.sh "" ObstacleTests     # one class

# Equivalent raw invocation:
xcodebuild test -scheme AeroCheckTests -destination "platform=iOS Simulator,name=iPad Air 11-inch (M4)"
```

> **If a test run hangs with ZERO test cases started** — the log stops partway and it sits there —
> the cause is a stalled **build service**, not the test harness. `xcodebuild` blocks in
> `waitForBuildWithBuildLog:` waiting on `SWBBuildService`, which sits idle in `read`: a lost message
> between the two, so the build never completes and tests never begin.
>
> Fix: `killall SWBBuildService XCBBuildService` (xcodebuild spawns a fresh one), plus
> `pkill -f "AeroCheck.app/AeroCheck"` to clear leftover simulator app processes.
> `scripts/run-tests.sh` does both in its preflight.
>
> **Diagnose by sampling `xcodebuild`, not the app.** An app process left running on the simulator is
> a red herring — it is usually a leftover from a previous run, and sampling it shows an ordinary idle
> run loop, which reads convincingly like "the test bundle was never injected" when the build simply
> never finished. Quick discriminator: if the log stops growing over ~20 s and no test case has
> started, the build is stuck.
>
> Never stop a test run with `kill -9` — Ctrl-C/SIGTERM lets xcodebuild tear its own session down.

Requirements: Xcode 26 (ships the iOS 26 SDK — `CompanionConnectivityManager.swift` and
`CompanionPairingView.swift` unconditionally `import WiFiAware`, which won't compile under
an older toolchain), development team configured

**StoreKit Testing:** Use `Configuration.storekit` for subscription testing in development.

## Project Structure

```
AeroCheck/
├── AeroCheckApp.swift         # Entry point, environment injection
├── Localizable.xcstrings      # Localization strings (English, French)
├── Localization.swift         # Generated localization helpers
├── Views/
│   ├── ContentView.swift      # Root router: GroundView on the ground, FlightView in flight
│   ├── GroundView.swift       # 6.0 ground tab bar: Today · Plan (Flights | Routes | Map) · Logbook · Aircraft · Settings
│   ├── HomeView.swift         # The Today tab: logo (5-tap), next flight, START, Circuits / second action, aircraft, last flight
│   ├── FlightView.swift       # In flight: the Cockpit on iPad (see Cockpit.swift), the v4 HUD on iPhone; the Menu sheet
│   ├── Cockpit.swift          # 6.0 Cockpit pieces: CockpitPaneRule (CHECKLIST | MAP by phase), thumb button, pane picker
│   ├── DeferredItemsViews.swift # Open-items review on NEXT, deferred chip + sheet (v6.0 · B2)
│   ├── FlightLogView.swift    # The Logbook: dashboard + master/detail flight history, export/import, share cards (modes: combined/logbook/plan)
│   ├── NavigationView.swift   # The nav map: iPad kneeboard chrome (next-waypoint card, Map sheet, NOW/NEXT, MARK thumb bar), iPhone compact sheet; embedded in the Cockpit and Plan › Map
│   ├── OnboardingView.swift   # v4 redesigned first-run onboarding (replayable from Settings)
│   ├── SettingsView.swift     # Settings hub (routes into Views/Settings/* sub-pages)
│   ├── SubscriptionView.swift # Subscription / paywall UI
│   ├── FlightPlanningView.swift    # Flight-plan list (master/detail, route thumbnails, From→To)
│   ├── FlightPlanMapBuilderView.swift # Map-first route builder (live drag, smart cheapest-insertion, interactive route profile)
│   ├── FlightPlanEditorView.swift  # "Flight plan details" live editor sheet
│   ├── WaypointEditorSheet.swift   # Waypoint editing sheet
│   ├── SetAltitudesSheet.swift     # Builder: set many planned altitudes at once (fixed / terrain + clearance)
│   ├── CompanionPairingView.swift  # Companion mode pairing (Wi-Fi Aware, iOS 26+)
│   ├── CompanionFlightView.swift   # Companion viewer second-screen UI
│   ├── EventConfirmationView.swift # Flight event confirmation UI (hold-to-confirm go-around / touch-and-go / full-stop)
│   ├── AmbientCelebration.swift    # Ambient accent reveal overlay (hidden theme easter egg)
│   ├── HourMeterInputView.swift    # Engine hour meter (Hobbs/tachometer) input during start/stop
│   └── Settings/              # v4 cockpit-styled Settings sub-pages
│       ├── AboutSettingsView.swift
│       ├── AircraftSettingsView.swift
│       ├── ChecklistFlightSettingsView.swift
│       ├── CompanionSettingsView.swift
│       ├── FlightPlanningSettingsView.swift
│       ├── NavigationMapsSettingsView.swift
│       └── SyncDataSettingsView.swift
├── Models/
│   ├── AppState.swift         # Central state manager (@MainActor @Observable — NOT ObservableObject; see Architecture); decomposed via facade structs (NavigationMapState, FlightTiming, ChecklistProgress)
│   ├── Flight.swift           # Flight data + GPX/JSON export/import
│   ├── FlightPlan.swift       # Flight plan models and export
│   ├── FlightPlanManager.swift # Flight plan state management (CRUD, waypoints, route)
│   ├── Checklist.swift        # 16 flight phases with items
│   ├── ActiveChecklist.swift  # Owned, resolved checklist + speeds for the active aircraft (replaces the old global ChecklistData statics)
│   ├── Aircraft.swift         # Bundled aircraft types and metadata
│   ├── RemoteAircraft.swift   # Remote/premium aircraft API models
│   ├── WT9ChecklistData.swift # WT9 Dynamic checklist loader — reads the bundled JSON in Resources/
│   ├── FlightThread.swift     # Flight Thread: chapters, tasks, state machine (v5.0.0)
│   ├── FlightThreadManager.swift # Thread CRUD, task state, persistence, the two reminders (v5.0.0)
│   ├── Airport.swift          # Airport, AirportFrequency, and Runway data models
│   ├── Airspace.swift         # OpenAIP airspace model (CTR boundaries, frequencies, altitude limits)
│   ├── Navaid.swift           # OpenAIP navaid (VOR/DME/NDB) model, incl. magnetic declination
│   ├── Obstacle.swift         # OpenAIP vertical obstacle model (towers, masts, wind turbines)
│   ├── OpenAIPAirport.swift   # OpenAIP airport/frequency model merged into the OurAirports backbone
│   ├── ReportingPoint.swift   # OpenAIP VFR reporting-point model (mandatory/on-request)
│   └── BriefingData.swift     # Dynamic departure and approach briefing context builder
├── Services/
│   ├── LocationManager.swift       # GPS tracking (CLLocationManagerDelegate)
│   ├── FlightLauncher.swift        # Shared flight-start sequence for every entry point (buttons, widget, deep link): checklist load → guards → start → GPS tracking
│   ├── WidgetBridge.swift          # Publishes the owned-aircraft list to the home-screen widget via the App Group
│   ├── SubscriptionManager.swift   # StoreKit 2 subscription handling
│   ├── AircraftDataService.swift   # Remote aircraft/checklist fetching
│   ├── DataPersistenceManager.swift # File-based data persistence
│   ├── SyncManager.swift           # iCloud sync (CKSyncEngine)
│   ├── OfflineMapManager.swift     # ICAO chart caching for offline use
│   ├── ThreadTaskEngine.swift      # PURE rules: which admin tasks a flight deserves (v5.0.0)
│   ├── NotificationService.swift   # UNUserNotifications: close-flight-plan + prep reminders (v5.0.0)
│   ├── FlightEventDetector.swift   # Automatic detection of go-arounds, touch-and-gos, full-stop landings
│   ├── AirportDataService.swift    # OurAirports data management (download, cache, query ~40K airports)
│   ├── OpenAIPDataService.swift    # OpenAIP airspace data (download, cache, spatial queries, streaming fallback)
│   ├── OpenAIPConfig.swift         # OpenAIP API configuration and constants
│   ├── OpenAIPTileOverlay.swift    # Custom MKTileOverlay for OpenAIP map tiles
│   ├── BundledChecklistService.swift # Loading bundled (free) aircraft checklists
│   ├── WindDataService.swift       # MeteoSwiss surface wind for departure/approach briefings (CH only)
│   ├── ElevationService.swift      # Terrain elevation (swisstopo CH + Open-Meteo worldwide) for route profiles
│   ├── SwisstopoTileOverlays.swift # Consolidated swisstopo tile overlays (ICAO / Segelflug / Landeskarte / SWISSIMAGE)
│   ├── OpenAIPCacheManager.swift   # Atomic, crash-safe OpenAIP airspace cache writes
│   ├── FlightPlanExportService.swift # Nav log PDF (multi-page) / Excel, GPX route export for avionics (Dynon/Garmin)
│   ├── RouteRadioPlanner.swift     # PURE: who to talk to on each leg of a planned route (nav log Freq/C/S, remarks, Radio box)
│   ├── AltitudePlanner.swift       # PURE: bulk planned altitudes (fixed / above terrain) + per-leg clearance
│   ├── CompanionConnectivityManager.swift # Companion mode (Wi-Fi Aware, iOS 26+); kept available on 17.0 but inert below 26
│   ├── ExternalRequest.swift       # Centralized outbound HTTP request helper
│   ├── MarketingLocationProvider.swift # Simulated location for marketing/screenshot capture
│   ├── AirportDataMergeEngine.swift # Pure engine folding OpenAIP airports into the OurAirports backbone (v4.1.0)
│   ├── DataStatusManager.swift     # Per-source data freshness tracking (fresh/aging/stale/missing) (v4.1.0)
│   ├── NetworkMonitor.swift        # NWPath-derived connection/Wi-Fi/metered hints for refresh decisions (v4.1.0)
│   ├── RouteDataCalculator.swift   # Countries a planned route crosses, for trip-aware data prefetch (v4.1.0)
│   ├── OpenAIPAirportDataService.swift # OpenAIP AIRPORT data (keyless per-country GeoJSON); primary airport source (v4.1.0)
│   ├── OpenAIPNavaidDataService.swift  # OpenAIP NAVAID data (keyless per-country GeoJSON), nearest-navaid + region queries (v4.1.0)
│   ├── OpenAIPObstacleDataService.swift # OpenAIP OBSTACLE data (keyless per-country GeoJSON), region queries for map markers (v4.1.0)
│   ├── OpenAIPReportingPointDataService.swift # OpenAIP VFR REPORTING-POINT data (keyless per-country GeoJSON) (v4.1.0)
│   └── WatchConnectivityManager.swift # Apple Watch communication
├── Components/
│   ├── DesignSystem.swift     # Cockpit theme engine, semantic tokens, button styles, Settings kit (SettingsPage/Group/Row), Liquid Glass chrome
│   ├── Typography.swift       # B612 (`Font.aero`, `UIFont.aero`), `CockpitType` sizes, `CockpitTarget` touch targets (v6.0)
│   └── ChecklistView.swift    # Checklist display component
├── Shared/                    # Targets shared with Watch + Widget + Companion
│   ├── WatchConnectivityData.swift     # Watch/iOS shared data models
│   ├── CompanionConnectivityData.swift # Companion (iPad↔iPhone) shared data models + service name constant
│   ├── DesignTokens.swift              # Shared cockpit colour palette / ThemePreference
│   ├── AmbientPalette.swift            # Runtime-overridable accent palette (hidden theme)
│   └── AppLog.swift                    # Centralized `os.Logger` wrapper (see logging convention below)
├── Resources/
│   ├── wt9-dynamic-bundled.json    # Free WT9 checklist (EN) — the bundled aircraft's source of truth
│   └── wt9-dynamic-bundled-fr.json # Free WT9 checklist (FR)
└── Assets.xcassets/           # App icon, colors

AeroCheckWidget/
└── AeroCheckWidget.swift      # Home screen widgets

AeroCheckWatch/
├── AeroCheckWatchApp.swift    # Watch app entry point
├── ContentView.swift          # Watch UI
└── WatchConnectivityManager.swift # Watch-side connectivity
```

## Architecture

**State Management:** MVVM. `AppState` is `@Observable` (Observation framework, PERF-30): views hold it via `@Environment(AppState.self)` and re-render only when a property they actually READ changes — a GPS-track append no longer invalidates every screen. Bindings into it use `Bindable(appState).property`. The other managers (SubscriptionManager, LocationManager, …) remain `ObservableObject` + `@EnvironmentObject`.
- `AppState`: Central state (flight lifecycle, navigation, timing, settings, sync). Being decomposed: cohesive `@Published` clusters are merged into facade structs (`NavigationMapState`, `FlightTiming`, `ChecklistProgress`) with thin forwarding accessors so existing call sites stay reactive; pure rules are extracted into testable types (`ChecklistHighlighting`, `FlightClock`).
- `LocationManager`: GPS service with background tracking
- `SubscriptionManager`: StoreKit 2 product/subscription management
- `AircraftDataService`: Remote aircraft fetching with subscription validation
- `SyncManager`: iCloud CloudKit sync for settings and flights
- `FlightPlanManager`: Flight plan CRUD, waypoint/route management, map-builder state
- `OpenAIPDataService`: OpenAIP airspace data management (download by country/continent, tile overlay, streaming CTR fallback)
- `CompanionConnectivityManager`: Companion mode pairing + live-data push (Wi-Fi Aware). Available on iOS 17 but **inert** below 26 (all `WiFiAware`/`NetworkListener` calls gated behind `if #available(iOS 26)`); stores version-agnostic `CompanionPairedDevice` so views on 17 can hold it.
- **Theme engine:** `ThemePreference` (auto/day/sunlight/night) → resolved `CockpitThemeMode` palette
  injected as `@Environment(\.cockpitTheme)`. **Adoption is PARTIAL — see the note under Theming.**
- Views observe `AppState` via `@Environment(AppState.self)` (per-property tracking); the other managers via `@EnvironmentObject`

**Data Persistence:**
- `DataPersistenceManager`: File-based storage in Documents/iCloud
- `UserDefaults`: Settings and app state (Codable serialization)
- Local checklist caching with 24-hour expiration

**iCloud sync conflict handling (`SyncManager`):** `Flight` carries `modifiedAt` + `schemaVersion`. Inbound CloudKit records are validated on ingest (unknown schema / oversized / non-finite coordinates are rejected; numeric settings are clamped) and **merged**, not overwritten: newer `modifiedAt` wins for metadata, but append-only data (GPS track, landing counts/times) keeps the richer side, so a concurrent edit never silently drops a logbook entry. `serverRecordChanged` for a flight merges + re-queues; conflicts surface via `AppState.syncConflictNotice` (ARCH-02, SEC-17).

## Key Features

| Feature | Implementation |
|---------|----------------|
| 16 Flight Phases | `ChecklistPhase` enum in `Checklist.swift` |
| Multi-Aircraft (Bundled) | `AircraftType` enum, `WT9ChecklistData` |
| Premium Aircraft | `RemoteAircraft.swift`, `AircraftDataService` |
| Unified Flight Start | `FlightLauncher` — one start sequence shared by the buttons, widget, and deep links (checklist load → ARCH-01/entitlement/permission/active-flight guards → start → GPS) |
| Subscription System | `SubscriptionManager` (StoreKit 2), `SubscriptionView` |
| Step-by-step highlighting | `AppState.currentHighlightedItem` |
| Memory test (was Learning Mode) | Off by default since 6.0 (every check shown); on hides memorizable items. Stored as `learningMode` (inverted) |
| Ground tabs (6.0) | `GroundView` — Today · Plan · Logbook · Aircraft · Settings; `appState.groundTab` switches tabs from anywhere |
| Cockpit (6.0, iPad) | `FlightView` + `Cockpit.swift` — header, GS/ALT/TRK/NEXT strip, CHECKLIST \| MAP pane that follows the phase, 104 pt thumb bar (CHECK · DEFER · phase action; MARK on the map) |
| Deferred items (6.0) | `ChecklistProgress.deferredItems` — DEFER in a phase, or NEXT with items open (after a review sheet); follow the pilot until checked |
| Map presets (6.0) | `MapPreset` in the iPad Map sheet — Cruise / Approach / Everything |
| GPS Tracking | `LocationManager` + `GPSPoint` in Flight |
| Ground Speed Indicator | Real-time GPS ground speed in knots with color coding |
| Briefing Wind | `WindDataService` + MeteoSwiss surface stations (Switzerland only) — feeds the departure/approach briefings. Station chosen by distance AND altitude delta, not distance alone. There is deliberately **no** estimated-airspeed readout and **no** stall annunciation: the app has no pitot or AoA source, and a surface-station wind cannot describe air at altitude. |
| Navigation Mode (3.5) | `NavigationView` — 2-row bottom bar, expandable flight-plan sheet with leg timing, ground-track trend vector, FREDA cruise-check reminder; SwissTopo + OpenAIP layers |
| FREQ Panel | CURRENT / NEXT / EMERGENCY frequency model in NavigationView (OpenAIP CTR worldwide, FIS, common; OurAirports TWR fallback) |
| Offline Maps | `OfflineMapManager` for ICAO/Segelflug chart caching |
| Timing Events | Engine start, line up (+2min), landing, shutdown |
| Circuit Mode | Streamlined phases for pattern training |
| Export | GPX 1.1 (with `pc:` extensions), JSON, ZIP |
| Flight Plan GPX Export | `FlightPlanExportService` for Dynon/Garmin avionics |
| Home Screen Widgets | `AeroCheckWidget` for quick flight start; renders only owned aircraft via the App Group (`WidgetBridge`) and routes through `FlightLauncher` |
| Apple Watch App | Real-time flight data on wrist |
| iCloud Sync | Settings and flights sync across devices |
| Multi-Language | English, French (via `Localization.swift`) |
| Map-First Flight Planning | `FlightPlanMapBuilderView` + `FlightPlanManager` — live route drag, smart cheapest-insertion, auto-snap to airfields, interactive route-profile cross-section (drag-to-altitude, hold-to-add) |
| Route Profile & Conflicts | `OpenAIPDataService.airspaceProfileBlocks` + `ElevationService` — on-route airspace conflicts and terrain-clearance warnings on the route cross-section |
| Cockpit Theme Engine | `ThemePreference` (auto/day/sunlight/night) → `CockpitThemeMode`, injected as `@Environment(\.cockpitTheme)` |
| Companion Mode | `CompanionConnectivityManager` — iPad (master) ↔ iPhone (viewer) synced second screen over Wi-Fi Aware (iOS 26+) |
| Accessibility | VoiceOver labels, Dynamic Type, WCAG contrast, 44pt targets, Reduce Motion across the redesigned screens |
| Hold-to-Confirm Events | Go-Around / Touch-and-Go / Full-Stop behind a deliberate hold with brief undo (`EventConfirmationView`) |
| Flight Thread (v5.0.0) | `FlightThread` + `FlightThreadManager` + `ThreadTaskEngine` — the admin bracket around a flight (PLAN / PREPARE / FLY / CLOSE). Optional: a flight can always run without one |
| Local Notifications | `NotificationService` — two reminders only: close your flight plan (after landing, armed by the "filed" tick) and a T−24 h preparation nudge |
| Dynamic Briefings | `BriefingData` - auto-generated departure/approach briefings with airport/wind detection |
| Airport Frequencies | `AirportDataService` — FREQ panel, nearest 6 airports within **40 nm** (`NavigationView.swift`); OpenAIP is the primary source with an OurAirports TWR fallback |
| Engine Hour Logging | `HourMeterInputView` - Hobbs meter input at engine start/stop |
| Flight Event Detection | `FlightEventDetector` - automatic go-around, touch-and-go, full-stop detection |
| OpenAIP Airspace Overlay | `OpenAIPTileOverlay` + `OpenAIPDataService` - 119 countries worldwide |
| Nearby CTR Frequencies | `OpenAIPDataService.nearbyCTRs()` with streaming fallback |
| Continent-based Download | `OpenAIPDataService` - download airspace data by region |
| Airspace Conflict Warning | `OpenAIPDataService.airspacesContaining()` for altitude alerts |

## Code Patterns

### View Structure
```swift
struct SomeView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var subscriptionManager: SubscriptionManager

    var body: some View {
        ZStack {
            Color.cockpitBackground.ignoresSafeArea()
            // Content
        }
    }
}
```

### State Updates
```swift
appState.nextPhase()           // Navigate phases
appState.recordEngineStart()   // Record timing
appState.addGPSPoint(point)    // Add GPS data
```

### Localization
```swift
// Use L10n namespace for localized strings
Text(L10n.someKey)
L10n.phaseTitle(for: phase)
```

### Logging
All logging goes through `AppLog` (`Shared/AppLog.swift`, an `os.Logger` wrapper) — no raw `print()`.

### Subscription Checking
```swift
if subscriptionManager.isSubscribed {
    // Premium content
}
```

## Flight Thread (v5.0.0)

The app follows a flight through four chapters — **PLAN → PREPARE → FLY → CLOSE**. FLY is the
existing 16-phase flight and is deliberately untouched; the thread only carries the admin work that
brackets it. Every item is a check, so the metaphor is the one pilots already use.

> ⚠️ **A thread is OPTIONAL and must stay that way.** START FLIGHT works with no thread in sight, and
> a flight that ran without one ends exactly as it always did. `FlightView`'s END FLIGHT resolves the
> thread with `threadToCloseOut(flightId:planId:)` **before** `deactivateFlightPlan()` (afterwards
> there is no plan left to resolve from); `nil` means nothing below it runs. Resolving at END rather
> than linking at START is what makes a widget- or deep-link-launched flight close out correctly
> without touching `FlightLauncher`'s guard sequence.

- **`ThreadTaskEngine` is pure** — `Context` in, `[ThreadTask]` out, no services. Regeneration is
  non-destructive: tasks match on `key#subject`, so a tick survives a route edit. Auto tasks are
  ALWAYS recomputed, so a fuel row can never keep claiming a stale computation.
- **Tasks store a key, never copy.** `ThreadTaskPresentation` resolves title/hint/icon/links at
  render time, so a persisted thread is language-agnostic and wording changes need no migration.
- **The close-flight-plan reminder is the load-bearing feature.** It exists only when the pilot
  ticked "flight plan filed" (`FlightThread.hasOpenFlightPlan`) — that is what keeps circuit sessions
  and unfiled flights silent. Zurich RCC is alerted 30 min after the ETA, which is why this one is
  red, has no auto-dismiss, and carries the FIC number as its primary action.
- **Profiles:** `.full` for cross-country, `.local` for circuits (weather, DABS, logbook, debrief).
- **Reminders and links, not integrations.** skybriefing and DABS are opened, then ticked. Nothing
  here breaks when an upstream changes its interface.
- `FlightThreadManager` mirrors `FlightPlanManager` exactly (ObservableObject + `@Published`,
  injectable `defaults:` because the test host shares the app's bundle id, dirty-diffed off-main file
  writes). `context(for:profile:)` is `@MainActor` (the border test reads `CountryBoundaries.shared`);
  the `countries:` overload is `nonisolated` and is what tests drive.

## Design System

The v4 cockpit design language lives in `Components/DesignSystem.swift` + `Shared/DesignTokens.swift`.

**Theming:** The intended model is that views read the active theme via `@Environment(\.cockpitTheme)`
and use semantic tokens (`action`, `onTarget`, surfaces, text, chrome) rather than hard-coded colors.
The user picks a `ThemePreference` (auto / day / sunlight / night); `auto` resolves day vs night from
the system appearance.

> ⚠️ **Adoption is deliberate and partial — know which side of the line you are on.**
>
> **Migrated (cycle-2 P7-1):** the three in-flight surfaces — `NavigationView.swift`,
> `FlightView.swift`, `ChecklistView.swift` — read `@Environment(\.cockpitTheme)` and paint with
> semantic tokens. These are the surfaces you actually read in glare, so **Sunlight now does
> something** there.
>
> **Not migrated, on purpose:**
> - **Ground-use screens** (Home, Settings, Flight Log, planning, onboarding, paywall) still use the
>   legacy `Color` statics. Nobody reads them at 5000 ft in sunlight; migrate opportunistically.
> - **`MKMapView` delegate code** inside the `UIViewRepresentable`s (`NativeMapViewUIKit`,
>   `SwissMapView`, `FlightMiniMap`) — annotation views and overlay renderers run outside the
>   SwiftUI environment, so `@Environment` is unreachable there. Theming those means threading the
>   palette into the `Coordinator` from `updateUIView`. ~50 sites; a separate, riskier job.
>
> **Why the migration was safe:** `CockpitTheme.day` mapped 1:1 onto the legacy tokens, so the
> substitution was byte-identical in day mode and gained sunlight/night for free.
>
> **6.0 broke that on purpose for two tokens: the in-flight colour contract.** Following FAA AC 25-11B,
> the in-flight surfaces use red for warnings only, amber for cautions only, green for normal/done,
> **magenta (`route`) for the active route**, **cyan (`action`) for anything the pilot can touch**
> and white for data. Aviation gold stays the brand colour on the ground screens (legacy statics);
> in flight it read as a caution. Every other `.day` token still equals its legacy value — keep it
> that way for new tokens. Night keeps its red family (`route` is a dim rose). The map delegates
> can't read the theme: they use fixed colours (`UIColor.flownTrack`, a white ownship, magenta route).
>
> **Do NOT "fix" this by making the legacy statics theme-aware.** They already resolve through
> `AmbientPalette` (`DesignTokens.swift:17-33`) for the hidden accent, and that path needs
> `.id(ambient.revision)` at the root (`AeroCheckApp.swift`) to invalidate — which **re-creates the
> view tree and drops all transient `@State`**. Acceptable for a manual, rare toggle; not for
> `.auto` flipping to night mid-approach and resetting scroll positions and open sheets. That is
> exactly why the migration went through the environment instead.
>
> `\.isNightMode` and `\.cockpitTheme` both derive from the same `themePreference`
> (`AppState.swift:56-72`), so `isNightMode == true` exactly when the mode is `.night` — they can
> never disagree, and a site using either is consistent with one using the other.

> ⚠️ **`.preferredColorScheme(.dark)` reaches the whole WINDOW from an embedded view.** Use it only
> on a view presented on its own (cover, sheet). A view embedded in a tab, or pushed, inherits the
> root's subtree-local `.environment(\.colorScheme, .dark)` and must not set it: when the 6.0 tab bar
> embedded FlightLog/Settings/Routes/the map, their modifier darkened the window, the root could no
> longer read the device's appearance, and **Auto resolved to night in daylight**. The pattern is
> `.preferredColorScheme(isEmbedded ? nil : .dark)` (see `FlightLogView`, `SettingsView`,
> `FlightPlanningView`, `NavigationMapView`).

Liquid Glass chrome (`DesignSystem.floatingChromeBackground/Circle`) is iOS 26+ with a
`.regularMaterial` fallback on 17.0.

**Legacy color helpers** (still used as token inputs): `.cockpitBackground`, `.aviationGold` (primary accent), `.aviationGreen` / `.aviationRed` (status).

**Settings kit:** reusable `SettingsPage` / `SettingsGroup` / `Settings*Row` components — use these for any settings UI.

**Typography (6.0):** B612 everywhere in the app (`Font.aero` mirrors `Font.system`; widget, Watch and the nav log PDF keep the system font). Anything read in flight uses a `CockpitType` size (label 20, row 24, response 28, button 30, item 42, value 48) and a `CockpitTarget` (thumb 104, control 64) — the kneeboard yardsticks from the 2026-09 review. Monospaced fonts for checklist items; 44pt minimum touch targets elsewhere. **Dynamic Type:** ground-use screens (planning, settings, onboarding, paywall) use `.scaledFont(size:weight:design:relativeTo:)` from `DesignSystem.swift` (a `@ScaledMetric` wrapper) instead of fixed `.font(.system(size:))`; in-flight HUD instrumentation intentionally keeps fixed sizes for cockpit legibility (UX-24). Adoption is in progress — Flight Log, Home and the in-flight surfaces still use fixed sizes.

**Custom `ButtonStyle` + `.disabled()`:** a style must read `@Environment(\.isEnabled)` itself to dim when disabled (Primary/SecondaryButtonStyle do).

**Accessibility:** VoiceOver labels, Dynamic Type, WCAG contrast, 44pt targets and Reduce Motion are first-class across the redesigned screens — preserve them when editing views.

## Supported Aircraft

### Bundled (Free)
- **F-HVXA** - Aerospool WT9 Dynamic (Checklist v2.1e)

### Premium (Subscription) — 13 aircraft (14 total) delivered via the v3 API
Piper Archer II PA-28-181 (HB-PFA), PA28-161 Warrior II (HB-PNL), PA28-161 Piper Cadet (HB-OJI),
PA28-236 Dakota II (HB-PMP), PA32R-301 Saratoga II (HB-PJE), PA18-150 Super Cub (HB-ORV),
Piper L4 (HB-OKN), Robin DR400/140B (HB-KFD), Robin DR400/140B (HB-KFO, HB-KFP), Robin DR401/140B (HB-KOJ),
CAP10-C (HB-SAX), Pipistrel VELIS Electro SW128 (HB-SYI), Sportcruiser PS-28 (F-HPSA).

Sourced from three flying clubs (Groupe de Vol à Moteur de Porrentruy / GVMP, Lausanne Aéroclub, and
Groupe de Vol à Moteur Neuchâtel / GVMN), surfaced via the v3 `aeroclub` field. Some are FR- or EN-only;
most ship EN+FR. The app fetches the list and checklists at runtime via `AircraftDataService` — see the
ecosystem `CLAUDE.md` for the full roster.

## API Integration

**Base URL:** `https://api.aerocheck.app/api/v3`

**Key Endpoints:**
- `POST /subscription/verify` - Validate Apple subscription (JWS token)
- `GET /subscription/status` - Get subscription status
- `GET /aircraft/available` - List all aircraft
- `GET /aircraft/:id/checklist` - Get full checklist (auth for premium)
- `GET /aircraft/:id/version` - Get current checklist version (used by the app's update-check flow)
- `GET /aircraft/:id/history` - Get version history (no auth)
- `GET /aircraft/aeroclubs` - List aeroclubs sourcing the aircraft roster

## Checklist Phases

1. Preflight → 2. Before Engine Start → 3. Engine Start → 4. After Engine Start →
5. Taxi → 6. Run Up → 7. Before Departure → 8. Line Up → 9. Climb →
10. Cruise → 11. Descent → 12. Approach → 13. Landing →
14. After Landing → 15. Engine Shutdown → 16. At the Hangar

## Export Formats

**GPX:** Standard format with custom `pc:` namespace for flight metadata
**JSON:** Full flight data with ISO8601 dates
**ZIP:** Batch export of multiple flights
**GPX Routes:** Navigation plan export for MFDs (Dynon, Garmin)
**Nav log (PDF A4/A5, Excel):** each row is the leg ENDING at that waypoint (the Nav view's
`legArriving(at:)` convention); the route is never truncated — it flows onto further sheets with the
column headers repeated, and fuel · times · debriefing move to the last sheet when it doesn't fit.
Freq/C/S, airspace remarks and the Radio box come from `RouteRadioPlanner` (OpenAIP airspace at the
planned altitude, else the Swiss FIS sector; aerodromes matched by position). Wind/GS print what the
EET was computed with (`FlightPlan.legPlanning(from:)`).

**GPX import — what `<ele>` means depends on the creator.** AeroCheck's own files: planned altitude.
SkyDemon: terrain; the plan is `<skd:level>` (level of the leg starting at the point, stored on the
waypoint where that leg ends; endpoint aerodromes keep field elevation), idents in `<sym>`. Any other
source: `<ele>` is not read as a plan — the builder offers "Set altitudes" instead.

## Testing Focus

- Phase navigation (forward, back, skip)
- Circuit mode (skip Cruise/Descent, full-stop tracking)
- GPS recording at configured intervals
- Timing event recording (engine start, line up, landing, shutdown)
- Flight persistence and export/import
- Subscription purchase/restore flow (use Configuration.storekit)
- Premium aircraft download and caching
- iCloud sync (settings, flights), conflict merge
- Apple Watch connectivity (live data, Circuit-mode next phase)
- Companion mode pairing + live-data sync (iOS 26+); verify it stays inert/crash-free below 26
- Theme engine (auto/day/sunlight/night) and accessibility (VoiceOver, Dynamic Type, contrast, 44pt, Reduce Motion)
- Map-first flight-plan builder (route drag, smart insert, route-profile conflicts/terrain)
- Localization (English/French)

## Permissions (Info.plist)

- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`
- `NSMotionUsageDescription` — CoreMotion `CMAltimeter`, started with GPS tracking by
  `LocationManager.beginTrackingNow()` (barometric altitude for the flight-event detector)
- `NSPhotoLibraryAddUsageDescription` — saving flight-log share cards to Photos
- `UIBackgroundModes: [location, remote-notification]`

> ⚠️ **A missing TCC usage description is a crash, not a denied permission.** iOS terminates the
> process, uncatchably, the first time the protected API is called. That is what 4.4.0 shipped:
> `BarometricAltitudeService` (CoreMotion) went in without `NSMotionUsageDescription`, so every
> barometer-equipped device — every iPhone since the 6, every cellular iPad — died on the first
> tap of **START FLIGHT**. It survived review because the simulator has **no barometer**:
> `CMAltimeter.isRelativeAltitudeAvailable()` is false there, `start()` returns early, and the
> protected call is never reached in the simulator or in the test suite.
>
> The keys are locked by `AeroCheckTests/PrivacyUsageDescriptionTests.swift` (the TCC sibling of
> `CompanionServiceContractTests`, which guards the same class of Info.plist-induced flight-start
> crash for Wi-Fi Aware). **Adding any privacy-protected API means adding its key and a row there
> in the same change.** Note the app target uses `INFOPLIST_FILE = AeroCheck/Info.plist` *and*
> `GENERATE_INFOPLIST_FILE = YES`, so a key may live in either the file or an `INFOPLIST_KEY_*`
> build setting — the location keys are build settings, the rest are in the file.

## Entitlements

- In-App Purchase
- iCloud (CloudKit)
- App Groups (`group.com.fetzu.aerocheck`) — shares the owned-aircraft list with the widget (`WidgetBridge` → `WidgetSharedData`)
- Wi-Fi Aware (`com.apple.developer.wifi-aware`, Publish + Subscribe) — Companion mode (iOS 26+)
- `aps-environment` (push notifications)

## Performance Notes

- **GPS accuracy:** Default is `kCLLocationAccuracyBest`; the user's `GPSPriority` setting drops it to `kCLLocationAccuracyNearestTenMeters` in Battery Saver (`LocationManager.applyGPSPriority`)
- **Distance filter (dynamic):** ground mode ~5 m (taxi/block-on detail), flight mode 50 m (Precision) / 100 m (Battery Saver) — see `LocationManager.setGroundMode`
- **Signal check timer:** 5-second interval
- **Airport data:** Lazy-loaded on demand (flight start or map overlay enabled), not at app startup
- **Wind data:** Automatically paused when app backgrounds, resumed on foreground during active flight
- **HomeView item count:** Cached to avoid disk I/O on every render

## Localization Patterns

- Aviation abbreviations (kt, ft, NM, MSL, GPS, FREQ, etc.) are intentionally NOT translated per ICAO standards
- **One vocabulary (6.0 · P8):** *Flight* = one take-off to landing, planned (Plan) or flown (Logbook);
  *Trip* = several flights in a row; *Route* = a reusable path with no date; *Nav log* = the printout;
  *ATC flight plan* = what you file and close with ATC. Never "flight plan" on its own. The printed
  nav log keeps its form title ("AVIS DE VOL – PLAN DE VOL DE NAVIGATION"): it mirrors the paper form.
- All user-facing strings should use `L10n.*` keys from `Localization.swift`
- `Localizable.xcstrings` contains EN/FR translations

## Settings Organization

`SettingsView` is a v4 hub that routes into dedicated sub-pages under `Views/Settings/`, each built with the shared Settings kit (`SettingsPage`/`SettingsGroup`/`Settings*Row`):
1. **Aircraft** (`AircraftSettingsView`) - aircraft selection, subscription/premium management
2. **Checklist & Flight** (`ChecklistFlightSettingsView`) - memory test, checklist language, engine hours, UTC, theme + sunlight

   Retired in 6.0 (review P7) — the values are still decoded and synced for older builds, but no longer read:
   circuit mode (CIRCUITS is always on Today), keep screen on (on exactly while a flight runs), step-by-step
   highlighting (always on; settings schema 4 migrates it back on once).
3. **Navigation & Maps** (`NavigationMapsSettingsView`) - map layers, offline maps, OpenAIP airspace overlay & data, airport data, wind data, online airspace streaming, theme picker
4. **Flight Planning** (`FlightPlanningSettingsView`) - route-builder and export preferences
5. **Sync & Data** (`SyncDataSettingsView`) - iCloud sync, GPS recording settings, flight-count/GPS-point stats
6. **Data Storage** (`DataStorageSettingsView`) - external-data freshness (per-source status, refresh) and offline storage management (v4.1.0)
7. **Companion** (`CompanionSettingsView`) - Companion-mode pairing (Wi-Fi Aware, iOS 26+)
8. **About** (`AboutSettingsView`) - version info, onboarding replay, developer options (tap version 5×), debug tools

## Development Notes

### Subscription Testing
1. Use `Configuration.storekit` in Xcode scheme
2. Developer Options accessible by tapping version 5 times in Settings
3. Debug log viewer available in Developer Options

### Adding New Aircraft
1. Add the checklist JSON to the `AeroCheck-checklists` repo (`checklists/{id}/current/`)
2. Bump the server's `checklists` submodule pointer and redeploy (auto-discovery — no server code edit)
3. App fetches the new aircraft automatically via `AircraftDataService`

### Localization
1. Add keys to `Localizable.xcstrings`
2. Regenerate `Localization.swift` if using code generation
3. Use `L10n.key` in views

### Secrets / API keys (OpenAIP)

Secrets are **not** hard-coded in tracked source. They flow:

`Secrets.xcconfig` (untracked) → `OPENAIP_API_KEY` build setting → `OpenAIPAPIKey` in
`AeroCheck/Info.plist` (`$(OPENAIP_API_KEY)`) → `OpenAIPConfig.apiKey`
(`Bundle.main.object(forInfoDictionaryKey:)`).

- `Config.xcconfig` (tracked) is the app target's base configuration. It defines an empty
  `OPENAIP_API_KEY` default and `#include?`s the untracked `Secrets.xcconfig`, which overrides it.
- **First-time / fresh checkout:** `cp Secrets.example.xcconfig Secrets.xcconfig` and paste your
  OpenAIP key (register/rotate at https://www.openaip.net/). `Secrets.xcconfig` is gitignored.
- An **empty** key degrades gracefully — OpenAIP tile/CTR requests 401 and the airspace overlay
  doesn't render; the app does not crash. So a checkout without the key still builds and runs.
- **CI (Xcode Cloud):** builds come from a fresh GitHub clone, so `Secrets.xcconfig` is absent.
  Define `OPENAIP_API_KEY` as a *secret* environment variable in the Xcode Cloud workflow;
  `ci_scripts/ci_post_clone.sh` writes `Secrets.xcconfig` from it after clone. GitHub Actions
  runs only CodeQL (`codeql.yml`) — no key needed there.
- A client-embedded key is inherently extractable from the binary/traffic. The protections that
  matter are: (a) keep it out of *tracked* (esp. *public*) source, and (b) rotate if it leaks.
  Do **not** reintroduce a literal key in source.

### Versioning and build numbers

Two fields, two different jobs. Conflating them is what `CURRENT_PROJECT_VERSION = 0.1` was.

| Build setting | Info.plist key | What it is | Who sets it |
|---|---|---|---|
| `MARKETING_VERSION` | `CFBundleShortVersionString` | SemVer, human-facing (`5.0.0`) | **You**, by hand, once per release |
| `CURRENT_PROJECT_VERSION` | `CFBundleVersion` | Not a version: an opaque token whose only contract is that it increases | **CI**, never by hand |

- **The build number comes from Xcode Cloud.** `ci_scripts/ci_pre_xcodebuild.sh` writes
  `CI_BUILD_NUMBER` into every `CURRENT_PROJECT_VERSION` occurrence in `project.pbxproj`. Outside
  Xcode Cloud the script is a no-op, so local builds keep the checked-in default and still build.
- **It is never reset between releases.** Resetting is allowed by App Store Connect but buys
  nothing and sets a trap: upload 5.0.0 build 3, ship 5.0.1 as build 1, then need another 5.0.0
  build and you have to remember where that train was. Monotonic forever means the question never
  comes up. (The counter was at 307 when this was wired up, in Sept 2026.)
- **The checked-in default is `1`**, deliberately not a plausible upload number: only CI uploads, so
  a local archive that reached App Store Connect should look obviously wrong.

> **Only ONE Xcode Cloud workflow may upload.** `CI_BUILD_NUMBER` is per-workflow and each new
> workflow starts its own count at 1, which regresses the build number and gets the upload refused.

**Why the script rewrites `project.pbxproj` instead of using an xcconfig:** `Config.xcconfig` is the
base configuration of the **app target only**. Injecting the number there would bump the app and
leave `AéroCheckWidgetExtension` and `AéroCheckWatch` behind, and an embedded bundle whose
`CFBundleVersion` does not match its host app is refused at upload. Rewriting every occurrence
covers all three shipping targets, and covers a target added later without anyone remembering the
script exists. (`agvtool new-version -all` is the usual answer and does **not** apply here:
`VERSIONING_SYSTEM` is not `apple-generic`.)

**Cutting a release:**
1. Bump `MARKETING_VERSION` in all 8 build configurations (`sed -i '' -E 's/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = X.Y.Z;/g' AeroCheck.xcodeproj/project.pbxproj`). Leave `CURRENT_PROJECT_VERSION` alone.
2. Tag `X.Y.Z` on `main` and publish the GitHub release. That fires the website rebuild dispatcher, so
   aerocheck.app/changelog picks it up on its own.
3. In the Xcode Cloud log, check the line `ci_pre_xcodebuild: build number N written to 8 build
   configurations`. **If that count is not 8, a target has stopped being covered** and the upload
   will be refused for a version mismatch.

### Re-enabling heliports (rotorcraft support)
The flight-plan builder (search + map) is filtered to fixed-wing sites only — heliports, seaplane
bases, balloonports and closed fields are hidden so airplane route building stays uncluttered. The
filter is the single set `AirportType.fixedWing` in `Models/Airport.swift`
(`[.largeAirport, .mediumAirport, .smallAirport]`). To surface heliports (e.g. if the app ever
supports helicopters), add `.heliport` (and/or `.seaplaneBase`) to that set — both
`AirportDataService.searchAirports(types:)` and the builder's map query
(`FlightPlanMapBuilderView.scheduleAirportUpdate`) consume it, so one edit re-enables them everywhere.
