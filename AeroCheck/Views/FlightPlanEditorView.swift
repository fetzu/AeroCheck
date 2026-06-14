import SwiftUI
import MapKit
import UniformTypeIdentifiers

/// Export format options
enum FlightPlanExportFormat {
    case json
    case gpx  // Avionics-compatible GPX route format (Dynon SkyView, Garmin G3X)
    case xlsx
    case pdf

    var fileExtension: String {
        switch self {
        case .json: return "json"
        case .gpx: return "gpx"
        case .xlsx: return "xlsx"
        case .pdf: return "pdf"
        }
    }

    var contentType: UTType {
        switch self {
        case .json: return .json
        case .gpx: return .xml  // GPX is XML-based
        case .xlsx: return .spreadsheet
        case .pdf: return .pdf
        }
    }
}

/// Wrapper for export data to use with sheet(item:)
struct FlightPlanExportItem: Identifiable {
    let id = UUID()
    let data: Data
    let filename: String
    let format: FlightPlanExportFormat
}

/// Flight plan editor view - tabular format similar to "AVIS DE VOL" form
struct FlightPlanEditorView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @Environment(\.dismiss) var dismiss

    @State private var flightPlan: FlightPlan
    @State private var showingWaypointEditor: FlightPlanWaypoint?
    @State private var showingAddWaypoint = false
    @State private var showingTerrainProfile = false
    @State private var showingMapPicker = false
    @State private var showingICAOSearch = false
    @State private var exportItem: FlightPlanExportItem?
    @State private var showingAddWaypointChoice = false
    @State private var routeRefreshToken = UUID() // Forces route table refresh
    @State private var showingBulkAltitude = false
    @State private var bulkAltitudeString = ""
    @State private var airspaceConflicts: [AirspaceConflict] = []
    @State private var showingAirspaceConflicts = false
    @State private var airspaceDataUnavailable = false
    @State private var icaoSectionExpanded = false
    @State private var showingICAOCopied = false

    /// Whether we're on a compact width device (iPhone)
    /// Note: Using UIDevice instead of horizontalSizeClass because sheets on iPad
    /// report compact size class even though the device has plenty of space
    private var isCompactWidth: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// When true, hides Deactivate/Recalculate buttons (viewing from Flight Log)
    let isViewingFromFlightLog: Bool

    init(flightPlan: FlightPlan, isViewingFromFlightLog: Bool = false) {
        _flightPlan = State(initialValue: flightPlan)
        self.isViewingFromFlightLog = isViewingFromFlightLog
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header section
                    headerSection

                    // Airspace conflict warning banner (or data unavailable hint)
                    if !airspaceConflicts.isEmpty {
                        airspaceWarningBanner
                    } else if airspaceDataUnavailable && flightPlan.waypoints.count >= 2 {
                        airspaceDataHint
                    }

                    // Route table section
                    routeSection

                    // Fuel calculation section
                    fuelSection

                    // Timing section
                    timingSection

                    // Notes section
                    notesSection

                    // ICAO Details section (collapsible)
                    icaoDetailsSection

                    // Actions section
                    actionsSection
                }
                .padding()
                // Add keyboard padding only when needed (handled by system)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.cockpitBackground)
            .navigationTitle(flightPlan.name.isEmpty ? L10n.Nav.flightPlan : flightPlan.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Nav.save) {
                        saveAndDismiss()
                    }
                }
            }
            .sheet(item: $showingWaypointEditor) { waypoint in
                WaypointEditorSheet(
                    waypoint: waypoint,
                    aircraftType: flightPlan.aircraftTypeId,
                    onSave: { updatedWaypoint in
                        updateWaypoint(updatedWaypoint)
                    },
                    onDelete: {
                        if let index = flightPlan.waypoints.firstIndex(where: { $0.id == waypoint.id }) {
                            deleteWaypoint(at: index)
                        }
                    }
                )
            }
            .sheet(isPresented: $showingAddWaypoint) {
                AddWaypointSheet(aircraftTypeId: flightPlan.aircraftTypeId) { newWaypoint in
                    addWaypoint(newWaypoint)
                }
            }
            .sheet(isPresented: $showingTerrainProfile) {
                TerrainProfileView(waypoints: flightPlan.waypoints)
                    .environmentObject(appState)
            }
            .alert(L10n.Nav.setAltitude, isPresented: $showingBulkAltitude) {
                TextField("ft", text: $bulkAltitudeString)
                    .keyboardType(.numberPad)
                Button(L10n.Nav.allWaypoints) {
                    if let alt = Double(bulkAltitudeString) {
                        for i in 0..<flightPlan.waypoints.count {
                            flightPlan.waypoints[i].altitude = alt
                        }
                        routeRefreshToken = UUID()
                    }
                }
                Button(L10n.Nav.emptyOnly) {
                    if let alt = Double(bulkAltitudeString) {
                        for i in 0..<flightPlan.waypoints.count {
                            if flightPlan.waypoints[i].altitude == nil {
                                flightPlan.waypoints[i].altitude = alt
                            }
                        }
                        routeRefreshToken = UUID()
                    }
                }
                Button(L10n.Button.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Nav.setAltitudeMessage)
            }
            .sheet(isPresented: $showingMapPicker) {
                MapWaypointPickerView { coordinate, name in
                    let waypoint = FlightPlanWaypoint(
                        name: name,
                        coordinate: coordinate,
                        plannedGroundSpeed: FlightPlan.defaultCruiseSpeed(for: flightPlan.aircraftTypeId)
                    )
                    addWaypoint(waypoint)
                }
                .environmentObject(airportDataService)
                .environmentObject(appState)
            }
            .sheet(isPresented: $showingICAOSearch) {
                ICAOSearchSheet(airportDataService: airportDataService) { airport, primaryFrequency in
                    let waypoint = FlightPlanWaypoint(
                        name: airport.ident,
                        coordinate: airport.coordinate,
                        altitude: airport.elevation.map { Double($0) },
                        frequency: primaryFrequency,
                        plannedGroundSpeed: FlightPlan.defaultCruiseSpeed(for: flightPlan.aircraftTypeId)
                    )
                    addWaypoint(waypoint)
                }
            }
            .sheet(item: $exportItem) { item in
                FlightPlanExportSheet(
                    data: item.data,
                    filename: item.filename,
                    format: item.format
                )
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: routeRefreshToken) { _, _ in Task { await analyzeAirspaceConflicts() } }
        .task { await analyzeAirspaceConflicts() }
        .sheet(isPresented: $showingAirspaceConflicts) {
            AirspaceConflictDetailSheet(conflicts: airspaceConflicts)
        }
    }

    // MARK: - Airspace Warning Banner

    private var airspaceWarningBanner: some View {
        Button(action: { showingAirspaceConflicts = true }) {
            HStack(spacing: 10) {
                let highSeverity = airspaceConflicts.contains { $0.severity == .high }
                Image(systemName: highSeverity ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundColor(highSeverity ? .aviationRed : .aviationAmber)
                    .font(.system(size: 18))

                VStack(alignment: .leading, spacing: 2) {
                    Text(highSeverity ? L10n.Nav.restrictedAirspaceOnRoute : L10n.Nav.airspaceAlongRoute)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primaryText)

                    let summary = airspaceConflicts.prefix(3)
                        .map { $0.airspace.name }
                        .joined(separator: ", ")
                    Text(summary + (airspaceConflicts.count > 3 ? " +\(airspaceConflicts.count - 3) more" : ""))
                        .font(.system(size: 12))
                        .foregroundColor(.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.panelBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                airspaceConflicts.contains(where: { $0.severity == .high })
                                    ? Color.aviationRed.opacity(0.5)
                                    : Color.aviationAmber.opacity(0.3),
                                lineWidth: 1
                            )
                    )
            )
        }
    }

    private func analyzeAirspaceConflicts() async {
        guard flightPlan.waypoints.count >= 2 else {
            airspaceConflicts = []
            airspaceDataUnavailable = false
            return
        }

        let waypoints = flightPlan.waypoints.map { wp in
            (coordinate: wp.coordinate, altitude: wp.altitude)
        }
        let routeCoords = flightPlan.waypoints.map(\.coordinate)

        // Use downloaded data if available, otherwise fetch on-demand from API
        let nearbyAirspaces: [Airspace]
        if openAIPDataService.isDataAvailable {
            airspaceDataUnavailable = false
            await openAIPDataService.ensureLoaded()
            nearbyAirspaces = openAIPDataService.airspacesAlongRoute(routeCoords)
        } else {
            // On-demand fetch from API — works without downloading the full dataset
            do {
                nearbyAirspaces = try await openAIPDataService.fetchAirspacesAlongRoute(routeCoords)
                airspaceDataUnavailable = false
            } catch {
                print("[Airspace] On-demand fetch failed: \(error.localizedDescription)")
                airspaceConflicts = []
                airspaceDataUnavailable = true
                return
            }
        }

        airspaceConflicts = AirspaceAnalyzer.analyzeRoute(
            waypoints: waypoints,
            airspaces: nearbyAirspaces
        )
    }

    // MARK: - Airspace Data Hint

    private var airspaceDataHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14))
                .foregroundColor(.secondaryText)
            Text(L10n.Nav.airspaceCheckFailed)
                .font(.system(size: 13))
                .foregroundColor(.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.panelBackground)
        )
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 16) {
            // Title bar
            HStack {
                Text(L10n.Nav.navigationFlightPlan)
                    .font(.system(size: isCompactWidth ? 12 : 14, weight: .bold))
                    .foregroundColor(.aviationGold)
                    .tracking(1)

                Spacer()

                HStack(spacing: 8) {
                    Text(L10n.Nav.flightType)
                        .font(.system(size: isCompactWidth ? 10 : 12))
                        .foregroundColor(.secondaryText)

                    Picker("", selection: $flightPlan.flightType) {
                        ForEach(FlightType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.aviationGold)
                    .onChange(of: flightPlan.flightType) { _, _ in
                        // Force refresh by saving and recalculating
                        var updatedPlan = flightPlan
                        updatedPlan.calculateRouteData()
                        flightPlan = updatedPlan
                    }
                }
            }

            // Main header grid - adaptive columns for compact devices
            if isCompactWidth {
                // 2 columns for iPhone
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    FormField(label: L10n.Nav.pilot, text: $flightPlan.pilot)
                    FormField(label: L10n.Nav.aircraft, text: .constant(flightPlan.aircraftRegistration), isReadOnly: true)
                    DateFormField(label: L10n.Nav.date, date: Binding(
                        get: { flightPlan.plannedDepartureTime ?? Date() },
                        set: { flightPlan.plannedDepartureTime = $0 }
                    ))
                    OptionalFormField(label: L10n.Nav.runway, text: $flightPlan.runwayInUse, keyboardType: .numberPad)
                    OptionalFormField(label: L10n.Nav.instructor, text: $flightPlan.instructor)
                    FormField(label: L10n.Nav.totalEET, text: .constant(flightPlan.formattedTotalEET), isReadOnly: true)
                    FormField(label: L10n.Nav.distance, text: .constant(String(format: "%.1f NM", flightPlan.totalDistance)), isReadOnly: true)
                    FormField(label: L10n.Nav.endurance, text: .constant(flightPlan.formattedEndurance ?? "--:--"), isReadOnly: true)
                }
            } else {
                // 4 columns for iPad
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    // Row 1
                    FormField(label: L10n.Nav.pilot, text: $flightPlan.pilot)
                    FormField(label: L10n.Nav.aircraft, text: .constant(flightPlan.aircraftRegistration), isReadOnly: true)
                    DateFormField(label: L10n.Nav.date, date: Binding(
                        get: { flightPlan.plannedDepartureTime ?? Date() },
                        set: { flightPlan.plannedDepartureTime = $0 }
                    ))
                    OptionalFormField(label: L10n.Nav.runway, text: $flightPlan.runwayInUse, keyboardType: .numberPad)

                    // Row 2
                    OptionalFormField(label: L10n.Nav.instructor, text: $flightPlan.instructor)
                    FormField(label: L10n.Nav.totalEET, text: .constant(flightPlan.formattedTotalEET), isReadOnly: true)
                    FormField(label: L10n.Nav.distance, text: .constant(String(format: "%.1f NM", flightPlan.totalDistance)), isReadOnly: true)
                    FormField(label: L10n.Nav.endurance, text: .constant(flightPlan.formattedEndurance ?? "--:--"), isReadOnly: true)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground)
        )
    }

    // MARK: - Route Section

    private var routeSection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Label(L10n.Nav.route, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.aviationGold)

                Spacer()

                Button(action: { showingTerrainProfile = true }) {
                    Label(L10n.Nav.terrain, systemImage: "mountain.2")
                        .font(.system(size: 12))
                }
                .disabled(flightPlan.waypoints.count < 2)

                Menu {
                    Button(action: { showingAddWaypoint = true }) {
                        Label(L10n.Nav.addWaypointManually, systemImage: "plus")
                    }
                    if airportDataService.isDataAvailable {
                        Button(action: { showingICAOSearch = true }) {
                            Label(L10n.Nav.addWithICAO, systemImage: "magnifyingglass")
                        }
                    }
                    Button(action: { showingMapPicker = true }) {
                        Label(L10n.Nav.addFromMap, systemImage: "map")
                    }
                    if !flightPlan.waypoints.isEmpty {
                        Divider()
                        Button(action: {
                            bulkAltitudeString = ""
                            showingBulkAltitude = true
                        }) {
                            Label(L10n.Nav.setAltitude, systemImage: "arrow.up.and.down")
                        }
                    }
                } label: {
                    Label(L10n.Nav.add, systemImage: "plus.circle")
                        .font(.system(size: 12))
                }
            }

            // Route table - id forces refresh when waypoints change
            Group {
                if flightPlan.waypoints.isEmpty {
                    emptyRouteView
                } else {
                    routeTable
                }
            }
            .id(routeRefreshToken)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground)
        )
    }

    private var emptyRouteView: some View {
        VStack(spacing: 12) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 32))
                .foregroundColor(.dimText)

            Text(L10n.Nav.noWaypoints)
                .font(.system(size: 14))
                .foregroundColor(.secondaryText)

            Menu {
                Button(action: { showingAddWaypoint = true }) {
                    Label(L10n.Nav.addWaypointManually, systemImage: "plus")
                }
                Button(action: { showingMapPicker = true }) {
                    Label(L10n.Nav.addFromMap, systemImage: "map")
                }
            } label: {
                Label(L10n.Nav.addFirstWaypoint, systemImage: "plus")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(.aviationGold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var routeTable: some View {
        Group {
            if isCompactWidth {
                // iPhone: Wrap in horizontal ScrollView with fixed-width content
                ScrollView(.horizontal, showsIndicators: true) {
                    compactRouteTableContent
                        .frame(minWidth: 600)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.aviationDarkBlue.opacity(0.5), lineWidth: 1)
                )
            } else {
                // iPad: Flexible waypoint column with drag-and-reorder support
                VStack(spacing: 0) {
                    // Table header
                    HStack(spacing: 0) {
                        tableHeaderCell("#", width: 30)
                        tableHeaderCell(L10n.Nav.waypoint, width: nil, alignment: .leading)
                        tableHeaderCell(L10n.Nav.freq, width: 55)
                        tableHeaderCell(L10n.Nav.mc, width: 50)
                        tableHeaderCell(L10n.Nav.dist, width: 50)
                        tableHeaderCell(L10n.Nav.alt, width: 60)
                        tableHeaderCell(L10n.Nav.gs, width: 50)
                        tableHeaderCell(L10n.Nav.eet, width: 50)
                        tableHeaderCell(L10n.Nav.eto, width: 55)
                        tableHeaderCell(L10n.Nav.ato, width: 55)
                    }
                    .background(Color.aviationDarkBlue)

                    // Table rows with drag-and-reorder
                    List {
                        ForEach(Array(flightPlan.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                            WaypointTableRow(
                                index: index,
                                waypoint: waypoint,
                                isLast: index == flightPlan.waypoints.count - 1,
                                isCompact: false,
                                onTap: {
                                    showingWaypointEditor = waypoint
                                },
                                onDelete: {
                                    deleteWaypoint(at: index)
                                },
                                onMoveUp: index > 0 ? { moveWaypoint(from: index, to: index - 1) } : nil,
                                onMoveDown: index < flightPlan.waypoints.count - 1 ? { moveWaypoint(from: index, to: index + 1) } : nil
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                        .onMove { source, destination in
                            guard let from = source.first else { return }
                            moveWaypoint(from: from, to: destination > from ? destination - 1 : destination)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: CGFloat(flightPlan.waypoints.count) * 36, maxHeight: CGFloat(flightPlan.waypoints.count) * 36)
                    .environment(\.editMode, .constant(.active))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.aviationDarkBlue, lineWidth: 1)
                )
            }
        }
    }

    /// Compact route table content for iPhone - uses fixed column widths
    private var compactRouteTableContent: some View {
        VStack(spacing: 0) {
            // Table header with fixed widths
            HStack(spacing: 0) {
                tableHeaderCell("#", width: 30)
                tableHeaderCell(L10n.Nav.waypoint, width: 100, alignment: .leading)
                tableHeaderCell(L10n.Nav.freq, width: 55)
                tableHeaderCell(L10n.Nav.mc, width: 50)
                tableHeaderCell(L10n.Nav.dist, width: 50)
                tableHeaderCell(L10n.Nav.alt, width: 60)
                tableHeaderCell(L10n.Nav.gs, width: 50)
                tableHeaderCell(L10n.Nav.eet, width: 50)
                tableHeaderCell(L10n.Nav.eto, width: 55)
                tableHeaderCell(L10n.Nav.ato, width: 55)
            }
            .background(Color.aviationDarkBlue)

            // Table rows
            ForEach(Array(flightPlan.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                WaypointTableRow(
                    index: index,
                    waypoint: waypoint,
                    isLast: index == flightPlan.waypoints.count - 1,
                    isCompact: true,
                    onTap: {
                        showingWaypointEditor = waypoint
                    },
                    onDelete: {
                        deleteWaypoint(at: index)
                    },
                    onMoveUp: index > 0 ? { moveWaypoint(from: index, to: index - 1) } : nil,
                    onMoveDown: index < flightPlan.waypoints.count - 1 ? { moveWaypoint(from: index, to: index + 1) } : nil
                )
            }
        }
    }

    private func tableHeaderCell(_ text: String, width: CGFloat?, alignment: Alignment = .center) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.aviationGold)
            .frame(width: width, alignment: alignment)
            .frame(height: 32)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }

    // MARK: - Fuel Section

    private var fuelSection: some View {
        VStack(spacing: 12) {
            HStack {
                Label(L10n.Nav.fuelCalculation, systemImage: "fuelpump")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.aviationGold)

                Spacer()
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: isCompactWidth ? 2 : 3), spacing: 12) {
                NumberFormField(
                    label: L10n.Nav.fuelFlow,
                    value: Binding(
                        get: { flightPlan.fuelFlow ?? FlightPlan.defaultFuelFlow(for: flightPlan.aircraftTypeId) },
                        set: { flightPlan.fuelFlow = $0 }
                    ),
                    format: "%.0f"
                )

                NumberFormField(
                    label: L10n.Nav.tripFuel,
                    value: Binding(
                        get: { flightPlan.tripFuel ?? 0 },
                        set: { flightPlan.tripFuel = $0 }
                    ),
                    format: "%.1f"
                )

                NumberFormField(
                    label: L10n.Nav.reserveFuel,
                    value: Binding(
                        get: { flightPlan.reserveFuel ?? 0 },
                        set: { flightPlan.reserveFuel = $0 }
                    ),
                    format: "%.1f"
                )

                NumberFormField(
                    label: L10n.Nav.additionalFuel,
                    value: Binding(
                        get: {
                            // Auto-populate with 45 minutes of fuel if not set
                            if let additional = flightPlan.additionalFuel, additional > 0 {
                                return additional
                            }
                            let fuelFlow = flightPlan.fuelFlow ?? FlightPlan.defaultFuelFlow(for: flightPlan.aircraftTypeId)
                            return fuelFlow * 0.75 // 45 minutes = 0.75 hours
                        },
                        set: { flightPlan.additionalFuel = $0 }
                    ),
                    format: "%.1f"
                )

                NumberFormField(
                    label: L10n.Nav.extraFuel,
                    value: Binding(
                        get: { flightPlan.extraFuel ?? 0 },
                        set: { flightPlan.extraFuel = $0 }
                    ),
                    format: "%.1f"
                )

                FormField(
                    label: L10n.Nav.requiredFuel,
                    text: .constant(flightPlan.fuelRequired.map { String(format: "%.1f", $0) } ?? "--"),
                    isReadOnly: true
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground)
        )
    }

    // MARK: - Timing Section

    private var timingSection: some View {
        VStack(spacing: 12) {
            HStack {
                Label(L10n.Nav.timing, systemImage: "clock")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.aviationGold)

                Spacer()
            }

            // First row: Counter Start, Block OFF, Time ON, Time OFF, Block ON, Counter Stop
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: isCompactWidth ? 2 : 6), spacing: 12) {
                NumberFormField(
                    label: L10n.Nav.counterStart,
                    value: Binding(
                        get: { flightPlan.counterStart ?? 0 },
                        set: { flightPlan.counterStart = $0 }
                    ),
                    format: "%.1f"
                )

                OptionalTimeFormField(label: L10n.Nav.blockOff, time: $flightPlan.blockOff)
                OptionalTimeFormField(label: L10n.Nav.timeOn, time: $flightPlan.timeOn)
                OptionalTimeFormField(label: L10n.Nav.timeOff, time: $flightPlan.timeOff)
                OptionalTimeFormField(label: L10n.Nav.blockOn, time: $flightPlan.blockOn)

                NumberFormField(
                    label: L10n.Nav.counterStop,
                    value: Binding(
                        get: { calculatedCounterStop },
                        set: { flightPlan.counterStop = $0 }
                    ),
                    format: "%.1f"
                )
            }

            // Second row: Landings and Engine Time
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: isCompactWidth ? 2 : 6), spacing: 12) {
                IntFormField(
                    label: L10n.Nav.ldgsAtBase,
                    value: Binding(
                        get: { flightPlan.landingsAtBase ?? 0 },
                        set: { flightPlan.landingsAtBase = $0 }
                    )
                )

                IntFormField(
                    label: L10n.Nav.totalLdgs,
                    value: Binding(
                        get: { calculatedTotalLandings },
                        set: { flightPlan.totalLandings = $0 }
                    )
                )

                // Engine Time display (HH:MM format)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.Nav.engineTime)
                        .font(.system(size: 11))
                        .foregroundColor(.secondaryText)
                    Text(formattedEngineTime)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.cardBackground.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Empty cells to maintain grid alignment
                Spacer()
                Spacer()
                Spacer()
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground)
        )
    }

    // MARK: - Notes Section

    private var notesSection: some View {
        VStack(spacing: 12) {
            HStack {
                Label(L10n.Nav.notes, systemImage: "note.text")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.aviationGold)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Nav.remarks)
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)

                TextEditor(text: $flightPlan.remarks)
                    .font(.system(size: 14))
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Nav.debriefing)
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)

                TextEditor(text: $flightPlan.debriefing)
                    .font(.system(size: 14))
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground)
        )
    }

    // MARK: - ICAO Details Section

    private var icaoDetailsSection: some View {
        VStack(spacing: 12) {
            Button(action: { withAnimation { icaoSectionExpanded.toggle() } }) {
                HStack {
                    Label(L10n.Nav.icaoDetails, systemImage: "doc.plaintext")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.aviationGold)

                    Spacer()

                    Image(systemName: icaoSectionExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(.secondaryText)
                }
            }
            .buttonStyle(.plain)

            if icaoSectionExpanded {
                icaoFieldsContent
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground)
        )
    }

    private var icaoFieldsContent: some View {
        VStack(spacing: 12) {
            icaoFieldRow(label: L10n.Nav.icaoAircraftType, placeholder: flightPlan.resolvedICAOType, binding: Binding(
                get: { flightPlan.icaoAircraftType ?? "" },
                set: { flightPlan.icaoAircraftType = $0.isEmpty ? nil : $0 }
            ))

            // Wake turbulence category picker
            HStack {
                Text(L10n.Nav.wakeTurbulence)
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)
                    .frame(width: 140, alignment: .leading)

                Picker("", selection: Binding(
                    get: { flightPlan.wakeTurbulenceCategory ?? "L" },
                    set: { flightPlan.wakeTurbulenceCategory = $0 }
                )) {
                    Text("L").tag("L")
                    Text("M").tag("M")
                    Text("H").tag("H")
                }
                .pickerStyle(.segmented)
            }

            icaoFieldRow(label: L10n.Nav.equipmentCodes, placeholder: "S", binding: Binding(
                get: { flightPlan.equipmentCodes ?? "" },
                set: { flightPlan.equipmentCodes = $0.isEmpty ? nil : $0 }
            ))

            icaoFieldRow(label: L10n.Nav.surveillanceCodes, placeholder: "N", binding: Binding(
                get: { flightPlan.surveillanceCodes ?? "" },
                set: { flightPlan.surveillanceCodes = $0.isEmpty ? nil : $0 }
            ))

            icaoFieldRow(label: L10n.Nav.alternateAerodrome, placeholder: "LFGB", binding: Binding(
                get: { flightPlan.alternateAerodrome ?? "" },
                set: { flightPlan.alternateAerodrome = $0.isEmpty ? nil : $0 }
            ))

            // Persons on board
            HStack {
                Text(L10n.Nav.personsOnBoard)
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)
                    .frame(width: 140, alignment: .leading)

                TextField("1", text: Binding(
                    get: { flightPlan.personsOnBoard.map { String($0) } ?? "" },
                    set: { flightPlan.personsOnBoard = Int($0) }
                ))
                .keyboardType(.numberPad)
                .font(.system(size: 14, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            }

            icaoFieldRow(label: L10n.Nav.aircraftColour, placeholder: "WHITE RED", binding: Binding(
                get: { flightPlan.aircraftColour ?? "" },
                set: { flightPlan.aircraftColour = $0.isEmpty ? nil : $0 }
            ))
        }
    }

    private func icaoFieldRow(label: String, placeholder: String, binding: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondaryText)
                .frame(width: 140, alignment: .leading)

            TextField(placeholder, text: binding)
                .font(.system(size: 14, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.allCharacters)
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 12) {
            // Hide Activate/Deactivate and Recalculate buttons when viewing from Flight Log
            if !isViewingFromFlightLog {
                if flightPlan.id == flightPlanManager.activeFlightPlan?.id {
                    Button(action: {
                        flightPlanManager.deactivateFlightPlan()
                    }) {
                        Label(L10n.Nav.deactivateFlightPlan, systemImage: "airplane.arrival")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } else {
                    Button(action: {
                        flightPlanManager.updateFlightPlan(flightPlan)
                        flightPlanManager.activateFlightPlan(flightPlan)
                        dismiss()
                    }) {
                        Label(L10n.Nav.activateFlightPlan, systemImage: "airplane.departure")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.aviationGreen)
                }

                Button(action: {
                    recalculateRoute()
                }) {
                    Label(L10n.Nav.recalculateRoute, systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Divider()
                    .padding(.vertical, 8)
            }

            // Export section
            exportSection
        }
        .padding()
    }

    // MARK: - Export Section

    private var exportSection: some View {
        VStack(spacing: 8) {
            Text(L10n.Nav.exportFlightPlan)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondaryText)

            HStack(spacing: 12) {
                Button(action: { exportFlightPlan(format: .json) }) {
                    VStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 20))
                        Text("JSON")
                            .font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Button(action: { exportFlightPlan(format: .gpx) }) {
                    VStack(spacing: 4) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.system(size: 20))
                        Text("GPX")
                            .font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Button(action: { exportFlightPlan(format: .xlsx) }) {
                    VStack(spacing: 4) {
                        Image(systemName: "tablecells")
                            .font(.system(size: 20))
                        Text("Excel")
                            .font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Button(action: { exportFlightPlan(format: .pdf) }) {
                    VStack(spacing: 4) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 20))
                        Text("PDF")
                            .font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }

            // ICAO FPL copy button
            Button(action: {
                let fplText = flightPlan.toICAOFlightPlan()
                UIPasteboard.general.string = fplText
                showingICAOCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    showingICAOCopied = false
                }
            }) {
                HStack {
                    Image(systemName: showingICAOCopied ? "checkmark.circle.fill" : "doc.on.clipboard")
                        .font(.system(size: 16))
                    Text(showingICAOCopied ? L10n.Nav.icaoCopied : L10n.Nav.copyICAOFlightPlan)
                        .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(showingICAOCopied ? .green : .aviationGold)
            .disabled(flightPlan.waypoints.count < 2)
        }
    }

    // MARK: - Computed Properties for Auto-Population

    /// Calculate Counter Stop based on Counter Start + Engine Time
    /// Engine Time = Time OFF (engine stop) - Time ON (engine start)
    private var calculatedCounterStop: Double {
        // If explicitly set, use that value
        if let counterStop = flightPlan.counterStop, counterStop > 0 {
            return counterStop
        }

        // Otherwise, try to calculate from counter start + engine time
        guard let counterStart = flightPlan.counterStart,
              let timeOn = flightPlan.timeOn,
              let timeOff = flightPlan.timeOff else {
            return flightPlan.counterStop ?? 0
        }

        // Engine time in hours (Hobbs meter is in decimal hours)
        let engineTimeSeconds = timeOff.timeIntervalSince(timeOn)
        let engineTimeHours = engineTimeSeconds / 3600.0

        return counterStart + engineTimeHours
    }

    /// Format engine time as HH:MM (from Time ON = engine start to Time OFF = engine stop)
    /// Same format as Flight Log detail view duration
    private var formattedEngineTime: String {
        guard let timeOn = flightPlan.timeOn,
              let timeOff = flightPlan.timeOff else {
            return "--:--"
        }

        let engineTimeSeconds = timeOff.timeIntervalSince(timeOn)
        if engineTimeSeconds < 0 { return "--:--" }

        let hours = Int(engineTimeSeconds) / 3600
        let minutes = (Int(engineTimeSeconds) % 3600) / 60

        return String(format: "%02d:%02d", hours, minutes)
    }

    /// Calculate Total Landings from current flight if available
    private var calculatedTotalLandings: Int {
        // If explicitly set, use that value
        if let totalLandings = flightPlan.totalLandings, totalLandings > 0 {
            return totalLandings
        }

        // Try to get from current flight
        if let currentFlight = appState.currentFlight {
            return currentFlight.totalLandings
        }

        return flightPlan.totalLandings ?? 0
    }

    // MARK: - Actions

    private func saveAndDismiss() {
        flightPlan.calculateRouteData()
        flightPlanManager.updateFlightPlan(flightPlan)
        dismiss()
    }

    private func exportFlightPlan(format: FlightPlanExportFormat) {
        // Generate the data
        let generatedData: Data?
        switch format {
        case .json:
            generatedData = FlightPlanExportService.exportToJSON(flightPlan)
        case .gpx:
            generatedData = FlightPlanExportService.exportToAvionicsGPX(flightPlan)
        case .xlsx:
            generatedData = FlightPlanExportService.exportToXLSX(flightPlan)
        case .pdf:
            generatedData = FlightPlanExportService.exportToPDF(flightPlan)
        }

        // Only proceed if data was generated successfully
        guard let data = generatedData else { return }

        // Create export item and show sheet (using item: binding is more reliable than isPresented)
        exportItem = FlightPlanExportItem(
            data: data,
            filename: flightPlan.exportFilename,
            format: format
        )
    }

    private func addWaypoint(_ waypoint: FlightPlanWaypoint) {
        var updatedPlan = flightPlan
        updatedPlan.waypoints.append(waypoint)
        updatedPlan.calculateRouteData()
        flightPlan = updatedPlan
        routeRefreshToken = UUID() // Force UI refresh
    }

    private func updateWaypoint(_ waypoint: FlightPlanWaypoint) {
        if let index = flightPlan.waypoints.firstIndex(where: { $0.id == waypoint.id }) {
            var updatedPlan = flightPlan
            updatedPlan.waypoints[index] = waypoint
            updatedPlan.calculateRouteData()
            flightPlan = updatedPlan
            routeRefreshToken = UUID() // Force UI refresh
        }
    }

    private func deleteWaypoint(at index: Int) {
        var updatedPlan = flightPlan
        updatedPlan.waypoints.remove(at: index)
        updatedPlan.calculateRouteData()
        flightPlan = updatedPlan
        routeRefreshToken = UUID() // Force UI refresh
    }

    private func moveWaypoint(from source: Int, to destination: Int) {
        var updatedPlan = flightPlan
        let waypoint = updatedPlan.waypoints.remove(at: source)
        updatedPlan.waypoints.insert(waypoint, at: destination)
        updatedPlan.calculateRouteData()
        flightPlan = updatedPlan
        routeRefreshToken = UUID() // Force UI refresh
    }

    private func recalculateRoute() {
        var updatedPlan = flightPlan
        // Clear ATO fields when recalculating
        for i in updatedPlan.waypoints.indices {
            updatedPlan.waypoints[i].actualTimeOver = nil
        }
        updatedPlan.calculateRouteData()
        flightPlan = updatedPlan
        routeRefreshToken = UUID() // Force UI refresh
    }
}

// MARK: - Waypoint Table Row

struct WaypointTableRow: View {
    let index: Int
    let waypoint: FlightPlanWaypoint
    let isLast: Bool
    var isCompact: Bool = false
    let onTap: () -> Void
    let onDelete: () -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    /// Whether this is the first waypoint (departure point - no leg data to display)
    private var isFirstWaypoint: Bool { index == 0 }

    var body: some View {
        HStack(spacing: 0) {
            // Index - fixed width
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.dimText)
                .frame(width: 30)

            // Waypoint name - flexible on iPad, fixed on iPhone
            if isCompact {
                Text(waypoint.name.isEmpty ? "\(L10n.Nav.wpt)\(index + 1)" : waypoint.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primaryText)
                    .lineLimit(1)
                    .frame(width: 100, alignment: .leading)
            } else {
                Text(waypoint.name.isEmpty ? "\(L10n.Nav.wpt)\(index + 1)" : waypoint.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Frequency - fixed width
            Text(waypoint.frequency ?? "-")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.aviationGold)
                .frame(width: 55)
                .lineLimit(1)

            // MC (Magnetic Course) - not shown for first waypoint
            Text(isFirstWaypoint ? "-" : (waypoint.magneticCourse.map { String(format: "%03d°", Int($0)) } ?? "-"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primaryText)
                .frame(width: 50)

            // Distance - not shown for first waypoint
            Text(isFirstWaypoint ? "-" : (waypoint.distance.map { String(format: "%.1f", $0) } ?? "-"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primaryText)
                .frame(width: 50)

            // Altitude - shown for all waypoints (it's the planned altitude AT this waypoint)
            Text(waypoint.altitude.map { String(format: "%.0f", $0) } ?? "-")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primaryText)
                .frame(width: 60)

            // Ground Speed - not shown for first waypoint
            Text(isFirstWaypoint ? "-" : (waypoint.plannedGroundSpeed.map { "\($0)" } ?? "-"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primaryText)
                .frame(width: 50)

            // EET - not shown for first waypoint
            Text(isFirstWaypoint ? "-" : (waypoint.formattedEET ?? "-"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primaryText)
                .frame(width: 50)

            // ETO - shown for all waypoints (time at which we should arrive AT this waypoint)
            Text(waypoint.formattedETO ?? "-")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primaryText)
                .frame(width: 55)

            // ATO - fixed width
            Text(waypoint.formattedATO ?? "-")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(waypoint.actualTimeOver != nil ? .aviationGreen : .dimText)
                .frame(width: 55)
        }
        .frame(height: 40)
        .background(index % 2 == 0 ? Color.cardBackground : Color.panelBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .contextMenu {
            Button(action: onTap) {
                Label(L10n.Nav.edit, systemImage: "pencil")
            }

            if let moveUp = onMoveUp {
                Button(action: moveUp) {
                    Label(L10n.Nav.moveUp, systemImage: "arrow.up")
                }
            }

            if let moveDown = onMoveDown {
                Button(action: moveDown) {
                    Label(L10n.Nav.moveDown, systemImage: "arrow.down")
                }
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label(L10n.Button.delete, systemImage: "trash")
            }
        }
    }
}

// MARK: - Form Fields

struct FormField: View {
    let label: String
    @Binding var text: String
    var isReadOnly: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondaryText)

            if isReadOnly {
                Text(text.isEmpty ? "-" : text)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.cardBackground.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                TextField("", text: $text)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// Form field for optional string values
struct OptionalFormField: View {
    let label: String
    @Binding var text: String?
    var keyboardType: UIKeyboardType = .default

    @State private var localText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondaryText)

            TextField("", text: $localText)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .keyboardType(keyboardType)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onAppear {
                    localText = text ?? ""
                }
                .onChange(of: localText) { _, newValue in
                    text = newValue.isEmpty ? nil : newValue
                }
                .onChange(of: text) { _, newValue in
                    let newText = newValue ?? ""
                    if newText != localText {
                        localText = newText
                    }
                }
        }
    }
}

struct DateFormField: View {
    let label: String
    @Binding var date: Date

    @State private var showingDatePicker = false

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM yyyy"
        return formatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondaryText)

            // Display date as styled text, tap to edit
            Button(action: { showingDatePicker = true }) {
                Text(dateFormatter.string(from: date))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingDatePicker) {
            DatePickerSheet(selectedDate: $date, isPresented: $showingDatePicker)
        }
    }
}

