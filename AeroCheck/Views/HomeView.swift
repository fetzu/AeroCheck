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
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var flightEventDetector: FlightEventDetector
    @EnvironmentObject var openAIPCacheManager: OpenAIPCacheManager
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @State private var showSettings = false
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
            || showFlightPlanning || lastFlightForDetail != nil
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
                                .padding(.horizontal, isCompact ? 16 : 24)
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
            SettingsView()
                .environmentObject(appState)
                .environmentObject(locationManager)
        }
        .fullScreenCover(isPresented: coverBinding($showFlightLog)) {
            FlightLogView(initialFlightID: flightLogSelectionID)
                .environmentObject(appState)
                .environmentObject(flightPlanManager)
                .environmentObject(airportDataService)
                .environmentObject(openAIPDataService)
        }
        .sheet(isPresented: coverBinding($showSpeedReference)) {
            SpeedReferenceSheet()
                .environmentObject(appState)
        }
        .fullScreenCover(isPresented: $showFlightPlanning) {
            FlightPlanningView()
                .environmentObject(appState)
                .environmentObject(flightPlanManager)
                .environmentObject(airportDataService)
                .environmentObject(aircraftDataService)
                .environmentObject(openAIPDataService)
                .environmentObject(locationManager)
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
            .environmentObject(appState)
            .environmentObject(flightPlanManager)
            .environmentObject(airportDataService)
            .environmentObject(openAIPDataService)
        }
        .fullScreenCover(isPresented: coverBinding($showNavigation)) {
            NavigationMapView(isPresented: $showNavigation)
                .environmentObject(appState)
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
            SubscriptionView()
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
                    await aircraftDataService.fetchAvailableAircraft()
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
                    SettingsView(onClose: { showSettings = false })
                        .environmentObject(appState)
                        .environmentObject(locationManager)
                        .background(Color.cockpitBackground.ignoresSafeArea())
                        .transition(.move(edge: .leading))
                }
                if showFlightLog {
                    FlightLogView(onClose: { showFlightLog = false }, initialFlightID: flightLogSelectionID)
                        .environmentObject(appState)
                        .environmentObject(flightPlanManager)
                        .environmentObject(airportDataService)
                        .environmentObject(openAIPDataService)
                        .background(Color.cockpitBackground.ignoresSafeArea())
                        .transition(.move(edge: .leading))
                }
                if showSpeedReference {
                    // Speed Reference stays a *popup* (not a full takeover) — the landscape analog of
                    // the portrait bottom sheet: a constrained card sliding in from the leading edge
                    // over a dimmed backdrop, tap-outside to dismiss. (v4 UI/UX Revamp — device feedback)
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                            .onTapGesture { showSpeedReference = false }
                            .transition(.opacity)
                        SpeedReferenceSheet(onClose: { showSpeedReference = false })
                            .environmentObject(appState)
                            .frame(width: 460, height: 540)
                            .background(Color.cockpitBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
                            .padding(.leading, 28)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                if showNavigation {
                    NavigationMapView(isPresented: $showNavigation)
                        .environmentObject(appState)
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
            aircraftCard(isLandscape: false, isCompact: isCompact)   // the fuller, taller card
                .frame(maxWidth: heroWidth)
            startCircuitsButtons(isLandscape: landscape, isCompact: isCompact)
                .frame(maxWidth: heroWidth)
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
            HStack(spacing: 12) {
                lastFlightStrip
                flightPlanStrip
            }
        } else {
            VStack(spacing: 12) {
                lastFlightStrip
                flightPlanStrip
            }
        }
    }

    /// Shared width for the hero card, the Start/Circuits line, and the last-flight strip. (v4 UI/UX Revamp)
    private var heroWidth: CGFloat { 620 }

    /// Brand mark for the portrait header (no gear — Settings lives in the tab bar now). (v4 UI/UX Revamp)
    private func brandHeader(isCompact: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: isCompact ? 6 : 10) {
                    Image(systemName: "airplane")
                        .font(.system(size: isCompact ? 22 : 28))
                        .foregroundColor(.aviationGold)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 5) { AmbientController.shared.engage() }
                    Text("AéroCheck")
                        .font(.system(size: isCompact ? 20 : 26, weight: .bold))
                        .foregroundColor(.primaryText)
                        .tracking(isCompact ? 1 : 2)
                }
                Text(L10n.App.tagline)
                    .font(.system(size: isCompact ? 10 : 12))
                    .foregroundColor(.secondaryText)
            }
            Spacer()
            // The single GPS status for portrait / iPhone (landscape shows it in the rail foot). (v4 UI/UX Revamp)
            gpsStatusIndicator(isCompact: isCompact)
        }
    }

    // MARK: - Nav rail / tab bar (Direction 1)

    private var railSurface: Color { AmbientPalette.chrome ?? Color(red: 0.10, green: 0.10, blue: 0.13) }

    /// Vertical command rail (iPad landscape): brand mark, the four destinations, GPS at the foot.
    private var navRail: some View {
        VStack(spacing: 0) {
            Image(systemName: "airplane")
                .font(.system(size: 26))
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
            gpsStatusIndicator(isCompact: true)
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
        navButton("clock.arrow.circlepath", L10n.FlightLog.title, tint: .aviationGold, badge: appState.flights.count) { flightLogSelectionID = nil; showFlightLog = true }
        navButton("map.fill", L10n.Nav.navigation, tint: .altimeterBlue) { showNavigation = true }
        navButton("speedometer", L10n.Nav.speeds, tint: .aviationGreen) { showSpeedReference = true }
        navButton("gearshape.fill", L10n.Settings.title, tint: .secondaryText) { showSettings = true }
    }

    private func navButton(_ icon: String, _ label: String, tint: Color, badge: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(tint)
                        .frame(width: 32, height: 26)
                        .loadingRotationEffect(isActive: icon == "clock.arrow.circlepath" && appState.isLoadingFlights)
                    if let badge, badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.aviationGold))
                            .offset(x: 10, y: -3)
                    }
                }
                Text(label)
                    .font(.system(size: 10, weight: .medium))
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
    private var lastFlightStrip: some View {
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
                            .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                            .foregroundColor(.dimText)
                        Text(lastFlightRoute(last))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(last.formattedDuration)
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(.aviationGreen)
                        if let when = lastFlightWhen(last) {
                            Text(when).font(.system(size: 11)).foregroundColor(.dimText)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.dimText.opacity(0.7))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
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
    private var flightPlanStrip: some View {
        if let active = flightPlanManager.activeFlightPlan {
            flightPlanStripCard(title: planRoute(active), detail: "\(active.waypoints.count) WP", accent: .altimeterBlue)
        } else if let today = todaysFlightPlan, let departure = today.plannedDepartureTime {
            flightPlanStripCard(title: planRoute(today), detail: departure.formatted(date: .omitted, time: .shortened), accent: .aviationGold)
        } else if !flightPlanManager.flightPlans.isEmpty {
            flightPlanStripCard(title: L10n.Nav.flightPlans, detail: "\(flightPlanManager.flightPlans.count)", accent: .secondaryText)
        }
    }

    /// The soonest flight plan whose planned departure falls today — surfaced on the strip so an
    /// imminent flight is one tap away instead of buried behind the generic list. (v4 UI/UX Revamp)
    private var todaysFlightPlan: FlightPlan? {
        let calendar = Calendar.current
        return flightPlanManager.flightPlans
            .filter { plan in
                guard let departure = plan.plannedDepartureTime else { return false }
                return calendar.isDateInToday(departure)
            }
            .min { ($0.plannedDepartureTime ?? .distantFuture) < ($1.plannedDepartureTime ?? .distantFuture) }
    }

    private func flightPlanStripCard(title: String, detail: String?, accent: Color) -> some View {
        Button { showFlightPlanning = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 17))
                    .foregroundColor(accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Home.flightPlan)
                        .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                        .foregroundColor(.dimText)
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primaryText)
                            .lineLimit(1)
                        if let detail {
                            Text("· \(detail)").font(.system(size: 12)).foregroundColor(.dimText).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.dimText.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.22), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(L10n.Home.flightPlan), \(title)")
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
                        .font(.system(size: isCompact ? 18 : 22))
                    Text(L10n.Button.startFlight)
                        .font(.system(size: isCompact ? 18 : 22, weight: .bold))
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
                            .font(.system(size: isCompact ? 18 : 20))
                        Text(L10n.Button.circuits)
                            .font(.system(size: isCompact ? 13 : 14, weight: .bold))
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
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.4)
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
                    .font(.system(size: 20, weight: .semibold))
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
                .font(.system(size: isCompact ? 32 : (isLandscape ? 36 : 60)))
                .foregroundColor(.aviationGold.opacity(0.3))

            // Aircraft info
            VStack(spacing: isLandscape ? 2 : (isCompact ? 3 : 6)) {
                Text(option.registration)
                    .font(.system(size: isCompact ? 22 : (isLandscape ? 26 : 32), weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationGold)

                Text(option.modelName)
                    .font(.system(size: isCompact ? 12 : (isLandscape ? 14 : 16), weight: .semibold))
                    .foregroundColor(.primaryText)

                if !isLandscape {
                    Text(L10n.Home.version(option.version))
                        .font(.system(size: isCompact ? 10 : 12))
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
                .font(.system(size: compact ? 10 : 11, weight: .semibold)).tracking(0.4)
                .foregroundColor(.secondaryText)
                .lineLimit(1)
            Text(value)
                .font(.system(size: compact ? 15 : 18, weight: .bold, design: .monospaced))
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

    private func gpsStatusIndicator(isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 4 : 6) {
            Image(systemName: locationStatusIcon)
                .font(.system(size: isCompact ? 11 : 13))
                .foregroundColor(locationStatusColor)
            Text(locationStatusText)
                .font(.system(size: 12))
                .foregroundColor(.secondaryText)
        }
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
    
    private func startFlight() { beginFlight(circuitMode: false) }

    private func startCircuits() { beginFlight(circuitMode: true) }

    /// Unified flight-start path. Every entry point — these buttons, the widget, and deep links —
    /// goes through the shared `FlightLauncher`, which resolves the checklist, runs the ARCH-01 /
    /// entitlement / permission / active-flight guards, configures the event detector, starts the
    /// flight and begins GPS tracking in one place. (Task 2/3)
    private func beginFlight(circuitMode: Bool) {
        let launcher = FlightLauncher(
            appState: appState,
            locationManager: locationManager,
            aircraftDataService: aircraftDataService,
            airportDataService: airportDataService,
            flightEventDetector: flightEventDetector,
            flightPlanManager: flightPlanManager
        )
        Task { await launcher.begin(circuitMode: circuitMode) }
    }
}

// MARK: - Quick Stat View

struct QuickStatView: View {
    let icon: String
    let value: String
    let label: String
    var isCompact: Bool = false
    
    var body: some View {
        VStack(spacing: isCompact ? 3 : 8) {
            Image(systemName: icon)
                .font(.system(size: isCompact ? 16 : 20))
                .foregroundColor(.aviationBlue)
                .accessibilityHidden(true)

            Text(value)
                .font(.system(size: isCompact ? 18 : 24, weight: .bold, design: .monospaced))
                .foregroundColor(.primaryText)

            Text(label)
                .font(.system(size: isCompact ? 11 : 13))
                .foregroundColor(.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
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
        .environmentObject(AppState())
        .environmentObject(LocationManager())
        .environmentObject(OfflineMapManager())
        .environmentObject(FlightPlanManager())
        .environmentObject(AircraftDataService(subscriptionManager: subManager))
        .environmentObject(subManager)
}

