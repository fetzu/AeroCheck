import Combine
import Foundation
import WatchConnectivity

/// Watch-side connectivity manager for receiving data from iPhone
@MainActor
class WatchConnectivityManager: NSObject, ObservableObject {
    @Published var flightData: WatchFlightData = WatchFlightData()
    @Published var isConnected: Bool = false
    @Published var lastUpdateTime: Date?

    private var session: WCSession?

    override init() {
        super.init()
        setupSession()
    }

    private func setupSession() {
        guard WCSession.isSupported() else {
            print("[AéroCheck Watch] WatchConnectivity not supported")
            return
        }

        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }

    /// Format time according to UTC setting
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        if flightData.alwaysUseUTC {
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: date) + "Z"
        }
        return formatter.string(from: date)
    }

    /// Get current time formatted according to settings
    func getCurrentTimeString() -> String {
        formatTime(Date())
    }

    /// Live data is considered stale after this long without an update from the phone. (UX-05)
    let staleThresholdSeconds: TimeInterval = 5.0

    /// True when an active flight's live data hasn't refreshed within the stale window, so the
    /// UI should dim the frozen values and show a clear STALE indication rather than imply live.
    func isDataStale(asOf now: Date = Date()) -> Bool {
        guard flightData.isFlightActive else { return false }
        guard let last = lastUpdateTime else { return true }
        return now.timeIntervalSince(last) > staleThresholdSeconds
    }

    /// Calculate flight time from line-up (takeoff) to now or landing
    var flightTimeInterval: TimeInterval? {
        guard let lineUp = flightData.lineUpTime else { return nil }
        let endTime = flightData.landingTime ?? Date()
        return endTime.timeIntervalSince(lineUp)
    }

    /// Format flight time as HH:MM:SS
    var formattedFlightTime: String {
        guard let interval = flightTimeInterval else { return "--:--" }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// Format EET to waypoint as MM:SS
    var formattedEET: String? {
        guard let eet = flightData.eetToWaypointSeconds else { return nil }
        let minutes = Int(eet) / 60
        let seconds = Int(eet) % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return String(format: "%d:%02d:%02d", hours, remainingMinutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// The flight-plan chronometer, interpolated locally so it ticks smoothly between phone updates;
    /// mirrors the phone's chronometer. (Watch chrono sync)
    var chronometerDisplayString: String {
        let base = flightData.chronometerElapsed
        let elapsed = flightData.chronometerRunning
            ? base + max(0, Date().timeIntervalSince(lastUpdateTime ?? Date()))
            : base
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        let seconds = Int(elapsed) % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    /// Send a chronometer command to the phone (pause/resume, reset, mark waypoint). The phone acts on
    /// it and echoes the new state back. (Watch chrono control)
    func sendCommand(_ command: WatchCommand) {
        guard let session = session, session.isReachable else { return }
        session.sendMessage([WatchConnectivityKeys.command: command.rawValue], replyHandler: nil) { error in
            print("[AéroCheck Watch] Failed to send command: \(error.localizedDescription)")
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("[AéroCheck Watch] Activation failed: \(error.localizedDescription)")
            return
        }

        Task { @MainActor in
            // Connection reflects live reachability of the phone, not just activation state,
            // so the indicator goes red when the phone is gone. (UX-05)
            self.isConnected = activationState == .activated && session.isReachable
            print("[AéroCheck Watch] Session activated: \(activationState == .activated), reachable: \(session.isReachable)")

            // Load any existing application context
            if let flightDataEncoded = session.receivedApplicationContext[WatchConnectivityKeys.flightData] as? Data {
                self.processFlightData(flightDataEncoded)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        // Drive the connection state from reachability (the phone coming/going). (UX-05)
        Task { @MainActor in
            self.isConnected = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.handleMessage(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            if let flightDataEncoded = applicationContext[WatchConnectivityKeys.flightData] as? Data {
                self.processFlightData(flightDataEncoded)
            }
        }
    }

    private func handleMessage(_ message: [String: Any]) {
        guard let messageTypeRaw = message[WatchConnectivityKeys.messageType] as? String else { return }

        switch messageTypeRaw {
        case WatchMessage.flightStarted.rawValue, WatchMessage.dataUpdate.rawValue:
            if let flightDataEncoded = message[WatchConnectivityKeys.flightData] as? Data {
                processFlightData(flightDataEncoded)
            }

        case WatchMessage.flightEnded.rawValue:
            flightData.isFlightActive = false
            lastUpdateTime = Date()

        case WatchMessage.launchApp.rawValue:
            // App is already launched if receiving this
            if let flightDataEncoded = message[WatchConnectivityKeys.flightData] as? Data {
                processFlightData(flightDataEncoded)
            }

        default:
            break
        }
    }

    private func processFlightData(_ data: Data) {
        do {
            let decoded = try JSONDecoder().decode(WatchFlightData.self, from: data)
            self.flightData = decoded
            self.lastUpdateTime = Date()
        } catch {
            print("[v Watch] Failed to decode flight data: \(error.localizedDescription)")
        }
    }
}
