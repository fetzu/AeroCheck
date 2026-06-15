import SwiftUI
import Combine
import CoreLocation
import MapKit
import UIKit

/// Main flight view displayed during an active flight
struct FlightView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var windDataService: WindDataService
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var flightEventDetector: FlightEventDetector
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager
    @State private var showPhaseSelector = false
    @State private var showEndFlightAlert = false
    @State private var showAbandonFlightAlert = false
    @State private var abandonFlightProgress: CGFloat = 0
    @State private var abandonFlightTimer: Timer?
    @State private var showFlightInfo = false
    @State private var showNavigationMode = false
    /// The reference popup currently shown in the HUD context slot (Pattern B of the A+B hybrid):
    /// docked into the iPad-landscape right column (over the map), or a cockpit-themed bottom drawer
    /// on iPad portrait / iPhone. nil = none. HUD Settings stays a sheet (Pattern A). (Phase 3.1)
    @State private var activeReference: HUDReference? = nil
    @State private var timerTrigger = false
    @State private var pulseNextButton = false
    @State private var pulseActionButton = false
    @State private var allItemsChecked = false
    @State private var scrollToBottom = false
    @State private var nearestFreqText: String?
    /// Whether the current phase's hidden (memorizable) items have been temporarily revealed (owned here
    /// so tap-to-advance can step through them). Reset on phase change. (Phase 3.1 feedback)
    @State private var hiddenItemsRevealed = false

    // Hour meter input modals
    @State private var showHourMeterStart = false
    @State private var showHourMeterStop = false
    @State private var hourMeterStartInitialValue: String = ""
    @State private var hourMeterStopInitialValue: String = ""

    // Timer for updating flight duration display
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Check if current phase has an action button that hasn't been pressed yet
    private var currentPhaseNeedsAction: Bool {
        switch appState.currentPhase {
        case .engineStart:
            return appState.engineStartTime == nil
        case .beforeDeparture:
            return appState.lineUpTime == nil
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
    /// button stays tappable either way so a phase can still be skipped. (Phase 3.1 feedback)
    private var nextButtonReady: Bool {
        let itemsDone = !appState.settings.stepByStepHighlighting || appState.areAllItemsCompleted(learningMode: effectiveLearningMode)
        return itemsDone && !currentPhaseNeedsAction
    }

    /// Learning mode OR temporarily-revealed hidden items — the set of items the checklist is showing,
    /// so tap-to-advance and completion stay in sync with what's on screen. (Phase 3.1 feedback)
    private var effectiveLearningMode: Bool {
        appState.settings.learningMode || hiddenItemsRevealed
    }

    /// Determine if we're on an iPhone-sized device
    private func isCompactWidth(_ geometry: GeometryProxy) -> Bool {
        geometry.size.width < 600
    }

    /// Current track (direction of travel) in degrees from GPS
    /// Uses cached heading to prevent snapping to 0° during brief GPS gaps
    private var currentTrackDegrees: Double {
        locationManager.currentCourseDegrees ?? 0
    }

    /// Estimated airspeed if the feature is enabled, otherwise nil
    private var estimatedAirspeed: Double? {
        guard appState.settings.showEstimatedAirspeed else { return nil }
        return windDataService.calculateEstimatedAirspeed(
            groundSpeedKnots: locationManager.displaySpeedKnots,
            trackDegrees: currentTrackDegrees,
            coordinate: locationManager.getCurrentCoordinate()
        )
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

        // Get wind data if available (from MeteoSwiss)
        let windDirection: Double?
        let windSpeed: Double?
        if let windData = windDataService.currentWindData {
            windDirection = windData.directionDegrees
            windSpeed = windData.speedKmh * 0.539957  // Convert km/h to knots
        } else {
            windDirection = nil
            windSpeed = nil
        }

        // Get destination from flight plan if available (waypoint name is often the ICAO code)
        let destinationIdent = flightPlanManager.activeFlightPlan?.waypoints.last?.name

        return BriefingContextBuilder.build(
            speeds: speeds,
            hasParachute: hasParachute,
            aircraftRegistration: registration,
            aircraftType: aircraftType,
            currentLocation: locationManager.getCurrentCoordinate(),
            airportDataService: airportDataService,
            windDirection: windDirection,
            windSpeed: windSpeed,
            destinationIdent: destinationIdent
        )
    }

    /// Width of the left (checklist) column in the iPad two-column layout; the HUD context column
    /// takes the rest. Tune here. (Phase 3.1)
    private static let checklistColumnFraction: CGFloat = 0.6

    // MARK: - HUD shell (top bar + phase progress bar over the content)

    /// Wraps the iPad HUD: the full-width top bar and tappable phase progress bar span both columns,
    /// with the orientation-specific content below. Also drives the throttled NEAREST lookup. (Phase 3.1)
    private func hudShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            hudTopBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.panelBackground)

            phaseProgressBarView
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .background(Color.panelBackground)

            content()
        }
        .onAppear { updateNearestFrequency() }
        .onChange(of: coarseLocationKey) { _, _ in updateNearestFrequency() }
        .onChange(of: airportDataService.isDataAvailable) { _, _ in updateNearestFrequency() }
    }

    /// Phases shown in the progress bar (Cruise/Descent hidden in circuit mode, matching the old list).
    private var visiblePhases: [ChecklistPhase] {
        ChecklistPhase.allCases.filter { phase in
            !(appState.isCircuitMode && (phase == .cruise || phase == .descent))
        }
    }

    private var phaseProgressBarView: some View {
        PhaseProgressBar(
            phases: visiblePhases,
            currentPhase: appState.currentPhase,
            status: { appState.getPhaseStatus($0) },
            onSelect: { appState.goToPhase($0) },
            isCircuitMode: appState.isCircuitMode
        )
    }

    /// Full-width HUD top bar: aircraft · tappable phase badge · counter ‖ timer · GPS · options.
    /// Top-bar phase-badge tint by flight stage, so the chip reads at a glance (was always gold):
    /// ground prep = blue, departure = gold, airborne = green, arrival = orange, wrap-up = grey.
    private var phaseBadgeColor: Color {
        switch appState.currentPhase {
        case .preflight, .beforeEngineStart, .engineStart, .afterEngineStart, .taxi, .runup:
            return .altimeterBlue
        case .beforeDeparture, .lineUp:
            return .aviationGold
        case .climb, .cruise, .descent:
            return .aviationGreen
        case .approach, .landing:
            return .orange
        case .afterLanding, .shutdown, .hangar:
            return .secondaryText
        }
    }

    private var hudTopBar: some View {
        HStack(spacing: 12) {
            abandonableAircraftIdentifier(iconSize: 20, isCompact: false)

            Button(action: { showPhaseSelector = true }) {
                Text(appState.currentPhase.shortTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(phaseBadgeColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(phaseBadgeColor.opacity(0.18)))
            }
            // Just the counter — the phase NAME is already in the badge, so "Phase" is redundant.
            Text("\(appState.currentPhase.rawValue + 1) / \(ChecklistPhase.allCases.count)")
                .font(.captionText)
                .foregroundColor(.secondaryText)

            circuitCounterChip

            Spacer()

            if companionConnectivityManager.connectionState == .connected {
                HStack(spacing: 4) {
                    Image(systemName: "iphone").font(.system(size: 12))
                    StatusIndicator(.active, size: 8)
                }
                .foregroundColor(.aviationGreen)
            }

            // Flight timer — just the elapsed clock (no status dot; GPS status is its own indicator).
            Text(appState.flightDuration)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(.primaryText)
                .id(timerTrigger)

            // GPS status — icon AND label reflect the signal status; tap to open the dedicated GPS
            // popup (status guide + advanced fix info). (Phase 3.1 feedback)
            Button(action: { openReference(.gps) }) {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 12))
                    Text("GPS")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(gpsStatusColor)
            }
            .accessibilityLabel(L10n.GPS.status)
            .accessibilityHint(L10n.Flight.info)

            // Flight details / options (consolidates the GPS/points/times panel)
            Button(action: { showFlightInfo = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundColor(.secondaryText)
            }
            .accessibilityLabel(L10n.Flight.info)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if isCompactWidth(geometry) {
                // iPhone layout: full-width checklist with compact header
                VStack(spacing: 0) {
                    mainChecklistAreaCompact(geometry: geometry)
                }
                // Reference popups (V-SPEEDS / GPS / BRIEFING) → themed bottom drawer; iPhone has no
                // side column, so Pattern B degrades to a cockpit-styled sheet. (Phase 3.1)
                .overlay { referenceDrawerOverlay(maxHeight: geometry.size.height * 0.66) }
            } else if geometry.size.height > geometry.size.width {
                // iPad PORTRAIT: full-width top bar + phase bar, then the vertical stack. (Phase 3.1 HUD)
                hudShell {
                    portraitLayout
                }
                // Reference popups → themed bottom drawer over the stack (no side column in portrait).
                .overlay { referenceDrawerOverlay(maxHeight: geometry.size.height * 0.6) }
            } else {
                // iPad LANDSCAPE: full-width top bar + phase bar, then checklist-left / context-right.
                // (Phase 3.1 HUD)
                hudShell {
                    HStack(spacing: 0) {
                        hudLeftColumn
                            .frame(width: geometry.size.width * Self.checklistColumnFraction)
                        sidePanel
                            .frame(width: geometry.size.width * (1 - Self.checklistColumnFraction))
                            .background(Color.panelBackground)
                    }
                }
            }
        }
        .background(Color.cockpitBackground)
        .sheet(isPresented: $showPhaseSelector) {
            PhaseSelectorView()
        }
        .sheet(isPresented: $showFlightInfo) {
            FlightInfoSheet(locationManager: locationManager)
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
        .fullScreenCover(isPresented: $showNavigationMode) {
            NavigationMapView(isPresented: $showNavigationMode)
        }
        .alert(L10n.Alert.endFlightTitle, isPresented: $showEndFlightAlert) {
            Button(L10n.Button.cancel, role: .cancel) { }
            Button(L10n.Button.endFlight, role: .destructive) {
                locationManager.stopTracking()
                // Populate timing fields on the active flight plan from the current flight
                if let activePlan = flightPlanManager.activeFlightPlan,
                   let flight = appState.currentFlight {
                    flightPlanManager.populateTimingFromFlight(activePlan.id, flight: flight)
                }
                appState.endFlight(withFlightPlan: flightPlanManager.activeFlightPlan)
                flightPlanManager.deactivateFlightPlan()
            }
        } message: {
            Text(L10n.Alert.endFlightMessage)
        }
        .alert(L10n.Alert.abandonFlightTitle, isPresented: $showAbandonFlightAlert) {
            Button(L10n.Button.cancel, role: .cancel) { }
            Button(L10n.Alert.abandonFlightButton, role: .destructive) {
                locationManager.stopTracking()
                appState.cancelFlight()
                flightPlanManager.deactivateFlightPlan()
            }
        } message: {
            Text(L10n.Alert.abandonFlightMessage)
        }
        .onReceive(timer) { _ in
            // Trigger view update for timer display
            timerTrigger.toggle()
        }
        .onAppear {
            // Start wind data fetching if estimated airspeed is enabled
            if appState.settings.showEstimatedAirspeed {
                windDataService.startFetching(locationManager: locationManager)
            }
        }
        .onDisappear {
            // Stop wind data fetching when leaving flight view
            windDataService.stopFetching()
        }
        .onChange(of: appState.settings.showEstimatedAirspeed) { _, newValue in
            if newValue {
                windDataService.startFetching(locationManager: locationManager)
            } else {
                windDataService.stopFetching()
            }
        }
        .onChange(of: appState.currentPhase) { oldPhase, newPhase in
            // Show hour meter input when navigating TO Engine Start phase
            if newPhase == .engineStart && appState.settings.logEngineHours {
                if appState.currentFlight?.engineHourStart == nil {
                    hourMeterStartInitialValue = ""
                    showHourMeterStart = true
                }
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
    
    // MARK: - Main Checklist Area
    
    /// The HUD left column: the live instrument strip (top), the checklist with the hero item
    /// (scrolls, takes the slack), and the big NEXT button (bottom). The full-width top bar + phase
    /// progress bar live above both columns in the body. (Phase 3.1 HUD rebuild)
    private var hudLeftColumn: some View {
        VStack(spacing: 0) {
            // Live SPD/ALT/HDG instrument strip (flight phases only).
            if appState.activeChecklist.showsSpeedIndicator(for: appState.currentPhase) {
                CockpitInstrumentStrip(
                    speedKnots: locationManager.displaySpeedKnots,
                    targetSpeed: appState.activeChecklist.targetSpeed(for: appState.currentPhase),
                    stallSpeed: appState.activeChecklist.stallSpeed,
                    gpsSignalStatus: locationManager.gpsSignalStatus,
                    estimatedAirspeed: estimatedAirspeed,
                    stallAlertEnabled: appState.settings.stallAlertSound,
                    altitudeFeet: locationManager.currentAltitudeFeet,
                    headingDegrees: locationManager.currentCourseDegrees,
                    verticalSpeedFPM: locationManager.verticalSpeedFpm
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }

            // Checklist content - entire area is tappable
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ChecklistView(
                            phase: appState.currentPhase,
                            activeChecklist: appState.activeChecklist,
                            onEngineStart: { performEngineStart() },
                            onEngineStartUpdate: { performEngineStartUpdate() },
                            onLineUp: { performLineUp() },
                            onLineUpUpdate: { performLineUpUpdate() },
                            onEngineShutdown: { performEngineShutdown() },
                            onEngineShutdownUpdate: { performEngineShutdownUpdate() },
                            onGoAround: {
                                appState.recordGoAround()
                                flightEventDetector.notifyManualEvent(.goAround) // PR-07: suppress a duplicate auto-detect
                                // Reset UI state since we're jumping to a new phase
                                pulseActionButton = false
                                pulseNextButton = false
                                allItemsChecked = false
                            },
                            onTouchAndGo: {
                                appState.recordTouchAndGo()
                                flightEventDetector.notifyManualEvent(.touchAndGo) // PR-07
                                // Reset UI state since we're jumping to a new phase
                                pulseActionButton = false
                                pulseNextButton = false
                                allItemsChecked = false
                            },
                            onFullStop: {
                                appState.recordFullStop()
                                flightEventDetector.notifyManualEvent(.fullStop) // PR-07
                                // Reset UI state since we're jumping to a new phase
                                pulseActionButton = false
                                pulseNextButton = false
                                allItemsChecked = false
                            },
                            onLanded: {
                                appState.recordLanding()
                                // PR-07: notify the detector so it doesn't emit a duplicate full stop
                                // ~40 s later (dismissFullStop only cleared an already-pending event;
                                // a LANDED tap while vacating fires the pending full stop afterwards).
                                flightEventDetector.notifyManualEvent(.fullStop)
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
                            onTapToAdvance: {
                                handleChecklistTap(scrollProxy: scrollProxy)
                            },
                            onAllItemsCompleted: {
                                // Not used anymore - handled in handleChecklistTap
                            },
                            engineStartTime: appState.formattedEngineStartTime,
                            lineUpTime: appState.formattedLineUpTime,
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
                            hiddenItemsRevealed: $hiddenItemsRevealed
                        )
                        .padding(24)
                        .id("checklistContent")
                        
                        // Spacer to allow scroll area to be tappable
                        Color.clear
                            .frame(height: 1)
                            .id("bottomAnchor")
                    }
                }
                .contentShape(Rectangle()) // Make entire scroll area tappable
                .onTapGesture {
                    if appState.settings.stepByStepHighlighting {
                        handleChecklistTap(scrollProxy: scrollProxy)
                    }
                }
                .onChange(of: scrollToBottom) { _, shouldScroll in
                    if shouldScroll {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scrollProxy.scrollTo("actionButton", anchor: .center)
                        }
                        scrollToBottom = false
                    }
                }
            }
            .background(Color.cockpitBackground)

            // Bottom bar: the phase's timestamp action (engine-start / ready-for-line-up / shutdown,
            // when applicable) next to the big NEXT. NAV moved to the map, SPEEDS to the V-SPEEDS tile,
            // PREV to the tappable phase progress bar.
            HStack(spacing: 12) {
                hudPhaseActionButton
                circuitQuickEventButtons
                hudNextButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.panelBackground)
        }
    }

    // MARK: - HUD primary action (NEXT / END FLIGHT)

    @ViewBuilder
    private var hudNextButton: some View {
        if appState.isLastPhase {
            Button(action: { showEndFlightAlert = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "flag.checkered")
                    Text(L10n.Button.end)
                }
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.aviationRed))
            }
            .modifier(PulseModifier(isActive: pulseNextButton && allItemsChecked))
        } else {
            Button(action: {
                pulseNextButton = false
                pulseActionButton = false
                allItemsChecked = false
                appState.nextPhase()
            }) {
                HStack(spacing: 8) {
                    Text(L10n.Button.next)
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 20, weight: .bold))
                // Greyed (but still tappable) until the checklist is complete; full gold when ready.
                .foregroundColor(nextButtonReady ? .black : .secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(nextButtonReady ? Color.aviationGold : Color.aviationGold.opacity(0.22))
                )
            }
            // When the phase becomes ready, a finite gold halo pulses AROUND the button then settles
            // (no resize, no loop) — reuses the shared PulseModifier. (round 6 feedback)
            .modifier(PulseModifier(isActive: nextButtonReady))
        }
    }

    /// The phase's timestamp action (engine-start / ready-for-line-up / shutdown) shown next to NEXT in
    /// the HUD bottom bar — moved out of the checklist scroll so it's always reachable, not scrolled
    /// away. Mutually exclusive per phase; empty otherwise. (Phase 3.1)
    @ViewBuilder
    private var hudPhaseActionButton: some View {
        let phase = appState.currentPhase
        let lang = appState.settings.checklistLanguage.resolvedLanguage
        if phase.showsEngineStartButton {
            TimestampActionButton(
                title: L10n.ChecklistAction.engineStart(language: lang),
                icon: "engine.combustion.fill",
                color: .aviationGreen,
                timestamp: appState.formattedEngineStartTime,
                timestampLabel: L10n.ChecklistAction.started(language: lang),
                isPulsing: pulseActionButton,
                compact: true,
                onFirstPress: { performEngineStart() },
                onUpdateTime: { performEngineStartUpdate() }
            )
        } else if phase.showsLineUpButton {
            TimestampActionButton(
                title: L10n.ChecklistAction.readyForLineUp(language: lang),
                icon: "airplane.departure",
                color: .aviationAmber,
                timestamp: appState.formattedLineUpTime,
                timestampLabel: L10n.ChecklistAction.lineUp(language: lang),
                timestampSuffix: " (+2 min)",
                isPulsing: pulseActionButton,
                compact: true,
                onFirstPress: { performLineUp() },
                onUpdateTime: { performLineUpUpdate() }
            )
        } else if phase.showsEngineShutdownButton {
            TimestampActionButton(
                title: L10n.ChecklistAction.engineShutdown(language: lang),
                icon: "engine.combustion.fill",
                color: .aviationRed,
                timestamp: appState.formattedEngineShutdownTime,
                timestampLabel: L10n.ChecklistAction.shutdown(language: lang),
                isPulsing: pulseActionButton,
                compact: true,
                onFirstPress: { performEngineShutdown() },
                onUpdateTime: { performEngineShutdownUpdate() }
            )
        }
    }

    // Phase timestamp actions — shared by the HUD bottom-bar button (iPad) and the in-checklist
    // buttons (these methods back the iPad ChecklistView callbacks too, so behavior can't diverge).
    private func performEngineStart() {
        appState.recordEngineStart()
        pulseActionButton = false
        if allItemsChecked { triggerNextButtonPulse() }
    }
    private func performEngineStartUpdate() {
        appState.recordEngineStart()
    }
    private func performLineUp() {
        appState.recordLineUpTime()
        if let lineUpTime = appState.lineUpTime {
            flightPlanManager.updateDepartureTimeFromLineUp(lineUpTime)
        }
        pulseActionButton = false
        if allItemsChecked { triggerNextButtonPulse() }
    }
    private func performLineUpUpdate() {
        appState.recordLineUpTime()
        if let lineUpTime = appState.lineUpTime {
            flightPlanManager.updateDepartureTimeFromLineUp(lineUpTime)
        }
    }
    private func performEngineShutdown() {
        appState.recordEngineShutdown()
        pulseActionButton = false
        if appState.settings.logEngineHours {
            hourMeterStopInitialValue = ""
            showHourMeterStop = true
        }
        if allItemsChecked { triggerNextButtonPulse() }
    }
    private func performEngineShutdownUpdate() {
        appState.recordEngineShutdown()
        if appState.settings.logEngineHours {
            if let prevEnd = appState.currentFlight?.engineHourEnd {
                let prevFormat = appState.currentFlight?.engineHourEndInputFormat ?? "decimal"
                hourMeterStopInitialValue = prevFormat == "time"
                    ? Flight.formatHoursTime(prevEnd)
                    : Flight.formatHoursDecimal(prevEnd)
            } else {
                hourMeterStopInitialValue = ""
            }
            showHourMeterStop = true
        }
    }

    // MARK: - iPad Portrait Layout (vertical stack)

    /// iPad portrait stack: a top instruments strip (primary flight data), the reused header + hero
    /// checklist + NEXT bar in the middle (takes the slack), and the persistent map band at the
    /// bottom. Reuses `mainChecklistArea` wholesale so the checklist wiring isn't duplicated. (Phase 3.1)
    private var portraitLayout: some View {
        VStack(spacing: 0) {
            // Instruments + hero checklist + NEXT (takes the vertical slack so the checklist scrolls).
            hudLeftColumn

            // Hold-to-confirm GO-AROUND / T&G / FULL-STOP for the relevant phases (empty otherwise).
            eventActionsRow

            // Persistent map band (tap to open the full nav map).
            if appState.isFlightActive {
                miniMapContent
                    .frame(height: 200)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
            }

            // Phase-aware tiles (V-SPEEDS / briefings).
            phaseContextZone
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .background(Color.cockpitBackground)
    }

    // MARK: - Event Actions (hold-to-confirm)

    /// Always-accessible GO-AROUND / TOUCH & GO / FULL-STOP buttons for the relevant phases, so the
    /// pilot doesn't have to scroll the checklist to reach them. Gated on the same phase flags as the
    /// in-checklist buttons; hold-to-confirm so a stray touch can't fire a go-around. Empty (no space)
    /// when no event applies to the current phase. (Phase 3.1)
    @ViewBuilder
    private var eventActionsRow: some View {
        let phase = appState.currentPhase
        let language = appState.settings.checklistLanguage.resolvedLanguage
        // In circuit mode GO-AROUND / TOUCH & GO become single-tap buttons beside NEXT
        // (circuitQuickEventButtons) for fast missed-detection recovery, so they're omitted here.
        // Outside circuit mode they stay hold-to-confirm. FULL-STOP stays hold-to-confirm always.
        let showHoldGoAround = phase.showsGoAroundButtons && !appState.isCircuitMode
        if showHoldGoAround || phase.showsLandedButton {
            HStack(spacing: 10) {
                if showHoldGoAround {
                    HoldToConfirmButton(
                        title: L10n.ChecklistAction.goAround(language: language),
                        systemImage: "arrow.up.right.circle.fill",
                        tint: .aviationAmber,
                        count: appState.currentFlight?.goAroundCount ?? 0,
                        action: performGoAround
                    )
                    HoldToConfirmButton(
                        title: L10n.ChecklistAction.touchAndGo(language: language),
                        systemImage: "arrow.triangle.2.circlepath",
                        tint: .aviationBlue,
                        count: appState.currentFlight?.touchAndGoCount ?? 0,
                        action: performTouchAndGo
                    )
                }
                if phase.showsLandedButton {
                    HoldToConfirmButton(
                        title: L10n.ChecklistAction.landed(language: language),
                        systemImage: "airplane.arrival",
                        tint: .aviationBlue,
                        count: appState.currentFlight?.fullStopCount ?? 0,
                        action: performLanded
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    /// In circuit mode, single-tap GO-AROUND / TOUCH & GO shown beside NEXT in the HUD bottom bar so a
    /// missed auto-detection can be corrected instantly (jump back to the CLIMB check). Hold-to-confirm
    /// is too slow here; the accepted trade-off is a small accidental-tap risk during circuit training.
    @ViewBuilder
    private var circuitQuickEventButtons: some View {
        let phase = appState.currentPhase
        let language = appState.settings.checklistLanguage.resolvedLanguage
        if appState.isCircuitMode && phase.showsGoAroundButtons {
            // The pair shares ~50% of the bottom bar (so each button ≈ 25%, leaving NEXT ≈ 50%).
            HStack(spacing: 12) {
                quickEventButton(
                    title: L10n.ChecklistAction.goAround(language: language),
                    systemImage: "arrow.up.right.circle.fill",
                    tint: .orange,   // distinct from the gold NEXT (not red/green), caution semantics
                    action: performGoAround
                )
                quickEventButton(
                    title: L10n.ChecklistAction.touchAndGo(language: language),
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: .altimeterBlue,
                    action: performTouchAndGo
                )
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func quickEventButton(title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.system(size: 18, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            // Match the solid action-button family (NEXT / TimestampActionButton): SOLID tint fill,
            // black label, corner 14, and the same ~60pt height so they're flush with NEXT. (round 6)
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(tint)
                    .shadow(color: tint.opacity(0.4), radius: 6, x: 0, y: 3)
            )
        }
        .accessibilityLabel(title)
    }

    /// Subtle circuit-stats readout in the HUD top bar (circuit mode only): touch-and-goes and, if any,
    /// go-arounds done. Deliberately non-prominent — dim and small. (round 6 feedback)
    @ViewBuilder
    private var circuitCounterChip: some View {
        if appState.isCircuitMode, let flight = appState.currentFlight {
            HStack(spacing: 6) {
                Text("[").foregroundColor(.dimText)
                Label("\(flight.touchAndGoCount)", systemImage: "arrow.triangle.2.circlepath")
                if flight.goAroundCount > 0 {
                    Label("\(flight.goAroundCount)", systemImage: "arrow.up.right.circle")
                }
                Text("]").foregroundColor(.dimText)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondaryText)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(flight.touchAndGoCount) touch and go, \(flight.goAroundCount) go around")
        }
    }

    // These mirror the in-checklist event callbacks exactly (record + PR-07 manual-event dedup), so
    // the HUD buttons and the checklist buttons log identically — no double-counting. (Phase 3.1)
    private func performGoAround() {
        appState.recordGoAround()
        flightEventDetector.notifyManualEvent(.goAround)
        pulseActionButton = false
        pulseNextButton = false
        allItemsChecked = false
    }

    private func performTouchAndGo() {
        appState.recordTouchAndGo()
        flightEventDetector.notifyManualEvent(.touchAndGo)
        pulseActionButton = false
        pulseNextButton = false
        allItemsChecked = false
    }

    private func performLanded() {
        appState.recordLanding()
        flightEventDetector.notifyManualEvent(.fullStop)
        pulseActionButton = false
    }

    // MARK: - Phase-aware context zone

    /// Phase-aware quick-access tiles for the HUD context column, from a fixed vocabulary so it's
    /// predictable. This first slice surfaces the synchronous, reuse-existing tiles — V-SPEEDS (a
    /// labeled tap showing the phase-relevant target inline) and the departure/approach BRIEFINGS for
    /// their phase clusters. Async tiles (FREQ / NEAREST / WIND) are a later slice. (Phase 3.1)
    @ViewBuilder
    private var phaseContextZone: some View {
        let phase = appState.currentPhase
        HStack(spacing: 10) {
            // V-SPEEDS — a labeled tap (no longer a hidden one), with the phase target speed inline.
            PhaseContextTile(
                title: "V-SPEEDS",
                systemImage: "speedometer",
                tint: .aviationGreen,
                action: { openReference(.vSpeeds) }
            )

            // Departure / approach briefing for the relevant phase clusters (always reachable here,
            // not only via the inline checklist button that scrolls away). The icon distinguishes
            // departure vs approach.
            if phase.briefingType == .departure {
                PhaseContextTile(
                    title: "BRIEFING",
                    systemImage: "airplane.departure",
                    tint: .aviationGold,
                    action: { openReference(.departureBriefing) }
                )
            }
            if phase.briefingType == .approach {
                PhaseContextTile(
                    title: "BRIEFING",
                    systemImage: "airplane.arrival",
                    tint: .aviationGold,
                    action: { openReference(.approachBriefing) }
                )
            }
        }
    }

    // MARK: - Compact Layout (iPhone)

    private func mainChecklistAreaCompact(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // Compact header bar for iPhone
            compactHeaderBar
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.panelBackground)

            // Speed and altitude indicators inline (when applicable)
            if appState.activeChecklist.showsSpeedIndicator(for: appState.currentPhase) {
                compactInstrumentBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.panelBackground.opacity(0.8))
            }

            // Checklist content
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ChecklistView(
                            phase: appState.currentPhase,
                            activeChecklist: appState.activeChecklist,
                            onEngineStart: {
                                appState.recordEngineStart()
                                pulseActionButton = false
                                if allItemsChecked { triggerNextButtonPulse() }
                            },
                            onEngineStartUpdate: { appState.recordEngineStart() },
                            onLineUp: {
                                appState.recordLineUpTime()
                                if let lineUpTime = appState.lineUpTime {
                                    flightPlanManager.updateDepartureTimeFromLineUp(lineUpTime)
                                }
                                pulseActionButton = false
                                if allItemsChecked { triggerNextButtonPulse() }
                            },
                            onLineUpUpdate: {
                                appState.recordLineUpTime()
                                if let lineUpTime = appState.lineUpTime {
                                    flightPlanManager.updateDepartureTimeFromLineUp(lineUpTime)
                                }
                            },
                            onEngineShutdown: {
                                appState.recordEngineShutdown()
                                pulseActionButton = false
                                if appState.settings.logEngineHours {
                                    hourMeterStopInitialValue = ""
                                    showHourMeterStop = true
                                }
                                if allItemsChecked { triggerNextButtonPulse() }
                            },
                            onEngineShutdownUpdate: {
                                appState.recordEngineShutdown()
                                if appState.settings.logEngineHours {
                                    if let prevEnd = appState.currentFlight?.engineHourEnd {
                                        let prevFormat = appState.currentFlight?.engineHourEndInputFormat ?? "decimal"
                                        hourMeterStopInitialValue = prevFormat == "time"
                                            ? Flight.formatHoursTime(prevEnd)
                                            : Flight.formatHoursDecimal(prevEnd)
                                    } else {
                                        hourMeterStopInitialValue = ""
                                    }
                                    showHourMeterStop = true
                                }
                            },
                            onGoAround: {
                                appState.recordGoAround()
                                pulseActionButton = false
                                pulseNextButton = false
                                allItemsChecked = false
                            },
                            onTouchAndGo: {
                                appState.recordTouchAndGo()
                                pulseActionButton = false
                                pulseNextButton = false
                                allItemsChecked = false
                            },
                            onFullStop: {
                                appState.recordFullStop()
                                pulseActionButton = false
                                pulseNextButton = false
                                allItemsChecked = false
                            },
                            onLanded: {
                                appState.recordLanding()
                                pulseActionButton = false
                                if allItemsChecked { triggerNextButtonPulse() }
                            },
                            onLandedUpdate: { appState.updateLandingTime() },
                            onBriefingTap: { briefingType in
                                switch briefingType {
                                case .departure: openReference(.departureBriefing)
                                case .approach: openReference(.approachBriefing)
                                }
                            },
                            onTapToAdvance: { handleChecklistTap(scrollProxy: scrollProxy) },
                            onAllItemsCompleted: { },
                            engineStartTime: appState.formattedEngineStartTime,
                            lineUpTime: appState.formattedLineUpTime,
                            landingTime: appState.formattedLandingTime,
                            engineShutdownTime: appState.formattedEngineShutdownTime,
                            goAroundCount: appState.currentFlight?.goAroundCount ?? 0,
                            touchAndGoCount: appState.currentFlight?.touchAndGoCount ?? 0,
                            fullStopCount: appState.currentFlight?.fullStopCount ?? 0,
                            stepByStepEnabled: appState.settings.stepByStepHighlighting,
                            learningModeEnabled: appState.settings.learningMode,
                            highlightedItemIndex: appState.getHighlightedItem(for: appState.currentPhase),
                            pulseActionButton: pulseActionButton,
                            isCompact: true,
                            checklistLanguage: appState.settings.checklistLanguage.resolvedLanguage,
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
                            hiddenItemsRevealed: $hiddenItemsRevealed
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                        .id("checklistContent")

                        Color.clear
                            .frame(height: 1)
                            .id("bottomAnchor")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if appState.settings.stepByStepHighlighting {
                        handleChecklistTap(scrollProxy: scrollProxy)
                    }
                }
                .onChange(of: scrollToBottom) { _, shouldScroll in
                    if shouldScroll {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scrollProxy.scrollTo("actionButton", anchor: .center)
                        }
                        scrollToBottom = false
                    }
                }
            }
            .background(Color.cockpitBackground)

            // Compact navigation bar
            compactNavigationBar
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.panelBackground)
        }
    }

    // MARK: - Compact Header Bar (iPhone)

    private var compactHeaderBar: some View {
        HStack(spacing: 8) {
            // Aircraft identifier with long-press to abandon
            abandonableAircraftIdentifier(iconSize: 14, isCompact: true)

            Spacer()

            // Phase indicator (tappable)
            Button(action: { showPhaseSelector = true }) {
                HStack(spacing: 4) {
                    Text("\(appState.currentPhase.rawValue + 1)/\(ChecklistPhase.allCases.count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondaryText)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondaryText)
                }
            }

            Spacer()

            // Flight duration
            HStack(spacing: 4) {
                StatusIndicator(.active, size: 8)
                Text(appState.flightDuration)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationGreen)
                    .id(timerTrigger)
            }

            // Flight info button
            Button(action: { showFlightInfo = true }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.secondaryText)
            }
        }
    }

    // MARK: - Compact Instrument Bar (iPhone)

    private var compactInstrumentBar: some View {
        HStack(spacing: 16) {
            // Speed indicator (compact)
            if let targetSpeed = appState.activeChecklist.targetSpeed(for: appState.currentPhase) {
                CompactSpeedView(
                    speedKnots: locationManager.displaySpeedKnots,
                    targetSpeed: targetSpeed,
                    stallSpeed: appState.activeChecklist.stallSpeed,
                    gpsSignalStatus: locationManager.gpsSignalStatus,
                    estimatedAirspeed: estimatedAirspeed,
                    stallAlertEnabled: appState.settings.stallAlertSound
                )
            }

            Spacer()

            // Altimeter (compact)
            CompactAltimeterView(
                altitudeFeet: locationManager.currentAltitudeFeet,
                gpsSignalStatus: locationManager.gpsSignalStatus
            )
        }
    }

    // MARK: - Compact Navigation Bar (iPhone)

    private var compactNavigationBar: some View {
        HStack(spacing: 12) {
            // Previous button
            Button(action: { appState.previousPhase() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(appState.canGoToPreviousPhase ? .primaryText : .dimText)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(appState.canGoToPreviousPhase ? Color.aviationBlue : Color.gray.opacity(0.3))
                    )
            }
            .disabled(!appState.canGoToPreviousPhase)

            // Navigation mode button (compact)
            Button(action: { showNavigationMode = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "map")
                        .font(.system(size: 14))
                    Text(L10n.Button.nav)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.aviationBlue, lineWidth: 2)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.aviationBlue.opacity(0.2)))
                )
            }

            // Speeds button
            Button(action: { openReference(.vSpeeds) }) {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 14))
                    Text(L10n.Button.speeds)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.aviationBlue, lineWidth: 2)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.aviationBlue.opacity(0.2)))
                )
            }

            Spacer()

            // Right side: END FLIGHT or NEXT
            if appState.isLastPhase {
                Button(action: { showEndFlightAlert = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.checkered")
                            .font(.system(size: 14))
                        Text(L10n.Button.end)
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.aviationRed)
                    )
                }
                .modifier(PulseModifier(isActive: pulseNextButton && allItemsChecked))
            } else {
                Button(action: {
                    pulseNextButton = false
                    pulseActionButton = false
                    allItemsChecked = false
                    appState.nextPhase()
                }) {
                    HStack(spacing: 4) {
                        Text(L10n.Button.next)
                            .font(.system(size: 14, weight: .bold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(appState.canGoToNextPhase ? .primaryText : .dimText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(appState.canGoToNextPhase ? Color.aviationGreen : Color.gray.opacity(0.3))
                    )
                }
                .disabled(!appState.canGoToNextPhase)
                .modifier(PulseModifier(isActive: pulseNextButton && allItemsChecked && !currentPhaseNeedsAction))
            }
        }
    }

    private func handleChecklistTap(scrollProxy: ScrollViewProxy) {
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
                // Scroll to show the action button
                scrollToBottom = true
            } else {
                // No action needed or already done, pulse NEXT button
                triggerNextButtonPulse()
            }
        } else {
            appState.advanceHighlightedItem(learningMode: effectiveLearningMode)
        }
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

    private func startAbandonFlightTimer() {
        abandonFlightProgress = 0
        abandonFlightTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            abandonFlightProgress += 0.05 / 1.5 // 1.5 seconds total
            if abandonFlightProgress >= 1.0 {
                timer.invalidate()
                abandonFlightTimer = nil
                abandonFlightProgress = 0
                // Haptic feedback
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.warning)
                showAbandonFlightAlert = true
            }
        }
    }

    private func cancelAbandonFlightTimer() {
        abandonFlightTimer?.invalidate()
        abandonFlightTimer = nil
        withAnimation(.easeOut(duration: 0.2)) {
            abandonFlightProgress = 0
        }
    }

    /// Creates an airplane identifier section with long press to abandon gesture
    /// Both the airplane icon and the call sign are tappable
    private func abandonableAircraftIdentifier(iconSize: CGFloat, isCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 4 : 8) {
            // Progress ring behind the icon. The ring footprint is RESERVED at all times (fixed frame)
            // so it appearing on press-and-hold doesn't enlarge the icon and shift the top bar. (3.5 fix)
            ZStack {
                if abandonFlightProgress > 0 {
                    Circle()
                        .stroke(Color.aviationRed.opacity(0.3), lineWidth: isCompact ? 2 : 3)

                    Circle()
                        .trim(from: 0, to: abandonFlightProgress)
                        .stroke(Color.aviationRed, style: StrokeStyle(lineWidth: isCompact ? 2 : 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }

                Image(systemName: "airplane")
                    .font(.system(size: iconSize))
                    .foregroundColor(abandonFlightProgress > 0 ? .aviationRed : .aviationGold)
            }
            .frame(width: iconSize + (isCompact ? 8 : 12), height: iconSize + (isCompact ? 8 : 12))

            HStack(spacing: 4) {
                Text(appState.activeChecklist.registration)
                    .font(isCompact ? .system(size: 14, weight: .semibold) : .headerText)
                    .foregroundColor(abandonFlightProgress > 0 ? .aviationRed : .primaryText)

                // Circuit mode indicator
                if appState.isCircuitMode {
                    Text(L10n.Flight.forCircuits)
                        .font(isCompact ? .system(size: 11, weight: .medium) : .system(size: 13, weight: .medium))
                        .foregroundColor(.aviationAmber)
                }
            }
        }
        .contentShape(Rectangle()) // Make entire area tappable
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if abandonFlightTimer == nil {
                        startAbandonFlightTimer()
                    }
                }
                .onEnded { _ in
                    cancelAbandonFlightTimer()
                }
        )
    }

    // MARK: - Side Panel

    @ViewBuilder
    private var sidePanel: some View {
        if let reference = activeReference {
            // Pattern B (iPad landscape): the reference popup takes over the right column over the map;
            // the checklist stays live on the left, back/close restores the map. (Phase 3.1)
            HUDReferencePanel(
                reference: reference,
                presentation: .docked,
                locationManager: locationManager,
                briefingContext: reference.isBriefing ? briefingContext : nil,
                aglFeet: reference == .vSpeeds ? currentAGLFeet : nil,
                onClose: closeReference
            )
            .padding(12)
            .transition(.opacity)
        } else {
            VStack(spacing: 10) {
                // Persistent map (tall — fills the slack); NEAREST strip + NAV chip overlaid. Tap → full map.
                if appState.isFlightActive {
                    miniMapContent
                        .frame(maxHeight: .infinity)
                }

                // Hold-to-confirm GO-AROUND / T&G / FULL-STOP for the relevant phases (empty otherwise).
                eventActionsRow

                // Phase-aware tiles (V-SPEEDS / briefings).
                phaseContextZone
            }
            .padding(12)
        }
    }

    // MARK: - HUD reference popups (Pattern B)

    /// Open a reference popup in the HUD context slot (docked column on iPad landscape, bottom drawer
    /// on iPad portrait / iPhone). Animated so the docked swap cross-fades and the drawer slides up.
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

    /// The bottom-drawer presentation of a reference popup for iPad portrait / iPhone: a dimming scrim
    /// (tap to dismiss) with the cockpit-themed panel rising from the bottom, leaving the instruments
    /// and current checklist item visible above. (Phase 3.1)
    @ViewBuilder
    private func referenceDrawerOverlay(maxHeight: CGFloat) -> some View {
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
                    locationManager: locationManager,
                    briefingContext: reference.isBriefing ? briefingContext : nil,
                    aglFeet: reference == .vSpeeds ? currentAGLFeet : nil,
                    onClose: closeReference
                )
                .frame(maxHeight: maxHeight)
                .transition(.move(edge: .bottom))
            }
        }
    }

    // MARK: - Mini-Map (iPad side panel)

    /// The persistent glance mini-map, wrapped as a button that opens the full nav map. The map
    /// itself has hit-testing disabled (it follows programmatically), so the whole tile is one big,
    /// discoverable NAV target. (Phase 3.1)
    /// The persistent map tile, filling whatever frame the caller gives it (tall in the landscape
    /// right column, a band in portrait). Tapping it opens the full nav map; the NEAREST-frequency
    /// strip is overlaid along the bottom. (Phase 3.1 HUD rebuild)
    private var miniMapContent: some View {
        Button {
            showNavigationMode = true
        } label: {
            FlightMiniMap(
                points: appState.currentFlight?.gpsTrack ?? [],
                currentCoordinate: locationManager.currentLocation?.coordinate,
                layer: appState.navigationMapState.selectedLayer
            )
            .allowsHitTesting(false)
            .overlay(alignment: .topTrailing) {
                // Affordance chip: signals the tile is tappable → full map.
                HStack(spacing: 4) {
                    Image(systemName: "map.fill").font(.system(size: 9))
                    Text(L10n.Button.nav).font(.system(size: 11, weight: .semibold))
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9))
                }
                .foregroundColor(.primaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                hudNearestStrip.allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Button.nav)
        .accessibilityHint("Opens the full navigation map")
    }

    /// NEAREST-airport frequency strip overlaid on the map (e.g. "LSZB TWR 121.075"). Throttled via a
    /// coarse-location key so the spatial query doesn't run on every frame. Hidden until data loads.
    @ViewBuilder
    private var hudNearestStrip: some View {
        if let text = nearestFreqText {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 11))
                Text("NEAREST").font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 8)
                Text(text).font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            .foregroundColor(.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.62))
        }
    }

    /// ~1 nm location bucket so the NEAREST spatial query only recomputes when the aircraft actually
    /// moves a meaningful distance, not on every timer tick / location publish.
    private var coarseLocationKey: String {
        guard let c = locationManager.currentLocation?.coordinate else { return "none" }
        return "\(Int((c.latitude * 50).rounded()))_\(Int((c.longitude * 50).rounded()))"
    }

    private func updateNearestFrequency() {
        guard let coord = locationManager.currentLocation?.coordinate, airportDataService.isDataAvailable else {
            nearestFreqText = nil
            return
        }
        let nearby = airportDataService.findNearestAirports(to: coord, limit: 6, maxDistanceNm: 40)
        for airport in nearby {
            let freqs = airportDataService.getFrequencies(for: airport.ident)
            let pick = freqs.first(where: { $0.type == "TWR" })
                ?? freqs.first(where: { ["APP", "ATIS", "GND"].contains($0.type) })
                ?? freqs.first
            if let f = pick {
                nearestFreqText = "\(airport.ident) \(f.type) \(f.formattedFrequency)"
                return
            }
        }
        nearestFreqText = nil
    }

    // MARK: - Flight Info Panel
    
    private var gpsStatusColor: Color {
        // PR-01: an ACTIVE flight that isn't recording GPS is an alarm state (the track is being
        // lost), never a subtle dim. Dim only applies when no flight is active.
        if appState.isFlightActive && !locationManager.isTracking { return .aviationRed }
        guard locationManager.isTracking else { return .dimText }
        switch locationManager.gpsSignalStatus {
        case .good: return .aviationGreen
        case .degraded: return .orange
        case .lost: return .aviationRed
        }
    }

}

