#if DEBUG
import CoreLocation
import Foundation

// MARK: - Ground replays (DEV-ONLY, compiled out of Release)
//
// A recorded or generated flight, replayed on the simulator through the app's own GPS pipeline, so
// what the app does in flight (the check slot, the cues, FREDA, the landed card, the times over, the
// logbook) can be tested on the ground, end to end, by a UI test that taps what a pilot taps.
//
// - The clock: `FlightClock.now` runs `rate` times faster than the wall clock (10 by default) from
//   the replay's start, and every part of the flight reads it, the detector included.
// - The fixes: one per virtual second, through `LocationManager.feedReplayFix`, which is the device's
//   own path (`processLocation(isOwnFix: true)`) at the replay's clock. The simulator's own fixes are
//   ignored meanwhile. Nothing is bypassed and the marketing mode is never set.
// - The holds: the replay waits on its first fix until the pilot has pressed ENGINE START, and at any
//   further hold the scenario names (at the holding point until LINE UP, say), re-sending the fix
//   about once a virtual second, so the UI test sets the pace of the ground work.
// - The aerodromes come with the scenario (a fresh simulator has none), and so does the route, armed
//   as a pilot arms one, so START FLIGHT flies it: a route, or with `planned` a flight planned for today
//   (its own copy of the route, followed by a flight thread, as Plan new flight makes it).
//
// Launched by the environment (`ContentView`'s DEBUG task):
//   AEROCHECK_REPLAY=<path of the scenario JSON>   AEROCHECK_REPLAY_SPEED=10
//   AEROCHECK_REPLAY_RESUME=1   relaunched mid-flight: the clock and the track go on where they were,
//                               as if the aircraft had flown on while the app was gone
//   AEROCHECK_MEMORY_TEST=1     Settings › Memory test on
// The scenario format and the generator are in scripts/flightsim/.

/// A flight to replay: the track, the aerodromes near it, where to wait for the pilot, and the route.
struct GroundReplayScenario: Decodable {
    struct Aerodrome: Decodable {
        let ident: String
        let name: String?
        let lat: Double
        let lon: Double
        let elev: Int?
        let type: String?
    }

    /// Wait at `t` (seconds into the track) until `until` holds: `engineStart`, `lineUp` (LINE UP
    /// tapped, or the LINE UP check reached), `phase:<name>` (that check or a later one reached),
    /// `flightActive`.
    struct Hold: Decodable {
        let t: Double
        let until: String
    }

    struct RoutePoint: Decodable {
        let name: String
        let lat: Double
        let lon: Double
        /// Planned altitude, feet.
        let altitude: Double?
        /// `aerodrome`, `vrp`, `navaid` or `user`.
        let kind: String?
        /// A reporting point's aerodrome: "E (LSGC)".
        let aerodrome: String?
        let code: String?
    }

    struct Route: Decodable {
        let name: String?
        let waypoints: [RoutePoint]
        /// The planned departure, minutes after the replay starts.
        let departureInMinutes: Double?
        /// A flight planned for today on the route (Plan new flight), rather than the route alone, which
        /// has no date (a route's departure time is swept at launch).
        let planned: Bool?
    }

    let name: String
    let registration: String?
    let speedFactor: Double?
    /// `[t, lat, lon, altitude m, speed m/s, horizontal accuracy m, course°?, baro relative m?]`; `t` in
    /// seconds, any origin. A missing or negative course is taken from the track.
    let track: [[Double?]]
    let airports: [Aerodrome]
    let holds: [Hold]?
    let route: Route?

