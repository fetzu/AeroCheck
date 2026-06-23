Welcome to the AéroCheck user manual. This guide covers every feature of the app — from your first launch through planning, flying, and logging — so you can get the most out of each flight.

AéroCheck is a flight companion, not a certified instrument. Everything it shows — speeds, airspace, terrain, frequencies — is advisory and may be incomplete or out of date. It never replaces your aircraft's instruments, current aeronautical charts, NOTAMs, or your own judgment as pilot in command.


## Getting Started

### First Launch and Onboarding

When you first open AéroCheck, a short onboarding flow walks you through setup:

- **Location permission** — required for GPS flight tracking, ground speed, and the navigation map. Grant "While Using the App" or "Always" for full functionality. "Always" is what lets the track keep recording when the screen locks or you switch apps in flight; if you grant only "While Using the App," AéroCheck offers to **upgrade to "Always"** when you start a flight.
- **Maps and data for your region** — AéroCheck suggests the aeronautical data to download for your home country (detected from your device region or, if available, a GPS fix) and its neighbours, so airspace, frequencies, and map markers work where you fly. See [Aeronautical Data and Storage](#aeronautical-data-and-storage).
- **Preferences** — set checklist options (learning mode, circuit mode) and tour the in-flight features.

You can replay the whole tour anytime from **Settings > About > Replay Onboarding**.

### AéroCheck Pro

AéroCheck is free to use with the bundled **WT9 Dynamic (F-HVXA)** aircraft. The other aircraft are unlocked with **AéroCheck Pro**:

- A **monthly** or **yearly** subscription — the yearly plan includes a **7-day free trial** for eligible accounts.
- A one-time **Lifetime** purchase — pay once, no renewal.

Manage your plan under **Settings > Aircraft & Subscription**, where you can subscribe, start a trial, buy Lifetime, or **Restore Purchases** on a new device. Subscriptions renew automatically unless cancelled at least 24 hours before the period ends; you can cancel anytime in your device's Settings app. Premium aircraft and their checklists are delivered over the network, so an unlocked aircraft downloads its checklist the first time you select it and is then cached for offline use.

### Selecting an Aircraft

The home screen shows an **aircraft carousel**. Swipe left or right to browse the aircraft you own — the free WT9 Dynamic plus any premium aircraft you have unlocked. Each card shows the registration, type, and the checklist version and item count. Use **Settings > Aircraft & Subscription** to choose your active aircraft, manage your subscription, or show/hide aircraft by aeroclub.

### Starting a Flight

Tap **START FLIGHT** to begin a standard flight through all 16 phases, from Preflight to At the Hangar. For pattern work, tap **CIRCUITS** to start in [Circuit Mode](#circuit-mode).

For premium aircraft, the checklist is fetched from the AéroCheck service. If it has not finished loading — for example because of a missing connection or an inactive subscription — AéroCheck will **not** start the flight with an incomplete checklist. It shows a **"Checklist Not Ready"** alert asking you to check your connection and subscription, so a wrong or empty checklist can never appear in flight.

### Starting from the Home Screen Widget

Add the **AéroCheck widget** to your iPhone or iPad home screen for one-tap starts. The widget shows a start button for each aircraft you own (aircraft you don't own are never shown). Tapping a button loads that aircraft's checklist and begins GPS tracking, exactly like the in-app START button. The medium widget also includes a shortcut to your flight log.

---

## Flight Planning

Open **Flight Planning** from the home screen or the navigation map to build a route directly on the map.

### Building a Route

AéroCheck's planner is **map-first**:

- Set your departure and destination in the **From → To** bar, then refine on the map.
- **Drag a waypoint** to move it; **drag the route line** to insert a new waypoint mid-route.
- Release a dragged point **near an airfield or navaid** to auto-snap to it — its name and frequency are filled in automatically.
- Dropping a waypoint uses **smart "cheapest insertion,"** placing it into the leg that adds the least detour.
- Saved plans appear in a list with route thumbnails and a one-tap **Activate**.

### Flight Plan Details

Open the **Flight plan details** sheet for the full leg-by-leg breakdown — each waypoint's name and frequency, planned altitude, ground speed, estimated enroute time (EET), estimated time over (ETO), and magnetic course (MC).

### Route Profile

The **interactive route profile** draws a terrain silhouette (swisstopo elevation in Switzerland, worldwide elsewhere) against your planned-altitude line. Drag a point to set its altitude, or hold to add one. Terrain-clearance and airspace-conflict warnings update live as you reshape the route.

### Airspace Conflict Checks

AéroCheck checks your planned route against OpenAIP airspace data and flags controlled or restricted airspace it may enter. Conflicts appear as a banner and highlight on the route; tap to see each airspace, its vertical limits, and its frequency. A green "no conflicts" result is shown only when airspace data is actually loaded — otherwise AéroCheck tells you airspace wasn't checked rather than implying you are clear.

The check follows the exact route geometry between waypoints (not just the endpoints), so a leg that clips the corner of a zone is still caught. Where the result depends on altitude, AéroCheck is deliberately conservative: it reports the worst-case severity, and when a zone's limit is published relative to the ground or as a flight level (AGL/FL), or when a leg has no planned altitude, the conflict is marked **"Altitude uncertain — verify vertical separation."** That qualifier means the horizontal conflict is real but the app cannot confirm whether your altitude keeps you clear — you must verify the vertical separation yourself against current charts and QNH.

As always, airspace data is advisory and may be incomplete or out of date; it never replaces official aeronautical charts and NOTAMs.

### Exporting a Plan

Flight plans can be exported as **GPX** files compatible with Dynon, Garmin, and other avionics systems.

---

## Checklists and the In-Flight HUD

### The 16 Flight Phases

AéroCheck covers every phase of flight:

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

Move between phases with the **tappable phase bar** at the top of the screen. Completed phases are marked; you can jump forward or back at any time.

### The Cockpit HUD

In flight, the current checklist item is shown as the **hero** while past and future steps recede, so the next action is always obvious. A **cockpit instrument strip** shows live **speed, altitude, heading, and vertical speed**, with a color-blind-safe on-target bar and stall / instrument-failure annunciations. Reference panels — V-speeds, GPS status, and departure/approach briefings — open as a docked panel on iPad or a bottom drawer on iPhone.

### Step-by-Step Mode

When enabled (default), the current checklist item is highlighted. Tap it to mark it complete and advance to the next item, helping ensure nothing is skipped. Toggle it under **Settings > Checklist & Flight**.

### Learning Mode

Learning mode hides items that should be memorized so you can test your knowledge. Items configured as "memorizable" only appear when Learning Mode is off. In flight you can hold the hidden-content placeholder to reveal those items temporarily. Toggle it under **Settings > Checklist & Flight**.

### Multi-Page Phases

Some phases span multiple pages. A page indicator shows your position; swipe or tap to move between pages within a phase.

### Checklist Language

If a checklist is available in multiple languages, choose your preferred language under **Settings > Checklist & Flight > Checklist Language**. Options include Auto (follows device language), English, and French.

### Speed, Stall, and Estimated Airspeed

During the flying phases, AéroCheck shows a large speed indicator with color-coded guidance toward the target speed for the current phase, plus a stall warning (flashing red/white) when you drop below the aircraft's stall speed.

By default this shows **GPS ground speed** (`GND SPD`, in knots). Ground speed is not the same as the airspeed your panel shows — a head- or tailwind shifts it — so treat the on-screen stall warning as an awareness aid, never as a replacement for your aircraft's airspeed indicator.

**Estimated airspeed (experimental, Switzerland only).** When you enable *Show Estimated Airspeed* in Settings, the indicator instead estimates indicated airspeed by correcting GPS ground speed with mean wind from the nearest MeteoSwiss station. An estimated value is clearly marked: the label reads **`EST. IAS`** and the number is prefixed with a tilde (for example `~62`), so a derived figure is never confused with a measured one. The correction uses steady mean wind (not gusts), and readings that are too old are aged out rather than used.

**Aural stall alert (optional).** With estimated airspeed enabled, you can also turn on an **Aural stall alert** in Settings. When armed, it plays an audible warning if your speed drops below the stall speed — useful when your eyes are outside the cockpit. It is **off by default** and, like the visual indicator, is an aid only: always fly the aircraft's certified airspeed indicator.

---

## In-Flight Navigation

### Opening the Map

Tap the **NAV** button during a flight to open the full-screen navigation map, which shows your position with a heading indicator and a short ground-track trend vector.

### Map Layers

Open the **Layers** button to choose the base chart and toggle overlays.

**Base charts:**

- **Standard** — default Apple Maps view
- **Satellite** — Apple satellite imagery
- **ICAO Chart 1:500,000** — Swiss aeronautical chart from swisstopo
- **Landeskarten 1:100,000 / 1:50,000** — Swiss national maps
- **Segelflugkarte 1:300,000** — Swiss glider chart

The ICAO Chart and Segelflugkarte switch seamlessly with zoom. Swiss map layers are available within and near Switzerland.

**Overlays and markers** (from downloaded OpenAIP data — see [Aeronautical Data and Storage](#aeronautical-data-and-storage)):

- **Airspace** — OpenAIP airspace (CTR/TMA/restricted, etc.), as a vector overlay; raster airspace tiles are an optional, separate toggle
- **Airports** — with frequencies on tap
- **Navaids** — VOR / DME / NDB (gold markers, on by default)
- **Obstacles** — towers, masts, wind turbines (off by default; they are dense)
- **Reporting points** — VFR reporting points (on by default; compulsory points are emphasized)

If downloaded airspace data is aging, an amber **staleness badge** appears on the Layers button as a reminder that what's drawn may not reflect recent changes.

### Following a Flight Plan

With a plan active, the map adds leg-by-leg guidance: the next waypoint, track-up orientation, leg timing (EET/ETO), and a chronometer. A **FREDA** reminder prompts the periodic cruise check. Expand the bottom bar for the waypoint-progress list and the frequency panel.

### FREQ Panel

The radio-frequency panel displays:

- **Flight plan frequencies** (if a plan is active)
- **Nearby airport frequencies** — airports within 15 NM, showing ATIS, TWR, GND, APP, and other published frequencies from the OurAirports / OpenAIP data
- **Common Swiss frequencies** — emergency, information, and FIS
- **Nearby CTR frequencies** — control-zone frequencies based on your position

It is organized as **CURRENT / NEXT / EMERGENCY** so the frequency you need is one glance away.

### GPS Indicators

The navigation view shows real-time **ground speed** (knots), **altitude** (feet MSL), and a **GPS signal quality** indicator.

If the GPS position stops updating in flight (no fix for more than 90 seconds), the speed and altitude indicators show a **failure flag** instead of stale numbers, and the GPS status reads **Lost** — so a silent dropout is never mistaken for a valid reading. If location access is limited to "While Using the App," an amber **"Limited GPS"** banner reminds you to grant "Always" so the track keeps recording in the background.

### Offline Maps

The Swiss ICAO Chart and Segelflugkarte can be cached for offline use under **Settings > Navigation & Maps** (or the Data & Storage hub), roughly 100–250 MB. When a cached chart is available it is served from local storage, so the map works without a connection.

---

## Briefings

### Departure Briefing

Before departure, a dynamic briefing shows:

- **Airport** and **elevation** (detected from your GPS position)
- **Runway** (detected or manually selected)
- **Departure procedure** — first turn direction and level-off altitude (to be briefed verbally by the pilot)
- **Wind** (when available from MeteoSwiss)
- **Airspeeds** — rotation (Vr), best angle (Vx), best rate (Vy), best glide (Vbg), and others from the aircraft flight manual
- **Emergency procedures** — malfunction before rotation, engine failure after takeoff, minimum safe altitudes
- **Nearby reporting points** — compulsory and on-request VFR points around the field

### Approach Briefing

Before approach, a similar briefing covers the **airport** and **elevation**, **runway**, **wind**, **approach speeds** (initial, final, and stall), nearby **reporting points**, and the **go-around procedure**. When wind data is unavailable, it reminds you to check the windsock for calm, crosswind, headwind, or tailwind conditions.

---

## Flight Logging

### Automatic Timing

AéroCheck automatically records the key timestamps of your flight:

- **Block off / Block on**
- **Engine start / Engine shutdown**
- **Line-up** and **Takeoff / Landing** times

### Flight Events

The app automatically detects and logs:

- **Go-arounds** — climbing above a threshold after an approach
- **Touch-and-goes** — brief ground contact followed by takeoff
- **Full-stop landings** — the final landing of the flight

Detected go-arounds, touch-and-goes, and full stops are confirmed with a brief hold-to-confirm gesture (with a short undo), so an automatic detection is never logged against your wishes.

### Engine Hours

If enabled under **Settings > Checklist & Flight**, the app prompts for tachometer or Hobbs readings at engine start and shutdown, and calculates hours flown automatically.

### Viewing Flight History

Open the **Flight Log** to review past flights; each entry shows the date, duration, aircraft, and distance. Tap a flight for its **detail view**:

- An interactive map of your flight track
- An altitude (and speed) profile chart
- Route information (departure and arrival)
- A chronological timeline of all events
- Engine hours (if logged) and flight notes

The log filters by year (set it to **All time** to see every flight) and your flights sync across devices via iCloud.

### Exporting and Sharing

From the detail view, tap **Export** to save a flight as **GPX** (standard GPS exchange) or **JSON** (full data including events and metadata); multiple flights can be exported together as a **ZIP**. You can also generate a **share card** — a visual summary to post or message.

---

## Apple Watch and Companion Mode

AéroCheck can put your live flight on a second screen.

### Apple Watch

The **Apple Watch app** shows the current phase, ground speed, and altitude on your wrist, updated in real time from your iPhone (including the correct next phase in Circuit Mode). If the watch stops receiving fresh data — for example, out of range of the phone — a **"NO DATA"** banner appears so frozen values are never mistaken for live ones.

### Companion Mode

**Companion Mode** pairs an iPad and an iPhone over a direct Wi-Fi link (Wi-Fi Aware; requires **iOS 26 on both devices**) to turn the second device into a synced **wingman** screen. Pair the two devices once under **Settings > Companion Mode**; afterwards they connect automatically when both are nearby and ready.

The companion viewer offers two screens you can swipe between, and it switches automatically with the flight phase:

- **NAV** — a track-up next-waypoint view with the active plan
- **CHECKLIST** — a mirror of the master's checklist

Control is **two-way**: advancing the checklist or revealing hidden items on either device updates both, and both screens match the master's theme (day / sunlight / night). A **GPS chip** shows which device's GPS is in use.

**Shared GPS.** If the iPad has no GPS of its own (a Wi-Fi-only model), it can run the entire flight on the **iPhone's GPS** — the iPhone shares its position over the link, and the iPad records the track and drives the HUD as if the fix were its own.

If the connection drops or the data goes stale, the companion shows a **"Data stale — values may be frozen"** or **"Connection lost"** banner. The rule is simple: a staleness or disconnect banner means *stop trusting the numbers on that screen* until it reconnects. To save battery, an idle link disconnects on its own.

---

## Circuit Mode

Circuit mode is designed for **pattern training** (touch-and-go practice). When active:

- The checklist skips the **Cruise** and **Descent** phases
- After landing, the checklist returns directly to the **Before Departure** phase
- **Full-stop landings** are tracked automatically

Start it by tapping **CIRCUITS** on the home screen, or toggle it under **Settings > Checklist & Flight > Circuit Mode**.

---

## Aeronautical Data and Storage

AéroCheck draws on several external datasets so navigation works wherever you fly. All of it is downloaded on demand and cached on the device.

### What Data AéroCheck Uses

- **Airports and frequencies** — from OurAirports and OpenAIP (positions, runways, and radio frequencies)
- **Airspace** — OpenAIP controlled and restricted airspace, with vertical limits and frequencies
- **Navaids, obstacles, and reporting points** — OpenAIP map layers (see [Map Layers](#map-layers))
- **Charts** — Swiss ICAO, Landeskarten, and Segelflug charts from swisstopo

### Downloading Data

Download aeronautical data **by country or continent** from **Settings > Data & Storage** (or **Navigation & Maps**). Onboarding offers a recommended set for your region and its neighbours so you are covered from the first flight. Airspace, navaids, obstacles, and reporting points download together per country.

### Keeping Data Current

Aeronautical data changes regularly, so AéroCheck surfaces its freshness in several places:

- A **data indicator** on the home screen and a freshness summary in **Data & Storage**
- A snoozable **nudge** when a dataset is out of date
- The on-map **staleness badge** when downloaded airspace is aging (see [Map Layers](#map-layers))
- **Trip-aware prefetch** — when your active plan crosses a country you haven't downloaded, AéroCheck offers to fetch that data

Data refreshes when you bring the app to the foreground (there is no background download), so updates happen while you're using the app, not on battery in your pocket.

> Even current data is advisory. Always cross-check against official charts and NOTAMs.

### Offline Maps and Storage

Cache the Swiss ICAO Chart and Segelflugkarte for offline use (~100–250 MB). **Data & Storage** lists each dataset with its size and currency, and lets you update or delete cached data to reclaim space.

---

## Settings Reference

Settings are organized into a hub of dedicated pages.

### Aircraft & Subscription

Select your active aircraft, manage **AéroCheck Pro** (subscribe, start the trial, buy Lifetime, or restore purchases), and show or hide aircraft by aeroclub.

### Checklist & Flight

Step-by-step highlighting, learning mode, circuit mode, and checklist language; engine-hour (Hobbs) logging; and in-flight display options such as keeping the screen on and using UTC time.

### Navigation & Maps

Map layers and the **cockpit theme** (Auto / Day / Sunlight / Night, where Auto follows the system appearance); the OpenAIP airspace overlay and marker layers; offline chart caching; airport data; and the experimental **Estimated Airspeed** (with its optional Aural stall alert).

### Flight Planning

Route-builder and GPX export preferences.

### iCloud & Log

iCloud sync of settings and flights across devices, GPS recording interval, and flight-log preferences.

### Data & Storage

Aeronautical-data currency, per-country and continent downloads, offline chart cache, and storage management. See [Aeronautical Data and Storage](#aeronautical-data-and-storage).

### Companion Mode

Pair an iPhone and iPad as a synced second screen (Wi-Fi Aware; requires iOS 26 on both devices).

### About

App version, website, author and open-source information; the list of cached aircraft checklists and versions; **Replay Onboarding**; and hidden **Developer Options** (tap the version number five times to unlock).
