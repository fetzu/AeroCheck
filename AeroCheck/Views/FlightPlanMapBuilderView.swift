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

    @State private var searchText = ""
    @State private var searchResults: [Airport] = []
    @State private var editingWaypoint: FlightPlanWaypoint?
    @State private var showTableEditor = false
    @State private var showTerrain = false
    @State private var exportItem: FlightPlanExportItem?

    /// Live plan from the manager (single source of truth).
    private var plan: FlightPlan? {
        flightPlanManager.flightPlans.first { $0.id == planId }
    }

    private var waypoints: [FlightPlanWaypoint] { plan?.waypoints ?? [] }

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
            .navigationTitle((plan?.name.isEmpty == false) ? plan!.name : "Route Builder")
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
                searchBar
                HStack {
                    layerPicker
                    Spacer()
                    fitRouteButton
                }
            }
            .padding(12)
        }
    }

    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondaryText)
                TextField("Search ICAO / airport name", text: $searchText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .foregroundColor(.primaryText)
                if !searchText.isEmpty {
                    Button { searchText = ""; searchResults = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.dimText)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .floatingChromeBackground(cornerRadius: 12)

            if !searchResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(searchResults.prefix(6)) { airport in
                        Button { addAirport(airport); searchText = ""; searchResults = [] } label: {
                            HStack(spacing: 10) {
                                Text(airport.ident)
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(.aviationGold)
                                    .frame(width: 64, alignment: .leading)
                                Text(airport.name)
                                    .font(.system(size: 13))
                                    .foregroundColor(.primaryText)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundColor(.aviationGreen)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        if airport.id != searchResults.prefix(6).last?.id {
                            Divider().background(Color.white.opacity(0.06))
                        }
                    }
                }
                .floatingChromeBackground(cornerRadius: 12)
                .padding(.top, 4)
            }
        }
        .onChange(of: searchText) { _, query in
            searchResults = query.count >= 2 ? airportDataService.searchAirports(query: query, limit: 12) : []
        }
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
                waypointList
            }
            panelActions
        }
        .background(Color.cockpitBackground)
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
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
                types: [.largeAirport, .mediumAirport, .smallAirport],
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
            let overlay = WaypointPickerICAOTileOverlay()
            overlay.canReplaceMapContent = true
            mapView.insertOverlay(overlay, at: 0, level: .aboveLabels)
        case .swissimage:
            mapView.mapType = .standard
            let overlay = WaypointPickerSwisstopoTileOverlay(layerIdentifier: "ch.swisstopo.swissimage", tileExtension: "jpeg")
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

        // Replace the route polyline.
        mapView.removeOverlays(mapView.overlays.filter { $0 is MKPolyline })
        if waypoints.count >= 2 {
            let coords = waypoints.map { $0.coordinate }
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
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 0.95) // aviationGold
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
                view.markerTintColor = UIColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1) // aviationGold
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
