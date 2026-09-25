import Foundation
import CoreLocation
import SwiftUI

/// Manages flight plan state, persistence, and calculations
@MainActor
class FlightPlanManager: ObservableObject {
    // MARK: - Published Properties

    @Published var flightPlans: [FlightPlan] = []
    @Published var activeFlightPlan: FlightPlan?
    @Published var chronometerElapsed: TimeInterval = 0
    /// Set once at launch when an activation is retired by age; drives the notice banner. (v4.4.0)
    @Published var expiredActivation: ExpiredActivation?
    /// Elapsed accumulated from completed run segments, so pause/resume preserves the leg time. (v4 UI/UX Revamp)
    private var chronometerAccumulated: TimeInterval = 0

    /// True while the leg timer is actively counting (pause clears the plan's start time). (v4 UI/UX Revamp)
    var isChronometerRunning: Bool { activeFlightPlan?.chronometerStartTime != nil }

    // MARK: - Private Properties

    private let activeFlightPlanKey = "activeFlightPlan"
    private var chronometerTimer: Timer?
    /// Where the plan files live. Injectable for the same reason as `defaults`: in a test, `.shared`
    /// is the simulator app's own datastore.
    private let persistence: DataPersistenceManager
    /// Where the active-plan pointer lives. Injectable so tests get their own suite: the test host
    /// shares the app's bundle id, so a test that activated a plan against `.standard` left a
    /// synthetic route showing as ACTIVE in the real app on that simulator.
    private let defaults: UserDefaults

    /// How long an activation survives without a flight ever starting.
    ///
    /// Activating a plan is an intention ("this is the flight I'm about to make"), and it is normal
    /// to form that intention well before engine start — in the clubhouse, or the evening before. So
    /// an activation must survive backgrounding and relaunch. It should NOT survive forever, though:
    /// a plan activated and never flown would otherwise still be framing the nav map weeks later,
    /// beside a flight it has nothing to do with.
    ///
    /// 72 hours covers planning on a Friday for a Sunday flight, which is the longest gap that came
    /// up as realistic, while still expiring an abandoned activation on a human timescale. Only
    /// checked at launch, and only when no flight is in progress.
    static let activationLifetime: TimeInterval = 72 * 60 * 60

    // MARK: - Initialization

    /// True once the on-disk plans have arrived — see `FlightThreadManager.hasLoadedThreads`.
    @Published private(set) var hasLoadedPlans = false

    init(defaults: UserDefaults = .standard, persistence: DataPersistenceManager? = nil) {
        self.defaults = defaults
        self.persistence = persistence ?? DataPersistenceManager.shared
        // Active plan + chronometer come from UserDefaults (local, fast) and are needed for
        // initial UI. The plans themselves live in iCloud Drive: enumerating/reading them can
        // stall on iCloud — for an evicted file, long enough on a slow network to trip the launch
        // watchdog — so they load off-main, mirroring the flights fix (PR-24). (PERF-25)
        loadActiveFlightPlan()
        startChronometerIfNeeded()
        Task { [weak self] in
            await self?.loadFlightPlansAsync()
        }
    }

    /// Clear the departure time from every plan no flight follows.
    ///
    /// A route is a path, not an appointment: it is flyable any day, and the date belongs to the
    /// FLIGHT that uses it. Saves written before that distinction existed still carry a time, and a
    /// route claiming a date is what made three of them all look like "today's flight plan".
    ///
    /// `followedPlanIds` is passed in rather than reached for — this type knows nothing about
    /// flights, and the caller is the one place that can see both. It must only be called once the
    /// threads have actually loaded, or every plan looks unfollowed and real flights lose their
    /// dates; `FlightThreadManager.hasLoadedThreads` is that gate. (v5.x)
    func clearDatesFromUnflownRoutes(followedPlanIds: Set<UUID>) {
        // The active route is a copy held separately, so it is cleared FIRST and unconditionally.
        // Behind the `guard changed` below it was skipped whenever the active plan was the only one
        // carrying a date — producing exactly the state the guard's own comment says it exists to
        // prevent: the next edit writes the date back and the route re-acquires a departure time
        // the sweep already decided it should not have. (review F11)
        if let active = activeFlightPlan,
           active.plannedDepartureTime != nil,
           !followedPlanIds.contains(active.id) {
            activeFlightPlan?.plannedDepartureTime = nil
            // Waypoint times-over are DERIVED from the departure time. Clearing the date without
            // recomputing left a full set of ETOs hanging off a time that no longer exists, which
            // the editor then would not show and could not explain. (review F11)
            activeFlightPlan?.calculateRouteData()
            saveActiveFlightPlan()
        }

        var changed = false
        for index in flightPlans.indices
        where flightPlans[index].plannedDepartureTime != nil
            && !followedPlanIds.contains(flightPlans[index].id) {
            flightPlans[index].plannedDepartureTime = nil
            flightPlans[index].calculateRouteData()
            flightPlans[index].updatedAt = Date()
            changed = true
        }
        guard changed else { return }
        saveFlightPlans()
        AppLog.general.debugLine("Cleared departure times from routes with no flight")
    }

    // MARK: - Flight Plan CRUD

