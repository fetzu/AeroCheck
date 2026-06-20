import Foundation
import Network

/// A point-in-time snapshot of the network path, decoupled from `NWPath` so the refresh-policy
/// decisions below are unit-testable without a live network interface.
///
/// These are HINTS for deciding *whether* to start a refresh. The actual enforcement happens at the
/// request layer (`URLRequest.allowsConstrainedNetworkAccess` / `allowsExpensiveNetworkAccess`,
/// fail-closed), so a stale or wrong hint can never let a forbidden transfer through. (v4.1.0 Data Freshness)
struct NetworkConditions: Equatable, Sendable {
    /// The path can carry traffic (`NWPath.status == .satisfied`).
    var isConnected: Bool
    /// The active path uses Wi-Fi.
    var isWiFi: Bool
    /// The active path is metered — cellular or Personal Hotspot (`NWPath.isExpensive`).
    var isExpensive: Bool
    /// The user has Low Data Mode enabled for the active path (`NWPath.isConstrained`).
    var isConstrained: Bool

    /// Nothing reachable — the conservative default before the first path update arrives.
    static let disconnected = NetworkConditions(isConnected: false, isWiFi: false, isExpensive: false, isConstrained: false)
}

extension NetworkConditions {
    /// Derive the decision-relevant snapshot from a live `NWPath`.
    init(path: NWPath) {
        self.init(
            isConnected: path.status == .satisfied,
            isWiFi: path.usesInterfaceType(.wifi),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}

/// Pure connectivity policy for data refresh — separated from `NetworkMonitor` so every branch is
/// unit-tested without a live interface. These functions decide whether a refresh/download is
/// permitted *given* the current `NetworkConditions`; the per-dataset refresh policy (added in a later
/// increment) selects which gate applies. Enforcement still happens at the request layer. (v4.1.0 Data Freshness)
enum DataRefreshGate {

    /// Silent automatic refresh of SMALL aeronautical JSON (airspace / airports / navaids / obstacles /
    /// reporting points / checklists). These are a few MB at most, so cellular is allowed — unless the
    /// user turned cellular updates off — but Low Data Mode always blocks a *silent* refresh, and an
    /// offline path obviously can't refresh.
    static func allowsSilentSmallRefresh(_ conditions: NetworkConditions, cellularUpdatesEnabled: Bool) -> Bool {
        guard conditions.isConnected else { return false }
        if conditions.isConstrained { return false }                          // Low Data Mode → never silent
        if conditions.isExpensive && !cellularUpdatesEnabled { return false }  // cellular + toggle off
        return true
    }

    /// A LARGE tile download (Swiss ICAO/Segelflug ~2 GB, OpenAIP imagery). Never silent or automatic.
    /// On Wi-Fi it may proceed; on a metered path it proceeds only behind an explicit, size-shown user
    /// confirmation (`userConfirmedCellular`). Low Data Mode keeps the same confirmation gate.
    static func allowsTileDownload(_ conditions: NetworkConditions, userConfirmedCellular: Bool) -> Bool {
        guard conditions.isConnected else { return false }
        if conditions.isExpensive { return userConfirmedCellular }
        return true
    }
}

/// Observes network reachability + interface characteristics (Wi-Fi vs cellular, Low Data Mode) so the
/// data-freshness layer can decide *when* to refresh. A thin `NWPathMonitor` wrapper — the app had no
/// reachability monitoring before v4.1.0. Decisions live in `DataRefreshGate`; enforcement lives at the
/// request layer. Construct the live monitor with `init()`; tests use `init(stub:)`. (v4.1.0 Data Freshness)
@MainActor
final class NetworkMonitor: ObservableObject {

    /// The latest observed conditions. Seeded to `.disconnected` until the first path update lands.
    @Published private(set) var conditions: NetworkConditions

    // Convenience forwards for call sites / SwiftUI that only need one signal.
    var isConnected: Bool { conditions.isConnected }
    var isWiFi: Bool { conditions.isWiFi }
    var isExpensive: Bool { conditions.isExpensive }
    var isConstrained: Bool { conditions.isConstrained }

    private let monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "app.aerocheck.networkmonitor", qos: .utility)

    /// Live monitor — starts observing the default path immediately.
    init() {
        conditions = .disconnected
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = NetworkConditions(path: path)
            Task { @MainActor in self?.conditions = snapshot }
        }
        monitor.start(queue: queue)
    }

    /// Test seam: fixed conditions, no live `NWPathMonitor`.
    init(stub conditions: NetworkConditions) {
        self.conditions = conditions
        self.monitor = nil
    }

    deinit {
        monitor?.cancel()
    }
}
