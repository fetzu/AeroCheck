import SwiftUI
import UniformTypeIdentifiers

/// Main flight planning view - lists all flight plans with CRUD operations
struct FlightPlanningView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @Environment(\.dismiss) var dismiss

    @State private var showingNewPlanSheet = false
    @State private var selectedPlan: FlightPlan?
    @State private var showingDeleteAlert = false
    @State private var planToDelete: FlightPlan?
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var planToExport: FlightPlan?
    @State private var exportFormat: ExportFormat = .gpx
    @State private var importError: String?
    @State private var showingImportError = false

    enum ExportFormat: String, CaseIterable {
        case gpx = "GPX"
        case json = "JSON"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()

                if flightPlanManager.flightPlans.isEmpty {
                    emptyState
                } else {
                    plansList
                }
            }
            .navigationTitle(L10n.Nav.flightPlans)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.done) { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(action: { showingNewPlanSheet = true }) {
                            Label(L10n.Nav.newFlightPlan, systemImage: "plus")
                        }

                        Button(action: { showingImporter = true }) {
                            Label(L10n.Nav.importFlightPlan, systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewPlanSheet) {
                NewFlightPlanSheet { plan in
                    selectedPlan = plan
                }
                .environmentObject(appState)
                .environmentObject(flightPlanManager)
            }
            // Map-centric builder is the default creation/edit path (Phase 3.4); full-screen so
            // iPad gets the two-column map+list layout. The dense table editor is reachable from
            // inside the builder ("Table"). Presented by id so it always reads the live plan.
            .fullScreenCover(item: $selectedPlan) { plan in
                FlightPlanMapBuilderView(planId: plan.id)
                    .environmentObject(appState)
                    .environmentObject(flightPlanManager)
                    .environmentObject(airportDataService)
                    .environmentObject(openAIPDataService)
            }
            .alert(L10n.Nav.deleteFlightPlan, isPresented: $showingDeleteAlert) {
                Button(L10n.Button.cancel, role: .cancel) { }
                Button(L10n.Button.delete, role: .destructive) {
                    if let plan = planToDelete {
                        flightPlanManager.deleteFlightPlan(plan)
                    }
                }
            } message: {
                Text(L10n.Nav.deleteFlightPlanMessage)
            }
            .alert(L10n.Nav.importError, isPresented: $showingImportError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importError ?? L10n.Nav.importErrorMessage)
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.json, UTType(filenameExtension: "gpx") ?? .xml],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: planToExport.map { FlightPlanDocument(plan: $0, format: exportFormat) },
                contentType: exportFormat == .gpx ? (UTType(filenameExtension: "gpx") ?? .xml) : .json,
                defaultFilename: planToExport?.exportFilename ?? "FlightPlan"
            ) { result in
                if case .failure(let error) = result {
                    print("[AéroCheck] Export failed: \(error.localizedDescription)")
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "map.fill")
                .font(.system(size: 60))
                .foregroundColor(.aviationGold.opacity(0.5))

            Text(L10n.Nav.noFlightPlans)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.primaryText)

            Text(L10n.Nav.noFlightPlansMessage)
                .font(.system(size: 16))
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: { showingNewPlanSheet = true }) {
                HStack {
                    Image(systemName: "plus")
                    Text(L10n.Nav.newFlightPlan)
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.aviationGold)
                )
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Plans List

    private var plansList: some View {
        List {
            // Active flight plan section
            if let activePlan = flightPlanManager.activeFlightPlan {
                Section {
                    ActiveFlightPlanRow(plan: activePlan)
                        .onTapGesture {
                            selectedPlan = activePlan
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))
                } header: {
                    cockpitSectionHeader(L10n.Nav.activeFlightPlan, tint: .aviationGreen, showDot: true)
                }
            }

            // All flight plans section
            Section {
                ForEach(flightPlanManager.flightPlans) { plan in
                    FlightPlanRow(
                        plan: plan,
                        isActive: plan.id == flightPlanManager.activeFlightPlan?.id
                    )
                    .id("\(plan.id)-\(plan.waypoints.count)-\(plan.updatedAt)")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedPlan = plan
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            planToDelete = plan
                            showingDeleteAlert = true
                        } label: {
                            Label(L10n.Button.delete, systemImage: "trash")
                        }

                        Button {
                            _ = flightPlanManager.duplicateFlightPlan(plan)
                        } label: {
                            Label(L10n.Nav.duplicate, systemImage: "doc.on.doc")
                        }
                        .tint(.aviationBlue)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if plan.id != flightPlanManager.activeFlightPlan?.id {
                            Button {
                                flightPlanManager.activateFlightPlan(plan)
                            } label: {
                                Label(L10n.Nav.activate, systemImage: "airplane.departure")
                            }
                            .tint(.aviationGreen)
                        } else {
                            Button {
                                flightPlanManager.deactivateFlightPlan()
                            } label: {
                                Label(L10n.Nav.deactivate, systemImage: "airplane.arrival")
                            }
                            .tint(.orange)
                        }
                    }
                    .contextMenu {
                        Button {
                            selectedPlan = plan
                        } label: {
                            Label(L10n.Nav.edit, systemImage: "pencil")
                        }

                        if plan.id != flightPlanManager.activeFlightPlan?.id {
                            Button {
                                flightPlanManager.activateFlightPlan(plan)
                            } label: {
                                Label(L10n.Nav.activate, systemImage: "airplane.departure")
                            }
                        } else {
                            Button {
                                flightPlanManager.deactivateFlightPlan()
                            } label: {
                                Label(L10n.Nav.deactivate, systemImage: "airplane.arrival")
                            }
                        }

                        Divider()

                        Menu {
                            Button {
                                exportFormat = .gpx
                                planToExport = plan
                                showingExporter = true
                            } label: {
                                Label(L10n.Nav.exportAsGPX, systemImage: "doc")
                            }

                            Button {
                                exportFormat = .json
                                planToExport = plan
                                showingExporter = true
                            } label: {
                                Label(L10n.Nav.exportAsJSON, systemImage: "doc.text")
                            }
                        } label: {
                            Label(L10n.Nav.export, systemImage: "square.and.arrow.up")
                        }

                        Button {
                            _ = flightPlanManager.duplicateFlightPlan(plan)
                        } label: {
                            Label(L10n.Nav.duplicate, systemImage: "doc.on.doc")
                        }

                        Divider()

                        Button(role: .destructive) {
                            planToDelete = plan
                            showingDeleteAlert = true
                        } label: {
                            Label(L10n.Button.delete, systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in
                    flightPlanManager.deleteFlightPlans(at: offsets)
                }
            } header: {
                cockpitSectionHeader(L10n.Nav.allFlightPlans, tint: .secondaryText, showDot: false)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Cockpit-style section header: tracked uppercase label with an optional status dot. (Phase 3.5 redesign)
    private func cockpitSectionHeader(_ title: String, tint: Color, showDot: Bool) -> some View {
        HStack(spacing: 7) {
            if showDot {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundColor(tint)
            Spacer()
        }
        .textCase(nil)
    }

    // MARK: - Import Handler

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                importError = L10n.Nav.importErrorAccess
                showingImportError = true
                return
            }

            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                if let _ = flightPlanManager.importFlightPlan(from: data) {
                    // Success - plan was imported
                } else {
                    importError = L10n.Nav.importErrorFormat
                    showingImportError = true
                }
            } catch {
                importError = error.localizedDescription
                showingImportError = true
            }

        case .failure(let error):
            importError = error.localizedDescription
            showingImportError = true
        }
    }
}

