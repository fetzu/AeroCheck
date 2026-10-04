import SwiftUI
import Combine
import CoreLocation
import MapKit
import UIKit

/// Main flight view displayed during an active flight
struct FlightView: View {
    @Environment(\.cockpitTheme) private var theme
    @Environment(AppState.self) private var appState
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var windDataService: WindDataService
    @EnvironmentObject var aviationWeatherService: AviationWeatherService
    @EnvironmentObject var windsAloftService: WindsAloftService
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var threadManager: FlightThreadManager
    @EnvironmentObject var flightEventDetector: FlightEventDetector
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager
    @State private var showPhaseSelector = false
    @State private var showEndFlightAlert = false
    @State private var showAbandonFlightAlert = false
    @State private var abandonFlightProgress: CGFloat = 0
    /// Whether the aircraft name is being held (red while held, whatever the ring shows).
    @State private var isHoldingAbandon = false
    @State private var showFlightInfo = false
    /// NEXT pressed with items still open: the review sheet lists them first. (v6.0 · B2)
    @State private var openItemsReview: OpenItemsReview?
    @State private var showDeferredItems = false
    /// A jump on the phase bar that leaves two checks or more undone asks first. (v6.0 review, J2-J3)
    @State private var jumpQuestion: JumpQuestion?
    /// A phase picked in the phase list, jumped to once the list is gone (one sheet at a time).
    @State private var pendingJump: ChecklistPhase?
    /// The reference popup currently shown in the HUD context slot (Pattern B of the A+B hybrid):
    /// docked into the iPad-landscape right column (over the map), or a cockpit-themed bottom drawer
    /// on iPad portrait / iPhone. nil = none. HUD Settings stays a sheet (Pattern A). (v4 UI/UX Revamp)
    @State private var activeReference: HUDReference? = nil
    /// The Cockpit page the pilot picked, over the one the flight suggests. Dropped as soon as the
    /// suggestion changes (next phase, checklist done). (v6.0 · P2; ROUTE 6.2)
    @State private var paneChoice: CockpitPaneChoice
    /// What the act band owns for every page: MARK's UNDO, the Divert sheet, the routes, the leg ROUTE
    /// asked MAP to show. (6.2)
    @State private var navState: CockpitNavState
    /// NOW, NEXT and every frequency, on every page, and the Watch's list. (6.2, ROUTE)
    @State private var radio: CockpitRadio
    /// OFF ROUTE, followed on every page, and More's requests to the chart. (6.2, MAP's chrome)
    @State private var chartState = CockpitMapState()
    @State private var pulseNextButton = false
    @State private var pulseActionButton = false
    @State private var allItemsChecked = false
    /// Binding to the hidden-items reveal state, now owned by `AppState` so a companion's hold-to-reveal
    /// syncs to both devices. Reset on phase change in AppState. (companion v2 — hidden-content parity)
    private var hiddenItemsRevealed: Binding<Bool> {
        Binding(get: { appState.hiddenItemsRevealed }, set: { appState.hiddenItemsRevealed = $0 })
    }

    // Hour meter input modals
    @State private var showHourMeterStart = false
    /// Stable periodic timer (created once) driving FREDA's evaluation. (v4 UI/UX Revamp fix; FREDA 6.1)
    @State private var fredaEvalTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var showHourMeterStop = false
    @State private var hourMeterStartInitialValue: String = ""
    @State private var hourMeterStopInitialValue: String = ""


    /// `initialPane`: the page to open on, as if the pilot had picked it (a test's way to CHECKLIST in
    /// cruise, which the flight shows on MAP, or to ROUTE). `radio`: a test's, to read what it computed.
    init(initialPane: CockpitPane? = nil, radio: CockpitRadio? = nil) {
        let navState = CockpitNavState()
        _paneChoice = State(initialValue: CockpitPaneChoice(override: Self.capturePane(initialPane, navState: navState)))
        _navState = State(initialValue: navState)
        _radio = State(initialValue: radio ?? CockpitRadio())
    }

