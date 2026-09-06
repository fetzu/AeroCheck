import SwiftUI

/// Root content view that switches between home and flight views
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var threadManager: FlightThreadManager
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
                if appState.needsDisclaimerAcceptance {
                    // Ahead of onboarding, not inside it: onboarding's "Skip" jumps straight to
                    // completeOnboarding(), so a disclaimer page in that TabView would be one tap
                    // from being skipped. An acknowledgement that can be skipped is not one.
                    DisclaimerView(mode: .gate) {
                        withAnimation { appState.acceptDisclaimer() }
                    }
                    .transition(.opacity)
                } else if !appState.hasSeenOnboarding {
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

                // Rotation prompt on iPhone in landscape — but NEVER over a flight surface.
                //
                // This is a full-screen OPAQUE cover. Shown during a flight it hides the entire HUD:
                // phase, checklist, instruments, everything. A phone can end up in landscape for
                // reasons that have nothing to do with intent — a kneeboard or vent mount, or simply
                // being knocked — and the app's answer was to blank the flight display until the
                // pilot rotated it back. A cramped landscape HUD is worse than the portrait one; it
                // is enormously better than no HUD.
                //
                // The Companion viewer is a flight surface too, so it is excluded on the same
                // grounds even though the master iPad holds the flight.
                let onFlightSurface = appState.isFlightActive
                    || (companionConnectivityManager.currentRole == .viewer
                        && companionConnectivityManager.connectionState == .connected)
                if isCompactDevice && isLandscape && !onFlightSurface {
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
                if let notice = appState.languageFallbackNotice, !appState.needsDisclaimerAcceptance {
                    VStack {
                        LanguageFallbackBanner(message: notice) {
                            appState.languageFallbackNotice = nil
                        }
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // v4.4.0: an activation retired by age says so, with a one-tap way to put it back.
                // Never during a flight — the expiry cannot fire then, and a banner over the HUD would
                // be exactly the wrong moment.
                if let expired = flightPlanManager.expiredActivation, !appState.isFlightActive,
                   !appState.needsDisclaimerAcceptance {
                    VStack {
                        ActivationExpiredBanner(
                            routeLabel: expired.routeLabel,
                            onRearm: { flightPlanManager.rearmExpiredActivation() },
                            onDismiss: { flightPlanManager.expiredActivation = nil }
                        )
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // v5.0.0: a filed VFR flight plan that is still open after landing. Deliberately the
                // most insistent banner in the app and the only one in red — Zurich RCC is alerted 30
                // minutes after the ETA, so this is the one piece of admin with a search-and-rescue
                // consequence for forgetting it.
                if let notice = threadManager.openFlightPlanNotice, !appState.isFlightActive,
                   !appState.needsDisclaimerAcceptance {
                    VStack {
                        OpenFlightPlanBanner(
                            routeLabel: notice.routeLabel,
                            onMarkClosed: { threadManager.markFlightPlanClosed(threadId: notice.threadId) },
                            onOpen: { appState.pendingThreadToOpen = notice.threadId },
                            onDismiss: { threadManager.openFlightPlanNotice = nil }
                        )
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // v4.1.0 Data Freshness: snoozable nudge when a dataset is stale (Home only, not in flight).
                if dataStatusManager.showStaleNudge && !appState.isFlightActive
                    && appState.settings.hasCompletedOnboarding && !appState.needsDisclaimerAcceptance {
                    VStack {
                        DataFreshnessNudgeBanner(message: L10n.DataStorage.nudgeMessage) {
                            dataStatusManager.snoozeNudge()
                        }
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: appState.acceptedDisclaimerVersion)
            .animation(.easeInOut(duration: 0.3), value: appState.settings.hasCompletedOnboarding)
            .animation(.easeInOut(duration: 0.3), value: appState.isFlightActive)
            .animation(.easeInOut(duration: 0.3), value: companionConnectivityManager.connectionState)
            .animation(.easeInOut(duration: 0.3), value: companionConnectivityManager.currentRole)
            .animation(.easeInOut(duration: 0.2), value: isLandscape)
            .animation(.easeInOut(duration: 0.3), value: showMarketingControls)
            .animation(.easeInOut(duration: 0.3), value: appState.languageFallbackNotice)
            .animation(.easeInOut(duration: 0.3), value: dataStatusManager.showStaleNudge)
            .animation(.easeInOut(duration: 0.3), value: threadManager.openFlightPlanNotice)
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

            // Retire an activation that was never flown. Runs once, at launch, and only when no
            // flight is in progress — a restored flight keeps its plan whatever its age.
            if !appState.isFlightActive {
                flightPlanManager.expireStaleActivation()
            }
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
        // Post-flight reconciliation review (D2): presented over Home right after END
        // FLIGHT when the track re-analysis disagrees with the confirmed events. Swipe
        // dismissal is disabled inside the sheet; both exits are explicit buttons, and
        // "keep as recorded" is the safe default wired to the binding's dismiss path.
        .sheet(isPresented: Binding(
            get: { appState.pendingReconciliation != nil },
            set: { if !$0 { appState.keepRecordedReconciliation() } }
        )) {
            if let result = appState.pendingReconciliation {
                FlightReconciliationView(
                    result: result,
                    onApply: { appState.applyReconciliation($0) },
                    onKeep: { appState.keepRecordedReconciliation() }
                )
                .presentationDetents([.large])
            }
        }
        .fullScreenCover(isPresented: Bindable(appState).showFlightLog) {
            FlightLogView()
                .environment(appState)
                .environmentObject(flightPlanManager)
                .environmentObject(threadManager)
                .environmentObject(airportDataService)
                .environmentObject(openAIPDataService)
        }
        // A thread opened from its notification, or from the open-flight-plan banner. Lives at the
        // root so it works over Home and over the close-out banner alike. (v5.0.0)
        .fullScreenCover(isPresented: Binding(
            get: { appState.pendingThreadToOpen != nil },
            set: { if !$0 { appState.pendingThreadToOpen = nil } }
        )) {
            if let id = appState.pendingThreadToOpen {
                FlightThreadView(threadId: id, onClose: { appState.pendingThreadToOpen = nil })
                    .environmentObject(threadManager)
                    .environmentObject(flightPlanManager)
            }
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
                // An activated flight plan is NOT discarded here.
                //
                // This used to call `deactivateFlightPlan()` whenever no flight was running. The
                // intent was "deactivate on app start", but `scenePhase == .active` fires on every
                // foreground — so activating a plan in the clubhouse and then glancing at any other
                // app silently threw it away, along with the route the nav map was drawing. The
                // condition was wrong too: activating before engine start is the normal order of
                // work, not a stale leftover. Staleness is now a question of AGE, checked once at
                // launch — see `expireStaleActivation` and `FlightPlanManager.activationLifetime`.

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

/// Caps a top banner's width and centres it.
///
/// These banners are full-width overlays, which on a 13" iPad turns a minor notice into a wall.
/// 620 pt is the same measure Home uses for its hero column, so a banner lines up with the content
/// underneath it instead of spanning the whole slab. Below that width nothing changes, so the phone
/// is untouched. (v4.4.0)
private struct AppBannerWidth: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension View {
    func appBannerWidth() -> some View { modifier(AppBannerWidth()) }
}

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
        .appBannerWidth()
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

/// Shown after landing when a filed VFR flight plan has not been closed. (v5.0.0)
///
/// The one banner in the app that is red, and the one with no auto-dismiss: Skyguide's RCC is alerted
/// 30 minutes after the ETA on an open plan, so a notice the pilot might have missed is worth nothing
/// here. Carries the phone number as the primary action because that is how a plan actually gets
/// closed — the app's job is to remember, not to file.
struct OpenFlightPlanBanner: View {
    let routeLabel: String
    let onMarkClosed: () -> Void
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.aviationRed)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Thread.closeFlightPlanTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primaryText)
                Text(L10n.Thread.closeFlightPlanBody(routeLabel))
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        if let url = URL(string: "tel://0800437837") { openURL(url) }
                    } label: {
                        Text(L10n.Thread.callFIC)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.aviationRed)
                            .padding(.horizontal, 12).frame(minHeight: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.aviationRed.opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.aviationRed.opacity(0.5), lineWidth: 1)))
                            .contentShape(Rectangle())
                    }
                    Button(action: onMarkClosed) {
                        Text(L10n.Thread.markFlightPlanClosed)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.aviationGreen)
                            .padding(.horizontal, 12).frame(minHeight: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.aviationGreen.opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.aviationGreen.opacity(0.45), lineWidth: 1)))
                            .contentShape(Rectangle())
                    }
                    Button(action: onDismiss) {
                        Text(L10n.Button.close)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondaryText)
                            .padding(.horizontal, 12).frame(minHeight: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                            .contentShape(Rectangle())
                    }
                }
                .padding(.top, 3)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.aviationRed.opacity(0.6), lineWidth: 1.5))
        )
        .appBannerWidth()
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }
}

