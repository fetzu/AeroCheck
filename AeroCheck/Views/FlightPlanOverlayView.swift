import SwiftUI
import CoreLocation

/// Preset positions for the flight plan overlay
enum FlightPlanOverlayPosition: Int, CaseIterable {
    case middleLeft = 0
    case bottomMiddle = 1
    case middleRight = 2

    var icon: String {
        switch self {
        case .middleLeft: return "rectangle.lefthalf.inset.filled"
        case .bottomMiddle: return "rectangle.bottomhalf.inset.filled"
        case .middleRight: return "rectangle.righthalf.inset.filled"
        }
    }

    func position(in size: CGSize, overlayWidth: CGFloat, overlayHeight: CGFloat) -> CGPoint {
        let padding: CGFloat = 20
        switch self {
        case .middleLeft:
            return CGPoint(x: padding + overlayWidth / 2, y: size.height / 2)
        case .bottomMiddle:
            return CGPoint(x: size.width / 2, y: size.height - padding - overlayHeight / 2)
        case .middleRight:
            return CGPoint(x: size.width - padding - overlayWidth / 2, y: size.height / 2)
        }
    }
}

/// Overlay HUD showing flight plan progress during navigation
/// Movable and resizable, displays next waypoint, distance, bearing, ETA, and chronometer
struct FlightPlanOverlayView: View {
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var openAIPDataService: OpenAIPDataService

    @State private var currentPresetPosition: FlightPlanOverlayPosition = .middleLeft
    @State private var customPosition: CGPoint? = nil
    @State private var isDragging = false
    @State private var isExpanded = true
    @State private var showingDepartureTimePicker = false
    @State private var showingFlightPlanDetail = false
    @State private var refreshTrigger = false // Triggers view refresh
    /// Preview index for browsing waypoints without affecting flight state (nil = showing real active waypoint)
    @State private var previewIndex: Int? = nil

    // Timer for refreshing values every second
    let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    let containerSize: CGSize
    /// Whether the radio frequency window is currently open (affects position constraints)
    var radioFrequencyWindowOpen: Bool = false

    private var overlayWidth: CGFloat { isExpanded ? 220 : 280 }
    private var overlayHeight: CGFloat { isExpanded ? 350 : 50 }