    /// The page to open on. DEV-ONLY, for captures (6.2): `AEROCHECK_PANE=route` opens on that page,
    /// `AEROCHECK_LEG=3` on MAP showing the leg to the fourth waypoint, as a tap on its row on ROUTE does.
    private static func capturePane(_ pane: CockpitPane?, navState: CockpitNavState) -> CockpitPane? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let leg = environment["AEROCHECK_LEG"].flatMap(Int.init) {
            navState.showLeg(leg)
            return .map
        }
        if pane == nil, let name = environment["AEROCHECK_PANE"]?.lowercased() {
            return ["checklist": .checklist, "map": .map, "route": .route][name]
        }
        #endif
        return pane
    }

    /// Check if current phase has an action button that hasn't been pressed yet. Not the check before
    /// departure since 6.2: READY FOR LINE UP is its NEXT.
    private var currentPhaseNeedsAction: Bool {
        switch appState.currentPhase {
        case .engineStart:
            return appState.engineStartTime == nil
        case .afterLanding:
            return appState.landingTime == nil
        case .shutdown:
            return appState.engineShutdownTime == nil
        default:
            return false
        }
    }

    /// Whether the current phase's checklist is "complete" — all items stepped through (in step-by-step
    /// mode) and any required timestamp action recorded. Drives the NEXT button's ready/greyed look; the
    /// button stays tappable either way so a phase can still be skipped. (v4 UI/UX Revamp feedback)
    private var nextButtonReady: Bool {
        appState.currentCheckIsDone && !currentPhaseNeedsAction
    }

    /// Learning mode OR temporarily-revealed hidden items — the set of items the checklist is showing,
    /// so tap-to-advance and completion stay in sync with what's on screen. (v4 UI/UX Revamp feedback)
    private var effectiveLearningMode: Bool {
        appState.effectiveLearningMode
    }

    /// Build briefing context from current state
    private var briefingContext: BriefingContext {
        // Get speeds from current checklist
        let speeds: [SpeedReference]
        let hasParachute: Bool
        let registration: String
        let aircraftType: String

        let checklist = appState.activeChecklist
        speeds = checklist.speeds
        hasParachute = checklist.hasParachute
        registration = checklist.registration
        aircraftType = checklist.shortModelName

        // Resolve the briefing wind across all available sources. The CHOICE is a pure rule
        // (`BriefingWindLadder`) rather than a preference expressed here, so it can be tested
        // without a network: METAR where a real aerodrome report is in range, a MeteoSwiss station
        // where one is closer and better matched in altitude, and the model only when neither
        // exists — always labelled as such.
        let briefingWind = BriefingWindLadder.select(
            metars: aviationWeatherService.ladderCandidates,
            station: windDataService.currentWindData,
            model: windsAloftService.surfaceCandidate(near: locationManager.getCurrentCoordinate()),
            aircraftAltitudeM: locationManager.currentAltitudeMeters,
            now: Date()
        )

        // Get destination from flight plan if available (waypoint name is often the ICAO code)
        let destinationIdent = flightPlanManager.activeFlightPlan?.waypoints.last?.name

        // Show a TAF only when it is for the field this briefing is ABOUT. The service holds one
        // forecast at a time, so a stale one for the departure field must not surface during an
        // approach briefing to somewhere else — matching on ICAO is what prevents that.
        let briefingTaf = aviationWeatherService.taf
            .flatMap { forecast -> BriefingContext.TafSummary? in
                guard let first = forecast.forecasts.first, let raw = first.raw else { return nil }
                return .init(icao: forecast.icao, issuedAt: first.issuedAt,
                             validFrom: first.validFrom, validTo: first.validTo, raw: raw)
            }

        return BriefingContextBuilder.build(
            speeds: speeds,
            hasParachute: hasParachute,
            aircraftRegistration: registration,
            aircraftType: aircraftType,
            currentLocation: locationManager.getCurrentCoordinate(),
            airportDataService: airportDataService,
            wind: briefingWind,
            taf: briefingTaf,
            destinationIdent: destinationIdent,
            flightPlan: flightPlanManager.activeFlightPlan,
            nonPoweredReportingPoints: appState.settings.showsNonPoweredReportingPoints
        )
    }

    /// Refresh aerodrome observations and en-route hazards around the aircraft.
    ///
    /// Silent by design: every failure inside the service degrades to "no data" and the ladder
    /// simply falls to its next rung. A briefing that cannot reach the network shows the sources it
    /// does have — which, before this existed, was nothing outside Switzerland.
    private func refreshAviationWeather() async {
        guard let coordinate = locationManager.getCurrentCoordinate() else { return }
        await aviationWeatherService.refresh(near: coordinate)

        // A TAF is issued FOR an aerodrome, so the phase decides which field to ask about: the
        // planned destination while briefing an approach, the field underneath while briefing a
        // departure. Falls back to the nearest reporting station, which is usually the same place.
        if let icao = briefingAerodromeIcao() {
            await aviationWeatherService.refreshTaf(icao: icao)
        }
    }

    /// The aerodrome the current briefing is about, as an ICAO code.
    private func briefingAerodromeIcao() -> String? {
        if appState.currentPhase.briefingType == .approach,
           let destination = flightPlanManager.activeFlightPlan?.waypoints.last?.name,
           destination.count == 4 {
            return destination.uppercased()
        }
        // Nearest station with an actual report — the field being flown from, in practice.
        return aviationWeatherService.observations.first?.icao
    }

    // MARK: - Phase progress bar

    /// Phases shown in the progress bar (Cruise/Descent hidden in circuit mode, matching the old list).
    private var visiblePhases: [ChecklistPhase] {
        ChecklistPhase.allCases.filter { phase in
            !(appState.isCircuitMode && (phase == .cruise || phase == .descent))
        }
    }

    private var phaseProgressBarView: some View {
        phaseProgressBar(interactive: true)
    }

    /// `interactive`: false for the bar drawn inside the phase button (`PhaseProgressBar.drawnBar`).
    private func phaseProgressBar(interactive: Bool) -> some View {
        PhaseProgressBar(
            phases: visiblePhases,
            currentPhase: appState.currentPhase,
            status: { appState.getPhaseStatus($0) },
            onSelect: { requestJump(to: $0) },
            isCircuitMode: appState.isCircuitMode,
            fredaDue: appState.fredaDue,
            currentOwed: appState.cueTiming(for: appState.currentPhase) == .owed,
            interactive: interactive
        )
    }

    var body: some View {
        GeometryReader { geometry in
            // The Cockpit on both devices: the iPad's zones, laid out for the room there is. (v6.0 · P2,
            // iPhone pass I1)
            let layout = CockpitLayout.make(width: geometry.size.width, height: geometry.size.height)
            cockpit(layout: layout, mergesReadLines: CockpitColumnRule.mergesNextAndNow(height: geometry.size.height))
                .modifier(CameraSideInset(enabled: layout == .columns,
                                          systemInset: geometry.safeAreaInsets.leading))
                // Reference popups (V-SPEEDS / GPS / BRIEFING) → themed bottom drawer.
                .overlay {
                    referenceDrawerOverlay(maxHeight: geometry.size.height * layout.drawerHeightFraction,
                                           kneeboard: true,
                                           landscape: geometry.size.width > geometry.size.height,
                                           // The iPad's table grows rather than scroll (D7); the phone's list
                                           // keeps the phone's cap, which leaves the strip in view.
                                           vSpeedsMaxHeight: geometry.size.height * (layout == .wide ? 0.75 : layout.drawerHeightFraction))
                }
        }
        // Laid out without the keyboard. The Cockpit has no field of its own, but the routes it opens
        // from the map (a cover, with a search field and the route builder) do, and their keyboard
        // reaches the Cockpit behind: on an iPad in landscape it left it under the 500 pt of
        // `.columns`, a Cockpit with a map of its own, and the cover opened from the old map closed
        // as the search field was tapped. The map pane's own switch (1.2 : 1) is kept out of it the
        // same way. (6.1.0)
        .ignoresSafeArea(.keyboard)
        .background(theme.background)
        .sheet(isPresented: $showPhaseSelector, onDismiss: {
            if let phase = pendingJump {
                pendingJump = nil
                requestJump(to: phase)
            }
        }) {
            PhaseSelectorView(onSelect: { phase in
                pendingJump = phase
                showPhaseSelector = false
            })
        }
        .sheet(isPresented: $showFlightInfo) {
            FlightInfoSheet(locationManager: locationManager, onEndFlight: {
                showFlightInfo = false
                performEndFlight()
            })
        }
        .sheet(item: $openItemsReview) { review in
            OpenItemsReviewSheet(
                phase: review.phase,
                items: review.items,
                memoryCheck: review.memoryCheck,
                // The highlight is already on the first open item.
                onBack: { openItemsReview = nil },
                onContinue: {
                    openItemsReview = nil
                    advanceToNextPhase()
                }
            )
            .environment(\.cockpitTheme, theme)
        }
        .sheet(item: $jumpQuestion) { question in
            JumpQuestionSheet(
                target: question.target,
                checks: question.checks,
                leaving: question.leaving,
                leavingOpenItems: question.leavingOpenItems,
                onDefer: {
                    jumpQuestion = nil
                    appState.goToPhase(question.target, skipped: .deferred)
                },
                onAlreadyDone: {
                    jumpQuestion = nil
                    appState.goToPhase(question.target, skipped: .alreadyDone)
                },
                onStay: { jumpQuestion = nil }
            )
            .environment(\.cockpitTheme, theme)
        }
        .sheet(isPresented: $showDeferredItems) {
            DeferredItemsSheet(onClose: { showDeferredItems = false })
                .environment(\.cockpitTheme, theme)
                // Room for a deferred check's list and thumb bar, not the form sheet's. (J1)
                .pageSizedSheet()
        }
        // ⚠️ DO NOT CHANGE the presentation style (.fullScreenCover) unless explicitly asked
        // by the user. Using .fullScreenCover guarantees all content is visible on both iPad
        // and iPhone. iPad ignores .presentationDetents on form sheets, so .sheet cannot
        // reliably show all HourMeterInputView content. Dismiss is handled by Cancel/Skip/Save.
        .fullScreenCover(isPresented: $showHourMeterStart) {
            HourMeterInputView(
                isPresented: $showHourMeterStart,
                phase: .start,
                onSubmit: { hours, format in
                    appState.currentFlight?.engineHourStart = hours
                    appState.currentFlight?.engineHourStartInputFormat = format
                },
                initialValue: hourMeterStartInitialValue
            )
        }
        .fullScreenCover(isPresented: $showHourMeterStop) {
            HourMeterInputView(
                isPresented: $showHourMeterStop,
                phase: .stop,
                onSubmit: { hours, format in
                    appState.currentFlight?.engineHourEnd = hours
                    appState.currentFlight?.engineHourEndInputFormat = format
                },
                initialValue: hourMeterStopInitialValue,
                startHours: appState.currentFlight?.engineHourStart
            )
        }
        .alert(L10n.Alert.endFlightTitle, isPresented: $showEndFlightAlert) {
            Button(L10n.Button.cancel, role: .cancel) { }
            Button(L10n.Button.endFlight, role: .destructive) { performEndFlight() }
        } message: {
            Text(L10n.Alert.endFlightMessage)
        }
        .alert(L10n.Alert.abandonFlightTitle, isPresented: $showAbandonFlightAlert) {
            Button(L10n.Button.cancel, role: .cancel) { }
            Button(L10n.Alert.abandonFlightButton, role: .destructive) {
                // Release the followed flight FIRST, while the flight id still exists to match on.
                // An abandoned flight did not happen: leaving it attached left the thread reading
                // IN FLIGHT forever, its FLY chapter green, and its START FLIGHT button hidden —
                // with no flight running. (device pass)
                let abandoned = appState.currentFlight
                if let abandonedId = abandoned?.id {
                    threadManager.detachAbandonedFlight(abandonedId)
                }
                locationManager.stopTracking()
                appState.cancelFlight()
                // Only the plan this flight was started with: one left armed through circuits or a
                // flight started without it stays armed. (v6.0.1)
                flightPlanManager.abandonFlownPlan(of: abandoned)
            }
        } message: {
            Text(L10n.Alert.abandonFlightMessage)
        }
        .onAppear {
            // Wind feeds the departure and approach briefings, so it is fetched for the whole
            // flight rather than gated behind a toggle. The service no-ops outside Switzerland.
            windDataService.startFetching(locationManager: locationManager)
            // METAR/SIGMET are the worldwide half of the same briefing. Self-throttled to the
            // proxy's own 5-minute cache window, so this is safe to call on every appearance.
            Task { await refreshAviationWeather() }
        }
        .onDisappear {
            windDataService.stopFetching()
        }
        .onReceive(fredaEvalTimer) { _ in
            evaluateFreda()
        }
        .onChange(of: appState.currentPhase) { _, phase in
            // A briefing phase is exactly when a stale observation matters most: an approach
            // briefing read off a departure-time METAR is an hour old at the worst moment.
            if phase.briefingType != nil { Task { await refreshAviationWeather() } }
        }
        .onChange(of: appState.currentPhase) { oldPhase, newPhase in
            evaluateFreda()
            // Entering Engine Start asks for the hour meter, unless it was entered inline at the end of
            // Before engine start. The prompt coming up by itself is what stops it being forgotten.
            // (on-device review #1, C-03)
            if newPhase == .engineStart && oldPhase != .engineStart && appState.settings.logEngineHours
                && appState.currentFlight?.engineHourStart == nil {
                hourMeterStartInitialValue = ""
                showHourMeterStart = true
            }
            // Re-show hour meter stop input when navigating back to Shutdown phase
            // (e.g., after reset) if shutdown time was cleared
            if newPhase == .shutdown && oldPhase != .shutdown && appState.settings.logEngineHours {
                if appState.engineShutdownTime == nil && appState.currentFlight?.engineHourEnd != nil {
                    // Shutdown was reset - pre-fill with previous value
                    let prevEnd = appState.currentFlight?.engineHourEnd ?? 0
                    let prevFormat = appState.currentFlight?.engineHourEndInputFormat ?? "decimal"
                    if prevFormat == "time" {
                        hourMeterStopInitialValue = Flight.formatHoursTime(prevEnd)
                    } else {
                        hourMeterStopInitialValue = Flight.formatHoursDecimal(prevEnd)
                    }
                    appState.currentFlight?.engineHourEnd = nil
                    appState.currentFlight?.engineHourEndInputFormat = nil
                }
            }
        }
        // Event confirmation overlays. The same modifier is also applied inside NavigationMapView
        // so a detected event's prompt is visible/dismissable while the full-screen map is up — a
        // .fullScreenCover renders above these overlays otherwise. (PR-40)
        .flightEventConfirmationOverlay(detector: flightEventDetector, appState: appState)
    }
    
    /// END FLIGHT, from the last phase or from the Menu at any phase: stop the track, settle the times,
    /// hand the flight over to its thread and the logbook. (v6.0 · P2 — was the alert's action)
    private func performEndFlight() {
        let endedFlightId = appState.currentFlight?.id
        let checklist = appState.activeChecklist
        locationManager.stopTracking()
        // Block off, take-off and block on from the whole track, before the plan's times over
        // and the thread read them. (v5.2)
        appState.refineTimingFromTrack()
        // Then a departure or an arrival the live detection missed (or an arrival it left on an
        // earlier stop), from those measured positions, before the plan reads where it landed. (v6.1)
        appState.settleAerodromesAtEndOfFlight(nearestAerodrome: { airportDataService.aerodromeIdent(at: $0) })
        // The plan this flight flew gets its times (and, landed elsewhere, the diversion), is attached
        // to it and ends its activation. Only the plan the flight was started with: one left armed
        // through circuits or a flight started without it is left as it was, still armed. (v5.1, v6.0.1)
        // Its landings are counted against the home aerodrome: the airport data is loaded at flight start.
        let flownPlan = appState.currentFlight.flatMap { flight in
            flightPlanManager.settleFlownPlan(flight, takeoff: appState.lineUpTime, landing: appState.landingTime,
                                              landedAt: landedAerodrome(flight),
                                              landings: airportDataService.landingTally(
                                                for: flight, home: appState.settings.homeAerodromeIdent))
        }
        let plannedDestination = flownPlan?.waypoints.last?.name
        let landedDiversion = flownPlan?.diversion
        // v5.0.0: resolve the followed thread BEFORE the plan is deactivated — afterwards
        // there is no plan left to resolve it from. A flight with no thread resolves to nil
        // and nothing below changes, which is what "start a flight without a thread" means.
        let wasCircuits = appState.isCircuitMode
        let closingThreadId = threadManager.threadToCloseOut(
            flightId: endedFlightId,
            planId: flightPlanManager.activeFlightPlan?.id,
            isCircuitMode: wasCircuits,
            isUnplanned: appState.flightIsUnplanned
        )
        appState.endFlight(withFlightPlan: flownPlan)
        if flownPlan != nil { flightPlanManager.deactivateFlightPlan() }

        // Move the thread into close-out. This is what raises the open-flight-plan banner and
        // arms the reminder, so it must run after the flight is actually over.
        if let closingThreadId {
            // Landed elsewhere: the thread says so first, so the banner and the reminder name
            // the aerodrome the aircraft is actually at. (v5.1)
            if let landedDiversion, let plannedDestination {
                threadManager.recordLanding(threadId: closingThreadId, plannedIdent: plannedDestination,
                                            landedIdent: landedDiversion.ident,
                                            landedName: landedDiversion.name)
            }
            threadManager.beginCloseOut(threadId: closingThreadId, flightId: endedFlightId)
        } else if wasCircuits, let endedFlightId,
                  let flown = appState.flights.first(where: { $0.id == endedFlightId }) {
            // Circuits resolve to no thread by design — they cannot be planned. Offer the
            // light close-out rather than leaving the session with no logbook line. (v5.x)
            threadManager.offerCircuitCloseOut(
                flightId: endedFlightId,
                departureIdent: flown.departureAirportIdent,
                aircraftRegistration: flown.aircraftRegistration
            )
        }

        // Post-flight reconciliation (D2): re-segment the saved track offline and
        // build the review diff. Shown only when it would change EVENTS; a pure
        // block-time back-fill (additive) is applied without ceremony.
        if let endedFlightId,
           let flight = appState.flights.first(where: { $0.id == endedFlightId }) {
            let result = FlightReconciliation.analyze(
                flight: flight,
                speeds: checklist.speeds,
                stallSpeed: checklist.stallSpeed,
                nearbyAirports: { coordinate in
                    airportDataService.findNearestAirports(
                        to: coordinate, limit: 3, maxDistanceNm: 5.0,
                        types: AirportType.fixedWing
                    )
                }
            )
            if result.hasEventDiff {
                appState.pendingReconciliation = result
            } else {
                appState.backfillBlockTimes(result)
            }
        }
    
    }

    // MARK: - Main Checklist Area
    
    // MARK: - FREDA (6.1)

    /// FREDA comes due by the clock or at a waypoint the flight passed (the ATO catch-up, or MARK). (6.1)
    private func evaluateFreda() {
        appState.evaluateFreda(lastPassage: FredaWaypointPassage.latest(in: flightPlanManager.activeFlightPlan))
    }

    /// NEXT: with items still open, list them before leaving the phase. (v6.0 · B2) A memory check not
    /// confirmed is reviewed the same way, then deferred whole. (6.1)
    private func requestNextPhase() {
        if appState.currentCheckAwaitsConfirmation {
            openItemsReview = OpenItemsReview(phase: appState.currentPhase, items: [], memoryCheck: true)
            return
        }
        let open = appState.openItems(in: appState.currentPhase)
        if open.isEmpty {
            advanceToNextPhase()
        } else {
            openItemsReview = OpenItemsReview(phase: appState.currentPhase, items: open)
        }
    }

    /// A jump on the phase bar or the phase list. Past the threshold, the checks it would leave undone
    /// are listed first: defer them, they were already done, or stay. (v6.0 review, J2-J3)
    private func requestJump(to target: ChecklistPhase) {
        guard appState.jumpNeedsQuestion(to: target) else {
            appState.goToPhase(target)
            return
        }
        let leaving = appState.currentPhase
        let untouched = appState.checkIsUntouched(leaving)
        jumpQuestion = JumpQuestion(
            target: target,
            checks: (untouched ? [leaving] : []) + appState.checksPassed(jumpingTo: target),
            leaving: leaving,
            leavingOpenItems: untouched ? 0 : appState.openItems(in: leaving).count)
    }

    private func advanceToNextPhase() {
        pulseNextButton = false
        pulseActionButton = false
        allItemsChecked = false
        appState.nextPhase()
    }

    // Phase timestamp actions — shared by the act band's first slot (`ActPhaseActionButton`) and the
    // in-checklist buttons (these methods back the ChecklistView callbacks too, so behavior can't diverge).
    private func performEngineStart() {
        appState.recordEngineStart()
        pulseActionButton = false
        // No keypad here: starting the engine is the busiest moment of the ground phase. The reading
        // is offered inline by the checklist, before the start. (v6.0 · B4)
        if allItemsChecked { triggerNextButtonPulse() }
    }
    private func performEngineStartUpdate() {
        appState.recordEngineStart()
    }
    private func performEngineShutdown() {
        appState.recordEngineShutdown()
        pulseActionButton = false
        // ENGINE SHUTDOWN asks for the hour meter straight away; the checklist still offers it inline
        // afterwards (Shutdown, At the hangar) if this is skipped. (on-device review #1, L-03)
        if appState.settings.logEngineHours && appState.currentFlight?.engineHourEnd == nil {
            hourMeterStopInitialValue = ""
            showHourMeterStop = true
        }
        if allItemsChecked { triggerNextButtonPulse() }
    }
    private func performEngineShutdownUpdate() {
        appState.recordEngineShutdown()
    }

    // MARK: - Event Actions (hold-to-confirm)

    /// Always-accessible GO-AROUND / TOUCH & GO / FULL-STOP buttons for the relevant phases, so the
    /// pilot doesn't have to scroll the checklist to reach them. Gated on the same phase flags as the
    /// in-checklist buttons; hold-to-confirm so a stray touch can't fire a go-around. Empty (no space)
    /// when no event applies to the current phase. (v4 UI/UX Revamp)
    ///
    /// In circuit mode GO-AROUND / TOUCH & GO are single taps, for a quick correction of a missed
    /// detection (the jump back to the CLIMB check); FULL-STOP stays hold-to-confirm always. They were
    /// beside NEXT in the checklist's thumb bar until the act band (6.2), whose slots never change with
    /// the phase.
    @ViewBuilder
    /// `kneeboard`: the Cockpit's size and colours (on-device review #1, L-02).
    private func eventActionsRow(kneeboard: Bool = false) -> some View {
        let phase = appState.currentPhase
        if phase.showsGoAroundButtons || phase.showsLandedButton {
            HStack(spacing: 10) {
                if phase.showsGoAroundButtons {
                    if appState.isCircuitMode {
                        circuitQuickEventButtons
                    } else {
                        holdEventButtons(kneeboard: kneeboard)
                    }
                }
                if phase.showsLandedButton {
                    HoldToConfirmButton(
                        title: L10n.ChecklistAction.landed(language: appState.settings.checklistLanguage.resolvedLanguage),
                        systemImage: "airplane.arrival",
                        tint: kneeboard ? theme.action : .aviationBlue,
                        count: appState.currentFlight?.fullStopCount ?? 0,
                        kneeboard: kneeboard,
                        action: performLanded
                    )
                    .accessibilityIdentifier("cockpit.fullStop")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    /// GO-AROUND and TOUCH & GO held 1 s to confirm.
    @ViewBuilder
    private func holdEventButtons(kneeboard: Bool) -> some View {
        let language = appState.settings.checklistLanguage.resolvedLanguage
        HoldToConfirmButton(
            title: L10n.ChecklistAction.goAround(language: language),
            systemImage: "arrow.up.right.circle.fill",
            tint: kneeboard ? theme.action : theme.warning,
            count: appState.currentFlight?.goAroundCount ?? 0,
            kneeboard: kneeboard,
            action: performGoAround
        )
        .accessibilityIdentifier("cockpit.goAround")
        HoldToConfirmButton(
            title: L10n.ChecklistAction.touchAndGo(language: language),
            systemImage: "arrow.triangle.2.circlepath",
            tint: kneeboard ? theme.action : .aviationBlue,
            count: appState.currentFlight?.touchAndGoCount ?? 0,
            kneeboard: kneeboard,
            action: performTouchAndGo
        )
        .accessibilityIdentifier("cockpit.touchAndGo")
    }

    /// In circuit mode, single-tap GO-AROUND / TOUCH & GO, as tall as the hold buttons: a missed
    /// auto-detection is corrected at once (jump back to the CLIMB check). Hold-to-confirm is too slow
    /// here; the accepted trade-off is a small accidental-tap risk during circuit training. Cyan, the
    /// outlined buttons of the Cockpit: things to press, not alerts. (on-device review #1, L-02)
    @ViewBuilder
    private var circuitQuickEventButtons: some View {
        let language = appState.settings.checklistLanguage.resolvedLanguage
        CockpitThumbButton(title: L10n.ChecklistAction.goAround(language: language),
                           icon: "arrow.up.right.circle.fill", style: .outlined(tint: theme.action),
                           minHeight: 88, action: performGoAround)
            .accessibilityIdentifier("cockpit.goAround")
        CockpitThumbButton(title: L10n.ChecklistAction.touchAndGo(language: language),
                           icon: "arrow.triangle.2.circlepath", style: .outlined(tint: theme.action),
                           minHeight: 88, action: performTouchAndGo)
            .accessibilityIdentifier("cockpit.touchAndGo")
    }

    /// Touch-and-goes and, if any, go-arounds, in the font the caller sets.
    @ViewBuilder
    private var circuitCounts: some View {
        if let flight = appState.currentFlight {
            HStack(spacing: 6) {
                Label("\(flight.touchAndGoCount)", systemImage: "arrow.triangle.2.circlepath")
                if flight.goAroundCount > 0 {
                    Label("\(flight.goAroundCount)", systemImage: "arrow.up.right.circle")
                }
            }
            .foregroundColor(theme.textSecondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(flight.touchAndGoCount) touch and go, \(flight.goAroundCount) go around")
        }
    }

    // These mirror the in-checklist event callbacks exactly (record + PR-07 manual-event dedup), so
    // the HUD buttons and the checklist buttons log identically — no double-counting. (v4 UI/UX Revamp)
    private func performGoAround() {
        let physicalTime = flightEventDetector.notifyManualEvent(.goAround)
        appState.recordGoAround(at: physicalTime)
        pulseActionButton = false
        pulseNextButton = false
        allItemsChecked = false
    }

    private func performTouchAndGo() {
        let physicalTime = flightEventDetector.notifyManualEvent(.touchAndGo)
        appState.recordTouchAndGo(at: physicalTime)
        pulseActionButton = false
        pulseNextButton = false
        allItemsChecked = false
    }

    private func performLanded() {
        let physicalTime = flightEventDetector.notifyManualEvent(.fullStop)
        appState.recordLanding(at: physicalTime)
        pulseActionButton = false
    }

    /// ✓ DONE: the memory check confirmed, and left where it can go on. (6.1)
    private func performMemoryDone() {
        if appState.memoryConfirmationMovesTo != nil {
            pulseNextButton = false
            pulseActionButton = false
            allItemsChecked = false
            appState.confirmMemoryCheckAndAdvance()
        } else {
            appState.confirmMemoryCheck()
        }
    }

    /// CHECK: the highlighted item is done. Shared by the iPhone's tap-to-advance and the Cockpit's
    /// CHECK button. Returns true when that finished the list with the phase's own action (ENGINE
    /// START, SHUTDOWN) still to press.
    @discardableResult
    private func checkCurrentItem() -> Bool {
        // Use the EFFECTIVE learning mode so revealed / learning-mode items are part of the step-through.
        let visibleCount = appState.activeChecklist.visibleItemCount(
            for: appState.currentPhase,
            learningMode: effectiveLearningMode
        )
        let currentIndex = appState.getHighlightedItem(for: appState.currentPhase)

        if currentIndex >= visibleCount - 1 {
            // At last item, mark it complete
            appState.markLastItemComplete(learningMode: effectiveLearningMode)
            allItemsChecked = true

            // If this phase has an action button that hasn't been pressed, pulse it first
            if currentPhaseNeedsAction {
                triggerActionButtonPulse()
                return true
            }
            // No action needed or already done, pulse NEXT button
            triggerNextButtonPulse()
        } else {
            appState.advanceHighlightedItem(learningMode: effectiveLearningMode)
        }
        return false
    }
    
    private func triggerActionButtonPulse() {
        pulseActionButton = true
        // Reset after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            pulseActionButton = false
        }
    }
    
    private func triggerNextButtonPulse() {
        pulseNextButton = true
        // Reset after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            pulseNextButton = false
        }
    }

    // MARK: - Abandon Flight Long Press

    /// Hold the aircraft name this long to abandon the flight.
    private static let abandonHoldDuration: TimeInterval = 1.5

    /// Creates an airplane identifier section with long press to abandon gesture
    /// Both the airplane icon and the call sign are tappable. `stacked` (the Cockpit) puts the circuit
    /// caption and counts under the registration instead of beside it: in portrait the header row had no
    /// room for them, and cut "(for circuits)" short. (on-device review #2)
    private func abandonableAircraftIdentifier(iconSize: CGFloat, isCompact: Bool, stacked: Bool = false,
                                               circuitCaption: Bool = true) -> some View {
        HStack(spacing: isCompact ? 4 : 8) {
            // Progress ring behind the icon. The ring footprint is RESERVED at all times (fixed frame)
            // so it appearing on press-and-hold doesn't enlarge the icon and shift the top bar. (v4 UI/UX Revamp fix)
            ZStack {
                // Always in the tree, so the sweep animates from 0 the moment the hold starts.
                Circle()
                    .stroke(theme.danger.opacity(0.3), lineWidth: isCompact ? 2 : 3)
                    .opacity(isHoldingAbandon ? 1 : 0)
                Circle()
                    .trim(from: 0, to: abandonFlightProgress)
                    .stroke(theme.danger, style: StrokeStyle(lineWidth: isCompact ? 2 : 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Image(systemName: "airplane")
                    .font(.aero(size: iconSize))
                    .foregroundColor(isHoldingAbandon ? theme.danger : theme.action)
            }
            .frame(width: iconSize + (isCompact ? 8 : 12), height: iconSize + (isCompact ? 8 : 12))

            if stacked {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.activeChecklist.registration)
                        .font(.headerText)
                        .foregroundColor(isHoldingAbandon ? theme.danger : theme.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                    if appState.isCircuitMode {
                        HStack(spacing: 8) {
                            if circuitCaption {
                                Text(L10n.Flight.forCircuits)
                                    .foregroundColor(theme.warning)
                            }
                            circuitCounts
                        }
                        .font(.aero(size: 16, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                    }
                }
            } else {
                HStack(spacing: 4) {
                    Text(appState.activeChecklist.registration)
                        .font(isCompact ? .aero(size: 14, weight: .semibold) : .headerText)
                        .foregroundColor(isHoldingAbandon ? theme.danger : theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)   // never wrap the registration; shrink slightly if tight

                    // Circuit mode indicator
                    if appState.isCircuitMode {
                        Text(L10n.Flight.forCircuits)
                            .font(isCompact ? .aero(size: 11, weight: .medium) : .aero(size: 13, weight: .medium))
                            .foregroundColor(theme.warning)
                            .lineLimit(1)
                    }
                }
            }
        }
        .contentShape(Rectangle()) // Make entire area tappable
        // The ring sweeps from the moment the finger lands, over the whole hold; the alert comes at
        // the end. It used to step a timer, which showed almost nothing at first. (on-device review #1)
        .onLongPressGesture(minimumDuration: Self.abandonHoldDuration, maximumDistance: 40) {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            isHoldingAbandon = false
            abandonFlightProgress = 0
            showAbandonFlightAlert = true
        } onPressingChanged: { pressing in
            isHoldingAbandon = pressing
            withAnimation(.linear(duration: pressing ? Self.abandonHoldDuration : 0.2)) {
                abandonFlightProgress = pressing ? 1 : 0
            }
        }
    }

    // MARK: - HUD reference popups (Pattern B)

    /// Open a reference popup: a bottom drawer over the Cockpit (iPad) or the HUD (iPhone). Animated so
    /// the drawer slides up.
    private func openReference(_ reference: HUDReference) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            activeReference = reference
        }
    }

    private func closeReference() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            activeReference = nil
        }
    }

    /// Height above the departure field (the flight's first recorded altitude is the field elevation),
    /// used to switch the climb V-speed highlight Vx → Vy at 300 ft AGL. nil until both fixes exist.
    private var currentAGLFeet: Double? {
        guard let groundMeters = appState.currentFlight?.gpsTrack.first?.altitude else { return nil }
        return locationManager.currentAltitudeFeet - groundMeters * 3.28084
    }

    /// The bottom-drawer presentation of a reference popup: a dimming scrim
    /// (tap to dismiss) with the cockpit-themed panel rising from the bottom, leaving the instruments
    /// and current checklist item visible above. (v4 UI/UX Revamp)
    /// `vSpeedsMaxHeight`: V-SPEEDS grows rather than scroll (V-SPEEDS proposal, D7); the densest
    /// checklist in landscape needs about two thirds of the screen.
    @ViewBuilder
    private func referenceDrawerOverlay(maxHeight: CGFloat, kneeboard: Bool = false, landscape: Bool = false,
                                        vSpeedsMaxHeight: CGFloat? = nil) -> some View {
        if let reference = activeReference {
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeReference() }
                    .transition(.opacity)

                HUDReferencePanel(
                    reference: reference,
                    presentation: .drawer,
                    kneeboard: kneeboard,
                    landscape: landscape,
                    locationManager: locationManager,
                    briefingContext: reference.isBriefing ? briefingContext : nil,
                    aglFeet: reference == .vSpeeds ? currentAGLFeet : nil,
                    onClose: closeReference
                )
                // Bottom-aligned: a frame with a max height takes the whole cap and would centre a
                // shorter drawer in it, floating above the thumb bar.
                .frame(maxHeight: reference == .vSpeeds ? (vSpeedsMaxHeight ?? maxHeight) : maxHeight, alignment: .bottom)
                .transition(.move(edge: .bottom))
            }
        }
    }

    /// Where the flight ended: the aerodrome block-on detection found, else the one nearest the last
    /// fix. Nil when neither is known (no airport data, no track). (v5.1)
    private func landedAerodrome(_ flight: Flight) -> TripPlanner.Aerodrome? {
        if let ident = flight.arrivalAirportIdent, let airport = airportDataService.findAirport(byIdent: ident) {
            return airportDataService.planningAerodrome(airport)
        }
        guard let last = flight.gpsTrack.last else { return nil }
        return airportDataService.nearestAirport(to: last.coordinate, maxDistanceNm: 3, types: AirportType.fixedWing)
            .map(airportDataService.planningAerodrome)
    }

    // MARK: - Flight Info Panel
    
    private var gpsStatusColor: Color {
        // PR-01: an ACTIVE flight that isn't recording GPS is an alarm state (the track is being
        // lost), never a subtle dim. Dim only applies when no flight is active.
        if appState.isFlightActive && !locationManager.isTracking { return theme.danger }
        guard locationManager.isTracking else { return theme.textDim }
        switch locationManager.gpsSignalStatus {
        case .good: return theme.onTarget
        case .degraded: return .orange
        case .lost: return theme.danger
        }
    }

    /// True when this device is running the flight off a borrowed companion (iPhone) GPS fix rather
    /// than its own. (shared-GPS)
    private var isBorrowingCompanionGPS: Bool {
        companionConnectivityManager.effectiveGPSSource == .peer
    }

    /// The cockpit GPS label: "GPS", or "GPS · iPhone" when position is sourced from the paired
    /// companion. (Both verbatim — aviation abbreviation + brand — so no localization.) (shared-GPS)
    /// "GPS · SIM" while the developer option holds a simulated position. (S9-25)
    private var gpsSourceLabel: String {
        if locationManager.isSimulatingPosition { return "GPS · SIM" }
        return isBorrowingCompanionGPS ? "GPS · iPhone" : "GPS"
    }

}
// MARK: - Cockpit (v6.0 · P2)
//
// FlightView's iPad layout. The zones and the pane rule are described in `Cockpit.swift`; this is the
// part that needs FlightView's state and actions.