// MARK: - Flight Plan Row

struct FlightPlanRow: View {
    let plan: FlightPlan
    let isActive: Bool

    private var tint: Color { isActive ? .aviationGreen : .aviationGold }
    private var icon: String { isActive ? "airplane.circle.fill" : "point.topleft.down.to.point.bottomright.curvepath" }

    /// Compact mono stats line: "F-HVXA · 5 WP · 86 NM" (WP/NM are ICAO-style, intentionally untranslated).
    private var statsLine: String {
        var parts: [String] = [plan.aircraftRegistration, "\(plan.waypoints.count) WP"]
        if plan.totalDistance > 0 { parts.append(String(format: "%.0f NM", plan.totalDistance)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(tint)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(plan.name.isEmpty ? L10n.Nav.unnamedPlan : plan.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                    if isActive {
                        Text(L10n.Nav.active)
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.aviationGreen))
                    }
                }
                Text(statsLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.dimText.opacity(0.7))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isActive ? Color.aviationGreen.opacity(0.35) : Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Active Flight Plan Row

struct ActiveFlightPlanRow: View {
    let plan: FlightPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(plan.name.isEmpty ? L10n.Nav.unnamedPlan : plan.name)
                    .font(.headline)
                    .foregroundColor(.primaryText)
                Spacer()
                Text(plan.aircraftRegistration)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.aviationGold)
            }

