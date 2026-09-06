import SwiftUI

/// Represents an aircraft option for selection in the carousel
enum AircraftOption: Identifiable, Hashable {
    case bundled(AircraftType)
    case remote(RemoteAircraftMetadata)

    var id: String {
        switch self {
        case .bundled(let aircraft):
            return "bundled-\(aircraft.rawValue)"
        case .remote(let metadata):
            return "remote-\(metadata.id)"
        }
    }

    var registration: String {
        switch self {
        case .bundled(let aircraft):
            return aircraft.registration
        case .remote(let metadata):
            return metadata.registration
        }
    }

    var modelName: String {
        switch self {
        case .bundled(let aircraft):
            return aircraft.shortModelName
        case .remote(let metadata):
            return metadata.shortModelName
        }
    }

    var version: String {
        switch self {
        case .bundled(let aircraft):
            return aircraft.checklistVersion
        case .remote(let metadata):
            return metadata.version
        }
    }

    /// Aircraft type identifier (e.g., "WT9", "PA28")
    var aircraftType: String {
        switch self {
        case .bundled(let aircraft):
            return aircraft.rawValue
        case .remote(let metadata):
            return metadata.aircraftType
        }
    }

    var isFree: Bool {
        switch self {
        case .bundled:
            return true
        case .remote(let metadata):
            return metadata.isFree
        }
    }

    var remoteId: String? {
        switch self {
        case .bundled:
            return nil
        case .remote(let metadata):
            return metadata.id
        }
    }

    var bundledType: AircraftType? {
        switch self {
        case .bundled(let aircraft):
            return aircraft
        case .remote:
            return nil
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AircraftOption, rhs: AircraftOption) -> Bool {
        lhs.id == rhs.id
    }
}

/// Home view - main screen when no flight is active
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var threadManager: FlightThreadManager
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var flightEventDetector: FlightEventDetector
    @EnvironmentObject var openAIPCacheManager: OpenAIPCacheManager
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @EnvironmentObject var dataStatusManager: DataStatusManager
    @State private var showSettings = false
    /// Section to open Settings at — the data-status dot deep-links to Data & Storage. (v4.1.0 Data Freshness)
    @State private var pendingSettingsSection: SettingsView.Section? = nil
    @State private var showFlightLog = false
    @State private var showSpeedReference = false
    @State private var showNavigation = false
    @State private var showFlightPlanning = false
    @State private var selectedAircraftIndex: Int = 0
    @State private var cachedItemCountText: String = "—"
    /// Mirrors the body's rail-layout test (iPad landscape). When true, the rail destinations present
    /// as leading-edge slide-in overlays instead of the default bottom covers. (v4 UI/UX Revamp — device feedback)
    @State private var useRailLayout: Bool = false
    /// Latest computed rail value; applied to `useRailLayout` only when no destination is open, so a
    /// rotation / app-switch resize never tears down (and loses) a presented destination. (orientation)
    @State private var railWhenIdle: Bool = false

    /// True while any Home destination is presented (cover or rail overlay). The layout switch is
    /// frozen while this holds. (orientation reliability)
    private var anyDestinationOpen: Bool {
        showSettings || showFlightLog || showSpeedReference || showNavigation
            || showFlightPlanning || lastFlightForDetail != nil || threadToOpen != nil
    }

    /// The thread being viewed. Presented as a cover in BOTH layouts (the `showFlightPlanning`
    /// precedent) rather than a rail overlay: the admin chapters are read sitting down, often on the
    /// phone, and they do not need the rail beside them. (v5.0.0)
    @State private var threadToOpen: UUID?
    /// True while a flight is being created, so a double-tap cannot make two. (review, concurrency)
    @State private var isCreatingFlight = false
    /// The flight being planned. Non-nil presents the one creation sheet. (v5.0.0)
    @State private var planningNewFlight: NewFlightIntent?
    /// What START FLIGHT needs to ask before it departs. (v5.x)
    /// The aircraft screen, reachable from the strip once the flight owns the hero — the carousel
    /// it replaced is gone then, and the tail still has to be changeable on the day. (v5.x)
    @State private var showAircraftSheet = false
    @State private var startPrompt: StartPrompt?

    /// The one question START FLIGHT may need answered first.
    ///
    /// There used to be a second case — "arm today's flight plan" — for a saved route that carried a
    /// date. Routes are timeless now, and a flight for today is the hero and arms its own route, so
    /// nothing is left to ask about. (device pass)
    private enum StartPrompt: Identifiable {
        /// A followed flight for today with pre-flight work still open.
        case outstanding(thread: FlightThread, remaining: Int)

        var id: String {
            switch self {
            case .outstanding(let thread, _): return "outstanding-\(thread.id)"
            }
        }
    }
    /// When the Flight Log is opened from the last-flight strip, preselect that flight so its details
    /// show immediately; the Flight Log nav button clears it to open the plain list. (v4 UI/UX Revamp — feedback)
    @State private var flightLogSelectionID: UUID? = nil
    /// Non-rail (portrait / iPhone): the last-flight strip opens this flight's detail directly, so its
    /// back button returns to Home rather than the Flight Log list. (v4 UI/UX Revamp — feedback round 2)
    @State private var lastFlightForDetail: Flight? = nil

    /// Check if we're on a compact width device (iPhone)
    private func isCompactWidth(_ geometry: GeometryProxy) -> Bool {
        geometry.size.width < 600
    }

    /// Available aircraft options based on subscription status and visibility settings
    private var availableAircraft: [AircraftOption] {
        var options: [AircraftOption] = []

        // Add bundled aircraft first (bundled aircraft are always visible - they can't be hidden)
        for aircraft in AircraftType.allCases {
            options.append(.bundled(aircraft))
        }

        // Add remote aircraft that user has access to and are visible
        for remote in aircraftDataService.availableAircraft where remote.hasAccess && !remote.isBundled {
            // Check visibility settings
            if appState.settings.isAircraftVisible(aircraftId: remote.id, aeroclub: remote.aeroclub) {
                options.append(.remote(remote))
            }
        }

        return options
    }

    /// Currently selected aircraft option
    private var selectedAircraft: AircraftOption? {
        guard selectedAircraftIndex >= 0 && selectedAircraftIndex < availableAircraft.count else {
            return availableAircraft.first
        }
        return availableAircraft[selectedAircraftIndex]
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let isLandscape = geometry.size.width > geometry.size.height
                let isCompact = isCompactWidth(geometry)
                let rail = isLandscape && geometry.size.width >= 900

                ZStack {
                    // Background
                    Color.cockpitBackground
                        .ignoresSafeArea()

                    if rail {
                        // iPad landscape: command rail (nav) + hero canvas. (v4 UI/UX Revamp — Direction 1)
                        HStack(spacing: 0) {
                            navRail
                            heroCanvas(landscape: true, isCompact: false)
                        }
                    } else {
                        // Portrait / iPhone: brand header, hero canvas, then the nav as a bottom tab bar.
                        VStack(spacing: 0) {
                            brandHeader(isCompact: isCompact)
                                // Align with the hero content below (32 on iPad portrait) so the brand
                                // and the Data/GPS chips aren't hugging the screen edges. (UX feedback)
                                .padding(.horizontal, isCompact ? 16 : 32)
                                .padding(.top, isCompact ? 12 : 20)
                            heroCanvas(landscape: isLandscape, isCompact: isCompact)
                            navTabBar
                        }
                    }
                }
                .onAppear { railWhenIdle = rail; if !anyDestinationOpen { useRailLayout = rail } }
                .onChange(of: geometry.size) { _, _ in
                    // Track the layout the size implies, but DON'T switch while a destination is open —
                    // switching destroys the presented cover/overlay (and its whole nested stack),
                    // bouncing you back on rotation or an app-switch resize. Freeze; re-sync on close.
                    railWhenIdle = rail
                    if !anyDestinationOpen, useRailLayout != rail { useRailLayout = rail }
                }
            }

