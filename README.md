__IMPORTANT CAVEAT: This application is provided solely for training and pedagogical purposes; its information is not guaranteed for accuracy and must not be used for operational decision-making. Always rely on the official Aircraft Flight Manual (AFM) and approved checklists when operating an aircraft.__

_NOTE: This app has been entirely vibe coded. If you hate that, feel free to close your browser window in disgust and not use it._

# AéroCheck - WT9 Dynamic

A native iPad application for pilot students flying the WT9 Dynamic aircraft. This app guides pilots through all checklists during a flight, from preflight to shutdown, while recording GPS tracks and flight data.

![Platform](https://img.shields.io/badge/Platform-iPadOS%2017%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-Private-red)

## Features

### ✈️ Complete Checklist System
- All 16 flight phases from the official WT9 Dynamic checklist (Version 2.1e)
- Checklists displayed exactly as in the official documentation
- Easy navigation between phases
- Quick phase selector for jumping to any checklist
- Speed reference card always accessible
- **Step-by-Step Highlighting**: Items highlighted one at a time; tap anywhere in the checklist area to advance
- **Smart completion**: When all items are checked, the NEXT button pulses to draw attention
- **Learning Mode**: Toggle to show all checks for studying, or hide memorizable checks to test memory

### 📍 GPS Flight Tracking
- Automatic GPS recording during flights
- Configurable recording interval (1-30 seconds)
- Background location tracking support
- Track visualization on map

### 🎯 Live Speed Indicator
- Real-time GPS speed display during flight phases
- Color-coded feedback:
  - **Green**: Speed within 5 KIAS of target
  - **Orange**: Speed outside ±5 KIAS range
  - **Flashing Red/White**: Below stall speed (42 KIAS)
- Target speed guidance based on current flight phase
- Arrow indicators showing speed trend (up/down/on target)
- Automatically hidden during ground operations (taxi, parking)

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
- Notes for each flight

### 💾 Data Export/Import
- Export flights to GPX format (standard GPS track format)
- Export flights to JSON format (includes all timing data)
- **Export all flights**: Export entire flight log as a ZIP archive
- All timing data included (start, engine, takeoff, landing, shutdown, stop)
- Distance calculation included in exports
- Import GPX or JSON files from other sources
- Compatible with most flight tracking software
- Share flights via any iOS sharing method

### 🎨 Cockpit-Optimized UI
- Dark theme for reduced glare
- Large, high-contrast buttons
- Aviation-inspired color scheme (gold, blue, green)
- Large readable text
- Screen stays on during flights
- Phase completion tracking with color-coded indicators:
  - **Green dot**: Phase completed (pressed NEXT)
  - **Orange dot**: Phase skipped (jumped ahead without NEXT)
  - **Red dot**: Phase skipped with missing action (e.g., Engine Start button not pressed)
  - **Gold dot**: Current active phase

### 📋 Interactive Briefings
- Departure briefing modal with runway, routing, speeds, and emergency procedures
- Approach briefing modal with approach info, speeds, and missed approach

## Checklist Phases

The app includes all phases from the official checklist:

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

- iPad Air (11-inch) or larger
- iPadOS 17.0 or later (designed for iOS 26)
- Location services enabled
- Xcode 15.0+ for building

## Installation

### From Xcode

1. Clone or download this repository
2. Open `AeroCheck.xcodeproj` in Xcode 15+
3. Select your development team in Signing & Capabilities
4. Connect your iPad or select a simulator
5. Build and run (⌘R)

### Building for Distribution

1. In Xcode, select Product → Archive
2. Follow the distribution wizard
3. Choose Ad Hoc or App Store distribution

## Usage

### Starting a Flight

1. Launch the app
2. Verify your aircraft registration (default: F-HVXA)
3. Tap "START FLIGHT"
4. GPS tracking begins automatically
5. Follow the checklists in order

### During Flight

- Use "PREVIOUS" and "NEXT" buttons to navigate
- Tap the phase indicator to jump to any checklist
- Access speed reference anytime via "SPEEDS" button
- Side panel shows all phases and current status

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
│   ├── Assets.xcassets/             # Images and colors
│   ├── Models/
│   │   ├── Flight.swift             # Flight data model & GPX
│   │   ├── Checklist.swift          # Checklist items & phases
│   │   └── AppState.swift           # App state management
│   ├── Views/
│   │   ├── ContentView.swift        # Root view
│   │   ├── HomeView.swift           # Home screen
│   │   ├── FlightView.swift         # Active flight view
│   │   ├── FlightLogView.swift      # Flight history
│   │   └── SettingsView.swift       # Configuration
│   ├── Components/
│   │   ├── DesignSystem.swift       # Colors, fonts, styles
│   │   └── ChecklistView.swift      # Checklist display
│   └── Services/
│       └── LocationManager.swift     # GPS tracking
└── README.md
```

## GPX Format

Exported flights use the standard GPX 1.1 format with extensions:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="AeroCheck">
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

- **Default Aircraft**: Registration code for new flights
- **GPS Recording Interval**: 1-30 seconds between points
- **Keep Screen On**: Prevents display sleep during use
- **Step-by-Step Highlighting**: Highlights checklist items one at a time; tap anywhere to advance to the next item (auto-scrolls if needed)
- **Learning Mode (show all checks)**: When OFF (default), memorizable checks are hidden to test your memory. When ON, all checks are visible for studying. Hidden phases include Engine Start (items 3+), Taxi, Runup (items 4+), Line Up, Climb, Descent, Approach, Landing, and After Landing

## Speed Reference

Quick access to all important speeds (KIAS):

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

### Target Speeds by Phase

| Phase | Target | Notes |
|-------|--------|-------|
| Climb | 55 | Vx - best angle of climb |
| Cruise | 100 | Cruise speed |
| Descent | 85 | Vcc - cruise descent |
| Approach | 65 | Initial approach with F1 |
| Landing | 55 | Final approach F3 |

*Note: Speed indicator is hidden during ground operations (taxi, runup, parking)*

## Based On

- WT9 F-HVXA Checklist Version 2.1e (March 2025)
- Extended Checklist Version 1.2 (March 2025)
- Aéroclub du Jura GVMP
- SPHAIR Bases et procédures

## Privacy

- All flight data stored locally on device
- GPS data never transmitted to external servers
- Export only when explicitly requested by user

## Support

For questions about the checklist content, contact Aéroclub du Jura GVMP.

For app technical issues, check the project repository.

---

**Safe flying! ✈️**
