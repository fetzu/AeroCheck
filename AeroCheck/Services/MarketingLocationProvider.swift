//
//  MarketingLocationProvider.swift
//  AéroCheck
//
//  The screenshots' scenes (DEBUG only, compiled out of Release builds): launched with `AEROCHECK_SCENE=<key>`,
//  the app drives itself into a state for a capture, and the screenshot tour (AeroCheck-tools, `shots/`) takes it
//  from there; the list of shots is `scripts/shots.json` on the website branch (SCREENSHOTS.md). Until 6.6.0 this
//  file was also Marketing Mode, GPS tours and a control panel behind a shake: retired with the tour (25 Oct 2026).
//

import Foundation
import CoreLocation
import Combine

#if DEBUG
/// A scene's GPS fix, in aviation units: where the aircraft is held.
struct MarketingGPSPoint {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double       // in knots
    let course: Double      // in degrees

    init(lat: Double, lon: Double, alt: Double, speed: Double, course: Double) {
        self.latitude = lat
        self.longitude = lon
        self.altitude = alt
        self.speed = speed
        self.course = course
    }

    /// Convert speed from knots to m/s for CLLocation
    var speedMPS: Double {
        speed * 0.514444
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func toCLLocation(timestamp: Date = FlightClock.now, heading: Double? = nil) -> CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 10.0,
            course: heading ?? course,
            speed: speedMPS,
            timestamp: timestamp
        )
    }
}

/// The scenes' GPS: one held fix, published so `ContentView` forwards it into `LocationManager` and the in-flight
/// instruments (SPD / ALT / HDG) stay lit for a screenshot.
@MainActor
final class MarketingLocationProvider: ObservableObject {
    static let shared = MarketingLocationProvider()

    /// True once a scene holds a fix: `ContentView` forwards it from then on.
    @Published private(set) var isActive = false

    /// The held fix.
    @Published private(set) var currentLocation: CLLocation?

    private init() {}

    /// Hold one static GPS fix and keep publishing it. `altitudeMeters` is the GPS altitude in METERS (CLLocation
    /// native); `speedKnots` and `headingDegrees` are aviation units.
    func holdStaticFix(latitude: Double, longitude: Double, altitudeMeters: Double, speedKnots: Double, headingDegrees: Double) {
        isActive = true
        let point = MarketingGPSPoint(
            lat: latitude,
            lon: longitude,
            alt: altitudeMeters,
            speed: speedKnots,
            course: headingDegrees
        )
        // Re-assign to a fresh location each call so `.onChange(of: currentLocation)` always fires.
        currentLocation = point.toCLLocation(heading: headingDegrees)
    }
}

// MARK: - Marketing Scene Injector (DEV-ONLY)

/// The screenshot scenes: each drives the app into a deterministic state for a capture. Their launch keys are in
/// `ContentView`'s DEBUG `.task`; the shots that use them, in the website branch's `scripts/shots.json`.
enum MarketingScene {
    /// Active flight in CRUISE, LSZQ → LSGC → LSGN → LSZB on the Cockpit, Fuel quantity framed (4/5).
    case cruiseRoute
    /// The same, with the cruise check worked through, so the Cockpit shows its MAP by itself. (6.0 captures)
    case cruiseMap
    /// Geneva → Samedan in the route editor, its full conflict list.
    case planConflicts
    /// The bundled demo flights and Vol d'Alpes imported for the logbook.
    case flightLogDetail
    /// LSZQ → LFSB on the next 1 August, prepared, its page open.
    case flightFollowed
    /// The same flight, for the shot that opens its Prepare blocks.
    case flightPrepare
    /// Vol d'Alpes in CLOSE with its route and its rate.
    case flightCloseOut
    /// LSZQ → LFSB today at 14:00: Today's next flight.
    case homeFlightToday
    /// Plan › Map close in on LSZQ: its traffic circuit, its arrival sectors and runway, on the national map with the
    /// airspace off. (6.3.0)
    case planMapCircuits
}

/// Fixed airport coordinates used to build marketing routes without depending on airport data being
/// loaded. Resolved via AirportDataService when available, with these as the fallback. (DEV-ONLY)
private struct MarketingAirport {
    let ident: String
    let latitude: Double
    let longitude: Double
    let elevationFt: Double
}