            // In the rail layout, the four rail destinations slide in from the leading edge (they sit
            // "behind" the left rail), rather than the default bottom cover. Portrait keeps the covers
            // below. (v4 UI/UX Revamp — device feedback)
            railDestinationOverlays
        }
        // When the last destination closes, apply any layout change deferred while it was open.
        .onChange(of: anyDestinationOpen) { _, open in
            if !open, useRailLayout != railWhenIdle { useRailLayout = railWhenIdle }
        }
        .fullScreenCover(isPresented: coverBinding($showSettings)) {
            SettingsView(initialSection: pendingSettingsSection)
                .environment(appState)
                .environmentObject(locationManager)
        }
        .fullScreenCover(isPresented: coverBinding($showFlightLog)) {
            FlightLogView(initialFlightID: flightLogSelectionID)
                .environment(appState)
                .environmentObject(flightPlanManager)
                .environmentObject(airportDataService)
                .environmentObject(openAIPDataService)
        }
        .sheet(isPresented: coverBinding($showSpeedReference)) {
            SpeedReferenceSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showAircraftSheet) {
            NavigationStack {
                AircraftSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(L10n.Button.close) { showAircraftSheet = false }
                        }
                    }
            }
            .environment(appState)
            .environmentObject(subscriptionManager)
            .environmentObject(aircraftDataService)
        }
        .fullScreenCover(isPresented: $showFlightPlanning) {
            FlightPlanningView()
                .environment(appState)
                .environmentObject(flightPlanManager)
                .environmentObject(threadManager)
                .environmentObject(airportDataService)
                .environmentObject(aircraftDataService)
                .environmentObject(openAIPDataService)
                .environmentObject(locationManager)
        }
        // Derived binding rather than `item:` — UUID is not Identifiable, and a retroactive
        // conformance on a stdlib type is not worth it for one presentation. (Same shape as
        // ContentView's reconciliation sheet.)
        .fullScreenCover(isPresented: Binding(
            get: { threadToOpen != nil },
            set: { if !$0 { threadToOpen = nil } }
        )) {
            if let id = threadToOpen {
                FlightThreadView(threadId: id,
                                 onClose: { threadToOpen = nil },
                                 onStartFlight: { circuits in
                                     threadToOpen = nil
                                     // Through `launch`, not `beginFlight`. The hero's button armed
                                     // the flight's route and this one did not, so a flight started
                                     // from its own screen flew with an empty map — the one place a
                                     // pilot has most reason to expect the route to be there.
                                     // Circuits still bypass it: they drop the plan by design.
                                     // (device pass)
                                     if circuits {
                                         beginFlight(circuitMode: true, followedFlightId: id)
                                     } else if let thread = threadManager.thread(withId: id) {
                                         launch(thread)
                                     } else {
                                         beginFlight(circuitMode: false, followedFlightId: id)
                                     }
                                 })
                    .environmentObject(threadManager)
                    .environmentObject(flightPlanManager)
            }
        }
        .confirmationDialog(
            startPromptTitle,
            isPresented: Binding(
                get: { startPrompt != nil },
                set: { if !$0 { startPrompt = nil } }
            ),
            titleVisibility: .visible
        ) {
            switch startPrompt {
            case .outstanding(let thread, _):
                // "Start anyway" is not a warning to be dismissed — an outstanding item may be a
                // briefing nobody did, so the pilot gets a way to go and look before departing.
                Button(L10n.Home.reviewFlightFirst) {
                    let id = thread.id
                    startPrompt = nil
                    threadToOpen = id
                }
                Button(L10n.Home.startAnyway) {
                    startPrompt = nil
                    launch(thread)
                }
                Button(L10n.Button.cancel, role: .cancel) { startPrompt = nil }

            case nil:
                EmptyView()
            }
        } message: {
            switch startPrompt {
            case .outstanding(let thread, let remaining):
                Text(L10n.Home.outstandingBeforeFlight(thread.routeLabel, remaining))
            case nil:
                EmptyView()
            }
        }
        // Derived binding rather than `item:` — NewFlightIntent is a value the sheet edits, and
        // presenting on `item:` would rebuild the sheet on every keystroke it reports back.
        .sheet(isPresented: Binding(
            get: { planningNewFlight != nil },
            set: { if !$0 { planningNewFlight = nil } }
        )) {
            if let seed = planningNewFlight {
                PlanNewFlightView(
                    intent: seed,
                    aircraft: availableAircraft,
                    savedRoutes: flightPlanManager.flightPlans,
                    onCreate: { stops, intent, route in
                        planningNewFlight = nil
                        createFlight(stops: stops, from: intent, route: route)
                    },
                    onCancel: { planningNewFlight = nil }
                )
            }
        }
        // Last-flight detail opened straight from the Home strip (non-rail layouts) — its back button
        // returns to Home, not the Flight Log list. (v4 UI/UX Revamp — feedback round 2)
        .fullScreenCover(item: $lastFlightForDetail) { flight in
            NavigationStack {
                FlightDetailView(flight: flight)
                    .navigationTitle(lastFlightRoute(flight))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { lastFlightForDetail = nil } label: {
                                Image(systemName: "chevron.left")
                                    .fontWeight(.semibold)
                            }
                            .accessibilityLabel(L10n.Button.close)
                        }
                    }
            }
            .environment(appState)
            .environmentObject(flightPlanManager)
            .environmentObject(airportDataService)
            .environmentObject(openAIPDataService)
        }
        .fullScreenCover(isPresented: coverBinding($showNavigation)) {
            NavigationMapView(isPresented: $showNavigation)
                .environment(appState)
                .environmentObject(locationManager)
                .environmentObject(offlineMapManager)
                .environmentObject(flightPlanManager)
                .environmentObject(airportDataService)
                .environmentObject(aircraftDataService)
                .environmentObject(openAIPCacheManager)
                .environmentObject(openAIPDataService)
        }
        .onAppear {
            syncSelectedAircraftIndex()
            updateCachedItemCount()
            // Refresh the data-currency status: a download made during onboarding (or in the data hub)
            // happens without a scenePhase change, so the Home indicator would otherwise stay stale. (bug)
            dataStatusManager.recompute()
            // Warm up GPS on the pre-flight screen so the FIRST flight-start tap already has a fix and
            // doesn't bounce off "Acquiring GPS…". No-op until authorized (startTracking still prompts).
            // (v4.1 — fixes the systematic first-try GPS warning)
            if locationManager.authorizationStatus == .authorizedWhenInUse
                || locationManager.authorizationStatus == .authorizedAlways {
                locationManager.startLocationUpdates()
            }
        }
        .alert(L10n.Alert.cannotStartFlightTitle, isPresented: Binding(
            get: { appState.flightStartError != nil },
            set: { if !$0 { appState.flightStartError = nil } }
        )) {
            Button(L10n.Button.close, role: .cancel) { appState.flightStartError = nil }
        } message: {
            Text(appState.flightStartError ?? "")
        }
        // PR-14: a just-finished flight could not be persisted — its checkpoint was kept and will
        // be restored next launch. Surface it rather than letting the failure be silent.
        .alert(L10n.Alert.flightSaveFailedTitle, isPresented: Binding(
            get: { appState.flightSaveError != nil },
            set: { if !$0 { appState.flightSaveError = nil } }
        )) {
            Button(L10n.Button.close, role: .cancel) { appState.flightSaveError = nil }
        } message: {
            Text(appState.flightSaveError ?? "")
        }
        // Present the paywall when a flight start was refused for an unowned premium aircraft. (UX-07)
        .sheet(isPresented: Binding(
            get: { appState.flightStartPaywallRequest },
            set: { if !$0 { appState.flightStartPaywallRequest = false } }
        )) {
            // Personalise the paywall with the aircraft the pilot just tried to fly.
            SubscriptionView(contextAircraftName: selectedAircraft?.modelName)
                .environmentObject(subscriptionManager)
        }
        .onChange(of: aircraftDataService.availableAircraft) { _, _ in
            syncSelectedAircraftIndex()
        }
        .onChange(of: subscriptionManager.subscriptionStatus) { oldValue, newValue in
            // Re-fetch aircraft list when subscription becomes active to fix race condition
            // where the initial fetch completed before the server-side subscription was verified
            if newValue.isSubscribed && !oldValue.isSubscribed {
                Task {
                    // Bounded retry: the server entitlement write can lag the StoreKit confirmation, so
                    // a single fetch may still come back locked. (premium reliability)
                    await aircraftDataService.refetchUntilPremiumUnlocked()
                }
            }
        }
        .onChange(of: aircraftDataService.checklistUpdateCount) { _, _ in
            // A checklist was updated in the background - reload active checklist if needed
            Task {
                await appState.loadRemoteChecklistIfNeeded(aircraftDataService: aircraftDataService)
                updateCachedItemCount()
            }
        }
        .onChange(of: selectedAircraftIndex) { _, newIndex in
            updateAppStateAircraft(index: newIndex)
            updateCachedItemCount()
        }
        .onChange(of: appState.settings.hiddenAircraftIds) { _, _ in
            syncSelectedAircraftIndex()
        }
        .onChange(of: appState.settings.hiddenAeroclubs) { _, _ in
            syncSelectedAircraftIndex()
        }
    }

    // MARK: - Rail destination presentation

    /// Routes a rail destination to the default bottom cover only in the portrait/compact layout.
    /// In the rail layout it stays unpresented here so `railDestinationOverlays` can slide it in from
    /// the leading edge instead. (v4 UI/UX Revamp — device feedback)
    private func coverBinding(_ flag: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { flag.wrappedValue && !useRailLayout },
            // Only honor a `false` write as a real dismissal in the portrait/compact layout. When the
            // device rotates INTO the rail layout, `get` drops to false and SwiftUI writes `false` back
            // here to "dismiss" the cover — if we cleared the flag then, the destination would vanish
            // instead of being handed to `railDestinationOverlays`, bouncing the user back to Home. So
            // ignore the write while in the rail layout; the underlying flag survives the rotation.
            set: { newValue in
                if !newValue && !useRailLayout { flag.wrappedValue = false }
            }
        )
    }

    /// The four rail destinations, presented as full-screen overlays that slide in from the leading
    /// edge (they live "behind" the left rail). Each destination still owns its dismissal: Settings /
    /// Flight Log / Speeds route their close button to `onClose`; NavigationMapView flips its own
    /// `isPresented` binding. The per-flag `.animation` drives both the slide-in and the slide-out. (v4 UI/UX Revamp)
    @ViewBuilder
    private var railDestinationOverlays: some View {
        if useRailLayout {
            ZStack {
                if showSettings {
                    SettingsView(onClose: { showSettings = false }, initialSection: pendingSettingsSection)
                        .environment(appState)
                        .environmentObject(locationManager)
                        .background(Color.cockpitBackground.ignoresSafeArea())
                        .transition(.move(edge: .leading))
                }
                if showFlightLog {
                    FlightLogView(onClose: { showFlightLog = false }, initialFlightID: flightLogSelectionID)
                        .environment(appState)
                        .environmentObject(flightPlanManager)
                        .environmentObject(airportDataService)
                        .environmentObject(openAIPDataService)
                        .background(Color.cockpitBackground.ignoresSafeArea())
                        .transition(.move(edge: .leading))
                }
                if showSpeedReference {
                    // Full-screen leading-edge slide-in, consistent with the other rail destinations
                    // (Settings / Flight Log / Navigation). Reverts the 3.5 constrained-popup variant
                    // (88f4e5e) on iPad per user request; iPhone keeps its bottom sheet via coverBinding.
                    SpeedReferenceSheet(onClose: { showSpeedReference = false })
                        .environment(appState)
                        .background(Color.cockpitBackground.ignoresSafeArea())
                        .transition(.move(edge: .leading))
                }
                if showNavigation {
                    NavigationMapView(isPresented: $showNavigation)
                        .environment(appState)
                        .environmentObject(locationManager)
                        .environmentObject(offlineMapManager)
                        .environmentObject(flightPlanManager)
                        .environmentObject(airportDataService)
                        .environmentObject(aircraftDataService)
                        .environmentObject(openAIPCacheManager)
                        .environmentObject(openAIPDataService)
                        .background(Color.cockpitBackground.ignoresSafeArea())
                        .transition(.move(edge: .leading))
                }
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.3), value: showSettings)
            .animation(.easeInOut(duration: 0.3), value: showFlightLog)
            .animation(.easeInOut(duration: 0.3), value: showSpeedReference)
            .animation(.easeInOut(duration: 0.3), value: showNavigation)
        }
    }

    /// Sync the selected index with the current app state aircraft selection
    private func syncSelectedAircraftIndex() {
        let aircraft = availableAircraft

        // Find the index of the currently selected aircraft in app state
        if let remoteId = appState.settings.selectedRemoteAircraftId {
            // Remote aircraft selected
            if let index = aircraft.firstIndex(where: { $0.remoteId == remoteId }) {
                if selectedAircraftIndex != index {
                    selectedAircraftIndex = index
                }
                return
            }
            // Selected remote aircraft is hidden - fall back to first available (bundled)
            if !aircraft.isEmpty {
                selectedAircraftIndex = 0
                // Update app state to clear the hidden selection
                appState.settings.selectedRemoteAircraftId = nil
                appState.saveSettings()
            }
            return
        }

        // Bundled aircraft selected
        let bundledType = appState.settings.selectedAircraft
        if let index = aircraft.firstIndex(where: { $0.bundledType == bundledType }) {
            if selectedAircraftIndex != index {
                selectedAircraftIndex = index
            }
        }
    }

    /// Update app state when user swipes to a different aircraft
    private func updateAppStateAircraft(index: Int) {
        guard index >= 0 && index < availableAircraft.count else { return }

        let option = availableAircraft[index]
        // Delegate the actual selection to AppState's shared selector so every entry point
        // (carousel, deep link, widget) resolves aircraft the same way. (Task 3, step 1)
        let token = option.remoteId ?? option.bundledType?.rawValue ?? option.registration
        guard appState.selectAircraft(id: token, available: aircraftDataService.availableAircraft) else { return }

        // For a remote aircraft, pre-load the checklist in the background so the item count and
        // speed reference are ready before the flight starts.
        if option.remoteId != nil {
            Task {
                await appState.loadRemoteChecklistIfNeeded(aircraftDataService: aircraftDataService)
            }
        }
    }
    
    /// The hero canvas: aircraft selector + Start/Circuits + GPS + last-flight, centred. Shared by the
    /// landscape rail layout and the portrait stack. (v4 UI/UX Revamp — Direction 1)
    private func heroCanvas(landscape: Bool, isCompact: Bool) -> some View {
        // The hero, Start/Circuits, and last-flight all share one width so the column reads as a unit.
        // GPS lives in the rail foot (landscape) / brand header (portrait), not wedged in here. (v4 UI/UX Revamp)
        VStack(spacing: landscape ? 18 : (isCompact ? 16 : 24)) {
            // On the day you have planned a flight, that flight IS the screen. START FLIGHT opens
            // the PREFLIGHT checklist — fifteen phases before the engine turns — so there is no
            // hurry at this moment and nothing about it needs to be the largest thing here. On every
            // other day the aircraft keeps the slot, because a Home that always led with a flight
            // would show an empty promise on the ninety days there isn't one. (v5.x)
            if let flight = heroFlight {
                flightHeroCard(flight, isCompact: isCompact)
                    .frame(maxWidth: heroWidth)
                unplannedShortcutButtons(isLandscape: landscape, isCompact: isCompact)
                    .frame(maxWidth: heroWidth)
            } else {
                aircraftCard(isLandscape: false, isCompact: isCompact)   // the fuller, taller card
                    .frame(maxWidth: heroWidth)
                startCircuitsButtons(isLandscape: landscape, isCompact: isCompact)
                    .frame(maxWidth: heroWidth)
            }
            activityStrips(sideBySide: landscape && !isCompact)
                .frame(maxWidth: heroWidth)
        }
        .padding(landscape ? 24 : (isCompact ? 16 : 32))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Last-flight + flight-plan strips: side by side on a wide canvas, stacked otherwise. Ordered
    /// past → future (left/top = last flight, right/bottom = flight plan). (v4 UI/UX Revamp — device feedback)
    @ViewBuilder
    private func activityStrips(sideBySide: Bool) -> some View {
        if sideBySide {
            // A one-row Grid, not an HStack. The strips carry different numbers of lines — the
            // followed-flight card has a "next task" line the last-flight strip does not — so side
            // by side one card ended shorter than its neighbour.
            //
            // `maxHeight: .infinity` on HStack children was the obvious fix and did not work: it
            // makes each child accept the PARENT's proposal rather than match its sibling, so the
            // two still sized independently. A Grid row equalises its cells by construction, which
            // is the property actually wanted here.
            Grid(horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    lastFlightStrip(fillsHeight: true)
                    secondStrip(fillsHeight: true)
                }
            }
            // Without this the strips are enormous. The cards fill their cell so the shorter one's
            // background reaches the row height — but the parent VStack has `maxHeight: .infinity`
            // and hands out every spare point, which the filling cards then swallow. Sizing the Grid
            // to its own content caps the row at the TALLER CARD, which is all "equal heights" ever
            // meant. (device pass)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 12) {
                lastFlightStrip(fillsHeight: false)
                secondStrip(fillsHeight: false)
            }
        }
    }

    private var startPromptTitle: String {
        startPrompt == nil ? "" : L10n.Home.outstandingTitle
    }

    // MARK: - Flight-first hero (v5.x)

    /// The flight that owns the hero slot: one you can start today, including one already in FLY.
    ///
    /// Today ONLY. A flight on Saturday is not what this screen is about on Tuesday, and it stays a
    /// strip. A flight awaiting close-out stays a strip too — the red banner above already carries
    /// the one piece of close-out that is urgent.
    private var heroFlight: FlightThread? { threadManager.startableFlightToday }

    /// The second activity strip. The flight vacated it to become the hero, so the aircraft — which
    /// vacated the hero — takes its place. Neither disappears; they swap.
    @ViewBuilder
    private func secondStrip(fillsHeight: Bool) -> some View {
        if heroFlight != nil {
            aircraftStrip(fillsHeight: fillsHeight)
        } else {
            flightPlanStrip(fillsHeight: fillsHeight)
        }
    }

    /// Today's flight, as the thing the screen is about: how ready it is, what is left, and one green
    /// button that starts THIS flight and arms its own route.
    private func flightHeroCard(_ thread: FlightThread, isCompact: Bool) -> some View {
        let progress = thread.preFlightProgress
        let remaining = progress.total - progress.done
        let inFlight = thread.state == .flying
        let accent: Color = inFlight ? .altimeterBlue : .aviationGold

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                threadReadinessRing(progress: progress, accent: accent)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(inFlight ? L10n.Thread.stateFlying.uppercased() : heroWhen(thread))
                            .scaledFont(size: 10, weight: .bold, design: .monospaced, relativeTo: .caption2)
                            .foregroundColor(accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(accent.opacity(0.55), lineWidth: 1))
                        if let registration = thread.aircraftRegistration, !registration.isEmpty {
                            Text(registration)
                                .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                                .foregroundColor(.secondaryText)
                        }
                    }
                    Text(thread.routeLabel)
                        .scaledFont(size: isCompact ? 22 : 26, weight: .bold, design: .monospaced, relativeTo: .title2)
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
            }

            Text(heroDetail(thread, remaining: remaining))
                .scaledFont(size: 13, relativeTo: .footnote)
                .foregroundColor(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button { startHeroFlight(thread) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                            .scaledFont(size: isCompact ? 15 : 17, relativeTo: .title3)
                        Text(inFlight ? L10n.Home.resumeThisFlight : L10n.Home.startThisFlight)
                            .scaledFont(size: isCompact ? 15 : 17, weight: .bold, relativeTo: .title3)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: isCompact ? 46 : 52)
                }
                .buttonStyle(PrimaryButtonStyle(color: .aviationGreen))

                Button { threadToOpen = thread.id } label: {
                    Text(L10n.Home.reviewFlight)
                        .scaledFont(size: isCompact ? 13 : 15, weight: .bold, relativeTo: .subheadline)
                        .frame(height: isCompact ? 46 : 52)
                        .frame(minWidth: 92)
                }
                .buttonStyle(SecondaryButtonStyle(color: .aviationGold))
            }
        }
        .padding(isCompact ? 14 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.45), lineWidth: 1))
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
                        .fill(accent)
                        .frame(width: 4)
                }
        )
    }

    private func heroWhen(_ thread: FlightThread) -> String {
        guard let departure = thread.scheduledDeparture else { return L10n.Home.today.uppercased() }
        return "\(L10n.Home.today.uppercased()) \(departure.formatted(date: .omitted, time: .shortened))"
    }

    private func heroDetail(_ thread: FlightThread, remaining: Int) -> String {
        if let next = thread.nextTask {
            let title = ThreadTaskPresentation.make(for: next).title
            return remaining > 1
                ? L10n.Home.nextAndRemaining(title, remaining)
                : L10n.Home.nextOnly(title)
        }
        return L10n.Home.readyToFly
    }

    /// Starting from the hero is the same launch as anywhere else — including the outstanding-items
    /// question, which a bigger button is no reason to skip.
    private func startHeroFlight(_ thread: FlightThread) {
        let progress = thread.preFlightProgress
        let remaining = progress.total - progress.done
        if remaining > 0 {
            startPrompt = .outstanding(thread: thread, remaining: remaining)
            return
        }
        launch(thread)
    }

    /// The shortcut, kept but demoted: a flight with no plan behind it, and circuits.
    private func unplannedShortcutButtons(isLandscape: Bool, isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 8 : 12) {
            Button(action: startUnplannedFlight) {
                Text(L10n.Home.flyWithoutAPlan)
                    .scaledFont(size: isCompact ? 14 : 15, weight: .semibold, relativeTo: .subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(SecondaryButtonStyle(color: .secondaryText))

            if appState.settings.enableCircuitMode {
                Button(action: startCircuits) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .scaledFont(size: 14, relativeTo: .subheadline)
                        Text(L10n.Button.circuits)
                            .scaledFont(size: isCompact ? 13 : 14, weight: .semibold, relativeTo: .subheadline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(height: 44)
                    .frame(minWidth: isCompact ? 110 : 130)
                }
                .buttonStyle(SecondaryButtonStyle(color: .aviationAmber))
            }
        }
    }

    /// The aircraft, in the strip the flight vacated. Taps into the carousel's own screen.
    private func aircraftStrip(fillsHeight: Bool) -> some View {
        let option = selectedAircraft
        return Button { showAircraftSheet = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "airplane")
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundColor(.aviationGold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Nav.aircraft)
                        .scaledFont(size: 10, weight: .semibold, relativeTo: .caption2).tracking(0.5)
                        .foregroundColor(.dimText)
                    Text(option?.registration ?? appState.settings.selectedAircraft.registration)
                        .scaledFont(size: 15, weight: .semibold, design: .monospaced, relativeTo: .subheadline)
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(option?.modelName ?? appState.settings.selectedAircraft.modelName)
                    .scaledFont(size: 11, relativeTo: .caption2)
                    .foregroundColor(.dimText)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                    .foregroundColor(.dimText.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .homeStripHeight(fills: fillsHeight)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder((AmbientPalette.hairline ?? Color.white.opacity(0.06)), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    /// Shared width for the hero card, the Start/Circuits line, and the last-flight strip. (v4 UI/UX Revamp)
    private var heroWidth: CGFloat { 620 }

    /// Brand mark for the portrait header (no gear — Settings lives in the tab bar now). (v4 UI/UX Revamp)
    private func brandHeader(isCompact: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: isCompact ? 6 : 10) {
                    Image(systemName: "airplane")
                        .scaledFont(size: isCompact ? 22 : 28, relativeTo: .title2)
                        .foregroundColor(.aviationGold)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 5) { AmbientController.shared.engage() }
                    Text("AéroCheck")
                        .scaledFont(size: isCompact ? 20 : 26, weight: .bold, relativeTo: .title2)
                        .foregroundColor(.primaryText)
                        .tracking(isCompact ? 1 : 2)
                }
                Text(L10n.App.tagline)
                    .scaledFont(size: isCompact ? 10 : 12, relativeTo: .caption)
                    .foregroundColor(.secondaryText)
            }
            Spacer()
            // GPS + data-currency status for portrait / iPhone (landscape shows them in the rail foot). (v4 UI/UX Revamp)
            HStack(spacing: isCompact ? 8 : 12) {
                dataStatusIndicator(isCompact: isCompact)
                gpsStatusIndicator(isCompact: isCompact)
            }
        }
    }

    // MARK: - Nav rail / tab bar (Direction 1)

    private var railSurface: Color { AmbientPalette.chrome ?? Color(red: 0.10, green: 0.10, blue: 0.13) }

    /// Vertical command rail (iPad landscape): brand mark, the four destinations, GPS at the foot.
    private var navRail: some View {
        VStack(spacing: 0) {
            Image(systemName: "airplane")
                .scaledFont(size: 26, relativeTo: .title2)
                .foregroundColor(.aviationGold)
                .padding(.top, 18)
                .contentShape(Rectangle())
                .onTapGesture(count: 5) { AmbientController.shared.engage() }
                .accessibilityHidden(true)
            Spacer()
            VStack(spacing: 6) {
                navButtons
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                dataStatusIndicator(isCompact: true)
                gpsStatusIndicator(isCompact: true)
            }
            .padding(.bottom, 18)
        }
        .frame(width: 92)
        .frame(maxHeight: .infinity)
        .background(railSurface.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle().fill((AmbientPalette.hairline ?? Color.white.opacity(0.06))).frame(width: 1).ignoresSafeArea()
        }
    }

    /// Horizontal bottom tab bar (portrait / iPhone): the same four destinations.
    private var navTabBar: some View {
        HStack(spacing: 0) {
            navButtons
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(railSurface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill((AmbientPalette.hairline ?? Color.white.opacity(0.06))).frame(height: 1)
        }
    }

    /// The four destination buttons — laid out vertically (rail) or horizontally (tab bar). (v4 UI/UX Revamp)
    @ViewBuilder
    private var navButtons: some View {
        // Title Case for the menu labels, per Apple HIG (matches "Settings"). The compact all-caps
        // "NAV"/"SPEEDS" forms stay on the in-flight FlightView chrome. (v4 UI/UX Revamp — device feedback)
        navButton("airplane.departure", L10n.Flights.title, tint: .aviationGold, badge: appState.flights.count) { flightLogSelectionID = nil; showFlightLog = true }
        navButton("map.fill", L10n.Nav.navigation, tint: .altimeterBlue) { showNavigation = true }
        navButton("speedometer", L10n.Nav.speeds, tint: .aviationGreen) { showSpeedReference = true }
        navButton("gearshape.fill", L10n.Settings.title, tint: .secondaryText) { pendingSettingsSection = nil; showSettings = true }
    }

    private func navButton(_ icon: String, _ label: String, tint: Color, badge: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .scaledFont(size: 20, relativeTo: .title3)
                        .foregroundColor(tint)
                        .frame(width: 32, height: 26)
                        .loadingRotationEffect(isActive: icon == "clock.arrow.circlepath" && appState.isLoadingFlights)
                    if let badge, badge > 0 {
                        Text("\(badge)")
                            .scaledFont(size: 9, weight: .bold, relativeTo: .caption2)
                            .foregroundColor(.black)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.aviationGold))
                            .offset(x: 10, y: -3)
                    }
                }
                Text(label)
                    .scaledFont(size: 10, weight: .medium, relativeTo: .caption2)
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((badge ?? 0) > 0 ? "\(label), \(badge!)" : label)
    }

    /// Compact "last flight" strip surfaced on the console — taps into the Flight Log. (v4 UI/UX Revamp)
    @ViewBuilder
    private func lastFlightStrip(fillsHeight: Bool) -> some View {
        if let last = appState.flights.max(by: { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }) {
            // iPad rail (landscape): open the 2-column Flight Log with this flight in the right pane.
            // Otherwise (portrait / iPhone): open its detail directly so back returns to Home, not the
            // Flight Log list. (v4 UI/UX Revamp — feedback round 2)
            Button {
                if useRailLayout {
                    flightLogSelectionID = last.id
                    showFlightLog = true
                } else {
                    lastFlightForDetail = last
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.Home.lastFlight)
                            .scaledFont(size: 10, weight: .semibold, relativeTo: .caption2).tracking(0.5)
                            .foregroundColor(.dimText)
                        Text(lastFlightRoute(last))
                            .scaledFont(size: 15, weight: .semibold, design: .monospaced, relativeTo: .subheadline)
                            .foregroundColor(.primaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(last.formattedDuration)
                            .scaledFont(size: 15, weight: .bold, design: .monospaced, relativeTo: .subheadline)
                            .foregroundColor(.aviationGreen)
                        if let when = lastFlightWhen(last) {
                            Text(when).scaledFont(size: 11, relativeTo: .caption2).foregroundColor(.dimText)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                        .foregroundColor(.dimText.opacity(0.7))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .homeStripHeight(fills: fillsHeight)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.cardBackground)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder((AmbientPalette.hairline ?? Color.white.opacity(0.06)), lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(L10n.Home.lastFlight), \(lastFlightRoute(last)), \(last.formattedDuration)")
        }
    }

    /// Smart flight-plan strip, in priority order: the active plan (route + waypoints), else a plan
    /// scheduled for today (route + departure time, gold), else the saved-count link, else nothing.
    /// Taps into the flight-plan list. (v4 UI/UX Revamp — device feedback)
    @ViewBuilder
    private func flightPlanStrip(fillsHeight: Bool) -> some View {
        if let thread = homeThread {
            // A followed flight takes this slot: while a thread is live it IS the flight-plan status,
            // and a third strip would not survive the ~300 pt the iPad gives each one.
            flightThreadStripCard(thread, fillsHeight: fillsHeight)
        } else if let active = flightPlanManager.activeFlightPlan {
            // ARMED. This state used to differ from the others only by an icon tint and a 22 %-opacity
            // border — and in altimeter blue, which reads as "flight plan", not as "ready to fly". Home
            // is the screen you look at before pressing START FLIGHT, so the answer to "am I armed?"
            // has to be free here rather than two taps away in the plan list. Green rail + chip, the
            // same device the plan list already uses for its active section. (v4.4.0)
            // Was an ARMED badge with a green rail. Arming is no longer a state the pilot manages —
            // a flight loads its own route at start — so this now reads as what it actually is: a
            // route someone put on the map to look at. (v5.x)
            flightPlanStripCard(title: planRoute(active),
                                detail: armedDetail(active),
                                accent: .altimeterBlue,
                                badge: L10n.Nav.activate.uppercased(),
                                showsRail: false,
                                fillsHeight: fillsHeight)
        } else {
            // Nothing more specific to say. This slot used to render the saved-plan count — and
            // NOTHING AT ALL for a pilot with no plans yet, which is precisely why the feature that
            // defines this release was unreachable: Home never once mentioned that a flight can be
            // followed. It now always offers to plan one.
            planNewFlightStripCard(fillsHeight: fillsHeight)
        }
    }

    /// The teaching state, and the only door to following a flight that does not require already
    /// having a flight plan.
    private func planNewFlightStripCard(fillsHeight: Bool) -> some View {
        Button { beginPlanningNewFlight() } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus")
                        .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                        .foregroundColor(.aviationGold)
                    Text(L10n.Flights.planNewFlight)
                        .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundColor(.primaryText)
                    Spacer(minLength: 0)
                }
                Text(L10n.Flights.homeExplainer)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if !flightPlanManager.flightPlans.isEmpty {
                    Text(L10n.Flights.savedPlans(flightPlanManager.flightPlans.count))
                        .scaledFont(size: 11, relativeTo: .caption2)
                        .foregroundColor(.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.aviationGold.opacity(0.35), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(L10n.Flights.planNewFlight). \(L10n.Flights.homeExplainer)")
    }

    /// Detail line for an armed plan, longest-first. `ViewThatFits` in the card picks one.
    ///
    /// Needed because the strip is NARROWER on iPad than on iPhone: landscape puts the last-flight and
    /// flight-plan strips side by side inside a 620 pt hero, so each gets ~300 pt, where an iPhone
    /// stacks them full-width. The big screen has less room here, not more.
    private func armedDetail(_ plan: FlightPlan) -> [String] {
        let waypoints = L10n.Home.flightPlanWaypointCount(plan.waypoints.count)
        // "NM" is an ICAO abbreviation and deliberately untranslated, like the rest of the app.
        let distance = plan.totalDistance > 0 ? "\(Int(plan.totalDistance.rounded())) NM" : nil
        let time = plan.totalEET > 0 ? formattedEET(plan.totalEET) : nil
        return [
            [waypoints, distance, time].compactMap { $0 }.joined(separator: " · "),
            [waypoints, distance].compactMap { $0 }.joined(separator: " · "),
            waypoints
        ]
    }

    private func formattedEET(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// The soonest flight plan whose planned departure falls today — surfaced on the strip so an
    /// imminent flight is one tap away instead of buried behind the generic list. (v4 UI/UX Revamp)

    /// `detail` is a longest-first list of candidate strings; the widest that fits is used. A single
    /// string is just a one-element list. `badge` and `showsRail` mark the armed state.
    private func flightPlanStripCard(title: String, detail: [String], accent: Color,
                                     badge: String? = nil, showsRail: Bool = false,
                                     fillsHeight: Bool = false) -> some View {
        Button { showFlightPlanning = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .scaledFont(size: 17, relativeTo: .body)
                    .foregroundColor(accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L10n.Home.flightPlan)
                            .scaledFont(size: 10, weight: .semibold, relativeTo: .caption2).tracking(0.5)
                            .foregroundColor(badge == nil ? .dimText : accent)
                        if let badge {
                            Text(badge)
                                .scaledFont(size: 8.5, weight: .bold, relativeTo: .caption2).tracking(0.8)
                                .foregroundColor(accent)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(accent.opacity(0.18))
                                        .overlay(RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(accent.opacity(0.55), lineWidth: 0.5))
                                )
                        }
                    }
                    HStack(spacing: 6) {
                        Text(title)
                            .scaledFont(size: 14, weight: .semibold, design: .monospaced, relativeTo: .subheadline)
                            .foregroundColor(.primaryText)
                            .lineLimit(1)
                        // Longest detail that fits. See `armedDetail` — the iPad's side-by-side strip
                        // is narrower than the iPhone's full-width one.
                        ViewThatFits(in: .horizontal) {
                            ForEach(detail, id: \.self) { candidate in
                                Text("· \(candidate)")
                                    .scaledFont(size: 12, relativeTo: .caption)
                                    .foregroundColor(.dimText)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                    .foregroundColor(.dimText.opacity(0.7))
            }
            .padding(.leading, showsRail ? 11 : 14)
            .padding(.trailing, 14)
            .padding(.vertical, 12)
            .homeStripHeight(fills: fillsHeight)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(accent.opacity(showsRail ? 0.4 : 0.22), lineWidth: 1))
                    .overlay(alignment: .leading) {
                        if showsRail {
                            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                                .fill(accent)
                                .frame(width: 3)
                        }
                    }
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            [L10n.Home.flightPlan, badge, title, detail.first].compactMap { $0 }.joined(separator: ", ")
        )
    }

    /// Overload keeping the single-detail call sites unchanged.
    private func flightPlanStripCard(title: String, detail: String?, accent: Color,
                                     fillsHeight: Bool = false) -> some View {
        flightPlanStripCard(title: title, detail: [detail].compactMap { $0 }, accent: accent,
                            fillsHeight: fillsHeight)
    }

    // MARK: - Flight thread strip (v5.0.0)

    /// The thread Home advertises: close-out work first because it is already overdue (a filed flight
    /// plan may still be open), otherwise the flight currently being followed.
    private var homeThread: FlightThread? {
        if let closing = threadManager.threadAwaitingCloseOut { return closing }
        if let current = threadManager.currentThread, !current.isFinished { return current }
        return nil
    }

    /// Replaces the flight-plan strip while a flight is being followed: route, readiness, and the one
    /// thing to do next. Taps into the thread.
    private func flightThreadStripCard(_ thread: FlightThread, fillsHeight: Bool) -> some View {
        let isCloseOut = thread.state == .closeOut
        // Urgency belongs to an OPEN plan AFTER the flight, not before it. A filed plan sitting
        // there the day before departure is the normal state of a well-prepared flight; painting
        // Home red for it teaches the pilot to ignore the colour that matters after landing.
        let urgent = thread.hasOpenFlightPlan && isCloseOut
        let accent: Color = urgent ? .aviationRed : (isCloseOut ? .aviationAmber : .aviationGold)
        let progress = isCloseOut ? thread.closeOutProgress : thread.preFlightProgress

        return Button { threadToOpen = thread.id } label: {
            HStack(spacing: 10) {
                threadReadinessRing(progress: progress, accent: accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L10n.Thread.title)
                            .scaledFont(size: 10, weight: .semibold, relativeTo: .caption2).tracking(0.5)
                            .foregroundColor(accent)
                        Text(threadBadge(thread))
                            .scaledFont(size: 8.5, weight: .bold, relativeTo: .caption2).tracking(0.8)
                            .foregroundColor(accent)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(accent.opacity(0.18))
                                    .overlay(RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(accent.opacity(0.55), lineWidth: 0.5))
                            )
                    }
                    Text(thread.routeLabel)
                        .scaledFont(size: 14, weight: .semibold, design: .monospaced, relativeTo: .subheadline)
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                    // Same longest-first ladder as the plan strip: this card is narrower on iPad than
                    // on iPhone, so the next-task line has to be able to shrink.
                    ViewThatFits(in: .horizontal) {
                        ForEach(threadDetail(thread), id: \.self) { candidate in
                            Text(candidate)
                                .scaledFont(size: 12, relativeTo: .caption)
                                .foregroundColor(.dimText)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                    .foregroundColor(.dimText.opacity(0.7))
            }
            .padding(.leading, 11)
            .padding(.trailing, 14)
            .padding(.vertical, 12)
            .homeStripHeight(fills: fillsHeight)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(accent.opacity(0.4), lineWidth: 1))
                    .overlay(alignment: .leading) {
                        UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                            .fill(accent)
                            .frame(width: 3)
                    }
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            [L10n.Thread.title, threadBadge(thread), thread.routeLabel, threadDetail(thread).first]
                .compactMap { $0 }.joined(separator: ", ")
        )
    }

    private func threadReadinessRing(progress: (done: Int, total: Int), accent: Color) -> some View {
        let fraction = progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
        return ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(fraction >= 1 ? Color.aviationGreen : accent,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(progress.done)/\(progress.total)")
                .scaledFont(size: 8.5, weight: .semibold, design: .monospaced, relativeTo: .caption2)
                .foregroundColor(.primaryText)
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }

    private func threadBadge(_ thread: FlightThread) -> String {
        // Same rule as the accent: only shout about an open plan once the flight is over.
        if thread.hasOpenFlightPlan && thread.state == .closeOut {
            return L10n.Thread.openFlightPlanBanner
        }
        switch thread.state {
        case .planned:  return L10n.Thread.statePlanned
        case .ready:    return L10n.Thread.stateReady
        case .flying:   return L10n.Thread.stateFlying
        case .closeOut: return L10n.Thread.stateCloseOut
        case .done:     return L10n.Thread.stateDone
        }
    }

    /// Longest-first detail candidates: the next task if there is one, else the readiness count.
    private func threadDetail(_ thread: FlightThread) -> [String] {
        let progress = thread.state == .closeOut ? thread.closeOutProgress : thread.preFlightProgress
        let count = L10n.Thread.readiness(progress.done, progress.total)
        guard let next = thread.nextTask else {
            return [L10n.Thread.allDone, L10n.Thread.allDone]
        }
        let title = ThreadTaskPresentation.make(for: next).title
        return ["\(L10n.Thread.nextUp): \(title)", title, count]
    }

    /// Departure → destination from a plan's first/last waypoint, else the plan name.
    private func planRoute(_ plan: FlightPlan) -> String {
        let names = plan.waypoints.map(\.name).filter { !$0.isEmpty }
        if names.count >= 2, let first = names.first, let last = names.last {
            return "\(first) → \(last)"
        }
        return plan.name.isEmpty ? (names.first ?? L10n.Nav.flightPlan) : plan.name
    }

    private func lastFlightRoute(_ flight: Flight) -> String {
        if let dep = flight.departureAirportIdent, let arr = flight.arrivalAirportIdent {
            return "\(dep) → \(arr)"
        }
        if !flight.name.isEmpty { return flight.name }
        return flight.aircraftRegistration ?? flight.airplane
    }

    private func lastFlightWhen(_ flight: Flight) -> String? {
        guard let date = flight.startTime else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// START FLIGHT (green) + CIRCUITS (amber) — shared by the stacked layout and the iPad console. (v4 UI/UX Revamp)
    private func startCircuitsButtons(isLandscape: Bool, isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 8 : 12) {
            Button(action: startFlight) {
                HStack(spacing: isCompact ? 10 : 14) {
                    Image(systemName: "play.fill")
                        .scaledFont(size: isCompact ? 18 : 22, relativeTo: .title2)
                    Text(L10n.Button.startFlight)
                        .scaledFont(size: isCompact ? 18 : 22, weight: .bold, relativeTo: .title2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .frame(height: isLandscape ? 50 : (isCompact ? 50 : 70))
            }
            .buttonStyle(PrimaryButtonStyle(color: .aviationGreen))

            // START CIRCUITS button - only shown when circuit mode is enabled
            if appState.settings.enableCircuitMode {
                Button(action: startCircuits) {
                    VStack(spacing: isCompact ? 2 : 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .scaledFont(size: isCompact ? 18 : 20, relativeTo: .title3)
                        Text(L10n.Button.circuits)
                            .scaledFont(size: isCompact ? 13 : 14, weight: .bold, relativeTo: .subheadline)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: isLandscape ? 50 : (isCompact ? 50 : 70))
                }
                .buttonStyle(PrimaryButtonStyle(color: .aviationAmber))
                .frame(minWidth: isLandscape ? 100 : (isCompact ? 120 : 140), maxWidth: isLandscape ? 120 : (isCompact ? 150 : 160))
            }
        }
    }
    
    // MARK: - Aircraft Card Carousel

    /// Current aircraft from settings
    private var currentAircraft: AircraftType {
        appState.settings.selectedAircraft
    }

    private func aircraftCard(isLandscape: Bool, isCompact: Bool) -> some View {
        let aircraft = availableAircraft

        return VStack(spacing: isLandscape ? 4 : (isCompact ? 6 : 12)) {
            // Swipeable aircraft carousel
            TabView(selection: $selectedAircraftIndex) {
                ForEach(Array(aircraft.enumerated()), id: \.element.id) { index, option in
                    aircraftCardContent(for: option, isLandscape: isLandscape, isCompact: isCompact)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: isLandscape ? 100 : (isCompact ? 120 : 180))
            // Discoverability: tappable edge chevrons hint the carousel without shouting. (v4 UI/UX Revamp)
            .overlay(alignment: .leading) { carouselChevron(.left, count: aircraft.count) }
            .overlay(alignment: .trailing) { carouselChevron(.right, count: aircraft.count) }

            // Aircraft indicator chip: dots + "N / M aircraft" (only when more than one). (v4 UI/UX Revamp)
            if aircraft.count > 1 {
                HStack(spacing: 7) {
                    HStack(spacing: 5) {
                        ForEach(0..<aircraft.count, id: \.self) { index in
                            // Active page reads as an elongated gold pill (App Store / onboarding
                            // convention — also matches OnboardingView's pageDots). (v4 UI/UX Revamp — feedback)
                            let isActive = index == selectedAircraftIndex
                            Capsule()
                                .fill(isActive ? Color.aviationGold : Color.dimText.opacity(0.5))
                                .frame(width: isActive ? 18 : 6, height: 6)
                                .animation(.easeInOut(duration: 0.2), value: selectedAircraftIndex)
                        }
                    }
                    Text("\(selectedAircraftIndex + 1) / \(aircraft.count)")
                        .scaledFont(size: 10, weight: .semibold, design: .monospaced, relativeTo: .caption2).tracking(0.4)
                        .foregroundColor(.dimText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.cockpitBackground))
                .padding(.top, isCompact ? 2 : 4)
                .accessibilityElement()
                .accessibilityLabel("Aircraft \(selectedAircraftIndex + 1) of \(aircraft.count)")
            }

            AviationDivider()
                .padding(.horizontal, isCompact ? 16 : (isLandscape ? 20 : 40))

            // Quick stats — cockpit stat chips (checklist version / phases / items). (v4 UI/UX Revamp)
            HStack(spacing: isCompact ? 8 : 10) {
                homeStatChip("CHECKLIST", selectedAircraft.map { "v\($0.version)" } ?? "—", .aviationGold, compact: isLandscape || isCompact)
                homeStatChip("PHASES", "\(ChecklistPhase.allCases.count)", .altimeterBlue, compact: isLandscape || isCompact)
                homeStatChip("ITEMS", cachedItemCountText, .primaryText, compact: isLandscape || isCompact)
            }
        }
        .padding(isCompact ? 12 : (isLandscape ? 14 : 32))
        .background(
            RoundedRectangle(cornerRadius: isCompact ? 12 : 18)
                .fill(Color.cardBackground)
                .shadow(color: .black.opacity(0.4), radius: isCompact ? 8 : (isLandscape ? 12 : 20), x: 0, y: isCompact ? 4 : (isLandscape ? 6 : 10))
        )
    }

    private enum CarouselDirection { case left, right }

    /// A tappable carousel chevron (prev/next aircraft), dimmed/disabled at the ends. Only shown when
    /// there's more than one aircraft, so it hints the swipe without adding weight otherwise. (v4 UI/UX Revamp)
    @ViewBuilder
    private func carouselChevron(_ direction: CarouselDirection, count: Int) -> some View {
        if count > 1 {
            let isLeft = direction == .left
            let atEnd = isLeft ? selectedAircraftIndex == 0 : selectedAircraftIndex == count - 1
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedAircraftIndex = isLeft ? max(0, selectedAircraftIndex - 1) : min(count - 1, selectedAircraftIndex + 1)
                }
            } label: {
                Image(systemName: isLeft ? "chevron.left" : "chevron.right")
                    .scaledFont(size: 20, weight: .semibold, relativeTo: .title3)
                    .foregroundColor(.dimText)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(atEnd)
            .opacity(atEnd ? 0.25 : 0.8)
            .accessibilityLabel(isLeft ? "Previous aircraft" : "Next aircraft")
        }
    }

    /// Content for a single aircraft card in the carousel
    private func aircraftCardContent(for option: AircraftOption, isLandscape: Bool, isCompact: Bool) -> some View {
        VStack(spacing: isLandscape ? 4 : (isCompact ? 6 : 12)) {
            // Aircraft silhouette
            Image(systemName: "airplane")
                .scaledFont(size: isCompact ? 32 : (isLandscape ? 36 : 60), relativeTo: .largeTitle)
                .foregroundColor(.aviationGold.opacity(0.3))

            // Aircraft info
            VStack(spacing: isLandscape ? 2 : (isCompact ? 3 : 6)) {
                Text(option.registration)
                    .scaledFont(size: isCompact ? 22 : (isLandscape ? 26 : 32), weight: .bold, design: .monospaced, relativeTo: .largeTitle)
                    .foregroundColor(.aviationGold)

                Text(option.modelName)
                    .scaledFont(size: isCompact ? 12 : (isLandscape ? 14 : 16), weight: .semibold, relativeTo: .body)
                    .foregroundColor(.primaryText)

                if !isLandscape {
                    Text(L10n.Home.version(option.version))
                        .scaledFont(size: isCompact ? 10 : 12, relativeTo: .caption)
                        .foregroundColor(.dimText)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// A cockpit stat chip for the home card: tiny tracked label over a mono value, on the darker
    /// cockpit surface for contrast against the card. (v4 UI/UX Revamp)
    private func homeStatChip(_ label: String, _ value: String, _ color: Color, compact: Bool) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .scaledFont(size: compact ? 10 : 11, weight: .semibold, relativeTo: .caption2).tracking(0.4)
                .foregroundColor(.secondaryText)
                .lineLimit(1)
            Text(value)
                .scaledFont(size: compact ? 15 : 18, weight: .bold, design: .monospaced, relativeTo: .title3)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 8 : 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cockpitBackground))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    /// Update the cached item count text — avoids disk I/O on every render
    private func updateCachedItemCount() {
        guard let option = selectedAircraft else {
            cachedItemCountText = "—"
            return
        }

        switch option {
        case .bundled(let aircraft):
            cachedItemCountText = "\(aircraft.totalChecklistItems)"
        case .remote(let metadata):
            if let checklist = aircraftDataService.getChecklist(for: metadata.id) {
                cachedItemCountText = "\(checklist.toAircraftAdapter().totalChecklistItems)"
            } else {
                cachedItemCountText = "—"
            }
        }
    }
    
    // MARK: - GPS Status Indicator

    /// Ambient data-currency dot beside GPS: quiet green when fresh, amber/red when stale; tap opens the
    /// Data & Storage hub. Per-state SF Symbols read the state without relying on colour. (v4.1.0)
    /// A small status chip — a tinted capsule with a state icon + short label, both in the state colour.
    /// Shared look for the Home GPS + data-currency indicators. (v4.1.0)
    private func statusChip(icon: String, label: String, tint: Color, isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 4 : 5) {
            Image(systemName: icon)
                .scaledFont(size: isCompact ? 10 : 11, weight: .semibold, relativeTo: .caption2)
            Text(label)
                .scaledFont(size: isCompact ? 11 : 12, weight: .medium, relativeTo: .caption)
                .lineLimit(1)
        }
        .foregroundColor(tint)
        .padding(.horizontal, isCompact ? 7 : 9)
        .padding(.vertical, isCompact ? 3 : 4)
        .background(Capsule().fill(tint.opacity(0.16)))
    }

    private func dataStatusIndicator(isCompact: Bool) -> some View {
        let health = dataStatusManager.overallHealth
        return Button {
            pendingSettingsSection = .dataStorage
            showSettings = true
        } label: {
            statusChip(icon: dataStatusIcon(health), label: dataStatusLabel(health),
                       tint: dataStatusColor(health), isCompact: isCompact)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.DataStorage.title)
        .accessibilityValue(dataStatusAccessibilityValue(health))
        .accessibilityHint(L10n.DataStorage.subtitle)
    }

    private func dataStatusIcon(_ health: DataHealth) -> String {
        switch health {
        case .noData: return "externaldrive.badge.xmark"
        case .ok: return "checkmark.seal.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .urgent: return "exclamationmark.octagon.fill"
        }
    }

    private func dataStatusColor(_ health: DataHealth) -> Color {
        switch health {
        case .noData: return .secondaryText   // neutral grey — nothing downloaded
        case .ok: return .aviationGreen
        case .attention: return .aviationYellow
        case .urgent: return .aviationRed
        }
    }

    /// Short chip label. Only the "no data" case overrides the generic "Data" label — colour carries
    /// fresh/aging/stale, while "No data" replaces the previously-misleading green "OK". (v4.1.0)
    private func dataStatusLabel(_ health: DataHealth) -> String {
        switch health {
        case .noData: return L10n.DataStorage.statusNoData
        case .ok, .attention, .urgent: return L10n.DataStorage.homeLabel
        }
    }

    private func dataStatusAccessibilityValue(_ health: DataHealth) -> String {
        switch health {
        case .noData: return L10n.DataStorage.statusNoData
        case .ok: return L10n.DataStorage.statusFresh
        case .attention: return L10n.DataStorage.statusAging
        case .urgent: return L10n.DataStorage.statusStale
        }
    }

    private func gpsStatusIndicator(isCompact: Bool) -> some View {
        statusChip(icon: locationStatusIcon, label: locationStatusText,
                   tint: locationStatusColor, isCompact: isCompact)
    }
    
    // MARK: - Helpers

    private var locationStatusIcon: String {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return "location.fill"
        case .denied, .restricted:
            return "location.slash.fill"
        default:
            return "location"
        }
    }
    
    private var locationStatusColor: Color {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return .aviationGreen
        case .denied, .restricted:
            return .aviationRed
        default:
            return .dimText
        }
    }
    
    private var locationStatusText: String {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return L10n.GPS.ready
        case .denied:
            return L10n.GPS.denied
        case .restricted:
            return L10n.GPS.restricted
        default:
            return L10n.GPS.notSet
        }
    }
    
    // MARK: - Planning a flight (v5.0.0)

    /// Open the one creation sheet, seeded from the aircraft already selected on this screen.
    /// `seed` is supplied by "Plan this again"; nil starts from scratch.
    private func beginPlanningNewFlight(_ seed: NewFlightIntent? = nil) {
        if let seed {
            planningNewFlight = seed
            return
        }
        let aircraft = selectedAircraft
        planningNewFlight = NewFlightIntent(
            departureIdent: "",
            arrivalIdent: "",
            departureTime: nil,
            aircraftTypeId: aircraft?.aircraftType ?? appState.settings.selectedAircraft.rawValue,
            aircraftRegistration: aircraft?.registration ?? appState.settings.selectedAircraft.registration,
            aircraftModelName: aircraft?.modelName ?? appState.settings.selectedAircraft.modelName,
            kind: .crossCountry
        )
    }

    /// Turn an intent into a plan and the flight that follows it.
    ///
    /// The airport layer is loaded on demand rather than at launch, so this awaits it before
    /// resolving idents — otherwise a flight created on a cold start would silently get no waypoints,
    /// and with no coordinates there is no country detection and therefore no customs, DABS or GAFOR.
    /// Three or more stops is a trip; two is the single flight this has always made.
    private func createFlight(stops: [String], from intent: NewFlightIntent, route: FlightPlan? = nil) {
        // The creation awaits `ensureLoaded()` and the notification prompt, and the sheet stays
        // hit-testable through its dismissal animation — so a double-tap ran this body twice and
        // produced two plans and two threads, breaking the one-thread-per-plan invariant that
        // `thread(forPlanId:)` and close-out both depend on. (review, concurrency)
        guard !isCreatingFlight else { return }
        isCreatingFlight = true
        Task { @MainActor in
            defer { isCreatingFlight = false }
            // A saved route is copied whole — its waypoints, altitudes and fuel are the reason it
            // was worth saving, and rebuilding from two idents would discard all of it.
            if let route {
                let thread = await FlightCreator.create(fromRoute: route,
                                                        intent: intent,
                                                        plans: flightPlanManager,
                                                        threads: threadManager)
                threadToOpen = thread.id
                return
            }
            if stops.count > 2,
               let trip = await FlightCreator.createTrip(idents: stops,
                                                         template: intent,
                                                         plans: flightPlanManager,
                                                         threads: threadManager,
                                                         airports: airportDataService) {
                threadToOpen = trip.legIds.first
                return
            }
            let thread = await FlightCreator.create(from: intent,
                                                    plans: flightPlanManager,
                                                    threads: threadManager,
                                                    airports: airportDataService)
            threadToOpen = thread.id
        }
    }

    /// START FLIGHT.
    ///
    /// A followed flight for today is what this press is ABOUT, so it answers first — including one
    /// left in FLY, which is a session the pilot abandoned and is coming back to. Everything else
    /// departs straight away: there is no route to offer, because a route without a flight has no
    /// date and is not "today's".
    private func startFlight() {
        // A followed flight for today is what this press is ABOUT, so it answers first — including
        // one left in FLY, which is a session the pilot abandoned and is coming back to. Asking
        // about tomorrow's plan while today's flight sits half-flown was the confusing case.
        if let followed = threadManager.startableFlightToday {
            let remaining = followed.preFlightProgress.total - followed.preFlightProgress.done
            if remaining > 0 {
                startPrompt = .outstanding(thread: followed, remaining: remaining)
                return
            }
            launch(followed)
            return
        }
        beginFlight(circuitMode: false)
    }

    /// Depart on a followed flight: arm its route if it has one and nothing is armed yet, then start.
    ///
    /// Arming here is what the pilot means by pressing START FLIGHT on a flight they planned — the
    /// route, the leg timing and the waypoint sequencing are the reason they built it.
    private func launch(_ thread: FlightThread) {
        // The aircraft the flight was PLANNED with, not whatever the carousel was left on. Without
        // this the hero card names HB-PFA while the flight starts on the WT9's checklist, with the
        // WT9's speeds in the event detector, logged under the wrong registration — and the thread,
        // its mass & balance and its cost ledger all disagree with the flight. `selectAircraft`
        // resolves a registration and leaves the selection untouched if it cannot. (review F19)
        if let registration = thread.aircraftRegistration, !registration.isEmpty {
            _ = appState.selectAircraft(id: registration,
                                        available: aircraftDataService.availableAircraft)
        }
        if let planId = thread.flightPlanId,
           flightPlanManager.activeFlightPlan?.id != planId,
           let plan = flightPlanManager.flightPlans.first(where: { $0.id == planId }),
           !plan.waypoints.isEmpty {
            flightPlanManager.activateFlightPlan(plan)
        }
        // A planned circuits session is still circuits. Hardcoding false here started it as a
        // 16-phase cross-country from the hero while its own screen started it correctly, so one
        // thread produced two different flights depending on which button was pressed. (review F20)
        beginFlight(circuitMode: thread.profile == .local, followedFlightId: thread.id)
    }

    private func startCircuits() { beginFlight(circuitMode: true) }

    /// Unified flight-start path. Every entry point — these buttons, the widget, and deep links —
    /// goes through the shared `FlightLauncher`, which resolves the checklist, runs the ARCH-01 /
    /// entitlement / permission / active-flight guards, configures the event detector, starts the
    /// flight and begins GPS tracking in one place. (Task 2/3)
    /// The demoted shortcut: a flight that is deliberately not the one on the hero.
    private func startUnplannedFlight() { beginFlight(circuitMode: false, unplanned: true) }

    private func beginFlight(circuitMode: Bool, followedFlightId: UUID? = nil, unplanned: Bool = false) {
        let launcher = FlightLauncher(
            appState: appState,
            locationManager: locationManager,
            aircraftDataService: aircraftDataService,
            airportDataService: airportDataService,
            flightEventDetector: flightEventDetector,
            flightPlanManager: flightPlanManager,
            threadManager: threadManager
        )
        Task { await launcher.begin(circuitMode: circuitMode, followedFlightId: followedFlightId, unplanned: unplanned) }
    }
}

// MARK: - Symbol Effect Compatibility

private extension View {
    /// Rotating symbol effect used as the "loading flights" cue.
    /// `.rotate` requires iOS 18+; fall back to `.pulse` on the iOS 17.0 floor. (ARCH-09)
    @ViewBuilder
    func loadingRotationEffect(isActive: Bool) -> some View {
        if #available(iOS 18.0, *) {
            symbolEffect(.rotate, isActive: isActive)
        } else {
            symbolEffect(.pulse, isActive: isActive)
        }
    }
}

// MARK: - Preview

#Preview {
    let subManager = SubscriptionManager()
    return HomeView()
        .environment(AppState())
        .environmentObject(LocationManager())
        .environmentObject(OfflineMapManager())
        .environmentObject(FlightPlanManager())
        .environmentObject(AircraftDataService(subscriptionManager: subManager))
        .environmentObject(subManager)
        .environmentObject(DataStatusManager(providers: [], networkMonitor: NetworkMonitor(stub: .disconnected)))
}



// MARK: - Home strip sizing

private extension View {
    /// Make a Home activity strip fill the height its row was given.
    ///
    /// A `Grid` equalises the CELL, not the card drawn inside it: without this the shorter card's
    /// rounded rectangle keeps its own intrinsic height and floats, centred, in a taller cell — which
    /// looks exactly like the mismatch a Grid was supposed to remove. The frame has to sit BEFORE the
    /// `.background`, so the background paints behind the stretched bounds rather than the content's.
    ///
    /// Off in the stacked layout, where the strips are in a scroll view with no height to fill.
    func homeStripHeight(fills: Bool) -> some View {
        frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil)
    }
}
