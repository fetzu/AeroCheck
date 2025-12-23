import SwiftUI
import UniformTypeIdentifiers

/// Main flight planning view - lists all flight plans with CRUD operations
struct FlightPlanningView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var flightPlanManager: FlightPlanManager
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
        NavigationView {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()

                if flightPlanManager.flightPlans.isEmpty {
                    emptyState
                } else {
                    plansList
                }
            }
            .navigationTitle("Flight Plans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(action: { showingNewPlanSheet = true }) {
                            Label("New Flight Plan", systemImage: "plus")
                        }

                        Button(action: { showingImporter = true }) {
                            Label("Import Flight Plan", systemImage: "square.and.arrow.down")
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
            .sheet(item: $selectedPlan) { plan in
                FlightPlanEditorView(flightPlan: plan)
                    .environmentObject(appState)
                    .environmentObject(flightPlanManager)
            }
            .alert("Delete Flight Plan?", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    if let plan = planToDelete {
                        flightPlanManager.deleteFlightPlan(plan)
                    }
                }
            } message: {
                Text("This action cannot be undone.")
            }
            .alert("Import Error", isPresented: $showingImportError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importError ?? "Failed to import flight plan.")
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
                    print("[AeroCheck] Export failed: \(error.localizedDescription)")
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

            Text("No Flight Plans")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.primaryText)

            Text("Create a new flight plan to get started with route planning.")
                .font(.system(size: 16))
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: { showingNewPlanSheet = true }) {
                HStack {
                    Image(systemName: "plus")
                    Text("New Flight Plan")
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
                } header: {
                    HStack {
                        Label("Active Flight Plan", systemImage: "airplane.circle.fill")
                        Spacer()
                        StatusIndicator(.active, size: 8)
                    }
                }
            }

            // All flight plans section
            Section {
                ForEach(flightPlanManager.flightPlans) { plan in
                    FlightPlanRow(
                        plan: plan,
                        isActive: plan.id == flightPlanManager.activeFlightPlan?.id
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedPlan = plan
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            planToDelete = plan
                            showingDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            _ = flightPlanManager.duplicateFlightPlan(plan)
                        } label: {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }
                        .tint(.aviationBlue)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if plan.id != flightPlanManager.activeFlightPlan?.id {
                            Button {
                                flightPlanManager.activateFlightPlan(plan)
                            } label: {
                                Label("Activate", systemImage: "airplane.departure")
                            }
                            .tint(.aviationGreen)
                        } else {
                            Button {
                                flightPlanManager.deactivateFlightPlan()
                            } label: {
                                Label("Deactivate", systemImage: "airplane.arrival")
                            }
                            .tint(.orange)
                        }
                    }
                    .contextMenu {
                        Button {
                            selectedPlan = plan
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }

                        if plan.id != flightPlanManager.activeFlightPlan?.id {
                            Button {
                                flightPlanManager.activateFlightPlan(plan)
                            } label: {
                                Label("Activate", systemImage: "airplane.departure")
                            }
                        } else {
                            Button {
                                flightPlanManager.deactivateFlightPlan()
                            } label: {
                                Label("Deactivate", systemImage: "airplane.arrival")
                            }
                        }

                        Divider()

                        Menu {
                            Button {
                                exportFormat = .gpx
                                planToExport = plan
                                showingExporter = true
                            } label: {
                                Label("Export as GPX", systemImage: "doc")
                            }

                            Button {
                                exportFormat = .json
                                planToExport = plan
                                showingExporter = true
                            } label: {
                                Label("Export as JSON", systemImage: "doc.text")
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }

                        Button {
                            _ = flightPlanManager.duplicateFlightPlan(plan)
                        } label: {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }

                        Divider()

                        Button(role: .destructive) {
                            planToDelete = plan
                            showingDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in
                    flightPlanManager.deleteFlightPlans(at: offsets)
                }
            } header: {
                Label("All Flight Plans", systemImage: "list.bullet")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Import Handler

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                importError = "Unable to access the selected file."
                showingImportError = true
                return
            }

            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                if let _ = flightPlanManager.importFlightPlan(from: data) {
                    // Success - plan was imported
                } else {
                    importError = "The file format is not supported or the file is corrupted."
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

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            VStack {
                if isActive {
                    Image(systemName: "airplane.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.aviationGreen)
                } else {
                    Image(systemName: "map")
                        .font(.system(size: 24))
                        .foregroundColor(.aviationGold)
                }
            }
            .frame(width: 32)

            // Plan details
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(plan.name.isEmpty ? "Unnamed Plan" : plan.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primaryText)

                    if isActive {
                        Text("ACTIVE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.aviationGreen)
                            )
                    }
                }

                HStack(spacing: 8) {
                    Text(plan.aircraftRegistration)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondaryText)

                    Text("•")
                        .foregroundColor(.dimText)

                    Text("\(plan.waypoints.count) waypoints")
                        .font(.system(size: 13))
                        .foregroundColor(.secondaryText)

                    if plan.totalDistance > 0 {
                        Text("•")
                            .foregroundColor(.dimText)

                        Text(String(format: "%.1f NM", plan.totalDistance))
                            .font(.system(size: 13))
                            .foregroundColor(.secondaryText)
                    }
                }

                if let departureTime = plan.plannedDepartureTime {
                    Text(formatDate(departureTime))
                        .font(.system(size: 12))
                        .foregroundColor(.dimText)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14))
                .foregroundColor(.dimText)
        }
        .padding(.vertical, 8)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Active Flight Plan Row

