import SwiftUI
import Combine
import CoreLocation

/// Main flight view displayed during an active flight
struct FlightView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @State private var showPhaseSelector = false
    @State private var showSpeedReference = false
    @State private var showEndFlightAlert = false
    @State private var showDepartureBriefing = false
    @State private var showApproachBriefing = false
    @State private var showFlightInfo = false
    @State private var timerTrigger = false
    @State private var pulseNextButton = false
    @State private var pulseActionButton = false
    @State private var allItemsChecked = false
    @State private var scrollToBottom = false

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
        }
        .sheet(isPresented: $showDepartureBriefing) {
            DepartureBriefingView()
        }
        .sheet(isPresented: $showApproachBriefing) {
            ApproachBriefingView()
        }
        .sheet(isPresented: $showFlightInfo) {
            FlightInfoSheet(locationManager: locationManager)
        }
        .alert("End Flight?", isPresented: $showEndFlightAlert) {
            Button("Cancel", role: .cancel) { }
            Button("End Flight", role: .destructive) {
                locationManager.stopTracking()
                appState.endFlight()
            }
        } message: {
            Text("This will save the flight to your log and stop GPS recording.")
        }
        .onReceive(timer) { _ in
            // Trigger view update for timer display
            timerTrigger.toggle()
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
                                pulseActionButton = false
                                // Now pulse NEXT button if all items checked
                                if allItemsChecked {
                                    triggerNextButtonPulse()
                                }
                            },
                            onLineUpUpdate: {
                                appState.recordLineUpTime()
                            },
                            onEngineShutdown: {
                                appState.recordEngineShutdown()
                                pulseActionButton = false
                                // Now pulse NEXT button if all items checked
                                if allItemsChecked {
                                    triggerNextButtonPulse()
                                }
                            },
                            onEngineShutdownUpdate: {
                                appState.recordEngineShutdown()
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
                            onLanded: {
                                appState.recordLanding()
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
                            stepByStepEnabled: appState.settings.stepByStepHighlighting,
                            learningModeEnabled: appState.settings.learningMode,
                            highlightedItemIndex: appState.getHighlightedItem(for: appState.currentPhase),
                            pulseActionButton: pulseActionButton
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
            if appState.currentPhase.showsSpeedIndicator {
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
                            onEngineStart: {
                                appState.recordEngineStart()
                                pulseActionButton = false
                                if allItemsChecked { triggerNextButtonPulse() }
                            },
                            onEngineStartUpdate: { appState.recordEngineStart() },
                            onLineUp: {
                                appState.recordLineUpTime()
                                pulseActionButton = false
                                if allItemsChecked { triggerNextButtonPulse() }
                            },
                            onLineUpUpdate: { appState.recordLineUpTime() },
                            onEngineShutdown: {
                                appState.recordEngineShutdown()
                                pulseActionButton = false
                                if allItemsChecked { triggerNextButtonPulse() }
                            },
                            onEngineShutdownUpdate: { appState.recordEngineShutdown() },
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
                            stepByStepEnabled: appState.settings.stepByStepHighlighting,
                            learningModeEnabled: appState.settings.learningMode,
                            highlightedItemIndex: appState.getHighlightedItem(for: appState.currentPhase),
                            pulseActionButton: pulseActionButton,
                            isCompact: true
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
            // Aircraft identifier
            HStack(spacing: 4) {
                Image(systemName: "airplane")
                    .font(.system(size: 14))
                    .foregroundColor(.aviationGold)
                Text(appState.currentFlight?.airplane ?? "F-HVXA")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primaryText)
            }

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
            if let targetSpeed = appState.currentPhase.targetSpeed {
                CompactSpeedView(
                    speedKnots: locationManager.currentSpeedMPS * 1.94384,
                    targetSpeed: targetSpeed,
                    gpsSignalStatus: locationManager.gpsSignalStatus
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

            // Speeds button
            Button(action: { showSpeedReference = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 14))
                    Text("SPEEDS")
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
                        Text("END")
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
                        Text("NEXT")
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
        let visibleCount = ChecklistData.visibleItemCount(
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
    
    // MARK: - Header Bar
    
    private var headerBar: some View {
        HStack {
            // Aircraft identifier
            HStack(spacing: 8) {
                Image(systemName: "airplane")
                    .font(.system(size: 20))
                    .foregroundColor(.aviationGold)
                Text(appState.currentFlight?.airplane ?? "F-HVXA")
                    .font(.headerText)
                    .foregroundColor(.primaryText)
            }
            
            Spacer()
            
            // Phase indicator
            Button(action: { showPhaseSelector = true }) {
                HStack(spacing: 8) {
                    Text("Phase \(appState.currentPhase.rawValue + 1)/\(ChecklistPhase.allCases.count)")
                        .font(.captionText)
                        .foregroundColor(.secondaryText)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(.secondaryText)
                }
            }
            
            Spacer()
            
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
                    Text("PREV")
                }
                .fixedSize()
            }
            .buttonStyle(NavigationButtonStyle(direction: .previous, isEnabled: appState.canGoToPreviousPhase))
            .disabled(!appState.canGoToPreviousPhase)
            
            Spacer()
            
            // Speed reference button (always centered)
            Button(action: { showSpeedReference = true }) {
                HStack {
                    Image(systemName: "speedometer")
                    Text("SPEEDS")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            
            Spacer()
            
            // Right side: either END FLIGHT (on last phase) or NEXT button
            if appState.isLastPhase {
                // End flight button - with pulse effect
                Button(action: { showEndFlightAlert = true }) {
                    HStack {
                        Image(systemName: "flag.checkered")
                        Text("END FLIGHT")
                    }
                }
                .buttonStyle(ActionButtonStyle(color: .aviationRed))
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
                        Text("NEXT")
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
            if appState.currentPhase.showsSpeedIndicator {
                FlightSpeedIndicator(
                    gpsSpeedMetersPerSecond: locationManager.currentSpeedMPS,
                    targetSpeed: appState.currentPhase.targetSpeed,
                    gpsSignalStatus: locationManager.gpsSignalStatus
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
            Text("FLIGHT PHASES")
                .font(.captionText)
                .foregroundColor(.secondaryText)
                .padding(.top, 16)
                .padding(.bottom, 8)
            
            AviationDivider(color: .dimText)
            
            // Phase list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ChecklistPhase.allCases) { phase in
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
                Text("GPS")
                    .font(.captionText)
                    .foregroundColor(.secondaryText)
                Spacer()
                StatusIndicator(gpsStatusIndicator)
            }
            
            // Points recorded
            HStack {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    .foregroundColor(.aviationBlue)
                Text("Points")
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
                TimeInfoRow(icon: "engine.combustion", label: "Engine Start", time: engineTime, color: .aviationGreen)
            }
            
            if let lineUpTime = appState.formattedLineUpTime {
                TimeInfoRow(icon: "airplane.departure", label: "Take-off", time: lineUpTime, color: .aviationAmber)
            }
            
            if let landingTime = appState.formattedLandingTime {
                TimeInfoRow(icon: "airplane.arrival", label: "Landing", time: landingTime, color: .aviationBlue)
            }
            
            if let shutdownTime = appState.formattedEngineShutdownTime {
                TimeInfoRow(icon: "engine.combustion.fill", label: "Shutdown", time: shutdownTime, color: .aviationRed)
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
        NavigationView {
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
                        Text("Page \(phase.pageNumber)")
                            .font(.captionText)
                            .foregroundColor(.secondaryText)
                    }
                }
            }
            .navigationTitle("Select Phase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
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
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            SpeedReferenceView()
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            .background(Color.cockpitBackground)
            .navigationTitle("Speed Reference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.fraction(0.6)])
        .preferredColorScheme(.dark)
    }
}

// MARK: - Compact Speed View (iPhone)

struct CompactSpeedView: View {
    let speedKnots: Double
    let targetSpeed: Int
    let gpsSignalStatus: GPSSignalStatus

    private var stallSpeed: Int {
        ChecklistData.currentAircraft.stallSpeed
    }

    private var speedState: SpeedState {
        let speedInt = Int(speedKnots)
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
            // Speed value with failure flag
            ZStack {
                HStack(spacing: 4) {
                    if gpsSignalStatus != .lost {
                        Text("\(Int(max(0, speedKnots)))")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(textColor)
                        Text("kt")
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
                Text("TGT")
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
    }

    private var backgroundColor: Color {
        switch speedState {
        case .onTarget: return Color.aviationGreen.opacity(0.2)
        case .offTarget: return Color.orange.opacity(0.2)
        case .stall: return isFlashing ? Color.aviationRed : Color.aviationRed.opacity(0.7)
        }
    }

    private var textColor: Color {
        switch speedState {
        case .onTarget: return .aviationGreen
        case .offTarget: return .orange
        case .stall: return isFlashing ? .white : .aviationRed
        }
    }

    private var targetIcon: String {
        let speedInt = Int(speedKnots)
        if speedInt < targetSpeed - 5 { return "arrow.up" }
        else if speedInt > targetSpeed + 5 { return "arrow.down" }
        else { return "checkmark" }
    }

    private func startFlashing() {
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
                            .foregroundColor(.black)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text("ft")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.black.opacity(0.7))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.altimeterBlue)
                )

                // Failure flag overlay
                if showFailureFlag {
                    InstrumentFailureFlag(level: failureLevel, size: CGSize(width: 80, height: 40))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(minWidth: 80, minHeight: 40)

            Text("MSL")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondaryText)
        }
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
        guard locationManager.isTracking else { return "Inactive" }
        switch locationManager.gpsSignalStatus {
        case .good: return "Good"
        case .degraded: return "Degraded"
        case .lost: return "Lost"
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section("GPS Status") {
                    HStack {
                        Image(systemName: "location.fill")
                            .foregroundColor(gpsStatusColor)
                        Text("Signal")
                        Spacer()
                        Text(gpsStatusText)
                            .foregroundColor(gpsStatusColor)
                    }

                    HStack {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                            .foregroundColor(.aviationBlue)
                        Text("Points Recorded")
                        Spacer()
                        Text("\(appState.currentFlight?.gpsTrack.count ?? 0)")
                            .foregroundColor(.primaryText)
                    }
                }

                Section("Flight Times") {
                    if let engineTime = appState.formattedEngineStartTime {
                        HStack {
                            Image(systemName: "engine.combustion")
                                .foregroundColor(.aviationGreen)
                            Text("Engine Start")
                            Spacer()
                            Text(engineTime)
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    if let lineUpTime = appState.formattedLineUpTime {
                        HStack {
                            Image(systemName: "airplane.departure")
                                .foregroundColor(.aviationAmber)
                            Text("Take-off")
                            Spacer()
                            Text(lineUpTime)
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    if let landingTime = appState.formattedLandingTime {
                        HStack {
                            Image(systemName: "airplane.arrival")
                                .foregroundColor(.aviationBlue)
                            Text("Landing")
                            Spacer()
                            Text(landingTime)
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    if let shutdownTime = appState.formattedEngineShutdownTime {
                        HStack {
                            Image(systemName: "engine.combustion.fill")
                                .foregroundColor(.aviationRed)
                            Text("Shutdown")
                            Spacer()
                            Text(shutdownTime)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }

                Section("Flight Phases") {
                    ForEach(ChecklistPhase.allCases) { phase in
                        HStack {
                            Circle()
                                .fill(statusColor(for: phase))
                                .frame(width: 8, height: 8)
                            Text(phase.shortTitle)
                                .font(.system(size: 14))
                            Spacer()
                            Text("P\(phase.pageNumber)")
                                .font(.system(size: 12))
                                .foregroundColor(.dimText)
                        }
                    }
                }
            }
            .navigationTitle("Flight Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
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
}
