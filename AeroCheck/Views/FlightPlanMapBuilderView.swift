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

    // On-route hazards — airspace profile + terrain (#4 redesign: route-profile cross-section)
    @State private var airspaceBlocks: [AirspaceProfileBlock] = []
    @State private var crossedAirspaces: [Airspace] = []   // conflict subset, for the list + map highlight
    @State private var airspacePolygons: [AirspacePolygon] = []
    @State private var airspaceTask: Task<Void, Never>?
    @State private var terrainData: [(distance: Double, elevation: Double)] = []
    @State private var terrainTask: Task<Void, Never>?
    @State private var minTerrainClearanceFt: Double?
    @State private var selectedConflictId: String?   // tapped conflict — highlighted on map + profile (#4)
    private let elevationService = ElevationService()
    private static let terrainConflictId = "terrain"

    enum RouteEndpoint: Hashable { case from, to }
    @State private var editingWaypoint: FlightPlanWaypoint?
    @State private var showTableEditor = false
    @State private var showProfileFull = false
    @State private var exportItem: FlightPlanExportItem?

    // Hybrid layout (#4 redesign): wide profile strip under the map + a Waypoints/Conflicts toggle.
    enum RightTab { case waypoints, conflicts }
    @State private var rightTab: RightTab = .waypoints
    @State private var profileCollapsed = false

    /// Live plan from the manager (single source of truth).
    private var plan: FlightPlan? {
        flightPlanManager.flightPlans.first { $0.id == planId }
    }

    private var waypoints: [FlightPlanWaypoint] { plan?.waypoints ?? [] }

    /// A custom plan name wins; otherwise a neutral title — the FROM→TO route already shows in the
    /// on-map endpoint bar, so the title no longer duplicates it. (flight-plan revamp #4 — dedup)
    private var builderTitle: String {
        if let p = plan, !p.name.isEmpty { return p.name }
        return L10n.Nav.flightPlanTitle
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let twoColumn = horizontalSizeClass == .regular && geo.size.width > geo.size.height
                Group {
                    if twoColumn {
                        HStack(spacing: 0) {
                            leftSide
                                .frame(width: geo.size.width * 0.62)
                            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                            rightColumn
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        VStack(spacing: 0) {
                            leftSide
                                .frame(height: geo.size.height * 0.5)
                            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                            rightColumn
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
                    Menu {
                        Button { exportGPX() } label: { Label(L10n.Nav.exportGPX, systemImage: "square.and.arrow.up") }
                        Button { showTableEditor = true } label: { Label(L10n.Nav.tableEditor, systemImage: "tablecells") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(waypoints.isEmpty)
                    .accessibilityLabel(L10n.Nav.moreActions)
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
            .sheet(isPresented: $showProfileFull) {
                NavigationStack {
                    RouteProfileView(waypoints: waypoints, terrain: terrainData, blocks: airspaceBlocks,
                                     selectedId: selectedConflictId, terrainId: Self.terrainConflictId)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.cockpitBackground)
                        .navigationTitle(L10n.Nav.routeProfileTitle)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L10n.Button.done) { showProfileFull = false }
                            }
                        }
                }
                .preferredColorScheme(.dark)
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
            scheduleAirspaceUpdate()
            scheduleTerrainUpdate()
        }
        .onChange(of: region.center.latitude) { _, _ in scheduleAirportUpdate() }
        .onChange(of: region.center.longitude) { _, _ in scheduleAirportUpdate() }
        // Recompute on-route hazards (airspace + terrain) whenever the route geometry changes (#4).
        .onChange(of: routeGeometryKey) { _, _ in selectedConflictId = nil; scheduleAirspaceUpdate(); scheduleTerrainUpdate() }
        .onChange(of: openAIPDataService.isDataAvailable) { _, _ in scheduleAirspaceUpdate() }
    }

    /// Full-geometry signature (every waypoint's coordinate AND planned altitude) so the airspace scan
    /// re-runs when an intermediate point moves OR an altitude is edited — unlike `routeSignature`,
    /// which only watches the endpoints + count.
    private var routeGeometryKey: String {
        waypoints.map { wp in
            let alt = wp.altitude.map { String(Int($0)) } ?? "-"
            return String(format: "%.4f,%.4f", wp.latitude, wp.longitude) + ",\(alt)"
        }.joined(separator: "|")
    }

    // MARK: - Map area

    private var mapArea: some View {
        RouteBuilderMapView(
            waypoints: waypoints,
            mapLayer: selectedLayer,
            airports: visibleAirports,
            airspacePolygons: airspacePolygons,
            selectedAirspaceId: selectedConflictId,
            fitRouteToken: fitRouteToken,
            region: $region,
            onAirportTap: { airport in addAirport(airport) },
            onMoveWaypoint: { index, coord in moveWaypoint(at: index, to: coord) },
            onInsertWaypoint: { afterIndex, coord in insertRouteWaypoint(afterIndex: afterIndex, at: coord) },
            onAddWaypoint: { coord in smartAddWaypoint(at: coord) }
        )
        .ignoresSafeArea(edges: .bottom)
        // From/To bar full-width at the top.
        .overlay(alignment: .top) {
            fromToBar
                .padding(12)
        }
        // Layer switcher bottom-left, center/fit bottom-right. (feedback)
        .overlay(alignment: .bottomLeading) {
            layerPicker
                .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            fitRouteButton
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
            // Near-opaque panel (app convention) instead of translucent glass — the From/To bar must
            // stay legible over busy chart layers (ICAO/Segelflug). (feedback)
            .background(Color.panelBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))

            if focusedEndpoint != nil && !searchResults.isEmpty {
                airportResults { airport in
                    if let slot = focusedEndpoint { setEndpoint(slot, airport) }
                }
                .background(Color.panelBackground.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
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
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.panelBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var fitRouteButton: some View {
        Button { fitRouteToken += 1 } label: {
            Image(systemName: "scope")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primaryText)
                .frame(width: 44, height: 44)
                .background(Color.panelBackground.opacity(0.92), in: Circle())
        }
        .disabled(waypoints.isEmpty)
        .opacity(waypoints.isEmpty ? 0.4 : 1)
        .accessibilityLabel("Fit route")
    }

    // MARK: - Side / bottom panel

    // MARK: - Hybrid layout: map + bottom profile strip (left) · summary + toggle (right) (#4 redesign)

    /// Map filling the area with the wide route-profile strip pinned beneath it (the EFB convention).
    private var leftSide: some View {
        VStack(spacing: 0) {
            mapArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if waypoints.count >= 2 {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                routeProfileStrip
            }
        }
    }

    /// Right column: compact route summary + a Waypoints/Conflicts toggle, showing one focused view at
    /// a time instead of stacking everything.
    private var rightColumn: some View {
        VStack(spacing: 0) {
            routeSummary
            if waypoints.count >= 2 { rightTabBar }
            Group {
                if rightTab == .conflicts && waypoints.count >= 2 {
                    conflictsTabContent
                } else if waypoints.isEmpty {
                    emptyRouteHint
                } else {
                    if waypoints.count >= 2 { waypointListHeader }
                    waypointList
                }
            }
        }
        .background(Color.cockpitBackground)
        .onChange(of: waypoints.count) { _, count in
            if count < 2 { listEditMode = .inactive; rightTab = .waypoints }
        }
    }

    /// Collapsible wide route-profile strip under the map; expand to a full-screen profile (replaces the
    /// old Terrain sheet).
    private var routeProfileStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L10n.Nav.routeProfileTitle.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    .foregroundColor(.secondaryText)
                Spacer()
                Button { showProfileFull = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondaryText)
                }
                .accessibilityLabel(L10n.Nav.expandProfile)
                Button { withAnimation(.easeInOut(duration: 0.18)) { profileCollapsed.toggle() } } label: {
                    Image(systemName: profileCollapsed ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondaryText)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            if !profileCollapsed {
                RouteProfileView(waypoints: waypoints, terrain: terrainData, blocks: airspaceBlocks,
                                 selectedId: selectedConflictId, terrainId: Self.terrainConflictId)
                    .frame(height: 136)
                    .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .background(Color.cockpitBackground)
    }

    private var rightTabBar: some View {
        HStack(spacing: 8) {
            tabButton(.waypoints, L10n.Nav.waypointsTab, count: nil, tint: .aviationGold)
            tabButton(.conflicts, L10n.Nav.conflictsTab, count: hazardCount, tint: hazardTint)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }

    private var hazardCount: Int { crossedAirspaces.count + (terrainWarning ? 1 : 0) }
    private var hazardTint: Color {
        if hazardCount == 0 { return .aviationGreen }
        if terrainWarning || crossedAirspaces.contains(where: { $0.isRestrictive }) { return .aviationRed }
        return .aviationAmber
    }

    private func tabButton(_ tab: RightTab, _ title: String, count: Int?, tint: Color) -> some View {
        let selected = rightTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { rightTab = tab }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let count = count {
                    Text(count == 0 ? "✓" : "\(count)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(selected ? .black : tint)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(selected ? Color.black.opacity(0.18) : tint.opacity(0.18)))
                }
            }
            .foregroundColor(selected ? .black : .primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? tint : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    /// Conflicts tab body — the hazard list, or a reassuring "clear" state.
    @ViewBuilder private var conflictsTabContent: some View {
        if hasHazards {
            conflictsList
            Spacer(minLength: 0)
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "checkmark.shield.fill").font(.system(size: 36)).foregroundColor(.aviationGreen)
                Text(L10n.Nav.noConflicts).font(.system(size: 13)).foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        }
    }

    // MARK: - On-route hazards: route check + profile + conflict list (#4 redesign)

    private var terrainWarning: Bool { (minTerrainClearanceFt.map { $0 < Self.terrainWarnFt }) ?? false }
    private var hasHazards: Bool { !crossedAirspaces.isEmpty || terrainWarning }
    private static let terrainWarnFt: Double = 150 * 3.28084 // 150 m ≈ 492 ft

    /// One-line route status above the profile: green when clear, amber for plain airspace, red for a
    /// restricted zone or a terrain-clearance bust.
    /// The genuine conflicts in the Conflicts tab: a terrain row (if too close) + each conflicting
    /// airspace.
    private var conflictsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if terrainWarning {
                    terrainWarnRow
                    if !crossedAirspaces.isEmpty { Divider().background(Color.white.opacity(0.06)) }
                }
                ForEach(crossedAirspaces) { airspace in
                    airspaceRow(airspace)
                    if airspace.id != crossedAirspaces.last?.id {
                        Divider().background(Color.white.opacity(0.06))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Toggle selection of a conflict — highlights it on the map and in the route profile. (#4 feedback)
    private func selectConflict(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            selectedConflictId = (selectedConflictId == id) ? nil : id
        }
    }

    private var terrainWarnRow: some View {
        let selected = selectedConflictId == Self.terrainConflictId
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color.aviationRed).frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Nav.terrainProximity)
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.primaryText)
                Text(L10n.Nav.terrainProximityDetail)
                    .font(.system(size: 10)).foregroundColor(.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let c = minTerrainClearanceFt {
                Text("\(Int(c.rounded())) ft")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.aviationRed)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(selected ? Color.white.opacity(0.07) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selectConflict(Self.terrainConflictId) }
    }

    private func airspaceRow(_ a: Airspace) -> some View {
        let selected = selectedConflictId == a.id
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(red: a.mapColor.red, green: a.mapColor.green, blue: a.mapColor.blue))
                .frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.shortName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primaryText).lineLimit(1)
                    if a.isRestrictive {
                        Text(a.airspaceType.displayName.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.aviationRed)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.aviationRed.opacity(0.18)))
                    }
                }
                Text(a.typeDisplayString)
                    .font(.system(size: 10)).foregroundColor(.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(a.altitudeRangeString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.dimText).lineLimit(1)
                if let freq = a.primaryFrequency {
                    Text(freq.value)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.aviationGold)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(selected ? Color.white.opacity(0.07) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selectConflict(a.id) }
    }

    /// Debounced recompute of the on-route airspace blocks (profile) + conflict subset (list + map). (#4)
    private func scheduleAirspaceUpdate() {
        airspaceTask?.cancel()
        let coords = waypoints.map { $0.coordinate }
        let alts = waypoints.map { $0.altitude }
        guard coords.count >= 2 else { airspaceBlocks = []; crossedAirspaces = []; airspacePolygons = []; return }
        airspaceTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await openAIPDataService.ensureLoaded()
            guard !Task.isCancelled else { return }
            let blocks = openAIPDataService.airspaceProfileBlocks(coords, altitudesFt: alts)
            let conflicts = blocks.filter { $0.isConflict }.map { $0.airspace }
            let polys: [AirspacePolygon] = conflicts.compactMap { airspace in
                var mc = airspace.polygonCoordinates
                guard mc.count >= 3 else { return nil }
                return AirspacePolygon(airspace: airspace, coordinates: &mc, count: mc.count)
            }
            guard !Task.isCancelled else { return }
            airspaceBlocks = blocks
            crossedAirspaces = conflicts
            airspacePolygons = polys
        }
    }

    /// Debounced terrain fetch (swisstopo via `ElevationService`; empty outside Switzerland) + the
    /// minimum clearance of the extrapolated altitude profile over terrain, for the 150 m warning. (#4)
    private func scheduleTerrainUpdate() {
        terrainTask?.cancel()
        let wpts = waypoints
        let coords = wpts.map { $0.coordinate }
        guard coords.count >= 2 else { terrainData = []; minTerrainClearanceFt = nil; return }
        terrainTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let terrain = await elevationService.fetchRouteElevationsOptimized(waypoints: coords, totalSamples: 60)
            guard !Task.isCancelled else { return }
            terrainData = terrain
            minTerrainClearanceFt = Self.minClearanceFt(terrain: terrain, waypoints: wpts)
        }
    }

    /// Lowest vertical gap (ft) between the extrapolated altitude profile and the terrain along the
    /// route, or nil when terrain or planned altitudes are unavailable.
    private static func minClearanceFt(terrain: [(distance: Double, elevation: Double)], waypoints: [FlightPlanWaypoint]) -> Double? {
        guard terrain.count >= 2, let terrMax = terrain.last?.distance, terrMax > 0 else { return nil }
        let prof = RouteAltitudeProfile(waypoints)
        guard prof.hasData, prof.totalNM > 0 else { return nil }
        var minC = Double.infinity
        for p in terrain {
            let nm = (p.distance / terrMax) * prof.totalNM
            guard let alt = prof.altitude(atNM: nm) else { continue }
            minC = min(minC, alt - p.elevation * 3.28084)
        }
        return minC.isFinite ? minC : nil
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
            Image(systemName: "hand.point.up.left")
                .font(.system(size: 40))
                .foregroundColor(.dimText)
            Text("Search an ICAO above, or press and\nhold the map to drop a waypoint")
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

    /// Snap radius for releasing a dragged waypoint onto a nearby airfield. (flight-plan revamp #3)
    private let snapRadiusNm: Double = 2.5

    /// Commit a live waypoint move: snap to a nearby airfield if released within `snapRadiusNm`
    /// (carrying its ident + frequency + elevation), otherwise just reposition the point. (#3)
    private func moveWaypoint(at index: Int, to coordinate: CLLocationCoordinate2D) {
        guard index < waypoints.count else { return }
        var wp = waypoints[index]
        if let airport = airportDataService.nearestAirport(to: coordinate, maxDistanceNm: snapRadiusNm, types: AirportType.fixedWing) {
            applyAirport(airport, to: &wp)
        } else {
            wp.coordinate = coordinate
        }
        flightPlanManager.updateWaypoint(wp, in: planId)
    }

    /// Commit a deliberate press-and-hold add: drop the waypoint at the cheapest-insertion position
    /// (the leg it least lengthens, or an endpoint), snapping to a nearby airfield within
    /// `snapRadiusNm`. (tap-add feedback + smart insertion)
    private func smartAddWaypoint(at coordinate: CLLocationCoordinate2D) {
        let index = FlightPlanManager.bestInsertionIndex(for: coordinate, in: waypoints)
        if let airport = airportDataService.nearestAirport(to: coordinate, maxDistanceNm: snapRadiusNm, types: AirportType.fixedWing) {
            flightPlanManager.insertWaypoint(to: planId, at: index, coordinate: airport.coordinate, name: airport.ident)
            if let p = plan, index < p.waypoints.count {
                var wp = p.waypoints[index]
                applyAirport(airport, to: &wp)
                flightPlanManager.updateWaypoint(wp, in: planId)
            }
        } else {
            flightPlanManager.insertWaypoint(to: planId, at: index, coordinate: coordinate)
        }
    }

    /// Commit a live mid-route insert after `afterIndex`, snapping to a nearby airfield if close. (#3)
    private func insertRouteWaypoint(afterIndex: Int, at coordinate: CLLocationCoordinate2D) {
        let insertAt = afterIndex + 1
        if let airport = airportDataService.nearestAirport(to: coordinate, maxDistanceNm: snapRadiusNm, types: AirportType.fixedWing) {
            flightPlanManager.insertWaypoint(to: planId, at: insertAt, coordinate: airport.coordinate, name: airport.ident)
            if let p = plan, insertAt < p.waypoints.count {
                var wp = p.waypoints[insertAt]
                applyAirport(airport, to: &wp)
                flightPlanManager.updateWaypoint(wp, in: planId)
            }
        } else {
            flightPlanManager.insertWaypoint(to: planId, at: insertAt, coordinate: coordinate)
        }
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
    var airspacePolygons: [AirspacePolygon] = []   // highlight the airspaces the route crosses (#4)
    var selectedAirspaceId: String? = nil          // tapped conflict — emphasised on the map (#4)
    var fitRouteToken: Int
    @Binding var region: MKCoordinateRegion
    var onAirportTap: (Airport) -> Void
    /// Live drag committed a waypoint move (index, new coordinate). nil ⇒ read-only map (no drag). (#3)
    var onMoveWaypoint: ((Int, CLLocationCoordinate2D) -> Void)? = nil
    /// Live drag committed a mid-route insert (afterIndex, coordinate). nil ⇒ read-only map. (#3)
    var onInsertWaypoint: ((Int, CLLocationCoordinate2D) -> Void)? = nil
    /// Deliberate press-and-hold on empty map appended a new waypoint (coordinate). (tap-add feedback)
    var onAddWaypoint: ((CLLocationCoordinate2D) -> Void)? = nil

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.setRegion(region, animated: false)
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.showsScale = true
        configureLayer(mapView)
        mapView.cameraZoomRange = cameraZoomRange(for: mapLayer)

        // One press-and-hold gesture drives ALL route editing: grab a waypoint to move it, grab the
        // route line to insert mid-route (both at the short grab threshold for a responsive feel), or
        // hold longer on empty map to drop a new waypoint. A plain tap no longer adds anything, so you
        // can pan/zoom/inspect without accidentally creating waypoints. Builder only — read-only map
        // previews get no editing. (flight-plan revamp #3 + tap-add feedback)
        if onMoveWaypoint != nil || onInsertWaypoint != nil || onAddWaypoint != nil {
            let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
            longPress.minimumPressDuration = 0.2
            longPress.delegate = context.coordinator
            mapView.addGestureRecognizer(longPress)
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Keep the coordinator's snapshot current so drag hit-testing reads live waypoints/closures.
        context.coordinator.parent = self
        // Never fight an in-progress live drag — the coordinator owns the geometry until release.
        if context.coordinator.isDragging { return }
        if context.coordinator.currentLayer != mapLayer {
            context.coordinator.currentLayer = mapLayer
            configureLayer(mapView)
            mapView.cameraZoomRange = cameraZoomRange(for: mapLayer)
        }

        updateAirportAnnotations(mapView, context: context)
        updateAirspaceOverlays(mapView, context: context)
        applyAirspaceSelection(mapView)
        updateRoute(mapView, context: context)

        if context.coordinator.lastFitToken != fitRouteToken {
            context.coordinator.lastFitToken = fitRouteToken
            fitRoute(mapView)
        }
    }

    /// Emphasise the selected conflict's polygon (brighter + thicker) by restyling its live renderer,
    /// so tapping a row in the list makes it pop on the map. (#4 feedback)
    private func applyAirspaceSelection(_ mapView: MKMapView) {
        for poly in mapView.overlays.compactMap({ $0 as? AirspacePolygon }) {
            guard let r = mapView.renderer(for: poly) as? MKPolygonRenderer else { continue }
            let c = poly.overlayColor
            let sel = poly.airspaceId == selectedAirspaceId
            r.fillColor = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: sel ? 0.36 : 0.18)
            r.strokeColor = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: sel ? 1.0 : 0.85)
            r.lineWidth = sel ? 3 : 1.5
            r.lineDashPattern = poly.isDashed ? [8, 4] : nil
            r.setNeedsDisplay()
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

    /// Add/remove highlighted airspace polygons incrementally (by id), so a small change to the crossed
    /// set doesn't rebuild the rest. Drawn under the route (translucent fill). (#4)
    private func updateAirspaceOverlays(_ mapView: MKMapView, context: Context) {
        let existing = mapView.overlays.compactMap { $0 as? AirspacePolygon }
        let existingIds = Set(existing.map { $0.airspaceId })
        let newIds = Set(airspacePolygons.map { $0.airspaceId })
        guard existingIds != newIds else { return }
        let toRemove = existing.filter { !newIds.contains($0.airspaceId) }
        if !toRemove.isEmpty { mapView.removeOverlays(toRemove) }
        for polygon in airspacePolygons where !existingIds.contains(polygon.airspaceId) {
            mapView.addOverlay(polygon, level: .aboveLabels)
        }
    }

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

        // MARK: Live drag (flight-plan revamp #3)
        enum DragMode { case move(Int); case insert(Int); case append } // insert(afterIndex)
        var dragMode: DragMode?
        var dragCoords: [CLLocationCoordinate2D] = []       // working geometry during a drag
        var dragIndex = 0                                   // index into dragCoords being moved
        var dragAnnotation: RouteWaypointAnnotation?        // the marker following the finger
        var dragCreatedTempAnnotation = false               // true for insert/append (remove on end)
        var isDragging: Bool { dragMode != nil }

        // Deferred add: a press on empty map only becomes a new waypoint after a longer, deliberate
        // hold (so a normal press/pan never adds one). (tap-add feedback)
        var pendingAddWork: DispatchWorkItem?
        var pendingAddAnchor: CGPoint?

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
            // Crossed-airspace highlight (translucent fill + colored stroke). (#4)
            if let airspace = overlay as? AirspacePolygon {
                let renderer = MKPolygonRenderer(polygon: airspace)
                let c = airspace.overlayColor
                renderer.fillColor = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 0.18)
                renderer.strokeColor = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 0.85)
                renderer.lineWidth = 1.5
                if airspace.isDashed { renderer.lineDashPattern = [8, 4] }
                return renderer
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
        // MARK: Live drag handling (flight-plan revamp #3 + deliberate add)

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            switch gesture.state {
            case .began:
                beginDrag(mapView, at: point)                 // move / insert on a waypoint or the line
                if dragMode == nil { schedulePendingAdd(mapView, at: point) } // empty → deferred add
            case .changed:
                if dragMode == nil {
                    // Still before the deliberate-add threshold; movement here means the user is panning.
                    if let anchor = pendingAddAnchor, hypot(point.x - anchor.x, point.y - anchor.y) > 16 {
                        cancelPendingAdd()
                    }
                    return
                }
                let coord = mapView.convert(point, toCoordinateFrom: mapView)
                if case .append = dragMode {
                    // A dropped point previews where it will actually land (cheapest insertion),
                    // recomputed as the finger moves — not stuck appended to the end. (smart-insert feedback)
                    rebuildAppendPreview(mapView, coord: coord)
                    return
                }
                guard dragIndex < dragCoords.count else { return }
                dragCoords[dragIndex] = coord
                dragAnnotation?.coordinate = coord
                redrawDragRoute(mapView)
            case .ended:
                if dragMode == nil { cancelPendingAdd(); return } // released before the add threshold
                endDrag(mapView, at: point)
            case .cancelled, .failed:
                cancelPendingAdd()
                cancelDrag(mapView)
            default:
                break
            }
        }

        /// Arm a deferred add: after a longer hold on empty map (without panning), drop a new waypoint
        /// under the finger and let the user drag it before release. (tap-add feedback)
        private func schedulePendingAdd(_ mapView: MKMapView, at point: CGPoint) {
            guard parent.onAddWaypoint != nil else { return }
            cancelPendingAdd()
            pendingAddAnchor = point
            let work = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView, self.pendingAddAnchor != nil, self.dragMode == nil else { return }
                self.startAppendDrag(mapView, at: point)
            }
            pendingAddWork = work
            // ~0.2 s recognizer threshold + 0.45 s ≈ a deliberate two-thirds-second hold before it adds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }

        private func cancelPendingAdd() {
            pendingAddWork?.cancel()
            pendingAddWork = nil
            pendingAddAnchor = nil
        }

        private func startAppendDrag(_ mapView: MKMapView, at point: CGPoint) {
            pendingAddWork = nil
            pendingAddAnchor = nil
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            dragMode = .append
            let temp = RouteWaypointAnnotation(coordinate: coord, index: 0, name: "")
            mapView.addAnnotation(temp)
            dragAnnotation = temp
            dragCreatedTempAnnotation = true
            grabbed(mapView, deselect: nil)
            rebuildAppendPreview(mapView, coord: coord) // place it at the cheapest-insertion position
        }

        /// Rebuild the live preview for a dropped point: splice it into the route at the cheapest
        /// insertion index for its current position, so the line shows how it will actually link in.
        private func rebuildAppendPreview(_ mapView: MKMapView, coord: CLLocationCoordinate2D) {
            let idx = FlightPlanManager.bestInsertionIndex(for: coord, in: parent.waypoints)
            var coords = parent.waypoints.map { $0.coordinate }
            let at = min(idx, coords.count)
            coords.insert(coord, at: at)
            dragCoords = coords
            dragIndex = at
            dragAnnotation?.coordinate = coord
            redrawDragRoute(mapView)
        }

        /// Grab a waypoint (move) if the press is on one, else the nearest route segment (insert).
        private func beginDrag(_ mapView: MKMapView, at point: CGPoint) {
            let wpts = parent.waypoints
            guard !wpts.isEmpty else { return }
            if parent.onMoveWaypoint != nil,
               let idx = waypointIndex(near: point, mapView: mapView, maxPointDistance: 34),
               let anno = routeAnnotation(at: idx, in: mapView) {
                dragMode = .move(idx)
                dragCoords = wpts.map { $0.coordinate }
                dragIndex = idx
                dragAnnotation = anno
                dragCreatedTempAnnotation = false
                grabbed(mapView, deselect: anno)
                return
            }
            if parent.onInsertWaypoint != nil, wpts.count >= 2,
               let seg = closestSegment(to: point, mapView: mapView, maxPointDistance: 22) {
                let coord = mapView.convert(point, toCoordinateFrom: mapView)
                let insertAt = seg + 1
                dragMode = .insert(seg)
                dragCoords = wpts.map { $0.coordinate }
                dragCoords.insert(coord, at: insertAt)
                dragIndex = insertAt
                let temp = RouteWaypointAnnotation(coordinate: coord, index: insertAt, name: "")
                mapView.addAnnotation(temp)
                dragAnnotation = temp
                dragCreatedTempAnnotation = true
                grabbed(mapView, deselect: nil)
                redrawDragRoute(mapView)
            }
        }

        private func grabbed(_ mapView: MKMapView, deselect: MKAnnotation?) {
            mapView.isScrollEnabled = false
            if let deselect = deselect { mapView.deselectAnnotation(deselect, animated: false) }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        private func endDrag(_ mapView: MKMapView, at point: CGPoint) {
            guard let mode = dragMode else { return }
            let finalCoord = mapView.convert(point, toCoordinateFrom: mapView)
            if dragCreatedTempAnnotation, let temp = dragAnnotation { mapView.removeAnnotation(temp) }
            finishDrag(mapView)
            switch mode {
            case .move(let index): parent.onMoveWaypoint?(index, finalCoord)
            case .insert(let afterIndex): parent.onInsertWaypoint?(afterIndex, finalCoord)
            case .append: parent.onAddWaypoint?(finalCoord)
            }
        }

        private func cancelDrag(_ mapView: MKMapView) {
            finishDrag(mapView)
            // Rebuilds markers + line from the model, dropping any temp insert/append marker and
            // resetting a moved marker to its committed position.
            redrawCommittedRoute(mapView)
        }

        private func finishDrag(_ mapView: MKMapView) {
            dragMode = nil
            dragAnnotation = nil
            dragCoords = []
            dragCreatedTempAnnotation = false
            mapView.isScrollEnabled = true
        }

        /// Redraw the magenta route from the live working geometry (move/insert preview).
        private func redrawDragRoute(_ mapView: MKMapView) {
            mapView.removeOverlays(mapView.overlays.filter { $0 is MKPolyline })
            guard dragCoords.count >= 2 else { return }
            let casing = RouteCasingPolyline(coordinates: dragCoords, count: dragCoords.count)
            mapView.addOverlay(casing, level: .aboveLabels)
            let line = MKPolyline(coordinates: dragCoords, count: dragCoords.count)
            mapView.addOverlay(line, level: .aboveLabels)
        }

        /// Rebuild markers + route from the committed model (used after a cancelled drag).
        private func redrawCommittedRoute(_ mapView: MKMapView) {
            let old = mapView.annotations.compactMap { $0 as? RouteWaypointAnnotation }
            mapView.removeAnnotations(old)
            mapView.removeOverlays(mapView.overlays.filter { $0 is MKPolyline })
            let wpts = parent.waypoints
            for (i, w) in wpts.enumerated() {
                mapView.addAnnotation(RouteWaypointAnnotation(coordinate: w.coordinate, index: i, name: w.name))
            }
            if wpts.count >= 2 {
                let coords = wpts.map { $0.coordinate }
                mapView.addOverlay(RouteCasingPolyline(coordinates: coords, count: coords.count), level: .aboveLabels)
                mapView.addOverlay(MKPolyline(coordinates: coords, count: coords.count), level: .aboveLabels)
            }
            lastRouteSignature = wpts.map { "\($0.id.uuidString)\($0.latitude),\($0.longitude)" }.joined(separator: "|")
        }

        // MARK: Drag hit-testing

        /// Index of the waypoint whose marker is closest to `point` (within `maxPointDistance` px), or nil.
        private func waypointIndex(near point: CGPoint, mapView: MKMapView, maxPointDistance: CGFloat) -> Int? {
            var best: (index: Int, dist: CGFloat)?
            for (i, w) in parent.waypoints.enumerated() {
                let p = mapView.convert(w.coordinate, toPointTo: mapView)
                // The marker balloon sits above its coordinate tip — bias the hit centre up.
                let centre = CGPoint(x: p.x, y: p.y - 14)
                let d = hypot(point.x - centre.x, point.y - centre.y)
                if best == nil || d < best!.dist { best = (i, d) }
            }
            if let best = best, best.dist <= maxPointDistance { return best.index }
            return nil
        }

        private func routeAnnotation(at index: Int, in mapView: MKMapView) -> RouteWaypointAnnotation? {
            mapView.annotations.compactMap { $0 as? RouteWaypointAnnotation }.first { $0.index == index }
        }

        /// Start index of the route segment closest to `point` (within `maxPointDistance` px), or nil.
        private func closestSegment(to point: CGPoint, mapView: MKMapView, maxPointDistance: CGFloat) -> Int? {
            let wpts = parent.waypoints
            guard wpts.count >= 2 else { return nil }
            var best: (index: Int, dist: CGFloat)?
            for i in 0..<(wpts.count - 1) {
                let a = mapView.convert(wpts[i].coordinate, toPointTo: mapView)
                let b = mapView.convert(wpts[i + 1].coordinate, toPointTo: mapView)
                let d = distance(from: point, toSegment: a, b)
                if best == nil || d < best!.dist { best = (i, d) }
            }
            if let best = best, best.dist <= maxPointDistance { return best.index }
            return nil
        }

        private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let ap = CGPoint(x: p.x - a.x, y: p.y - a.y)
            let len2 = ab.x * ab.x + ab.y * ab.y
            let t = len2 == 0 ? 0 : max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / len2))
            let proj = CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
            return hypot(p.x - proj.x, p.y - proj.y)
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

