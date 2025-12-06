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
    
    var body: some View {
        GeometryReader { geometry in
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
                    targetSpeed: appState.currentPhase.targetSpeed
                )
                .padding(.vertical, 16)

                // Altimeter display below speed indicator
                FlightAltimeter(
                    altitudeFeet: locationManager.currentAltitudeFeet
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

// MARK: - Preview

#Preview {
    FlightView()
        .environmentObject(AppState())
        .environmentObject(LocationManager())
}
