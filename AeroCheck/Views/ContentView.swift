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
    /// Needed to build a `FlightLauncher`, so a thread opened from its own notification can start
    /// its flight from there. (review F21)
    @EnvironmentObject var flightEventDetector: FlightEventDetector
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.scenePhase) var scenePhase
    /// Guards the one-shot route-date sweep, so a later load cannot run it twice.
    @State private var hasSweptRouteDates = false
    #if DEBUG
    /// The scenes' held GPS fix (`MarketingLocationProvider`), forwarded to the location manager below.
    @ObservedObject private var marketingProvider = MarketingLocationProvider.shared
    #endif
    /// A dry run's Cockpit covers the app while one runs. (6.4.0)
    @ObservedObject private var dryRuns = DryRunCenter.shared

    var body: some View {
        GeometryReader { geometry in
            let isCompactDevice = horizontalSizeClass == .compact
            // Not `width > height`: the keyboard takes its height off this reader. An iPad in portrait
            // read 820 x 811 pt with the keys up, landscape, and an iPhone SE typing is 12 pt away from
            // the rotation prompt covering the field (less with a keyboard toolbar). (6.1.0)
            let isLandscape = KeyboardProofOrientation.isLandscape(size: geometry.size,
                                                                   bottomInset: geometry.safeAreaInsets.bottom)

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
                    // On the ground: Today · Plan · Logbook · Aircraft · Settings. (v6.0 · P1)
                    GroundView()
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
                // most insistent banner in the app and the only one in red — search and rescue is alerted
                // after the ETA (30 minutes in Switzerland), so this is the one piece of admin with a
                // search-and-rescue consequence for forgetting it. Since 6.5.0, by the country landed in.
                if let notice = threadManager.openFlightPlanNotice, !appState.isFlightActive,
                   !appState.needsDisclaimerAcceptance {
                    VStack {
                        OpenFlightPlanBanner(
                            routeLabel: notice.routeLabel,
                            closeOut: threadManager.thread(withId: notice.threadId).map { threadManager.closeOut(for: $0) }
                                ?? CloseOut(),
                            onMarkClosed: { threadManager.markFlightPlanClosed(threadId: notice.threadId) },
                            onOpen: { appState.pendingThreadToOpen = notice.threadId },
                            onDismiss: { threadManager.openFlightPlanNotice = nil }
                        )
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // v5.x: a circuit session that ended with nothing following it. An offer, not a
                // thread created behind the pilot's back — dismissing it is a complete answer.
                if let offer = threadManager.circuitCloseOutOffer, !appState.isFlightActive,
                   !appState.needsDisclaimerAcceptance {
                    VStack {
                        CircuitCloseOutBanner(
                            routeLabel: offer.routeLabel,
                            onAccept: {
                                let thread = threadManager.acceptCircuitCloseOut(offer)
                                appState.pendingThreadToOpen = thread.id
                            },
                            onDismiss: { threadManager.circuitCloseOutOffer = nil }
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
            .animation(.easeInOut(duration: 0.3), value: appState.languageFallbackNotice)
            .animation(.easeInOut(duration: 0.3), value: dataStatusManager.showStaleNudge)
            .animation(.easeInOut(duration: 0.3), value: threadManager.openFlightPlanNotice)
            .animation(.easeInOut(duration: 0.3), value: threadManager.circuitCloseOutOffer)
        }
        .onAppear {
            // Only ask for location at launch for users who've already been through onboarding — a fresh
            // install requests it during the onboarding "Location" step instead. A skipped or revoked
            // permission is still caught at flight start (FlightLauncher UX-13). (onboarding revamp)
            if appState.hasSeenOnboarding {
                locationManager.requestAuthorization()
            }

            // The screen stays on for as long as a flight runs, and only then: a kneeboard iPad must
            // not lock mid-approach, and one on the desk should. It was a setting. (v6.0 · P7) And on a
            // Companion iPhone showing the iPad's flight (`ScreenAwakeRule`, 6.2.0).
            UIApplication.shared.isIdleTimerDisabled = keepsScreenAwake

            // Retire an activation that was never flown. Runs once, at launch, and only when no
            // flight is in progress — a restored flight keeps its plan whatever its age.
            if !appState.isFlightActive {
                flightPlanManager.expireStaleActivation()
            }

            threadManager.tracksCost = appState.settings.enableCostTracking
        }
        // Keep the task engine's view of the cost setting in step. The engine is pure and the
        // manager owns the settings-aware side, so the root is where the two are joined. (v5.0.0)
        .onChange(of: appState.settings.enableCostTracking) { _, tracks in
            threadManager.tracksCost = tracks
        }
        .onChange(of: keepsScreenAwake) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        // Once — and only once BOTH sides have loaded. Deliberately not hung off a plan change:
        // `FlightCreator` adds the plan before it creates the flight, so a sweep triggered by the
        // insertion would strip the date it had just set, a beat before anything followed it. (v5.x)
        .onChange(of: routeDateSweepReady) { _, ready in
            if ready { sweepRouteDates() }
        }
        // START FLIGHT from a flight opened in Plan › Flights. (round 6)
        .onChange(of: appState.pendingFlightStart) { _, request in
            guard let request else { return }
            appState.pendingFlightStart = nil
            startFollowedFlight(threadId: request.threadId, circuits: request.circuits)
        }
        // Re-derive the AUTO rows whenever a plan changes anywhere. The flight screen refreshes
        // itself on appear, but Home's strip advertises the next task and the readiness ring off the
        // same tasks — so without this, entering the fuel on the plan editor left Home still saying
        // "Next: Fuel plan" until the flight was opened. (device pass)
        // Every save, not `.onChange(of:)`: `FlightPlan`'s `==` compares ids only, so an edit to a plan
        // was never seen as a change here either. (on-device review #1, T-01)
        .onReceive(flightPlanManager.$flightPlans) { plans in
            threadManager.refreshTasks(from: plans)
        }
        #if DEBUG
        .task {
            // DEV-ONLY: auto-inject a marketing scene at launch for deterministic screenshot capture,
            // e.g. `SIMCTL_CHILD_AEROCHECK_SCENE=cruiseroute xcrun simctl launch <udid> com.fetzu.aerocheck`.
            // Compiled out of release builds entirely (this whole block is #if DEBUG).
            // A ground replay instead (`AEROCHECK_REPLAY`, GroundReplay.swift): never with a scene.
            if await GroundReplay.startIfRequested(appState: appState, locationManager: locationManager,
                                                   airportDataService: airportDataService,
                                                   flightPlanManager: flightPlanManager,
                                                   threadManager: threadManager) { return }
            // A dry run instead (`AEROCHECK_DRYRUN=lszq`, at `AEROCHECK_DRYRUN_SPEED`, 4 by default): its
            // circuits at LSZQ from launch, for a check or a capture without a tap. `AEROCHECK_DRYRUN_AUTO=1`
            // flies it as a pilot would, `AEROCHECK_DRYRUN_STOP=final|cruise|over` stops it there
            // (`DryRunAutopilot`). `AEROCHECK_DRYRUN=sheet`: the start sheet; `guided`: the guided dry run, the
            // whole story, from `AEROCHECK_DRYRUN_PART` (1 to 4) or Fly's `AEROCHECK_DRYRUN_CHAPTER`. (6.4.0)
            let environment = ProcessInfo.processInfo.environment
            if let dryRun = environment["AEROCHECK_DRYRUN"]?.lowercased() {
                if appState.needsDisclaimerAcceptance { appState.acceptDisclaimer() }
                if !appState.hasSeenOnboarding { appState.completeOnboarding() }
                if dryRun == "sheet" {
                    DryRunCenter.shared.requestStart()
                    return
                }
                if dryRun == "guided" {
                    // From a part (`AEROCHECK_DRYRUN_PART`, 1 to 4) or Fly's chapter (`AEROCHECK_DRYRUN_CHAPTER`).
                    let part = environment["AEROCHECK_DRYRUN_PART"].flatMap { Int($0) }.flatMap(DryRunPart.init(rawValue:))
                    let chapter = environment["AEROCHECK_DRYRUN_CHAPTER"].flatMap { Int($0) }
                    DryRunCenter.shared.requestGuided(chapter.map { DryRunStart(part: .fly, chapter: $0) }
                                                      ?? DryRunStart(part: part ?? .plan))
                    if environment["AEROCHECK_DRYRUN_AUTO"] == "1" {
                        DryRunAutopilot(stop: environment["AEROCHECK_DRYRUN_STOP"].flatMap(DryRunAutopilot.Stop.init)).fly()
                    }
                    return
                }
                let speed = environment["AEROCHECK_DRYRUN_SPEED"].flatMap(Double.init) ?? 4
                let auto = environment["AEROCHECK_DRYRUN_AUTO"] == "1"
                await DryRunCenter.shared.begin(DryRunSetup(mission: .circuits(.lszq), rate: speed,
                                                            landings: auto ? [] : [.touchAndGo, .goAround]),
                                                settings: { [appState] in appState.settings },
                                                airports: airportDataService, aircraftData: aircraftDataService,
                                                isFlightActive: appState.isFlightActive)
                if auto {
                    DryRunAutopilot(stop: environment["AEROCHECK_DRYRUN_STOP"].flatMap(DryRunAutopilot.Stop.init)).fly()
                }
                return
            }
            guard let key = ProcessInfo.processInfo.environment["AEROCHECK_SCENE"]?.lowercased() else { return }
            // The device checks' routes and flights, dated from today (`DevCheckScene`): not a marketing scene, so
            // no marketing mode, and only the scene's own items are replaced. (6.6.0)
            if key == "devcheck" {
                if appState.needsDisclaimerAcceptance { appState.acceptDisclaimer() }
                if !appState.hasSeenOnboarding { appState.completeOnboarding() }
                for _ in 0..<40 where !(threadManager.hasLoadedThreads && threadManager.hasLoadedTrips
                                        && flightPlanManager.hasLoadedPlans) {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                await DevCheckScene.inject(appState: appState, plans: flightPlanManager, threads: threadManager,
                                           airports: airportDataService)
                CaptureSignal.post()
                return
            }
            let scene: MarketingScene?
            switch key {
            case "cruiseroute":                 scene = .cruiseRoute
            case "cruisemap":                   scene = .cruiseMap
            case "conflicts", "planconflicts":  scene = .planConflicts
            case "flightlog", "flightlogdetail": scene = .flightLogDetail
            case "flight", "flightfollowed":    scene = .flightFollowed
            case "prepare", "flightprepare":    scene = .flightPrepare
            case "closeout", "flightcloseout":  scene = .flightCloseOut
            case "homeflight", "homeflighttoday": scene = .homeFlightToday
            case "circuits", "planmapcircuits": scene = .planMapCircuits
            default:                            scene = nil
            }
            guard let scene else { return }
            // A fresh simulator install would otherwise park the scene behind the safety gate and
            // onboarding; a scene launch means "show me the app", so both are treated as seen.
            if appState.needsDisclaimerAcceptance { appState.acceptDisclaimer() }
            if !appState.hasSeenOnboarding { appState.completeOnboarding() }
            // Let services initialize (airport data lazy-loads; the aircraft list fetch may be in flight).
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // WAIT for the stores to finish loading before injecting. Threads and routes arrive off
            // the main actor, so a fixed sleep raced them: the injector read an EMPTY thread list,
            // cleared nothing, and the threads then appeared on Home — which is how a leftover thread
            // kept hijacking Home's hero in captured screenshots even though the scene resets them.
            for _ in 0..<40 where !(threadManager.hasLoadedThreads && flightPlanManager.hasLoadedPlans) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await MarketingSceneInjector.inject(
                scene,
                appState: appState,
                locationManager: locationManager,
                aircraftDataService: aircraftDataService,
                flightPlanManager: flightPlanManager,
                airportDataService: airportDataService,
                threadManager: threadManager
            )
            // A ground tab, for a shot that opens on one (the logbook's): `AEROCHECK_TAB=logbook`.
            if !appState.isFlightActive, let name = environment["AEROCHECK_TAB"]?.lowercased() {
                let tabs: [String: GroundTab] = ["today": .today, "plan": .plan, "logbook": .logbook,
                                                 "aircraft": .aircraft, "settings": .settings]
                if let tab = tabs[name] { appState.groundTab = tab }
            }
            // The scene is up, with its extras: the screenshot tour takes it from here.
            CaptureSignal.post()
        }
        // The scenes' held fix into the location manager (`injectMarketingStaticFix` primes the smoothed speed and the
        // cached heading too, which SPD and HDG read).
        .onChange(of: marketingProvider.currentLocation) { _, newLocation in
            if marketingProvider.isActive, let location = newLocation {
                locationManager.injectMarketingStaticFix(location)
            }
        }
        #endif
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
                    onApply: { reviewed in
                        // The landings changed after END FLIGHT settled the flight's plan: its counters
                        // follow, in the copy attached to the flight and in the plan list. (v6.1)
                        let home = appState.settings.homeAerodromeIdent
                        let counted = appState.applyReconciliation(reviewed) { flight in
                            airportDataService.landingTally(for: flight, home: home)
                        }
                        if let counted, let flight = appState.flights.first(where: { $0.id == reviewed.flightId }) {
                            flightPlanManager.resettleLandings(of: flight, previous: counted.previous,
                                                               updated: counted.updated)
                        }
                    },
                    onKeep: { appState.keepRecordedReconciliation() }
                )
                .presentationDetents([.large])
            }
        }
        // A dry run: the start sheet (from Settings › About), then, once it has gone, the real Cockpit in a
        // world of its own, over everything, until its page's Done. (6.4.0)
        .dryRunPresenter()
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
                // `onStartFlight` is what gates the START FLIGHT button. Omitting it here meant the
                // cover reached from the T-24h reminder and the open-flight-plan banner — the "time
                // to go fly" moment — showed the whole thread with no way to depart from it.
                // (review F21)
                FlightThreadView(threadId: id,
                                 onClose: { appState.pendingThreadToOpen = nil },
                                 onStartFlight: { circuits in
                                     appState.pendingThreadToOpen = nil
                                     startFollowedFlight(threadId: id, circuits: circuits)
                                 },
                                 onOpenLeg: { appState.pendingThreadToOpen = $0 })
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

    /// Depart on a followed flight opened from its notification or from the close-out banner.
    ///
    /// Mirrors HomeView's `launch(_:)`: arm the thread's route, select the aircraft it was planned
    /// with, and go through the shared `FlightLauncher` rather than starting a flight some other
    /// way. Circuits skip the plan by design. (review F21)
    private func startFollowedFlight(threadId: UUID, circuits: Bool) {
        // Before anything else: the launcher refuses a second flight (UX-06), but only after this
        // has selected the thread's aircraft and armed its plan. A thread opened from its reminder
        // while flying switched both under the flight in progress. The page no longer offers a start
        // then (`ThreadStartOffer.flightInProgress`): this is the backstop, and says so in the log.
        guard !appState.isFlightActive else {
            AppLog.general.publicLine("Start from a flight's page refused: a flight is in progress")
            return
        }
        guard let thread = threadManager.thread(withId: threadId) else { return }
        if let registration = thread.aircraftRegistration, !registration.isEmpty {
            _ = appState.selectAircraft(id: registration,
                                        available: aircraftDataService.availableAircraft)
        }
        if !circuits,
           let planId = thread.flightPlanId,
           flightPlanManager.activeFlightPlan?.id != planId,
           let plan = flightPlanManager.flightPlans.first(where: { $0.id == planId }),
           !plan.waypoints.isEmpty {
            flightPlanManager.activateFlightPlan(plan)
        }
        let launcher = FlightLauncher(
            appState: appState,
            locationManager: locationManager,
            aircraftDataService: aircraftDataService,
            airportDataService: airportDataService,
            flightEventDetector: flightEventDetector,
            flightPlanManager: flightPlanManager,
            threadManager: threadManager
        )
        Task { await launcher.begin(circuitMode: circuits, followedFlightId: threadId) }
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
                .font(.aero(size: 15, weight: .semibold))
            Text(message)
                .font(.aero(size: 14, weight: .medium))
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
    /// The rule and the numbers of the country landed in. (6.5.0)
    let closeOut: CloseOut
    let onMarkClosed: () -> Void
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.aero(size: 15, weight: .semibold))
                .foregroundColor(.aviationRed)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Thread.closeFlightPlanTitle)
                    .font(.aero(size: 14, weight: .semibold))
                    .foregroundColor(.primaryText)
                Text(L10n.Thread.closeFlightPlanBody(routeLabel, rule: closeOut.rule))
                    .font(.aero(size: 12))
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 8) {
                    // The numbers of the country landed in, two at most as on the flight's page: Sweden's two ACCs
                    // are for the north and the south, so the first alone was half the answer (the author's v65-12,
                    // 23 Oct 2026). Wrapped onto a second line where they don't fit. (6.5.0)
                    ForEach(closeOut.phones.prefix(2), id: \.number) { phone in
                        if let url = CloseOut.callURL(phone) {
                            Button {
                                openURL(url)
                            } label: {
                                Text(L10n.CloseOut.call(phone.name))
                                    .font(.aero(size: 12, weight: .semibold))
                                    .foregroundColor(.aviationRed)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .padding(.horizontal, 12).frame(minHeight: 34)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.aviationRed.opacity(0.16))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.aviationRed.opacity(0.5), lineWidth: 1)))
                                    .contentShape(Rectangle())
                            }
                            .accessibilityValue(phone.number)
                        }
                    }
                    Button(action: onMarkClosed) {
                        Text(L10n.Thread.markFlightPlanClosed)
                            .font(.aero(size: 12, weight: .semibold))
                            .foregroundColor(.aviationGreen)
                            .padding(.horizontal, 12).frame(minHeight: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.aviationGreen.opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.aviationGreen.opacity(0.45), lineWidth: 1)))
                            .contentShape(Rectangle())
                    }
                    Button(action: onDismiss) {
                        Text(L10n.Button.close)
                            .font(.aero(size: 12, weight: .semibold))
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
                .font(.aero(size: 15, weight: .semibold))
                .foregroundColor(.aviationAmber)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Nav.activationExpiredTitle)
                    .font(.aero(size: 14, weight: .semibold))
                    .foregroundColor(.primaryText)
                Text(L10n.Nav.activationExpiredMessage(routeLabel))
                    .font(.aero(size: 12))
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: onRearm) {
                        Text(L10n.Nav.rearm)
                            .font(.aero(size: 12, weight: .semibold))
                            .foregroundColor(.aviationGreen)
                            .padding(.horizontal, 12).frame(minHeight: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.aviationGreen.opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.aviationGreen.opacity(0.45), lineWidth: 1)))
                            .contentShape(Rectangle())
                    }
                    Button(action: onDismiss) {
                        Text(L10n.Button.close)
                            .font(.aero(size: 12, weight: .semibold))
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
/// Offers the light close-out for a circuit session. Deliberately quieter than the open-flight-plan
/// banner: nothing here has a search-and-rescue consequence, and declining is a complete answer.
struct CircuitCloseOutBanner: View {
    let routeLabel: String
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.aero(size: 15, weight: .semibold))
                .foregroundColor(.aviationGold)
            VStack(alignment: .leading, spacing: 2) {
                Text(routeLabel)
                    .font(.aero(size: 14, weight: .semibold))
                    .foregroundColor(.primaryText)
                Text(L10n.Thread.circuitCloseOutOffer)
                    .font(.aero(size: 12))
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L10n.Thread.circuitCloseOutAccept, action: onAccept)
                .font(.aero(size: 13, weight: .semibold))
                .foregroundColor(.aviationGold)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.aero(size: 13, weight: .semibold))
                    .foregroundColor(.dimText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Button.close)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.panelBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.aviationGold.opacity(0.5), lineWidth: 1)
        )
        .appBannerWidth()
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }
}