@MainActor
enum MarketingSceneInjector {

    /// Every route name a scene creates. Deleted before each injection so repeated capture runs do
    /// not leave a pile of identical routes behind. Nothing outside this list is ever touched.
    private static let demoRouteNames: Set<String> = [
        "LSZQ → LSZB Tour", "Geneva → Samedan", "Jura → Engadin", "LSZQ → LFSB", "LSGS → LSZQ"
    ]

    // ICAO airports referenced by the route scenes (Swiss fields).
    private static let knownAirports: [String: MarketingAirport] = [
        "LSZQ": MarketingAirport(ident: "LSZQ", latitude: 47.3497, longitude: 7.0278, elevationFt: 1860),  // Bressaucourt
        "LSGC": MarketingAirport(ident: "LSGC", latitude: 47.0839, longitude: 6.7928, elevationFt: 3409),  // Les Eplatures
        "LSGN": MarketingAirport(ident: "LSGN", latitude: 46.9575, longitude: 6.8647, elevationFt: 1427),  // Neuchâtel
        "LSZB": MarketingAirport(ident: "LSZB", latitude: 46.9141, longitude: 7.4972, elevationFt: 1673),  // Bern-Belp
        "LSZG": MarketingAirport(ident: "LSZG", latitude: 47.1820, longitude: 7.4170, elevationFt: 1411),  // Grenchen
        "LSZP": MarketingAirport(ident: "LSZP", latitude: 47.1392, longitude: 7.2997, elevationFt: 1404),  // Biel/Bienne
        "LSZS": MarketingAirport(ident: "LSZS", latitude: 46.5341, longitude: 9.8841, elevationFt: 5600),  // Samedan
        "LSGG": MarketingAirport(ident: "LSGG", latitude: 46.2381, longitude: 6.1089, elevationFt: 1411),  // Geneva
        "LSGS": MarketingAirport(ident: "LSGS", latitude: 46.2196, longitude: 7.3268, elevationFt: 1585),  // Sion
        "LFSB": MarketingAirport(ident: "LFSB", latitude: 47.5896, longitude: 7.5299, elevationFt: 885),   // Basel-Mulhouse (FR)
    ]

    /// Resolve an ICAO to a coordinate, preferring loaded airport data, then the hardcoded fallback.
    private static func coordinate(_ ident: String, airportDataService: AirportDataService) -> CLLocationCoordinate2D? {
        if let a = airportDataService.findAirport(byIdent: ident) {
            return a.coordinate
        }
        if let a = knownAirports[ident] {
            return CLLocationCoordinate2D(latitude: a.latitude, longitude: a.longitude)
        }
        return nil
    }