/// Compact sheet for picking date (popover-style)
struct DatePickerSheet: View {
    @Binding var selectedDate: Date
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text(L10n.Nav.selectDate)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primaryText)

                Spacer()

                Button(L10n.Button.done) {
                    isPresented = false
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.aviationGold)
            }
            .padding(.horizontal)
            .padding(.top, 16)

            // Date picker
            DatePicker("", selection: $selectedDate, displayedComponents: [.date])
                .labelsHidden()
                .datePickerStyle(.graphical)
                .tint(.aviationGold)

            Spacer()
        }
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

struct OptionalTimeFormField: View {
    let label: String
    @Binding var time: Date?

    @State private var isSet: Bool = false
    @State private var selectedTime: Date = Date()
    @State private var showingPicker: Bool = false

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondaryText)

            Button(action: {
                if !isSet {
                    selectedTime = Date()
                    time = selectedTime
                    isSet = true
                }
                showingPicker = true
            }) {
                Text(isSet ? timeFormatter.string(from: selectedTime) : L10n.Nav.set)
                    .font(.system(size: 14, weight: isSet ? .medium : .regular, design: .monospaced))
                    .foregroundColor(isSet ? .primaryText : .aviationGold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingPicker) {
            TimePickerSheet(selectedTime: $selectedTime, isPresented: $showingPicker)
                .onChange(of: selectedTime) { _, newValue in
                    time = newValue
                }
        }
        .onAppear {
            if let existingTime = time {
                selectedTime = existingTime
                isSet = true
            }
        }
    }
}