struct DataFreshnessNudgeBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.aero(size: 15, weight: .semibold))
            Text(message)
                .font(.aero(size: 14, weight: .medium))
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

private extension ContentView {

    /// Both managers load off-main; the sweep needs the answer to "does a flight follow this plan?",
    /// which is only trustworthy once the threads are actually here.
    var routeDateSweepReady: Bool {
        flightPlanManager.hasLoadedPlans && threadManager.hasLoadedThreads
    }

    func sweepRouteDates() {
        guard !hasSweptRouteDates else { return }
        hasSweptRouteDates = true
        let followed = Set(threadManager.threads.compactMap(\.flightPlanId))
        flightPlanManager.clearDatesFromUnflownRoutes(followedPlanIds: followed)
    }

    /// See `ScreenAwakeRule`.
    var keepsScreenAwake: Bool {
        ScreenAwakeRule.keepsAwake(isFlightActive: appState.isFlightActive,
                                   companionRole: companionConnectivityManager.currentRole,
                                   companionState: companionConnectivityManager.connectionState,
                                   isDryRunning: dryRuns.isRunning)
    }
}

/// When the screen stays on: for as long as a flight runs, and only then, a kneeboard iPad must not
/// lock mid-approach and one on the desk should (v6.0 · P7). And on a Companion iPhone while it shows the
/// iPad's flight (`.connected`, or `.reconnecting` within the grace after a drop): it runs no flight of
/// its own, so it locked after its auto-lock delay, was suspended, and the link went with it. (6.2.0)
/// And during a dry run, flown as a flight is. (6.4.0)
enum ScreenAwakeRule {
    static func keepsAwake(isFlightActive: Bool, companionRole: CompanionRole,
                           companionState: CompanionConnectionState, isDryRunning: Bool = false) -> Bool {
        if isFlightActive || isDryRunning { return true }
        return companionRole == .viewer && (companionState == .connected || companionState == .reconnecting)
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
                    .font(.aero(size: 64))
                    .foregroundColor(.aviationGold)

                VStack(spacing: 8) {
                    Text(L10n.ContentViewStrings.rotateDevice)
                        .font(.aero(size: 24, weight: .bold))
                        .foregroundColor(.primaryText)

                    Text(L10n.ContentViewStrings.portraitMode)
                        .font(.aero(size: 16))
                        .foregroundColor(.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                // Visual hint with phone icon
                HStack(spacing: 20) {
                    // Current orientation (crossed out)
                    ZStack {
                        Image(systemName: "iphone.landscape")
                            .font(.aero(size: 32))
                            .foregroundColor(.dimText)
                        Image(systemName: "xmark")
                            .font(.aero(size: 24, weight: .bold))
                            .foregroundColor(.aviationRed)
                    }

                    Image(systemName: "arrow.right")
                        .font(.aero(size: 20))
                        .foregroundColor(.dimText)

                    // Desired orientation
                    Image(systemName: "iphone")
                        .font(.aero(size: 32))
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