    /// Inject the given scene, from `ContentView`'s DEBUG `AEROCHECK_SCENE` launch task. Async because the cruise
    /// scenes resolve their checklist before the flight starts, as a real start does.
    static func inject(
        _ scene: MarketingScene,
        appState: AppState,
        locationManager: LocationManager,
        aircraftDataService: AircraftDataService,
        flightPlanManager: FlightPlanManager,
        airportDataService: AirportDataService,
        threadManager: FlightThreadManager? = nil
    ) async {

        // Every scene starts from NO threads. A single leftover thread scheduled today takes over
        // Home's hero, which silently ruined the `home` and `conflicts` shots — they came back
        // showing a flight card instead of the aircraft carousel. A scene has to determine what is
        // on screen; inheriting whatever a previous run or an old build left behind is not a scene.
        if let threadManager {
            for old in threadManager.threads { threadManager.deleteThread(threadId: old.id) }
        }
        // …and from no demo ROUTES. Every scene that builds one used to leave it behind, so Saved
        // routes filled up with copies of the same route, one per capture run.
        for old in flightPlanManager.flightPlans where demoRouteNames.contains(old.name) {
            flightPlanManager.deleteFlightPlan(old)
        }

        switch scene {
        case .flightFollowed, .flightPrepare, .flightCloseOut, .homeFlightToday:
            guard let threadManager else {
                AppLog.marketing.debugLine("Scene \(String(describing: scene)) needs the FlightThreadManager — not injected")
                return
            }
            injectFlightThreadScene(scene, appState: appState, flightPlanManager: flightPlanManager,
                                    airportDataService: airportDataService, threadManager: threadManager)
            return
        default:
            break
        }
        switch scene {
        case .cruiseRoute:
            injectNavPlanActive(flightPlanManager: flightPlanManager, airportDataService: airportDataService, locationManager: locationManager)
            await injectCruiseHUD(appState: appState, locationManager: locationManager, airportDataService: airportDataService,
                                  aircraftDataService: aircraftDataService, fix: .onTheLeg)
        case .cruiseMap:
            injectNavPlanActive(flightPlanManager: flightPlanManager, airportDataService: airportDataService, locationManager: locationManager)
            await injectCruiseHUD(appState: appState, locationManager: locationManager, airportDataService: airportDataService,
                                  aircraftDataService: aircraftDataService, fix: .onTheLeg)
            // The chart as the 5.0 captures showed it: the ICAO chart's own airspace, no OpenAIP layers
            // over it. The scene sets it rather than relying on a simulator's settings.
            appState.settings.showOpenAIPOverlay = false
            appState.settings.showReportingPointsOnMap = false
            appState.settings.showObstaclesOnMap = false
            // Every cruise item checked: the pane rule then shows the map. Checked as the pilot's last tap does,
            // so FREDA counts from now and the check slot shows it at once, not after a later evaluation.
            // (screenshot run, 6.6.0)
            appState.markLastItemComplete(learningMode: appState.settings.learningMode)
        case .planConflicts:
            injectPlanConflicts(flightPlanManager: flightPlanManager, airportDataService: airportDataService)
        case .flightLogDetail:
            injectFlightLog(appState: appState)
        case .planMapCircuits:
            injectPlanMapCircuits(appState: appState)
        case .flightFollowed, .flightPrepare, .flightCloseOut, .homeFlightToday:
            break // dispatched above — they need the thread manager
        }
    }

    // MARK: - Plan › Map at LSZQ, the circuits shot (6.3.0)

    /// No flight, Plan › Map, the national map, the airspace off, the traffic circuits and the arrival and
    /// departure routes on (the airports too, for the runway). The map frames LSZQ itself as it appears
    /// (`NavigationMapView.frameForCaptureIfAsked`), as the search frames an aerodrome, without its callout.
    private static func injectPlanMapCircuits(appState: AppState) {
        if appState.isFlightActive { appState.cancelFlight() }
        appState.selectMapLayer(.landeskarten)
        appState.settings.showOpenAIPOverlay = false
        appState.settings.showVFRCircuitsOnMap = true
        appState.settings.showVFRRoutesOnMap = true
        appState.settings.showAirportsOnMap = true
        appState.groundTab = .plan
        appState.pendingPlanSection = .map
    }

    // MARK: - Scene 2: Active flight on CRUISE with a held static fix

    /// Where the cruise scenes hold the aircraft: ON the LSZQ → LSGC leg, tracking along it. A fix off the route
    /// with another course left the smoothed track vector pointing one way and the aircraft another. (6.0 captures)
    struct CruiseFix {
        let latitude: Double, longitude: Double, headingDegrees: Double
        static let onTheLeg = CruiseFix(latitude: 47.345151, longitude: 6.982395, headingDegrees: 211)
    }