    /// Create a new flight plan
    func createFlightPlan(
        name: String = "New Flight Plan",
        aircraftTypeId: String = "WT9",
        aircraftRegistration: String = "F-HVXA",
        aircraftModelName: String = "WT9 Dynamic"
    ) -> FlightPlan {
        let plan = FlightPlan(
            name: name,
            aircraftTypeId: aircraftTypeId,
            aircraftRegistration: aircraftRegistration,
            aircraftModelName: aircraftModelName,
            fuelFlow: FlightPlan.defaultFuelFlow(for: aircraftTypeId)
        )
        flightPlans.insert(plan, at: 0)
        saveFlightPlans()
        return plan
    }

    /// Insert a plan built elsewhere — currently by `FlightPlan.from(intent:)`, which turns what a
    /// pilot knows before they have a route into a plan. `createFlightPlan` cannot be reused for that
    /// because it builds its own empty plan; this takes one already assembled. (v5.0.0)
    func add(_ plan: FlightPlan) {
        flightPlans.insert(plan, at: 0)
        saveFlightPlans()
    }

    /// Update an existing flight plan
    func updateFlightPlan(_ plan: FlightPlan) {
        var updatedPlan = plan
        updatedPlan.updatedAt = Date()

        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) {
            flightPlans[index] = updatedPlan
        }

        // Update active plan if this is it
        if activeFlightPlan?.id == plan.id {
            activeFlightPlan = updatedPlan
            saveActiveFlightPlan()
        }

