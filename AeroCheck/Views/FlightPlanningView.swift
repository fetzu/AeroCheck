import SwiftUI
import MapKit
import UniformTypeIdentifiers

/// A plan is identified by its `id`; hashing by id lets it drive `navigationDestination(item:)` for
/// the master-detail push. Consistent with the synthesized `Equatable` (equal plans share an id). (Phase 3.5)
extension FlightPlan: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Main flight planning view - lists all flight plans with CRUD operations
struct FlightPlanningView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showingNewPlanSheet = false
    /// The plan shown in the read-only detail pane (2-column right / compact push). (Phase 3.5)
    @State private var selectedPlan: FlightPlan?
    /// The plan being edited in the map builder (opened from the detail pane's Edit / new plan). (Phase 3.5)
    @State private var editingPlan: FlightPlan?
    @State private var showingDeleteAlert = false
    @State private var planToDelete: FlightPlan?
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var planToExport: FlightPlan?
    @State private var exportFormat: ExportFormat = .gpx
    @State private var importError: String?
    @State private var showingImportError = false
    /// Optional aircraft filter (registration); nil = all. (Phase 3.5 — user feedback)
    @State private var selectedAircraft: String? = nil

    enum ExportFormat: String, CaseIterable {
        case gpx = "GPX"
        case json = "JSON"
    }

    /// Distinct aircraft (registration) across all plans, most-recent first.
    private var availableAircraft: [String] {
        var seen: [String] = []
        for plan in flightPlanManager.flightPlans {
            let reg = plan.aircraftRegistration
            if !reg.isEmpty && !seen.contains(reg) { seen.append(reg) }
        }
        return seen
    }

    /// The "all plans" list, scoped to the aircraft filter (the active plan stays pinned regardless).
    private var filteredPlans: [FlightPlan] {
        guard let selectedAircraft else { return flightPlanManager.flightPlans }
        return flightPlanManager.flightPlans.filter { $0.aircraftRegistration == selectedAircraft }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()

                if flightPlanManager.flightPlans.isEmpty {
                    emptyState
                } else {
                    GeometryReader { geo in
                        if horizontalSizeClass == .regular && geo.size.width > geo.size.height {
                            // iPad landscape: master (plan list) + read-only detail pane. (3.5)
                            HStack(spacing: 0) {
                                plansList(twoColumn: true)
                                    .frame(width: geo.size.width * 0.40)
                                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                                planDetailColumn
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        } else {
                            plansList(twoColumn: false)
                        }
                    }
                }
            }
            .navigationTitle(L10n.Nav.flightPlans)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.done) { dismiss() }
                }

                if availableAircraft.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker(L10n.Nav.aircraft, selection: $selectedAircraft) {
                                Text(L10n.Nav.allAircraft).tag(String?.none)
                                ForEach(availableAircraft, id: \.self) { reg in
                                    Text(reg).tag(String?.some(reg))
                                }
                            }
                        } label: {
                            Image(systemName: selectedAircraft == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                                .foregroundColor(selectedAircraft == nil ? .secondaryText : .aviationGold)
                        }
                        .accessibilityLabel(L10n.Nav.filterByAircraft)
                    }
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
                    // A new plan is empty — jump straight into the builder to lay out the route.
                    editingPlan = plan
                }
                .environmentObject(appState)
                .environmentObject(flightPlanManager)
            }
            // Map-centric builder (Phase 3.4), opened from the detail pane's Edit or a new plan.
            // Full-screen so iPad gets the two-column map+list layout. Presented by id → live plan.
            .fullScreenCover(item: $editingPlan) { plan in
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

    private func plansList(twoColumn: Bool) -> some View {
        let list = List {
            // Active flight plan section
            if let activePlan = flightPlanManager.activeFlightPlan {
                Section {
                    ActiveFlightPlanRow(plan: activePlan)
                        .onTapGesture {
                            selectedPlan = activePlan
                        }
                        .listRowBackground(rowHighlight(activePlan, twoColumn: twoColumn))
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))
                } header: {
                    cockpitSectionHeader(L10n.Nav.activeFlightPlan, tint: .aviationGreen, showDot: true)
                }
            }

            // All flight plans section (scoped to the aircraft filter)
            Section {
                ForEach(filteredPlans) { plan in
                    FlightPlanRow(
                        plan: plan,
                        isActive: plan.id == flightPlanManager.activeFlightPlan?.id
                    )
                    .id("\(plan.id)-\(plan.waypoints.count)-\(plan.updatedAt)")
                    .listRowBackground(rowHighlight(plan, twoColumn: twoColumn))
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
                            editingPlan = plan
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
                    // Map filtered indices back to plans (indices into filteredPlans, not the full list).
                    for index in offsets where index < filteredPlans.count {
                        flightPlanManager.deleteFlightPlan(filteredPlans[index])
                    }
                }
            } header: {
                cockpitSectionHeader(L10n.Nav.allFlightPlans, tint: .secondaryText, showDot: false)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)

        // Compact: tapping a plan pushes the read-only detail pane. Two-column shows it inline instead.
        return Group {
            if twoColumn {
                list
            } else {
                list.navigationDestination(item: $selectedPlan) { plan in
                    planDetailPane(plan)
                }
            }
        }
    }

    /// Subtle gold tint behind the selected row in the two-column layout.
    private func rowHighlight(_ plan: FlightPlan, twoColumn: Bool) -> Color {
        (twoColumn && selectedPlan?.id == plan.id) ? Color.aviationGold.opacity(0.10) : Color.clear
    }

    /// The right-hand detail pane in the two-column layout (or a placeholder until a plan is picked).
    @ViewBuilder
    private var planDetailColumn: some View {
        if let selected = selectedPlan, flightPlanManager.flightPlans.contains(where: { $0.id == selected.id }) {
            planDetailPane(selected).id(selected.id)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "map")
                    .font(.system(size: 48))
                    .foregroundColor(.dimText)
                Text("Select a flight plan")
                    .font(.system(size: 16))
                    .foregroundColor(.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.cockpitBackground)
        }
    }

    /// Read-only detail pane for a plan (always reads the live plan from the manager). (Phase 3.5)
    private func planDetailPane(_ plan: FlightPlan) -> some View {
        let live = flightPlanManager.flightPlans.first { $0.id == plan.id } ?? plan
        let isActive = live.id == flightPlanManager.activeFlightPlan?.id
        return FlightPlanDetailPane(
            plan: live,
            isActive: isActive,
            onEdit: { editingPlan = live },
            onToggleActive: {
                if isActive { flightPlanManager.deactivateFlightPlan() }
                else { flightPlanManager.activateFlightPlan(live) }
            },
            onExport: {
                exportFormat = .gpx
                planToExport = live
                showingExporter = true
            },
            onDelete: {
                planToDelete = live
                showingDeleteAlert = true
            }
        )
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

    /// Inactive plans are colour-keyed by aircraft (deterministic, stable across launches) so they're
    /// scannable by aircraft and pair with the aircraft filter — replacing the old identical icon.
    /// Active plans are always green. (Phase 3.5 — user feedback)
    static let aircraftPalette: [Color] = [.aviationGold, .altimeterBlue, .aviationAmber, .orange, .aviationRed]
    static func color(forAircraft reg: String) -> Color {
        let sum = reg.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return aircraftPalette[sum % aircraftPalette.count]
    }
    private var tint: Color { isActive ? .aviationGreen : Self.color(forAircraft: plan.aircraftRegistration) }

    /// The route as a chain of waypoint idents (departure → … → destination). Long routes keep the
    /// endpoints (the airports that matter most) rather than tail-truncating off the destination.
    private var routeChain: String {
        let names = plan.waypoints.map { $0.name.isEmpty ? L10n.Nav.wpt : $0.name }
        guard let first = names.first, let last = names.last else { return "—" }
        if names.count <= 4 { return names.joined(separator: " → ") }
        return "\(first) → … → \(last)"
    }

    private var statsLine: String {
        var parts: [String] = [plan.aircraftRegistration]
        if plan.totalDistance > 0 { parts.append(String(format: "%.0f NM", plan.totalDistance)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            // Per-aircraft colour tab (active = green).
            Capsule()
                .fill(tint)
                .frame(width: 4, height: 42)
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
                Text(routeChain)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primaryText.opacity(0.85))
                    .lineLimit(1)
                Text(statsLine)
                    .font(.caption)
                    .foregroundColor(.dimText)
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

// MARK: - Flight Plan Detail Pane (read-only)

/// Read-only summary of a plan for the master-detail (two-column right pane on iPad, pushed on iPhone):
/// route hero + stat chips, a route map, the waypoint list with leg data + ETO/ATO, and actions
/// (Edit → map builder, activate/deactivate, export, delete). Embeddable (no own NavigationStack). (Phase 3.5)
struct FlightPlanDetailPane: View {
    let plan: FlightPlan
    let isActive: Bool
    let onEdit: () -> Void
    let onToggleActive: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.1, longitude: 7.1),
        span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2)
    )
    @State private var fitToken = 0

    private var routeTitle: String {
        let names = plan.waypoints.map { $0.name.isEmpty ? L10n.Nav.wpt : $0.name }
        if names.count >= 2, let first = names.first, let last = names.last { return "\(first) → \(last)" }
        return plan.name.isEmpty ? L10n.Nav.unnamedPlan : plan.name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if plan.waypoints.count >= 2 { mapSection }
                waypointsSection
                actionsSection
            }
            .padding(16)
        }
        .background(Color.cockpitBackground)
        .navigationTitle(plan.name.isEmpty ? L10n.Nav.unnamedPlan : plan.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(routeTitle)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if isActive {
                    Text(L10n.Nav.active)
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.aviationGreen))
                }
            }
            Text("\(plan.aircraftRegistration) · \(plan.aircraftModelName)")
                .font(.subheadline)
                .foregroundColor(.secondaryText)
            HStack(spacing: 10) {
                statChip("DIST", String(format: "%.0f NM", plan.totalDistance), .altimeterBlue)
                statChip("EET", plan.formattedTotalEET, .aviationGold)
                statChip("WP", "\(plan.waypoints.count)", .primaryText)
            }
        }
    }

    private func statChip(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                .foregroundColor(.secondaryText)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground))
    }

    // MARK: Map

    private var mapSection: some View {
        RouteBuilderMapView(
            waypoints: plan.waypoints,
            mapLayer: .icao,
            airports: [],
            fitRouteToken: fitToken,
            region: $region,
            onMapTap: { _ in },
            onAirportTap: { _ in }
        )
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .onAppear { fitToken += 1 }
    }

    // MARK: Waypoints

    private var waypointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ROUTE")
                .font(.caption.weight(.semibold)).tracking(0.6)
                .foregroundColor(.secondaryText)
            VStack(spacing: 0) {
                ForEach(Array(plan.waypoints.enumerated()), id: \.element.id) { index, wp in
                    waypointRow(index, wp)
                    if wp.id != plan.waypoints.last?.id {
                        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 47)
                    }
                }
                if plan.waypoints.isEmpty {
                    Text("No waypoints yet")
                        .font(.caption)
                        .foregroundColor(.dimText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06), lineWidth: 1)))
        }
    }

    private func waypointRow(_ index: Int, _ wp: FlightPlanWaypoint) -> some View {
        HStack(spacing: 11) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.aviationGold))
            VStack(alignment: .leading, spacing: 2) {
                Text(wp.name.isEmpty ? "\(L10n.Nav.wpt)\(index + 1)" : wp.name)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primaryText)
                Text(legLine(wp))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.dimText)
            }
            Spacer(minLength: 6)
            if let alt = wp.altitude {
                Text("\(Int(alt)) ft")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func legLine(_ wp: FlightPlanWaypoint) -> String {
        var parts: [String] = []
        if let mc = wp.magneticCourse { parts.append(String(format: "%03.0f°", mc)) }
        if let d = wp.distance { parts.append(String(format: "%.0f NM", d)) }
        if let eto = wp.formattedETO { parts.append("ETO \(eto)") }
        if let ato = wp.formattedATO { parts.append("ATO \(ato)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // MARK: Actions

    private var actionsSection: some View {
        VStack(spacing: 10) {
            Button(action: onEdit) {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                    Text(L10n.Nav.edit).font(.body.weight(.semibold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.aviationGold))
            }
            HStack(spacing: 10) {
                actionButton(isActive ? L10n.Nav.deactivate : L10n.Nav.activate,
                             icon: isActive ? "airplane.arrival" : "airplane.departure",
                             tint: isActive ? .orange : .aviationGreen,
                             action: onToggleActive)
                actionButton(L10n.Nav.export, icon: "square.and.arrow.up", tint: .altimeterBlue, action: onExport)
                actionButton(L10n.Button.delete, icon: "trash", tint: .aviationRed, action: onDelete)
            }
        }
    }

    private func actionButton(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundColor(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.3), lineWidth: 1)))
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