    static func load(path: String) throws -> GroundReplayScenario {
        try JSONDecoder().decode(GroundReplayScenario.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

/// One fix of the track, re-based to start at 0 s.
struct GroundReplayFix: Equatable {
    let t: Double
    let latitude: Double
    let longitude: Double
    let altitudeM: Double
    let speedMS: Double
    let horizontalAccuracy: Double
    let course: Double
    let baroRelativeM: Double?

    func location(at time: Date) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                   altitude: altitudeM, horizontalAccuracy: horizontalAccuracy, verticalAccuracy: 8,
                   course: course, courseAccuracy: course >= 0 ? 5 : -1,
                   speed: speedMS, speedAccuracy: speedMS >= 0 ? 0.5 : -1, timestamp: time)
    }

    /// The rows, sorted and re-based to 0 s, with the course from the track where a row has none: the
    /// bearing from the last point it moved from (2 m or more), the first such bearing before it moves.
    static func fixes(from rows: [[Double?]]) -> [GroundReplayFix] {
        let valid = rows.compactMap { row -> [Double?]? in
            guard row.count >= 6, row[0...5].allSatisfy({ $0 != nil }) else { return nil }
            return row
        }.sorted { $0[0]! < $1[0]! }
        guard let t0 = valid.first?[0] ?? nil else { return [] }
        var bearings: [Double?] = Array(repeating: nil, count: valid.count)
        var from = 0
        for i in valid.indices.dropFirst() {
            let a = CLLocation(latitude: valid[from][1]!, longitude: valid[from][2]!)
            let b = CLLocation(latitude: valid[i][1]!, longitude: valid[i][2]!)
            if b.distance(from: a) >= 2 {
                bearings[i] = bearing(from: a.coordinate, to: b.coordinate)
                from = i
            }
        }
        let firstBearing = bearings.compactMap { $0 }.first
        var carried: Double? = nil
        return valid.enumerated().map { i, row in
            if let b = bearings[i] { carried = b }
            let given = row.count > 6 ? row[6] : nil
            let course = given.flatMap { $0 >= 0 ? $0 : nil } ?? carried ?? firstBearing ?? -1
            return GroundReplayFix(t: row[0]! - t0, latitude: row[1]!, longitude: row[2]!, altitudeM: row[3]!,
                                   speedMS: row[4]!, horizontalAccuracy: row[5]!, course: course,
                                   baroRelativeM: row.count > 7 ? row[7] : nil)
        }
    }

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}

/// The replay's position in the track, and how the pilot releases its holds. Pure: `GroundReplay`
/// drives it with the clock, the tests directly.
struct GroundReplayCursor: Equatable {
    struct Hold: Equatable {
        let t: Double
        let condition: Condition
    }

    enum Condition: Equatable {
        case engineStart
        case lineUp
        case phase(ChecklistPhase)
        case flightActive

        init?(_ text: String) {
            let lower = text.lowercased()
            switch lower {
            case "enginestart": self = .engineStart
            case "lineup": self = .lineUp
            case "flightactive": self = .flightActive
            default:
                guard lower.hasPrefix("phase:"),
                      let phase = ChecklistPhase.allCases.first(where: { "\($0)".lowercased() == lower.dropFirst(6) })
                else { return nil }
                self = .phase(phase)
            }
        }
    }

    /// What a hold waits on, as the flight stands.
    struct FlightState: Equatable {
        var isFlightActive = false
        var engineStarted = false
        var linedUp = false
        var phase: ChecklistPhase = .preflight

        func satisfies(_ condition: Condition) -> Bool {
            switch condition {
            case .engineStart: return isFlightActive && engineStarted
            case .lineUp: return isFlightActive && (linedUp || phase.rawValue >= ChecklistPhase.lineUp.rawValue)
            case .phase(let target): return isFlightActive && phase.rawValue >= target.rawValue
            case .flightActive: return isFlightActive
            }
        }
    }

    let duration: Double
    let holds: [Hold]
    /// Seconds into the track.
    private(set) var t: Double = 0
    /// The holds released so far.
    private(set) var released = 0

    init(duration: Double, holds: [Hold], t: Double = 0, released: Int = 0) {
        self.duration = duration
        self.holds = holds.sorted { $0.t < $1.t }
        self.t = t
        self.released = released
    }

    /// The hold the replay is waiting at, if it is waiting.
    var waitingAt: Hold? {
        guard released < holds.count, t >= holds[released].t else { return nil }
        return holds[released]
    }