/// Compact sheet for picking time (popover-style)
struct TimePickerSheet: View {
    @Binding var selectedTime: Date
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text(L10n.Nav.selectTime)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primaryText)

                Spacer()

                Button(L10n.Button.done) {
                    isPresented = false
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.aviationGold)
            }
            .padding(.horizontal)
            .padding(.top, 16)

            // Compact time picker
            DatePicker("", selection: $selectedTime, displayedComponents: [.hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.wheel)
                .frame(height: 150)
                .clipped()

            Spacer()
        }
        .frame(maxHeight: 280)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

struct NumberFormField: View {
    let label: String
    @Binding var value: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondaryText)

            TextField("", value: $value, format: .number)
                .font(.system(size: 14, design: .monospaced))
                .textFieldStyle(.plain)
                .keyboardType(.decimalPad)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct IntFormField: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondaryText)

            TextField("", value: $value, format: .number)
                .font(.system(size: 14, design: .monospaced))
                .textFieldStyle(.plain)
                .keyboardType(.numberPad)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Add Waypoint Sheet

struct AddWaypointSheet: View {
    @Environment(\.dismiss) var dismiss

    let aircraftTypeId: String
    let onAdd: (FlightPlanWaypoint) -> Void

    private let elevationService = ElevationService()

