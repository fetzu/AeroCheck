import Foundation
import WatchConnectivity
import CoreLocation

/// Manages Watch Connectivity between the iOS app and the Apple Watch companion app
@MainActor
class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    private var session: WCSession?
    private var updateTimer: Timer?
    /// Whether the app has asked for periodic updates (via `startUpdates`/`notifyFlightStarted`) and
    /// hasn't since called `stopUpdates`. Kept separate from `updateTimer` so a pairing/install change
    /// mid-flight (`sessionWatchStateDidChange`) knows whether it should (re)arm the timer. (WATCH-01)
    private var wantsUpdates = false

    /// True only when there's an actual Watch to talk to — paired AND with the companion app installed.
    /// Guards the 1 Hz timer so it never runs for a flight with no Watch in the picture. (WATCH-01)
    private var isWatchAvailable: Bool {
        guard let session = session else { return false }
        return session.isPaired && session.isWatchAppInstalled
    }

    // Held weakly so a Watch command (e.g. chronometer control) can act on live state + echo back.
    private weak var appStateRef: AppState?
    private weak var locationManagerRef: LocationManager?
    private weak var flightPlanManagerRef: FlightPlanManager?

    /// The nav-map FREQ panel's current list, pushed by NavigationView so the watch mirrors it exactly.
    private var panelFrequencies: [FrequencyInfo]?

    /// Called by NavigationView whenever it recomputes its FREQ panel. (Watch freq sync)
    func updatePanelFrequencies(_ frequencies: [FrequencyInfo]) {
        panelFrequencies = frequencies
    }

    private override init() {
        super.init()
        setupSession()
    }

    // MARK: - Setup

    private func setupSession() {
        guard WCSession.isSupported() else {
            AppLog.watch.debugLine("WatchConnectivity not supported on this device")
            return
        }

        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }

    // MARK: - Public Methods

    /// Start sending periodic updates to the Watch. No-ops the timer when there's no paired/installed
    /// Watch to receive them — `sessionWatchStateDidChange` arms it later if one pairs mid-flight. (WATCH-01)
    func startUpdates(appState: AppState, locationManager: LocationManager, flightPlanManager: FlightPlanManager) {
        stopUpdates()
        appStateRef = appState
        locationManagerRef = locationManager
        flightPlanManagerRef = flightPlanManager
        wantsUpdates = true

        guard isWatchAvailable else {
            AppLog.watch.debugLine("No paired/installed Watch — skipping periodic updates")
            return
        }

        armUpdateTimer()
    }

    /// Stop sending updates to the Watch
    func stopUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
        wantsUpdates = false
    }

    /// Sends the initial update and arms the 1 Hz timer. Only called once a Watch is actually available
    /// (either at `startUpdates` time, or later via `sessionWatchStateDidChange`). (WATCH-01)
    private func armUpdateTimer() {
        guard let appState = appStateRef, let locationManager = locationManagerRef,
              let flightPlanManager = flightPlanManagerRef else { return }

        // Send initial update immediately
        sendFlightData(appState: appState, locationManager: locationManager, flightPlanManager: flightPlanManager)

        // Start periodic updates (every 1 second for real-time data)
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let a = self.appStateRef, let l = self.locationManagerRef,
                      let f = self.flightPlanManagerRef else { return }
                self.sendFlightData(appState: a, locationManager: l, flightPlanManager: f)
            }
        }
    }

    /// Re-evaluate whether the timer should be running after the Watch's paired/installed state
    /// changes mid-session, without disturbing a flight that never asked for updates. (WATCH-01)
    @MainActor
    private func handleWatchAvailabilityChange() {
        guard wantsUpdates else { return }
        if isWatchAvailable {
            if updateTimer == nil { armUpdateTimer() }
        } else {
            updateTimer?.invalidate()
            updateTimer = nil
        }
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
            AppLog.watch.debugLine("Failed to encode flight data")
            return
        }

        let message: [String: Any] = [
            WatchConnectivityKeys.messageType: WatchMessage.flightStarted.rawValue,
            WatchConnectivityKeys.flightData: encodedData,
            WatchConnectivityKeys.timestamp: Date().timeIntervalSince1970
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            AppLog.watch.debugLine("Failed to send flight started message: \(error.localizedDescription)")
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
                AppLog.watch.debugLine("Failed to update context: \(error.localizedDescription)")
            }
            return
        }

        let message: [String: Any] = [
            WatchConnectivityKeys.messageType: WatchMessage.flightEnded.rawValue,
            WatchConnectivityKeys.timestamp: Date().timeIntervalSince1970
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            AppLog.watch.debugLine("Failed to send flight ended message: \(error.localizedDescription)")
        }

        // SEC-C38: ALSO clear the persisted application context, not just send a live message.
        // Previously only the unreachable branch did this, so ending a flight while the watch was
        // reachable left a stale isFlightActive=true context behind — which the watch replays on
        // its next launch, showing a finished flight as live.
        var noFlightData = WatchFlightData()
        noFlightData.isFlightActive = false
        if let encodedData = try? JSONEncoder().encode(noFlightData) {
            do {
                try session.updateApplicationContext([
                    WatchConnectivityKeys.flightData: encodedData,
                    WatchConnectivityKeys.timestamp: Date().timeIntervalSince1970
                ])
            } catch {
                AppLog.watch.debugLine("Failed to clear context: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private Methods

    private func sendFlightData(appState: AppState, locationManager: LocationManager, flightPlanManager: FlightPlanManager) {
        // No paired/installed Watch to receive this — short-circuit instead of building + encoding the
        // payload for nobody. (WATCH-01)
        guard let session = session, isWatchAvailable else { return }

        let flightData = createFlightData(appState: appState, locationManager: locationManager, flightPlanManager: flightPlanManager)

        guard let encodedData = try? JSONEncoder().encode(flightData) else {
            AppLog.watch.debugLine("Failed to encode flight data")
            return
        }

        // Always stage the latest snapshot in the application context, so a watch resuming from the
        // background (wrist-raise) reads the freshest state immediately rather than a stale one. The OS
        // coalesces these and delivers only the most recent, so calling it each tick is fine. (sync freshness)
        try? session.updateApplicationContext([
            WatchConnectivityKeys.flightData: encodedData,
            WatchConnectivityKeys.timestamp: Date().timeIntervalSince1970
        ])

        // When the watch is reachable (both apps active), also push live for ~instant updates.
        if session.isReachable {
            let message: [String: Any] = [
                WatchConnectivityKeys.messageType: WatchMessage.dataUpdate.rawValue,
                WatchConnectivityKeys.flightData: encodedData,
                WatchConnectivityKeys.timestamp: Date().timeIntervalSince1970
            ]
            session.sendMessage(message, replyHandler: nil) { _ in
                // Silently fail for periodic updates — the staged context covers it.
            }
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
            AppLog.watch.debugLine("Failed to update application context: \(error.localizedDescription)")
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

        // Next phase — use the canonical navigable-phase helper so it steps over EVERY consecutive
        // circuit-skipped phase. The old +1/+2 math only skipped one, so at CLIMB in circuit mode it
        // landed on DESCENT (itself skipped) instead of APPROACH. nil at the last phase, as before.
        data.nextPhaseName = appState.currentPhase.nextNavigable(circuitMode: appState.isCircuitMode)?.shortTitle

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

        // Chronometer (flight-plan leg timer) — sent every update so the watch mirrors the phone.
        data.chronometerElapsed = flightPlanManager.chronometerElapsed
        data.chronometerRunning = flightPlanManager.isChronometerRunning

        // The nav-map FREQ panel's list (NOW/NEXT + order), if NavigationView has pushed one.
        data.panelFrequencies = panelFrequencies

        return data
    }

    /// Swiss common frequencies for the Watch's fallback list, derived from the canonical
    /// `SwissCommonFrequency` source the phone's FREQ panel uses.
    ///
    /// These used to be hand-written literals, and two of them had drifted from the canonical
    /// values: the Watch showed FIS East 124.150 and FIS West 126.600 where the iPad showed
    /// 125.225 and 119.175 for the same sectors. A pilot reading the Watch would have tuned a
    /// frequency the app's own data says is not that FIS sector. Deriving them removes both the
    /// divergence and the ability for it to recur.
    ///
    /// The display order is stated explicitly rather than using `allCases`, because it is not the
    /// enum's declaration order and the Watch renders only the first four entries — reordering
    /// here would silently change which frequencies a pilot sees.
    private func getCommonFrequencies() -> [FrequencyInfo] {
        let ordered: [SwissCommonFrequency] = [
            .genevaInfo, .zurichInfo, .fisEast, .fisWest, .emergency,
        ]
        return ordered.map { freq in
            FrequencyInfo(
                name: freq.name,
                frequency: freq.frequency,
                type: freq == .emergency ? .common : .info
            )
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            AppLog.watch.debugLine("Session activation failed: \(error.localizedDescription)")
            return
        }

        AppLog.watch.debugLine("Session activated - Paired: \(session.isPaired), Installed: \(session.isWatchAppInstalled)")
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        AppLog.watch.debugLine("Session became inactive")
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        AppLog.watch.debugLine("Session deactivated")
        // Reactivate the session
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        AppLog.watch.debugLine("Reachability changed: \(session.isReachable)")
    }

    /// Fires when pairing/installation state changes (e.g. the Watch pairs or the companion app gets
    /// installed/removed) mid-session. Delegate callbacks land on a background queue, so hop to the
    /// MainActor — same pattern as `didReceiveMessage` below — before touching timer/actor state. (WATCH-01)
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        AppLog.watch.debugLine("Watch state changed - Paired: \(session.isPaired), Installed: \(session.isWatchAppInstalled)")
        Task { @MainActor in self.handleWatchAvailabilityChange() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let raw = message[WatchConnectivityKeys.command] as? String, let command = WatchCommand(rawValue: raw) {
            Task { @MainActor in self.handleWatchCommand(command) }
        }
    }

    /// Act on a chronometer command from the Watch, then immediately echo the updated state back so the
    /// watch reflects it without waiting for the next periodic tick.
    @MainActor
    private func handleWatchCommand(_ command: WatchCommand) {
        guard let fpm = flightPlanManagerRef else { return }
        switch command {
        case .chronoToggle:
            fpm.isChronometerRunning ? fpm.pauseChronometer() : fpm.startChronometer()
        case .chronoReset:
            fpm.resetChronometer()
        case .chronoMark:
            fpm.markWaypoint()
        }
        if let app = appStateRef, let loc = locationManagerRef {
            sendFlightData(appState: app, locationManager: loc, flightPlanManager: fpm)
        }
    }
}