// MARK: - Route altitude profile + cross-section (flight-plan revamp #4 redesign)

/// Piecewise-linear planned-altitude profile along the route, extrapolated from the waypoints that
/// carry a planned altitude (clamped at the ends). Shared by the builder (terrain clearance) and the
/// route-profile view (the altitude line). Distances use the same haversine NM as the airspace scan.
struct RouteAltitudeProfile {
    let cumNM: [Double]      // cumulative along-track distance per waypoint
    let totalNM: Double
    private let known: [(d: Double, alt: Double)]
    var hasData: Bool { !known.isEmpty }

    init(_ waypoints: [FlightPlanWaypoint]) {
        var c: [Double] = []
        for (i, w) in waypoints.enumerated() {
            if i == 0 { c.append(0); continue }
            let a = waypoints[i - 1].coordinate, b = w.coordinate
            let leg = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852.0
            c.append(c[i - 1] + leg)
        }
        cumNM = c
        totalNM = c.last ?? 0
        var k: [(Double, Double)] = []
        for (i, w) in waypoints.enumerated() where i < c.count {
            if let alt = w.altitude { k.append((c[i], alt)) }
        }
        known = k.sorted { $0.0 < $1.0 }
    }

    func altitude(atNM d: Double) -> Double? {
        guard let first = known.first, let last = known.last else { return nil }
        if d <= first.d { return first.alt }
        if d >= last.d { return last.alt }
        for k in 1..<known.count where d <= known[k].d {
            let p0 = known[k - 1], p1 = known[k]
            let t = (d - p0.d) / max(0.0001, p1.d - p0.d)
            return p0.alt + (p1.alt - p0.alt) * t
        }
        return last.alt
    }
}

