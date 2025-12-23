import SwiftUI
import CoreLocation

/// Overlay HUD showing flight plan progress during navigation
/// Movable and resizable, displays next waypoint, distance, bearing, ETA, and chronometer
struct FlightPlanOverlayView: View {
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var locationManager: LocationManager

    @State private var position: CGPoint = CGPoint(x: 100, y: 100)
    @State private var isDragging = false
    @State private var isExpanded = true
    @State private var showingDepartureTimePicker = false

    let containerSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if isExpanded {
                    expandedContent
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
            .position(constrainedPosition(in: geometry.size))
            .gesture(dragGesture)
        }
        .sheet(isPresented: $showingDepartureTimePicker) {
            DepartureTimePickerSheet()
                .environmentObject(flightPlanManager)
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(spacing: 0) {
            // Header with collapse button
            HStack {
                Text("FLIGHT PLAN")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.aviationGold)
                    .tracking(1)

                Spacer()

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

                // Distance & bearing
                if let location = locationManager.currentLocation {
                    let clLocation = CLLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                    if let distance = flightPlanManager.distanceToNextWaypoint(from: clLocation),
                       let bearing = flightPlanManager.bearingToNextWaypoint(from: clLocation) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.1f NM", distance))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.aviationGold)
                            Text(String(format: "%03d°", Int(bearing)))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondaryText)
                        }
                    }
                }
            }

            // Chronometer
            Text(flightPlanManager.formattedChronometer)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.aviationGreen)

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

            // Navigation data grid
            if let location = locationManager.currentLocation {
                let clLocation = CLLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)

                HStack(spacing: 16) {
                    // Distance
                    VStack(spacing: 2) {
                        Text("DIST")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.dimText)
                        if let distance = flightPlanManager.distanceToNextWaypoint(from: clLocation) {
                            Text(String(format: "%.1f", distance))
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(.aviationGold)
                            Text("NM")
                                .font(.system(size: 9))
                                .foregroundColor(.secondaryText)
                        } else {
                            Text("--")
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(.dimText)
                        }
                    }

                    // Bearing
                    VStack(spacing: 2) {
                        Text("BRG")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.dimText)
                        if let bearing = flightPlanManager.bearingToNextWaypoint(from: clLocation) {
                            Text(String(format: "%03d", Int(bearing)))
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(.primaryText)
                            Text("°M")
                                .font(.system(size: 9))
                                .foregroundColor(.secondaryText)
                        } else {
                            Text("---")
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(.dimText)
                        }
                    }

                    // ETA
                    VStack(spacing: 2) {
                        Text("ETA")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.dimText)

                        let groundSpeedKnots = (locationManager.currentLocation?.speed ?? 0) * 1.94384
                        if let eta = flightPlanManager.etaToNextWaypoint(from: clLocation, groundSpeedKnots: max(groundSpeedKnots, 1)) {
                            let minutes = Int(eta / 60)
                            let seconds = Int(eta) % 60
                            if minutes > 60 {
                                Text(String(format: "%d:%02d", minutes / 60, minutes % 60))
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundColor(.primaryText)
                                Text("h:mm")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondaryText)
                            } else {
                                Text(String(format: "%d:%02d", minutes, seconds))
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundColor(.primaryText)
                                Text("m:ss")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondaryText)
                            }
                        } else {
                            Text("--:--")
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(.dimText)
                        }
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

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true
                position = CGPoint(
                    x: position.x + value.translation.width,
                    y: position.y + value.translation.height
                )
            }
            .onEnded { _ in
                isDragging = false
            }
    }

    private func constrainedPosition(in size: CGSize) -> CGPoint {
        let overlayWidth: CGFloat = isExpanded ? 220 : 280
        let overlayHeight: CGFloat = isExpanded ? 350 : 50
        let padding: CGFloat = 10

        let x = max(overlayWidth / 2 + padding, min(size.width - overlayWidth / 2 - padding, position.x))
        let y = max(overlayHeight / 2 + padding, min(size.height - overlayHeight / 2 - padding, position.y))

        return CGPoint(x: x, y: y)
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
