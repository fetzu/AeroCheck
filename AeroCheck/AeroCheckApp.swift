import SwiftUI
import UIKit

/// Main application entry point
@main
struct AeroCheckApp: App {
    @State private var appState = AppState()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var offlineMapManager: OfflineMapManager
    @StateObject private var windDataService = WindDataService()
    @StateObject private var aviationWeatherService = AviationWeatherService()
    @StateObject private var windsAloftService: WindsAloftService
    @StateObject private var flightPlanManager = FlightPlanManager()
    /// The admin bracket around a flight — planning, preparation and close-out. (v5.0.0)
    @StateObject private var flightThreadManager = FlightThreadManager()
    @StateObject private var watchConnectivityManager = WatchConnectivityManager.shared
    @StateObject private var companionConnectivityManager = CompanionConnectivityManager.shared
    @StateObject private var subscriptionManager: SubscriptionManager
    @StateObject private var aircraftDataService: AircraftDataService
    @StateObject private var airportDataService: AirportDataService
    @StateObject private var openAIPCacheManager: OpenAIPCacheManager
    @StateObject private var openAIPNavaidDataService: OpenAIPNavaidDataService
    @StateObject private var openAIPDataService: OpenAIPDataService
    @StateObject private var flightEventDetector = FlightEventDetector()
    /// Network reachability (Wi-Fi vs cellular, Low Data Mode) for data-refresh decisions. (v4.1.0 Data Freshness)
    @StateObject private var networkMonitor: NetworkMonitor
    /// The single data-freshness "brain": aggregates per-source DataSets → ambient Home-dot health. (v4.1.0 Data Freshness)
    @StateObject private var dataStatusManager: DataStatusManager
    @State private var showUpdateReminder = false
    @State private var isInitialized = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Initialize subscription manager first, then aircraft data service
        // Use deferLoadProducts to speed up initial launch - products will be loaded after view appears
        let subManager = SubscriptionManager(deferLoadProducts: true)
        _subscriptionManager = StateObject(wrappedValue: subManager)
        _aircraftDataService = StateObject(wrappedValue: AircraftDataService(subscriptionManager: subManager))

