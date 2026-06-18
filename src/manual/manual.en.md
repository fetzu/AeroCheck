Welcome to the AeroCheck user manual. This guide covers all the features of the app to help you get the most out of your flights.


## Getting Started

### First Launch

When you first open AeroCheck, the app will request **location permission**. This is required for GPS flight tracking, ground speed display, and the navigation map. Grant "While Using the App" or "Always" permission for full functionality, including background tracking during flights.

If you grant only "While Using the App," AeroCheck will offer to **upgrade to "Always"** when you start a flight. "Always" access is what lets the track keep recording when the screen locks or you switch to another app in flight -- without it, an in-flight banner will warn you that background recording is limited (see [GPS Indicators](#gps-indicators)).

### Selecting an Aircraft

The home screen displays an **aircraft carousel**. Swipe left or right to browse available aircraft. The bundled aircraft (WT9 Dynamic / F-HVXA) is included free. Premium aircraft require an AeroCheck Pro subscription.

Each aircraft card shows the registration, type, and number of checklist items. Tap the **Settings** icon to manage aircraft, download additional checklists, or subscribe.

### Starting a Flight

Tap **START FLIGHT** to begin a standard flight. The app will guide you through all 16 flight phases, from Preflight to At the Hangar. For pattern training, tap **CIRCUITS** instead -- this activates Circuit Mode, which streamlines the checklist for repeated landings.

For premium aircraft, the checklist is downloaded from the AeroCheck API. If it has not finished loading -- for example, because of a missing connection or an inactive subscription -- AeroCheck will **not** start the flight with an incomplete checklist. Instead it shows a **"Checklist Not Ready"** alert asking you to check your connection and subscription and try again, so the wrong (or empty) checklist can never appear in flight.

### Starting from the Home Screen Widget

Add the **AeroCheck widget** to your iPhone or iPad home screen for one-tap flight starts. The widget shows a start button for each aircraft you own -- the free WT9 Dynamic plus any premium aircraft you have unlocked (aircraft you don't own are never shown). Tapping a button starts that aircraft's flight directly, loading its checklist and beginning GPS tracking, exactly as the in-app START button does. The medium widget also includes a shortcut to your flight log.

---

## Checklists

### The 16 Flight Phases

AeroCheck covers every phase of flight:

1. Preflight
2. Before Engine Start
3. Engine Start
4. After Engine Start
5. Taxi
6. Run Up
7. Before Departure
8. Line Up
9. Climb
10. Cruise
11. Descent
12. Approach
13. Landing
14. After Landing
15. Engine Shutdown
16. At the Hangar

Navigate between phases using the **phase selector** at the top of the screen. Completed phases are marked with a checkmark.

### Step-by-Step Mode

When enabled (default), the current checklist item is highlighted. Tap it to mark it as complete and advance to the next item. This helps ensure no items are skipped.

### Learning Mode

Learning mode hides items that should be memorized, allowing you to test your knowledge. Items configured as "memorizable" in the checklist will only appear when Learning Mode is turned off. Toggle this in **Settings > Checklist > Learning Mode**.

### Multi-Page Phases

Some phases span multiple pages. A page indicator at the bottom shows your position. Swipe or tap to navigate between pages within a phase.

### Checklist Language

If a checklist is available in multiple languages, you can choose your preferred language in **Settings > Checklist > Checklist Language**. Options include Auto (follows device language), English, and French.

---

## In-Flight Navigation

### Opening the Map

Tap the **NAV** button during a flight to open the full-screen navigation map. The map shows your current position with a heading indicator.

### Map Layers

AeroCheck offers several map layers:

- **Standard** -- Default Apple Maps view
- **Satellite** -- Satellite imagery
- **ICAO Chart 1:500,000** -- Swiss aeronautical chart from swisstopo
- **Landeskarten 1:100,000 / 1:50,000** -- Swiss national maps
- **Segelflugkarte 1:300,000** -- Swiss glider chart

The ICAO Chart and Segelflugkarte switch seamlessly based on zoom level. Swiss map layers are available within and near Switzerland.

### FREQ Panel

Tap the **FREQ** button to open the radio frequency panel. This displays:

- **Flight plan frequencies** (if a flight plan is active)
- **Nearby airport frequencies** -- Automatically detected airports within 15 NM, showing ATIS, TWR, GND, APP, and other published frequencies from the OurAirports database
- **Common Swiss frequencies** -- Emergency, information, and FIS frequencies
- **Nearby CTR frequencies** -- Control zone frequencies based on your position

### GPS Indicators

The navigation view displays real-time:
- **Ground speed** in knots
- **Altitude** in feet MSL
- **GPS signal quality** indicator

If the GPS position stops updating in flight (no fix for more than 90 seconds), the speed and altitude indicators show a **failure flag** instead of stale numbers, and the GPS status reads **Lost** -- so a silent signal dropout is never mistaken for a valid reading. If location access is limited to "While Using the App," an amber **"Limited GPS"** banner reminds you to grant "Always" so the track keeps recording in the background.

### Speed, Stall, and Estimated Airspeed

During the flying phases, AeroCheck shows a large speed indicator with color-coded guidance toward the target speed for the current phase, and a stall warning (flashing red/white) when you drop below the aircraft's stall speed.

By default this indicator shows **GPS ground speed** (`GND SPD`, in knots). Ground speed is not the same as the airspeed your panel shows -- a head- or tailwind shifts it -- so treat the on-screen stall warning as an awareness aid, never as a replacement for your aircraft's airspeed indicator.

**Estimated airspeed (experimental, Switzerland only).** When you enable *Show Estimated Airspeed* in Settings, the indicator instead estimates indicated airspeed by correcting GPS ground speed with mean wind from the nearest MeteoSwiss station. To keep it honest, an estimated value is clearly marked: the label reads **`EST. IAS`** and the number is prefixed with a tilde (for example `~62`), so a derived figure is never confused with a measured one. The correction uses steady mean wind (not gusts), and wind readings that are too old are aged out rather than used, so a stale observation cannot quietly drive the estimate.

**Aural stall alert (optional).** With estimated airspeed enabled, you can also turn on an **Aural stall alert** in Settings. When armed, it plays an audible warning if your speed drops below the stall speed -- useful when your eyes are outside the cockpit. It is **off by default** and, like the visual indicator, is an aid only: always fly the aircraft's certified airspeed indicator.

### Offline Maps

Swiss ICAO Chart and Segelflugkarte can be cached for offline use. Go to **Settings > Offline Maps** to download charts (~100-250 MB). When offline mode is enabled, maps are served from your local cache.

---

## Briefings

### Departure Briefing

Before departure, a dynamic briefing is displayed showing:
- **Airport** and **elevation** (automatically detected from your GPS position)
- **Runway** (detected or manually selected)
- **Departure procedure** -- First turn direction and level-off altitude (to be briefed verbally by the pilot)
- **Wind** conditions (when available from MeteoSwiss)
- **Airspeeds** -- Rotation (Vr), best angle (Vx), best rate (Vy), best glide (Vbg), and other speeds from the aircraft flight manual
- **Emergency procedures** -- Malfunction before rotation, engine failure after takeoff, minimum safe altitudes

### Approach Briefing

Before approach, a similar briefing covers:
- **Airport** and **elevation**
- **Runway**
- **Wind** conditions
- **Approach speeds** -- Initial approach, final approach, and stall speeds
- **Go-around procedure**

When wind data is unavailable, the briefing shows a reminder to check the windsock for calm, crosswind, headwind, or tailwind conditions.

---

## Flight Logging

### Automatic Timing

AeroCheck automatically records key timestamps during your flight:
- **Block off / Block on** times
- **Engine start / Engine shutdown** times
- **Takeoff / Landing** times (tap action buttons to record)

### Flight Events

The app automatically detects and logs:
- **Go-arounds** -- Detected when climbing above a threshold after an approach
- **Touch-and-goes** -- Brief ground contact followed by takeoff
- **Full-stop landings** -- Final landing at end of flight

### Engine Hours

If enabled in **Settings > Flight Logging**, the app prompts for tachometer or Hobbs meter readings at engine start and shutdown. Hours flown are calculated automatically.

### Viewing Flight History

Tap the **flight log** icon on the home screen to view past flights. Each flight entry shows the date, duration, aircraft, and distance.

Tap a flight to see its **detail view**, which includes:
- An interactive map with your flight track
- An altitude profile chart
- Route information (departure and arrival airports)
- Chronological timeline of all events
- Engine hours (if logged)
- Flight notes

### Exporting Flights

From the flight detail view, tap **Export** to save your flight as:
- **GPX** -- Standard GPS exchange format, compatible with most mapping tools
- **JSON** -- Detailed flight data including all events and metadata

You can also generate a **share card** -- a visual summary of your flight that can be shared to social media or messaging apps.

---

## Apple Watch and Companion Mode

AeroCheck can mirror your live flight onto a second screen.

### Apple Watch

The companion **Apple Watch app** shows the current flight phase, ground speed, and altitude on your wrist, updated in real time from your iPhone. If the watch stops receiving fresh data -- for example, when it moves out of range of the phone -- a **"NO DATA"** banner appears so you know the values on the watch may be frozen rather than current.

### Companion Mode

On supported devices, **Companion Mode** turns a second iPhone or iPad into a synced second screen over a direct Wi-Fi link: one device acts as the master and the other mirrors its flight display. If the connection drops or the data goes stale, the companion screen shows a **"Data stale -- values may be frozen"** or **"Connection lost"** banner, so a mirrored screen is never mistaken for a live one.

In both cases the rule is the same: a staleness or disconnect banner means *stop trusting the numbers on that screen* until it reconnects.

---

## Flight Planning

Open **Flight Planning** from the home screen or the navigation map to build a route directly on the map.

### Building a Route

AeroCheck's planner is **map-first**:
- Set your departure and destination in the **From → To** bar, then refine on the map.
- **Drag a waypoint** to move it; **drag the route line** to insert a new waypoint mid-route.
- Release a dragged point **near an airfield** to auto-snap to it — its name and frequency are filled in automatically.
- Dropping a waypoint uses **smart "cheapest insertion"**, placing it into the leg that adds the least detour.
- Saved plans appear in a list with route thumbnails and a one-tap **Activate**.

### Flight Plan Details

Open the **Flight plan details** sheet for the full leg-by-leg breakdown — each waypoint's name and frequency, planned altitude, ground speed, estimated enroute time (EET), estimated time of arrival (ETO) and magnetic course (MC).

### Route Profile

The **interactive route profile** draws a terrain silhouette (swisstopo elevation in Switzerland, worldwide elsewhere) against your planned-altitude line. Drag a point to set its altitude, or hold to add one. Terrain-clearance and airspace-conflict warnings update live as you reshape the route.

### Airspace Conflict Checks

AeroCheck checks your planned route against OpenAIP airspace data and flags controlled or restricted airspace it may enter. Conflicts appear as a banner and highlight on the route; tap to see each airspace, its vertical limits, and its frequency. A green "no conflicts" result is shown only when airspace data is actually loaded — otherwise AeroCheck tells you airspace wasn't checked rather than implying you are clear.

The check follows the exact route geometry between waypoints (not just the endpoints), so a leg that clips the corner of a zone is still caught. Where the result depends on altitude, AeroCheck is deliberately conservative: it reports the worst-case severity, and when a zone's ceiling or floor is published relative to the ground or as a flight level (AGL/FL), or when a leg has no planned altitude entered, the conflict is marked **"Altitude uncertain -- verify vertical separation."** That qualifier means the horizontal conflict is real but the app cannot confirm whether your altitude keeps you clear -- you must verify the vertical separation yourself against current charts and QNH.

As always, airspace data is advisory and may be incomplete or out of date; it never replaces official aeronautical charts and NOTAMs.

### In-Flight HUD

During a flight with an active plan, a heads-up display shows:
- Next waypoint name, heading, and distance
- Planned altitude
- Flight time and ETO
- Progress indicator
- A chronometer for timing legs

### Exporting

Flight plans can be exported as GPX files compatible with Dynon, Garmin, and other avionics systems.

---

## Circuit Mode

Circuit mode is designed for **pattern training** (touch-and-go practice). When activated:

- The checklist skips the **Cruise** and **Descent** phases
- After landing, the checklist returns directly to the **Before Departure** phase
- **Full-stop landings** are tracked automatically

Enable circuit mode when starting a flight by tapping **CIRCUITS** on the home screen, or toggle it in **Settings > Checklist > Circuit Mode**.

---

## Settings and Subscription

Settings are organized into a hub of dedicated pages:

### Aircraft

- **AeroCheck Pro** -- Subscribe to unlock premium aircraft checklists
- **Aircraft** -- Select your active aircraft from the free WT9 Dynamic and any unlocked premium options
- **Aircraft Visibility** -- Show or hide aircraft by aeroclub

### Checklist & Flight

- **Checklist** -- Step-by-step highlighting, learning mode, circuit mode, and language
- **Flight Logging** -- Engine hour (Hobbs meter) logging
- **GPS** -- Recording interval (1-30 seconds) and permission status
- **Display** -- Keep the screen on during flight, use UTC time

### Navigation & Maps

- **Theme** -- Choose the cockpit theme: **Auto, Day, Sunlight or Night** (Auto follows the system appearance)
- **Navigation** -- Force ICAO chart layer
- **Airspace** -- OpenAIP airspace overlay, continent downloads, and online streaming
- **Airport Data** -- Download the OurAirports database for worldwide airport frequencies
- **Offline Maps** -- Cache the Swiss ICAO Chart and Segelflugkarte for offline use
- **Estimated Airspeed** (Experimental) -- GPS ground speed corrected with MeteoSwiss mean-wind data (Switzerland only). Estimated values are shown as `EST. IAS` with a `~` prefix so they are never mistaken for measured airspeed. Enabling it also reveals an **Aural stall alert** toggle (off by default) that plays an audible warning below stall speed

### Flight Planning

- Route-builder and GPX export preferences

### Companion

- **Companion Mode** -- Pair an iPhone as a synced second screen for your iPad (requires iOS 26 on both devices)

### Sync & Data

- **iCloud Sync** -- Synchronize settings and flight logs across devices
- **Data** -- Flight and GPS statistics

### About

- **About** -- App version, website, author, and open-source information
- **Available Checklists** -- View all cached aircraft checklists and versions
- **Replay Onboarding** -- Show the introductory tour again
- **Developer Options** -- Hidden debug tools (tap the version number 5 times to unlock)