    /// The exclusion zone for the radio frequency window (bottom-right area)
    private var radioFrequencyExclusionZone: CGRect {
        let radioWidth: CGFloat = 220
        let radioHeight: CGFloat = 400
        let padding: CGFloat = 20
        return CGRect(
            x: containerSize.width - radioWidth - padding - 20,
            y: containerSize.height - radioHeight - padding - 80,
            width: radioWidth + 40,
            height: radioHeight + 40
        )
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if isExpanded {
                    expandedContent(geometry: geometry)
                } else {
                    compactContent
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.panelBackground.opacity(0.95))
                    .shadow(color: .black.opacity(0.5), radius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.aviationGold.opacity(0.3), lineWidth: 1)
            )
            .position(currentPosition(in: geometry.size))
            .animation(.easeInOut(duration: 0.3), value: isExpanded)
        }
        .sheet(isPresented: $showingDepartureTimePicker) {
            DepartureTimePickerSheet()
                .environmentObject(flightPlanManager)
        }
        .sheet(isPresented: $showingFlightPlanDetail) {
            if let plan = flightPlanManager.activeFlightPlan {
                FlightPlanEditorView(flightPlan: plan)
                    .environmentObject(appState)
                    .environmentObject(flightPlanManager)
                    .environmentObject(airportDataService)
                    .environmentObject(openAIPDataService)
            }
        }
        .onReceive(refreshTimer) { _ in
            // Trigger view refresh every second for real-time values
            refreshTrigger.toggle()
        }
        .onChange(of: flightPlanManager.activeFlightPlan?.currentWaypointIndex) {
            // Reset preview when GPS auto-advances the real waypoint
            previewIndex = nil
        }
    }

    /// Calculate the current position based on expanded/collapsed state
    /// Expanded = middle-left, Collapsed = bottom-middle
    private func currentPosition(in size: CGSize) -> CGPoint {
        // Use fixed positions based on expanded state
        let targetPosition: FlightPlanOverlayPosition = isExpanded ? .middleLeft : .bottomMiddle
        return targetPosition.position(in: size, overlayWidth: overlayWidth, overlayHeight: overlayHeight)
    }

    /// Constrain a position within bounds, respecting radio frequency exclusion zone
    private func constrainedPosition(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let padding: CGFloat = 10
        var x = max(overlayWidth / 2 + padding, min(size.width - overlayWidth / 2 - padding, point.x))
        let y = max(overlayHeight / 2 + padding, min(size.height - overlayHeight / 2 - padding, point.y))

        // If radio frequency window is open, prevent dragging into exclusion zone
        if radioFrequencyWindowOpen {
            let proposedRect = CGRect(
                x: x - overlayWidth / 2,
                y: y - overlayHeight / 2,
                width: overlayWidth,
                height: overlayHeight
            )
            if proposedRect.intersects(radioFrequencyExclusionZone) {
                // Push to the left of the exclusion zone
                x = min(x, radioFrequencyExclusionZone.minX - overlayWidth / 2 - padding)
            }
        }

        return CGPoint(x: x, y: y)
    }

    // MARK: - Expanded Content

    private func expandedContent(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // Header with collapse button (expanded is always middle-left)
            HStack {
                Text(L10n.FlightPlan.overlayTitle)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.aviationGold)
                    .tracking(1)

                Spacer()

                Button(action: { withAnimation(.easeInOut(duration: 0.3)) { isExpanded = false } }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12))
                        .foregroundColor(.secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.aviationDarkBlue)

            // Main content
            VStack(spacing: 12) {
                // Waypoint info - shows preview or active waypoint
                if let plan = flightPlanManager.activeFlightPlan,
                   !plan.waypoints.isEmpty {
                    let displayIndex = previewIndex ?? plan.currentWaypointIndex
                    let clampedIndex = Swift.min(displayIndex, plan.waypoints.count - 1)
                    let displayWaypoint = plan.waypoints[clampedIndex]
                    let isPreview = previewIndex != nil && previewIndex != plan.currentWaypointIndex

                    Button(action: { showingFlightPlanDetail = true }) {
                        waypointSection(plan: plan, waypoint: displayWaypoint, index: clampedIndex, isPreview: isPreview)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else {
                    Text(L10n.Nav.noActiveFlightPlan)
                        .font(.system(size: 12))
                        .foregroundColor(.secondaryText)
                        .padding()
                }

                Divider()
                    .background(Color.dimText)

                // Progress bar - tappable to open flight plan detail
                if let plan = flightPlanManager.activeFlightPlan {
                    Button(action: { showingFlightPlanDetail = true }) {
                        progressSection(plan: plan)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Divider()
                    .background(Color.dimText)

                // Chronometer
                chronometerSection

                Divider()
                    .background(Color.dimText)

                // Quick actions
                quickActionsSection
            }
            .padding(12)
        }
        .frame(width: 220)
    }

    // MARK: - Compact Content

    private var compactContent: some View {
        HStack(spacing: 12) {
            // Waypoint info (preview or active)
            if let plan = flightPlanManager.activeFlightPlan,
               !plan.waypoints.isEmpty {
                let displayIndex = previewIndex ?? plan.currentWaypointIndex
                let clampedIndex = Swift.min(displayIndex, plan.waypoints.count - 1)
                let displayWaypoint = plan.waypoints[clampedIndex]
                let isPreview = previewIndex != nil && previewIndex != plan.currentWaypointIndex

                VStack(alignment: .leading, spacing: 2) {
                    Text(isPreview ? "PREVIEW" : L10n.Nav.next)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(isPreview ? .aviationBlue : .dimText)
                    Text(displayWaypoint.name.isEmpty ? "\(L10n.Nav.wpt)\(clampedIndex + 1)" : displayWaypoint.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                }

                // Planned MC & DIST from preceding waypoint
                VStack(alignment: .center, spacing: 2) {
                    HStack(spacing: 8) {
                        if clampedIndex > 0, let dist = displayWaypoint.distance {
                            Text(String(format: "%.1f", dist))
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.aviationGold)
                            + Text(" NM")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondaryText)
                        }

                        if clampedIndex > 0, let mc = displayWaypoint.magneticCourse {
                            Text(String(format: "%03d°", Int(mc)))
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundColor(.primaryText)
                        }
                    }

                    // EET from preceding waypoint
                    if clampedIndex > 0, let eet = displayWaypoint.estimatedElapsedTime {
                        let minutes = Int(eet / 60)
                        HStack(spacing: 4) {
                            Text("EET")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.dimText)
                            Text(String(format: "%d min", minutes))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondaryText)
                        }
                    }
                }

                Divider()
                    .frame(height: 30)
            }

            // Chronometer with label
            VStack(spacing: 2) {
                Text(L10n.FlightPlan.chrono)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.dimText)
                Text(flightPlanManager.formattedChronometer)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationGreen)
                    .id(refreshTrigger) // Force refresh every second
            }

            // Expand button
            Button(action: { withAnimation { isExpanded = true } }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) { isExpanded = true }
        }
    }

    // MARK: - Sections

    private func waypointSection(plan: FlightPlan, waypoint: FlightPlanWaypoint, index: Int, isPreview: Bool) -> some View {
        VStack(spacing: 8) {
            // Waypoint name with preview indicator
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(isPreview ? "PREVIEW" : L10n.Nav.nextWaypoint)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(isPreview ? .aviationBlue : .dimText)
                    }
                    Text(waypoint.name.isEmpty ? "\(L10n.Nav.wpt)\(index + 1)" : waypoint.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(index + 1)/\(plan.waypoints.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondaryText)
            }

            // PRIMARY: Planned waypoint-to-waypoint data (MC, DIST, EET from preceding waypoint)
            plannedLegDataRow(waypoint: waypoint, index: index)

            // ATO status
            atoStatusRow(waypoint: waypoint)

            // SECONDARY: Live GPS data to real next waypoint (always shown)
            if let location = locationManager.currentLocation {
                let clLocation = CLLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                liveGPSDataRow(clLocation: clLocation, plan: plan, isPreview: isPreview)

                // Total flight time (from takeoff)
                flightTimeRow
            }

            // Planned altitude if set
            if let altitude = waypoint.altitude {
                HStack {
                    Text(L10n.FlightPlan.plannedAlt)
                        .font(.system(size: 10))
                        .foregroundColor(.secondaryText)
                    Text(String(format: "%.0f ft", altitude))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.primaryText)
                }
            }
        }
    }

    /// PRIMARY display: Planned leg data (MC, DIST, EET) from the preceding waypoint
    private func plannedLegDataRow(waypoint: FlightPlanWaypoint, index: Int) -> some View {
        HStack(spacing: 20) {
            // Planned MC (magnetic course from preceding waypoint)
            VStack(spacing: 2) {
                Text(L10n.Nav.mc)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.dimText)
                if index > 0, let mc = waypoint.magneticCourse {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(String(format: "%03d", Int(mc)))
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(.aviationGold)
                        Text("°")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.aviationGold)
                    }
                } else {
                    Text("---°")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.dimText)
                }
            }

            // Planned DIST (distance from preceding waypoint)
            VStack(spacing: 2) {
                Text(L10n.Nav.dist)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.dimText)
                if index > 0, let dist = waypoint.distance {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.1f", dist))
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(.aviationGold)
                        Text("NM")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondaryText)
                    }
                } else {
                    Text("-- NM")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.dimText)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// ATO status display
    private func atoStatusRow(waypoint: FlightPlanWaypoint) -> some View {
        HStack(spacing: 12) {
            Text("ATO:")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.dimText)
            if let ato = waypoint.actualTimeOver {
                let formatter = DateFormatter()
                let _ = formatter.dateFormat = "HH:mm"
                Text(formatter.string(from: ato))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationGreen)
            } else {
                Text("--:--")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.dimText)
            }

            Spacer()

            // Planned ETO
            Text("ETO:")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.dimText)
            if let eto = waypoint.estimatedTimeOver {
                let formatter = DateFormatter()
                let _ = formatter.dateFormat = "HH:mm"
                Text(formatter.string(from: eto))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.primaryText)
            } else {
                Text("--:--")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.dimText)
            }
        }
    }

    /// SECONDARY display: Live GPS heading, distance, ETA to real next waypoint
    private func liveGPSDataRow(clLocation: CLLocation, plan: FlightPlan, isPreview: Bool) -> some View {
        VStack(spacing: 2) {
            // Label shows context
            Text(isPreview ? "\(L10n.Nav.hdgTo) \(L10n.Nav.nextWaypoint)" : L10n.Nav.hdgTo)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.dimText)

            HStack(spacing: 12) {
                // Live heading to real next waypoint
                if let bearing = flightPlanManager.bearingToNextWaypoint(from: clLocation) {
                    Text(String(format: "%03d°", Int(bearing)))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondaryText)
                }

                // Live distance
                if let distance = flightPlanManager.distanceToNextWaypoint(from: clLocation) {
                    Text(String(format: "%.1f NM", distance))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondaryText)
                }

                // Live ETA
                let groundSpeedKnots = max(locationManager.currentSpeedKnots, 1)
                if let eta = flightPlanManager.etaToNextWaypoint(from: clLocation, groundSpeedKnots: groundSpeedKnots) {
                    let etoDate = Date().addingTimeInterval(eta)
                    let formatter = DateFormatter()
                    let _ = formatter.dateFormat = "HH:mm"
                    Text(formatter.string(from: etoDate))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondaryText)
                }
            }
        }
    }

    /// Flight time display row
    private var flightTimeRow: some View {
        HStack(spacing: 12) {
            Text(L10n.FlightPlan.fltTime)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.dimText)

            if let takeoffTime = appState.lineUpTime {
                let elapsed = Date().timeIntervalSince(takeoffTime)
                let hours = Int(elapsed) / 3600
                let minutes = (Int(elapsed) % 3600) / 60
                let seconds = Int(elapsed) % 60
                Text(String(format: "%02d:%02d:%02d", hours, minutes, seconds))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondaryText)
                    .id(refreshTrigger) // Force refresh every second
            } else {
                Text("--:--:--")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.dimText)
            }
        }
    }

    private func progressSection(plan: FlightPlan) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(L10n.Nav.progress)
                    .font(.system(size: 10))
                    .foregroundColor(.secondaryText)
                Spacer()
                Text(String(format: "%.0f%%", plan.progress * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondaryText)
            }

            ProgressView(value: plan.progress)
                .progressViewStyle(LinearProgressViewStyle(tint: .aviationGreen))

            // Waypoint dots
            HStack(spacing: 4) {
                ForEach(0..<plan.waypoints.count, id: \.self) { index in
                    Circle()
                        .fill(index < plan.currentWaypointIndex ? Color.aviationGreen :
                              index == plan.currentWaypointIndex ? Color.aviationGold : Color.dimText)
                        .frame(width: 6, height: 6)
                }
            }
        }
    }

    private var chronometerSection: some View {
        VStack(spacing: 6) {
            HStack {
                Text(L10n.Nav.chronometer)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.dimText)

                Spacer()

                // Reset button
                Button(action: {
                    flightPlanManager.resetChronometer()
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12))
                        .foregroundColor(.secondaryText)
                }
            }

            Text(flightPlanManager.formattedChronometer)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundColor(.aviationGreen)
                .id(refreshTrigger) // Force refresh every second

            // EET to displayed waypoint (planned EET from flight plan, in MM format)
            if let plan = flightPlanManager.activeFlightPlan {
                let displayIndex = previewIndex ?? plan.currentWaypointIndex
                let clampedIndex = Swift.min(displayIndex, plan.waypoints.count - 1)
                if clampedIndex < plan.waypoints.count {
                    let displayWaypoint = plan.waypoints[clampedIndex]
                    if clampedIndex == 0 {
                        // First waypoint = departure airport
                        Text(L10n.FlightPlan.departure)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondaryText)
                    } else if let eet = displayWaypoint.estimatedElapsedTime {
                        let minutes = Int(eet / 60)
                        let extra = displayWaypoint.legEETExtra.map { Int($0 / 60) } ?? 0
                        HStack(spacing: 4) {
                            Text("EET")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.dimText)
                            if extra > 0 {
                                Text(String(format: "%d + %d", minutes, extra))
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(.aviationGold)
                            } else {
                                Text(String(format: "%d", minutes))
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(.aviationGold)
                            }
                            Text("min")
                                .font(.system(size: 10))
                                .foregroundColor(.secondaryText)
                        }
                    }
                }
            }

            // Start/Stop button
            if flightPlanManager.activeFlightPlan?.chronometerStartTime == nil {
                Button(action: {
                    flightPlanManager.startChronometer()
                }) {
                    Text(L10n.Nav.start)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.aviationGreen)
                        )
                }
            }
        }
    }

    private var quickActionsSection: some View {
        VStack(spacing: 8) {
            // Waypoint preview navigation (does NOT affect flight state)
            if let plan = flightPlanManager.activeFlightPlan {
                let displayIndex = previewIndex ?? plan.currentWaypointIndex
                let isPreview = previewIndex != nil && previewIndex != plan.currentWaypointIndex

                HStack(spacing: 12) {
                    Button(action: {
                        let current = previewIndex ?? plan.currentWaypointIndex
                        previewIndex = max(0, current - 1)
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primaryText)
                            .frame(width: 36, height: 28)
                            .background(Color.aviationBlue)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .disabled(displayIndex == 0)

                    if isPreview {
                        // Return to active waypoint button
                        Button(action: { previewIndex = nil }) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.black)
                                .frame(width: 36, height: 28)
                                .background(Color.aviationGold)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    } else {
                        Text(L10n.Nav.wpt)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondaryText)
                    }

                    Button(action: {
                        let current = previewIndex ?? plan.currentWaypointIndex
                        previewIndex = Swift.min(plan.waypoints.count - 1, current + 1)
                    }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primaryText)
                            .frame(width: 36, height: 28)
                            .background(Color.aviationGreen)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .disabled(displayIndex >= plan.waypoints.count - 1)
                }
            }

            // Departure time adjustment - only show on first waypoint
            if flightPlanManager.activeFlightPlan?.currentWaypointIndex == 0 {
                Button(action: { showingDepartureTimePicker = true }) {
                    HStack {
                        Image(systemName: "clock")
                        Text(L10n.FlightPlan.adjustDepartureTime)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.aviationGold)
                }
            }
        }
    }

    // MARK: - Drag Gesture

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true
                let startPosition = customPosition ?? currentPresetPosition.position(in: size, overlayWidth: overlayWidth, overlayHeight: overlayHeight)
                customPosition = CGPoint(
                    x: startPosition.x + value.translation.width,
                    y: startPosition.y + value.translation.height
                )
            }
            .onEnded { _ in
                isDragging = false
                // Snap to nearest preset position
                guard let current = customPosition else { return }
                let nearestPreset = findNearestPresetPosition(to: current, in: size)
                withAnimation(.easeOut(duration: 0.2)) {
                    customPosition = nil
                    currentPresetPosition = nearestPreset
                }
            }
    }

    /// Find the nearest preset position to a given point
    private func findNearestPresetPosition(to point: CGPoint, in size: CGSize) -> FlightPlanOverlayPosition {
        var nearestPosition = currentPresetPosition
        var nearestDistance = CGFloat.infinity

        for position in FlightPlanOverlayPosition.allCases {
            let presetPoint = position.position(in: size, overlayWidth: overlayWidth, overlayHeight: overlayHeight)
            let distance = hypot(point.x - presetPoint.x, point.y - presetPoint.y)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestPosition = position
            }
        }

        return nearestPosition
    }
}

