import Foundation
import WatchConnectivity
import CoreLocation

/// Manages Watch Connectivity between the iOS app and the Apple Watch companion app
@MainActor
class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var isWatchReachable: Bool = false
    @Published var isWatchPaired: Bool = false
    @Published var isWatchAppInstalled: Bool = false

    private var session: WCSession?
    private var updateTimer: Timer?

    private override init() {
        super.init()
        setupSession()
    }

    // MARK: - Setup

    private func setupSession() {
        guard WCSession.isSupported() else {
            print("[AéroCheck Watch] WatchConnectivity not supported on this device")
            return
        }

        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }

    // MARK: - Public Methods

    /// Start sending periodic updates to the Watch
    func startUpdates(appState: AppState, locationManager: LocationManager, flightPlanManager: FlightPlanManager) {
        stopUpdates()

        // Send initial update immediately
        sendFlightData(appState: appState, locationManager: locationManager, flightPlanManager: flightPlanManager)

        // Start periodic updates (every 1 second for real-time data)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendFlightData(appState: appState, locationManager: locationManager, flightPlanManager: flightPlanManager)
            }
        }
    }

    /// Stop sending updates to the Watch
    func stopUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    /// Notify Watch that a flight has started (triggers Watch app launch)
    func notifyFlightStarted(appState: AppState, locationManager: LocationManager, flightPlanManager: FlightPlanManager) {
        guard let session = session, session.isReachable else {
            // If not reachable, try to update application context instead
            updateApplicationContext(appState: appState, locationManager: locationManager, flightPlanManager: flightPlanManager)
            return
        }

        let flightData = createFlightData(appState: appState, locationManager: locationManager, flightPlanManager: flightPlanManager)

        guard let encodedData = try? JSONEncoder().encode(flightData) else {
            print("[AéroCheck Watch] Failed to encode flight data")
            return
        }

        let message: [String: Any] = [
            WatchConnectivityKeys.messageType: WatchMessage.flightStarted.rawValue,
            WatchConnectivityKeys.flightData: encodedData,
            WatchConnectivityKeys.timestamp: Date().timeIntervalSince1970
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            print("[AéroCheck Watch] Failed to send flight started message: \(error.localizedDescription)")
        }

        // Start periodic updates
        startUpdates(appState: appState, locationManager: locationManager, flightPlanManager: flightPlanManager)
    }

    /// Notify Watch that a flight has ended
    func notifyFlightEnded() {
        stopUpdates()

        guard let session = session, session.isReachable else {
            // Update application context to reflect no active flight
            var noFlightData = WatchFlightData()
            noFlightData.isFlightActive = false

            guard let encodedData = try? JSONEncoder().encode(noFlightData) else { return }

            do {
                try session?.updateApplicationContext([
                    WatchConnectivityKeys.flightData: encodedData,
                    WatchConnectivityKeys.timestamp: Date().timeIntervalSince1970
                ])
            } catch {
                print("[AéroCheck Watch] Failed to update context: \(error.localizedDescription)")
            }
            return
        }

        let message: [String: Any] = [
            WatchConnectivityKeys.messageType: WatchMessage.flightEnded.rawValue,
            WatchConnectivityKeys.timestamp: Date().timeIntervalSince1970
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            print("[AéroCheck Watch] Failed to send flight ended message: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Methods

    private func sendFlightData(appState: AppState, locationManager: LocationManager, flightPlanManager: FlightPlanManager) {
        guard let session = session else { return }

        let flightData = createFlightData(appState: appState, locationManager: locationManager, flightPlanManager: flightPlanManager)

        guard let encodedData = try? JSONEncoder().encode(flightData) else {
            print("[AéroCheck Watch] Failed to encode flight data")
            return
        }

        if session.isReachable {
            // Send as message for real-time updates
            let message: [String: Any] = [
                WatchConnectivityKeys.messageType: WatchMessage.dataUpdate.rawValue,
                WatchConnectivityKeys.flightData: encodedData,
                WatchConnectivityKeys.timestamp: Date().timeIntervalSince1970
            ]

            session.sendMessage(message, replyHandler: nil) { error in
                // Silently fail for periodic updates
            }
        } else {
            // Fall back to application context
            updateApplicationContext(appState: appState, locationManager: locationManager, flightPlanManager: flightPlanManager)
        }
    }

    private func updateApplicationContext(appState: AppState, locationManager: LocationManager, flightPlanManager: FlightPlanManager) {
        let flightData = createFlightData(appState: appState, locationManager: locationManager, flightPlanManager: flightPlanManager)

        guard let encodedData = try? JSONEncoder().encode(flightData) else { return }

        do {
            try session?.updateApplicationContext([
                WatchConnectivityKeys.flightData: encodedData,
                WatchConnectivityKeys.timestamp: Date().timeIntervalSince1970
            ])
        } catch {
            print("[AéroCheck Watch] Failed to update application context: \(error.localizedDescription)")
        }
    }

    private func createFlightData(appState: AppState, locationManager: LocationManager, flightPlanManager: FlightPlanManager) -> WatchFlightData {
        var data = WatchFlightData()

        // Flight status
        data.isFlightActive = appState.isFlightActive
        data.isCircuitMode = appState.isCircuitMode

        // Current phase
        data.currentPhaseRawValue = appState.currentPhase.rawValue
        data.currentPhaseName = appState.currentPhase.shortTitle

        // Next phase
        if let nextPhaseIndex = ChecklistPhase.allCases.firstIndex(of: appState.currentPhase),
           nextPhaseIndex + 1 < ChecklistPhase.allCases.count {
            let nextPhase = ChecklistPhase.allCases[nextPhaseIndex + 1]
            // Skip CRUISE and DESCENT in circuit mode
            if appState.isCircuitMode && (nextPhase == .cruise || nextPhase == .descent) {
                if nextPhaseIndex + 2 < ChecklistPhase.allCases.count {
                    data.nextPhaseName = ChecklistPhase.allCases[nextPhaseIndex + 2].shortTitle
                }
            } else {
                data.nextPhaseName = nextPhase.shortTitle
            }
        }

        // Timing
        data.lineUpTime = appState.lineUpTime
        data.landingTime = appState.landingTime

        // Settings
        data.alwaysUseUTC = appState.settings.alwaysUseUTC

        // GPS data
        if let location = locationManager.currentLocation {
            data.speedMPS = location.speed >= 0 ? location.speed : nil
            data.altitudeFeet = location.altitude * 3.28084 // Convert meters to feet
            data.course = location.course >= 0 ? location.course : nil
        }

        // Navigation plan
        if let activePlan = flightPlanManager.activeFlightPlan {
            data.hasActiveNavPlan = true
            data.currentWaypointIndex = activePlan.currentWaypointIndex
            data.totalWaypoints = activePlan.waypoints.count

            if let nextWaypoint = activePlan.nextWaypoint {
                data.currentWaypointName = nextWaypoint.name
                data.currentWaypointFrequency = nextWaypoint.frequency

                // Calculate distance and bearing
                if let location = locationManager.currentLocation {
                    data.distanceToWaypointNM = flightPlanManager.distanceToNextWaypoint(from: location)
                    data.bearingToWaypoint = flightPlanManager.bearingToNextWaypoint(from: location)

                    // Calculate EET
                    let groundSpeedKnots = (location.speed >= 0 ? location.speed : 0) * 1.94384
                    if let eta = flightPlanManager.etaToNextWaypoint(from: location, groundSpeedKnots: groundSpeedKnots) {
                        data.eetToWaypointSeconds = eta
                    }
                }
            }

            // Next waypoint frequency (waypoint after current)
            if activePlan.currentWaypointIndex + 1 < activePlan.waypoints.count {
                data.nextWaypointFrequency = activePlan.waypoints[activePlan.currentWaypointIndex + 1].frequency
            }

            // Common frequencies
            data.commonFrequencies = getCommonFrequencies()
        } else {
            data.hasActiveNavPlan = false
        }

        return data
    }

    private func getCommonFrequencies() -> [FrequencyInfo] {
        // Swiss common frequencies for aviation
        var frequencies: [FrequencyInfo] = []

        frequencies.append(FrequencyInfo(
            name: "Geneva Info",
            frequency: "126.350",
            type: .info
        ))

        frequencies.append(FrequencyInfo(
            name: "Zurich Info",
            frequency: "124.700",
            type: .info
        ))

        frequencies.append(FrequencyInfo(
            name: "FIS East",
            frequency: "124.150",
            type: .info
        ))

        frequencies.append(FrequencyInfo(
            name: "FIS West",
            frequency: "126.600",
            type: .info
        ))

        frequencies.append(FrequencyInfo(
            name: "Emergency",
            frequency: "121.500",
            type: .common
        ))

        return frequencies
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("[AéroCheck Watch] Session activation failed: \(error.localizedDescription)")
            return
        }

        Task { @MainActor in
            self.isWatchPaired = session.isPaired
            self.isWatchAppInstalled = session.isWatchAppInstalled
            self.isWatchReachable = session.isReachable
            print("[AéroCheck Watch] Session activated - Paired: \(session.isPaired), Installed: \(session.isWatchAppInstalled)")
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        print("[AéroCheck Watch] Session became inactive")
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        print("[AéroCheck Watch] Session deactivated")
        // Reactivate the session
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isWatchReachable = session.isReachable
            print("[AéroCheck Watch] Reachability changed: \(session.isReachable)")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // Handle messages from Watch if needed
        print("[AéroCheck Watch] Received message from Watch: \(message)")
    }
}
