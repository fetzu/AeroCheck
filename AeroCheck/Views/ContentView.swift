import SwiftUI

/// Root content view that switches between home and flight views
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var windDataService: WindDataService
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @EnvironmentObject var dataStatusManager: DataStatusManager
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.scenePhase) var scenePhase
    @State private var showMarketingControls: Bool = false
    @ObservedObject private var marketingProvider = MarketingLocationProvider.shared

    var body: some View {
        GeometryReader { geometry in
            let isCompactDevice = horizontalSizeClass == .compact
            let isLandscape = geometry.size.width > geometry.size.height

            ZStack {
                if !appState.hasSeenOnboarding {
                    OnboardingView()
                        .transition(.opacity)
                } else if companionConnectivityManager.currentRole == .viewer &&
                          (companionConnectivityManager.connectionState == .connected ||
                           companionConnectivityManager.connectionState == .reconnecting) {
                    // A viewer iPhone mirrors the master iPad's flight and has no local flight of
                    // its own, so this is checked BEFORE `isFlightActive` (always false on the
                    // viewer — previously a connected viewer fell through to HomeView and never
                    // showed the companion screen). Staying through `.reconnecting` avoids a flicker
                    // back to Home on a transient drop; CompanionFlightView shows its own banner. (PR-16)
                    CompanionFlightView()
                        .transition(.opacity)
                } else if appState.isFlightActive {
                    FlightView()
                        .transition(.opacity)
                } else {
                    HomeView()
                        .transition(.opacity)
                }

                // Show rotation prompt on iPhone in landscape
                if isCompactDevice && isLandscape {
                    RotateToPortraitView()
                        .transition(.opacity)
                }

                // Marketing controls overlay (shown when shaking with marketing mode enabled).
                // SEC-C37: compiled out of Release along with the toggle that reveals it.
                #if DEBUG
                if showMarketingControls && appState.settings.marketingMode {
                    VStack {
                        HStack {
                            Spacer()
                            MarketingControlsView()
                                .padding(.top, 50)
                                .padding(.trailing, 16)
                        }
                        Spacer()
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                #endif

                // PR-41: non-blocking banner when the checklist was served in a fallback language.
                if let notice = appState.languageFallbackNotice {
                    VStack {
                        LanguageFallbackBanner(message: notice) {
                            appState.languageFallbackNotice = nil
                        }
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // v4.1.0 Data Freshness: snoozable nudge when a dataset is stale (Home only, not in flight).
                if dataStatusManager.showStaleNudge && !appState.isFlightActive && appState.settings.hasCompletedOnboarding {
                    VStack {
                        DataFreshnessNudgeBanner(message: L10n.DataStorage.nudgeMessage) {
                            dataStatusManager.snoozeNudge()
                        }
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: appState.settings.hasCompletedOnboarding)
            .animation(.easeInOut(duration: 0.3), value: appState.isFlightActive)
            .animation(.easeInOut(duration: 0.3), value: companionConnectivityManager.connectionState)
            .animation(.easeInOut(duration: 0.3), value: companionConnectivityManager.currentRole)
            .animation(.easeInOut(duration: 0.2), value: isLandscape)
            .animation(.easeInOut(duration: 0.3), value: showMarketingControls)
            .animation(.easeInOut(duration: 0.3), value: appState.languageFallbackNotice)
            .animation(.easeInOut(duration: 0.3), value: dataStatusManager.showStaleNudge)
        }
        .onAppear {
            // Only ask for location at launch for users who've already been through onboarding — a fresh
            // install requests it during the onboarding "Location" step instead. A skipped or revoked
            // permission is still caught at flight start (FlightLauncher UX-13). (onboarding revamp)
            if appState.hasSeenOnboarding {
                locationManager.requestAuthorization()
            }

            // Apply screen setting
            UIApplication.shared.isIdleTimerDisabled = appState.settings.keepScreenOn
        }
        #if DEBUG
        .task {
            // DEV-ONLY: auto-inject a marketing scene at launch for deterministic screenshot capture,
            // e.g. `SIMCTL_CHILD_AEROCHECK_SCENE=cruiseHUD xcrun simctl launch <dev> com.fetzu.aerocheck`.
            // Compiled out of release builds entirely (this whole block is #if DEBUG).
            guard let key = ProcessInfo.processInfo.environment["AEROCHECK_SCENE"]?.lowercased() else { return }
            let scene: MarketingScene?
            switch key {
            case "home", "home2aircraft":       scene = .home2Aircraft
            case "cruise", "cruisehud":         scene = .cruiseHUD
            case "nav", "navplanactive":        scene = .navPlanActive
            case "conflicts", "planconflicts":  scene = .planConflicts
            case "plan", "planbuilder":         scene = .planBuilder
            case "flightlog", "flightlogdetail": scene = .flightLogDetail
            default:                            scene = nil
            }
            guard let scene else { return }
            appState.settings.marketingMode = true
            // Let services initialize (airport data lazy-loads; the aircraft list fetch may be in flight).
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            MarketingSceneInjector.inject(
                scene,
                appState: appState,
                locationManager: locationManager,
                subscriptionManager: subscriptionManager,
                aircraftDataService: aircraftDataService,
                flightPlanManager: flightPlanManager,
                airportDataService: airportDataService
            )
        }
        #endif
        .onShake {
            // SEC-C37: the shake trigger is Debug-only too. A shake is a plausible ACCIDENT in a
            // cockpit (turbulence), and it was the entry point to a control panel that could
            // discard an active flight.
            #if DEBUG
            if appState.settings.marketingMode {
                showMarketingControls.toggle()
            }
            #endif
        }
        .onChange(of: marketingProvider.currentLocation) { _, newLocation in
            // Inject marketing location into LocationManager when active. Use injectMarketingStaticFix
            // so the smoothed speed / cached heading are primed too — otherwise only ALT lights up
            // (SPD/HDG read the smoothed caches, which didUpdateLocations skips in marketing mode).
            if appState.settings.marketingMode && marketingProvider.isActive {
                if let location = newLocation {
                    locationManager.injectMarketingStaticFix(location)
                }
            }
        }
        .onChange(of: marketingProvider.isActive) { _, isActive in
            // When marketing mode stops, clear the GPS status override
            if !isActive {
                locationManager.clearGPSStatusOverride()
            }
        }
        .fullScreenCover(isPresented: Bindable(appState).showFlightLog) {
            FlightLogView()
                .environment(appState)
                .environmentObject(flightPlanManager)
                .environmentObject(airportDataService)
                .environmentObject(openAIPDataService)
        }
        // SEC-C40 follow-up: a paired peer asking to drive checklist/waypoint state must be
        // authorised by whoever holds the master. That prompt was mounted ONLY on the Companion
        // settings page, which is reachable only from HomeView — and HomeView is not in the
        // hierarchy while a flight is active. So during flight, exactly when a viewer is most
        // likely to reach for a control, the request had nowhere to present and was silently
        // swallowed. Mounting it here covers Home, FlightView and CompanionFlightView.
        //
        // It stays mounted on the settings page as well: Settings is presented as a
        // `fullScreenCover` over HomeView, and this root alert cannot present above that cover.
        // The two are mutually exclusive in practice — whichever host is actually on screen owns
        // the prompt — and they share one binding, so answering either clears both.
        .modifier(CompanionCommandAuthorizationAlert(manager: companionConnectivityManager))
        // PR-01: a crash-recovered flight resumed GPS recording automatically — tell the pilot so
        // they know tracking is live again (presented over FlightView, which a restored flight shows).
        .alert(L10n.Alert.flightRestoredTitle, isPresented: Binding(
            get: { appState.flightRestoredNotice != nil },
            set: { if !$0 { appState.flightRestoredNotice = nil } }
        )) {
            Button(L10n.Button.close, role: .cancel) { appState.flightRestoredNotice = nil }
        } message: {
            Text(appState.flightRestoredNotice ?? "")
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background, .inactive:
                // Save flight state when app goes to background or becomes inactive
                if appState.isFlightActive {
                    appState.saveActiveFlightState()
                }
                // Stop wind data fetching in background to save battery
                windDataService.stopFetching()
            case .active:
                // On app start, deactivate flight plan if no flight is in progress
                // This is handled after flight state restoration, so if a flight was
                // restored, isFlightActive will be true and we keep the flight plan
                if !appState.isFlightActive {
                    flightPlanManager.deactivateFlightPlan()
                }
                // Resume wind fetching for the briefings if a flight is active.
                if appState.isFlightActive {
                    windDataService.startFetching(locationManager: locationManager)
                }
                // Re-check entitlement on foreground and enforce offline/grace expiry by
                // clearing premium caches when access is no longer allowed. Defense-in-depth;
                // the server remains the authoritative gate. (SEC-05)
                Task {
                    // Result intentionally unused here — the foreground re-check runs for its side
                    // effects (refresh + grace/offline enforcement); the cache validation below acts on it.
                    _ = await subscriptionManager.performPeriodicCheck()
                    _ = aircraftDataService.validatePremiumCaches(subscriptionManager: subscriptionManager)
                }
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Language Fallback Banner

/// A non-blocking top banner shown when a checklist was served in a language other than the one
/// requested. Auto-dismisses after a few seconds and is tappable to dismiss early. (PR-41 / UX-08)
struct LanguageFallbackBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(.cockpitBackground)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.aviationAmber, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(L10n.Button.close))
        .task {
            try? await Task.sleep(for: .seconds(6))
            onDismiss()
        }
    }
}

/// Snoozable "your data is out of date" nudge (v4.1.0 Data Freshness). Mirrors LanguageFallbackBanner
/// but persists until tapped — currency is a deliberate action, so there's no auto-dismiss.
struct DataFreshnessNudgeBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(.cockpitBackground)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.aviationAmber, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(message)
        .accessibilityHint(Text(L10n.Button.close))
    }
}

// MARK: - Shake Gesture Detection

/// Notification name for shake gesture
extension NSNotification.Name {
    static let deviceDidShake = NSNotification.Name("deviceDidShake")
}

/// UIWindow extension to detect shake gestures
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
    }
}

/// View modifier to handle shake gestures
struct ShakeGestureModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                action()
            }
    }
}

