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

    @State private var currentPresetPosition: FlightPlanOverlayPosition = .middleLeft
    @State private var customPosition: CGPoint? = nil
    @State private var isDragging = false
    @State private var isExpanded = true
    @State private var showingDepartureTimePicker = false

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
            .gesture(dragGesture(in: geometry.size))
            .animation(.easeInOut(duration: 0.3), value: currentPresetPosition)
        }
        .sheet(isPresented: $showingDepartureTimePicker) {
            DepartureTimePickerSheet()
                .environmentObject(flightPlanManager)
        }
    }

    /// Calculate the current position based on preset or custom drag
    private func currentPosition(in size: CGSize) -> CGPoint {
        var position: CGPoint
        if let custom = customPosition {
            position = constrainedPosition(custom, in: size)
        } else {
            position = currentPresetPosition.position(in: size, overlayWidth: overlayWidth, overlayHeight: overlayHeight)
        }

        // If radio frequency window is open and position overlaps with exclusion zone, move to left side
        if radioFrequencyWindowOpen {
            let overlayRect = CGRect(
                x: position.x - overlayWidth / 2,
                y: position.y - overlayHeight / 2,
                width: overlayWidth,
                height: overlayHeight
            )
            if overlayRect.intersects(radioFrequencyExclusionZone) {
                // Move to middle-left position
                position = FlightPlanOverlayPosition.middleLeft.position(in: size, overlayWidth: overlayWidth, overlayHeight: overlayHeight)
                // Clear custom position so it stays at preset
                DispatchQueue.main.async {
                    self.customPosition = nil
                    self.currentPresetPosition = .middleLeft
                }
            }
        }

        return position
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
            // Header with position selector and collapse button
            HStack {
                Text("FLIGHT PLAN")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.aviationGold)
                    .tracking(1)

                Spacer()

                // Position selector buttons
                HStack(spacing: 4) {
                    ForEach(FlightPlanOverlayPosition.allCases, id: \.rawValue) { position in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                customPosition = nil
                                currentPresetPosition = position
                            }
                        }) {
                            Image(systemName: position.icon)
                                .font(.system(size: 10))
                                .foregroundColor(currentPresetPosition == position && customPosition == nil ? .aviationGold : .secondaryText)
                        }
                    }
                }

                Divider()
                    .frame(height: 12)
                    .padding(.horizontal, 4)

                Button(action: { withAnimation { isExpanded = false } }) {
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
                // Next waypoint info
                if let plan = flightPlanManager.activeFlightPlan,
                   let nextWaypoint = plan.nextWaypoint {
                    nextWaypointSection(plan: plan, waypoint: nextWaypoint)
                } else {
                    Text("No active flight plan")
                        .font(.system(size: 12))
                        .foregroundColor(.secondaryText)
                        .padding()
                }

                Divider()
                    .background(Color.dimText)

                // Progress bar
                if let plan = flightPlanManager.activeFlightPlan {
                    progressSection(plan: plan)
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
            // Next waypoint
            if let plan = flightPlanManager.activeFlightPlan,
               let nextWaypoint = plan.nextWaypoint {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NEXT")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.dimText)
                    Text(nextWaypoint.name.isEmpty ? "WPT\(plan.currentWaypointIndex + 1)" : nextWaypoint.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                }

                // Distance, bearing & EET
                if let location = locationManager.currentLocation {
                    let clLocation = CLLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                    if let distance = flightPlanManager.distanceToNextWaypoint(from: clLocation),
                       let bearing = flightPlanManager.bearingToNextWaypoint(from: clLocation) {
                        VStack(alignment: .center, spacing: 2) {
                            HStack(spacing: 8) {
                                // Distance
                                Text(String(format: "%.1f", distance))
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(.aviationGold)
                                + Text(" NM")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondaryText)

                                // Heading
                                Text(String(format: "%03d°", Int(bearing)))
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundColor(.primaryText)
                            }

                            // EET to waypoint
                            let groundSpeedKnots = max((locationManager.currentLocation?.speed ?? 0) * 1.94384, 1)
                            if let eta = flightPlanManager.etaToNextWaypoint(from: clLocation, groundSpeedKnots: groundSpeedKnots) {
                                let minutes = Int(eta / 60)
                                let seconds = Int(eta) % 60
                                HStack(spacing: 4) {
                                    Text("EET")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.dimText)
                                    Text(String(format: "%d:%02d", minutes, seconds))
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundColor(.secondaryText)
                                }
                            }
                        }
                    }
                }

                Divider()
                    .frame(height: 30)
            }

            // Chronometer with label
            VStack(spacing: 2) {
                Text("CHRONO")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.dimText)
                Text(flightPlanManager.formattedChronometer)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationGreen)
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
    }

    // MARK: - Sections

    private func nextWaypointSection(plan: FlightPlan, waypoint: FlightPlanWaypoint) -> some View {
        VStack(spacing: 8) {
            // Waypoint name
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NEXT WAYPOINT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.dimText)
                    Text(waypoint.name.isEmpty ? "WPT\(plan.currentWaypointIndex + 1)" : waypoint.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(plan.currentWaypointIndex + 1)/\(plan.waypoints.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondaryText)
            }

            // Navigation data - Heading and Distance to next waypoint
            // Displayed prominently with real-time updates
            if let location = locationManager.currentLocation {
                let clLocation = CLLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)

                // Heading and Distance row - more prominent display
                HStack(spacing: 20) {
                    // Heading TO waypoint
                    VStack(spacing: 2) {
                        Text("HDG TO")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.dimText)
                        if let bearing = flightPlanManager.bearingToNextWaypoint(from: clLocation) {
                            HStack(alignment: .firstTextBaseline, spacing: 1) {
                                Text(String(format: "%03d", Int(bearing)))
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

                    // Distance TO waypoint
                    VStack(spacing: 2) {
                        Text("DIST TO")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.dimText)
                        if let distance = flightPlanManager.distanceToNextWaypoint(from: clLocation) {
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(String(format: "%.1f", distance))
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

                // EET row - smaller
                HStack(spacing: 12) {
                    Text("EET:")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.dimText)

                    let groundSpeedKnots = (locationManager.currentLocation?.speed ?? 0) * 1.94384
                    if let eta = flightPlanManager.etaToNextWaypoint(from: clLocation, groundSpeedKnots: max(groundSpeedKnots, 1)) {
                        let minutes = Int(eta / 60)
                        let seconds = Int(eta) % 60
                        if minutes > 60 {
                            Text(String(format: "%dh %02dm", minutes / 60, minutes % 60))
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.primaryText)
                        } else {
                            Text(String(format: "%d:%02d", minutes, seconds))
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.primaryText)
                        }
                    } else {
                        Text("--:--")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.dimText)
                    }
                }
            }

            // Planned altitude if set
            if let altitude = waypoint.altitude {
                HStack {
                    Text("Planned Alt:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondaryText)
                    Text(String(format: "%.0f ft", altitude))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.primaryText)
                }
            }
        }
    }

    private func progressSection(plan: FlightPlan) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text("Progress")
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
                Text("CHRONOMETER")
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

            // Start/Stop button
            if flightPlanManager.activeFlightPlan?.chronometerStartTime == nil {
                Button(action: {
                    flightPlanManager.startChronometer()
                }) {
                    Text("START")
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
            // Waypoint navigation
            HStack(spacing: 12) {
                Button(action: {
                    flightPlanManager.goToPreviousWaypoint()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primaryText)
                        .frame(width: 36, height: 28)
                        .background(Color.aviationBlue)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .disabled(flightPlanManager.activeFlightPlan?.currentWaypointIndex == 0)

                Text("WPT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondaryText)

                Button(action: {
                    flightPlanManager.advanceToNextWaypoint()
                }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primaryText)
                        .frame(width: 36, height: 28)
                        .background(Color.aviationGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .disabled(flightPlanManager.activeFlightPlan?.currentWaypointIndex == (flightPlanManager.activeFlightPlan?.waypoints.count ?? 0))
            }

            // Departure time adjustment
            Button(action: { showingDepartureTimePicker = true }) {
                HStack {
                    Image(systemName: "clock")
                    Text("Adjust Departure Time")
                }
                .font(.system(size: 11))
                .foregroundColor(.aviationGold)
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
                Text("Adjust the planned departure time to recalculate ETOs for all waypoints.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                DatePicker("Departure Time", selection: $selectedTime, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.wheel)
                    .labelsHidden()

                Button(action: {
                    updateDepartureTime()
                }) {
                    Text("Update Departure Time")
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

                Spacer()
            }
            .padding(.top)
            .background(Color.cockpitBackground)
            .navigationTitle("Departure Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.cockpitBackground.ignoresSafeArea()

        FlightPlanOverlayView(containerSize: CGSize(width: 400, height: 800))
            .environmentObject(FlightPlanManager())
            .environmentObject(LocationManager())
    }
}
