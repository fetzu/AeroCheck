import SwiftUI

/// Home view - main screen when no flight is active
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @State private var showSettings = false
    @State private var showFlightLog = false
    @State private var showSpeedReference = false
    @State private var showNavigation = false
    @State private var remoteAircraftMetadata: RemoteAircraftMetadata? = nil
    
    /// Check if we're on a compact width device (iPhone)
    private func isCompactWidth(_ geometry: GeometryProxy) -> Bool {
        geometry.size.width < 600
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
        .sheet(isPresented: $showFlightLog) {
            FlightLogView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showSpeedReference) {
            SpeedReferenceSheet()
        }
        .fullScreenCover(isPresented: $showNavigation) {
            NavigationMapView(isPresented: $showNavigation)
                .environmentObject(appState)
                .environmentObject(locationManager)
                .environmentObject(offlineMapManager)
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

                Text("Keep your flights in check!")
                    .font(.system(size: isCompact ? 10 : 12))
                    .foregroundColor(.secondaryText)
            }

            Spacer()

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: isCompact ? 18 : 22))
                    .foregroundColor(.secondaryText)
            }
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
                        Text("START FLIGHT")
                            .font(.system(size: isCompact ? 18 : 22, weight: .bold))
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
                            Text("CIRCUITS")
                                .font(.system(size: isCompact ? 14 : 14, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
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
                    Text("Starting a flight will begin GPS tracking and guide you through all checklists.")
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
    
    // MARK: - Aircraft Card

    /// Current aircraft from settings
    private var currentAircraft: AircraftType {
        appState.settings.selectedAircraft
    }

    private func aircraftCard(isLandscape: Bool, isCompact: Bool) -> some View {
        VStack(spacing: isLandscape ? 8 : (isCompact ? 10 : 20)) {
            // Aircraft silhouette
            Image(systemName: "airplane")
                .font(.system(size: isCompact ? 40 : (isLandscape ? 44 : 80)))
                .foregroundColor(.aviationGold.opacity(0.3))

            // Aircraft info - show remote or bundled
            if let remoteId = appState.settings.selectedRemoteAircraftId,
               let remote = remoteAircraftMetadata {
                // Remote aircraft
                VStack(spacing: isLandscape ? 2 : (isCompact ? 4 : 8)) {
                    HStack(spacing: 8) {
                        Text(remote.registration)
                            .font(.system(size: isCompact ? 24 : (isLandscape ? 28 : 36), weight: .bold, design: .monospaced))
                            .foregroundColor(.aviationGold)

                        if !remote.isFree {
                            Image(systemName: "star.fill")
                                .font(.system(size: isCompact ? 16 : 20))
                                .foregroundColor(.aviationGold)
                        }
                    }

                    Text(remote.shortModelName)
                        .font(.system(size: isCompact ? 13 : (isLandscape ? 15 : 18), weight: .semibold))
                        .foregroundColor(.primaryText)

                    if !isLandscape && !isCompact {
                        VStack(spacing: 4) {
                            Text("Version \(remote.version) • \(remote.lastUpdated)")
                                .font(.system(size: 13))
                                .foregroundColor(.dimText)

                            // Show cache status if checklist is cached
                            if aircraftDataService.isChecklistCached(aircraftId: remote.id) {
                                if aircraftDataService.isCacheValid(aircraftId: remote.id) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.aviationGreen)
                                        Text("Available offline")
                                            .font(.system(size: 11))
                                            .foregroundColor(.aviationGreen)
                                    }
                                } else {
                                    HStack(spacing: 4) {
                                        Image(systemName: "clock")
                                            .font(.system(size: 10))
                                            .foregroundColor(.aviationAmber)
                                        Text("Cache expired")
                                            .font(.system(size: 11))
                                            .foregroundColor(.aviationAmber)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                // Bundled aircraft
                VStack(spacing: isLandscape ? 2 : (isCompact ? 4 : 8)) {
                    Text(currentAircraft.registration)
                        .font(.system(size: isCompact ? 24 : (isLandscape ? 28 : 36), weight: .bold, design: .monospaced))
                        .foregroundColor(.aviationGold)

                    Text(currentAircraft.shortModelName)
                        .font(.system(size: isCompact ? 13 : (isLandscape ? 15 : 18), weight: .semibold))
                        .foregroundColor(.primaryText)

                    if !isLandscape && !isCompact {
                        Text("Version \(currentAircraft.checklistVersion) • \(currentAircraft.lastUpdated)")
                            .font(.system(size: 13))
                            .foregroundColor(.dimText)
                    }
                }
            }

            AviationDivider()
                .padding(.horizontal, isCompact ? 16 : (isLandscape ? 20 : 40))

            // Quick stats
            HStack(spacing: isCompact ? 16 : (isLandscape ? 24 : 40)) {
                QuickStatView(
                    icon: "book.closed.fill",
                    value: "\(ChecklistPhase.allCases.count)",
                    label: "Checklists",
                    isCompact: isLandscape || isCompact
                )

                QuickStatView(
                    icon: "list.bullet",
                    value: itemCountText,
                    label: "Items",
                    isCompact: isLandscape || isCompact
                )

                QuickStatView(
                    icon: "doc.text.fill",
                    value: pageCountText,
                    label: "Pages",
                    isCompact: isLandscape || isCompact
                )
            }
        }
        .padding(isCompact ? 12 : (isLandscape ? 14 : 32))
        .background(
            RoundedRectangle(cornerRadius: isCompact ? 12 : 18)
                .fill(Color.cardBackground)
                .shadow(color: .black.opacity(0.4), radius: isCompact ? 8 : (isLandscape ? 12 : 20), x: 0, y: isCompact ? 4 : (isLandscape ? 6 : 10))
        )
        .onAppear {
            loadRemoteAircraftIfNeeded()
        }
        .onChange(of: appState.settings.selectedRemoteAircraftId) { _, _ in
            loadRemoteAircraftIfNeeded()
        }
    }

    private var itemCountText: String {
        if let remote = remoteAircraftMetadata {
            return "—" // Will be calculated when checklist is loaded
        }
        return "\(currentAircraft.totalChecklistItems)"
    }

    private var pageCountText: String {
        if let remote = remoteAircraftMetadata {
            return "\(remote.pageCount)"
        }
        return "\(currentAircraft.pageCount)"
    }

    private func loadRemoteAircraftIfNeeded() {
        guard let remoteId = appState.settings.selectedRemoteAircraftId else {
            remoteAircraftMetadata = nil
            return
        }

        // Find the remote aircraft in the available list
        remoteAircraftMetadata = aircraftDataService.availableAircraft.first { $0.id == remoteId }
    }
    
    // MARK: - Bottom Bar

    private func bottomBar(isLandscape: Bool, isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 8 : 16) {
            // Flight log button
            Button(action: { showFlightLog = true }) {
                HStack(spacing: isCompact ? 4 : 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: isCompact ? 14 : 18))
                    if !isCompact {
                        Text("FLIGHT LOG")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    if !appState.flights.isEmpty {
                        Text(isCompact ? "\(appState.flights.count)" : "(\(appState.flights.count))")
                            .font(.system(size: isCompact ? 12 : 14, weight: .semibold))
                            .foregroundColor(.aviationGold)
                    }
                }
            }
            .buttonStyle(SecondaryButtonStyle())

            Spacer()

            // Navigation button (centered)
            Button(action: { showNavigation = true }) {
                HStack(spacing: isCompact ? 4 : 8) {
                    Image(systemName: "map.fill")
                        .font(.system(size: isCompact ? 14 : 18))
                    if !isCompact {
                        Text("NAV")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
            }
            .buttonStyle(SecondaryButtonStyle())

            Spacer()

            // Speed reference button
            Button(action: { showSpeedReference = true }) {
                HStack(spacing: isCompact ? 4 : 8) {
                    Image(systemName: "speedometer")
                        .font(.system(size: isCompact ? 14 : 18))
                    if !isCompact {
                        Text("SPEEDS")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
            }
            .buttonStyle(SecondaryButtonStyle())
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
            return "GPS Ready"
        case .denied:
            return "GPS Denied"
        case .restricted:
            return "GPS Restricted"
        default:
            return "GPS Not Set"
        }
    }
    
    private func startFlight() {
        Task {
            // Load remote checklist if needed
            await appState.loadRemoteChecklistIfNeeded(aircraftDataService: aircraftDataService)

            // Pass the active flight plan ID to the flight if one is active
            let activeFlightPlanId = flightPlanManager.activeFlightPlan?.id
            appState.startFlight(withAircraft: appState.settings.defaultAirplane, flightPlanId: activeFlightPlanId, circuitMode: false)
            locationManager.startTracking(
                appState: appState,
                interval: appState.settings.gpsRecordingInterval
            )
        }
    }

    private func startCircuits() {
        Task {
            // Load remote checklist if needed
            await appState.loadRemoteChecklistIfNeeded(aircraftDataService: aircraftDataService)

            // Start flight in circuit mode (no flight plan, skips CRUISE and DESCENT)
            appState.startFlight(withAircraft: appState.settings.defaultAirplane, flightPlanId: nil, circuitMode: true)
            locationManager.startTracking(
                appState: appState,
                interval: appState.settings.gpsRecordingInterval
            )
        }
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
            
            Text(value)
                .font(.system(size: isCompact ? 18 : 24, weight: .bold, design: .monospaced))
                .foregroundColor(.primaryText)
            
            Text(label)
                .font(.system(size: isCompact ? 11 : 13))
                .foregroundColor(.secondaryText)
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
}

