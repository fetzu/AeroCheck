import Foundation
import Network
import CoreLocation
import UIKit

/// Manages companion device connectivity using Network Framework (NWBrowser / NWListener)
/// iPad acts as Master (advertises), iPhone acts as Viewer (discovers and connects)
@MainActor
class CompanionConnectivityManager: NSObject, ObservableObject {
    static let shared = CompanionConnectivityManager()

    // MARK: - Published State

    @Published var connectionState: CompanionConnectionState = .disconnected
    @Published var currentRole: CompanionRole = .none
    @Published var connectedDeviceName: String?
    @Published var lastReceivedData: CompanionFlightData?
    @Published var lastFlightPlanSnapshot: CompanionFlightPlanSnapshot?
    @Published var discoveredPeers: [DiscoveredPeer] = []
    @Published var latencyMs: Int?

    // MARK: - Private Properties

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var updateTimer: Timer?
    private var reconnectTimer: Timer?
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts = 20  // 20 * 3s = 60s
    private var lastSessionId: UUID?
    private var currentSessionId: UUID = UUID()
    private var lastSentFlightPlanId: UUID?

    // References for data creation (set during startUpdates)
    private weak var appState: AppState?
    private weak var locationManager: LocationManager?
    private weak var flightPlanManager: FlightPlanManager?

    // Data buffer for receiving length-prefixed messages
    private var receiveBuffer = Data()

    private let serviceType = "_aerocheck._tcp"

    private override init() {
        super.init()
    }

    // MARK: - Master (iPad) Methods

