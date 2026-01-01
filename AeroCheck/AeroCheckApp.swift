import SwiftUI

/// Main application entry point
@main
struct AeroCheckApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var offlineMapManager = OfflineMapManager()
    @StateObject private var windDataService = WindDataService()
    @StateObject private var flightPlanManager = FlightPlanManager()
    @StateObject private var subscriptionManager = SubscriptionManager()
    @StateObject private var aircraftDataService: AircraftDataService
    @State private var showUpdateReminder = false

    init() {
        // Initialize subscription manager first, then aircraft data service
        let subManager = SubscriptionManager()
        _subscriptionManager = StateObject(wrappedValue: subManager)
        _aircraftDataService = StateObject(wrappedValue: AircraftDataService(subscriptionManager: subManager))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(locationManager)
                .environmentObject(offlineMapManager)
                .environmentObject(windDataService)
                .environmentObject(flightPlanManager)
                .environmentObject(subscriptionManager)
                .environmentObject(aircraftDataService)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .onAppear {
                    // Check for yearly map update reminder
                    if offlineMapManager.shouldShowUpdateReminder {
                        showUpdateReminder = true
                    }
                }
                .sheet(isPresented: $showUpdateReminder) {
                    MapUpdateReminderSheet()
                        .environmentObject(offlineMapManager)
                }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(locationManager)
                .environmentObject(offlineMapManager)
                .environmentObject(windDataService)
                .environmentObject(flightPlanManager)
                .environmentObject(subscriptionManager)
                .environmentObject(aircraftDataService)
                .preferredColorScheme(.dark)
        }
        #endif
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "aerocheck" else { return }

        switch url.host {
        case "start-flight":
            // Parse aircraft from query parameters
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let aircraft = components.queryItems?.first(where: { $0.name == "aircraft" })?.value {
                // Pass active flight plan ID if one exists
                let activeFlightPlanId = flightPlanManager.activeFlightPlan?.id
                appState.startFlight(withAircraft: aircraft, flightPlanId: activeFlightPlanId)
            }
        case "flight-log":
            appState.showFlightLog = true
        default:
            break
        }
    }
}

// MARK: - Map Update Reminder Sheet

struct MapUpdateReminderSheet: View {
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @Environment(\.dismiss) var dismiss
    @State private var isUpdating = false

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Header icon
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 60))
                    .foregroundColor(.aviationGold)
                    .padding(.top, 40)

                // Title
                Text("ICAO Chart Update Available")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primaryText)

                // Description
                Text("SwissTopo has released a new version of the ICAO Aeronautical Chart. The chart is updated yearly in April. Update your cached chart to ensure accurate navigation data.")
                    .font(.system(size: 16))
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Current cache info
                VStack(spacing: 8) {
                    Text("Current cache: \(offlineMapManager.cacheVersion)")
                        .font(.system(size: 14))
                        .foregroundColor(.secondaryText)

                    Text("Downloaded: \(offlineMapManager.formattedCacheDate)")
                        .font(.system(size: 14))
                        .foregroundColor(.secondaryText)
                }
                .padding(.top, 8)

                Spacer()

                // Download progress
                if offlineMapManager.isDownloading {
                    VStack(spacing: 16) {
                        ProgressView(value: offlineMapManager.downloadProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .aviationGold))
                            .padding(.horizontal, 40)

                        Text("Updating tiles...")
                            .font(.system(size: 14))
                            .foregroundColor(.secondaryText)

                        Text("\(offlineMapManager.downloadedTileCount) / \(offlineMapManager.totalTileCount)")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.secondaryText)
                    }
                }

                Spacer()

                // Action buttons
                if !offlineMapManager.isDownloading {
                    VStack(spacing: 12) {
                        Button(action: updateNow) {
                            Text("Update Now")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.aviationGold)
                                )
                        }
                        .padding(.horizontal, 24)

                        Button(action: remindLater) {
                            Text("Remind Me Next Time")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(.aviationGold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                        .padding(.horizontal, 24)

                        Button(action: ignore) {
                            Text("Ignore")
                                .font(.system(size: 15))
                                .foregroundColor(.secondaryText)
                        }
                        .padding(.top, 8)
                    }
                    .padding(.bottom, 40)
                } else {
                    Spacer()
                        .frame(height: 150)
                }
            }
            .background(Color.cockpitBackground)
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(offlineMapManager.isDownloading)
        .onChange(of: offlineMapManager.isDownloading) { _, isDownloading in
            // Auto-dismiss when download completes
            if !isDownloading && isUpdating && offlineMapManager.isCacheAvailable {
                dismiss()
            }
        }
    }

    private func updateNow() {
        isUpdating = true
        Task {
            await offlineMapManager.downloadICAOChart()
        }
    }

    private func remindLater() {
        offlineMapManager.remindLater()
        dismiss()
    }

    private func ignore() {
        offlineMapManager.ignoreUpdate()
        dismiss()
    }
}
