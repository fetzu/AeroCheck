Welcome to the AéroCheck user manual. This guide covers every feature of the app (from your first launch through planning a flight, preparing it, flying it and closing it out), so you can get the most out of each flight. To try it all on the ground first, see [Dry Run](#dry-run).

AéroCheck is a flight companion, not a certified instrument. Everything it shows (speeds, airspace, terrain, frequencies, fuel figures, mass and balance) is advisory and may be incomplete or out of date. It never replaces your aircraft's instruments and documents, current aeronautical charts, NOTAMs, or your own judgment as pilot in command.


## Getting Started

### First Launch

The very first screen is a **safety notice** you must acknowledge before anything else; it comes back whenever its wording changes materially, and you can read it again at any time under **Settings › About › Safety notice**. A short introduction then walks you through setup:

- **Use your location**: needed for the GPS track, ground speed and the map. Grant "While Using the App" or "Always". "Always" is what keeps the track recording when the screen locks or you switch apps in flight; if you grant only "While Using the App", AéroCheck asks to **upgrade to "Always"** when you start a flight.
- **Maps & Data**: the aeronautical data for your country (detected from the device region or, if available, a GPS fix) and its neighbours, the worldwide airport database and, optionally, the Swiss charts. See [Aeronautical Data and Storage](#aeronautical-data-and-storage).
- **Checklists**: **Hide memory items** and the checklist language.
- **Flights**: the four chapters AéroCheck follows a flight through: Plan, Prepare, Fly, Close. See [Following a Flight](#following-a-flight).
- **Home aerodrome** (optional): where you are based. Plan new flight starts from it, and the landings you make there count as landings at base on the nav log. Set or change it later under **Settings › Flights**.
- **Your map** and **In flight & features**: what the map draws (airspace, track vector, obstacles, the ICAO chart at every zoom), engine-hour logging and iCloud sync.

The last page, **You're Ready**, offers **Start using AéroCheck**, or **Fly my first flight on the ground**, the guided dry run (see [Dry Run](#dry-run)). You can replay the whole tour at any time from **Settings › About › Replay introduction**.

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
- **NEXT FLIGHT**: the flight the start button is about, as a card with its time, aircraft, name and what is left to do ("Next: Weather briefed · 2 open in Plan and Prepare", or "Everything ticked, ready to fly"). That is today's flight, a flight you left in the air, or the next leg of a trip once you have landed at a stop. A trip shows as one card: its number of legs (**3 LEGS**), the whole route ("LSZQ → LSGE → LSZQ"), and a chip per leg with its time (✓ once flown). Tap the card to open the flight. With no such flight, the slot shows a flight you are following or still have to close, or **Plan new flight**.
- The green start button, always in the same place: **START THIS FLIGHT** when there is a flight for today (**RESUME THIS FLIGHT** once it is in the air), **START FLIGHT** otherwise. For a leg of a trip it reads **START FLIGHT** and names the leg under it ("LEG 1 · LSZQ → LSGE").
- Under it, **CIRCUITS**, always offered, beside **FLY WITHOUT A PLAN** when there is a flight for today, or **PLAN NEW FLIGHT** when there is not.
- While your logbook is empty, a card under them offers **Fly your first flight on the ground**, the guided dry run (see [Dry Run](#dry-run)).
- **AIRCRAFT AND LAST FLIGHT**: the aircraft you fly (tap it to switch, see below) and your last flight (tap it for its details). With nothing planned, a route you have put on the map shows here as well; tap it to open **Plan › Routes**.

### Choosing Your Aircraft

Tap the aircraft on Today for the list of every aircraft you can fly: the free WT9 Dynamic, and each premium aircraft AéroCheck Pro unlocks that you have not hidden. Choose one to switch to it; **Speeds and details** opens the **Aircraft** tab, and **Not listed? Send us its checklist** the request sheet (see [Sending an Aircraft's Checklist](#sending-an-aircrafts-checklist)).

The **Aircraft** tab lists the same aircraft under **YOUR AIRCRAFT**, the last row being **Send us an aircraft's checklist**, and the requests you sent under **Your requests**. Then come the selected aircraft's **SPEED REFERENCE**, its **FUEL** (the usable fuel with full tanks, see [Fuel on Board](#fuel-on-board)), its **PLANNING** (the **Cruise speed** your plans fly, see [Cruise Speed and EET Allowances](#cruise-speed-and-eet-allowances)), a link to **AéroCheck Pro**, and **Aircraft Visibility**, which opens Settings to show or hide aircraft one by one or by aeroclub.

Selecting a premium aircraft loads its checklist in the background, so it is ready before you start.

Your aircraft isn't in the list, or its checklist is older than the club's? Send the club's checklist, from the app (below) or from [aerocheck.app/send](/send). The club confirms before the aircraft goes live, and it joins AéroCheck Pro like the others; [aerocheck.app/clubs](/clubs) has the rest.

### Sending an Aircraft's Checklist

The app sends a club's checklist as [aerocheck.app/send](/send) does, with the same form in the same words. It opens from the **Aircraft** tab (**Send us an aircraft's checklist**, also in **Settings › Aircraft & Subscription**), from the aircraft menu on Today (**Not listed? Send us its checklist**), and from the line under what AéroCheck Pro unlocks on its page (**Can't find your aircraft? Send us its checklist**).

- **The registration** first, then **Look it up**: one AéroCheck already has makes the request an update (the club's new revision replaces the checklist the app has), any other a new aircraft, with its type and the other registrations the same checklist covers. The rest of the form opens after the lookup.
- The club (left empty for a privately owned aircraft), then **Who sends it**: **For the club**, or **As a pilot**, with the club's contact, whom AéroCheck asks to confirm (or "I don't know it", and the request waits for the club's OK until someone adds it).
- **The checklist**: **Scan** (the document scanner, one PDF), **Photos** or **Files** (PDF, JPEG, PNG or HEIC), up to 4 files, 10 MB each and 25 MB in all. A photo is sent without the position it may carry. Then its language: English, French, German or Italian, or another one typed.
- **You**: your name (optional) and e-mail, both remembered on the device for the next request, and your notes. Then the two statements to tick.

Above **Send the request**, "A quick check that you're not a robot" runs the website's own Cloudflare check in a small web view; it usually needs nothing from you. Each file then goes up with its progress (an upload that stops goes on from that file when you try again), and the sheet ends on the ticket ("Sent: AC-2610-001"), what happens next and **Your request's page**, whose link also comes by e-mail.

**Your requests**, in the Aircraft tab (and in **Settings › Aircraft & Subscription**) once you have sent one, gives each request its ticket and where it stands, in the website's words: Received, Accepted, In preparation, Proofreading, In testing, Live, Need info, Declined or Duplicate. A tap opens the request's page, with its history; touch and hold for **Remove from this list**. A closed request leaves the list by itself a month later. The statuses are read when the app opens or comes to the foreground, at most every three hours and never during a flight: nothing runs in the background. The first time a request reads Live, a notification says so ("HB-ABC is in AéroCheck"); a tap on it opens the Aircraft tab, its list of aircraft fetched again so the new one is there.

### Starting a Flight

There are four ways to start, and they are different on purpose.

- **START THIS FLIGHT** on Today, or **START FLIGHT** on a flight's own page, starts that flight: on the aircraft it was planned with, and with its route on the map. If Plan and Prepare still have items open, AéroCheck asks first ("Not everything is ticked"): **Review the flight** or **Start anyway**. An unticked item may be a briefing nobody did.
- **START FLIGHT** on Today, when there is no flight for today, starts the 16-phase checklist on the selected aircraft. If a route is on the map (**Show on map** in Plan › Routes), the flight flies it.
- **FLY WITHOUT A PLAN**, offered when there is a flight for today, starts another flight: no route, and today's flight is left as it is.
- **CIRCUITS** starts circuit training; see [Circuit Mode](#circuit-mode). A circuit session never takes over a planned flight.

A flight planned for another day starts from its own page, after a question; see [Fly](#fly). A dry run is none of these: it flies on the ground and is never logged (see [Dry Run](#dry-run)).

AéroCheck will not start a flight it cannot run properly, and it says why:

- **AéroCheck Pro isn't active** for the selected premium aircraft: **See plans** or **Restore Purchases**.
- **Can't Start Flight**: the checklist of a premium aircraft could not be downloaded and there is no copy on the device yet (check your connection and try again), location access is off, or there is no GPS fix yet (try again once the GPS has one). A wrong or empty checklist never appears in flight.

### Starting from the Widget

Add the **AéroCheck widget** to the Home Screen of your iPhone or iPad (the system's, outside the app) for one-tap starts. It shows a start button for each aircraft you own (aircraft you don't own are never shown). A tap starts a flight on that aircraft through the same checks as START FLIGHT, and flies the route on the map if there is one. The medium widget also opens your logbook.

---

## Dry Run

A dry run is a flight flown on the ground, in the real Cockpit: the aircraft is flown for you, on a simulated GPS, and you work the checks and the buttons as you would in the air. It runs in a world of its own, built when it starts and dropped when it ends: nothing it does reaches your logbook, your flights, your routes or your settings, nothing is sent to iCloud, and no reminder is scheduled. One runs at a time, never during a flight, and no flight starts while it runs.

### Starting a Dry Run

- **The introduction's last page**: **Fly my first flight on the ground** starts the guided dry run.
- **Today**: while your logbook is empty, a card offers **Fly your first flight on the ground**, with **Start the dry run** and **Not now** (which puts the card away for good on this device). It also goes once you have flown the guided dry run, or a real flight.
- **Settings › About**, under **LEARN AND PRACTISE** (between ABOUT and LEGAL): **Replay introduction**, **Your first flight, from plan to logbook** (the guided dry run, about 15 minutes), **One part at a time**, and **Fly a dry run on the ground** (free practice).
- **A route**: **Fly a dry run**, in the route editor's **…** menu or in the route's swipe to the right in **Plan › Routes**, flies that route in free practice.

### The Guided Dry Run

**Your first flight, from plan to logbook** is one story in four parts, flown in the WT9 from your home aerodrome (LSZQ when you have none, or when the airport data has no runway for it): a triangle out to two turning points and back, with a go-around, then a full stop.

1. **Plan a flight**: **Plan new flight** on Today, the sheet already filled in with the dry run's route, **Create flight**, then the flight's page: its chapters, the next thing to do, the fuel plan and Fuel on board, a link (in a dry run, a link only says where it would go), a tick, and the ATC flight plan set to not applicable. **START FLIGHT** opens the Cockpit, with the rest of Plan and Prepare ticked for you.
2. **Fly it**: the flight itself, in seven chapters (Before you go, Engine and taxi, Line-up, Take-off and climb, On the route, Back to land, After landing). Every check is yours, from the pre-flight check to the shutdown, with the memory items and the Menu's switch that hides them, DEFER and the deferred items, READY FOR LINE UP, MAP and ROUTE, NEXT's change of frequency after the cruise check (when NEXT is due by then), the turning points the app marks by itself (and their UNDO), MARK and the leg timer, a go-around chosen on final and the circuit's checks after it, the full stop, ENGINE SHUTDOWN at the parking and END FLIGHT.
3. **Close out**: the flight's page in CLOSE-OUT, the logbook line and **Logbook & costs**, the debrief and **Finish**.
4. **Your logbook**: the **Logbook** tab, where five made-up flights (circuits earlier in the year) come before yours, the year at a glance, then your flight's page, its track, its checks and its exports.

A card guides each step: what to look at, and what to do. The control it speaks of is highlighted, and where a single tap is asked for, the rest of the screen dims, so only that control takes it. A card that shows something has **Next** (and, in the Cockpit, **Pause**); a card that asks for something goes once you have done it, and **Show me again** highlights its control again. The card sits at the foot of the screen, or at the top when what it points to is low. Once you start doing what it asks, it folds to one line: what the aircraft is doing, then your next step ("Lining up: in a dry run, the aircraft takes off automatically. Your next step: the climb check, once established in the climb."). Its chevron folds it, and a tap on the folded line opens it again. Along its top, **PART 1 OF 4** and a bar that fills as you go through the part.

In the Cockpit, the flight waits at each card (the band reads **DRY RUN · waiting for you**) and runs on between them at a pace that follows the aircraft: slower for what is worth watching (the take-off, the landing), fast along the legs. There is no pace to choose here; the card's **Pause** stops it, and **END** in the band stops the dry run.

Each part ends on a page of its own ("Close out: done"), with **On to** the next part, or **Stop here**: the rest waits in Settings, under Learn and practise. **One part at a time** starts any of the four parts on its own, and **Fly it, chapter by chapter** any of the seven chapters. Getting there takes a few seconds behind a cover, the earlier steps done for you.

### Free Practice

**Fly a dry run on the ground** in Settings, or a route's **Fly a dry run**, opens **Fly a dry run**:

- **What to fly**, when you came from a route: **The route** or **Circuits**.
- **Circuits**: the aerodrome's ICAO code (your home aerodrome to start with, else LSZQ). The sheet says what it found ("LSZQ Bressaucourt · runway 07, left-hand circuit at 2,900 ft"): the runway and the powered circuit open flightmaps publishes, else a runway from the airport data with a left-hand circuit 1,000 ft above the field. Until the airport data is on the device, LSZQ is the only aerodrome on offer.
- **The route**: its first and last waypoints must be aerodromes with a runway.
- **Aircraft**: any aircraft you can fly (a premium one needs AéroCheck Pro, as for a flight).
- **Pace**: 1×, 4× (to start with), 10× or 30×.

**FLY THE DRY RUN** prepares the dry run, closes the sheet and opens the Cockpit.

Where the status bar was, a hatched band reads **DRY RUN** and how it stands (its pace, "paused", "waiting for you" or "next check"), with **END** at its right end, over every screen. On the iPad the band also holds the controls: pause, the four paces and **NEXT CHECK ›**. On the iPhone, DRY RUN sits left of the Dynamic Island and END right of it, and the controls are in the Menu, under **DRY RUN**, with **End the dry run**. A pause puts **DRY RUN PAUSED** in the middle of the screen, with **Go on**; leaving the app pauses the dry run too, and it stays paused until you go on. **NEXT CHECK** runs the flight at 30× until something needs you: a check falls due, a leg begins, the aircraft waits for you, or the final comes (15 minutes of flight at most).

The aircraft waits where a pilot would: until ENGINE START before it taxis, at the holding point until READY FOR LINE UP, on the runway until the line-up check is done. Then it takes off by itself. On a route it follows the Cockpit: a **Direct** to a waypoint ahead, a diversion to an aerodrome with a runway, **Resume route**. An early MARK only writes a time over; the aircraft keeps its leg.

On each final, a light card over the foot of the page reads **ON THIS FINAL, THE AIRCRAFT WILL**, with **FULL STOP** (lit), **TOUCH-AND-GO** and **GO AROUND**, and the line "This card controls the flight in a dry run. It doesn't appear in a real flight." The flight waits on final until you tap one. After a full stop in circuits, **NEW CIRCUIT** at the end of the after landing check sends it round again from the runway (a stop-and-go), and the parking check sends it to the parking.

What the app detects in a dry run (a go-around, a touch-and-go, a full stop) is always recorded at once, with UNDO, whatever the setting for real flights (see [Flight Events](#flight-events)).

### When a Dry Run Ends

A dry run ends with its flight (**END FLIGHT**, or the flight abandoned), or with **END** at any time. Its page, **The dry run is over**, gives the checks, landings, circuits and time, then what was flown, in order, and something to try next time; after the guided dry run, **What you take with you** sums up the habits it went through. Nothing was saved: no logbook entry, nothing sent to iCloud. **FLY IT AGAIN** starts it once more; **DONE** brings you back where you were.

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

- **Route**, with **Airports**: a **From** and a **To** row where you type each aerodrome's ICAO code or name, with completion (the aerodrome's name shows beside a code it knows). **Add a stop on the way** adds a row just before To; three or more aerodromes make a [trip](#trips-and-stops) (LSZQ, LSGE, then LSZQ is LSZQ → LSGE → LSZQ). Drag a stop to reorder it, or remove it. The same aerodrome in From and To is a local flight ("Back to LSZQ: this is a local flight. To land on the way, add a stop."). With a [home aerodrome](#flights) set, the sheet starts with it in both rows.
- **Route**, with **A saved route** (offered once you keep routes): the routes, searchable, each with its map. The flight is built from a **copy** of the route (its waypoints, altitudes and fuel figures). Under it, **Aerodromes on this route** lists those on the route or within 5 NM, in flying order, each with a **Land here** switch: each one you turn on adds a leg, and each leg keeps its part of the route. **Land somewhere else…** searches any aerodrome.
- **The legs**, once there is a stop (**2 legs**): each leg with its distance, time and departure ("≈" when estimated), and between two legs the time **On the ground** (30 min unless you change it) and a **Refuel** box (unticked, the next leg starts with the fuel this one leaves in the tanks).
- **When**: already set to tomorrow at 10:00, since the preparation reminder counts back from it (for a trip, it is leg 1's departure). Change it, or choose **No date yet**.
- **Aircraft**: your aircraft as chips, one tap.

The bar at the bottom says what it will create (the route, the day and time, the aircraft) above **Create flight**, or **Create trip · 3 legs**. The new flight opens on its page.

In the Logbook, swipe a flight to the right for **Plan this again**: the same sheet, filled in with that flight's route and aircraft and nothing else, since last week's preparation is not this week's.

### A Flight's Page

A flight has a page of its own, opened from Today or from Plan › Flights.

- **The header**: the route as a thumbnail (tap it to edit the route), the flight's name with its date and aircraft (tap it for [the flight sheet](#the-flight-sheet)), a pencil to name the flight, its state (PLANNED, READY, IN FLIGHT, CLOSE-OUT, DONE) and a ring counting what is done ("3 of 4 done" on iPad). A flight is READY once every task before the flight is ticked or set aside, and PLANNED again when one is unticked or a new one appears.
- **The chapters**: Plan, Prepare, Fly and Close, each with its count. A chapter turns green when everything in it is done; Fly turns green once the flight has been flown. A tap on one takes the page to it, its ticked tasks unfolded when nothing in it is open.
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

Before the flight, a **Weather** card sits above Prepare's tasks: each aerodrome of the route with its METAR and TAF as published, the departure, the destination and the alternates of the ATC flight plan (item 16). A field without a TAF says so and points to the nearest one that has one ("No METAR or TAF · nearest LSZG, 20 NM"), whose reports follow in a **NEAREST** row. Under them, the SIGMETs along the route, or "No SIGMET along the route · 142 received" (in amber, "No SIGMET data received: check the official briefing", when none came at all). At the top, the time the reports were fetched (UTC) and a refresh button; at the foot, "METAR, TAF, SIGMET · NOAA Aviation Weather Center". Opening the page again within ten minutes shows the same reports without asking again; nothing is stored. The card needs no AéroCheck Pro, and a dry run has none. Read it before the official briefing, never instead of it.

A route through a country whose airspace is closed (Belarus) gets a red row at the top of Prepare: "Belarus: flights prohibited", "Operations in this airspace are prohibited. Change the route.", with the directive that says so (EASA SD-2021-02). It is not a task: nothing to tick and nothing stored, and nothing is blocked. It goes when the route does.

- **Weather briefed** and **NOTAMs checked**: a blue chip for each official page of every country the route touches, the departure's first (a page two countries share shows once). Each chip names its publisher (skybriefing, MeteoSwiss, SOFIA-Briefing (DGAC)…) and, on a second line, what the page takes: **free account**, **paid** or **authorised users**, or **general page** where the country has no page of its own for it (the EAUP, an AIP's start page). A chip without a second line is open to all.
- **Airspace activity** and **Area forecast**: one task per country of the route that publishes them, with its code ("Airspace activity CH", "Area forecast FR") and that country's pages. Switzerland's airspace activity is the DABS: its hint reads "Today's DABS; tomorrow's from 16:00" (the time in your device's time zone), and its chip opens the DABS of the flight's day once it is out, today's until then.
- **ATC flight plan filed**: "Copy the ATC flight plan, then file it in the departure's country". **Copy ATC flight plan** puts a complete ICAO flight plan message on the clipboard (fields 7 to 19, with your route, endurance and persons on board), and the chip opens the departure country's filing portal (skybriefing for Switzerland, SOFIA-Briefing for France, the DFS AIS-Portal for Germany). Ticking this task is what arms the close-out reminder after landing. Where the departure's country wants a plan filed from a field without ATS to be activated by the pilot (Sweden, Finland, Estonia, Latvia, the Czech Republic, Slovakia, Poland, Hungary and Ireland), and the app's data gives the field neither a tower nor an AFIS, an amber line says so: "ESKT has no ATS: activate the plan yourself after take-off, by radio or phone." A field the data doesn't know gets no line.
- **PPR**: raised for an aerodrome on your route that openAIP flags as prior permission required, so you call before you go. Its **Official chart** chip opens the aerodrome's chart (see [Official Chart](#official-chart)), which is usually where the number and the hours are. It appears only when the airfield data is downloaded.
- **Border crossing**: one task per foreign country the route crosses, with the country's **border pack**: whether a customs aerodrome is required, whether prior notification is required, and the lead time, for CH, FR, DE, AT, IT and GB. Each comes with **Official rules** (and **Swiss side** when the flight touches Switzerland) and the date it was checked. A country not yet curated says so and points you to the AIP. Where official sources disagree, the task says that too. **Treat an unestablished requirement as one that applies until you have checked.** This is a reminder, not a clearance.
- **Nav log ready**: **Export nav log** opens the nav log as an A4 PDF, to read, print, mark up or share. The flight sheet's **Export** menu has it in A5 as well, the kneeboard size.

The day before a dated flight, a **preparation reminder** arrives at T−24 h.

The chips come from AéroCheck's briefing registry, which lists each country's official publishers (see [What Data AéroCheck Uses](#what-data-aérocheck-uses)). A country with no page for a task adds no chip to it.

### Fly

The Fly card says what comes next ("16 phases · checklist, nav and briefings") and starts it.

- For today's flight, a flight with no date, or the next leg after a stop: **START FLIGHT**. It selects the flight's aircraft, puts its route on the map and starts the checklist; the flight is then IN FLIGHT.
- For a flight planned for another day: its day ("Planned for Sat 27 Sep, 10:00") and a quieter **Start now**, which asks first ("Start this flight now?"), so tomorrow's flight is not started by mistake in place of today's. The page offers it in the same way when you open it from Plan › Flights.
- While another flight is flying: neither. The card says, in their place, "Flight in progress (F-HVXA). End it before starting this one." That flight ends with END FLIGHT, in the Cockpit; the rest of this page stays open to read.

From there on it is the 16 phases; see [The Cockpit](#the-cockpit) and [The Map](#the-map). If you abandon the flight (see [Ending or Abandoning a Flight](#ending-or-abandoning-a-flight)), the planned flight goes back to READY: what you prepared stays ticked.

### Close

After **END FLIGHT**, the flight moves to CLOSE-OUT.

- **Close the ATC flight plan**: only if you ticked **ATC flight plan filed**. It is the one task with a search-and-rescue consequence, and it follows the rule of the country you landed in. So the flight's page opens on a red card, **Close your ATC flight plan**, with that rule, that country's numbers and **Mark closed**; the Today tab shows a badge; and a notification reminds you. The task's hint is the rule, and its chips are the numbers and the country's links. See [Closing the ATC Flight Plan](#closing-the-atc-flight-plan).
- **Logbook entry**: **Logbook line** opens **Logbook & costs** for the recorded flight; see [Logbook & Costs](#logbook--costs).
- **Fees**: the landing fee, when your destination has one. **Flight cost** opens the cost of the flight, **Operator's tariff** the operator's own tariff page, where AéroCheck knows it, and **Official chart** the aerodrome's chart. It appears only when cost tracking is on.
- **Debrief**, marked optional: a field of a few lines for what went well and what to change. It is the flight's notes, the same text as **NOTES** in its Logbook entry, so either place edits it. It is not a task: never ticked, never counted, and the close-out is complete without it.

**Finish** the flight when you are done; anything still open simply stops asking. A finished flight leaves Plan › Flights and stays in the Logbook.

### Closing the ATC Flight Plan

A filed ATC flight plan is closed by the rule of the country the flight lands in: the destination's, or that of the field you landed at instead. AéroCheck takes it from its briefing registry and says it in a sentence that starts with the country:

- Where the AIP ties alerting to a delay (Switzerland, the United Kingdom, Poland and the Isle of Man): "Switzerland: if it is still open, search and rescue starts 30 min after your ETA."
- Where it sets a deadline for reporting the arrival (Sweden, Estonia, Latvia and Romania): "Sweden: report your arrival within 30 min of landing."
- Elsewhere, with the unit to report to: "Germany: report your arrival to AIS-C (DFS). No delay is published; if it stays open, search and rescue may be started."
- A country with nothing checked (Italy, Greece…) gets the rule that holds everywhere, never another country's number: "Close it with the aerodrome's ATS unit, or the nearest one. If it stays open, search and rescue may be started."

The red card has the rule, then up to two numbers, each named, with the number under the name (**Call skyguide ARO**, +41800437837), beside **Mark closed**; the task's chips have all of them, and the banner that comes over the app after END FLIGHT has the first. The numbers are written in the international format (E.164), so they work from a foreign SIM too. In Spain, the number is the aerodrome's own ARO.

Under the buttons, a line says what a landing at an aerodrome with ATS does, by the country's rule: "An aerodrome with ATS that saw you land closes it: nothing to do." (SERA's rule); "Only a controlled aerodrome closes it for you." (Germany, the Netherlands and the Czech Republic), with "EDTF is not one: close it yourself." when the app's data has no tower there; "At an aerodrome with an ATSU, the ATSU closes it." (the United Kingdom); "Report your arrival even at an aerodrome with ATS." (Belgium and Luxembourg). A country whose rule AéroCheck has not checked gets no line. Then the country's own links, with what they take: in Switzerland, the FOCA's Swiss SAR Alerts app; in Germany, the DFS AIS-Portal, for the arrival report.

If you landed somewhere other than planned, the card adds: "Say you landed at LSZS, not LSZE."

The notification comes about two minutes after END FLIGHT. If you have not ended the flight, it comes after a full-stop landing, whether the app detected it or you counted it: at half the alerting delay the country publishes, or after 15 minutes where it publishes none (15 minutes in Switzerland either way). It gives the rule as well; with the app open before At the Hangar, it waits in Notification Center (see [Notifications](#notifications)).

### The Flight Sheet

Tap a flight's name on its page for the flight sheet: the flight's nav log data, in the order a flight is planned. Its title is the flight's name (tap it to rename the flight), with the date, the aircraft and the flight type under it. Changes are saved as you type.

- **ROUTE**: the map, the waypoints, the distance and the EET, with what the EET is built on (see [Cruise Speed and EET Allowances](#cruise-speed-and-eet-allowances)), and **Edit route**.
- **DEPARTURE**: **Date and time** (local time; every waypoint's ETO is counted from it until the take-off, then from the take-off itself, see [The Act Band](#the-act-band)), **Runway** (pick one of the departure aerodrome's runways, or type one) and **Flight Type**.
- **CREW AND AIRCRAFT**: **Pilot** (filled in from Settings when empty), **Instructor**, and the aircraft, which is the flight's.
- **FUEL**, as the paper nav log adds it up: **Fuel flow**, **Trip** (the route's EET at that flow), + **Alternate**, + **Final reserve 45′**, + **Extra**, = **Required**; then **On board**, with **Full tanks** and **= Required**, the **Margin** (in litres and minutes, green; or short, amber) and the **Endurance**. **DEFAULT** marks what the app filled in (the fuel flow and the 45-minute reserve), so you check it.
- **AFTER THE FLIGHT** (block and flight times, hour meter, landings), **NOTES** and **ATC FLIGHT PLAN DETAILS** (type, wake turbulence, equipment, alternate, persons on board, colour) stay folded to one line until there is something in them.
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

Each leg's page shows the trip (**TRIP · 2 of 6**, the shared tasks done), its legs (tap one to open it) and the preparation the legs share: **Aircraft reserved**, **Weather briefed**, **NOTAMs checked** and each country's **Airspace activity** and **Area forecast** are ticked once for the whole trip. A briefing tick **goes stale** when it no longer covers the next leg (a different day, or more than six hours before its departure), so yesterday's NOTAM briefing never shows as done on today's leg; the row then says when it was last checked. Everything else (route, fuel, mass & balance, ATC flight plan, PPR, customs, nav log, fees, logbook, the debrief in each leg's notes) belongs to each leg.

At the bottom of a leg's page, **Cancel this leg** and **Cancel whole trip (3 legs)** sit side by side. The trip's question ("Cancel this trip?") lists the legs it deletes; the legs already flown stay, with their flights in the logbook.

If you land somewhere other than planned, the flight's page says so ("Landed at LSZE") and offers **Continue to** the planned destination as the next leg of the trip, or **Finish here**. Weather and NOTAM come back unticked on that next leg: you turned away from something.

### Notifications

AéroCheck sends exactly three kinds of local notification: the **preparation reminder** the day before a dated flight, the **reminder to close the ATC flight plan** after landing, when one was filed, and, once per request, the notice that an aircraft whose checklist you sent is in AéroCheck ("HB-ABC is in AéroCheck", see [Sending an Aircraft's Checklist](#sending-an-aircrafts-checklist)). Permission is asked when you first follow a flight, or right after you send a request. Nothing else notifies.

In flight, with the app open, none of them interrupts you: outside the pre-flight check and At the Hangar, a notification goes to Notification Center only, and shows as a banner once the flight gets to At the Hangar or ends, unless you have opened or cleared it meanwhile. With the app in the background, they show as usual. A reminder tapped during a flight opens its flight's page, to read; the flight you are flying stays the one AéroCheck follows.

---

## Routes

A **route** is a path (waypoints, altitudes, distances, fuel figures) that you can fly on any day. It has **no date**: the date belongs to the flight that uses it. A flight planned from a route gets its own copy, so changing next month's flight never rewrites last month's, and that copy stays with its flight rather than among your routes.

### Plan › Routes

The routes you keep. Each row shows the route's map, its name or its ends, its waypoints, distance and time, and a **Show on map** button: it puts the route on the map to look at without starting a flight, and START FLIGHT on Today then flies it. The route on the map is listed on top, under **On the map**, and its button reads **Clear from map**. A route on the map that nobody flies comes off it after 72 hours.

- Tap a route to edit it.
- Swipe left for **Archive**, **Duplicate** and **Delete** (which asks first). An archived route leaves the list; once anything is archived, **Routes** and **Archived · 2** (with the count) appear beside the search, and **Unarchive** brings a route back.
- Swipe right for **Show on map** or **Clear from map**, and for **Fly a dry run**, which flies the route on the ground (see [Dry Run](#dry-run)).
- Touch and hold for the menu: **Edit**, **Rename** (any name, whatever the route's ends; empty shows the ends again), **Use ICAO codes…**, **Export** (GPX or JSON), and the actions above.
- The search field finds routes by name, aerodrome, waypoint or aircraft, ignoring case and accents; every word must match, in any order.
- The filter button shows the routes of one aircraft; **+** draws a **New Route** or opens **Import route**.

To fly a route on a given day, plan a flight from it: **Plan new flight › A saved route**.

### The Route Editor

The route editor is a map with **From** and **To** above it, the route profile under it, and the legs.

- Type the departure and the destination in **From** and **To** (ICAO code or name; the results are sorted by distance). The arrows between the two swap them.
- On the map, **drag a waypoint** to move it, **drag the route line** to insert a waypoint, or **touch and hold** an empty spot to add one where it lengthens the route least. A waypoint released within 2.5 NM of an aerodrome or a navaid (or 1.2 NM of a reporting point, when they are shown) takes its name, frequency and position. Tap an aerodrome for its callout: **+** adds it to the route, **Chart** opens its [official chart](#official-chart).
- **The legs** are a table in the nav log's columns: **#**, **WAYPOINT** (with its call sign when it differs), **MC**, **NM**, **EET**, **ALT FT** (edit it in place) and ⚠. The figures are those of the leg *from* the waypoint; the last row is the destination. On the iPhone, the figures go under the name.
- **One selection** across map, profile and legs: tap a leg to select it, and it is highlighted in the table, on the map and on the profile, where each stands. Tap the selected row again to open the waypoint; tap a pin to select its row.
- **Set altitudes…** sets many waypoints at once: a **Fixed altitude**, or a clearance **Above terrain**, with a preview of the lowest clearance on each leg and of the airspace the new profile runs into. The departure and the destination keep theirs. A route with no planned altitudes (often an imported GPX) says so: **No planned altitudes**.

At the top: **Show this route on the map** (or **Clear this route from the map**), and a **…** menu with **Nav Log** (the flight sheet), **Export GPX** and **Fly a dry run**; **Done** closes the editor. When the route crosses a country whose data you have not downloaded, a banner offers the download, and fetches only the countries you are missing.

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

In flight, AéroCheck shows one screen: the **Cockpit**. It is built for an iPad in portrait on a kneeboard, read from about 55 cm, and the iPhone shows the same Cockpit, sized for the phone (see [The iPhone](#the-iphone)). The screen stays on while a flight runs, and on a Companion iPhone while it is connected to the iPad (see [Companion Mode](#companion-mode)); otherwise it sleeps as usual.

### Three Zones

From top to bottom, always in the same places, whatever the page:

1. **The read band**, what you read: the header (the aircraft, the phase and its place in the flight, the flight time, GPS and **Menu**; on the iPhone, the phase and **Menu** alone), the phase bar, the instrument strip (GS, ALT, TRK and, on the iPad, NEXT) and **NOW | NEXT**, the two frequencies. Under it, **CHECKLIST · MAP · ROUTE** picks the page.
2. **The page**: **CHECKLIST**, **MAP** or **ROUTE**, at full height.
3. **The act band**, what you press: four big buttons, where the hand rests. They keep their size and their place on every page and in every phase, so the hand learns them once; only what they hold changes (see [The Act Band](#the-act-band)).

An iPad on its side has the same three zones, wider.

Colours keep one meaning in flight: cyan for what you can touch, magenta for the active route, green for normal or done, amber for a caution, red for a warning, white for data.

### The Header

On the iPad, one row:

- **The registration**. Touch and hold it to abandon the flight (see [Ending or Abandoning a Flight](#ending-or-abandoning-a-flight)).
- **The phase** and its place ("CRUISE CHECK 10/16"; in circuit mode, the lap instead, "↻ 4"). Tap it for **Select Phase**, the list of all 16 phases with their status and each one's page in the paper checklist.
- **The flight time**, counted from ENGINE START.
- **GPS**, in the colour of its status: green good, orange degraded, red lost or not recording (see [GPS Indicators](#gps-indicators)). Tap it for the **GPS Status** drawer: the signal and why it is degraded or lost, the accuracy, the time of the fix, the altitude, the position (tap it to copy) and the points recorded. When location access is limited to "While Using the App", the drawer says so. On the Companion iPhone's GPS, it reads **GPS · iPhone**.
- **Menu**: see [The Menu](#the-menu).
- An iPhone icon appears while a companion is connected.

On the iPhone, the header is the phase button (with the lap at its right end in circuit mode) and **Menu** alone; the flight time, the circuit's counts and **Abandon Flight** are in the Menu (see [The Cockpit on the Phone](#the-cockpit-on-the-phone)).

### The Phase Bar

Under the header, one segment per phase: the current one taller, the others coloured by their status (green done, or outlined in green for a landing check confirmed after the landing; orange skipped; red when a required ENGINE START or ENGINE SHUTDOWN was not pressed; amber for an overdue check, for Cruise while FREDA is due, or for a landing check you were not sure of; grey not started). Tap a segment to jump to that phase (on the iPhone, the bar is drawn inside the phase button: a phase is picked by its name in **Select Phase**). A jump forward leaves the phases behind it the way NEXT does: they turn orange, and their unchecked items go on the [deferred list](#deferred-items-and-next). Coming back to a phase takes its open items off that list again. In circuit mode, Cruise and Descent are left out, and two brackets with ↻ mark the loops a lap flies again, each with its count: over the bar, the touch-and-go loop (the climb check to the landing check, with the touch-and-goes and go-arounds, which fly the same loop); under it, the full-stop loop (the before take-off check to the after landing check, with the full stops). The current lap's loop is drawn full, the other faint. On the iPhone, the bar in the phase button has a mark under the current loop's phases instead.

### The Instrument Strip

From the taxi check to the after landing check, whenever the aircraft moves, the strip shows:

- **GS kt**: GPS ground speed. In a phase with a target speed it is green within 5 kt of the target and amber outside it, with a bar that fills as you get closer; without a target (taxi, run-up) it is plain white. A tap on it opens **V-SPEEDS**.
- **ALT ft**: GPS altitude, with the vertical speed under it (↑ or ↓, from 50 ft/min; on the iPhone, beside ALT's label).
- **TRK**: the GPS track.
- **NEXT** (iPad): the waypoint you are flying to, in magenta ("E (LSGC)", or "E" when that does not fit), and at its right, one under the other, its bearing, its distance (NM), the ETE and the ETA. ETE is given in minutes ("13 min", or "1:07 h" past the hour), so it does not read as a clock time; ETE and ETA appear only above 30 kt, so a taxi at 8 kt does not promise an hour and a half to the first waypoint. While you divert, **DIVERT** takes the place of NEXT, over the diversion field. Without a route the cell stays, with dashes, so the strip never divides again. A tap on it opens ROUTE. On an iPad on its side, the figures sit on one row beside the name ("206° · 17.5 NM · 10 min · 11:58").

On the iPhone, NEXT is a line of its own under the strip (see [The Cockpit on the Phone](#the-cockpit-on-the-phone)).

Ground speed is not the airspeed your panel shows (a head- or tailwind shifts it), and the app has no pitot or angle-of-attack source: it deliberately shows **no estimated airspeed and no stall warning**. Fly the aircraft's certified airspeed indicator. When the GPS degrades, a failure flag covers the values; when it is lost (no position for 45 seconds), only the flag remains, so a silent dropout is never mistaken for a valid reading. A flight whose track is not recording (no location access, for one) shows the lost flag too, whatever the signal, on every page of both devices.

### NOW and NEXT

Under the strip, in every phase and on every page, the two frequencies to have set, one line each:

- **NOW**: the station you are on.
- **NEXT**: the one to call next, or one to listen to, tagged **LISTEN** in NEXT's place.

Each line gives the frequency, then the station's name, set smaller when it is long but never left out. Both follow the flight whichever page is on screen, CHECKLIST included.

On a route, they follow its radio timeline: every call in the order the flight makes it, the stations the nav log prints, worked out from the route at its planned altitudes. NEXT is the next call on another frequency; when its moment comes it falls due, and a tap on it makes it NOW (see [Changing Frequency](#changing-frequency)). The calls, as they come:

- **The departure aerodrome**, from the ground to the level-off (10 NM out at most). One with a zone of its own (a CTR, a FIZ) is the call until you leave that zone.
- **The FIS of each area**, from boundary to boundary: Zürich Info or Geneva Info, either side of their line, and Bâle Information (130.900) over the Ajoie and the northern Jura from 2,000 ft above the ground (the part of TMA BALE ZURICH, AZ4, where Zurich hands low-level VFR traffic to Basel).
- **A CTR, an RMZ or a FIZ** (an ATZ too): from 5 minutes before its boundary to its exit. A zone active by NOTAM (HX) counts as active, with HX after its station ("LSZG TWR HX"). A zone the route may or may not enter (a limit in ft above the ground, or a flight level) is never called; ROUTE lists it.
- **A TMA the FIS clears** (TMA GENEVA, the Basel sectors, the Swiss class C TMAs such as TMA ZUERICH): the Info stays the call, with the TMA named beside it from 10 minutes before ("Zürich Info · TMA ZUERICH"), where it fits.
- **An aerodrome whose reporting points the route flies** (V and E of Les Eplatures, outside its CTR): its station, from 5 minutes before the first point to 2 NM past the last.
- **The destination**: 5 minutes before the aerodrome (before its zone's boundary, where it has one), or 2 minutes before its arrival point (the route's last waypoint of that aerodrome) if that comes first. NEXT is empty from then on.

The minutes count at your ground speed (from 30 kt; slower than that, the leg's planned speed): the same minutes before, a slower aircraft gets its calls nearer the boundary, a faster one further out.

NEXT reads **LISTEN** for a station to listen to rather than call:

- **The destination's ATIS**, from 10 minutes before the destination's call until it.
- **An aerodrome on the way**, one the route passes within 2 NM with no zone of its own: from 5 minutes before abeam to 2 NM past, NOW staying with the Info. **Aerodromes on the way**, in **Settings › Checklist & Flight** (on by default), turns these off.

Of two LISTENs at once, the one whose window ends first shows, then the other.

A frequency has one name all flight: of two names for it, the 8.33 kHz channel's ("120.105", not "120.100"), and an aerodrome's own zone goes under the aerodrome's name ("LSGC TWR 118.130", not "LES EPLATURES 118.125"). With OpenAIP's aerodromes on the device, an aerodrome's own radio reads as its country writes it ("LSZQ AD 122.055"; A/A in France).

Off a route's timeline, NOW and NEXT move by themselves, nothing comes due, and a tap on either opens ROUTE:

- **Without a route**: an aerodrome is NOW only inside its zone (a CTR, an RMZ, a FIZ or an ATZ), or within 3 NM of one that has none; else the area's FIS (Bâle Information over AZ4 at your GPS altitude). NEXT is, near an aerodrome, the area's Info; else the nearest control zone within 25 NM; else the nearest aerodrome.
- **In circuits**: NOW is the field, NEXT is empty.
- **While you divert**: NEXT is the diversion field, which becomes NOW 5 minutes before it (or inside its zone); NEXT is then empty.
- **More than 5 NM off the route**: the rules without a route, until you are back on it.

Without a GPS position or airport data, they follow the route instead: the departure's frequency, then the next waypoint that has one.

On the iPhone, the NOW line sits under the next line. NEXT is on ROUTE's RADIO list, and on the NOW line while it is due (see [The Cockpit on the Phone](#the-cockpit-on-the-phone)).

### Changing Frequency

The app does not hear the radio, and the FIS or a tower often gives the change ("frequency change approved") before or after the timeline's call point. So on a route, NOW changes when you say so:

- **NEXT comes due** at its call point: outlined, with a line along its foot that runs out at the latest point, where the app changes by itself. NOW stays as it is. With Reduce Motion on, the line steps down once a second.
- **A tap on NEXT** makes it NOW, due or not, and the message "LSZG TWR HX now" offers **UNDO** for six seconds, where a MARK's does (see [Leg Timer and MARK](#leg-timer-and-mark)). A second tap within a second does nothing (a bounce in turbulence never takes the call after it as well), and neither does a tap in the two seconds after the app's own change: it was meant for that call.
- **Without a tap**, the app changes at the latest point: "Zürich Info now, automatically", outlined like a waypoint marked automatically, with UNDO. Undone, the call stays due in NEXT, without its line, and the app leaves it to you.
- **A tap on a LISTEN** marks it heard ("LSZG ATIS heard", with UNDO), and NEXT shows the call after it. A call that is due comes before a LISTEN.
- **A tap on NOW** opens ROUTE, where a tap on a row makes that station NOW, as when a controller sends you to another (see [The Route Page](#the-route-page)).

Where each change comes due, and where the app makes it at the latest:

- **Leaving the departure**: due at the level-off (from an aerodrome with a zone, once out of it); the app changes 2 NM out of that zone, or 10 NM out, whichever comes first. A zone the climb goes into comes due before, by its own rule.
- **Into a CTR, an RMZ or a FIZ**: due 5 minutes before its boundary; the app changes at the boundary.
- **Out of a zone, back to the Info**: due at its exit; the app changes 2 NM past it.
- **From one Info to the next**: due 2 minutes before the boundary; the app changes at the boundary, never to an Info you would be on for less than a minute.
- **An aerodrome at its reporting points**: due 5 minutes before the first point; the app changes 30 seconds before it.
- **The destination**: due 5 minutes before it, or 2 minutes before its arrival point; the app changes at its zone's boundary or 30 seconds before its arrival point, whichever comes first (without either, 2 minutes before the aerodrome).

The station you are on is kept with the flight: a relaunch in flight comes back to it, and a route changed in flight (an edit, a Direct) keeps it, the calls behind the aircraft taken as made.

### Three Pages

**CHECKLIST · MAP · ROUTE**, under the read band, picks the page:

- **CHECKLIST**: the phase's checklist (see below). At its top, a row of chips: an amber chip with the number of deferred items, **BRIEFING** at the before take-off check and the descent check (on the iPhone; the iPad has it beside the page names), and **NEXT** while the list still has items open (it leaves through the review, see below). The row keeps its height when none shows, so the list never moves.
- **MAP**: the chart (see [The Map](#the-map)).
- **ROUTE**: the destination, the legs and every frequency (see [The Route Page](#the-route-page)).

The page also follows the flight by itself, between CHECKLIST and MAP: the checklist on the ground, around take-off and landing, and whenever a checklist is open; the map in Climb, Cruise and Descent once that phase's checklist is worked through. A check from memory (see [Memory Items](#memory-items)) has no list to show, so it opens on the map, where the [check slot](#the-check-slot) takes it: in Climb, Cruise and Descent, and in Approach, Landing and After Landing too. A check coming due never switches the page, and ROUTE is never chosen for you. A tap on any of the three overrides the choice until the flight moves on: the next phase, or the check done or opened again.

On the iPad, **BRIEFING** (at the before take-off check and the descent check) and **V-SPEEDS** sit at the right of the three, on every page; in a window too narrow for BRIEFING, it goes back to the top of CHECKLIST and to MAP's status slot, as on the iPhone. On the iPhone, V-SPEEDS is in **More**. On both, a tap on GS opens V-SPEEDS.

### Working the Checklist

The checklist runs step by step, as on paper with a finger on the line. The current item is framed where it stands in the list, larger, with its place ("3 / 11"); the items checked above it are dimmed with a tick, and the ones below wait their turn. The list scrolls to keep the current item near the top.

- **CHECK**, the act band's second slot, with the item's challenge under the word (on the iPad; the iPhone's says CHECK alone, the item framed in the list above), checks the current item and moves the frame to the next one.
- **DEFER** ("keep for later"), the third, passes over the current item without checking it: it stays in the list in amber and goes on the deferred list.
- Tap a checked (or deferred) item to go back to it: that item and everything after it are open again.

On the iPad the list only reads, and CHECK is the way to check. On the iPhone, a tap on the list checks as well.

When the last item is checked, the checklist's closing line ("CRUISE CHECK COMPLETE", for instance) turns green, and the second slot becomes **NEXT: <phase>**, with "All checked" (or the number of deferred items) under it; at the end of the before take-off check it reads **READY FOR LINE UP** (on the iPhone, **NEXT** and **READY** alone; see [The Act Band](#the-act-band)). If the phase has its own button still to press (ENGINE START, ENGINE SHUTDOWN), that one pulses first.

### Deferred Items and NEXT

NEXT with items still open lists them first ("3 items not checked", with the phase): **BACK TO CHECKLIST** stays on the phase, at the first open item; **CONTINUE, CHECK LATER** leaves it, and the unchecked items become deferred items. The phase turns orange.

Deferred items follow you until you check them. On CHECKLIST, the amber chip with their number, at the top of the list, opens **Deferred items**, phase by phase, each with its own **CHECK**. On MAP and ROUTE, **More** opens the same list ("2 deferred items"). A skipped phase turns green once its last deferred item is checked; a phase missing its ENGINE START or ENGINE SHUTDOWN stays red.

In circuit mode, a go-around or a touch-and-go starts the checks from Climb on clean, and NEW CIRCUIT those from the before take-off check to the after landing check, their deferred items included: what you put off on the last lap is asked again on this one.

### When a Check Is Due

The flight says when each check falls due, without pulsing, beeping or switching the page. Before its moment a check is dark (you can still do it early); at its moment it turns amber.

- **Climb**: 500 ft above the field, after the take-off, not on the take-off roll. Until the take-off, the line-up check's NEXT waits for it (see [The Act Band](#the-act-band)).
- **Cruise**: at the level-off.
- **Descent**: once the aircraft is really going down. A dip you climb back from withdraws it.
- **Approach**: 5 NM from the destination; without a route, when you descend near an aerodrome; in circuits, on the downwind, once the turn onto it is flown (at the level-off when the app has no course to go by).
- **Landing**: at circuit height near the aerodrome you are approaching. It is shown, never asked: from there to the runway there is nothing to press.

The other checks (on the ground, after landing) are due as soon as they come up, and so is every check when the device has no airport data.

A check the flight moves past while it is still open turns **overdue**, once: filled amber, with what passed it ("overdue · not done before level-off"), until you do it (it then counts as done late) or skip it. The flight's debrief lists it (see [Checks](#checks)).

### The Check Slot

The **check slot** holds the current check, in the act band's first slot: on MAP and ROUTE in every phase, and on CHECKLIST too, except at the engine start, the engine shutdown and in the cruise, where the phase's own button takes the slot (see [The Act Band](#the-act-band)). It names the check and what it needs, and a tap does it:

- A check with a list: "CRUISE CHECK · 5 items". On MAP and ROUTE, the tap opens the checklist, and the map comes back after the last CHECK; on CHECKLIST, it brings the current item into view.
- A check from memory: "from memory · one tap when done". The tap records it done.
- An overdue check: its reason ("overdue · not done before the descent"), and the same tap.
- Once a check is done, the slot offers the next one ("next check"), dark until its moment, then amber; a tap goes on to it (and records it done, for a check from memory).
- A phase button still to press: "ENGINE START first", which opens the checklist. Once the before take-off check is done: **READY FOR LINE UP**, "then LINE-UP CHECK". From the line-up check to the take-off, a tap on the climb check opens the checklist rather than going on to it.
- From circuit height: the landing check, dashed, "nothing to press".

On the iPhone, the slot shows the check's word alone (**CRUISE**, **CLIMB**; **READY** once the before take-off check is done), on one line: its colours and its frame say the state, and VoiceOver reads the whole name and its line.

On MAP and ROUTE, in Approach and Landing, and from circuit height, **GO AROUND** and **TOUCH-AND-GO** sit beside the slot in place of MARK and Divert (see [The Act Band](#the-act-band) for how they work).

### FREDA

In cruise, once the cruise check is done, **FREDA** (fuel, radio, engine, direction, altimeter) takes over from it. FREDA is due every 10 minutes, or at a waypoint passed 5 minutes or more after the last one, whichever comes first.

The check slot says when the last one was done ("FREDA ✓ 14:34", the cruise check's time at first) and counts down to the next ("FREDA in 6 min"; a tap opens the checklist). When FREDA is due, the slot turns amber (**F·R·E·D·A** on the iPad, with the waypoint's name) and the Cruise segment of the phase bar too: one tap records it, and a message ("FREDA done at 14:34") offers **UNDO** for six seconds. On CHECKLIST, the FREDA button takes the act band's first slot in Cruise and does the same: dimmed until the cruise check is done, then counting down, amber when due, and a tap records FREDA (early, if you like). The cruise list itself is not reset. On the iPhone, the slot and the button say **FREDA** alone, in the colour of their state.

FREDA stops at the descent; one that was due and not done is logged as missed. There is no FREDA in circuit mode.

### The Landed Card

With **Confirm landings and go-arounds** on (**Settings › Checklist & Flight**, off by default), a full-stop landing outside circuit mode brings the landed card over the Cockpit: "LANDED · LSZQ · 14:44 · Was the landing check done before touchdown?", with **YES, IT WAS DONE** and **NOT SURE**. Yes records the landing check as confirmed after the landing (outlined in green on the phase bar); Not sure puts it in the debrief, in amber. Either way the full stop is logged at the touchdown and the checklist goes on to the after landing check. When the landing check was done before touchdown, the card says so and offers **NEXT: AFTER LANDING CHECK**.

The card waits for an answer, however long the taxi off the runway takes, and goes by itself only on the next take-off roll. The Companion iPhone can answer it too. In circuit mode, a full stop brings the full-stop card instead, whose **Confirm** goes on to the after landing check as well (see [Circuit Mode](#circuit-mode)).

With the setting off, there is no card: the full stop is recorded at the touchdown, with UNDO in a message (see [Flight Events](#flight-events)), and the checklist goes on to the after landing check, nothing asked about the landing check; one still open goes to the deferred list, as on any jump.

### Memory Items

Every item is shown by default. Turn on **Hide memory items** (in the Menu, under **Settings › Checklist & Flight**, or in the introduction) to hide the memory items, the items you should know by heart, so you say them from memory. A **MEMORY ITEMS** banner at the end of the list says how many are hidden ("3 items hidden: hold to reveal"); hold it to show them for the current phase.

A check with every item hidden is done in one tap. On CHECKLIST, the second slot's **✓ CLIMB CHECK DONE** (with "NEXT: CRUISE CHECK · from memory" under it; on the iPhone, **DONE** alone) records it done from memory, in green, and opens the next check; in the [check slot](#the-check-slot), a tap records it. A message ("CLIMB CHECK done from memory") offers **UNDO** for six seconds, which takes both back. **Hide memory items** (called Memory test before 6.4.0) replaces the former learning mode.

### V-SPEEDS and BRIEFING

**V-SPEEDS** opens the aircraft's speeds (indicated airspeed, in knots) in a drawer from the bottom: from its chip beside CHECKLIST · MAP · ROUTE on the iPad, from **More** on the iPhone, and with a tap on GS on both. On the iPad it is one fixed table, the same in every phase: **STALL & GLIDE** first, on a panel of its own (Vso and Vs in amber, Vne in red), then **TAKE-OFF & CLIMB**, **APPROACH & LANDING** (in the order they are flown), **LIMITS**, **OTHER** and **CROSSWIND** (T/O and LDG). The phase only decides which cells are framed, where they stand: Vr at the before take-off check and the line-up check, Vx below 300 ft above the departure field and then Vy in the climb, Vno and Va in cruise, Va and Vbg in the descent, the approach speeds on approach, Vfinal and Vso on landing. On the iPhone the speeds are a list, with the phase's highlighted. Tap outside the drawer, or drag it down, to close it.

**BRIEFING** opens the departure briefing at the before take-off check and the approach briefing at the descent check. On the iPad, it sits beside CHECKLIST · MAP · ROUTE, between ROUTE and V-SPEEDS, on all three pages (in a window too narrow for it, as on the iPhone); on the iPhone, at the top of CHECKLIST, and in the [status slot](#the-status-slot) on MAP. See [Briefings](#briefings).

### The Act Band

The act band is the four slots at the foot of the Cockpit, under every page. Their size and their place never change; what they hold follows the page and the phase:

- **CHECKLIST**: **ENGINE START** at the engine start, **ENGINE SHUTDOWN** at the engine shutdown, **FREDA** in the cruise, the [check slot](#the-check-slot) in every other phase; then **CHECK** with the current item; **DEFER** (dimmed when there is nothing to defer); and **More**.
- **MAP and ROUTE**: the check slot; **START LEG**, then **MARK** with the waypoint and the leg timer (see [Leg Timer and MARK](#leg-timer-and-mark)), or **Routes** without a route; **Divert** (amber while you divert, dimmed without a route or once it is flown); and **More**.
- **MAP and ROUTE, in Approach and Landing, and from circuit height**: the check slot; **GO AROUND**; **TOUCH-AND-GO**; and **More**, with **Divert** inside.
- **In circuit mode, once the after landing check is done**: the check slot offers the parking check, and **NEW CIRCUIT** takes the second slot on every page (NEXT's place on CHECKLIST, MARK's on MAP and ROUTE), with "then BEFORE TAKE-OFF CHECK" under it. See [Circuit Mode](#circuit-mode).

**More** holds what you need less often: **Divert** where the third slot holds something else (on CHECKLIST, and from the approach), the leg timer's pause or start and **Reset chronometer**, **Legs and frequencies** (it opens ROUTE), the deferred items on MAP and ROUTE ("2 deferred items"), on MAP **Show the whole route** and, with SIGMETs in range, **Hazards (2)**, **V-SPEEDS** on the iPhone, and **Routes**.

If you flew with 6.1, three things moved: CHECK is the second slot, no longer at the right end of the bar; the map's legs and frequencies panel is now the ROUTE page; and the deferred count on MAP and ROUTE, and V-SPEEDS on the iPhone, are in More.

On the iPhone, the band is one line of words: no icons and no second lines, the first three slots as wide and **More** the narrow one at the right end. On MAP and ROUTE it reads, for instance, **CRUISE · MARK · Divert · More**; on CHECKLIST in cruise, **FREDA · CHECK · DEFER · More**. The check slot shows the check's word, MARK says **MARK** alone (the waypoint is the read band's next line, the leg time is on ROUTE), and the long names are shortened: **DONE** for a check from memory, **NEXT**, **READY** for READY FOR LINE UP, **START** and **SHUTDOWN** for ENGINE START and ENGINE SHUTDOWN, **↻ CIRCUIT** for NEW CIRCUIT. GO AROUND and TOUCH-AND-GO take one line each, with no **Hold to confirm** under them and no count; the hold is still 1 second. A word too long for its slot is set smaller, never cut, and VoiceOver still reads the whole names.

Each phase's own buttons are in the checklist's language:

- **ENGINE START** and **ENGINE SHUTDOWN**, each in its own phase: a tap records the time. Once it is recorded, hold the button 1.5 s to change it; AéroCheck asks first.
- **READY FOR LINE UP** is the NEXT of the before take-off check: with every item checked, the second slot reads READY FOR LINE UP, with "then LINE-UP CHECK" under it. The tap records the line-up time and goes on to the line-up check. The ETOs count from the line-up until the take-off shows in the track (within about 30 seconds of lift-off), then from the take-off.
- **AFTER TAKE-OFF** is the NEXT of the line-up check, with "Climb check after take-off" under it on the iPad, and a tap on it does nothing: the climb check is for once you are airborne. It opens at the take-off the app detects, or once the ground speed reaches 40 kt. It waits only where the app can detect the take-off (an aerodrome near enough in its data), and the phase bar and **Select Phase** still go anywhere.
- **FREDA** (Cruise): see [FREDA](#freda).
- On CHECKLIST, in **Landing**, **GO AROUND** and **TOUCH-AND-GO** sit above the act band, and in **After Landing**, **FULL STOP LANDING**. On MAP and ROUTE, GO AROUND and TOUCH-AND-GO are the second and third slots from the approach on. Each needs a 1-second hold (**Hold to confirm**), so a stray touch cannot fire it. On CHECKLIST each shows its count beside its name once there is one; on MAP and ROUTE only the iPad's GO AROUND does (TOUCH-AND-GO's narrow slot and the iPhone's band have the name alone). A go-around or a touch-and-go takes the checklist back to the climb check; near the route's destination, it also turns circuits on (see [Circuit Mode](#circuit-mode)).
- In circuit mode, **GO AROUND** and **TOUCH-AND-GO** are single taps instead, to correct a missed detection at once, and show no count (the counts are on the iPad's phase bar and in the Menu).
- **END FLIGHT** takes NEXT's place once the last phase is checked.

When **Log Engine Hours** is on (**Settings › Checklist & Flight**), the checklist offers the hour meter at the end of the before start check and at the engine start (it asks by itself as the engine start opens, if you have not entered it yet), and again after ENGINE SHUTDOWN, in the shutdown phase and At the Hangar.

### The Route Page

**ROUTE** is where the flight goes and who to talk to on the way. The flight never opens it for you: pick it, or tap NEXT (the waypoint) or NOW in the read band, NEXT's frequency too off a route's timeline (on the iPhone, the next line opens it on LEGS and the NOW line on RADIO), or **Legs and frequencies** in More. From top to bottom:

- **The DEST line**: **DEST** and the destination, then the distance still to fly, the ETE and the ETA over the destination, and how far ahead of the plan (▲, green) or behind it (▼, amber) you are, in whole minutes (±0 on time). On the iPad it is one line; on the iPhone too, without the ETA ("DEST LSZB 52 NM · 30 min ▲3"), a long name set smaller rather than cut.
- **The route to scale**, under it, on the iPad: a bar as long as the route, filled as far as you have flown, with a notch at each waypoint where it lies along the route (the next one magenta and taller), and the aircraft where it is. The iPhone has none.
- **LEGS** and **RADIO**, each scrolling on its own: side by side on the iPad; on the iPhone, one at a time: a **LEGS | RADIO** switch under the DEST line picks the list, which takes the page down to Emergency (ROUTE opens on LEGS, from CHECKLIST · MAP · ROUTE too). LEGS opens on the leg being flown and brings it back into view at each MARK. Each leg, on the row of the waypoint it leads to, gives its planned time, the time flown (the leg timer on the leg being flown; from one time over to the next on a leg flown) and how far ahead (▲) or over (▼) you are, a leg of an hour or more as "1h05"; on the iPhone, each leg is one line, a long name set smaller, never cut. RADIO lists every frequency in the order you will use it: NOW and NEXT, tagged; on the ground, the aerodrome you are at, with its ATIS; then the route's radio timeline from NOW on (see [NOW and NEXT](#now-and-next)), each station once, a LISTEN in its place and tagged; the zones the route may or may not enter; and, under **NEARBY, OFF ROUTE**, the control zones within 25 NM that the route does not call. A tap on a row (all but NOW, a LISTEN and Emergency) makes that station NOW, with UNDO, off the route too: the station a controller sends you to. While NEXT is due, its row is outlined. Off a route's timeline (no route, circuits, a diversion), the list is the aerodrome you are at, with its ATIS; the diversion field; the stations of the route from the waypoint you are flying to onward (the aerodromes passed are dropped); the FIS where you are, then that of each area the way ahead enters, in the order it enters them (Zürich Info, then Geneva Info from LSZQ to LSGE); and the control zones within 25 NM. Without a route, RADIO takes the whole page.
- **Emergency**, 121.500, under both, always whole.

The DEST line's ETE is NEXT's (the leg being flown, at the current ground speed) plus the planned EETs of the legs after it, to overhead the destination without the arrival allowance; ▲ or ▼ compares the ETA with the plan's time over the destination. Below 30 kt or without a GPS position, there is no ETE, ETA or ▲/▼: the line gives the plan's time over the destination instead ("ETO 11:55"). Once the destination is marked, it keeps the final ▲ or ▼.

Tap a leg to see it on MAP, framed on that leg (the waypoint before it and its own). A bar at the foot of the chart (left of the buttons on the iPad, across the chart on the iPhone, whose buttons give way) offers **Back to aircraft** and the leg's action: **Direct** and the waypoint's name, for a waypoint ahead, flies you straight to it; **Resume leg**, for one already passed, asks first ("Go back to this leg?"), then clears its crossing and the later ones and restarts the leg timer. **Centre** does what Back to aircraft does, and leaving MAP ends the framing.

While you divert, the DEST line shows the diversion field in amber, with the distance, the ETE and, on the iPad, the ETA straight there (and no ▲ or ▼: the plan knows nothing of that field). On the iPad, **Resume route** takes the place of the route bar; on the iPhone, it is in the Divert sheet. With an ATC flight plan filed, a line under it reminds you to tell FIS ("ATC flight plan filed: tell FIS you are diverting to …").

The act band on ROUTE is MAP's: the check slot, START LEG or MARK, Divert and More.

### The Menu

**Menu**, at the right of the header, opens (in a dry run, its own **DRY RUN** group first, see [Dry Run](#dry-run)):

- **DISPLAY**: the **Cockpit theme**, **Auto**, **Day** or **Night** (Night dims to red to protect your night vision; Auto follows the device's appearance), and **High contrast in sunlight**, which switches to a high-contrast palette while the screen is near full brightness (the app cannot read the ambient light, so brightness is the signal).
- **OPTIONS**: **Circuits** (on and off during the flight, see [Circuit Mode](#circuit-mode)), **Hide memory items**, **Always Use UTC Times**, and **Enable Companion Mode** once a device is paired.
- **GPS STATUS**: the signal and the points recorded.
- **FLIGHT TIMES**: the **Flight time**, running since ENGINE START, then engine start, take-off, landing and shutdown, as recorded.
- **CIRCUITS**, in circuit mode: the touch-and-goes, the full stops and the go-arounds.
- **END FLIGHT**, from any phase ("Ends the flight now, in any phase."), after a question.
- **Abandon Flight**, under it, after a question ("Abandon Flight?"): see [Ending or Abandoning a Flight](#ending-or-abandoning-a-flight).

### Checklist Language

When an aircraft's checklist exists in several languages, choose yours under **Settings › Checklist & Flight › Checklist Language**: Auto (follows the device language), English or French. If your language is not available for an aircraft, English is used.

### The 16 Flight Phases

AéroCheck covers every phase of flight, each named for its check, in the order **Select Phase** lists them:

1. Pre-flight check
2. Before start check
3. Engine start
4. After start check
5. Taxi check
6. Run-up
7. Before take-off check
8. Line-up check
9. Climb check
10. Cruise check
11. Descent check
12. Approach check
13. Landing check
14. After landing check
15. Engine shutdown and parking check
16. At the hangar

In circuit mode, Cruise and Descent are skipped. **Select Phase** keeps them, dimmed and marked "skipped in circuits", and a tap on either asks "Leave circuits?" (see [Circuit Mode](#circuit-mode)).

### Ending or Abandoning a Flight

**END FLIGHT** (the act band's second slot after At the Hangar, or in the Menu at any phase) asks first ("End Flight?"), then saves the flight to your logbook and stops the GPS recording. A followed flight then moves to its close-out ([Close](#close)); a circuit session offers a light close-out ([Circuit Mode](#circuit-mode)). If the track disagrees with the recorded events, or the app recorded some by itself, a review follows ([Post-Flight Review](#post-flight-review)).

To abandon a flight, open the Menu and tap **Abandon Flight**, under END FLIGHT, then confirm ("Abandon Flight?"). On the iPad, touching and holding the registration in the header for 1.5 s, until the ring around the aircraft icon closes, asks the same question. **Abandon Flight** discards the flight without saving it; its GPS data is lost.

---

## The Map

The map is the same chart in two places: the **MAP** page of the Cockpit, and **Plan › Map** on the ground, so the map you plan on is the map you fly with. It opens on your position, at the zoom you left it. In the Cockpit, the next waypoint and the frequencies are in the read band and the legs on ROUTE, so MAP is the chart alone: the aircraft, the route and the airspace, a few buttons low on the right edge (see [Map Controls](#map-controls)) and one [status slot](#the-status-slot) at the top left, dark until something needs you. Plan › Map keeps its next waypoint, its frequencies, its legs, its labelled controls, its badge and its scale on the chart, as before.

### The Next Waypoint

In the Cockpit, the next waypoint is NEXT, in the read band (see [The Instrument Strip](#the-instrument-strip)). In **Plan › Map**, with a route on the map, it sits on top of the chart: its name in magenta, then **BRG**, **DIST** (NM), **ETE** and **ETA**, as a card on the iPad and one line on the iPhone. Tap it, or NOW | NEXT at the foot of the map, for every leg and every frequency: the panel opens under the chart, which clears its controls and frames the leg to the next waypoint. A tap on the chart closes the panel and puts the map back as it was.

The panel opens with ROUTE's DEST line, on one line (see [The Route Page](#the-route-page)), then the legs, each with its planned leg time at the right ("1h05" for an hour or more), and the frequencies. On the iPad, each leg also has its distance under its name, with a bar to the route's scale, the longest leg the widest: you see how the waypoints split the route (the route to scale stays on ROUTE). Tap a waypoint to look at its leg on the map: the leg ending there, both ends in view, at least 3 NM across, wherever the device itself is. Plan › Map has no **Direct**: nothing is flown before the flight exists (in flight, a leg shown from ROUTE keeps its Direct).

If none of the route is on screen, a pill says where it is ("Route 12 NM · 045°"); **Show** frames it. In the Cockpit, the arrow at the chart's edge, OFF ROUTE and **Show the whole route** in More say the same.

### The Map Sheet

**Map** (the layers button on the Cockpit's MAP) opens everything about how the map looks, in one sheet:

- **Base chart**: **ICAO chart/Glider map** (the Swiss aeronautical chart 1:500,000, which becomes the glider chart, the Segelflugkarte 1:300,000, when you zoom in, unless **Force ICAO Chart Layer** is on), **National map**, **SWISSIMAGE**, **Apple Maps** and **Apple Maps Satellite**. The Swiss layers are available within and near Switzerland. In offline mode, the cached ICAO chart is the only one. The chart you pick is kept on the device: the map opens on it, in the Cockpit and in Plan › Map.
- **Presets**: **Cruise** shows airspace and reporting points; **Approach** adds airports, obstacles, the traffic circuits and the arrival and departure routes; **Everything** shows every marker, and the circuits and routes too. Airspace stays on in all three.
- **Airspace & charts**: **Airspace** (the OpenAIP airspace, drawn as a vector overlay) and **Map tiles** (OpenAIP's raster tiles, off by default). When the airspace is on and no data is downloaded, the sheet says so and offers **Download data…**.
- **Map markers**, from the downloaded OpenAIP data (see [Aeronautical Data and Storage](#aeronautical-data-and-storage)): **Airports** (with frequencies on tap), **Navaids** (VOR, DME, NDB), **Reporting points** and **Obstacles** (towers, masts, wind turbines; off by default, they are dense). **Show all** or **Hide all**.
- **Aerodrome procedures**, from open flightmaps: **Traffic circuits**, **Arrival & departure routes (with sectors)** and **Glider, UL & helicopter**. All three are off by default, and no preset turns on the third. See [Traffic Circuits and VFR Routes](#traffic-circuits-and-vfr-routes).
- **Flight**: **Track vector**.

The foot of the sheet credits the sources it draws from: open flightmaps (with the AIRAC cycle on the device) and OpenAIP.

When the downloaded airspace is aging, an amber mark sits on the **Map** button (or the layers button), and the sheet explains it ("Airspace data is out of date") with **Update**, so you know that what is drawn may not reflect recent changes.

### Traffic Circuits and VFR Routes

With **Traffic circuits** or **Arrival & departure routes** on, the map draws the aerodrome procedures that open flightmaps publishes, in {ofmCountries} countries (most of Europe; the most complete are Switzerland, Austria, Germany, the Czech Republic, Slovakia and Hungary; the [Countries](/countries) page has the figures): in Plan › Map, in the Cockpit's MAP, and in the route editor (its layers button has the same three switches, as does **Settings › Navigation & Maps**). They are **indicative**: open flightmaps is a community source, and the aerodrome's official chart always prevails (it is one tap away, see below).

- **A traffic circuit** is a solid dark-blue line with a white edge, with its altitude on the downwind ("2900 ft", or "Alt: see chart" when open flightmaps gives none). A field with several circuits (by runway, or by type of aircraft) shows each of them. Altitudes that would cover each other on screen are stacked, each one a label further out, and two identical ones show once.
- **An arrival or a departure** is a dashed blue line with its name halfway along, and an arrowhead toward the field (arrival) or away from it (departure). **A sector** is a light blue area with a dashed outline; Austria's noise-abatement areas are a grey hatched outline.
- **Glider and UL circuits** are dashed, **helicopter** procedures dotted. A shape open flightmaps only has roughly is drawn thinner and lighter. At night, the blue gets lighter and the edge dark, so nothing on the chart glows white.

**Glider, UL & helicopter** works on its own: a glider pilot can show the glider circuits without the powered ones. It also shows the helicopter routes (with **Arrival & departure routes** on) and the reporting points meant for gliders and helicopters.

Tap a label for its callout: the procedure's name, what it is ("Traffic circuit · 2900 ft · LSZQ"), its source and cycle ("open flightmaps · AIRAC 2610 · indicative, check the official chart"), then **Official chart** (see [Official Chart](#official-chart)) and **Report an error**. Report an error opens open flightmaps' error form in the browser, with the region, the cycle, the aerodrome and the procedure already filled in (nothing about you); without a form, the same text comes as an e-mail, which you send or not.

To keep the chart readable, the procedures are drawn only when the map shows 40 NM or less across (on its shorter side), and their labels (and so their callouts) from 20 NM. At most 80 are drawn at once: your destination's first, then your departure's, then the nearest.

Near an aerodrome, the map adds its approach view: in flight, for the destination (or the field you divert to) within 10 NM or from the approach check on; in Plan › Map, for the aerodromes in view once the map shows 8 NM or less. It draws each runway's extended centreline with the runway numbers at its ends (in flight, the number of the runway in use filled, from the wind), the circuit's direction for that runway, and a parachute beside the field where OpenAIP reports parachuting.

In the United States, where open flightmaps has no data, **Traffic circuits** shows the traffic patterns of the FAA's NASR instead. Each runway number carries the side its pattern turns ("30 RIGHT", "12 LEFT"), and the field its pattern altitude where the FAA publishes one ("TPA 806 ft", above sea level, as the Chart Supplement prints it). No pattern is drawn: the FAA publishes no shape. In Plan › Map, the US fields in view at 8 NM or less show it; in flight, the destination. VoiceOver reads "Runway 30, right-hand traffic". The patterns are fetched the first time a US field needs them, never at launch.

The procedures come with the aeronautical data of each country (see [Downloading Data](#downloading-data)). When a switch is on and the country under the map has none on the device, the card says so ("Download VFR procedures for CZ in Data & Storage"), and a tap takes you there.

With **Reporting points** on, the map also shows the few reporting points OpenAIP lacks, from open flightmaps. They look like the others; their callout adds where they come from ("open flightmaps · AIRAC 2610"), and so does the route editor's search.

### Map Controls

On the Cockpit's MAP, the buttons sit low on the right edge, one above the other: **N↑** or **TRK** (north up or track up; a tap switches), the layers button (it opens the Map sheet), **Centre** and, on the iPad, **+** and **−**. On an iPad on its side they make a row along the foot of the chart, at the right. **Centre** fills in once you have moved the map off the aircraft, and puts it back; while the aircraft is out of sight, an arrow at the edge of the chart points to it. Pinching zooms too, and it is the only zoom on the iPhone. The scale shows at the foot of the chart while the zoom changes, and fades about 2 seconds later.

In Plan › Map, the controls are a labelled row, at the top of the chart on the iPad (under the next waypoint) and at its foot on the iPhone: a magnifying glass, **Map**, **North up** / **Track up**, **Centre** and, on the iPad, the zoom buttons, with the scale at the bottom left.

The magnifying glass, immediately left of **Map**, opens **Search aerodromes**: type an ICAO code, a name or a town, from two letters, ignoring case and accents. It lists up to 12 aerodromes, the codes first, then the names, towns and other names, each group nearest to the map's centre first, each with its town, its country and its distance from that centre. Pick one and the map moves to it, about 8 NM across, so its circuits show, and, with **Airports** shown, opens its callout. The search is Plan › Map's only.

### The Status Slot

At the top left of the Cockpit's MAP, one slot says the one thing that needs you, and stays dark otherwise. It shows one state at a time, the most urgent first, and a tap opens what it is about:

- **UNDO**: for six seconds after a MARK, a leg-timer reset, a waypoint marked automatically, a check or FREDA recorded with one tap, a go-around, touch-and-go or full stop the app recorded by itself, or a change of frequency (yours or the app's, see [Changing Frequency](#changing-frequency)), the message and **UNDO**, with its time running out under the word.
- **NO GPS** (red), by the GPS indicator's rule (see [GPS Indicators](#gps-indicators)). A tap opens the GPS Status drawer.
- **OFF ROUTE 1.2 NM** (amber), see below. A tap frames the aircraft and the leg.
- **CHART OFFLINE** (amber): the chart on screen can neither be fetched (offline mode, or no network) nor drawn from the offline cache (another layer, a zoom the cache does not hold, or outside Switzerland). A tap says where the chart comes from.
- **TELL FIS** (amber), over "Diverting to LSGC": while you divert with an ATC flight plan filed. A tap opens Divert.
- **SIGMET** (amber), with the hazard ("SEV TURB · on route"), when one is on your path. A tap opens the SIGMET sheet; **Hazards (2)** in More lists every one in range.
- **BRIEFING** (cyan), at the before take-off check and the descent check. A tap opens the briefing.
- **GPS DEGRADED** (amber), by the same rule, last: it shows only when nothing above it does (on the iPad, the header's GPS says it all along). A tap tucks it away, see below.

A tap on GPS DEGRADED tucks it into an amber square the size of a map button, in line with the buttons at **N↑**: above it when they are a column, before it when they are a row (an iPad on its side), and beside the column's foot on a chart too short for that. For the rest of the flight, GPS DEGRADED shows in that square whenever the GPS is degraded, and the slot is free for the other states. The square opens the GPS Status drawer. **NO GPS** never tucks away.

OFF ROUTE shows when the aircraft is more than 1.0 NM off the route it is flying (the leg flown, the one just flown and those still to fly, so a corner cut or a MARK pressed early is still on the route), and clears below 0.7 NM. It stays dark on the ground, in circuits, while you divert, without good GPS, and within 5 NM of the route's departure and destination, where the circuit and its joining are flown. After the take-off, a direct to a waypoint, a resumed leg, an UNDO or the route resumed after a diversion, it waits until the aircraft has been on the route once: an aircraft that never joins its route is never told.

### Frequencies

In the Cockpit, NOW and NEXT are in the read band (see [NOW and NEXT](#now-and-next)), and every frequency is on ROUTE. In Plan › Map, NOW and NEXT run along the bottom of the map, from where you are and the route rather than its radio timeline: NOW the aerodrome within 10 NM of you, else the area's FIS; NEXT the route's next aerodrome (the area's Info, on a local flight). Nothing comes due there: changing frequency is the Cockpit's. Tap them for the legs and the **RADIO FREQUENCIES**: NOW and NEXT, **All frequencies** along the way (the nearest aerodrome, the route's waypoints, the FIS of the areas on the way, nearby control zones), and the emergency frequency, 121.500, always at the foot.

### Leg Timer and MARK

In flight, with a route, the act band on MAP and ROUTE holds:

- **The check slot**, first; see [The Check Slot](#the-check-slot).
- **START LEG** starts the leg timer. The second slot then becomes **MARK** with the waypoint's name, and the leg timer under it (on the iPad, "LEG 2:05 / 17:32": the time on the current leg and the planned leg time; ‖ when paused; on the iPhone, **MARK** alone: the waypoint is the read band's next line and the leg time is on ROUTE): tap it as you pass the waypoint to record its time over and start the next leg. Once the route is flown, it is dimmed. A leg timer that never ran starts at the take-off, so the slot offers MARK for the next waypoint rather than START LEG all the way; one you paused stays paused.
- **Divert**: see below.
- **More**: pause or start the chronometer, **Reset chronometer**, **Legs and frequencies** (it opens ROUTE), and **Routes**.

Without a route, **Routes** takes MARK's place. In Approach and Landing, and from circuit height, **GO AROUND** and **TOUCH-AND-GO** take the place of MARK and Divert, and Divert moves into More.

A waypoint is also passed automatically, from the GPS track, as you pass it (abeam included), whichever page is on screen. A message ("VRP1 marked automatically at 10:42") offers **UNDO** for six seconds; a waypoint taken back waits for MARK.

For six seconds after a MARK or a reset, a message ("LSGC passed at 10:42", "Leg timer reset") offers **UNDO**: a mis-tap in turbulence is taken back with one tap. On MAP it takes the [status slot](#the-status-slot), at the top left; on CHECKLIST and ROUTE, it sits over the foot of the page, above the act band.

In Plan › Map, **Routes** takes their place: nothing is timed or marked before the flight exists.

### Divert

**Divert** (in flight, the act band's third slot on MAP and ROUTE, or in **More**) answers "where do I go instead?" in two taps and no typing. It lists the aerodromes around you, **Ahead · soonest first** and **Behind · turn back**, with the destination and the alternate; tap one to see it (with its runway, elevation and **Official chart**), then **DIVERT TO** it. Tapping the destination itself is **DIRECT TO**, not a diversion. Glacier and mountain landing sites, heliports and closed fields are not listed. With a route on the map, an airport's callout on the map offers the diversion too, on its right (**Chart**, on its left, opens the official chart).

A diversion changes where you navigate to and nothing else: Divert turns amber, NEXT shows **DIVERT** and the field, the frequencies follow it, ROUTE's DEST line shows the field, and **Resume route** (on that line on the iPad, and in the Divert sheet) takes you back to the route in one tap. With an ATC flight plan filed, ROUTE reminds you to tell FIS, under the DEST line ("ATC flight plan filed: tell FIS you are diverting to …"). Nothing administrative moves until you are on the ground; for what the flight's page offers after the landing, see [Trips and Stops](#trips-and-stops). On MAP, the status slot says **TELL FIS** as well. The Companion iPhone can divert the flight too (see [Companion Mode](#companion-mode)).

### Official Chart

**Official chart** opens the aerodrome's chart on its publisher's site, in the browser. AéroCheck never downloads or shows the chart itself, so what you read is the publisher's current version, amendments included.

- **Germany**: the aerodrome's page in DFS BasicVFR.
- **France**: the aerodrome's VAC (PDF) from the SIA, for the AIRAC cycle in force.
- **Czech Republic, Slovakia, Hungary, Slovenia, Poland, Finland, Sweden, the Netherlands, Denmark, Romania and South Africa**: the aerodrome's VFR chart, or its page in the VFR manual or the AIP, from the national publisher (ANS CR, LPS SR, HungaroControl, Slovenia Control, PANSA, Fintraffic, LFV, LVNL, Naviair, ROMATSA, SACAA).
- **Switzerland**: skyguide's VFR Manual on SkyBriefing, one page for every aerodrome, behind a login and a subscription; the button says so (**Official chart · SkyBriefing (subscription)**), so a sign-in page comes as no surprise.
- **The United States**: the airport's page of the FAA's Chart Supplement (the former A/FD), from the edition in force, public and without a sign-in. A field without an ICAO code is found by its FAA identifier ("1N7").
- **Croatia** and **Bulgaria**: the AIP portal, behind a login (Croatia Control's by order, BULATSA's after a free sign-in; the button says which).
- **Austria**, **Greece**, **Australia** and **New Zealand**: the AIP's start page (Greece's asks you to prove you are not a robot; Australia's and New Zealand's terms allow no other link).

Italy has none (ENAV's terms forbid links to its site without its authorisation), nor do Belgium and Luxembourg (skeyes allows links to its home page only) or Malta (its AIP is sold), and neither do the countries elsewhere. The link is in the airport callout on the map (**Chart**, on the left), the route editor's airport callout, the Divert list, the departure and approach briefings, the PPR and Fees tasks of a flight's page, and the callout of a traffic circuit or a VFR route.

### Track Vector

The track vector projects your smoothed ground track 5 minutes ahead, with ticks at 1, 2 and 5 minutes. It hides below 5 kt, where a track means nothing. Turn it off in the Map sheet (**Track vector**) or under **Settings › Navigation & Maps**.

### GPS Indicators

On the iPad, the GPS button in the Cockpit's header shows the signal in its colour; tap it for the GPS Status drawer (see [The Header](#the-header)). The iPhone's header has no GPS button: the strip's flags, MAP's status slot (NO GPS, and GPS DEGRADED's square, open the drawer) and **GPS STATUS** in the Menu say it.

- **Green** (**Good**) takes a fix from the satellites, within 100 m, in the last 20 seconds. A parked aircraft stays green as long as the receiver has a fix.
- **Orange** (**Degraded**): the fix is worse than 100 m, nothing has come for 20 seconds, or the positions come only from Wi-Fi or cell towers ("No satellite fix · network position"), so an iPad indoors on Wi-Fi is not green. The drawer says how long since the last position ("No position update for 25 s").
- **Red** (**Lost**): no position for 45 seconds, or no location access. In flight, the instrument strip then shows a failure flag instead of stale numbers.

An external GPS receiver's fixes count as satellite fixes. If location access is limited to "While Using the App", the GPS Status drawer says so ("Limited GPS …"), so you can grant "Always" and keep the track recording in the background.

### Offline Maps

The Swiss ICAO chart and the Segelflugkarte can be cached for offline use under **Settings › Navigation & Maps › Offline Maps** (up to about 250 MB), with **Offline Mode** to use the cache only. A cached chart is served from the device, so the map works without a connection. In Plan › Map, an **OFFLINE** or **CACHED** badge at the bottom left says which; tap it for the details. The Cockpit's MAP shows nothing while it can draw the chart, and **CHART OFFLINE** in its status slot when it cannot; the details are a tap on it, and in the Map sheet.

---

## The iPhone

The iPhone flies with the same Cockpit as the iPad: the same zones, in the same order, with the same words. Its sizes are the iPad's × 0.85: a phone is read closer, in the hand or on a yoke clip, so the text reaches the eye at the same angle.

### The Cockpit on the Phone

- **The header, on one row**: the phase button, with the phase bar drawn inside (and the lap at its right end in circuit mode), and **Menu**. A tap on the phase opens **Select Phase**, which is where a phase is picked on the phone (the iPad keeps its bar of segments to tap). The registration, the flight time and the GPS icon are not there: the Menu has the running flight time, the circuit's counts and **Abandon Flight** (see [The Menu](#the-menu)), and a GPS problem shows in the strip's flags and in MAP's status slot.
- **The strip** has three cells, GS, ALT and TRK (a tap on GS opens V-SPEEDS; the vertical speed sits beside ALT's label). Under it, one card holds the **next line** (the waypoint's name in magenta, framed in amber while you divert, then its distance and its ETE) and the **NOW line** (NOW's frequency and station). The bearing and the ETA are on ROUTE. A tap on the next line opens ROUTE on LEGS, a tap on the NOW line opens it on RADIO, where NEXT's frequency is too. While NEXT is due, the NOW line shows it beside NOW ("NOW 124.700 › 120.105 LSZG TWR HX", NOW's frequency smaller and grey, the due call outlined with its line), and a tap on the line changes frequency instead (see [Changing Frequency](#changing-frequency)). The next line comes and goes with the strip; the NOW line is there in every phase.
- **CHECKLIST · MAP · ROUTE** runs across the width, slim (the words alone where their icons do not fit). **V-SPEEDS** is in **More**, and behind a tap on GS. At the top of CHECKLIST, the deferred count, **BRIEFING** and **NEXT** appear only while they apply.
- **The act band** has the iPad's four slots, one line of words tall: the first three as wide, **More** narrow at the right end, no icons and no second lines (**CRUISE · MARK · Divert · More** on MAP and ROUTE; see [The Act Band](#the-act-band)). A word too long for its slot is set smaller rather than cut. A tap anywhere on the list checks the current item too.
- **V-SPEEDS** is a list, with the phase's speeds highlighted and the maximum crosswind under it.
- A checklist row too long for one line puts the response under the challenge. The list opens on the current item.

### The Map on the Phone

The chart takes the page between the read band and the act band, with the iPad's buttons on its right edge but no **+** or **−**: pinch to zoom. The status slot is at its top left, as on the iPad. A leg tapped on ROUTE shows with its bar across the foot of the chart, and the buttons give way to it (**Back to aircraft** does what **Centre** does). In Plan › Map, the controls sit at the foot of the chart: the magnifying glass (see [Map Controls](#map-controls)), **Map**, one button showing the orientation (**North up** or **Track up**; a tap switches it) and **Centre**.

### The Phone on Its Side

On its side, the phone puts the page on the left, at full height (CHECKLIST, MAP or ROUTE; MAP is the same chart as upright, with the same buttons and status slot, and nothing over it), and everything else in a column on the right, whichever way the phone is turned. From top to bottom:

- **One header row**, as upright: the phase button, with the phase bar drawn inside (a tap opens **Select Phase**), and **Menu**, which has the flight time, the circuit's counts and **Abandon Flight**.
- **CHECKLIST · MAP · ROUTE**, a little more compact.
- **The strip**: GS, ALT and TRK.
- **The next waypoint and NOW, on one line**: the waypoint's name and its ETE, then NOW and its frequency (the name framed in amber while you divert). On the largest phones, two lines: the name with its distance and ETE, then the NOW line. A tap opens ROUTE. While NEXT is due, it shows as on the NOW line upright (on one line, "› 120.105" in place of NOW's frequency, outlined), and a tap there changes frequency.
- **The act band**, its four slots two by two, at the foot of the column, with the same one-line words as upright.

---

## Briefings

**BRIEFING** in the Cockpit opens the departure briefing at the before take-off check, and the approach briefing at the descent check.

### Departure Briefing

Before departure, a dynamic briefing shows:

- **Airport** and **elevation** (detected from your GPS position), with the aerodrome's **Official chart** under them (see [Official Chart](#official-chart))
- **Runway** (detected or manually selected)
- **Departure procedure**: first turn direction and level-off altitude (to be briefed verbally by the pilot)
- **Wind**: from a MeteoSwiss surface station in Switzerland, from model winds elsewhere
- **Airspeeds**: rotation (Vr), best angle (Vx), best rate (Vy), best glide (Vbg), and others from the aircraft flight manual
- **Emergency procedures**: malfunction before rotation, engine failure after take-off, minimum safe altitudes
- **Nearby reporting points**: compulsory and on-request VFR points around the field

METAR and TAF join the briefing, and SIGMETs are shown on the map with their distance from your route.

### Approach Briefing

Before approach, a similar briefing covers the **airport** and **elevation** (with the **Official chart**), **runway**, **wind**, **approach speeds** (initial, final, and stall), nearby **reporting points**, and the **go-around procedure**. When wind data is unavailable, it reminds you to check the windsock for calm, crosswind, headwind, or tailwind conditions.

For a US destination, a **Traffic pattern** section follows the reporting points, from the FAA's NASR: each runway end with its side (**RWY 30**, "Right traffic"), then the **TPA** as the FAA publishes it ("806 ft (800 ft AGL)"). Where the FAA only has a remark about it, the TPA reads "See the FAA's remark" and the remark follows word for word, "(FAA NASR, as written)", never a figure taken from it ("TPA 1000 FT W & 800 FT E." at Palo Alto). Where the FAA says nothing, it reads "1000 ft AGL recommended (AIM)". The section ends with "Check the Chart Supplement."

---

## Flight Logging

### Automatic Timing

AéroCheck automatically records the key timestamps of your flight:

- **Off-block / On-block**: off-block is the first moving fix, on-block the moment the aircraft finally comes to rest
- **Engine start / Engine shutdown**
- **Line-up** and **Take-off / Landing** times

### Flight Events

The app detects **take-offs**, **go-arounds**, **touch-and-goes** and **full-stop landings** from GPS altitude and speed and, on devices with a barometer, relative pressure altitude. A take-off is logged without asking. A go-around, a touch-and-go or a full stop is recorded at once, as you would have confirmed it: the checklist moves on (back to the climb check, or on to the after landing check), and a message ("Go-around detected and recorded") offers **UNDO** for six seconds, which puts the flight and its checks back as they were. After END FLIGHT, the [Flight review](#post-flight-review) lists what the app recorded this way, for you to confirm.

To confirm each one in flight instead, turn on **Confirm landings and go-arounds** under **Settings › Checklist & Flight** (off by default). A go-around or a touch-and-go then comes up as a card ("Go-around detected at LSZQ") with **Dismiss** and **Confirm**; it goes away by itself after 20 seconds and never confirms itself, so a detection is never logged against your wishes. A full stop brings [the landed card](#the-landed-card), or in circuit mode the full-stop card, which waits for **Dismiss** or **Confirm** (see [Circuit Mode](#circuit-mode)).

### Post-Flight Review

After END FLIGHT the whole track is analysed again. When it disagrees with what was recorded, or when the app recorded events by itself in flight, **Flight review** shows them: what the app recorded in flight is marked "detected in flight" and included, each one yours to leave out; change an event's type, include or leave out what was only detected, then **Apply to logbook**, or **Keep as recorded**. Nothing changes unless you apply, and the nav log's landing counts follow what you apply. With the cards on, it also catches what you missed: the go-around and touch-and-go cards go away by themselves, and in the circuit you will miss some.

### Engine Hours

If **Log Engine Hours** is on under **Settings › Checklist & Flight**, the app asks for the hour meter readings at the engine start and the shutdown, and calculates the hours flown automatically.

### Viewing Flight History

Open the **Logbook** tab to review flights. Each one is titled by its route ("LSZQ → LSGE"; "LSZQ" for a flight back home; "LSZQ → ?" when an end is unknown; "LSZQ ↻" for circuits), with the aircraft, the landings, the distance and the duration. Flights are grouped by month, and a day with two flights or more gets a header with its totals and **Share day** (see [Exporting and Sharing](#exporting-and-sharing)). Tap a flight for its **detail view**:

- **FLIGHT TRACK**: an interactive map of your flight track
- An altitude (and speed) profile chart
- **TIMELINE**: every event, in order, with a row and its time for each touch-and-go, go-around and full stop between the take-off and the landing: **Stop-and-go** for a full stop back at an aerodrome of the flight (within 2 NM of the take-off, of an earlier full stop or of the landing), **Stop** for one anywhere else
- **CHECKS**: the debrief, see [Checks](#checks)
- Engine hours (if logged), **PLAN vs ACTUAL**, the flight's name and notes
- **Nav Log**, **Logbook & costs** (see below), **Export** and **Share card**

The logbook filters by year (set it to **All time** to see every flight), in UTC like every printed date, and your flights sync across devices via iCloud.

### Checks

A flight's **CHECKS** section is its debrief. A clean flight reads "All checks done". Otherwise each exception gets a line, in flight order: **overdue** (with the moment that passed it, "still open at level-off, 14:26"), **done late**, **not sure**, **confirmed after landing**, **skipped**, or still open when the flight ended. The checks done on time follow as a count ("9 other checks done"), and **Show each check** lists them. FREDA has a line of its own ("done 3× · missed 1×"), with the times. Flights from before 6.1 have no Checks section.

The Logbook spots a trend: from three flights with checks, **CHECKS · LAST 10 FLIGHTS** lists what keeps coming back ("CLIMB CHECK overdue on 4 of 10 flights", "FREDA missed 3×"), most frequent first. A pattern is the same check overdue, skipped or not sure on two flights or more; without one, there is no card. It follows the year and aircraft filters.

### Logbook & Costs

From a flight's detail in the Logbook, or from a flight's CLOSE chapter, **Logbook & costs** holds three things.

**The logbook line.** A draft of the line an EASA Part-FCL logbook wants for this flight, per **AMC1 FCL.050**: date, departure and arrival with **UTC** block times, aircraft, single-engine and total time, PIC, landings, night and IFR time, function time, remarks. Dates, places, times and landings come from the recorded flight, and the remarks name the touch-and-goes, go-arounds and stop-and-goes ("1 touch-and-go, 1 go-around, 2 stop-and-goes") until you write your own. **Function time is a judgment** the app cannot make from a flight, so it defaults from a signal (an instructor named on the flight, or [student mode](#student-pilots)) and is yours to change with **Edit**, together with the PIC name, night landings, night and IFR time (deliberately **not computed**: a plausible wrong number in a logbook column is worse than an empty one you fill in) and remarks.

**Logbook row** lays the same values out as your paper logbook's own twelve column groups, to copy from; **Copy line** and **Export CSV** hand them over as text; and **Export logbook PDF** in the Logbook renders any selection of flights as logbook pages with page and carried-forward totals. AéroCheck is not a logbook of record and every page says so.

**Cost.** Set an hourly **rate** per aircraft once, with its billing basis (block time, flight time or engine hours) and its currency; each flight then shows its aircraft cost, plus any fees you add (a landing fee, fuel). The rate is snapshot onto the flight when computed, so a rate change next year does not rewrite last year. The Logbook's summary shows the period total and says how many flights have no cost rather than pretending the total is complete. Turn the whole thing off with **Track flight costs** under **Settings › Flights** if you do not track what flying costs.

### Mass & Balance

The **Mass & balance** calculator, per aircraft: enter the empty mass and arm, the stations and their loads, and, if you want the landing case too, the fuel you expect to burn and which station it comes from. It reports mass, centre of gravity and, when you have entered the aircraft's **envelope** from the flight manual, whether take-off and landing are inside it. Without an envelope, or with a station left blank, the verdict is **unknown, never a pass**. No aircraft data ships with the app; everything here is what you entered from your own AFM.

### Student Pilots

If you fly with an instructor, turn on **Student pilot** under **Settings › Flights** and enter the instructor's name. Your flights then log as **dual**, with the **instructor named as PIC** (that column states who commanded the aircraft), and the instructor is pre-filled on new flights. An instructor named on the flight itself always wins over the usual one, and your own edits to a line win over everything.

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
- **Frequencies**: the frequencies of the Cockpit's RADIO (see [The Route Page](#the-route-page)), NOW and NEXT first, then the others in the order you will use them; NEXT outlined while it is due, a LISTEN tagged as such. They follow the flight whatever page the iPhone shows. The watch only shows them: the frequency is changed on the iPhone.

When the watch has had nothing from the phone for five seconds (out of range, for example), its values dim under a **NO DATA** banner, so frozen values are never mistaken for live ones.

### Companion Mode

**Companion Mode** pairs an iPad and an iPhone over a direct Wi-Fi link (Wi-Fi Aware; requires **iOS 26 on both devices**) to turn the second device into a synced **wingman** screen. Pair the two devices once under **Settings › Companion Mode** (**Pair New Device** shows even with the mode off); afterwards they connect automatically when both are nearby and ready.

The first time a phone wants to drive the iPad's flight (its checklist and waypoints, its radio, a diversion, or its GPS position), the iPad asks: **Allow companion control?**, with **Allow for This Flight**, **Always Allow** (on this iPad, until you **Forget** the phone or tap **Ask Each Flight** in Settings) and **Don't Allow**.

The companion viewer has two screens, **NAV** and **CHECKLIST**, under the read band of the phone's Cockpit: the strip (GS, ALT, TRK), the next line (with an arrow that shows where the waypoint lies from your track, amber while you divert) and NOW | NEXT, the iPad's two frequencies side by side. It shows the checklist on the ground and NAV once airborne, until you tap one; a tap on the next line or on NOW shows NAV, and a tap on NAV's check slot that sends the iPad on to the next check shows CHECKLIST once the iPad is there (unless that check is from memory). On a route, a tap on NEXT changes the iPad's frequency (a LISTEN, marked heard), as a tap on the iPad's own NEXT does: NEXT is outlined while it is due, its line running out, and the phone offers UNDO for six seconds, which takes the change back on the iPad (the iPad offers its own too). This needs 6.4.3 on the iPad; with an older one, or off a route's timeline, a tap on NEXT shows NAV.

- **NAV** is the phone's ROUTE page, drawn from what the iPad sends: the DEST line, the legs and the radio in one scroll, Emergency under it (see [The Route Page](#the-route-page)), and the act band at the foot. Its four slots: the iPad's [check slot](#the-check-slot), which takes the same one tap as on the iPad; **START LEG**, then **MARK** with the waypoint and the leg time, which marks the waypoint on the iPad and starts its next leg; **Divert** (below); and **More**, to start the leg timer again after a pause, **Reset chronometer**, or open the **Nav Log** (the leg to each waypoint, MC and NM, its ETO and its ATO; tap an empty ATO to record it now). RADIO lists what the iPad sends: NOW, NEXT, the diversion field and the frequencies typed for the waypoints ahead. A leg's row does nothing here (the phone has no map to show it on), and a MARK from the phone has no UNDO. At the end of a circuits flight's after landing check, **NEW CIRCUIT** takes MARK's place.
- **CHECKLIST**: a mirror of the master's checklist. At the end of a circuits flight's after landing check, **NEXT: PARKING CHECK** and **NEW CIRCUIT** sit side by side. NEW CIRCUIT needs 6.3.0 on both devices; otherwise the phone keeps NEXT.

**Divert** on the phone lists the nearest aerodromes from the phone's own airport data (up to 8, within 60 NM), with their bearing and distance, and a search field. Tap one, then **DIVERT TO** it (**DIRECT TO** for the route's destination), or **Resume route** while you divert: the iPad does exactly what its own Divert does. A diversion asks the same question as a MARK (**Allow companion control?**, on the iPad), so the phone keeps sending it until the iPad has it: it says "Waiting for the iPad…" and "If the iPad asks, allow the iPhone there.", closes by itself once the iPad diverts, and after 30 seconds says "The iPad hasn't confirmed the diversion. Check the iPad.", with **Retry**. Divert is dimmed when the route has no leg left to fly, and when the iPad runs a version before 6.2, which cannot take a diversion from the phone. With such an iPad, NOW | NEXT gives the frequency typed for the waypoint you are flying to (or the diversion field's), else GUARD 121.50.

Control is **two-way**: advancing the checklist or revealing the hidden memory items on either device updates both, and both screens match the master's theme. The phone can also answer [the landed card](#the-landed-card). A **GPS chip** shows which device's GPS is in use (**GPS iPad** or **GPS iPhone**), with a dot in the colour of the signal, red too for a flight not recording. To leave, hold **COMPANION** on the phone until it fills red.

When the data goes stale (nothing for five seconds), the companion shows **"Data stale: values may be frozen"**; when the link drops (after 10 seconds without anything), **"Connection lost"**, with **Go Standalone**. The rule is simple: a staleness or disconnect banner means *stop trusting the numbers on that screen* until it reconnects. After a drop, the phone looks for the iPad again by itself, and shows connected only once the iPad's first data has arrived. While it is connected to the iPad, or reconnecting after a drop, the phone keeps its screen on, flight or not. To save battery, the iPad ends a link that has been idle for 10 minutes without a flight, and keeps listening.

### Wi-Fi-Only iPads

An iPad without GPS (a Wi-Fi-only model) installs AéroCheck and flies with it, on a position from elsewhere:

- **The iPhone's GPS, through Companion mode** (iOS 26 on both devices). Once the phone is allowed, the iPad runs the whole flight on it: the iPhone shares its satellite fixes over the link (never a Wi-Fi position), and the iPad records the track and drives the Cockpit as if the fix were its own; the header's GPS reads **GPS · iPhone**. In a hangar or a clubhouse, the iPad's own Wi-Fi positions do not push the iPhone's GPS aside.
- **An external GPS receiver**, connected to the iPad: nothing to set up. Its fixes count as satellite fixes, so the GPS indicator stays green on one.

START FLIGHT waits up to five seconds for a position. Without one, it says so ("Waiting for a GPS fix. Once GPS is acquired, try again.").

---

## Circuit Mode

Circuit mode is designed for **circuit training** (touch-and-go practice). Start it with **CIRCUITS** on Today, where it is always offered. When active:

- The checklist skips the **Cruise** and **Descent** phases, and so FREDA
- The approach check falls due on the downwind, once the turn onto it is flown (at the level-off when the app has no course to go by), and the landing check shows (nothing to press) once you start down
- **GO AROUND** and **TOUCH-AND-GO** are single taps, and either takes the checklist back to **Climb** for the next lap
- A **full stop** goes on to the after landing check, as on any other flight, and **NEW CIRCUIT**, at the end of the after landing check, back to the before take-off check for the next lap

A go-around or a touch-and-go within 5 NM of the route's destination (or of the field you divert to), or anywhere on a flight without a route, turns circuits on by itself, as the **Circuits** switch in the Menu does: the climb check again, then the approach check on the downwind and the landing check, with no cruise or descent check left behind on that lap. One at an aerodrome on the way keeps the route's checks.

A full stop the app detects is recorded at once, with UNDO; with **Confirm landings and go-arounds** on, it brings the full-stop card instead ("Full-stop landing detected at LSZQ"), which waits for **Confirm** or **Dismiss**. At the end of the after landing check, the second slot reads **NEW CIRCUIT** (NEXT's place on CHECKLIST, MARK's on MAP and ROUTE), with "then BEFORE TAKE-OFF CHECK" under it (**↻ CIRCUIT** on the iPhone): the next lap starts at the before take-off check, so the taxi check and the run-up are flown once, on the first lap. The check slot beside it offers the parking check ("PARKING CHECK · next check", **PARKING** on the iPhone), which ends the circuits. A full stop is counted once per lap: as the app records it (or by the card's **Confirm**), by **FULL STOP LANDING**, or else by the choice at the end of the after landing check, which counts it at its touchdown when the app detected one. With the after landing check from memory, **✓ AFTER LANDING CHECK DONE** records it, and the same choice follows.

The iPad's phase bar draws the two loops with their counts (see [The Phase Bar](#the-phase-bar)), and the phase button shows the lap, "↻ 4" (on the iPad in place of "10/16", on the iPhone at its right end): a touch-and-go, a go-around and NEW CIRCUIT each start one. **CIRCUITS**, in the Menu, counts the touch-and-goes, the full stops and the go-arounds.

To leave circuits, tap Cruise or Descent in **Select Phase**, where they stay, dimmed and marked "skipped in circuits". "Leave circuits?" then offers **LEAVE CIRCUITS, GO TO CRUISE CHECK** (or DESCENT CHECK), which makes it a normal flight from there (Cruise and Descent back on the bar, FREDA counting, GO AROUND and TOUCH-AND-GO held again) and jumps as any jump does, or **Stay in circuits**. The touch-and-goes and full stops so far stay in the flight. The **Circuits** switch, under OPTIONS in the Menu, works both ways: off, it leaves circuits the same way; on, for circuits at the end of a cross-country, Cruise and Descent are skipped from then on, and a flight in either goes on to the approach check.

Circuits are start-now only (there is no such thing as a planned circuit session), so a session never adopts a flight you planned, even once it leaves circuits. When it ends, AéroCheck **offers** to close it out: a light version of CLOSE with just the logbook line and the optional debrief (a followed flight that ends in circuits has its own close-out). Dismissing the offer is a complete answer.

---

## Aeronautical Data and Storage

AéroCheck draws on several external datasets so navigation works wherever you fly. All of it is downloaded on demand and cached on the device.

### What Data AéroCheck Uses

- **Airports and frequencies**: from OurAirports and OpenAIP (positions, runways, fuel grades, PPR flags and radio frequencies). A runway shows once, even when the two sources number it differently: it takes the numbers most sources agree on, and a short list, checked by hand, corrects the few they get wrong.
- **Airspace**: OpenAIP controlled and restricted airspace, with vertical limits and frequencies.
- **FIS areas**: where another FIS than the area's works low-level VFR traffic (so far one: Bâle Information over the Ajoie and the northern Jura, from 2,000 ft above the ground), from the AéroCheck service, refreshed weekly; the area is drawn by your own OpenAIP airspace. Until it is on the device, the FIS sectors decide alone.
- **Navaids, obstacles, and reporting points**: OpenAIP map layers (see [The Map Sheet](#the-map-sheet)), plus the few reporting points OpenAIP lacks, from open flightmaps.
- **Weather reports**: METAR, TAF and SIGMET from NOAA's Aviation Weather Center (public domain), through the AéroCheck weather proxy: in flight for the briefings and the map, and before it for Prepare's weather card (see [Prepare](#prepare)).
- **Traffic circuits and VFR routes**: open flightmaps' traffic circuits (with their altitude), VFR arrival and departure routes and their sectors, in the {ofmCountries} countries open flightmaps covers. Indicative only: open flightmaps is a community source, not for primary navigation. They follow the AIRAC cycle (a new one every 28 days) and are kept offline like the rest (see [Traffic Circuits and VFR Routes](#traffic-circuits-and-vfr-routes)).
- **US traffic patterns**: the side of each runway's pattern and the pattern altitude, from the FAA's NASR (public domain), through the AéroCheck service. Fetched the first time a US field needs them, then at most once a week.
- **Charts**: Swiss ICAO, national map, and Segelflug charts from swisstopo.
- **Official charts**: a link to each aerodrome's chart on its publisher's site in {chartCountries} countries (DFS, the SIA, skyguide on SkyBriefing, Austro Control, the FAA and the AIS of {chartOthers} more countries), never the chart itself; see [Official Chart](#official-chart) and, country by country, [Countries](/countries).
- **Briefing links**: the official pages behind Prepare's tasks (weather, NOTAMs, airspace activity, area forecast, filing) and each country's rule and numbers for closing an ATC flight plan, from the AéroCheck service's briefing registry. It is built weekly on the AéroCheck server from each country's own publishers, every link checked, and the app ships with a copy, so the links and the numbers are there before the first download. Each link names its publisher.
- **Landing-fee sources**: where each aerodrome publishes its own tariff (links and dates, never amounts), from the AéroCheck service.

### Downloading Data

Download aeronautical data **by country or continent** from **Settings › Data & Storage** (or **Navigation & Maps**). Onboarding offers a recommended set for your region and its neighbours so you are covered from the first flight. Airspace, navaids, obstacles, reporting points and aerodromes download together per country, and so do the VFR procedures, for the countries open flightmaps covers (the download page says which of yours get them).

If you used AéroCheck before 6.2.0, your countries are there but their VFR procedures are not yet: **Refresh** on the **VFR procedures (open flightmaps)** row of Data & Storage fetches them for the countries you have (so does a new download from Navigation & Maps).

### Keeping Data Current

Aeronautical data changes regularly, so AéroCheck surfaces its freshness in several places:

- The **Data** chip on Today and a freshness summary in **Data & Storage**
- A snoozable **nudge** when a dataset is out of date
- The amber mark on the map's **Map** button (or the layers button) when downloaded airspace is aging (see [The Map Sheet](#the-map-sheet))
- **Route-aware prefetch**: when a route crosses a country you haven't downloaded, AéroCheck offers to fetch that data, and fetches only what is missing
- A red line under a dataset whose last update failed ("Couldn't update CH, DE. Try again on Wi-Fi."), in Data & Storage and in Navigation & Maps; the next update that completes clears it

Data refreshes when you bring the app to the foreground (there is no background download), so updates happen while you're using the app, not on battery in your pocket.

The VFR procedures age by AIRAC cycle rather than by date. Their row in Data & Storage gives the cycle on the device and its validity ("AIRAC 2610 · valid 1 Oct – 28 Oct 2026"). It turns aging the day the next cycle takes effect (and tells you when open flightmaps has not published that cycle yet: "AIRAC 2610 · a newer cycle isn't published yet"), and stale four weeks later. AéroCheck fetches the new cycle as soon as the data is aging, the next time you bring the app to the foreground.

> Even current data is advisory. Always cross-check against official charts and NOTAMs.

### Offline Maps and Storage

Cache the Swiss ICAO Chart and Segelflugkarte for offline use (~100–250 MB). **Data & Storage** lists each dataset with its countries, size and currency (**Airspace**, **Navaids**, **Obstacles**, **Reporting points**, **Aerodromes** from OpenAIP, **Airports** from OurAirports, and **VFR procedures (open flightmaps)**), and lets you update or delete cached data to reclaim space. New aerodrome data (runways, frequencies) shows as soon as it is downloaded, without restarting the app.

---

## Settings Reference

Settings is a tab of its own, organised into dedicated pages. Three former settings are now simply how the app works: **CIRCUITS** is always offered on Today, the screen stays on during a flight (and otherwise only on a Companion iPhone connected to the iPad), and every checklist runs step by step. Two things live outside Settings: the aircraft you fly is chosen on Today or in the **Aircraft** tab, which also keeps each aircraft's usable fuel with full tanks and its cruise speed; and the Cockpit's **Menu** repeats the display options in flight.

### Aircraft & Subscription

**AéroCheck Pro** (subscribe, start the trial, buy Lifetime, or restore purchases), the aircraft you fly (with **Get latest aircraft data** to refresh the list and check for checklist updates, and **Send us an aircraft's checklist**), **Your requests** once you have sent one (see [Sending an Aircraft's Checklist](#sending-an-aircrafts-checklist)), and **Aircraft Visibility**, to show or hide aircraft one by one or by aeroclub.

### Checklist & Flight

**Hide memory items** and **Checklist Language**; **Log Engine Hours** (on by default) and **Confirm landings and go-arounds** (off by default, see [Flight Events](#flight-events)); under **Radio**, **Aerodromes on the way** (on by default: an aerodrome the route passes within 2 NM shows in NEXT as LISTEN, see [NOW and NEXT](#now-and-next)); **Always Use UTC Times**; the **Cockpit theme** (Auto / Day / Night) and **High contrast in sunlight**.

### Navigation & Maps

**Force ICAO Chart Layer** and the **Track vector**; **Offline Maps** (offline mode, chart cache, update, delete, download); the OpenAIP airspace overlay, the navaid, obstacle and reporting-point layers, and **Online Airspace Data** (nearby control zones fetched online when no airspace is downloaded); the **Aerodrome procedures** switches (as in the Map sheet); airport data; the countries you download, with a red line when an update failed.

### Flights

The row was called Flight Planning before 6.4.0. Your **pilot name** (for the PIC column and the logbook PDF), **Student pilot** with your instructor's name, your **Home aerodrome** (**Based at**: Plan new flight starts from it, and the landings you make within 5 NM of it count as landings at base on the nav log, which prints "– / 1" without one), **Track flight costs** on or off, and the **Terrain Altitude Unit** of the route profile.

### iCloud & Log

**iCloud Sync** of settings and flights across devices, the GPS **Recording Interval** and **GPS Priority** (**Precision** or **Battery Saver**), and the numbers of recorded flights and GPS points.

### Data & Storage

Aeronautical-data currency (one row per dataset, the VFR procedures with their AIRAC cycle), per-country and continent downloads, offline chart cache, and storage management. See [Aeronautical Data and Storage](#aeronautical-data-and-storage).

### Companion Mode

Pair an iPhone and iPad as a synced second screen (Wi-Fi Aware; requires iOS 26 on both devices): **Enable Companion Mode**, then **Paired Devices**, with **Pair New Device** (shown even with the mode off), **Forget** for each device, and **Ask Each Flight** for a phone you always allowed. See [Companion Mode](#companion-mode).

### About

App version, website, author and open-source information; **LEARN AND PRACTISE**, with **Replay introduction**, the guided dry run, **One part at a time** and free practice (see [Dry Run](#dry-run)); **Legal** (the safety notice, the terms of use and the privacy policy) and the data sources (among them the briefing links' publishers, named on each link, and the FAA's NASR for the US traffic patterns); and hidden **Developer Options** (tap the version number five times to unlock).