    @State private var name: String = ""
    @State private var latitude: String = ""
    @State private var longitude: String = ""
    @State private var altitude: String = ""
    @State private var frequency: String = ""
    @State private var remarks: String = ""
    @State private var groundElevationMeters: Double?
    @State private var isLoadingElevation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.FlightPlan.waypointNameHint, text: $name)

                    HStack {
                        TextField(L10n.Nav.latitude, text: $latitude)
                            .keyboardType(.decimalPad)
                        TextField(L10n.Nav.longitude, text: $longitude)
                            .keyboardType(.decimalPad)
                    }

                    TextField(L10n.FlightPlan.altitudePlaceholder, text: $altitude)
                        .keyboardType(.numberPad)

                    // Ground level display
                    HStack {
                        if isLoadingElevation {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(L10n.Nav.loadingElevation)
                                .foregroundColor(.secondaryText)
                                .font(.system(size: 12))
                        } else if let groundElevation = groundElevationMeters {
                            let groundFeet = groundElevation * 3.28084
                            Text(L10n.Nav.groundLevel(Int(groundFeet)))
                                .foregroundColor(.dimText)
                                .font(.system(size: 12))
                        }
                    }
                } header: {
                    Label(L10n.Nav.location, systemImage: "mappin")
                } footer: {
                    if groundElevationMeters != nil {
                        Text(L10n.Nav.defaultAGL)
                    }
                }

                Section {
                    TextField(L10n.Nav.frequency, text: $frequency)
                        .keyboardType(.decimalPad)

                    TextField(L10n.Nav.remarks, text: $remarks)
                } header: {
                    Label(L10n.Nav.details, systemImage: "info.circle")
                }
            }
            .navigationTitle(L10n.Nav.addWaypoint)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Nav.add) {
                        addWaypoint()
                    }
                    .disabled(latitude.isEmpty || longitude.isEmpty)
                }
            }
            .onChange(of: latitude) { _, _ in
                Task { await fetchGroundElevation() }
            }
            .onChange(of: longitude) { _, _ in
                Task { await fetchGroundElevation() }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func fetchGroundElevation() async {
        guard let lat = Double(latitude),
              let lon = Double(longitude) else {
            groundElevationMeters = nil
            return
        }

        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)

        // Only fetch if within Switzerland
        guard await elevationService.isInSwitzerland(coordinate) else {
            groundElevationMeters = nil
            return
        }

        isLoadingElevation = true

        if let elevation = await elevationService.fetchElevation(at: coordinate) {
            groundElevationMeters = elevation

            // If altitude is not set, default to ground level + 3000 ft AGL
            if altitude.isEmpty {
                let defaultAltitude = (elevation * 3.28084) + 3000
                altitude = String(format: "%.0f", defaultAltitude)
            }
        } else {
            groundElevationMeters = nil
        }

        isLoadingElevation = false
    }

    private func addWaypoint() {
        guard let lat = Double(latitude),
              let lon = Double(longitude) else { return }

        let waypoint = FlightPlanWaypoint(
            name: name.isEmpty ? L10n.Nav.wpt : name,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: Double(altitude),
            frequency: frequency.isEmpty ? nil : frequency,
            remarks: remarks,
            plannedGroundSpeed: FlightPlan.defaultCruiseSpeed(for: aircraftTypeId)
        )

        onAdd(waypoint)
        dismiss()
    }
}

