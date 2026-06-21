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
    /// The peer's most recent GPS fix (master side), used when this device has no own fix. (shared-GPS)
    @Published var receivedPeerGPS: CompanionPeerGPS?
    /// Which GPS the flight owner (master) is currently using — own, a borrowed peer fix, or none. (shared-GPS)
    @Published private(set) var effectiveGPSSource: CompanionGPSSource = .own
    /// True on the viewer while it is actively streaming its fix up to a GPS-less master. (shared-GPS)
    @Published private(set) var isProvidingGPS = false

    /// The source-election policy (own fix preferred, peer as fallback). (shared-GPS)
    private let gpsElection = GPSSourceElection()
    /// Local (this-device) wall-clock time the most recent peer fix arrived. Peer freshness is judged
    /// by THIS, not the fix's embedded timestamp, which carries the peer's clock and would be unsafe to
    /// compare across devices. The viewer already validated the fix's own-clock age before sending. (shared-GPS)
    private var lastPeerGPSReceivedAt: Date?
    @Published var latencyMs: Int?
    @Published var pairedDevices: [CompanionPairedDevice] = []
    @Published var isWiFiAwareSupported: Bool = false

    /// Rolling, newest-first log of companion lifecycle events (advertise/browse/connect/disconnect/
    /// errors), surfaced in the dev-only diagnostics panel so a failed pairing/connection can be
    /// inspected on-device without a debugger. Capped to the most recent entries. (v4.1 diagnostics)
    @Published private(set) var diagnostics: [String] = []
    private static let diagnosticsCap = 50

    /// The Wi-Fi Aware service name both roles advertise/browse — surfaced in diagnostics so a service
    /// mismatch (e.g. an old build on one device) is visible. (v4.1 diagnostics)
    var serviceName: String { companionWiFiAwareServiceName }

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
            diag("Wi-Fi Aware supported: \(isWiFiAwareSupported)")
            startMonitoringPairedDevices()
        } else {
            diag("Wi-Fi Aware unavailable (needs iOS/iPadOS 26)")
        }
    }

    // MARK: - Diagnostics (v4.1)

    private static let diagTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Log a pairing-phase event from the DeviceDiscoveryUI pairing views, which run as system UI
    /// outside this manager — so the diagnostics panel shows the pairing attempt, not just connection. (v4.1)
    func logPairing(_ message: String) { diag(message) }

    /// Record a companion lifecycle event for the dev diagnostics panel (newest first) and the log.
    private func diag(_ message: String) {
        let line = "\(Self.diagTimeFormatter.string(from: Date()))  \(message)"
        diagnostics.insert(line, at: 0)
        if diagnostics.count > Self.diagnosticsCap {
            diagnostics.removeLast(diagnostics.count - Self.diagnosticsCap)
        }
        AppLog.companion.debugLine(message)
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
                        guard let self else { return }
                        if self.pairedDevices.count != mapped.count {
                            self.diag("Paired devices: \(mapped.count) (\(mapped.compactMap(\.name).joined(separator: ", ")))")
                        }
                        self.pairedDevices = mapped
                    }
                }
            } catch {
                await MainActor.run { self?.diag("Paired-devices monitor error — \(error.localizedDescription)") }
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
        diag("Master: start listening (advertising '\(serviceName)')")

        // Wi-Fi Aware listening requires iOS 26+. Below that, stay inert. (ARCH-09)
        guard #available(iOS 26.0, *) else {
            connectionState = .disconnected
            diag("Master: aborted — Wi-Fi Aware needs iOS 26")
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
                        self.sendHandler = send
                        self.connectionState = .connected
                        self.connectedDeviceName = L10n.Companion.companionDevice
                        self.diag("Master: companion connected")
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
                                AppLog.companion.debugLine("Invalid message length: \(length)")
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
                            AppLog.companion.debugLine("Receive error: \(error)")
                        }
                    }

                    // Connection ended
                    await MainActor.run {
                        self.handleDisconnection(generation: myGeneration)
                    }
                }
            }

            diag("Master: listener started, awaiting companion")
        } catch {
            diag("Master: listener FAILED — \(error.localizedDescription)")
            connectionState = .disconnected
        }
    }

    /// Stop listening for connections
    func stopListening() {
        listenerTask?.cancel()
        listenerTask = nil
    }

    /// Wire the data sources (idempotent, no timer). Needed on BOTH roles, so the viewer can read its
    /// own GPS to stream upstream when the master has none. (shared-GPS)
    func configure(appState: AppState, locationManager: LocationManager, flightPlanManager: FlightPlanManager) {
        self.appState = appState
        self.locationManager = locationManager
        self.flightPlanManager = flightPlanManager
    }

    /// Start sending periodic updates to the companion (master)
    func startUpdates(appState: AppState, locationManager: LocationManager, flightPlanManager: FlightPlanManager) {
        configure(appState: appState, locationManager: locationManager, flightPlanManager: flightPlanManager)

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
        diag("Viewer: browsing for iPad ('\(serviceName)')")

        // Wi-Fi Aware browsing requires iOS 26+. Below that, stay inert. (ARCH-09)
        guard #available(iOS 26.0, *) else {
            connectionState = .disconnected
            diag("Viewer: aborted — Wi-Fi Aware needs iOS 26")
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
                    self?.diag("Viewer: connected to iPad")
                }

                // Receive messages until connection ends
                do {
                    while !Task.isCancelled {
                        let lengthData = try await connection.receive(exactly: 4).content
                        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

                        guard length > 0 && length < 1_000_000 else {
                            AppLog.companion.debugLine("Invalid message length: \(length)")
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
                        AppLog.companion.debugLine("Receive error: \(error)")
                    }
                }

                // Connection ended
                await MainActor.run {
                    self?.handleDisconnection(generation: myGeneration)
                }
            } catch {
                await MainActor.run {
                    guard let self, self.connectionGeneration == myGeneration else { return }
                    self.diag("Viewer: browse/connect error — \(error.localizedDescription); retrying")
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

        AppLog.companion.debugLine("Browsing for paired master device...")
    }

    /// Send a command to the master device
    func sendCommand(_ command: CompanionCommand) {
        guard connectionState == .connected, sendHandler != nil else { return }

        do {
            let payload = try JSONEncoder().encode(command)
            let message = CompanionMessage(type: .command, payload: payload)
            sendMessage(message)
        } catch {
            AppLog.companion.debugLine("Failed to encode command: \(error)")
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
        // Release the companion GPS provider session if we were sourcing GPS for the master. (shared-GPS)
        stopProvidingGPS()
        browserTask?.cancel()
        browserTask = nil
        connectionState = .disconnected
        connectedDeviceName = nil
        currentRole = .none
        lastReceivedData = nil
        lastFlightPlanSnapshot = nil
        diag("Disconnected (user)")
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
            AppLog.companion.debugLine("Ignoring teardown from stale connection (gen \(generation))")
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
            AppLog.companion.debugLine("Failed to encode message: \(error)")
        }
    }

    // MARK: - Message Handling

    private func handleReceivedMessage(_ message: CompanionMessage) {
        switch message.type {
        case .flightData:
            if let flightData = try? JSONDecoder().decode(CompanionFlightData.self, from: message.payload) {
                lastReceivedData = flightData
                // Viewer: when the master has no fix of its own, stream ours up so it can run the flight
                // off our GPS; stop once the master regains its own fix. (shared-GPS)
                if currentRole == .viewer {
                    if flightData.ownGPSAvailable {
                        stopProvidingGPS()
                    } else {
                        // The viewer isn't running its own flight, so its GPS may be idle — spin it up the
                        // moment the master asks for a fix, otherwise there's nothing to share. (shared-GPS)
                        ensureViewerLocationActive()
                        sendPeerGPSIfAvailable()
                    }
                }
            }

        case .flightPlanUpdate:
            if let snapshot = try? JSONDecoder().decode(CompanionFlightPlanSnapshot.self, from: message.payload) {
                lastFlightPlanSnapshot = snapshot
            }

        case .command:
            if let command = try? JSONDecoder().decode(CompanionCommand.self, from: message.payload) {
                handleCommand(command)
            }

        case .peerGPS:
            // The flight owner (master) receives the peer's fix to run the flight off it when it has no
            // own GPS. Ignored on the viewer — GPS only flows up to the owner. (shared-GPS)
            if currentRole == .master,
               let gps = try? JSONDecoder().decode(CompanionPeerGPS.self, from: message.payload) {
                receivedPeerGPS = gps
                lastPeerGPSReceivedAt = Date()
                updateEffectiveGPSSource()
                // Feed the borrowed fix into the flight pipeline the moment it lands (once per received
                // fix → ~1 Hz, matching the viewer's send cadence), but only while we've actually elected
                // the peer. injectCompanionLocation itself no-ops if our own GPS is live. (shared-GPS)
                if effectiveGPSSource == .peer, let borrowed = effectiveLocation {
                    locationManager?.injectCompanionLocation(borrowed)
                }
            }

        case .disconnect:
            AppLog.companion.debugLine("Received disconnect message")
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
                  plan.waypoints.indices.contains(waypointIndex) else { return }
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

        updateEffectiveGPSSource()   // re-elect own-vs-peer each tick (shared-GPS)
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
            AppLog.companion.debugLine("Failed to encode flight data: \(error)")
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
            AppLog.companion.debugLine("Failed to encode flight plan: \(error)")
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
            // Whether the master has its OWN (real device) fix — drives the viewer's decision to source
            // GPS. Reads own-fix liveness, NOT `currentLocation`, which may already hold a borrowed peer
            // fix; otherwise borrowing would mark the master "has GPS" and stop the feed it depends on. (shared-GPS)
            ownGPSAvailable: locationManager.ownFixIsLive,
            currentWaypointIndex: flightPlanManager.activeFlightPlan?.currentWaypointIndex ?? 0,
            chronometerStartTime: flightPlanManager.activeFlightPlan?.chronometerStartTime,
            chronometerElapsed: flightPlanManager.chronometerElapsed,
            aircraftRegistration: flightPlanManager.activeFlightPlan?.aircraftRegistration ?? "",
            aircraftType: flightPlanManager.activeFlightPlan?.aircraftModelName ?? "",
            timestamp: Date()
        )
    }

    // MARK: - Shared GPS (v4.1)

    /// Viewer: make sure our own GPS is delivering fixes so we have something to stream to a GPS-less
    /// master. The viewer isn't running a flight, so its location is otherwise idle. Starts a dedicated
    /// background-capable provider session (requests Always) so the feed can survive the viewer being
    /// backgrounded — best-effort, since the Wi-Fi Aware link itself may suspend. Idempotent. (shared-GPS)
    private func ensureViewerLocationActive() {
        locationManager?.startSharedGPSProvider()
    }

    /// Viewer: we no longer need to source GPS for the master (it regained its own fix, or we
    /// disconnected). Stop streaming and release the provider session. (shared-GPS)
    private func stopProvidingGPS() {
        isProvidingGPS = false
        locationManager?.stopSharedGPSProvider()
    }

    /// Viewer: stream this device's current fix up to the master, if it's usable. (shared-GPS)
    private func sendPeerGPSIfAvailable() {
        guard currentRole == .viewer, sendHandler != nil, connectionState == .connected,
              let loc = locationManager?.currentLocation else { return }
        let accuracy = loc.horizontalAccuracy
        guard gpsElection.isValid(accuracy: accuracy, age: Date().timeIntervalSince(loc.timestamp)) else { return }
        let gps = CompanionPeerGPS(
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            speedMPS: loc.speed >= 0 ? loc.speed : nil,
            altitudeMeters: loc.altitude,
            courseDegrees: loc.course >= 0 ? loc.course : nil,
            horizontalAccuracy: accuracy,
            signalStatus: locationManager?.gpsSignalStatus.description ?? "unknown",
            timestamp: loc.timestamp
        )
        guard let payload = try? JSONEncoder().encode(gps) else { return }
        sendMessage(CompanionMessage(type: .peerGPS, payload: payload))
        isProvidingGPS = true
    }

    /// Master: re-elect which GPS feeds the flight (own preferred, peer as fallback). (shared-GPS)
    private func updateEffectiveGPSSource() {
        guard currentRole == .master else { effectiveGPSSource = .own; return }
        let now = Date()
        // Own validity reads own-fix LIVENESS, never `currentLocation` — once we borrow, currentLocation
        // holds the peer fix and would masquerade as "own", pinning the election to .own and starving the
        // very feed we depend on. `ownFixIsLive` reflects real device fixes only. (shared-GPS)
        let ownValid = locationManager?.ownFixIsLive ?? false
        // Peer freshness is judged by local receive time, not the peer's embedded timestamp (its clock). (shared-GPS)
        let peerValid = gpsElection.isValid(accuracy: receivedPeerGPS?.horizontalAccuracy,
                                            age: lastPeerGPSReceivedAt.map { now.timeIntervalSince($0) })
        effectiveGPSSource = gpsElection.elect(ownValid: ownValid, peerValid: peerValid)
    }

    /// True when a connected companion is currently supplying a usable fix this device could borrow —
    /// i.e. we are the master and hold a fresh, accurate peer fix. Lets the flight-start guard allow a
    /// GPS-less device (e.g. a Wi-Fi iPad) to launch off the companion's GPS. (shared-GPS)
    var hasUsablePeerFix: Bool {
        guard currentRole == .master, let peer = receivedPeerGPS, let at = lastPeerGPSReceivedAt else { return false }
        return gpsElection.isValid(accuracy: peer.horizontalAccuracy, age: Date().timeIntervalSince(at))
    }

    /// The location the flight owner should record/navigate from: its own fix, or a borrowed peer fix
    /// when its own GPS is unavailable. nil when neither is usable. Consumed by the flight pipeline in a
    /// later increment. (shared-GPS)
    var effectiveLocation: CLLocation? {
        switch effectiveGPSSource {
        case .own:
            return locationManager?.currentLocation
        case .peer:
            guard let p = receivedPeerGPS else { return nil }
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                altitude: p.altitudeMeters ?? 0,
                horizontalAccuracy: p.horizontalAccuracy,
                verticalAccuracy: -1,
                course: p.courseDegrees ?? -1,
                speed: p.speedMPS ?? -1,
                timestamp: p.timestamp
            )
        case .none:
            return nil
        }
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
