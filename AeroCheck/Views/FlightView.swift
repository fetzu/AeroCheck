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
    /// on iPad portrait / iPhone. nil = none. HUD Settings stays a sheet (Pattern A). (v4 UI/UX Revamp)
    @State private var activeReference: HUDReference? = nil
    @State private var pulseNextButton = false
    @State private var pulseActionButton = false
    @State private var allItemsChecked = false
    @State private var scrollToBottom = false
    @State private var nearestFreqText: String?
    /// Binding to the hidden-items reveal state, now owned by `AppState` so a companion's hold-to-reveal
    /// syncs to both devices. Reset on phase change in AppState. (companion v2 — hidden-content parity)
    private var hiddenItemsRevealed: Binding<Bool> {
        Binding(get: { appState.hiddenItemsRevealed }, set: { appState.hiddenItemsRevealed = $0 })
    }

    // Hour meter input modals
    @State private var showHourMeterStart = false
    /// Stable periodic timer (created once) driving the cruise-check evaluation. (v4 UI/UX Revamp fix)
    @State private var cruiseEvalTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    /// 0…1 fill of the CRUISE button while the pilot holds to reset (animates left→right over 1.5 s). (v4 UI/UX Revamp)
    @State private var cruiseHoldProgress: CGFloat = 0
    @State private var showHourMeterStop = false
    @State private var hourMeterStartInitialValue: String = ""
    @State private var hourMeterStopInitialValue: String = ""


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
    /// button stays tappable either way so a phase can still be skipped. (v4 UI/UX Revamp feedback)
    private var nextButtonReady: Bool {
        let itemsDone = !appState.settings.stepByStepHighlighting || appState.areAllItemsCompleted(learningMode: effectiveLearningMode)
        return itemsDone && !currentPhaseNeedsAction
    }

    /// Learning mode OR temporarily-revealed hidden items — the set of items the checklist is showing,
    /// so tap-to-advance and completion stay in sync with what's on screen. (v4 UI/UX Revamp feedback)
    private var effectiveLearningMode: Bool {
        appState.effectiveLearningMode
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
            destinationIdent: destinationIdent,
            flightPlan: flightPlanManager.activeFlightPlan
        )
    }

    /// Width of the left (checklist) column in the iPad two-column layout; the HUD context column
    /// takes the rest. Tune here. (v4 UI/UX Revamp)
    private static let checklistColumnFraction: CGFloat = 0.6

    // MARK: - HUD shell (top bar + phase progress bar over the content)

    /// Wraps the iPad HUD: the full-width top bar and tappable phase progress bar span both columns,
    /// with the orientation-specific content below. Also drives the throttled NEAREST lookup. (v4 UI/UX Revamp)
    private func hudShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            hudTopBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(theme.panel)

            phaseProgressBarView
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .background(theme.panel)

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
            isCircuitMode: appState.isCircuitMode,
            cruiseCheckDue: appState.cruiseCheckDue
        )
    }

    /// Full-width HUD top bar: aircraft · tappable phase badge · counter ‖ timer · GPS · options.
    /// Top-bar phase-badge tint by flight stage, so the chip reads at a glance (was always gold):
    /// ground prep = blue, departure = gold, airborne = green, arrival = orange, wrap-up = grey.
    private var phaseBadgeColor: Color {
        switch appState.currentPhase {
        case .preflight, .beforeEngineStart, .engineStart, .afterEngineStart, .taxi, .runup:
            return theme.info
        case .beforeDeparture, .lineUp:
            return theme.action
        case .climb, .cruise, .descent:
            return theme.onTarget
        case .approach, .landing:
            return .orange
        case .afterLanding, .shutdown, .hangar:
            return theme.textSecondary
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
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            // Just the counter — the phase NAME is already in the badge, so "Phase" is redundant.
            Text("\(appState.currentPhase.rawValue + 1) / \(ChecklistPhase.allCases.count)")
                .font(.captionText)
                .foregroundColor(theme.textSecondary)

            circuitCounterChip

            Spacer()

            if companionConnectivityManager.connectionState == .connected {
                HStack(spacing: 4) {
                    Image(systemName: "iphone").font(.system(size: 12))
                    StatusIndicator(.active, size: 8)
                }
                .foregroundColor(theme.onTarget)
            }

            // Flight timer — just the elapsed clock (no status dot; GPS status is its own indicator).
            FlightDurationText(
                startTime: appState.engineStartTime ?? appState.currentFlight?.startTime,
                font: .system(size: 18, weight: .bold, design: .monospaced),
                color: theme.textPrimary
            )

            // GPS status — icon AND label reflect the signal status; tap to open the dedicated GPS
            // popup (status guide + advanced fix info). When the flight is running off a borrowed
            // companion fix, the label shows "GPS · iPhone" so the source is unmistakable. (shared-GPS)
            Button(action: { openReference(.gps) }) {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 12))
                    Text(gpsSourceLabel)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(gpsStatusColor)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(isBorrowingCompanionGPS ? L10n.GPS.sourceCompanion : L10n.GPS.status)
            .accessibilityHint(L10n.Flight.info)

            // Flight details / options (consolidates the GPS/points/times panel)
            Button(action: { showFlightInfo = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundColor(theme.textSecondary)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
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
                // side column, so Pattern B degrades to a cockpit-styled sheet. (v4 UI/UX Revamp)
                .overlay { referenceDrawerOverlay(maxHeight: geometry.size.height * 0.66) }
            } else if geometry.size.height > geometry.size.width {
                // iPad PORTRAIT: full-width top bar + phase bar, then the vertical stack. (v4 UI/UX Revamp HUD)
                hudShell {
                    portraitLayout
                }
                // Reference popups → themed bottom drawer over the stack (no side column in portrait).
                .overlay { referenceDrawerOverlay(maxHeight: geometry.size.height * 0.6) }
            } else {
                // iPad LANDSCAPE: full-width top bar + phase bar, then checklist-left / context-right.
                // (v4 UI/UX Revamp HUD)
                hudShell {
                    HStack(spacing: 0) {
                        hudLeftColumn
                            .frame(width: geometry.size.width * Self.checklistColumnFraction)
                        sidePanel
                            .frame(width: geometry.size.width * (1 - Self.checklistColumnFraction))
                            .background(theme.panel)
                    }
                }
            }
        }
        .background(theme.background)
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
        .onAppear {
            // Wind feeds the departure and approach briefings, so it is fetched for the whole
            // flight rather than gated behind a toggle. The service no-ops outside Switzerland.
            windDataService.startFetching(locationManager: locationManager)
        }
        .onDisappear {
            windDataService.stopFetching()
        }
        .onReceive(cruiseEvalTimer) { _ in
            appState.evaluateCruiseCheck()
        }
        .onChange(of: appState.currentPhase) { oldPhase, newPhase in
            appState.evaluateCruiseCheck()
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
    /// progress bar live above both columns in the body. (v4 UI/UX Revamp HUD rebuild)
    private var hudLeftColumn: some View {
        VStack(spacing: 0) {
            // Live SPD/ALT/HDG instrument strip (flight phases only).
            if appState.activeChecklist.showsSpeedIndicator(for: appState.currentPhase) {
                CockpitInstrumentStrip(
                    speedKnots: locationManager.displaySpeedKnots,
                    targetSpeed: appState.activeChecklist.targetSpeed(for: appState.currentPhase),
                    gpsSignalStatus: locationManager.gpsSignalStatus,
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
                            hiddenItemsRevealed: hiddenItemsRevealed
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
            .background(theme.background)

            // Bottom bar: the phase's timestamp action (engine-start / ready-for-line-up / shutdown,
            // when applicable) next to the big NEXT. NAV moved to the map, SPEEDS to the V-SPEEDS tile,
            // PREV to the tappable phase progress bar.
            HStack(spacing: 12) {
                hudPhaseActionButton
                circuitQuickEventButtons
                cruiseCheckButton
                hudNextButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(theme.panel)
        }
    }

    // MARK: - Cruise check (v4 UI/UX Revamp)

    /// On the Cruise checklist page the CRUISE button shares the bottom bar 50/50 with NEXT, styled to
    /// match it (large ⟳ icon + value). It shows the countdown to the next cruise check. Tap to start
    /// (idle) or acknowledge + restart (when due); completing the Cruise checklist also auto-starts it.
    /// Hold 1 s to reset/re-arm — the button fills left→right while held, so the hold is discoverable.
    /// When due it turns amber + pulses and the Cruise checklist re-arms. Hidden outside cruise. (v4 UI/UX Revamp)
    @ViewBuilder
    private var cruiseCheckButton: some View {
        if appState.currentPhase == .cruise {
            let due = appState.cruiseCheckDue
            let started = appState.cruiseCheckStartTime != nil
            let colors = cruiseCheckColors(due: due, started: started)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = appState.cruiseCheckRemaining(now: context.date)
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(due ? L10n.Nav.checkNow : cruiseTimeText(remaining)).monospacedDigit()
                }
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(colors.label)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(colors.fill)
                        // Hold-to-reset progress fill — grows left→right while held. (v4 UI/UX Revamp)
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(0.20))
                            .scaleEffect(x: cruiseHoldProgress, anchor: .leading)
                        RoundedRectangle(cornerRadius: 14).stroke(colors.stroke, lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture { if due || !started { appState.armCruiseCheck() } }
            .onLongPressGesture(minimumDuration: 1.0, maximumDistance: 60) {
                appState.armCruiseCheck()
                cruiseHoldProgress = 0
            } onPressingChanged: { pressing in
                if pressing {
                    withAnimation(.linear(duration: 1.0)) { cruiseHoldProgress = 1 }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { cruiseHoldProgress = 0 }
                }
            }
            .modifier(PulseModifier(isActive: due))
            .sensoryFeedback(.impact(weight: .medium), trigger: appState.cruiseCheckStartTime)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.Nav.cruise)
            .accessibilityHint(L10n.Nav.holdToReset)
        }
    }

    /// (label, fill, stroke) for the CRUISE button by state: due = amber, running = green, idle = dim.
    private func cruiseCheckColors(due: Bool, started: Bool) -> (label: Color, fill: Color, stroke: Color) {
        if due { return (.black, theme.warning, Color(red: 1.0, green: 0.81, blue: 0.52)) }
        if started { return (theme.onTarget, theme.onTarget.opacity(0.14), theme.onTarget.opacity(0.5)) }
        return (theme.textSecondary, .subtleOverlay(0.05), .subtleOverlay(0.12))
    }

    /// Countdown remaining as "M:SS". (v4 UI/UX Revamp)
    private func cruiseTimeText(_ remaining: TimeInterval) -> String {
        let s = Int(remaining.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
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
                .background(RoundedRectangle(cornerRadius: 14).fill(theme.danger))
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
                .foregroundColor(nextButtonReady ? .black : theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(nextButtonReady ? theme.action : theme.action.opacity(0.22))
                )
            }
            // When the phase becomes ready, a finite gold halo pulses AROUND the button then settles
            // (no resize, no loop) — reuses the shared PulseModifier. (round 6 feedback)
            .modifier(PulseModifier(isActive: nextButtonReady))
        }
    }

    /// The phase's timestamp action (engine-start / ready-for-line-up / shutdown) shown next to NEXT in
    /// the HUD bottom bar — moved out of the checklist scroll so it's always reachable, not scrolled
    /// away. Mutually exclusive per phase; empty otherwise. (v4 UI/UX Revamp)
    @ViewBuilder
    private var hudPhaseActionButton: some View {
        let phase = appState.currentPhase
        let lang = appState.settings.checklistLanguage.resolvedLanguage
        if phase.showsEngineStartButton {
            TimestampActionButton(
                title: L10n.ChecklistAction.engineStart(language: lang),
                icon: "engine.combustion.fill",
                color: theme.onTarget,
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
                color: theme.warning,
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
                color: theme.danger,
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
        // Prompt the engine-hour (Hobbs/tach) input on first start, mirroring shutdown — otherwise the
        // HUD action button records the time but never offers the hour entry on iPhone. (HUD feedback)
        if appState.settings.logEngineHours && appState.currentFlight?.engineHourStart == nil {
            hourMeterStartInitialValue = ""
            showHourMeterStart = true
        }
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
    /// bottom. Reuses `mainChecklistArea` wholesale so the checklist wiring isn't duplicated. (v4 UI/UX Revamp)
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
        .background(theme.background)
    }

    // MARK: - Event Actions (hold-to-confirm)

    /// Always-accessible GO-AROUND / TOUCH & GO / FULL-STOP buttons for the relevant phases, so the
    /// pilot doesn't have to scroll the checklist to reach them. Gated on the same phase flags as the
    /// in-checklist buttons; hold-to-confirm so a stray touch can't fire a go-around. Empty (no space)
    /// when no event applies to the current phase. (v4 UI/UX Revamp)
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
                        tint: theme.warning,
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
                    tint: theme.info,
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
                Text("[").foregroundColor(theme.textDim)
                Label("\(flight.touchAndGoCount)", systemImage: "arrow.triangle.2.circlepath")
                if flight.goAroundCount > 0 {
                    Label("\(flight.goAroundCount)", systemImage: "arrow.up.right.circle")
                }
                Text("]").foregroundColor(theme.textDim)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(theme.textSecondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(flight.touchAndGoCount) touch and go, \(flight.goAroundCount) go around")
        }
    }

    // These mirror the in-checklist event callbacks exactly (record + PR-07 manual-event dedup), so
    // the HUD buttons and the checklist buttons log identically — no double-counting. (v4 UI/UX Revamp)
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
    /// their phase clusters. Async tiles (FREQ / NEAREST / WIND) are a later slice. (v4 UI/UX Revamp)
    @ViewBuilder
    private var phaseContextZone: some View {
        let phase = appState.currentPhase
        HStack(spacing: 10) {
            // V-SPEEDS — a labeled tap (no longer a hidden one), with the phase target speed inline.
            PhaseContextTile(
                title: "V-SPEEDS",
                systemImage: "speedometer",
                tint: theme.onTarget,
                action: { openReference(.vSpeeds) }
            )

            // Departure / approach briefing for the relevant phase clusters (always reachable here,
            // not only via the inline checklist button that scrolls away). The icon distinguishes
            // departure vs approach.
            if phase.briefingType == .departure {
                PhaseContextTile(
                    title: "BRIEFING",
                    systemImage: "airplane.departure",
                    tint: theme.action,
                    action: { openReference(.departureBriefing) }
                )
            }
            if phase.briefingType == .approach {
                PhaseContextTile(
                    title: "BRIEFING",
                    systemImage: "airplane.arrival",
                    tint: theme.action,
                    action: { openReference(.approachBriefing) }
                )
            }
        }
    }

    // MARK: - Compact Layout (iPhone)

    private func mainChecklistAreaCompact(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // v4 compact top: aircraft · tappable phase badge · counter ‖ timer · GPS · options.
            compactHudTopBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(theme.panel)

            // Tappable segmented phase progress bar — replaces the old PREV button.
            phaseProgressBarView
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .background(theme.panel)

            // Live SPD / ALT / HDG instrument strip (flight phases only).
            if appState.activeChecklist.showsSpeedIndicator(for: appState.currentPhase) {
                CockpitInstrumentStrip(
                    speedKnots: locationManager.displaySpeedKnots,
                    targetSpeed: appState.activeChecklist.targetSpeed(for: appState.currentPhase),
                    gpsSignalStatus: locationManager.gpsSignalStatus,
                    altitudeFeet: locationManager.currentAltitudeFeet,
                    headingDegrees: locationManager.currentCourseDegrees,
                    verticalSpeedFPM: locationManager.verticalSpeedFpm
                )
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
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
                            hiddenItemsRevealed: hiddenItemsRevealed
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
            .background(theme.background)

            // Contextual hold-to-confirm GO-AROUND / T&G / FULL-STOP (approach/landing; circuit mode
            // shows single-tap GO-AROUND/T&G beside NEXT instead).
            eventActionsRow

            // Bottom action bar: phase timestamp action · circuit quick events · cruise check · NEXT.
            HStack(spacing: 10) {
                hudPhaseActionButton
                circuitQuickEventButtons
                cruiseCheckButton
                hudNextButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(theme.panel)

            // Bottom dock — MAP · V-SPEEDS · FREQ (locked iPhone concept).
            compactDock
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .background(theme.panel)
        }
    }

    // MARK: - Compact HUD top bar (iPhone, v4)

    /// iPhone HUD top bar — the v4 language in one row: aircraft · stage-tinted phase badge · counter
    /// ‖ timer · GPS · options. Badge → phase selector; GPS → GPS reference; gear → flight-info sheet.
    private var compactHudTopBar: some View {
        HStack(spacing: 7) {
            abandonableAircraftIdentifier(iconSize: 14, isCompact: true)

            Button(action: { showPhaseSelector = true }) {
                Text(appState.currentPhase.shortTitle)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(2)                 // hard cap: never more than 2 lines (iPhone requirement)
                    .minimumScaleFactor(0.5)      // shrink the text to fit 2 lines rather than wrap further
                    .multilineTextAlignment(.center)
                    .foregroundColor(phaseBadgeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(phaseBadgeColor.opacity(0.18)))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            Text("\(appState.currentPhase.rawValue + 1)/\(ChecklistPhase.allCases.count)")
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)

            circuitCounterChip

            Spacer(minLength: 4)

            FlightDurationText(
                startTime: appState.engineStartTime ?? appState.currentFlight?.startTime,
                font: .system(size: 16, weight: .bold, design: .monospaced),
                color: theme.textPrimary
            )
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)   // claim full width — never wrap the clock

            // GPS status — icon only on iPhone to reclaim the horizontal room the bar needs to stay one
            // row; still a button that opens the GPS reference. (v4.0.0 review iPhone HUD fix)
            Button(action: { openReference(.gps) }) {
                Image(systemName: "location.fill")
                    .font(.system(size: 14))
                    .foregroundColor(gpsStatusColor)
            }
            .frame(minWidth: 36, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(L10n.GPS.status)

            Button(action: { showFlightInfo = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundColor(theme.textSecondary)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(L10n.Flight.info)
        }
    }

    // MARK: - Compact bottom dock (iPhone, v4)

    /// The iPhone HUD bottom dock — MAP / V-SPEEDS / FREQ, replacing the old blue NAV/SPEEDS buttons.
    /// MAP opens the full nav map; V-SPEEDS and FREQ open the themed bottom drawers.
    private var compactDock: some View {
        HStack(spacing: 8) {
            dockButton(icon: "map.fill", title: L10n.Button.nav) { showNavigationMode = true }
            dockButton(icon: "speedometer", title: L10n.Button.speeds) { openReference(.vSpeeds) }
            dockButton(icon: "antenna.radiowaves.left.and.right", title: L10n.Nav.freq) { openReference(.freq) }
        }
    }

    private func dockButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(theme.info)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
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
            // so it appearing on press-and-hold doesn't enlarge the icon and shift the top bar. (v4 UI/UX Revamp fix)
            ZStack {
                if abandonFlightProgress > 0 {
                    Circle()
                        .stroke(theme.danger.opacity(0.3), lineWidth: isCompact ? 2 : 3)

                    Circle()
                        .trim(from: 0, to: abandonFlightProgress)
                        .stroke(theme.danger, style: StrokeStyle(lineWidth: isCompact ? 2 : 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }

                Image(systemName: "airplane")
                    .font(.system(size: iconSize))
                    .foregroundColor(abandonFlightProgress > 0 ? theme.danger : theme.action)
            }
            .frame(width: iconSize + (isCompact ? 8 : 12), height: iconSize + (isCompact ? 8 : 12))

            HStack(spacing: 4) {
                Text(appState.activeChecklist.registration)
                    .font(isCompact ? .system(size: 14, weight: .semibold) : .headerText)
                    .foregroundColor(abandonFlightProgress > 0 ? theme.danger : theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)   // never wrap the registration; shrink slightly if tight

                // Circuit mode indicator
                if appState.isCircuitMode {
                    Text(L10n.Flight.forCircuits)
                        .font(isCompact ? .system(size: 11, weight: .medium) : .system(size: 13, weight: .medium))
                        .foregroundColor(theme.warning)
                        .lineLimit(1)
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
            // the checklist stays live on the left, back/close restores the map. (v4 UI/UX Revamp)
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
    /// and current checklist item visible above. (v4 UI/UX Revamp)
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
    /// discoverable NAV target. (v4 UI/UX Revamp)
    /// The persistent map tile, filling whatever frame the caller gives it (tall in the landscape
    /// right column, a band in portrait). Tapping it opens the full nav map; the NEAREST-frequency
    /// strip is overlaid along the bottom. (v4 UI/UX Revamp HUD rebuild)
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
                .foregroundColor(theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .floatingChromeCapsule()
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
            .foregroundColor(theme.textPrimary)
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
            // Prefer the field's own contact freq (tower, else AFIS/INFO/advisory) over a distant
            // approach controller — an AFIS field like LSZQ must show its 122.05, not Bâle Approach.
            if let f = airportDataService.bestFieldFrequency(for: airport.ident) {
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
    private var gpsSourceLabel: String {
        isBorrowingCompanionGPS ? "GPS · iPhone" : "GPS"
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
    /// When true, the Cruise segment turns amber to flag an (over)due FREDA cruise check. (v4 UI/UX Revamp)
    var cruiseCheckDue: Bool = false

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
                            // Hit area ~45 pt tall while the bar still DRAWS at 5–8 pt. The
                            // pad/contentShape/negative-pad sandwich grows the touch region without
                            // growing the layout, so the HUD keeps its thin progress bar.
                            //
                            // This is not cosmetic. Tapping a segment calls `goToPhase`, and a
                            // forward jump marks every phase it passes as `.skipped` or
                            // `.missingAction` — silently, by design, because a deliberate jump
                            // should not nag. At 5 pt that made an ACCIDENTAL jump likely, and in
                            // turbulence a mis-tap quietly marked checklist phases skipped. Apple's
                            // current floor is 28x28 pt (44x44 recommended); this was well under it.
                            // Enlarging the target is the right fix rather than confirming the jump:
                            // phase navigation is frequent and deliberate, and a prompt on every
                            // jump would be worse in a cockpit than the thing it guards. (UX-10)
                            .padding(.vertical, 20)
                            .contentShape(Rectangle())
                            .padding(.vertical, -20)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(phase.shortTitle)
                    .accessibilityValue(accessibilityStatus(for: phase))
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
                            .font(.system(size: 9, weight: .bold))
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
        if phase == .cruise && phase == currentPhase && cruiseCheckDue {
            return L10n.Accessibility.phaseCruiseCheckDue
        }
        switch status(phase) {
        case .completed:     return L10n.Accessibility.phaseCompleted
        case .skipped:       return L10n.Accessibility.phaseSkipped
        case .missingAction: return L10n.Accessibility.phaseMissingAction
        case .empty:         return L10n.Accessibility.phaseNothingToDo
        case .notStarted:    return L10n.Accessibility.phaseNotStarted
        }
    }

    private func color(for phase: ChecklistPhase, isCurrent: Bool) -> Color {
        if phase == .cruise && isCurrent && cruiseCheckDue { return theme.warning }
        if isCurrent { return theme.action }
        switch status(phase) {
        case .completed: return theme.onTarget
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
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(startTime.map { FlightClock.formattedDuration(seconds: context.date.timeIntervalSince($0)) } ?? "--:--")
                .font(font)
                .foregroundColor(color)
        }
    }
}

// MARK: - Phase Selector Sheet

struct PhaseSelectorView: View {
    @Environment(\.cockpitTheme) private var theme
    @Environment(AppState.self) private var appState
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
        case .completed:
            return theme.onTarget
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

// MARK: - Speed Reference Sheet

struct SpeedReferenceSheet: View {
    @Environment(\.cockpitTheme) private var theme
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) var dismiss

    /// When presented as a custom overlay (HomeView's leading-edge slide-in), the host supplies a
    /// close action; otherwise `nil` and the standard `@Environment(\.dismiss)` is used. (v4 UI/UX Revamp)
    var onClose: (() -> Void)? = nil

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
            .background(theme.background)
            .navigationTitle(L10n.Sheet.speedReference)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { if let onClose { onClose() } else { dismiss() } }
                }
            }
        }
        .presentationDetents(isIPad ? [.height(480)] : [.fraction(0.6)])
        .preferredColorScheme(.dark)
    }
}

// MARK: - Compact Speed View (iPhone)

struct CompactSpeedView: View {
    @Environment(\.cockpitTheme) private var theme
    let speedKnots: Double // Ground speed in knots
    let targetSpeed: Int
    let gpsSignalStatus: GPSSignalStatus

    /// Always GPS ground speed — the app has no pitot or AoA source. See
    /// `SpeedIndicatorView.annunciationState` for why the wind-derived estimate was removed.
    private var displaySpeed: Double { speedKnots }

    // Delegates to the shared pure function so the iPhone annunciates identically to the iPad.
    private var speedState: SpeedState {
        switch SpeedIndicatorView.annunciationState(
            displaySpeed: displaySpeed, targetSpeed: targetSpeed, gpsSignalStatus: gpsSignalStatus) {
        case .onTarget: return .onTarget
        case .offTarget: return .offTarget
        }
    }

    enum SpeedState {
        case onTarget, offTarget
    }

    @Environment(\.isNightMode) private var nightMode

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
            // Speed type label. Always ground speed — the app has no airspeed source.
            VStack(alignment: .trailing, spacing: 2) {
                Text(L10n.Speed.gs)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.textDim)
            }

            // Speed value with failure flag, plus the color-blind-safe proximity bar beneath it
            VStack(spacing: 3) {
                ZStack {
                    VStack(spacing: 0) {
                        if gpsSignalStatus != .lost {
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
                // state in words). (v4 UI/UX Revamp)
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
                    .foregroundColor(theme.textDim)
                HStack(spacing: 2) {
                    Image(systemName: targetIcon)
                        .font(.system(size: 10))
                    Text("\(targetSpeed)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                .foregroundColor(theme.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ground speed")
        .accessibilityValue(SpeedIndicatorView.accessibilityValue(
            displaySpeed: Int(displaySpeed), targetSpeed: targetSpeed, state: mappedSpeedState,
            gpsLost: gpsSignalStatus == .lost))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Maps to the shared instrument state so the VoiceOver wording is identical (and tested). (UX-10)
    private var mappedSpeedState: SpeedIndicatorView.SpeedState {
        switch speedState {
        case .onTarget: return .onTarget
        case .offTarget: return .offTarget
        }
    }

    private var backgroundColor: Color {
        // Solid high-contrast fills (black text) for sunlight legibility (UX-17); low-luminance
        // variants at night (UX-09).
        switch speedState {
        case .onTarget: return nightMode ? .nightOnTarget : theme.onTarget
        case .offTarget: return nightMode ? .nightOffTarget : .orange
        }
    }

    private var textColor: Color {
        if nightMode { return .nightInstrumentText }
        switch speedState {
        case .onTarget, .offTarget: return .black
        }
    }

    private var targetIcon: String {
        let speedInt = Int(displaySpeed)
        if speedInt < targetSpeed - 5 { return "arrow.up" }
        else if speedInt > targetSpeed + 5 { return "arrow.down" }
        else { return "checkmark" }
    }

}

// MARK: - Flight Mini-Map (persistent HUD glance map)

/// A lightweight, glance-only mini-map for the in-flight HUD. It recenters on the aircraft, draws the
/// flight track, and **mirrors the chart layer the pilot picked in the full nav map** — ICAO+Segelflug,
/// Landeskarten, SWISSIMAGE, or Apple standard/satellite. Swisstopo charts are content-replacing, so
/// MapKit drops the Apple Maps logo (oversized on a small map) — they have full coverage over
/// Switzerland; outside it the area is blank rather than Apple tiles. Deliberately lightweight (no
/// airspace / airport / flight-plan overlays); tap it (handled by the caller) to open the full
/// `NavigationMapView`. (v4 UI/UX Revamp)
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
                // Outside the SwiftUI environment (MKMapViewDelegate), so the legacy token stands in
                // for the theme accent here. See the theming note in CLAUDE.md.
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
/// immediately (it's already a deliberate action). Optionally shows a running count. (v4 UI/UX Revamp)
struct HoldToConfirmButton: View {
    @Environment(\.cockpitTheme) private var theme
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
                        .foregroundColor(theme.textSecondary)
                }
                if count > 0 {
                    Spacer(minLength: 4)
                    Text("\(count)").font(.system(size: 17, weight: .heavy, design: .monospaced))
                }
            }
            .foregroundColor(theme.textPrimary)
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
/// inline value (e.g. the phase target speed). Presentational; the caller supplies the action. (v4 UI/UX Revamp)
struct PhaseContextTile: View {
    @Environment(\.cockpitTheme) private var theme
    let title: String
    let systemImage: String
    /// Accent for the icon + label (e.g. green for V-SPEEDS, gold for BRIEFING), matching the concept.
    /// `nil` means "follow the theme's primary text colour" — resolved in `body`, because a stored
    /// property's default value runs before `self` exists and so cannot read `@Environment`.
    var tint: Color? = nil
    private var resolvedTint: Color { tint ?? theme.textPrimary }
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .foregroundColor(resolvedTint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(resolvedTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let value {
                    Text(value)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.textPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.card)
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
    @Environment(\.cockpitTheme) private var theme
    @Environment(AppState.self) private var appState
    @ObservedObject var locationManager: LocationManager
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
                    // Quick in-flight options — the most useful settings without leaving the flight.
                    // ("Options" is identical in EN/FR, so no separate localization entry is needed.)
                    settingsCard(title: "Options") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.Settings.theme)
                                .font(.system(size: 15))
                                .foregroundColor(theme.textPrimary)
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
                        rowDivider
                        toggleRow(L10n.Settings.learningMode, optionBinding(\.learningMode))
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
                                    if on { CompanionConnectivityManager.shared.autoConnectIfReady(force: true) }
                                    else { CompanionConnectivityManager.shared.disconnect() }
                                }
                            ))
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "ipad.and.iphone")
                                    .font(.system(size: 13))
                                    .foregroundColor(theme.textDim)
                                Text(L10n.Companion.pairInSettings)
                                    .font(.system(size: 13))
                                    .foregroundColor(theme.textSecondary)
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    settingsCard(title: L10n.GPS.status) {
                        HStack(spacing: 10) {
                            Image(systemName: "location.fill").foregroundColor(gpsStatusColor)
                            Text(L10n.GPS.signal).font(.system(size: 15)).foregroundColor(theme.textPrimary)
                            Spacer()
                            Text(gpsStatusText).font(.system(size: 15, weight: .semibold)).foregroundColor(gpsStatusColor)
                        }
                        rowDivider
                        HStack(spacing: 10) {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                                .foregroundColor(.aviationBlue)
                            Text(L10n.GPS.pointsRecorded).font(.system(size: 15)).foregroundColor(theme.textPrimary)
                            Spacer()
                            Text("\(appState.currentFlight?.gpsTrack.count ?? 0)")
                                .font(.system(size: 15, design: .monospaced)).foregroundColor(theme.textSecondary)
                        }
                    }

                    settingsCard(title: L10n.Flight.times) {
                        if timeEntries.isEmpty {
                            HStack {
                                Text(L10n.GPS.signalInactive).font(.system(size: 14)).foregroundColor(theme.textDim)
                                Spacer()
                            }
                        } else {
                            ForEach(Array(timeEntries.enumerated()), id: \.offset) { idx, row in
                                if idx > 0 { rowDivider }
                                HStack(spacing: 10) {
                                    Image(systemName: row.icon).foregroundColor(row.color).frame(width: 22)
                                    Text(row.label).font(.system(size: 15)).foregroundColor(theme.textPrimary)
                                    Spacer()
                                    Text(row.value).font(.system(size: 15, design: .monospaced)).foregroundColor(theme.textPrimary)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(theme.background)
            .navigationTitle("HUD Settings")
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
                .font(.system(size: 12, weight: .semibold))
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
            Text(title).font(.system(size: 15)).foregroundColor(theme.textPrimary)
            Spacer()
            Toggle("", isOn: binding).labelsHidden().tint(theme.onTarget)
        }
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
    case freq

    var id: Int {
        switch self {
        case .vSpeeds: return 0
        case .gps: return 1
        case .departureBriefing: return 2
        case .approachBriefing: return 3
        case .freq: return 4
        }
    }

    var title: String {
        switch self {
        case .vSpeeds: return "V-SPEEDS"
        case .gps: return L10n.GPS.statusTitle
        case .departureBriefing, .approachBriefing: return "BRIEFING"
        case .freq: return L10n.Nav.freq
        }
    }

    var systemImage: String {
        switch self {
        case .vSpeeds: return "speedometer"
        case .gps: return "location.fill"
        case .departureBriefing: return "airplane.departure"
        case .approachBriefing: return "airplane.arrival"
        case .freq: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Accent for the panel's icon + back chevron. GPS is neutral so the chrome never implies a signal
    /// state (the live status colour lives inside the panel); briefings gold; v-speeds green. (round 6)
    var tint: Color {
        switch self {
        case .vSpeeds: return .aviationGreen
        case .gps: return .primaryText
        case .departureBriefing, .approachBriefing: return .aviationGold
        case .freq: return .altimeterBlue
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
    @ObservedObject var locationManager: LocationManager
    var briefingContext: BriefingContext? = nil
    var aglFeet: Double? = nil
    let onClose: () -> Void

    @Environment(AppState.self) private var appState
    @EnvironmentObject var airportDataService: AirportDataService

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
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 22)
            }
        }
        .background(theme.panel)
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
                .foregroundColor(theme.textPrimary)   // neutral title; the icon carries the accent (round 6)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
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
        case .freq:
            FrequencyReferenceContent(locationManager: locationManager)
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
                        .font(.system(size: 24))
                        .foregroundColor(statusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusText)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(statusColor)
                        Text(statusReason ?? L10n.GPS.signal)
                            .font(.system(size: 12))
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
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 9))
                        .foregroundColor(theme.textDim)
                }
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
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
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(color)
                Text(desc).font(.system(size: 12)).foregroundColor(theme.textSecondary)
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
    @Environment(\.cockpitTheme) private var theme
    let activeChecklist: ActiveChecklist
    let currentPhase: ChecklistPhase
    let aglFeet: Double?

    private var speeds: [SpeedReference] { activeChecklist.speeds }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(activeChecklist.registration)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
                Spacer()
                Text("IAS · kt")
                    .font(.system(size: 11, weight: .semibold))
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.textSecondary)
                Spacer()
                Text("T/O \(crosswind.takeoff) · LDG \(crosswind.landing)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
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
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(isVne ? theme.danger : theme.action)
                .frame(width: 58, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(speed.description)
                .font(.system(size: 12))
                .foregroundColor(theme.textDim)
                .lineLimit(1)
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(speed.value)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(isVne ? theme.danger : theme.textPrimary)
                Text("kt")
                    .font(.system(size: 11))
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


// MARK: - Frequency reference content (nearby radio frequencies, hosted in HUDReferencePanel)

/// iPhone HUD FREQ drawer: nearby airports and their radio frequencies, queried once on appear.
/// Cockpit cards (no system List), matching the other reference drawers. (iPhone HUD)
struct FrequencyReferenceContent: View {
    @ObservedObject var locationManager: LocationManager
    @EnvironmentObject var airportDataService: AirportDataService

    private struct Entry: Identifiable {
        let id = UUID()
        let ident: String
        let freqs: [(type: String, value: String)]
    }
    @State private var entries: [Entry] = []
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 12) {
            if !airportDataService.isDataAvailable {
                infoCard(L10n.Nav.freqUnavailable)
            } else if loaded && entries.isEmpty {
                infoCard(L10n.Nav.noNearbyFreq)
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.ident)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.aviationGold)
                        ForEach(Array(entry.freqs.enumerated()), id: \.offset) { _, f in
                            HStack {
                                Text(f.type)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondaryText)
                                Spacer()
                                Text(f.value)
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.primaryText)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSection()
                }
            }
        }
        .onAppear(perform: load)
    }

    private func infoCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSection()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let coord = locationManager.currentLocation?.coordinate, airportDataService.isDataAvailable else { return }
        let nearby = airportDataService.findNearestAirports(to: coord, limit: 6, maxDistanceNm: 40)
        entries = nearby.compactMap { airport in
            let fs = airportDataService.getFrequencies(for: airport.ident)
            guard !fs.isEmpty else { return nil }
            return Entry(ident: airport.ident, freqs: fs.map { (type: $0.type, value: $0.formattedFrequency) })
        }
    }
}