    /// Start advertising as a master device
    func startAdvertising() {
        stopAdvertising()

        currentRole = .master
        currentSessionId = UUID()

        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true

            listener = try NWListener(using: parameters)
            listener?.service = NWListener.Service(type: serviceType)

            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerStateChange(state)
                }
            }

            listener?.newConnectionHandler = { [weak self] newConnection in
                Task { @MainActor in
                    self?.handleNewConnection(newConnection)
                }
            }

            listener?.start(queue: .main)
            connectionState = .advertising
            print("[AéroCheck Companion] Started advertising as master")
        } catch {
            print("[AéroCheck Companion] Failed to start listener: \(error.localizedDescription)")
            connectionState = .disconnected
        }
    }

    /// Stop advertising
    func stopAdvertising() {
        listener?.cancel()
        listener = nil
        if connectionState == .advertising {
            connectionState = .disconnected
        }
    }

    /// Start sending periodic updates to the companion
    func startUpdates(appState: AppState, locationManager: LocationManager, flightPlanManager: FlightPlanManager) {
        self.appState = appState
        self.locationManager = locationManager
        self.flightPlanManager = flightPlanManager

        stopUpdates()

        // Send initial update immediately if connected
        if connectionState == .connected {
            sendFlightPlanSnapshot()
            sendFlightData()
        }

        // Start periodic updates (every 1 second)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connectionState == .connected else { return }
                self.sendFlightData()
                self.checkForFlightPlanChanges()
            }
        }
    }

    /// Stop sending updates
    func stopUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    // MARK: - Viewer (iPhone) Methods

    /// Start browsing for master devices
    func startBrowsing() {
        stopBrowsing()

        currentRole = .viewer
        discoveredPeers = []

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)

        browser?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleBrowserStateChange(state)
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                self?.handleBrowseResults(results)
            }
        }

        browser?.start(queue: .main)
        connectionState = .searching
        print("[AéroCheck Companion] Started browsing for masters")
    }

    /// Stop browsing
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        discoveredPeers = []
        if connectionState == .searching {
            connectionState = .disconnected
        }
    }

    /// Connect to a discovered peer
    func connectToPeer(_ peer: DiscoveredPeer) {
        // Find the matching NWBrowseResult endpoint
        guard let results = browser?.browseResults,
              let result = results.first(where: { peerFromResult($0)?.id == peer.id }) else {
            print("[AéroCheck Companion] Could not find endpoint for peer: \(peer.name)")
            return
        }

        connectionState = .connecting

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let nwConnection = NWConnection(to: result.endpoint, using: parameters)
        setupConnection(nwConnection)
    }

    /// Send a command to the master device
    func sendCommand(_ command: CompanionCommand) {
        guard connectionState == .connected, let connection else { return }

        do {
            let payload = try JSONEncoder().encode(command)
            let message = CompanionMessage(type: .command, payload: payload)
            sendMessage(message, on: connection)
        } catch {
            print("[AéroCheck Companion] Failed to encode command: \(error.localizedDescription)")
        }
    }

    // MARK: - Common Methods

    /// Disconnect from the current companion
    func disconnect() {
        // Send graceful disconnect message
        if let connection, connectionState == .connected {
            let message = CompanionMessage(type: .disconnect, payload: Data())
            sendMessage(message, on: connection)
        }

        cleanupConnection()
        stopReconnectTimer()
        connectionState = .disconnected
        connectedDeviceName = nil
        currentRole = .none
        lastReceivedData = nil
        lastFlightPlanSnapshot = nil
        print("[AéroCheck Companion] Disconnected")
    }

    // MARK: - Listener State Handling (Master)

    private func handleListenerStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            print("[AéroCheck Companion] Listener ready")
        case .failed(let error):
            print("[AéroCheck Companion] Listener failed: \(error.localizedDescription)")
            connectionState = .disconnected
        case .cancelled:
            print("[AéroCheck Companion] Listener cancelled")
        default:
            break
        }
    }

    private func handleNewConnection(_ newConnection: NWConnection) {
        // Accept only one connection at a time
        if let existing = connection {
            existing.cancel()
        }

        print("[AéroCheck Companion] New connection from companion")
        setupConnection(newConnection)
    }

    // MARK: - Browser State Handling (Viewer)

    private func handleBrowserStateChange(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            print("[AéroCheck Companion] Browser ready")
        case .failed(let error):
            print("[AéroCheck Companion] Browser failed: \(error.localizedDescription)")
            connectionState = .disconnected
        case .cancelled:
            print("[AéroCheck Companion] Browser cancelled")
        default:
            break
        }
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        discoveredPeers = results.compactMap { peerFromResult($0) }
        print("[AéroCheck Companion] Found \(discoveredPeers.count) peers")
    }

    private func peerFromResult(_ result: NWBrowser.Result) -> DiscoveredPeer? {
        switch result.endpoint {
        case .service(let name, _, _, _):
            return DiscoveredPeer(
                id: UUID(uuidString: name) ?? UUID(),
                name: name,
                endpoint: "\(result.endpoint)"
            )
        default:
            return nil
        }
    }

    // MARK: - Connection Management

    private func setupConnection(_ nwConnection: NWConnection) {
        connection = nwConnection

        nwConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionStateChange(state)
            }
        }

        nwConnection.start(queue: .main)
        startReceiving(on: nwConnection)
    }

    private func handleConnectionStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connectionState = .connected
            reconnectAttempts = 0
            stopReconnectTimer()
            print("[AéroCheck Companion] Connection established")

            // Send handshake
            sendHandshake()

            // If master, send current flight data
            if currentRole == .master {
                sendFlightPlanSnapshot()
                sendFlightData()
            }

        case .failed(let error):
            print("[AéroCheck Companion] Connection failed: \(error.localizedDescription)")
            handleDisconnection()

        case .cancelled:
            print("[AéroCheck Companion] Connection cancelled")

        case .waiting(let error):
            print("[AéroCheck Companion] Connection waiting: \(error.localizedDescription)")

        default:
            break
        }
    }

    private func handleDisconnection() {
        cleanupConnection()

        if currentRole == .viewer {
            connectionState = .reconnecting
            startReconnectTimer()
        } else {
            connectionState = currentRole == .master ? .advertising : .disconnected
            connectedDeviceName = nil
        }
    }

    private func cleanupConnection() {
        connection?.cancel()
        connection = nil
        receiveBuffer = Data()
    }

    // MARK: - Message Framing (Length-Prefixed)

    private func sendMessage(_ message: CompanionMessage, on connection: NWConnection) {
        do {
            let data = try JSONEncoder().encode(message)
            var length = UInt32(data.count).bigEndian
            var frame = Data(bytes: &length, count: 4)
            frame.append(data)

            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    print("[AéroCheck Companion] Send failed: \(error.localizedDescription)")
                }
            })
        } catch {
            print("[AéroCheck Companion] Failed to encode message: \(error.localizedDescription)")
        }
    }

    private func startReceiving(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }

                if let data = content {
                    self.receiveBuffer.append(data)
                    self.processReceiveBuffer()
                }

                if isComplete {
                    self.handleDisconnection()
                } else if let error {
                    print("[AéroCheck Companion] Receive error: \(error.localizedDescription)")
                    self.handleDisconnection()
                } else {
                    // Continue receiving
                    self.startReceiving(on: connection)
                }
            }
        }
    }

    private func processReceiveBuffer() {
        while receiveBuffer.count >= 4 {
            let lengthData = receiveBuffer.prefix(4)
            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            guard receiveBuffer.count >= 4 + Int(length) else {
                // Not enough data yet, wait for more
                break
            }

            let messageData = receiveBuffer.subdata(in: 4..<(4 + Int(length)))
            receiveBuffer = receiveBuffer.subdata(in: (4 + Int(length))..<receiveBuffer.count)

            handleReceivedMessage(messageData)
        }
    }

    // MARK: - Message Handling

    private func handleReceivedMessage(_ data: Data) {
        do {
            let message = try JSONDecoder().decode(CompanionMessage.self, from: data)

            switch message.type {
            case .handshake:
                let handshake = try JSONDecoder().decode(CompanionHandshake.self, from: message.payload)
                handleHandshake(handshake)

            case .flightData:
                let flightData = try JSONDecoder().decode(CompanionFlightData.self, from: message.payload)
                lastReceivedData = flightData

            case .flightPlanUpdate:
                let snapshot = try JSONDecoder().decode(CompanionFlightPlanSnapshot.self, from: message.payload)
                lastFlightPlanSnapshot = snapshot

            case .command:
                let command = try JSONDecoder().decode(CompanionCommand.self, from: message.payload)
                handleCommand(command)

            case .disconnect:
                print("[AéroCheck Companion] Received disconnect message")
                cleanupConnection()
                connectionState = .disconnected
                connectedDeviceName = nil
            }
        } catch {
            print("[AéroCheck Companion] Failed to decode message: \(error.localizedDescription)")
        }
    }

    private func handleHandshake(_ handshake: CompanionHandshake) {
        connectedDeviceName = handshake.deviceName
        if let sessionId = handshake.sessionId {
            lastSessionId = sessionId
        }
        print("[AéroCheck Companion] Handshake from \(handshake.deviceName) (role: \(handshake.role))")
    }

    private func handleCommand(_ command: CompanionCommand) {
        guard currentRole == .master, let flightPlanManager else { return }

        switch command {
        case .recordATO(let waypointIndex):
            flightPlanManager.recordATO(forWaypointAt: waypointIndex)

        case .updateGroundSpeed(let waypointIndex, let newGS):
            guard var plan = flightPlanManager.activeFlightPlan,
                  waypointIndex < plan.waypoints.count else { return }
            plan.waypoints[waypointIndex].plannedGroundSpeed = newGS
            plan.calculateRouteData()
            flightPlanManager.updateFlightPlan(plan)

        case .advanceWaypoint:
            flightPlanManager.advanceToNextWaypoint()

        case .goToPreviousWaypoint:
            flightPlanManager.goToPreviousWaypoint()

        case .startChronometer:
            flightPlanManager.startChronometer()

        case .resetChronometer:
            flightPlanManager.resetChronometer()

        case .ping:
            // Could send pong for latency measurement
            break
        }
    }

    // MARK: - Data Sending (Master)

    private func sendHandshake() {
        guard let connection else { return }

        let handshake = CompanionHandshake(
            deviceName: UIDevice.current.name,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
            role: currentRole,
            sessionId: currentRole == .viewer ? lastSessionId : currentSessionId
        )

        do {
            let payload = try JSONEncoder().encode(handshake)
            let message = CompanionMessage(type: .handshake, payload: payload)
            sendMessage(message, on: connection)
        } catch {
            print("[AéroCheck Companion] Failed to encode handshake: \(error.localizedDescription)")
        }
    }

    private func sendFlightData() {
        guard let connection, connectionState == .connected,
              let appState, let locationManager, let flightPlanManager else { return }

        let data = createCompanionFlightData(
            appState: appState,
            locationManager: locationManager,
            flightPlanManager: flightPlanManager
        )

        do {
            let payload = try JSONEncoder().encode(data)
            let message = CompanionMessage(type: .flightData, payload: payload)
            sendMessage(message, on: connection)
        } catch {
            print("[AéroCheck Companion] Failed to encode flight data: \(error.localizedDescription)")
        }
    }

    private func sendFlightPlanSnapshot() {
        guard let connection, connectionState == .connected,
              let flightPlanManager, let plan = flightPlanManager.activeFlightPlan else { return }

        let snapshot = createFlightPlanSnapshot(plan)

        do {
            let payload = try JSONEncoder().encode(snapshot)
            let message = CompanionMessage(type: .flightPlanUpdate, payload: payload)
            sendMessage(message, on: connection)
            lastSentFlightPlanId = plan.id
        } catch {
            print("[AéroCheck Companion] Failed to encode flight plan snapshot: \(error.localizedDescription)")
        }
    }

    private func checkForFlightPlanChanges() {
        guard let flightPlanManager, let plan = flightPlanManager.activeFlightPlan else { return }

        // Resend if plan changed (new plan or waypoint updates like ATO)
        if plan.id != lastSentFlightPlanId || plan.waypoints.contains(where: { $0.actualTimeOver != nil }) {
            // Simple change detection: resend every time there's a connected companion
            // The snapshot is small enough that sending it periodically (at most 1Hz) is fine
            sendFlightPlanSnapshot()
        }
    }

    // MARK: - Data Creation

    private func createCompanionFlightData(appState: AppState, locationManager: LocationManager, flightPlanManager: FlightPlanManager) -> CompanionFlightData {
        let location = locationManager.currentLocation

        return CompanionFlightData(
            isFlightActive: appState.isFlightActive,
            currentPhase: appState.currentPhase.shortTitle,
            currentPhaseRawValue: appState.currentPhase.rawValue,
            isCircuitMode: appState.isCircuitMode,
            engineStartTime: appState.engineStartTime,
            lineUpTime: appState.lineUpTime,
            landingTime: appState.landingTime,
            alwaysUseUTC: appState.settings.alwaysUseUTC,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            speedMPS: location?.speed ?? 0 >= 0 ? location?.speed : nil,
            altitudeFeet: location != nil ? location!.altitude * 3.28084 : nil,
            courseDegrees: location?.course ?? 0 >= 0 ? location?.course : nil,
            gpsSignalStatus: locationManager.gpsSignalStatus.description,
            currentWaypointIndex: flightPlanManager.activeFlightPlan?.currentWaypointIndex ?? 0,
            chronometerStartTime: flightPlanManager.activeFlightPlan?.chronometerStartTime,
            chronometerElapsed: flightPlanManager.chronometerElapsed,
            aircraftRegistration: flightPlanManager.activeFlightPlan?.aircraftRegistration ?? "",
            aircraftType: flightPlanManager.activeFlightPlan?.aircraftModelName ?? "",
            timestamp: Date()
        )
    }

    private func createFlightPlanSnapshot(_ plan: FlightPlan) -> CompanionFlightPlanSnapshot {
        let waypoints = plan.waypoints.map { wp in
            CompanionWaypoint(
                id: wp.id,
                name: wp.name,
                latitude: wp.latitude,
                longitude: wp.longitude,
                altitude: wp.altitude,
                frequency: wp.frequency,
                magneticCourse: wp.magneticCourse,
                distance: wp.distance,
                plannedGroundSpeed: wp.plannedGroundSpeed,
                estimatedElapsedTime: wp.estimatedElapsedTime,
                legEETExtra: wp.legEETExtra,
                cumulativeEET: wp.cumulativeEET,
                estimatedTimeOver: wp.estimatedTimeOver,
                actualTimeOver: wp.actualTimeOver,
                remarks: wp.remarks
            )
        }

        let totalDistance = plan.waypoints.compactMap(\.distance).reduce(0, +)
        let totalEET = plan.waypoints.last?.cumulativeEET ?? 0

        return CompanionFlightPlanSnapshot(
            planId: plan.id,
            planName: plan.name,
            waypoints: waypoints,
            currentWaypointIndex: plan.currentWaypointIndex,
            totalDistance: totalDistance,
            totalEET: totalEET,
            plannedDepartureTime: plan.plannedDepartureTime,
            chronometerStartTime: plan.chronometerStartTime
        )
    }

    // MARK: - Auto-Reconnect (Viewer)

    private func startReconnectTimer() {
        stopReconnectTimer()
        reconnectAttempts = 0

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reconnectAttempts += 1

                if self.reconnectAttempts >= self.maxReconnectAttempts {
                    self.stopReconnectTimer()
                    // Stay in .reconnecting state — UI will show "Go Standalone" option
                    print("[AéroCheck Companion] Max reconnect attempts reached")
                    return
                }

                // Re-browse and try to find the same master
                if self.browser == nil {
                    self.startBrowsing()
                    self.connectionState = .reconnecting
                }

                // Auto-connect to first available peer
                if let peer = self.discoveredPeers.first {
                    print("[AéroCheck Companion] Auto-reconnecting to \(peer.name) (attempt \(self.reconnectAttempts))")
                    self.connectToPeer(peer)
                }
            }
        }
    }

    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectAttempts = 0
    }

    /// Switch from companion mode back to standalone (called from UI when user gives up on reconnection)
    func switchToStandalone() {
        disconnect()
    }
}

// MARK: - GPSSignalStatus Description

extension GPSSignalStatus: CustomStringConvertible {
    var description: String {
        switch self {
        case .good: return "good"
        case .degraded: return "degraded"
        case .lost: return "lost"
        }
    }
}
