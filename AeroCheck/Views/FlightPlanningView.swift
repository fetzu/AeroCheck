import SwiftUI
import MapKit
import UIKit
import UniformTypeIdentifiers

/// A plan is identified by its `id`; hashing by id lets it drive `navigationDestination(item:)` for
/// the master-detail push. Consistent with the synthesized `Equatable` (equal plans share an id). (v4 UI/UX Revamp)
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
    @EnvironmentObject var locationManager: LocationManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The plan being edited in the map builder (opened on tap, or for a new plan). (flight-plan revamp)
    @State private var editingPlan: FlightPlan?
    /// Activating an empty plan prompts to add waypoints first (was silently refused). (flight-plan revamp)
    @State private var showingEmptyActivateAlert = false
    @State private var planToActivate: FlightPlan?
    @State private var showingDeleteAlert = false
    @State private var planToDelete: FlightPlan?
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var planToExport: FlightPlan?
    @State private var exportFormat: ExportFormat = .gpx
    @State private var importError: String?
    @State private var showingImportError = false
    /// Optional aircraft filter (registration); nil = all. (v4 UI/UX Revamp — user feedback)
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
        Group {
            if flightPlanManager.flightPlans.isEmpty {
                listNavStack { emptyState }
            } else {
                // Single full-width card list — tapping a card opens the builder directly (which is
                // itself the iPad two-column map+list), so there's no separate read-only detail pane to
                // navigate through. (flight-plan revamp)
                listNavStack { plansList() }
            }
        }
        .alert(L10n.Nav.activateEmptyTitle, isPresented: $showingEmptyActivateAlert) {
            Button(L10n.Button.cancel, role: .cancel) { }
            Button(L10n.Nav.addWaypoints) { if let p = planToActivate { editingPlan = p } }
        } message: {
            Text(L10n.Nav.activateEmptyMessage)
        }
        // Map-centric builder (v4 UI/UX Revamp), opened from the detail pane's Edit or a new plan.
        // Full-screen so iPad gets the two-column map+list layout. Presented by id → live plan.
        .fullScreenCover(item: $editingPlan) { plan in
            FlightPlanMapBuilderView(planId: plan.id)
                .environmentObject(appState)
                .environmentObject(flightPlanManager)
                .environmentObject(airportDataService)
                .environmentObject(openAIPDataService)
                .environmentObject(locationManager)
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
                AppLog.general.debugLine("Export failed: \(error.localizedDescription)")
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Wraps the list (or empty state) in its own NavigationStack so its toolbar (Done + filter + add)
    /// lives in the LEFT panel's nav bar, not spanning both columns. (v4 UI/UX Revamp — user feedback)
    private func listNavStack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()
                content()
            }
            .navigationTitle(L10n.Nav.flightPlans)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { listToolbar }
        }
    }

    /// The list actions — they scope the list, so they belong to its panel: Done (top-left),
    /// the aircraft filter, and the add/import menu.
    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
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
                Button(action: createAndEditNewPlan) {
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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "map.fill")
                .scaledFont(size: 60, relativeTo: .largeTitle)
                .foregroundColor(.aviationGold.opacity(0.5))

            Text(L10n.Nav.noFlightPlans)
                .scaledFont(size: 24, weight: .bold, relativeTo: .title2)
                .foregroundColor(.primaryText)

            Text(L10n.Nav.noFlightPlansMessage)
                .scaledFont(size: 16, relativeTo: .body)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: createAndEditNewPlan) {
                HStack {
                    Image(systemName: "plus")
                    Text(L10n.Nav.newFlightPlan)
                }
                .scaledFont(size: 17, weight: .semibold, relativeTo: .body)
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

    private func plansList() -> some View {
        let list = List {
            // Active flight plan section
            if let activePlan = flightPlanManager.activeFlightPlan {
                Section {
                    ActiveFlightPlanRow(plan: activePlan)
                        .onTapGesture {
                            editingPlan = activePlan
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))
                } header: {
                    cockpitSectionHeader(L10n.Nav.activeFlightPlan, tint: .aviationGreen, showDot: true)
                }
            }

            // All flight plans section (scoped to the aircraft filter)
            Section {
                ForEach(Array(filteredPlans.enumerated()), id: \.element.id) { index, plan in
                    FlightPlanRow(
                        plan: plan,
                        isActive: plan.id == flightPlanManager.activeFlightPlan?.id,
                        loadPriority: index,
                        onActivate: { activate(plan) }
                    )
                    .id("\(plan.id)-\(plan.waypoints.count)-\(plan.updatedAt)")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingPlan = plan
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
                                activate(plan)
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
                                activate(plan)
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

        return list
    }

    /// Create a new plan and open the builder immediately — no name/aircraft gate. Defaults to the
    /// selected aircraft; the builder's From/To bar names the plan. (flight-plan revamp)
    private func createAndEditNewPlan() {
        let ac = appState.settings.selectedAircraft
        let plan = flightPlanManager.createFlightPlan(
            name: "",
            aircraftTypeId: ac.rawValue,
            aircraftRegistration: ac.registration,
            aircraftModelName: ac.modelName
        )
        editingPlan = plan
    }

    /// Activate a plan; if it has no waypoints, prompt to add some instead of silently refusing. (revamp)
    private func activate(_ plan: FlightPlan) {
        if plan.waypoints.isEmpty {
            planToActivate = plan
            showingEmptyActivateAlert = true
        } else {
            flightPlanManager.activateFlightPlan(plan)
        }
    }

    /// Cockpit-style section header: tracked uppercase label with an optional status dot. (v4 UI/UX Revamp)
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
    var loadPriority: Int = 0   // row index — top rows render their map preview first
    var onActivate: () -> Void

    /// The route endpoints (departure → destination) — the plan's identity. (revamp #1b)
    private var routeEndpoints: String {
        let names = plan.waypoints.map { $0.name.isEmpty ? L10n.Nav.wpt : $0.name }
        if names.count >= 2, let first = names.first, let last = names.last { return "\(first) → \(last)" }
        if let only = names.first { return only }
        return plan.name.isEmpty ? L10n.Nav.newFlightPlan : plan.name
    }

    /// Relative recency ("2d ago"), localised. (revamp #1b)
    private var relativeDate: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: plan.updatedAt, relativeTo: Date())
    }

    private func metric(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).scaledFont(size: 10, relativeTo: .caption2).foregroundColor(.dimText)
            Text(value).scaledFont(size: 12, weight: .semibold, design: .monospaced, relativeTo: .caption).foregroundColor(.secondaryText)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Route map preview — anchors the card visually. (revamp #1b)
            RouteThumbnail(waypoints: plan.waypoints, loadPriority: loadPriority)
                .frame(width: 96, height: 66)

            VStack(alignment: .leading, spacing: 5) {
                // Custom name as a small caption — only when it differs from the route.
                if !plan.name.isEmpty && plan.name != routeEndpoints {
                    Text(plan.name).font(.caption2).foregroundColor(.dimText).lineLimit(1)
                }
                // Hero: the route endpoints.
                HStack(spacing: 6) {
                    Text(routeEndpoints)
                        .scaledFont(size: 16, weight: .semibold, design: .monospaced, relativeTo: .body)
                        .foregroundColor(.primaryText)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if isActive {
                        Text(L10n.Nav.active)
                            .font(.caption2.weight(.bold)).foregroundColor(.black)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.aviationGreen))
                    }
                }
                // Metric strip — structured, not a flat dot-list.
                if plan.waypoints.count >= 2 {
                    HStack(spacing: 13) {
                        if plan.totalDistance > 0 { metric("ruler", String(format: "%.0f NM", plan.totalDistance)) }
                        let eet = plan.formattedTotalEET
                        if !eet.isEmpty && eet != "0:00" { metric("clock", eet) }
                        metric("mappin.and.ellipse", "\(plan.waypoints.count)")
                    }
                } else {
                    Text(L10n.Nav.tapToBuild).font(.caption).foregroundColor(.aviationGold.opacity(0.85))
                }
                // Metadata: aircraft · recency (muted).
                HStack(spacing: 5) {
                    Image(systemName: "airplane").scaledFont(size: 9, relativeTo: .caption2)
                    Text(plan.aircraftRegistration)
                    Text("·")
                    Text(relativeDate)
                }
                .scaledFont(size: 11, relativeTo: .caption2).foregroundColor(.dimText).lineLimit(1)
            }

            Spacer(minLength: 6)

            // One-tap activate (or "in use") — was buried in a swipe / context menu. (revamp)
            if isActive {
                VStack(spacing: 3) {
                    Image(systemName: "airplane.departure").scaledFont(size: 14, relativeTo: .subheadline)
                    Text(L10n.Nav.inUse).scaledFont(size: 10, weight: .semibold, relativeTo: .caption2)
                }
                .foregroundColor(.aviationGreen)
                .frame(width: 62)
            } else {
                Button(action: onActivate) {
                    VStack(spacing: 3) {
                        Image(systemName: "airplane.departure").scaledFont(size: 15, relativeTo: .subheadline)
                        Text(L10n.Nav.activate).scaledFont(size: 10, weight: .semibold, relativeTo: .caption2)
                    }
                    .foregroundColor(.aviationGreen)
                    .frame(width: 62)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.aviationGreen.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.aviationGreen.opacity(0.4), lineWidth: 1)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
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

// MARK: - Route Thumbnail

/// A small map preview of a plan's route — a cached `MKMapSnapshotter` image (muted dark Apple map)
/// with the route + endpoints drawn on top, and a vector outline fallback shown instantly / when the
/// snapshot can't render (e.g. offline). (flight-plan revamp #1b)
struct RouteThumbnail: View {
    let waypoints: [FlightPlanWaypoint]
    var loadPriority: Int = 0   // row index — stagger snapshot generation so top rows finish first
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    private var coords: [CLLocationCoordinate2D] { waypoints.map { $0.coordinate } }
    private var signature: String { coords.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) }.joined(separator: ";") }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.cockpitBackground
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if coords.count >= 2 {
                    RouteOutline(coords: coords)
                        .stroke(Color(red: 0.85, green: 0.31, blue: 0.69).opacity(0.85),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .padding(10)
                } else {
                    Image(systemName: coords.isEmpty ? "plus" : "mappin")
                        .scaledFont(size: 16, relativeTo: .body).foregroundColor(.dimText)
                }
            }
            .task(id: "\(signature)|\(Int(geo.size.width))x\(Int(geo.size.height))") {
                guard coords.count >= 1, geo.size.width > 1 else { image = nil; return }
                // Stagger by row index (≈40 ms each, capped) so the snapshots generate top-to-bottom —
                // the rows the user looks at first get their preview first. The vector outline shows
                // meanwhile, so nothing is blank. (list feedback)
                if loadPriority > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(min(loadPriority, 12)) * 40_000_000)
                    guard !Task.isCancelled else { return }
                }
                image = await RouteSnapshotCache.shared.snapshot(coords: coords, size: geo.size, scale: displayScale)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
    }
}

