import SwiftUI
import MapKit

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

    init(flightPlan: FlightPlan) {
        _flightPlan = State(initialValue: flightPlan)
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
            }
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
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 16) {
            // Title bar
            HStack {
                Text("NAVIGATION FLIGHT PLAN")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.aviationGold)
                    .tracking(1)

                Spacer()

                HStack(spacing: 8) {
                    Text("Flight Type")
                        .font(.system(size: 12))
                        .foregroundColor(.secondaryText)

                    Picker("", selection: $flightPlan.flightType) {
                        ForEach(FlightType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.aviationGold)
                }
            }

            // Main header grid
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
                FormField(label: "Runway", text: Binding(
                    get: { flightPlan.runwayInUse ?? "" },
                    set: { flightPlan.runwayInUse = $0.isEmpty ? nil : $0 }
                ))

                // Row 2
                FormField(label: "Instructor", text: Binding(
                    get: { flightPlan.instructor ?? "" },
                    set: { flightPlan.instructor = $0.isEmpty ? nil : $0 }
                ))
                FormField(label: "Total EET", text: .constant(flightPlan.formattedTotalEET), isReadOnly: true)
                FormField(label: "Distance", text: .constant(String(format: "%.1f NM", flightPlan.totalDistance)), isReadOnly: true)
                FormField(label: "Endurance", text: .constant(flightPlan.formattedEndurance ?? "--:--"), isReadOnly: true)
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
        VStack(spacing: 0) {
            // Table header
            HStack(spacing: 0) {
                tableHeaderCell("#", width: 30)
                tableHeaderCell("Waypoint", width: nil, alignment: .leading)
                tableHeaderCell("MC", width: 50)
                tableHeaderCell("Dist", width: 50)
                tableHeaderCell("Alt", width: 60)
                tableHeaderCell("GS", width: 50)
                tableHeaderCell("EET", width: 50)
                tableHeaderCell("ETO", width: 60)
            }
            .background(Color.aviationDarkBlue)

            // Table rows
            ForEach(Array(flightPlan.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                WaypointTableRow(
                    index: index,
                    waypoint: waypoint,
                    isLast: index == flightPlan.waypoints.count - 1,
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

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
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
                        get: { flightPlan.additionalFuel ?? 0 },
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

                NumberFormField(
                    label: "FOB (L)",
                    value: Binding(
                        get: { flightPlan.fuelOnBoard ?? 0 },
                        set: { flightPlan.fuelOnBoard = $0 }
                    ),
                    format: "%.0f"
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

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                OptionalTimeFormField(label: "Block OFF", time: $flightPlan.blockOff)
                OptionalTimeFormField(label: "Time OFF", time: $flightPlan.timeOff)
                OptionalTimeFormField(label: "Time ON", time: $flightPlan.timeOn)
                OptionalTimeFormField(label: "Block ON", time: $flightPlan.blockOn)

                NumberFormField(
                    label: "Counter Start",
                    value: Binding(
                        get: { flightPlan.counterStart ?? 0 },
                        set: { flightPlan.counterStart = $0 }
                    ),
                    format: "%.1f"
                )

                NumberFormField(
                    label: "Counter Stop",
                    value: Binding(
                        get: { flightPlan.counterStop ?? 0 },
                        set: { flightPlan.counterStop = $0 }
                    ),
                    format: "%.1f"
                )

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
                        get: { flightPlan.totalLandings ?? 0 },
                        set: { flightPlan.totalLandings = $0 }
                    )
                )
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
        }
        .padding()
    }

    // MARK: - Actions

    private func saveAndDismiss() {
        flightPlan.calculateRouteData()
        flightPlanManager.updateFlightPlan(flightPlan)
        dismiss()
    }

    private func addWaypoint(_ waypoint: FlightPlanWaypoint) {
        flightPlan.waypoints.append(waypoint)
        flightPlan.calculateRouteData()
    }

    private func updateWaypoint(_ waypoint: FlightPlanWaypoint) {
        if let index = flightPlan.waypoints.firstIndex(where: { $0.id == waypoint.id }) {
            flightPlan.waypoints[index] = waypoint
            flightPlan.calculateRouteData()
        }
    }

    private func deleteWaypoint(at index: Int) {
        flightPlan.waypoints.remove(at: index)
        flightPlan.calculateRouteData()
    }

    private func moveWaypoint(from source: Int, to destination: Int) {
        let waypoint = flightPlan.waypoints.remove(at: source)
        flightPlan.waypoints.insert(waypoint, at: destination)
        flightPlan.calculateRouteData()
    }

    private func recalculateRoute() {
        flightPlan.calculateRouteData()
    }
}

// MARK: - Waypoint Table Row

struct WaypointTableRow: View {
    let index: Int
    let waypoint: FlightPlanWaypoint
    let isLast: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            // Index
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.dimText)
                .frame(width: 30)

            // Waypoint name
            Text(waypoint.name.isEmpty ? "WPT\(index + 1)" : waypoint.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            // MC (Magnetic Course)
            Text(waypoint.magneticCourse.map { String(format: "%03d°", Int($0)) } ?? "-")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primaryText)
                .frame(width: 50)

            // Distance
            Text(waypoint.distance.map { String(format: "%.1f", $0) } ?? "-")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primaryText)
                .frame(width: 50)

            // Altitude
            Text(waypoint.altitude.map { String(format: "%.0f", $0) } ?? "-")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primaryText)
                .frame(width: 60)

            // Ground Speed
            Text(waypoint.plannedGroundSpeed.map { "\($0)" } ?? "-")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primaryText)
                .frame(width: 50)

            // EET
            Text(waypoint.formattedEET ?? "-")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primaryText)
                .frame(width: 50)

            // ETO
            Text(waypoint.formattedETO ?? "-")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primaryText)
                .frame(width: 60)
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

