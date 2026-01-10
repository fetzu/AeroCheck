# AéroCheck Marketing Assets

This folder contains resources for creating marketing screenshots and promotional materials.

## Contents

### Flight Data Files (`flights/`)

Historical flight JSON files that can be imported into the app for showcasing the Flight Log view:

1. **`wright_brothers_1903.json`** - First Powered Flight (Wright Brothers, December 17, 1903)
   - Location: Kill Devil Hills, Kitty Hawk, NC
   - Duration: 12 seconds
   - Distance: 120 feet
   - Aircraft: Wright Flyer I

2. **`harriet_quimby_1912.json`** - First American Woman to Cross English Channel (April 16, 1912)
   - Route: Dover, England → Hardelot, France
   - Duration: ~59 minutes
   - Distance: ~35 miles
   - Aircraft: Blériot XI

3. **`lindbergh_1927.json`** - First Solo Transatlantic Flight (May 20-21, 1927)
   - Route: Roosevelt Field, NY → Le Bourget, Paris
   - Duration: 33 hours 30 minutes
   - Distance: 3,600 miles
   - Aircraft: Spirit of St. Louis (Ryan NYP)

4. **`yeager_1947.json`** - Breaking the Sound Barrier (October 14, 1947)
   - Location: Edwards AFB, California
   - Max Speed: Mach 1.06 (700 mph)
   - Max Altitude: 43,000 ft
   - Aircraft: Bell X-1 "Glamorous Glennis"

5. **`lszq_alpine_tour.json`** - Alpine Tour from LSZQ Bressaucourt
   - Route: LSZQ → Chasseral → Sion (T&G) → Samedan (T&G) → LSZQ
   - Duration: ~4h 25min
   - Distance: ~650 km
   - Aircraft: WT9 Dynamic (F-HVXA)

## How to Use

### Importing Historical Flights

1. Open the app
2. Go to **Flight Log** view
3. Tap the **Import** button (document icon)
4. Select a JSON file from this folder
5. The flight will appear in your log with full GPS track and timing data

### Using the Marketing Location Provider

The Marketing Location Provider is now built into the app. Here's how to enable it:

#### Enabling Marketing Mode

1. Open **Settings** in the app
2. **Tap the "App Version" row 5 times** - this reveals a hidden "Developer Options" section
3. **Toggle "Marketing Mode" ON**

#### Using Marketing Mode

Once enabled:
1. **Shake your device** to show/hide the marketing controls overlay
2. The overlay appears in the top-right corner

#### Available Scenarios

The provider includes 5 predefined Swiss flight scenarios:

1. **LSZQ Alpine Tour** - Bressaucourt → Sion (T&G) → Samedan (T&G) → Bressaucourt
2. **Swiss Alps Flight** - Scenic flight around Interlaken, Grindelwald, Lauterbrunnen
3. **LSZJ Circuit Pattern** - Standard traffic pattern at Courtelary aerodrome
4. **Jura Mountains Crossing** - La Chaux-de-Fonds to Delémont
5. **Geneva to Zurich** - Cross-country flight across Switzerland

#### Marketing Controls

- **Scenario picker** - Select which flight to simulate
- **Playback controls** - Play, pause, previous/next waypoint, stop
- **Position info** - Shows current lat, lon, altitude, speed, heading
- **Custom Position** - Toggle to manually set exact coordinates

## Screenshot Suggestions

### Flight Log Screenshots
- Import all historical flights
- Show the list view with varied flight durations and distances
- Show a detail view of the Lindbergh flight with the transatlantic GPS track

### Nav View Screenshots
- Use "Swiss Alps Flight" scenario for scenic mountain views with ICAO chart
- Use "LSZJ Circuit" for showing the traffic pattern
- Use "LSZQ Alpine Tour" for showing a complex cross-country route

### Checklist View Screenshots
- Start a new flight with the marketing provider active
- Use custom position to show realistic speed/altitude in the header
- Progress through different checklist phases

## Notes

- All GPS coordinates are historically accurate where data is available
- Speed values are in knots (converted to m/s internally)
- Altitudes are in meters
- The historical flights use realistic timing data
- Marketing mode is hidden by default and requires the 5-tap gesture to reveal
