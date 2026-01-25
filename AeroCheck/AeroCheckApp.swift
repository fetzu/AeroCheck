import SwiftUI
import WatchConnectivity

/// Main application entry point
@main
struct AeroCheckApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var offlineMapManager = OfflineMapManager()
    @StateObject private var windDataService = WindDataService()
    @StateObject private var flightPlanManager = FlightPlanManager()
    @StateObject private var watchConnectivityManager = WatchConnectivityManager.shared
    @StateObject private var subscriptionManager: SubscriptionManager
    @StateObject private var aircraftDataService: AircraftDataService
    @State private var showUpdateReminder = false
    @State private var isInitialized = false

    init() {
        // Initialize subscription manager first, then aircraft data service
        // Use deferLoadProducts to speed up initial launch - products will be loaded after view appears
        let subManager = SubscriptionManager(deferLoadProducts: true)
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
                .environmentObject(watchConnectivityManager)
                .environmentObject(subscriptionManager)
                .environmentObject(aircraftDataService)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .task {
                    // Perform deferred initialization in background after initial render
                    guard !isInitialized else { return }
                    isInitialized = true

                    // Load subscription products and aircraft data in parallel with timeouts
                    // Use TaskGroup to handle errors gracefully and not block startup on network issues
                    await withTaskGroup(of: Void.self) { group in
                        // Load products with timeout - non-critical for initial launch
                        group.addTask {
                            await withTimeout(seconds: 10) {
                                await subscriptionManager.loadProducts()
                            }
                        }

                        // Fetch aircraft data with timeout - falls back to cached data
                        group.addTask {
                            await withTimeout(seconds: 15) {
                                await aircraftDataService.fetchAvailableAircraft()
                            }
                        }

                        // Wait for all tasks (they handle their own errors)
                        await group.waitForAll()
                    }

                    // Check for yearly map update reminder (after main content loads)
                    if offlineMapManager.shouldShowUpdateReminder {
                        showUpdateReminder = true
                    }
                }
                .sheet(isPresented: $showUpdateReminder) {
                    MapUpdateReminderSheet()
                        .environmentObject(offlineMapManager)
                }
                .onChange(of: appState.isFlightActive) { _, isActive in
                    handleFlightStateChange(isActive: isActive)
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

    private func handleFlightStateChange(isActive: Bool) {
        if isActive {
            // Notify Watch that flight has started (triggers Watch app launch)
            watchConnectivityManager.notifyFlightStarted(
                appState: appState,
                locationManager: locationManager,
                flightPlanManager: flightPlanManager
            )
        } else {
            // Notify Watch that flight has ended
            watchConnectivityManager.notifyFlightEnded()
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

// MARK: - Timeout Helper

/// Executes an async operation with a timeout
/// If the timeout is reached, the operation is cancelled and returns gracefully
/// This helps prevent app hangs on poor network connectivity
private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            await operation()
        }

        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }

        // Return the first completed result
        if let result = await group.next() {
            group.cancelAll()
            return result
        }

        return nil
    }
}

/// Executes an async void operation with a timeout
/// If the timeout is reached, the operation is cancelled gracefully
private func withTimeout(seconds: TimeInterval, operation: @escaping () async -> Void) async {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await operation()
            return true
        }

        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return false
        }

        // Wait for first completion
        _ = await group.next()
        group.cancelAll()
    }
}