extension View {
    /// Adds an action to perform when the device is shaken
    func onShake(perform action: @escaping () -> Void) -> some View {
        modifier(ShakeGestureModifier(action: action))
    }
}

// MARK: - Rotate to Portrait View

/// Overlay shown on iPhone when in landscape mode
struct RotateToPortraitView: View {
    var body: some View {
        ZStack {
            // Solid background to hide content underneath
            Color.cockpitBackground
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // Rotation icon
                Image(systemName: "rectangle.portrait.rotate")
                    .font(.system(size: 64))
                    .foregroundColor(.aviationGold)

                VStack(spacing: 8) {
                    Text(L10n.ContentViewStrings.rotateDevice)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.primaryText)

                    Text(L10n.ContentViewStrings.portraitMode)
                        .font(.system(size: 16))
                        .foregroundColor(.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                // Visual hint with phone icon
                HStack(spacing: 20) {
                    // Current orientation (crossed out)
                    ZStack {
                        Image(systemName: "iphone.landscape")
                            .font(.system(size: 32))
                            .foregroundColor(.dimText)
                        Image(systemName: "xmark")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.aviationRed)
                    }

                    Image(systemName: "arrow.right")
                        .font(.system(size: 20))
                        .foregroundColor(.dimText)

                    // Desired orientation
                    Image(systemName: "iphone")
                        .font(.system(size: 32))
                        .foregroundColor(.aviationGreen)
                }
                .padding(.top, 16)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(AppState())
        .environmentObject(LocationManager())
        .environmentObject(FlightPlanManager())
        .environmentObject(DataStatusManager(providers: [], networkMonitor: NetworkMonitor(stub: .disconnected)))
}