// MARK: - Map Layer Type for Waypoint Picker

enum WaypointPickerMapLayer: String, CaseIterable, Identifiable {
    case apple = "Apple Maps"
    case icao = "ICAO / Segelflug"
    case swissimage = "SwissImage"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .apple: return "map"
        case .icao: return "airplane"
        case .swissimage: return "photo"
        }
    }
}

// MARK: - Map Waypoint Picker

struct MapWaypointPickerView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var appState: AppState

    let onSelect: (CLLocationCoordinate2D, String) -> Void

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.1, longitude: 7.1), // Default to Swiss Jura
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
    )
    @State private var waypointName: String = ""
    @State private var selectedLayer: WaypointPickerMapLayer = .apple
    @State private var selectedAirport: Airport?
    @State private var selectedAirportFrequency: String?
    @State private var showAirportConfirmation = false
    @State private var visibleAirports: [Airport] = []
    @State private var airportUpdateTask: Task<Void, Never>?

    private func scheduleAirportUpdate() {
        airportUpdateTask?.cancel()
        airportUpdateTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled else { return }
            guard appState.settings.showAirportsOnMap, airportDataService.isDataAvailable else {
                await MainActor.run { visibleAirports = [] }
                return
            }
            let currentRegion = region
            let halfLatSpan = currentRegion.span.latitudeDelta / 2
            let halfLonSpan = currentRegion.span.longitudeDelta / 2
            let airports = airportDataService.getAirportsInRegion(
                minLat: currentRegion.center.latitude - halfLatSpan,
                maxLat: currentRegion.center.latitude + halfLatSpan,
                minLon: currentRegion.center.longitude - halfLonSpan,
                maxLon: currentRegion.center.longitude + halfLonSpan,
                types: [.largeAirport, .mediumAirport, .smallAirport],
                limit: 100
            )
            await MainActor.run { visibleAirports = airports }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Map view based on selected layer
                WaypointPickerMapViewRepresentable(
                    region: $region,
                    mapLayer: selectedLayer,
                    airports: visibleAirports,
                    onAirportTapped: { airport in
                        selectedAirport = airport
                        let frequencies = airportDataService.getFrequencies(for: airport.ident)
                        selectedAirportFrequency = frequencies.first(where: { $0.type.uppercased().contains("TWR") })?.formattedFrequency
                            ?? frequencies.first(where: { $0.type.uppercased().contains("ATIS") })?.formattedFrequency
                            ?? frequencies.first?.formattedFrequency
                        showAirportConfirmation = true
                    }
                )
                .ignoresSafeArea()

                // Crosshair at center
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.aviationGold)
                        .frame(width: 2, height: 20)
                    Rectangle()
                        .fill(Color.aviationGold)
                        .frame(width: 2, height: 20)
                }
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.aviationGold)
                        .frame(width: 20, height: 2)
                    Rectangle()
                        .fill(Color.aviationGold)
                        .frame(width: 20, height: 2)
                }

                // Layer selector at top
                VStack {
                    HStack {
                        Spacer()
                        Picker(L10n.Nav.layer, selection: $selectedLayer) {
                            ForEach(WaypointPickerMapLayer.allCases) { layer in
                                Label(layer.rawValue, systemImage: layer.icon)
                                    .tag(layer)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(8)
                        .background(Color.panelBackground.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding()
                    }
                    Spacer()
                }

                // Bottom panel
                VStack {
                    Spacer()

                    VStack(spacing: 12) {
                        TextField(L10n.Nav.waypointNamePlaceholder, text: $waypointName)
                            .textFieldStyle(.roundedBorder)

                        Text("Lat: \(String(format: "%.4f", region.center.latitude))  Lon: \(String(format: "%.4f", region.center.longitude))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondaryText)

                        Button(action: {
                            onSelect(region.center, waypointName)
                            dismiss()
                        }) {
                            Text(L10n.Nav.addWaypointAtCenter)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.aviationGold)
                    }
                    .padding()
                    .background(Color.panelBackground.opacity(0.95))
                }
            }
            .navigationTitle(L10n.Nav.selectLocation)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { dismiss() }
                }
            }
            .alert(L10n.Nav.addAirportToRoute, isPresented: $showAirportConfirmation) {
                Button(L10n.Nav.add) {
                    if let airport = selectedAirport {
                        onSelect(airport.coordinate, airport.ident)
                        dismiss()
                    }
                }
                Button(L10n.Button.cancel, role: .cancel) { }
            } message: {
                if let airport = selectedAirport {
                    Text("\(airport.ident) - \(airport.name)")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { scheduleAirportUpdate() }
        .onChange(of: region.center.latitude) { _, _ in scheduleAirportUpdate() }
        .onChange(of: region.center.longitude) { _, _ in scheduleAirportUpdate() }
    }
}

// MARK: - Waypoint Picker Map View Representable

struct WaypointPickerMapViewRepresentable: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let mapLayer: WaypointPickerMapLayer
    var airports: [Airport] = []
    var onAirportTapped: ((Airport) -> Void)?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.setRegion(region, animated: false)
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.showsScale = true
        configureMapLayer(mapView)
        mapView.cameraZoomRange = cameraZoomRange(for: mapLayer)
        return mapView
    }

    private func cameraZoomRange(for layer: WaypointPickerMapLayer) -> MKMapView.CameraZoomRange? {
        switch layer {
        case .apple:
            return MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: 100,
                maxCenterCoordinateDistance: 10_000_000
            )
        case .icao:
            // ICAO + Segelflugkarte: zoom 7-12, matching NavigationView values
            return MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: 65_000,
                maxCenterCoordinateDistance: 600_000
            )
        case .swissimage:
            // SWISSIMAGE: zoom 7-18
            return MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: 1_500,
                maxCenterCoordinateDistance: 600_000
            )
        }
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Only reconfigure tiles when layer actually changes
        if context.coordinator.currentLayer != mapLayer {
            context.coordinator.currentLayer = mapLayer
            configureMapLayer(mapView)
            mapView.cameraZoomRange = cameraZoomRange(for: mapLayer)
        }
        // Update airport annotations (already uses diff logic)
        updateAirportAnnotations(mapView)
    }

    private func updateAirportAnnotations(_ mapView: MKMapView) {
        let existingAirportAnnotations = mapView.annotations.compactMap { $0 as? AirportAnnotation }
        let existingIds = Set(existingAirportAnnotations.map { $0.airport.id })
        let newIds = Set(airports.map { $0.id })

        let toRemove = existingAirportAnnotations.filter { !newIds.contains($0.airport.id) }
        mapView.removeAnnotations(toRemove)

        let toAdd = airports.filter { !existingIds.contains($0.id) }
        for airport in toAdd {
            let annotation = AirportAnnotation(airport: airport)
            mapView.addAnnotation(annotation)
        }
    }

    private func configureMapLayer(_ mapView: MKMapView) {
        // Remove existing tile overlays
        let existingTileOverlays = mapView.overlays.compactMap { $0 as? MKTileOverlay }
        mapView.removeOverlays(existingTileOverlays)

        switch mapLayer {
        case .apple:
            mapView.mapType = .standard

        case .icao:
            mapView.mapType = .standard
            let overlay = ICAOSegelflugkarteTileOverlay()
            overlay.canReplaceMapContent = true
            mapView.addOverlay(overlay, level: .aboveLabels)

        case .swissimage:
            mapView.mapType = .standard
            let overlay = SwisstopoTileOverlay(
                layerIdentifier: "ch.swisstopo.swissimage",
                tileExtension: "jpeg"
            )
            overlay.canReplaceMapContent = true
            mapView.addOverlay(overlay, level: .aboveLabels)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: WaypointPickerMapViewRepresentable
        var currentLayer: WaypointPickerMapLayer
        var isUserInteracting = false

        init(_ parent: WaypointPickerMapViewRepresentable) {
            self.parent = parent
            self.currentLayer = parent.mapLayer
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            if let gestureRecognizers = mapView.subviews.first?.gestureRecognizers {
                for recognizer in gestureRecognizers {
                    if recognizer.state == .began || recognizer.state == .changed {
                        isUserInteracting = true
                        return
                    }
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            isUserInteracting = false
            parent.region = mapView.region
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is AirportAnnotation else { return nil }

            let identifier = "WaypointPickerAirport"
            let annotationView: MKAnnotationView

            if let reusedView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) {
                reusedView.annotation = annotation
                annotationView = reusedView
            } else {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            }

            annotationView.canShowCallout = true

            let size: CGFloat = 14
            let config = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
            let color = UIColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.9)
            if let image = UIImage(systemName: "airplane", withConfiguration: config) {
                annotationView.image = image.withTintColor(color, renderingMode: .alwaysOriginal)
            }

            // Add a tap button as right callout accessory to add to route
            let addButton = UIButton(type: .contactAdd)
            annotationView.rightCalloutAccessoryView = addButton

            return annotationView
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            guard let airportAnnotation = view.annotation as? AirportAnnotation else { return }
            parent.onAirportTapped?(airportAnnotation.airport)
        }
    }
}

