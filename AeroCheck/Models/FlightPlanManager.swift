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

    // MARK: - Private Properties

    private let flightPlansKey = "savedFlightPlans"
    private let activeFlightPlanKey = "activeFlightPlan"
    private var chronometerTimer: Timer?

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
        aircraftType: AircraftType = .wt9Dynamic
    ) -> FlightPlan {
        var plan = FlightPlan(
            name: name,
            aircraftType: aircraftType,
            fuelFlow: FlightPlan.defaultFuelFlow(for: aircraftType)
        )
        plan.aircraftRegistration = aircraftType.registration
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

        saveFlightPlans()
    }

    /// Delete flight plans at offsets
    func deleteFlightPlans(at offsets: IndexSet) {
        for index in offsets {
            if flightPlans[index].id == activeFlightPlan?.id {
                deactivateFlightPlan()
            }
        }
        flightPlans.remove(atOffsets: offsets)
        saveFlightPlans()
    }

    /// Duplicate a flight plan
    func duplicateFlightPlan(_ plan: FlightPlan) -> FlightPlan {
        var newPlan = plan
        newPlan = FlightPlan(
            name: "\(plan.name) (Copy)",
            waypoints: plan.waypoints,
            aircraftType: plan.aircraftType,
            aircraftRegistration: plan.aircraftRegistration,
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
            plannedGroundSpeed: FlightPlan.defaultCruiseSpeed(for: plan.aircraftType)
        )

        plan.waypoints.append(waypoint)
        plan.calculateRouteData()
        updateFlightPlan(plan)
    }

    /// Insert a waypoint at a specific index
    func insertWaypoint(to planId: UUID, at index: Int, coordinate: CLLocationCoordinate2D, name: String = "") {
        guard var plan = flightPlans.first(where: { $0.id == planId }) else { return }

        let waypoint = FlightPlanWaypoint(
            name: name.isEmpty ? "WPT" : name,
            coordinate: coordinate,
            plannedGroundSpeed: FlightPlan.defaultCruiseSpeed(for: plan.aircraftType)
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

        plan.waypoints.removeAll { $0.id == waypoint.id }
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

        // Time OFF = Line up time (expected takeoff time)
        if plan.timeOff == nil, let lineUpTime = flight.lineUpTime {
            plan.timeOff = lineUpTime
        }

        // Time ON = Landing time
        if plan.timeOn == nil, let landingTime = flight.landingTime {
            plan.timeOn = landingTime
        }

        // Block OFF = First GPS point with movement after engine start
        // Looking for speed > 2 knots (about 1 m/s) to detect taxi start
        if plan.blockOff == nil, let engineStart = flight.engineStartTime {
            let movementThreshold: Double = 1.0 // m/s (about 2 knots)
            if let firstMovement = flight.gpsTrack.first(where: {
                $0.timestamp > engineStart && $0.speed > movementThreshold
            }) {
                plan.blockOff = firstMovement.timestamp
            }
        }

        // Block ON = Engine shutdown time (when plane stops moving)
        // If we have GPS data, use last point with movement before shutdown
        if plan.blockOn == nil {
            if let engineShutdown = flight.engineShutdownTime {
                plan.blockOn = engineShutdown
            } else if let stopTime = flight.stopTime {
                plan.blockOn = stopTime
            }
        }

        // Total landings from flight
        if plan.totalLandings == nil || plan.totalLandings == 0 {
            plan.totalLandings = flight.totalLandings
        }

        updateFlightPlan(plan)
    }

    /// Advance to the next waypoint
    func advanceToNextWaypoint() {
        guard var plan = activeFlightPlan else { return }
        guard plan.currentWaypointIndex < plan.waypoints.count else { return }

        // Record ATO for current waypoint
        plan.waypoints[plan.currentWaypointIndex].actualTimeOver = Date()
        plan.currentWaypointIndex += 1

        activeFlightPlan = plan

        // Update in plans list
        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) {
            flightPlans[index] = plan
        }

        saveFlightPlans()
        saveActiveFlightPlan()
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

    /// Auto-advance waypoint if within proximity
    func autoAdvanceWaypointIfNeeded(currentLocation: CLLocation, threshold: Double) {
        if checkWaypointProximity(currentLocation: currentLocation, threshold: threshold) {
            advanceToNextWaypoint()
        }
    }

    // MARK: - Chronometer

    /// Start the chronometer
    func startChronometer() {
        guard var plan = activeFlightPlan else { return }

        plan.chronometerStartTime = Date()
        activeFlightPlan = plan

        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) {
            flightPlans[index] = plan
        }

        saveActiveFlightPlan()
        startChronometerTimer()
    }

    /// Stop the chronometer
    func stopChronometer() {
        chronometerTimer?.invalidate()
        chronometerTimer = nil
    }

    /// Reset the chronometer to zero
    func resetChronometer() {
        guard var plan = activeFlightPlan else { return }

        plan.chronometerStartTime = Date()
        activeFlightPlan = plan
        chronometerElapsed = 0

        if let index = flightPlans.firstIndex(where: { $0.id == plan.id }) {
            flightPlans[index] = plan
        }

        saveActiveFlightPlan()
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
            chronometerElapsed = 0
            return
        }
        chronometerElapsed = Date().timeIntervalSince(startTime)
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
        return calculateBearing(
            from: location.coordinate,
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

    private func calculateBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        var bearing = atan2(y, x) * 180 / .pi
        bearing = (bearing + 360).truncatingRemainder(dividingBy: 360)

        return bearing
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
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(flightPlans)
            UserDefaults.standard.set(data, forKey: flightPlansKey)
        } catch {
            print("[AeroCheck] Failed to save flight plans: \(error.localizedDescription)")
        }
    }

    private func loadFlightPlans() {
        guard let data = UserDefaults.standard.data(forKey: flightPlansKey) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            flightPlans = try decoder.decode([FlightPlan].self, from: data)
        } catch {
            print("[AeroCheck] Failed to load flight plans: \(error.localizedDescription)")
        }
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
            print("[AeroCheck] Failed to save active flight plan: \(error.localizedDescription)")
        }
    }

    private func loadActiveFlightPlan() {
        guard let data = UserDefaults.standard.data(forKey: activeFlightPlanKey) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            activeFlightPlan = try decoder.decode(FlightPlan.self, from: data)
        } catch {
            print("[AeroCheck] Failed to load active flight plan: \(error.localizedDescription)")
        }
    }

    private func clearActiveFlightPlan() {
        UserDefaults.standard.removeObject(forKey: activeFlightPlanKey)
    }
}
