Welcome to the AéroCheck user manual. This guide covers every feature of the app — from your first launch through planning a flight, preparing it, flying it, and closing it out — so you can get the most out of each flight.

AéroCheck is a flight companion, not a certified instrument. Everything it shows — speeds, airspace, terrain, frequencies, fuel figures, mass and balance — is advisory and may be incomplete or out of date. It never replaces your aircraft's instruments and documents, current aeronautical charts, NOTAMs, or your own judgment as pilot in command.


## Getting Started

### First Launch

The very first screen is a **safety notice** you must acknowledge before anything else; it comes back whenever its wording changes materially, and you can read it again at any time under **Settings › About › Safety notice**. A short onboarding then walks you through setup:

- **Use your location**: needed for the GPS track, ground speed and the map. Grant "While Using the App" or "Always". "Always" is what keeps the track recording when the screen locks or you switch apps in flight; if you grant only "While Using the App", AéroCheck asks to **upgrade to "Always"** when you start a flight.
- **Maps & Data**: the aeronautical data for your country (detected from the device region or, if available, a GPS fix) and its neighbours, the worldwide airport database and, optionally, the Swiss charts. See [Aeronautical Data and Storage](#aeronautical-data-and-storage).
- **Checklists**: the **Memory test** and the checklist language.
- **Flights**: the four chapters AéroCheck follows a flight through: Plan, Prepare, Fly, Close. See [Following a Flight](#following-a-flight).
- **Home aerodrome** (optional): where you are based. Plan new flight starts from it, and the landings you make there count as landings at base on the nav log. Set or change it later under **Settings › Flight Planning**.
- **Your map** and **In flight & features**: what the map draws (airspace, track vector, obstacles, the ICAO chart at every zoom), engine-hour logging and iCloud sync.

You can replay the whole tour at any time from **Settings › About › Replay onboarding**.

### AéroCheck Pro

AéroCheck is free to use with the bundled **WT9 Dynamic (F-HVXA)** aircraft. The other aircraft are unlocked with **AéroCheck Pro**:

- A **monthly** or **yearly** subscription; the yearly plan includes a **7-day free trial** for eligible accounts.
- A one-time **Lifetime** purchase: pay once, no renewal.

Open **AéroCheck Pro** from the **Aircraft** tab or from **Settings › Aircraft & Subscription** to subscribe, start the trial, buy Lifetime, or **Restore Purchases** on a new device. Subscriptions renew automatically unless cancelled at least 24 hours before the period ends; you can cancel at any time in your device's Settings app. Premium aircraft and their checklists are delivered over the network: an unlocked aircraft downloads its checklist the first time you select it, and it is then kept on the device for offline use.

When AéroCheck Pro is not active for the aircraft you selected (never bought, or lapsed), Today shows that aircraft locked with **Pro not active**, and a start is refused with "AéroCheck Pro isn't active", which offers **See plans** and **Restore Purchases**.

### The Five Tabs

On the ground, AéroCheck has five tabs along the bottom: **Today**, **Plan**, **Logbook**, **Aircraft** and **Settings**. Each one keeps its place while you look at another. In flight, the Cockpit takes the whole screen instead (see [The Cockpit](#the-cockpit)).

- **Today**: the next flight, the buttons that start one, your aircraft and your last flight. A badge on the tab means an ATC flight plan is still open after landing.
- **Plan**: three sections, **Flights** (the flights you are preparing), **Routes** (the routes you keep) and **Map** (the map, to look at the airspace before either). See [Following a Flight](#following-a-flight) and [Routes](#routes).
- **Logbook**: the flights you have flown. See [Flight Logging](#flight-logging).
- **Aircraft**: the aircraft you fly, its speeds, its usable fuel with full tanks and its cruise speed.
- **Settings**: see [Settings Reference](#settings-reference).

### Today

Today keeps the same slots in the same places every day, filled or not.

- At the top, two chips: **Data** (how current your aeronautical data is; tap it for Data & Storage) and **GPS Ready** when location access is granted (the signal itself shows in flight, see [GPS Indicators](#gps-indicators)).
- **NEXT FLIGHT**: the flight the start button is about, as a card with its time, aircraft, name and what is left to do ("Next: Weather briefed · 2 open in Plan and Prepare", or "Everything ticked — ready to fly"). That is today's flight, a flight you left in the air, or the next leg of a trip once you have landed at a stop. A trip shows as one card: its number of legs (**3 LEGS**), the whole route ("LSZQ → LSGE → LSZQ"), and a chip per leg with its time (✓ once flown). Tap the card to open the flight. With no such flight, the slot shows a flight you are following or still have to close, or **Plan new flight**.
- The green start button, always in the same place: **START THIS FLIGHT** when there is a flight for today (**RESUME THIS FLIGHT** once it is in the air), **START FLIGHT** otherwise. For a leg of a trip it reads **START FLIGHT** and names the leg under it ("LEG 1 · LSZQ → LSGE").
- Under it, **CIRCUITS**, always offered, beside **FLY WITHOUT A PLAN** when there is a flight for today, or **PLAN NEW FLIGHT** when there is not.
- **AIRCRAFT AND LAST FLIGHT**: the aircraft you fly (tap it to switch, see below) and your last flight (tap it for its details). With nothing planned, a route you have put on the map shows here as well; tap it to open **Plan › Routes**.

### Choosing Your Aircraft

Tap the aircraft on Today for the list of every aircraft you can fly: the free WT9 Dynamic, and each premium aircraft AéroCheck Pro unlocks that you have not hidden. Choose one to switch to it; **Speeds and details** opens the **Aircraft** tab.

The **Aircraft** tab lists the same aircraft under **YOUR AIRCRAFT**. Below the list come the selected aircraft's **SPEED REFERENCE**, its **FUEL** (the usable fuel with full tanks, see [Fuel on Board](#fuel-on-board)), its **PLANNING** (the **Cruise speed** your plans fly, see [Cruise Speed and EET Allowances](#cruise-speed-and-eet-allowances)), a link to **AéroCheck Pro**, and **Aircraft Visibility**, which opens Settings to show or hide aircraft one by one or by aeroclub.

Selecting a premium aircraft loads its checklist in the background, so it is ready before you start.

Your aircraft isn't in the list, or its checklist is older than the club's? Send the club's checklist from [aerocheck.app/send](/send): the registration first (one AéroCheck already has becomes an update), then the document as a PDF or photos of its pages. The club confirms before the aircraft goes live, and it joins AéroCheck Pro like the others; [aerocheck.app/clubs](/clubs) has the rest.

### Starting a Flight

There are four ways to start, and they are different on purpose.

- **START THIS FLIGHT** on Today, or **START FLIGHT** on a flight's own page, starts that flight: on the aircraft it was planned with, and with its route on the map. If Plan and Prepare still have items open, AéroCheck asks first ("Not everything is ticked"): **Review the flight** or **Start anyway**. An unticked item may be a briefing nobody did.
- **START FLIGHT** on Today, when there is no flight for today, starts the 16-phase checklist on the selected aircraft. If a route is on the map (**Show on map** in Plan › Routes), the flight flies it.
- **FLY WITHOUT A PLAN**, offered when there is a flight for today, starts another flight: no route, and today's flight is left as it is.
- **CIRCUITS** starts pattern work; see [Circuit Mode](#circuit-mode). A circuit session never takes over a planned flight.

A flight planned for another day starts from its own page, after a question; see [Fly](#fly).

AéroCheck will not start a flight it cannot run properly, and it says why:

- **AéroCheck Pro isn't active** for the selected premium aircraft: **See plans** or **Restore Purchases**.
- **Can't Start Flight**: the checklist of a premium aircraft could not be downloaded and there is no copy on the device yet (check your connection and try again), location access is off, or there is no GPS fix yet (try again once the GPS has one). A wrong or empty checklist never appears in flight.

### Starting from the Widget

Add the **AéroCheck widget** to the Home Screen of your iPhone or iPad (the system's, outside the app) for one-tap starts. It shows a start button for each aircraft you own (aircraft you don't own are never shown). A tap starts a flight on that aircraft through the same checks as START FLIGHT, and flies the route on the map if there is one. The medium widget also opens your logbook.

---

## Following a Flight

A flight in AéroCheck has four chapters: **Plan**, **Prepare**, **Fly** and **Close**. Fly is the checklist. The other three carry the admin around it, as tasks you tick, each with the link or the tool it needs. Following a flight is optional: START FLIGHT works without one, and a flight flown without one is logged all the same.

### Plan › Flights

The flights you are preparing, in the order they will be flown. At the top, the count (**UPCOMING · 3**) and **Plan new flight**.

- A flight waiting for its close-out comes first, under **NEEDS ATTENTION**.
- The next flight gets a card: its day, time and how long until; its map, distance (DIST), time (EET), waypoints (WPT) and aircraft (ACFT); the borders it crosses; its progress chapter by chapter; and its next task. Tap it to open the flight. A trip gets one card (**TRIP · 3 LEGS**): the whole route, its totals, and its **LEGS**, each with its time, distance and state (**FLOWN**, **NEXT**).
- Later flights follow, one line each, under their day ("TOMORROW · SUN 27 SEP"). Flights with no date come last, under **NOT SCHEDULED**.
- A flight whose day went by without it being flown moves after the others, under **DATE PASSED**, where you can still fly it, move it or cancel it.

### Plan New Flight

**Plan new flight** (on Today or in Plan › Flights) opens one sheet, the route first:

- **Route**, with **Airports**: a **From** and a **To** row where you type each aerodrome's ICAO code or name, with completion (the aerodrome's name shows beside a code it knows). **Add a stop on the way** adds a row just before To; three or more aerodromes make a [trip](#trips-and-stops) (LSZQ, LSGE, then LSZQ is LSZQ → LSGE → LSZQ). Drag a stop to reorder it, or remove it. The same aerodrome in From and To is a local flight ("Back to LSZQ: a local flight, or add a stop to land on the way."). With a [home aerodrome](#flight-planning) set, the sheet starts with it in both rows.
- **Route**, with **A saved route** (offered once you keep routes): the routes, searchable, each with its map. The flight is built from a **copy** of the route (its waypoints, altitudes and fuel figures). Under it, **Aerodromes on this route** lists those on the route or within 5 NM, in flying order, each with a **Land here** switch: each one you turn on adds a leg, and each leg keeps its part of the route. **Land somewhere else…** searches any aerodrome.
- **The legs**, once there is a stop (**2 legs**): each leg with its distance, time and departure ("≈" when estimated), and between two legs the time **On the ground** (30 min unless you change it) and a **Refuel** box (unticked, the next leg starts with the fuel this one leaves in the tanks).
- **When**: already set to tomorrow at 10:00, since the preparation reminder counts back from it (for a trip, it is leg 1's departure). Change it, or choose **No date yet**.
- **Aircraft**: your aircraft as chips, one tap.

The bar at the bottom says what it will create (the route, the day and time, the aircraft) above **Create flight**, or **Create trip · 3 legs**. The new flight opens on its page.

In the Logbook, swipe a flight to the right for **Plan this again**: the same sheet, filled in with that flight's route and aircraft and nothing else, since last week's preparation is not this week's.

### A Flight's Page

A flight has a page of its own, opened from Today or from Plan › Flights.

- **The header**: the route as a thumbnail (tap it to edit the route), the flight's name with its date and aircraft (tap it for [the flight sheet](#the-flight-sheet)), a pencil to name the flight, its state (PLANNED, READY, IN FLIGHT, CLOSE-OUT, DONE) and a ring counting what is done ("3 of 4 done" on iPad).
- **The chapters**: Plan, Prepare, Fly and Close, each with its count. A chapter turns green when everything in it is done; Fly turns green once the flight has been flown.
- **NEXT**, on top: the one thing to do next, larger, with its link or its tool. It is the task Today shows. When nothing is left before the flight, it reads "Everything done". After a landing with an ATC flight plan still open, a red card comes first (see [Close](#close)).
- Then each chapter lists what is left. The ticked and not applicable tasks fold into one row ("6 done"), which unfolds on a tap.

Each task has a tick, a hint and often a chip: a gold chip opens a tool in the app, a blue one opens an official page outside it. Touch and hold a task for **Not applicable**, which takes it out of the count. The two **AUTO** tasks, Route planned and Fuel plan, are computed, not ticked: they settle by themselves as soon as the plan satisfies them, and open again if it stops doing so.

At the bottom of the page, **Cancel flight** asks first ("Cancel this flight?"): the page, its tasks and the copy of the route made for it are deleted; your routes and the logbook are not touched. **Keep flight** leaves it as it was.

### Plan

- **Route planned** (AUTO): the flight has a route. **View route** opens the route editor.
- **Fuel plan** (AUTO): **REQ** (trip + alternate + 45-minute final reserve + extra) against **FOB** (what you plan to carry); it ticks itself once FOB covers REQ. A tap anywhere on the task, or on its **Fuel on board** chip, opens [Fuel on Board](#fuel-on-board). When the fuel on board is short, the task says so in amber ("Short by 12.0 L"). With airfield data downloaded, it also lists the fuel grades the destination reports.
- **Mass & balance**: opens the calculator for the flight's aircraft; see [Mass & Balance](#mass--balance).
- **Aircraft reserved**: booked with your club. A reminder; AéroCheck talks to no booking system.

### Prepare

- **Weather briefed**. On routes that touch Switzerland, **DABS checked** (**Open DABS**) and **GAFOR checked** (**Open MeteoSwiss**). **NOTAMs checked** (**Open NOTAM briefing**).
- **ATC flight plan filed**: **Copy ATC flight plan** puts a complete ICAO flight plan message on the clipboard (fields 7 to 19, with your route, endurance and persons on board), and **Open skybriefing** takes you to file it. Ticking this task is what arms the close-out reminder after landing.
- **PPR**: raised for an aerodrome on your route that openAIP flags as prior permission required, so you call before you go. It appears only when the airfield data is downloaded.
- **Border crossing**: one task per foreign country the route crosses, with the country's **border pack**: whether a customs aerodrome is required, whether prior notification is required, and the lead time, for CH, FR, DE, AT, IT and GB. Each comes with **Official rules** (and **Swiss side** when the flight touches Switzerland) and the date it was checked. A country not yet curated says so and points you to the AIP. Where official sources disagree, the task says that too. **Treat an unestablished requirement as one that applies until you have checked.** This is a reminder, not a clearance.
- **Nav log ready**: **Export nav log** opens the nav log as an A4 PDF, to read, print, mark up or share. The flight sheet's **Export** menu has it in A5 as well, the kneeboard size.

The day before a dated flight, a **preparation reminder** arrives at T−24 h.

### Fly

The Fly card says what comes next ("16 phases · checklist, nav and briefings") and starts it.

- For today's flight, a flight with no date, or the next leg after a stop: **START FLIGHT**. It selects the flight's aircraft, puts its route on the map and starts the checklist; the flight is then IN FLIGHT.
- For a flight planned for another day: its day ("Planned for Sat 27 Sep, 10:00") and a quieter **Start now**, which asks first ("Start this flight now?"), so tomorrow's flight is not started by mistake in place of today's. The page offers it in the same way when you open it from Plan › Flights.

From there on it is the 16 phases; see [The Cockpit](#the-cockpit) and [The Map](#the-map). If you abandon the flight (see [Ending or Abandoning a Flight](#ending-or-abandoning-a-flight)), the planned flight goes back to READY: what you prepared stays ticked.

### Close

After **END FLIGHT**, the flight moves to CLOSE-OUT.

- **Close the ATC flight plan**: only if you ticked **ATC flight plan filed**. It is the one task with a search-and-rescue consequence: if the plan was not closed on arrival, Zurich RCC is alerted 30 minutes after your ETA. So the flight's page opens on a red card, **Close your ATC flight plan**, with **Call 0800 437 837** and **Mark closed**; the Today tab shows a badge; and a notification comes about two minutes after END FLIGHT (or 15 minutes after a detected full-stop landing, if you have not ended the flight). If you landed somewhere other than planned, the card tells you which aerodrome to give the FIC.
- **Logbook entry**: **Logbook line** opens **Logbook & costs** for the recorded flight; see [Logbook & Costs](#logbook--costs).
- **Fees**: the landing fee, when your destination has one. **Flight cost** opens the cost of the flight, and **Operator's tariff** the operator's own tariff page, where AéroCheck knows it. It appears only when cost tracking is on.
- **Debrief**: a note to yourself.

**Finish** the flight when you are done; anything still open simply stops asking. A finished flight leaves Plan › Flights and stays in the Logbook.

### The Flight Sheet

Tap a flight's name on its page for the flight sheet: the flight's nav log data, in the order a flight is planned. Its title is the flight's name (tap it to rename the flight), with the date, the aircraft and the flight type under it. Changes are saved as you type.

- **ROUTE**: the map, the waypoints, the distance and the EET, with what the EET is built on (see [Cruise Speed and EET Allowances](#cruise-speed-and-eet-allowances)), and **Edit route**.
- **DEPARTURE**: **Date and time** (local time; every waypoint's ETO is counted from it until the take-off, then from the take-off itself, see [The Thumb Bar](#the-thumb-bar)), **Runway** (pick one of the departure aerodrome's runways, or type one) and **Flight Type**.
- **CREW AND AIRCRAFT**: **Pilot** (filled in from Settings when empty), **Instructor**, and the aircraft, which is the flight's.
- **FUEL**, as the paper nav log adds it up: **Fuel flow**, **Trip** (the route's EET at that flow), + **Alternate**, + **Final reserve 45′**, + **Extra**, = **Required**; then **On board**, with **Full tanks** and **= Required**, the **Margin** (in litres and minutes, green; or short, amber) and the **Endurance**. **DEFAULT** marks what the app filled in (the fuel flow and the 45-minute reserve), so you check it.
- **AFTER THE FLIGHT** (block and flight times, counters, landings), **NOTES** and **ATC FLIGHT PLAN DETAILS** (type, wake turbulence, equipment, alternate, persons on board, colour) stay folded to one line until there is something in them.
- **Show this route on the map**, or **Clear this route from the map**.

The **Export** menu at the top offers GPX, JSON, Excel (every waypoint, no page limit) and the nav log as **PDF · A4** or **PDF · A5**, then **Preview & Print**, **Save to Files…** and **Copy ATC flight plan**.

### Fuel on Board

A tap on the Fuel plan task opens **Fuel on board**:

- **REQUIRED**, large, with what it adds up to (trip + alternate + final reserve 45′ + extra). It shows once the route has a flight time.
- **ON BOARD**: type the litres, or tap **Full tanks** or **= Required** (rounded up to the litre); each button shows its figure.
- The result: how much is over the requirement, in litres and in minutes at the fuel flow (green), or **Short by … L** (amber). More than full tanks can hold is flagged too.
- **Fuel & times: flow, reserves, extra** opens the flight sheet for the rest.

**Full tanks** is the aircraft's usable fuel with full tanks. It comes from the aircraft's data when its checklist gives one; otherwise AéroCheck asks you for it once, for this registration, from the POH, and keeps it. Change your figure here (**Change**) or in the **Aircraft** tab, under **FUEL**. An empty field means "not entered"; 0 is an answer (empty tanks) and reads as short.

### Cruise Speed and EET Allowances

A leg's EET is its distance at the aircraft's cruise speed, flown as a true airspeed at the leg's altitude and with the wind of the plan, plus an allowance at each end for the departure and the arrival. Both come from your own flights once there are enough of them.

- **Cruise speed**: set it in the **Aircraft** tab, under **PLANNING** (**Cruise speed**, in KIAS, at the power you cruise at). Your figure wins; otherwise what your flights in this aircraft show (from 5 flights), then the aircraft's data, then 100 kt. The row says which one it uses ("Learned from 7 flights") and the true airspeed it makes at 5,000 ft. A leg where you typed an airspeed keeps yours.
- **Allowances**: +5 minutes at each end by default. From 3 flights at an aerodrome, the figure is learned from your flights there; before that, from 5 flights in all, the figure across all aerodromes.

The flight sheet says what the EET is built on, under the route ("departure +4 at LSZQ (4 flights) · arrival +5 at LFSB (all aerodromes, 14 flights) · cruise 95 KIAS (your figure)"), and the nav log prints it as **EET basis**. The ATC flight plan's total EET stops over the destination, without the arrival allowance.

A plan keeps the wind it was planned with, taken at the level each leg is flown at: a relaunch in flight does not drop it to zero, and the nav log prints the winds of the plan, not those of the day you export it.

### Naming a Flight or a Trip

A flight can have a name of its own, whatever its ends: tap the pencil beside its title (or the title of the flight sheet). The name becomes the title and the route moves to the line under it; an empty name shows the route again. A trip is named the same way, with the pencil beside its aerodromes on each leg; each leg keeps its own name.

### Trips and Stops

Several aerodromes in Plan new flight make a **trip**: one flight per leg, shown as one entry in Plan › Flights. Only the first leg has a departure time; the later ones show an estimate ("≈ 15:10 (est.)"), since each leaves when the one before lands.

**Add a stop…**, on a flight that has not flown yet, turns it into legs of one trip, each with its own logbook line, ATC flight plan, nav log and close-out. It lists the aerodromes within 5 NM of the route, in the order you reach them, with the frequency and a PPR mark; on a local flight, those within 40 NM, nearest first. Tick every aerodrome you will land at (in the order you will land there), or **Search any aerodrome**; each one ticked adds a leg. Set the time **On the ground** at each stop and its **Refuel** box (without a refuel, the next leg starts with the fuel this one leaves in the tanks), then **Split into 3 legs**. **Join with next leg** puts two legs that have not flown back into one flight.

A stop can be changed until the leg after it flies: that leg's page has **Stop at LSGE**, with its time on the ground and its Refuel box, and the departures estimated after it follow ("Leaves ≈ 15:10, when the leg before lands plus the time on the ground").

Each leg's page shows the trip (**TRIP · 2 of 6**, the shared tasks done), its legs (tap one to open it) and the preparation the legs share: **Aircraft reserved**, **Weather briefed**, **DABS checked**, **GAFOR checked**, **NOTAMs checked** and **Debrief** are ticked once for the whole trip. A briefing tick **goes stale** when it no longer covers the next leg (a different day, or more than six hours before its departure), so yesterday's NOTAM briefing never shows as done on today's leg; the row then says when it was last checked. Everything else (route, fuel, mass & balance, ATC flight plan, PPR, customs, nav log, fees, logbook) belongs to each leg.

At the bottom of a leg's page, **Cancel this leg** and **Cancel whole trip (3 legs)** sit side by side. The trip's question ("Cancel this trip?") lists the legs it deletes; the legs already flown stay, with their flights in the logbook.

If you land somewhere other than planned, the flight's page says so ("Landed at LSZE") and offers **Continue to** the planned destination as the next leg of the trip, or **Finish here**. Weather and NOTAM come back unticked on that next leg: you turned away from something.

### Notifications

AéroCheck sends exactly two kinds of local notification: the **preparation reminder** the day before a dated flight, and the **reminder to close the ATC flight plan** after landing, when one was filed. Permission is asked when you first follow a flight. Nothing else notifies.

---

## Routes

A **route** is a path (waypoints, altitudes, distances, fuel figures) that you can fly on any day. It has **no date**: the date belongs to the flight that uses it. A flight planned from a route gets its own copy, so changing next month's flight never rewrites last month's, and that copy stays with its flight rather than among your routes.

### Plan › Routes

The routes you keep. Each row shows the route's map, its name or its ends, its waypoints, distance and time, and a **Show on map** button: it puts the route on the map to look at without starting a flight, and START FLIGHT on Today then flies it. The route on the map is listed on top, under **On the map**, and its button reads **Clear from map**. A route on the map that nobody flies comes off it after 72 hours.

- Tap a route to edit it.
- Swipe left for **Archive**, **Duplicate** and **Delete** (which asks first). An archived route leaves the list; once anything is archived, **Routes** and **Archived · 2** (with the count) appear beside the search, and **Unarchive** brings a route back.
- Swipe right for **Show on map** or **Clear from map**.
- Touch and hold for the menu: **Edit**, **Rename** (any name, whatever the route's ends; empty shows the ends again), **Use ICAO codes…**, **Export** (GPX or JSON), and the actions above.
- The search field finds routes by name, aerodrome, waypoint or aircraft, ignoring case and accents; every word must match, in any order.
- The filter button shows the routes of one aircraft; **+** draws a **New Route** or opens **Import route**.

To fly a route on a given day, plan a flight from it: **Plan new flight › A saved route**.

### The Route Editor

The route editor is a map with **From** and **To** above it, the route profile under it, and the legs.

- Type the departure and the destination in **From** and **To** (ICAO code or name; the results are sorted by distance). The arrows between the two swap them.
- On the map, **drag a waypoint** to move it, **drag the route line** to insert a waypoint, or **touch and hold** an empty spot to add one where it lengthens the route least. A waypoint released within 2.5 NM of an aerodrome or a navaid (or 1.2 NM of a reporting point, when they are shown) takes its name, frequency and position.
- **The legs** are a table in the nav log's columns: **#**, **WAYPOINT** (with its call sign when it differs), **MC**, **NM**, **EET**, **ALT FT** (edit it in place) and ⚠. The figures are those of the leg *from* the waypoint; the last row is the destination. On the iPhone, the figures go under the name.
- **One selection** across map, profile and legs: tap a leg to select it, and it is highlighted in the table, on the map and on the profile, where each stands. Tap the selected row again to open the waypoint; tap a pin to select its row.
- **Set altitudes…** sets many waypoints at once: a **Fixed altitude**, or a clearance **Above terrain**, with a preview of the lowest clearance on each leg and of the airspace the new profile runs into. The departure and the destination keep theirs. A route with no planned altitudes (often an imported GPX) says so: **No planned altitudes**.

At the top: **Show this route on the map** (or **Clear this route from the map**), **Nav Log** (the flight sheet) and **Export GPX**; **Done** closes the editor. When the route crosses a country whose data you have not downloaded, a banner offers the download, and fetches only the countries you are missing.

### Route Profile

The **Route profile** draws the terrain along the route (swisstopo elevation when the whole route is in Switzerland, worldwide elevation elsewhere) under your planned altitudes, with the airspace the route crosses as blocks. Drag a waypoint's dot to set its altitude, or touch and hold elsewhere on the profile to add a waypoint, then drag it into place. The waypoints are numbered as on the map. Tap the title to fold the profile away; the arrows beside it make it taller.

### Airspace and Terrain Checks

AéroCheck checks the route against the downloaded OpenAIP airspace along its whole geometry, about every nautical mile, not only at the waypoints: a leg that clips the corner of a zone is still caught. An airspace counts as a conflict where your planned altitude is within 500 ft of its vertical limits; one crossed but cleared vertically is drawn faded on the profile. On a route with no planned altitudes, every airspace it crosses counts as a conflict. The check also warns when a planned altitude comes within 150 m of the terrain (**Terrain proximity**).

Conflicts show on their legs: ⚠ with a count in the leg's row, an amber pin on the map, a ⚠ above the profile where the conflict starts. The chip above the legs sums it up: **⚠ 3 conflicts**, **✓ No conflicts** or **? Not checked**. Tap it for the list (**‹ Legs** goes back): each entry gives the airspace's vertical limits and frequency. Tap an entry to highlight it on the profile and the map and select its leg; hold it to centre the map on it.

A green "no conflicts" appears only when both checks actually ran. Without airspace data, or without terrain data and planned altitudes, AéroCheck says **Airspace not checked** or **Terrain not checked** rather than implying you are clear. A limit published above the ground or as a flight level can only be estimated without QNH and terrain: verify the vertical separation yourself against current charts and QNH.

As always, the data is advisory and may be incomplete or out of date; it never replaces official aeronautical charts and NOTAMs.

### Importing a Route

**Import route** (the **+** menu in Plan › Routes) reads GPX and JSON. An imported route is a new route, planned for the aircraft you have selected, with its fuel flow.

A route exported from SkyDemon names its aerodromes after their place ("Samedan", "Bressaucourt"). The file carries their ICAO codes too, and AéroCheck offers them after the import: **Use ICAO codes?**, one switch per waypoint (Samedan → LSZS), all on, then **Use the codes** or **Keep the names**. The place name moves to the waypoint's remarks. The codes matter beyond the label: PPR, landing fees, fuel and frequencies are looked up by code. For a route imported before, **Use ICAO codes…** in its menu offers the aerodrome each waypoint sits on.

### Exporting a Route

Routes export as **GPX** for Dynon, Garmin and other avionics, and as JSON. The nav log comes as a PDF in A4 or A5 (the kneeboard size) from the flight sheet's **Export** menu, which also has **Copy ATC flight plan**.

---

## The Cockpit

In flight, AéroCheck shows one screen: the **Cockpit**. It is built for an iPad in portrait on a kneeboard, read from about 55 cm, and the iPhone shows the same Cockpit, sized for the phone (see [The iPhone](#the-iphone)). The screen stays on while a flight runs, and only then.

### Four Zones

From top to bottom, always in the same places:

1. **The header**: the aircraft, the phase and its place in the flight, the flight time, GPS and **Menu**.
2. **The instrument strip**: GS, ALT, TRK and, on the iPad, NEXT.
3. **The pane**: **CHECKLIST** or **MAP**, at full height.
4. **The thumb bar**: the big buttons, where the hand rests. Their places never change, so the hand learns them.

Colours keep one meaning in flight: cyan for what you can touch, magenta for the active route, green for normal or done, amber for a caution, red for a warning, white for data.

### The Header

- **The registration**, with "(for circuits)" and the touch-and-go and go-around counts in circuit mode. Touch and hold it to abandon the flight (see [Ending or Abandoning a Flight](#ending-or-abandoning-a-flight)).
- **The phase** and its place ("CRUISE CHECK 10/16"). Tap it for **Select Phase**, the list of all 16 phases with their status and each one's page in the paper checklist.
- **The flight time**, counted from ENGINE START.
- **GPS**, in the colour of its status: green good, orange degraded, red lost or not recording (see [GPS Indicators](#gps-indicators)). Tap it for the **GPS Status** drawer: the signal and why it is degraded or lost, the accuracy, the time of the fix, the altitude, the position (tap it to copy) and the points recorded. When location access is limited to "While Using the App", the drawer says so. On the Companion iPhone's GPS, it reads **GPS · iPhone**.
- **Menu**: see [The Menu](#the-menu).
- An iPhone icon appears while a companion is connected.

### The Phase Bar

Under the header, one segment per phase: the current one taller, the others coloured by their status (green done, or outlined in green for a landing check confirmed after the landing; orange skipped; red when a required ENGINE START or ENGINE SHUTDOWN was not pressed; amber for a check owed, for Cruise while FREDA is due, or for a landing check you were not sure of; grey not started). Tap a segment to jump to that phase. A jump forward leaves the phases behind it the way NEXT does: they turn orange, and their unchecked items go on the [deferred list](#deferred-items-and-next). Coming back to a phase takes its open items off that list again. In circuit mode, a bracket with ↻ marks the phases that repeat each lap (Climb to Landing), and Cruise and Descent are left out.

### The Instrument Strip

From Taxi to After Landing, whenever the aircraft moves, the strip shows:

- **GS kt**: GPS ground speed. In a phase with a target speed it is green within 5 kt of the target and amber outside it, with a bar that fills as you get closer; without a target (taxi, run-up) it is plain white.
- **ALT ft**: GPS altitude, with the vertical speed under it (↑ or ↓, from 50 ft/min).
- **TRK**: the GPS track.
- **NEXT** (iPad): the next waypoint of the route on the map, in magenta, or the diversion field.

Ground speed is not the airspeed your panel shows (a head- or tailwind shifts it), and the app has no pitot or angle-of-attack source: it deliberately shows **no estimated airspeed and no stall warning**. Fly the aircraft's certified airspeed indicator. When the GPS degrades, a failure flag covers the values; when it is lost (no position for 45 seconds), only the flag remains, so a silent dropout is never mistaken for a valid reading.

### Checklist or Map

**CHECKLIST | MAP** switches the pane. The pane also follows the flight by itself: the checklist on the ground, around take-off and landing, and whenever a checklist is open; the map in Climb, Cruise and Descent once that phase's checklist is worked through. A check from memory (see [Memory Test](#memory-test)) has no list to show, so it opens on the map, where the [check slot](#the-check-slot) takes it: in Climb, Cruise and Descent, and in Approach, Landing and After Landing too. A check coming due never switches the pane. A tap on CHECKLIST or MAP overrides the choice until the flight moves on: the next phase, or the check done or opened again.

Beside the switch: **V-SPEEDS** always, **BRIEFING** in Before Departure and in Descent, and **NEXT** while the list still has items open (it leaves through the review, see below). On the map, an amber chip with the number of deferred items follows you.

### Working the Checklist

The checklist runs step by step, as on paper with a finger on the line. The current item is framed where it stands in the list, larger, with its place ("3 / 11"); the items checked above it are dimmed with a tick, and the ones below wait their turn. The list scrolls to keep the current item near the top.

- **CHECK**, in the thumb bar with the item's challenge under the word, checks the current item and moves the frame to the next one.
- **DEFER** ("keep for later") passes over the current item without checking it: it stays in the list in amber and goes on the deferred list.
- Tap a checked (or deferred) item to go back to it: that item and everything after it are open again.

On the iPad the list only reads, and CHECK is the way to check. On the iPhone, a tap on the list checks as well.

When the last item is checked, the checklist's closing line ("… CHECK COMPLETED") turns green, and the big button becomes **NEXT: <phase>**, with "All checked" (or the number of deferred items) under it; at the end of Before Departure it reads **READY FOR LINE UP** (see [The Thumb Bar](#the-thumb-bar)). If the phase has its own button still to press (ENGINE START, ENGINE SHUTDOWN), that one pulses first.

### Deferred Items and NEXT

NEXT with items still open lists them first ("3 items not checked", with the phase): **BACK TO CHECKLIST** stays on the phase, at the first open item; **CONTINUE, CHECK LATER** leaves it, and the unchecked items become deferred items. The phase turns orange.

Deferred items follow you until you check them. An amber row on top of the checklist ("2 deferred items", **Review**) opens **Deferred items**, phase by phase, each with its own **CHECK**. On the map, the amber chip with the count opens the same list. A skipped phase turns green once its last deferred item is checked; a phase missing its ENGINE START or ENGINE SHUTDOWN stays red.

In circuit mode, a go-around, a touch-and-go or a full stop starts the repeated phases clean, their deferred items included: what you put off on the last lap is asked again on this one.

### When a Check Is Due

The flight says when each check falls due, without pulsing, beeping or switching the pane. Before its moment a check is dark (you can still do it early); at its moment it turns amber.

- **Climb**: 500 ft above the field, after the take-off, not on the take-off roll.
- **Cruise**: at the level-off.
- **Descent**: once the aircraft is really going down. A dip you climb back from withdraws it.
- **Approach**: 5 NM from the destination; without a route, when you descend near an aerodrome.
- **Landing**: at circuit height near the aerodrome you are approaching. It is shown, never asked: from there to the runway there is nothing to press.

The other checks (on the ground, after landing) are due as soon as they come up, and so is every check when the device has no airport data.

A check the flight moves past while it is still open turns **owed**, once: filled amber, with what passed it ("owed · you levelled off with it open"), until you do it (it then counts as done late) or skip it. The flight's debrief lists it (see [Checks](#checks)).

### The Check Slot

On the map, the **check slot** holds the current check, first in the bottom row, on the iPad and the iPhone (on an iPad in landscape, at the top of the side column). It names the check and what it needs, and a tap does it:

- A check with a list: "CRUISE CHECK · 5 items". The tap opens the checklist, and the map comes back after the last CHECK.
- A check from memory: "from memory · one tap when done". The tap records it done.
- An owed check: its reason ("owed · the descent began with it open"), and the same tap.
- Once a check is done, the slot offers the next one ("next check"), dark until its moment, then amber; a tap goes on to it (and records it done, for a check from memory).
- A phase button still to press: "ENGINE START first", which opens the checklist. Once the check before departure is done: **READY FOR LINE UP**, "then LINE UP CHECK".
- From circuit height: the landing check, dashed, "nothing to press".

In Approach and Landing, and from circuit height, **GO AROUND** and **TOUCH-AND-GO** sit beside the slot in place of MARK, Divert and More (see [The Thumb Bar](#the-thumb-bar) for how they work).

### FREDA

In cruise, once the cruise check is done, **FREDA** (fuel, radio, engine, direction, altimeter) takes over from it. FREDA is due every 10 minutes, or at a waypoint passed 5 minutes or more after the last one, whichever comes first.

The check slot says when the last one was done ("FREDA ✓ 14:34", the cruise check's time at first) and counts down to the next ("FREDA in 6 min"; a tap opens the checklist). When FREDA is due, the slot turns amber (**F·R·E·D·A**, with the waypoint's name on the iPad) and the Cruise segment of the phase bar too: one tap records it, and a message ("FREDA done at 14:34") offers **UNDO** for six seconds. On the checklist pane, the FREDA button in the thumb bar does the same: dimmed until the cruise check is done, then counting down, amber when due, and a tap records FREDA (early, if you like). The cruise list itself is not reset.

FREDA stops at the descent; one that was due and not done is logged as missed. There is no FREDA in circuit mode.

### The Landed Card

After a full-stop landing (outside circuit mode), the landed card comes up over the Cockpit: "LANDED · LSZQ · 14:44 · Was the landing check done before touchdown?", with **YES, IT WAS DONE** and **NOT SURE**. Yes records the landing check as confirmed after the landing (outlined in green on the phase bar); Not sure puts it in the debrief, in amber. Either way the full stop is logged at the touchdown and the checklist goes on to After Landing. When the landing check was done before touchdown, the card says so and offers **NEXT: AFTER LANDING CHECK**.

The card waits for an answer, however long the taxi off the runway takes, and goes by itself only on the next take-off roll. The Companion iPhone can answer it too. In circuit mode, a full stop brings the full-stop card instead (see [Circuit Mode](#circuit-mode)).

### Memory Test

Every check is shown by default. Turn on **Memory test** (in the Menu, under **Settings › Checklist & Flight**, or in onboarding) to hide the checks you should know by heart, so you can say them from memory. A **MEMORY TEST** banner at the end of the list says how many are hidden; hold it to show them for the current phase.

A check with every item hidden is done in one tap. On the checklist pane, **✓ CLIMB CHECK DONE** (with "NEXT: CRUISE CHECK · from memory" under it) records it done from memory, in green, and opens the next check; in the [check slot](#the-check-slot), a tap records it. A message ("CLIMB CHECK done from memory") offers **UNDO** for six seconds, which takes both back. Memory test replaces the former learning mode.

### V-SPEEDS and BRIEFING

**V-SPEEDS** opens the aircraft's speeds (indicated airspeed, in knots) in a drawer from the bottom. On the iPad it is one fixed table, the same in every phase: **STALL & GLIDE** first, on a panel of its own (Vso and Vs in amber, Vne in red), then **TAKE-OFF & CLIMB**, **APPROACH & LANDING** (in the order they are flown), **LIMITS**, **OTHER** and **CROSSWIND** (T/O and LDG). The phase only decides which cells are framed, where they stand: Vr before departure and on the line-up, Vx below 300 ft above the departure field and then Vy in the climb, Vno and Va in cruise, Va and Vbg in the descent, the approach speeds on approach, Vfinal and Vso on landing. On the iPhone the speeds are a list, with the phase's highlighted. Tap outside the drawer, or drag it down, to close it.

**BRIEFING** opens the departure briefing in Before Departure and the approach briefing in Descent; see [Briefings](#briefings).

### The Thumb Bar

Besides CHECK, DEFER and NEXT, the thumb bar carries each phase's own buttons, in the checklist's language:

- **ENGINE START** (Engine Start) and **ENGINE SHUTDOWN** (Shutdown): a tap records the time. Once it is recorded, hold the button 1.5 s to change it; AéroCheck asks first.
- **READY FOR LINE UP** is the NEXT of Before Departure: with every item checked, the big button reads READY FOR LINE UP, with "then LINE UP CHECK" under it. The tap records the line-up time and goes on to Line Up. The ETOs count from the line-up until the take-off shows in the track (within about 30 seconds of lift-off), then from the take-off.
- **FREDA** (Cruise): see [FREDA](#freda).
- In **Landing**, **GO AROUND** and **TOUCH-AND-GO** sit above the thumb bar, and in **After Landing**, **FULL STOP LANDING**. Each needs a 1-second hold (**Hold to confirm**), so a stray touch cannot fire it, and shows its count. A go-around or a touch-and-go takes the checklist back to Climb.
- In circuit mode, **GO AROUND** and **TOUCH-AND-GO** are single-tap buttons in the thumb bar instead, to correct a missed detection at once.
- **END FLIGHT** takes NEXT's place once the last phase is checked.

When **Log Engine Hours** is on (**Settings › Checklist & Flight**), the checklist offers the hour meter at the end of Before Engine Start and in Engine Start (it asks by itself on entering Engine Start if you have not entered it yet), and again after ENGINE SHUTDOWN, in Shutdown and At the Hangar.

### The Menu

**Menu**, at the right of the header, opens:

- **DISPLAY**: the **Cockpit theme**, **Auto**, **Day** or **Night** (Night dims to red to protect your night vision; Auto follows the device's appearance), and **High contrast in sunlight**, which switches to a high-contrast palette while the screen is near full brightness (the app cannot read the ambient light, so brightness is the signal).
- **OPTIONS**: **Memory test**, **Always Use UTC Times**, and **Enable Companion Mode** once a device is paired.
- **GPS STATUS**: the signal and the points recorded.
- **FLIGHT TIMES**: engine start, take-off, landing and shutdown, as recorded.
- **END FLIGHT**, from any phase ("Ends the flight now, in any phase."), after a question.

### Checklist Language

When an aircraft's checklist exists in several languages, choose yours under **Settings › Checklist & Flight › Checklist Language**: Auto (follows the device language), English or French. If your language is not available for an aircraft, English is used.

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

In circuit mode, Cruise and Descent are skipped.

### Ending or Abandoning a Flight

**END FLIGHT** (the big button after At the Hangar, or in the Menu at any phase) asks first ("End Flight?"), then saves the flight to your logbook and stops the GPS recording. A followed flight then moves to its close-out ([Close](#close)); a circuit session offers a light close-out ([Circuit Mode](#circuit-mode)). If the track disagrees with the events you confirmed, a review follows ([Post-Flight Review](#post-flight-review)).

To abandon a flight, touch and hold the registration in the header for 1.5 s, until the ring around the aircraft icon closes. **Abandon Flight** discards the flight without saving it; its GPS data is lost.

---

## The Map

The map is the same in two places: the **MAP** pane of the Cockpit, and **Plan › Map** on the ground, so the map you plan on is the map you fly with. It opens on your position, at the zoom you left it.

### The Next Waypoint

With a route on the map, the next waypoint sits on top: its name in magenta, then **BRG**, **DIST** (NM), **ETE** and **ETA**. ETE is given in minutes ("13 min", or "1:07 h" past the hour), so it does not read as a clock time; ETE and ETA appear only above 30 kt, so a taxi at 8 kt does not promise an hour and a half to the first waypoint. On the iPad it is a card; on the iPhone, one line. Tap it for every leg and every frequency: the panel opens under the chart, which clears its controls and frames the aircraft and the next waypoint. A tap on the chart closes the panel and puts the map back as it was.

The legs list each waypoint with its planned leg time, the time flown, and how far ahead (▲) or over (▼) you are, then the destination with the distance left and the ETA. Tap a waypoint ahead to look at it on the map, then **Direct to** to fly straight to it. Tap one already passed to go back to that leg ("Go back to this leg?"): its crossing and the later ones are cleared, and the leg timer restarts.

In flight, a waypoint is passed automatically, from the GPS track, as you pass it (abeam included), whichever pane is on screen. A message ("VRP1 marked automatically at 10:42") offers **UNDO** for six seconds; a waypoint taken back waits for MARK. If none of the route is on screen, a pill says where it is ("Route 12 NM · 045°"); **Show** frames it.

### The Map Sheet

**Map** opens everything about how the map looks, in one sheet:

- **Base chart**: **ICAO chart** (the Swiss aeronautical chart 1:500,000, which becomes the glider chart, the Segelflugkarte 1:300,000, when you zoom in, unless **Force ICAO Chart Layer** is on), **National map**, **SWISSIMAGE aerial**, **Satellite** and **Standard map**. The Swiss layers are available within and near Switzerland. In offline mode, the cached ICAO chart is the only one.
- **Presets**: **Cruise** shows airspace and reporting points; **Approach** adds airports and obstacles; **Everything** shows every marker. Airspace stays on in all three.
- **Airspace & charts**: **Airspace** (the OpenAIP airspace, drawn as a vector overlay) and **Map tiles** (OpenAIP's raster tiles, off by default). When the airspace is on and no data is downloaded, the sheet says so and offers **Download data…**.
- **Map markers**, from the downloaded OpenAIP data (see [Aeronautical Data and Storage](#aeronautical-data-and-storage)): **Airports** (with frequencies on tap), **Navaids** (VOR, DME, NDB), **Reporting points** and **Obstacles** (towers, masts, wind turbines; off by default, they are dense). **Show all** or **Hide all**.
- **Flight**: **Track vector**.

When the downloaded airspace is aging, an amber mark sits on the **Map** button, and the sheet explains it ("Airspace data is out of date") with **Update**, so you know that what is drawn may not reflect recent changes.

### Map Controls

Under the next waypoint on the iPad, and at the foot of the chart on the iPhone: **Map**, **North up** / **Track up**, **Centre** and the zoom buttons. **Centre** fills in once you have moved the map off the aircraft, and puts it back. Pinching zooms too.

### Frequencies

Along the bottom of the map, the two frequencies to have set: **NOW**, the one to talk to now (within about 10 NM of an aerodrome, its contact frequency; en route, the area FIS), and **NEXT**, the next one you will need (the next aerodrome on the route, else the nearest control zone ahead, else the hand-over between FIS and an aerodrome; when diverting, the diversion field). Tap them for the legs and the **RADIO FREQUENCIES**: NOW and NEXT, **All frequencies** along the way (the nearest aerodrome, the route's waypoints, the area FIS, nearby control zones), and the emergency frequency, 121.500, always at the foot.

### Leg Timer and MARK

In flight, with a route on the map, the thumb bar under the map holds:

- **The check slot**, first; see [The Check Slot](#the-check-slot).
- **START LEG** starts the leg timer. The big button then becomes **MARK** with the waypoint's name, and the leg timer under it (on the iPad, "LEG 2:05 / 17:32": the time on the current leg and the planned leg time; ‖ when paused): tap it as you pass the waypoint to record its time over and start the next leg.
- **Divert**: see below.
- **More**: pause or start the chronometer, **Reset chronometer**, **Legs and frequencies**, and **Routes**.

Without a route on the map, **Routes** follows the check slot. In Approach and Landing, **GO AROUND** and **TOUCH-AND-GO** take the place of MARK, Divert and More.

For six seconds after a MARK or a reset, a message ("LSGC passed at 10:42", "Leg timer reset") offers **UNDO**: a mis-tap in turbulence is taken back with one tap.

On the ground, and in Plan › Map, the thumb bar holds **Routes** instead: nothing is timed or marked before the flight exists.

### Divert

**Divert** (in flight, in the thumb bar) answers "where do I go instead?" in two taps and no typing. It lists the aerodromes around you, **Ahead · soonest first** and **Behind · turn back**, with the destination and the alternate; tap one to see it, then **DIVERT TO** it. Tapping the destination itself is **DIRECT TO**, not a diversion. Glacier and mountain landing sites, heliports and closed fields are not listed. With a route on the map, an airport's callout on the map offers the diversion too.

A diversion changes where you navigate to and nothing else: the next waypoint shows **DIVERT** and the field, the frequencies follow it, and **Resume route** takes you back to the route in one tap. With an ATC flight plan filed, the iPad's card reminds you to tell FIS ("ATC flight plan filed: tell FIS you are diverting to …"). Nothing administrative moves until you are on the ground; for what the flight's page offers after the landing, see [Trips and Stops](#trips-and-stops).

### Track Vector

The track vector projects your smoothed ground track 5 minutes ahead, with ticks at 1, 2 and 5 minutes. It hides below 5 kt, where a track means nothing. Turn it off in the Map sheet (**Track vector**) or under **Settings › Navigation & Maps**.

### GPS Indicators

The GPS button in the Cockpit's header shows the signal in its colour; tap it for the GPS Status drawer (see [The Header](#the-header)).

- **Green** (**Good**) takes a fix from the satellites, within 100 m, in the last 20 seconds. A parked aircraft stays green as long as the receiver has a fix.
- **Orange** (**Degraded**): the fix is worse than 100 m, nothing has come for 20 seconds, or the positions come only from Wi-Fi or cell towers ("No satellite fix · network position"), so an iPad indoors on Wi-Fi is not green. The drawer says how long since the last position ("No position update for 25 s").
- **Red** (**Lost**): no position for 45 seconds, or no location access. In flight, the instrument strip then shows a failure flag instead of stale numbers.

An external GPS receiver's fixes count as satellite fixes. If location access is limited to "While Using the App", the GPS Status drawer says so ("Limited GPS …"), so you can grant "Always" and keep the track recording in the background.

### Offline Maps

The Swiss ICAO chart and the Segelflugkarte can be cached for offline use under **Settings › Navigation & Maps › Offline Maps** (up to about 250 MB), with **Offline Mode** to use the cache only. A cached chart is served from the device, so the map works without a connection. An **OFFLINE** or **CACHED** badge at the bottom left of the map says which; tap it for the details.

---

## The iPhone

The iPhone flies with the same Cockpit as the iPad: the same zones, in the same order, with the same words. Its sizes are the iPad's × 0.85: a phone is read closer, in the hand or on a yoke clip, so the text reaches the eye at the same angle.

### The Cockpit on the Phone

- **The header, on two rows**: the registration, the flight time, GPS and **Menu** on the first; the phase and its place on a line of its own under them.
- **The strip** has three cells, GS, ALT and TRK; the next waypoint is on the map.
- **CHECKLIST | MAP** runs across the width, with **V-SPEEDS** beside it. **BRIEFING** and **NEXT** appear at the top of the list, only while they apply; on the map, **BRIEFING** and the amber chips sit over the chart.
- **CHECK** and **DEFER** in the thumb bar, as on the iPad, and a tap anywhere on the list checks the current item too.
- **V-SPEEDS** is a list, with the phase's speeds highlighted and the maximum crosswind under it.
- A checklist row too long for one line puts the response under the challenge. The list opens on the current item.

### The Map on the Phone

The next waypoint takes one line (its name in magenta, then BRG, DIST and ETE), and the controls sit at the foot of the chart: **Map**, one button showing the orientation (**North up** or **Track up**; a tap switches it) and **Centre**. Pinch to zoom. NOW and NEXT, and the thumb bar (the check slot, MARK with the waypoint's name and the leg time under the word, Divert, More), are under the chart. In flight with no route on the map, **Routes** sits where the next waypoint would be.

### The Phone on Its Side

On its side, the phone shows two columns. On the left, the Cockpit's controls: the header, the phase button (the phase and its place, with the progress drawn inside it; a tap opens **Select Phase**), CHECKLIST | MAP with V-SPEEDS, the strip, and the thumb bar at the foot, where the thumb is. On the right, the pane at full height. On the map, the frequencies run along the bottom of the chart on two lines, and the foot of the column holds the check slot and MARK, with Divert and More stacked so that MARK keeps its width.

---

## Briefings

**BRIEFING** in the Cockpit opens the departure briefing in Before Departure, and the approach briefing in Descent.

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

The app detects **take-offs**, **go-arounds**, **touch-and-goes** and **full-stop landings** from GPS altitude and speed and, on devices with a barometer, relative pressure altitude. A take-off is logged without asking. A go-around or a touch-and-go comes up as a card ("Go-around detected at LSZQ") with **Dismiss** and **Confirm**; it goes away by itself after 20 seconds and never confirms itself, so a detection is never logged against your wishes. A full stop brings [the landed card](#the-landed-card), or in circuit mode the full-stop card, whose **Confirm** makes it a stop-and-go (see [Circuit Mode](#circuit-mode)).

### Post-Flight Review

The go-around and touch-and-go cards go away by themselves, and in the circuit you will miss some. After END FLIGHT the whole track is analysed again; when it disagrees with what you confirmed, **Flight review** shows the difference: change an event's type, include or leave out what was only detected, then **Apply to logbook**, or **Keep as recorded**. Nothing changes unless you apply, and the nav log's landing counts follow what you apply.

### Engine Hours

If **Log Engine Hours** is on under **Settings › Checklist & Flight**, the app asks for the tachometer or Hobbs readings at engine start and shutdown, and calculates the hours flown automatically.

### Viewing Flight History

Open the **Logbook** tab to review flights. Each one is titled by its route ("LSZQ → LSGE"; "LSZQ" for a flight back home; "LSZQ → ?" when an end is unknown; "LSZQ ↻" for circuits), with the aircraft, the landings, the distance and the duration. Flights are grouped by month, and a day with two flights or more gets a header with its totals and **Share day** (see [Exporting and Sharing](#exporting-and-sharing)). Tap a flight for its **detail view**:

- **FLIGHT TRACK**: an interactive map of your flight track
- An altitude (and speed) profile chart
- **TIMELINE**: every event, in order
- **CHECKS**: the debrief, see [Checks](#checks)
- Engine hours (if logged), **PLAN vs ACTUAL**, the flight's name and notes
- **Nav Log**, **Logbook & costs** (see below), **Export** and **Share card**

The logbook filters by year (set it to **All time** to see every flight), in UTC like every printed date, and your flights sync across devices via iCloud.

### Checks

A flight's **CHECKS** section is its debrief. A clean flight reads "All checks done". Otherwise each exception gets a line, in flight order: **owed** (with the moment that passed it, "you levelled off with it open, 14:26"), **done late**, **not sure**, **confirmed after landing**, **skipped**, or still open when the flight ended. The checks done on time follow as a count ("9 other checks done"), and **Show each check** lists them. FREDA has a line of its own ("done 3× · missed 1×"), with the times. Flights from before 6.1 have no Checks section.

The Logbook spots a trend: from three flights with checks, **CHECKS · LAST 10 FLIGHTS** lists what keeps coming back ("CLIMB CHECK owed on 4 of 10 flights", "FREDA missed 3×"), most frequent first. A pattern is the same check owed, skipped or not sure on two flights or more; without one, there is no card. It follows the year and aircraft filters.

### Logbook & Costs

From a flight's detail in the Logbook, or from a flight's CLOSE chapter, **Logbook & costs** holds three things.

**The logbook line.** A draft of the line an EASA Part-FCL logbook wants for this flight, per **AMC1 FCL.050**: date, departure and arrival with **UTC** block times, aircraft, single-engine and total time, PIC, landings, night and IFR time, function time, remarks. Dates, places, times and landings come from the recorded flight. **Function time is a judgment** the app cannot make from a flight, so it defaults from a signal — an instructor named on the flight, or [student mode](#student-pilots) — and is yours to change with **Edit**, together with the PIC name, night landings, night and IFR time (deliberately **not computed**: a plausible wrong number in a logbook column is worse than an empty one you fill in) and remarks.

**Logbook row** lays the same values out as your paper logbook's own twelve column groups, to copy from; **Copy line** and **Export CSV** hand them over as text; and **Export logbook PDF** in the Logbook renders any selection of flights as logbook pages with page and carried-forward totals. AéroCheck is not a logbook of record and every page says so.

**Cost.** Set an hourly **rate** per aircraft (with the billing basis — block time, flight time or engine hours — and currency) once; each flight then shows its aircraft cost, plus any fees you add (a landing fee, fuel). The rate is snapshot onto the flight when computed, so a rate change next year does not rewrite last year. The Logbook's summary shows the period total and says how many flights have no cost rather than pretending the total is complete. Turn the whole thing off with **Track flight costs** under **Settings › Flight Planning** if you do not track what flying costs.

### Mass & Balance

The **Mass & balance** calculator, per aircraft: enter the empty mass and arm, the stations and their loads, and — if you want the landing case too — the fuel you expect to burn and which station it comes from. It reports mass, centre of gravity and, when you have entered the aircraft's **envelope** from the flight manual, whether take-off and landing are inside it. Without an envelope, or with a station left blank, the verdict is **unknown — never a pass**. No aircraft data ships with the app; everything here is what you entered from your own AFM.

### Student Pilots

If you fly with an instructor, turn on **Student pilot** under **Settings › Flight Planning** and enter the instructor's name. Your flights then log as **dual**, with the **instructor named as PIC** — that column states who commanded the aircraft — and the instructor is pre-filled on new flights. An instructor named on the flight itself always wins over the usual one, and your own edits to a line win over everything.

### Exporting and Sharing

From the detail view, tap **Export** to save a flight as **GPX** (standard GPS exchange) or **JSON** (full data including events and metadata). The Logbook's own **Export** menu exports the listed flights, or all of them, together as a **ZIP**, and the logbook PDF. Files are named after the flight's title, and a GPX import brings that name back.

**Share card** makes an image of the flight to post or send: the route as flown, with each waypoint's time over, on the ICAO chart (the glider chart or the national map for a short flight, sharper at that scale); the block time, distance, maximum altitude and maximum ground speed; and the times marked "Local time · UTC+2". Two styles (**Standard**, **Full map**) and two formats (**9:16**, **4:5**). **Hide where I parked** (off by default) leaves out the track's first and last 300 m. The distance follows the Logbook's NM or km.

The **journey card** puts a day or a trip on one image: **Share day** in the Logbook, on a day with two flights or more, or **Share trip** on a trip's leg, once two legs have flown. It shows the whole route ("LSZQ → LSGE → LSGN → LSZQ"), the totals, each leg numbered on the map and the time on the ground at each stop. **Add each leg's card** sends the legs' own cards after it.

---

## Apple Watch and Companion Mode

AéroCheck can put your live flight on a second screen.

### Apple Watch

The **Apple Watch app** follows the flight from your iPhone. Before a flight it shows the time and whether it is connected to the phone ("Start flight on iPhone").

In flight, the **flight page** shows the phase (in the colour of its stage) and the next one (the right one in circuit mode, which skips Cruise and Descent), the time (**LOCAL**, or **UTC** with **Always Use UTC Times**), and the **FLIGHT TIME**, from the line-up to the landing. With a route on the map, the watch has three pages, from top to bottom **Navigation**, the flight page and **Frequencies**, and opens on the first; turn the Digital Crown or swipe up and down to go from one to the next:

- **Navigation**: the next waypoint (or the diversion field) and its place in the route ("3/7"); the leg timer (**CHRONO**) with three buttons, MARK, pause or start, and reset, which work the iPhone's leg timer as the Cockpit's do (MARK records the time over and starts the next leg); then **HDG** (the bearing to the waypoint), **DIST** (NM) and **EET** (the time to it at the current ground speed).
- **Frequencies**: the frequencies of the map's list, NOW and NEXT first, then the others.

When the watch has had nothing from the phone for five seconds (out of range, for example), its values dim under a **NO DATA** banner, so frozen values are never mistaken for live ones.

### Companion Mode

**Companion Mode** pairs an iPad and an iPhone over a direct Wi-Fi link (Wi-Fi Aware; requires **iOS 26 on both devices**) to turn the second device into a synced **wingman** screen. Pair the two devices once under **Settings › Companion Mode** (**Pair New Device** shows even with the mode off); afterwards they connect automatically when both are nearby and ready.

The first time a phone wants to drive the iPad's flight (its checklist and waypoints, or its GPS position), the iPad asks: **Allow companion control?**, with **Allow for This Flight**, **Always Allow** (on this iPad, until you **Forget** the phone or tap **Ask Each Flight** in Settings) and **Don't Allow**.

The companion viewer has two screens, **NAV** and **CHECKLIST**. It shows the checklist on the ground and NAV once airborne, until you tap one:

- **NAV**: a track-up next-waypoint view with the route on the map, **RECORD ATO** (the time over the current waypoint, recorded on the iPad) and the [check slot](#the-check-slot) under it, which takes the same one tap as on the iPad.
- **CHECKLIST**: a mirror of the master's checklist.

Control is **two-way**: advancing the checklist or revealing the checks the Memory test hides on either device updates both, and both screens match the master's theme. The phone can also answer [the landed card](#the-landed-card). A **GPS chip** shows which device's GPS is in use (**GPS iPad** or **GPS iPhone**). To leave, hold **COMPANION** on the phone until it fills red.

When the data goes stale (nothing for five seconds), the companion shows **"Data stale — values may be frozen"**; when the link drops (after 10 seconds without anything), **"Connection lost"**, with **Go Standalone**. The rule is simple: a staleness or disconnect banner means *stop trusting the numbers on that screen* until it reconnects. To save battery, the iPad ends a link that has been idle for 10 minutes without a flight, and keeps listening.

### Wi-Fi-Only iPads

An iPad without GPS (a Wi-Fi-only model) installs AéroCheck and flies with it, on a position from elsewhere:

- **The iPhone's GPS, through Companion mode** (iOS 26 on both devices). Once the phone is allowed, the iPad runs the whole flight on it: the iPhone shares its satellite fixes over the link (never a Wi-Fi position), and the iPad records the track and drives the Cockpit as if the fix were its own; the header's GPS reads **GPS · iPhone**. In a hangar or a clubhouse, the iPad's own Wi-Fi positions do not push the iPhone's GPS aside.
- **An external GPS receiver**, connected to the iPad: nothing to set up. Its fixes count as satellite fixes, so the GPS indicator stays green on one.

START FLIGHT waits up to five seconds for a position. Without one, it says so ("Waiting for a GPS fix. Once GPS is acquired, try again.").

---

## Circuit Mode

Circuit mode is designed for **pattern training** (touch-and-go practice). Start it with **CIRCUITS** on Today, where it is always offered. When active:

- The checklist skips the **Cruise** and **Descent** phases, and so FREDA
- The approach check falls due at the level-off, and the landing check shows (nothing to press) once you start down
- **GO AROUND** and **TOUCH-AND-GO** are single taps, and either takes the checklist back to **Climb** for the next lap
- **Full-stop landings** are detected: the full-stop card ("Full-stop landing detected at LSZQ") waits for **Confirm**, which logs a stop-and-go and takes the checklist back to **Taxi**, or **Dismiss**. Outside circuit mode, a full stop goes on to After Landing instead (see [The Landed Card](#the-landed-card))

Circuits are start-now only (there is no such thing as a planned circuit session), so a session never adopts a flight you planned. When it ends, AéroCheck **offers** to close it out: a light version of CLOSE with just the logbook line and a debrief. Dismissing the offer is a complete answer.

---

## Aeronautical Data and Storage

AéroCheck draws on several external datasets so navigation works wherever you fly. All of it is downloaded on demand and cached on the device.

### What Data AéroCheck Uses

- **Airports and frequencies** — from OurAirports and OpenAIP (positions, runways, fuel grades, PPR flags and radio frequencies)
- **Airspace** — OpenAIP controlled and restricted airspace, with vertical limits and frequencies
- **Navaids, obstacles, and reporting points** — OpenAIP map layers (see [The Map Sheet](#the-map-sheet))
- **Charts** — Swiss ICAO, national map, and Segelflug charts from swisstopo
- **Landing-fee sources** — where each aerodrome publishes its own tariff (links and dates, never amounts), from the AéroCheck service

### Downloading Data

Download aeronautical data **by country or continent** from **Settings › Data & Storage** (or **Navigation & Maps**). Onboarding offers a recommended set for your region and its neighbours so you are covered from the first flight. Airspace, navaids, obstacles, and reporting points download together per country.

### Keeping Data Current

Aeronautical data changes regularly, so AéroCheck surfaces its freshness in several places:

- The **Data** chip on Today and a freshness summary in **Data & Storage**
- A snoozable **nudge** when a dataset is out of date
- The amber mark on the map's **Map** button when downloaded airspace is aging (see [The Map Sheet](#the-map-sheet))
- **Route-aware prefetch** — when a route crosses a country you haven't downloaded, AéroCheck offers to fetch that data, and fetches only what is missing

Data refreshes when you bring the app to the foreground (there is no background download), so updates happen while you're using the app, not on battery in your pocket.

> Even current data is advisory. Always cross-check against official charts and NOTAMs.

### Offline Maps and Storage

Cache the Swiss ICAO Chart and Segelflugkarte for offline use (~100–250 MB). **Data & Storage** lists each dataset with its size and currency, and lets you update or delete cached data to reclaim space.

---

## Settings Reference

Settings is a tab of its own, organized into dedicated pages. Three former settings are now simply how the app works: **CIRCUITS** is always offered on Today, the screen stays on during a flight (and only then), and every checklist runs step by step. Two things live outside Settings: the aircraft you fly is chosen on Today or in the **Aircraft** tab, which also keeps each aircraft's usable fuel with full tanks and its cruise speed; and the Cockpit's **Menu** repeats the display options in flight.

### Aircraft & Subscription

**AéroCheck Pro** (subscribe, start the trial, buy Lifetime, or restore purchases), the aircraft you fly (with **Get latest aircraft data** to refresh the list and check for checklist updates), and **Aircraft Visibility**, to show or hide aircraft one by one or by aeroclub.

### Checklist & Flight

**Memory test** and **Checklist Language**; **Log Engine Hours** (on by default); **Always Use UTC Times**; the **Cockpit theme** (Auto / Day / Night) and **High contrast in sunlight**.

### Navigation & Maps

**Force ICAO Chart Layer** and the **Track vector**; **Offline Maps** (offline mode, chart cache, update, delete, download); the OpenAIP airspace overlay, the navaid, obstacle and reporting-point layers, and **Online Airspace Data** (nearby control zones fetched online when no airspace is downloaded); airport data.

### Flight Planning

Your **pilot name** (for the PIC column and the logbook PDF), **Student pilot** with your instructor's name, your **Home aerodrome** (**Based at**: Plan new flight starts from it, and the landings you make within 5 NM of it count as landings at base on the nav log, which prints "– / 1" without one), **Track flight costs** on or off, and the **Terrain Altitude Unit** of the route profile.

### iCloud & Log

**iCloud Sync** of settings and flights across devices, the GPS **Recording Interval** and **GPS Priority** (**Precision** or **Battery Saver**), and the numbers of recorded flights and GPS points.

### Data & Storage

Aeronautical-data currency, per-country and continent downloads, offline chart cache, and storage management. See [Aeronautical Data and Storage](#aeronautical-data-and-storage).

### Companion Mode

Pair an iPhone and iPad as a synced second screen (Wi-Fi Aware; requires iOS 26 on both devices): **Enable Companion Mode**, then **Paired Devices**, with **Pair New Device** (shown even with the mode off), **Forget** for each device, and **Ask Each Flight** for a phone you always allowed. See [Companion Mode](#companion-mode).

### About

App version, website, author and open-source information; **Legal** (the safety notice, the terms of use and the privacy policy) and the data sources; **Replay onboarding**; and hidden **Developer Options** (tap the version number five times to unlock).