// MARK: - Export Sheet

struct FlightPlanExportSheet: View {
    @Environment(\.dismiss) var dismiss

    let data: Data
    let filename: String
    let format: FlightPlanExportFormat

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: iconName)
                    .font(.system(size: 60))
                    .foregroundColor(.aviationGold)

                Text(L10n.Nav.exportReady)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primaryText)

                Text("\(fullFilename)")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.secondaryText)

                Text(formattedSize)
                    .font(.system(size: 12))
                    .foregroundColor(.dimText)

                ShareLink(item: exportFile, preview: SharePreview(filename, icon: iconName)) {
                    Label(L10n.Nav.share, systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .tint(.aviationGold)
                .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.cockpitBackground)
            .navigationTitle(L10n.Nav.exportFlightPlan)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.done) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var iconName: String {
        switch format {
        case .json: return "doc.text"
        case .xlsx: return "tablecells"
        case .pdf: return "doc.richtext"
        case .gpx: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    private var fullFilename: String {
        "\(filename).\(format.fileExtension)"
    }

    private var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(data.count))
    }

    private var exportFile: ExportFile {
        ExportFile(data: data, filename: fullFilename, contentType: format.contentType)
    }
}

/// Transferable file for sharing
struct ExportFile: Transferable {
    let data: Data
    let filename: String
    let contentType: UTType

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .data) { file in
            file.data
        }
        .suggestedFileName { $0.filename }
    }
}