struct DateFormField: View {
    let label: String
    @Binding var date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondaryText)

            DatePicker("", selection: $date, displayedComponents: [.date])
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(.aviationGold)
        }
    }
}

struct OptionalTimeFormField: View {
    let label: String
    @Binding var time: Date?

    @State private var isSet: Bool = false
    @State private var selectedTime: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondaryText)

            HStack {
                if isSet {
                    DatePicker("", selection: $selectedTime, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .tint(.aviationGold)
                        .onChange(of: selectedTime) { _, newValue in
                            time = newValue
                        }

                    Button(action: {
                        isSet = false
                        time = nil
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.dimText)
                    }
                } else {
                    Button(action: {
                        selectedTime = Date()
                        time = selectedTime
                        isSet = true
                    }) {
                        Text("Set")
                            .font(.system(size: 12))
                            .foregroundColor(.aviationGold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
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

    @State private var name: String = ""
    @State private var latitude: String = ""
    @State private var longitude: String = ""
    @State private var altitude: String = ""
    @State private var frequency: String = ""
    @State private var remarks: String = ""

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
                } header: {
                    Label("Location", systemImage: "mappin")
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
        }
        .preferredColorScheme(.dark)
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

// MARK: - Map Waypoint Picker

struct MapWaypointPickerView: View {
    @Environment(\.dismiss) var dismiss

    let onSelect: (CLLocationCoordinate2D, String) -> Void

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.1, longitude: 7.1), // Default to Swiss Jura
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
    )
    @State private var cameraPosition: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.1, longitude: 7.1),
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
    ))
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var waypointName: String = ""

    var body: some View {
        NavigationView {
            ZStack {
                Map(position: $cameraPosition, interactionModes: .all) {
                }
                .ignoresSafeArea()
                .onMapCameraChange { context in
                    region = context.region
                }

                // Crosshair at center
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(.aviationGold)

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

// MARK: - Preview

#Preview {
    FlightPlanEditorView(flightPlan: FlightPlan(name: "Test Flight"))
        .environmentObject(AppState())
        .environmentObject(FlightPlanManager())
}
