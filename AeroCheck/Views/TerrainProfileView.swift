import SwiftUI
import CoreLocation

/// View showing a horizontal terrain profile along the flight plan route
struct TerrainProfileView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    let waypoints: [FlightPlanWaypoint]

    @State private var terrainData: [(distance: Double, elevation: Double)] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isOutsideSwitzerland = false

    private let elevationService = ElevationService()

    var body: some View {
        NavigationView {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()

                if isLoading {
                    loadingView
                } else if isOutsideSwitzerland {
                    outsideSwitzerlandView
                } else if let error = loadError {
                    errorView(error)
                } else if terrainData.isEmpty {
                    noDataView
                } else {
                    profileContent
                }
            }
            .navigationTitle("Terrain Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await loadTerrainData()
        }
    }

    // MARK: - Content Views

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .aviationGold))
                .scaleEffect(1.5)

            Text("Loading terrain data...")
                .font(.system(size: 14))
                .foregroundColor(.secondaryText)

            Text("Fetching elevation from swisstopo")
                .font(.system(size: 12))
                .foregroundColor(.dimText)
        }
    }

    private var outsideSwitzerlandView: some View {
        VStack(spacing: 16) {
            Image(systemName: "map.fill")
                .font(.system(size: 48))
                .foregroundColor(.dimText)

            Text("Terrain Data Unavailable")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primaryText)

            Text("Terrain profile visualization is only available for routes within Switzerland using swisstopo data.")
                .font(.system(size: 14))
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                Text("Route must be within Swiss boundaries")
            }
            .font(.system(size: 12))
            .foregroundColor(.dimText)
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.aviationAmber)

            Text("Error Loading Terrain")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primaryText)

            Text(error)
                .font(.system(size: 14))
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: {
                Task { await loadTerrainData() }
            }) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(.aviationGold)
        }
    }

    private var noDataView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.downtrend.xyaxis")
                .font(.system(size: 48))
                .foregroundColor(.dimText)

            Text("No Terrain Data")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primaryText)

            Text("Could not fetch terrain data for this route.")
                .font(.system(size: 14))
                .foregroundColor(.secondaryText)
        }
    }

    private var profileContent: some View {
        VStack(spacing: 0) {
            // Legend and info
            HStack {
                legendItem(color: .brown.opacity(0.6), label: "Terrain")
                legendItem(color: .aviationGold, label: "Planned Alt")

                Spacer()

                // Altitude unit selector
                Picker("Unit", selection: Binding(
                    get: { appState.settings.terrainAltitudeUnit },
                    set: { appState.settings.terrainAltitudeUnit = $0; appState.saveSettings() }
                )) {
                    ForEach(TerrainAltitudeUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            .padding()
            .background(Color.panelBackground)

            // Profile chart
            GeometryReader { geometry in
                profileChart(in: geometry.size)
            }
            .padding()

            // Waypoint list
            waypointList
                .frame(height: 80)
                .background(Color.panelBackground)
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(color)
                .frame(width: 16, height: 10)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondaryText)
        }
    }

    // MARK: - Profile Chart

    private func profileChart(in size: CGSize) -> some View {
        let maxElevation = (terrainData.map { $0.elevation }.max() ?? 0) * 1.2 // 20% headroom
        let minElevation = max(0, (terrainData.map { $0.elevation }.min() ?? 0) - 100)
        let maxDistance = terrainData.last?.distance ?? 1
        _ = max(maxElevation - minElevation, 100)

        // Also consider planned altitudes
        let maxPlannedAlt = waypoints.compactMap { $0.altitude }.max().map { $0 * 0.3048 } ?? maxElevation
        let displayMaxElevation = max(maxElevation, maxPlannedAlt * 1.1)
        let displayRange = max(displayMaxElevation - minElevation, 100)

        return ZStack {
            // Grid lines
            ForEach(0..<5) { i in
                let y = size.height * CGFloat(i) / 4
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                .stroke(Color.dimText.opacity(0.3), lineWidth: 0.5)

                // Y-axis labels
                let elevation = displayMaxElevation - (displayRange * Double(i) / 4)
                Text(formatElevation(elevation))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.dimText)
                    .position(x: 30, y: y)
            }

            // Terrain profile
            if !terrainData.isEmpty {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height))

                    for point in terrainData {
                        let x = CGFloat(point.distance / maxDistance) * size.width
                        let y = size.height - CGFloat((point.elevation - minElevation) / displayRange) * size.height
                        path.addLine(to: CGPoint(x: x, y: y))
                    }

                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [.brown.opacity(0.6), .brown.opacity(0.2)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Terrain outline
                Path { path in
                    var started = false
                    for point in terrainData {
                        let x = CGFloat(point.distance / maxDistance) * size.width
                        let y = size.height - CGFloat((point.elevation - minElevation) / displayRange) * size.height
                        if !started {
                            path.move(to: CGPoint(x: x, y: y))
                            started = true
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.brown, lineWidth: 1.5)
            }

            // Planned altitude line
            plannedAltitudeLine(in: size, maxDistance: maxDistance, minElevation: minElevation, displayRange: displayRange)

            // Waypoint markers
            waypointMarkers(in: size, maxDistance: maxDistance)
        }
    }

    private func plannedAltitudeLine(in size: CGSize, maxDistance: Double, minElevation: Double, displayRange: Double) -> some View {
        let waypointDistances = calculateWaypointDistances()

        return ZStack {
            // Line connecting waypoint altitudes
            Path { path in
                var started = false
                for (index, waypoint) in waypoints.enumerated() {
                    guard let altitude = waypoint.altitude else { continue }
                    let altitudeMeters = altitude * 0.3048

                    let distance = index < waypointDistances.count ? waypointDistances[index] : maxDistance
                    let x = CGFloat(distance / maxDistance) * size.width
                    let y = size.height - CGFloat((altitudeMeters - minElevation) / displayRange) * size.height

                    if !started {
                        path.move(to: CGPoint(x: x, y: y))
                        started = true
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Color.aviationGold, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))

            // Altitude points
            ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, waypoint in
                if let altitude = waypoint.altitude {
                    let altitudeMeters = altitude * 0.3048
                    let distance = index < waypointDistances.count ? waypointDistances[index] : maxDistance
                    let x = CGFloat(distance / maxDistance) * size.width
                    let y = size.height - CGFloat((altitudeMeters - minElevation) / displayRange) * size.height

                    Circle()
                        .fill(Color.aviationGold)
                        .frame(width: 8, height: 8)
                        .position(x: x, y: y)
                }
            }
        }
    }

    private func waypointMarkers(in size: CGSize, maxDistance: Double) -> some View {
        let waypointDistances = calculateWaypointDistances()

        return ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, waypoint in
            let distance = index < waypointDistances.count ? waypointDistances[index] : maxDistance
            let x = CGFloat(distance / maxDistance) * size.width

            VStack(spacing: 2) {
                // Waypoint name
                Text(waypoint.name.isEmpty ? "WPT\(index + 1)" : waypoint.name)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.primaryText)
                    .lineLimit(1)
                    .frame(width: 50)

                // Vertical line
                Rectangle()
                    .fill(Color.aviationBlue.opacity(0.5))
                    .frame(width: 1, height: size.height)
            }
            .position(x: x, y: size.height / 2)
        }
    }

    // MARK: - Waypoint List

    private var waypointList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, waypoint in
                    VStack(spacing: 4) {
                        Text(waypoint.name.isEmpty ? "WPT\(index + 1)" : waypoint.name)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.primaryText)
                            .lineLimit(1)

                        if let altitude = waypoint.altitude {
                            Text(formatAltitude(altitude))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.aviationGold)
                        }

                        if let distance = waypoint.distance {
                            Text(String(format: "%.1f NM", distance))
                                .font(.system(size: 9))
                                .foregroundColor(.secondaryText)
                        }
                    }
                    .frame(width: 70)
                    .padding(.vertical, 8)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Helpers

    private func loadTerrainData() async {
        isLoading = true
        loadError = nil
        isOutsideSwitzerland = false

        // Check if route is within Switzerland
        let coordinates = waypoints.map { $0.coordinate }

        // Check if all waypoints are in Switzerland
        var allInSwitzerland = true
        for coord in coordinates {
            if await !elevationService.isInSwitzerland(coord) {
                allInSwitzerland = false
                break
            }
        }

        if !allInSwitzerland {
            isOutsideSwitzerland = true
            isLoading = false
            return
        }

        // Fetch terrain data
        terrainData = await elevationService.fetchRouteElevationsOptimized(
            waypoints: coordinates,
            totalSamples: 50
        )

        if terrainData.isEmpty {
            loadError = "Unable to fetch elevation data. Please check your internet connection."
        }

        isLoading = false
    }

    private func calculateWaypointDistances() -> [Double] {
        var distances: [Double] = []
        var cumulative: Double = 0

        for waypoint in waypoints {
            distances.append(cumulative)
            if let distance = waypoint.distance {
                cumulative += distance
            }
        }

        return distances
    }

    private func formatElevation(_ meters: Double) -> String {
        switch appState.settings.terrainAltitudeUnit {
        case .feet:
            return String(format: "%.0f ft", meters * 3.28084)
        case .meters:
            return String(format: "%.0f m", meters)
        case .dual:
            return String(format: "%.0f ft\n%.0f m", meters * 3.28084, meters)
        }
    }

    private func formatAltitude(_ feet: Double) -> String {
        switch appState.settings.terrainAltitudeUnit {
        case .feet:
            return String(format: "%.0f ft", feet)
        case .meters:
            return String(format: "%.0f m", feet * 0.3048)
        case .dual:
            return String(format: "%.0f ft", feet)
        }
    }
}

// MARK: - Preview

#Preview {
    TerrainProfileView(waypoints: [
        FlightPlanWaypoint(
            name: "LSZQ",
            coordinate: CLLocationCoordinate2D(latitude: 47.5, longitude: 7.5),
            altitude: 5000
        ),
        FlightPlanWaypoint(
            name: "JORAT",
            coordinate: CLLocationCoordinate2D(latitude: 46.8, longitude: 7.2),
            altitude: 6000
        ),
        FlightPlanWaypoint(
            name: "LSGG",
            coordinate: CLLocationCoordinate2D(latitude: 46.2, longitude: 6.1),
            altitude: 4000
        )
    ])
    .environmentObject(AppState())
}