    /// `seconds` of the replay's clock have passed: on through the track, up to the next hold, unless
    /// the flight released it.
    mutating func advance(by seconds: Double, flight: FlightState) {
        var left = max(0, seconds)
        while true {
            if let hold = waitingAt {
                guard flight.satisfies(hold.condition) else { return }
                released += 1
                continue
            }
            let stop = released < holds.count ? min(holds[released].t, duration) : duration
            let step = min(left, max(0, stop - t))
            t += step
            left -= step
            if left <= 0 || t >= duration { return }
        }
    }
}

/// The replay itself: the clock, the cursor, the fixes, and the state kept for a relaunch.
@MainActor
final class GroundReplay {
    static private(set) var current: GroundReplay?

    private let scenarioPath: String
    let scenario: GroundReplayScenario
    let fixes: [GroundReplayFix]
    private(set) var cursor: GroundReplayCursor
    private weak var appState: AppState?
    private weak var locationManager: LocationManager?
    private var timer: Timer?
    private var lastTick: Date
    private var fixIndex = 0
    private var lastDelivered: (index: Int, at: Date)?
    private var lastSaved = Date.distantPast

    private init(path: String, scenario: GroundReplayScenario, fixes: [GroundReplayFix], cursor: GroundReplayCursor,
                 appState: AppState, locationManager: LocationManager) {
        self.scenarioPath = path
        self.scenario = scenario
        self.fixes = fixes
        self.cursor = cursor
        self.appState = appState
        self.locationManager = locationManager
        self.lastTick = FlightClock.now
    }

    // MARK: Launch

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// The replay's clock, from the launch environment: nil without `AEROCHECK_REPLAY`. Started now at
    /// the wall clock's time, or, resumed, where the last run left it plus the time the app was gone.
    nonisolated static func clockAtLaunch() -> FlightClock.Virtual? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["AEROCHECK_REPLAY"], !path.isEmpty else { return nil }
        let rate = env["AEROCHECK_REPLAY_SPEED"].flatMap(Double.init)
            ?? (try? GroundReplayScenario.load(path: path))?.speedFactor ?? 10
        let wall = Date()
        if env["AEROCHECK_REPLAY_RESUME"] == "1", let saved = GroundReplaySavedState.load(), saved.scenarioPath == path {
            let virtual = saved.virtualNow.addingTimeInterval(wall.timeIntervalSince(saved.wallNow) * saved.rate)
            return FlightClock.Virtual(wallAnchor: wall, virtualAnchor: virtual, rate: saved.rate)
        }
        return FlightClock.Virtual(wallAnchor: wall, virtualAnchor: wall, rate: max(rate, 0.1))
    }