/// Shown once when a flight-plan activation is retired by age (`FlightPlanManager.activationLifetime`).
///
/// Carries actions rather than just words: the pilot who left a plan armed on Friday and opens the app
/// on Monday morning almost certainly still wants it, so re-arming is one tap and does not send them
/// back through the plan list. No auto-dismiss — this reports a state change, and a notice you might
/// not have seen is no better than the silence it replaced. (v4.4.0)
struct ActivationExpiredBanner: View {
    let routeLabel: String
    let onRearm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "airplane.arrival")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.aviationAmber)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Nav.activationExpiredTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primaryText)
                Text(L10n.Nav.activationExpiredMessage(routeLabel))
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: onRearm) {
                        Text(L10n.Nav.rearm)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.aviationGreen)
                            .padding(.horizontal, 12).frame(minHeight: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.aviationGreen.opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.aviationGreen.opacity(0.45), lineWidth: 1)))
                            .contentShape(Rectangle())
                    }
                    Button(action: onDismiss) {
                        Text(L10n.Button.close)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondaryText)
                            .padding(.horizontal, 12).frame(minHeight: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                            .contentShape(Rectangle())
                    }
                }
                .padding(.top, 3)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.aviationAmber.opacity(0.45), lineWidth: 1))
        )
        .appBannerWidth()
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
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
        .appBannerWidth()
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
