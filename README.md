__IMPORTANT CAVEAT: This application is provided solely for training and pedagogical purposes; its information is not guaranteed for accuracy and must not be used for operational decision-making. Always rely on the official Aircraft Flight Manual (AFM) and approved checklists when operating an aircraft.__

_NOTE: This app has been entirely vibe coded. If you hate that, feel free to close your browser window in disgust and not use it._

# AéroCheck

![Platform](https://img.shields.io/badge/Platform-i(Pad)OS%2017%2B-blue)
![Devices](https://img.shields.io/badge/Devices-iPhone%20%7C%20iPad-green)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-red)

An iPad-first application for students and licensed pilots. Works on both iPhone and iPad. This app guides pilots through all checklists during a flight, from preflight to shutdown, while recording GPS tracks and flight data.

> **New in 4.0** — the biggest overhaul yet: a ground-up, iPad-first redesign with a cockpit-style in-flight HUD, a selectable theme engine (auto / day / sunlight / night), a map-first flight-plan builder, **Companion mode** (use an iPhone as a synced second screen for your iPad over Wi-Fi Aware, iOS 26+), an accessibility pass, and full French localization. See the [4.0.0 release notes](https://github.com/fetzu/AeroCheck/releases/tag/4.0.0).

## Open Source with Premium Content

AéroCheck is open source under the MIT License. The app includes:

- **Free aircraft** (bundled with the app):
  - WT9 Dynamic (F-HVXA)

- **Premium aircraft** (requires AeroCheck Pro subscription):
  - 13 aircraft delivered via the AeroCheck API — Piper (Archer II, Warrior II, Cadet, Dakota II, Saratoga II, Super Cub, L4), Robin DR400 (two variants) & DR401, CAP10-C, Pipistrel VELIS Electro and Sportcruiser PS-28
  - Sourced from three Swiss flying clubs (Groupe de Vol à Moteur de Porrentruy, Lausanne Aéroclub, and Groupe de Vol à Moteur Neuchâtel)
  - Automatic updates when checklists change
  - Offline access after initial download

### Subscription Options

- **Monthly**: Access to all premium aircraft checklists
- **Yearly**: Same access with a 30% discount

All subscription payments are handled securely through the Apple App Store. See the [API Server](../AeroCheck-server) for self-hosting options.

## Supported Aircraft

**Free (bundled)**
- **F-HVXA** - Aerospool WT9 Dynamic - Free

**Premium (AeroCheck Pro)** — 13 aircraft delivered via the API:

| Registration | Aircraft | Club |
|--------------|----------|------|
| HB-PFA | Piper Archer II PA-28-181 | GVMP Porrentruy |
| F-HPSA | Sportcruiser PS-28 | GVMP Porrentruy |
| HB-PNL | Piper PA28-161 Warrior II | Lausanne Aéroclub |
| HB-OJI | PA28-161 Piper Cadet | Lausanne Aéroclub |
| HB-PMP | Piper PA28-236 Dakota II | Lausanne Aéroclub |
| HB-PJE | Piper PA32R-301 Saratoga II | Lausanne Aéroclub |
| HB-ORV | Piper PA18-150 Super Cub | Lausanne Aéroclub |
| HB-OKN | Piper L4 | Lausanne Aéroclub |
| HB-KFD | Robin DR400/140B | Lausanne Aéroclub |
| HB-KOJ | Robin DR401/140B | Lausanne Aéroclub |
| HB-SAX | CAP10-C | Lausanne Aéroclub |
| HB-SYI | Pipistrel VELIS Electro SW128 | Lausanne Aéroclub |
| HB-KFO | Robin DR400/140B | GVMN Neuchâtel |
| HB-KFP | Robin DR400/140B | GVMN Neuchâtel |

Checklists, speeds and limits adapt automatically to the selected aircraft. Some aircraft are French- or English-only; most ship in both languages.

## Features

### ✈️ Multi-Aircraft Checklist System
- **WT9 Dynamic bundled free**, additional aircraft via AeroCheck Pro subscription
- All 16 flight phases from official checklists
- Aircraft selection in Settings - checklists, speeds, and limits adapt automatically
- Checklists displayed exactly as in the official documentation
- Easy navigation between phases
- Quick phase selector for jumping to any checklist
- Speed reference card with aircraft-specific speeds always accessible
- **Step-by-Step Highlighting**: Items highlighted one at a time; tap anywhere in the checklist area to advance
- **Smart completion**: When all items are checked, the NEXT button pulses to draw attention
- **Learning Mode**: Toggle to show all checks for studying, or hide memorizable checks to test memory
- **Circuit Mode**: Streamlined workflow for pattern training - skips irrelevant phases (Cruise, Descent) and tracks full-stop landings

### 🗺️ Navigation Mode
- Full-screen map with real-time aircraft position and track
- **Multiple map layers**:
  - Apple Maps (Standard and Satellite)
  - Swiss ICAO Chart (1:500,000) from SwissTopo
  - Segelflugkarte (1:300,000) - seamless switch at higher zoom
  - Swiss Landeskarten (national map)
  - SWISSIMAGE (aerial imagery)
- **Two-row bottom bar** with the live instrument readout (speed, altitude, heading, time) and a centered VFR leg chronometer
- **Expandable flight-plan sheet**: pull up the active route to see leg-by-leg timing (FROM → TO), distances and estimated times; go back a leg, or mark the current waypoint
- **Ground-track trend vector**: a projected track line with 1/2/5-minute graduations
- **FREDA cruise-check reminder** during the cruise phase
- **FREQ panel** (`CURRENT / NEXT / EMERGENCY`): nearby controlled-airspace and area frequencies organised by where you are and where you're heading (OpenAIP worldwide; OurAirports TWR fallback)
- GPS status card, scale bar with accurate distance measurement
- **Liquid Glass map controls** on iOS 26 (material fallback on iOS 17)
- **Offline maps**: Download Swiss ICAO Chart (~100 MB) and/or Segelflugkarte (~150 MB) for offline navigation

### 🧭 Map-First Flight Planning
- **Build routes directly on the map**: drag a waypoint to move it, drag the route line to insert one, and release near an airfield to **auto-snap** (name and frequency filled in automatically)
- **Smart "cheapest insertion"** places a dropped waypoint into the leg that adds the least detour
- **From → To bar** and **route thumbnails** on the plan list, with one-tap Activate
- **Interactive route profile**: a terrain silhouette with your planned-altitude line — drag a point to set its altitude, hold to add one
- **On-route airspace conflicts** and **terrain-clearance** warnings update live as you reshape the route. When a ceiling/floor is given as AGL/FL or a leg has no planned altitude, the warning is flagged "verify vertical separation" rather than implying you're clear; a green "no conflicts" only shows when airspace data is actually loaded
- **GPX route export** for Dynon/Garmin avionics

### 📍 GPS Flight Tracking
- Automatic GPS recording during flights
- Configurable recording interval (1-30 seconds)
- Background location tracking support
- Track visualization on map
- **GPS failure flags** on speed and altitude indicators when signal is lost or degraded
- **"Always" permission prompt**: If only "While Using" access is granted, the app offers to upgrade to "Always" when a flight starts, so the track keeps recording when the screen locks or you switch apps
- **In-flight GPS-lost banner**: A warning appears if the position stops updating (no fix for >90 s) or background tracking is limited — a silent GPS dropout is never mistaken for a valid reading

### 🎯 Live Speed Indicator
- Real-time GPS ground speed display during flight phases
- Displays "GND SPD" (ground speed) with "kt" (knots) unit
- Color-coded feedback:
  - **Green**: Speed within 5 kt of target
  - **Orange**: Speed outside ±5 kt range
  - **Flashing Red/White**: Below stall speed (aircraft-specific: 42 kt for WT9, 53 kt for PA-28)
- Target speed guidance based on current flight phase and aircraft type
- Arrow indicators showing speed trend (up/down/on target)
- Automatically hidden during ground operations (taxi, parking)
- **Honest provenance**: The indicator shows GPS **ground speed** ("GND SPD") by default — not true airspeed — so the stall warning is an awareness aid, never a replacement for the aircraft's airspeed indicator
- **Optional aural stall alert**: An audible warning below stall speed (off by default; see Estimated Airspeed)

### 🌬️ Experimental: Estimated Airspeed (Switzerland only)
- **Optional feature** to display estimated indicated airspeed (IAS) calculated from GPS ground speed and wind data
- Uses real-time **mean wind** from MeteoSwiss automatic weather stations (steady wind, not peak gusts)
- Finds nearest weather station and applies wind correction to ground speed
- **Clearly marked as estimated**: shows "EST. IAS" with a `~` prefix (e.g. `~62`) so a derived value is never confused with a measured one
- **Stale wind aged out**: wind readings that are too old are discarded rather than used, so an outdated observation can't silently drive the estimate
- **Optional aural stall alert**: once enabled, an "Aural stall alert" toggle (off by default) plays an audible warning below stall speed
- **Important limitations**:
  - Only works within Switzerland (with ~5 NM margin at borders)
  - Requires constant cellular connection
  - Can be highly inaccurate - always rely on aircraft's onboard airspeed indicator
- Disabled by default; enable in Settings with mandatory safety warning acknowledgment

### 📏 Live Altimeter
- Real-time GPS altitude display (feet MSL)
- Light blue background for easy visibility
- Displayed alongside speed indicator during flight phases

### 📊 Flight Log
- Complete flight history with all parameters
- **Custom flight names**: Name your flights for easy identification (e.g., "Circuits 2 (F-HVXA)")
- Flight duration (engine start to shutdown)
- Distance travelled in kilometers
- All times recorded chronologically:
  1. Session Start
  2. Engine Start
  3. Take-off (Line Up +2 min)
  4. Landing (auto-detected)
  5. Engine Shutdown
  6. Session End
- GPS track visualization on map
- **Altitude profile graph**: Time-based altitude chart with flight event markers (Engine Start, Take-off, Landing, Shutdown)
- **Go-arounds and touch-and-goes**: Detected and displayed on altitude profile
- Notes for each flight
- **Flight sharing**: Generate shareable image cards with flight summary and map

### 💾 Data Export/Import
- Export flights to GPX format (standard GPS track format)
- Export flights to JSON format (includes all timing data)
- **Export all flights**: Export entire flight log as a ZIP archive
- All timing data included (start, engine, takeoff, landing, shutdown, stop)
- Distance calculation included in exports
- **Bulk import**: Import multiple flights from ZIP archives
- Import GPX or JSON files from other sources
- Compatible with most flight tracking software
- Share flights via any iOS sharing method

### 🎨 Cockpit Design & Themes
- **Redesigned in-flight HUD**: the current checklist item is the hero; past and future steps recede. A cockpit instrument strip shows live speed, altitude, heading and vertical speed with a color-blind-safe on-target bar, plus stall and instrument-failure annunciations
- **Tappable phase bar**: jump forward and back through the 16 phases from a single segmented bar
- **One-tap reference panels**: V-Speeds, GPS status and departure/approach briefings open as a docked panel on iPad or a bottom drawer on iPhone
- **Hold-to-confirm events**: Go-Around, Touch-and-Go and Full-Stop sit behind a deliberate hold, with a brief undo
- **Selectable theme engine** — choose **Auto / Day / Sunlight / Night**; Auto follows the system appearance. Tuned for glare, dusk and night cockpits
- **Aviation-inspired palette** (gold, blue, green); large, high-contrast buttons and readable text; screen stays on during flights
- **Adaptive, iPad-first layout**: two-column landscape and reflowed portrait across Home, Flight, Navigation, Flight Log and Settings
- Phase completion tracking with color-coded indicators:
  - **Green dot**: Phase completed (pressed NEXT)
  - **Orange dot**: Phase skipped (jumped ahead without NEXT)
  - **Red dot**: Phase skipped with missing action (e.g., Engine Start button not pressed)
  - **Gold dot**: Current active phase

### ♿ Accessibility
- VoiceOver labels across the redesigned screens
- Dynamic Type support
- WCAG-aware contrast and 44-point minimum touch targets
- Reduce Motion support

### 📲 Companion Mode (iPad ↔ iPhone)
- Pair an iPhone as a **synced second screen** that mirrors your iPad's live flight data over Wi-Fi Aware
- Pairing and status live under **Settings → Companion**
- Requires **iOS 26** on both devices; on earlier iOS the feature is safely hidden

### 📋 Interactive Briefings
- Departure briefing modal with runway, routing, speeds, and emergency procedures
- Approach briefing modal with approach info, speeds, and missed approach

### 📱 Home Screen Widgets
- **Small widget**: Quick-start buttons for the aircraft you own — the free F-HVXA plus any premium aircraft you've unlocked (unowned aircraft are never shown)
- **Medium widget**: Owned-aircraft quick start plus a Flight Log shortcut
- Deep links start a flight directly from the widget, going through the same checklist load, entitlement, location-permission, and GPS-tracking setup as the in-app START button

## Checklist Phases

The app includes all 16 phases from the official checklists (same structure for both aircraft):

1. **Preflight Check** (Page 1)
2. **Check Before Engine Start** (Page 1)
3. **Engine Start** (Page 1) - with "Engine Start" button
4. **Check After Engine Start** (Page 2)
5. **Taxi Check** (Page 2)
6. **Runup** (Page 2)
7. **Check Before Departure** (Page 2) - with "Ready for Line Up" button
8. **Line Up Check** (Page 3)
9. **Climb Check** (Page 3)
10. **Cruise Check** (Page 3)
11. **Descent Check** (Page 3)
12. **Approach Check** (Page 3)
13. **Landing Check** (Page 3)
14. **After Landing Check** (Page 4)
15. **Engine Shutdown and Parking Check** (Page 4) - with "Engine Shutdown" button
16. **At the Hangar** (Page 4)

## Requirements

### For iPad
- iPad Air (11-inch) or larger recommended
- iPadOS 17.0 or later

### For iPhone
- Any iPhone running iOS 17.0 or later
- Compact UI adapts to smaller screens

### General
- Location services enabled
- Xcode 26 for building (ships the iOS 26 SDK required by Companion mode's `WiFiAware` imports)

## Installation

### From Xcode

1. Clone or download this repository
2. Open `AeroCheck.xcodeproj` in Xcode 26+
3. Select your development team in Signing & Capabilities
4. Connect your iPhone/iPad or select a simulator
5. Build and run (⌘R)

### Building for Distribution

1. In Xcode, select Product → Archive
2. Follow the distribution wizard
3. Choose Ad Hoc or App Store distribution

## Usage

### Starting a Flight

1. Launch the app
2. Select your aircraft in Settings if needed (the free WT9 Dynamic or any unlocked premium aircraft)
3. Tap "START FLIGHT"
4. GPS tracking begins automatically
5. Follow the checklists in order

> **Premium aircraft**: If the aircraft's checklist hasn't finished downloading (no connection or an inactive subscription), the app shows a **"Checklist Not Ready"** alert and refuses to start rather than launch with an incomplete or wrong checklist.

### During Flight

- Use "PREVIOUS" and "NEXT" buttons to navigate
- Tap the phase indicator to jump to any checklist
- Access speed reference anytime via "SPEEDS" button
- **iPad**: Side panel shows all phases, flight times, and current status
- **iPhone**: Tap the info button (i) to view flight info and phases in a sheet

### Special Buttons

- **ENGINE START**: Records the engine start time (shown on Engine Start phase)
- **READY FOR LINE UP**: Adds 2 minutes to current time for take-off time (shown on Check Before Departure phase)
- **ENGINE SHUTDOWN**: Records the engine shutdown time (shown on Engine Shutdown phase)

### Briefing Modals

Tap on the briefing reminder text to open interactive briefings:

- **Departure Briefing**: LSZQ 25, wind, routing, speeds (Vr/Vx/Vy/Vbg), emergency procedures
- **Approach Briefing**: LSZQ 25, routing, approach speeds, missed approach, alternate

### Ending a Flight

1. Complete all checklists through "At the Hangar"
2. Tap "END FLIGHT" on the final page
3. Flight is saved with all data to the Flight Log

### Flight Log

- Access via "FLIGHT LOG" on home screen
- View all recorded flights
- Tap any flight to see details and map
- Export flights to GPX or JSON format
- Add notes to flights
- Delete unwanted flights

## File Structure

```
AeroCheck/
├── AeroCheck.xcodeproj/
│   └── project.pbxproj
├── AeroCheck/
│   ├── AeroCheckApp.swift           # App entry point
│   ├── Info.plist                    # App configuration
│   ├── Configuration.storekit        # StoreKit config for testing
│   ├── Assets.xcassets/             # Images and colors
│   ├── Models/
│   │   ├── Aircraft.swift           # Bundled aircraft types & metadata
│   │   ├── RemoteAircraft.swift     # Remote/API aircraft models
│   │   ├── Flight.swift             # Flight data model & GPX
│   │   ├── FlightPlan.swift         # Flight plan models
│   │   ├── FlightPlanManager.swift  # Flight plan state (CRUD, route)
│   │   ├── Checklist.swift          # Checklist phases & items
│   │   ├── WT9ChecklistData.swift   # WT9 Dynamic checklist data (bundled)
│   │   └── AppState.swift           # App state management (facade-decomposed)
│   ├── Views/
│   │   ├── ContentView.swift        # Root view
│   │   ├── HomeView.swift           # Home (command rail + hero canvas + carousel)
│   │   ├── FlightView.swift         # Active flight HUD
│   │   ├── FlightLogView.swift      # Flight Log dashboard + detail
│   │   ├── NavigationView.swift     # Full-screen navigation map + FREQ panel
│   │   ├── FlightPlanningView.swift # Flight-plan list (master/detail)
│   │   ├── FlightPlanMapBuilderView.swift # Map-first route builder
│   │   ├── CompanionPairingView.swift / CompanionFlightView.swift # Companion mode
│   │   ├── OnboardingView.swift     # First-run onboarding
│   │   ├── SubscriptionView.swift   # Subscription / paywall
│   │   ├── SettingsView.swift       # Settings hub
│   │   └── Settings/                # 8 cockpit-styled settings sub-pages
│   ├── Components/
│   │   ├── DesignSystem.swift       # Theme engine, tokens, styles, Settings kit
│   │   └── ChecklistView.swift      # Checklist display
│   └── Services/
│       ├── LocationManager.swift     # GPS tracking
│       ├── OfflineMapManager.swift   # Offline ICAO/Segelflug chart caching
│       ├── ElevationService.swift    # Terrain elevation (swisstopo CH + Open-Meteo)
│       ├── AirspaceAnalyzer.swift    # On-route airspace/terrain conflict analysis
│       ├── WindDataService.swift     # MeteoSwiss wind data (experimental)
│       ├── CompanionConnectivityManager.swift # Companion mode (Wi-Fi Aware, iOS 26+)
│       ├── SubscriptionManager.swift # StoreKit 2 subscription handling
│       └── AircraftDataService.swift # Remote aircraft checklist API
├── Shared/                          # Shared with Watch / Widget / Companion targets
├── AeroCheckWidget/
│   └── AeroCheckWidget.swift        # Home screen widgets
├── AeroCheckWatch/                  # Apple Watch app
└── README.md
```

## Related Repositories

- **[AeroCheck-server](../AeroCheck-server)**: Cloudflare Workers API for subscription management and premium checklist delivery
- **[AeroCheck-checklists](../AeroCheck-checklists)**: Aircraft checklist data in JSON format

## GPX Format

Exported flights use the standard GPX 1.1 format with extensions:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="AéroCheck">
  <metadata>
    <name>F-HVXA - Dec 1, 2025</name>
    <time>2025-12-01T10:00:00Z</time>
  </metadata>
  <trk>
    <name>F-HVXA</name>
    <extensions>
      <airplane>F-HVXA</airplane>
      <engineStartTime>2025-12-01T10:05:00Z</engineStartTime>
      <lineUpTime>2025-12-01T10:15:00Z</lineUpTime>
      <landingTime>2025-12-01T11:00:00Z</landingTime>
      <engineShutdownTime>2025-12-01T11:05:00Z</engineShutdownTime>
      <distanceKm>45.2</distanceKm>
      <notes>Training flight</notes>
    </extensions>
    <trkseg>
      <trkpt lat="47.123" lon="7.456">
        <ele>430</ele>
        <time>2025-12-01T10:00:00Z</time>
        <speed>0</speed>
        <course>0</course>
      </trkpt>
      <!-- More track points -->
    </trkseg>
  </trk>
</gpx>
```

## JSON Format

JSON export includes all flight data in a structured format:

```json
{
  "id": "uuid-string",
  "airplane": "F-HVXA",
  "startTime": "2025-12-01T10:00:00Z",
  "engineStartTime": "2025-12-01T10:05:00Z",
  "lineUpTime": "2025-12-01T10:15:00Z",
  "landingTime": "2025-12-01T11:00:00Z",
  "engineShutdownTime": "2025-12-01T11:05:00Z",
  "stopTime": "2025-12-01T11:10:00Z",
  "notes": "Training flight",
  "gpsTrack": [
    {
      "latitude": 47.123,
      "longitude": 7.456,
      "altitude": 430,
      "timestamp": "2025-12-01T10:00:00Z",
      "speed": 0,
      "course": 0
    }
  ]
}
```

## Configuration Options

In Settings:

- **Aircraft in use**: Select your aircraft (the free WT9 Dynamic or any unlocked premium aircraft) - this changes checklists, speeds, and stall warnings
- **Theme**: Auto / Day / Sunlight / Night cockpit theme (Auto follows the system appearance)
- **Companion**: Pair an iPhone as a synced second screen for your iPad (iOS 26+)
- **GPS Recording Interval**: 1-30 seconds between points
- **Show Estimated Airspeed** *(Experimental)*: Display estimated IAS calculated from GPS ground speed and MeteoSwiss mean-wind data. Estimated values are shown as "EST. IAS" with a `~` prefix so they're never mistaken for measured airspeed. Only works in Switzerland with cellular connection. Shows safety warning before enabling.
- **Aural Stall Alert** *(Experimental)*: Revealed once Estimated Airspeed is enabled. Plays an audible warning below the aircraft's stall speed. Off by default.
- **Keep Screen On**: Prevents display sleep during use
- **Always Use UTC Times**: Display all times in UTC with a (UTC) suffix
- **Force ICAO Chart Layer**: Keep ICAO Chart (1:500,000) at all zoom levels instead of switching to Segelflugkarte
- **Offline Mode**: Use only cached charts for navigation (requires download)
- **Step-by-Step Highlighting**: Highlights checklist items one at a time; tap anywhere to advance to the next item (auto-scrolls if needed)
- **Learning Mode (show all checks)**: When OFF (default), memorizable checks are hidden to test your memory. When ON, all checks are visible for studying. Hidden phases vary by aircraft
- **Circuit Mode**: Enable for pattern training - skips Cruise and Descent phases, adds FULL STOP button for tracking landings

## Speed Reference

Quick access to all important speeds (KIAS). The SPEEDS modal shows aircraft-specific values:

### WT9 Dynamic (F-HVXA)

| Speed | Value | Description |
|-------|-------|-------------|
| Vso | 33 | Stall (flaps down) |
| Vs | 42 | Stall (clean) |
| Vr | 40 | Rotation |
| Vx | 55 | Best angle |
| Vy | 70 | Best rate of climb |
| Vcc | 85 | Cruise climb |
| Vfe | 76 | Flaps extension |
| Vbg | 70 | Best glide |

**Max crosswind**: TO 14 kt / LDG 16 kt

### PA-28-181 (HB-PFA)

| Speed | Value | Description |
|-------|-------|-------------|
| Vso | 47 | Stall (flaps down) |
| Vs | 53 | Stall (clean) |
| Vr | 53 | Rotation |
| Vx | 64 | Best angle |
| Vy | 76 | Best rate of climb |
| Vcc | 87 | Cruise climb |
| Vfe | 103 | Flaps extension |
| Vbg | 76 | Best glide |

**Max crosswind**: 17 kt

### Target Speeds by Phase

Target speeds vary by aircraft. Examples for WT9:

| Phase | Target | Notes |
|-------|--------|-------|
| Climb | 55 | Vx - best angle of climb |
| Cruise | 100 | Cruise speed |
| Descent | 85 | Vcc - cruise descent |
| Approach | 65 | Initial approach with F1 |
| Landing | 55 | Final approach F3 |

*Note: Speed indicator is hidden during ground operations (taxi, runup, parking)*

## Based On

- WT9 F-HVXA Checklist v2.1e from Groupe de Vol à Moteur de Porrentruy (Aeroclub du Jura GVMP)
- Premium checklists from Groupe de Vol à Moteur de Porrentruy and Lausanne Aéroclub (e.g. PA-28-181 HB-PFA v2.0e)
- SPHAIR Bases et procédures

## Testing

### StoreKit Testing

The app includes a `Configuration.storekit` file for testing subscriptions locally:

1. Open the project in Xcode
2. Edit the scheme (Product > Scheme > Edit Scheme)
3. Under Run > Options, set StoreKit Configuration to `Configuration.storekit`
4. Run the app to test subscription flows without real purchases

### API Testing

For testing against the development server:

1. Run the server locally with Wrangler: `cd ../AeroCheck-server && npm run dev`
2. Update the API URL in `SubscriptionManager.swift` to `http://localhost:8787`
3. Test subscription verification and checklist fetching

## Privacy

- All flight data stored locally on device
- Your flight log, tracks and settings are never uploaded to AeroCheck's servers. Flights and
  settings sync only through **your own** iCloud account (CloudKit private database).
- **Terrain profiles send route coordinates to a third party.** When you generate a flight-plan or
  flight-share terrain profile, the route — for a recorded flight, a sampled version of the actual
  GPS track — is sent to swisstopo (`api3.geo.admin.ch`) inside Switzerland or Open-Meteo
  (`api.open-meteo.com`) elsewhere, to look up ground elevation. Coordinates are rounded to roughly
  100 m before they leave the device, and nothing identifying you is attached. No terrain profile
  means no transmission.
- Map, airspace and airport data are fetched by area, not by your position.
- Checklist data cached locally after initial download
- Export only when explicitly requested by user

## Data Sources & Licences

AéroCheck displays third-party geographic, aeronautical and weather data. These sources require visible attribution (shown in-app on the navigation map's layer panel) and their terms govern your use:

| Data | Source | Attribution |
|------|--------|-------------|
| ICAO / Segelflug / Landeskarte / SwissImage chart tiles | **swisstopo / BAZL** (geo.admin.ch) | © swisstopo / BAZL |
| Terrain elevation (Switzerland) | **swisstopo** profile API | © swisstopo |
| Terrain elevation (worldwide) | **Open-Meteo** elevation API | Elevation: Open-Meteo |
| Wind (experimental, Switzerland) | **MeteoSwiss** Open Data (geo.admin.ch) | © MeteoSwiss |
| Airspace / airports | **OpenAIP** | Aeronautical data © OpenAIP contributors |
| Airport / runway / frequency data | **OurAirports** (public domain) | OurAirports |

> **Offline chart caching:** the offline ICAO/Segelflug chart download is a bulk extraction of BAZL aeronautical chart products. Shipping that feature requires an explicit licence/agreement with swisstopo/BAZL (tracked separately as SEC-09); until then it is a release blocker for the offline-cache feature.

The app code is MIT-licensed; premium checklist content is proprietary. Third-party data remains under its providers' respective licences.

## Support

The app is provided as-is and support is not guaranteed. In case of issues, feel free to open an issue on GitHub.

---

**Safe flying!**