    /// Starts the replay `AEROCHECK_REPLAY` names, if any: true when it did. A fresh replay abandons a
    /// flight left over from an earlier run and any route armed, and arms the scenario's own once the
    /// plans and the flights have loaded.
    @discardableResult
    static func startIfRequested(appState: AppState, locationManager: LocationManager,
                                 airportDataService: AirportDataService,
                                 flightPlanManager: FlightPlanManager,
                                 threadManager: FlightThreadManager) async -> Bool {
        guard current == nil, let path = environment["AEROCHECK_REPLAY"], !path.isEmpty,
              FlightClock.virtual != nil else { return false }
        let scenario: GroundReplayScenario
        do {
            scenario = try GroundReplayScenario.load(path: path)
        } catch {
            AppLog.general.debugLine("Ground replay: cannot read \(path): \(error)")
            return false
        }
        let fixes = GroundReplayFix.fixes(from: scenario.track)
        guard !fixes.isEmpty else { return false }

        // The pilot's own setup, as the scenes do it, without the marketing mode.
        if appState.needsDisclaimerAcceptance { appState.acceptDisclaimer() }
        if !appState.hasSeenOnboarding { appState.completeOnboarding() }
        if let memoryTest = environment["AEROCHECK_MEMORY_TEST"] {
            appState.settings.learningMode = memoryTest != "1"
        }

        airportDataService.injectForReplay(scenario.airports.map(airport))

        let holds = (scenario.holds ?? [.init(t: 0, until: "engineStart")]).compactMap { hold in
            GroundReplayCursor.Condition(hold.until).map { GroundReplayCursor.Hold(t: hold.t, condition: $0) }
        }
        var cursor = GroundReplayCursor(duration: fixes.last?.t ?? 0, holds: holds)
        let resumed = environment["AEROCHECK_REPLAY_RESUME"] == "1" ? GroundReplaySavedState.load() : nil
        if let resumed, resumed.scenarioPath == path {
            cursor = GroundReplayCursor(duration: cursor.duration, holds: holds, t: resumed.trackT,
                                        released: resumed.released)
            // The aircraft flew on while the app was gone, unless it was waiting for the pilot.
            let gone = FlightClock.now.timeIntervalSince(resumed.virtualNow)
            cursor.advance(by: gone, flight: .init(isFlightActive: true, engineStarted: resumed.engineStarted,
                                                   linedUp: resumed.linedUp, phase: resumed.phase))
        } else {
            if appState.isFlightActive {
                let leftOver = appState.currentFlight
                locationManager.stopTracking()
                appState.cancelFlight()
                flightPlanManager.abandonFlownPlan(of: leftOver)
            }
            if flightPlanManager.activeFlightPlan != nil { flightPlanManager.deactivateFlightPlan() }
        }

        let replay = GroundReplay(path: path, scenario: scenario, fixes: fixes, cursor: cursor,
                                  appState: appState, locationManager: locationManager)
        current = replay
        // GPS on, as Today does it, so START FLIGHT finds a fix.
        locationManager.startLocationUpdates()
        replay.start()
        AppLog.general.debugLine("Ground replay: \(scenario.name), \(fixes.count) fixes, x\(FlightClock.virtual?.rate ?? 1)")

        // The route, once the stores have loaded (an earlier write would be overwritten by the load).
        guard resumed?.scenarioPath != path, let route = scenario.route else { return true }
        for _ in 0..<100 where !(threadManager.hasLoadedThreads && flightPlanManager.hasLoadedPlans) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if route.planned == true {
            armPlannedFlight(route, name: scenario.name, plans: flightPlanManager, threads: threadManager)
        } else {
            arm(route, name: scenario.name, in: flightPlanManager)
        }
        return true
    }

