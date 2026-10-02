import Foundation
import Network
import WiFiAware
import CoreLocation
import UIKit
import os

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
    /// The system's `WAPairedDevice.ID`s behind this row. Usually one; a flaky or retried pairing
    /// can leave several records for the same device, which the list shows once, so forgetting it
    /// has to forget them all. (S9-09)
    var deviceIDs: [UInt64] = []

    var displayName: String? { name ?? pairingName }
}

/// Who is at the other end of a companion connection, as Wi-Fi Aware names it: the system's
/// `WAPairedDevice.ID`, kept as a plain number so the manager stays usable below iOS 26 (ARCH-09).
///
/// The master used to call whoever connected `pairedDevices.first`, the first entry of an unordered
/// list, so on an iPad paired to several phones the authorisation prompt could name one phone while
/// another was asking. The identity now comes from the connection itself. (S9-28)
struct CompanionPeerIdentity: Equatable, Sendable {
    let deviceID: UInt64
    let name: String?
}

@available(iOS 26.0, *)
extension CompanionPeerIdentity {
    init(_ device: WAPairedDevice) {
        self.init(deviceID: device.id, name: device.name ?? device.pairingInfo?.pairingName)
    }
}

/// The pilot's answer about the peer of ONE connection. (SEC-C40)
enum CompanionPeerAuthorization: Equatable {
    case undecided
    case allowed
    case denied
}

/// One accepted connection and what its peer may do. Trust lives here, per connection, and dies with
/// it; nothing about it is global to the manager any more. (S9-28)
struct CompanionPeerLink: Equatable {
    /// The connection's `connectionGeneration`: frames and answers carrying another one are stale.
    let generation: Int
    /// Nil when Wi-Fi Aware would not say who it is.
    let identity: CompanionPeerIdentity?
    var authorization: CompanionPeerAuthorization = .undecided
    /// The pilot was asked about this connection already. Never twice: the viewer's keep-alive and
    /// its taps kept raising the same modal every 2 s, and a pilot who cancelled got it straight back
    /// over the checklist until they gave in and allowed it. (S9-08)
    var hasAsked = false
    /// What the viewer's latest hello says about its own subscription. Unverified, so it counts for
    /// the checklist text only, and only on an entitled iPad (see `mayStreamItemText`). (S9-30)
    var claimsEntitlement = false

    /// A request to act on the flight (a command that changes something, or a position to borrow):
    /// whether it goes through, and whether to ask the pilot now.
    mutating func admit() -> (admitted: Bool, ask: Bool) {
        switch authorization {
        case .allowed: return (true, false)
        case .denied: return (false, false)
        case .undecided:
            let ask = !hasAsked
            hasAsked = true
            return (false, ask)
        }
    }
}

/// The question put to the pilot, bound to the connection that raised it, so an answer given after
/// that connection was replaced cannot authorise its successor. (S9-28)
struct CompanionAuthorizationRequest: Identifiable, Equatable {
    let generation: Int
    /// The peer's name as Wi-Fi Aware gives it; nil and the prompt says "a paired device".
    let deviceName: String?
    var id: Int { generation }
}

/// The paired devices the pilot told AéroCheck to forget. (S9-09)
///
/// Wi-Fi Aware has no API to remove a system pairing (`WAPairedDevice` only lists them), so this is
/// the app's own list: a device on it is refused when it connects to the iPad and skipped when the
/// iPhone looks for one. "Allow Again" takes it off. Stored by `WAPairedDevice.ID`, as strings
/// because a `UInt64` above `Int64.max` does not survive a round trip through `UserDefaults`.
struct CompanionForgottenDevices {
    static let defaultsKey = "companionForgottenDeviceIDs"

    private let defaults: UserDefaults
    private(set) var ids: Set<UInt64>

    init(defaults: UserDefaults) {
        self.defaults = defaults
        ids = Set((defaults.stringArray(forKey: Self.defaultsKey) ?? []).compactMap { UInt64($0) })
    }

    func contains(_ id: UInt64) -> Bool { ids.contains(id) }

    mutating func forget(_ newIDs: [UInt64]) {
        ids.formUnion(newIDs)
        save()
    }

    mutating func allow(_ allowedIDs: [UInt64]) {
        ids.subtract(allowedIDs)
        save()
    }

