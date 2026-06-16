import SwiftUI
import MapKit

// MARK: - Flight Plan Map Builder (Phase 3.4)

/// Map-centric flight-plan builder — the default creation/edit path. Tap the map or search
/// ICAO/name to add waypoints; the route draws live with numbered markers; a side panel (iPad
/// landscape) or bottom panel (portrait/iPhone) shows the route summary + a reorderable waypoint
/// list with editable altitudes. The dense tabular `FlightPlanEditorView` stays reachable as the
/// "Table" (advanced) view. All mutations go through `FlightPlanManager` (single source of truth,
/// auto-recalculates the route), so the builder reads the live plan by id and stays reactive.
struct FlightPlanMapBuilderView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @EnvironmentObject var locationManager: LocationManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let planId: UUID

    @State private var selectedLayer: WaypointPickerMapLayer = .icao
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.1, longitude: 7.1), // Swiss Jura default
        span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2)
    )
    @State private var visibleAirports: [Airport] = []
    @State private var airportUpdateTask: Task<Void, Never>?
    @State private var fitRouteToken = 0
    @State private var didInitialFit = false

    @State private var fromText = ""
    @State private var toText = ""
    @FocusState private var focusedEndpoint: RouteEndpoint?
    @State private var searchResults: [Airport] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var listEditMode: EditMode = .inactive

    enum RouteEndpoint: Hashable { case from, to }
    @State private var editingWaypoint: FlightPlanWaypoint?
    @State private var showTableEditor = false
    @State private var showTerrain = false
    @State private var exportItem: FlightPlanExportItem?

    /// Live plan from the manager (single source of truth).
    private var plan: FlightPlan? {
        flightPlanManager.flightPlans.first { $0.id == planId }
    }

    private var waypoints: [FlightPlanWaypoint] { plan?.waypoints ?? [] }

    /// Title derives the route (FROM → TO) when the plan is unnamed, so a new plan is auto-named by its
    /// endpoints; a custom name (set in the Table) wins. (flight-plan revamp #2)
    private var builderTitle: String {
        if let p = plan, !p.name.isEmpty { return p.name }
        let names = waypoints.map { $0.name.isEmpty ? L10n.Nav.wpt : $0.name }
        if names.count >= 2, let f = names.first, let l = names.last { return "\(f) → \(l)" }
        return L10n.Nav.newFlightPlan
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let twoColumn = horizontalSizeClass == .regular && geo.size.width > geo.size.height
                Group {
                    if twoColumn {
                        HStack(spacing: 0) {
                            mapArea
                                .frame(width: geo.size.width * 0.6)
                            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                            sidePanel
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        VStack(spacing: 0) {
                            mapArea
                                .frame(height: geo.size.height * 0.46)
                            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                            sidePanel
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .background(Color.cockpitBackground)
            .navigationTitle(builderTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.done) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showTableEditor = true
                    } label: {
                        Label("Table", systemImage: "tablecells")
                    }
                    .accessibilityLabel("Advanced table editor")
                }
            }
            .sheet(isPresented: $showTableEditor) {
                if let plan {
                    FlightPlanEditorView(flightPlan: plan)
                        .environmentObject(appState)
                        .environmentObject(flightPlanManager)
                        .environmentObject(airportDataService)
                        .environmentObject(openAIPDataService)
                }
            }
            .sheet(item: $editingWaypoint) { waypoint in
                WaypointEditorSheet(
                    waypoint: waypoint,
                    aircraftType: plan?.aircraftTypeId ?? "WT9",
                    onSave: { updated in flightPlanManager.updateWaypoint(updated, in: planId) },
                    onDelete: { flightPlanManager.removeWaypoint(waypoint, from: planId) }
                )
                .environmentObject(appState)
                .environmentObject(airportDataService)
            }
            .sheet(isPresented: $showTerrain) {
                TerrainProfileView(waypoints: waypoints)
                    .environmentObject(appState)
            }
            .sheet(item: $exportItem) { item in
                FlightPlanExportSheet(data: item.data, filename: item.filename, format: item.format)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            Task {
                await airportDataService.ensureLoaded()
                scheduleAirportUpdate()
            }
            initialFitIfNeeded()
        }
        .onChange(of: region.center.latitude) { _, _ in scheduleAirportUpdate() }
        .onChange(of: region.center.longitude) { _, _ in scheduleAirportUpdate() }
    }

    // MARK: - Map area

    private var mapArea: some View {
        ZStack(alignment: .top) {
            RouteBuilderMapView(
                waypoints: waypoints,
                mapLayer: selectedLayer,
                airports: visibleAirports,
                fitRouteToken: fitRouteToken,
                region: $region,
                onMapTap: { coordinate in
                    flightPlanManager.addWaypoint(to: planId, coordinate: coordinate)
                },
                onAirportTap: { airport in addAirport(airport) }
            )
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 8) {
                fromToBar
                HStack {
                    layerPicker
                    Spacer()
                    fitRouteButton
                }
            }
            .padding(12)
        }
    }

    /// From → To endpoint bar — the destination-first entry. Type/select airfields to seed a direct
    /// route (or change the endpoints of an existing one); intermediate waypoints come from tapping the
    /// map / airport markers, or the Table. (flight-plan revamp #2)
    private var fromToBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                endpointField(.from)
                Button { swapEndpoints() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(waypoints.count >= 2 ? .secondaryText : .dimText.opacity(0.4))
                        .frame(width: 30, height: 30)
                }
                .disabled(waypoints.count < 2)
                .accessibilityLabel(L10n.Nav.swapEndpoints)
                endpointField(.to)
            }
            .padding(8)
            .floatingChromeBackground(cornerRadius: 12)

            if focusedEndpoint != nil && !searchResults.isEmpty {
                airportResults { airport in
                    if let slot = focusedEndpoint { setEndpoint(slot, airport) }
                }
                .floatingChromeBackground(cornerRadius: 12)
                .padding(.top, 4)
            }
        }
        .onChange(of: fromText) { _, q in if focusedEndpoint == .from { scheduleSearch(q) } }
        .onChange(of: toText) { _, q in if focusedEndpoint == .to { scheduleSearch(q) } }
        .onChange(of: focusedEndpoint) { _, _ in searchTask?.cancel(); searchResults = [] }
        .onChange(of: routeSignature) { _, _ in if focusedEndpoint == nil { syncEndpointText() } }
        .onAppear { syncEndpointText() }
    }

    private func endpointField(_ slot: RouteEndpoint) -> some View {
        HStack(spacing: 6) {
            Text(slot == .from ? L10n.Nav.from : L10n.Nav.to)
                .font(.system(size: 9, weight: .semibold)).tracking(0.4).foregroundColor(.dimText)
            TextField(slot == .from ? L10n.Nav.from : L10n.Nav.to,
                      text: slot == .from ? $fromText : $toText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(slot == .from ? .aviationGreen : .aviationGold)
                .focused($focusedEndpoint, equals: slot)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }

    private func airportResults(onSelect: @escaping (Airport) -> Void) -> some View {
        let reference = searchReference
        return VStack(spacing: 0) {
            ForEach(searchResults.prefix(6)) { airport in
                Button { onSelect(airport) } label: {
                    HStack(spacing: 10) {
                        Text(airport.ident)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.aviationGold)
                            .frame(width: 58, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(airport.name)
                                .font(.system(size: 13))
                                .foregroundColor(.primaryText)
                                .lineLimit(1)
                            if let muni = airport.municipality, !muni.isEmpty, muni != airport.name {
                                Text(muni)
                                    .font(.system(size: 10))
                                    .foregroundColor(.dimText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        if let dist = distanceLabel(to: airport, from: reference) {
                            Text(dist)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondaryText)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if airport.id != searchResults.prefix(6).last?.id {
                    Divider().background(Color.white.opacity(0.06))
                }
            }
        }
    }

    /// Endpoint-change signature, to re-sync the field text when the route changes elsewhere (map tap).
    private var routeSignature: String { "\(waypoints.first?.name ?? "")|\(waypoints.last?.name ?? "")|\(waypoints.count)" }

    /// Reference point for ordering search results by distance (feedback #2): a destination sorts
    /// relative to the departure (or, failing that, where you are / the map you're looking at); a
    /// departure sorts relative to your position (or a set destination / the map).
    private var searchReference: CLLocationCoordinate2D? {
        let here = locationManager.getCurrentCoordinate()
        switch focusedEndpoint {
        case .to:
            return waypoints.first?.coordinate ?? here ?? region.center
        case .from, .none:
            return here ?? (waypoints.count >= 2 ? waypoints.last?.coordinate : nil) ?? region.center
        }
    }

    /// Debounced, distance-aware, fixed-wing-only airport search. Debouncing keeps each keystroke off
    /// the ~40K-airport scan (feedback #1 perf); `near:`/`types:` apply the distance sort + heliport
    /// filter (feedback #2/#3). Runs on the main actor (the service is `@MainActor`); the sleep simply
    /// coalesces bursts of typing into one scan.
    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { searchResults = []; return }
        let reference = searchReference
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let results = airportDataService.searchAirports(
                query: trimmed, limit: 12, near: reference, types: AirportType.fixedWing)
            guard !Task.isCancelled else { return }
            searchResults = results
        }
    }

    /// Great-circle distance from a reference point to an airport, shown on each result row so the
    /// distance ordering is legible.
    private func distanceLabel(to airport: Airport, from reference: CLLocationCoordinate2D?) -> String? {
        guard let reference = reference else { return nil }
        let from = CLLocation(latitude: reference.latitude, longitude: reference.longitude)
        let to = CLLocation(latitude: airport.latitude, longitude: airport.longitude)
        return String(format: "%.0f NM", from.distance(from: to) / 1852.0)
    }

    private func syncEndpointText() {
        fromText = waypoints.first?.name ?? ""
        toText = waypoints.count >= 2 ? (waypoints.last?.name ?? "") : ""
    }

    /// Set the FROM or TO endpoint to an airfield — seeds a direct route, or updates the endpoint of an
    /// existing one (reusing the ident name + auto frequency + elevation). (flight-plan revamp #2)
    private func setEndpoint(_ slot: RouteEndpoint, _ airport: Airport) {
        switch slot {
        case .from:
            if var wp = waypoints.first {
                applyAirport(airport, to: &wp)
                flightPlanManager.updateWaypoint(wp, in: planId)
            } else {
                addAirport(airport)
            }
            fromText = airport.ident
        case .to:
            if waypoints.count >= 2, var wp = waypoints.last {
                applyAirport(airport, to: &wp)
                flightPlanManager.updateWaypoint(wp, in: planId)
            } else {
                addAirport(airport) // appends → makes [from, to] (or the only point)
            }
            toText = airport.ident
        }
        focusedEndpoint = nil
        searchResults = []
        fitRouteToken += 1
    }

    private func applyAirport(_ airport: Airport, to wp: inout FlightPlanWaypoint) {
        wp.name = airport.ident
        wp.coordinate = airport.coordinate
        wp.callSign = airport.ident
        let freqs = airportDataService.getFrequencies(for: airport.ident)
        wp.frequency = (freqs.first { $0.type.uppercased().contains("TWR") }
            ?? freqs.first { $0.type.uppercased().contains("ATIS") } ?? freqs.first)?.formattedFrequency
        if let elevation = airport.elevation { wp.altitude = Double(elevation) }
    }

    private func swapEndpoints() {
        flightPlanManager.reverseRoute(planId: planId)
        syncEndpointText()
        fitRouteToken += 1
    }

    private var layerPicker: some View {
        Menu {
            Picker("Map layer", selection: $selectedLayer) {
                ForEach(WaypointPickerMapLayer.allCases) { layer in
                    Label(layer.rawValue, systemImage: layer.icon).tag(layer)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedLayer.icon).font(.system(size: 13, weight: .semibold))
                Text(selectedLayer.rawValue).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .floatingChromeBackground(cornerRadius: 12)
        }
    }

    private var fitRouteButton: some View {
        Button { fitRouteToken += 1 } label: {
            Image(systemName: "scope")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primaryText)
                .frame(width: 40, height: 40)
                .floatingChromeCircle()
        }
        .disabled(waypoints.isEmpty)
        .opacity(waypoints.isEmpty ? 0.4 : 1)
        .accessibilityLabel("Fit route")
    }

    // MARK: - Side / bottom panel

    private var sidePanel: some View {
        VStack(spacing: 0) {
            routeSummary
            if waypoints.isEmpty {
                emptyRouteHint
            } else {
                if waypoints.count >= 2 { waypointListHeader }
                waypointList
            }
            panelActions
        }
        .background(Color.cockpitBackground)
        .onChange(of: waypoints.count) { _, count in
            if count < 2 { listEditMode = .inactive }
        }
    }

    /// Thin header above the waypoint list with the single reorder toggle. Replaces the navigation-bar
    /// `EditButton` that previously collided with the screen's "Done" (feedback #7): the toggle lives
    /// next to the list it edits, leaving exactly one unambiguous "Done" in the top bar to exit.
    private var waypointListHeader: some View {
        HStack(spacing: 8) {
            if listEditMode == .active {
                Text(L10n.Nav.dragToReorder)
                    .font(.system(size: 10))
                    .foregroundColor(.dimText)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    listEditMode = (listEditMode == .active ? .inactive : .active)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(listEditMode == .active ? .black : .aviationGold)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(listEditMode == .active ? Color.aviationGold : Color.white.opacity(0.06)))
            }
            .accessibilityLabel(L10n.Nav.reorderWaypoints)
            .accessibilityAddTraits(listEditMode == .active ? [.isSelected] : [])
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var panelActions: some View {
        HStack(spacing: 10) {
            Button { showTerrain = true } label: {
                Label("Terrain", systemImage: "mountain.2.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
                    .foregroundColor(.primaryText)
            }
            Button { exportGPX() } label: {
                Label("Export GPX", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.aviationGold))
                    .foregroundColor(.black)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .disabled(waypoints.count < 2)
        .opacity(waypoints.count < 2 ? 0.4 : 1)
    }

    private var routeSummary: some View {
        HStack(spacing: 0) {
            summaryMetric("WAYPOINTS", "\(waypoints.count)", .primaryText)
            summaryDivider
            summaryMetric("DISTANCE", String(format: "%.0f NM", plan?.totalDistance ?? 0), .altimeterBlue)
            summaryDivider
            summaryMetric("EET", plan?.formattedTotalEET ?? "0:00", .aviationGold)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(Color.cardBackground)
    }

    private func summaryMetric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundColor(.secondaryText)
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryDivider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 30)
    }

    private var emptyRouteHint: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "hand.tap")
                .font(.system(size: 40))
                .foregroundColor(.dimText)
            Text("Tap the map or search an ICAO\nto add your first waypoint")
                .font(.system(size: 14))
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var waypointList: some View {
        List {
            ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, waypoint in
                WaypointBuilderRow(
                    index: index,
                    waypoint: waypoint,
                    isLast: index == waypoints.count - 1,
                    onEditAltitude: { feet in
                        var wp = waypoint
                        wp.altitude = feet
                        flightPlanManager.updateWaypoint(wp, in: planId)
                    },
                    onTap: { editingWaypoint = waypoint }
                )
                .listRowBackground(Color.cardBackground)
                .listRowSeparatorTint(Color.white.opacity(0.06))
            }
            .onMove { source, destination in
                flightPlanManager.moveWaypoints(in: planId, from: source, to: destination)
            }
            .onDelete { offsets in
                for index in offsets where index < waypoints.count {
                    flightPlanManager.removeWaypoint(waypoints[index], from: planId)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $listEditMode)
    }

    // MARK: - Actions

    /// Add an airport as a waypoint, carrying its identifier as name + call sign and the primary
    /// (TWR/ATIS/first) frequency. The manager appends + recalculates; we then set the radio fields
    /// on the just-added waypoint.
    private func addAirport(_ airport: Airport) {
        flightPlanManager.addWaypoint(to: planId, coordinate: airport.coordinate, name: airport.ident)
        guard let p = plan, var wp = p.waypoints.last else { return }
        let freqs = airportDataService.getFrequencies(for: airport.ident)
        let primary = freqs.first { $0.type.uppercased().contains("TWR") }
            ?? freqs.first { $0.type.uppercased().contains("ATIS") }
            ?? freqs.first
        wp.callSign = airport.ident
        wp.frequency = primary?.formattedFrequency
        if let elevation = airport.elevation, wp.altitude == nil {
            wp.altitude = Double(elevation)
        }
        flightPlanManager.updateWaypoint(wp, in: planId)
    }

    /// Export the route as an avionics-compatible GPX (Dynon / Garmin) via the shared service.
    private func exportGPX() {
        guard let plan, let data = FlightPlanExportService.exportToAvionicsGPX(plan) else { return }
        exportItem = FlightPlanExportItem(data: data, filename: plan.exportFilename, format: .gpx)
    }

    /// Center the map on the existing route once when opening an already-populated plan.
    private func initialFitIfNeeded() {
        guard !didInitialFit else { return }
        didInitialFit = true
        if !waypoints.isEmpty {
            // Defer to the next runloop so the map view exists.
            DispatchQueue.main.async { fitRouteToken += 1 }
        }
    }

    private func scheduleAirportUpdate() {
        airportUpdateTask?.cancel()
        airportUpdateTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms debounce
            guard !Task.isCancelled else { return }
            guard airportDataService.isDataAvailable else {
                await MainActor.run { visibleAirports = [] }
                return
            }
            let r = region
            let halfLat = r.span.latitudeDelta / 2
            let halfLon = r.span.longitudeDelta / 2
            let airports = airportDataService.getAirportsInRegion(
                minLat: r.center.latitude - halfLat,
                maxLat: r.center.latitude + halfLat,
                minLon: r.center.longitude - halfLon,
                maxLon: r.center.longitude + halfLon,
                types: AirportType.fixedWing, // fixed-wing only (see CLAUDE.md "Re-enabling heliports")
                limit: 80
            )
            await MainActor.run { visibleAirports = airports }
        }
    }
}

// MARK: - Waypoint list row

private struct WaypointBuilderRow: View {
    let index: Int
    let waypoint: FlightPlanWaypoint
    let isLast: Bool
    let onEditAltitude: (Double?) -> Void
    let onTap: () -> Void

    @State private var altitudeText: String = ""
    @FocusState private var altitudeFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Numbered badge
            Text("\(index + 1)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.aviationGold))
                .accessibilityLabel("Waypoint \(index + 1)")

            VStack(alignment: .leading, spacing: 3) {
                Button(action: onTap) {
                    Text(waypoint.name.isEmpty ? "WPT\(index + 1)" : waypoint.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                // Inline leg data to the NEXT waypoint (nil on the last waypoint).
                if !isLast {
                    Text(legLine)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.dimText)
                        .lineLimit(1)
                } else {
                    Text("destination")
                        .font(.system(size: 11))
                        .foregroundColor(.dimText)
                }
            }

            Spacer(minLength: 6)

            // Editable altitude chip (feet).
            HStack(spacing: 3) {
                TextField("ALT", text: $altitudeText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primaryText)
                    .frame(width: 52)
                    .focused($altitudeFocused)
                    .accessibilityLabel("Planned altitude in feet")
                Text("ft")
                    .font(.system(size: 11))
                    .foregroundColor(.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        }
        .padding(.vertical, 6)
        .onAppear { altitudeText = waypoint.altitude.map { String(Int($0)) } ?? "" }
        .onChange(of: altitudeFocused) { _, focused in
            if !focused { commitAltitude() }
        }
    }

    private var legLine: String {
        var parts: [String] = []
        if let mc = waypoint.magneticCourse { parts.append(String(format: "%03.0f°", mc)) }
        if let dist = waypoint.distance { parts.append(String(format: "%.0f NM", dist)) }
        if let eet = waypoint.formattedEET { parts.append("\(eet)′") }
        return parts.isEmpty ? "—" : parts.joined(separator: "  ·  ")
    }

    private func commitAltitude() {
        let trimmed = altitudeText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            onEditAltitude(nil)
        } else if let value = Double(trimmed) {
            onEditAltitude(value)
        }
    }
}

// MARK: - Route builder map (UIViewRepresentable)

/// Live route map: swisstopo/Apple tile overlay + gold route polyline + numbered waypoint markers +
/// nearby airport markers. Tapping empty map adds a free waypoint; tapping an airport marker adds
/// that airport. Reuses the waypoint-picker tile overlays.
struct RouteBuilderMapView: UIViewRepresentable {
    let waypoints: [FlightPlanWaypoint]
    let mapLayer: WaypointPickerMapLayer
    var airports: [Airport]
    var fitRouteToken: Int
    @Binding var region: MKCoordinateRegion
    var onMapTap: (CLLocationCoordinate2D) -> Void
    var onAirportTap: (Airport) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.setRegion(region, animated: false)
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.showsScale = true
        configureLayer(mapView)
        mapView.cameraZoomRange = cameraZoomRange(for: mapLayer)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if context.coordinator.currentLayer != mapLayer {
            context.coordinator.currentLayer = mapLayer
            configureLayer(mapView)
            mapView.cameraZoomRange = cameraZoomRange(for: mapLayer)
        }

        updateAirportAnnotations(mapView, context: context)
        updateRoute(mapView, context: context)

        if context.coordinator.lastFitToken != fitRouteToken {
            context.coordinator.lastFitToken = fitRouteToken
            fitRoute(mapView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: Layer

    private func cameraZoomRange(for layer: WaypointPickerMapLayer) -> MKMapView.CameraZoomRange? {
        switch layer {
        case .apple:
            return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 100, maxCenterCoordinateDistance: 10_000_000)
        case .icao:
            return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 65_000, maxCenterCoordinateDistance: 600_000)
        case .swissimage:
            return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 1_500, maxCenterCoordinateDistance: 600_000)
        }
    }

    private func configureLayer(_ mapView: MKMapView) {
        let existingTiles = mapView.overlays.compactMap { $0 as? MKTileOverlay }
        mapView.removeOverlays(existingTiles)

        switch mapLayer {
        case .apple:
            mapView.mapType = .standard
        case .icao:
            mapView.mapType = .standard
            let overlay = ICAOSegelflugkarteTileOverlay()
            overlay.canReplaceMapContent = true
            mapView.insertOverlay(overlay, at: 0, level: .aboveLabels)
        case .swissimage:
            mapView.mapType = .standard
            let overlay = SwisstopoTileOverlay(layerIdentifier: "ch.swisstopo.swissimage", tileExtension: "jpeg")
            overlay.canReplaceMapContent = true
            mapView.insertOverlay(overlay, at: 0, level: .aboveLabels)
        }
    }

    // MARK: Airports

    private func updateAirportAnnotations(_ mapView: MKMapView, context: Context) {
        let existing = mapView.annotations.compactMap { $0 as? AirportAnnotation }
        let existingIds = Set(existing.map { $0.airport.id })
        let newIds = Set(airports.map { $0.id })

        mapView.removeAnnotations(existing.filter { !newIds.contains($0.airport.id) })
        for airport in airports where !existingIds.contains(airport.id) {
            mapView.addAnnotation(AirportAnnotation(airport: airport))
        }
    }

    // MARK: Route

    private func updateRoute(_ mapView: MKMapView, context: Context) {
        let signature = waypoints.map { "\($0.id.uuidString)\($0.latitude),\($0.longitude)" }.joined(separator: "|")
        guard signature != context.coordinator.lastRouteSignature else { return }
        context.coordinator.lastRouteSignature = signature

        // Replace numbered waypoint annotations.
        let oldWaypoints = mapView.annotations.compactMap { $0 as? RouteWaypointAnnotation }
        mapView.removeAnnotations(oldWaypoints)
        for (index, waypoint) in waypoints.enumerated() {
            let annotation = RouteWaypointAnnotation(coordinate: waypoint.coordinate, index: index, name: waypoint.name)
            mapView.addAnnotation(annotation)
        }

        // Replace the route polyline. Draw a black casing under a magenta core, matching the in-flight
        // navigation map so the plan previews exactly how the route reads in flight, and so it stays
        // visible on every tile layer (feedback #6 — gold washed out on some charts).
        mapView.removeOverlays(mapView.overlays.filter { $0 is MKPolyline })
        if waypoints.count >= 2 {
            let coords = waypoints.map { $0.coordinate }
            let casing = RouteCasingPolyline(coordinates: coords, count: coords.count)
            mapView.addOverlay(casing, level: .aboveLabels)
            let polyline = MKPolyline(coordinates: coords, count: coords.count)
            mapView.addOverlay(polyline, level: .aboveLabels)
        }
    }

    private func fitRoute(_ mapView: MKMapView) {
        guard !waypoints.isEmpty else { return }
        let coords = waypoints.map { $0.coordinate }
        let rects = coords.map { MKMapRect(origin: MKMapPoint($0), size: MKMapSize(width: 0, height: 0)) }
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        let padding = UIEdgeInsets(top: 60, left: 60, bottom: 60, right: 60)
        mapView.setVisibleMapRect(union, edgePadding: padding, animated: true)
    }

    // MARK: Coordinator

    class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: RouteBuilderMapView
        var currentLayer: WaypointPickerMapLayer
        var lastRouteSignature = ""
        var lastFitToken = 0

        init(_ parent: RouteBuilderMapView) {
            self.parent = parent
            self.currentLayer = parent.mapLayer
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.region = mapView.region
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            // Casing first — it is also an MKPolyline, so this branch must precede the generic one.
            if let casing = overlay as? RouteCasingPolyline {
                let renderer = MKPolylineRenderer(polyline: casing)
                renderer.strokeColor = UIColor.black.withAlphaComponent(0.5)
                renderer.lineWidth = 7
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1.0) // navigation magenta
                renderer.lineWidth = 4
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let waypoint = annotation as? RouteWaypointAnnotation {
                let id = "RouteWaypoint"
                let view: MKMarkerAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView {
                    reused.annotation = annotation
                    view = reused
                } else {
                    view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                }
                view.markerTintColor = UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1) // navigation magenta
                view.glyphText = "\(waypoint.index + 1)"
                view.titleVisibility = .adaptive
                view.displayPriority = .required
                view.canShowCallout = true
                return view
            }

            if annotation is AirportAnnotation {
                let id = "BuilderAirport"
                let view: MKAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) {
                    reused.annotation = annotation
                    view = reused
                } else {
                    view = MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                }
                view.canShowCallout = true
                let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                let color = UIColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.9)
                if let image = UIImage(systemName: "airplane", withConfiguration: config) {
                    view.image = image.withTintColor(color, renderingMode: .alwaysOriginal)
                }
                let addButton = UIButton(type: .contactAdd)
                view.rightCalloutAccessoryView = addButton
                return view
            }

            return nil
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            if let airport = (view.annotation as? AirportAnnotation)?.airport {
                parent.onAirportTap(airport)
                mapView.deselectAnnotation(view.annotation, animated: true)
            }
        }

        // Tap empty map → add a free waypoint. Taps on an annotation are handled by the callout.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            if let hit = mapView.hitTest(point, with: nil),
               hit is MKAnnotationView || hit.superview is MKAnnotationView {
                return // tapping a marker — let the callout/accessory handle it
            }
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            parent.onMapTap(coordinate)
        }

        // Let the tap coexist with the map's own pan/zoom recognizers.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

// MARK: - Route overlays

/// Black casing drawn underneath the magenta route core (a distinct subclass so the renderer can tell
/// the two `MKPolyline`s apart). Mirrors the in-flight navigation map's route styling.
final class RouteCasingPolyline: MKPolyline {}

// MARK: - Route waypoint annotation

/// A numbered route waypoint marker. `coordinate` is KVO-observable so MapKit can move it in place.
final class RouteWaypointAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let index: Int
    let title: String?

    init(coordinate: CLLocationCoordinate2D, index: Int, name: String) {
        self.coordinate = coordinate
        self.index = index
        self.title = name.isEmpty ? "WPT\(index + 1)" : name
    }
}