// MARK: - Time Info Row

struct TimeInfoRow: View {
    let icon: String
    let label: String
    let time: String
    let color: Color
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            Text(label)
                .font(.captionText)
                .foregroundColor(.secondaryText)
            Spacer()
            Text(time)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.primaryText)
        }
    }
}

// MARK: - Phase Row Button

/// A compact segmented phase progress bar for the HUD top region: one segment per phase, colored by
/// completion status, the current phase taller + gold. Tapping a segment jumps to that phase — this is
/// the back/forward navigation in the revamped HUD (replacing the PREV button and the phase list).
/// (Phase 3.1)
struct PhaseProgressBar: View {
    let phases: [ChecklistPhase]
    let currentPhase: ChecklistPhase
    let status: (ChecklistPhase) -> PhaseCompletionStatus
    let onSelect: (ChecklistPhase) -> Void
    var isCircuitMode: Bool = false

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
        VStack(spacing: 3) {
            if !loopPhases.isEmpty {
                circuitBracket
            }
            HStack(spacing: 3) {
                ForEach(phases, id: \.self) { phase in
                    let isCurrent = phase == currentPhase
                    Button { onSelect(phase) } label: {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: phase, isCurrent: isCurrent))
                            .frame(height: isCurrent ? 8 : 5)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(phase.shortTitle)
                    .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
                }
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
                        Rectangle().fill(Color.altimeterBlue).frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    if phase == loopPhases.first {
                        Rectangle().fill(Color.altimeterBlue).frame(width: 2, height: 7)
                    }
                }
                .overlay(alignment: .trailing) {
                    if phase == loopPhases.last {
                        Rectangle().fill(Color.altimeterBlue).frame(width: 2, height: 7)
                    }
                }
                .overlay {
                    if phase == loopMiddle {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.altimeterBlue)
                            .padding(.horizontal, 3)
                            .background(Color.panelBackground)
                    }
                }
            }
        }
        .frame(height: 9)
        .accessibilityLabel("Circuit pattern repeats from climb to landing")
    }

    private func color(for phase: ChecklistPhase, isCurrent: Bool) -> Color {
        if isCurrent { return .aviationGold }
        switch status(phase) {
        case .completed: return .aviationGreen
        case .skipped: return .orange
        case .missingAction: return .aviationRed
        case .notStarted: return .dimText.opacity(0.3)
        }
    }
}