        saveFlightPlans()
        carryIntoNextLeg(from: updatedPlan)
    }

    /// Wired at launch to the thread manager: the plan of the leg after the one flying a plan, in its
    /// trip. Nil outside a trip. (v5.1)
    var nextLegPlanId: (@MainActor (UUID) -> UUID?)?

    /// A later trip leg departs when the one before it lands, so moving leg 1's departure, or
    /// changing its route, moves leg 2's estimated departure and ETOs, and its fuel when it does not
    /// refuel. Each updated leg carries on into the next one through `updateFlightPlan`; the chain ends
    /// where nothing changes, or at a departure the pilot chose. (v5.1)
    private func carryIntoNextLeg(from plan: FlightPlan) {
        guard let nextId = nextLegPlanId?(plan.id), nextId != plan.id,
              let next = flightPlans.first(where: { $0.id == nextId }),
              let refreshed = TripPlanner.refreshed(next, after: plan) else { return }
        updateFlightPlan(refreshed)
    }

    /// Delete a flight plan
    func deleteFlightPlan(_ plan: FlightPlan) {
        flightPlans.removeAll { $0.id == plan.id }

        // Deactivate if this was the active plan
        if activeFlightPlan?.id == plan.id {
            deactivateFlightPlan()
        }

        // Delete the file from iCloud
        deleteFlightPlanFile(plan)
    }

    /// Delete flight plans at offsets
    func deleteFlightPlans(at offsets: IndexSet) {
        // Collect plans to delete for file cleanup
        let plansToDelete = offsets.map { flightPlans[$0] }

        for index in offsets {
            if flightPlans[index].id == activeFlightPlan?.id {
                deactivateFlightPlan()
            }
        }
        flightPlans.remove(atOffsets: offsets)

        // Delete files from iCloud
        for plan in plansToDelete {
            deleteFlightPlanFile(plan)
        }
    }

    /// Duplicate a flight plan
    func duplicateFlightPlan(_ plan: FlightPlan) -> FlightPlan {
        var newPlan = plan
        newPlan = FlightPlan(
            name: "\(plan.name) (Copy)",
            waypoints: plan.waypoints,
            aircraftTypeId: plan.aircraftTypeId,
            aircraftRegistration: plan.aircraftRegistration,
            aircraftModelName: plan.aircraftModelName,
            pilot: plan.pilot,
            instructor: plan.instructor,
            flightType: plan.flightType,
            runwayInUse: plan.runwayInUse,
            fuelFlow: plan.fuelFlow,
            reserveFuel: plan.reserveFuel,
            additionalFuel: plan.additionalFuel,
            extraFuel: plan.extraFuel,
            fuelOnBoard: plan.fuelOnBoard,
            remarks: plan.remarks
        )
        newPlan.calculateRouteData()
        flightPlans.insert(newPlan, at: 0)
        saveFlightPlans()
        return newPlan
    }

    // MARK: - Waypoint Management

    /// Add a waypoint to a flight plan
    func addWaypoint(to planId: UUID, coordinate: CLLocationCoordinate2D, name: String = "") {
        guard var plan = flightPlans.first(where: { $0.id == planId }) else { return }

        let waypoint = FlightPlanWaypoint(
            name: name.isEmpty ? "WPT\(plan.waypoints.count + 1)" : name,
            coordinate: coordinate,
            plannedGroundSpeed: FlightPlan.defaultCruiseSpeed(for: plan.aircraftTypeId)
        )

        plan.waypoints.append(waypoint)
        plan.calculateRouteData()
        updateFlightPlan(plan)
    }

    /// Best index to INSERT a dropped point so it least lengthens the route ("cheapest insertion"):
    /// the interior leg it adds the smallest detour to, or prepend/append when the point sits beyond an
    /// endpoint. Returns an index in `0...count` suitable for `insertWaypoint(at:)`. (flight-plan
    /// revamp #4 — smart add; same convention as ForeFlight rubber-band / SkyDemon tap-insert.)
    nonisolated static func bestInsertionIndex(for coordinate: CLLocationCoordinate2D, in waypoints: [FlightPlanWaypoint]) -> Int {
        guard waypoints.count >= 2 else { return waypoints.count } // 0/1 points → just append
        func dist(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
            CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
        let coords = waypoints.map { $0.coordinate }
        // Added route length for the two endpoint options…
        var bestIndex = coords.count
        var bestAdded = dist(coords[coords.count - 1], coordinate)   // append after the last
        let prepend = dist(coordinate, coords[0])                    // prepend before the first
        if prepend < bestAdded { bestAdded = prepend; bestIndex = 0 }
        // …versus the detour added by routing through the point on each interior leg.
        for i in 0..<(coords.count - 1) {
            let detour = dist(coords[i], coordinate) + dist(coordinate, coords[i + 1]) - dist(coords[i], coords[i + 1])
            if detour < bestAdded { bestAdded = detour; bestIndex = i + 1 }
        }
        return bestIndex
    }

    /// Insert a waypoint at a specific index
    func insertWaypoint(to planId: UUID, at index: Int, coordinate: CLLocationCoordinate2D, name: String = "") {
        guard var plan = flightPlans.first(where: { $0.id == planId }) else { return }

        let waypoint = FlightPlanWaypoint(
            name: name.isEmpty ? "WPT" : name,
            coordinate: coordinate,
            plannedGroundSpeed: FlightPlan.defaultCruiseSpeed(for: plan.aircraftTypeId)
        )

        plan.waypoints.insert(waypoint, at: min(index, plan.waypoints.count))
        plan.calculateRouteData()
        updateFlightPlan(plan)
    }

    /// Recompute the active plan's leg data in place. Used after an async input that route
    /// calculation reads synchronously has landed — currently the winds-aloft forecast, which
    /// `FlightPlan.windsAloftProvider` can only serve from cache.
    func recalculateCurrentPlanRouteData() {
        guard var plan = activeFlightPlan else { return }
        plan.calculateRouteData()
        updateFlightPlan(plan)
    }

    /// Set many planned altitudes in one write (the builder's "Set altitudes"), so the route is
    /// recalculated and saved once rather than once per waypoint.
    func setAltitudes(_ altitudes: [UUID: Double], in planId: UUID) {
        guard var plan = flightPlans.first(where: { $0.id == planId }), !altitudes.isEmpty else { return }
        for i in plan.waypoints.indices {
            if let altitude = altitudes[plan.waypoints[i].id], altitude.isFinite {
                plan.waypoints[i].altitude = altitude
            }
        }
        plan.calculateRouteData()
        updateFlightPlan(plan)
    }

    /// Update a waypoint in a flight plan
    func updateWaypoint(_ waypoint: FlightPlanWaypoint, in planId: UUID) {
        guard var plan = flightPlans.first(where: { $0.id == planId }) else { return }
        guard let index = plan.waypoints.firstIndex(where: { $0.id == waypoint.id }) else { return }

        plan.waypoints[index] = waypoint
        plan.calculateRouteData()
        updateFlightPlan(plan)
    }

    /// Remove a waypoint from a flight plan
    func removeWaypoint(_ waypoint: FlightPlanWaypoint, from planId: UUID) {
        guard var plan = flightPlans.first(where: { $0.id == planId }) else { return }

        // PR-02: never empty the in-use active plan — the in-flight overlay indexes waypoints.
        if activeFlightPlan?.id == planId && plan.waypoints.count <= 1 { return }

        plan.waypoints.removeAll { $0.id == waypoint.id }
        plan.calculateRouteData()
        updateFlightPlan(plan)
    }

    /// Reverse the route (swap From ↔ To and everything between). (flight-plan revamp #2)
    func reverseRoute(planId: UUID) {
        guard var plan = flightPlans.first(where: { $0.id == planId }), plan.waypoints.count >= 2 else { return }
        plan.waypoints.reverse()
        plan.calculateRouteData()
        updateFlightPlan(plan)
    }

    /// Move waypoints within a flight plan
    func moveWaypoints(in planId: UUID, from source: IndexSet, to destination: Int) {
        guard var plan = flightPlans.first(where: { $0.id == planId }) else { return }

        plan.waypoints.move(fromOffsets: source, toOffset: destination)
        plan.calculateRouteData()
        updateFlightPlan(plan)
    }

    // MARK: - Active Flight Plan Management

    /// Activate a flight plan for in-flight use
    func activateFlightPlan(_ plan: FlightPlan) {
        // PR-02: never activate an empty plan — the in-flight overlay/chronometer index waypoints.
        guard !plan.waypoints.isEmpty else { return }
        var activePlan = plan
        activePlan.isActive = true
        activePlan.currentWaypointIndex = 0
        activePlan.chronometerStartTime = nil
        activePlan.activatedAt = Date()
        // A diversion belongs to the flight that made it.
        activePlan.diversion = nil

        // Reset ATO values for all waypoints (fresh start for new flight)
        for i in 0..<activePlan.waypoints.count {
            activePlan.waypoints[i].actualTimeOver = nil
        }

        // Update in the plans list
        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) {
            flightPlans[index] = activePlan
        }

        activeFlightPlan = activePlan
        chronometerElapsed = 0
        chronometerAccumulated = 0
        saveFlightPlans()
        saveActiveFlightPlan()
    }

    /// Whether the active plan has anything a deactivation would destroy.
    ///
    /// `activateFlightPlan` resets `currentWaypointIndex` and clears every `actualTimeOver`, so a
    /// deactivate → re-activate round trip loses the waypoint times recorded on this flight. Before
    /// departure there is nothing to lose; once the flight is under way there is. The UI asks for
    /// confirmation exactly when this is true. (v4.4.0)
    var activePlanHasRecordedProgress: Bool {
        guard let plan = activeFlightPlan else { return false }
        return plan.currentWaypointIndex > 0
            || plan.chronometerStartTime != nil
            || plan.waypoints.contains { $0.actualTimeOver != nil }
    }

    /// Drop an activation that was made long ago and never flown. Call ONCE at launch, after flight
    /// restoration, and only when no flight is in progress.
    ///
    /// This is what remains of "deactivate flight plans on app start", which used to run on every
    /// `scenePhase == .active` — so backgrounding the app for thirty seconds silently discarded the
    /// plan the pilot had just activated. Activation is user intent and now survives; only its age
    /// can retire it. Returns true if a plan was expired, for the test to assert on.
    @discardableResult
    func expireStaleActivation(now: Date = Date()) -> Bool {
        guard let plan = activeFlightPlan else { return false }
        // No timestamp means the plan predates v4.4.0. An unknown age is not evidence of staleness,
        // so it is kept — the user can always deactivate it.
        guard let activatedAt = plan.activatedAt else { return false }
        guard now.timeIntervalSince(activatedAt) > Self.activationLifetime else { return false }
        AppLog.general.debugLine("Expiring flight-plan activation from \(activatedAt) (never flown)")
        // Remembered BEFORE deactivating, so the notice can name the plan and offer to re-arm it. An
        // expiry is still the app changing state on its own — the same shape as the bug it replaced,
        // only slower and better justified — so it says so instead of leaving an empty nav map to
        // explain itself. (v4.4.0)
        expiredActivation = ExpiredActivation(planId: plan.id, routeLabel: routeLabel(for: plan))
        deactivateFlightPlan()
        return true
    }

    /// A plan whose activation was retired at launch, pending a one-shot notice. Cleared when the
    /// user acts on it or dismisses it.
    struct ExpiredActivation: Equatable {
        let planId: UUID
        let routeLabel: String
    }

    /// Re-arm the plan whose activation just expired, if it is still around.
    func rearmExpiredActivation() {
        guard let expired = expiredActivation,
              let plan = flightPlans.first(where: { $0.id == expired.planId }) else {
            expiredActivation = nil
            return
        }
        activateFlightPlan(plan)
        expiredActivation = nil
    }

    /// `"LSGG → LSZS"`, else the plan's name — the same identity the plan list shows.
    private func routeLabel(for plan: FlightPlan) -> String {
        let names = plan.waypoints.map(\.name).filter { !$0.isEmpty }
        if names.count >= 2, let first = names.first, let last = names.last { return "\(first) → \(last)" }
        return plan.name.isEmpty ? (names.first ?? L10n.Nav.flightPlan) : plan.name
    }

    /// Deactivate the current flight plan
    func deactivateFlightPlan() {
        if var plan = activeFlightPlan {
            plan.isActive = false
            plan.chronometerStartTime = nil

            if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) {
                flightPlans[index] = plan
            }
        }

        activeFlightPlan = nil
        chronometerElapsed = 0
        chronometerAccumulated = 0
        stopChronometer()
        saveFlightPlans()
        clearActiveFlightPlan()
    }

    /// Update the departure time for the active flight plan
    /// Called when the Line Up time is recorded from the checklist
    func updateDepartureTimeFromLineUp(_ lineUpTime: Date) {
        guard var plan = activeFlightPlan else { return }
        plan.plannedDepartureTime = lineUpTime
        // A real departure now: a trip leg's estimate is replaced by what happened.
        plan.departureIsEstimate = nil
        plan.calculateRouteData()
        updateFlightPlan(plan)
    }

    /// Populate flight plan timing fields from a completed flight's data
    /// - Parameters:
    ///   - planId: The ID of the flight plan to update
    ///   - flight: The completed flight with timing data
    ///   - takeoff, landing: the flight's line-up and landing times. Passed in because at END FLIGHT
    ///     they still live on AppState: `endFlight` copies them onto the flight only afterwards.
    func populateTimingFromFlight(_ planId: UUID, flight: Flight, takeoff: Date? = nil, landing: Date? = nil,
                                  landedAt field: TripPlanner.Aerodrome? = nil) {
        guard var plan = flightPlans.first(where: { $0.id == planId }) else { return }

        // ATO for every waypoint the in-flight trigger did not record, from the GPS track: the
        // after-flight nav log is the one the times are written on.
        plan = plan.withActualTimesOver(fromTrack: flight.gpsTrack,
                                        takeoff: takeoff ?? flight.lineUpTime,
                                        landing: landing ?? flight.landingTime)
        // Landed somewhere else than planned: record the diversion, pressed or not. (v5.1)
        plan = TripPlanner.settlingDiversion(plan, landedAt: field, landing: landing ?? flight.landingTime)

        // Time OFF = take-off, Time ON = landing (wheels off, wheels on). Never the engine: engine
        // start and shutdown are the checklist taps, kept on the flight and its hour meter. Until
        // 5.2 these two held the engine times, which made the nav log's air time the engine's. (v5.2)
        if plan.timeOff == nil, let takeoff = takeoff ?? flight.lineUpTime {
            plan.timeOff = takeoff
        }
        if plan.timeOn == nil, let landing = landing ?? flight.landingTime {
            plan.timeOn = landing
        }

        // Block OFF = Auto-detected first movement (from Flight model)
        if plan.blockOff == nil, let blockOff = flight.blockOffTime {
            plan.blockOff = blockOff
        }

        // Block ON = Auto-detected final stop (from Flight model)
        if plan.blockOn == nil, let blockOn = flight.blockOnTime {
            plan.blockOn = blockOn
        }

        // Counter Start = Engine hour meter at start
        if plan.counterStart == nil, let hourStart = flight.engineHourStart {
            plan.counterStart = hourStart
        }

        // Counter Stop = Engine hour meter at end
        if plan.counterStop == nil, let hourEnd = flight.engineHourEnd {
            plan.counterStop = hourEnd
        }

        // Total landings from flight
        if plan.totalLandings == nil || plan.totalLandings == 0 {
            plan.totalLandings = flight.totalLandings
        }

        // Landings at base = landings at departure airport
        // Count full-stop landings and touch-and-gos that occurred near the departure airport
        if plan.landingsAtBase == nil || plan.landingsAtBase == 0 {
            if let depIdent = flight.departureAirportIdent, let arrIdent = flight.arrivalAirportIdent {
                // If departure == arrival, all landings were at base
                if depIdent == arrIdent {
                    plan.landingsAtBase = flight.totalLandings
                } else {
                    // Different airports: only the final landing counts at arrival, not at base
                    // Touch-and-gos and full stops during flight could be at various airports,
                    // but for simplicity, assume circuits (T&Gs + full stops) were at departure
                    let circuitLandings = flight.touchAndGoCount + flight.fullStopCount
                    plan.landingsAtBase = circuitLandings
                }
            } else {
                // No airport detection available, set total as base landings
                plan.landingsAtBase = flight.totalLandings
            }
        }

        updateFlightPlan(plan)
    }

    /// Advance to the next waypoint (manual advance — does not auto-set ATO)
    func advanceToNextWaypoint() {
        guard var plan = activeFlightPlan else { return }
        guard plan.currentWaypointIndex < plan.waypoints.count else { return }

        plan.currentWaypointIndex += 1

        activeFlightPlan = plan

        // Update in plans list
        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) {
            flightPlans[index] = plan
        }

        saveFlightPlans()
        saveActiveFlightPlan()
    }

    /// Record ATO for the current waypoint (called on GPS proximity detection)
    func recordATOForCurrentWaypoint() {
        guard var plan = activeFlightPlan else { return }
        guard plan.currentWaypointIndex < plan.waypoints.count else { return }
        // Only record if not already set
        guard plan.waypoints[plan.currentWaypointIndex].actualTimeOver == nil else { return }

        plan.waypoints[plan.currentWaypointIndex].actualTimeOver = Date()
        activeFlightPlan = plan

        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) {
            flightPlans[index] = plan
        }

        saveFlightPlans()
        saveActiveFlightPlan()
    }

    /// Whether the active flight plan has been completed (all waypoints reached)
    var isFlightPlanCompleted: Bool {
        guard let plan = activeFlightPlan else { return false }
        return plan.currentWaypointIndex >= plan.waypoints.count
    }

    /// Go back to the previous waypoint
    func goToPreviousWaypoint() {
        guard var plan = activeFlightPlan else { return }
        guard plan.currentWaypointIndex > 0 else { return }

        plan.currentWaypointIndex -= 1
        activeFlightPlan = plan

        // Update in plans list
        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) {
            flightPlans[index] = plan
        }

        saveFlightPlans()
        saveActiveFlightPlan()
    }

    /// Check if current location is within proximity of next waypoint
    func checkWaypointProximity(currentLocation: CLLocation, threshold: Double) -> Bool {
        guard let plan = activeFlightPlan,
              plan.currentWaypointIndex < plan.waypoints.count else {
            return false
        }

        let nextWaypoint = plan.waypoints[plan.currentWaypointIndex]
        let waypointLocation = CLLocation(
            latitude: nextWaypoint.latitude,
            longitude: nextWaypoint.longitude
        )

        let distance = currentLocation.distance(from: waypointLocation)
        return distance <= threshold
    }

    /// Record ATO for a specific waypoint by index (used for map tap/long-press and GPS proximity)
    func recordATO(forWaypointAt index: Int) {
        guard var plan = activeFlightPlan,
              index >= 0, index < plan.waypoints.count,
              plan.waypoints[index].actualTimeOver == nil else { return }

        plan.waypoints[index].actualTimeOver = Date()

        // If recording ATO for the current waypoint, also advance to next
        var advanced = false
        if index == plan.currentWaypointIndex {
            plan.currentWaypointIndex += 1
            advanced = true
        }

        activeFlightPlan = plan

        if let planIndex = flightPlans.firstIndex(where: { $0.id == plan.id }) {
            flightPlans[planIndex] = plan
        }

        saveFlightPlans()
        saveActiveFlightPlan()

        // Crossing the active waypoint begins a new leg — restart the leg timer (keeps run state). (v4 UI/UX Revamp)
        if advanced { resetChronometer() }
    }

    /// Catch the active plan up with the waypoints already passed, from the track recorded so far.
    ///
    /// The proximity trigger below only ever looks at the CURRENT waypoint, and only within its
    /// radius. That starts at the departure aerodrome, so opening the map once airborne (outside the
    /// radius) left the plan on waypoint 0 for the whole flight, with no ATO anywhere. This records
    /// every passage `WaypointPassage` can establish (at the time it happened, not now) and moves the
    /// current waypoint past the last one. Times already recorded are kept.
    func catchUpWaypointPassages(track: [GPSPoint], takeoff: Date?) {
        guard var plan = activeFlightPlan, plan.currentWaypointIndex < plan.waypoints.count else { return }
        let filled = plan.withActualTimesOver(fromTrack: track, takeoff: takeoff, landing: nil)
        guard let lastPassed = filled.waypoints.lastIndex(where: { $0.actualTimeOver != nil }),
              lastPassed >= plan.currentWaypointIndex else { return }
        for i in 0...lastPassed where plan.waypoints[i].actualTimeOver == nil {
            plan.waypoints[i].actualTimeOver = filled.waypoints[i].actualTimeOver
        }
        plan.currentWaypointIndex = lastPassed + 1
        activeFlightPlan = plan
        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) { flightPlans[index] = plan }
        saveFlightPlans()
        saveActiveFlightPlan()
        resetChronometer()
    }

    /// Auto-advance waypoint if within proximity (records ATO based on GPS position)
    func autoAdvanceWaypointIfNeeded(currentLocation: CLLocation, threshold: Double) {
        if checkWaypointProximity(currentLocation: currentLocation, threshold: threshold) {
            guard let plan = activeFlightPlan else { return }
            recordATO(forWaypointAt: plan.currentWaypointIndex)
        }
    }

    // MARK: - Chronometer

    /// Start — or resume from pause — the leg timer. No-op if already running. (v4 UI/UX Revamp)
    func startChronometer() {
        guard var plan = activeFlightPlan, plan.chronometerStartTime == nil else { return }

        plan.chronometerStartTime = Date()
        activeFlightPlan = plan

        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) {
            flightPlans[index] = plan
        }

        saveActiveFlightPlan()
        startChronometerTimer()
    }

    #if DEBUG
    /// DEBUG (Marketing): start the leg chronometer as if it had already been running for
    /// `elapsedSeconds`, so a screenshot shows a realistic mid-run clock (e.g. 1:37) without waiting.
    /// Back-dates the active plan's start time and seeds the published elapsed value.
    func marketingStartChronometer(elapsedSeconds: TimeInterval) {
        guard var plan = activeFlightPlan else { return }
        chronometerAccumulated = 0
        plan.chronometerStartTime = Date().addingTimeInterval(-elapsedSeconds)
        activeFlightPlan = plan
        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) {
            flightPlans[index] = plan
        }
        saveActiveFlightPlan()
        chronometerElapsed = elapsedSeconds
        startChronometerTimer()
    }
    #endif

    /// Pause the leg timer, freezing the elapsed time (resume with startChronometer). (v4 UI/UX Revamp)
    func pauseChronometer() {
        guard var plan = activeFlightPlan, let start = plan.chronometerStartTime else { return }
        chronometerAccumulated += Date().timeIntervalSince(start)
        plan.chronometerStartTime = nil
        activeFlightPlan = plan

        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) {
            flightPlans[index] = plan
        }

        saveActiveFlightPlan()
        chronometerTimer?.invalidate()
        chronometerTimer = nil
        chronometerElapsed = chronometerAccumulated
    }

    /// Stop the chronometer
    func stopChronometer() {
        chronometerTimer?.invalidate()
        chronometerTimer = nil
    }

    /// Reset the leg timer to zero, keeping the running/paused state. (v4 UI/UX Revamp)
    func resetChronometer() {
        guard var plan = activeFlightPlan else { return }

        chronometerAccumulated = 0
        if plan.chronometerStartTime != nil { plan.chronometerStartTime = Date() }
        activeFlightPlan = plan
        chronometerElapsed = 0

        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) {
            flightPlans[index] = plan
        }

        saveActiveFlightPlan()
    }

    /// The leg timer at one moment, so a MARK or a reset can be taken back. (v6.0 · C2)
    struct LegTimerSnapshot: Equatable {
        let accumulated: TimeInterval
        let startTime: Date?
    }

    var legTimerSnapshot: LegTimerSnapshot? {
        guard let plan = activeFlightPlan else { return nil }
        return LegTimerSnapshot(accumulated: chronometerAccumulated, startTime: plan.chronometerStartTime)
    }

    /// Put the leg timer back as it was, running or paused. A running timer keeps counting from its
    /// original start, so the time spent since is not lost.
    func restoreLegTimer(_ snapshot: LegTimerSnapshot) {
        guard var plan = activeFlightPlan else { return }
        chronometerAccumulated = snapshot.accumulated
        plan.chronometerStartTime = snapshot.startTime
        activeFlightPlan = plan
        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) {
            flightPlans[index] = plan
        }
        saveActiveFlightPlan()
        if snapshot.startTime != nil {
            startChronometerTimer()
        } else {
            chronometerTimer?.invalidate()
            chronometerTimer = nil
        }
        updateChronometerElapsed()
    }

    /// Take back a MARK: the waypoint is the target again, its crossing is forgotten, and the leg
    /// timer reads what it did before. (v6.0 · C2)
    func undoMark(ofWaypointAt index: Int, timer: LegTimerSnapshot) {
        resumeLeg(at: index)
        restoreLegTimer(timer)
    }

    /// Mark the current waypoint as crossed (record ATO + advance, which restarts the leg timer) — the
    /// classic VFR leg-timing action. (v4 UI/UX Revamp)
    func markWaypoint() {
        guard let plan = activeFlightPlan, plan.currentWaypointIndex < plan.waypoints.count else { return }
        recordATO(forWaypointAt: plan.currentWaypointIndex)
    }

    /// Go back to (resume) the leg arriving at `index`: make it the current target again, clear its and
    /// every later crossing (ATO), and restart the leg timer. (v4 UI/UX Revamp — go back a leg)
    func resumeLeg(at index: Int) {
        guard var plan = activeFlightPlan, index >= 0, index < plan.waypoints.count else { return }
        plan.currentWaypointIndex = index
        for i in index..<plan.waypoints.count { plan.waypoints[i].actualTimeOver = nil }
        activeFlightPlan = plan
        if let idx = flightPlans.firstIndex(where: { $0.id == plan.id }) { flightPlans[idx] = plan }
        saveFlightPlans()
        saveActiveFlightPlan()
        resetChronometer()
    }

    private func startChronometerTimer() {
        chronometerTimer?.invalidate()
        chronometerTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateChronometerElapsed()
            }
        }
    }

    private func updateChronometerElapsed() {
        guard let startTime = activeFlightPlan?.chronometerStartTime else {
            chronometerElapsed = chronometerAccumulated  // paused — frozen at the accumulated value
            return
        }
        chronometerElapsed = chronometerAccumulated + Date().timeIntervalSince(startTime)
    }

    private func startChronometerIfNeeded() {
        if activeFlightPlan?.chronometerStartTime != nil {
            startChronometerTimer()
            updateChronometerElapsed()
        }
    }

    /// Formatted chronometer string (MM:SS or HH:MM:SS)
    var formattedChronometer: String {
        let hours = Int(chronometerElapsed) / 3600
        let minutes = (Int(chronometerElapsed) % 3600) / 60
        let seconds = Int(chronometerElapsed) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Navigation Calculations

    /// Calculate distance from current location to next waypoint
    func distanceToNextWaypoint(from location: CLLocation) -> Double? {
        // The navigation TARGET: the next waypoint, or the diversion field. (v5.1)
        guard let target = activeFlightPlan?.navigationTarget else { return nil }
        let waypointLocation = CLLocation(latitude: target.latitude, longitude: target.longitude)

        // Return distance in nautical miles
        return location.distance(from: waypointLocation) / 1852.0
    }

    /// Calculate bearing from current location to next waypoint
    func bearingToNextWaypoint(from location: CLLocation) -> Double? {
        guard let target = activeFlightPlan?.navigationTarget else { return nil }
        return location.coordinate.bearing(to: target.coordinate)
    }

    /// Calculate ETA to next waypoint based on current ground speed
    func etaToNextWaypoint(from location: CLLocation, groundSpeedKnots: Double) -> TimeInterval? {
        guard let distance = distanceToNextWaypoint(from: location),
              groundSpeedKnots > 0 else {
            return nil
        }

        // Time = Distance / Speed (in hours), convert to seconds
        return (distance / groundSpeedKnots) * 3600
    }

    // MARK: - Import/Export

    /// Import a flight plan from data
    func importFlightPlan(from data: Data) -> FlightPlan? {
        // Try JSON first
        if let plan = FlightPlan.fromJSON(data) {
            var importedPlan = plan
            importedPlan.isActive = false
            importedPlan.currentWaypointIndex = 0
            flightPlans.insert(importedPlan, at: 0)
            saveFlightPlans()
            return importedPlan
        }

        // Try GPX
        if let plan = FlightPlan.fromGPX(data) {
            var importedPlan = plan
            importedPlan.isActive = false
            importedPlan.currentWaypointIndex = 0
            flightPlans.insert(importedPlan, at: 0)
            saveFlightPlans()
            return importedPlan
        }

        return nil
    }

    /// Name of the waypoint currently being flown to on the active plan, or nil when there is no
    /// active plan / the route is complete. Surfaces on the Live Activity. (UX-25)
    var activeNextWaypointName: String? {
        activeFlightPlan?.navigationTarget?.name
    }

    // MARK: - Divert, resume, direct to (v5.1)

    /// Go to `field` instead of the rest of the route. One decision, nothing else: the route stays as
    /// planned (so `resumeRoute` is one tap and the nav log shows what was planned), no task, reminder
    /// or thread changes. Everything administrative waits for the ground.
    func divert(to field: TripPlanner.Aerodrome, now: Date = Date()) {
        guard var plan = activeFlightPlan else { return }
        plan.diversion = Diversion(ident: field.ident, name: field.name,
                                   latitude: field.latitude, longitude: field.longitude,
                                   elevationFeet: field.elevationFeet, frequency: field.frequency,
                                   startedAt: now, leftRouteAt: plan.currentWaypointIndex)
        commitActive(plan)
        resetChronometer()
    }

    /// Back onto the route after a diversion, at the waypoint that was next when the aircraft left it.
    /// Passages recorded meanwhile (route waypoints overflown on the way) are kept.
    func resumeRoute() {
        guard var plan = activeFlightPlan, plan.diversion != nil else { return }
        plan.diversion = nil
        commitActive(plan)
        resetChronometer()
    }

    /// Fly straight to a later waypoint of the route. The ones skipped keep no ATO: they were not
    /// flown. Also ends a diversion, since the target is the route again.
    func directTo(waypointAt index: Int) {
        guard var plan = activeFlightPlan, plan.waypoints.indices.contains(index) else { return }
        plan.currentWaypointIndex = index
        plan.diversion = nil
        commitActive(plan)
        resetChronometer()
    }

    /// Write an edited active plan back everywhere it lives.
    private func commitActive(_ plan: FlightPlan) {
        activeFlightPlan = plan
        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) { flightPlans[index] = plan }
        saveFlightPlans()
        saveActiveFlightPlan()
    }

    // MARK: - Persistence

    /// Each plan's content as last persisted (its encoding), for dirty detection. Keyed by id;
    /// entries are removed on plan deletion.
    ///
    /// NOT the plan itself: `FlightPlan ==` compares ids only, so a dirty check built on it saw every
    /// edit to an already-saved plan as "unchanged" and never wrote it again. The edit lived in memory
    /// until the next launch, then the file on disk won: a whole "Set altitudes" pass came back undone.
    private var lastPersisted: [UUID: Data] = [:]

    /// The plan's content, for comparing against what was persisted.
    nonisolated static func fingerprint(_ plan: FlightPlan) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(plan)
    }

    /// Plans whose content differs from what was last written (or that were never written).
    nonisolated static func plansNeedingSave(_ plans: [FlightPlan], lastPersisted: [UUID: Data]) -> [FlightPlan] {
        plans.filter { plan in
            guard let saved = lastPersisted[plan.id] else { return true }
            return fingerprint(plan) != saved
        }
    }

    /// Persists only the plans that actually changed since the last save (plus the index), off the
    /// main actor. Previously this rewrote EVERY plan file synchronously on the main thread — and it
    /// is called on every waypoint edit and every ATO record/auto-advance during a flight. (PERF-25)
    private func saveFlightPlans() {
        let changed = Self.plansNeedingSave(flightPlans, lastPersisted: lastPersisted)
        guard !changed.isEmpty else { return }
        let all = flightPlans
        Task { [weak self] in
            let written = await self?.persistence.saveNavigationPlansOffMain(changed: changed, all: all) ?? []
            // RES-01: mark plans persisted only once their file is CONFIRMED written. This used to
            // run synchronously before the write was even attempted, so a failed write left the
            // plan looking clean — the next save saw no diff, skipped it, and the edit was dropped
            // permanently with nothing logged. Marking on confirmation makes a failure self-heal:
            // the plan stays dirty and the very next saveFlightPlans() retries it.
            guard let self else { return }
            let confirmed = Set(written)
            for plan in changed where confirmed.contains(plan.id) {
                self.lastPersisted[plan.id] = Self.fingerprint(plan)
            }
        }
    }

    /// Save a single flight plan
    private func saveFlightPlan(_ plan: FlightPlan) {
        lastPersisted[plan.id] = Self.fingerprint(plan)
        persistence.saveNavigationPlan(plan)
    }

    private func loadFlightPlansAsync() async {
        defer { hasLoadedPlans = true }
        let loaded = await persistence.loadNavigationPlansOffMain()
        // The async load can finish long after launch (an iCloud download on a slow network).
        // Plans created/edited in the meantime win by id; loaded plans only fill the gaps.
        let existingIds = Set(flightPlans.map(\.id))
        let merged = flightPlans + loaded.filter { !existingIds.contains($0.id) }
        flightPlans = merged.sorted { $0.createdAt > $1.createdAt }
        for plan in loaded where lastPersisted[plan.id] == nil {
            lastPersisted[plan.id] = Self.fingerprint(plan)
        }
    }

    /// Delete a flight plan file
    private func deleteFlightPlanFile(_ plan: FlightPlan) {
        lastPersisted[plan.id] = nil
        persistence.deleteNavigationPlan(plan)
    }

    private func saveActiveFlightPlan() {
        guard let plan = activeFlightPlan else {
            clearActiveFlightPlan()
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(plan)
            defaults.set(data, forKey: activeFlightPlanKey)
        } catch {
            AppLog.general.debugLine("Failed to save active flight plan: \(error.localizedDescription)")
        }
    }

    private func loadActiveFlightPlan() {
        guard let data = defaults.data(forKey: activeFlightPlanKey) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            activeFlightPlan = try decoder.decode(FlightPlan.self, from: data)
        } catch {
            AppLog.general.debugLine("Failed to load active flight plan: \(error.localizedDescription)")
        }
    }

    private func clearActiveFlightPlan() {
        defaults.removeObject(forKey: activeFlightPlanKey)
    }
}