/// Vertical route cross-section: terrain silhouette + the extrapolated altitude line + the airspaces
/// the route enters (conflicts solid, "context" zones the route clears vertically drawn faded) + red
/// ticks where terrain clearance busts 150 m. The VFR-standard way to read vertical separation at a
/// glance. (flight-plan revamp #4 redesign)
private struct RouteProfileView: View {
    let waypoints: [FlightPlanWaypoint]
    let terrain: [(distance: Double, elevation: Double)]
    let blocks: [AirspaceProfileBlock]
    var selectedId: String? = nil          // tapped conflict — emphasised here too (#4)
    var terrainId: String = "terrain"

    private let leftPad: CGFloat = 38
    private let bottomPad: CGFloat = 16
    private let topPad: CGFloat = 6
    private let rightPad: CGFloat = 8
    private static let warnFt: Double = 150 * 3.28084
    private static let magenta = Color(red: 1.0, green: 0.08, blue: 0.8)

    var body: some View {
        Canvas { ctx, size in
            let prof = RouteAltitudeProfile(waypoints)
            let totalNM = max(prof.totalNM, 0.0001)

            // Terrain (m → ft), mapped onto the route's total NM (it has its own distance scale).
            let terrMax = terrain.last?.distance ?? 0
            let terrainFt: [(nm: Double, ft: Double)] = terrMax > 0
                ? terrain.map { (($0.distance / terrMax) * totalNM, $0.elevation * 3.28084) }
                : []
            let lineFt: [(nm: Double, ft: Double)] = prof.hasData
                ? prof.cumNM.map { ($0, prof.altitude(atNM: $0) ?? 0) }
                : []
            let yMax = computeYMax(terrainFt: terrainFt, lineFt: lineFt)

            let plot = CGRect(x: leftPad, y: topPad,
                              width: size.width - leftPad - rightPad,
                              height: size.height - topPad - bottomPad)
            func px(_ nm: Double) -> CGFloat { plot.minX + CGFloat(min(max(nm / totalNM, 0), 1)) * plot.width }
            func py(_ ft: Double) -> CGFloat { plot.minY + plot.height - CGFloat(min(max(ft / yMax, 0), 1)) * plot.height }

            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8),
                     with: .color(Color(red: 0.10, green: 0.10, blue: 0.13)))