extension FlightView {

    /// The pane the flight suggests right now.
    private var cockpitDefaultPane: CockpitPane {
        CockpitPaneRule.defaultPane(phase: appState.currentPhase, checklistDone: appState.currentCheckIsDone,
                                    memoryCheck: appState.isMemoryCheck(appState.currentPhase))
    }

    private var cockpitPane: CockpitPane { paneChoice.pane(suggested: cockpitDefaultPane) }

    /// The check slot's way to a list still to check: the CHECKLIST pane, as a tap on the picker picks
    /// it; the map comes back after the last CHECK, when the default pane changes. (6.1)
    private func showChecklistPane() {
        cockpitPaneBinding.wrappedValue = .checklist
    }

    private var cockpitPaneBinding: Binding<CockpitPane> {
        Binding(get: { cockpitPane },
                set: { pane in paneChoice.pick(pane, suggested: cockpitDefaultPane) })
    }

    /// A leg's row on ROUTE: MAP, showing that leg. (6.2, the plan's Q7)
    private func showLeg(_ index: Int) {
        navState.showLeg(index)
        cockpitPaneBinding.wrappedValue = .map
    }

    /// `mergesReadLines`: the phone's column on its side, under 400 pt tall (`CockpitColumnRule`).
    func cockpit(layout: CockpitLayout, mergesReadLines: Bool = false) -> some View {
        Group {
            switch layout {
            case .wide, .narrow: cockpitStack(narrow: layout == .narrow)
            case .columns: cockpitColumns(mergesReadLines: mergesReadLines)
            }
        }
        .background(theme.background)
        .onChange(of: cockpitDefaultPane) { _, _ in paneChoice.suggestionChanged() }
        // NOW and NEXT on every page, CHECKLIST included, and the Watch's list. (6.2, ROUTE)
        .modifier(CockpitRadioFollower(radio: radio))
        // OFF ROUTE on every fix, whatever page shows. (6.2, MAP's chrome)
        .modifier(CockpitMapFollower(mapState: chartState))
        .environment(navState)
        .environment(radio)
        .environment(chartState)
    }

    // MARK: Frame (6.2)
    //
    // Three zones, whatever the page: the read band on top (the header, the phase bar, the strip with
    // NEXT, NOW | NEXT, and the picker; `CockpitReadBand.swift`), the page (CHECKLIST, MAP or ROUTE), and
    // the act band at the foot (`CockpitActBand`). The iPad on its side has the same frame, wider: the
    // map's side column is Plan › Map's alone now.

    /// The zones stacked, top to bottom: the iPad, and the phone in portrait (`narrow`).
    private func cockpitStack(narrow: Bool) -> some View {
        VStack(spacing: 0) {
            // No padding under the header: the phase bar's segments are a full control tall, and the
            // room around the drawn bar is theirs to the touch. (v6.0 review, B1)
            // The header and the checklist are views of their own (`SeparateView`): inline, the
            // Cockpit's value was 23 KB and its first render took 824 KB of the device's 1 MB
            // main-thread stack in a Debug build.
            SeparateView { cockpitHeader(style: narrow ? .narrow : .wide) }
                .padding(.horizontal, narrow ? 16 : 20)
                .padding(.top, narrow ? 4 : 8)
                .padding(.bottom, narrow ? 6 : 0)
                .background(theme.panel)

            // The iPad's phase bar, its segments a control tall to the touch. The phone draws it in the
            // phase button, as on its side, whose tap opens the phase list, where a phase is picked by
            // its name: its own row took 50 pt of a chart that has 220 (an iPhone 17e) since the read
            // band. (6.2, PR 4)
            if !narrow {
                phaseProgressBarView
                    .padding(.horizontal, 20)
                    .background(theme.panel)
            }

            // The read band's live rows, over every page: GS · ALT · TRK · NEXT whenever the aircraft
            // moves (Taxi to After landing), NEXT with its figures, then NOW | NEXT; on the phone, the
            // strip of three, then the next line and the NOW line. (6.2, the read band)
            SeparateView { cockpitReadRows(layout: narrow ? .narrow : .wide) }

            // 6 pt on the phone, whose chart has every point it can get (6.2, PR 4).
            cockpitPaneBar(narrow: narrow)
                .padding(.horizontal, narrow ? 12 : 16)
                .padding(.vertical, narrow ? 6 : 10)

            SeparateView { cockpitPage(layout: narrow ? .narrow : .wide) }
                .frame(maxHeight: .infinity)

            SeparateView { cockpitActBand(layout: narrow ? .narrow : .wide) }
        }
    }

    /// The page between the read band and the act band.
    @ViewBuilder
    private func cockpitPage(layout: CockpitLayout) -> some View {
        let narrow = layout == .narrow
        switch cockpitPane {
        case .checklist:
            VStack(spacing: 0) {
                // What is deferred, BRIEFING and NEXT at the top of the list, in a row whose height is
                // kept: the picker row has no room left for them. (6.2)
                cockpitChecklistChips(narrow: narrow)
                SeparateView { cockpitChecklistPane(narrow: narrow) }
            }
        case .map:
            // The chart alone since 6.2 (PR 4): the aircraft, the route, the airspace, and the chrome over
            // them (the stack, the status slot with BRIEFING, the edge arrow, the scale while zooming). The
            // next waypoint and the frequencies are in the read band, the deferred count and the SIGMETs
            // in More.
            NavigationMapView(isPresented: .constant(true), showsCloseButton: false, chrome: .cockpit(layout),
                              onDivert: { navState.openDivert($0) },
                              onOpenReference: { openReference($0) },
                              onShowRoute: { cockpitPaneBinding.wrappedValue = .route })
        case .route:
            CockpitRoutePage(layout: layout, onShowLeg: { showLeg($0) })
        }
    }

    /// The four slots under either page. (6.2)
    private func cockpitActBand(layout: CockpitLayout) -> some View {
        CockpitActBand(page: cockpitPane, layout: layout, actions: cockpitActions)
    }

    /// What the act band's buttons do that only this view can.
    private var cockpitActions: CockpitActions {
        CockpitActions(
            check: { checkCurrentItem() },
            next: { requestNextPhase() },
            memoryDone: { performMemoryDone() },
            endFlight: { showEndFlightAlert = true },
            engineStart: { performEngineStart() },
            engineStartUpdate: { performEngineStartUpdate() },
            engineShutdown: { performEngineShutdown() },
            engineShutdownUpdate: { performEngineShutdownUpdate() },
            showChecklist: { showChecklistPane() },
            showMap: { cockpitPaneBinding.wrappedValue = .map },
            showRoute: { cockpitPaneBinding.wrappedValue = .route },
            showVSpeeds: { openReference(.vSpeeds) },
            showDeferred: { showDeferredItems = true },
            pulseAction: pulseActionButton,
            nextReady: nextButtonReady)
    }

