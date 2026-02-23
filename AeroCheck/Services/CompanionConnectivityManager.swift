import Foundation
import Network
import WiFiAware
import CoreLocation
import UIKit

// MARK: - Wi-Fi Aware Service Extensions

extension WAPublishableService {
    static var aerocheck: WAPublishableService {
        allServices["_aerocheck._tcp"]!
    }
}

extension WASubscribableService {
    static var aerocheck: WASubscribableService {
        allServices["_aerocheck._tcp"]!
    }
}

/// Manages companion device connectivity using Wi-Fi Aware (iOS 26+)
/// iPad acts as Master (publisher/listener), iPhone acts as Viewer (subscriber/browser)
///
/// Pairing is a one-time operation handled by DeviceDiscoveryUI views
/// (DevicePairingView on iPad, DevicePicker on iPhone).
/// After pairing, devices reconnect automatically whenever in proximity.
@MainActor
class CompanionConnectivityManager: NSObject, ObservableObject {
    static let shared = CompanionConnectivityManager()

    // MARK: - Published State

    @Published var connectionState: CompanionConnectionState = .disconnected
    @Published var currentRole: CompanionRole = .none
    @Published var connectedDeviceName: String?
    @Published var lastReceivedData: CompanionFlightData?
    @Published var lastFlightPlanSnapshot: CompanionFlightPlanSnapshot?
    @Published var latencyMs: Int?
    @Published var pairedDevices: [WAPairedDevice] = []
    @Published var isWiFiAwareSupported: Bool = false

    // MARK: - Private Properties

    /// Closure to send framed data over the active connection (avoids storing generic NetworkConnection)
    private var sendHandler: (@Sendable (Data) async throws -> Void)?
    private var updateTimer: Timer?
    private var lastSentFlightPlanId: UUID?

    // Task management
    private var listenerTask: Task<Void, any Error>?
    private var browserTask: Task<Void, any Error>?
    private var receiveTask: Task<Void, any Error>?
    private var pairedDevicesTask: Task<Void, any Error>?

    // References for data creation (set during startUpdates)
    private weak var appState: AppState?
    private weak var locationManager: LocationManager?
    private weak var flightPlanManager: FlightPlanManager?

    private override init() {
        super.init()
        isWiFiAwareSupported = WACapabilities.supportedFeatures.contains(.wifiAware)
        startMonitoringPairedDevices()
    }

    // MARK: - Paired Device Monitoring

    /// Continuously monitor the list of paired devices
    private func startMonitoringPairedDevices() {
        pairedDevicesTask = Task { [weak self] in
            do {
                for try await devices in WAPairedDevice.allDevices {
                    await MainActor.run {
                        self?.pairedDevices = Array(devices.values)
                    }
                }
            } catch {
                print("[AéroCheck Companion] Paired devices monitoring error: \(error)")
            }
        }
    }

    /// Whether any devices have been paired for companion mode
    var hasPairedDevices: Bool {
        !pairedDevices.isEmpty
    }

    // MARK: - Master (iPad) Methods

    /// Start listening for incoming companion connections via Wi-Fi Aware
    func startListening() {
        stopListening()

        currentRole = .master
        connectionState = .connecting

        do {
            let deviceFilter = #Predicate<WAPairedDevice> { _ in true }

            let listener = try NetworkListener(
                for: .wifiAware(.connecting(to: .aerocheck, from: .matching(deviceFilter))),
                using: .parameters {
                    TLS()
                }
                .wifiAware { $0.performanceMode = .realtime }
                .serviceClass(.interactiveVideo)
            )

            listenerTask = Task { [weak self] in
                try await listener.run { connection in
                    guard let self else { return }

                    // Capture send capability before entering main actor
                    let send: @Sendable (Data) async throws -> Void = { data in
                        try await connection.send(data)
                    }

                    // New companion connected — update state on main actor
                    await MainActor.run {
                        self.receiveTask?.cancel()
                        self.sendHandler = send
                        self.connectionState = .connected
                        self.connectedDeviceName = L10n.Companion.companionDevice
                        print("[AéroCheck Companion] Companion connected")
                    }

                    // Send initial flight data and plan
                    await self.sendInitialData(send: send)

                    // Receive messages until connection ends
                    do {
                        while !Task.isCancelled {
                            let lengthData = try await connection.receive(exactly: 4).content
                            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

                            guard length > 0 && length < 1_000_000 else {
                                print("[AéroCheck Companion] Invalid message length: \(length)")
                                break
                            }

                            let messageData = try await connection.receive(exactly: Int(length)).content

                            if let message = try? JSONDecoder().decode(CompanionMessage.self, from: messageData) {
                                await MainActor.run {
                                    self.handleReceivedMessage(message)
                                }
                            }
                        }
                    } catch {
                        if !Task.isCancelled {
                            print("[AéroCheck Companion] Receive error: \(error)")
                        }
                    }

                    // Connection ended
                    await MainActor.run {
                        self.handleDisconnection()
                    }
                }
            }

            print("[AéroCheck Companion] Started Wi-Fi Aware listener")
        } catch {
            print("[AéroCheck Companion] Failed to create listener: \(error)")
            connectionState = .disconnected
        }
    }