            // gridlines + altitude labels
            for frac in [0.0, 0.34, 0.67, 1.0] {
                let gy = plot.minY + plot.height * CGFloat(1 - frac)
                var g = Path(); g.move(to: CGPoint(x: plot.minX, y: gy)); g.addLine(to: CGPoint(x: plot.maxX, y: gy))
                ctx.stroke(g, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
                ctx.draw(Text(altLabel(yMax * frac)).font(.system(size: 8, design: .monospaced)).foregroundColor(.dimText),
                         at: CGPoint(x: leftPad - 4, y: gy), anchor: .trailing)
            }

            // airspace blocks (conflicts solid, context faded/dashed; the selected one emphasised)
            for b in blocks where b.floorFt <= yMax {
                let color = Color(red: b.airspace.mapColor.red, green: b.airspace.mapColor.green, blue: b.airspace.mapColor.blue)
                let topY = py(min(b.ceilingFt, yMax))
                let rect = CGRect(x: px(b.startNM), y: topY,
                                  width: max(2, px(b.endNM) - px(b.startNM)), height: py(b.floorFt) - topY)
                let path = Path(rect)
                let sel = b.id == selectedId
                if b.isConflict {
                    ctx.fill(path, with: .color(color.opacity(sel ? 0.42 : 0.22)))
                    ctx.stroke(path, with: .color(color.opacity(sel ? 1.0 : 0.85)), lineWidth: sel ? 2.5 : 1)
                } else {
                    ctx.fill(path, with: .color(color.opacity(sel ? 0.20 : 0.07)))
                    ctx.stroke(path, with: .color(color.opacity(sel ? 0.9 : 0.35)),
                               style: StrokeStyle(lineWidth: sel ? 2 : 0.75, dash: sel ? [] : [4, 3]))
                }
            }

            // terrain silhouette
            if terrainFt.count >= 2 {
                var t = Path()
                t.move(to: CGPoint(x: px(terrainFt[0].nm), y: plot.maxY))
                for p in terrainFt { t.addLine(to: CGPoint(x: px(p.nm), y: py(p.ft))) }
                t.addLine(to: CGPoint(x: px(terrainFt.last!.nm), y: plot.maxY)); t.closeSubpath()
                ctx.fill(t, with: .color(Color(red: 0.42, green: 0.35, blue: 0.24).opacity(0.85)))
                var top = Path()
                top.move(to: CGPoint(x: px(terrainFt[0].nm), y: py(terrainFt[0].ft)))
                for p in terrainFt.dropFirst() { top.addLine(to: CGPoint(x: px(p.nm), y: py(p.ft))) }
                ctx.stroke(top, with: .color(Color(red: 0.54, green: 0.45, blue: 0.31)), lineWidth: 1)
            }

            // extrapolated altitude line + waypoint dots
            if lineFt.count >= 2 {
                var l = Path()
                l.move(to: CGPoint(x: px(lineFt[0].nm), y: py(lineFt[0].ft)))
                for p in lineFt.dropFirst() { l.addLine(to: CGPoint(x: px(p.nm), y: py(p.ft))) }
                ctx.stroke(l, with: .color(Self.magenta), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                for p in lineFt {
                    ctx.fill(Path(ellipseIn: CGRect(x: px(p.nm) - 3, y: py(p.ft) - 3, width: 6, height: 6)), with: .color(Self.magenta))
                }
            }

            // terrain-clearance warning ticks (< 150 m); emphasised when the terrain row is selected
            if !terrainFt.isEmpty, prof.hasData {
                let terrSel = selectedId == terrainId
                for p in terrainFt {
                    guard let alt = prof.altitude(atNM: p.nm), alt - p.ft < Self.warnFt else { continue }
                    var m = Path(); m.move(to: CGPoint(x: px(p.nm), y: py(alt))); m.addLine(to: CGPoint(x: px(p.nm), y: py(p.ft)))
                    ctx.stroke(m, with: .color(Color.aviationRed.opacity(terrSel ? 1.0 : 0.85)), lineWidth: terrSel ? 3.5 : 2)
                }
            }

            // x-axis waypoint labels
            for (i, nm) in prof.cumNM.enumerated() where i < waypoints.count {
                let name = waypoints[i].name.isEmpty ? "WPT\(i + 1)" : waypoints[i].name
                let color: Color = i == 0 ? .aviationGreen : (i == prof.cumNM.count - 1 ? .aviationGold : .secondaryText)
                ctx.draw(Text(name).font(.system(size: 8, design: .monospaced)).foregroundColor(color),
                         at: CGPoint(x: px(nm), y: size.height - 5), anchor: .center)
            }
        }
    }

    private func computeYMax(terrainFt: [(nm: Double, ft: Double)], lineFt: [(nm: Double, ft: Double)]) -> Double {
        var top = terrainFt.map { $0.ft }.max() ?? 0
        let routeTop = lineFt.map { $0.ft }.max() ?? 0
        top = max(top, routeTop)
        for b in blocks where b.isConflict { top = max(top, b.ceilingFt) }
        top = max(top, routeTop + 4000) // headroom to show nearby context-zone floors above the route
        return max(2000, top * 1.1)
    }

    private func altLabel(_ ft: Double) -> String {
        if ft <= 0 { return "GND" }
        if ft >= 10000 { return "FL\(Int((ft / 100).rounded()))" }
        return "\(Int((ft / 100).rounded()) * 100)"
    }
}
