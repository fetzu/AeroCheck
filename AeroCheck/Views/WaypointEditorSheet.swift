import SwiftUI
import MapKit

/// Sheet for editing a single waypoint's details
struct WaypointEditorSheet: View {
    @Environment(\.dismiss) var dismiss

    @State private var waypoint: FlightPlanWaypoint
    let aircraftTypeId: String
    let onSave: (FlightPlanWaypoint) -> Void
    let onDelete: (() -> Void)?

    private let elevationService = ElevationService()

    init(waypoint: FlightPlanWaypoint, aircraftType aircraftTypeId: String, onSave: @escaping (FlightPlanWaypoint) -> Void, onDelete: (() -> Void)? = nil) {
        _waypoint = State(initialValue: waypoint)
        self.aircraftTypeId = aircraftTypeId
        self.onSave = onSave
        self.onDelete = onDelete
    }

    @State private var showingDeleteConfirmation = false

    // Local state for form fields
    @State private var name: String = ""
    @State private var latitudeString: String = ""
    @State private var longitudeString: String = ""
    @State private var altitudeString: String = ""
    @State private var frequency: String = ""
    @State private var callSign: String = ""
    @State private var remarks: String = ""
    @State private var groundSpeedString: String = ""
    @State private var windDirectionString: String = ""
    @State private var windSpeedString: String = ""

    @State private var showingMapPicker = false
    @State private var groundElevationMeters: Double?
    @State private var isLoadingElevation = false