// MARK: - ICAO Search Sheet

/// Sheet for searching and adding airports by ICAO code
struct ICAOSearchSheet: View {
    @Environment(\.dismiss) var dismiss
    let airportDataService: AirportDataService
    let onSelect: (Airport, String?) -> Void  // (airport, primaryFrequency)

    @State private var searchText: String = ""
    @State private var searchResults: [Airport] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                searchContent
            }
            .background(Color.cockpitBackground)
            .navigationTitle(L10n.Nav.addWithICAO)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: searchText) { _, newValue in
            updateSearchResults(query: newValue)
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondaryText)
            TextField(L10n.Nav.icaoSearchPlaceholder, text: $searchText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        }
        .padding(12)
        .background(Color.panelBackground)
        .cornerRadius(10)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var searchContent: some View {
        if searchResults.isEmpty && !searchText.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundColor(.dimText)
                Text(L10n.Nav.noAirportsFound)
                    .font(.bodyText)
                    .foregroundColor(.dimText)
            }
            Spacer()
        } else if searchResults.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "airplane")
                    .font(.system(size: 40))
                    .foregroundColor(.dimText)
                Text(L10n.Nav.icaoSearchHint)
                    .font(.bodyText)
                    .foregroundColor(.dimText)
                    .multilineTextAlignment(.center)
            }
            .padding()
            Spacer()
        } else {
            airportResultsList
        }
    }

    private var airportResultsList: some View {
        List {
            ForEach(Array(searchResults), id: \.id) { airport in
                Button {
                    selectAirport(airport)
                } label: {
                    airportRow(airport)
                }
                .listRowBackground(Color.panelBackground)
            }
        }
        .listStyle(.plain)
    }

    private func airportRow(_ airport: Airport) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(airport.ident)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.primaryText)
                Text(airport.name)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
            }
            Spacer()
            Text(airport.type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.caption2)
                .foregroundColor(.dimText)
        }
    }

    private func updateSearchResults(query: String) {
        guard query.count >= 2 else {
            searchResults = []
            return
        }
        searchResults = airportDataService.searchAirports(query: query, limit: 30)
    }

    private func selectAirport(_ airport: Airport) {
        let frequencies = airportDataService.getFrequencies(for: airport.ident)
        // Extract just the frequency number for the waypoint field
        let freqValue: String? = {
            let priorityTypes = ["TWR", "ATIS", "APP", "GND"]
            for type in priorityTypes {
                if let freq = frequencies.first(where: { $0.type.uppercased().contains(type) }) {
                    return freq.formattedFrequency
                }
            }
            return frequencies.first?.formattedFrequency
        }()
        onSelect(airport, freqValue)
        dismiss()
    }
}