struct PhaseRowButton: View {
    let phase: ChecklistPhase
    let isActive: Bool
    let status: PhaseCompletionStatus
    let action: () -> Void
    
    var statusColor: Color {
        if isActive {
            return .aviationGold
        }
        switch status {
        case .completed:
            return .aviationGreen
        case .skipped:
            return .orange
        case .missingAction:
            return .aviationRed
        case .notStarted:
            return .dimText.opacity(0.3)
        }
    }
    
    var textColor: Color {
        if isActive {
            return .aviationGold
        }
        switch status {
        case .completed:
            return .primaryText
        case .skipped:
            return .orange
        case .missingAction:
            return .aviationRed
        case .notStarted:
            return .dimText
        }
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                
                // Phase name
                Text(phase.shortTitle)
                    .font(.system(size: 12, weight: isActive ? .bold : .regular))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                
                Spacer()
                
                // Page indicator
                Text("P\(phase.pageNumber)")
                    .font(.system(size: 10))
                    .foregroundColor(.dimText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.aviationGold.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Phase Selector Sheet

struct PhaseSelectorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            List(ChecklistPhase.allCases) { phase in
                Button(action: {
                    appState.goToPhase(phase)
                    dismiss()
                }) {
                    HStack {
                        // Status indicator
                        Circle()
                            .fill(statusColor(for: phase))
                            .frame(width: 10, height: 10)
                        
                        Text(phase.title)
                            .foregroundColor(phase == appState.currentPhase ? .aviationGold : .primaryText)
                        Spacer()
                        if phase == appState.currentPhase {
                            Image(systemName: "checkmark")
                                .foregroundColor(.aviationGold)
                        }
                        Text(L10n.Sheet.page(phase.pageNumber))
                            .font(.captionText)
                            .foregroundColor(.secondaryText)
                    }
                }
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
            return .aviationGold
        }
        switch appState.getPhaseStatus(phase) {
        case .completed:
            return .aviationGreen
        case .skipped:
            return .orange
        case .missingAction:
            return .aviationRed
        case .notStarted:
            return .dimText.opacity(0.3)
        }
    }
}

// MARK: - Speed Reference Sheet

struct SpeedReferenceSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    private var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                SpeedReferenceView(activeChecklist: appState.activeChecklist)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
            .scrollDisabled(isIPad)
            .background(Color.cockpitBackground)
            .navigationTitle(L10n.Sheet.speedReference)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { dismiss() }
                }
            }
        }
        .presentationDetents(isIPad ? [.height(480)] : [.fraction(0.6)])
        .preferredColorScheme(.dark)
    }
}