    var body: some View {
        NavigationStack {
            Form {
                // Location section
                Section {
                    TextField(L10n.Nav.waypointNamePlaceholder, text: $name)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Nav.latitude)
                                .font(.system(size: 11))
                                .foregroundColor(.secondaryText)
                            TextField("46.0000", text: $latitudeString)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 14, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Nav.longitude)
                                .font(.system(size: 11))
                                .foregroundColor(.secondaryText)
                            TextField("7.0000", text: $longitudeString)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 14, design: .monospaced))
                        }
                    }

                    Button(action: { showingMapPicker = true }) {
                        Label(L10n.Nav.selectOnMap, systemImage: "map")
                    }

                    // Mini map preview
                    if let lat = Double(latitudeString), let lon = Double(longitudeString) {
                        MiniMapPreview(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } header: {
                    Label(L10n.Nav.location, systemImage: "mappin.and.ellipse")
                } footer: {
                    Text(L10n.Nav.coordinatesHelp)
                }

                // Altitude section
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Nav.plannedAltitude)
                                .font(.system(size: 11))
                                .foregroundColor(.secondaryText)
                            TextField("5000", text: $altitudeString)
                                .keyboardType(.numberPad)
                                .font(.system(size: 14, design: .monospaced))
                        }

                        Text(L10n.Unit.ft)
                            .foregroundColor(.secondaryText)
                    }

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
                        } else {
                            Text(L10n.Nav.groundLevelNA)
                                .foregroundColor(.dimText)
                                .font(.system(size: 12))
                        }
                    }
                } header: {
                    Label(L10n.Nav.altitude, systemImage: "arrow.up.and.down")
                } footer: {
                    if groundElevationMeters != nil {
                        Text(L10n.Nav.defaultAGL)
                    }
                }

                // Navigation section
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Nav.groundSpeed)
                                .font(.system(size: 11))
                                .foregroundColor(.secondaryText)
                            TextField("\(FlightPlan.defaultCruiseSpeed(for: aircraftTypeId))", text: $groundSpeedString)
                                .keyboardType(.numberPad)
                                .font(.system(size: 14, design: .monospaced))
                        }

                        Text(L10n.Unit.kt)
                            .foregroundColor(.secondaryText)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Nav.windDirection)
                                .font(.system(size: 11))
                                .foregroundColor(.secondaryText)
                            TextField("270", text: $windDirectionString)
                                .keyboardType(.numberPad)
                                .font(.system(size: 14, design: .monospaced))
                        }

                        Text("°")
                            .foregroundColor(.secondaryText)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Nav.windSpeed)
                                .font(.system(size: 11))
                                .foregroundColor(.secondaryText)
                            TextField("10", text: $windSpeedString)
                                .keyboardType(.numberPad)
                                .font(.system(size: 14, design: .monospaced))
                        }

                        Text(L10n.Unit.kt)
                            .foregroundColor(.secondaryText)
                    }

                    // Computed values (read-only)
                    if let mc = waypoint.magneticCourse {
                        HStack {
                            Text(L10n.Nav.magneticCourse)
                                .foregroundColor(.secondaryText)
                            Spacer()
                            Text(String(format: "%03d°", Int(mc)))
                                .font(.system(size: 14, design: .monospaced))
                        }
                    }

                    if let distance = waypoint.distance {
                        HStack {
                            Text(L10n.Nav.distanceToNext)
                                .foregroundColor(.secondaryText)
                            Spacer()
                            Text(String(format: "%.1f NM", distance))
                                .font(.system(size: 14, design: .monospaced))
                        }
                    }
                } header: {
                    Label(L10n.Nav.navigation, systemImage: "location.north.line")
                } footer: {
                    Text(L10n.Nav.navigationHelp)
                }

                // Radio section
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Nav.frequency)
                            .font(.system(size: 11))
                            .foregroundColor(.secondaryText)
                        TextField("118.100", text: $frequency)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 14, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Nav.callsign)
                            .font(.system(size: 11))
                            .foregroundColor(.secondaryText)
                        TextField("e.g., PORRENTRUY INFO", text: $callSign)
                            .font(.system(size: 14))
                    }
                } header: {
                    Label(L10n.Nav.radio, systemImage: "antenna.radiowaves.left.and.right")
                }

                // Remarks section
                Section {
                    TextEditor(text: $remarks)
                        .frame(minHeight: 80)
                        .font(.system(size: 14))
                } header: {
                    Label(L10n.Nav.remarks, systemImage: "note.text")
                }

                // Timing section (read-only computed values)
                if waypoint.estimatedElapsedTime != nil || waypoint.estimatedTimeOver != nil {
                    Section {
                        if let eet = waypoint.formattedEET {
                            HStack {
                                Text(L10n.Nav.eetFromDeparture)
                                    .foregroundColor(.secondaryText)
                                Spacer()
                                Text(eet)
                                    .font(.system(size: 14, design: .monospaced))
                            }
                        }

                        if let eto = waypoint.formattedETO {
                            HStack {
                                Text(L10n.Nav.eto)
                                    .foregroundColor(.secondaryText)
                                Spacer()
                                Text(eto)
                                    .font(.system(size: 14, design: .monospaced))
                            }
                        }

                        if let ato = waypoint.formattedATO {
                            HStack {
                                Text(L10n.Nav.atoRecorded)
                                    .foregroundColor(.secondaryText)
                                Spacer()
                                Text(ato)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(.aviationGreen)
                            }
                        }
                    } header: {
                        Label(L10n.Nav.timing, systemImage: "clock")
                    }
                }

                // Delete section - only shown when onDelete callback is provided
                if onDelete != nil {
                    Section {
                        Button(role: .destructive, action: {
                            showingDeleteConfirmation = true
                        }) {
                            HStack {
                                Spacer()
                                Image(systemName: "trash")
                                Text(L10n.Nav.deleteWaypoint)
                                Spacer()
                            }
                            .foregroundColor(.red)
                        }
                    }
                }
            }
            .confirmationDialog(
                L10n.Nav.deleteWaypoint,
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.Button.delete, role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button(L10n.Button.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Nav.deleteWaypointConfirmation)
            }
            .navigationTitle(L10n.Nav.editWaypoint)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Nav.save) {
                        saveWaypoint()
                    }
                    .disabled(latitudeString.isEmpty || longitudeString.isEmpty)
                }
            }
            .onAppear {
                loadWaypointData()
            }
            .task {
                await fetchGroundElevation()
            }
            .onChange(of: latitudeString) { _, _ in
                Task { await fetchGroundElevation() }
            }
            .onChange(of: longitudeString) { _, _ in
                Task { await fetchGroundElevation() }
            }
            .sheet(isPresented: $showingMapPicker) {
                CoordinatePickerView(
                    initialCoordinate: CLLocationCoordinate2D(
                        latitude: Double(latitudeString) ?? 47.0,
                        longitude: Double(longitudeString) ?? 7.0
                    )
                ) { coordinate in
                    latitudeString = String(format: "%.6f", coordinate.latitude)
                    longitudeString = String(format: "%.6f", coordinate.longitude)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func loadWaypointData() {
        name = waypoint.name
        latitudeString = String(format: "%.6f", waypoint.latitude)
        longitudeString = String(format: "%.6f", waypoint.longitude)
        altitudeString = waypoint.altitude.map { String(format: "%.0f", $0) } ?? ""
        frequency = waypoint.frequency ?? ""
        callSign = waypoint.callSign ?? ""
        remarks = waypoint.remarks
        groundSpeedString = waypoint.plannedGroundSpeed.map { "\($0)" } ?? "\(FlightPlan.defaultCruiseSpeed(for: aircraftTypeId))"
        windDirectionString = waypoint.windDirection.map { String(format: "%.0f", $0) } ?? ""
        windSpeedString = waypoint.windSpeed.map { String(format: "%.0f", $0) } ?? ""
    }

    private func fetchGroundElevation() async {
        guard let lat = Double(latitudeString),
              let lon = Double(longitudeString) else {
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
            if altitudeString.isEmpty {
                let defaultAltitude = (elevation * 3.28084) + 3000 // Convert meters to feet and add 3000
                altitudeString = String(format: "%.0f", defaultAltitude)
            }
        } else {
            groundElevationMeters = nil
        }

        isLoadingElevation = false
    }

    private func saveWaypoint() {
        guard let lat = Double(latitudeString),
              let lon = Double(longitudeString) else { return }

        var updatedWaypoint = waypoint
        updatedWaypoint.name = name
        updatedWaypoint.latitude = lat
        updatedWaypoint.longitude = lon
        updatedWaypoint.altitude = Double(altitudeString)
        updatedWaypoint.frequency = frequency.isEmpty ? nil : frequency
        updatedWaypoint.callSign = callSign.isEmpty ? nil : callSign
        updatedWaypoint.remarks = remarks
        updatedWaypoint.plannedGroundSpeed = Int(groundSpeedString)
        updatedWaypoint.windDirection = Double(windDirectionString)
        updatedWaypoint.windSpeed = Double(windSpeedString)

        onSave(updatedWaypoint)
        dismiss()
    }
}

// MARK: - Mini Map Preview

struct MiniMapPreview: View {
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        Map(position: .constant(.region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        ))), interactionModes: []) {
            Marker("", coordinate: coordinate)
                .tint(Color.aviationGold)
        }
    }
}

