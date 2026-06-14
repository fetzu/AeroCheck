import SwiftUI
import Combine
import CoreLocation
import MapKit

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
    @State private var showSpeedReference = false
    @State private var showEndFlightAlert = false
    @State private var showAbandonFlightAlert = false
    @State private var abandonFlightProgress: CGFloat = 0
    @State private var abandonFlightTimer: Timer?
    @State private var showDepartureBriefing = false
    @State private var showApproachBriefing = false
    @State private var showFlightInfo = false
    @State private var showNavigationMode = false
    @State private var timerTrigger = false
    @State private var pulseNextButton = false
    @State private var pulseActionButton = false
    @State private var allItemsChecked = false
    @State private var scrollToBottom = false
    @State private var nearestFreqText: String?

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
            onSelect: { appState.goToPhase($0) }
        )
    }

    /// Full-width HUD top bar: aircraft · tappable phase badge · counter ‖ timer · GPS · options.
    private var hudTopBar: some View {
        HStack(spacing: 12) {
            abandonableAircraftIdentifier(iconSize: 20, isCompact: false)

            Button(action: { showPhaseSelector = true }) {
                Text(appState.currentPhase.shortTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.aviationGold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.aviationGold.opacity(0.18)))
            }
            // Just the counter — the phase NAME is already in the badge, so "Phase" is redundant.
            Text("\(appState.currentPhase.rawValue + 1) / \(ChecklistPhase.allCases.count)")
                .font(.captionText)
                .foregroundColor(.secondaryText)

            Spacer()

            if companionConnectivityManager.connectionState == .connected {
                HStack(spacing: 4) {
                    Image(systemName: "iphone").font(.system(size: 12))
                    StatusIndicator(.active, size: 8)
                }
                .foregroundColor(.aviationGreen)
            }

            // Flight timer
            HStack(spacing: 6) {
                StatusIndicator(.active, size: 8)
                Text(appState.flightDuration)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationGreen)
                    .id(timerTrigger)
            }

            // GPS status
            HStack(spacing: 4) {
                Image(systemName: "location.fill")
                    .font(.system(size: 12))
                    .foregroundColor(gpsStatusColor)
                Text("GPS")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondaryText)
            }

            // Flight details / options (consolidates the GPS/points/times panel)
            Button(action: { showFlightInfo = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundColor(.secondaryText)
            }
            .accessibilityLabel(L10n.GPS.status)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if isCompactWidth(geometry) {
                // iPhone layout: full-width checklist with compact header
                VStack(spacing: 0) {
                    mainChecklistAreaCompact(geometry: geometry)
                }
            } else if geometry.size.height > geometry.size.width {
                // iPad PORTRAIT: full-width top bar + phase bar, then the vertical stack. (Phase 3.1 HUD)
                hudShell {
                    portraitLayout
                }
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
        .sheet(isPresented: $showSpeedReference) {
            SpeedReferenceSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showDepartureBriefing) {
            DepartureBriefingView(context: briefingContext)
        }
        .sheet(isPresented: $showApproachBriefing) {
            ApproachBriefingView(context: briefingContext)
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
                    headingDegrees: locationManager.currentCourseDegrees
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
                                    showDepartureBriefing = true
                                case .approach:
                                    showApproachBriefing = true
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
                            }
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
                .foregroundColor(appState.canGoToNextPhase ? .black : .dimText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(appState.canGoToNextPhase ? Color.aviationGold : Color.gray.opacity(0.3))
                )
            }
            .disabled(!appState.canGoToNextPhase)
            .modifier(PulseModifier(isActive: pulseNextButton && allItemsChecked && !currentPhaseNeedsAction))
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
        if phase.showsGoAroundButtons || phase.showsLandedButton {
            HStack(spacing: 10) {
                if phase.showsGoAroundButtons {
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
                value: appState.activeChecklist.targetSpeed(for: phase).map { "\($0)" },
                action: { showSpeedReference = true }
            )

            // Departure / approach briefing for the relevant phase clusters (always reachable here,
            // not only via the inline checklist button that scrolls away). The icon distinguishes
            // departure vs approach.
            if phase.briefingType == .departure {
                PhaseContextTile(
                    title: "BRIEFING",
                    systemImage: "airplane.departure",
                    tint: .aviationGold,
                    action: { showDepartureBriefing = true }
                )
            }
            if phase.briefingType == .approach {
                PhaseContextTile(
                    title: "BRIEFING",
                    systemImage: "airplane.arrival",
                    tint: .aviationGold,
                    action: { showApproachBriefing = true }
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
                                case .departure: showDepartureBriefing = true
                                case .approach: showApproachBriefing = true
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
                            }
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
            Button(action: { showSpeedReference = true }) {
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
        let visibleCount = appState.activeChecklist.visibleItemCount(
            for: appState.currentPhase,
            learningMode: appState.settings.learningMode
        )
        let currentIndex = appState.getHighlightedItem(for: appState.currentPhase)
        
        if currentIndex >= visibleCount - 1 {
            // At last item, mark it complete
            appState.markLastItemComplete()
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
            appState.advanceHighlightedItem()
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
            // Progress ring behind the icon
            ZStack {
                if abandonFlightProgress > 0 {
                    Circle()
                        .stroke(Color.aviationRed.opacity(0.3), lineWidth: isCompact ? 2 : 3)
                        .frame(width: iconSize + (isCompact ? 8 : 12), height: iconSize + (isCompact ? 8 : 12))

                    Circle()
                        .trim(from: 0, to: abandonFlightProgress)
                        .stroke(Color.aviationRed, style: StrokeStyle(lineWidth: isCompact ? 2 : 3, lineCap: .round))
                        .frame(width: iconSize + (isCompact ? 8 : 12), height: iconSize + (isCompact ? 8 : 12))
                        .rotationEffect(.degrees(-90))
                }

                Image(systemName: "airplane")
                    .font(.system(size: iconSize))
                    .foregroundColor(abandonFlightProgress > 0 ? .aviationRed : .aviationGold)
            }

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

    private var sidePanel: some View {
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

    var body: some View {
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
            let chart = WaypointPickerICAOTileOverlay()  // ICAO z7-11 + Segelflugkarte z11-12
            chart.canReplaceMapContent = true
            mapView.insertOverlay(chart, at: 0, level: .aboveLabels)
        case .landeskarten, .swissimage:
            mapView.mapType = .standard
            if let identifier = layer.swisstopoLayerIdentifier {
                let chart = WaypointPickerSwisstopoTileOverlay(layerIdentifier: identifier, tileExtension: layer.tileExtension)
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

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.GPS.status) {
                    HStack {
                        Image(systemName: "location.fill")
                            .foregroundColor(gpsStatusColor)
                        Text(L10n.GPS.signal)
                        Spacer()
                        Text(gpsStatusText)
                            .foregroundColor(gpsStatusColor)
                    }

                    HStack {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                            .foregroundColor(.aviationBlue)
                        Text(L10n.GPS.pointsRecorded)
                        Spacer()
                        Text("\(appState.currentFlight?.gpsTrack.count ?? 0)")
                            .foregroundColor(.primaryText)
                    }
                }

                Section(L10n.Flight.times) {
                    if let engineTime = appState.formattedEngineStartTime {
                        HStack {
                            Image(systemName: "engine.combustion")
                                .foregroundColor(.aviationGreen)
                            Text(L10n.Time.engineStart)
                            Spacer()
                            Text(engineTime)
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    if let lineUpTime = appState.formattedLineUpTime {
                        HStack {
                            Image(systemName: "airplane.departure")
                                .foregroundColor(.aviationAmber)
                            Text(L10n.Time.takeoff)
                            Spacer()
                            Text(lineUpTime)
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    if let landingTime = appState.formattedLandingTime {
                        HStack {
                            Image(systemName: "airplane.arrival")
                                .foregroundColor(.aviationBlue)
                            Text(L10n.Time.landing)
                            Spacer()
                            Text(landingTime)
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    if let shutdownTime = appState.formattedEngineShutdownTime {
                        HStack {
                            Image(systemName: "engine.combustion.fill")
                                .foregroundColor(.aviationRed)
                            Text(L10n.Time.shutdown)
                            Spacer()
                            Text(shutdownTime)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }

                Section(L10n.Flight.phases) {
                    ForEach(ChecklistPhase.allCases) { phase in
                        HStack {
                            Circle()
                                .fill(statusColor(for: phase))
                                .frame(width: 8, height: 8)
                            Text(phase.shortTitle)
                                .font(.system(size: 14))
                            Spacer()
                            Text(L10n.Sheet.page(phase.pageNumber))
                                .font(.system(size: 12))
                                .foregroundColor(.dimText)
                        }
                    }
                }
            }
            .navigationTitle(L10n.Flight.info)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func statusColor(for phase: ChecklistPhase) -> Color {
        if phase == appState.currentPhase {
            return .aviationGold
        }
        switch appState.getPhaseStatus(phase) {
        case .completed: return .aviationGreen
        case .skipped: return .orange
        case .missingAction: return .aviationRed
        case .notStarted: return .dimText.opacity(0.3)
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