    private static func injectCruiseHUD(appState: AppState, locationManager: LocationManager, airportDataService: AirportDataService,
                                        aircraftDataService: AircraftDataService, fix: CruiseFix) async {
        // Start a fresh flight on the bundled WT9 (always resolvable: offline, the load below falls
        // back to the bundled JSON).
        if appState.isFlightActive { appState.cancelFlight() }
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        // Resolve its checklist the way FlightLauncher does before every real start: the WT9 in the
        // checklist language (Settings, or the system's on Auto). Without it the flight ran on the
        // hard-coded WT9 data, which is English only, so the French captures showed English checks
        // and V-speeds. (6.1 App Store captures)
        await appState.loadRemoteChecklistIfNeeded(aircraftDataService: aircraftDataService)
        appState.startFlight()

        // Mark every phase up to and including climb as completed (green); current phase = cruise.
        appState.currentPhase = .cruise
        for phase in ChecklistPhase.allCases where phase.rawValue < ChecklistPhase.cruise.rawValue {
            appState.phaseCompletionStatus[phase] = .completed
            // A worked-through phase shows its highlight past the last item.
            let count = appState.activeChecklist.visibleItemCount(for: phase, learningMode: appState.settings.learningMode)
            appState.currentHighlightedItem[phase] = ChecklistHighlighting.lastItemComplete(visibleCount: count)
        }
        appState.highestCompletedPhase = .climb

        // Cruise: highlight the Fuel-Quantity item with the items before it completed (green).
        // The WT9 cruise checklist lists Fuel Quantity as item 4 ("Quantité carburant" in French);
        // locate it by challenge text so the index is robust to checklist edits, falling back to
        // index 3 (the 4th visible item).
        let cruiseItems = appState.activeChecklist.visibleItems(for: .cruise, learningMode: appState.settings.learningMode)
        let fuelIndex = cruiseItems.firstIndex {
            let challenge = $0.challenge.lowercased()
            return challenge.contains("fuel quantity") || challenge.contains("quantité carburant")
        } ?? min(3, max(0, cruiseItems.count - 1))
        appState.currentHighlightedItem[.cruise] = fuelIndex
        appState.phaseCompletionStatus[.cruise] = nil // in-progress, not yet completed

        // Record engine start + line up so the in-flight clock and timing readouts are populated, on the
        // flight's clock (`AEROCHECK_CLOCK`'s 9:41 for the screenshots). (6.4.3)
        let now = FlightClock.now
        appState.engineStartTime = now.addingTimeInterval(-25 * 60)
        appState.lineUpTime = now.addingTimeInterval(-20 * 60)
        appState.currentFlight?.engineStartTime = appState.engineStartTime
        appState.currentFlight?.lineUpTime = appState.lineUpTime

        // Load the airport DB FIRST, then inject the held fix. The HUD's NEAREST-frequency strip
        // recomputes on the location change and is throttled to a coarse ~1 NM bucket, so it must see
        // the data the first time the static fix lands — otherwise it resolves nil and never recomputes
        // (the fix never moves). Held just SW of LSZQ Bressaucourt; ~SPD 105 kt, ALT 3500 ft, HDG 315°.
        let altMeters = 3500.0 / 3.28084
        let provider = MarketingLocationProvider.shared
        Task {
            await airportDataService.ensureLoaded()
            provider.holdStaticFix(latitude: fix.latitude, longitude: fix.longitude, altitudeMeters: altMeters,
                                   speedKnots: 105, headingDegrees: fix.headingDegrees)
            if let loc = provider.currentLocation {
                locationManager.injectMarketingStaticFix(loc)
            }
        }
    }

    // MARK: - Scene 3: Active nav plan LSZQ → LSGC → LSGN → LSZB

    private static func injectNavPlanActive(flightPlanManager: FlightPlanManager, airportDataService: AirportDataService, locationManager: LocationManager) {
        let route = ["LSZQ", "LSGC", "LSGN", "LSZB"]
        // OurAirports' LSZQ point doesn't line up with the field symbol on the SwissTopo chart, so pin
        // the departure waypoint (and the held fix below) to the charted airport position. (Marketing.)
        let lszqCoord = CLLocationCoordinate2D(latitude: 47.392250, longitude: 7.029552)

        // Build the plan fresh so the LSZQ waypoint always sits on the charted field — a previously
        // saved plan could carry the off-position OurAirports coordinate.
        var plan = flightPlanManager.createFlightPlan(name: "LSZQ → LSZB Tour")
        for ident in route {
            let coord = ident == "LSZQ" ? lszqCoord : coordinate(ident, airportDataService: airportDataService)
            if let coord {
                plan.waypoints.append(FlightPlanWaypoint(name: ident, coordinate: coord))
            }
        }
        plan.calculateRouteData()
        flightPlanManager.updateFlightPlan(plan)
        flightPlanManager.activateFlightPlan(plan)

        // Present LSZQ (index 0) as the departure already passed and the active leg as LSZQ→LSGC:
        // markWaypoint() records LSZQ's ATO and advances currentWaypointIndex to 1 (LSGC). The nav
        // renders index < currentWaypointIndex as passed (green) and == as the active/next waypoint,
        // so LSGC becomes the next waypoint. (Explicit waypoint-index advance — the API the nav reads.)
        flightPlanManager.markWaypoint()

        // Held fix ON the first waypoint LSZQ — the aircraft sits exactly on the field marker (the old
        // fix sat ~3 NM south of it). LSGC is the active next waypoint; the speed + heading drive the
        // ground-track trend vector (1 / 2 / 5 min projection).
        // The LSZQ waypoint sits on the field (lszqCoord); the aircraft sits just down the LSZQ→LSGC
        // leg, SW of the field — "just departed". Charted position supplied for the marketing capture.
        let provider = MarketingLocationProvider.shared
        provider.holdStaticFix(latitude: 47.345151, longitude: 6.982395,
                               altitudeMeters: 2500.0 / 3.28084, speedKnots: 80, headingDegrees: 211)
        if let loc = provider.currentLocation {
            locationManager.injectMarketingStaticFix(loc)
        }

        // Show the leg chronometer mid-run (~1:37) so the nav map reads as an active navigation.
        // marketingStartChronometer back-dates the start time (DEBUG only in FlightPlanManager, as this file is).
        flightPlanManager.marketingStartChronometer(elapsedSeconds: 95)
    }