/// Vector route outline (lat/lon normalised into the rect) — the instant fallback. (revamp #1b)
struct RouteOutline: Shape {
    let coords: [CLLocationCoordinate2D]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard coords.count >= 2 else { return p }
        let lats = coords.map { $0.latitude }, lons = coords.map { $0.longitude }
        let minLat = lats.min()!, maxLat = lats.max()!, minLon = lons.min()!, maxLon = lons.max()!
        let latRange = max(maxLat - minLat, 0.0005), lonRange = max(maxLon - minLon, 0.0005)
        func pt(_ c: CLLocationCoordinate2D) -> CGPoint {
            CGPoint(x: (c.longitude - minLon) / lonRange * rect.width,
                    y: (1 - (c.latitude - minLat) / latRange) * rect.height)
        }
        p.move(to: pt(coords[0]))
        for c in coords.dropFirst() { p.addLine(to: pt(c)) }
        return p
    }
}

/// Renders + caches small route map snapshots. NSCache is thread-safe → `@unchecked Sendable`. (revamp #1b)
final class RouteSnapshotCache: @unchecked Sendable {
    static let shared = RouteSnapshotCache()
    private let cache = NSCache<NSString, UIImage>()

    func snapshot(coords: [CLLocationCoordinate2D], size: CGSize, scale: CGFloat) async -> UIImage? {
        guard !coords.isEmpty, size.width > 1, size.height > 1 else { return nil }
        let key = "\(coords.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) }.joined(separator: ";"))|\(Int(size.width))x\(Int(size.height))@\(Int(scale))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let img = await render(coords: coords, size: size, scale: scale) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    private func render(coords: [CLLocationCoordinate2D], size: CGSize, scale: CGFloat) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        options.region = Self.region(for: coords)
        options.size = size
        options.scale = scale
        options.mapType = .mutedStandard
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot: MKMapSnapshotter.Snapshot? = await withCheckedContinuation { cont in
            snapshotter.start(with: DispatchQueue.global(qos: .userInitiated)) { snap, _ in cont.resume(returning: snap) }
        }
        guard let snapshot else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            snapshot.image.draw(at: .zero)
            let pts = coords.map { snapshot.point(for: $0) }
            if pts.count >= 2 {
                let route = UIBezierPath()
                route.move(to: pts[0])
                for pt in pts.dropFirst() { route.addLine(to: pt) }
                route.lineJoinStyle = .round; route.lineCapStyle = .round
                UIColor.black.withAlphaComponent(0.45).setStroke(); route.lineWidth = 4.5; route.stroke()  // casing
                UIColor(red: 0.85, green: 0.31, blue: 0.69, alpha: 1).setStroke(); route.lineWidth = 2.5; route.stroke()
            }
            for (i, pt) in pts.enumerated() {
                let isFirst = i == 0, isLast = i == pts.count - 1
                let r: CGFloat = (isFirst || isLast) ? 3.5 : 2.5
                let fill: UIColor = isFirst ? UIColor(red: 0.23, green: 0.49, blue: 0.27, alpha: 1)
                    : isLast ? UIColor(red: 0.85, green: 0.65, blue: 0.20, alpha: 1)
                    : UIColor(red: 0.62, green: 0.40, blue: 0.52, alpha: 1)
                let dot = UIBezierPath(ovalIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
                fill.setFill(); dot.fill()
                UIColor.black.setStroke(); dot.lineWidth = 1; dot.stroke()
            }
        }
    }