// MARK: - Compact Speed View (iPhone)

struct CompactSpeedView: View {
    let speedKnots: Double // Ground speed in knots
    let targetSpeed: Int
    let stallSpeed: Int // Stall speed (clean) of the active aircraft
    let gpsSignalStatus: GPSSignalStatus
    var estimatedAirspeed: Double? = nil // Optional estimated airspeed in knots
    var stallAlertEnabled: Bool = false // Fire aural+haptic alert on stall, mirroring the iPad indicator (UX-02)

    /// The speed value to display (estimated airspeed if available, otherwise ground speed)
    private var displaySpeed: Double {
        estimatedAirspeed ?? speedKnots
    }

    /// Whether we're showing estimated airspeed
    private var showingEstimatedAirspeed: Bool {
        estimatedAirspeed != nil
    }

    // Delegates to the shared pure function so the iPhone annunciates a stall identically to the
    // iPad — crucially, only from a reliable airspeed estimate, never raw GPS ground speed. (UX-02)
    private var speedState: SpeedState {
        switch SpeedIndicatorView.annunciationState(
            displaySpeed: displaySpeed, targetSpeed: targetSpeed, stallSpeed: stallSpeed,
            showingEstimatedAirspeed: showingEstimatedAirspeed, gpsSignalStatus: gpsSignalStatus) {
        case .onTarget: return .onTarget
        case .offTarget: return .offTarget
        case .stall: return .stall
        }
    }