    private func save() {
        defaults.set(ids.sorted().map(String.init), forKey: Self.defaultsKey)
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
    /// The plan snapshot last streamed, and when. A change goes on the next tick, whatever it is: an ETO
    /// anchored on READY FOR LINE UP or retimed on the measured take-off, a time over marked, auto-marked
    /// or taken back, a Divert / Resume, the plan swapped. It used to go only for a new plan, a
    /// diversion, or once any waypoint had a time over (and then every second), so the ETOs anchored
    /// before the take-off reached the phone only with the next full snapshot, after a reconnect. An
    /// unchanged one goes again every `CompanionTiming.snapshotRefresh`, since a datagram lost over UDP
    /// is not resent. Cleared on teardown. (6.1.0)
    private var lastSentPlan: CompanionFlightPlanSnapshot?
    private var lastPlanSentAt: Date?
    /// The last checklist snapshot actually streamed, so the 1 Hz timer only re-encodes/sends when the
    /// phase/highlight/items change instead of every tick (a phase is static for seconds-to-minutes).
    /// Cleared on teardown so a fresh connection re-sends. (efficiency)
    private var lastSentChecklist: CompanionChecklistSnapshot?

    /// Connection-health watchdog (v4.1): without it, a peer that quit/backgrounded leaves the other side
    /// showing "Connected" for minutes (the TCP/Wi-Fi Aware drop is slow to surface). Either side treats
    /// a silence from the peer as a drop (`CompanionTiming.linkSilenceLimit`), and sends that keep failing.
    private var connectionHealthTimer: Timer?
    private var lastReceivedAt: Date?
    /// When the sends started failing, nil while they go through. The link ends on sends failing for
    /// `linkSilenceLimit`, no longer on three failures in a row: the iPad sends two or three datagrams a
    /// second (flight data, checklist, plan), so three were one bad second of radio. (6.1.0)
    private var sendFailingSince: Date?
    /// Viewer: whether the current connection has heard from the iPad yet (`firstFrameLimit`).
    private var viewerHeardFromIPad = false
    /// Viewer: when the live link dropped, while the Companion screen stays up and the phone looks for
    /// the iPad again (`CompanionTiming.reconnectGrace`). Nil otherwise. (6.1.0)
    private var viewerLinkLostAt: Date?
    /// The app went to the background since it was last active (`appBecameActive`).
    private var wasInBackground = false

    /// Battery: drop the hot Wi-Fi Aware link (the 1 Hz stream, the realtime radio mode) once it has
    /// been up for a while with NO flight, e.g. companion left on in the hangar. The phone is told and
    /// stays off until it is used again (its app back in the foreground, Companion mode turned on
    /// there); the iPad keeps listening, so that brings the link back without touching the iPad. It
    /// used to stop listening too, and then only the iPad (a flight start, its Companion screen) could.
    /// (6.1.0)
    private var idleSince: Date?
    private static let idleDisconnectAfter: TimeInterval = 600   // 10 min connected + no flight

    /// Master: listener failures in a row, for the retry's back-off. Reset by an accepted connection.
    private var listenerFailures = 0
    /// How many times a listener (master) or a browse (viewer) was started: the diagnostics' count,
    /// and what the tests read, since a test manager starts nothing real.
    private(set) var listenerStarts = 0
    private(set) var browseStarts = 0

    /// Monotonic token identifying the current connection attempt. Each new connect/accept bumps it
    /// and captures the value; a stale connection's teardown (its receive loop ending *after* a
    /// newer connection has already taken over) carries an older token and is ignored — so it can't
    /// clobber the live connection's state or schedule a duplicate reconnect. (PR-15)
    private(set) var connectionGeneration: Int = 0

    // Task management
    private var listenerTask: Task<Void, any Error>?
    private var browserTask: Task<Void, any Error>?
    private var pairedDevicesTask: Task<Void, any Error>?

    // References for data creation (set during startUpdates)
    private weak var appState: AppState?

    /// The current connection and what its peer may do (SEC-C40). Nil when nothing is connected.
    ///
    /// The listener accepts `.allPairedDevices`, so any device that completed the one-time system
    /// pairing at any point in the past can connect. That is a realistic precondition in this app's
    /// actual market: shared aeroclub/rental iPads that many student pilots pair their personal
    /// phones to over time. So a peer may drive the checklist or waypoints, or feed its position into
    /// the flight, only once the person holding the master allowed it, and only for that connection:
    /// a stale pairing from a previous user gets nothing, and saying yes does not persist. (SEC-C40,
    /// S9-09)
    @Published private(set) var peerLink: CompanionPeerLink?

    /// The question awaiting the pilot's answer, for the prompt to show. (SEC-C40)
    @Published var pendingAuthorization: CompanionAuthorizationRequest?

    /// Whether the connected peer may act on this flight. Read-only: only the pilot's answer to
    /// `pendingAuthorization` sets it, through `answerAuthorization(_:allow:)`.
    var peerMayIssueCommands: Bool { peerLink?.authorization == .allowed }

    /// The devices the pilot forgot (S9-09): refused on the iPad, skipped by the iPhone.
    @Published private(set) var forgottenDevices: CompanionForgottenDevices

    private weak var locationManager: LocationManager?
    private weak var flightPlanManager: FlightPlanManager?

    /// False for a manager built by a test: it never touches Wi-Fi Aware, so a test cannot start a
    /// real listener or browser on the simulator.
    private let usesWiFiAware: Bool

    private override convenience init() {
        self.init(defaults: .standard, usesWiFiAware: true)
    }

    /// `usesWiFiAware: false` and a defaults suite of its own for tests; the app has `shared`.
    init(defaults: UserDefaults, usesWiFiAware: Bool) {
        forgottenDevices = CompanionForgottenDevices(defaults: defaults)
        self.usesWiFiAware = usesWiFiAware
        super.init()
        guard usesWiFiAware else { return }
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
    ///
    /// Logged in the clear, so a Console capture of a failed pairing shows the steps (6.1.0): callers
    /// pass fixed text only, never a device name.
    func logPairing(_ message: String) { diag(message, isPublic: true) }

    /// Record a companion lifecycle event for the dev diagnostics panel (newest first) and the log.
    /// `isPublic` only for a fixed state message with no device name in it (SA-20).
    private func diag(_ message: String, isPublic: Bool = false) {
        appendDiagnostic(message)
        if isPublic {
            AppLog.companion.publicLine(message)
        } else {
            AppLog.companion.debugLine(message)
        }
    }

    /// A link lifecycle event (up, down and why, a listener re-armed, a reconnect attempt): in the
    /// diagnostics panel with `detail`, and in the device log in the clear at a level a `log collect`
    /// archive keeps, without `detail`. So a USB capture taken after a field report shows why a link
    /// dropped. `event` is fixed text and numbers only; a device name goes in `detail`, which the
    /// device log keeps private. (6.1.0, SA-20)
    private func lifecycle(_ event: String, detail: String? = nil) {
        appendDiagnostic(detail.map { "\(event) (\($0))" } ?? event)
        AppLog.companion.publicNotice(event)
        if let detail { AppLog.companion.debugLine("\(event): \(detail)") }
    }

    private func appendDiagnostic(_ message: String) {
        let line = "\(Self.diagTimeFormatter.string(from: Date()))  \(message)"
        diagnostics.insert(line, at: 0)
        if diagnostics.count > Self.diagnosticsCap {
            diagnostics.removeLast(diagnostics.count - Self.diagnosticsCap)
        }
    }

    /// An error as fixed text for the public log: its domain and code, never its description, which
    /// can carry an endpoint or a device name.
    nonisolated static func errorCode(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
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
                    // The row keeps every record's id, so Forget covers them all (S9-09), and the list is
                    // sorted: the dictionary has no order, and a row that moves is a row mis-tapped.
                    var rows: [String: CompanionPairedDevice] = [:]
                    for dev in devices.values {
                        let fresh = CompanionPairedDevice(name: dev.name, pairingName: dev.pairingInfo?.pairingName)
                        var row = rows[fresh.id] ?? fresh
                        row.deviceIDs = (row.deviceIDs + [dev.id]).sorted()
                        rows[row.id] = row
                    }
                    let mapped = rows.values.sorted { ($0.displayName ?? "", $0.id) < ($1.displayName ?? "", $1.id) }
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

    /// Whether any device is paired for companion mode and not forgotten: one the app will connect to.
    var hasPairedDevices: Bool {
        pairedDevices.contains { !isForgotten($0) }
    }

    // MARK: - Forget device (S9-09)

    /// Whether the pilot forgot this device: every system record behind the row is on the list.
    func isForgotten(_ device: CompanionPairedDevice) -> Bool {
        !device.deviceIDs.isEmpty && device.deviceIDs.allSatisfy(forgottenDevices.contains)
    }

    /// Stop connecting to this device, on both roles, until the pilot allows it again. If it is the
    /// device connected right now, the link ends here. (S9-09)
    func forget(_ device: CompanionPairedDevice) {
        forgottenDevices.forget(device.deviceIDs)
        diag("Forgot \(device.displayName ?? "a device"): it can no longer connect")
        rebrowseIfLooking()
        guard let connected = peerLink?.identity?.deviceID, device.deviceIDs.contains(connected) else { return }
        switch currentRole {
        case .master:
            // Tell the viewer, then drop it and listen again: the next connection it makes is refused.
            sendMessage(CompanionMessage(type: .disconnect, payload: Data()))
            handleDisconnection(generation: connectionGeneration, reason: .forgotten)
        case .viewer:
            disconnect()
        case .none:
            break
        }
    }

    /// Take the device off the forgotten list; it connects again as any paired device does.
    func allowAgain(_ device: CompanionPairedDevice) {
        forgottenDevices.allow(device.deviceIDs)
        diag("Allowed \(device.displayName ?? "a device") again")
        rebrowseIfLooking()
        autoConnectIfReady()
    }

    /// Viewer: a browse already running took the forgotten list as it was when it started. Start it
    /// again so the change applies now, not after the next drop.
    private func rebrowseIfLooking() {
        guard currentRole == .viewer,
              connectionState == .connecting || connectionState == .reconnecting else { return }
        connectToPairedDevice()
    }

    /// Whether the iPad refuses a connecting peer: one the pilot forgot or, once any device is
    /// forgotten, one Wi-Fi Aware will not name, since it could be the forgotten one. Fails closed on
    /// purpose: a pilot who forgot a device and finds the companion refusing everything notices at
    /// once, which is better than a forget that silently does nothing. With nothing forgotten an
    /// unnamed peer connects, and like any peer it still has to be allowed to act. (S9-09)
    nonisolated static func refusesPeer(_ identity: CompanionPeerIdentity?, forgotten: Set<UInt64>) -> Bool {
        guard let identity else { return !forgotten.isEmpty }
        return forgotten.contains(identity.deviceID)
    }

    // MARK: - Master (iPad) Methods

    /// Start listening for incoming companion connections via Wi-Fi Aware
    func startListening() {
        // The pairing screen publishes the service itself (see `isPairing`). This also covers the
        // re-arm after a drop and the Companion screen's Start Listening button.
        guard !isPairing else {
            AppLog.companion.publicLine("Master: listener held, pairing in progress")
            return
        }
        stopListening()

        currentRole = .master
        connectionState = .connecting
        listenerStarts += 1
        diag("Master: start listening (advertising '\(serviceName)')")

        // A test manager: "listening" with nothing to hear, the state the iPad is in while it waits.
        guard usesWiFiAware else { return }
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

                    // Who is connecting, from the connection itself, before anything is streamed to
                    // it or it takes over from the current one. (S9-28) The Wi-Fi Aware path may
                    // only be there once the connection carries traffic, so when it will not say
                    // yet, take the first frame (the viewer pings on connect, then every 2 s) and
                    // ask again. Both waits are short: the viewer drops a link that stays silent
                    // for 5 s.
                    var messages = connection.messages.makeAsyncIterator()
                    var firstFrame: CompanionMessage?
                    var identity = await Self.peerIdentity(of: connection)
                    if identity == nil {
                        guard let frame = try? await messages.next() else { return }   // gone already
                        firstFrame = frame.0
                        identity = await Self.peerIdentity(of: connection)
                    }

                    // New companion connected — update state on main actor and capture this
                    // connection's generation so a later teardown only acts if it's still current.
                    // Nil: a forgotten device, refused; returning ends (closes) its connection. (S9-09)
                    guard let myGeneration = await MainActor.run(body: { [identity] in
                        self.adoptMasterConnection(identity: identity, send: send)
                    }) else { return }

                    // Send initial flight data and plan
                    await self.sendInitialData(send: send)

                    // Receive typed messages until the connection ends (the Coder decodes each one).
                    do {
                        var pending = firstFrame
                        while true {
                            let message: CompanionMessage
                            if let frame = pending {
                                message = frame
                                pending = nil
                            } else if let frame = try await messages.next() {
                                message = frame.0
                            } else {
                                break
                            }
                            let isCurrent = await MainActor.run {
                                self.handleReceivedMessage(message, generation: myGeneration)
                            }
                            // A newer connection took over: this one's frames are dropped, and
                            // leaving the loop closes it rather than keeping it half alive. (S9-28)
                            if !isCurrent { break }
                        }
                    } catch {
                        if !Task.isCancelled {
                            AppLog.companion.debugLine("Receive error: \(error)")
                        }
                    }

                    // Connection ended
                    await MainActor.run {
                        self.handleDisconnection(generation: myGeneration, reason: .receiveEnded)
                    }
                }
            }

            // A listener that stops on an error of its own (not a cancel) used to leave the iPad on
            // "Connecting" with nothing listening, and nothing in the diagnostics. Wi-Fi Aware takes one
            // publisher per service, so a listener started while the system's pairing session still
            // holds it (right after the pairing screen closes) could end that way. (6.1.0)
            if let listenerTask {
                Task { [weak self] in
                    guard case .failure(let error) = await listenerTask.result,
                          !listenerTask.isCancelled else { return }
                    self?.listenerFailed(error)
                }
            }

            lifecycle("Master: listener up, waiting for the phone")
        } catch {
            listenerFailed(error)
        }
    }

