# CLAUDE.md - AéroCheck Project

## Project Overview

iPad app for pilot students flying the WT9 Dynamic aircraft. Guides pilots through flight checklists while recording GPS tracks and flight data.

- **Target:** iPadOS 17.0+ (iPad Air 11" and larger)
- **Tech:** Swift 5.9+, SwiftUI, CoreLocation, MapKit
- **Theme:** Dark cockpit-optimized UI with aviation colors

## Build & Run

```bash
# Open in Xcode
open AeroCheck.xcodeproj

# Build: Cmd + R (requires connected iPad or simulator)
# Archive: Product → Archive
```

Requirements: Xcode 15.0+, development team configured

## Project Structure

```
AeroCheck/
├── AeroCheckApp.swift         # Entry point, environment injection
├── Views/
│   ├── ContentView.swift      # Root router (home vs flight)
│   ├── HomeView.swift         # Start screen
│   ├── FlightView.swift       # Main checklist UI during flight
│   ├── FlightLogView.swift    # Flight history, export/import
│   └── SettingsView.swift     # App configuration
├── Models/
│   ├── AppState.swift         # Central state manager (@MainActor ObservableObject)
│   ├── Flight.swift           # Flight data + GPX/JSON export/import
│   └── Checklist.swift        # 16 flight phases with items
├── Services/
│   └── LocationManager.swift  # GPS tracking (CLLocationManagerDelegate)
├── Components/
│   ├── DesignSystem.swift     # Colors, fonts, button styles
│   └── ChecklistView.swift    # Checklist display component
└── Assets.xcassets/           # App icon, colors
```

## Architecture

**State Management:** MVVM with `@EnvironmentObject` injection
- `AppState`: Central state (flight lifecycle, navigation, timing, settings)
- `LocationManager`: GPS service with background tracking
- Views observe state via `@EnvironmentObject`

**Data Persistence:** UserDefaults with Codable serialization

## Key Features

| Feature | Implementation |
|---------|----------------|
| 16 Flight Phases | `ChecklistPhase` enum in `Checklist.swift` |
| Step-by-step highlighting | `AppState.currentHighlightedItem` |
| Learning Mode | Hides memorizable items |
| GPS Tracking | `LocationManager` + `GPSPoint` in Flight |
| Speed Indicator | Real-time GPS speed in knots with color coding |
| Timing Events | Engine start, line up (+2min), landing, shutdown |
| Export | GPX 1.1 (with `pc:` extensions), JSON, ZIP |

## Code Patterns

### View Structure
```swift
struct SomeView: View {
    @EnvironmentObject var appState: AppState

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

## Design System

**Colors** (in `DesignSystem.swift`):
- `.cockpitBackground` - Dark base (0.08, 0.08, 0.1)
- `.aviationGold` - Primary accent
- `.aviationGreen` / `.aviationRed` - Status indicators

**Typography**: Monospaced fonts for checklist items, large touch targets

## Checklist Phases

1. Preflight → 2. Before Engine Start → 3. Engine Start → 4. After Engine Start →
5. Taxi → 6. Run Up → 7. Before Departure → 8. Takeoff → 9. Climb →
10. Cruise → 11. Descent → 12. Approach → 13. After Landing →
14. Parking → 15. Engine Shutdown → 16. At the Hangar

## Export Formats

**GPX:** Standard format with custom `pc:` namespace for flight metadata
**JSON:** Full flight data with ISO8601 dates
**ZIP:** Batch export of multiple flights

## Testing Focus

- Phase navigation (forward, back, skip)
- GPS recording at configured intervals
- Timing event recording (engine start, line up, landing, shutdown)
- Flight persistence and export/import
- Dark theme and large button accessibility

## Permissions (Info.plist)

- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`
- `UIBackgroundModes: location`
