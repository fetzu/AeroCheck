import SwiftUI
import MapKit

/// Sheet for editing a single waypoint's details
struct WaypointEditorSheet: View {
    @Environment(\.dismiss) var dismiss

    @State private var waypoint: FlightPlanWaypoint
    let aircraftType: AircraftType
    let onSave: (FlightPlanWaypoint) -> Void

    init(waypoint: FlightPlanWaypoint, aircraftType: AircraftType, onSave: @escaping (FlightPlanWaypoint) -> Void) {
        _waypoint = State(initialValue: waypoint)
        self.aircraftType = aircraftType
        self.onSave = onSave
    }

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

    var body: some View {
        NavigationView {
            Form {
                // Location section
                Section {
                    TextField("Name (e.g., LSZQ, JORAT VOR)", text: $name)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Latitude")
                                .font(.system(size: 11))
                                .foregroundColor(.secondaryText)
                            TextField("46.0000", text: $latitudeString)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 14, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Longitude")
                                .font(.system(size: 11))
                                .foregroundColor(.secondaryText)
                            TextField("7.0000", text: $longitudeString)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 14, design: .monospaced))
                        }
                    }

                    Button(action: { showingMapPicker = true }) {
                        Label("Select on Map", systemImage: "map")
                    }

                    // Mini map preview
                    if let lat = Double(latitudeString), let lon = Double(longitudeString) {
                        MiniMapPreview(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } header: {
                    Label("Location", systemImage: "mappin.and.ellipse")
                } footer: {
                    Text("Enter coordinates in decimal degrees (e.g., 46.9481 for latitude)")
                }

                // Altitude section
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Planned Altitude")
                                .font(.system(size: 11))
                                .foregroundColor(.secondaryText)
                            TextField("5000", text: $altitudeString)
                                .keyboardType(.numberPad)
                                .font(.system(size: 14, design: .monospaced))
                        }

                        Text("ft")
                            .foregroundColor(.secondaryText)
                    }
                } header: {
                    Label("Altitude", systemImage: "arrow.up.and.down")
                }

                // Navigation section
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ground Speed")
                                .font(.system(size: 11))
                                .foregroundColor(.secondaryText)
                            TextField("\(FlightPlan.defaultCruiseSpeed(for: aircraftType))", text: $groundSpeedString)
                                .keyboardType(.numberPad)
                                .font(.system(size: 14, design: .monospaced))
                        }

                        Text("kt")
                            .foregroundColor(.secondaryText)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Wind Direction")
                                .font(.system(size: 11))
                                .foregroundColor(.secondaryText)
                            TextField("270", text: $windDirectionString)
                                .keyboardType(.numberPad)
                                .font(.system(size: 14, design: .monospaced))
                        }

                        Text("°")
                            .foregroundColor(.secondaryText)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Wind Speed")
                                .font(.system(size: 11))
                                .foregroundColor(.secondaryText)
                            TextField("10", text: $windSpeedString)
                                .keyboardType(.numberPad)
                                .font(.system(size: 14, design: .monospaced))
                        }

                        Text("kt")
                            .foregroundColor(.secondaryText)
                    }

                    // Computed values (read-only)
                    if let mc = waypoint.magneticCourse {
                        HStack {
                            Text("Magnetic Course")
                                .foregroundColor(.secondaryText)
                            Spacer()
                            Text(String(format: "%03d°", Int(mc)))
                                .font(.system(size: 14, design: .monospaced))
                        }
                    }

                    if let distance = waypoint.distance {
                        HStack {
                            Text("Distance to Next")
                                .foregroundColor(.secondaryText)
                            Spacer()
                            Text(String(format: "%.1f NM", distance))
                                .font(.system(size: 14, design: .monospaced))
                        }
                    }
                } header: {
                    Label("Navigation", systemImage: "location.north.line")
                } footer: {
                    Text("Ground speed and wind are used to calculate EET. MC and distance are computed automatically.")
                }

                // Radio section
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Frequency")
                            .font(.system(size: 11))
                            .foregroundColor(.secondaryText)
                        TextField("118.100", text: $frequency)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 14, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Callsign")
                            .font(.system(size: 11))
                            .foregroundColor(.secondaryText)
                        TextField("e.g., PORRENTRUY INFO", text: $callSign)
                            .font(.system(size: 14))
                    }
                } header: {
                    Label("Radio", systemImage: "antenna.radiowaves.left.and.right")
                }

                // Remarks section
                Section {
                    TextEditor(text: $remarks)
                        .frame(minHeight: 80)
                        .font(.system(size: 14))
                } header: {
                    Label("Remarks", systemImage: "note.text")
                }

                // Timing section (read-only computed values)
                if waypoint.estimatedElapsedTime != nil || waypoint.estimatedTimeOver != nil {
                    Section {
                        if let eet = waypoint.formattedEET {
                            HStack {
                                Text("EET (from departure)")
                                    .foregroundColor(.secondaryText)
                                Spacer()
                                Text(eet)
                                    .font(.system(size: 14, design: .monospaced))
                            }
                        }

                        if let eto = waypoint.formattedETO {
                            HStack {
                                Text("ETO")
                                    .foregroundColor(.secondaryText)
                                Spacer()
                                Text(eto)
                                    .font(.system(size: 14, design: .monospaced))
                            }
                        }

                        if let ato = waypoint.formattedATO {
                            HStack {
                                Text("ATO (recorded)")
                                    .foregroundColor(.secondaryText)
                                Spacer()
                                Text(ato)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(.aviationGreen)
                            }
                        }
                    } header: {
                        Label("Timing", systemImage: "clock")
                    }
                }
            }
            .navigationTitle("Edit Waypoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveWaypoint()
                    }
                    .disabled(latitudeString.isEmpty || longitudeString.isEmpty)
                }
            }
            .onAppear {
                loadWaypointData()
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
        groundSpeedString = waypoint.plannedGroundSpeed.map { "\($0)" } ?? "\(FlightPlan.defaultCruiseSpeed(for: aircraftType))"
        windDirectionString = waypoint.windDirection.map { String(format: "%.0f", $0) } ?? ""
        windSpeedString = waypoint.windSpeed.map { String(format: "%.0f", $0) } ?? ""
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
    @State private var cameraPosition: MapCameraPosition

    init(initialCoordinate: CLLocationCoordinate2D, onSelect: @escaping (CLLocationCoordinate2D) -> Void) {
        self.initialCoordinate = initialCoordinate
        self.onSelect = onSelect
        let initialRegion = MKCoordinateRegion(
            center: initialCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
        )
        _region = State(initialValue: initialRegion)
        _cameraPosition = State(initialValue: .region(initialRegion))
    }

    var body: some View {
        NavigationView {
            ZStack {
                Map(position: $cameraPosition, interactionModes: .all) {
                }
                .ignoresSafeArea()
                .onMapCameraChange { context in
                    region = context.region
                }

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

                // Coordinate display
                VStack {
                    Spacer()

                    VStack(spacing: 8) {
                        Text("Selected Coordinates")
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
                            Text("Use This Location")
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
    WaypointEditorSheet(
        waypoint: FlightPlanWaypoint(
            name: "LSZQ",
            coordinate: CLLocationCoordinate2D(latitude: 47.1, longitude: 7.1),
            altitude: 5000
        ),
        aircraftType: .wt9Dynamic
    ) { _ in }
}
