# CLAUDE.md - AeroCheck Project

## Project Overview

iPhone/iPad app for pilot students. Guides pilots through flight checklists while recording GPS tracks and flight data. Supports multiple aircraft with a freemium model: free bundled aircraft (WT9 Dynamic) and premium aircraft via subscription.

- **Target:** iOS/iPadOS 17.0+ (iPhone and iPad, optimized for iPad Air 11" and larger)
- **Tech:** Swift 5.9+, SwiftUI, CoreLocation, MapKit, WidgetKit, StoreKit 2, CloudKit
- **Theme:** Dark cockpit-optimized UI with aviation colors
- **Languages:** English, French (multi-language support)

## Build & Run

```bash
# Open in Xcode
open AeroCheck.xcodeproj

# Build: Cmd + R (requires connected iPad or simulator)
# Archive: Product → Archive
```

Requirements: Xcode 15.0+, development team configured

**StoreKit Testing:** Use `Configuration.storekit` for subscription testing in development.

## Project Structure

```
AeroCheck/
├── AeroCheckApp.swift         # Entry point, environment injection
├── Localizable.xcstrings      # Localization strings (English, French)
├── Localization.swift         # Generated localization helpers
├── Views/
│   ├── ContentView.swift      # Root router (home vs flight)
│   ├── HomeView.swift         # Aircraft carousel, quick start
│   ├── FlightView.swift       # Main checklist UI during flight
│   ├── FlightLogView.swift    # Flight history, export/import
│   ├── NavigationView.swift   # Full-screen map with Swiss layers + frequency drawer
│   ├── SettingsView.swift     # App configuration, premium aircraft management
│   ├── SubscriptionView.swift # Subscription purchase UI
│   ├── FlightPlanningView.swift    # Flight plan list (Beta)
│   ├── FlightPlanEditorView.swift  # Tabular flight plan editor (Beta)
│   ├── WaypointEditorSheet.swift   # Waypoint editing sheet (Beta)
│   ├── FlightPlanOverlayView.swift # In-flight HUD overlay (Beta)
│   └── TerrainProfileView.swift    # Terrain elevation display (Beta)
├── Models/
│   ├── AppState.swift         # Central state manager (@MainActor ObservableObject)
│   ├── Flight.swift           # Flight data + GPX/JSON export/import
│   ├── FlightPlan.swift       # Flight plan models and export (Beta)
│   ├── FlightPlanManager.swift # Flight plan state management (Beta)
│   ├── Checklist.swift        # 16 flight phases with items
│   ├── Aircraft.swift         # Bundled aircraft types and metadata
│   ├── RemoteAircraft.swift   # Remote/premium aircraft API models
│   └── WT9ChecklistData.swift # WT9 Dynamic checklist data (bundled)
├── Services/
│   ├── LocationManager.swift       # GPS tracking (CLLocationManagerDelegate)
│   ├── SubscriptionManager.swift   # StoreKit 2 subscription handling
│   ├── AircraftDataService.swift   # Remote aircraft/checklist fetching
│   ├── DataPersistenceManager.swift # File-based data persistence
│   ├── SyncManager.swift           # iCloud sync (CKSyncEngine)
│   ├── OfflineMapManager.swift     # ICAO chart caching for offline use
│   ├── WindDataService.swift       # MeteoSwiss wind data (experimental)
│   ├── ElevationService.swift      # Terrain elevation from swisstopo (Beta)
│   ├── FlightPlanExportService.swift # GPX route export for avionics (Beta)
│   └── WatchConnectivityManager.swift # Apple Watch communication
├── Components/
│   ├── DesignSystem.swift     # Colors, fonts, button styles
│   └── ChecklistView.swift    # Checklist display component
├── Shared/
│   └── WatchConnectivityData.swift # Watch/iOS shared data models
└── Assets.xcassets/           # App icon, colors

AeroCheckWidget/
└── AeroCheckWidget.swift      # Home screen widgets

AeroCheckWatch/
├── AeroCheckWatchApp.swift    # Watch app entry point
├── ContentView.swift          # Watch UI
└── WatchConnectivityManager.swift # Watch-side connectivity
```

## Architecture

**State Management:** MVVM with `@EnvironmentObject` injection
- `AppState`: Central state (flight lifecycle, navigation, timing, settings, sync)
- `LocationManager`: GPS service with background tracking
- `SubscriptionManager`: StoreKit 2 product/subscription management
- `AircraftDataService`: Remote aircraft fetching with subscription validation
- `SyncManager`: iCloud CloudKit sync for settings and flights
- `FlightPlanManager`: Flight plan CRUD, waypoint management (Beta)
- Views observe state via `@EnvironmentObject`

**Data Persistence:**
- `DataPersistenceManager`: File-based storage in Documents/iCloud
- `UserDefaults`: Settings and app state (Codable serialization)
- Local checklist caching with 24-hour expiration

## Key Features

| Feature | Implementation |
|---------|----------------|
| 16 Flight Phases | `ChecklistPhase` enum in `Checklist.swift` |
| Multi-Aircraft (Bundled) | `AircraftType` enum, `WT9ChecklistData` |
| Premium Aircraft | `RemoteAircraft.swift`, `AircraftDataService` |
| Subscription System | `SubscriptionManager` (StoreKit 2), `SubscriptionView` |
| Step-by-step highlighting | `AppState.currentHighlightedItem` |
| Learning Mode | Hides memorizable items |
| GPS Tracking | `LocationManager` + `GPSPoint` in Flight |
| Ground Speed Indicator | Real-time GPS ground speed in knots with color coding |
| Estimated Airspeed | `WindDataService` + MeteoSwiss API (experimental, Switzerland only) |
| Navigation Mode | `NavigationView` with SwissTopo layers |
| Radio Frequencies | Frequency drawer in NavigationView (Swiss CTR, FIS, common) |
| Offline Maps | `OfflineMapManager` for ICAO/Segelflug chart caching |
| Timing Events | Engine start, line up (+2min), landing, shutdown |
| Circuit Mode | Streamlined phases for pattern training |
| Export | GPX 1.1 (with `pc:` extensions), JSON, ZIP |
| Flight Plan GPX Export | `FlightPlanExportService` for Dynon/Garmin avionics (Beta) |
| Home Screen Widgets | `AeroCheckWidget` for quick flight start |
| Apple Watch App | Real-time flight data on wrist |
| iCloud Sync | Settings and flights sync across devices |
| Multi-Language | English, French (via `Localization.swift`) |
| Flight Planning (Beta) | `FlightPlanManager` + waypoint routes, terrain profile, in-flight overlay |

## Code Patterns

### View Structure
```swift
struct SomeView: View {
    @EnvironmentObject var appState: AppState
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

### Subscription Checking
```swift
if subscriptionManager.isSubscribed {
    // Premium content
}
```

## Design System

**Colors** (in `DesignSystem.swift`):
- `.cockpitBackground` - Dark base (0.08, 0.08, 0.1)
- `.aviationGold` - Primary accent
- `.aviationGreen` / `.aviationRed` - Status indicators

**Typography**: Monospaced fonts for checklist items, large touch targets

## Supported Aircraft

### Bundled (Free)
- **F-HVXA** - WT9 Dynamic (Checklist v2.1e)

### Premium (Subscription)
- **HB-PFA** - Piper Archer II PA-28-181 (via API)
- Additional aircraft available through subscription

## API Integration

**Base URL:** `https://api.aerocheck.app/api/v2`

**Key Endpoints:**
- `POST /subscription/verify` - Validate Apple subscription (JWS token)
- `GET /subscription/status` - Get subscription status
- `GET /aircraft/available` - List all aircraft
- `GET /aircraft/:id/checklist` - Get full checklist (auth for premium)

## Checklist Phases

1. Preflight → 2. Before Engine Start → 3. Engine Start → 4. After Engine Start →
5. Taxi → 6. Run Up → 7. Before Departure → 8. Line Up → 9. Climb →
10. Cruise → 11. Descent → 12. Approach → 13. Landing →
14. After Landing → 15. Engine Shutdown → 16. At the Hangar

## Export Formats

**GPX:** Standard format with custom `pc:` namespace for flight metadata
**JSON:** Full flight data with ISO8601 dates
**ZIP:** Batch export of multiple flights
**GPX Routes (Beta):** Navigation plan export for MFDs (Dynon, Garmin)

## Testing Focus

- Phase navigation (forward, back, skip)
- Circuit mode (skip Cruise/Descent, full-stop tracking)
- GPS recording at configured intervals
- Timing event recording (engine start, line up, landing, shutdown)
- Flight persistence and export/import
- Subscription purchase/restore flow (use Configuration.storekit)
- Premium aircraft download and caching
- iCloud sync (settings, flights)
- Apple Watch connectivity
- Dark theme and large button accessibility
- Localization (English/French)

## Permissions (Info.plist)

- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`
- `UIBackgroundModes: location`

## Entitlements

- In-App Purchase
- iCloud (CloudKit)
- App Groups (for Widget)

## Development Notes

### Subscription Testing
1. Use `Configuration.storekit` in Xcode scheme
2. Developer Options accessible by tapping version 5 times in Settings
3. Debug log viewer available in Developer Options

### Adding New Aircraft
1. Create checklist JSON on server (AeroCheck-server)
2. Update aircraft registry on server
3. App will fetch automatically via `AircraftDataService`

### Localization
1. Add keys to `Localizable.xcstrings`
2. Regenerate `Localization.swift` if using code generation
3. Use `L10n.key` in views
