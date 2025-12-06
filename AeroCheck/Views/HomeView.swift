import SwiftUI

/// Home view - main screen when no flight is active
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @State private var showSettings = false
    @State private var showFlightLog = false
    @State private var showSpeedReference = false
    
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

                Text("Aéroclub du Jura • GVMP")
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

            // Start flight button - keep consistent size
            Button(action: startFlight) {
                HStack(spacing: isCompact ? 10 : 14) {
                    Image(systemName: "play.fill")
                        .font(.system(size: isCompact ? 18 : 22))
                    Text("START FLIGHT")
                        .font(.system(size: isCompact ? 18 : 22, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, isLandscape ? 14 : (isCompact ? 14 : 22))
            }
            .buttonStyle(PrimaryButtonStyle(color: .aviationGreen))
            .padding(.horizontal, isCompact ? 20 : 40)

            // Info text - hide in landscape and compact to save space
            if !isLandscape && !isCompact {
                Text("Starting a flight will begin GPS tracking and guide you through all checklists.")
                    .font(.system(size: 15))
                    .foregroundColor(.dimText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
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

            // Aircraft info
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
                    value: "\(currentAircraft.totalChecklistItems)",
                    label: "Items",
                    isCompact: isLandscape || isCompact
                )

                QuickStatView(
                    icon: "doc.text.fill",
                    value: "\(currentAircraft.pageCount)",
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
    }
    
    // MARK: - Bottom Bar

    private func bottomBar(isLandscape: Bool, isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 8 : 16) {
            // Flight log button - consistent size
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

            // Location status
            HStack(spacing: isCompact ? 4 : 6) {
                Image(systemName: locationStatusIcon)
                    .font(.system(size: isCompact ? 11 : 13))
                    .foregroundColor(locationStatusColor)
                Text(isCompact ? "" : locationStatusText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)
            }

            Spacer()

            // Speed reference button - consistent size
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
        appState.startFlight()
        locationManager.startTracking(
            appState: appState,
            interval: appState.settings.gpsRecordingInterval
        )
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
    HomeView()
        .environmentObject(AppState())
        .environmentObject(LocationManager())
}

