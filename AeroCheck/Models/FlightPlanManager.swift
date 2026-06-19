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
    /// Elapsed accumulated from completed run segments, so pause/resume preserves the leg time. (v4 UI/UX Revamp)
    private var chronometerAccumulated: TimeInterval = 0

    /// True while the leg timer is actively counting (pause clears the plan's start time). (v4 UI/UX Revamp)
    var isChronometerRunning: Bool { activeFlightPlan?.chronometerStartTime != nil }

    // MARK: - Private Properties

    private let activeFlightPlanKey = "activeFlightPlan"
    private var chronometerTimer: Timer?
    private let persistence = DataPersistenceManager.shared

    // MARK: - Initialization

    init() {
        loadFlightPlans()
        loadActiveFlightPlan()
        startChronometerIfNeeded()
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
        plan.calculateRouteData()
        updateFlightPlan(plan)
    }

    /// Populate flight plan timing fields from a completed flight's data
    /// - Parameters:
    ///   - planId: The ID of the flight plan to update
    ///   - flight: The completed flight with timing data
    func populateTimingFromFlight(_ planId: UUID, flight: Flight) {
        guard var plan = flightPlans.first(where: { $0.id == planId }) else { return }

        // Time ON = Engine started (engine on)
        if plan.timeOn == nil, let engineStart = flight.engineStartTime {
            plan.timeOn = engineStart
        }

        // Time OFF = Engine shutdown (engine off)
        if plan.timeOff == nil, let engineShutdown = flight.engineShutdownTime {
            plan.timeOff = engineShutdown
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
        guard let plan = activeFlightPlan,
              plan.currentWaypointIndex < plan.waypoints.count else {
            return nil
        }

        let nextWaypoint = plan.waypoints[plan.currentWaypointIndex]
        let waypointLocation = CLLocation(
            latitude: nextWaypoint.latitude,
            longitude: nextWaypoint.longitude
        )

        // Return distance in nautical miles
        return location.distance(from: waypointLocation) / 1852.0
    }

    /// Calculate bearing from current location to next waypoint
    func bearingToNextWaypoint(from location: CLLocation) -> Double? {
        guard let plan = activeFlightPlan,
              plan.currentWaypointIndex < plan.waypoints.count else {
            return nil
        }

        let nextWaypoint = plan.waypoints[plan.currentWaypointIndex]
        return location.coordinate.bearing(
            to: CLLocationCoordinate2D(latitude: nextWaypoint.latitude, longitude: nextWaypoint.longitude)
        )
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

    // MARK: - Persistence

    private func saveFlightPlans() {
        // Save all plans to individual files in iCloud
        persistence.saveNavigationPlans(flightPlans)
    }

    /// Save a single flight plan
    private func saveFlightPlan(_ plan: FlightPlan) {
        persistence.saveNavigationPlan(plan)
    }

    private func loadFlightPlans() {
        flightPlans = persistence.loadNavigationPlans()
    }

    /// Delete a flight plan file
    private func deleteFlightPlanFile(_ plan: FlightPlan) {
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
            UserDefaults.standard.set(data, forKey: activeFlightPlanKey)
        } catch {
            print("[AéroCheck] Failed to save active flight plan: \(error.localizedDescription)")
        }
    }

    private func loadActiveFlightPlan() {
        guard let data = UserDefaults.standard.data(forKey: activeFlightPlanKey) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            activeFlightPlan = try decoder.decode(FlightPlan.self, from: data)
        } catch {
            print("[AéroCheck] Failed to load active flight plan: \(error.localizedDescription)")
        }
    }

    private func clearActiveFlightPlan() {
        UserDefaults.standard.removeObject(forKey: activeFlightPlanKey)
    }
}
