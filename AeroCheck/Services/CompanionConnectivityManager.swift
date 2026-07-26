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
    /// The master's current checklist (phase + items + highlight), mirrored to the viewer so the iPhone
    /// can show and drive the same checklist. (companion v2)
    @Published var lastReceivedChecklist: CompanionChecklistSnapshot?
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

    /// Closure to send a typed message over the active connection. The connection uses a JSON Coder over
    /// UDP (matching the `._udp` Wi-Fi Aware service + Apple's sample), so we hand it a `CompanionMessage`
    /// and the Coder frames/encodes it — no manual length-prefix framing. (v4.1 — was TLS/TCP, which
    /// never carried data over the UDP datapath.)
    private var sendHandler: (@Sendable (CompanionMessage) async throws -> Void)?
    private var updateTimer: Timer?
    private var lastSentFlightPlanId: UUID?
    /// The last checklist snapshot actually streamed, so the 1 Hz timer only re-encodes/sends when the
    /// phase/highlight/items change instead of every tick (a phase is static for seconds-to-minutes).
    /// Cleared on teardown so a fresh connection re-sends. (efficiency)
    private var lastSentChecklist: CompanionChecklistSnapshot?

    /// Connection-health watchdog (v4.1): without it, a peer that quit/backgrounded leaves the other side
    /// showing "Connected" for minutes (the TCP/Wi-Fi Aware drop is slow to surface). The viewer treats a
    /// gap in the master's ~1 Hz stream as a drop; the master treats repeated send failures as a drop.
    private var connectionHealthTimer: Timer?
    private var lastReceivedAt: Date?
    private var sendFailureCount = 0
    private static let receiveStaleAfter: TimeInterval = CompanionTiming.streamStaleAfter
    private static let maxConsecutiveSendFailures = 3

    /// Battery: drop the hot Wi-Fi Aware link if it's been connected with NO active flight for a while
    /// (e.g. companion left on in the hangar). It re-establishes automatically on flight start or when
    /// the user opens the Companion screen — but a passive foreground/launch won't silently re-arm it.
    private var idleSince: Date?
    private var idleDisconnected = false
    private static let idleDisconnectAfter: TimeInterval = 600   // 10 min connected + no flight

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

    /// Whether the connected viewer reported its own premium entitlement (SA-26).
    /// Defaults to false and resets on every disconnect — an older viewer that never sends
    /// `viewerHello`, or one that sends a malformed one, gets the redacted checklist stream.
    private var peerIsEntitled = false

    /// Whether the connected peer may drive checklist/waypoint state in THIS session. (SEC-C40)
    ///
    /// The listener accepts `.allPairedDevices`, and `handleCommand` checked only that we are the
    /// master — i.e. any device that completed the one-time system pairing at any point in the past
    /// could mutate the master's checklist and waypoints, forever, with no in-app way to revoke it.
    /// That is a realistic precondition in this app's actual market: shared aeroclub/rental iPads
    /// that many student pilots pair their personal phones to over time.
    ///
    /// Deliberately per-connection and defaulting to false: a stale pairing from a previous user
    /// gets nothing until the person holding the master says so, and saying so does not persist.
    @Published var peerMayIssueCommands = false

    /// Set when a peer attempted a command before being authorised, so the UI can ask. (SEC-C40)
    @Published var pendingCommandAuthorizationFrom: String?
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
                    // De-dupe by identity: a flaky/retried pairing can leave several system records for the
                    // SAME device (e.g. "FlyPad" twice), which would show duplicates and warn in ForEach.
                    var seen = Set<String>()
                    let mapped = devices.values.compactMap { dev -> CompanionPairedDevice? in
                        let d = CompanionPairedDevice(name: dev.name, pairingName: dev.pairingInfo?.pairingName)
                        return seen.insert(d.id).inserted ? d : nil
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
            let listener = try NetworkListener(
                // Accept connections from any already-paired device — the connection phase uses
                // .allPairedDevices (matches Apple's sample), not the pairing-only .userSpecifiedDevices.
                for: .wifiAware(.connecting(to: .aerocheck, from: .allPairedDevices)),
                using: .parameters {
                    // JSON messages over UDP — matches the ._udp Wi-Fi Aware service and Apple's sample.
                    Coder(receiving: CompanionMessage.self, sending: CompanionMessage.self, using: NetworkJSONCoder()) {
                        UDP()
                    }
                }
                .wifiAware { $0.performanceMode = .realtime }
                .serviceClass(.interactiveVideo)
            )

            listenerTask = Task { [weak self] in
                try await listener.run { connection in
                    guard let self else { return }

                    // Capture send capability before entering main actor
                    let send: @Sendable (CompanionMessage) async throws -> Void = { msg in
                        try await connection.send(msg)
                    }

                    // New companion connected — update state on main actor and capture this
                    // connection's generation so a later teardown only acts if it's still current.
                    let myGeneration = await MainActor.run { () -> Int in
                        self.connectionGeneration += 1
                        self.sendHandler = send
                        self.connectionState = .connected
                        self.connectedDeviceName = self.pairedDevices.first?.name ?? self.pairedDevices.first?.pairingName ?? L10n.Companion.companionDevice
                        self.sendFailureCount = 0
                        self.lastReceivedAt = Date()
                        self.startSendTimer()              // stream state 1 Hz while connected (flight or not)
                        self.startConnectionHealthTimer()
                        self.diag("Master: companion connected (\(self.connectedDeviceName ?? "?"))")
                        return self.connectionGeneration
                    }

                    // Send initial flight data and plan
                    await self.sendInitialData(send: send)

                    // Receive typed messages until the connection ends (the Coder decodes each one).
                    do {
                        for try await (message, _) in connection.messages {
                            await MainActor.run {
                                self.handleReceivedMessage(message)
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

    /// Reports THIS device's own premium entitlement, for the viewer→master hello (SA-26).
    ///
    /// A closure rather than a stored reference so the manager keeps no dependency on
    /// SubscriptionManager and stays usable in tests and previews. Absent ⇒ not entitled, which is
    /// the fail-closed direction: the worst case is a legitimate subscriber briefly seeing the
    /// redacted stream, never an unentitled peer seeing premium text.
    var viewerEntitlementProvider: (() -> Bool)?

    /// Wire the data sources (idempotent, no timer). Needed on BOTH roles, so the viewer can read its
    /// own GPS to stream upstream when the master has none. (shared-GPS)
    func configure(appState: AppState, locationManager: LocationManager, flightPlanManager: FlightPlanManager) {
        self.appState = appState
        self.locationManager = locationManager
        self.flightPlanManager = flightPlanManager
    }

    /// Wire data sources + ensure the master is streaming if already connected. The 1 Hz stream now
    /// starts on CONNECT (startSendTimer), not on flight start, so the viewer stays in sync the whole
    /// time the link is up — flight or not. (v4.1 companion)
    func startUpdates(appState: AppState, locationManager: LocationManager, flightPlanManager: FlightPlanManager) {
        configure(appState: appState, locationManager: locationManager, flightPlanManager: flightPlanManager)
        if connectionState == .connected, currentRole == .master { startSendTimer() }
    }

    /// Master: push current state to the viewer every second while connected (flight or not).
    private func startSendTimer() {
        stopUpdates()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connectionState == .connected, self.currentRole == .master else { return }
                self.sendFlightData()
                self.sendChecklistSnapshot()
                self.checkForFlightPlanChanges()
            }
        }
    }

    /// Stop sending updates
    func stopUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    // MARK: - Auto-connect & connection health (v4.1)

    /// Connect automatically when companion mode is enabled and a device is paired — so the user never
    /// has to start it on BOTH devices. The iPad listens (always ready), the iPhone connects. Idempotent:
    /// a no-op unless currently disconnected with a paired device. Call at launch, on foreground, on
    /// enabling companion mode, and after pairing. (v4.1 companion UX)
    func autoConnectIfReady(force: Bool = false) {
        guard #available(iOS 26.0, *) else { return }
        // `force` (flight start, or the user opening the Companion screen) clears an idle-disconnect; a
        // passive foreground/launch (force == false) leaves it dropped so the battery saving sticks.
        if force { idleDisconnected = false }
        guard !idleDisconnected else { return }
        guard let appState, appState.settings.enableCompanionMode, hasPairedDevices else { return }
        guard connectionState == .disconnected else { return }
        switch CompanionRole.automatic(for: UIDevice.current.userInterfaceIdiom) {
        case .master: startListening()
        case .viewer: connectToPairedDevice()
        case .none: break
        }
    }

    private func startConnectionHealthTimer() {
        connectionHealthTimer?.invalidate()
        // .common mode so it keeps firing during scroll/gesture tracking. (cf. PR-21)
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkConnectionHealth() }
        }
        RunLoop.main.add(timer, forMode: .common)
        connectionHealthTimer = timer
    }

    private func stopConnectionHealthTimer() {
        connectionHealthTimer?.invalidate()
        connectionHealthTimer = nil
    }

    /// Bidirectional heartbeat + staleness, every 2 s. UDP is connectionless, so (a) the viewer must keep
    /// sending or the master's flow goes idle and it can't tell we're alive, and (b) send-failure can't
    /// detect a drop (UDP sends never fail). So: the viewer pings each tick (the master streams 1 Hz the
    /// other way), and EITHER side drops the link if the peer's traffic goes silent for >5 s. (v4.1)
    private func checkConnectionHealth() {
        guard connectionState == .connected else { stopConnectionHealthTimer(); return }
        if currentRole == .viewer {
            sendPing()          // keep the UDP flow open + prove liveness to the master
            sendViewerHello()   // report entitlement so the master knows what it may stream (SA-26)
        }
        if let last = lastReceivedAt, Date().timeIntervalSince(last) > Self.receiveStaleAfter {
            diag("\(currentRole == .master ? "Master" : "Viewer"): no data for \(Int(Date().timeIntervalSince(last)))s — dropping")
            handleDisconnection(generation: connectionGeneration)
            return
        }
        // Battery: master drops the hot link after a long idle stretch with no active flight. (v4.1)
        if currentRole == .master, let appState, !appState.isFlightActive {
            if idleSince == nil { idleSince = Date() }
            else if Date().timeIntervalSince(idleSince!) > Self.idleDisconnectAfter {
                diag("Master: idle \(Int(Self.idleDisconnectAfter/60)) min with no flight — disconnecting (battery)")
                idleDisconnected = true
                disconnect()
            }
        } else {
            idleSince = nil
        }
    }

    /// Viewer → master keep-alive. Also the FIRST one (sent on connect) is what opens the UDP flow so the
    /// master's listener actually accepts the connection (it never fires until it receives a datagram).
    private func sendPing() {
        guard let payload = try? JSONEncoder().encode(CompanionCommand.ping) else { return }
        sendMessage(CompanionMessage(type: .command, payload: payload))
    }

    /// Viewer → master: report our own entitlement so the master knows how much checklist text it
    /// may stream to us. Sent on connect, alongside the first ping. (SA-26)
    private func sendViewerHello() {
        guard currentRole == .viewer else { return }
        let hello = CompanionViewerHello(isSubscribed: viewerEntitlementProvider?() ?? false)
        guard let payload = try? JSONEncoder().encode(hello) else { return }
        sendMessage(CompanionMessage(type: .viewerHello, payload: payload))
    }

    /// Master/viewer: repeated send failures mean the peer is gone — drop the connection.
    private func noteSendFailure(generation: Int) {
        guard generation == connectionGeneration, connectionState == .connected else { return }
        sendFailureCount += 1
        if sendFailureCount >= Self.maxConsecutiveSendFailures {
            diag("\(currentRole == .master ? "Master" : "Viewer"): send failing — dropping connection")
            sendFailureCount = 0
            handleDisconnection(generation: generation)
        }
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

        browserTask = Task { [weak self] in
            do {
                let browser = NetworkBrowser(
                    // Browse for any paired master — .allPairedDevices for the connection phase (sample-matched).
                    for: .wifiAware(.connecting(to: .allPairedDevices, from: .aerocheck))
                )

                // Browse for the master device
                let endpoint = try await browser.run { waEndpoints in
                    if let endpoint = waEndpoints.first {
                        return .finish(endpoint)
                    }
                    return .continue
                }

                // Create connection to the master — JSON messages over UDP (matches the listener + service).
                let connection = NetworkConnection(to: endpoint, using: .parameters {
                    Coder(receiving: CompanionMessage.self, sending: CompanionMessage.self, using: NetworkJSONCoder()) {
                        UDP()
                    }
                }
                .wifiAware { $0.performanceMode = .realtime }
                .serviceClass(.interactiveVideo))

                // Capture send capability
                let send: @Sendable (CompanionMessage) async throws -> Void = { msg in
                    try await connection.send(msg)
                }

                // Re-check the generation BEFORE adopting this connection. `browser.run`/connection
                // establishment can suspend for a long time; if disconnect()/a newer connect() superseded
                // this attempt during that suspension (bumping connectionGeneration + cancelling browserTask),
                // adopting it here would resurrect a link the user just tore down — re-arming the send
                // handler/health timer and flipping the UI back to .connected. Every sibling branch already
                // guards on `myGeneration`; this one didn't. (v4.1.0 pre-tag fix — M2)
                let stillCurrent = await MainActor.run { () -> Bool in
                    guard let self, self.connectionGeneration == myGeneration else { return false }
                    self.sendHandler = send
                    self.connectionState = .connected
                    self.connectedDeviceName = self.pairedDevices.first?.name ?? self.pairedDevices.first?.pairingName ?? L10n.Companion.masterDevice
                    self.sendFailureCount = 0
                    self.lastReceivedAt = Date()
                    self.startConnectionHealthTimer()
                    // Open the UDP flow immediately — until the master receives a datagram from us, its
                    // listener never accepts and it never streams back. (v4.1)
                    self.sendPing()
                    self.diag("Viewer: connected to iPad")
                    return true
                }
                // Superseded mid-establish — drop this stale connection instead of entering its receive
                // loop (which would keep feeding the manager messages from a connection the user dropped).
                guard stillCurrent else { return }

                // Receive typed messages until the connection ends (the Coder decodes each one).
                do {
                    for try await (message, _) in connection.messages {
                        await MainActor.run { [weak self] in
                            self?.handleReceivedMessage(message)
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

        cleanupConnection()   // also releases the GPS provider + clears peer-fix state (shared-GPS)
        stopListening()
        stopUpdates()
        browserTask?.cancel()
        browserTask = nil
        connectionState = .disconnected
        connectedDeviceName = nil
        currentRole = .none
        lastReceivedData = nil
        lastFlightPlanSnapshot = nil
        lastReceivedChecklist = nil
        diag("Disconnected (user)")
    }

    /// Leave companion mode entirely: turn the setting OFF (so auto-connect can't re-arm it seconds
    /// later) and tear down the link. Used by the viewer's hold-to-exit and the "switch to standalone"
    /// banner button. (companion v2 — leave-companion fix)
    func switchToStandalone() {
        appState?.settings.enableCompanionMode = false
        appState?.saveSettings()
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
            connectionState = .connecting
            connectedDeviceName = nil
            // Re-arm a FRESH listener. Keeping the old one running wedges it — after a drop it won't
            // accept the viewer's reconnect (observed on device: only an iPad app restart recovered).
            // startListening() cancels + recreates the listener; deferred a tick so we don't cancel the
            // listener task from inside its own teardown. (v4.1)
            diag("Master: re-arming listener after drop")
            Task { @MainActor in
                guard self.currentRole == .master, self.connectionState == .connecting else { return }
                self.startListening()
            }
        }
    }

    private func cleanupConnection() {
        sendHandler = nil
        stopConnectionHealthTimer()
        stopUpdates()
        sendFailureCount = 0
        idleSince = nil
        lastSentChecklist = nil
        // Reset the shared-GPS state on EVERY teardown (graceful or not), so a stale peer fix can't keep
        // the source election pinned to .peer, can't masquerade as a usable fix to the flight-start guard
        // (hasUsablePeerFix), and the viewer's background GPS provider isn't stranded. (shared-GPS)
        stopProvidingGPS()
        receivedPeerGPS = nil
        lastPeerGPSReceivedAt = nil
        effectiveGPSSource = .own
    }

    // MARK: - Message Sending (Length-Prefixed JSON)

    private func sendMessage(_ message: CompanionMessage) {
        guard let sendHandler else { return }
        let gen = connectionGeneration
        Task {
            do {
                try await sendHandler(message)   // the Coder encodes/frames it
                await MainActor.run { self.sendFailureCount = 0 }
            } catch {
                // A failing send means the peer is gone — surface it instead of swallowing. (v4.1)
                await MainActor.run { self.noteSendFailure(generation: gen) }
            }
        }
    }

    // MARK: - Message Handling

    private func handleReceivedMessage(_ message: CompanionMessage) {
        lastReceivedAt = Date()   // any inbound traffic = the link is alive (connection-health watchdog)
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

        case .checklistUpdate:
            if let snapshot = try? JSONDecoder().decode(CompanionChecklistSnapshot.self, from: message.payload) {
                lastReceivedChecklist = snapshot
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
                // SA-10: reject a geometrically-invalid fix at the wire boundary so it is never
                // stored, never elected, and never reaches the flight pipeline or MapKit. Dropping
                // it (rather than clamping) keeps the previous good fix in play until it goes stale,
                // which is the same behaviour as a missed update.
                guard gps.hasValidGeometry else {
                    AppLog.companion.debugLine("Dropped peer GPS with invalid geometry")
                    return
                }
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

        case .viewerHello:
            // Only the master consumes this, and only to decide how much checklist text to stream.
            if currentRole == .master,
               let hello = try? JSONDecoder().decode(CompanionViewerHello.self, from: message.payload) {
                peerIsEntitled = hello.isSubscribed
                diag("Master: viewer reported entitlement = \(hello.isSubscribed)")
                // Re-send with the new redaction level applied.
                sendChecklistSnapshot()
            }

        case .disconnect:
            AppLog.companion.debugLine("Received disconnect message")
            cleanupConnection()
            connectionState = .disconnected
            connectedDeviceName = nil
            peerIsEntitled = false   // a new peer must re-prove entitlement (SA-26)
            // SEC-C40: authorisation is per-connection, so a reconnecting (or different) device
            // must be confirmed again rather than inheriting the last session's trust.
            peerMayIssueCommands = false
            pendingCommandAuthorizationFrom = nil
        }
    }

    private func handleCommand(_ command: CompanionCommand) {
        guard currentRole == .master, let flightPlanManager else { return }

        // SEC-C40: being paired is not authorisation to control this flight.
        guard peerMayIssueCommands else {
            if pendingCommandAuthorizationFrom == nil {
                pendingCommandAuthorizationFrom = connectedDeviceName ?? L10n.Companion.companionDevice
                diag("Master: blocked command from unauthorised peer; awaiting confirmation")
            }
            return
        }

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

        // Companion v2 — synced checklist: drive the iPad's shared checklist from the iPhone. The iPad
        // stays the source of truth; these mirror exactly what tapping on the iPad would do.
        case .advanceChecklistItem:
            if let appState {
                // Mirror FlightView.handleChecklistTap: on the LAST item, mark the phase complete
                // (so the viewer's NEXT button lights up); otherwise step to the next item. Using
                // only advanceHighlightedItem here meant tapping the last item was a no-op. (item 1b)
                let learning = appState.effectiveLearningMode
                let visibleCount = appState.activeChecklist.visibleItemCount(for: appState.currentPhase, learningMode: learning)
                let currentIndex = appState.getHighlightedItem(for: appState.currentPhase)
                if currentIndex >= visibleCount - 1 {
                    appState.markLastItemComplete(learningMode: learning)
                } else {
                    appState.advanceHighlightedItem(learningMode: learning)
                }
            }

        case .nextChecklistPhase:
            appState?.nextPhase()

        case .previousChecklistPhase:
            appState?.previousPhase()

        case .revealHiddenItems:
            // Hold-to-reveal on the viewer reveals hidden items on BOTH devices (single source of truth
            // in AppState; the iPad's FlightView binds to it). (item 1c)
            appState?.hiddenItemsRevealed = true
        }
    }

    // MARK: - Data Sending (Master)

    /// Send initial flight data, plan, and checklist when a companion first connects
    private nonisolated func sendInitialData(send: @Sendable (CompanionMessage) async throws -> Void) async {
        // Create snapshots on main actor
        let (flightData, planSnapshot, checklist) = await MainActor.run { [weak self] () -> (CompanionFlightData?, CompanionFlightPlanSnapshot?, CompanionChecklistSnapshot?) in
            guard let self else { return (nil, nil, nil) }
            return (self.createCurrentFlightData(), self.createCurrentFlightPlanSnapshot(), self.createChecklistSnapshot())
        }

        // Send flight plan snapshot first, then checklist, then current flight data (the Coder encodes each).
        if let planSnapshot, let payload = try? JSONEncoder().encode(planSnapshot) {
            try? await send(CompanionMessage(type: .flightPlanUpdate, payload: payload))
        }
        if let checklist, let payload = try? JSONEncoder().encode(checklist) {
            try? await send(CompanionMessage(type: .checklistUpdate, payload: payload))
        }
        if let flightData, let payload = try? JSONEncoder().encode(flightData) {
            try? await send(CompanionMessage(type: .flightData, payload: payload))
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

    /// Master: snapshot the current checklist phase + its visible items + highlight, for the viewer to
    /// show and drive. (companion v2 — synced checklist)
    private func createChecklistSnapshot() -> CompanionChecklistSnapshot? {
        guard let appState else { return nil }
        let phase = appState.currentPhase
        // Effective learning mode includes a hold-to-reveal, so revealing on either device streams the
        // hidden items to the viewer (and vice-versa). (companion v2 — hidden-content parity)
        let learning = appState.effectiveLearningMode
        let visible = appState.activeChecklist.visibleItems(for: phase, learningMode: learning)

        // SA-26: stream the actual challenge/response text only when the viewer is entitled to it.
        // Pairing is one system sheet plus one confirmation code, after which the devices reconnect
        // automatically in proximity — so without this, an unsubscribed peer could read a
        // subscriber's whole premium checklist (and drive it via nextChecklistPhase /
        // revealHiddenItems) simply by being nearby. The viewer still gets the phase title,
        // progress counters and highlight, so the second-screen layout is intact; only the words
        // are withheld.
        //
        // Bundled/free aircraft always stream in full. `isUsingRemoteAircraft` is the conservative
        // signal available here — today every remote aircraft is premium, and if a free one ever
        // ships, withholding its text from an unentitled peer is the harmless direction to err.
        //
        // Defence in depth, NOT a server gap: the paid content is legitimately on the paying
        // device. A legitimate single user's iPhone shares the subscriber's Apple ID, reports
        // isSubscribed = true, and is unaffected.
        let mayStreamItemText = peerIsEntitled || !appState.settings.isRemoteAircraftSelected
        let items = mayStreamItemText
            ? visible.map {
                CompanionChecklistItem(id: $0.id, challenge: $0.challenge, response: $0.response, isHeader: $0.isHeader)
            }
            : []
        let visibleCount = appState.activeChecklist.visibleItemCount(for: phase, learningMode: learning)
        let highlighted = appState.getHighlightedItem(for: phase)
        // How many memorizable items are still hidden (0 once revealed/learning mode) — drives the
        // viewer's "Hidden Checklist Content" placeholder, mirroring the iPad.
        let hiddenCount = max(0, appState.activeChecklist.items(for: phase).count - visible.count)
        return CompanionChecklistSnapshot(
            phaseTitle: phase.title,
            phaseRawValue: phase.rawValue,
            highlightedIndex: highlighted,
            visibleCount: visibleCount,
            completedCount: min(highlighted, visibleCount),
            items: items,
            hiddenItemCount: hiddenCount
        )
    }

    /// Master: stream the current checklist to the viewer (sent each tick alongside flight data — the
    /// payload is small and the viewer needs it to stay in sync as items/phase advance).
    private func sendChecklistSnapshot() {
        guard sendHandler != nil, connectionState == .connected, currentRole == .master,
              let snapshot = createChecklistSnapshot() else { return }
        // Skip the encode + radio send when nothing changed since the last send (CompanionChecklistSnapshot
        // is Equatable). Mirrors the flight-plan path's lastSentFlightPlanId guard. (efficiency)
        guard snapshot != lastSentChecklist else { return }
        do {
            let payload = try JSONEncoder().encode(snapshot)
            sendMessage(CompanionMessage(type: .checklistUpdate, payload: payload))
            lastSentChecklist = snapshot
        } catch {
            AppLog.companion.debugLine("Failed to encode checklist: \(error)")
        }
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
            gpsSource: effectiveGPSSource.rawValue,
            // The master's resolved cockpit theme, so the viewer renders the SAME day/sunlight/night
            // styling as the iPad rather than its own device theme. (companion v2 — theme parity)
            // Resolve against the DEVICE's real appearance (published from AppRootView) so the viewer
            // mirrors what the iPad displays. The window trait is force-dark, which made `.auto` always
            // stream night. (companion v2 — theme default fix)
            cockpitThemeMode: appState.settings.cockpitThemeMode(systemIsDark: appState.deviceIsDark).rawValue,
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
        // SA-10: isPeerFixValid also checks the fix's GEOMETRY. Accuracy and age alone would let a
        // peer pair a plausible 10 m accuracy with an out-of-range or non-finite coordinate and be
        // elected, after which effectiveLocation builds a CLLocation straight from the wire values.
        let peerValid = gpsElection.isPeerFixValid(receivedPeerGPS,
                                                   age: lastPeerGPSReceivedAt.map { now.timeIntervalSince($0) })
        effectiveGPSSource = gpsElection.elect(ownValid: ownValid, peerValid: peerValid)
    }

    /// True when a connected companion is currently supplying a usable fix this device could borrow —
    /// i.e. we are the master and hold a fresh, accurate peer fix. Lets the flight-start guard allow a
    /// GPS-less device (e.g. a Wi-Fi iPad) to launch off the companion's GPS. (shared-GPS)
    var hasUsablePeerFix: Bool {
        guard currentRole == .master, connectionState == .connected,
              let at = lastPeerGPSReceivedAt else { return false }
        // SA-10: this gates whether a GPS-less device may START a flight off the peer, so it must
        // apply the same geometry check as the election.
        return gpsElection.isPeerFixValid(receivedPeerGPS, age: Date().timeIntervalSince(at))
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