    /// A phone on its side: the page on the left at full height (the chart, the list, ROUTE), and on the
    /// right a column with everything the pilot reads and presses, the read band's in one header row, the
    /// pages' picker, the strip at 28 pt, the next line and the NOW line (one line under 400 pt tall),
    /// then the act band two by two at its foot, where the thumb is. The author's answers to the plan's Q5
    /// (the column on the right) and Q2 (compact, the in-flight sizes kept). Until 6.2 the column was on
    /// the left and the chart kept the next line and the frequencies over its top and foot. (6.2, PR 5)
    ///
    /// The column's room in an iPhone 17e's 370 pt over the home indicator: 2 over the header's 44, 4 over
    /// the picker's 46, 4 over the strip's 70, 4 over the merged line's 28, 4 over the band's 2 × 76 + 6, 2
    /// under it: 367, measured (`CockpitColumnFitTests`).
    private func cockpitColumns(mergesReadLines: Bool) -> some View {
        HStack(spacing: 0) {
            SeparateView { cockpitColumnsPage }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                cockpitColumnHead
                SeparateView { cockpitReadRows(layout: .columns, mergesLines: mergesReadLines) }
                    .padding(.top, Self.cockpitColumnGap)
                Spacer(minLength: 0)
                SeparateView { cockpitActBand(layout: .columns) }
            }
            .frame(width: Self.cockpitColumnWidth)
            .background(theme.panel.ignoresSafeArea())
            .overlay(alignment: .leading) { Rectangle().fill(theme.panelStroke).frame(width: 1) }
        }
    }

    /// The page beside the column.
    @ViewBuilder
    private var cockpitColumnsPage: some View {
        switch cockpitPane {
        case .checklist:
            VStack(spacing: 0) {
                cockpitChecklistChips(narrow: true)
                SeparateView { cockpitChecklistPane(narrow: true) }
            }
        case .map:
            NavigationMapView(isPresented: .constant(true), showsCloseButton: false, chrome: .cockpit(.columns),
                              onDivert: { navState.openDivert($0) },
                              onOpenReference: { openReference($0) },
                              onShowRoute: { cockpitPaneBinding.wrappedValue = .route })
        case .route:
            CockpitRoutePage(layout: .columns, onShowLeg: { showLeg($0) })
        }
    }

    /// The CHECKLIST page's chips, at the top of the list: what is deferred, the phase's BRIEFING, and
    /// NEXT while items are still open. The row keeps a chip's height when none shows, so the list never
    /// moves as they come and go; the full-width deferred row it replaces pushed the list down. They
    /// were in the iPad's picker row, which ROUTE's segment filled. (6.2)
    private func cockpitChecklistChips(narrow: Bool) -> some View {
        HStack(spacing: 8) {
            if appState.hasDeferredWork { deferredChip }
            cockpitBriefingChip
            cockpitNextChip
            Spacer(minLength: 0)
        }
        .frame(minHeight: CockpitType.size(kneeboard: 52, phone: 46), alignment: .leading)
        .padding(.horizontal, narrow ? 12 : 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// The column's width on a phone on its side: the longest phase name ("CHECK BEFORE ENGINE START",
    /// 250 pt at 17) beside Menu on one row, and on one line "ST-URSANNE" at 17 pt beside its ETE and NOW.
    /// The wireframe's rail was about 330 pt at 12 to 16 pt type; 402 (an iPhone 17 in portrait) until
    /// 6.2 left an iPhone 17e's chart 379 pt. (6.2, PR 5)
    static let cockpitColumnWidth: CGFloat = 370

    /// Between the column's rows, and over its header, which has no point to spare.
    static let cockpitColumnGap: CGFloat = 4
    static let cockpitColumnTop: CGFloat = 2
    /// The column's header row: the phase button's 44 pt (its name, its bar), Menu as tall.
    static let cockpitColumnHeaderHeight: CGFloat = 44

    /// The top of the column: the header on one row (the phase with its bar inside the button, Menu) and
    /// CHECKLIST · MAP · ROUTE.
    ///
    /// The header's two rows (the aircraft, the flight time, GPS and Menu over the phase) took 46 pt of a
    /// column that holds the act band two by two in 370. GPS says itself in the strip's flags, in MAP's
    /// status slot and in Menu; the flight time, and the hold on the aircraft that abandons the flight, are
    /// the portrait's. (6.2, PR 5)
    private var cockpitColumnHead: some View {
        VStack(spacing: 0) {
            SeparateView { cockpitHeader(style: .column) }
                .padding(.horizontal, 12)
                .padding(.top, Self.cockpitColumnTop)
            cockpitPickerRow(compact: true)
                .padding(.horizontal, 12)
                .padding(.top, Self.cockpitColumnGap)
        }
    }

    /// The strip's values, in the phases that show it (`CockpitStripRule`).
    private var stripReading: StripReading? {
        guard CockpitStripRule.showsStrip(in: appState.currentPhase) else { return nil }
        return StripReading(speedKnots: locationManager.displaySpeedKnots,
                            targetSpeed: appState.activeChecklist.targetSpeed(for: appState.currentPhase),
                            gpsSignalStatus: locationManager.gpsSignalStatus,
                            altitudeFeet: locationManager.currentAltitudeFeet,
                            headingDegrees: locationManager.currentCourseDegrees,
                            verticalSpeedFPM: locationManager.verticalSpeedFpm)
    }

    /// The read band's rows under the phase bar (`CockpitReadRows`): the strip, NEXT and its figures (the
    /// leg's ETE is the DEST line's first term, `NextLegLive`), NOW and NEXT from the Cockpit's one radio.
    /// A tap on NEXT or on a frequency opens ROUTE, where every leg and frequency is. (6.2)
    private func cockpitReadRows(layout: CockpitLayout, mergesLines: Bool = false) -> some View {
        CockpitReadRows(
            layout: layout,
            mergesLines: mergesLines,
            strip: stripReading,
            next: NextFigures(plan: flightPlanManager.activeFlightPlan, location: locationManager.currentLocation,
                              groundSpeedKnots: locationManager.currentSpeedKnots),
            now: radio.now,
            nextFrequency: radio.next,
            onShowRoute: { cockpitPaneBinding.wrappedValue = .route },
            // V-SPEEDS from GS, where the phone's picker row has no room for its chip. (6.2, Q8)
            onSpeedTap: { openReference(.vSpeeds) })
    }

    // MARK: Header

    /// `column`: the phone on its side, one row: the phase with its bar inside the button, and Menu.
    enum CockpitHeaderStyle { case wide, narrow, column }

    /// Aircraft, phase and its place in the flight, flight time, GPS, Menu. Everything a glance at the
    /// top needs, and nothing in the stage colours the old badge used: colour means something in flight.
    ///
    /// `wide` (the iPad): one row. Portrait is tight (about 780 pt for all of it), so the aircraft stacks
    /// its circuit line under the registration, the time, GPS and Menu keep their size, and the phase
    /// takes what's left, wrapping between words ("CHECK BEFORE / ENGINE START"), never inside one.
    /// (on-device review #2)
    /// `narrow` (the phone in portrait): the phase gets a line of its own under the rest, instead of a
    /// badge shrunk to about 7 pt, with the progress bar drawn in the phase button (6.2, PR 4). (iPhone
    /// pass; 6.1)
    /// `column` (the phone on its side): one row, the phase button with its bar and Menu, every phase's
    /// name at 17 pt; the bar says where the phase sits, so the "10/16" goes to VoiceOver. (6.2, PR 5)
    @ViewBuilder
    private func cockpitHeader(style: CockpitHeaderStyle) -> some View {
        switch style {
        case .wide:
            HStack(spacing: 14) {
                abandonableAircraftIdentifier(iconSize: 20, isCompact: false, stacked: true)
                cockpitPhaseButton(fillsWidth: false)
                    .layoutPriority(1)   // one line whenever the row has room; the spacer gets what's left
                Spacer(minLength: 8)
                cockpitCompanionIndicator
                cockpitFlightTime
                cockpitGPSButton(labelled: true)
                cockpitMenuButton()
            }
        case .column:
            HStack(spacing: 8) {
                cockpitPhaseButton(fillsWidth: true, showsProgress: true, showsCount: false)
                cockpitMenuButton(.stacked, minHeight: Self.cockpitColumnHeaderHeight)
            }
        case .narrow:
            VStack(spacing: 6) {
                // Richest first, down to one that always fits. A row wider than the screen doesn't
                // just clip: it widens the whole Cockpit, which then sits off centre with the Menu
                // past the edge. With the Menu labelled beside its icon, an iPhone 17's row was
                // 16 pt too wide. (round 6, I-06)
                ViewThatFits(in: .horizontal) {
                    cockpitHeaderTopRow(gpsLabelled: true, menu: .labelled)
                    cockpitHeaderTopRow(gpsLabelled: false, menu: .labelled)
                    cockpitHeaderTopRow(gpsLabelled: false, menu: .stacked)
                    cockpitHeaderTopRow(gpsLabelled: false, menu: .stacked, circuitCaption: false)
                    cockpitHeaderTopRow(gpsLabelled: false, menu: .icon, circuitCaption: false)
                }
                cockpitPhaseButton(fillsWidth: true, showsProgress: true)
            }
        }
    }

    /// `circuitCaption`: "for circuits" beside the counts under the registration. Without it the counts
    /// stay; the progress bar already says circuits by skipping cruise and descent.
    private func cockpitHeaderTopRow(gpsLabelled: Bool, menu: CockpitMenuStyle,
                                     circuitCaption: Bool = true) -> some View {
        HStack(spacing: menu == .labelled ? 10 : 8) {
            abandonableAircraftIdentifier(iconSize: 18, isCompact: false, stacked: true,
                                          circuitCaption: circuitCaption)
            Spacer(minLength: menu == .labelled ? 8 : 4)
            cockpitCompanionIndicator
            cockpitFlightTime
            cockpitGPSButton(labelled: gpsLabelled)
            cockpitMenuButton(menu)
        }
    }

    /// `showsProgress`: the progress bar drawn under the phase, inside the button (the phone). `showsCount`:
    /// "10/16" beside the name, which the column on its side leaves to the bar.
    private func cockpitPhaseButton(fillsWidth: Bool, showsProgress: Bool = false, showsCount: Bool = true) -> some View {
        Button(action: { showPhaseSelector = true }) {
            VStack(spacing: 4) {
                cockpitPhaseTitleRow(fillsWidth: fillsWidth, showsCount: showsCount)
                if showsProgress {
                    phaseProgressBar(interactive: false)
                }
            }
            .padding(.horizontal, showsCount ? 14 : 10)
            .padding(.vertical, 4)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: CockpitType.size(kneeboard: 48, phone: 44))
            .background(Capsule().fill(theme.textPrimary.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(showsCount ? "" : phaseCount)
        .accessibilityHint(L10n.Sheet.selectPhase)
        // The UI tests' way to the phase on the phone, whose bar has no segment to read since 6.2 (PR 4):
        // "cockpit.phase.climb". An identifier, never read out.
        .accessibilityIdentifier("cockpit.phase.\(appState.currentPhase)")
    }

    /// Where the phase sits in the flight: "10/16".
    private var phaseCount: String {
        "\(appState.currentPhase.rawValue + 1)/\(ChecklistPhase.allCases.count)"
    }

    /// The phase and where it sits in the flight ("10/16").
    private func cockpitPhaseTitleRow(fillsWidth: Bool, showsCount: Bool = true) -> some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                // The iPad's one-row header holds two lines' height whether the title takes one or
                // two: it wrapped when the Companion's iPhone mark came or the GPS label grew (and on
                // the longer phase names), and every row under the header moved 5 pt. (6.1.0)
                if !fillsWidth {
                    Text(verbatim: "A\nA")
                        .font(.aero(size: CockpitType.label, weight: .bold))
                        .hidden()
                        .accessibilityHidden(true)
                }
                // The phone's on one line (6.2, PR 4): the button holds the phase bar under it now, and a
                // title wrapping on a narrow phone ("CHECK BEFORE ENGINE START" on an iPhone SE) would move
                // everything under the header. It needs 99.6 % of its size there; every other phone, 100.
                Text(appState.currentPhase.shortTitle)
                    .font(.aero(size: CockpitType.label, weight: .bold))
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(fillsWidth ? 1 : 2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if fillsWidth { Spacer(minLength: showsCount ? 8 : 0) }
            if showsCount {
                Text(phaseCount)
                    .font(.aero(size: CockpitType.label, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var cockpitCompanionIndicator: some View {
        if companionConnectivityManager.connectionState == .connected {
            HStack(spacing: 4) {
                Image(systemName: "iphone").font(.aero(size: 16))
                StatusIndicator(.active, size: 8)
            }
            .foregroundColor(theme.onTarget)
        }
    }

    private var cockpitFlightTime: some View {
        FlightDurationText(
            startTime: appState.engineStartTime ?? appState.currentFlight?.startTime,
            font: .aero(size: CockpitType.size(kneeboard: CockpitType.row, phone: CockpitType.label),
                        weight: .bold, design: .monospaced),
            color: theme.textPrimary
        )
        .fixedSize()
    }

    private func cockpitGPSButton(labelled: Bool) -> some View {
        Button(action: { openReference(.gps) }) {
            HStack(spacing: 6) {
                Image(systemName: "location.fill").font(.aero(size: 16))
                if labelled {
                    Text(gpsSourceLabel).font(.aero(size: CockpitType.label, weight: .semibold))
                }
            }
            .foregroundColor(gpsStatusColor)
            // The Menu's height beside it on the phone, where its column on its side has no point to spare.
            .frame(minWidth: 44, minHeight: CockpitType.size(kneeboard: 48, phone: 46))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(isBorrowingCompanionGPS ? L10n.GPS.sourceCompanion : L10n.GPS.status)
    }

    /// The Menu button's shapes, widest first: the name beside the icon, the name under it (a phone's
    /// header), the icon alone (only when nothing else fits).
    enum CockpitMenuStyle { case labelled, stacked, icon }

    /// Named: the grey gear gave no hint that the display mode was inside. (review B7) `minHeight`: the
    /// header's, 44 pt in the phone's column on its side.
    private func cockpitMenuButton(_ style: CockpitMenuStyle = .labelled, minHeight: CGFloat? = nil) -> some View {
        Button(action: { showFlightInfo = true }) {
            Group {
                switch style {
                case .labelled:
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3").font(.aero(size: 18, weight: .semibold))
                        Text(L10n.Cockpit.menu).font(.aero(size: CockpitType.label, weight: .bold))
                    }
                case .stacked:
                    VStack(spacing: 1) {
                        Image(systemName: "slider.horizontal.3").font(.aero(size: 16, weight: .semibold))
                        // The Cockpit's label size, as the labelled variant beside it; 14 pt was under
                        // the phone's scale on every mid-size iPhone in portrait. (v6.0 review)
                        Text(L10n.Cockpit.menu).font(.aero(size: CockpitType.label, weight: .bold))
                    }
                case .icon:
                    Image(systemName: "slider.horizontal.3").font(.aero(size: 18, weight: .semibold))
                }
            }
            .foregroundColor(theme.action)
            .padding(.horizontal, style == .labelled ? CockpitType.size(kneeboard: 16, phone: 12) : 10)
            .frame(minHeight: minHeight ?? CockpitType.size(kneeboard: 52, phone: 46))
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.action.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.action.opacity(0.45), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityIdentifier("cockpit.menu")
        .accessibilityLabel(L10n.Cockpit.menu)
    }

    // MARK: Pane bar

    /// CHECKLIST · MAP · ROUTE, and V-SPEEDS beside it on the iPad. The chips that were beside it there
    /// (what is deferred, BRIEFING, NEXT) are at the top of the CHECKLIST page since ROUTE's segment, the
    /// deferred count in More on MAP and ROUTE, BRIEFING over the chart. (6.1; 6.2)
    ///
    /// `narrow` (the phone): the three across the width, V-SPEEDS in More and behind GS. (6.2, Q8)
    @ViewBuilder
    private func cockpitPaneBar(narrow: Bool) -> some View {
        if narrow {
            cockpitPickerRow()
        } else {
            cockpitPaneBarRow
        }
    }

    /// CHECKLIST · MAP · ROUTE across the phone, in both orientations: with their icons where they fit,
    /// the words alone where they don't ("CHECKLIST · CARTE · ROUTE"). One row always: a second one took
    /// the 54 pt the phone's column on its side doesn't have, and its thumb row ran off the screen. (6.1,
    /// device check; 6.2) `compact`: the column on its side, 46 pt tall (`CockpitPanePicker.compact`).
    private func cockpitPickerRow(compact: Bool = false) -> some View {
        ViewThatFits(in: .horizontal) {
            CockpitPanePicker(selection: cockpitPaneBinding, fillsWidth: true, compact: compact)
            CockpitPanePicker(selection: cockpitPaneBinding, fillsWidth: true, showsIcons: false, compact: compact)
        }
    }

    private var cockpitVSpeedsChip: some View {
        CockpitChip(title: "V-SPEEDS", icon: "speedometer") { openReference(.vSpeeds) }
    }

    @ViewBuilder
    private var cockpitBriefingChip: some View {
        if let briefing = appState.currentPhase.briefingType {
            // BRIEFING stays in English in FR, like the other aviation terms.
            CockpitChip(title: "BRIEFING", icon: briefing == .departure ? "airplane.departure" : "airplane.arrival") {
                openReference(briefing == .departure ? .departureBriefing : .approachBriefing)
            }
        }
    }

    @ViewBuilder
    private var cockpitNextChip: some View {
        if cockpitPane == .checklist, !cockpitChecklistDone,
           let next = appState.currentPhase.nextNavigable(circuitMode: appState.isCircuitMode) {
            // Leaving with items open goes through the review of what's left. (v6.0 · B2)
            // Just NEXT: phase titles run to "CHECK BEFORE ENGINE START". The name is on the big
            // NEXT button once the list is done, and in the VoiceOver label here.
            CockpitChip(title: L10n.Button.next, icon: "forward.end") { requestNextPhase() }
                .accessibilityIdentifier("cockpit.nextChip")
                .accessibilityLabel(L10n.Cockpit.nextPhaseA11y(next.title))
        }
    }

    /// What is deferred: checks and items together, in one count; amber, a caution. It opens the list.
    private var deferredChip: some View {
        CockpitChip(title: "\(appState.deferredChecks.count + appState.deferredItemCount)",
                    icon: "clock.arrow.circlepath", tint: theme.warning) {
            showDeferredItems = true
        }
        .accessibilityLabel(L10n.Deferred.summary(checks: appState.deferredChecks.count,
                                                  items: appState.deferredItemCount))
    }

    /// The iPad's: the three pages, then V-SPEEDS at the right, in every phase.
    private var cockpitPaneBarRow: some View {
        HStack(spacing: 10) {
            CockpitPanePicker(selection: cockpitPaneBinding)
            Spacer(minLength: 8)
            cockpitVSpeedsChip
        }
    }

    // MARK: Checklist pane

    /// The check worked through, or, a memory check, confirmed. (6.1)
    private var cockpitChecklistDone: Bool {
        appState.currentCheckIsDone
    }

    /// A tap on the list checks the item too, on the phone, as it always did there; CHECK is the same
    /// action in a place that doesn't move. The iPad checks with CHECK only. (iPhone pass, I2)
    private var listTapChecksItem: Bool {
        CockpitScale.current == .phone && appState.settings.stepByStepHighlighting && !cockpitChecklistDone
    }

    /// The list, the undo toast over its foot and the event row. The act band is the frame's, under it;
    /// the chips over it (`cockpitChecklistChips`). (6.2)
    private func cockpitChecklistPane(narrow: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { listProxy in
            ScrollView {
                VStack(spacing: 0) {
                    ChecklistView(
            phase: appState.currentPhase,
            activeChecklist: appState.activeChecklist,
            onEngineStart: { performEngineStart() },
            onEngineStartUpdate: { performEngineStartUpdate() },
            onEngineShutdown: { performEngineShutdown() },
            onEngineShutdownUpdate: { performEngineShutdownUpdate() },
            onGoAround: {
                // PR-07: notify first so the detector suppresses a duplicate
                // auto-detect; it returns the physical timestamp (approach low
                // point) when it knows one, so the record carries the real time.
                let physicalTime = flightEventDetector.notifyManualEvent(.goAround)
                appState.recordGoAround(at: physicalTime)
                // Reset UI state since we're jumping to a new phase
                pulseActionButton = false
                pulseNextButton = false
                allItemsChecked = false
            },
            onTouchAndGo: {
                let physicalTime = flightEventDetector.notifyManualEvent(.touchAndGo) // PR-07
                appState.recordTouchAndGo(at: physicalTime)
                // Reset UI state since we're jumping to a new phase
                pulseActionButton = false
                pulseNextButton = false
                allItemsChecked = false
            },
            onFullStop: {
                let physicalTime = flightEventDetector.notifyManualEvent(.fullStop) // PR-07
                appState.recordFullStop(at: physicalTime)
                // Reset UI state since we're jumping to a new phase
                pulseActionButton = false
                pulseNextButton = false
                allItemsChecked = false
            },
            onLanded: {
                // PR-07: notify the detector so it doesn't emit a duplicate full stop
                // ~40 s later (dismissFullStop only cleared an already-pending event;
                // a LANDED tap while vacating fires the pending full stop afterwards).
                // The detector returns the real touchdown time when a rollout is in
                // progress — that, not "now minus a minute", becomes the landing time.
                let physicalTime = flightEventDetector.notifyManualEvent(.fullStop)
                appState.recordLanding(at: physicalTime)
                pulseActionButton = false
                // Now pulse NEXT button if all items checked
                if allItemsChecked {
                    triggerNextButtonPulse()
                }
            },
            onLandedUpdate: {
                appState.updateLandingTime()
            },
            onBriefingTap: { briefingType in
                switch briefingType {
                case .departure:
                    openReference(.departureBriefing)
                case .approach:
                    openReference(.approachBriefing)
                }
            },
            // CHECK in the thumb bar advances; the list itself only reads. (v6.0 · P2, B1)
            onTapToAdvance: nil,
            engineStartTime: appState.formattedEngineStartTime,
            landingTime: appState.formattedLandingTime,
            engineShutdownTime: appState.formattedEngineShutdownTime,
            goAroundCount: appState.currentFlight?.goAroundCount ?? 0,
            touchAndGoCount: appState.currentFlight?.touchAndGoCount ?? 0,
            fullStopCount: appState.currentFlight?.fullStopCount ?? 0,
            stepByStepEnabled: appState.settings.stepByStepHighlighting,
            learningModeEnabled: appState.settings.learningMode,
            highlightedItemIndex: appState.getHighlightedItem(for: appState.currentPhase),
            pulseActionButton: pulseActionButton,
            checklistLanguage: appState.settings.checklistLanguage.resolvedLanguage,
            hudMode: true,
            engineHourStart: appState.settings.logEngineHours ? appState.currentFlight?.engineHourStart : nil,
            engineHourEnd: appState.settings.logEngineHours ? appState.currentFlight?.engineHourEnd : nil,
            engineHourStartInputFormat: appState.currentFlight?.engineHourStartInputFormat,
            engineHourEndInputFormat: appState.currentFlight?.engineHourEndInputFormat,
            onEditEngineHourStart: {
                if let prevStart = appState.currentFlight?.engineHourStart {
                    let prevFormat = appState.currentFlight?.engineHourStartInputFormat ?? "decimal"
                    hourMeterStartInitialValue = prevFormat == "time"
                        ? Flight.formatHoursTime(prevStart)
                        : Flight.formatHoursDecimal(prevStart)
                } else {
                    hourMeterStartInitialValue = ""
                }
                showHourMeterStart = true
            },
            onEditEngineHourEnd: {
                if let prevEnd = appState.currentFlight?.engineHourEnd {
                    let prevFormat = appState.currentFlight?.engineHourEndInputFormat ?? "decimal"
                    hourMeterStopInitialValue = prevFormat == "time"
                        ? Flight.formatHoursTime(prevEnd)
                        : Flight.formatHoursDecimal(prevEnd)
                } else {
                    hourMeterStopInitialValue = ""
                }
                showHourMeterStop = true
            },
            promptsEngineHours: appState.settings.logEngineHours,
            deferredItemIds: appState.currentPhaseDeferredIds,
            onToggleItem: appState.settings.stepByStepHighlighting
                ? { appState.toggleItem(at: $0) } : nil,
            awaitsMemoryConfirmation: appState.currentCheckAwaitsConfirmation,
            hiddenItemsRevealed: hiddenItemsRevealed
        )
                    .padding(narrow ? 14 : 24)
                }
                .modifier(TapToCheck(enabled: CockpitScale.current == .phone) {
                    if listTapChecksItem { checkCurrentItem() }
                })
            }
            .background(theme.background)
            // Open on the current item: on the phone, a few checked rows are enough to push it below
            // the fold. (iPhone pass)
            .onAppear {
                listProxy.scrollTo(appState.getHighlightedItem(for: appState.currentPhase),
                                   anchor: UnitPoint(x: 0.5, y: 0.12))
            }
            // The check slot in the act band, on this page: the current item into view. (6.2, Q11)
            .onChange(of: navState.checklistScrollRequest) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    listProxy.scrollTo(appState.getHighlightedItem(for: appState.currentPhase),
                                       anchor: UnitPoint(x: 0.5, y: 0.12))
                }
            }
            }
            // A waypoint the flight marked on its own, offered back over the foot of the list: never
            // over the event buttons or the act band, and never in the layout. The MAP page shows it
            // on the map. (v6.0.1)
            .overlay(alignment: .bottom) { AutoMarkUndoToast(narrow: narrow) }

            // Hold-to-confirm GO-AROUND / T&G / LANDED in the phases they belong to (a tap in circuits).
            eventActionsRow(kneeboard: true)
        }
    }
}

/// The phone's tap on the checklist: it checks the highlighted item, as it always did there. The iPad
/// checks with CHECK only, so it gets no gesture at all. (iPhone pass, I2)
private struct TapToCheck: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
        } else {
            content
        }
    }
}

// MARK: - Phase Row Button

/// A compact segmented phase progress bar for the HUD top region: one segment per phase, colored by
/// completion status, the current phase taller + gold. Tapping a segment jumps to that phase — this is
/// the back/forward navigation in the revamped HUD (replacing the PREV button and the phase list).
/// (v4 UI/UX Revamp)
struct PhaseProgressBar: View {
    @Environment(\.cockpitTheme) private var theme
    let phases: [ChecklistPhase]
    let currentPhase: ChecklistPhase
    let status: (ChecklistPhase) -> PhaseCompletionStatus
    let onSelect: (ChecklistPhase) -> Void
    var isCircuitMode: Bool = false
    /// When true, the Cruise segment turns amber: FREDA is due. (v4 UI/UX Revamp; FREDA since 6.1)
    var fredaDue: Bool = false
    /// The current check is owed (the flight moved past it open): its segment amber, as FREDA due. (6.1)
    var currentOwed: Bool = false
    /// How tall a segment is to the touch; the bar is drawn centred in it.
    var hitHeight: CGFloat = CockpitTarget.control
    /// False: the bar drawn only, its own height, no segment to touch (`drawnBar`).
    var interactive: Bool = true

    /// The pattern phases that repeat each lap in circuit mode. Contiguous in the visible list since
    /// cruise/descent are filtered out, so the bracket draws as one continuous span. (round 6)
    private var loopPhases: [ChecklistPhase] {
        guard isCircuitMode else { return [] }
        return phases.filter { $0 == .climb || $0 == .approach || $0 == .landing }
    }

    private var loopMiddle: ChecklistPhase? {
        loopPhases.isEmpty ? nil : loopPhases[loopPhases.count / 2]
    }

    var body: some View {
        if interactive {
            touchBar
        } else {
            drawnBar
        }
    }

    /// The bar drawn only, 8 pt tall: inside the phase button of the phone's column on its side, whose
    /// tap opens the phase list, where a full control's height for its segments left the column too
    /// tall for the screen (6.1, device check). Without the circuit bracket, which needs the room above
    /// the bar: the header says circuits under the registration, and the bar by skipping cruise and
    /// descent. VoiceOver reads the phase from the button.
    private var drawnBar: some View {
        HStack(spacing: 3) {
            ForEach(phases, id: \.self) { phase in
                let isCurrent = phase == currentPhase
                segment(for: phase, isCurrent: isCurrent)
                    .frame(height: isCurrent ? 8 : 5)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private var touchBar: some View {
        HStack(spacing: 3) {
            ForEach(phases, id: \.self) { phase in
                let isCurrent = phase == currentPhase
                Button { onSelect(phase) } label: {
                    segment(for: phase, isCurrent: isCurrent)
                        .frame(height: isCurrent ? 8 : 5)
                        .frame(maxWidth: .infinity)
                        // The bar DRAWS at 5–8 pt; its segments are a full Cockpit control tall
                        // (`CockpitTarget.control`, 64 pt on the kneeboard, 50 on the phone).
                        //
                        // This is not cosmetic. Tapping a segment calls `goToPhase`, and a forward
                        // jump marks every phase it passes as skipped and defers what they hold,
                        // without asking, by design: a deliberate jump should not nag. At 5 pt that
                        // made an ACCIDENTAL jump likely, and in turbulence a mis-tap quietly marked
                        // checklist phases skipped. (UX-10)
                        //
                        // The segments used to reach about 45 pt by growing their touch region 20 pt
                        // over their neighbours without growing the layout. That was still well
                        // under the Cockpit's scale, and the 20 pt above landed on the header: a tap
                        // low on the phase name jumped to a phase instead. The height is now real
                        // layout, so the target is the Cockpit's size and overlaps nothing.
                        // (v6.0 review, B1)
                        .frame(height: hitHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("phaseBar.\(phase)")
                .accessibilityLabel(phase.shortTitle)
                .accessibilityValue(accessibilityStatus(for: phase))
                .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
            }
        }
        // The circuit bracket sits just over the drawn bar, inside the segments' touch height, and
        // lets taps through to them.
        .overlay {
            if !loopPhases.isEmpty {
                circuitBracket
                    .offset(y: -(8 / 2 + 3 + 9 / 2))
                    .allowsHitTesting(false)
            }
        }
    }

    /// A repeat (↻) bracket over the looping pattern segments, so the circuit cycle reads at a glance.
    /// Aligns to the segments below (same spacing + equal-width cells); a leading/trailing tick encloses
    /// the span and the ↻ badge sits at its centre. (round 6)
    private var circuitBracket: some View {
        HStack(spacing: 3) {
            ForEach(phases, id: \.self) { phase in
                ZStack {
                    if loopPhases.contains(phase) {
                        Rectangle().fill(theme.info).frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    if phase == loopPhases.first {
                        Rectangle().fill(theme.info).frame(width: 2, height: 7)
                    }
                }
                .overlay(alignment: .trailing) {
                    if phase == loopPhases.last {
                        Rectangle().fill(theme.info).frame(width: 2, height: 7)
                    }
                }
                .overlay {
                    if phase == loopMiddle {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.aero(size: 9, weight: .bold))
                            .foregroundColor(theme.info)
                            .padding(.horizontal, 3)
                            .background(theme.panel)
                    }
                }
            }
        }
        .frame(height: 9)
        .accessibilityLabel("Circuit pattern repeats from climb to landing")
    }

    /// Spoken status for a segment. Six states are drawn as six FILL COLOURS and nothing else —
    /// green completed, orange skipped, red missing-action, amber cruise-check-due, two greys — so
    /// on a 5 pt bar the entire meaning is carried by colour. That fails VoiceOver outright, and
    /// fails the ~8% of male pilots with a colour vision deficiency for whom the green/orange/red
    /// triple is the hardest possible palette. HIG: "Convey information with more than color
    /// alone." (UX-10)
    private func accessibilityStatus(for phase: ChecklistPhase) -> String {
        Self.spokenStatus(of: phase, current: currentPhase, status: status(phase), fredaDue: fredaDue,
                          currentOwed: currentOwed)
    }

    /// A phase's status in words: the bar's segment and the phase list's row say the same. (6.2, PR 4)
    static func spokenStatus(of phase: ChecklistPhase, current currentPhase: ChecklistPhase,
                             status: PhaseCompletionStatus, fredaDue: Bool, currentOwed: Bool) -> String {
        if phase == .cruise && phase == currentPhase && fredaDue {
            return L10n.Accessibility.phaseFredaDue
        }
        if phase == currentPhase && currentOwed { return L10n.Accessibility.phaseOwed }
        switch status {
        case .completed:     return L10n.Accessibility.phaseCompleted
        case .doneFromMemory: return L10n.Accessibility.phaseDoneFromMemory
        case .skipped:       return L10n.Accessibility.phaseSkipped
        case .missingAction: return L10n.Accessibility.phaseMissingAction
        case .empty:         return L10n.Accessibility.phaseNothingToDo
        case .notStarted:    return L10n.Accessibility.phaseNotStarted
        case .confirmedAfterLanding: return L10n.Accessibility.phaseConfirmedAfterLanding
        case .notSure:       return L10n.Accessibility.phaseNotSure
        }
    }

    /// A segment: filled in its status's colour, or, for a landing check confirmed after the landing, a
    /// green OUTLINE: done, but never the solid green of a check flown before touchdown. (6.1)
    @ViewBuilder
    private func segment(for phase: ChecklistPhase, isCurrent: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        if !isCurrent && status(phase) == .confirmedAfterLanding {
            shape.fill(theme.panel).overlay(shape.strokeBorder(theme.onTarget, lineWidth: 1.5))
        } else {
            shape.fill(color(for: phase, isCurrent: isCurrent))
        }
    }

    private func color(for phase: ChecklistPhase, isCurrent: Bool) -> Color {
        if phase == .cruise && isCurrent && fredaDue { return theme.warning }
        // Owed: amber, as FREDA due, until done or skipped. (6.1)
        if isCurrent && currentOwed { return theme.warning }
        if isCurrent { return theme.action }
        switch status(phase) {
        // Done from memory is done: green, as a check worked through. (6.1)
        case .completed, .doneFromMemory: return theme.onTarget
        // Confirmed after landing is drawn as an outline (`segment`); here for anything else that asks.
        case .confirmedAfterLanding: return theme.onTarget
        // "Not sure" on the landed card: amber, with owed, for the debrief. (6.1)
        case .notSure: return theme.warning
        case .skipped: return .orange
        case .missingAction: return theme.danger
        // SEC-C36: a phase with nothing to display is NOT "done" — render it as neutral/inactive
        // so a pilot never reads green for a phase they were never shown.
        case .empty: return theme.textDim.opacity(0.5)
        case .notStarted: return theme.textDim.opacity(0.3)
        }
    }
}

// MARK: - Flight Duration Clock

/// Scoped 1 Hz clock for the flight-duration readout. The previous top-level `Timer.publish` +
/// view-owned `@State` toggle re-evaluated the entire FlightView body every second for the whole
/// flight; `TimelineView` scopes the redraw to this small subview — the same fix NavigationView's
/// `NavClockText` documents. (PERF-28)
private struct FlightDurationText: View {
    let startTime: Date?
    let font: Font
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(startTime.map { FlightClock.formattedDuration(seconds: FlightClock.now.timeIntervalSince($0)) } ?? "--:--")
                .font(font)
                .foregroundColor(color)
        }
    }
}

// MARK: - Phase Selector Sheet

struct PhaseSelectorView: View {
    /// The Cockpit's jump, so a long one asks as it does from the phase bar. (v6.0 review, J2)
    let onSelect: (ChecklistPhase) -> Void
    @Environment(\.cockpitTheme) private var theme
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            List(ChecklistPhase.allCases) { phase in
                Button(action: { onSelect(phase) }) {
                    HStack {
                        // Status indicator
                        Circle()
                            .fill(statusColor(for: phase))
                            .frame(width: 10, height: 10)
                        
                        Text(phase.title)
                            .foregroundColor(phase == appState.currentPhase ? theme.action : theme.textPrimary)
                        Spacer()
                        if phase == appState.currentPhase {
                            Image(systemName: "checkmark")
                                .foregroundColor(theme.action)
                        }
                        Text(L10n.Sheet.page(phase.pageNumber))
                            .font(.captionText)
                            .foregroundColor(theme.textSecondary)
                    }
                }
                // What the bar's segment says, which the phone's bar, drawn in its phase button, no longer
                // says on its own since 6.2 (PR 4): the status in words (the dot is colour alone), the
                // current phase selected. The UI tests read and pick a phase here on the phone.
                .accessibilityIdentifier("phaseList.\(phase)")
                .accessibilityValue(PhaseProgressBar.spokenStatus(
                    of: phase, current: appState.currentPhase, status: appState.getPhaseStatus(phase),
                    fredaDue: appState.fredaDue,
                    currentOwed: appState.cueTiming(for: appState.currentPhase) == .owed))
                .accessibilityAddTraits(phase == appState.currentPhase ? .isSelected : [])
            }
            .navigationTitle(L10n.Sheet.selectPhase)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private func statusColor(for phase: ChecklistPhase) -> Color {
        if phase == appState.currentPhase {
            return theme.action
        }
        switch appState.getPhaseStatus(phase) {
        case .completed, .doneFromMemory, .confirmedAfterLanding:
            return theme.onTarget
        case .notSure:
            return theme.warning
        case .skipped:
            return .orange
        case .missingAction:
            return theme.danger
        case .empty: // SEC-C36 — nothing to show, so not "completed"
            return theme.textDim.opacity(0.5)
        case .notStarted:
            return theme.textDim.opacity(0.3)
        }
    }
}

// MARK: - Flight Mini-Map (persistent HUD glance map)

// MARK: - Hold-to-Confirm Button

/// A press-and-hold button for consequential flight events (GO-AROUND, TOUCH & GO, FULL STOP). The
/// action fires only after a deliberate ~1 s hold — a fill sweeps to show progress and releasing
/// early cancels — so a stray cockpit touch can't trigger a go-around. VoiceOver activation fires
/// immediately (it's already a deliberate action). Optionally shows a running count. (v4 UI/UX Revamp)
struct HoldToConfirmButton: View {
    @Environment(\.cockpitTheme) private var theme
    let title: String
    let systemImage: String
    let tint: Color
    var count: Int = 0
    /// The Cockpit: kneeboard sizes, the label in the tint (a cyan control), 88 pt tall.
    /// (on-device review #1, L-02)
    var kneeboard: Bool = false
    /// Another height than the kneeboard's 88 pt: the map's bottom row, at the thumb bar's. (6.1)
    var height: CGFloat? = nil
    /// The words only, "Hold to confirm" under the title, no icon: a narrow button (the phone's map row).
    var stacked: Bool = false
    /// Two in the act band's narrow slot: "TOUCH-" over "AND-GO" at the in-flight sizes. (6.2)
    var titleLines: Int = 1
    var horizontalPadding: CGFloat? = nil
    /// What VoiceOver reads, where `title` is broken on two lines.
    var spokenTitle: String? = nil
    /// The act band's slots on the phone (`stacked`): the title and the hint set to fit the slot
    /// (`ActFace`), the title at the row size or as near as fits, the hint at the label size, smaller
    /// only where the slot has no more room ("Maintenir pour confirmer"). (6.2)
    var fitted = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    private let holdDuration: TimeInterval = 1.0

    /// The title, then "Hold to confirm", as the phone's slot sets them.
    static func fittedBlocks(title: String, titleLines: Int, hintColor: Color? = nil,
                             hint: String = L10n.ChecklistAction.holdToConfirm) -> [ActFaceBlock] {
        let label = CockpitType.label(for: .phone)
        // The hint regular, in grey: as large as the title where the slot allows, never as loud.
        return [ActFaceBlock(text: title, size: CockpitType.size(kneeboard: 24, phone: 20, scale: .phone),
                             maxLines: max(2, titleLines)),
                ActFaceBlock(text: hint, size: label, bold: false, maxLines: 3, floor: label * 0.75, color: hintColor)]
    }

    private var corner: CGFloat { kneeboard ? 18 : 12 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner).fill(tint.opacity(kneeboard ? 0.12 : 0.18))

            // Hold-progress fill.
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: corner)
                    .fill(tint.opacity(kneeboard ? 0.38 : 0.5))
                    .frame(width: geo.size.width * progress)
            }

            RoundedRectangle(cornerRadius: corner).strokeBorder(tint, lineWidth: kneeboard ? 1.5 : 2)

            if fitted {
                ActFaceText(blocks: Self.fittedBlocks(title: title, titleLines: titleLines, hintColor: theme.textSecondary))
                    .foregroundColor(tint)
                    .padding(.horizontal, horizontalPadding ?? 8)
            } else {
                HStack(spacing: kneeboard ? 12 : 8) {
                    if !stacked {
                        Image(systemName: systemImage).font(.aero(size: kneeboard ? CockpitType.row : 16, weight: .bold))
                    }
                    VStack(alignment: stacked ? .center : .leading, spacing: kneeboard ? 2 : 0) {
                        // On two lines (the act band's narrow slot), the title at the label size and the hint
                        // smaller, on two lines too ("Maintenir pour" over "confirmer"): four lines at the
                        // full sizes ran over the slot's 104 pt.
                        Text(title)
                            .font(.aero(size: kneeboard ? (titleLines > 1 ? CockpitType.label : CockpitType.row) : 14,
                                        weight: .bold))
                            .multilineTextAlignment(stacked ? .center : .leading)
                            .lineLimit(titleLines)
                            .minimumScaleFactor(stacked ? 0.55 : 0.7)
                        Text(L10n.ChecklistAction.holdToConfirm)
                            .font(.aero(size: kneeboard ? (titleLines > 1 ? CockpitType.label * 0.75 : CockpitType.label) : 9,
                                        weight: .semibold))
                            .foregroundColor(theme.textSecondary)
                            .multilineTextAlignment(stacked ? .center : .leading)
                            .lineLimit(titleLines)
                            .minimumScaleFactor(0.7)
                    }
                    if count > 0 {
                        Spacer(minLength: 4)
                        Text("\(count)").font(.aero(size: kneeboard ? CockpitType.response : 17, weight: .heavy, design: .monospaced))
                    }
                }
                .foregroundColor(kneeboard ? tint : theme.textPrimary)
                .padding(.horizontal, horizontalPadding ?? (stacked ? 8 : (kneeboard ? 16 : 12)))
            }
        }
        .frame(height: height ?? (kneeboard ? 88 : 54))
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onLongPressGesture(minimumDuration: holdDuration, maximumDistance: 60) {
            action()
            withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
        } onPressingChanged: { pressing in
            if reduceMotion {
                progress = pressing ? 1 : 0  // no sweep, but the hold is still required to fire
            } else {
                withAnimation(.linear(duration: pressing ? holdDuration : 0.2)) {
                    progress = pressing ? 1 : 0
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(count > 0 ? "\(spokenTitle ?? title), \(count)" : spokenTitle ?? title)
        .accessibilityHint(L10n.ChecklistAction.holdToConfirm)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

// MARK: - Phase Context Tile

// MARK: - Flight Info Sheet (iPhone)

/// The in-flight Menu: display first, then the in-flight options, GPS, the times recorded, and END
/// FLIGHT at any phase. It was an unlabelled grey gear called "HUD Settings". (v6.0 · B7)
struct FlightInfoSheet: View {
    @Environment(\.cockpitTheme) private var theme
    @Environment(AppState.self) private var appState
    @ObservedObject var locationManager: LocationManager
    /// Ends the flight now, whatever the phase. The sheet asks first.
    var onEndFlight: (() -> Void)? = nil
    @State private var confirmEndFlight = false
    @ObservedObject private var companion = CompanionConnectivityManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var detent: PresentationDetent = .large  // open extended

    private var gpsStatusColor: Color {
        // PR-01: a non-recording GPS during an active flight is an alarm, not a dim.
        if appState.isFlightActive && !locationManager.isTracking { return theme.danger }
        guard locationManager.isTracking else { return theme.textDim }
        switch locationManager.gpsSignalStatus {
        case .good: return theme.onTarget
        case .degraded: return .orange
        case .lost: return theme.danger
        }
    }

    private var gpsStatusText: String {
        guard locationManager.isTracking else { return L10n.GPS.signalInactive }
        switch locationManager.gpsSignalStatus {
        case .good: return L10n.GPS.signalGood
        case .degraded: return L10n.GPS.signalDegraded
        case .lost: return L10n.GPS.signalLost
        }
    }

    /// A toggle binding to an AppSettings Bool that persists on change.
    private func optionBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { appState.settings[keyPath: keyPath] },
            set: { appState.settings[keyPath: keyPath] = $0; appState.saveSettings() }
        )
    }

    /// Engine-start / line-up / landing / shutdown rows that have actually been recorded.
    private var timeEntries: [(icon: String, color: Color, label: String, value: String)] {
        var rows: [(icon: String, color: Color, label: String, value: String)] = []
        if let t = appState.formattedEngineStartTime { rows.append((icon: "engine.combustion", color: theme.onTarget, label: L10n.Time.engineStart, value: t)) }
        if let t = appState.formattedLineUpTime { rows.append((icon: "airplane.departure", color: theme.warning, label: L10n.Time.takeoff, value: t)) }
        if let t = appState.formattedLandingTime { rows.append((icon: "airplane.arrival", color: .aviationBlue, label: L10n.Time.landing, value: t)) }
        if let t = appState.formattedEngineShutdownTime { rows.append((icon: "engine.combustion.fill", color: theme.danger, label: L10n.Time.shutdown, value: t)) }
        return rows
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // Display first: it is what the Menu is opened for, in glare or at dusk. (review B7)
                    settingsCard(title: L10n.Cockpit.display) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.Settings.theme)
                                .font(.aero(size: CockpitType.label))
                                .foregroundColor(theme.textPrimary)
                            Picker(L10n.Settings.theme, selection: Binding(
                                get: { appState.settings.themePreference },
                                set: { appState.settings.themePreference = $0; appState.saveSettings() }
                            )) {
                                Text(L10n.Settings.themeAuto).tag(ThemePreference.auto)
                                Text(L10n.Settings.themeDay).tag(ThemePreference.day)
                                Text(L10n.Settings.themeNight).tag(ThemePreference.night)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        rowDivider
                        // The one place this switch is reached with the sun actually on the screen.
                        toggleRow(L10n.Settings.sunlightBoost, optionBinding(\.sunlightBoost))
                    }

                    // The most useful settings without leaving the flight.
                    settingsCard(title: L10n.Cockpit.options) {
                        toggleRow(L10n.Settings.memoryTest, Binding(
                            get: { !appState.settings.learningMode },
                            set: { appState.settings.learningMode = !$0; appState.saveSettings() }
                        ))
                        rowDivider
                        toggleRow(L10n.Settings.alwaysUseUTC, optionBinding(\.alwaysUseUTC))
                        rowDivider
                        // Companion mode only makes sense once a device is paired (pairing happens in
                        // the main Settings, not mid-flight). Show the toggle when paired; otherwise a
                        // hint pointing to Settings. (companion — HUD gating)
                        if companion.hasPairedDevices {
                            // Toggle the second screen on/off without leaving the flight (e.g. the iPad
                            // pilot brings up the iPhone wingman mid-flight). Mirrors the main settings
                            // toggle: enabling auto-connects to a paired device, disabling tears down.
                            toggleRow(L10n.Companion.enableCompanionMode, Binding(
                                get: { appState.settings.enableCompanionMode },
                                set: { on in
                                    appState.settings.enableCompanionMode = on
                                    appState.saveSettings()
                                    if on { CompanionConnectivityManager.shared.autoConnectIfReady() }
                                    else { CompanionConnectivityManager.shared.disconnect() }
                                }
                            ))
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "ipad.and.iphone")
                                    .font(.aero(size: 16))
                                    .foregroundColor(theme.textDim)
                                Text(L10n.Companion.pairInSettings)
                                    .font(.aero(size: 16))
                                    .foregroundColor(theme.textSecondary)
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    settingsCard(title: L10n.GPS.status) {
                        HStack(spacing: 10) {
                            Image(systemName: "location.fill").foregroundColor(gpsStatusColor)
                            Text(L10n.GPS.signal).font(.aero(size: CockpitType.label)).foregroundColor(theme.textPrimary)
                            Spacer()
                            Text(gpsStatusText).font(.aero(size: CockpitType.label, weight: .semibold)).foregroundColor(gpsStatusColor)
                        }
                        rowDivider
                        HStack(spacing: 10) {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                                .foregroundColor(.aviationBlue)
                            Text(L10n.GPS.pointsRecorded).font(.aero(size: CockpitType.label)).foregroundColor(theme.textPrimary)
                            Spacer()
                            Text("\(appState.currentFlight?.gpsTrack.count ?? 0)")
                                .font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(theme.textSecondary)
                        }
                    }

                    settingsCard(title: L10n.Flight.times) {
                        if timeEntries.isEmpty {
                            HStack {
                                Text(L10n.GPS.signalInactive).font(.aero(size: CockpitType.label)).foregroundColor(theme.textDim)
                                Spacer()
                            }
                        } else {
                            ForEach(Array(timeEntries.enumerated()), id: \.offset) { idx, row in
                                if idx > 0 { rowDivider }
                                HStack(spacing: 10) {
                                    Image(systemName: row.icon).foregroundColor(row.color).frame(width: 22)
                                    Text(row.label).font(.aero(size: CockpitType.label)).foregroundColor(theme.textPrimary)
                                    Spacer()
                                    Text(row.value).font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(theme.textPrimary)
                                }
                            }
                        }
                    }

                    // END FLIGHT from any phase, not only from the last one. Asked first.
                    if onEndFlight != nil {
                        Button { confirmEndFlight = true } label: {
                            VStack(spacing: 4) {
                                Label(L10n.Button.endFlight, systemImage: "flag.checkered")
                                    .font(.aero(size: CockpitType.label, weight: .bold))
                                Text(L10n.Cockpit.endFlightHint)
                                    .font(.aero(size: 15))
                                    .opacity(0.85)
                            }
                            .foregroundColor(theme.danger)
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .background(RoundedRectangle(cornerRadius: 14).stroke(theme.danger.opacity(0.6), lineWidth: 1.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("menu.endFlight")
                        .padding(.top, 8)
                        .confirmationDialog(L10n.Alert.endFlightTitle, isPresented: $confirmEndFlight,
                                            titleVisibility: .visible) {
                            Button(L10n.Button.endFlight, role: .destructive) { onEndFlight?() }
                            Button(L10n.Button.cancel, role: .cancel) { }
                        } message: {
                            Text(L10n.Alert.endFlightMessage)
                        }
                    }
                }
                .padding(16)
            }
            .background(theme.background)
            .navigationTitle(L10n.Cockpit.menu)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackground(theme.background)
        .preferredColorScheme(.dark)
    }

    // MARK: - Cockpit-styled section helpers

    @ViewBuilder
    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.aero(size: 15, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(theme.textSecondary)
            VStack(spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(theme.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.aero(size: CockpitType.label)).foregroundColor(theme.textPrimary)
            Spacer()
            Toggle("", isOn: binding).labelsHidden().tint(theme.onTarget)
        }
        .frame(minHeight: 44)
    }

    private var rowDivider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
    }
}

// MARK: - HUD reference popups (Pattern B)

/// A reference popup that pairs with the live checklist (V-speeds, GPS, briefings). In the approved
/// A+B hybrid these render as Pattern B: docked into the iPad-landscape right column (over the map),
/// or as a cockpit-themed bottom drawer on iPad portrait / iPhone. (v4 UI/UX Revamp popup redesign)
enum HUDReference: Identifiable, Equatable {
    case vSpeeds
    case gps
    case departureBriefing
    case approachBriefing

    var id: Int {
        switch self {
        case .vSpeeds: return 0
        case .gps: return 1
        case .departureBriefing: return 2
        case .approachBriefing: return 3
        }
    }

    var title: String {
        switch self {
        case .vSpeeds: return "V-SPEEDS"
        case .gps: return L10n.GPS.statusTitle
        case .departureBriefing, .approachBriefing: return "BRIEFING"
        }
    }

    var systemImage: String {
        switch self {
        case .vSpeeds: return "speedometer"
        case .gps: return "location.fill"
        case .departureBriefing: return "airplane.departure"
        case .approachBriefing: return "airplane.arrival"
        }
    }

    /// Accent for the panel's icon + back chevron. GPS is neutral so the chrome never implies a signal
    /// state (the live status colour lives inside the panel); briefings gold; v-speeds green. (round 6)
    var tint: Color {
        switch self {
        case .vSpeeds: return .aviationGreen
        case .gps: return .primaryText
        case .departureBriefing, .approachBriefing: return .primaryText   // no gold in flight (v6.0 · P5)
        }
    }

    var isBriefing: Bool { self == .departureBriefing || self == .approachBriefing }
}

/// Shared cockpit-themed container for a reference popup. The SAME view renders in two presentations:
/// `.docked` (fills the iPad-landscape right column, back-arrow header restores the map) and `.drawer`
/// (a bottom drawer with a grabber + drag-down to dismiss, for iPad portrait / iPhone). The content is
/// identical in both — only the chrome differs. (v4 UI/UX Revamp popup redesign)
struct HUDReferencePanel: View {
    @Environment(\.cockpitTheme) private var theme
    enum Presentation { case docked, drawer }

    let reference: HUDReference
    var presentation: Presentation = .docked
    /// The Cockpit: kneeboard sizes in the header, and the drawer only as tall as its content.
    var kneeboard: Bool = false
    /// The Cockpit in landscape (V-SPEEDS lays its rows out for it).
    var landscape: Bool = false
    /// V-SPEEDS as the fixed table (the iPad) or as the list (the phone keeps its list, iPhone pass I5).
    var vSpeedsTable: Bool = CockpitScale.current == .kneeboard
    @ObservedObject var locationManager: LocationManager
    var briefingContext: BriefingContext? = nil
    var aglFeet: Double? = nil
    let onClose: () -> Void

    @Environment(AppState.self) private var appState
    @EnvironmentObject var airportDataService: AirportDataService
    @State private var contentHeight: CGFloat = 0

    private var corners: AnyShape {
        switch presentation {
        case .docked: return AnyShape(RoundedRectangle(cornerRadius: 12))
        case .drawer: return AnyShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if presentation == .drawer {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 38, height: 4)
                        .padding(.vertical, 7)
                }
                header
            }
            .background(theme.panel)
            .modifier(DrawerDragDismiss(enabled: presentation == .drawer, onClose: onClose))

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            ScrollView {
                content
                    .padding(.horizontal, kneeboard ? 20 : 16)
                    .padding(.top, kneeboard ? 16 : 14)
                    .padding(.bottom, 22)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ReferenceContentHeightKey.self, value: proxy.size.height)
                    })
            }
            // In the Cockpit the drawer hugs its content (the caller caps it) instead of always taking
            // the cap and covering the map with empty panel. (on-device review #2)
            .frame(maxHeight: kneeboard && contentHeight > 0 ? contentHeight : nil)
            .onPreferenceChange(ReferenceContentHeightKey.self) { contentHeight = $0 }
        }
        .background(theme.panel)
        .clipShape(corners)
        .overlay(corners.stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    @ViewBuilder
    private var header: some View {
        if kneeboard { kneeboardHeader } else { compactHeader }
    }

    private var kneeboardHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: reference.systemImage)
                .font(.aero(size: CockpitType.label))
                .foregroundColor(reference.tint)
            Text(reference.title)
                .font(.aero(size: CockpitType.label, weight: .bold))
                .tracking(0.6)
                .foregroundColor(theme.textPrimary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.aero(size: 22, weight: .semibold))
                    .foregroundColor(theme.textSecondary)
                    .frame(width: CockpitTarget.control, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Button.close)
        }
        .padding(.leading, 20)
        .padding(.trailing, 6)
    }

    private var compactHeader: some View {
        HStack(spacing: 10) {
            if presentation == .docked {
                Button(action: onClose) {
                    Image(systemName: "arrow.left")
                        .font(.aero(size: 16, weight: .semibold))
                        .foregroundColor(reference.tint)
                }
                .accessibilityLabel(L10n.Button.close)
            }
            Image(systemName: reference.systemImage)
                .font(.aero(size: 14))
                .foregroundColor(reference.tint)
            Text(reference.title)
                .font(.aero(size: 13, weight: .bold))
                .tracking(0.6)
                .foregroundColor(theme.textPrimary)   // neutral title; the icon carries the accent (round 6)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.aero(size: 14, weight: .semibold))
                    .foregroundColor(theme.textSecondary)
            }
            .accessibilityLabel(L10n.Button.close)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var content: some View {
        switch reference {
        case .vSpeeds:
            InFlightSpeedReference(
                activeChecklist: appState.activeChecklist,
                currentPhase: appState.currentPhase,
                aglFeet: aglFeet,
                kneeboard: kneeboard && vSpeedsTable,
                landscape: landscape
            )
        case .gps:
            GPSStatusContent(locationManager: locationManager)
        case .departureBriefing:
            if let context = briefingContext {
                DepartureBriefingContent(context: context)
            }
        case .approachBriefing:
            if let context = briefingContext {
                ApproachBriefingContent(context: context)
            }
        }
    }
}

