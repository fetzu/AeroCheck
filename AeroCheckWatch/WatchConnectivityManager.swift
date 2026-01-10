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
            print("[AeroCheck Watch] WatchConnectivity not supported")
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
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("[AeroCheck Watch] Activation failed: \(error.localizedDescription)")
            return
        }

        Task { @MainActor in
            self.isConnected = activationState == .activated
            print("[AeroCheck Watch] Session activated: \(activationState == .activated)")

            // Load any existing application context
            if let flightDataEncoded = session.receivedApplicationContext[WatchConnectivityKeys.flightData] as? Data {
                self.processFlightData(flightDataEncoded)
            }
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
            print("[AeroCheck Watch] Failed to decode flight data: \(error.localizedDescription)")
        }
    }
}