        // Data-freshness backbone (v4.1.0): construct the external-data services here so the freshness
        // brain can hold references to the same instances. Each service loads its on-disk metadata
        // (last-updated dates) in its own init, so the brain's first reduction is already accurate.
        let offline = OfflineMapManager()
        _offlineMapManager = StateObject(wrappedValue: offline)
        let airports = AirportDataService()
        _airportDataService = StateObject(wrappedValue: airports)
        let openAIP = OpenAIPDataService()
        _openAIPDataService = StateObject(wrappedValue: openAIP)
        let openAIPCache = OpenAIPCacheManager()
        _openAIPCacheManager = StateObject(wrappedValue: openAIPCache)
        let navaids = OpenAIPNavaidDataService.shared
        _openAIPNavaidDataService = StateObject(wrappedValue: navaids)
        // Per-location magnetic declination for flight-plan course calc, sourced from navaid data
        // (falls back to the Switzerland constant when no navaid is near). (v4.1.0 — declination fix)
        FlightPlan.magneticDeclinationProvider = { [weak navaids] coordinate in
            navaids?.nearestNavaid(to: coordinate, maxDistanceNm: 250)?.magneticDeclination ?? FlightPlan.defaultMagneticDeclination
        }
        // Forecast winds aloft for per-leg ground speed and ETA. Reads cache only — route
        // recalculation runs on every waypoint drag and must not block on the network — so a cold
        // cell returns nil and the leg keeps its zero-wind timing until the forecast lands.
        let windsAloft = WindsAloftService()
        _windsAloftService = StateObject(wrappedValue: windsAloft)
        FlightPlan.windsAloftProvider = { [weak windsAloft] coordinate, altitudeFt in
            windsAloft?.wind(at: coordinate, altitudeFt: altitudeFt)
        }
        let net = NetworkMonitor()
        _networkMonitor = StateObject(wrappedValue: net)
        _dataStatusManager = StateObject(wrappedValue: DataStatusManager(
            providers: [
                OpenAIPAirspaceProvider(service: openAIP),
                OpenAIPNavaidProvider(service: navaids),
                OpenAIPObstacleProvider(service: OpenAIPObstacleDataService.shared),
                OpenAIPReportingPointProvider(service: OpenAIPReportingPointDataService.shared),
                OurAirportsProvider(service: airports),
                SwissChartsProvider(manager: offline),
                OpenAIPTilesProvider(manager: openAIPCache),
            ],
            networkMonitor: net
        ))
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(appState: appState) {
            ContentView()
                .environment(appState)
                .environmentObject(locationManager)
                .environmentObject(offlineMapManager)
                .environmentObject(windDataService)
                .environmentObject(aviationWeatherService)
                .environmentObject(windsAloftService)
                .environmentObject(flightPlanManager)
                .environmentObject(flightThreadManager)
                .environmentObject(watchConnectivityManager)
                .environmentObject(companionConnectivityManager)
                .environmentObject(subscriptionManager)
                .environmentObject(aircraftDataService)
                .environmentObject(airportDataService)
                .environmentObject(openAIPCacheManager)
                .environmentObject(openAIPNavaidDataService)
                .environmentObject(openAIPDataService)
                .environmentObject(flightEventDetector)
                .environmentObject(networkMonitor)
                .environmentObject(dataStatusManager)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .task {
                    // Perform deferred initialization in background after initial render
                    guard !isInitialized else { return }
                    isInitialized = true

                    // Wire the companion manager's data sources for BOTH roles, so a viewer (iPhone) can
                    // read its own GPS to stream up to a GPS-less master (iPad). (shared-GPS)
                    companionConnectivityManager.configure(
                        appState: appState,
                        locationManager: locationManager,
                        flightPlanManager: flightPlanManager
                    )
                    // The viewer reports its OWN entitlement to the master, which decides how much
                    // premium checklist text it may stream back. (SA-26)
                    companionConnectivityManager.viewerEntitlementProvider = { [weak subscriptionManager] in
                        subscriptionManager?.subscriptionStatus.isSubscribed ?? false
                    }

                    // Live Activity next-waypoint feed (UX-25): AppState has no FlightPlanManager
                    // reference, so the controller pulls the name through this closure at sync time.
                    FlightActivityController.shared.nextWaypointProvider = {
                        flightPlanManager.activeNextWaypointName
                    }

                    // v5.0.0: register the notification delegate + the actionable close-flight-plan
                    // category. No permission is requested here — that happens when the pilot first
                    // follows a flight, so the prompt arrives with context instead of at cold launch.
                    NotificationService.shared.configure()
                    NotificationService.shared.markFlightPlanClosedHandler = { threadId in
                        flightThreadManager.markFlightPlanClosed(threadId: threadId)
                    }
                    NotificationService.shared.openThreadHandler = { threadId in
                        flightThreadManager.setCurrentThread(threadId)
                        appState.pendingThreadToOpen = threadId
                    }
                    // Auto-connect if companion mode is on and a device is paired — the user shouldn't
                    // have to start it on both devices. (v4.1 companion UX)
                    companionConnectivityManager.autoConnectIfReady()

                    // v4.1.0: OpenAIP is the primary airport source. Re-apply the merge here in case an
                    // early ensureLoaded (widget/deep-link cold start via FlightLauncher) loaded airports
                    // before OpenAIP airport data was ready; idempotent + a no-op without OpenAIP data.
                    await airportDataService.applyOpenAIPMergeIfAvailable()

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

                    // If a flight was restored from a crash-recovery checkpoint, re-resolve its
                    // checklist now that aircraft data is loaded — a restored premium flight
                    // reloads its own checklist instead of showing unresolved content. (ARCH-08)
                    if appState.isFlightActive && appState.resolvedRemoteChecklist == nil {
                        await appState.loadRemoteChecklistIfNeeded(aircraftDataService: aircraftDataService)
                    }

                    // PR-01: a flight restored from the crash-recovery checkpoint comes back "live"
                    // (running clock, restored checklist/track) but with GPS tracking OFF —
                    // restoreActiveFlightState() sets isFlightActive = true without going through
                    // FlightLauncher, the only place startTracking is ever called. Left alone, an
                    // OOM/watchdog kill (or the relaunch iOS forces after a mid-flight location-
                    // permission change) would record no GPS points and run no event detection for
                    // the rest of the flight. Resume tracking here, where every service exists.
                    if appState.isFlightActive && !locationManager.isTracking {
                        let authorization = locationManager.authorizationStatus
                        if authorization != .denied && authorization != .restricted {
                            await airportDataService.ensureLoaded()
                            flightEventDetector.configure(
                                speeds: appState.activeChecklist.speeds,
                                stallSpeed: appState.activeChecklist.stallSpeed
                            )
                            locationManager.startTracking(
                                appState: appState,
                                interval: appState.settings.gpsRecordingInterval,
                                airportDataService: airportDataService,
                                flightEventDetector: flightEventDetector,
                                activeChecklist: appState.activeChecklist
                            )
                            appState.flightRestoredNotice = L10n.Alert.flightRestored
                        }
                    }

                    // After aircraft list is loaded, check for checklist updates in background
                    // This ensures bundled and cached checklists stay up to date automatically
                    Task.detached(priority: .utility) {
                        await aircraftDataService.syncBundledAircraft()
                    }

                    // v4.1.0: preload navaids so the flight-plan declination lookup has data in memory.
                    await openAIPNavaidDataService.ensureLoaded()
                    // v4.1.0: preload obstacles so the nav-map markers have data in memory.
                    await OpenAIPObstacleDataService.shared.ensureLoaded()
                    // v4.1.0: preload reporting points so the nav-map markers have data in memory.
                    await OpenAIPReportingPointDataService.shared.ensureLoaded()

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
                // v4.1.0 Data Freshness: foreground-only refresh — recompute the status and silently
                // refresh any STALE small data the network gate permits. No background tasks.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    dataStatusManager.recompute()
                    Task { await dataStatusManager.autoRefreshIfNeeded(cellularUpdatesEnabled: true) }
                    // Re-establish the companion link on foreground (e.g. after the peer relaunched). (v4.1)
                    companionConnectivityManager.autoConnectIfReady()
                }
            }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(appState)
                .environmentObject(locationManager)
                .environmentObject(offlineMapManager)
                .environmentObject(windDataService)
                .environmentObject(aviationWeatherService)
                .environmentObject(windsAloftService)
                .environmentObject(flightPlanManager)
                .environmentObject(flightThreadManager)
                .environmentObject(subscriptionManager)
                .environmentObject(aircraftDataService)
                .environmentObject(airportDataService)
                .environmentObject(openAIPCacheManager)
                .environmentObject(openAIPNavaidDataService)
                .environmentObject(openAIPDataService)
                .environmentObject(flightEventDetector)
                .environmentObject(networkMonitor)
                .environmentObject(dataStatusManager)
                .preferredColorScheme(.dark)
        }
        #endif
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "aerocheck" else { return }

        switch url.host {
        case "start-flight":
            // Parse aircraft from query parameters
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let aircraft = components.queryItems?.first(where: { $0.name == "aircraft" })?.value else {
                return
            }
            // UX-06: never overwrite a running flight from a widget tap / deep link.
            guard !appState.isFlightActive else { return }
            // UX-11: resolve and select the requested aircraft (by id or registration); refuse an
            // unknown token rather than launching the wrong or an empty aircraft.
            guard appState.selectAircraft(id: aircraft, available: aircraftDataService.availableAircraft) else {
                AppLog.general.debugLine("Deep link requested unknown aircraft: \(aircraft)")
                return
            }

            // SA-25: only the app's OWN widget may start a flight unattended. The scheme is
            // registered with no universal-link restriction, so without this any web page,
            // iMessage, QR code or third-party app could start a flight — and with it continuous
            // background GPS recording that persists after the user switches away — from one tap.
            // An untrusted link is treated as a REQUEST: the aircraft is now selected, and the
            // user's START tap on Home is the confirmation.
            let token = components.queryItems?.first(where: { $0.name == "token" })?.value
            guard WidgetBridge.isTrustedLaunch(token: token) else {
                AppLog.general.debugLine("Deep link start-flight without a widget token — pre-selecting only")
                appState.showFlightLog = false
                return
            }

            // Route through the same launcher as the home screen so the checklist is loaded, the
            // ARCH-01 / entitlement / permission guards run, and GPS tracking actually starts.
            // (Fixes UX-08/13: widget/deep-link flights previously recorded no GPS.)
            let launcher = FlightLauncher(
                appState: appState,
                locationManager: locationManager,
                aircraftDataService: aircraftDataService,
                airportDataService: airportDataService,
                flightEventDetector: flightEventDetector,
                flightPlanManager: flightPlanManager
            )
            Task { await launcher.begin(circuitMode: false) }
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

            // Ensure the companion link is up (no-op if already connected). The connection is now tied to
            // companion-mode-enabled + paired, NOT to the flight — it's a persistent second screen that
            // shows the flight when one is running and an idle state otherwise. The master streams on
            // connect, so starting a flight just changes WHAT is streamed. force:true re-arms it even if
            // an idle auto-disconnect had dropped the link for battery. (v4.1 companion)
            companionConnectivityManager.autoConnectIfReady(force: true)
        } else {
            // Notify Watch that flight has ended
            watchConnectivityManager.notifyFlightEnded()

            // Companion mode deliberately STAYS connected across flights (persistent second screen). It is
            // torn down only by disabling companion mode, tapping Disconnect, or quitting — not here.
        }
    }
}