    // MARK: - Scene 4: Plan with a FULL conflict list (Geneva → Samedan)

    private static func injectPlanConflicts(flightPlanManager: FlightPlanManager, airportDataService: AirportDataService) {
        // Geneva → Samedan: a long plateau-to-Alps crossing through the most controlled airspace (~30
        // conflicts) with a dramatic climb profile. The intermediate altitude waypoints + planned
        // altitudes below are backported from a hand-tuned plan so the route profile shows a realistic
        // flight-altitude line over the terrain (1000 ft → 10'800 ft → 9500 ft). Built fresh = deterministic.
        let pts: [(name: String, lat: Double, lon: Double, alt: Double)] = [
            ("LSGG",      46.2381,            6.1089,             1000),
            ("WPT (ALT)", 46.26882281959379,  6.500740501792115,  5400),
            ("WPT (ALT)", 46.3138496829949,   7.0750155514943645, 9200),
            ("WPT (ALT)", 46.40886879183133,  8.28689440176229,   10800),
            ("LSZS",      46.5341,            9.8841,             9500),
        ]
        var plan = flightPlanManager.createFlightPlan(name: "Geneva → Samedan")
        for p in pts {
            var wp = FlightPlanWaypoint(name: p.name, coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
            wp.altitude = p.alt
            plan.waypoints.append(wp)
        }
        plan.calculateRouteData()
        flightPlanManager.updateFlightPlan(plan)
        flightPlanManager.activateFlightPlan(plan)
    }

    // MARK: - Scenes 7–10: the Flight Thread (v5.0.0)
    //
    // One demo flight serves three of them: LSZQ → LFSB (Bressaucourt → Basel-Mulhouse), chosen because
    // it crosses a border — that is what puts a customs row and the border pack on screen — and lands
    // at a field every Swiss pilot knows. Dated the NEXT 1 August (Swiss National Day), computed at
    // inject time so the scene stays repeatable in any year, and prepared to 10 of 11 so the readiness
    // ring can never be misread as a date. (The user caught "9/11" on a hero shot.)

    /// The next 1 August at 10:00 local, strictly after now — so a planned flight is never in the past.
    private static func nextFirstOfAugust() -> Date {
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year], from: now)
        comps.month = 8; comps.day = 1; comps.hour = 10; comps.minute = 0
        let thisYear = cal.date(from: comps) ?? now
        if thisYear > now { return thisYear }
        comps.year = (comps.year ?? 2026) + 1
        return cal.date(from: comps) ?? now
    }

    /// Today at 14:00 local — what makes the flight "today's" for the Home hero.
    private static func todayAtTwo() -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 14; comps.minute = 0
        return cal.date(from: comps) ?? Date()
    }

    /// The demo route with fuel figures that let the AUTO fuel row settle itself.
    private static func makeDemoPlan(from origin: String = "LSZQ", to destination: String = "LFSB",
                                     departure: Date, flightPlanManager: FlightPlanManager,
                                     airportDataService: AirportDataService) -> FlightPlan? {
        var plan = flightPlanManager.createFlightPlan(name: "\(origin) → \(destination)")
        for ident in [origin, destination] {
            guard let coord = coordinate(ident, airportDataService: airportDataService) else { continue }
            var wp = FlightPlanWaypoint(name: ident, coordinate: coord)
            wp.altitude = knownAirports[ident].map { $0.elevationFt }
            plan.waypoints.append(wp)
        }
        guard plan.waypoints.count == 2 else { return nil }
        plan.aircraftTypeId = AircraftType.wt9Dynamic.rawValue
        plan.aircraftRegistration = AircraftType.wt9Dynamic.registration
        plan.aircraftModelName = AircraftType.wt9Dynamic.modelName
        plan.plannedDepartureTime = departure
        plan.fuelFlow = 18
        plan.tripFuel = 22
        plan.reserveFuel = 8
        plan.additionalFuel = 13.5
        plan.extraFuel = 0
        plan.fuelOnBoard = 80
        plan.runwayInUse = "24"
        plan.calculateRouteData()
        flightPlanManager.updateFlightPlan(plan)
        return plan
    }

    /// Tick every check task except the ones named, so the ring reads done/total the way we want it.
    /// Close tasks stay open unless asked: a PLANNED flight with "Debrief written" ticked reads wrong.
    /// Ticked on the flight clock, so the capture clock's 9:41 is what "Briefed at" says. (6.5.0)
    private static func tick(_ threadId: UUID, leaving open: Set<ThreadTaskKey>, includingClose: Bool = false,
                             threadManager: FlightThreadManager) {
        guard let thread = threadManager.thread(withId: threadId) else { return }
        for task in thread.tasks where task.kind != .auto && !open.contains(task.key)
            && (includingClose || task.chapter != .close) {
            threadManager.setTaskState(.done, taskId: task.id, threadId: threadId,
                                       now: FlightClock.captureStart ?? FlightClock.now)
        }
    }

    private static func injectFlightThreadScene(_ scene: MarketingScene, appState: AppState,
                                                flightPlanManager: FlightPlanManager,
                                                airportDataService: AirportDataService,
                                                threadManager: FlightThreadManager) {
        if appState.isFlightActive { appState.cancelFlight() }
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        // Home's "last flight" strip and the close-out scene both want the real Vol d'Alpes flight.
        importMarketingFlights(into: appState)
        importFlight(named: realHighlightFlightFile, into: appState)

        // Built fresh on every inject so the capture is deterministic; a previous run's copies are
        // retired first so the Upcoming list does not fill with duplicates across sessions.

        switch scene {
        case .flightFollowed, .flightPrepare:
            guard let plan = makeDemoPlan(departure: nextFirstOfAugust(),
                                          flightPlanManager: flightPlanManager,
                                          airportDataService: airportDataService) else { return }
            let thread = threadManager.createThread(from: plan)
            // 10 of 12. The count is deliberate: a ring is read at a glance, and a numerator over a
            // denominator of 12 reads as a date. 10/12 is the count the user signed off; 9/11 was
            // caught on a hero shot. Re-check this whenever a task is added to Plan or Prepare.
            tick(thread.id, leaving: [.navLogReady, .notamChecked], threadManager: threadManager)
            appState.pendingThreadToOpen = thread.id

        case .homeFlightToday:
            guard let plan = makeDemoPlan(departure: todayAtTwo(),
                                          flightPlanManager: flightPlanManager,
                                          airportDataService: airportDataService) else { return }
            let thread = threadManager.createThread(from: plan)
            // Two left open so the hero has something to say ("Next: …  · 2 open").
            tick(thread.id, leaving: [.navLogReady, .notamChecked], threadManager: threadManager)
            appState.pendingThreadToOpen = nil   // the point is Home itself

        case .flightCloseOut:
            // A flown flight: the real Vol d'Alpes, followed and now in CLOSE, with a club rate so the
            // cost card has something to show. The logbook line derives from the flight itself.
            let alpineId = UUID(uuidString: "E3293374-6672-4484-A00F-92FC7BC2347E")
            guard let flight = appState.flights.first(where: { $0.id == alpineId }) else {
                AppLog.marketing.debugLine("Close-out scene: Vol d'Alpes not found after import")
                return
            }
            appState.settings.aircraftRates[AircraftType.wt9Dynamic.registration] =
                AircraftRateProfile(hourlyRate: 260, currency: "CHF", basis: .block)
            appState.saveSettings()
            // With no plan the AUTO rows (route, fuel) can never settle, and the close-out reads as a
            // flight nobody planned. Give it the route it actually flew.
            let plan = makeDemoPlan(from: "LSGS", to: "LSZQ",
                                    departure: flight.startTime ?? Date(),
                                    flightPlanManager: flightPlanManager,
                                    airportDataService: airportDataService)
            let thread = threadManager.createThread(from: plan, profile: .full,
                                                    routeLabel: "LSGS → LSZQ",
                                                    aircraftRegistration: flight.aircraftRegistration)
            tick(thread.id, leaving: [], includingClose: true, threadManager: threadManager)
            threadManager.beginCloseOut(threadId: thread.id, flightId: flight.id)
            appState.pendingThreadToOpen = thread.id

        default:
            break
        }
    }

    // MARK: - Scene 5: Flight Log — import the bundled marketing flights

    /// Filenames (without extension) of the bundled marketing flights, in display order. These are
    /// imported by BOTH the Home and Flight Log scenes.
    private static let marketingFlightFiles = [
        "wright_brothers_1903",
        "harriet_quimby_1912",
        "lindbergh_1927",
        "yeager_1947",
        "lszq_alpine_tour"
    ]

    /// A real recorded flight, bundled for the Flight Log hero only (NOT the Home set). It is the most
    /// recent flight, so it sorts to the top and is the one shown open in detail. (User-supplied export.)
    private static let realHighlightFlightFile = "vol_dalpes_2026"

    private static func injectFlightLog(appState: AppState) {
        let imported = importMarketingFlights(into: appState)
        // Flight Log hero highlights a REAL flight (Vol d'Alpes) on top of the marketing set.
        let real = importFlight(named: realHighlightFlightFile, into: appState)
        AppLog.marketing.debugLine("Imported \(imported) marketing flights + \(real ? 1 : 0) real flight")
    }

    /// Loads the bundled marketing flights into the real flight store (idempotent — skips ids already
    /// present). Shared by the Flight Log scene and the Home scene (so Home's "last flight" card has
    /// something to show). Returns the number newly imported.
    @discardableResult
    private static func importMarketingFlights(into appState: AppState) -> Int {
        marketingFlightFiles.reduce(0) { $0 + (importFlight(named: $1, into: appState) ? 1 : 0) }
    }

    /// Load one bundled flight JSON and insert it via the real persistence path. Idempotent (skips if
    /// the id is already present). Returns true if it was newly imported. The marketing/flights folder
    /// is a blue folder reference, so the JSONs land at <bundle>/flights/<name>.json.
    @discardableResult
    private static func importFlight(named name: String, into appState: AppState) -> Bool {
        guard let url = bundledMarketingFlightURL(named: name),
              let data = try? Data(contentsOf: url),
              let flight = try? Flight.fromJSON(data) else {
            AppLog.marketing.debugLine("Could not load bundled flight \(name)")
            return false
        }
        guard !appState.flights.contains(where: { $0.id == flight.id }) else { return false }
        var f = flight
        f.computeSummaryStats()
        appState.flights.insert(f, at: 0)
        appState.saveFlight(f) // real persistence path → appears in Flight Log
        return true
    }

    /// Resolve a bundled marketing flight JSON URL. Tries the folder-reference layout (flights/),
    /// then a flat bundle layout as a fallback.
    private static func bundledMarketingFlightURL(named name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "flights") {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: "json")
    }
}

/// DEV-ONLY: "the scene is up", for the screenshot tour (a UI test outside this repository that drives the app by
/// its bundle id): a Darwin notification, posted once a launch scene is injected (`ContentView`) or the dry run's
/// autopilot holds where it was asked to stop (`DryRunAutopilot`). The tour waits for it instead of a fixed time.
enum CaptureSignal {
    static let sceneReady = "com.fetzu.aerocheck.debug.sceneReady"

    static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(sceneReady as CFString), nil, nil, true)
    }
}
#endif
