import SwiftUI
import MapKit
import UniformTypeIdentifiers

/// Export format options
enum FlightPlanExportFormat {
    case json
    case xlsx
    case pdf

    var fileExtension: String {
        switch self {
        case .json: return "json"
        case .xlsx: return "xlsx"
        case .pdf: return "pdf"
        }
    }

    var contentType: UTType {
        switch self {
        case .json: return .json
        case .xlsx: return .spreadsheet
        case .pdf: return .pdf
        }
    }
}

/// Flight plan editor view - tabular format similar to "AVIS DE VOL" form
struct FlightPlanEditorView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @Environment(\.dismiss) var dismiss

    @State private var flightPlan: FlightPlan
    @State private var showingWaypointEditor: FlightPlanWaypoint?
    @State private var showingAddWaypoint = false
    @State private var showingTerrainProfile = false
    @State private var showingMapPicker = false
    @State private var showingExportSheet = false
    @State private var exportData: Data?
    @State private var exportFormat: FlightPlanExportFormat = .json

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
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Header section
                    headerSection

                    // Route table section
                    routeSection

                    // Fuel calculation section
                    fuelSection

                    // Timing section
                    timingSection

                    // Notes section
                    notesSection

                    // Actions section
                    actionsSection
                }
                .padding()
                // Add keyboard padding only when needed (handled by system)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.cockpitBackground)
            .navigationTitle(flightPlan.name.isEmpty ? "Flight Plan" : flightPlan.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAndDismiss()
                    }
                }
            }
            .sheet(item: $showingWaypointEditor) { waypoint in
                WaypointEditorSheet(
                    waypoint: waypoint,
                    aircraftType: flightPlan.aircraftType
                ) { updatedWaypoint in
                    updateWaypoint(updatedWaypoint)
                }
            }
            .sheet(isPresented: $showingAddWaypoint) {
                AddWaypointSheet(aircraftType: flightPlan.aircraftType) { newWaypoint in
                    addWaypoint(newWaypoint)
                }
            }
            .sheet(isPresented: $showingTerrainProfile) {
                TerrainProfileView(waypoints: flightPlan.waypoints)
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showingMapPicker) {
                MapWaypointPickerView { coordinate, name in
                    let waypoint = FlightPlanWaypoint(
                        name: name,
                        coordinate: coordinate,
                        plannedGroundSpeed: FlightPlan.defaultCruiseSpeed(for: flightPlan.aircraftType)
                    )
                    addWaypoint(waypoint)
                }
            }
            .sheet(isPresented: $showingExportSheet) {
                if let data = exportData {
                    FlightPlanExportSheet(
                        data: data,
                        filename: flightPlan.exportFilename,
                        format: exportFormat
                    )
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 16) {
            // Title bar
            HStack {
                Text("NAVIGATION FLIGHT PLAN")
                    .font(.system(size: isCompactWidth ? 12 : 14, weight: .bold))
                    .foregroundColor(.aviationGold)
                    .tracking(1)

                Spacer()

                HStack(spacing: 8) {
                    Text("Flight Type")
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
                    FormField(label: "Pilot", text: $flightPlan.pilot)
                    FormField(label: "Aircraft", text: .constant(flightPlan.aircraftRegistration), isReadOnly: true)
                    DateFormField(label: "Date", date: Binding(
                        get: { flightPlan.plannedDepartureTime ?? Date() },
                        set: { flightPlan.plannedDepartureTime = $0 }
                    ))
                    OptionalFormField(label: "Runway", text: $flightPlan.runwayInUse, keyboardType: .numberPad)
                    OptionalFormField(label: "Instructor", text: $flightPlan.instructor)
                    FormField(label: "Total EET", text: .constant(flightPlan.formattedTotalEET), isReadOnly: true)
                    FormField(label: "Distance", text: .constant(String(format: "%.1f NM", flightPlan.totalDistance)), isReadOnly: true)
                    FormField(label: "Endurance", text: .constant(flightPlan.formattedEndurance ?? "--:--"), isReadOnly: true)
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
                    FormField(label: "Pilot", text: $flightPlan.pilot)
                    FormField(label: "Aircraft", text: .constant(flightPlan.aircraftRegistration), isReadOnly: true)
                    DateFormField(label: "Date", date: Binding(
                        get: { flightPlan.plannedDepartureTime ?? Date() },
                        set: { flightPlan.plannedDepartureTime = $0 }
                    ))
                    OptionalFormField(label: "Runway", text: $flightPlan.runwayInUse, keyboardType: .numberPad)

                    // Row 2
                    OptionalFormField(label: "Instructor", text: $flightPlan.instructor)
                    FormField(label: "Total EET", text: .constant(flightPlan.formattedTotalEET), isReadOnly: true)
                    FormField(label: "Distance", text: .constant(String(format: "%.1f NM", flightPlan.totalDistance)), isReadOnly: true)
                    FormField(label: "Endurance", text: .constant(flightPlan.formattedEndurance ?? "--:--"), isReadOnly: true)
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
                Label("Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.aviationGold)

                Spacer()

                Button(action: { showingTerrainProfile = true }) {
                    Label("Terrain", systemImage: "mountain.2")
                        .font(.system(size: 12))
                }
                .disabled(flightPlan.waypoints.count < 2)

                Menu {
                    Button(action: { showingAddWaypoint = true }) {
                        Label("Add Waypoint Manually", systemImage: "plus")
                    }
                    Button(action: { showingMapPicker = true }) {
                        Label("Add from Map", systemImage: "map")
                    }
                } label: {
                    Label("Add", systemImage: "plus.circle")
                        .font(.system(size: 12))
                }
            }

            // Route table
            if flightPlan.waypoints.isEmpty {
                emptyRouteView
            } else {
                routeTable
            }
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

            Text("No waypoints added")
                .font(.system(size: 14))
                .foregroundColor(.secondaryText)

            Button(action: { showingAddWaypoint = true }) {
                Label("Add First Waypoint", systemImage: "plus")
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
                // iPad: Original implementation - flexible waypoint column, standard styling
                VStack(spacing: 0) {
                    // Table header
                    HStack(spacing: 0) {
                        tableHeaderCell("#", width: 30)
                        tableHeaderCell("Waypoint", width: nil, alignment: .leading)
                        tableHeaderCell("Freq", width: 55)
                        tableHeaderCell("MC", width: 50)
                        tableHeaderCell("Dist", width: 50)
                        tableHeaderCell("Alt", width: 60)
                        tableHeaderCell("GS", width: 50)
                        tableHeaderCell("EET", width: 50)
                        tableHeaderCell("ETO", width: 55)
                        tableHeaderCell("ATO", width: 55)
                    }
                    .background(Color.aviationDarkBlue)

                    // Table rows
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
                    }
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
                tableHeaderCell("Waypoint", width: 100, alignment: .leading)
                tableHeaderCell("Freq", width: 55)
                tableHeaderCell("MC", width: 50)
                tableHeaderCell("Dist", width: 50)
                tableHeaderCell("Alt", width: 60)
                tableHeaderCell("GS", width: 50)
                tableHeaderCell("EET", width: 50)
                tableHeaderCell("ETO", width: 55)
                tableHeaderCell("ATO", width: 55)
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
                Label("Fuel Calculation", systemImage: "fuelpump")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.aviationGold)

                Spacer()
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: isCompactWidth ? 2 : 3), spacing: 12) {
                NumberFormField(
                    label: "Fuel Flow (L/h)",
                    value: Binding(
                        get: { flightPlan.fuelFlow ?? FlightPlan.defaultFuelFlow(for: flightPlan.aircraftType) },
                        set: { flightPlan.fuelFlow = $0 }
                    ),
                    format: "%.0f"
                )

                NumberFormField(
                    label: "Trip Fuel (L)",
                    value: Binding(
                        get: { flightPlan.tripFuel ?? 0 },
                        set: { flightPlan.tripFuel = $0 }
                    ),
                    format: "%.1f"
                )

                NumberFormField(
                    label: "Reserve (L)",
                    value: Binding(
                        get: { flightPlan.reserveFuel ?? 0 },
                        set: { flightPlan.reserveFuel = $0 }
                    ),
                    format: "%.1f"
                )

                NumberFormField(
                    label: "Additional 45' (L)",
                    value: Binding(
                        get: {
                            // Auto-populate with 45 minutes of fuel if not set
                            if let additional = flightPlan.additionalFuel, additional > 0 {
                                return additional
                            }
                            let fuelFlow = flightPlan.fuelFlow ?? FlightPlan.defaultFuelFlow(for: flightPlan.aircraftType)
                            return fuelFlow * 0.75 // 45 minutes = 0.75 hours
                        },
                        set: { flightPlan.additionalFuel = $0 }
                    ),
                    format: "%.1f"
                )

                NumberFormField(
                    label: "Extra (L)",
                    value: Binding(
                        get: { flightPlan.extraFuel ?? 0 },
                        set: { flightPlan.extraFuel = $0 }
                    ),
                    format: "%.1f"
                )

                FormField(
                    label: "Required (L)",
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
                Label("Timing", systemImage: "clock")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.aviationGold)

                Spacer()
            }

            // First row: Counter Start, Block OFF, Time OFF, Time ON, Block ON, Counter Stop
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: isCompactWidth ? 2 : 6), spacing: 12) {
                NumberFormField(
                    label: "Counter Start",
                    value: Binding(
                        get: { flightPlan.counterStart ?? 0 },
                        set: { flightPlan.counterStart = $0 }
                    ),
                    format: "%.1f"
                )

                OptionalTimeFormField(label: "Block OFF", time: $flightPlan.blockOff)
                OptionalTimeFormField(label: "Time OFF", time: $flightPlan.timeOff)
                OptionalTimeFormField(label: "Time ON", time: $flightPlan.timeOn)
                OptionalTimeFormField(label: "Block ON", time: $flightPlan.blockOn)

                NumberFormField(
                    label: "Counter Stop",
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
                    label: "Ldgs at Base",
                    value: Binding(
                        get: { flightPlan.landingsAtBase ?? 0 },
                        set: { flightPlan.landingsAtBase = $0 }
                    )
                )

                IntFormField(
                    label: "Total Ldgs",
                    value: Binding(
                        get: { calculatedTotalLandings },
                        set: { flightPlan.totalLandings = $0 }
                    )
                )

                // Engine Time display (MMMMM.ZZ format)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Engine Time")
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
                Label("Notes", systemImage: "note.text")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.aviationGold)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Remarks")
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
                Text("Debriefing")
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

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 12) {
            // Hide Activate/Deactivate and Recalculate buttons when viewing from Flight Log
            if !isViewingFromFlightLog {
                if flightPlan.id == flightPlanManager.activeFlightPlan?.id {
                    Button(action: {
                        flightPlanManager.deactivateFlightPlan()
                    }) {
                        Label("Deactivate Flight Plan", systemImage: "airplane.arrival")
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
                        Label("Activate Flight Plan", systemImage: "airplane.departure")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.aviationGreen)
                }

                Button(action: {
                    recalculateRoute()
                }) {
                    Label("Recalculate Route", systemImage: "arrow.triangle.2.circlepath")
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
            Text("Export Flight Plan")
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
        }
    }

    // MARK: - Computed Properties for Auto-Population

    /// Calculate Counter Stop based on Counter Start + Engine Time
    /// Engine Time = Block ON - Block OFF (when both are set)
    /// Block OFF = when plane starts moving (after engine start)
    /// Block ON = when plane stops moving (before engine shutdown)
    private var calculatedCounterStop: Double {
        // If explicitly set, use that value
        if let counterStop = flightPlan.counterStop, counterStop > 0 {
            return counterStop
        }

        // Otherwise, try to calculate from counter start + engine time
        guard let counterStart = flightPlan.counterStart,
              let blockOff = flightPlan.blockOff,
              let blockOn = flightPlan.blockOn else {
            return flightPlan.counterStop ?? 0
        }

        // Engine time in hours (Hobbs meter is in decimal hours)
        // Block ON happens after Block OFF, so this gives positive time
        let engineTimeSeconds = blockOn.timeIntervalSince(blockOff)
        let engineTimeHours = engineTimeSeconds / 3600.0

        return counterStart + engineTimeHours
    }

    /// Format engine time as MMMMM.ZZ (minutes with decimal 60ths)
    /// Example: 90.50 = 90 minutes and 30 seconds
    private var formattedEngineTime: String {
        guard let blockOff = flightPlan.blockOff,
              let blockOn = flightPlan.blockOn else {
            return "--"
        }

        let engineTimeSeconds = blockOn.timeIntervalSince(blockOff)
        if engineTimeSeconds < 0 { return "--" }

        let totalMinutes = Int(engineTimeSeconds / 60)
        let remainingSeconds = Int(engineTimeSeconds) % 60
        // Convert seconds to decimal 60ths (0-59 -> 0.00-0.98)
        let decimalSeconds = Double(remainingSeconds) / 60.0 * 100.0

        return String(format: "%d.%02d", totalMinutes, Int(decimalSeconds))
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
        // Generate the data first, before updating any state
        let generatedData: Data?
        switch format {
        case .json:
            generatedData = FlightPlanExportService.exportToJSON(flightPlan)
        case .xlsx:
            generatedData = FlightPlanExportService.exportToXLSX(flightPlan)
        case .pdf:
            generatedData = FlightPlanExportService.exportToPDF(flightPlan)
        }

        // Only proceed if data was generated successfully
        guard let data = generatedData else { return }

        // Update state synchronously in the correct order
        exportFormat = format
        exportData = data

        // Use a small delay to ensure state updates have propagated before showing sheet
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.showingExportSheet = true
        }
    }

    private func addWaypoint(_ waypoint: FlightPlanWaypoint) {
        var updatedPlan = flightPlan
        updatedPlan.waypoints.append(waypoint)
        updatedPlan.calculateRouteData()
        flightPlan = updatedPlan
    }

    private func updateWaypoint(_ waypoint: FlightPlanWaypoint) {
        if let index = flightPlan.waypoints.firstIndex(where: { $0.id == waypoint.id }) {
            var updatedPlan = flightPlan
            updatedPlan.waypoints[index] = waypoint
            updatedPlan.calculateRouteData()
            flightPlan = updatedPlan
        }
    }

    private func deleteWaypoint(at index: Int) {
        var updatedPlan = flightPlan
        updatedPlan.waypoints.remove(at: index)
        updatedPlan.calculateRouteData()
        flightPlan = updatedPlan
    }

    private func moveWaypoint(from source: Int, to destination: Int) {
        var updatedPlan = flightPlan
        let waypoint = updatedPlan.waypoints.remove(at: source)
        updatedPlan.waypoints.insert(waypoint, at: destination)
        updatedPlan.calculateRouteData()
        flightPlan = updatedPlan
    }

    private func recalculateRoute() {
        var updatedPlan = flightPlan
        updatedPlan.calculateRouteData()
        flightPlan = updatedPlan
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
                Text(waypoint.name.isEmpty ? "WPT\(index + 1)" : waypoint.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primaryText)
                    .lineLimit(1)
                    .frame(width: 100, alignment: .leading)
            } else {
                Text(waypoint.name.isEmpty ? "WPT\(index + 1)" : waypoint.name)
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
                Label("Edit", systemImage: "pencil")
            }

            if let moveUp = onMoveUp {
                Button(action: moveUp) {
                    Label("Move Up", systemImage: "arrow.up")
                }
            }

            if let moveDown = onMoveDown {
                Button(action: moveDown) {
                    Label("Move Down", systemImage: "arrow.down")
                }
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
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
                Text("Select Date")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primaryText)

                Spacer()

                Button("Done") {
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
                Text(isSet ? timeFormatter.string(from: selectedTime) : "Set")
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
                Text("Select Time")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primaryText)

                Spacer()

                Button("Done") {
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

    let aircraftType: AircraftType
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
        NavigationView {
            Form {
                Section {
                    TextField("Name (e.g., LSZQ, JORAT)", text: $name)

                    HStack {
                        TextField("Latitude", text: $latitude)
                            .keyboardType(.decimalPad)
                        TextField("Longitude", text: $longitude)
                            .keyboardType(.decimalPad)
                    }

                    TextField("Altitude (ft)", text: $altitude)
                        .keyboardType(.numberPad)

                    // Ground level display
                    HStack {
                        if isLoadingElevation {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading elevation...")
                                .foregroundColor(.secondaryText)
                                .font(.system(size: 12))
                        } else if let groundElevation = groundElevationMeters {
                            let groundFeet = groundElevation * 3.28084
                            Text("Ground level: \(Int(groundFeet)) ft")
                                .foregroundColor(.dimText)
                                .font(.system(size: 12))
                        }
                    }
                } header: {
                    Label("Location", systemImage: "mappin")
                } footer: {
                    if groundElevationMeters != nil {
                        Text("Default: 3000 ft AGL (above ground level)")
                    }
                }

                Section {
                    TextField("Frequency", text: $frequency)
                        .keyboardType(.decimalPad)

                    TextField("Remarks", text: $remarks)
                } header: {
                    Label("Details", systemImage: "info.circle")
                }
            }
            .navigationTitle("Add Waypoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
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
            name: name.isEmpty ? "WPT" : name,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: Double(altitude),
            frequency: frequency.isEmpty ? nil : frequency,
            remarks: remarks,
            plannedGroundSpeed: FlightPlan.defaultCruiseSpeed(for: aircraftType)
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

    let onSelect: (CLLocationCoordinate2D, String) -> Void

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.1, longitude: 7.1), // Default to Swiss Jura
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
    )
    @State private var waypointName: String = ""
    @State private var selectedLayer: WaypointPickerMapLayer = .apple

    var body: some View {
        NavigationView {
            ZStack {
                // Map view based on selected layer
                WaypointPickerMapViewRepresentable(
                    region: $region,
                    mapLayer: selectedLayer
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
                        Picker("Layer", selection: $selectedLayer) {
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
                        TextField("Waypoint Name", text: $waypointName)
                            .textFieldStyle(.roundedBorder)

                        Text("Lat: \(String(format: "%.4f", region.center.latitude))  Lon: \(String(format: "%.4f", region.center.longitude))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondaryText)

                        Button(action: {
                            onSelect(region.center, waypointName)
                            dismiss()
                        }) {
                            Text("Add Waypoint at Center")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.aviationGold)
                    }
                    .padding()
                    .background(Color.panelBackground.opacity(0.95))
                }
            }
            .navigationTitle("Select Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Waypoint Picker Map View Representable

struct WaypointPickerMapViewRepresentable: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let mapLayer: WaypointPickerMapLayer

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.setRegion(region, animated: false)
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.showsScale = true
        configureMapLayer(mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update layer if changed
        context.coordinator.currentLayer = mapLayer
        configureMapLayer(mapView)
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
            let overlay = WaypointPickerICAOTileOverlay()
            overlay.canReplaceMapContent = true
            mapView.addOverlay(overlay, level: .aboveLabels)

        case .swissimage:
            mapView.mapType = .standard
            let overlay = WaypointPickerSwisstopoTileOverlay(
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

        init(_ parent: WaypointPickerMapViewRepresentable) {
            self.parent = parent
            self.currentLayer = parent.mapLayer
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.region = mapView.region
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Waypoint Picker Tile Overlays

/// ICAO/Segelflugkarte tile overlay for waypoint picker
class WaypointPickerICAOTileOverlay: MKTileOverlay {
    private let icaoLayerIdentifier = "ch.bazl.luftfahrtkarten-icao"
    private let segelflugkarteLayerIdentifier = "ch.bazl.segelflugkarte"

    override init(urlTemplate URLTemplate: String?) {
        super.init(urlTemplate: "https://wmts.geo.admin.ch/1.0.0/ch.bazl.luftfahrtkarten-icao/default/current/3857/{z}/{x}/{y}.png")
        self.minimumZ = 7
        self.maximumZ = 14
    }

    convenience init() {
        self.init(urlTemplate: nil)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let layerIdentifier: String
        let finalZ: Int

        // ICAO for zoom 7-11, Segelflugkarte for zoom 11-14
        if path.z <= 11 {
            layerIdentifier = icaoLayerIdentifier
            finalZ = min(max(path.z, 7), 11)
        } else {
            layerIdentifier = segelflugkarteLayerIdentifier
            finalZ = min(max(path.z, 11), 14)
        }

        let urlString = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/\(finalZ)/\(path.x)/\(path.y).png"
        return URL(string: urlString) ?? URL(string: "about:blank")!
    }
}

/// SwissImage tile overlay for waypoint picker
class WaypointPickerSwisstopoTileOverlay: MKTileOverlay {
    let layerIdentifier: String
    let tileExtension: String

    init(layerIdentifier: String, tileExtension: String = "png") {
        self.layerIdentifier = layerIdentifier
        self.tileExtension = tileExtension

        let urlTemplate = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/{z}/{x}/{y}.\(tileExtension)"
        super.init(urlTemplate: urlTemplate)

        self.minimumZ = 7
        self.maximumZ = 18
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let clampedZ = min(max(path.z, 7), 18)
        let urlString = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/\(clampedZ)/\(path.x)/\(path.y).\(tileExtension)"
        return URL(string: urlString) ?? URL(string: "about:blank")!
    }
}

// MARK: - Export Sheet

struct FlightPlanExportSheet: View {
    @Environment(\.dismiss) var dismiss

    let data: Data
    let filename: String
    let format: FlightPlanExportFormat

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: iconName)
                    .font(.system(size: 60))
                    .foregroundColor(.aviationGold)

                Text("Export Ready")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primaryText)

                Text("\(fullFilename)")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.secondaryText)

                Text(formattedSize)
                    .font(.system(size: 12))
                    .foregroundColor(.dimText)

                ShareLink(item: exportFile, preview: SharePreview(filename, icon: iconName)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .tint(.aviationGold)
                .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.cockpitBackground)
            .navigationTitle("Export Flight Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
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

// MARK: - Preview

#Preview {
    FlightPlanEditorView(flightPlan: FlightPlan(name: "Test Flight"))
        .environmentObject(AppState())
        .environmentObject(FlightPlanManager())
}
