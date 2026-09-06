import CoreLocation
import Foundation

/// The single, shared flight-start sequence used by **every** entry point — the home-screen
/// START / START CIRCUITS buttons, the home-screen widget, and `aerocheck://start-flight` deep
/// links. Centralising it guarantees each launch resolves the checklist, loads airport data,
/// configures the flight-event detector, passes the safety guards, and only then begins GPS
/// tracking. A widget- or deep-link-launched flight therefore can never be missing its checklist
/// (ARCH-01) or its GPS track (UX-08), nor silently overwrite a running flight (UX-06), start an
/// unowned premium aircraft (UX-07), or record nothing because location was denied (UX-13).
@MainActor
struct FlightLauncher {
    let appState: AppState
    let locationManager: LocationManager
    let aircraftDataService: AircraftDataService
    let airportDataService: AirportDataService
    let flightEventDetector: FlightEventDetector
    let flightPlanManager: FlightPlanManager
    /// Optional so the guard sequence above stays independent of the Flight Thread feature: a launch
    /// with no manager behaves exactly as it always did. Used only AFTER a successful start, never
    /// as a condition of one — linking a followed flight is a consequence of departing, not a
    /// permission to depart. (v5.x)
    var threadManager: FlightThreadManager?

    /// The outcome of a launch attempt, so a caller can present the right follow-up.
    enum Outcome: Equatable {
        case started
        case blockedActiveFlight        // a flight is already running (UX-06)
        case blockedUnowned             // premium aircraft not owned → present paywall (UX-07)
        case blockedChecklistUnresolved // premium checklist failed to load (ARCH-01)
        case blockedLocationDenied      // location permission denied/restricted, no companion fix (UX-13)
        case blockedAcquiringGPS        // permitted but no usable fix yet — transient, retry (shared-GPS)
    }

    /// Pure guard evaluation, factored out so each branch is unit-testable without real services.
    /// The order defines which block wins when several conditions hold at once: an active flight
    /// first (never overwrite), then ownership (so an unowned aircraft shows the paywall rather
    /// than a misleading "checklist not ready"), then checklist resolution, then location/GPS.
    ///
    /// `hasOwnFix` / `hasPeerFix` are whether THIS device, or a connected companion, currently has a
    /// usable GPS fix. The shared-GPS guard requires at least one before starting, so a flight never
    /// begins blind — and so a GPS-less device (e.g. a Wi-Fi iPad) can still launch off a companion's
    /// GPS. They default to "own fix present, no peer", the pre-shared-GPS assumption. (shared-GPS)
    static func evaluate(isFlightActive: Bool,
                         isOwned: Bool,
                         isChecklistResolved: Bool,
                         authorization: CLAuthorizationStatus,
                         hasOwnFix: Bool = true,
                         hasPeerFix: Bool = false) -> Outcome {
        if isFlightActive { return .blockedActiveFlight }
        if !isOwned { return .blockedUnowned }
        if !isChecklistResolved { return .blockedChecklistUnresolved }

        // Own location denied/restricted: the flight can still run off a companion's borrowed GPS, but
        // with neither own nor peer fix it would record nothing. (UX-13, extended for shared-GPS)
        if authorization == .denied || authorization == .restricted {
            return hasPeerFix ? .started : .blockedLocationDenied
        }

        // Permission granted or still to be asked: require at least one usable fix before starting so the
        // flight never begins blind (option b). While permission is still `.notDetermined` the prompt
        // hasn't been answered, so a fix can't exist yet — defer to startTracking (which requests it)
        // rather than nag "Acquiring GPS…".
        if hasOwnFix || hasPeerFix { return .started }
        if authorization == .notDetermined { return .started }
        return .blockedAcquiringGPS
    }