/// A reference drawer's natural content height, measured inside its scroll view.
private struct ReferenceContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Adds drag-down-to-dismiss to the drawer header only (so it doesn't fight the content ScrollView).
private struct DrawerDragDismiss: ViewModifier {
    let enabled: Bool
    let onClose: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.gesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        if value.translation.height > 60 { onClose() }
                    }
            )
        } else {
            content
        }
    }
}

// MARK: - GPS status content (cockpit-styled, hosted in HUDReferencePanel)

/// Dedicated GPS reference: current signal, the advanced fix info iOS exposes (accuracy, fix time,
/// position/altitude), and a guide explaining each status. Satellite count / raw GNSS time aren't
/// available through CoreLocation. Cockpit cards (no system List). (v4 UI/UX Revamp popup redesign)
struct GPSStatusContent: View {
    @Environment(\.cockpitTheme) private var theme
    @Environment(AppState.self) private var appState
    @ObservedObject var locationManager: LocationManager
    // Tap the value to switch units: Vertical defaults to metres, Altitude to feet. (round 6)
    @State private var verticalInFeet = false
    @State private var altitudeInMeters = false
    @State private var positionCopied = false

    /// When GPS is degraded/lost, a short reason shown under the status word ("why"). (round 6)
    private var statusReason: String? {
        // Permission causes are checked BEFORE the isTracking guard, so they also surface when a
        // flight is active but tracking never started for lack of authorization. Without these two
        // branches a revoked permission and a disabled Precise Location both rendered as an ordinary
        // signal dropout — the pilot could see that recording had stopped, but not why, and neither
        // cause resolves on its own the way weak reception does. (RES-14 / RES-09)
        if locationManager.authorizationStatus == .denied || locationManager.authorizationStatus == .restricted {
            return L10n.GPS.accessRevoked
        }
        if locationManager.accuracyAuthorization == .reducedAccuracy {
            return L10n.GPS.preciseOff
        }
        if locationManager.isSimulatingPosition {
            return L10n.GPS.simulatedPosition
        }
        guard locationManager.isTracking else { return nil }
        switch locationManager.gpsSignalStatus {
        case .good:
            return nil
        case .degraded:
            // Degraded for one of two reasons: the last fix is worse than 100 m, or none has come for
            // 20 s. It said "Reduced accuracy · ± 10 m" for the second. (6.1.0)
            if let fix {
                if fix.horizontalAccuracy > 100 {
                    return L10n.GPS.reasonReducedAccuracy(Int(fix.horizontalAccuracy.rounded()))
                }
                let age = Int(FlightClock.now.timeIntervalSince(fix.timestamp).rounded())
                if fix.horizontalAccuracy >= 0 && age >= 10 { return L10n.GPS.reasonNoUpdate(age) }
                // Positions keep coming, from Wi-Fi or cell towers, not the satellites. (6.1.0)
                if fix.horizontalAccuracy >= 0 && !LocationManager.isSatelliteFix(fix) {
                    return L10n.GPS.reasonNetworkPosition(Int(fix.horizontalAccuracy.rounded()))
                }
            }
            return L10n.GPS.reasonWeakSignal
        case .lost:
            if let ts = fix?.timestamp {
                return L10n.GPS.reasonNoUpdate(Int(FlightClock.now.timeIntervalSince(ts).rounded()))
            }
            return L10n.GPS.reasonNoFix
        }
    }