    /// Stop listening for connections
    func stopListening() {
        listenerTask?.cancel()
        listenerTask = nil
    }

    /// Start sending periodic updates to the companion
    func startUpdates(appState: AppState, locationManager: LocationManager, flightPlanManager: FlightPlanManager) {
        self.appState = appState
        self.locationManager = locationManager
        self.flightPlanManager = flightPlanManager

        stopUpdates()

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

    /// Connect to a paired master device via Wi-Fi Aware
    func connectToPairedDevice() {
        browserTask?.cancel()

        currentRole = .viewer
        connectionState = .connecting

        let deviceFilter = #Predicate<WAPairedDevice> { _ in true }

        browserTask = Task { [weak self] in
            do {
                let browser = NetworkBrowser(
                    for: .wifiAware(.connecting(to: .matching(deviceFilter), from: .aerocheck))
                )

                // Browse for the master device
                let endpoint = try await browser.run { waEndpoints in
                    if let endpoint = waEndpoints.first {
                        return .finish(endpoint)
                    }
                    return .continue
                }

                // Create connection to the master
                let connection = NetworkConnection(to: endpoint, using: .parameters {
                    TLS()
                }
                .wifiAware { $0.performanceMode = .realtime }
                .serviceClass(.interactiveVideo))

                // Capture send capability
                let send: @Sendable (Data) async throws -> Void = { data in
                    try await connection.send(data)
                }

                await MainActor.run {
                    self?.sendHandler = send
                    self?.connectionState = .connected
                    self?.connectedDeviceName = self?.pairedDevices.first?.name ?? L10n.Companion.masterDevice
                    print("[AéroCheck Companion] Connected to master")
                }

                // Receive messages until connection ends
                do {
                    while !Task.isCancelled {
                        let lengthData = try await connection.receive(exactly: 4).content
                        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

                        guard length > 0 && length < 1_000_000 else {
                            print("[AéroCheck Companion] Invalid message length: \(length)")
                            break
                        }

                        let messageData = try await connection.receive(exactly: Int(length)).content

                        if let message = try? JSONDecoder().decode(CompanionMessage.self, from: messageData) {
                            await MainActor.run { [weak self] in
                                self?.handleReceivedMessage(message)
                            }
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        print("[AéroCheck Companion] Receive error: \(error)")
                    }
                }

                // Connection ended
                await MainActor.run {
                    self?.handleDisconnection()
                }
            } catch {
                await MainActor.run {
                    print("[AéroCheck Companion] Browser/connection error: \(error)")
                    self?.connectionState = .reconnecting
                    // Auto-retry after delay
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3))
                        if self?.connectionState == .reconnecting {
                            self?.connectToPairedDevice()
                        }
                    }
                }
            }
        }