    /// Resolve the checklist, run the guards, start the flight, and begin GPS tracking.
    /// Returns the outcome; side effects (paywall request / error alert) are set on `appState`.
    /// `followedFlightId` is set when the pilot pressed START FLIGHT inside a followed flight, which
    /// names it exactly. Every other entry point leaves it nil and relies on the armed plan.
    @discardableResult
    func begin(circuitMode: Bool, followedFlightId: UUID? = nil) async -> Outcome {
        // UX-06: never overwrite a running flight. Checked first so we don't reload the active
        // checklist out from under a flight already in progress.
        guard !appState.isFlightActive else { return .blockedActiveFlight }

        // UX-07: refuse an unowned premium aircraft up-front, so the caller can present the
        // paywall instead of the misleading "checklist not ready" error a failed load would give.
        guard isSelectedAircraftOwned else {
            appState.flightStartPaywallRequest = true
            return .blockedUnowned
        }

        // Resolve the checklist for the current selection (premium, or a language-specific
        // bundled checklist). This is the load every entry point previously skipped (UX-08/11).
        await appState.loadRemoteChecklistIfNeeded(aircraftDataService: aircraftDataService)

        // ARCH-01: a premium aircraft whose checklist failed to load must not start — it would
        // otherwise present an empty or wrong checklist.
        guard appState.isPremiumChecklistResolved else {
            appState.flightStartError = L10n.Alert.checklistNotReady
            return .blockedChecklistUnresolved
        }

        // Airport data backs the FREQ panel and automatic flight-event detection.
        await airportDataService.ensureLoaded()

        // Configure the event detector with this aircraft's speeds before tracking starts.
        configureFlightEventDetector()

        // UX-13 + shared-GPS: the flight needs a usable GPS fix to record anything — its own device fix,
        // or a companion's borrowed over Wi-Fi Aware. The first three guards have already passed, so
        // evaluate() here reduces to the location/GPS decision.
        let authorization = locationManager.authorizationStatus
        // Use the lenient start-fix check (valid position + GPS active), NOT ownFixIsLive's tight few-second
        // window — a stationary aircraft on the ramp stops producing fresh fixes but its position is valid.
        let hasOwnFix = locationManager.hasRecentUsableFix
        let hasPeerFix = CompanionConnectivityManager.shared.hasUsablePeerFix
        switch FlightLauncher.evaluate(isFlightActive: false, isOwned: true, isChecklistResolved: true,
                                       authorization: authorization, hasOwnFix: hasOwnFix, hasPeerFix: hasPeerFix) {
        case .blockedLocationDenied:
            appState.flightStartError = L10n.Alert.locationRequired
            return .blockedLocationDenied
        case .blockedAcquiringGPS:
            // Transient: permission is granted but no fix has locked yet. Kick the GPS pipeline (no-op if
            // already running) so a fix arrives, tell the pilot to retry, and don't start a blind flight.
            locationManager.startLocationUpdates()
            // If companion mode is on, also re-arm the link (force clears an idle-disconnect) so a GPS-less
            // master can pull a peer fix to retry with — otherwise a master whose link idle-dropped is
            // locked out of starting until the user reopens the Companion screen. (shared-GPS)
            if appState.settings.enableCompanionMode {
                CompanionConnectivityManager.shared.autoConnectIfReady(force: true)
            }
            appState.flightStartError = L10n.Alert.acquiringGPS
            return .blockedAcquiringGPS
        default:
            break   // .started — proceed (a `.notDetermined` defer also lands here; startTracking prompts)
        }

        // A flight plan applies to a normal flight only, not to circuit training.
        let flightPlanId = circuitMode ? nil : flightPlanManager.activeFlightPlan?.id
        appState.startFlight(
            withAircraft: appState.settings.defaultAirplane,
            aircraftRegistration: selectedRegistration,
            aircraftType: selectedAircraftType,
            checklistVersion: selectedVersion,
            flightPlanId: flightPlanId,
            circuitMode: circuitMode
        )

        // startFlight() is the authoritative guard and may still have refused the start (e.g. a
        // race on the unresolved-checklist state). Only begin tracking if it actually started.
        guard appState.isFlightActive else { return .blockedChecklistUnresolved }

        // The flight is real: tell the followed flight it is under way, so it shows FLY rather than
        // sitting in PREPARE until landing, and stops offering to start a flight already running.
        // Only ever on an exact signal — see `threadToAttach`. (v5.x)
        if let threadManager, let startedFlightId = appState.currentFlight?.id,
           let threadId = threadManager.threadToAttach(explicitThreadId: followedFlightId,
                                                       planId: flightPlanId) {
            threadManager.attachFlight(startedFlightId, toThreadId: threadId)
        }

        locationManager.startTracking(
            appState: appState,
            interval: appState.settings.gpsRecordingInterval,
            airportDataService: airportDataService,
            flightEventDetector: flightEventDetector,
            activeChecklist: appState.activeChecklist
        )
        return .started
    }

    // MARK: - Selection helpers

    /// Metadata for the currently selected remote aircraft (nil for a bundled selection or when
    /// the aircraft list hasn't loaded yet).
    private var selectedRemoteMetadata: RemoteAircraftMetadata? {
        guard let remoteId = appState.settings.selectedRemoteAircraftId else { return nil }
        return aircraftDataService.availableAircraft.first(where: { $0.id == remoteId })
    }

    /// Whether the selected aircraft is owned. Bundled aircraft are always owned. A premium
    /// aircraft is owned when its metadata grants access; if the metadata hasn't loaded yet we
    /// allow the start to proceed and let the checklist-resolution guard decide. (UX-07)
    private var isSelectedAircraftOwned: Bool {
        guard appState.settings.selectedRemoteAircraftId != nil else { return true }
        guard let meta = selectedRemoteMetadata else { return true }
        return meta.hasAccess
    }

    private var selectedRegistration: String? {
        selectedRemoteMetadata?.registration ?? appState.settings.selectedAircraft.registration
    }

    private var selectedAircraftType: String? {
        selectedRemoteMetadata?.aircraftType ?? appState.settings.selectedAircraft.rawValue
    }

    private var selectedVersion: String? {
        selectedRemoteMetadata?.version ?? appState.settings.selectedAircraft.checklistVersion
    }

    /// Configure the flight-event detector with the current aircraft's speed data.
    private func configureFlightEventDetector() {
        let checklist = appState.activeChecklist
        flightEventDetector.configure(speeds: checklist.speeds, stallSpeed: checklist.stallSpeed)
    }
}