    static func airport(_ row: GroundReplayScenario.Aerodrome) -> Airport {
        // A stable id: the replay's aerodromes are never saved, but the same on every launch.
        let id = row.ident.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 100_000_000 }
        return Airport(id: id, ident: row.ident,
                type: row.type.flatMap(AirportType.init(rawValue:)) ?? .smallAirport,
                name: row.name ?? row.ident, latitude: row.lat, longitude: row.lon, elevation: row.elev,
                continent: "EU", isoCountry: row.ident.hasPrefix("LS") ? "CH" : row.ident.hasPrefix("LF") ? "FR" : "",
                isoRegion: "", municipality: nil, scheduledService: false, gpsCode: row.ident,
                iataCode: nil, localCode: nil)
    }

    /// The scenario's route, made and armed as a pilot's, so START FLIGHT takes it. (Its departure time
    /// is the route's until the launch's sweep clears it: a route has no date, a flight has.)
    static func arm(_ route: GroundReplayScenario.Route, name: String, in manager: FlightPlanManager) {
        let plan = plan(of: route, name: name)
        manager.add(plan)
        manager.activateFlightPlan(plan)
    }

    /// A flight planned for today on the scenario's route, as Plan new flight makes one from a saved
    /// route, its plan armed: START FLIGHT on Today starts it. `FlightCreator.create(fromRoute:)` without
    /// its notification request: on a fresh install that waits on a system alert, between the plan and
    /// its flight, long enough for the launch's sweep to take the date of a plan no flight follows yet.
    static func armPlannedFlight(_ route: GroundReplayScenario.Route, name: String, plans: FlightPlanManager,
                                 threads: FlightThreadManager) {
        let template = plan(of: route, name: name)
        let intent = NewFlightIntent(departureIdent: route.waypoints.first?.name ?? "",
                                     arrivalIdent: route.waypoints.last?.name ?? "",
                                     departureTime: template.plannedDepartureTime,
                                     aircraftTypeId: template.aircraftTypeId,
                                     aircraftRegistration: template.aircraftRegistration,
                                     aircraftModelName: template.aircraftModelName)
        let plan = FlightCreator.plan(fromRoute: template, intent: intent)
        plans.add(plan)
        threads.createThread(from: plan, profile: intent.kind.profile,
                             routeLabel: FlightThreadManager.routeLabel(for: plan),
                             aircraftRegistration: intent.aircraftRegistration)
        plans.activateFlightPlan(plan)
    }

    private static func plan(of route: GroundReplayScenario.Route, name: String) -> FlightPlan {
        let waypoints = route.waypoints.map { point in
            FlightPlanWaypoint(name: point.name, coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon),
                               altitude: point.altitude,
                               pointKind: point.kind.flatMap(WaypointPointKind.init(rawValue:)),
                               sourceId: point.kind == "aerodrome" ? point.name : nil,
                               code: point.code, aerodromeICAO: point.aerodrome)
        }
        var plan = FlightPlan(name: route.name ?? name, waypoints: waypoints,
                              plannedDepartureTime: FlightClock.now.addingTimeInterval((route.departureInMinutes ?? 10) * 60))
        plan.calculateRouteData()
        return plan
    }

    // MARK: Running

    private func start() {
        lastTick = FlightClock.now
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private var flightState: GroundReplayCursor.FlightState {
        guard let appState else { return .init() }
        return .init(isFlightActive: appState.isFlightActive, engineStarted: appState.engineStartTime != nil,
                     linedUp: appState.lineUpTime != nil, phase: appState.currentPhase)
    }

    private func tick() {
        let now = FlightClock.now
        cursor.advance(by: now.timeIntervalSince(lastTick), flight: flightState)
        lastTick = now
        // The fix the track has reached; held, or at the end, the same one again once a virtual second.
        while fixIndex + 1 < fixes.count, fixes[fixIndex + 1].t <= cursor.t { fixIndex += 1 }
        let index = fixIndex
        if lastDelivered.map({ index != $0.index || now.timeIntervalSince($0.at) >= 1 }) ?? true {
            let fix = fixes[index]
            locationManager?.feedReplayFix(fix.location(at: now), baroRelativeAltitudeM: fix.baroRelativeM)
            lastDelivered = (index, now)
        }
        if Date().timeIntervalSince(lastSaved) >= 1 {
            lastSaved = Date()
            GroundReplaySavedState(scenarioPath: scenarioPath, trackT: cursor.t, released: cursor.released,
                       virtualNow: now, wallNow: Date(), rate: FlightClock.virtual?.rate ?? 1,
                       engineStarted: flightState.engineStarted, linedUp: flightState.linedUp,
                       phase: flightState.phase).save()
        }
    }
}

// MARK: - Relaunch

/// Where the replay was, for `AEROCHECK_REPLAY_RESUME`: in Caches, nothing a user keeps.
struct GroundReplaySavedState: Codable {
    let scenarioPath: String
    let trackT: Double
    let released: Int
    let virtualNow: Date
    let wallNow: Date
    let rate: Double
    let engineStarted: Bool
    let linedUp: Bool
    let phaseRawValue: Int

    var phase: ChecklistPhase { ChecklistPhase(rawValue: phaseRawValue) ?? .preflight }

    init(scenarioPath: String, trackT: Double, released: Int, virtualNow: Date, wallNow: Date, rate: Double,
         engineStarted: Bool, linedUp: Bool, phase: ChecklistPhase) {
        self.scenarioPath = scenarioPath
        self.trackT = trackT
        self.released = released
        self.virtualNow = virtualNow
        self.wallNow = wallNow
        self.rate = rate
        self.engineStarted = engineStarted
        self.linedUp = linedUp
        self.phaseRawValue = phase.rawValue
    }

    static var url: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ground-replay-state.json")
    }

    static func load() -> GroundReplaySavedState? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GroundReplaySavedState.self, from: data)
    }

    func save() {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
#endif