struct ActiveFlightPlanRow: View {
    let plan: FlightPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text(plan.name.isEmpty ? "Unnamed Plan" : plan.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.primaryText)

                Spacer()

                Text(plan.aircraftRegistration)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.aviationGold)
            }

            // Progress
            if !plan.waypoints.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Progress")
                            .font(.system(size: 12))
                            .foregroundColor(.secondaryText)

                        Spacer()

                        Text("\(plan.currentWaypointIndex)/\(plan.waypoints.count)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondaryText)
                    }

                    ProgressView(value: plan.progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .aviationGreen))
                }

                // Next waypoint info
                if let nextWaypoint = plan.nextWaypoint {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Next")
                                .font(.system(size: 10))
                                .foregroundColor(.dimText)
                            Text(nextWaypoint.name.isEmpty ? "WPT\(plan.currentWaypointIndex + 1)" : nextWaypoint.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.primaryText)
                        }

                        Spacer()

                        if let distance = nextWaypoint.distance {
                            VStack(alignment: .trailing) {
                                Text("Dist")
                                    .font(.system(size: 10))
                                    .foregroundColor(.dimText)
                                Text(String(format: "%.1f NM", distance))
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.primaryText)
                            }
                        }

                        if let mc = nextWaypoint.magneticCourse {
                            VStack(alignment: .trailing) {
                                Text("MC")
                                    .font(.system(size: 10))
                                    .foregroundColor(.dimText)
                                Text(String(format: "%03d°", Int(mc)))
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.primaryText)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - New Flight Plan Sheet

struct NewFlightPlanSheet: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @Environment(\.dismiss) var dismiss

    @State private var name: String = ""
    @State private var selectedAircraft: AircraftType = .wt9Dynamic

    var onCreated: (FlightPlan) -> Void

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Flight Plan Name", text: $name)

                    Picker("Aircraft", selection: $selectedAircraft) {
                        ForEach(AircraftType.allCases) { aircraft in
                            HStack {
                                Text(aircraft.registration)
                                    .font(.system(.body, design: .monospaced))
                                Text("(\(aircraft.shortModelName))")
                                    .foregroundColor(.secondary)
                            }
                            .tag(aircraft)
                        }
                    }
                } header: {
                    Label("Details", systemImage: "doc.text")
                }
            }
            .navigationTitle("New Flight Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let plan = flightPlanManager.createFlightPlan(
                            name: name.isEmpty ? "New Flight Plan" : name,
                            aircraftType: selectedAircraft
                        )
                        dismiss()
                        onCreated(plan)
                    }
                }
            }
            .onAppear {
                selectedAircraft = appState.settings.selectedAircraft
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