    /// The latest fix the status counted: on the ground it is newer than the position the flight
    /// works from while the aircraft stands still (`LocationManager.latestFix`).
    private var fix: CLLocation? { locationManager.latestFix ?? locationManager.currentLocation }

    private var statusColor: Color {
        if appState.isFlightActive && !locationManager.isTracking { return theme.danger }
        guard locationManager.isTracking else { return theme.textDim }
        switch locationManager.gpsSignalStatus {
        case .good: return theme.onTarget
        case .degraded: return .orange
        case .lost: return theme.danger
        }
    }

    private var statusText: String {
        guard locationManager.isTracking else { return L10n.GPS.signalInactive }
        switch locationManager.gpsSignalStatus {
        case .good: return L10n.GPS.signalGood
        case .degraded: return L10n.GPS.signalDegraded
        case .lost: return L10n.GPS.signalLost
        }
    }

    private func fixTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        if appState.settings.alwaysUseUTC {
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: date) + " UTC"
        }
        return f.string(from: date)
    }

    var body: some View {
        VStack(spacing: 14) {
            // Current status — when degraded/lost, the subtitle explains WHY.
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "location.fill")
                        .font(.aero(size: 24))
                        .foregroundColor(statusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusText)
                            .font(.aero(size: 16, weight: .semibold))
                            .foregroundColor(statusColor)
                        Text(statusReason ?? L10n.GPS.signal)
                            .font(.aero(size: 12))
                            .foregroundColor(statusReason == nil ? theme.textSecondary : statusColor)
                    }
                    Spacer(minLength: 0)
                }
                if locationManager.backgroundTrackingLimited {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(theme.warning)
                        Text(L10n.GPS.backgroundLimited)
                            .foregroundColor(theme.warning)
                        Spacer(minLength: 0)
                    }
                    .font(.aero(size: 13))
                }
            }
            .cardSection()

            // Advanced fix info — Vertical / Altitude tap to switch units; Position taps to copy.
            if let loc = fix {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    fixTile(L10n.GPS.fixAccuracy, loc.horizontalAccuracy >= 0 ? "± \(Int(loc.horizontalAccuracy.rounded())) m" : "—")
                    Button { verticalInFeet.toggle() } label: {
                        fixTile(L10n.GPS.fixVertical, verticalAccuracyText(loc), trailing: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.plain)
                    fixTile(L10n.GPS.fixTime, fixTime(loc.timestamp))
                    Button { altitudeInMeters.toggle() } label: {
                        fixTile(L10n.GPS.fixAltitude, altitudeText(loc), trailing: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.plain)
                    Button { copyPosition(loc) } label: {
                        fixTile(L10n.GPS.fixPosition, positionText(loc), trailing: positionCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    fixTile(L10n.GPS.pointsRecorded, "\(appState.currentFlight?.gpsTrack.count ?? 0)")
                }
            }

            // Status guide
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.GPS.statusTitle.uppercased())
                    .font(.aero(size: 12, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(theme.textSecondary)
                guideRow(theme.onTarget, L10n.GPS.signalGood, L10n.GPS.statusGoodDesc)
                guideRow(.orange, L10n.GPS.signalDegraded, L10n.GPS.statusDegradedDesc)
                guideRow(theme.danger, L10n.GPS.signalLost, L10n.GPS.statusLostDesc)
            }
            .cardSection()
        }
    }

    private func verticalAccuracyText(_ loc: CLLocation) -> String {
        guard loc.verticalAccuracy >= 0 else { return "—" }
        return verticalInFeet
            ? "± \(Int((loc.verticalAccuracy * 3.28084).rounded())) ft"
            : "± \(Int(loc.verticalAccuracy.rounded())) m"
    }

    private func altitudeText(_ loc: CLLocation) -> String {
        altitudeInMeters
            ? "\(Int(loc.altitude.rounded())) m"
            : "\(Int((loc.altitude * 3.28084).rounded())) ft"
    }

    private func positionText(_ loc: CLLocation) -> String {
        String(format: "%.5f, %.5f", loc.coordinate.latitude, loc.coordinate.longitude)
    }

    private func copyPosition(_ loc: CLLocation) {
        UIPasteboard.general.string = positionText(loc)
        positionCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { positionCopied = false }
    }

    private func fixTile(_ label: String, _ value: String, trailing: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.aero(size: 11))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
                if let trailing {
                    Image(systemName: trailing)
                        .font(.aero(size: 9))
                        .foregroundColor(theme.textDim)
                }
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.aero(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.background)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        )
    }

    private func guideRow(_ color: Color, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.aero(size: 14, weight: .semibold)).foregroundColor(color)
                Text(desc).font(.aero(size: 12)).foregroundColor(theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Cockpit card wrapper shared by the reference popups (dark card, hairline border).
private extension View {
    func cardSection() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            )
    }
}

