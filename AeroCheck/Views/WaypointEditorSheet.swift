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
    /// Message shown when the entered coordinates/altitude were rejected. (SEC-C20)
    ///
    /// A plain `Bool` + `String` pair rather than a computed `Binding<Bool>` over an optional:
    /// this view body is already at the Swift type-checker's budget, and the computed binding
    /// tipped it over.
    @State private var invalidFieldMessage: String = ""
    @State private var showingInvalidValue = false

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

    private let tint: Color = .altimeterBlue

    var body: some View {
        NavigationStack {
            SettingsPage {
                // Location section
                SettingsGroup(title: L10n.Nav.location, tint: tint, footer: L10n.Nav.coordinatesHelp) {
                    fieldRow(L10n.Nav.waypointName, icon: "mappin.and.ellipse") {
                        TextField(L10n.Nav.waypointNamePlaceholder, text: $name)
                            .foregroundColor(.primaryText)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Nav.latitude)
                                .scaledFont(size: 11, relativeTo: .caption2)
                                .foregroundColor(.secondaryText)
                            TextField("46.0000", text: $latitudeString)
                                .keyboardType(.decimalPad)
                                .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                                .foregroundColor(.primaryText)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Nav.longitude)
                                .scaledFont(size: 11, relativeTo: .caption2)
                                .foregroundColor(.secondaryText)
                            TextField("7.0000", text: $longitudeString)
                                .keyboardType(.decimalPad)
                                .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                                .foregroundColor(.primaryText)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    SettingsButtonRow(icon: "map", title: L10n.Nav.selectOnMap, tint: tint, showsChevron: false) {
                        showingMapPicker = true
                    }

                    // Mini map preview
                    if let lat = Double(latitudeString), let lon = Double(longitudeString) {
                        MiniMapPreview(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                }

                // Altitude section
                SettingsGroup(title: L10n.Nav.altitude, tint: tint, footer: groundElevationMeters != nil ? L10n.Nav.defaultAGL : nil) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Nav.plannedAltitude)
                                .scaledFont(size: 11, relativeTo: .caption2)
                                .foregroundColor(.secondaryText)
                            TextField("5000", text: $altitudeString)
                                .keyboardType(.numberPad)
                                .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                                .foregroundColor(.primaryText)
                        }

                        Text(L10n.Unit.ft)
                            .foregroundColor(.secondaryText)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    // Ground level display
                    HStack {
                        if isLoadingElevation {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(L10n.Nav.loadingElevation)
                                .foregroundColor(.secondaryText)
                                .scaledFont(size: 12, relativeTo: .caption)
                        } else if let groundElevation = groundElevationMeters {
                            let groundFeet = groundElevation * 3.28084
                            Text(L10n.Nav.groundLevel(Int(groundFeet)))
                                .foregroundColor(.dimText)
                                .scaledFont(size: 12, relativeTo: .caption)
                        } else {
                            Text(L10n.Nav.groundLevelNA)
                                .foregroundColor(.dimText)
                                .scaledFont(size: 12, relativeTo: .caption)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }

                // Navigation section
                SettingsGroup(title: L10n.Nav.navigation, tint: tint, footer: L10n.Nav.navigationHelp) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Nav.groundSpeed)
                                .scaledFont(size: 11, relativeTo: .caption2)
                                .foregroundColor(.secondaryText)
                            TextField("\(FlightPlan.defaultCruiseSpeed(for: aircraftTypeId))", text: $groundSpeedString)
                                .keyboardType(.numberPad)
                                .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                                .foregroundColor(.primaryText)
                        }

                        Text(L10n.Unit.kt)
                            .foregroundColor(.secondaryText)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Nav.windDirection)
                                .scaledFont(size: 11, relativeTo: .caption2)
                                .foregroundColor(.secondaryText)
                            TextField("270", text: $windDirectionString)
                                .keyboardType(.numberPad)
                                .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                                .foregroundColor(.primaryText)
                        }

                        Text("°")
                            .foregroundColor(.secondaryText)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.Nav.windSpeed)
                                .scaledFont(size: 11, relativeTo: .caption2)
                                .foregroundColor(.secondaryText)
                            TextField("10", text: $windSpeedString)
                                .keyboardType(.numberPad)
                                .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                                .foregroundColor(.primaryText)
                        }

                        Text(L10n.Unit.kt)
                            .foregroundColor(.secondaryText)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    // Computed values (read-only)
                    if let mc = waypoint.magneticCourse {
                        SettingsValueRow(title: L10n.Nav.magneticCourse, tint: tint, value: String(format: "%03d°", Int(mc)))
                    }

                    if let distance = waypoint.distance {
                        SettingsValueRow(title: L10n.Nav.distanceToNext, tint: tint, value: String(format: "%.1f NM", distance))
                    }
                }

                // Radio section
                SettingsGroup(title: L10n.Nav.radio, tint: tint) {
                    fieldRow(L10n.Nav.frequency, icon: "antenna.radiowaves.left.and.right") {
                        TextField("118.100", text: $frequency)
                            .keyboardType(.decimalPad)
                            .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                            .foregroundColor(.primaryText)
                    }

                    fieldRow(L10n.Nav.callsign) {
                        TextField("e.g., PORRENTRUY INFO", text: $callSign)
                            .scaledFont(size: 14, relativeTo: .subheadline)
                            .foregroundColor(.primaryText)
                    }
                }

                // Remarks section
                SettingsGroup(title: L10n.Nav.remarks, tint: tint) {
                    TextEditor(text: $remarks)
                        .frame(minHeight: 80)
                        .scaledFont(size: 14, relativeTo: .subheadline)
                        .foregroundColor(.primaryText)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }

                // Timing section (read-only computed values)
                if waypoint.estimatedElapsedTime != nil || waypoint.estimatedTimeOver != nil {
                    SettingsGroup(title: L10n.Nav.timing, tint: tint) {
                        if let eet = waypoint.formattedEET {
                            SettingsValueRow(icon: "clock", title: L10n.Nav.eetFromDeparture, tint: tint, value: eet)
                        }

                        if let eto = waypoint.formattedETO {
                            SettingsValueRow(title: L10n.Nav.eto, tint: tint, value: eto)
                        }

                        if let ato = waypoint.formattedATO {
                            SettingsValueRow(title: L10n.Nav.atoRecorded, tint: tint, value: ato, valueColor: .aviationGreen)
                        }
                    }
                }

                // Delete section - only shown when onDelete callback is provided
                if onDelete != nil {
                    SettingsGroup(tint: tint) {
                        SettingsButtonRow(icon: "trash", title: L10n.Nav.deleteWaypoint, tint: tint, showsChevron: false, destructive: true) {
                            showingDeleteConfirmation = true
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
            .modifier(InvalidValueAlert(isPresented: $showingInvalidValue, message: invalidFieldMessage))
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

    /// Houses a text-input control on a cockpit settings card: an optional tinted label row above the
    /// field, both padded to match the kit's row insets.
    @ViewBuilder
    private func fieldRow<Field: View>(_ label: String, icon: String? = nil, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRowLabel(icon: icon, title: label, tint: tint)
            field()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        // SEC-C20: `Double("nan")` and `Double("inf")` PARSE SUCCESSFULLY, so a mistyped or pasted
        // value silently produced a waypoint that persisted, synced to iCloud, and exported as the
        // literal string `nan` into the GPX/XLSX/PDF handed to a Dynon/Garmin. Both file-import
        // paths validated these exact fields; the editor — the far likelier source — did not.
        guard let lat = Double(latitudeString),
              let lon = Double(longitudeString),
              GeoValidation.isValidLatLon(lat, lon) else {
            invalidFieldMessage = L10n.Nav.invalidCoordinatesMessage
            showingInvalidValue = true
            return
        }

        // An altitude that is present but implausible is rejected outright rather than silently
        // dropped: the pilot typed something, and quietly discarding it would be worse than saying
        // so. (An EMPTY field still legitimately means "no planned altitude".)
        let parsedAltitude = altitudeString.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil
            : Double(altitudeString)
        if !altitudeString.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let alt = parsedAltitude,
                  PlausibleRange.isPlausible(alt, in: PlausibleRange.altitudeFeet) else {
                invalidFieldMessage = L10n.Nav.invalidAltitudeMessage
                showingInvalidValue = true
                return
            }
        }

        var updatedWaypoint = waypoint
        updatedWaypoint.name = name
        updatedWaypoint.latitude = lat
        updatedWaypoint.longitude = lon
        updatedWaypoint.altitude = parsedAltitude
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
                            .scaledFont(size: 30, weight: .light, relativeTo: .largeTitle)
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
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.secondaryText)

                        HStack(spacing: 16) {
                            VStack {
                                Text("LAT")
                                    .scaledFont(size: 10, relativeTo: .caption2)
                                    .foregroundColor(.dimText)
                                Text(String(format: "%.6f", region.center.latitude))
                                    .scaledFont(size: 14, weight: .medium, design: .monospaced, relativeTo: .subheadline)
                            }

                            VStack {
                                Text("LON")
                                    .scaledFont(size: 10, relativeTo: .caption2)
                                    .foregroundColor(.dimText)
                                Text(String(format: "%.6f", region.center.longitude))
                                    .scaledFont(size: 14, weight: .medium, design: .monospaced, relativeTo: .subheadline)
                            }
                        }

                        Button(action: {
                            onSelect(region.center)
                            dismiss()
                        }) {
                            Text(L10n.Nav.useThisLocation)
                                .scaledFont(size: 16, weight: .semibold, relativeTo: .body)
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
        onDelete: { }
    )
}

/// Alert shown when a waypoint's coordinates or altitude are rejected. (SEC-C20)
///
/// Extracted into a `ViewModifier` purely for compile time: `WaypointEditorSheet`'s body is a long
/// modifier chain that the Swift type-checker could not resolve within its budget once one more
/// `.alert` was appended inline.
private struct InvalidValueAlert: ViewModifier {
    @Binding var isPresented: Bool
    let message: String

    func body(content: Content) -> some View {
        content.alert(L10n.Nav.invalidValueTitle, isPresented: $isPresented) {
            Button(L10n.Subscription.ok, role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}
