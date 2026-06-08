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

    /// The outcome of a launch attempt, so a caller can present the right follow-up.
    enum Outcome: Equatable {
        case started
        case blockedActiveFlight        // a flight is already running (UX-06)
        case blockedUnowned             // premium aircraft not owned → present paywall (UX-07)
        case blockedChecklistUnresolved // premium checklist failed to load (ARCH-01)
        case blockedLocationDenied      // location permission denied/restricted (UX-13)
    }

    /// Pure guard evaluation, factored out so each branch is unit-testable without real services.
    /// The order defines which block wins when several conditions hold at once: an active flight
    /// first (never overwrite), then ownership (so an unowned aircraft shows the paywall rather
    /// than a misleading "checklist not ready"), then checklist resolution, then location.
    static func evaluate(isFlightActive: Bool,
                         isOwned: Bool,
                         isChecklistResolved: Bool,
                         authorization: CLAuthorizationStatus) -> Outcome {
        if isFlightActive { return .blockedActiveFlight }
        if !isOwned { return .blockedUnowned }
        if !isChecklistResolved { return .blockedChecklistUnresolved }
        if authorization == .denied || authorization == .restricted { return .blockedLocationDenied }
        return .started
    }

    /// Resolve the checklist, run the guards, start the flight, and begin GPS tracking.
    /// Returns the outcome; side effects (paywall request / error alert) are set on `appState`.
    @discardableResult
    func begin(circuitMode: Bool) async -> Outcome {
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

        // UX-13: a denied/restricted location permission means the flight would record no GPS —
        // block the start and surface an explanatory alert instead of launching a blind flight.
        // (`.notDetermined` is allowed through: startTracking requests the prompt and defers.)
        let authorization = locationManager.authorizationStatus
        guard authorization != .denied && authorization != .restricted else {
            appState.flightStartError = L10n.Alert.locationRequired
            return .blockedLocationDenied
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