// MARK: - Coordinate Picker View

struct CoordinatePickerView: View {
    @Environment(\.dismiss) var dismiss

    let initialCoordinate: CLLocationCoordinate2D
    let onSelect: (CLLocationCoordinate2D) -> Void

    @State private var region: MKCoordinateRegion
    @State private var selectedLayer: WaypointPickerMapLayer = .apple

    init(initialCoordinate: CLLocationCoordinate2D, onSelect: @escaping (CLLocationCoordinate2D) -> Void) {
        self.initialCoordinate = initialCoordinate
        self.onSelect = onSelect
        let initialRegion = MKCoordinateRegion(
            center: initialCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
        )
        _region = State(initialValue: initialRegion)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WaypointPickerMapViewRepresentable(
                    region: $region,
                    mapLayer: selectedLayer,
                    airports: [],
                    onAirportTapped: nil
                )
                .ignoresSafeArea()

                // Crosshair
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "plus")
                            .font(.system(size: 30, weight: .light))
                            .foregroundColor(.aviationGold)
                            .shadow(color: .black, radius: 2)
                        Spacer()
                    }
                    Spacer()
                }

                // Layer selector at top-right
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

                // Coordinate display
                VStack {
                    Spacer()

                    VStack(spacing: 8) {
                        Text(L10n.Nav.selectedCoordinates)
                            .font(.system(size: 12))
                            .foregroundColor(.secondaryText)

                        HStack(spacing: 16) {
                            VStack {
                                Text("LAT")
                                    .font(.system(size: 10))
                                    .foregroundColor(.dimText)
                                Text(String(format: "%.6f", region.center.latitude))
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                            }

                            VStack {
                                Text("LON")
                                    .font(.system(size: 10))
                                    .foregroundColor(.dimText)
                                Text(String(format: "%.6f", region.center.longitude))
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                            }
                        }

                        Button(action: {
                            onSelect(region.center)
                            dismiss()
                        }) {
                            Text(L10n.Nav.useThisLocation)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.aviationGold)
                                )
                        }
                    }
                    .padding()
                    .background(Color.panelBackground.opacity(0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding()
                }
            }
            .navigationTitle(L10n.Nav.selectLocation)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Preview

#Preview {
    WaypointEditorSheet(
        waypoint: FlightPlanWaypoint(
            name: "LSZQ",
            coordinate: CLLocationCoordinate2D(latitude: 47.1, longitude: 7.1),
            altitude: 5000
        ),
        aircraftType: "WT9",
        onSave: { _ in },
        onDelete: { print("Delete tapped") }
    )
}
