import Foundation
import Network
import WiFiAware
import CoreLocation
import UIKit

// MARK: - Wi-Fi Aware Service Extensions

/// The Wi-Fi Aware service name shared by the publisher (iPad master) and subscriber (iPhone viewer).
///
/// The transport label MUST be `._udp`. Apple's WiFiAware framework validates this name against
/// RFC6335/RFC6763 while parsing the `WiFiAwareServices` Info.plist key, and TRAPS with an
/// uncatchable assertion on a `._tcp` name — which crashed the app 100% of the time on flight start
/// whenever companion mode was enabled (the master's `startListening()` touches
/// `WAPublishableService.allServices`, forcing that parse). Keep this in exact sync with the
/// `WiFiAwareServices` key in Info.plist. (See CompanionServiceContractTests.)
let companionWiFiAwareServiceName = "_aerocheck._udp"

@available(iOS 26.0, *)
extension WAPublishableService {
    static var aerocheck: WAPublishableService {
        guard let service = allServices[companionWiFiAwareServiceName] else {
            preconditionFailure("Info.plist WiFiAwareServices is missing publishable '\(companionWiFiAwareServiceName)'")
        }
        return service
    }
}

@available(iOS 26.0, *)
extension WASubscribableService {
    static var aerocheck: WASubscribableService {
        guard let service = allServices[companionWiFiAwareServiceName] else {
            preconditionFailure("Info.plist WiFiAwareServices is missing subscribable '\(companionWiFiAwareServiceName)'")
        }
        return service
    }
}

/// Version-agnostic snapshot of a paired companion device.
///
/// The underlying `WAPairedDevice` type is only available on iOS 26+. To keep
/// `CompanionConnectivityManager` instantiable on the iOS 17.0 deployment floor
/// (it is injected as an `@EnvironmentObject` consumed by views that run on
/// iOS 17–25), we never store `WAPairedDevice` directly — we map it into this
/// plain struct inside an `if #available(iOS 26.0, *)` block. (ARCH-09)
struct CompanionPairedDevice: Identifiable, Equatable {
    var id: String { (name ?? "") + (pairingName ?? "") }
    let name: String?
    let pairingName: String?
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
    @Published var pairedDevices: [CompanionPairedDevice] = []
    @Published var isWiFiAwareSupported: Bool = false

    // MARK: - Private Properties

    /// Closure to send framed data over the active connection (avoids storing generic NetworkConnection)
    private var sendHandler: (@Sendable (Data) async throws -> Void)?
    private var updateTimer: Timer?
    private var lastSentFlightPlanId: UUID?

    /// Monotonic token identifying the current connection attempt. Each new connect/accept bumps it
    /// and captures the value; a stale connection's teardown (its receive loop ending *after* a
    /// newer connection has already taken over) carries an older token and is ignored — so it can't
    /// clobber the live connection's state or schedule a duplicate reconnect. (PR-15)
    private var connectionGeneration: Int = 0

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
        // Wi-Fi Aware is an iOS 26+ capability. On the iOS 17.0 deployment floor
        // the manager is still instantiated (it is injected as an environment
        // object) but stays inert: no Wi-Fi Aware symbol is ever touched. (ARCH-09)
        if #available(iOS 26.0, *) {
            isWiFiAwareSupported = WACapabilities.supportedFeatures.contains(.wifiAware)
            startMonitoringPairedDevices()
        }
    }

    // MARK: - Paired Device Monitoring

    /// Continuously monitor the list of paired devices
    @available(iOS 26.0, *)
    private func startMonitoringPairedDevices() {
        pairedDevicesTask = Task { [weak self] in
            do {
                for try await devices in WAPairedDevice.allDevices {
                    let mapped = devices.values.map {
                        CompanionPairedDevice(name: $0.name, pairingName: $0.pairingInfo?.pairingName)
                    }
                    await MainActor.run {
                        self?.pairedDevices = mapped
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

        // Wi-Fi Aware listening requires iOS 26+. Below that, stay inert. (ARCH-09)
        guard #available(iOS 26.0, *) else {
            connectionState = .disconnected
            return
        }

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

                    // New companion connected — update state on main actor and capture this
                    // connection's generation so a later teardown only acts if it's still current.
                    let myGeneration = await MainActor.run { () -> Int in
                        self.connectionGeneration += 1
                        self.receiveTask?.cancel()
                        self.sendHandler = send
                        self.connectionState = .connected
                        self.connectedDeviceName = L10n.Companion.companionDevice
                        print("[AéroCheck Companion] Companion connected")
                        return self.connectionGeneration
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
                        self.handleDisconnection(generation: myGeneration)
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

        // Supersede any prior attempt so its in-flight teardown/retry can't race this one. (PR-15)
        connectionGeneration += 1
        let myGeneration = connectionGeneration

        currentRole = .viewer
        connectionState = .connecting

        // Wi-Fi Aware browsing requires iOS 26+. Below that, stay inert. (ARCH-09)
        guard #available(iOS 26.0, *) else {
            connectionState = .disconnected
            return
        }

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
                    self?.handleDisconnection(generation: myGeneration)
                }
            } catch {
                await MainActor.run {
                    guard let self, self.connectionGeneration == myGeneration else { return }
                    print("[AéroCheck Companion] Browser/connection error: \(error)")
                    self.connectionState = .reconnecting
                    // Auto-retry after delay, only while this attempt is still the current one. (PR-15)
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3))
                        if self.connectionState == .reconnecting,
                           self.connectionGeneration == myGeneration {
                            self.connectToPairedDevice()
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
        // Supersede the current connection so any in-flight teardown/reconnect is invalidated. (PR-15)
        connectionGeneration += 1

        // Send graceful disconnect message
        if connectionState == .connected, sendHandler != nil {
            let message = CompanionMessage(type: .disconnect, payload: Data())
            sendMessage(message)
        }

        cleanupConnection()
        stopListening()
        stopUpdates()
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

    private func handleDisconnection(generation: Int) {
        // Ignore teardown from a connection that has already been superseded by a newer connect or
        // an explicit disconnect — otherwise a stale receive loop ending would clobber the live
        // connection's state and spawn a duplicate reconnect. (PR-15)
        guard generation == connectionGeneration else {
            print("[AéroCheck Companion] Ignoring teardown from stale connection (gen \(generation))")
            return
        }

        cleanupConnection()

        if currentRole == .viewer && connectionState != .disconnected {
            connectionState = .reconnecting
            // Auto-reconnect, only while this connection is still the current one. (PR-15)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if connectionState == .reconnecting, connectionGeneration == generation {
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
