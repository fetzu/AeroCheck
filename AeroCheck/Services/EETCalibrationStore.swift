import Combine
import Foundation
import Observation

/// Keeps what the logbook taught (`EETCalibration.Snapshot`) between launches, and gives every plan what
/// its times are computed with: the aircraft's cruise speed and the two allowances
/// (`FlightPlan.planningCalibrationProvider`). (6.1)
///
/// The snapshot is recomputed at END FLIGHT and whenever the logbook it came from has changed (a first
/// launch, a flight synced from another device, an edit). It is derived data, so it lives in this
/// device's defaults: every device computes its own from the same logbook.
///
/// Plans can be computed anywhere, so what they read is held behind a lock: the pilot's cruise figures
/// (settings) and the aircraft's (metadata) are copied in on the main actor as they change
/// (`follow(appState:aircraftDataService:)`).
@Observable
final class EETCalibrationStore: @unchecked Sendable {
    /// The app's own, on the app's defaults. Tests build theirs on a suite of their own.
    static let shared = EETCalibrationStore(defaults: .standard)

    /// Changes whenever what plans compute with changes, for the views that show it.
    private(set) var revision = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var storedSnapshot: EETCalibration.Snapshot
    @ObservationIgnored private var manualCruise: [String: Int] = [:]
    @ObservationIgnored private var aircraftCruise: [String: Double] = [:]
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var aircraftUpdates: AnyCancellable?

    static let snapshotKey = "eetCalibration.snapshot"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        storedSnapshot = defaults.data(forKey: Self.snapshotKey)
            .flatMap { try? JSONDecoder().decode(EETCalibration.Snapshot.self, from: $0) }
            .flatMap { $0.version == EETCalibration.Snapshot.currentVersion ? $0 : nil }
            ?? .empty
    }

    var snapshot: EETCalibration.Snapshot {
        lock.lock(); defer { lock.unlock() }
        return storedSnapshot
    }

    // MARK: What plans compute with

    /// The cruise speed of `registration`: the pilot's, learned, the aircraft's, 100 kt.
    func cruise(forRegistration registration: String?) -> CruiseSpeed {
        lock.lock(); defer { lock.unlock() }
        let key = CruiseSpeed.key(for: registration)
        return CruiseSpeed.resolve(manualKIAS: key.flatMap { manualCruise[$0] }.map(Double.init),
                                   aircraftDataKIAS: key.flatMap { aircraftCruise[$0] },
                                   learnedSamples: key.flatMap { storedSnapshot.cruise[$0] } ?? [])
    }

    func calibration(for plan: FlightPlan) -> FlightPlan.PlanningCalibration {
        let snapshot = self.snapshot
        return FlightPlan.PlanningCalibration(
            cruise: cruise(forRegistration: plan.aircraftRegistration),
            departureAllowance: EETCalibration.departureAllowance(at: plan.departureAerodromeIdent, in: snapshot),
            arrivalAllowance: EETCalibration.arrivalAllowance(at: plan.destinationAerodromeIdent, in: snapshot))
    }

    // MARK: Inputs

    @MainActor
    func setManualCruise(_ values: [String: Int]) {
        lock.lock()
        let changed = manualCruise != values
        manualCruise = values
        lock.unlock()
        if changed { revision += 1 }
    }

    @MainActor
    func setAircraftCruise(from aircraft: [RemoteAircraftMetadata]) {
        var values: [String: Double] = [:]
        for meta in aircraft {
            if let key = CruiseSpeed.key(for: meta.registration), let kias = meta.cruiseSpeedKIAS { values[key] = kias }
            for registration in meta.registrations ?? [] {
                if let key = CruiseSpeed.key(for: registration.registration), let kias = registration.cruiseSpeedKIAS {
                    values[key] = kias
                }
            }
        }
        lock.lock()
        let changed = aircraftCruise != values
        aircraftCruise = values
        lock.unlock()
        if changed { revision += 1 }
    }

    /// Copy the pilot's figures and the aircraft's in now, and again whenever they change.
    @MainActor
    func follow(appState: AppState, aircraftDataService: AircraftDataService) {
        followSettings(of: appState)
        aircraftUpdates = aircraftDataService.$availableAircraft
            .receive(on: DispatchQueue.main)
            .sink { [weak self] aircraft in
                MainActor.assumeIsolated { self?.setAircraftCruise(from: aircraft) }
            }
    }

    @MainActor
    private func followSettings(of appState: AppState) {
        let values = withObservationTracking {
            appState.settings.cruiseSpeedKIAS
        } onChange: { [weak self, weak appState] in
            Task { @MainActor in
                guard let self, let appState else { return }
                self.followSettings(of: appState)
            }
        }
        setManualCruise(values)
    }

    // MARK: Learning

    /// Learn again from `flights` when they are not the logbook the snapshot came from, or always with
    /// `force` (END FLIGHT). Off the main actor: every track is read.
    @MainActor
    func refresh(from flights: [Flight], force: Bool = false) {
        let fingerprint = EETCalibration.fingerprint(of: flights)
        guard force || fingerprint != snapshot.logbookFingerprint else { return }
        refreshing?.cancel()
        refreshing = Task { [weak self] in
            let computed = await Task.detached(priority: .utility) { EETCalibration.snapshot(from: flights) }.value
            guard !Task.isCancelled, let self else { return }
            self.apply(computed)
        }
    }

    /// Wait for a refresh in progress (tests, and the store's own sequencing).
    @MainActor
    func waitForRefresh() async {
        await refreshing?.value
    }

    @MainActor
    func apply(_ snapshot: EETCalibration.Snapshot) {
        lock.lock()
        let changed = storedSnapshot != snapshot
        storedSnapshot = snapshot
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: Self.snapshotKey) }
        if changed { revision += 1 }
        AppLog.general.publicLine("EET calibration: \(snapshot.departures.values.map(\.count).reduce(0, +)) departures, "
                                  + "\(snapshot.arrivals.values.map(\.count).reduce(0, +)) arrivals, "
                                  + "\(snapshot.cruise.values.map(\.count).reduce(0, +)) cruise samples")
    }
}