    enum SpeedState {
        case onTarget, offTarget, stall
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isNightMode) private var nightMode
    @State private var isFlashing = false

    /// Whether to show failure flag overlay
    private var showFailureFlag: Bool {
        gpsSignalStatus == .degraded || gpsSignalStatus == .lost
    }

    /// Failure level for the flag
    private var failureLevel: InstrumentFailureFlag.FailureLevel {
        gpsSignalStatus == .lost ? .lost : .degraded
    }

    var body: some View {
        HStack(spacing: 8) {
            // Speed type label (GS / EST. IAS). The stall warning now lives inside the value box as
            // a legible annunciation, matching the iPad instrument. (UX-02)
            VStack(alignment: .trailing, spacing: 2) {
                Text(showingEstimatedAirspeed ? L10n.Speed.ias : L10n.Speed.gs)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(showingEstimatedAirspeed ? .aviationAmber : .dimText)
            }

            // Speed value with failure flag, plus the color-blind-safe proximity bar beneath it
            VStack(spacing: 3) {
                ZStack {
                    VStack(spacing: 0) {
                        if gpsSignalStatus != .lost {
                            // Static, always-on STALL annunciation inside the value box — heavy white on
                            // the red fill, never dependent on the flash or colour alone (and steady under
                            // Reduce Motion), at parity with the iPad indicator. (UX-02 / UX-18)
                            if speedState == .stall {
                                Text("STALL")
                                    .font(.system(size: 13, weight: .heavy))
                                    .foregroundColor(.white)
                            }
                            HStack(spacing: 4) {
                                // Live airspeed is primary flight data — give it the largest, heaviest type
                                // in the in-flight bar so it's the glance focal point. (UX-15)
                                Text("\(Int(max(0, displaySpeed)))")
                                    .font(.system(size: 30, weight: .heavy, design: .monospaced))
                                    .foregroundColor(textColor)
                                    .minimumScaleFactor(0.6)
                                    .lineLimit(1)
                                Text(L10n.Unit.kt)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(textColor.opacity(0.8))
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(backgroundColor)
                    )

                    // Failure flag overlay
                    if showFailureFlag {
                        InstrumentFailureFlag(level: failureLevel, size: CGSize(width: 70, height: 40))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(minWidth: 70, minHeight: 40)

                // Same proximity bar as the iPad instrument: WIDTH = closeness to target, COLOR =
                // state. Hidden when GPS is lost; accessibilityHidden (the value already speaks the
                // state in words). (Phase 3.1)
                if gpsSignalStatus != .lost {
                    InstrumentTargetBar(
                        fraction: SpeedIndicatorView.targetBarFraction(displaySpeed: displaySpeed, targetSpeed: targetSpeed),
                        state: SpeedIndicatorView.barState(for: mappedSpeedState)
                    )
                    .frame(width: 70)
                    .accessibilityHidden(true)
                }
            }

            // Target indicator (always shown)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Speed.tgt)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.dimText)
                HStack(spacing: 2) {
                    Image(systemName: targetIcon)
                        .font(.system(size: 10))
                    Text("\(targetSpeed)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                .foregroundColor(.secondaryText)
            }
        }
        .onAppear {
            if speedState == .stall {
                startFlashing()
                if stallAlertEnabled { StallAlert.shared.trigger() }
            }
        }
        .onChange(of: speedState) { _, newState in
            if newState == .stall {
                startFlashing()
                if stallAlertEnabled { StallAlert.shared.trigger() }
            } else {
                stopFlashing()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showingEstimatedAirspeed ? "Estimated airspeed" : "Ground speed")
        .accessibilityValue(SpeedIndicatorView.accessibilityValue(
            displaySpeed: Int(displaySpeed), targetSpeed: targetSpeed, state: mappedSpeedState,
            estimated: showingEstimatedAirspeed, gpsLost: gpsSignalStatus == .lost))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Maps to the shared instrument state so the VoiceOver wording is identical (and tested). (UX-10)
    private var mappedSpeedState: SpeedIndicatorView.SpeedState {
        switch speedState {
        case .onTarget: return .onTarget
        case .offTarget: return .offTarget
        case .stall: return .stall
        }
    }

    private var backgroundColor: Color {
        // Solid high-contrast fills (black text) for sunlight legibility (UX-17); low-luminance
        // variants at night (UX-09).
        switch speedState {
        case .onTarget: return nightMode ? .nightOnTarget : .aviationGreen
        case .offTarget: return nightMode ? .nightOffTarget : .orange
        case .stall:
            if nightMode { return .nightStall }
            if reduceMotion { return Color.aviationRed } // steady solid red under Reduce Motion (UX-18)
            return isFlashing ? Color.aviationRed : Color.aviationRed.opacity(0.7)
        }
    }

    private var textColor: Color {
        if nightMode { return .nightInstrumentText }
        switch speedState {
        case .onTarget, .offTarget: return .black
        case .stall: return .white
        }
    }

    private var targetIcon: String {
        let speedInt = Int(displaySpeed)
        if speedInt < targetSpeed - 5 { return "arrow.up" }
        else if speedInt > targetSpeed + 5 { return "arrow.down" }
        else { return "checkmark" }
    }

    private func startFlashing() {
        guard !reduceMotion else { return } // no repeatForever flash under Reduce Motion (UX-18)
        withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) {
            isFlashing = true
        }
    }

    private func stopFlashing() {
        withAnimation(.easeInOut(duration: 0.1)) {
            isFlashing = false
        }
    }
}

// MARK: - Compact Altimeter View (iPhone)

struct CompactAltimeterView: View {
    let altitudeFeet: Double
    let gpsSignalStatus: GPSSignalStatus
    @Environment(\.isNightMode) private var nightMode
    private var altimeterFill: Color { nightMode ? .nightAltimeterBackground : .altimeterBlue }
    private var altimeterText: Color { nightMode ? .nightInstrumentText : .black }

    private var altitudeFontSize: CGFloat {
        // Sized to match the elevated airspeed readout — altitude is primary flight data too. (UX-15)
        let altitude = Int(altitudeFeet)
        let digitCount = String(abs(altitude)).count
        switch digitCount {
        case 1, 2: return 30
        case 3: return 27
        case 4: return 22
        default: return 17
        }
    }

    /// Whether to show failure flag overlay
    private var showFailureFlag: Bool {
        gpsSignalStatus == .degraded || gpsSignalStatus == .lost
    }

    /// Failure level for the flag
    private var failureLevel: InstrumentFailureFlag.FailureLevel {
        gpsSignalStatus == .lost ? .lost : .degraded
    }

    var body: some View {
        HStack(spacing: 8) {
            // Altitude value with failure flag
            ZStack {
                HStack(spacing: 4) {
                    if gpsSignalStatus != .lost {
                        Text("\(Int(max(0, altitudeFeet)))")
                            .font(.system(size: altitudeFontSize, weight: .bold, design: .monospaced))
                            .foregroundColor(altimeterText)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text(L10n.Unit.ft)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(altimeterText.opacity(0.7))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(altimeterFill)
                )

                // Failure flag overlay
                if showFailureFlag {
                    InstrumentFailureFlag(level: failureLevel, size: CGSize(width: 80, height: 40))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(minWidth: 80, minHeight: 40)

            Text(L10n.Speed.msl)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Altitude")
        .accessibilityValue(AltimeterView.accessibilityValue(
            altitudeFeet: Int(altitudeFeet), gpsLost: gpsSignalStatus == .lost))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Flight Mini-Map (persistent HUD glance map)

/// A lightweight, glance-only mini-map for the in-flight HUD. It recenters on the aircraft, draws the
/// flight track, and **mirrors the chart layer the pilot picked in the full nav map** — ICAO+Segelflug,
/// Landeskarten, SWISSIMAGE, or Apple standard/satellite. Swisstopo charts are content-replacing, so
/// MapKit drops the Apple Maps logo (oversized on a small map) — they have full coverage over
/// Switzerland; outside it the area is blank rather than Apple tiles. Deliberately lightweight (no
/// airspace / airport / flight-plan overlays); tap it (handled by the caller) to open the full
/// `NavigationMapView`. (Phase 3.1)
struct FlightMiniMap: UIViewRepresentable {
    /// The live flight track; the polyline is rebuilt only when the point count changes.
    let points: [GPSPoint]
    /// The aircraft's current position; the map recenters on it (the caller disables interaction).
    var currentCoordinate: CLLocationCoordinate2D?
    /// Mirrors `AppState.navigationMapState.selectedLayer` (live, via @Published) so the mini-map
    /// shows the same chart the pilot chose in the full nav map.
    var layer: MapLayerType

    /// ~20 km across. Still within ICAO/Segelflugkarte coverage (their tiles stop at zoom 12); the
    /// finer swisstopo layers (Landeskarten / SWISSIMAGE) reach zoom 18, so they sharpen further in.
    private static let viewSpanMeters: CLLocationDistance = 20_000

    private static let switzerlandCenter = CLLocationCoordinate2D(latitude: 46.8, longitude: 8.2)

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.overrideUserInterfaceStyle = .dark
        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.pointOfInterestFilter = .excludingAll

        configureLayer(mapView, layer: layer)
        context.coordinator.currentLayer = layer

        // Center on Switzerland (or the first known position) until a fix arrives — avoids an ocean flash.
        let center = currentCoordinate ?? Self.switzerlandCenter
        mapView.setRegion(MKCoordinateRegion(center: center,
                                             latitudinalMeters: Self.viewSpanMeters,
                                             longitudinalMeters: Self.viewSpanMeters), animated: false)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator

        // Re-skin when the pilot switches the nav layer (live, via the @Published navigationMapState).
        if coordinator.currentLayer != layer {
            coordinator.currentLayer = layer
            configureLayer(mapView, layer: layer)
        }

        // Rebuild ONLY the track polyline when the point count changes — never the tile overlay, and
        // never an O(n) teardown on every location publish. (mirrors FlightMapView's pattern)
        if coordinator.builtPointCount != points.count {
            coordinator.builtPointCount = points.count
            mapView.removeOverlays(mapView.overlays.filter { $0 is MKPolyline })
            if points.count >= 2 {
                let coordinates = points.map { $0.coordinate }
                mapView.addOverlay(MKPolyline(coordinates: coordinates, count: coordinates.count), level: .aboveLabels)
            }
        }

        // Follow the aircraft by recentering (the caller disables interaction, so we own the camera).
        // setCenter preserves the span set above, so the chart zoom stays within tile coverage.
        if let coordinate = currentCoordinate {
            mapView.setCenter(coordinate, animated: false)
        }
    }

    /// Sets the base map + swisstopo tile overlay for `layer`. The chart tile is INSERTED below any
    /// existing track polyline (so the gold track stays on top). Swisstopo charts are CONTENT-REPLACING
    /// (`canReplaceMapContent = true`, matching the waypoint picker) so MapKit drops the oversized Apple
    /// Maps attribution logo on this small glance map — swisstopo has full coverage over Switzerland;
    /// outside it the area is blank rather than Apple tiles. Reuses the app's standalone overlays.
    private func configureLayer(_ mapView: MKMapView, layer: MapLayerType) {
        mapView.removeOverlays(mapView.overlays.filter { $0 is MKTileOverlay })

        switch layer {
        case .standard:
            mapView.mapType = .standard
        case .satellite:
            mapView.mapType = .hybrid
        case .icao:
            mapView.mapType = .standard
            let chart = ICAOSegelflugkarteTileOverlay()  // ICAO z7-11 + Segelflugkarte z11-12
            chart.canReplaceMapContent = true
            mapView.insertOverlay(chart, at: 0, level: .aboveLabels)
        case .landeskarten, .swissimage:
            mapView.mapType = .standard
            if let identifier = layer.swisstopoLayerIdentifier {
                let chart = SwisstopoTileOverlay(layerIdentifier: identifier, tileExtension: layer.tileExtension)
                chart.canReplaceMapContent = true
                mapView.insertOverlay(chart, at: 0, level: .aboveLabels)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MKMapViewDelegate {
        /// Track length the polyline was last built for (-1 = not yet built).
        var builtPointCount = -1
        /// The layer currently configured on the map, to detect live switches.
        var currentLayer: MapLayerType?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(Color.aviationGold)
                renderer.lineWidth = 3
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Hold-to-Confirm Button

/// A press-and-hold button for consequential flight events (GO-AROUND, TOUCH & GO, FULL STOP). The
/// action fires only after a deliberate ~1 s hold — a fill sweeps to show progress and releasing
/// early cancels — so a stray cockpit touch can't trigger a go-around. VoiceOver activation fires
/// immediately (it's already a deliberate action). Optionally shows a running count. (Phase 3.1)
struct HoldToConfirmButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    var count: Int = 0
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    private let holdDuration: TimeInterval = 1.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.18))

            // Hold-progress fill.
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 12)
                    .fill(tint.opacity(0.5))
                    .frame(width: geo.size.width * progress)
            }

            RoundedRectangle(cornerRadius: 12).strokeBorder(tint, lineWidth: 2)

            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .bold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(L10n.ChecklistAction.holdToConfirm)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondaryText)
                }
                if count > 0 {
                    Spacer(minLength: 4)
                    Text("\(count)").font(.system(size: 17, weight: .heavy, design: .monospaced))
                }
            }
            .foregroundColor(.primaryText)
            .padding(.horizontal, 12)
        }
        .frame(height: 54)
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
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
        .accessibilityHint(L10n.ChecklistAction.holdToConfirm)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

// MARK: - Phase Context Tile

/// A compact, tappable quick-access tile for the phase-aware HUD zone: icon + label, with an optional
/// inline value (e.g. the phase target speed). Presentational; the caller supplies the action. (Phase 3.1)
struct PhaseContextTile: View {
    let title: String
    let systemImage: String
    /// Accent for the icon + label (e.g. green for V-SPEEDS, gold for BRIEFING), matching the concept.
    var tint: Color = .primaryText
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let value {
                    Text(value)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.primaryText)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement()
        .accessibilityLabel(value != nil ? "\(title), \(value!)" : title)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Flight Info Sheet (iPhone)

struct FlightInfoSheet: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var locationManager: LocationManager
    @Environment(\.dismiss) var dismiss
    @State private var detent: PresentationDetent = .large  // open extended

    private var gpsStatusColor: Color {
        // PR-01: a non-recording GPS during an active flight is an alarm, not a dim.
        if appState.isFlightActive && !locationManager.isTracking { return .aviationRed }
        guard locationManager.isTracking else { return .dimText }
        switch locationManager.gpsSignalStatus {
        case .good: return .aviationGreen
        case .degraded: return .orange
        case .lost: return .aviationRed
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
        if let t = appState.formattedEngineStartTime { rows.append((icon: "engine.combustion", color: .aviationGreen, label: L10n.Time.engineStart, value: t)) }
        if let t = appState.formattedLineUpTime { rows.append((icon: "airplane.departure", color: .aviationAmber, label: L10n.Time.takeoff, value: t)) }
        if let t = appState.formattedLandingTime { rows.append((icon: "airplane.arrival", color: .aviationBlue, label: L10n.Time.landing, value: t)) }
        if let t = appState.formattedEngineShutdownTime { rows.append((icon: "engine.combustion.fill", color: .aviationRed, label: L10n.Time.shutdown, value: t)) }
        return rows
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // Quick in-flight options — the most useful settings without leaving the flight.
                    // ("Options" is identical in EN/FR, so no separate localization entry is needed.)
                    settingsCard(title: "Options") {
                        toggleRow(L10n.Settings.learningMode, optionBinding(\.learningMode))
                        rowDivider
                        toggleRow(L10n.Settings.alwaysUseUTC, optionBinding(\.alwaysUseUTC))
                        rowDivider
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.Settings.theme)
                                .font(.system(size: 15))
                                .foregroundColor(.primaryText)
                            Picker(L10n.Settings.theme, selection: Binding(
                                get: { appState.settings.themePreference },
                                set: { appState.settings.themePreference = $0; appState.saveSettings() }
                            )) {
                                Text(L10n.Settings.themeAuto).tag(ThemePreference.auto)
                                Text(L10n.Settings.themeDay).tag(ThemePreference.day)
                                Text(L10n.Settings.themeSunlight).tag(ThemePreference.sunlight)
                                Text(L10n.Settings.themeNight).tag(ThemePreference.night)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }

                    settingsCard(title: L10n.GPS.status) {
                        HStack(spacing: 10) {
                            Image(systemName: "location.fill").foregroundColor(gpsStatusColor)
                            Text(L10n.GPS.signal).font(.system(size: 15)).foregroundColor(.primaryText)
                            Spacer()
                            Text(gpsStatusText).font(.system(size: 15, weight: .semibold)).foregroundColor(gpsStatusColor)
                        }
                        rowDivider
                        HStack(spacing: 10) {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                                .foregroundColor(.aviationBlue)
                            Text(L10n.GPS.pointsRecorded).font(.system(size: 15)).foregroundColor(.primaryText)
                            Spacer()
                            Text("\(appState.currentFlight?.gpsTrack.count ?? 0)")
                                .font(.system(size: 15, design: .monospaced)).foregroundColor(.secondaryText)
                        }
                    }

                    settingsCard(title: L10n.Flight.times) {
                        if timeEntries.isEmpty {
                            HStack {
                                Text(L10n.GPS.signalInactive).font(.system(size: 14)).foregroundColor(.dimText)
                                Spacer()
                            }
                        } else {
                            ForEach(Array(timeEntries.enumerated()), id: \.offset) { idx, row in
                                if idx > 0 { rowDivider }
                                HStack(spacing: 10) {
                                    Image(systemName: row.icon).foregroundColor(row.color).frame(width: 22)
                                    Text(row.label).font(.system(size: 15)).foregroundColor(.primaryText)
                                    Spacer()
                                    Text(row.value).font(.system(size: 15, design: .monospaced)).foregroundColor(.primaryText)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.cockpitBackground)
            .navigationTitle("HUD Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackground(Color.cockpitBackground)
        .preferredColorScheme(.dark)
    }

    // MARK: - Cockpit-styled section helpers

    @ViewBuilder
    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.secondaryText)
            VStack(spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundColor(.primaryText)
            Spacer()
            Toggle("", isOn: binding).labelsHidden().tint(.aviationGreen)
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
    }
}

// MARK: - HUD reference popups (Pattern B)

/// A reference popup that pairs with the live checklist (V-speeds, GPS, briefings). In the approved
/// A+B hybrid these render as Pattern B: docked into the iPad-landscape right column (over the map),
/// or as a cockpit-themed bottom drawer on iPad portrait / iPhone. (Phase 3.1 popup redesign)
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
        case .departureBriefing, .approachBriefing: return .aviationGold
        }
    }

    var isBriefing: Bool { self == .departureBriefing || self == .approachBriefing }
}

/// Shared cockpit-themed container for a reference popup. The SAME view renders in two presentations:
/// `.docked` (fills the iPad-landscape right column, back-arrow header restores the map) and `.drawer`
/// (a bottom drawer with a grabber + drag-down to dismiss, for iPad portrait / iPhone). The content is
/// identical in both — only the chrome differs. (Phase 3.1 popup redesign)
struct HUDReferencePanel: View {
    enum Presentation { case docked, drawer }

    let reference: HUDReference
    var presentation: Presentation = .docked
    @ObservedObject var locationManager: LocationManager
    var briefingContext: BriefingContext? = nil
    var aglFeet: Double? = nil
    let onClose: () -> Void

    @EnvironmentObject var appState: AppState

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
            .background(Color.panelBackground)
            .modifier(DrawerDragDismiss(enabled: presentation == .drawer, onClose: onClose))

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 22)
            }
        }
        .background(Color.panelBackground)
        .clipShape(corners)
        .overlay(corners.stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 10) {
            if presentation == .docked {
                Button(action: onClose) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(reference.tint)
                }
                .accessibilityLabel(L10n.Button.close)
            }
            Image(systemName: reference.systemImage)
                .font(.system(size: 14))
                .foregroundColor(reference.tint)
            Text(reference.title)
                .font(.system(size: 13, weight: .bold))
                .tracking(0.6)
                .foregroundColor(.primaryText)   // neutral title; the icon carries the accent (round 6)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondaryText)
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
                aglFeet: aglFeet
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
/// available through CoreLocation. Cockpit cards (no system List). (Phase 3.1 popup redesign)
struct GPSStatusContent: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var locationManager: LocationManager
    // Tap the value to switch units: Vertical defaults to metres, Altitude to feet. (round 6)
    @State private var verticalInFeet = false
    @State private var altitudeInMeters = false
    @State private var positionCopied = false

    /// When GPS is degraded/lost, a short reason shown under the status word ("why"). (round 6)
    private var statusReason: String? {
        guard locationManager.isTracking else { return nil }
        switch locationManager.gpsSignalStatus {
        case .good:
            return nil
        case .degraded:
            if let acc = locationManager.currentLocation?.horizontalAccuracy, acc >= 0 {
                return "Reduced accuracy · ± \(Int(acc.rounded())) m"
            }
            return "Weak signal"
        case .lost:
            if let ts = locationManager.currentLocation?.timestamp {
                return "No position update for \(Int(Date().timeIntervalSince(ts).rounded())) s"
            }
            return "No position fix"
        }
    }

    private var statusColor: Color {
        if appState.isFlightActive && !locationManager.isTracking { return .aviationRed }
        guard locationManager.isTracking else { return .dimText }
        switch locationManager.gpsSignalStatus {
        case .good: return .aviationGreen
        case .degraded: return .orange
        case .lost: return .aviationRed
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
                        .font(.system(size: 24))
                        .foregroundColor(statusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusText)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(statusColor)
                        Text(statusReason ?? L10n.GPS.signal)
                            .font(.system(size: 12))
                            .foregroundColor(statusReason == nil ? .secondaryText : statusColor)
                    }
                    Spacer(minLength: 0)
                }
                if locationManager.backgroundTrackingLimited {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.aviationAmber)
                        Text(L10n.GPS.backgroundLimited)
                            .foregroundColor(.aviationAmber)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13))
                }
            }
            .cardSection()

            // Advanced fix info — Vertical / Altitude tap to switch units; Position taps to copy.
            if let loc = locationManager.currentLocation {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    fixTile("Accuracy", loc.horizontalAccuracy >= 0 ? "± \(Int(loc.horizontalAccuracy.rounded())) m" : "—")
                    Button { verticalInFeet.toggle() } label: {
                        fixTile("Vertical", verticalAccuracyText(loc), trailing: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.plain)
                    fixTile("Fix time", fixTime(loc.timestamp))
                    Button { altitudeInMeters.toggle() } label: {
                        fixTile("Altitude (MSL)", altitudeText(loc), trailing: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.plain)
                    Button { copyPosition(loc) } label: {
                        fixTile("Position", positionText(loc), trailing: positionCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    fixTile(L10n.GPS.pointsRecorded, "\(appState.currentFlight?.gpsTrack.count ?? 0)")
                }
            }

            // Status guide
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.GPS.statusTitle.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(.secondaryText)
                guideRow(.aviationGreen, L10n.GPS.signalGood, L10n.GPS.statusGoodDesc)
                guideRow(.orange, L10n.GPS.signalDegraded, L10n.GPS.statusDegradedDesc)
                guideRow(.aviationRed, L10n.GPS.signalLost, L10n.GPS.statusLostDesc)
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
                    .font(.system(size: 11))
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 9))
                        .foregroundColor(.dimText)
                }
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.cockpitBackground)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        )
    }

    private func guideRow(_ color: Color, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(color)
                Text(desc).font(.system(size: 12)).foregroundColor(.secondaryText)
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

/// The V-speeds reference shown in the HUD panel: a scannable list (V-name accent · description muted ·
/// value bright white, right-aligned) with the phase-relevant speed(s) highlighted and Vne in red. The
/// climb highlight switches Vx → Vy at 300 ft AGL; cruise = Vc (or Va); descent = Va + Vbg. (round 6)
struct InFlightSpeedReference: View {
    let activeChecklist: ActiveChecklist
    let currentPhase: ChecklistPhase
    let aglFeet: Double?

    private var speeds: [SpeedReference] { activeChecklist.speeds }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(activeChecklist.registration)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondaryText)
                Spacer()
                Text("IAS · kt")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.dimText)
            }

            VStack(spacing: 5) {
                ForEach(speeds) { speed in
                    speedRow(speed)
                }
            }

            let crosswind = activeChecklist.crosswindLimits
            HStack {
                Text("Max crosswind")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondaryText)
                Spacer()
                Text("T/O \(crosswind.takeoff) · LDG \(crosswind.landing)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationAmber)
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
                .fill(highlighted ? (isVne ? Color.aviationRed : Color.aviationGold) : Color.clear)
                .frame(width: 3)
            Text(speed.name)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(isVne ? .aviationRed : .aviationGold)
                .frame(width: 58, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(speed.description)
                .font(.system(size: 12))
                .foregroundColor(.dimText)
                .lineLimit(1)
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(speed.value)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(isVne ? .aviationRed : .primaryText)
                Text("kt")
                    .font(.system(size: 11))
                    .foregroundColor(.dimText)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(highlighted ? (isVne ? Color.aviationRed.opacity(0.12) : Color.aviationGold.opacity(0.14)) : Color.clear)
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
        .environmentObject(AppState())
        .environmentObject(LocationManager())
        .environmentObject(WindDataService())
        .environmentObject(FlightPlanManager())
}
