Welcome to the AéroCheck user manual. This guide covers every feature of the app — from your first launch through planning a flight, preparing it, flying it, and closing it out — so you can get the most out of each flight.

AéroCheck is a flight companion, not a certified instrument. Everything it shows — speeds, airspace, terrain, frequencies, fuel figures, mass and balance — is advisory and may be incomplete or out of date. It never replaces your aircraft's instruments and documents, current aeronautical charts, NOTAMs, or your own judgment as pilot in command.


## Getting Started

### First Launch

The very first screen is a **safety notice** you must acknowledge before anything else; it comes back whenever its wording changes materially. Then a short onboarding flow walks you through setup:

- **Location permission** — required for GPS flight tracking, ground speed, and the navigation map. Grant "While Using the App" or "Always" for full functionality. "Always" is what lets the track keep recording when the screen locks or you switch apps in flight; if you grant only "While Using the App," AéroCheck offers to **upgrade to "Always"** when you start a flight.
- **Maps and data for your region** — AéroCheck suggests the aeronautical data to download for your home country (detected from your device region or, if available, a GPS fix) and its neighbours, so airspace, frequencies, and map markers work where you fly. See [Aeronautical Data and Storage](#aeronautical-data-and-storage).
- **The four chapters** — a page introduces how AéroCheck follows a flight: Plan, Prepare, Fly, Close. See [Following a Flight](#following-a-flight).
- **Preferences** — checklist options (learning mode, circuit mode) and a tour of the in-flight features.

You can replay the whole tour anytime from **Settings > About > Replay Onboarding**.

### AéroCheck Pro

AéroCheck is free to use with the bundled **WT9 Dynamic (F-HVXA)** aircraft. The other aircraft are unlocked with **AéroCheck Pro**:

- A **monthly** or **yearly** subscription — the yearly plan includes a **7-day free trial** for eligible accounts.
- A one-time **Lifetime** purchase — pay once, no renewal.

Manage your plan under **Settings > Aircraft & Subscription**, where you can subscribe, start a trial, buy Lifetime, or **Restore Purchases** on a new device. Subscriptions renew automatically unless cancelled at least 24 hours before the period ends; you can cancel anytime in your device's Settings app. Premium aircraft and their checklists are delivered over the network, so an unlocked aircraft downloads its checklist the first time you select it and is then cached for offline use.

### The Home Screen

Home changes with your day.

- **On a day you have planned a flight**, that flight is the hero: its route, how ready it is, what is left to do, and a green **START THIS FLIGHT** button. Your aircraft moves to a strip below, next to your last flight. Underneath, **Fly without a plan** and **CIRCUITS** remain for a flight you did not plan in the app.
- **On any other day**, Home shows your **aircraft** — swipe the carousel to browse the aircraft you own — with **START FLIGHT** and **CIRCUITS**, your last flight, and either the route currently shown on the map, or an invitation to **Plan a flight**.

The badge on the **Flights** button counts the flights in your log.

### Selecting an Aircraft

The aircraft carousel shows the free WT9 Dynamic plus any premium aircraft you have unlocked; each card shows the registration, type, and the checklist version and item count. When a flight owns the hero, tap the **aircraft strip** to open the aircraft settings instead. Use **Settings > Aircraft & Subscription** to choose your active aircraft, manage your subscription, or show and hide aircraft by aeroclub.

### Starting a Flight

There are three ways to start, and they are different on purpose.

- **START THIS FLIGHT** on a planned flight (from Home's hero or from the flight's own screen) starts the checklist **and loads the flight's route** into the navigation map, on the aircraft the flight was planned with. If preparation items are still open, AéroCheck says how many and offers to **review the flight** first or **start anyway** — an unticked item may be a briefing nobody did.
- **START FLIGHT** / **Fly without a plan** starts the 16-phase checklist with no route and no follow-up. It is the shortcut for a flight you did not plan in the app; it never adopts a planned flight.
- **CIRCUITS** starts pattern work — see [Circuit Mode](#circuit-mode). A circuit session never adopts a planned cross-country either.

For premium aircraft, the checklist is fetched from the AéroCheck service. If it has not finished loading — for example because of a missing connection or an inactive subscription — AéroCheck will **not** start the flight with an incomplete checklist. It shows a **"Checklist Not Ready"** alert asking you to check your connection and subscription, so a wrong or empty checklist can never appear in flight.

### Starting from the Home Screen Widget

Add the **AéroCheck widget** to your iPhone or iPad home screen for one-tap starts. The widget shows a start button for each aircraft you own (aircraft you don't own are never shown). Tapping a button loads that aircraft's checklist and begins GPS tracking, exactly like the in-app START button; if a route is loaded on the map, the flight follows it. The medium widget also includes a shortcut to your flights.

---

## Following a Flight

A flight in AéroCheck has four chapters — **PLAN → PREPARE → FLY → CLOSE**. FLY is the checklist you know, unchanged. The other three carry the admin around it, as checks you tick, each with the link or tool it needs. Following a flight is optional: START FLIGHT works without one, and a flight that ran without one ends exactly as it always did.

### Plan New Flight

Open **Flights** (the first tab) and tap **Plan new flight**, or tap **Plan a flight** on Home. The sheet asks for what you know first:

- **When** — turn on *I know when I am flying* and pick the date and time. This is what makes the flight *today's* on Home and what drives the reminder the day before. Leave it off if you do not know yet.
- **Aircraft** — defaults to your selection.
- **Start from a saved route** — pick one of your routes and the flight is built from a **copy** of it: its waypoints, altitudes and fuel figures, on the aircraft you chose. See [Routes](#routes).
- **From → To** — or type the aerodromes: ICAO code or name, with completion. **Add stop** turns the flight into a [trip](#trips) with one leg per stop.

**Create flight** opens the new flight. Waypoints take the elevation of the aerodrome under them, and an aerodrome you fly over gets a transit altitude you can change.

### The Flight Screen

The header shows the route as a thumbnail (tap it to edit the route on the map), the route and date (tap them to open the **flight details**: pilot, aircraft, date, runway, fuel, times), a state chip — PLANNED, IN FLIGHT, or the close-out — and the **readiness ring**, which counts ticked items across Plan and Prepare.

Below it, one chip per chapter: tap a chip to expand or collapse that chapter. A chapter turns green when everything in it is done; FLY turns green once the flight has been flown.

Each task is a row with a checkbox, a hint, and often an action — *Open DABS*, *Copy ICAO flight plan*, *Fuel & times*, *Mass & balance*. Tap a row's text for a **note**; use the context menu to mark a task **not applicable**, which removes it from the ring rather than leaving it stuck at 9 of 10.

**AUTO rows** — *Route planned* and *Fuel plan* — are computed, not ticked. They settle themselves as soon as the plan satisfies them and un-settle if it stops: the fuel row shows **REQ** (trip + alternate + 45-minute final reserve + extra) against **FOB** (what you plan to carry) and stays open until FOB covers REQ. Edit either through *Fuel & times*.

### Plan

- **Route planned** (auto) — the flight has a route with at least two points. *View route* opens the map builder.
- **Fuel plan** (auto) — see above. The row also lists the fuel grades the destination reports, when airfield data is downloaded.
- **Mass & balance** — opens the calculator for the flight's aircraft; see [Mass & Balance](#mass--balance).
- **Aircraft reserved** — booked with your club. A reminder; AéroCheck talks to no booking system.

### Prepare

- **Weather briefed**; **DABS checked** and **GAFOR checked** appear on routes that touch Switzerland (each opens the official page); **NOTAMs checked** opens a NOTAM briefing.
- **Flight plan filed** — *Copy ICAO flight plan* puts a complete ICAO Doc 4444 message on the clipboard (fields 7–19, with your route, endurance and persons on board), and *Open skybriefing* takes you to file it. Ticking this is what arms the close-out reminder after landing.
- **PPR** — raised automatically for an aerodrome on your route that openAIP flags as prior permission required, so you call before you go. Appears only when the airfield data is downloaded.
- **Customs / border** — one row per foreign country the route crosses, with the country's **border pack**: whether a customs aerodrome is required, whether prior notification is required, and the lead time, for CH, FR, DE, AT, IT and GB, each with a link to the official source and the date it was checked. A country not yet curated says so and points you to the AIP. Where official sources disagree the row says that too. **Treat an unestablished requirement as one that applies until you have checked.** This is a reminder, not a clearance.
- **Nav log ready** — *Export nav log* hands you the route as an **A5 PDF for the kneeboard** (A4 from the route details), ready to print.

The day before a dated flight, a **preparation reminder** arrives at T−24 h.

### Fly

**START THIS FLIGHT** loads the route into the map, starts the checklist on the flight's aircraft and moves the flight into IN FLIGHT. From here on it is the 16 phases — see [Checklists and the In-Flight HUD](#checklists-and-the-in-flight-hud) and [In-Flight Navigation](#in-flight-navigation). Abandoning a flight (hold the tail number on the checklist screen) returns the planned flight to READY: what you prepared stays ticked.

### Close

After **END FLIGHT** the flight moves to CLOSE:

- **Close your flight plan** — appears **only if you ticked *Flight plan filed***. It is the one reminder with a search-and-rescue consequence: Zurich RCC is alerted 30 minutes after your ETA, so this row is red, the banner does not go away on its own, and a notification is scheduled 15 minutes after your landing is confirmed. Mark it closed from the banner, the row, or the notification itself.
- **Logbook entry** — opens **Logbook & costs** for the recorded flight; see [Logbook & Costs](#logbook--costs).
- **Fees paid** — the landing fee, when your destination has one; the row links to the operator's own tariff page where AéroCheck knows it (810 aerodromes across Europe). Appears only when cost tracking is on.
- **Debrief written** — a note to yourself.

**Finish** the flight when you are done; anything still open simply stops asking. Finished flights stay in **Past**.

### Trips

Several stops in *Plan new flight* create a **trip**: one flight per leg, shown as one entry in Upcoming. Only the first leg carries the departure time — the later legs depart when the earlier ones land, which the app cannot know.

Preparation that is really about the day — weather, DABS, GAFOR, NOTAMs, the filed flight plan, the nav log — is **shared across the legs**: tick it once. A shared tick **goes stale** when it no longer covers the next leg (a different day, or more than six hours before its departure), so yesterday's NOTAM briefing never shows as green on today's leg. Deleting a leg dissolves a trip that has only one leg left.

### Upcoming and Past

The **Flights** tab has two segments. **Upcoming** lists the flights and trips still owing something, close-out first, plus **Saved routes**. **Past** is the flight log — see [Flight Logging](#flight-logging); swipe a past flight to **Plan again**, which opens the creation sheet pre-filled with its route and aircraft and nothing else: last week's preparation is not this week's.

### Notifications

AéroCheck sends exactly two kinds of local notification: the **preparation reminder** the day before a dated flight, and the **close-your-flight-plan reminder** after landing when a plan was filed. Permission is asked when you create your first flight. Nothing else notifies.

---

## Routes

A **route** is a path — waypoints, distances, fuel figures — that you can fly on any day. It has **no date**: the date belongs to the flight that uses it. Routes are reached from **Flights > Saved routes** and from the navigation map.

### The Routes List

Each route shows a thumbnail, its endpoints, waypoint count, distance and time. Tap a route to edit it. Swipe left to **delete** or **duplicate**; swipe right to **Show on map**, which loads the route onto the navigation map to look at without starting a flight (**Clear from map** takes it off again). A route shown on the map that nobody flies is retired from the map after 72 hours.

To fly a route, create a flight from it — *Plan new flight > Start from a saved route*. The flight gets its own copy, so changing the fuel on next month's flight never rewrites last month's.

### Building a Route

AéroCheck's planner is **map-first**:

- Set your departure and destination in the **From → To** bar, then refine on the map.
- **Drag a waypoint** to move it; **drag the route line** to insert a new waypoint mid-route.
- Release a dragged point **near an airfield or navaid** to auto-snap to it — its name and frequency are filled in automatically.
- Dropping a waypoint uses **smart "cheapest insertion,"** placing it into the leg that adds the least detour.

### Route Details

Open **Flight details** (from a flight's title, or from the route) for the leg-by-leg breakdown — each waypoint's name and frequency, planned altitude, ground speed, estimated enroute time (EET), estimated time over (ETO), and magnetic course (MC) — and the header fields: **pilot** (pre-filled from Settings), aircraft, **runway** (pick from the departure aerodrome's own runways, or type one), instructor, and the **fuel** figures: fuel flow, trip, reserve, additional, extra and **fuel on board**. The **date** appears only when a flight follows the plan.

### Route Profile

The **interactive route profile** draws a terrain silhouette (swisstopo elevation in Switzerland, worldwide elsewhere) against your planned-altitude line. Drag a point to set its altitude, or hold to add one. Terrain-clearance and airspace-conflict warnings update live as you reshape the route.

### Airspace Conflict Checks

AéroCheck checks your planned route against OpenAIP airspace data and flags controlled or restricted airspace it may enter. Conflicts appear as a banner and highlight on the route; tap to see each airspace, its vertical limits, and its frequency. A green "no conflicts" result is shown only when airspace data is actually loaded — otherwise AéroCheck tells you airspace wasn't checked rather than implying you are clear.

The check follows the exact route geometry between waypoints (not just the endpoints), so a leg that clips the corner of a zone is still caught. Where the result depends on altitude, AéroCheck is deliberately conservative: it reports the worst-case severity, and when a zone's limit is published relative to the ground or as a flight level (AGL/FL), or when a leg has no planned altitude, the conflict is marked **"Altitude uncertain — verify vertical separation."** That qualifier means the horizontal conflict is real but the app cannot confirm whether your altitude keeps you clear — you must verify the vertical separation yourself against current charts and QNH.

When the route crosses a country whose airspace you have not downloaded, the builder offers the download — and fetches only the countries you are missing, not the ones you already have.

As always, airspace data is advisory and may be incomplete or out of date; it never replaces official aeronautical charts and NOTAMs.

### Exporting a Route

Routes export as **GPX** for Dynon, Garmin and other avionics, and as a **nav log PDF** in A4 or A5 (the kneeboard size). The **ICAO flight plan** message is one tap away from any flight that has a route.

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

In flight, the current checklist item is shown as the **hero** while past and future steps recede, so the next action is always obvious. A **cockpit instrument strip** shows live **speed, altitude, heading, and vertical speed**, with a color-blind-safe on-target bar and an instrument-failure flag when the GPS stops delivering. Reference panels — V-speeds, GPS status, and departure/approach briefings — open as a docked panel on iPad or a bottom drawer on iPhone.

### Step-by-Step Mode

When enabled (default), the current checklist item is highlighted. Tap it to mark it complete and advance to the next item, helping ensure nothing is skipped. Toggle it under **Settings > Checklist & Flight**.

### Learning Mode

Learning mode hides items that should be memorized so you can test your knowledge. Items configured as "memorizable" only appear when Learning Mode is off. In flight you can hold the hidden-content placeholder to reveal those items temporarily. Toggle it under **Settings > Checklist & Flight**.

### Multi-Page Phases

Some phases span multiple pages. A page indicator shows your position; swipe or tap to move between pages within a phase.

### Checklist Language

If a checklist is available in multiple languages, choose your preferred language under **Settings > Checklist & Flight > Checklist Language**. Options include Auto (follows device language), English, and French.

### Speed Guidance

During the flying phases, AéroCheck shows a large speed indicator with color-coded guidance toward the target speed for the current phase. It shows **GPS ground speed** (`GND SPD`, in knots). Ground speed is not the same as the airspeed your panel shows — a head- or tailwind shifts it — and the app has no pitot or angle-of-attack source, so it deliberately shows **no estimated airspeed and no stall warning**. Fly the aircraft's certified airspeed indicator.

### Cockpit Theme

Under **Settings > Checklist & Flight**, choose **Auto**, **Day** or **Night** (Night dims the instruments to a red/amber palette to protect dark adaptation; Auto follows the system appearance), and optionally turn on **High contrast in sunlight**, which switches to a high-contrast palette while the screen is near full brightness — the app cannot read ambient light, so screen brightness is the signal. The same options are one tap away in the in-flight **Options** panel.

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

If downloaded airspace data is aging, an amber **staleness badge** appears on the Layers button as a reminder that what's drawn may not reflect recent changes. When your data is old or missing for where you are, a banner says so — it never draws a stale map as if it were current.

### Following a Route

With a route loaded — automatically, when you started a planned flight — the map adds leg-by-leg guidance: the next waypoint, track-up orientation, leg timing (EET/ETO), and a chronometer. A **FREDA** reminder prompts the periodic cruise check. Expand the bottom bar for the waypoint-progress list and the frequency panel. If none of the route is on screen, a pill says which way it is.

### FREQ Panel

The radio-frequency panel displays:

- **Route frequencies** (if a route is loaded)
- **Nearby airport frequencies** — the nearest six airports within 40 NM, showing ATIS, TWR, GND, APP, and other published frequencies from the OpenAIP / OurAirports data
- **Common frequencies** — emergency, information, and FIS
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
- **Wind** — from a MeteoSwiss surface station in Switzerland, from model winds elsewhere
- **Airspeeds** — rotation (Vr), best angle (Vx), best rate (Vy), best glide (Vbg), and others from the aircraft flight manual
- **Emergency procedures** — malfunction before rotation, engine failure after takeoff, minimum safe altitudes
- **Nearby reporting points** — compulsory and on-request VFR points around the field

METAR and TAF join the briefing, and SIGMETs are shown on the map with their distance from your route.

### Approach Briefing

Before approach, a similar briefing covers the **airport** and **elevation**, **runway**, **wind**, **approach speeds** (initial, final, and stall), nearby **reporting points**, and the **go-around procedure**. When wind data is unavailable, it reminds you to check the windsock for calm, crosswind, headwind, or tailwind conditions.

---

## Flight Logging

### Automatic Timing

AéroCheck automatically records the key timestamps of your flight:

- **Block off / Block on** — block off is the first moving fix, block on the moment the aircraft finally comes to rest
- **Engine start / Engine shutdown**
- **Line-up** and **Takeoff / Landing** times

### Flight Events

The app automatically detects and logs **take-offs**, **go-arounds**, **touch-and-goes**, **stop-and-goes** and **full-stop landings**, from GPS altitude and speed and, on devices with a barometer, relative pressure altitude. Detected events are confirmed with a brief hold-to-confirm gesture (with a short undo), so an automatic detection is never logged against your wishes.

### Post-Flight Review

Confirmation prompts auto-dismiss, and in the circuit you will miss some. At flight end the whole track is re-analyzed; when it disagrees with what you confirmed, a **review sheet** shows the difference — apply the track's reading in one tap, override an event's type, or keep the log exactly as you recorded it. Confirmed events are never changed silently.

### Engine Hours

If enabled under **Settings > Checklist & Flight**, the app prompts for tachometer or Hobbs readings at engine start and shutdown, and calculates hours flown automatically.

### Viewing Flight History

Open **Flights > Past** to review flights; each entry shows the date, duration, aircraft, and distance. Tap a flight for its **detail view**:

- An interactive map of your flight track
- An altitude (and speed) profile chart
- Route information (departure and arrival)
- A chronological timeline of all events
- Engine hours (if logged) and flight notes
- **Logbook & costs** — see below

The log filters by year (set it to **All time** to see every flight), in UTC like every printed date, and your flights sync across devices via iCloud.

### Logbook & Costs

From a past flight's detail, or from a flight's CLOSE chapter, **Logbook & costs** holds three things.

**The logbook line.** A draft of the line an EASA Part-FCL logbook wants for this flight, per **AMC1 FCL.050**: date, departure and arrival with **UTC** block times, aircraft, single-engine and total time, PIC, landings, night and IFR time, function time, remarks. Dates, places, times and landings come from the recorded flight. **Function time is a judgment** the app cannot make from a flight, so it defaults from a signal — an instructor named on the flight, or [student mode](#student-pilots) — and is yours to change with **Edit**, together with the PIC name, night landings, night and IFR time (deliberately **not computed**: a plausible wrong number in a logbook column is worse than an empty one you fill in) and remarks.

**Logbook row** lays the same values out as your paper logbook's own twelve column groups, to copy from; **Copy line** and **Export CSV** hand them over as text; and **Export logbook PDF** from the Past list renders any selection of flights as logbook pages with page and carried-forward totals. AéroCheck is not a logbook of record and every page says so.

**Cost.** Set an hourly **rate** per aircraft (with the billing basis — block time, flight time or engine hours — and currency) once; each flight then shows its aircraft cost, plus any fees you add (a landing fee, fuel). The rate is snapshot onto the flight when computed, so a rate change next year does not rewrite last year. The Past list's summary shows the period total and says how many flights have no cost rather than pretending the total is complete. Turn the whole thing off under **Settings > Flight Planning** if you do not track what flying costs.

### Mass & Balance

The **Mass & balance** calculator, per aircraft: enter the empty mass and arm, the stations and their loads, and — if you want the landing case too — the fuel you expect to burn and which station it comes from. It reports mass, centre of gravity and, when you have entered the aircraft's **envelope** from the flight manual, whether take-off and landing are inside it. Without an envelope, or with a station left blank, the verdict is **unknown — never a pass**. No aircraft data ships with the app; everything here is what you entered from your own AFM.

### Student Pilots

If you fly with an instructor, turn on **Student pilot** under **Settings > Flight Planning** and enter the instructor's name. Your flights then log as **dual**, with the **instructor named as PIC** — that column states who commanded the aircraft — and the instructor is pre-filled on new flights. An instructor named on the flight itself always wins over the usual one, and your own edits to a line win over everything.

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

- **NAV** — a track-up next-waypoint view with the loaded route
- **CHECKLIST** — a mirror of the master's checklist

Control is **two-way**: advancing the checklist or revealing hidden items on either device updates both, and both screens match the master's theme. A **GPS chip** shows which device's GPS is in use.

**Shared GPS.** If the iPad has no GPS of its own (a Wi-Fi-only model), it can run the entire flight on the **iPhone's GPS** — the iPhone shares its position over the link, and the iPad records the track and drives the HUD as if the fix were its own.

If the connection drops or the data goes stale, the companion shows a **"Data stale — values may be frozen"** or **"Connection lost"** banner. The rule is simple: a staleness or disconnect banner means *stop trusting the numbers on that screen* until it reconnects. To save battery, an idle link disconnects on its own.

---

## Circuit Mode

Circuit mode is designed for **pattern training** (touch-and-go practice). When active:

- The checklist skips the **Cruise** and **Descent** phases
- After landing, the checklist returns directly to the **Before Departure** phase
- **Full-stop landings** are tracked automatically

Start it by tapping **CIRCUITS** on the home screen. Circuits are start-now only — there is no such thing as a planned circuit session — so a session never adopts a flight you planned. When it ends, AéroCheck **offers** to close it out: a light version of CLOSE with just the logbook line and a debrief. Dismissing the offer is a complete answer.

---

## Aeronautical Data and Storage

AéroCheck draws on several external datasets so navigation works wherever you fly. All of it is downloaded on demand and cached on the device.

### What Data AéroCheck Uses

- **Airports and frequencies** — from OurAirports and OpenAIP (positions, runways, fuel grades, PPR flags and radio frequencies)
- **Airspace** — OpenAIP controlled and restricted airspace, with vertical limits and frequencies
- **Navaids, obstacles, and reporting points** — OpenAIP map layers (see [Map Layers](#map-layers))
- **Charts** — Swiss ICAO, Landeskarten, and Segelflug charts from swisstopo
- **Landing-fee sources** — where each aerodrome publishes its own tariff (links and dates, never amounts), from the AéroCheck service

### Downloading Data

Download aeronautical data **by country or continent** from **Settings > Data & Storage** (or **Navigation & Maps**). Onboarding offers a recommended set for your region and its neighbours so you are covered from the first flight. Airspace, navaids, obstacles, and reporting points download together per country.

### Keeping Data Current

Aeronautical data changes regularly, so AéroCheck surfaces its freshness in several places:

- A **data indicator** on the home screen and a freshness summary in **Data & Storage**
- A snoozable **nudge** when a dataset is out of date
- The on-map **staleness badge** when downloaded airspace is aging (see [Map Layers](#map-layers))
- **Trip-aware prefetch** — when a route crosses a country you haven't downloaded, AéroCheck offers to fetch that data, and fetches only what is missing

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

Step-by-step highlighting, learning mode, circuit mode, and checklist language; the **cockpit theme** (Auto / Day / Night) and **High contrast in sunlight**; engine-hour (Hobbs) logging; and in-flight display options such as keeping the screen on and using UTC time.

### Navigation & Maps

Map layers, the OpenAIP airspace overlay and marker layers, offline chart caching, and airport data.

### Flight Planning

Your **pilot name** (used for the plan and the logbook), **Student pilot** with your instructor's name, **cost tracking** on or off, and the waypoint-proximity distance the map uses to advance to the next waypoint.

### iCloud & Log

iCloud sync of settings and flights across devices, GPS recording interval, and flight-log preferences.

### Data & Storage

Aeronautical-data currency, per-country and continent downloads, offline chart cache, and storage management. See [Aeronautical Data and Storage](#aeronautical-data-and-storage).

### Companion Mode

Pair an iPhone and iPad as a synced second screen (Wi-Fi Aware; requires iOS 26 on both devices).

### About

App version, website, author and open-source information; the list of cached aircraft checklists and versions; **Replay Onboarding**; and hidden **Developer Options** (tap the version number five times to unlock).