// MARK: - Map Update Reminder Sheet

struct MapUpdateReminderSheet: View {
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @Environment(\.dismiss) var dismiss
    @State private var isUpdating = false

    var body: some View {
        NavigationStack {
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

// MARK: - App appearance

/// Forces the app's SwiftUI UI to dark with `.environment(\.colorScheme, .dark)` — a SUBTREE-local
/// override that does NOT touch the window/presentation — so this wrapper, which sits ABOVE that
/// override, can still read the DEVICE's real light/dark via `@Environment(\.colorScheme)` to drive the
/// `.system` night-mode preference.
///
/// Why not `.preferredColorScheme(.dark)`: per Apple, that sets the presentation/window level and
/// propagates UP the hierarchy, so once applied the system scheme can no longer be read — it masked
/// every probe (window/scene/screen), which is why the earlier four attempts all failed.
/// `.environment(\.colorScheme, _)` is local-only, leaving the device setting readable. (round 6)
struct AppRootView<Content: View>: View {
    // AppState is @Observable (PERF-30): a plain stored reference is tracked automatically.
    var appState: AppState
    @ObservedObject private var ambient = AmbientController.shared
    @Environment(\.colorScheme) private var systemColorScheme
    private let content: Content
    /// Live screen brightness, for the sunlight boost. iOS exposes no ambient-light reading, so this
    /// is the proxy — see `AppSettings.sunlightBoost`. (v5.x)
    @State private var screenBrightness: Double = 0

    init(appState: AppState, @ViewBuilder content: () -> Content) {
        self.appState = appState
        self.content = content()
    }

    var body: some View {
        let systemIsDark = systemColorScheme == .dark
        content
            // Screen brightness drives the optional sunlight boost. Observed rather than polled: the
            // notification fires on every change, including the ones auto-brightness makes when the
            // aircraft turns into the sun. (v5.x)
            .onReceive(NotificationCenter.default.publisher(
                for: UIScreen.brightnessDidChangeNotification)) { _ in
                screenBrightness = Double(UIScreen.main.brightness)
            }
            .onAppear { screenBrightness = Double(UIScreen.main.brightness) }
            // A fresh identity when the runtime accent revision changes forces the view tree to
            // re-read the (computed) design tokens so an installed override takes effect everywhere.
            .id(ambient.revision)
            // Night mode: dims the flight instruments to the red/amber palette; `.system` follows the
            // device scheme read above (UX-09 / v4 UI/UX Revamp).
            .environment(\.isNightMode, appState.settings.effectiveNightMode(systemIsDark: systemIsDark))
            // Cockpit theme: app-wide semantic palette the revamped screens read (v4 UI/UX Revamp).
            // An installed runtime accent takes precedence over the user's resolved mode.
            .environment(\.cockpitTheme, CockpitTheme.ambientOverride ?? CockpitTheme.resolve(appState.settings.cockpitThemeMode(systemIsDark: systemIsDark, screenBrightness: screenBrightness)))
            // Force the app's appearance dark WITHOUT a window override, so the read above stays valid.
            // The runtime light treatment flips this to `.light` so system controls (toggles, pickers),
            // materials and any default/semantic text render correctly on the light surfaces.
            .environment(\.colorScheme, AmbientPalette.isActive ? .light : .dark)
            .ambientCelebrationOverlay()
            // Publish the DEVICE's real appearance so the companion master streams the same theme the
            // iPad actually displays (not the force-dark window trait). (companion v2 — theme default fix)
            .onAppear { appState.deviceIsDark = systemIsDark }
            .onChange(of: systemColorScheme) { _, scheme in appState.deviceIsDark = (scheme == .dark) }
    }
}