    private static func region(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coords.map { $0.latitude }, lons = coords.map { $0.longitude }
        let minLat = lats.min()!, maxLat = lats.max()!, minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.6, 0.06),
                                    longitudeDelta: max((maxLon - minLon) * 1.6, 0.06))
        return MKCoordinateRegion(center: center, span: span)
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
                    .scaledFont(size: 13, design: .monospaced, relativeTo: .caption)
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
                            .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                            .foregroundColor(.secondaryText)
                    }
                    ProgressView(value: plan.progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .aviationGreen))
                }

                if let nextWaypoint = plan.nextWaypoint {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.Nav.next)
                                .scaledFont(size: 10, relativeTo: .caption2).tracking(0.4)
                                .foregroundColor(.dimText)
                            Text(nextWaypoint.name.isEmpty ? "\(L10n.Nav.wpt)\(plan.currentWaypointIndex + 1)" : nextWaypoint.name)
                                .scaledFont(size: 14, weight: .semibold, design: .monospaced, relativeTo: .subheadline)
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
                .scaledFont(size: 10, relativeTo: .caption2).tracking(0.4)
                .foregroundColor(.dimText)
            Text(value)
                .scaledFont(size: 14, weight: .semibold, design: .monospaced, relativeTo: .subheadline)
                .foregroundColor(color)
        }
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
        .environmentObject(LocationManager())
}
