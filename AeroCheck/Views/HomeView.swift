import SwiftUI

/// Home view - main screen when no flight is active
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @State private var showSettings = false
    @State private var showFlightLog = false
    @State private var showSpeedReference = false
    
    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            
            ZStack {
                // Background
                Color.cockpitBackground
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Header
                    header(isLandscape: isLandscape)
                        .padding(.horizontal, 24)
                        .padding(.top, isLandscape ? 8 : 20)
                    
                    Spacer(minLength: isLandscape ? 8 : 24)
                    
                    // Main content
                    mainContent(isLandscape: isLandscape)
                        .frame(maxWidth: 700)
                    
                    Spacer(minLength: isLandscape ? 8 : 24)
                    
                    // Quick access buttons
                    bottomBar(isLandscape: isLandscape)
                        .padding(.horizontal, 24)
                        .padding(.bottom, isLandscape ? 12 : 32)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showFlightLog) {
            FlightLogView()
        }
        .sheet(isPresented: $showSpeedReference) {
            SpeedReferenceSheet()
        }
    }
    
    // MARK: - Header
    
    private func header(isLandscape: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Image(systemName: "airplane")
                        .font(.system(size: isLandscape ? 26 : 32))
                        .foregroundColor(.aviationGold)
                    
                    Text("PILOT CHECKLIST")
                        .font(.system(size: isLandscape ? 24 : 28, weight: .bold, design: .default))
                        .foregroundColor(.primaryText)
                        .tracking(2)
                }
                
                Text("WT9 Dynamic • Aéroclub du Jura • GVMP")
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)
            }
            
            Spacer()
            
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.secondaryText)
            }
        }
    }
    
    // MARK: - Main Content
    
    private func mainContent(isLandscape: Bool) -> some View {
        VStack(spacing: isLandscape ? 12 : 40) {
            // Aircraft card
            aircraftCard(isLandscape: isLandscape)
            
            // Start flight button - keep consistent size
            Button(action: startFlight) {
                HStack(spacing: 14) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22))
                    Text("START FLIGHT")
                        .font(.system(size: 22, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, isLandscape ? 14 : 22)
            }
            .buttonStyle(PrimaryButtonStyle(color: .aviationGreen))
            .padding(.horizontal, 40)
            
            // Info text - hide in landscape to save space
            if !isLandscape {
                Text("Starting a flight will begin GPS tracking and guide you through all checklists.")
                    .font(.system(size: 15))
                    .foregroundColor(.dimText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .padding(isLandscape ? 12 : 32)
    }
    
    // MARK: - Aircraft Card
    
    private func aircraftCard(isLandscape: Bool) -> some View {
        VStack(spacing: isLandscape ? 8 : 20) {
            // Aircraft silhouette
            Image(systemName: "airplane")
                .font(.system(size: isLandscape ? 44 : 80))
                .foregroundColor(.aviationGold.opacity(0.3))
            
            // Aircraft info
            VStack(spacing: isLandscape ? 2 : 8) {
                Text(appState.settings.defaultAirplane)
                    .font(.system(size: isLandscape ? 28 : 36, weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationGold)
                
                Text("WT9 Dynamic")
                    .font(.system(size: isLandscape ? 15 : 18, weight: .semibold))
                    .foregroundColor(.primaryText)
                
                if !isLandscape {
                    Text("Version 2.1e • March 2025")
                        .font(.system(size: 13))
                        .foregroundColor(.dimText)
                }
            }
            
            AviationDivider()
                .padding(.horizontal, isLandscape ? 20 : 40)
            
            // Quick stats
            HStack(spacing: isLandscape ? 24 : 40) {
                QuickStatView(
                    icon: "book.closed.fill",
                    value: "\(ChecklistPhase.allCases.count)",
                    label: "Checklists",
                    isCompact: isLandscape
                )
                
                QuickStatView(
                    icon: "list.bullet",
                    value: "\(totalChecklistItems)",
                    label: "Items",
                    isCompact: isLandscape
                )
                
                QuickStatView(
                    icon: "doc.text.fill",
                    value: "4",
                    label: "Pages",
                    isCompact: isLandscape
                )
            }
        }
        .padding(isLandscape ? 14 : 32)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.cardBackground)
                .shadow(color: .black.opacity(0.4), radius: isLandscape ? 12 : 20, x: 0, y: isLandscape ? 6 : 10)
        )
    }
    
    // MARK: - Bottom Bar
    
    private func bottomBar(isLandscape: Bool) -> some View {
        HStack(spacing: 16) {
            // Flight log button - consistent size
            Button(action: { showFlightLog = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 18))
                    Text("FLIGHT LOG")
                        .font(.system(size: 14, weight: .semibold))
                    if !appState.flights.isEmpty {
                        Text("(\(appState.flights.count))")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.aviationGold)
                    }
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            
            Spacer()
            
            // Location status
            HStack(spacing: 6) {
                Image(systemName: locationStatusIcon)
                    .font(.system(size: 13))
                    .foregroundColor(locationStatusColor)
                Text(locationStatusText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)
            }
            
            Spacer()
            
            // Speed reference button - consistent size
            Button(action: { showSpeedReference = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 18))
                    Text("SPEEDS")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }
    
    // MARK: - Helpers
    
    private var totalChecklistItems: Int {
        ChecklistPhase.allCases.reduce(0) { count, phase in
            count + ChecklistData.items(for: phase).count
        }
    }
    
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