    /// Stop listening for connections
    func stopListening() {
        listenerTask?.cancel()
        listenerTask = nil
    }

    /// Master: the listener stopped on an error of its own, or could not be made. Still waiting for a
    /// phone means nothing listens any more, so start another after a pause that doubles up to 30 s,
    /// for as long as nothing else took over (a connection, Disconnect, pairing mode). The iPad used to
    /// go "disconnected" here and stay so until it was touched (a flight start, its Companion screen),
    /// whatever the phone did; and a re-arm right after a drop can fail this way while the previous
    /// publish of the service is still being torn down (Wi-Fi Aware takes one publisher per service).
    /// A live connection is left to its own teardown. (6.1.0)
    func listenerFailed(_ error: any Error) {
        guard currentRole == .master, connectionState == .connecting else {
            diag("Master: a listener stopped on an error under a live link, \(Self.errorCode(error))", isPublic: true)
            return
        }
        listenerFailures += 1
        let delay = Self.listenerRetryDelay(afterFailures: listenerFailures)
        lifecycle("Master: listener stopped on an error (\(Self.errorCode(error))), "
                  + "retry \(listenerFailures) in \(Int(delay)) s")
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.connectionGeneration == generation,
                  self.currentRole == .master, self.connectionState == .connecting else { return }
            self.startListening()
        }
    }

    /// 2, 4, 8, 16, then every 30 s.
    nonisolated static func listenerRetryDelay(afterFailures failures: Int) -> TimeInterval {
        min(30, 2 * pow(2, Double(max(0, failures - 1))))
    }

    /// Master: take an accepted connection as the current one, or refuse it (nil) when it comes from
    /// a device the pilot forgot. Trust starts from nothing: the new peer has to be allowed before it
    /// can act, whatever the previous one was allowed. (SEC-C40, S9-09, S9-28)
    func adoptMasterConnection(identity: CompanionPeerIdentity?,
                               send: @escaping @Sendable (CompanionMessage) async throws -> Void) -> Int? {
        // A connection the listener accepted just before `beginPairing()` cancelled it: closed, so
        // the pairing screen keeps the service to itself.
        if isPairing {
            diag("Master: a connection arrived while pairing, closed", isPublic: true)
            return nil
        }
        if Self.refusesPeer(identity, forgotten: forgottenDevices.ids) {
            lifecycle(identity == nil ? "Master: refused a peer not identified, a device is forgotten on this iPad"
                                      : "Master: refused a device forgotten on this iPad", detail: identity?.name)
            return nil
        }
        connectionGeneration += 1
        resetPeerTrust()   // before anything is streamed to this peer
        peerLink = CompanionPeerLink(generation: connectionGeneration, identity: identity)
        sendHandler = send
        connectionState = .connected
        connectedDeviceName = identity?.name ?? L10n.Companion.companionDevice
        sendFailingSince = nil
        listenerFailures = 0
        lastReceivedAt = Date()
        startSendTimer()              // stream state 1 Hz while connected (flight or not)
        startConnectionHealthTimer()
        lifecycle(identity == nil ? "Master: link up, peer not identified" : "Master: link up",
                  detail: identity?.name)
        return connectionGeneration
    }

    /// The paired device at the other end of an accepted connection, from its Wi-Fi Aware path.
    ///
    /// The path can lag the accept by a moment, hence a few short tries; and the whole thing is
    /// capped, because a companion that never connects is worse than one whose peer has no name.
    /// Nil when Wi-Fi Aware will not say. (S9-28)
    @available(iOS 26.0, *)
    private nonisolated static func peerIdentity<P: NetworkProtocolOptions>(
        of connection: NetworkConnection<P>
    ) async -> CompanionPeerIdentity? {
        await firstResult(within: .milliseconds(800)) {
            for attempt in 0..<3 {
                if let path = connection.currentPath, let wifiAware = try? await path.wifiAware {
                    return CompanionPeerIdentity(wifiAware.endpoint.device)
                }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(200)) }
            }
            return nil
        }
    }

    /// `work`'s result, or nil when it has not finished within `timeout`: the caller moves on either
    /// way, and a late result is dropped.
    private nonisolated static func firstResult<T: Sendable>(
        within timeout: Duration, _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        let waiting = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: nil)
        return await withCheckedContinuation { continuation in
            waiting.withLock { $0 = continuation }
            Task {
                let value = await work()
                waiting.withLock { $0?.resume(returning: value); $0 = nil }
            }
            Task {
                try? await Task.sleep(for: timeout)
                waiting.withLock { $0?.resume(returning: nil); $0 = nil }
            }
        }
    }

    /// Reports THIS device's own premium entitlement (SA-26, S9-30).
    ///
    /// The master needs it before any premium checklist text goes out; the viewer reports it in its
    /// hello, which the master takes as one of the two ways to let the text through (a master on 6.0
    /// or older takes it as the only one).
    ///
    /// A closure rather than a stored reference so the manager keeps no dependency on
    /// SubscriptionManager and stays usable in tests and previews. Absent ⇒ not entitled, which is
    /// the fail-closed direction: the worst case is a legitimate subscriber briefly seeing the
    /// redacted stream, never an unentitled peer seeing premium text.
    var entitlementProvider: (() -> Bool)?

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
            Task { @MainActor in self?.streamTick() }
        }
    }

    /// Master: one tick of the stream: the flight data, and the checklist and the plan when they
    /// changed (or are due again). Internal, with `now`, for the tests; the timer passes the clock.
    func streamTick(now: Date = Date()) {
        guard connectionState == .connected, currentRole == .master else { return }
        sendFlightData()
        sendChecklistSnapshot()
        sendFlightPlanSnapshotIfChanged(now: now)
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
    ///
    /// A no-op while a pairing screen is up (`isPairing`), whoever calls; `endPairing()` calls it again.
    ///
    /// Nothing else holds it back since 6.1.0: the idle saving no longer stops the iPad's listener, so
    /// there is no idle state for a "forced" call to clear.
    func autoConnectIfReady() {
        guard #available(iOS 26.0, *) else { return }
        guard !isPairing else {
            AppLog.companion.publicLine("Auto-connect held, pairing in progress")
            return
        }
        guard let appState, appState.settings.enableCompanionMode, hasPairedDevices else { return }
        guard connectionState == .disconnected else { return }
        switch CompanionRole.automatic(for: UIDevice.current.userInterfaceIdiom) {
        case .master: startListening()
        case .viewer: connectToPairedDevice()
        case .none: break
        }
    }

    // MARK: - Pairing mode (6.1.0)

    /// True while a pairing screen is up (`CompanionPairingView`, either role).
    ///
    /// The pairing views publish (`DevicePairingView`, iPad) or subscribe (`DevicePicker`, iPhone)
    /// `_aerocheck._udp` themselves, and Wi-Fi Aware takes one publisher and one subscriber per service
    /// on a device (`serviceAlreadyPublishing` / `serviceAlreadySubscribing`). With a device already
    /// paired, auto-connect kept our own listener or browser on that service under the pairing screen.
    /// The 6.1.0 device check fits that: the iPhone saw the iPad, the iPad never got the request (the
    /// daemon skips a pairing session when "pairing mode is not active"). And an iPhone whose browse
    /// fails goes `.reconnecting`, which swaps the root to `CompanionFlightView` and takes Settings and
    /// the pairing screen down with it. The June pairing started with nothing paired, so nothing of
    /// ours ran then.
    ///
    /// So while this is set nothing of ours holds the service: `beginPairing()` ends the session, and
    /// `autoConnectIfReady`, `startListening`, `connectToPairedDevice` and `adoptMasterConnection`
    /// start nothing (which covers launch, foreground, flight start, the Companion screen, the re-arm
    /// after a drop and the viewer's retries). `endPairing()` hands back to auto-connect.
    ///
    /// Not `@Published`: no view shows it, so none has to re-render for it.
    private(set) var isPairing = false

    /// The pairing screen appeared: stop whatever of ours runs on the service and hold auto-connect.
    /// A connected peer is told, as on Disconnect, and comes back on its own next auto-connect.
    func beginPairing() {
        guard !isPairing else { return }
        isPairing = true
        let running = sessionOnTheService
        endSession()
        diag("Pairing mode on: \(running.map { "\($0) stopped" } ?? "nothing of ours was running"), auto-connect on hold",
             isPublic: true)
    }

    /// The pairing screen went away (paired, cancelled or torn down): auto-connect resumes, as the
    /// Companion screen it returns to does on appear.
    func endPairing() {
        guard isPairing else { return }
        isPairing = false
        autoConnectIfReady()
        diag("Pairing mode off: \(sessionOnTheService.map { "\($0) resumed" } ?? "nothing to resume")",
             isPublic: true)
    }

    /// What of ours holds the Wi-Fi Aware service right now, for the pairing log. Fixed text.
    private var sessionOnTheService: String? {
        guard connectionState != .disconnected else { return nil }
        switch currentRole {
        case .master: return "background listener"
        case .viewer: return "background browser"
        case .none: return nil
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
    /// other way), and EITHER side drops the link if the peer's traffic goes silent for too long. (v4.1)
    ///
    /// `now` for the tests; the timer passes the clock.
    func checkConnectionHealth(now: Date = Date()) {
        guard connectionState == .connected else { stopConnectionHealthTimer(); return }
        if currentRole == .viewer {
            sendPing()          // keep the UDP flow open + prove liveness to the master
            sendViewerHello()   // report entitlement so the master knows what it may stream (SA-26)
        }
        // A viewer's new connection that has not heard from the iPad yet gets less: see `firstFrameLimit`.
        let limit = currentRole == .viewer && !viewerHeardFromIPad
            ? CompanionTiming.firstFrameLimit : CompanionTiming.linkSilenceLimit
        if let last = lastReceivedAt, now.timeIntervalSince(last) > limit {
            handleDisconnection(generation: connectionGeneration,
                                reason: viewerHeardFromIPad || currentRole != .viewer
                                    ? .silence(Int(now.timeIntervalSince(last))) : .noFirstFrame)
            return
        }
        // Battery: master drops the hot link after a long idle stretch with no active flight, and
        // listens on. (v4.1; listening on since 6.1.0)
        if currentRole == .master, let appState, !appState.isFlightActive {
            if let idleSince {
                if now.timeIntervalSince(idleSince) > Self.idleDisconnectAfter {
                    sendMessage(CompanionMessage(type: .disconnect, payload: Data()))   // the phone stops retrying
                    handleDisconnection(generation: connectionGeneration,
                                        reason: .idle(minutes: Int(Self.idleDisconnectAfter / 60)))
                }
            } else {
                idleSince = now
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
        let hello = CompanionViewerHello(isSubscribed: entitlementProvider?() ?? false)
        guard let payload = try? JSONEncoder().encode(hello) else { return }
        sendMessage(CompanionMessage(type: .viewerHello, payload: payload))
    }

    /// Master/viewer: sends that keep failing mean the peer is gone: the link ends once they have
    /// failed for `linkSilenceLimit`. Internal, with `now`, for the tests.
    func noteSendFailure(generation: Int, error: any Error, now: Date = Date()) {
        guard generation == connectionGeneration, connectionState == .connected else { return }
        guard let since = sendFailingSince else {
            sendFailingSince = now
            lifecycle("\(currentRole == .master ? "Master" : "Viewer"): a send failed (\(Self.errorCode(error)))")
            return
        }
        if now.timeIntervalSince(since) > CompanionTiming.linkSilenceLimit {
            handleDisconnection(generation: generation, reason: .sendFailing)
        }
    }

    // MARK: - Viewer (iPhone) Methods

    /// Connect to a paired master device via Wi-Fi Aware
    func connectToPairedDevice() {
        // The pairing screen subscribes to the service itself (see `isPairing`). This also covers the
        // retry after a failed browse and the Companion screen's Connect to iPad button.
        guard !isPairing else {
            AppLog.companion.publicLine("Viewer: browse held, pairing in progress")
            return
        }
        browserTask?.cancel()

        // Supersede any prior attempt so its in-flight teardown/retry can't race this one. (PR-15)
        connectionGeneration += 1
        let myGeneration = connectionGeneration

        currentRole = .viewer
        // `.reconnecting` (the Companion screen) within the grace after a drop, `.connecting` (the
        // phone's own screens) otherwise. (6.1.0)
        connectionState = Self.viewerLookingState(linkLostAt: viewerLinkLostAt, now: Date())
        browseStarts += 1
        lifecycle("Viewer: looking for the iPad")

        // A test manager: looking, and finding nothing, the state the phone is in until the iPad answers.
        guard usesWiFiAware else { return }
        // Wi-Fi Aware browsing requires iOS 26+. Below that, stay inert. (ARCH-09)
        guard #available(iOS 26.0, *) else {
            connectionState = .disconnected
            diag("Viewer: aborted — Wi-Fi Aware needs iOS 26")
            return
        }

        // The iPads the pilot forgot on this phone are passed over. (S9-09)
        let forgotten = forgottenDevices.ids

        browserTask = Task { [weak self] in
            do {
                let browser = NetworkBrowser(
                    // Browse for any paired master — .allPairedDevices for the connection phase (sample-matched).
                    for: .wifiAware(.connecting(to: .allPairedDevices, from: .aerocheck))
                )

                // Browse for the master device
                let endpoint = try await browser.run { waEndpoints in
                    if let endpoint = waEndpoints.first(where: { !forgotten.contains($0.device.id) }) {
                        return .finish(endpoint)
                    }
                    return .continue
                }
                // The endpoint names the iPad it runs to; `pairedDevices.first` was whichever came
                // first in an unordered list. (S9-28)
                let identity = CompanionPeerIdentity(endpoint.device)

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

                // Adopted only if this browse is still the current one (see `adoptViewerConnection`).
                let stillCurrent = await MainActor.run { () -> Bool in
                    self?.adoptViewerConnection(identity: identity, generation: myGeneration, send: send) ?? false
                }
                // Superseded mid-establish — drop this stale connection instead of entering its receive
                // loop (which would keep feeding the manager messages from a connection the user dropped).
                guard stillCurrent else { return }

                // Receive typed messages until the connection ends (the Coder decodes each one).
                do {
                    for try await (message, _) in connection.messages {
                        let isCurrent = await MainActor.run { [weak self] in
                            self?.handleReceivedMessage(message, generation: myGeneration) ?? false
                        }
                        // Superseded by a newer connection: stop reading this one. (S9-28)
                        if !isCurrent { break }
                    }
                } catch {
                    if !Task.isCancelled {
                        AppLog.companion.debugLine("Receive error: \(error)")
                    }
                }

                // Connection ended
                await MainActor.run {
                    self?.handleDisconnection(generation: myGeneration, reason: .receiveEnded)
                }
            } catch {
                await MainActor.run {
                    guard let self, self.connectionGeneration == myGeneration else { return }
                    self.lifecycle("Viewer: browse failed (\(Self.errorCode(error))), retry in 3 s")
                    // Still looking: the Companion screen only within the grace after a drop. A first
                    // browse that failed used to swap the root to the Companion screen. (6.1.0)
                    self.connectionState = Self.viewerLookingState(linkLostAt: self.viewerLinkLostAt, now: Date())
                    // Auto-retry after delay, only while this attempt is still the current one. (PR-15)
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3))
                        if self.connectionState != .disconnected, self.connectionState != .connected,
                           self.connectionGeneration == myGeneration {
                            self.connectToPairedDevice()
                        }
                    }
                }
            }
        }

        AppLog.companion.debugLine("Browsing for paired master device...")
    }

    /// Viewer: take the connection a browse made as the current one, unless that browse was superseded
    /// while it ran (`generation` no longer current): false, and the connection is dropped. Re-checked
    /// here, BEFORE adopting: `browser.run` and the connection's set-up can suspend for a long time, and
    /// adopting a connection after disconnect() or a newer browse would resurrect a link the user just
    /// tore down, re-arming the send handler and the health timer and flipping the UI back to
    /// .connected. (v4.1.0 pre-tag fix, M2)
    func adoptViewerConnection(identity: CompanionPeerIdentity, generation: Int,
                               send: @escaping @Sendable (CompanionMessage) async throws -> Void) -> Bool {
        guard connectionGeneration == generation, currentRole == .viewer else { return false }
        sendHandler = send
        peerLink = CompanionPeerLink(generation: generation, identity: identity)
        connectionState = .connected
        connectedDeviceName = identity.name ?? L10n.Companion.masterDevice
        sendFailingSince = nil
        viewerHeardFromIPad = false
        lastReceivedAt = Date()
        startConnectionHealthTimer()
        // Open the UDP flow immediately — until the master receives a datagram from us, its listener
        // never accepts and it never streams back. (v4.1)
        sendPing()
        // And say at once what we may be sent, rather than on the first health tick 2 s later, as the
        // hello's own comment already promised. (v6.0 review, security)
        sendViewerHello()
        lifecycle("Viewer: link up", detail: identity.name)
        return true
    }

    /// Send a command to the master device
    func sendCommand(_ command: CompanionCommand) {
        #if DEBUG
        // The debug viewer scene has no link: its commands act on the flight it shows, through the
        // master's own code.
        if debugLoopback, let flightPlanManager {
            Self.apply(command, appState: appState, flightPlanManager: flightPlanManager)
            return
        }
        #endif
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
        endSession()
        lifecycle("Disconnected by the user")
    }

    /// End whatever runs: the connection (the peer is told), the iPad's listener, the iPhone's browse,
    /// and any re-arm or retry still pending (each checks the generation bumped here). Disconnect, and
    /// the start of a pairing.
    private func endSession() {
        // Supersede the current connection so any in-flight teardown/reconnect is invalidated. (PR-15)
        connectionGeneration += 1

        // Send graceful disconnect message
        if connectionState == .connected, sendHandler != nil {
            let message = CompanionMessage(type: .disconnect, payload: Data())
            sendMessage(message)
        }

        cleanupConnection()   // also releases the GPS provider + clears peer-fix state (shared-GPS)
        listenerFailures = 0
        viewerLinkLostAt = nil
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

    /// Viewer: the link dropped. The Companion screen stays up (`.reconnecting`) for
    /// `CompanionTiming.reconnectGrace` while the phone looks again, then the phone goes back to its own
    /// screens and keeps looking. (6.1.0)
    private func startViewerGrace() {
        let lostAt = Date()
        viewerLinkLostAt = lostAt
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(CompanionTiming.reconnectGrace))
            guard let self, self.viewerLinkLostAt == lostAt else { return }
            self.viewerLinkLostAt = nil
            guard self.currentRole == .viewer, self.connectionState == .reconnecting else { return }
            self.connectionState = .connecting
            self.lifecycle("Viewer: no iPad for \(Int(CompanionTiming.reconnectGrace)) s, "
                           + "back to the phone's own screens, still looking")
        }
    }

    /// What the viewer's state reads while it looks for the iPad: `.reconnecting` within the grace after
    /// a drop, which the root shows the Companion screen for, `.connecting` otherwise.
    nonisolated static func viewerLookingState(linkLostAt: Date?, now: Date) -> CompanionConnectionState {
        guard let linkLostAt, now.timeIntervalSince(linkLostAt) < CompanionTiming.reconnectGrace else {
            return .connecting
        }
        return .reconnecting
    }

    // MARK: - Foreground and background (6.1.0)

    /// The app went to the background: coming back checks the link (`appBecameActive`).
    func appWentToBackground() {
        wasInBackground = true
    }

    /// The app is active again: at launch, back from the background, or a system sheet gone. With
    /// nothing running, auto-connect, as always. Back from the background, also: a live link is checked
    /// at once rather than at the next tick, and a listener or a browse that was running is started
    /// afresh, since one left over a suspension can be dead without saying so.
    func appBecameActive() {
        let fromBackground = wasInBackground
        wasInBackground = false
        switch connectionState {
        case .disconnected:
            autoConnectIfReady()
        case .connected:
            if fromBackground { checkConnectionHealth() }
        case .connecting, .reconnecting:
            guard fromBackground, !isPairing else { return }
            switch currentRole {
            case .master:
                lifecycle("Master: back from the background, listening afresh")
                startListening()
            case .viewer:
                lifecycle("Viewer: back from the background, looking afresh")
                connectToPairedDevice()
            case .none:
                break
            }
        case .pairing:
            break
        }
    }

    /// Why a link ended, for the log: fixed text, never a device name.
    enum LinkEnd: Equatable {
        /// The peer said goodbye (`.disconnect`): Companion mode off or Disconnect there, its idle
        /// saving, a pairing, a Forget.
        case peerLeft
        /// Nothing heard from the peer for that many seconds.
        case silence(Int)
        /// Viewer: a new connection that never heard from the iPad (`firstFrameLimit`).
        case noFirstFrame
        case sendFailing
        /// The connection's receive loop ended (closed, cancelled or failed).
        case receiveEnded
        /// Master: up that long with no flight (battery).
        case idle(minutes: Int)
        /// Master: the pilot forgot the connected device.
        case forgotten

        var text: String {
            switch self {
            case .peerLeft: return "the peer left"
            case .silence(let seconds): return "nothing heard for \(seconds) s"
            case .noFirstFrame: return "the iPad never answered"
            case .sendFailing: return "sends failing"
            case .receiveEnded: return "the connection closed"
            case .idle(let minutes): return "idle \(minutes) min with no flight"
            case .forgotten: return "the device was forgotten"
            }
        }
    }

    /// A link ended without the user asking: the viewer reconnects, the master listens again.
    ///
    /// Internal for the tests. A teardown from a connection already superseded (by a newer connection,
    /// a Disconnect, a pairing) is ignored, or a stale receive loop ending would clobber the live
    /// connection's state and spawn a duplicate reconnect. (PR-15)
    func handleDisconnection(generation: Int, reason: LinkEnd) {
        guard generation == connectionGeneration else {
            AppLog.companion.debugLine("Ignoring teardown from stale connection (gen \(generation))")
            return
        }

        cleanupConnection()

        if currentRole == .viewer && connectionState != .disconnected {
            lifecycle("Viewer: link down, \(reason.text); looking for the iPad again in 2 s")
            // The Companion screen stays up, its "connection lost" banner on, while the phone looks
            // again: within the grace, the browse keeps `.reconnecting`, which the root shows it for.
            // (6.1.0)
            // A connection that never heard from the iPad was no link: it keeps the grace it was made
            // in, if any, rather than start one.
            if reason != .noFirstFrame { startViewerGrace() }
            connectionState = Self.viewerLookingState(linkLostAt: viewerLinkLostAt, now: Date())
            // Auto-reconnect, only while this connection is still the current one. (PR-15)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if connectionState != .disconnected, connectionState != .connected,
                   currentRole == .viewer, connectionGeneration == generation {
                    connectToPairedDevice()
                }
            }
        } else if currentRole == .master {
            // A new generation: the ended connection's frames, and its receive loop's own teardown when
            // the listener below is replaced, are stale from here. That teardown carried the still-current
            // generation and re-armed a second time, cancelling the fresh listener just after it started,
            // and a listener started while the previous publish is still going can fail (one publisher per
            // service). (6.1.0)
            connectionGeneration += 1
            let rearm = connectionGeneration
            connectionState = .connecting
            connectedDeviceName = nil
            // Re-arm a FRESH listener. Keeping the old one running wedges it — after a drop it won't
            // accept the viewer's reconnect (observed on device: only an iPad app restart recovered).
            // startListening() cancels + recreates the listener, after a short pause: it is not cancelled
            // from inside its own teardown, a goodbye just queued still goes out, and the old publish has
            // a moment to go. (v4.1; the pause 6.1.0)
            lifecycle("Master: link down, \(reason.text); listening again")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard self.connectionGeneration == rearm, self.currentRole == .master,
                      self.connectionState == .connecting else { return }
                self.startListening()
            }
        }
    }

    private func cleanupConnection() {
        sendHandler = nil
        resetPeerTrust()
        stopConnectionHealthTimer()
        stopUpdates()
        sendFailingSince = nil
        idleSince = nil
        lastSentChecklist = nil
        lastSentPlan = nil
        lastPlanSentAt = nil
        // Reset the shared-GPS state on EVERY teardown (graceful or not), so a stale peer fix can't keep
        // the source election pinned to .peer, can't masquerade as a usable fix to the flight-start guard
        // (hasUsablePeerFix), and the viewer's background GPS provider isn't stranded. (shared-GPS)
        stopProvidingGPS()
        receivedPeerGPS = nil
        lastPeerGPSReceivedAt = nil
        effectiveGPSSource = .own
    }

    /// A new peer is authorised again (SEC-C40): trust is per connection. This used to happen only on
    /// a graceful `.disconnect` message, so after a Wi-Fi Aware drop (health timeout, send failure,
    /// end of the receive loop) the next device to connect, possibly another phone paired to a shared
    /// club iPad, inherited the last one's right to drive the checklist. Now every teardown, and every
    /// accepted connection, resets it; the link itself carries the trust, so there is nothing left
    /// over to inherit. (v6.0 review, security; S9-28)
    private func resetPeerTrust() {
        peerLink = nil
        pendingAuthorization = nil
    }

    // MARK: - Peer authorisation (SEC-C40)

    /// Whether the current peer may act on this flight: drive the checklist or the waypoints, or feed
    /// its position into it. The first request of a connection asks the pilot; until the answer, and
    /// after a Don't Allow, requests are dropped without asking again. (SEC-C40, S9-08, S9-09)
    private func peerIsAuthorised() -> Bool {
        guard var link = peerLink else { return false }
        let (admitted, ask) = link.admit()
        peerLink = link
        if ask {
            pendingAuthorization = CompanionAuthorizationRequest(generation: link.generation,
                                                                 deviceName: link.identity?.name)
            diag("Master: \(link.identity?.name ?? "unnamed peer") asked to act on the flight, awaiting the pilot")
        }
        return admitted
    }

    /// The pilot's answer, for the connection it was asked about only. A connection that has since
    /// ended or been replaced gets nothing from it, the new one in particular. (S9-28)
    func answerAuthorization(_ request: CompanionAuthorizationRequest, allow: Bool) {
        if pendingAuthorization == request { pendingAuthorization = nil }
        guard var link = peerLink, link.generation == request.generation else {
            diag("Master: answer for a connection that has ended, ignored")
            return
        }
        link.authorization = allow ? .allowed : .denied
        peerLink = link
        diag("Master: pilot \(allow ? "allowed" : "did not allow") \(link.identity?.name ?? "the peer") for this connection")
        // An Allow also lets the checklist text through (S9-30): send it now, not on the next tick.
        sendChecklistSnapshot()
    }

    /// The prompt went away without an answer (SwiftUI can drop an alert it cannot present). The
    /// connection may then ask once more, rather than stay undecided and silently ignored for good.
    func authorizationPromptDismissed(_ request: CompanionAuthorizationRequest) {
        if pendingAuthorization == request { pendingAuthorization = nil }
        guard var link = peerLink, link.generation == request.generation,
              link.authorization == .undecided else { return }
        link.hasAsked = false
        peerLink = link
    }

    // MARK: - Message Sending (Length-Prefixed JSON)

    private func sendMessage(_ message: CompanionMessage) {
        guard let sendHandler else { return }
        let gen = connectionGeneration
        Task {
            do {
                try await sendHandler(message)   // the Coder encodes/frames it
                await MainActor.run { self.sendFailingSince = nil }
            } catch {
                // Failing sends may mean the peer is gone: surface them instead of swallowing. (v4.1)
                await MainActor.run { self.noteSendFailure(generation: gen, error: error) }
            }
        }
    }

    // MARK: - Message Handling

    /// Handle one frame from the connection of `generation`. False, and the frame dropped, when that
    /// connection is no longer the current one: its frames used to be processed as if they came from
    /// the current peer (commands under the current peer's authorisation, a stray `.disconnect`
    /// kicking the legitimate viewer). The receive loop stops on false. (S9-28) False too after the
    /// peer's goodbye (`.disconnect`), whose connection is done. (6.1.0)
    @discardableResult
    func handleReceivedMessage(_ message: CompanionMessage, generation: Int) -> Bool {
        guard generation == connectionGeneration else {
            AppLog.companion.debugLine("Dropped a \(message.type.rawValue) frame from a superseded connection (gen \(generation))")
            return false
        }
        lastReceivedAt = Date()   // any inbound traffic = the link is alive (connection-health watchdog)
        if currentRole == .viewer, !viewerHeardFromIPad {
            viewerHeardFromIPad = true
            viewerLinkLostAt = nil   // the iPad answers: back, the grace is over
        }
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
                    return true
                }
                // S9-09: a borrowed fix becomes the aircraft's position on the nav display and in
                // the recorded track, so it needs the same answer from the pilot as a command. Only
                // commands were gated, and any once-paired device in range could feed a GPS-less
                // iPad a plausible false position.
                guard peerIsAuthorised() else { return true }
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
            // The viewer's claim, kept on its connection's link: one of the two ways the checklist
            // text reaches it, and only from an entitled iPad (S9-30, see `mayStreamItemText`).
            if currentRole == .master,
               let hello = try? JSONDecoder().decode(CompanionViewerHello.self, from: message.payload),
               var link = peerLink, link.claimsEntitlement != hello.isSubscribed {
                link.claimsEntitlement = hello.isSubscribed
                peerLink = link
                diag("Master: viewer reports entitlement = \(hello.isSubscribed)")
                // Re-send with the new redaction level applied.
                sendChecklistSnapshot()
            }

        case .disconnect:
            switch currentRole {
            case .master:
                // The phone left (Companion mode turned off there, its Disconnect, its app closing):
                // its connection goes and the iPad listens again at once, so turning Companion mode back
                // on on the phone reconnects. The iPad used to go "disconnected" here, its old listener
                // still up but never taking the phone's next connection, until Companion mode was
                // toggled on the iPad. (6.1.0)
                handleDisconnection(generation: generation, reason: .peerLeft)
            case .viewer:
                viewerLinkEndedByIPad()
            case .none:
                break
            }
            // Stop reading the connection that said goodbye.
            return false
        }
        return true
    }

    /// Viewer: the iPad ended the link (Companion mode off or Disconnect there, its idle saving, a
    /// pairing, a Forget). The phone stops, and comes back when it is used: its app back in the
    /// foreground, Companion mode turned on, its Companion screen. Its browse and connection end here
    /// too, rather than stay open under the next one. (6.1.0)
    private func viewerLinkEndedByIPad() {
        connectionGeneration += 1   // the connection's own teardown is stale from here
        cleanupConnection()
        viewerLinkLostAt = nil
        browserTask?.cancel()
        browserTask = nil
        connectionState = .disconnected
        connectedDeviceName = nil
        lifecycle("Viewer: link down, the iPad ended it; waiting to be used again")
    }

    private func handleCommand(_ command: CompanionCommand) {
        guard currentRole == .master else { return }

        // The viewer's keep-alive changes nothing, so it needs no authorisation, and it must never
        // raise the prompt: it arrives every 2 s from every viewer, the first datagram of each
        // connection included, and asked "allow control?" of a phone that was only viewing. (S9-08)
        if case .ping = command { return }

        // SEC-C40: being paired is not authorisation to control this flight.
        guard peerIsAuthorised(), let flightPlanManager else { return }

        Self.apply(command, appState: appState, flightPlanManager: flightPlanManager)
    }

    /// What a command does on the master once it is allowed: the iPad's own action, as a tap there
    /// would do it. Apart from the checks above, so the debug viewer scene and the tests run exactly
    /// this. (v6.0 review, decision 2)
    static func apply(_ command: CompanionCommand, appState: AppState?, flightPlanManager: FlightPlanManager) {
        switch command {
        case .recordATO(let waypointIndex):
            flightPlanManager.recordATO(forWaypointAt: waypointIndex)

        case .updateGroundSpeed(let waypointIndex, let newGS):
            // A speed from the wire goes into the leg calculation: an impossible one is refused, as
            // the iPad's own waypoint editor refuses it.
            guard CompanionWireLimits.groundSpeedKnots.contains(newGS),
                  var plan = flightPlanManager.activeFlightPlan,
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

        // The phone's DEFER and its deferred list do exactly what the iPad's do. (v6.0 review, decision 2)
        case .deferChecklistItem:
            appState?.deferHighlightedItem()

        case .checkDeferredItem(let phaseRawValue, let itemId):
            if let phase = ChecklistPhase(rawValue: phaseRawValue) {
                appState?.checkDeferredItem(itemId, in: phase)
            }

        case .checkInDeferredCheck(let phaseRawValue):
            if let phase = ChecklistPhase(rawValue: phaseRawValue) {
                appState?.checkItem(inDeferredCheck: phase)
            }

        case .deferInDeferredCheck(let phaseRawValue):
            if let phase = ChecklistPhase(rawValue: phaseRawValue) {
                appState?.deferItem(inDeferredCheck: phase)
            }

        case .toggleChecklistItem(let phaseRawValue, let itemId):
            guard let appState, appState.currentPhase.rawValue == phaseRawValue else { return }
            let items = appState.activeChecklist.visibleItems(for: appState.currentPhase,
                                                              learningMode: appState.effectiveLearningMode)
            if let index = items.firstIndex(where: { $0.id == itemId }) {
                appState.toggleItem(at: index)
            }

        // ✓ DONE on the phone: the current memory check, or one deferred whole, as the iPad's own. (6.1)
        case .confirmMemoryCheck(let phaseRawValue):
            guard let appState, let phase = ChecklistPhase(rawValue: phaseRawValue),
                  phase == appState.currentPhase || appState.deferredChecks.contains(phase) else { return }
            appState.confirmMemoryCheck(phase)

        case .undoMemoryCheck(let phaseRawValue):
            guard let appState, let confirmation = appState.memoryConfirmation,
                  confirmation.phase.rawValue == phaseRawValue else { return }
            appState.undoMemoryConfirmation(confirmation.id)

        // ✓ DONE · NEXT on the phone: the iPad's own one tap. Only on the check being flown, so a tap
        // arriving after the iPad moved on does nothing. (6.1)
        case .confirmMemoryCheckAndNext(let phaseRawValue):
            guard let appState, appState.currentPhase.rawValue == phaseRawValue else { return }
            appState.confirmMemoryCheckAndAdvance()

        // The slot's tap from the phone: only while the iPad's slot still names that check and does that
        // (a tap arriving after it changed does nothing). SHOW CHECKLIST is the phone's own mode. (6.1)
        case .checkSlotTap(let phaseRawValue, let action):
            guard let appState, appState.isFlightActive else { return }
            let slot = CockpitCheckSlot.slot(for: appState)
            guard slot.phase.rawValue == phaseRawValue, slot.action.rawValue == action,
                  slot.action != .showChecklist else { return }
            CockpitCheckSlot.perform(slot.action, appState: appState, onShowChecklist: {})

        // The landed card answered from the phone: that card only. (6.1, M4)
        case .answerLandedCard(let cardId, let answer):
            guard let appState, appState.landedCard?.id == cardId,
                  let answer = LandedAnswer(rawValue: answer) else { return }
            appState.answerLandedCard(answer)
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

    /// Master: the active plan, when it differs from the one last sent or that one is due again (see
    /// `lastSentPlan`).
    private func sendFlightPlanSnapshotIfChanged(now: Date) {
        guard sendHandler != nil, connectionState == .connected,
              let plan = flightPlanManager?.activeFlightPlan else { return }
        let snapshot = createFlightPlanSnapshot(plan)
        let due = lastPlanSentAt.map { now.timeIntervalSince($0) >= CompanionTiming.snapshotRefresh } ?? true
        guard snapshot != lastSentPlan || due else { return }
        do {
            let payload = try JSONEncoder().encode(snapshot)
            sendMessage(CompanionMessage(type: .flightPlanUpdate, payload: payload))
            lastSentPlan = snapshot
            lastPlanSentAt = now
        } catch {
            AppLog.companion.debugLine("Failed to encode flight plan: \(error)")
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

    #if DEBUG
    private var debugLoopback = false

    /// DEV-ONLY (`AEROCHECK_SCENE=companion`): this device shows the Companion viewer of its own flight,
    /// refreshed every second from the local state, so the viewer can be checked and captured on one
    /// simulator. Wi-Fi Aware needs two real devices. Its commands act on that same flight, through
    /// `apply`, as the iPad would take them from a phone.
    func showAsViewerOfOwnFlight(appState: AppState, locationManager: LocationManager,
                                 flightPlanManager: FlightPlanManager) {
        configure(appState: appState, locationManager: locationManager, flightPlanManager: flightPlanManager)
        debugLoopback = true
        currentRole = .viewer
        connectionState = .connected
        connectedDeviceName = "iPad"
        Task { @MainActor in
            for _ in 0..<600 {
                lastReceivedData = createCompanionFlightData(appState: appState, locationManager: locationManager,
                                                             flightPlanManager: flightPlanManager)
                lastFlightPlanSnapshot = flightPlanManager.activeFlightPlan.map { createFlightPlanSnapshot($0) }
                lastReceivedChecklist = Self.checklistSnapshot(of: appState, mayStreamItemText: true)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    #endif

    /// Master: snapshot the current checklist phase + its visible items + highlight, for the viewer to
    /// show and drive. (companion v2 — synced checklist)
    private func createChecklistSnapshot() -> CompanionChecklistSnapshot? {
        guard let appState else { return nil }
        return Self.checklistSnapshot(of: appState, mayStreamItemText: streamsItemText)
    }

    /// Whether the checklist's words go to the current viewer right now. (SA-26, S9-30)
    var streamsItemText: Bool {
        Self.mayStreamItemText(masterIsEntitled: entitlementProvider?() ?? false,
                               viewerClaimsEntitlement: peerLink?.claimsEntitlement ?? false,
                               connectionAllowed: peerLink?.authorization == .allowed,
                               remoteAircraftSelected: appState?.settings.isRemoteAircraftSelected ?? true)
    }

    /// SA-26: the bundled aircraft's words always go out; a Pro aircraft's only from an iPad itself
    /// entitled to them, and then to a viewer that says it is subscribed or that the pilot allowed
    /// for this connection. (The reasoning is at the call in `checklistSnapshot`.)
    ///
    /// S9-30: this used to follow the viewer's claim alone, `CompanionViewerHello.isSubscribed`, a
    /// boolean nothing verifies, so a rebuilt viewer that said true on any iPad read the whole
    /// premium checklist. The iPad's own entitlement is now required, since it is the one thing here
    /// the iPad can check: one whose subscription lapsed streams no premium text whatever the viewer
    /// says. The claim still counts on an entitled iPad, so the subscriber's own iPhone (same Apple
    /// ID) needs no prompt; an unsubscribed phone gets the text once the pilot allows its connection
    /// (a Don't Allow keeps it off for that connection). A lying phone still needs a subscriber's
    /// iPad and the subscriber's pairing, and the subscriber has Forget (S9-09).
    nonisolated static func mayStreamItemText(masterIsEntitled: Bool, viewerClaimsEntitlement: Bool,
                                              connectionAllowed: Bool, remoteAircraftSelected: Bool) -> Bool {
        guard remoteAircraftSelected else { return true }
        return masterIsEntitled && (viewerClaimsEntitlement || connectionAllowed)
    }

    /// The snapshot itself, apart from the connection, so the SA-26 redaction can be tested against a
    /// real checklist.
    static func checklistSnapshot(of appState: AppState, mayStreamItemText: Bool) -> CompanionChecklistSnapshot {
        let phase = appState.currentPhase
        // Effective learning mode includes a hold-to-reveal, so revealing on either device streams the
        // hidden items to the viewer (and vice-versa). (companion v2 — hidden-content parity)
        let learning = appState.effectiveLearningMode
        let visible = appState.activeChecklist.visibleItems(for: phase, learningMode: learning)

        // SA-26: stream the actual challenge/response text only when it may go (see
        // `mayStreamItemText`: this iPad's own entitlement, and the viewer's claim or the pilot's
        // Allow, since S9-30). Pairing is one system sheet plus one confirmation code, after which
        // the devices reconnect automatically in proximity.
        // The viewer still gets the phase title, progress counters and highlight, so the
        // second-screen layout is intact; only the words are withheld. (Driving the checklist needs
        // the pilot's per-connection answer on top, SEC-C40.)
        //
        // Bundled/free aircraft always stream in full. `isUsingRemoteAircraft` is the conservative
        // signal available here — today every remote aircraft is premium, and if a free one ever
        // ships, withholding its text from an unentitled peer is the harmless direction to err.
        //
        // Defence in depth, NOT a server gap: the paid content is legitimately on the paying
        // device, which is the one deciding.
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
            hiddenItemCount: hiddenCount,
            // Withheld like the items: an item's id is built from its challenge text
            // ("3.I.Fuel selector"), so the ids alone would hand an unentitled viewer the challenges
            // of every deferred item. The count carries no text and always goes. (v6.0 review, security)
            deferredItemIds: mayStreamItemText ? (appState.deferredItems[phase] ?? []) : [],
            deferredItemCount: appState.deferredItemCount,
            // The list the viewer checks from, with the same SA-26 gate as the items.
            deferredGroups: mayStreamItemText ? appState.deferredChecklist.map { group in
                CompanionDeferredGroup(
                    phaseRawValue: group.phase.rawValue, phaseTitle: group.phase.title,
                    items: group.items.map {
                        CompanionChecklistItem(id: $0.id, challenge: $0.challenge, response: $0.response, isHeader: $0.isHeader)
                    })
            } : [],
            openItemCount: appState.openItems(in: phase).count,
            supportsDefer: true,
            deferredChecks: appState.deferredCheckList.map { check in
                CompanionDeferredCheck(
                    phaseRawValue: check.phase.rawValue, phaseTitle: check.phase.title,
                    remaining: check.remaining, total: check.total,
                    items: mayStreamItemText ? appState.checkItems(check.phase).map {
                        CompanionChecklistItem(id: $0.id, challenge: $0.challenge, response: $0.response, isHeader: $0.isHeader)
                    } : [],
                    highlightedIndex: appState.getHighlightedItem(for: check.phase),
                    deferredItemIds: mayStreamItemText ? (appState.deferredItems[check.phase] ?? []) : [],
                    fromMemory: appState.isMemoryCheck(check.phase, learningMode: appState.settings.learningMode))
            },
            memoryCheck: appState.isMemoryCheck(phase),
            memoryCheckDone: appState.isMemoryCheck(phase) && appState.currentCheckIsDone,
            supportsMemoryConfirm: true,
            memoryCheckNextRawValue: appState.memoryConfirmationMovesTo?.rawValue,
            // The slot and the landed card, drawn on the phone as here. No checklist text in either:
            // check names, counts and times only. (6.1, cues)
            checkSlotData: appState.isFlightActive ? try? JSONEncoder().encode(CockpitCheckSlot.slot(for: appState)) : nil,
            landedCard: appState.landedCard.map {
                CompanionLandedCard(id: $0.id, aerodrome: $0.aerodrome, touchdown: $0.touchdown,
                                    landingCheckSettled: appState.landingCheckSettled)
            },
            supportsFlightCues: true
        )
    }

    /// Master: stream the current checklist to the viewer (sent each tick alongside flight data — the
    /// payload is small and the viewer needs it to stay in sync as items/phase advance).
    private func sendChecklistSnapshot() {
        guard sendHandler != nil, connectionState == .connected, currentRole == .master,
              let snapshot = createChecklistSnapshot() else { return }
        // Skip the encode + radio send when nothing changed since the last send (CompanionChecklistSnapshot
        // is Equatable). (efficiency)
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
            // `screenBrightness` matters here too: without it the parameter defaults to 0, the sunlight
            // boost never engages, and a master iPad on the high-contrast palette streamed `.day` to
            // the companion — two screens side by side disagreeing. (review, missed caller)
            cockpitThemeMode: appState.settings.cockpitThemeMode(systemIsDark: appState.deviceIsDark,
                                                                 screenBrightness: Double(UIScreen.main.brightness)).rawValue,
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
            chronometerStartTime: plan.chronometerStartTime,
            diversion: plan.diversion.map { field in
                CompanionWaypoint(id: plan.id, name: field.ident, latitude: field.latitude,
                                  longitude: field.longitude, altitude: field.elevationFeet,
                                  frequency: field.frequency, magneticCourse: nil, distance: nil,
                                  plannedGroundSpeed: nil, estimatedElapsedTime: nil, legEETExtra: nil,
                                  cumulativeEET: nil, estimatedTimeOver: nil, actualTimeOver: nil,
                                  remarks: field.name)
            }
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
