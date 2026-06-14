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
    @State private var selectedAircraftIndex: Int = 0
    @State private var cachedItemCountText: String = "—"

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
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let isCompact = isCompactWidth(geometry)

            ZStack {
                // Background
                Color.cockpitBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    header(isLandscape: isLandscape, isCompact: isCompact)
                        .padding(.horizontal, isCompact ? 16 : 24)
                        .padding(.top, isLandscape ? 8 : (isCompact ? 12 : 20))

                    Spacer(minLength: isLandscape ? 8 : (isCompact ? 12 : 24))

                    // Main content
                    mainContent(isLandscape: isLandscape, isCompact: isCompact)
                        .frame(maxWidth: 700)

                    Spacer(minLength: isLandscape ? 8 : (isCompact ? 12 : 24))

                    // Quick access buttons
                    bottomBar(isLandscape: isLandscape, isCompact: isCompact)
                        .padding(.horizontal, isCompact ? 12 : 24)
                        .padding(.bottom, isLandscape ? 12 : (isCompact ? 16 : 32))
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(locationManager)
        }
        .fullScreenCover(isPresented: $showFlightLog) {
            FlightLogView()
                .environmentObject(appState)
                .environmentObject(flightPlanManager)
                .environmentObject(airportDataService)
                .environmentObject(openAIPDataService)
        }
        .sheet(isPresented: $showSpeedReference) {
            SpeedReferenceSheet()
                .environmentObject(appState)
        }
        .fullScreenCover(isPresented: $showNavigation) {
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
    
    // MARK: - Header

    private func header(isLandscape: Bool, isCompact: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: isCompact ? 6 : 10) {
                    Image(systemName: "airplane")
                        .font(.system(size: isCompact ? 22 : (isLandscape ? 26 : 32)))
                        .foregroundColor(.aviationGold)

                    Text("AéroCheck")
                        .font(.system(size: isCompact ? 20 : (isLandscape ? 24 : 28), weight: .bold, design: .default))
                        .foregroundColor(.primaryText)
                        .tracking(isCompact ? 1 : 2)
                }

                Text(L10n.App.tagline)
                    .font(.system(size: isCompact ? 10 : 12))
                    .foregroundColor(.secondaryText)
            }

            Spacer()

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: isCompact ? 18 : 22))
                    .foregroundColor(.secondaryText)
            }
            .accessibilityLabel(L10n.Settings.title)
        }
    }
    
    // MARK: - Main Content

    private func mainContent(isLandscape: Bool, isCompact: Bool) -> some View {
        VStack(spacing: isLandscape ? 12 : (isCompact ? 20 : 40)) {
            // Aircraft card
            aircraftCard(isLandscape: isLandscape, isCompact: isCompact)

            // Start flight button(s) - keep consistent size
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
                // Ratio: 60%/40% on iPhone, 70%/30% on iPad
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
            .padding(.horizontal, isCompact ? 20 : 40)

            // Info text and GPS status - hide only on compact devices (iPhone)
            if !isCompact {
                VStack(spacing: isLandscape ? 8 : 12) {
                    Text(L10n.Home.flightInfo)
                        .font(.system(size: isLandscape ? 13 : 15))
                        .foregroundColor(.dimText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, isLandscape ? 20 : 40)

                    // GPS status indicator
                    gpsStatusIndicator(isCompact: isCompact)
                }
            }
        }
        .padding(isLandscape ? 12 : (isCompact ? 16 : 32))
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

            // Page indicator dots (only show if more than 1 aircraft)
            if aircraft.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<aircraft.count, id: \.self) { index in
                        Circle()
                            .fill(index == selectedAircraftIndex ? Color.aviationGold : Color.dimText.opacity(0.5))
                            .frame(width: 6, height: 6)
                            .animation(.easeInOut(duration: 0.2), value: selectedAircraftIndex)
                    }
                }
                .padding(.top, isCompact ? 2 : 4)
                .accessibilityElement()
                .accessibilityLabel("Aircraft \(selectedAircraftIndex + 1) of \(aircraft.count)")
            }

            AviationDivider()
                .padding(.horizontal, isCompact ? 16 : (isLandscape ? 20 : 40))

            // Quick stats
            HStack(spacing: isCompact ? 16 : (isLandscape ? 24 : 40)) {
                QuickStatView(
                    icon: "list.bullet.clipboard.fill",
                    value: "\(ChecklistPhase.allCases.count)",
                    label: L10n.Stats.checks,
                    isCompact: isLandscape || isCompact
                )
                .frame(maxWidth: .infinity)

                QuickStatView(
                    icon: "list.bullet",
                    value: cachedItemCountText,
                    label: L10n.Stats.items,
                    isCompact: isLandscape || isCompact
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(isCompact ? 12 : (isLandscape ? 14 : 32))
        .background(
            RoundedRectangle(cornerRadius: isCompact ? 12 : 18)
                .fill(Color.cardBackground)
                .shadow(color: .black.opacity(0.4), radius: isCompact ? 8 : (isLandscape ? 12 : 20), x: 0, y: isCompact ? 4 : (isLandscape ? 6 : 10))
        )
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
    
    // MARK: - Bottom Bar

    private func bottomBar(isLandscape: Bool, isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 8 : 16) {
            // Flight log button
            Button(action: { showFlightLog = true }) {
                HStack(spacing: isCompact ? 4 : 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: isCompact ? 14 : 18))
                        .loadingRotationEffect(isActive: appState.isLoadingFlights)
                    if !isCompact {
                        Text(L10n.Button.flightLog)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    if appState.isLoadingFlights {
                        // Show nothing while loading — the spinning icon is the cue
                    } else if !appState.flights.isEmpty {
                        Text(isCompact ? "\(appState.flights.count)" : "(\(appState.flights.count))")
                            .font(.system(size: isCompact ? 12 : 14, weight: .semibold))
                            .foregroundColor(.aviationGold)
                    }
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            // The text label is hidden on iPhone (compact); always expose it to VoiceOver.
            .accessibilityLabel(appState.flights.isEmpty ? L10n.Button.flightLog : "\(L10n.Button.flightLog), \(appState.flights.count)")

            Spacer()

            // Navigation button (centered)
            Button(action: { showNavigation = true }) {
                HStack(spacing: isCompact ? 4 : 8) {
                    Image(systemName: "map.fill")
                        .font(.system(size: isCompact ? 14 : 18))
                    if !isCompact {
                        Text(L10n.Button.nav)
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityLabel(L10n.Button.nav)

            Spacer()

            // Speed reference button
            Button(action: { showSpeedReference = true }) {
                HStack(spacing: isCompact ? 4 : 8) {
                    Image(systemName: "speedometer")
                        .font(.system(size: isCompact ? 14 : 18))
                    if !isCompact {
                        Text(L10n.Button.speeds)
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityLabel(L10n.Button.speeds)
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