// MARK: - Departure Time Picker Sheet

struct DepartureTimePickerSheet: View {
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedTime: Date = Date()

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Text(L10n.FlightPlan.adjustDepartureTimeDesc)
                    .font(.system(size: 14))
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                DatePicker(L10n.FlightPlan.departureTime, selection: $selectedTime, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.wheel)
                    .labelsHidden()

                Button(action: {
                    updateDepartureTime()
                }) {
                    Text(L10n.FlightPlan.updateDepartureTime)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.aviationGold)
                        )
                }
                .padding(.horizontal)

                Button(action: {
                    setDepartureTimeToNow()
                }) {
                    Text(L10n.FlightPlan.setDepartureTimeToNow)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.aviationGold, lineWidth: 1)
                        )
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .background(Color.cockpitBackground)
            .navigationTitle(L10n.FlightPlan.departureTime)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { dismiss() }
                }
            }
            .onAppear {
                if let departureTime = flightPlanManager.activeFlightPlan?.plannedDepartureTime {
                    selectedTime = departureTime
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func updateDepartureTime() {
        guard var plan = flightPlanManager.activeFlightPlan else { return }
        plan.plannedDepartureTime = selectedTime
        plan.calculateRouteData()
        flightPlanManager.updateFlightPlan(plan)
        dismiss()
    }

    private func setDepartureTimeToNow() {
        guard var plan = flightPlanManager.activeFlightPlan else { return }
        plan.plannedDepartureTime = Date()
        plan.calculateRouteData()
        flightPlanManager.updateFlightPlan(plan)
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.cockpitBackground.ignoresSafeArea()

        FlightPlanOverlayView(containerSize: CGSize(width: 400, height: 800))
            .environmentObject(FlightPlanManager())
            .environmentObject(LocationManager())
            .environmentObject(AppState())
    }
}
