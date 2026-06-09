import SwiftUI
import Combine
import CoreLocation

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

    var body: some View {
        GeometryReader { geometry in
            if isCompactWidth(geometry) {
                // iPhone layout: full-width checklist with compact header
                VStack(spacing: 0) {
                    mainChecklistAreaCompact(geometry: geometry)
                }
            } else {
                // iPad layout: side panel
                HStack(spacing: 0) {
                    // Main checklist area
                    mainChecklistArea
                        .frame(width: geometry.size.width * 0.75)

                    // Side panel
                    sidePanel
                        .frame(width: geometry.size.width * 0.25)
                        .background(Color.panelBackground)
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
        // Event confirmation overlays
        .overlay {
            if let goAroundEvent = flightEventDetector.pendingGoAround {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture {
                        // Tap outside dismisses
                        flightEventDetector.dismissGoAround()
                    }
                    // VoiceOver: the two-finger-scrub escape gesture dismisses the dialog. (UX-24)
                    .accessibilityAction(.escape) { flightEventDetector.dismissGoAround() }
                EventConfirmationView(
                    event: goAroundEvent,
                    onConfirm: {
                        appState.recordGoAround()
                        flightEventDetector.dismissGoAround()
                    },
                    onDismiss: {
                        flightEventDetector.dismissGoAround()
                    }
                )
            }
        }
        .overlay {
            if let touchAndGoEvent = flightEventDetector.pendingTouchAndGo {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture {
                        // Tap outside dismisses
                        flightEventDetector.dismissTouchAndGo()
                    }
                    .accessibilityAction(.escape) { flightEventDetector.dismissTouchAndGo() }
                EventConfirmationView(
                    event: touchAndGoEvent,
                    onConfirm: {
                        appState.recordTouchAndGo()
                        flightEventDetector.dismissTouchAndGo()
                    },
                    onDismiss: {
                        flightEventDetector.dismissTouchAndGo()
                    }
                )
            }
        }
        .overlay {
            if let fullStopEvent = flightEventDetector.pendingFullStop {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture {
                        // Tap outside dismisses
                        flightEventDetector.dismissFullStop()
                    }
                    .accessibilityAction(.escape) { flightEventDetector.dismissFullStop() }
                EventConfirmationView(
                    event: fullStopEvent,
                    onConfirm: {
                        appState.recordFullStop()
                        flightEventDetector.dismissFullStop()
                    },
                    onDismiss: {
                        flightEventDetector.dismissFullStop()
                    }
                )
            }
        }
    }
    
    // MARK: - Main Checklist Area
    
    private var mainChecklistArea: some View {
        VStack(spacing: 0) {
            // Header bar
            headerBar
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color.panelBackground)
            
            // Checklist content - entire area is tappable
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ChecklistView(
                            phase: appState.currentPhase,
                            activeChecklist: appState.activeChecklist,
                            onEngineStart: {
                                appState.recordEngineStart()
                                pulseActionButton = false
                                // Now pulse NEXT button if all items checked
                                if allItemsChecked {
                                    triggerNextButtonPulse()
                                }
                            },
                            onEngineStartUpdate: {
                                appState.recordEngineStart()
                            },
                            onLineUp: {
                                appState.recordLineUpTime()
                                // Update flight plan departure time to now
                                if let lineUpTime = appState.lineUpTime {
                                    flightPlanManager.updateDepartureTimeFromLineUp(lineUpTime)
                                }
                                pulseActionButton = false
                                // Now pulse NEXT button if all items checked
                                if allItemsChecked {
                                    triggerNextButtonPulse()
                                }
                            },
                            onLineUpUpdate: {
                                appState.recordLineUpTime()
                                // Update flight plan departure time
                                if let lineUpTime = appState.lineUpTime {
                                    flightPlanManager.updateDepartureTimeFromLineUp(lineUpTime)
                                }
                            },
                            onEngineShutdown: {
                                appState.recordEngineShutdown()
                                pulseActionButton = false
                                // Show hour meter input if enabled
                                if appState.settings.logEngineHours {
                                    hourMeterStopInitialValue = ""
                                    showHourMeterStop = true
                                }
                                // Now pulse NEXT button if all items checked
                                if allItemsChecked {
                                    triggerNextButtonPulse()
                                }
                            },
                            onEngineShutdownUpdate: {
                                appState.recordEngineShutdown()
                                // Re-show hour meter with previous value pre-filled
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
                                // Reset UI state since we're jumping to a new phase
                                pulseActionButton = false
                                pulseNextButton = false
                                allItemsChecked = false
                            },
                            onTouchAndGo: {
                                appState.recordTouchAndGo()
                                // Reset UI state since we're jumping to a new phase
                                pulseActionButton = false
                                pulseNextButton = false
                                allItemsChecked = false
                            },
                            onFullStop: {
                                appState.recordFullStop()
                                // Reset UI state since we're jumping to a new phase
                                pulseActionButton = false
                                pulseNextButton = false
                                allItemsChecked = false
                            },
                            onLanded: {
                                appState.recordLanding()
                                flightEventDetector.dismissFullStop()  // Prevent double-counting
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
            
            // Navigation bar
            navigationBar
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color.panelBackground)
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
                    estimatedAirspeed: estimatedAirspeed
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

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack {
            // Aircraft identifier with long-press to abandon
            abandonableAircraftIdentifier(iconSize: 20, isCompact: false)
            
            Spacer()
            
            // Phase indicator
            Button(action: { showPhaseSelector = true }) {
                HStack(spacing: 8) {
                    Text(L10n.Flight.phase(appState.currentPhase.rawValue + 1, ChecklistPhase.allCases.count))
                        .font(.captionText)
                        .foregroundColor(.secondaryText)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(.secondaryText)
                }
            }
            
            Spacer()
            
            // Companion connected indicator
            if companionConnectivityManager.connectionState == .connected {
                HStack(spacing: 4) {
                    Image(systemName: "iphone")
                        .font(.system(size: 12))
                    StatusIndicator(.active, size: 8)
                }
                .foregroundColor(.aviationGreen)
            }

            // Flight duration (updates with timer)
            HStack(spacing: 8) {
                StatusIndicator(.active)
                Text(appState.flightDuration)
                    .font(.timeDisplay)
                    .foregroundColor(.aviationGreen)
                    .id(timerTrigger) // Force refresh on timer
            }
        }
    }
    
    // MARK: - Navigation Bar
    
    private var navigationBar: some View {
        HStack(spacing: 24) {
            // Previous button
            Button(action: { appState.previousPhase() }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text(L10n.Button.prev)
                }
                .fixedSize()
            }
            .buttonStyle(NavigationButtonStyle(direction: .previous, isEnabled: appState.canGoToPreviousPhase))
            .disabled(!appState.canGoToPreviousPhase)

            Spacer()

            // Navigation mode button (compact for portrait)
            Button(action: { showNavigationMode = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "map")
                        .font(.system(size: 16))
                    Text(L10n.Button.nav)
                        .font(.system(size: 16, weight: .semibold))
                }
                .fixedSize()
                .foregroundColor(.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.aviationBlue, lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.aviationBlue.opacity(0.2))
                        )
                )
            }
            .fixedSize()

            // Speed reference button (compact for portrait)
            Button(action: { showSpeedReference = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 16))
                    Text(L10n.Button.speeds)
                        .font(.system(size: 16, weight: .semibold))
                }
                .fixedSize()
                .foregroundColor(.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.aviationBlue, lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.aviationBlue.opacity(0.2))
                        )
                )
            }
            .fixedSize()

            Spacer()

            // Right side: either END FLIGHT (on last phase) or NEXT button
            if appState.isLastPhase {
                // End flight button - with pulse effect
                Button(action: { showEndFlightAlert = true }) {
                    HStack {
                        Image(systemName: "flag.checkered")
                        Text(L10n.Button.end)
                    }
                }
                .buttonStyle(ActionButtonStyle(color: .aviationRed))
                .fixedSize()
                .modifier(PulseModifier(isActive: pulseNextButton && allItemsChecked))
            } else {
                // Next button - with pulse effect
                Button(action: {
                    pulseNextButton = false
                    pulseActionButton = false
                    allItemsChecked = false
                    appState.nextPhase()
                }) {
                    HStack(spacing: 6) {
                        Text(L10n.Button.next)
                        Image(systemName: "chevron.right")
                    }
                    .fixedSize()
                }
                .buttonStyle(NavigationButtonStyle(direction: .next, isEnabled: appState.canGoToNextPhase))
                .disabled(!appState.canGoToNextPhase)
                .modifier(PulseModifier(isActive: pulseNextButton && allItemsChecked && !currentPhaseNeedsAction))
            }
        }
    }
    
    // MARK: - Side Panel

    private var sidePanel: some View {
        VStack(spacing: 0) {
            // Speed indicator (only during flight phases that need it)
            if appState.activeChecklist.showsSpeedIndicator(for: appState.currentPhase) {
                FlightSpeedIndicator(
                    gpsSpeedMetersPerSecond: locationManager.displaySpeedMPS,
                    targetSpeed: appState.activeChecklist.targetSpeed(for: appState.currentPhase),
                    stallSpeed: appState.activeChecklist.stallSpeed,
                    gpsSignalStatus: locationManager.gpsSignalStatus,
                    estimatedAirspeed: estimatedAirspeed,
                    stallAlertEnabled: appState.settings.stallAlertSound
                )
                .padding(.vertical, 16)

                // Altimeter display below speed indicator
                FlightAltimeter(
                    altitudeFeet: locationManager.currentAltitudeFeet,
                    gpsSignalStatus: locationManager.gpsSignalStatus
                )
                .padding(.bottom, 16)

                AviationDivider(color: .dimText)
            }
            
            // Phase overview header
            Text(L10n.Flight.phases)
                .font(.captionText)
                .foregroundColor(.secondaryText)
                .padding(.top, 16)
                .padding(.bottom, 8)
            
            AviationDivider(color: .dimText)
            
            // Phase list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ChecklistPhase.allCases.filter { phase in
                        // Hide CRUISE and DESCENT in circuit mode
                        if appState.isCircuitMode && (phase == .cruise || phase == .descent) {
                            return false
                        }
                        return true
                    }) { phase in
                        PhaseRowButton(
                            phase: phase,
                            isActive: phase == appState.currentPhase,
                            status: appState.getPhaseStatus(phase)
                        ) {
                            appState.goToPhase(phase)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            
            AviationDivider(color: .dimText)
            
            // Flight info
            flightInfoPanel
                .padding(16)
        }
    }
    
    // MARK: - Flight Info Panel
    
    private var gpsStatusColor: Color {
        guard locationManager.isTracking else { return .dimText }
        switch locationManager.gpsSignalStatus {
        case .good: return .aviationGreen
        case .degraded: return .orange
        case .lost: return .aviationRed
        }
    }

    private var gpsStatusIndicator: StatusIndicator.Status {
        guard locationManager.isTracking else { return .inactive }
        switch locationManager.gpsSignalStatus {
        case .good: return .active
        case .degraded: return .warning
        case .lost: return .error
        }
    }

    private var flightInfoPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // GPS Status
            HStack {
                Image(systemName: "location.fill")
                    .foregroundColor(gpsStatusColor)
                Text(L10n.GPS.status)
                    .font(.captionText)
                    .foregroundColor(.secondaryText)
                Spacer()
                StatusIndicator(gpsStatusIndicator)
            }

            // Background-tracking limitation (WhenInUse only) — the track may stop if the app
            // is backgrounded; prompt the pilot to grant Always. (PERF-04)
            if locationManager.backgroundTrackingLimited {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.aviationAmber)
                    Text(L10n.GPS.backgroundLimited)
                        .font(.captionText)
                        .foregroundColor(.aviationAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Points recorded
            HStack {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    .foregroundColor(.aviationBlue)
                Text(L10n.GPS.points)
                    .font(.captionText)
                    .foregroundColor(.secondaryText)
                Spacer()
                Text("\(appState.currentFlight?.gpsTrack.count ?? 0)")
                    .font(.captionText)
                    .foregroundColor(.primaryText)
            }

            AviationDivider(color: .dimText.opacity(0.5))
                .padding(.vertical, 4)

            // Chronological times
            if let engineTime = appState.formattedEngineStartTime {
                TimeInfoRow(icon: "engine.combustion", label: L10n.Time.engineStart, time: engineTime, color: .aviationGreen)
            }

            if let lineUpTime = appState.formattedLineUpTime {
                TimeInfoRow(icon: "airplane.departure", label: L10n.Time.takeoff, time: lineUpTime, color: .aviationAmber)
            }

            if let landingTime = appState.formattedLandingTime {
                TimeInfoRow(icon: "airplane.arrival", label: L10n.Time.landing, time: landingTime, color: .aviationBlue)
            }

            if let shutdownTime = appState.formattedEngineShutdownTime {
                TimeInfoRow(icon: "engine.combustion.fill", label: L10n.Time.shutdown, time: shutdownTime, color: .aviationRed)
            }
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

    /// The speed value to display (estimated airspeed if available, otherwise ground speed)
    private var displaySpeed: Double {
        estimatedAirspeed ?? speedKnots
    }

    /// Whether we're showing estimated airspeed
    private var showingEstimatedAirspeed: Bool {
        estimatedAirspeed != nil
    }

    private var speedState: SpeedState {
        // Don't trigger stall warning based on unreliable GPS data —
        // the InstrumentFailureFlag overlay already communicates GPS issues
        if gpsSignalStatus == .degraded || gpsSignalStatus == .lost {
            let speedInt = Int(displaySpeed)
            if abs(speedInt - targetSpeed) <= 5 { return .onTarget }
            return .offTarget
        }

        let speedInt = Int(displaySpeed)
        if speedInt < stallSpeed {
            return .stall
        } else if abs(speedInt - targetSpeed) <= 5 {
            return .onTarget
        } else {
            return .offTarget
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
            // Speed type label — a static "STALL" word annunciation when stalling, so the warning
            // never depends on the flash or colour alone (and is steady under Reduce Motion). (UX-18)
            VStack(alignment: .trailing, spacing: 2) {
                Text(speedState == .stall ? "STALL" : (showingEstimatedAirspeed ? L10n.Speed.ias : L10n.Speed.gs))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(speedState == .stall ? .aviationRed : (showingEstimatedAirspeed ? .aviationAmber : .dimText))
            }

            // Speed value with failure flag
            ZStack {
                HStack(spacing: 4) {
                    if gpsSignalStatus != .lost {
                        Text("\(Int(max(0, displaySpeed)))")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(textColor)
                        Text(L10n.Unit.kt)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(textColor.opacity(0.8))
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
            if speedState == .stall { startFlashing() }
        }
        .onChange(of: speedState) { _, newState in
            if newState == .stall { startFlashing() } else { stopFlashing() }
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
        let altitude = Int(altitudeFeet)
        let digitCount = String(abs(altitude)).count
        switch digitCount {
        case 1, 2: return 24
        case 3: return 22
        case 4: return 18
        default: return 14
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

// MARK: - Flight Info Sheet (iPhone)

struct FlightInfoSheet: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var locationManager: LocationManager
    @Environment(\.dismiss) var dismiss

    private var gpsStatusColor: Color {
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