// MARK: - In-flight V-speeds (phase-aware highlight, hosted in HUDReferencePanel)

/// Its content at its natural width up to `maxWidth`, wrapped beyond it, reporting the height the
/// wrapped text really takes. A `.frame(maxWidth:)` reports one line's height to a layout that
/// measures without a width (as `FlowLayout` does), so the line below it was cut off.
private struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(.unspecified)
        let cap = min(maxWidth, proposal.width ?? maxWidth)
        return natural.width <= cap ? natural : child.sizeThatFits(ProposedViewSize(width: cap, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The V-speeds reference shown in the HUD panel. The Cockpit shows `VSpeedTable`: one fixed table,
/// the phase's speeds framed where they stand, on the iPad. The phone keeps its list (V-name accent ·
/// description muted · value right-aligned, iPhone pass I5); its highlight switches Vx → Vy at 300 ft AGL,
/// cruise = Vc (or Va), descent = Va + Vbg. (round 6; V-SPEEDS proposal D1–D8)
struct InFlightSpeedReference: View {
    @Environment(\.cockpitTheme) private var theme
    let activeChecklist: ActiveChecklist
    let currentPhase: ChecklistPhase
    let aglFeet: Double?
    /// The Cockpit: the fixed table instead of the iPhone's list.
    var kneeboard: Bool = false
    /// The Cockpit in landscape: the same rows with smaller values, the two short rows side by side.
    var landscape: Bool = false

    private var speeds: [SpeedReference] { activeChecklist.speeds }

    var body: some View {
        if kneeboard { table } else { list }
    }

    // MARK: Cockpit table

    /// Values at today's tile size in portrait; smaller in landscape, where the height is short.
    private var valueSize: CGFloat { landscape ? 36 : CockpitType.item }
    private var stallGlideValueSize: CGFloat { landscape ? 40 : 46 }
    private var crosswindValueSize: CGFloat { landscape ? 30 : 34 }
    private static let labelWidth: CGFloat = 160
    private static let qualifierWidth: CGFloat = 150

    private var table: some View {
        let rows = VSpeedTable.rows(speeds: speeds, phase: currentPhase, aglFeet: aglFeet)
        let stallGlide = rows.first { $0.group == .stallGlide }
        let others = rows.filter { $0.group != .stallGlide }
        let climb = others.first { $0.group == .takeoffClimb }
        let crosswind = VSpeedTable.highlightedCrosswind(phase: currentPhase)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(activeChecklist.registration)
                    .font(.aero(size: CockpitType.label, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
                Spacer()
                Text("IAS · kt")
                    .font(.aero(size: CockpitType.label, weight: .semibold))
                    .foregroundColor(theme.textDim)
            }

            // Stall & glide first, on its own panel: the numbers for the moment something goes wrong.
            if let stallGlide {
                rowView(stallGlide, valueSize: stallGlideValueSize)
                    .padding(.leading, 16)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
            }

            VStack(alignment: .leading, spacing: 0) {
                if landscape {
                    // The same rows, full width; take-off & climb and crosswind, both short, share one.
                    HStack(alignment: .top, spacing: 28) {
                        if let climb { rowView(climb, valueSize: valueSize).frame(maxWidth: .infinity, alignment: .leading) }
                        crosswindRow(highlight: crosswind).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(others.filter { $0.group != .takeoffClimb }, id: \.group) { row in
                        rule
                        rowView(row, valueSize: valueSize)
                    }
                } else {
                    ForEach(Array(others.enumerated()), id: \.element.group) { index, row in
                        if index > 0 { rule }
                        rowView(row, valueSize: valueSize)
                    }
                    if !others.isEmpty { rule }
                    crosswindRow(highlight: crosswind)
                }
            }
        }
    }

    private var rule: some View {
        Rectangle().fill(theme.textPrimary.opacity(0.12)).frame(height: 1)
    }

    /// A row: its label in a fixed column on the left, then a cell per speed. The cells flow onto a
    /// second line inside the row if a checklist ever has more than fits, never truncated.
    private func rowView(_ row: VSpeedTable.Row, valueSize: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            rowLabel(Self.title(of: row.group), highlighted: row.isHighlighted)
            FlowLayout(spacing: 0) {
                ForEach(Array(row.cells.enumerated()), id: \.element.id) { index, cell in
                    if row.isSequence && index > 0 {
                        // The approach, flown in this order.
                        Text("›")
                            .font(.aero(size: 26, design: .monospaced))
                            .foregroundColor(theme.textDim)
                            .padding(.top, 22)
                            .accessibilityHidden(true)
                    }
                    cellView(name: cell.name, value: cell.value, qualifier: cell.qualifier,
                             nameColor: nameColor(cell.tone, highlighted: cell.highlighted),
                             valueColor: cell.tone == .neverExceed ? theme.danger : theme.textPrimary,
                             valueSize: valueSize, highlighted: cell.highlighted,
                             leadingRule: !row.isSequence && index > 0)
                        .accessibilityLabel(Self.spokenLabel(cell))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func crosswindRow(highlight: VSpeedTable.Crosswind?) -> some View {
        let limits = activeChecklist.crosswindLimits
        return HStack(alignment: .top, spacing: 0) {
            rowLabel(L10n.VSpeeds.crosswind, highlighted: highlight != nil)
            HStack(alignment: .top, spacing: 0) {
                cellView(name: "T/O", value: limits.takeoff, qualifier: nil, nameColor: theme.textSecondary,
                         valueColor: theme.warning, valueSize: crosswindValueSize,
                         highlighted: highlight == .takeoff, leadingRule: false)
                    .accessibilityLabel(L10n.VSpeeds.crosswindTakeoffA11y(limits.takeoff))
                cellView(name: "LDG", value: limits.landing, qualifier: nil, nameColor: theme.textSecondary,
                         valueColor: theme.warning, valueSize: crosswindValueSize,
                         highlighted: highlight == .landing, leadingRule: true)
                    .accessibilityLabel(L10n.VSpeeds.crosswindLandingA11y(limits.landing))
            }
        }
        .padding(.vertical, 4)
    }

    /// The row's label, with ▸ when it holds the phase's speed. The marker's room is always kept, so
    /// the highlight never shifts the table.
    private func rowLabel(_ title: String, highlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.aero(size: 12))
                .opacity(highlighted ? 1 : 0)
                .accessibilityHidden(true)
            Text(title.uppercased())
                .font(.aero(size: CockpitType.label, weight: .bold))
                .tracking(1)
                .lineLimit(3)
                .minimumScaleFactor(0.75)   // "ATTERRISSAGE" shrinks a little rather than break
        }
        .foregroundColor(highlighted ? theme.textPrimary : theme.textSecondary)
        .frame(width: Self.labelWidth, alignment: .leading)
        .padding(.top, 8)
        .accessibilityAddTraits(.isHeader)
    }

    /// One speed: its name, its value under it, what it depends on under that. The highlight is a
    /// frame and a fill drawn around the cell, so framing a cell moves nothing.
    private func cellView(name: String, value: String, qualifier: String?, nameColor: Color, valueColor: Color,
                          valueSize: CGFloat, highlighted: Bool, leadingRule: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.aero(size: CockpitType.label, weight: .bold, design: .monospaced))
                .foregroundColor(nameColor)
                .lineLimit(1)
                .fixedSize()
            Text(value)
                .font(.aero(size: valueSize, weight: .bold, design: .monospaced))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .fixedSize()
            if let qualifier {
                CappedWidth(maxWidth: Self.qualifierWidth) {
                    Text(qualifier)
                        .font(.aero(size: CockpitType.label))
                        .foregroundColor(theme.textSecondary)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(highlighted ? theme.textPrimary.opacity(0.14) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(highlighted ? theme.textPrimary : .clear, lineWidth: 2))
        .overlay(alignment: .leading) {
            if leadingRule { Rectangle().fill(theme.textPrimary.opacity(0.16)).frame(width: 1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private func nameColor(_ tone: VSpeedTable.Tone, highlighted: Bool) -> Color {
        switch tone {
        case .stall: return theme.warning
        case .neverExceed: return theme.danger
        case .plain: return highlighted ? theme.textPrimary : theme.textSecondary
        }
    }

    private static func title(of group: VSpeedTable.Group) -> String {
        switch group {
        case .stallGlide: return L10n.VSpeeds.stallGlide
        case .takeoffClimb: return L10n.VSpeeds.takeoffClimb
        case .approachLanding: return L10n.VSpeeds.approachLanding
        case .limits: return L10n.VSpeeds.limits
        case .other: return L10n.VSpeeds.other
        }
    }

    private static func spokenLabel(_ cell: VSpeedTable.Cell) -> String {
        [cell.name, "\(cell.value) knots", cell.qualifier].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: iPhone list

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(activeChecklist.registration)
                    .font(.aero(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
                Spacer()
                Text("IAS · kt")
                    .font(.aero(size: 11, weight: .semibold))
                    .foregroundColor(theme.textDim)
            }

            VStack(spacing: 5) {
                ForEach(speeds) { speed in
                    speedRow(speed)
                }
            }

            let crosswind = activeChecklist.crosswindLimits
            HStack {
                Text("Max crosswind")
                    .font(.aero(size: 12, weight: .medium))
                    .foregroundColor(theme.textSecondary)
                Spacer()
                Text("T/O \(crosswind.takeoff) · LDG \(crosswind.landing)")
                    .font(.aero(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.warning)
            }
            .padding(.top, 2)
        }
    }

    private func speedRow(_ speed: SpeedReference) -> some View {
        let highlighted = isHighlighted(speed)
        let isVne = speed.name.lowercased() == "vne"
        return HStack(spacing: 10) {
            // Left accent bar marks the phase-relevant row(s).
            RoundedRectangle(cornerRadius: 1.5)
                .fill(highlighted ? (isVne ? theme.danger : theme.action) : Color.clear)
                .frame(width: 3)
            Text(speed.name)
                .font(.aero(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(isVne ? theme.danger : theme.action)
                .frame(width: 58, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(speed.description)
                .font(.aero(size: 12))
                .foregroundColor(theme.textDim)
                .lineLimit(1)
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(speed.value)
                    .font(.aero(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(isVne ? theme.danger : theme.textPrimary)
                Text("kt")
                    .font(.aero(size: 11))
                    .foregroundColor(theme.textDim)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(highlighted ? (isVne ? theme.danger.opacity(0.12) : theme.action.opacity(0.14)) : Color.clear)
        )
    }

    private func isHighlighted(_ speed: SpeedReference) -> Bool {
        highlightNames.contains(speed.name.lowercased())
    }

    /// Phase-relevant V-speed names to highlight, resolved against what the aircraft actually defines.
    /// Mapping per user: line-up = Vr; climb = Vx until 300 ft AGL then Vy (Vy when AGL unknown);
    /// cruise = Vc (else Va); descent = Va + Vbg; approach = Vapp; landing = Vfinal/Vref + Vso. (round 6)
    private var highlightNames: Set<String> {
        let available = Set(speeds.map { $0.name.lowercased() })
        func resolve(_ wanted: [String], fallback: [String] = []) -> [String] {
            let hit = wanted.filter { available.contains($0) }
            return hit.isEmpty ? fallback.filter { available.contains($0) } : hit
        }
        switch currentPhase {
        case .beforeDeparture, .lineUp:
            return Set(resolve(["vr"]))
        case .climb:
            let belowTransition = aglFeet.map { $0 < 300 } ?? false
            return Set(resolve(belowTransition ? ["vx"] : ["vy"], fallback: ["vy", "vx"]))
        case .cruise:
            return Set(resolve(["vc"], fallback: ["va"]))
        case .descent:
            return Set(resolve(["va", "vbg"]))
        case .approach:
            return Set(resolve(["vapp"]))
        case .landing:
            return Set(resolve(["vfinal", "vref", "vso"]))
        default:
            return []
        }
    }
}

// MARK: - Preview

#Preview {
    FlightView()
        .environment(AppState())
        .environmentObject(LocationManager())
        .environmentObject(WindDataService())
        .environmentObject(FlightPlanManager())
}


/// One NEXT press held for review: the phase being left and its unchecked items. (v6.0 · B2)
struct JumpQuestion: Identifiable {
    let id = UUID()
    let target: ChecklistPhase
    let checks: [ChecklistPhase]
    let leaving: ChecklistPhase
    let leavingOpenItems: Int
}

struct OpenItemsReview: Identifiable {
    let id = UUID()
    let phase: ChecklistPhase
    let items: [ChecklistItem]
    /// A memory check left unconfirmed: nothing to list, the check itself is owed. (6.1)
    var memoryCheck: Bool = false
}