// MARK: - Airspace Conflict Detail Sheet

/// Shows detailed list of airspace conflicts along a flight plan route
struct AirspaceConflictDetailSheet: View {
    let conflicts: [AirspaceConflict]
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            // Severity indicator
                            Circle()
                                .fill(severityColor(conflict.severity))
                                .frame(width: 10, height: 10)

                            Text(conflict.airspace.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.primaryText)
                        }

                        HStack(spacing: 16) {
                            Label(conflict.airspace.typeDisplayString, systemImage: "shield")
                                .font(.system(size: 13))
                                .foregroundColor(.secondaryText)

                            Text(L10n.Nav.legNumber(conflict.legIndex + 1))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondaryText)
                        }

                        HStack(spacing: 12) {
                            Text("\(conflict.airspace.lowerCeiling.displayString) → \(conflict.airspace.upperCeiling.displayString)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.dimText)

                            Spacer()

                            Text(conflict.conflictType.displayString)
                                .font(.system(size: 12))
                                .foregroundColor(severityColor(conflict.severity))
                        }

                        if conflict.altitudeUncertain {
                            Label(L10n.Nav.airspaceAltitudeUncertain, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.aviationAmber)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.panelBackground)
                }
            }
            .listStyle(.plain)
            .background(Color.cockpitBackground)
            .navigationTitle(L10n.Nav.airspaceConflictsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.done) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func severityColor(_ severity: AirspaceConflict.ConflictSeverity) -> Color {
        switch severity {
        case .high: return .aviationRed
        case .medium: return .aviationAmber
        case .low: return .aviationGold
        }
    }
}

// MARK: - Preview

#Preview {
    FlightPlanEditorView(flightPlan: FlightPlan(name: "Test Flight"))
        .environmentObject(AppState())
        .environmentObject(FlightPlanManager())
        .environmentObject(AirportDataService())
        .environmentObject(OpenAIPDataService())
}