        print("[AéroCheck Companion] Browsing for paired master device...")
    }

    /// Send a command to the master device
    func sendCommand(_ command: CompanionCommand) {
        guard connectionState == .connected, sendHandler != nil else { return }

        do {
            let payload = try JSONEncoder().encode(command)
            let message = CompanionMessage(type: .command, payload: payload)
            sendMessage(message)
        } catch {
            print("[AéroCheck Companion] Failed to encode command: \(error)")
        }
    }

    // MARK: - Common Methods

    /// Disconnect from the current companion
    func disconnect() {
        // Send graceful disconnect message
        if connectionState == .connected, sendHandler != nil {
            let message = CompanionMessage(type: .disconnect, payload: Data())
            sendMessage(message)
        }

        cleanupConnection()
        stopListening()
        browserTask?.cancel()
        browserTask = nil
        connectionState = .disconnected
        connectedDeviceName = nil
        currentRole = .none
        lastReceivedData = nil
        lastFlightPlanSnapshot = nil
        print("[AéroCheck Companion] Disconnected")
    }

    /// Switch from companion mode back to standalone
    func switchToStandalone() {
        disconnect()
    }

    // MARK: - Connection Lifecycle

    private func handleDisconnection() {
        cleanupConnection()

        if currentRole == .viewer && connectionState != .disconnected {
            connectionState = .reconnecting
            // Auto-reconnect
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if connectionState == .reconnecting {
                    connectToPairedDevice()
                }
            }
        } else if currentRole == .master {
            // Master stays in connecting state, listener continues accepting
            connectionState = .connecting
            connectedDeviceName = nil
        }
    }

    private func cleanupConnection() {
        receiveTask?.cancel()
        receiveTask = nil
        sendHandler = nil
    }

    // MARK: - Message Sending (Length-Prefixed JSON)

    private func sendMessage(_ message: CompanionMessage) {
        guard let sendHandler else { return }

        do {
            let data = try JSONEncoder().encode(message)
            var length = UInt32(data.count).bigEndian
            var frame = Data(bytes: &length, count: 4)
            frame.append(data)

            Task {
                try? await sendHandler(frame)
            }
        } catch {
            print("[AéroCheck Companion] Failed to encode message: \(error)")
        }
    }

    // MARK: - Message Handling

    private func handleReceivedMessage(_ message: CompanionMessage) {
        switch message.type {
        case .flightData:
            if let flightData = try? JSONDecoder().decode(CompanionFlightData.self, from: message.payload) {
                lastReceivedData = flightData
            }

        case .flightPlanUpdate:
            if let snapshot = try? JSONDecoder().decode(CompanionFlightPlanSnapshot.self, from: message.payload) {
                lastFlightPlanSnapshot = snapshot
            }

        case .command:
            if let command = try? JSONDecoder().decode(CompanionCommand.self, from: message.payload) {
                handleCommand(command)
            }

        case .disconnect:
            print("[AéroCheck Companion] Received disconnect message")
            cleanupConnection()
            connectionState = .disconnected
            connectedDeviceName = nil
        }
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
            break
        }
    }

    // MARK: - Data Sending (Master)

    /// Send initial flight data and plan when a companion first connects
    private nonisolated func sendInitialData(send: @Sendable (Data) async throws -> Void) async {
        // Create snapshots on main actor
        let (flightData, planSnapshot) = await MainActor.run { [weak self] () -> (CompanionFlightData?, CompanionFlightPlanSnapshot?) in
            guard let self else { return (nil, nil) }
            let fd = self.createCurrentFlightData()
            let ps = self.createCurrentFlightPlanSnapshot()
            return (fd, ps)
        }

        // Send flight plan snapshot first
        if let planSnapshot, let payload = try? JSONEncoder().encode(planSnapshot) {
            let message = CompanionMessage(type: .flightPlanUpdate, payload: payload)
            if let data = try? JSONEncoder().encode(message) {
                var length = UInt32(data.count).bigEndian
                var frame = Data(bytes: &length, count: 4)
                frame.append(data)
                try? await send(frame)
            }
        }

        // Send current flight data
        if let flightData, let payload = try? JSONEncoder().encode(flightData) {
            let message = CompanionMessage(type: .flightData, payload: payload)
            if let data = try? JSONEncoder().encode(message) {
                var length = UInt32(data.count).bigEndian
                var frame = Data(bytes: &length, count: 4)
                frame.append(data)
                try? await send(frame)
            }
        }
    }

    private func sendFlightData() {
        guard sendHandler != nil, connectionState == .connected,
              let appState, let locationManager, let flightPlanManager else { return }

        let data = createCompanionFlightData(
            appState: appState,
            locationManager: locationManager,
            flightPlanManager: flightPlanManager
        )

        do {
            let payload = try JSONEncoder().encode(data)
            let message = CompanionMessage(type: .flightData, payload: payload)
            sendMessage(message)
        } catch {
            print("[AéroCheck Companion] Failed to encode flight data: \(error)")
        }
    }

    private func sendFlightPlanSnapshot() {
        guard sendHandler != nil, connectionState == .connected,
              let flightPlanManager, let plan = flightPlanManager.activeFlightPlan else { return }

        let snapshot = createFlightPlanSnapshot(plan)

        do {
            let payload = try JSONEncoder().encode(snapshot)
            let message = CompanionMessage(type: .flightPlanUpdate, payload: payload)
            sendMessage(message)
            lastSentFlightPlanId = plan.id
        } catch {
            print("[AéroCheck Companion] Failed to encode flight plan: \(error)")
        }
    }

    private func checkForFlightPlanChanges() {
        guard let flightPlanManager, let plan = flightPlanManager.activeFlightPlan else { return }

        if plan.id != lastSentFlightPlanId || plan.waypoints.contains(where: { $0.actualTimeOver != nil }) {
            sendFlightPlanSnapshot()
        }
    }

    // MARK: - Data Creation Helpers

    private func createCurrentFlightData() -> CompanionFlightData? {
        guard let appState, let locationManager, let flightPlanManager else { return nil }
        return createCompanionFlightData(
            appState: appState,
            locationManager: locationManager,
            flightPlanManager: flightPlanManager
        )
    }

    private func createCurrentFlightPlanSnapshot() -> CompanionFlightPlanSnapshot? {
        guard let flightPlanManager, let plan = flightPlanManager.activeFlightPlan else { return nil }
        return createFlightPlanSnapshot(plan)
    }

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