            if !plan.waypoints.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.Nav.progress)
                            .font(.caption)
                            .foregroundColor(.secondaryText)
                        Spacer()
                        Text("\(plan.currentWaypointIndex)/\(plan.waypoints.count)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondaryText)
                    }
                    ProgressView(value: plan.progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .aviationGreen))
                }

                if let nextWaypoint = plan.nextWaypoint {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.Nav.next)
                                .font(.system(size: 10)).tracking(0.4)
                                .foregroundColor(.dimText)
                            Text(nextWaypoint.name.isEmpty ? "\(L10n.Nav.wpt)\(plan.currentWaypointIndex + 1)" : nextWaypoint.name)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundColor(.primaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if let mc = nextWaypoint.magneticCourse {
                            statColumn(L10n.Nav.mc, String(format: "%03d°", Int(mc)), .altimeterBlue)
                        }
                        if let distance = nextWaypoint.distance {
                            statColumn(L10n.Nav.dist, String(format: "%.0f NM", distance), .primaryText)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.cockpitBackground))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.aviationGreen.opacity(0.35), lineWidth: 1))
        )
        .contentShape(Rectangle())
    }

    private func statColumn(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.system(size: 10)).tracking(0.4)
                .foregroundColor(.dimText)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        }
    }
}

// MARK: - New Flight Plan Sheet

struct NewFlightPlanSheet: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @Environment(\.dismiss) var dismiss

    @State private var name: String = ""
    @State private var selectedAircraftId: String = "WT9"

    var onCreated: (FlightPlan) -> Void

    /// All available aircraft options (bundled + visible remote with access)
    private var availableAircraft: [AircraftOption] {
        var options: [AircraftOption] = []
        for aircraft in AircraftType.allCases {
            options.append(.bundled(aircraft))
        }
        for remote in aircraftDataService.availableAircraft where remote.hasAccess && !remote.isBundled {
            if appState.settings.isAircraftVisible(aircraftId: remote.id, aeroclub: remote.aeroclub) {
                options.append(.remote(remote))
            }
        }
        return options
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.Nav.flightPlanName, text: $name)

                    Picker(L10n.Nav.aircraft, selection: $selectedAircraftId) {
                        ForEach(availableAircraft) { option in
                            HStack {
                                Text(option.registration)
                                    .font(.system(.body, design: .monospaced))
                                Text("(\(option.modelName))")
                                    .foregroundColor(.secondary)
                            }
                            .tag(option.aircraftType)
                        }
                    }
                } header: {
                    Label(L10n.Nav.details, systemImage: "doc.text")
                }
            }
            .navigationTitle(L10n.Nav.newFlightPlan)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Nav.create) {
                        let selected = availableAircraft.first { $0.aircraftType == selectedAircraftId }
                        let plan = flightPlanManager.createFlightPlan(
                            name: name.isEmpty ? L10n.Nav.newFlightPlan : name,
                            aircraftTypeId: selectedAircraftId,
                            aircraftRegistration: selected?.registration ?? "",
                            aircraftModelName: selected?.modelName ?? selectedAircraftId
                        )
                        dismiss()
                        onCreated(plan)
                    }
                }
            }
            .onAppear {
                selectedAircraftId = appState.settings.selectedAircraft.rawValue
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Flight Plan Document (for export)

struct FlightPlanDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, UTType(filenameExtension: "gpx") ?? .xml] }

    let plan: FlightPlan
    let format: FlightPlanningView.ExportFormat

    init(plan: FlightPlan, format: FlightPlanningView.ExportFormat) {
        self.plan = plan
        self.format = format
    }

    init(configuration: ReadConfiguration) throws {
        // This is for import - not used here
        plan = FlightPlan()
        format = .gpx
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data: Data
        switch format {
        case .gpx:
            data = plan.toGPX().data(using: .utf8) ?? Data()
        case .json:
            data = plan.toJSON() ?? Data()
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Preview

#Preview {
    FlightPlanningView()
        .environmentObject(AppState())
        .environmentObject(FlightPlanManager())
}
