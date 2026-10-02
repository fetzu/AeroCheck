import SwiftUI
import MapKit

// MARK: - Flight Plan Map Builder (v4 UI/UX Revamp)

/// Map-centric flight-plan builder — the default creation/edit path. Tap the map or search
/// ICAO/name to add waypoints; the route draws live with numbered markers; a side panel (iPad
/// landscape) or bottom panel (portrait/iPhone) shows the route summary + a reorderable waypoint
/// list with editable altitudes. The dense tabular `FlightPlanEditorView` stays reachable as the
/// "Table" (advanced) view. All mutations go through `FlightPlanManager` (single source of truth,
/// auto-recalculates the route), so the builder reads the live plan by id and stays reactive.
struct FlightPlanMapBuilderView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var windsAloftService: WindsAloftService
    /// An aerodrome's official chart, from its callout, opens in the browser. (6.2.0)
    @Environment(\.openURL) private var openURL
    // Observe the per-country layer singletons so the trip-prefetch banner reacts to download
    // completions (their @Published downloadedCountries) rather than only to airspace changes. (review #8)
    @ObservedObject private var navaidService = OpenAIPNavaidDataService.shared
    @ObservedObject private var obstacleService = OpenAIPObstacleDataService.shared
    @ObservedObject private var reportingPointService = OpenAIPReportingPointDataService.shared
    @ObservedObject private var vfrProcedureService = OFMDataService.shared   // 6.2.0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// For the aerodrome procedures' palette (night: no white casing). (6.2.0)
    @Environment(\.cockpitTheme) private var theme

    let planId: UUID

    @State private var selectedLayer: WaypointPickerMapLayer = .icao
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.1, longitude: 7.1), // Swiss Jura default
        span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2)
    )
    @State private var visibleAirports: [Airport] = []
    @State private var airportUpdateTask: Task<Void, Never>?
    @State private var visibleNavaids: [Navaid] = []
    @State private var visibleReportingPoints: [ReportingPoint] = []   // v4.1.0 ③
    @State private var visibleObstacles: [Obstacle] = []               // v4.1.0 ③
    /// Traffic circuits, VFR routes and sectors around the map's region. (6.2.0)
    @State private var vfrContent: VFRMapContent = .empty()
    @State private var navaidUpdateTask: Task<Void, Never>?
    @State private var fitRouteToken = 0
    @State private var didInitialFit = false

    @State private var fromText = ""
    @State private var toText = ""
    @FocusState private var focusedEndpoint: RouteEndpoint?
    @State private var searchResults: [Airport] = []
    @State private var searchTask: Task<Void, Never>?
    // "Via": a reporting point or navaid to put in the route (6.0.1)
    @State private var viaText = ""
    @FocusState private var viaFocused: Bool
    @State private var viaResults: [RoutePointSearch.Result] = []
    /// The query `viaResults` answer, so "no match" never shows for a query still being typed.
    @State private var viaResultsQuery = ""
    @State private var viaSearchTask: Task<Void, Never>?
    @State private var listEditMode: EditMode = .inactive
    /// The leg whose altitude is being typed, and how much of the builder the keyboard leaves: while
    /// both hold, the builder slides up so the legs sit on the keys. (6.1.0)
    @State private var altitudeEditingId: UUID?
    @State private var heightAboveKeyboard: CGFloat = 0

    // On-route hazards — airspace profile + terrain (#4 redesign: route-profile cross-section)
    @State private var airspaceBlocks: [AirspaceProfileBlock] = []
    @State private var crossedAirspaces: [Airspace] = []   // conflict subset, for the list + map highlight
    @State private var airspacePolygons: [AirspacePolygon] = []
    @State private var airspaceTask: Task<Void, Never>?
    @State private var terrainData: [(distance: Double, elevation: Double)] = []
    /// The route line `terrainData` was fetched for. The airspace check resolves limits in ft AGL
    /// against the terrain only while it still belongs to the route on screen. (APP-11)
    @State private var terrainRouteKey = ""
    @State private var terrainTask: Task<Void, Never>?
    @State private var windsAloftTask: Task<Void, Never>?
    @State private var minTerrainClearanceFt: Double?
    @State private var selectedConflictId: String?   // tapped conflict — highlighted on map + profile (#4)
    @State private var focusRegion: MKCoordinateRegion?   // hold a conflict → recenter the map (#4)
    @State private var focusToken = 0
    @State private var holdCenterId: String?              // conflict being held — drives the fill cue (#4)
    @State private var holdCenterProgress: CGFloat = 0
    private let elevationService = ElevationService()
    private static let terrainConflictId = "terrain"

    enum RouteEndpoint: Hashable { case from, to }
    @State private var editingWaypoint: FlightPlanWaypoint?
    @State private var showTableEditor = false
    @State private var showSetAltitudes = false
    @State private var profileExpanded = false
    @State private var exportItem: FlightPlanExportItem?

    // Hybrid layout (#4 redesign): wide profile strip under the map + a Waypoints/Conflicts toggle.
    enum RightTab { case waypoints, conflicts }
    @State private var rightTab: RightTab = .waypoints
    /// The leg selected in the table, on the map or from a conflict (from waypoint n to n+1),
    /// highlighted in all three where it stands. (planning proposal D3)
    @State private var selectedLeg: Int?
    @State private var profileCollapsed = false
    @State private var tripBannerDismissed = false   // v4.1.0 trip-aware prefetch banner
    @State private var showDeactivateConfirm = false   // v4.4.0 — arm/disarm from the builder
    @State private var tripPrefetchFailed = false    // v4.4.0 — coverage still incomplete after a download
    /// Which of the per-country layers is being fetched, so the banner can count instead of spin.
    @State private var prefetchStep = 0
    @State private var prefetchTotal = 0
    @State private var tripSizeEstimate: TripDataSizeEstimator.Estimate?   // v4.4.0 — what the offer costs
    @State private var tripSizeEstimateKey = ""      // the missing-set the estimate above belongs to
    @State private var isPrefetchingTrip = false
    /// Cached route→countries (the expensive resample+bbox scan) — recomputed only on route change, not
    /// every render. The cheap coverage diff stays in `tripNeededCountries`. (review #12)
    @State private var routeCountriesCache: [String] = []

    /// Live plan from the manager (single source of truth).
    private var plan: FlightPlan? {
        flightPlanManager.flightPlans.first { $0.id == planId }
    }

    private var waypoints: [FlightPlanWaypoint] { plan?.waypoints ?? [] }

    // MARK: - Trip-aware prefetch (v4.1.0)

    /// Per-country OpenAIP layers the route crosses but that aren't fully downloaded. Computed from the
    /// services directly (the builder reaches the singletons + the injected airspace service), avoiding
    /// the fragile env-injection of DataStatusManager through this full-screen cover.
    /// Recompute the cached route→countries set (the expensive part). Call on appear + route change.
    private func updateRouteCountriesCache() {
        routeCountriesCache = waypoints.count >= 2
            ? RouteDataCalculator.countries(crossing: waypoints.map { $0.coordinate })
            : []
    }

    /// The per-country layers of the trip top-up: the same providers, in the same order, as
    /// `DataStatusManager` checks (airspace, navaids, obstacles, reporting points, VFR procedures),
    /// built on the services because the manager isn't injected into this cover. The OpenAIP airport
    /// layer stays out (`OpenAIPAirportProvider.perCountryCoverage`). (6.2.0, was four hard-coded layers)
    private var tripProviders: [DataSetProvider] {
        DataStatusManager.tripProviders(airspace: openAIPDataService)
    }

    /// Missing countries PER LAYER, which is how coverage actually works: a device can hold Swiss
    /// airspace and no Swiss obstacles. Quoting a size for data already on disk would overstate the
    /// download, so the estimate needs the split even though the banner shows the union. A country a
    /// layer's source doesn't publish (open flightmaps outside CH, AT, DE, CZ) is no gap. (review #7)
    private var tripMissingByLayer: [TripDataSizeEstimator.Layer: [String]] {
        guard waypoints.count >= 2, !routeCountriesCache.isEmpty else { return [:] }
        return DataStatusManager.tripGaps(providers: tripProviders, routeCountries: routeCountriesCache)
    }

    private var tripNeededCountries: [String] {
        Set(tripMissingByLayer.values.flatMap { $0 }).sorted()
    }

    /// Download the per-country layers for the route's missing countries (merged with what's cached).
    ///
    /// If coverage is still incomplete afterwards the banner says the download failed rather than
    /// resetting to the same "Download data" offer — pressing a button, watching a spinner for ten
    /// seconds and getting the identical banner back tells a pilot nothing about whether they have the
    /// data. (device-test feedback, v4.4.0)
    private func prefetchTripData() async {
        let needed = tripNeededCountries
        guard !needed.isEmpty else { return }
        isPrefetchingTrip = true
        tripPrefetchFailed = false

        // Counted rather than spun. Each per-country layer is a separate download that can take tens
        // of seconds on a clubhouse hotspot — an indeterminate spinner for all of them tells the pilot
        // nothing about whether to keep waiting. (device pass) Each provider adds the countries to what
        // its layer holds (the union, so nothing is pruned) and skips what is already on disk.
        let providers = tripProviders
        prefetchStep = 0
        prefetchTotal = providers.count
        for provider in providers {
            await provider.prefetch(countries: needed)
            prefetchStep += 1
        }
        isPrefetchingTrip = false
        tripPrefetchFailed = !tripNeededCountries.isEmpty
    }

    /// `"France, Germany · ≈ 12 MB"`, dropping the size until the estimate lands (a few small
    /// requests) so the banner never blocks on the network to say what it already knows.
    private func tripDetailLine(_ needed: [String]) -> String {
        let names = needed.map { OpenAIPConfig.countryName(for: $0) }.joined(separator: ", ")
        guard let size = tripSizeEstimate.flatMap(TripDataSizeEstimator.displayString) else { return names }
        return "\(names) · \(size)"
    }

    /// Fetch the size estimate for whatever is currently missing. Keyed on the missing set so a route
    /// edit that doesn't change coverage doesn't re-query, and so a stale figure never survives a
    /// change that would invalidate it.
    private func refreshTripSizeEstimate() async {
        let missing = tripMissingByLayer
        let key = missing.keys.sorted { $0.rawValue < $1.rawValue }
            .map { "\($0.rawValue):\((missing[$0] ?? []).sorted().joined(separator: ","))" }
            .joined(separator: "|")
        guard key != tripSizeEstimateKey else { return }
        tripSizeEstimateKey = key
        tripSizeEstimate = nil
        guard !missing.isEmpty else { return }
        let estimate = await TripDataSizeEstimator.estimate(countriesByLayer: missing)
        // A later edit may have moved on while this was in flight; only publish if still current.
        guard key == tripSizeEstimateKey else { return }
        tripSizeEstimate = estimate.isEmpty ? nil : estimate
    }

    /// Floating, dismissible banner offered when the route crosses areas without downloaded data.
    @ViewBuilder
    private var tripDataBanner: some View {
        let needed = tripNeededCountries
        if !tripBannerDismissed, !needed.isEmpty {
            let tint: Color = tripPrefetchFailed ? .aviationAmber : .aviationGold
            HStack(spacing: 10) {
                Image(systemName: tripPrefetchFailed ? "exclamationmark.triangle" : "square.and.arrow.down")
                    .font(.aero(size: 15, weight: .semibold))
                    .foregroundColor(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tripPrefetchFailed ? L10n.Nav.tripDataFailed : L10n.Nav.tripDataMissing)
                        .font(.aero(size: 13, weight: .semibold))
                        .foregroundColor(.primaryText)
                    // Countries AND size. The offer used to name the countries and stop there, which
                    // hid the fact that adding Germany means ~30 000 obstacle records while adding
                    // Switzerland means a few hundred — the same sentence for a 200 KB download and a
                    // 12 MB one, quite possibly on a clubhouse hotspot. (v4.4.0)
                    Text(tripPrefetchFailed
                         ? L10n.Nav.tripDataFailedDetail
                         : tripDetailLine(needed))
                        .font(.aero(size: 11))
                        .foregroundColor(.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isPrefetchingTrip {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.Nav.tripDataProgress(prefetchStep, prefetchTotal))
                            .font(.aero(size: 11, design: .monospaced))
                            .foregroundColor(.secondaryText)
                    }
                } else {
                    Button(tripPrefetchFailed ? L10n.Button.retry : L10n.Settings.downloadData) {
                        Task { await prefetchTripData() }
                    }
                    .font(.aero(size: 13, weight: .semibold))
                    .foregroundColor(tint)
                    Button {
                        tripBannerDismissed = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.aero(size: 11, weight: .semibold))
                            .foregroundColor(.secondaryText)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(L10n.Button.close)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            // Near-opaque, as the From/To bar was: it sits over the chart now, and glass over a busy
            // ICAO chart left it unreadable. (planning proposal D)
            .background(Color.panelBackground.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // How much of the builder the keyboard leaves: measured here, never laid out against.
                GeometryReader { visible in
                    Color.clear
                        .onChange(of: visible.size.height, initial: true) { _, height in
                            heightAboveKeyboard = height
                        }
                }
                GeometryReader { geo in
                    // An altitude in the legs is typed where the keys would cover it (on a phone, and
                    // on an iPad whenever the system gives the field its full keyboard rather than the
                    // small pad beside it): everything slides up by what the keyboard covers, so the
                    // legs sit on the keys, and back down when it goes. Nothing resizes. (6.1.0)
                    let lift = altitudeEditingId != nil && heightAboveKeyboard > 0
                        ? max(0, geo.size.height - heightAboveKeyboard) : 0
                    // Landscape: the map on the left; From/To, the profile and the legs in a column on
                    // the right, like the navigation map. Portrait: From/To above the map rather than
                    // over it, the profile under it, then the legs, about ten of them in view. (planning
                    // proposal D1) One layout for both, so turning the iPad moves the parts instead of
                    // building them again: a field being typed in keeps its text and its keyboard.
                    RouteBuilderLayout(twoColumn: RouteBuilderLayout.isTwoColumn(
                                           regularWidth: horizontalSizeClass == .regular, size: geo.size),
                                       hasRoute: waypoints.count >= 2, lift: lift) {
                        fromToBar
                            .layoutValue(key: RouteBuilderLayout.PartKey.self, value: .fromTo)
                        mapArea
                            .layoutValue(key: RouteBuilderLayout.PartKey.self, value: .map)
                        if waypoints.count >= 2 {
                            routeProfileStrip
                                .layoutValue(key: RouteBuilderLayout.PartKey.self, value: .profile)
                        }
                        tablePanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.cockpitBackground)
                            .layoutValue(key: RouteBuilderLayout.PartKey.self, value: .legs)
                    }
                    // The 1 pt gaps the layout leaves between the parts are the dividers.
                    .background(Color.subtleOverlay(0.08))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: lift)
                    // Slid up, what passes the top edge is cut there rather than drawn under the bar.
                    // Not otherwise: the map runs on under the home indicator in two columns.
                    .clipShape(Rectangle().inset(by: lift > 0 ? 0 : -100))
                }
                // The keyboard is not part of the size read above. With it up, an iPad in portrait
                // read 820 x 757 pt, wider than tall, and the builder switched to its landscape columns
                // as soon as From, To or Via was focused (a phone sized its map from what the keys
                // left). The layout is decided, and the portrait parts sized, on the screen the pilot
                // holds: From, To and Via sit at the top and their results drop over the map, and the
                // keys cover the bottom of the legs. The waypoint editor is a sheet with its own
                // keyboard avoidance. (6.1.0)
                .ignoresSafeArea(.keyboard)
            }
            .background(Color.cockpitBackground)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: tripNeededCountries.isEmpty) // (UX-18)
            .navigationBarTitleDisplayMode(.inline)
            // Direction B: the bar stays, but the dead "Flight plan" title is replaced by the live
            // route summary, so the right column drops its summary row and starts at the toggle. (#4)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.done) { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    if waypoints.count >= 1 { toolbarSummary }
                }
                // Arm the route you just drew, while it is still on screen. Without this, building a
                // plan on a phone ends at Done → back to the list → find the row → Activate, or four
                // taps through the nav-log sheet. (v4.4.0 device-test feedback)
                //
                // Icon-only on both sizes. A labelled variant was tried for iPad — a navigation bar
                // renders a `Label` icon-only regardless, `.labelStyle(.titleAndIcon)` included — and
                // it would have been the odd one out anyway beside the nav-log and export icons.
                // The colour carries the state: green to arm, amber to disarm, matching the buttons
                // in the plan list.
                ToolbarItem(placement: .primaryAction) {
                    Button { toggleActivation() } label: {
                        Image(systemName: isPlanActive ? "airplane.arrival" : "airplane.departure")
                            .foregroundColor(isPlanActive ? .aviationAmber : .aviationGreen)
                    }
                    .disabled(waypoints.isEmpty)
                    .accessibilityLabel(isPlanActive ? L10n.Nav.deactivateFlightPlan : L10n.Nav.activateFlightPlan)
                }
                // Nav Log + Export GPX. Two surfaced icons on iPad, where there is room; folded into
                // one overflow menu on iPhone, because Done + summary + Activate + two icons is one
                // item too many — the principal route summary collapsed to "8 … · … · 1…". The
                // summary is the more useful of the two, so the secondary actions give way.
                if horizontalSizeClass == .compact {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { showTableEditor = true } label: {
                                Label(L10n.Nav.navLog, systemImage: "list.clipboard")
                            }
                            .disabled(waypoints.isEmpty)
                            Button { exportGPX() } label: {
                                Label(L10n.Nav.exportGPX, systemImage: "square.and.arrow.up")
                            }
                            .disabled(waypoints.count < 2)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(L10n.DataStorage.rowActions)
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showTableEditor = true } label: {
                            Image(systemName: "list.clipboard")
                        }
                        .disabled(waypoints.isEmpty)
                        .accessibilityLabel(L10n.Nav.navLog)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { exportGPX() } label: {
                            Image(systemName: "square.and.arrow.up").foregroundColor(.aviationGold)
                        }
                        .disabled(waypoints.count < 2)
                        .accessibilityLabel(L10n.Nav.exportGPX)
                    }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: focusToken)
            .alert(L10n.Nav.deactivateConfirmTitle, isPresented: $showDeactivateConfirm) {
                Button(L10n.Button.cancel, role: .cancel) { }
                Button(L10n.Nav.deactivate, role: .destructive) { flightPlanManager.deactivateFlightPlan() }
            } message: {
                Text(L10n.Nav.deactivateConfirmMessage)
            }
            .sheet(isPresented: $showTableEditor) {
                if let plan {
                    FlightPlanEditorView(flightPlan: plan)
                        .environment(appState)
                        .environmentObject(flightPlanManager)
                        .environmentObject(airportDataService)
                        .environmentObject(openAIPDataService)
                }
            }
            .sheet(item: $editingWaypoint) { waypoint in
                WaypointEditorSheet(
                    waypoint: waypoint,
                    aircraftType: plan?.aircraftTypeId ?? "WT9",
                    cruiseAirspeed: plan.flatMap { plan in
                        plan.waypoints.firstIndex { $0.id == waypoint.id }.map { plan.cruiseAirspeed(ofLegFrom: $0) }
                    } ?? Int(CruiseSpeedModel.standardKIAS),
                    onSave: { updated in flightPlanManager.updateWaypoint(updated, in: planId) },
                    onDelete: { flightPlanManager.removeWaypoint(waypoint, from: planId) }
                )
                .environment(appState)
                .environmentObject(airportDataService)
            }
            .sheet(item: $exportItem) { item in
                ShareSheet(activityItems: [item.file])
            }
            .sheet(isPresented: $showSetAltitudes) {
                if let plan {
                    SetAltitudesSheet(plan: plan) { altitudes in
                        flightPlanManager.setAltitudes(altitudes, in: planId)
                    }
                    .environmentObject(openAIPDataService)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            Task {
                await airportDataService.ensureLoaded()
                scheduleAirportUpdate()
                await OpenAIPNavaidDataService.shared.ensureLoaded()
                scheduleNavaidUpdate()
            }
            initialFitIfNeeded()
            updateRouteCountriesCache()
            Task { await refreshTripSizeEstimate() }
            scheduleAirspaceUpdate()
            scheduleTerrainUpdate()
            scheduleWindsAloftUpdate()
        }
        .onChange(of: region.center.latitude) { _, _ in scheduleAirportUpdate(); scheduleNavaidUpdate() }
        .onChange(of: region.center.longitude) { _, _ in scheduleAirportUpdate(); scheduleNavaidUpdate() }
        // The procedures depend on the zoom (40 NM, labels 20 NM), the data and the palette. (6.2.0)
        .onChange(of: region.span.latitudeDelta) { _, _ in scheduleNavaidUpdate() }
        .onChange(of: vfrProcedureService.revision) { _, _ in scheduleNavaidUpdate() }
        .onChange(of: theme.mode) { _, _ in scheduleNavaidUpdate() }
        // Recompute on-route hazards (airspace + terrain) whenever the route geometry changes (#4).
        .onChange(of: routeGeometryKey) { _, _ in
            selectedConflictId = nil; scheduleAirspaceUpdate(); scheduleTerrainUpdate(); scheduleWindsAloftUpdate()
            updateRouteCountriesCache()
            Task { await refreshTripSizeEstimate() }
        }
        .onChange(of: openAIPDataService.isDataAvailable) { _, _ in scheduleAirspaceUpdate() }
        // isDataAvailable is metadata-restored at launch (already true before first appear), so the
        // async feature decode landing must retrigger via the count — same first-open race as the
        // nav map. (v4.2 fix)
        .onChange(of: openAIPDataService.airspaceCount) { _, _ in scheduleAirspaceUpdate() }
    }

    /// Full-geometry signature (every waypoint's coordinate AND planned altitude) so the airspace scan
    /// re-runs when an intermediate point moves OR an altitude is edited — unlike `routeSignature`,
    /// which only watches the endpoints + count.
    private var routeGeometryKey: String {
        waypoints.map { wp in
            let alt = wp.altitude.map { String(Int($0)) } ?? "-"
            return String(format: "%.4f,%.4f", wp.latitude, wp.longitude) + ",\(alt)"
        }.joined(separator: "|")
    }

    // MARK: - Map area

    private var mapArea: some View {
        RouteBuilderMapView(
            waypoints: waypoints,
            mapLayer: selectedLayer,
            airports: visibleAirports,
            navaids: visibleNavaids,
            reportingPoints: visibleReportingPoints,
            obstacles: visibleObstacles,
            airspacePolygons: airspacePolygons,
            selectedAirspaceId: selectedConflictId,
            focusRegion: focusRegion,
            focusToken: focusToken,
            fitRouteToken: fitRouteToken,
            region: $region,
            // "+" on an aerodrome, navaid or reporting point: a planning control, so never offered
            // while flying (a builder left open under a flight started from the widget). (6.0.1)
            onPointAdd: appState.isFlightActive ? nil : { point in addPoint(point) },
            onMoveWaypoint: { index, coord in moveWaypoint(at: index, to: coord) },
            onInsertWaypoint: { afterIndex, coord in insertRouteWaypoint(afterIndex: afterIndex, at: coord) },
            onAddWaypoint: { coord in smartAddWaypoint(at: coord) },
            selectedLeg: selectedLeg,
            conflictLegs: Set(legConflicts.keys),
            onSelectWaypoint: { index in selectLeg(index) },
            vfrContent: vfrContent,
            onOpenOfficialChart: { openURL($0) }
        )
        .ignoresSafeArea(edges: .bottom)
        // From and To sit above the map now, not over it (planning proposal D1); what they find
        // drops over the map's top, under them, as does the missing-data banner (it covered them).
        .overlay(alignment: .top) { tripDataBanner }
        .overlay(alignment: .top) {
            if viaFocused, !viaResultsQuery.isEmpty,
               viaResultsQuery == viaText.trimmingCharacters(in: .whitespaces) {
                ViaSearchResults(results: viaResults, query: viaResultsQuery) { pickVia($0) }
                    .background(Color.panelBackground.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
        }
        .overlay(alignment: .top) {
            if focusedEndpoint != nil && !searchResults.isEmpty {
                airportResults { airport in
                    if let slot = focusedEndpoint { setEndpoint(slot, airport) }
                }
                .background(Color.panelBackground.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
        }
        // Map-type + Layers buttons bottom-left, center/fit bottom-right. (v4.1.0 two-button)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 10) {
                mapTypeButton
                dataLayersButton
            }
            .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            fitRouteButton
                .padding(12)
        }
    }

    /// From → To endpoint bar — the destination-first entry. Type/select airfields to seed a direct
    /// route (or change the endpoints of an existing one); intermediate waypoints come from tapping the
    /// map / airport markers, or the Table. (flight-plan revamp #2)
    private var fromToBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                endpointField(.from)
                Button { swapEndpoints() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.aero(size: 13, weight: .semibold))
                        .foregroundColor(waypoints.count >= 2 ? .secondaryText : .dimText.opacity(0.4))
                        .frame(width: 44, height: 44)
                }
                .disabled(waypoints.count < 2)
                .accessibilityLabel(L10n.Nav.swapEndpoints)
                endpointField(.to)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Through where: once there is a destination to go via. (6.0.1)
            if waypoints.count >= 2 {
                ViaSearchField(text: $viaText, focused: $viaFocused)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.panelBackground)
        .onChange(of: viaText) { _, q in scheduleViaSearch(q) }
        .onChange(of: fromText) { _, q in if focusedEndpoint == .from { scheduleSearch(q) } }
        .onChange(of: toText) { _, q in if focusedEndpoint == .to { scheduleSearch(q) } }
        .onChange(of: focusedEndpoint) { _, _ in searchTask?.cancel(); searchResults = [] }
        .onChange(of: routeSignature) { _, _ in if focusedEndpoint == nil { syncEndpointText() } }
        .onAppear { syncEndpointText() }
    }

    private func endpointField(_ slot: RouteEndpoint) -> some View {
        HStack(spacing: 6) {
            Text(slot == .from ? L10n.Nav.from : L10n.Nav.to)
                .font(.aero(size: 11, weight: .semibold)).tracking(0.6).foregroundColor(.dimText)
                .accessibilityHidden(true)   // the field carries the name
            // The label already says From or To: the empty field says what to type, as Plan new flight
            // does. It read "From  From" and "To  To". The field's own prompt stays empty: the
            // placeholder is drawn over it so it can shrink on a phone instead of being cut. (6.1.0)
            TextField(slot == .from ? L10n.Nav.from : L10n.Nav.to,
                      text: slot == .from ? $fromText : $toText, prompt: Text(verbatim: ""))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.aero(size: 17, weight: .semibold, design: .monospaced))
                .foregroundColor(slot == .from ? .aviationGreen : .aviationGold)
                .focused($focusedEndpoint, equals: slot)
                .modifier(FittingPlaceholder(text: L10n.Flights.identPlaceholder,
                                             isShown: (slot == .from ? fromText : toText).isEmpty,
                                             font: .aero(size: 17, weight: .semibold, design: .monospaced)))
                .accessibilityHint(L10n.Flights.identPlaceholder)
        }
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.subtleOverlay(0.06)))
    }

    private func airportResults(onSelect: @escaping (Airport) -> Void) -> some View {
        let reference = searchReference
        return VStack(spacing: 0) {
            ForEach(searchResults.prefix(6)) { airport in
                Button { onSelect(airport) } label: {
                    HStack(spacing: 10) {
                        Text(airport.ident)
                            .font(.aero(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.aviationGold)
                            .frame(width: 58, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(airport.name)
                                .font(.aero(size: 13))
                                .foregroundColor(.primaryText)
                                .lineLimit(1)
                            if let muni = airport.municipality, !muni.isEmpty, muni != airport.name {
                                Text(muni)
                                    .font(.aero(size: 10))
                                    .foregroundColor(.dimText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        if let dist = distanceLabel(to: airport, from: reference) {
                            Text(dist)
                                .font(.aero(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondaryText)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if airport.id != searchResults.prefix(6).last?.id {
                    Divider().background(Color.subtleOverlay(0.06))
                }
            }
        }
    }

    /// Endpoint-change signature, to re-sync the field text when the route changes elsewhere (map tap).
    private var routeSignature: String { "\(waypoints.first?.name ?? "")|\(waypoints.last?.name ?? "")|\(waypoints.count)" }

    /// Reference point for ordering search results by distance (feedback #2): a destination sorts
    /// relative to the departure (or, failing that, where you are / the map you're looking at); a
    /// departure sorts relative to your position (or a set destination / the map).
    private var searchReference: CLLocationCoordinate2D? {
        let here = locationManager.getCurrentCoordinate()
        switch focusedEndpoint {
        case .to:
            return waypoints.first?.coordinate ?? here ?? region.center
        case .from, .none:
            return here ?? (waypoints.count >= 2 ? waypoints.last?.coordinate : nil) ?? region.center
        }
    }

    /// Debounced, distance-aware, fixed-wing-only airport search. Debouncing keeps each keystroke off
    /// the ~40K-airport scan (feedback #1 perf); `near:`/`types:` apply the distance sort + heliport
    /// filter (feedback #2/#3). Runs on the main actor (the service is `@MainActor`); the sleep simply
    /// coalesces bursts of typing into one scan.
    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { searchResults = []; return }
        let reference = searchReference
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let results = airportDataService.searchAirports(
                query: trimmed, limit: 12, near: reference, types: AirportType.fixedWing)
            guard !Task.isCancelled else { return }
            searchResults = results
        }
    }

    /// The "Via" search, debounced like the airfield search: reporting points and navaids by name,
    /// aerodrome or ident, nearest the route first within a rank (`RoutePointSearch`). (6.0.1)
    private func scheduleViaSearch(_ query: String) {
        viaSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { viaResults = []; viaResultsQuery = ""; return }
        let route = waypoints.map(\.coordinate)
        let reference = region.center
        let nonPowered = appState.settings.showsNonPoweredReportingPoints
        viaSearchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let catalog = ReportingPointCatalog.shared
            await catalog.ensureLoaded()
            await OpenAIPNavaidDataService.shared.ensureLoaded()
            guard !Task.isCancelled else { return }
            let results = RoutePointSearch.search(
                trimmed,
                reportingPoints: catalog.allPoints(includingNonPowered: nonPowered),
                aerodrome: catalog.aerodrome(for:),
                navaids: OpenAIPNavaidDataService.shared.allLoadedNavaids(),
                route: route, reference: reference)
            guard !Task.isCancelled else { return }
            viaResults = results
            viaResultsQuery = trimmed
        }
    }

    /// A "Via" result goes in like the callout's "+": itself, on the leg it least lengthens.
    private func pickVia(_ result: RoutePointSearch.Result) {
        addPoint(result.point)
        viaSearchTask?.cancel()
        viaText = ""
        viaResults = []
        viaResultsQuery = ""
        viaFocused = false
    }

    /// Great-circle distance from a reference point to an airport, shown on each result row so the
    /// distance ordering is legible.
    private func distanceLabel(to airport: Airport, from reference: CLLocationCoordinate2D?) -> String? {
        guard let reference = reference else { return nil }
        let from = CLLocation(latitude: reference.latitude, longitude: reference.longitude)
        let to = CLLocation(latitude: airport.latitude, longitude: airport.longitude)
        return String(format: "%.0f NM", from.distance(from: to) / 1852.0)
    }

    private func syncEndpointText() {
        fromText = waypoints.first?.name ?? ""
        toText = waypoints.count >= 2 ? (waypoints.last?.name ?? "") : ""
    }

    /// Set the FROM or TO endpoint to an airfield — seeds a direct route, or updates the endpoint of an
    /// existing one (reusing the ident name + auto frequency + elevation). (flight-plan revamp #2)
    private func setEndpoint(_ slot: RouteEndpoint, _ airport: Airport) {
        switch slot {
        case .from:
            if var wp = waypoints.first {
                apply(.aerodrome(airport), to: &wp)
                flightPlanManager.updateWaypoint(wp, in: planId)
            } else {
                addPoint(.aerodrome(airport))
            }
            fromText = airport.ident
        case .to:
            if waypoints.count >= 2, var wp = waypoints.last {
                apply(.aerodrome(airport), to: &wp)
                flightPlanManager.updateWaypoint(wp, in: planId)
            } else {
                addPoint(.aerodrome(airport)) // appends → makes [from, to] (or the only point)
            }
            toText = airport.ident
        }
        focusedEndpoint = nil
        searchResults = []
        fitRouteToken += 1
    }

    /// Makes an existing waypoint `point` (a snap, a new endpoint). Only fills an elevation when no
    /// altitude is set, so a snap doesn't clobber a pilot's planned altitude (v4.0.0 review P2), and
    /// only clears the radio an earlier snap wrote, so what the pilot typed stays (6.0.1).
    private func apply(_ point: RoutePoint, to wp: inout FlightPlanWaypoint) {
        let asEndpoint = isRouteEndpoint(wp)
        let earlier = earlierSnapValues(on: wp)
        point.apply(to: &wp, asEndpoint: asEndpoint, contactFrequency: contactFrequency(for: point), replacing: earlier)
    }

    /// The call sign and frequencies the point `wp` was snapped to may have written, by this build or
    /// an older one (which recorded no source: then the aerodrome or navaid it is named after and sits
    /// on). Nothing for the pilot's own point. (6.0.1)
    private func earlierSnapValues(on wp: FlightPlanWaypoint) -> SnapValues {
        let here = wp.coordinate
        let candidates: [RoutePoint] = [
            airportDataService.nearestAirport(to: here, maxDistanceNm: RoutePoint.originToleranceNM).map { .aerodrome($0) },
            OpenAIPNavaidDataService.shared.nearestNavaid(to: here, maxDistanceNm: RoutePoint.originToleranceNM).map { .navaid($0) },
        ].compactMap { $0 }
        guard let origin = RoutePoint.origin(of: wp, among: candidates) else { return .none }
        guard case .aerodrome(let airport) = origin else { return origin.snapValues() }
        return origin.snapValues(aerodromeFrequencies: airportDataService.getFrequencies(for: airport.ident)
            .map(\.formattedFrequency))
    }

    /// An aerodrome's CONTACT frequency (TWR › AFIS › INFO …) ahead of its listen-only ATIS, which the
    /// old pick preferred over AFIS: this value is printed as the station to call on the nav log.
    private func contactFrequency(for point: RoutePoint) -> String? {
        guard case .aerodrome(let airport) = point else { return nil }
        return airportDataService.bestFieldFrequency(for: airport.ident)?.formattedFrequency
    }

    /// Ground elevation is a sensible altitude only where the aircraft is ON the ground: the departure
    /// and the destination. Mid-route, it would be a planned altitude along the terrain.
    private func isRouteEndpoint(_ wp: FlightPlanWaypoint) -> Bool {
        wp.id == waypoints.first?.id || wp.id == waypoints.last?.id
    }

    /// What a point dropped or dragged at `coordinate` snaps to, if anything: one rule for the move,
    /// the press-and-hold add and the drag off the route line (which used to snap to aerodromes
    /// only). (6.0.1)
    private func snapTarget(near coordinate: CLLocationCoordinate2D) -> RoutePoint? {
        RoutePoint.snapTarget(
            near: coordinate,
            aerodrome: airportDataService.nearestAirport(to: coordinate, maxDistanceNm: snapRadiusNm,
                                                          types: AirportType.fixedWing),
            navaid: OpenAIPNavaidDataService.shared.nearestNavaid(to: coordinate, maxDistanceNm: snapRadiusNm),
            reportingPoint: reportingPointSnapCandidate(near: coordinate)
                .map { ($0, ReportingPointCatalog.shared.label(for: $0)) })
    }

    /// Nearest reporting point eligible for snap — only when the RP layer is shown, within a tighter
    /// radius than airports/navaids (they're dense, so snap should be deliberate). (v4.1.0 ③)
    private func reportingPointSnapCandidate(near coordinate: CLLocationCoordinate2D) -> ReportingPoint? {
        guard appState.settings.showReportingPointsOnMap else { return nil }
        return ReportingPointCatalog.shared
            .pointsNear(to: coordinate, maxDistanceNm: rpSnapRadiusNm, limit: 1,
                        includingNonPowered: appState.settings.showsNonPoweredReportingPoints).first
    }

    private func swapEndpoints() {
        flightPlanManager.reverseRoute(planId: planId)
        syncEndpointText()
        fitRouteToken += 1
    }

    /// Binding to a builder map-data toggle that persists + refreshes the visible layers. (v4.1.0 ③)
    private func dataLayerBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { appState.settings[keyPath: keyPath] },
            set: { appState.settings[keyPath: keyPath] = $0; appState.saveSettings(); scheduleNavaidUpdate() }
        )
    }

    /// Map-type button — icon only (mirrors the nav view's two-button chrome). (v4.1.0)
    private var mapTypeButton: some View {
        Menu {
            Picker("Map layer", selection: $selectedLayer) {
                ForEach(WaypointPickerMapLayer.allCases) { layer in
                    Label(layer.rawValue, systemImage: layer.icon).tag(layer)
                }
            }
        } label: {
            Image(systemName: selectedLayer.icon)
                .font(.aero(size: 16, weight: .semibold))
                .foregroundColor(.primaryText)
                .frame(width: 44, height: 44)
                .background(Color.panelBackground.opacity(0.92), in: Circle())
        }
        .accessibilityLabel(L10n.MapLayer.title)
    }

    /// Layers button — toggles the OpenAIP map-data layers on/off. (v4.1.0)
    private var dataLayersButton: some View {
        Menu {
            Toggle(L10n.DataStorage.navaidsName, isOn: dataLayerBinding(\.showNavaidsOnMap))
            Toggle(L10n.DataStorage.reportingPointsName, isOn: dataLayerBinding(\.showReportingPointsOnMap))
            Toggle(L10n.DataStorage.obstaclesName, isOn: dataLayerBinding(\.showObstaclesOnMap))
            // The aerodrome procedures (6.2.0), as in the Map sheet.
            Section(L10n.VFRMap.aerodromeProcedures) {
                Toggle(L10n.VFRMap.showCircuits, isOn: dataLayerBinding(\.showVFRCircuitsOnMap))
                Toggle(L10n.VFRMap.showRoutes, isOn: dataLayerBinding(\.showVFRRoutesOnMap))
                Toggle(L10n.VFRMap.showNonPowered, isOn: dataLayerBinding(\.showNonPoweredCircuitsOnMap))
            }
        } label: {
            Image(systemName: "square.stack.3d.up")
                .font(.aero(size: 16, weight: .semibold))
                .foregroundColor(.primaryText)
                .frame(width: 44, height: 44)
                .background(Color.panelBackground.opacity(0.92), in: Circle())
        }
        .accessibilityLabel(L10n.Nav.layers)
    }

    private var fitRouteButton: some View {
        Button { fitRouteToken += 1 } label: {
            Image(systemName: "scope")
                .font(.aero(size: 16, weight: .semibold))
                .foregroundColor(.primaryText)
                .frame(width: 44, height: 44)
                .background(Color.panelBackground.opacity(0.92), in: Circle())
        }
        .disabled(waypoints.isEmpty)
        .opacity(waypoints.isEmpty ? 0.4 : 1)
        .accessibilityLabel("Fit route")
    }

    // MARK: - Side / bottom panel

    // MARK: - Hybrid layout: map + bottom profile strip (left) · summary + toggle (right) (#4 redesign)

    /// The legs, or the conflicts list. The Waypoints | Conflicts tabs are gone: the legs are what
    /// the editor is for, and a conflict now shows on its leg (⚠ in its row, an amber pin, a mark on
    /// the profile). The list stays one tap away, on the "⚠ N conflicts" chip, for the details and
    /// for highlighting one on the profile and the map. (planning proposal D2, and its note)
    private var tablePanel: some View {
        VStack(spacing: 0) {
            if rightTab == .conflicts && waypoints.count >= 2 {
                conflictsHeader
                conflictsTabContent
            } else if waypoints.isEmpty {
                emptyRouteHint
            } else {
                waypointListHeader
                if hasNoPlannedAltitudes { noAltitudesBanner }
                if horizontalSizeClass != .compact { legColumnsHeader }
                waypointList
            }
        }
        .background(Color.cockpitBackground)
        .onChange(of: waypoints.count) { _, count in
            if count < 2 { listEditMode = .inactive; rightTab = .waypoints }
            if let leg = selectedLeg, leg >= count { selectedLeg = nil }
        }
    }

    private var conflictsHeader: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { rightTab = .waypoints }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                    Text(L10n.RouteEditor.legs)
                }
                .font(.aero(size: 15, weight: .semibold))
                .foregroundColor(.altimeterBlue)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text(L10n.Nav.conflictsTab.uppercased())
                .font(.aero(size: 12, weight: .bold, design: .monospaced)).tracking(1.2)
                .foregroundColor(hazardTint)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Legs and their conflicts (planning proposal D)

    /// Along-track distance at each waypoint, from the legs' own distances.
    private var cumulativeNM: [Double] {
        var result: [Double] = [0]
        for waypoint in waypoints.dropLast() { result.append(result.last! + (waypoint.distance ?? 0)) }
        return result
    }

    /// The leg (from waypoint n) a distance along the route falls on.
    private func leg(atNM nm: Double) -> Int? {
        let cum = cumulativeNM
        guard cum.count >= 2 else { return nil }
        for index in 0..<(cum.count - 1) where nm < cum[index + 1] { return index }
        return cum.count - 2
    }

    /// The conflicting airspaces each leg crosses, by leg (from waypoint n), in the order they start.
    private var legConflicts: [Int: [String]] {
        let cum = cumulativeNM
        guard cum.count >= 2 else { return [:] }
        var result: [Int: [String]] = [:]
        for block in airspaceBlocks.filter(\.isConflict).sorted(by: { $0.startNM < $1.startNM }) {
            for index in 0..<(cum.count - 1) where block.startNM < cum[index + 1] && block.endNM > cum[index] {
                result[index, default: []].append(block.id)
            }
        }
        return result
    }

    /// Select a leg, from the table or a pin. Selecting the selected row again opens its waypoint.
    private func selectLeg(_ index: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            selectedLeg = index
            // A conflict of another leg no longer applies to what's selected.
            if let id = selectedConflictId, !(legConflicts[index]?.contains(id) ?? false) { selectedConflictId = nil }
        }
    }

    /// Collapsible wide route-profile strip under the map; expand to a full-screen profile (replaces the
    /// old Terrain sheet).
    private var routeProfileStrip: some View {
        VStack(spacing: 0) {
            // A 44 pt control strip. The glyphs stay 12 pt — what changed is the HIT BOX: each button
            // now owns a full 44 × 44 target, and the title itself is the collapse control (the
            // disclosure convention), so most of the row is tappable. Previously the only tappable
            // area WAS the glyph — a ~12 pt target on a phone, far under the 44 pt minimum the rest of
            // the app honours, and effectively unhittable one-handed. (device-test feedback, v4.4.0)
            HStack(spacing: 0) {
                Button { toggleProfileCollapsed() } label: {
                    HStack(spacing: 0) {
                        Text(L10n.Nav.routeProfileTitle.uppercased())
                            .font(.aero(size: 10, weight: .semibold)).tracking(0.6)
                            .foregroundColor(.secondaryText)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(profileCollapsed ? L10n.Nav.showProfile : L10n.Nav.collapseProfile)

                if !profileCollapsed {
                    // Resize the profile IN PLACE (no popup) — taller = easier to read / edit precisely.
                    Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { profileExpanded.toggle() } } label: { // (UX-18)
                        Image(systemName: profileExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.aero(size: 12, weight: .semibold))
                            .foregroundColor(.secondaryText)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(profileExpanded ? L10n.Nav.shrinkProfile : L10n.Nav.expandProfile)
                }
                Button { toggleProfileCollapsed() } label: {
                    Image(systemName: profileCollapsed ? "chevron.up" : "chevron.down").font(.aero(size: 12, weight: .bold))
                        .foregroundColor(.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(profileCollapsed ? L10n.Nav.showProfile : L10n.Nav.collapseProfile)
            }
            .padding(.leading, 14).padding(.trailing, 2)
            if !profileCollapsed {
                RouteProfileView(waypoints: waypoints, terrain: terrainData, blocks: airspaceBlocks,
                                 selectedId: selectedConflictId, terrainId: Self.terrainConflictId,
                                 visibleRegion: region,
                                 selectedLeg: selectedLeg,
                                 onSetAltitude: { index, alt in setWaypointAltitude(index, alt) },
                                 onAddAtDistance: { nm, alt in addProfilePoint(atNM: nm, altitude: alt) })
                    .frame(height: profileExpanded ? 300 : (horizontalSizeClass == .compact ? 100 : 136))
                    .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .background(Color.cockpitBackground)
    }

    private var isPlanActive: Bool { flightPlanManager.activeFlightPlan?.id == planId }

    /// Arm or disarm this plan from the builder. Deactivation confirms only when there is recorded
    /// progress to lose — same rule as the plan list. (v4.4.0)
    private func toggleActivation() {
        guard let plan else { return }
        if isPlanActive {
            if flightPlanManager.activePlanHasRecordedProgress {
                showDeactivateConfirm = true
            } else {
                flightPlanManager.deactivateFlightPlan()
            }
        } else {
            flightPlanManager.activateFlightPlan(plan)
        }
    }

    private func toggleProfileCollapsed() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { profileCollapsed.toggle() } // (UX-18)
    }

    private var hazardCount: Int { crossedAirspaces.count + (terrainWarning ? 1 : 0) }
    /// Whether any OpenAIP airspace data is actually loaded to check the route against. Airspace
    /// download is opt-in and off by default, so an empty conflict set means "not checked", NOT
    /// "clear" — never show a green all-clear when this is false.
    private var airspaceChecked: Bool { openAIPDataService.isDataAvailable }
    /// The terrain equivalent of `airspaceChecked`, and it exists for the same reason: `terrainWarning`
    /// collapses to `false` when the check could not run at all, which is indistinguishable from
    /// "checked and clear" unless we track it separately. `minTerrainClearanceFt` is nil whenever the
    /// route has no elevation data (it is swisstopo-backed, so empty outside Switzerland, and also
    /// empty while the debounced fetch is still in flight) or the waypoints carry no planned altitudes
    /// to measure clearance against. In every one of those cases terrain went unchecked.
    private var terrainChecked: Bool { minTerrainClearanceFt != nil }
    /// Both checks must have actually run before the route may be called clear. `nav.noConflicts`
    /// reads "No airspace or terrain conflicts" — it claims both, so it must be earned by both.
    private var routeFullyChecked: Bool { airspaceChecked && terrainChecked }
    private var hazardTint: Color {
        if hazardCount == 0 { return routeFullyChecked ? .aviationGreen : .aviationAmber }
        if terrainWarning || crossedAirspaces.contains(where: { $0.isRestrictive }) { return .aviationRed }
        return .aviationAmber
    }

    /// Conflicts tab body — the hazard list, a genuine "clear" state, or a "not checked" state. The
    /// green all-clear is shown ONLY when BOTH the airspace and terrain checks actually ran; an empty
    /// conflict set from a check that never ran means "not checked", never "clear".
    @ViewBuilder private var conflictsTabContent: some View {
        if hasHazards {
            // Either check can fire while the other never ran; flag whichever went unchecked so the
            // hazard list isn't read as a complete clearance.
            if !airspaceChecked { notCheckedBanner(L10n.Nav.airspaceNotChecked) }
            if !terrainChecked { notCheckedBanner(L10n.Nav.terrainNotChecked) }
            conflictsList
            Spacer(minLength: 0)
        } else if routeFullyChecked {
            clearStateView
        } else {
            notCheckedView
        }
    }

    /// Genuine all-clear: both checks ran and nothing on the route conflicts.
    private var clearStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.shield.fill").font(.aero(size: 36)).foregroundColor(.aviationGreen)
            Text(L10n.Nav.noConflicts).font(.aero(size: 13)).foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    /// One or both route checks did not run — never a green all-clear for a check that never happened.
    /// Renders a block per unchecked item so the pilot is told exactly WHICH check is missing rather
    /// than a generic warning. Mirrors the airport no-data handling (scheduleAirportUpdate guards on
    /// isDataAvailable).
    private var notCheckedView: some View {
        VStack(spacing: 20) {
            Spacer()
            if !airspaceChecked {
                notCheckedBlock(title: L10n.Nav.airspaceNotChecked, detail: L10n.Nav.airspaceNotCheckedDetail)
            }
            if !terrainChecked {
                notCheckedBlock(title: L10n.Nav.terrainNotChecked, detail: L10n.Nav.terrainNotCheckedDetail)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private func notCheckedBlock(title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill").font(.aero(size: 36)).foregroundColor(.aviationAmber)
            Text(title).font(.aero(size: 14, weight: .semibold)).foregroundColor(.primaryText)
                .multilineTextAlignment(.center)
            Text(detail).font(.aero(size: 12)).foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    /// Compact note above the hazard list when one check fired while the other never ran, so a
    /// partial hazard list is not mistaken for a complete clearance.
    private func notCheckedBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill").foregroundColor(.aviationAmber)
            Text(text).font(.aero(size: 12, weight: .medium))
                .foregroundColor(.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.aviationAmber.opacity(0.12))
        .accessibilityElement(children: .combine)
    }

    // MARK: - On-route hazards: route check + profile + conflict list (#4 redesign)

    private var terrainWarning: Bool { (minTerrainClearanceFt.map { $0 < Self.terrainWarnFt }) ?? false }
    private var hasHazards: Bool { !crossedAirspaces.isEmpty || terrainWarning }
    private static let terrainWarnFt: Double = 150 * 3.28084 // 150 m ≈ 492 ft

    /// One-line route status above the profile: green when clear, amber for plain airspace, red for a
    /// restricted zone or a terrain-clearance bust.
    /// The genuine conflicts in the Conflicts tab: a terrain row (if too close) + each conflicting
    /// airspace.
    private var conflictsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if terrainWarning {
                    terrainWarnRow
                    if !crossedAirspaces.isEmpty { Divider().background(Color.subtleOverlay(0.06)) }
                }
                ForEach(crossedAirspaces) { airspace in
                    airspaceRow(airspace)
                    if airspace.id != crossedAirspaces.last?.id {
                        Divider().background(Color.subtleOverlay(0.06))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Toggle selection of a conflict — highlights it on the map and in the route profile. (#4 feedback)
    private func selectConflict(_ id: String) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { // (UX-18)
            selectedConflictId = (selectedConflictId == id) ? nil : id
            // …and the leg it starts on, so the three views agree. (planning proposal D3)
            if selectedConflictId != nil, let block = airspaceBlocks.first(where: { $0.id == id }) {
                selectedLeg = leg(atNM: block.startNM)
            }
        }
    }

    /// A left-to-right fill that sweeps across a conflict row while it's being held, so the
    /// hold-to-center is discoverable and you can see it's about to fire. (#4 feedback)
    @ViewBuilder private func holdFill(_ id: String) -> some View {
        if holdCenterId == id {
            GeometryReader { geo in
                Rectangle().fill(Color.subtleOverlay(0.10)).frame(width: geo.size.width * holdCenterProgress)
            }
        }
    }

    private func updateHold(_ id: String, pressing: Bool) {
        if pressing {
            holdCenterId = id; holdCenterProgress = 0
            withAnimation(reduceMotion ? nil : .linear(duration: 0.6)) { holdCenterProgress = 1 } // (UX-18)
        } else {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { holdCenterProgress = 0 } // (UX-18)
            holdCenterId = nil
        }
    }

    /// Hold a conflict → select it AND recenter the map on it, so a small zone you can't see when
    /// zoomed out is brought into view. (#4 feedback)
    private func centerOnConflict(_ id: String) {
        selectedConflictId = id
        if id == Self.terrainConflictId {
            if let c = lowestClearanceCoordinate() {
                focusRegion = MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15))
                focusToken += 1
            }
            return
        }
        guard let a = crossedAirspaces.first(where: { $0.id == id }) else { return }
        if let box = a.boundingBox {
            let center = CLLocationCoordinate2D(latitude: (box.minLat + box.maxLat) / 2, longitude: (box.minLon + box.maxLon) / 2)
            let span = MKCoordinateSpan(latitudeDelta: max(0.04, (box.maxLat - box.minLat) * 1.8),
                                        longitudeDelta: max(0.04, (box.maxLon - box.minLon) * 1.8))
            focusRegion = MKCoordinateRegion(center: center, span: span)
        } else if let c = a.centroid {
            focusRegion = MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12))
        }
        focusToken += 1
    }

    /// Coordinate of the lowest terrain clearance along the route (for hold-to-center on the terrain row).
    private func lowestClearanceCoordinate() -> CLLocationCoordinate2D? {
        guard !terrainData.isEmpty, let terrMax = terrainData.last?.distance, terrMax > 0 else { return nil }
        let prof = RouteAltitudeProfile(waypoints)
        guard prof.hasUsableProfile, prof.totalNM > 0 else { return nil }
        var worst: (clearance: Double, nm: Double)?
        for p in terrainData {
            let nm = (p.distance / terrMax) * prof.totalNM
            guard let alt = prof.altitude(atNM: nm) else { continue }
            let clr = alt - p.elevation * 3.28084
            if worst == nil || clr < worst!.clearance { worst = (clr, nm) }
        }
        guard let w = worst else { return nil }
        return coordinate(atNM: w.nm)
    }

    /// Interpolate the route coordinate at a given along-track distance (NM).
    private func coordinate(atNM target: Double) -> CLLocationCoordinate2D? {
        guard waypoints.count >= 2 else { return waypoints.first?.coordinate }
        var cum = 0.0
        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i].coordinate, b = waypoints[i + 1].coordinate
            let seg = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852.0
            if target <= cum + seg || i == waypoints.count - 2 {
                let t = seg > 0 ? min(1, max(0, (target - cum) / seg)) : 0
                return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                              longitude: a.longitude + (b.longitude - a.longitude) * t)
            }
            cum += seg
        }
        return waypoints.last?.coordinate
    }

    private var terrainWarnRow: some View {
        let selected = selectedConflictId == Self.terrainConflictId
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color.aviationRed).frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Nav.terrainProximity)
                    .font(.aero(size: 13, weight: .semibold)).foregroundColor(.primaryText)
                Text(L10n.Nav.terrainProximityDetail)
                    .font(.aero(size: 10)).foregroundColor(.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let c = minTerrainClearanceFt {
                Text("\(Int(c.rounded())) ft")
                    .font(.aero(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.aviationRed)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(selected ? Color.subtleOverlay(0.07) : .clear)
        .background(alignment: .leading) { holdFill(Self.terrainConflictId) }
        .contentShape(Rectangle())
        .onTapGesture { selectConflict(Self.terrainConflictId) }
        .onLongPressGesture(minimumDuration: 0.6, maximumDistance: 50,
                            perform: { centerOnConflict(Self.terrainConflictId) },
                            onPressingChanged: { updateHold(Self.terrainConflictId, pressing: $0) })
    }

    private func airspaceRow(_ a: Airspace) -> some View {
        let selected = selectedConflictId == a.id
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(red: a.mapColor.red, green: a.mapColor.green, blue: a.mapColor.blue))
                .frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.shortName)
                        .font(.aero(size: 13, weight: .semibold))
                        .foregroundColor(.primaryText).lineLimit(1)
                    if a.isRestrictive {
                        Text(a.airspaceType.displayName.uppercased())
                            .font(.aero(size: 8, weight: .bold))
                            .foregroundColor(.aviationRed)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.aviationRed.opacity(0.18)))
                    }
                }
                Text(a.typeDisplayString)
                    .font(.aero(size: 10)).foregroundColor(.secondaryText).lineLimit(1)
                // Listed because the route MAY be inside: say which limit could not be pinned down.
                // (APP-11)
                ForEach(Self.uncertaintyNotes(airspaceBlocks.first { $0.id == a.id }?.verticalUncertainty ?? []),
                        id: \.self) { note in
                    Label(note, systemImage: "questionmark.diamond.fill")
                        .font(.aero(size: 10, weight: .medium)).foregroundColor(.aviationAmber)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(a.altitudeRangeString)
                    .font(.aero(size: 10, design: .monospaced))
                    .foregroundColor(.dimText).lineLimit(1)
                if let freq = a.primaryFrequency {
                    Text(freq.value)
                        .font(.aero(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.aviationGold)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(selected ? Color.subtleOverlay(0.07) : .clear)
        .background(alignment: .leading) { holdFill(a.id) }
        .contentShape(Rectangle())
        .onTapGesture { selectConflict(a.id) }
        .onLongPressGesture(minimumDuration: 0.6, maximumDistance: 50,
                            perform: { centerOnConflict(a.id) },
                            onPressingChanged: { updateHold(a.id, pressing: $0) })
    }

    /// What the conflict row says for a possible conflict, one line per limit that could not be
    /// pinned down. (APP-11)
    private static func uncertaintyNotes(_ why: Set<AirspaceVerticalUncertainty>) -> [String] {
        [why.contains(.terrainUnknown) ? L10n.Nav.airspaceMaybeAGL : nil,
         why.contains(.flightLevel) ? L10n.Nav.airspaceMaybeFL : nil].compactMap { $0 }
    }

    /// Debounced recompute of the on-route airspace blocks (profile) + conflict subset (list + map). (#4)
    private func scheduleAirspaceUpdate() {
        airspaceTask?.cancel()
        let coords = waypoints.map { $0.coordinate }
        let alts = waypoints.map { $0.altitude }
        guard coords.count >= 2 else { airspaceBlocks = []; crossedAirspaces = []; airspacePolygons = []; return }
        // Limits in ft AGL follow the ground: resolve them against the route's terrain, once it has
        // been fetched for THIS line. Until then (or outside Switzerland, or offline) they can't
        // clear the route, and show as possible conflicts. (APP-11)
        let terrain = terrainRouteKey == Self.terrainKey(coords)
            ? AltitudePlanner.samples(fromMetres: terrainData, routeNM: RouteAltitudeProfile(waypoints).totalNM) : []
        airspaceTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await openAIPDataService.ensureLoaded()
            guard !Task.isCancelled else { return }
            let blocks = openAIPDataService.airspaceProfileBlocks(coords, altitudesFt: alts, terrain: terrain)
            let conflicts = blocks.filter { $0.isConflict }.map { $0.airspace }
            let polys: [AirspacePolygon] = conflicts.compactMap { airspace in
                var mc = airspace.polygonCoordinates
                guard mc.count >= 3 else { return nil }
                return AirspacePolygon(airspace: airspace, coordinates: &mc, count: mc.count)
            }
            guard !Task.isCancelled else { return }
            airspaceBlocks = blocks
            crossedAirspaces = conflicts
            airspacePolygons = polys
        }
    }

    /// Debounced terrain fetch (swisstopo via `ElevationService`; empty outside Switzerland) + the
    /// minimum clearance of the extrapolated altitude profile over terrain, for the 150 m warning. (#4)
    /// Warm the winds-aloft cache for every 0.25 deg cell the route crosses, then recalculate so the
    /// leg ETAs pick the forecast up. `FlightPlan.windsAloftProvider` is a cache-only read (route
    /// recalculation runs on every drag and must not block on the network), so without this the legs
    /// would stay on their zero-wind timing forever.
    private func scheduleWindsAloftUpdate() {
        let coords = flightPlanManager.activeFlightPlan?.waypoints.map(\.coordinate) ?? []
        guard coords.count >= 2 else { return }
        windsAloftTask?.cancel()
        windsAloftTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await windsAloftService.prefetchRoute(coords)
            guard !Task.isCancelled else { return }
            flightPlanManager.recalculateCurrentPlanRouteData()
        }
    }

    private func scheduleTerrainUpdate() {
        terrainTask?.cancel()
        let wpts = waypoints
        let coords = wpts.map { $0.coordinate }
        guard coords.count >= 2 else { terrainData = []; minTerrainClearanceFt = nil; return }
        terrainTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let terrain = await elevationService.fetchRouteElevationsOptimized(waypoints: coords, spacingNM: 0.1)
            guard !Task.isCancelled else { return }
            terrainData = terrain
            terrainRouteKey = Self.terrainKey(coords)
            minTerrainClearanceFt = Self.minClearanceFt(terrain: terrain, waypoints: wpts)
            scheduleAirspaceUpdate()   // limits in ft AGL can now be resolved (APP-11)
        }
    }

    /// Identifies a route line (not its altitudes): the terrain under it only changes with it.
    private static func terrainKey(_ coords: [CLLocationCoordinate2D]) -> String {
        coords.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ";")
    }

    /// Lowest vertical gap (ft) between the extrapolated altitude profile and the terrain along the
    /// route, or nil when terrain or planned altitudes are unavailable.
    private static func minClearanceFt(terrain: [(distance: Double, elevation: Double)], waypoints: [FlightPlanWaypoint]) -> Double? {
        guard terrain.count >= 2, let terrMax = terrain.last?.distance, terrMax > 0 else { return nil }
        let prof = RouteAltitudeProfile(waypoints)
        guard prof.hasUsableProfile, prof.totalNM > 0 else { return nil }
        var minC = Double.infinity
        for p in terrain {
            let nm = (p.distance / terrMax) * prof.totalNM
            guard let alt = prof.altitude(atNM: nm) else { continue }
            minC = min(minC, alt - p.elevation * 3.28084)
        }
        return minC.isFinite ? minC : nil
    }

    /// Thin header above the waypoint list with the single reorder toggle. Replaces the navigation-bar
    /// `EditButton` that previously collided with the screen's "Done" (feedback #7): the toggle lives
    /// next to the list it edits, leaving exactly one unambiguous "Done" in the top bar to exit.
    private var waypointListHeader: some View {
        HStack(spacing: 8) {
            Text(L10n.RouteEditor.legs.uppercased())
                .font(.aero(size: 12, weight: .bold, design: .monospaced)).tracking(1.2)
                .foregroundColor(.aviationGold)
            if listEditMode == .active {
                Text(L10n.Nav.dragToReorder)
                    .font(.aero(size: 11))
                    .foregroundColor(.dimText)
                    .lineLimit(1)
            }
            Spacer()
            // Set many altitudes at once — fixed, or a clearance above the terrain.
            if waypoints.count >= 3 {
                Button { showSetAltitudes = true } label: {
                    Image(systemName: "arrow.up.and.down.text.horizontal")
                        .font(.aero(size: 13, weight: .semibold))
                        .foregroundColor(.aviationGold)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.subtleOverlay(0.06)))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(L10n.Altitudes.title)
            }
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { // (UX-18)
                    listEditMode = (listEditMode == .active ? .inactive : .active)
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.aero(size: 13, weight: .semibold))
                    .foregroundColor(listEditMode == .active ? .black : .aviationGold)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(listEditMode == .active ? Color.aviationGold : Color.subtleOverlay(0.06)))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(L10n.Nav.reorderWaypoints)
            .accessibilityAddTraits(listEditMode == .active ? [.isSelected] : [])
            if waypoints.count >= 2 { conflictsChip }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    /// "⚠ 12 conflicts", "✓ No conflicts" or "? Not checked": what the route check found, and the
    /// way to its list. (planning proposal D2)
    private var conflictsChip: some View {
        let text: String = hazardCount > 0
            ? "⚠ " + L10n.RouteEditor.conflicts(hazardCount)
            : (routeFullyChecked ? "✓ " + L10n.RouteEditor.noConflicts : "? " + L10n.RouteEditor.notChecked)
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { rightTab = .conflicts }
        } label: {
            HStack(spacing: 4) {
                Text(text)
                Image(systemName: "chevron.right").font(.aero(size: 11, weight: .bold))
            }
            .font(.aero(size: 14, weight: .semibold))
            .foregroundColor(hazardTint)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Capsule().fill(hazardTint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(hazardTint.opacity(0.5), lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The nav log's own columns, over the legs. (planning proposal D1)
    private var legColumnsHeader: some View {
        HStack(spacing: 0) {
            Text("#").frame(width: LegRow.numberWidth, alignment: .leading)
            Text(L10n.RouteEditor.waypoint).frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.RouteEditor.mc).frame(width: LegRow.mcWidth, alignment: .trailing)
            Text("NM").frame(width: LegRow.nmWidth, alignment: .trailing)
            Text("EET").frame(width: LegRow.eetWidth, alignment: .trailing)
            Text(L10n.RouteEditor.altFt).frame(width: LegRow.altWidth, alignment: .trailing)
            Text("").frame(width: LegRow.warnWidth)
        }
        .font(.aero(size: 11, weight: .bold, design: .monospaced))
        .tracking(0.8)
        .foregroundColor(.secondaryText)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 30)
    }

    /// True when no en-route waypoint has a planned altitude — typically a GPX from a planner whose
    /// `<ele>` is terrain, which the importer deliberately does not read as the plan.
    private var hasNoPlannedAltitudes: Bool {
        waypoints.count >= 3 && waypoints.dropFirst().dropLast().allSatisfy { $0.altitude == nil }
    }

    private var noAltitudesBanner: some View {
        Button { showSetAltitudes = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.aviationAmber)
                Text(L10n.Altitudes.banner)
                    .font(.aero(size: 12, weight: .medium))
                    .foregroundColor(.secondaryText)
                Spacer()
                Text(L10n.Altitudes.bannerAction)
                    .font(.aero(size: 12, weight: .semibold))
                    .foregroundColor(.aviationGold)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(Color.aviationAmber.opacity(0.12))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// Compact route summary for the system nav bar (replaces the dead title). (#4 Direction B)
    /// One `Text`, so it shrinks as a whole: as separate texts in an HStack, the one given the least
    /// room was cut on its own, and an iPhone SE read "8 WPT · 1… NM · 1:47". (6.1.0)
    private var toolbarSummary: some View {
        let separator = Text(verbatim: "  ·  ").font(.aero(size: 12)).foregroundColor(.dimText)
        return (metricText("\(waypoints.count)", "WPT", .primaryText)
                + separator
                + metricText(String(format: "%.0f", plan?.totalDistance ?? 0), "NM", .altimeterBlue)
                + separator
                + metricText(plan?.formattedTotalEET ?? "0:00", "", .aviationGold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private func metricText(_ value: String, _ unit: String, _ color: Color) -> Text {
        let text = Text(value).font(.aero(size: 15, weight: .bold, design: .monospaced)).foregroundColor(color)
        guard !unit.isEmpty else { return text }
        return text + Text(" " + unit).font(.aero(size: 10, weight: .semibold)).foregroundColor(.secondaryText)
    }

    private var emptyRouteHint: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "hand.point.up.left")
                .font(.aero(size: 40))
                .foregroundColor(.dimText)
            Text("Search an ICAO above, or press and\nhold the map to drop a waypoint")
                .font(.aero(size: 14))
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var waypointList: some View {
        let conflicts = legConflicts
        return ScrollViewReader { proxy in
            List {
                ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, waypoint in
                    let isSelected = selectedLeg == index
                    LegRow(
                        index: index,
                        waypoint: waypoint,
                        isLast: index == waypoints.count - 1,
                        isSelected: isSelected,
                        conflictCount: conflicts[index]?.count ?? 0,
                        compact: horizontalSizeClass == .compact,
                        onEditAltitude: { feet in
                            var wp = waypoint
                            wp.altitude = feet
                            flightPlanManager.updateWaypoint(wp, in: planId)
                        },
                        // A tap selects the leg (map, profile and table); a tap on the selected row
                        // opens its waypoint. (planning proposal D3)
                        onTap: { if isSelected { editingWaypoint = waypoint } else { selectLeg(index) } },
                        onConflictTap: {
                            selectLeg(index)
                            if let first = conflicts[index]?.first {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { selectedConflictId = first }
                            }
                        },
                        // By id: moving from one altitude to the next reports the new one before the
                        // old one lets go.
                        onAltitudeFocus: { focused in
                            if focused {
                                altitudeEditingId = waypoint.id
                            } else if altitudeEditingId == waypoint.id {
                                altitudeEditingId = nil
                            }
                        }
                    )
                    .id(waypoint.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
                    .listRowBackground(
                        (isSelected ? Color(red: 1.0, green: 0.08, blue: 0.8).opacity(0.16) : Color.cardBackground)
                            .overlay(alignment: .leading) {
                                if isSelected {
                                    Rectangle().fill(Color(red: 1.0, green: 0.08, blue: 0.8)).frame(width: 3)
                                }
                            }
                    )
                    .listRowSeparatorTint(Color.subtleOverlay(0.06))
                }
                .onMove { source, destination in
                    selectedLeg = nil
                    flightPlanManager.moveWaypoints(in: planId, from: source, to: destination)
                }
                .onDelete { offsets in
                    selectedLeg = nil
                    for index in offsets where index < waypoints.count {
                        flightPlanManager.removeWaypoint(waypoints[index], from: planId)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, $listEditMode)
            // A leg picked on the map comes into view; nothing reorders. (planning proposal D3)
            .onChange(of: selectedLeg) { _, leg in
                guard let leg, leg < waypoints.count else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo(waypoints[leg].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Actions

    /// The "+" in an aerodrome's, navaid's or reporting point's callout: the point itself, never
    /// snapped to a neighbour, on the leg it least lengthens. The departure and the destination stay
    /// where From and To put them; only a route without a destination yet (fewer than two points)
    /// gets the point appended. An aerodrome used to be appended after the destination, becoming it.
    /// (6.0.1)
    private func addPoint(_ point: RoutePoint) {
        insert(point, at: FlightPlanManager.bestLegInsertionIndex(for: point.coordinate, in: waypoints),
               droppedAt: point.coordinate)
    }

    /// Inserts `point`, or a plain waypoint at `coordinate` when there is none, at `index` in one
    /// write. At either end it is an endpoint, so it takes the elevation when it has one.
    private func insert(_ point: RoutePoint?, at index: Int, droppedAt coordinate: CLLocationCoordinate2D) {
        let asEndpoint = index == 0 || index >= waypoints.count
        let waypoint = point.map { $0.waypoint(asEndpoint: asEndpoint, contactFrequency: contactFrequency(for: $0)) }
            ?? FlightPlanWaypoint(coordinate: coordinate, pointKind: .user)
        flightPlanManager.insertWaypoint(waypoint, to: planId, at: index)
    }

    /// Snap radius for releasing a dragged waypoint onto a nearby airfield. (flight-plan revamp #3)
    private let snapRadiusNm: Double = 2.5
    private let rpSnapRadiusNm: Double = 1.2   // tighter — reporting points are dense (v4.1.0 ③)

    /// Commit a live waypoint move: snap to what is near the release (`snapTarget`), otherwise just
    /// reposition the point, which is then the pilot's own. (#3)
    private func moveWaypoint(at index: Int, to coordinate: CLLocationCoordinate2D) {
        guard index < waypoints.count else { return }
        var wp = waypoints[index]
        if let target = snapTarget(near: coordinate) {
            apply(target, to: &wp)
        } else {
            wp.coordinate = coordinate
            // No longer the aerodrome, navaid or point it was: its ident must not reach the GPX.
            if wp.pointKind != nil { wp.pointKind = .user; wp.sourceId = nil; wp.code = nil; wp.aerodromeICAO = nil }
        }
        flightPlanManager.updateWaypoint(wp, in: planId)
    }

    /// Commit a deliberate press-and-hold add: drop the waypoint at the cheapest-insertion position
    /// (the leg it least lengthens, or an endpoint), snapped to what is near (`snapTarget`).
    /// (tap-add feedback + smart insertion)
    private func smartAddWaypoint(at coordinate: CLLocationCoordinate2D) {
        insert(snapTarget(near: coordinate), at: FlightPlanManager.bestInsertionIndex(for: coordinate, in: waypoints),
               droppedAt: coordinate)
    }

    /// Profile drag committed: set a waypoint's planned altitude. (R3)
    private func setWaypointAltitude(_ index: Int, _ altitude: Double) {
        guard index < waypoints.count else { return }
        var wp = waypoints[index]
        wp.altitude = altitude
        flightPlanManager.updateWaypoint(wp, in: planId)
    }

    /// Profile tap committed: drop a new waypoint on the route line at the tapped along-track distance,
    /// carrying the tapped altitude. (R3)
    private func addProfilePoint(atNM nm: Double, altitude: Double) {
        guard let coord = coordinate(atNM: nm) else { return }
        let index = insertionIndex(forNM: nm)
        // Tag profile-dropped points "WPT (ALT)" so they're distinguishable from map-tapped ones. (#5 feedback)
        flightPlanManager.insertWaypoint(to: planId, at: index, coordinate: coord, name: "WPT (ALT)")
        if let p = plan, index < p.waypoints.count {
            var wp = p.waypoints[index]
            wp.altitude = altitude
            flightPlanManager.updateWaypoint(wp, in: planId)
        }
    }

    /// Array index at which to insert a point that sits at along-track distance `nm` (its leg + 1).
    private func insertionIndex(forNM nm: Double) -> Int {
        guard waypoints.count >= 2 else { return waypoints.count }
        var cum = 0.0
        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i].coordinate, b = waypoints[i + 1].coordinate
            let seg = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852.0
            if nm <= cum + seg { return i + 1 }
            cum += seg
        }
        return waypoints.count
    }

    /// Commit a live mid-route insert after `afterIndex`, snapped like the other two (`snapTarget`):
    /// it used to snap to aerodromes only. (#3, 6.0.1)
    private func insertRouteWaypoint(afterIndex: Int, at coordinate: CLLocationCoordinate2D) {
        insert(snapTarget(near: coordinate), at: afterIndex + 1, droppedAt: coordinate)
    }

    /// Export the route as an avionics-compatible GPX (Dynon / Garmin) via the shared service.
    private func exportGPX() {
        guard let plan, let data = FlightPlanExportService.exportToAvionicsGPX(
            plan, pointDescriptions: FlightPlanExportService.gpxDescriptions(for: plan)) else { return }
        exportItem = FlightPlanExportItem(data: data, filename: plan.exportFilename, format: .gpx)
    }

    /// Center the map on the existing route once when opening an already-populated plan.
    private func initialFitIfNeeded() {
        guard !didInitialFit else { return }
        didInitialFit = true
        if !waypoints.isEmpty {
            // Defer to the next runloop so the map view exists.
            DispatchQueue.main.async { fitRouteToken += 1 }
        }
    }

    private func scheduleAirportUpdate() {
        airportUpdateTask?.cancel()
        airportUpdateTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms debounce
            guard !Task.isCancelled else { return }
            guard airportDataService.isDataAvailable else {
                await MainActor.run { visibleAirports = [] }
                return
            }
            let r = region
            let halfLat = r.span.latitudeDelta / 2
            let halfLon = r.span.longitudeDelta / 2
            let airports = airportDataService.getAirportsInRegion(
                minLat: r.center.latitude - halfLat,
                maxLat: r.center.latitude + halfLat,
                minLon: r.center.longitude - halfLon,
                maxLon: r.center.longitude + halfLon,
                types: AirportType.fixedWing, // fixed-wing only (its doc comment says how to re-enable heliports)
                limit: 80
            )
            await MainActor.run { visibleAirports = airports }
        }
    }

    /// Refresh the OpenAIP map-data layers shown in the builder (navaids / reporting points / obstacles),
    /// each gated on its own toggle. Reporting points + obstacles are v4.1.0 ③. (Debounced.)
    private func scheduleNavaidUpdate() {
        navaidUpdateTask?.cancel()
        let showNavaids = appState.settings.showNavaidsOnMap
        let showRP = appState.settings.showReportingPointsOnMap
        let showNonPoweredRP = appState.settings.showsNonPoweredReportingPoints
        let showObstacles = appState.settings.showObstaclesOnMap
        let vfrSelection = VFRLayerSelection(settings: appState.settings)
        let vfrPalette = VFRMapPalette(theme: theme)
        navaidUpdateTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms debounce
            guard !Task.isCancelled else { return }
            let r = region
            let halfLat = r.span.latitudeDelta / 2
            let halfLon = r.span.longitudeDelta / 2
            let latRange = (r.center.latitude - halfLat)...(r.center.latitude + halfLat)
            let lonRange = (r.center.longitude - halfLon)...(r.center.longitude + halfLon)

            var navaids: [Navaid] = []
            if showNavaids, OpenAIPNavaidDataService.shared.isDataAvailable {
                await OpenAIPNavaidDataService.shared.ensureLoaded()
                navaids = OpenAIPNavaidDataService.shared.navaidsInRegion(latRange: latRange, lonRange: lonRange)
            }
            var reportingPoints: [ReportingPoint] = []
            if showRP, ReportingPointCatalog.shared.isDataAvailable {
                await ReportingPointCatalog.shared.ensureLoaded()
                reportingPoints = ReportingPointCatalog.shared.points(latRange: latRange, lonRange: lonRange,
                                                                     includingNonPowered: showNonPoweredRP)
            }
            var obstacles: [Obstacle] = []
            if showObstacles, OpenAIPObstacleDataService.shared.isDataAvailable {
                await OpenAIPObstacleDataService.shared.ensureLoaded()
                obstacles = OpenAIPObstacleDataService.shared.obstaclesInRegion(latRange: latRange, lonRange: lonRange)
            }
            // Traffic circuits, VFR routes and sectors: loaded the first time a switch needs them, then
            // gated by the span and capped as on the navigation map. (6.2.0)
            if vfrSelection.isAnyOn, OFMDataService.shared.isDataAvailable {
                await OFMDataService.shared.ensureLoaded()
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                visibleNavaids = navaids
                visibleReportingPoints = reportingPoints
                visibleObstacles = obstacles
                vfrContent = makeVFRContent(for: r, selection: vfrSelection, palette: vfrPalette)
            }
        }
    }

    /// The aerodrome procedures for `region`, the plan's destination and departure first. (6.2.0)
    private func makeVFRContent(for region: MKCoordinateRegion, selection: VFRLayerSelection,
                            palette: VFRMapPalette) -> VFRMapContent {
        let service = OFMDataService.shared
        guard selection.isAnyOn, service.isLoaded, VFRMapDensity.showsProcedures(in: region) else {
            return .empty(palette)
        }
        return VFRMapContent.make(
            candidates: service.procedures(in: region), region: region, selection: selection, palette: palette,
            firstAerodromes: VFRMapDensity.endpointAerodromes(of: plan),
            fieldPosition: { airportDataService.findAirport(byIdent: $0)?.coordinate },
            cycle: { (service.cycles[$0]?.airac, service.region(forCountry: $0)) })
    }
}

// MARK: - Layout (6.1.0)

/// Where the route builder's parts go: From/To (with Via), the map, the route profile (once there is a
/// destination) and the legs. Portrait stacks them, the map at 40 % of the height (62 % before there is
/// a route); two columns put the map on the left at 58 % of the width and the rest down the right.
///
/// It is one `Layout` for both, not an `HStack` swapped for a `VStack`: a swap builds every part again,
/// so turning the iPad while typing in From dropped the text and the keyboard, and reloaded the map.
/// Here the parts stay the same views and only move. The 1 pt gaps between them are the dividers (the
/// builder paints them behind). `frames` is pure, so the proportions are tested without a view.
struct RouteBuilderLayout: Layout {
    enum Part { case fromTo, map, profile, legs }

    struct PartKey: LayoutValueKey {
        static let defaultValue: Part = .legs
    }

    var twoColumn: Bool
    var hasRoute: Bool
    /// Everything moves up by this much, sizes unchanged (an altitude typed above the keyboard).
    var lift: CGFloat = 0

    static let landscapeMapShare: CGFloat = 0.58
    static let divider: CGFloat = 1

    /// Two columns on a regular width wider than tall. `size` must not lose the keyboard's height (the
    /// builder's reader ignores it): with the keys up, an iPad in portrait is wider than it is tall.
    static func isTwoColumn(regularWidth: Bool, size: CGSize) -> Bool {
        regularWidth && size.width > size.height
    }

    struct Frames: Equatable {
        var fromTo: CGRect
        var map: CGRect
        var profile: CGRect
        var legs: CGRect
    }

    /// Every part's frame in `size`, given the heights From/To and the profile ask for. Without a route
    /// the profile is `.zero` and the legs take its place.
    static func frames(in size: CGSize, twoColumn: Bool, hasRoute: Bool,
                       fromToHeight: CGFloat, profileHeight: CGFloat) -> Frames {
        let profileHeight = hasRoute ? profileHeight : 0
        if twoColumn {
            let mapWidth = (size.width * landscapeMapShare).rounded()
            let x = mapWidth + divider
            let width = max(0, size.width - x)
            let fromTo = CGRect(x: x, y: 0, width: width, height: fromToHeight)
            let profile = hasRoute
                ? CGRect(x: x, y: fromTo.maxY + divider, width: width, height: profileHeight) : .zero
            let legsY = (hasRoute ? profile.maxY : fromTo.maxY) + divider
            return Frames(fromTo: fromTo,
                          map: CGRect(x: 0, y: 0, width: mapWidth, height: size.height),
                          profile: profile,
                          legs: CGRect(x: x, y: legsY, width: width, height: max(0, size.height - legsY)))
        }
        let fromTo = CGRect(x: 0, y: 0, width: size.width, height: fromToHeight)
        let map = CGRect(x: 0, y: fromTo.maxY, width: size.width,
                         height: max(240, size.height * (hasRoute ? 0.40 : 0.62)))
        let profile = hasRoute
            ? CGRect(x: 0, y: map.maxY + divider, width: size.width, height: profileHeight) : .zero
        let legsY = (hasRoute ? profile.maxY : map.maxY) + divider
        return Frames(fromTo: fromTo, map: map, profile: profile,
                      legs: CGRect(x: 0, y: legsY, width: size.width, height: max(0, size.height - legsY)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let part = { (kind: Part) in subviews.first { $0[PartKey.self] == kind } }
        // From/To and the profile keep their own height, at the width they get.
        let columnWidth = twoColumn
            ? max(0, bounds.width - (bounds.width * Self.landscapeMapShare).rounded() - Self.divider)
            : bounds.width
        let height = { (kind: Part) -> CGFloat in
            part(kind)?.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height ?? 0
        }
        let frames = Self.frames(in: bounds.size, twoColumn: twoColumn, hasRoute: hasRoute,
                                 fromToHeight: height(.fromTo), profileHeight: height(.profile))
        for (kind, frame) in [(Part.fromTo, frames.fromTo), (.map, frames.map),
                              (.profile, frames.profile), (.legs, frames.legs)] {
            part(kind)?.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY - lift),
                              proposal: ProposedViewSize(frame.size))
        }
    }
}

// MARK: - Placeholder that fits (6.1.0)

/// A field's placeholder drawn over it, shrinking to fit (to 60 % at most) rather than being cut. The
/// field's own prompt must be empty. On an iPhone, From and To leave it 80 to 100 pt: "ICAO or name" at
/// 17 pt read "ICAO or…" on an iPhone 17.
private struct FittingPlaceholder: ViewModifier {
    let text: String
    let isShown: Bool
    let font: Font

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if isShown {
                Text(text)
                    .font(font)
                    .foregroundColor(Color(uiColor: .placeholderText))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Via search (6.0.1)

/// The "Via" field under From and To: finds a reporting point or a navaid for the route. Its own view,
/// so the builder's body doesn't grow (see `SeparateView`).
private struct ViaSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Text(L10n.Nav.via)
                .font(.aero(size: 11, weight: .semibold)).tracking(0.6).foregroundColor(.dimText)
            TextField(L10n.Nav.viaPlaceholder, text: $text)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .font(.aero(size: 17, weight: .semibold, design: .monospaced))
                .foregroundColor(.primaryText)
                .focused(focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.aero(size: 15))
                        .foregroundColor(.dimText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Button.clear)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.aero(size: 14))
                    .foregroundColor(.dimText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, text.isEmpty ? 12 : 0)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.subtleOverlay(0.06)))
    }
}

/// What the "Via" search found: kind, name, aerodrome (or navaid) and distance from the route. A tap
/// puts the point in the route.
private struct ViaSearchResults: View {
    let results: [RoutePointSearch.Result]
    let query: String
    let onPick: (RoutePointSearch.Result) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if results.isEmpty {
                Text(L10n.Nav.viaNoMatch(query))
                    .font(.aero(size: 13))
                    .foregroundColor(.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(results) { result in
                Button { onPick(result) } label: { row(result) }
                    .buttonStyle(.plain)
                    .accessibilityHint(L10n.Nav.addToRoute)
                if result.id != results.last?.id {
                    Divider().background(Color.subtleOverlay(0.06))
                }
            }
        }
    }

    private func row(_ result: RoutePointSearch.Result) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(result.kind))
                .font(.aero(size: 13, weight: .semibold))
                .foregroundColor(color(result.kind))
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(result.title)
                .font(.aero(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.aviationGold)
                .lineLimit(1)
            if let subtitle = result.subtitle {
                Text(subtitle)
                    .font(.aero(size: 13))
                    .foregroundColor(.primaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let distance = result.distanceNM {
                Text(String(format: distance < 10 ? "%.1f NM" : "%.0f NM", distance))
                    .font(.aero(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func icon(_ kind: RoutePointSearch.Kind) -> String {
        switch kind {
        case .reportingPoint(let compulsory): return compulsory ? "triangle.fill" : "triangle"
        case .navaid: return "hexagon"
        }
    }

    /// The map's own marker colours, so a result reads as the marker it is.
    private func color(_ kind: RoutePointSearch.Kind) -> Color {
        switch kind {
        case .reportingPoint: return Color(red: 0.85, green: 0.2, blue: 0.6)
        case .navaid: return Color(red: 1.0, green: 0.72, blue: 0.0)
        }
    }
}

// MARK: - Leg row (planning proposal D1)

/// One leg, in the nav log's columns: #, waypoint, MC, NM, EET, altitude (editable) and ⚠. 44 pt,
/// so about ten are in view in portrait where four were. The leg data is the leg FROM this waypoint;
/// the last row is the destination. On the iPhone the figures go under the name.
private struct LegRow: View {
    static let numberWidth: CGFloat = 36
    static let mcWidth: CGFloat = 58
    static let nmWidth: CGFloat = 64
    static let eetWidth: CGFloat = 78
    static let altWidth: CGFloat = 104
    static let warnWidth: CGFloat = 44

    let index: Int
    let waypoint: FlightPlanWaypoint
    let isLast: Bool
    let isSelected: Bool
    let conflictCount: Int
    let compact: Bool
    let onEditAltitude: (Double?) -> Void
    let onTap: () -> Void
    let onConflictTap: () -> Void
    /// The altitude field took or lost the keyboard, for the builder to lift the legs above it.
    let onAltitudeFocus: (Bool) -> Void

    @State private var altitudeText: String = ""
    @FocusState private var altitudeFocused: Bool

    /// "E (LSGC)" for a short reporting point: the list has the room. (6.0.1)
    private var name: String { waypoint.name.isEmpty ? "WPT\(index + 1)" : waypoint.routeName(.routeList) }

    var body: some View {
        HStack(spacing: 0) {
            // Number, name and figures: one target. A tap selects the leg; a tap on the selected
            // row opens the waypoint. Only the altitude and ⚠ keep their own. (proposal D3)
            Button(action: onTap) {
                HStack(spacing: 0) {
                    Text("\(index + 1)")
                        .font(.aero(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(.aviationGold)
                        .frame(width: Self.numberWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(name)
                                .font(.aero(size: 16, weight: .semibold))
                                .foregroundColor(.primaryText)
                                .lineLimit(1)
                            if let callSign = waypoint.callSign, !callSign.isEmpty, callSign != waypoint.name {
                                Text(callSign)
                                    .font(.aero(size: 12, design: .monospaced))
                                    .foregroundColor(.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        if compact {
                            Text(isLast ? L10n.RouteEditor.destination : legLine)
                                .font(.aero(size: 11, design: .monospaced))
                                .foregroundColor(.dimText)
                                .lineLimit(1)
                                // Smaller rather than cut: an iPhone SE read "194° · 12 NM · 7…".
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !compact {
                        figure(waypoint.magneticCourse.map { String(format: "%03.0f°", $0) }, width: Self.mcWidth)
                        figure(waypoint.distance.map { String(format: "%.1f", $0) }, width: Self.nmWidth)
                        figure(waypoint.formattedEET.map { "\($0)′" }, width: Self.eetWidth)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityHint(isSelected ? L10n.Nav.editWaypoint : L10n.RouteEditor.selectLeg)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            // Editable altitude (feet) — its own target.
            HStack(spacing: 3) {
                TextField("ALT", text: $altitudeText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.aero(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primaryText)
                    .focused($altitudeFocused)
                    .accessibilityLabel("Planned altitude in feet")
                Text("ft")
                    .font(.aero(size: 11))
                    .foregroundColor(.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(width: Self.altWidth - 12, height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.subtleOverlay(0.06)))
            .frame(width: Self.altWidth, alignment: .trailing)

            // The leg's conflicts: a tap highlights the first on the profile and the map. (D2)
            Group {
                if conflictCount > 0 {
                    Button(action: onConflictTap) {
                        Text(conflictCount > 1 ? "⚠\(conflictCount)" : "⚠")
                            .font(.aero(size: 15, weight: .semibold))
                            .foregroundColor(.aviationAmber)
                            .frame(width: Self.warnWidth, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.RouteEditor.conflicts(conflictCount))
                } else {
                    Color.clear.frame(width: Self.warnWidth, height: 1)
                }
            }
        }
        .frame(minHeight: 44)
        .onAppear { altitudeText = waypoint.altitude.map { String(Int($0)) } ?? "" }
        .onChange(of: altitudeFocused) { _, focused in
            if !focused { commitAltitude() }
            onAltitudeFocus(focused)
        }
        // Follow altitudes set elsewhere ("Set altitudes", a profile drag): rows are reused by id, so
        // onAppear alone left the field showing the old value.
        .onChange(of: waypoint.altitude) { _, altitude in
            if !altitudeFocused { altitudeText = altitude.map { String(Int($0)) } ?? "" }
        }
    }

    private func figure(_ text: String?, width: CGFloat) -> some View {
        Text(isLast ? "" : (text ?? "—"))
            .font(.aero(size: 15, design: .monospaced))
            .foregroundColor(.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: width, alignment: .trailing)
    }

    private var legLine: String {
        var parts: [String] = []
        if let mc = waypoint.magneticCourse { parts.append(String(format: "%03.0f°", mc)) }
        if let dist = waypoint.distance { parts.append(String(format: "%.0f NM", dist)) }
        if let eet = waypoint.formattedEET { parts.append("\(eet)′") }
        return parts.isEmpty ? "—" : parts.joined(separator: "  ·  ")
    }

    private func commitAltitude() {
        let trimmed = altitudeText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            onEditAltitude(nil)
        } else if let value = Double(trimmed) {
            onEditAltitude(value)
        }
    }
}

// MARK: - Route builder map (UIViewRepresentable)

/// Live route map: swisstopo/Apple tile overlay + gold route polyline + numbered waypoint markers +
/// nearby airport markers. Tapping empty map adds a free waypoint; tapping an airport marker adds
/// that airport. Reuses the waypoint-picker tile overlays.
struct RouteBuilderMapView: UIViewRepresentable {
    let waypoints: [FlightPlanWaypoint]
    let mapLayer: WaypointPickerMapLayer
    var airports: [Airport]
    var navaids: [Navaid] = []
    var reportingPoints: [ReportingPoint] = []     // v4.1.0 ③ (snap-enabled)
    var obstacles: [Obstacle] = []                 // v4.1.0 ③ (display only, no snap)
    var airspacePolygons: [AirspacePolygon] = []   // highlight the airspaces the route crosses (#4)
    var selectedAirspaceId: String? = nil          // tapped conflict — emphasised on the map (#4)
    var focusRegion: MKCoordinateRegion? = nil     // hold a conflict → recenter the map on it (#4)
    var focusToken: Int = 0
    var fitRouteToken: Int
    @Binding var region: MKCoordinateRegion
    /// "+" in an aerodrome's, navaid's or reporting point's callout. nil ⇒ no "+". (6.0.1)
    var onPointAdd: ((RoutePoint) -> Void)? = nil
    /// Live drag committed a waypoint move (index, new coordinate). nil ⇒ read-only map (no drag). (#3)
    var onMoveWaypoint: ((Int, CLLocationCoordinate2D) -> Void)? = nil
    /// Live drag committed a mid-route insert (afterIndex, coordinate). nil ⇒ read-only map. (#3)
    var onInsertWaypoint: ((Int, CLLocationCoordinate2D) -> Void)? = nil
    /// Deliberate press-and-hold on empty map appended a new waypoint (coordinate). (tap-add feedback)
    var onAddWaypoint: ((CLLocationCoordinate2D) -> Void)? = nil
    /// The leg selected in the table or the profile (from waypoint n to n+1): haloed on the map.
    /// (planning proposal D3)
    var selectedLeg: Int? = nil
    /// Waypoints whose leg has a conflict: their pins turn amber. (planning proposal D2)
    var conflictLegs: Set<Int> = []
    /// A tap on a waypoint's pin selects it, and its row in the table. (planning proposal D3)
    var onSelectWaypoint: ((Int) -> Void)? = nil
    /// Traffic circuits, VFR routes and sectors, under the route. (6.2.0)
    var vfrContent: VFRMapContent = .empty()
    /// Opens an aerodrome's official chart from its callout (the browser); nil: no chart. (6.2.0)
    var onOpenOfficialChart: ((URL) -> Void)? = nil

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.setRegion(region, animated: false)
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.showsScale = true
        configureLayer(mapView)
        mapView.cameraZoomRange = cameraZoomRange(for: mapLayer)

        // One press-and-hold gesture drives ALL route editing: grab a waypoint to move it, grab the
        // route line to insert mid-route (both at the short grab threshold for a responsive feel), or
        // hold longer on empty map to drop a new waypoint. A plain tap no longer adds anything, so you
        // can pan/zoom/inspect without accidentally creating waypoints. Builder only — read-only map
        // previews get no editing. (flight-plan revamp #3 + tap-add feedback)
        if onMoveWaypoint != nil || onInsertWaypoint != nil || onAddWaypoint != nil {
            let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
            longPress.minimumPressDuration = 0.2
            longPress.delegate = context.coordinator
            mapView.addGestureRecognizer(longPress)
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Keep the coordinator's snapshot current so drag hit-testing reads live waypoints/closures.
        context.coordinator.parent = self
        // Never fight an in-progress live drag — the coordinator owns the geometry until release.
        if context.coordinator.isDragging { return }
        if context.coordinator.currentLayer != mapLayer {
            context.coordinator.currentLayer = mapLayer
            configureLayer(mapView)
            mapView.cameraZoomRange = cameraZoomRange(for: mapLayer)
        }

        updateAirportAnnotations(mapView, context: context)
        updateNavaidAnnotations(mapView, context: context)
        updateReportingPointAnnotations(mapView, context: context)
        updateObstacleAnnotations(mapView, context: context)
        updateAirspaceOverlays(mapView, context: context)
        applyAirspaceSelection(mapView)
        updateRoute(mapView, context: context)
        updateSelectedLeg(mapView, context: context)
        VFRMapLayer.sync(vfrContent, on: mapView, state: context.coordinator.vfrLayer)

        if context.coordinator.lastFitToken != fitRouteToken {
            context.coordinator.lastFitToken = fitRouteToken
            fitRoute(mapView)
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            if let r = focusRegion { mapView.setRegion(r, animated: true) }
        }
    }

    /// Emphasise the selected conflict's polygon (brighter + thicker) by restyling its live renderer,
    /// so tapping a row in the list makes it pop on the map. (#4 feedback)
    private func applyAirspaceSelection(_ mapView: MKMapView) {
        for poly in mapView.overlays.compactMap({ $0 as? AirspacePolygon }) {
            guard let r = mapView.renderer(for: poly) as? MKPolygonRenderer else { continue }
            let c = poly.overlayColor
            let sel = poly.airspaceId == selectedAirspaceId
            r.fillColor = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: sel ? 0.36 : 0.18)
            r.strokeColor = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: sel ? 1.0 : 0.85)
            r.lineWidth = sel ? 3 : 1.5
            r.lineDashPattern = poly.isDashed ? [8, 4] : nil
            r.setNeedsDisplay()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: Layer

    private func cameraZoomRange(for layer: WaypointPickerMapLayer) -> MKMapView.CameraZoomRange? {
        switch layer {
        case .apple:
            return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 100, maxCenterCoordinateDistance: 10_000_000)
        case .icao:
            return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 65_000, maxCenterCoordinateDistance: 600_000)
        case .swissimage:
            return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 1_500, maxCenterCoordinateDistance: 600_000)
        }
    }

    private func configureLayer(_ mapView: MKMapView) {
        let existingTiles = mapView.overlays.compactMap { $0 as? MKTileOverlay }
        mapView.removeOverlays(existingTiles)

        switch mapLayer {
        case .apple:
            mapView.mapType = .standard
        case .icao:
            mapView.mapType = .standard
            let overlay = ICAOSegelflugkarteTileOverlay()
            overlay.canReplaceMapContent = true
            mapView.insertOverlay(overlay, at: 0, level: .aboveLabels)
        case .swissimage:
            mapView.mapType = .standard
            let overlay = SwisstopoTileOverlay(layerIdentifier: "ch.swisstopo.swissimage", tileExtension: "jpeg")
            overlay.canReplaceMapContent = true
            mapView.insertOverlay(overlay, at: 0, level: .aboveLabels)
        }
    }

    // MARK: Airports

    private func updateAirportAnnotations(_ mapView: MKMapView, context: Context) {
        let existing = mapView.annotations.compactMap { $0 as? AirportAnnotation }
        let existingIds = Set(existing.map { $0.airport.id })
        let newIds = Set(airports.map { $0.id })

        mapView.removeAnnotations(existing.filter { !newIds.contains($0.airport.id) })
        for airport in airports where !existingIds.contains(airport.id) {
            mapView.addAnnotation(AirportAnnotation(airport: airport))
        }
    }

    private func updateNavaidAnnotations(_ mapView: MKMapView, context: Context) {
        let existing = mapView.annotations.compactMap { $0 as? NavaidAnnotation }
        let existingIds = Set(existing.map { $0.navaid.id })
        let newIds = Set(navaids.map { $0.id })

        mapView.removeAnnotations(existing.filter { !newIds.contains($0.navaid.id) })
        for navaid in navaids where !existingIds.contains(navaid.id) {
            mapView.addAnnotation(NavaidAnnotation(navaid: navaid))
        }
    }

    private func updateReportingPointAnnotations(_ mapView: MKMapView, context: Context) {
        ReportingPointAnnotation.sync(reportingPoints, on: mapView,
                                      revision: &context.coordinator.reportingPointLabelRevision)
    }

    private func updateObstacleAnnotations(_ mapView: MKMapView, context: Context) {
        let existing = mapView.annotations.compactMap { $0 as? ObstacleAnnotation }
        let existingIds = Set(existing.map { $0.obstacle.id })
        let newIds = Set(obstacles.map { $0.id })
        mapView.removeAnnotations(existing.filter { !newIds.contains($0.obstacle.id) })
        for obstacle in obstacles where !existingIds.contains(obstacle.id) {
            mapView.addAnnotation(ObstacleAnnotation(obstacle: obstacle))
        }
    }

    // MARK: Route

    /// Add/remove highlighted airspace polygons incrementally (by id), so a small change to the crossed
    /// set doesn't rebuild the rest. Drawn under the route (translucent fill). (#4)
    private func updateAirspaceOverlays(_ mapView: MKMapView, context: Context) {
        let existing = mapView.overlays.compactMap { $0 as? AirspacePolygon }
        let existingIds = Set(existing.map { $0.airspaceId })
        let newIds = Set(airspacePolygons.map { $0.airspaceId })
        guard existingIds != newIds else { return }
        let toRemove = existing.filter { !newIds.contains($0.airspaceId) }
        if !toRemove.isEmpty { mapView.removeOverlays(toRemove) }
        for polygon in airspacePolygons where !existingIds.contains(polygon.airspaceId) {
            mapView.addOverlay(polygon, level: .aboveLabels)
        }
    }

    private func updateRoute(_ mapView: MKMapView, context: Context) {
        let signature = waypoints.map { "\($0.id.uuidString)\($0.latitude),\($0.longitude)" }.joined(separator: "|")
            + "#" + conflictLegs.sorted().map(String.init).joined(separator: ",")
        guard signature != context.coordinator.lastRouteSignature else { return }
        context.coordinator.lastRouteSignature = signature
        context.coordinator.lastSelectedLegKey = ""   // the leg halo is rebuilt below with the route

        // Replace numbered waypoint annotations.
        let oldWaypoints = mapView.annotations.compactMap { $0 as? RouteWaypointAnnotation }
        mapView.removeAnnotations(oldWaypoints)
        for (index, waypoint) in waypoints.enumerated() {
            let annotation = RouteWaypointAnnotation(coordinate: waypoint.coordinate, index: index, name: waypoint.name)
            annotation.hasConflict = conflictLegs.contains(index)
            mapView.addAnnotation(annotation)
        }

        // Replace the route polyline. Draw a black casing under a magenta core, matching the in-flight
        // navigation map so the plan previews exactly how the route reads in flight, and so it stays
        // visible on every tile layer (feedback #6 — gold washed out on some charts).
        Self.removeRouteOverlays(from: mapView)
        if waypoints.count >= 2 {
            let coords = waypoints.map { $0.coordinate }
            let casing = RouteCasingPolyline(coordinates: coords, count: coords.count)
            mapView.addOverlay(casing, level: .aboveLabels)
            let polyline = RouteLinePolyline(coordinates: coords, count: coords.count)
            mapView.addOverlay(polyline, level: .aboveLabels)
        }
    }

    /// The route's own lines: its core, its casing and the selected leg's halo. The three redraws take
    /// off only these; they used to take off every `MKPolyline`, which would have taken the traffic
    /// circuits and VFR routes with them. (6.2.0)
    static func isRouteOverlay(_ overlay: MKOverlay) -> Bool {
        overlay is RouteLinePolyline || overlay is RouteCasingPolyline || overlay is SelectedLegPolyline
    }

    static func removeRouteOverlays(from mapView: MKMapView) {
        let route = mapView.overlays.filter(isRouteOverlay)
        if !route.isEmpty { mapView.removeOverlays(route) }
    }

    /// A white halo under the selected leg, drawn below the route so the magenta line reads through
    /// it: the leg is highlighted where it is. (planning proposal D3)
    private func updateSelectedLeg(_ mapView: MKMapView, context: Context) {
        let key = selectedLeg.map { "\($0)|\(waypoints.count)" } ?? "none"
        guard key != context.coordinator.lastSelectedLegKey else { return }
        context.coordinator.lastSelectedLegKey = key
        mapView.removeOverlays(mapView.overlays.filter { $0 is SelectedLegPolyline })
        guard let leg = selectedLeg, leg >= 0, leg + 1 < waypoints.count else { return }
        let coords = [waypoints[leg].coordinate, waypoints[leg + 1].coordinate]
        let halo = SelectedLegPolyline(coordinates: coords, count: 2)
        // Right under the route's casing: above the chart tiles (which share the level), under the line.
        if let casing = mapView.overlays.first(where: { $0 is RouteCasingPolyline }) {
            mapView.insertOverlay(halo, below: casing)
        } else {
            mapView.addOverlay(halo, level: .aboveLabels)
        }
    }

    private func fitRoute(_ mapView: MKMapView) {
        guard !waypoints.isEmpty else { return }
        let coords = waypoints.map { $0.coordinate }
        let rects = coords.map { MKMapRect(origin: MKMapPoint($0), size: MKMapSize(width: 0, height: 0)) }
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        // The From/To bar sits above the map now; the inset only keeps pins off the edges.
        let padding = UIEdgeInsets(top: 50, left: 50, bottom: 70, right: 50)
        mapView.setVisibleMapRect(union, edgePadding: padding, animated: true)
    }

    // MARK: Coordinator

    class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: RouteBuilderMapView
        var currentLayer: WaypointPickerMapLayer
        var lastRouteSignature = ""
        var lastSelectedLegKey = ""
        var lastFitToken = 0
        var lastFocusToken = 0
        /// `ReportingPointAnnotation.labelRevision` the markers were labelled at. (6.0.1)
        var reportingPointLabelRevision = -1
        /// The aerodrome procedures drawn, and their palette. (6.2.0)
        let vfrLayer = VFRMapLayer.State()

        // MARK: Live drag (flight-plan revamp #3)
        enum DragMode { case move(Int); case insert(Int); case append } // insert(afterIndex)
        var dragMode: DragMode?
        var dragCoords: [CLLocationCoordinate2D] = []       // working geometry during a drag
        var dragIndex = 0                                   // index into dragCoords being moved
        var dragAnnotation: RouteWaypointAnnotation?        // the marker following the finger
        var dragCreatedTempAnnotation = false               // true for insert/append (remove on end)
        var isDragging: Bool { dragMode != nil }

        // Deferred add: a press on empty map only becomes a new waypoint after a longer, deliberate
        // hold (so a normal press/pan never adds one). (tap-add feedback)
        var pendingAddWork: DispatchWorkItem?
        var pendingAddAnchor: CGPoint?

        init(_ parent: RouteBuilderMapView) {
            self.parent = parent
            self.currentLayer = parent.mapLayer
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.region = mapView.region
        }

        // Fires continuously while the user pans/zooms (not just at the end), so the profile's
        // "looking here" band tracks the map live instead of snapping on release. (feedback)
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            guard !isDragging else { return } // don't fight an in-progress waypoint/line drag
            parent.region = mapView.region
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            // Traffic circuits, VFR routes and sectors: before the generic MKPolyline branch below, which
            // would draw them magenta, as the route. (6.2.0)
            if let renderer = VFRMapLayer.renderer(for: overlay, palette: vfrLayer.palette) {
                return renderer
            }
            // Crossed-airspace highlight (translucent fill + colored stroke). (#4)
            if let airspace = overlay as? AirspacePolygon {
                let renderer = MKPolygonRenderer(polygon: airspace)
                let c = airspace.overlayColor
                renderer.fillColor = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 0.18)
                renderer.strokeColor = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 0.85)
                renderer.lineWidth = 1.5
                if airspace.isDashed { renderer.lineDashPattern = [8, 4] }
                return renderer
            }
            // The selected leg's halo, under the route. (planning proposal D3)
            if let halo = overlay as? SelectedLegPolyline {
                let renderer = MKPolylineRenderer(polyline: halo)
                renderer.strokeColor = UIColor.white.withAlphaComponent(0.85)
                renderer.lineWidth = 16
                renderer.lineCap = .round
                return renderer
            }
            // Casing first — it is also an MKPolyline, so this branch must precede the generic one.
            if let casing = overlay as? RouteCasingPolyline {
                let renderer = MKPolylineRenderer(polyline: casing)
                renderer.strokeColor = UIColor.black.withAlphaComponent(0.5)
                renderer.lineWidth = 7
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            // The route's core (`RouteLinePolyline`).
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1.0) // navigation magenta
                renderer.lineWidth = 4
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        /// A tap on a waypoint's pin selects it in the table too. (planning proposal D3)
        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let waypoint = annotation as? RouteWaypointAnnotation else { return }
            parent.onSelectWaypoint?(waypoint.index)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let waypoint = annotation as? RouteWaypointAnnotation {
                let id = "RouteWaypoint"
                let view: MKMarkerAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView {
                    reused.annotation = annotation
                    view = reused
                } else {
                    view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                }
                // Navigation magenta; amber where the leg from this waypoint has a conflict. (D2)
                view.markerTintColor = waypoint.hasConflict
                    ? UIColor(red: 1.0, green: 0.75, blue: 0.0, alpha: 1)
                    : UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1)
                view.glyphText = "\(waypoint.index + 1)"
                view.titleVisibility = .adaptive
                view.displayPriority = .required
                view.canShowCallout = true
                return view
            }

            // A traffic circuit's altitude or a VFR route's name, and its callout. (6.2.0)
            if let label = VFRMapLayer.annotationView(for: annotation, on: mapView, palette: vfrLayer.palette,
                                                      openChart: parent.onOpenOfficialChart) {
                return label
            }

            if let airport = annotation as? AirportAnnotation {
                let id = "BuilderAirport"
                let view: MKAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) {
                    reused.annotation = annotation
                    view = reused
                } else {
                    view = MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                }
                view.canShowCallout = true
                view.image = aeroMarkerSymbol("airplane", color: UIColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1.0), pointSize: 13, weight: .medium)
                // The field's official chart on the left, "+" on the right. (6.2.0)
                view.leftCalloutAccessoryView = parent.onOpenOfficialChart == nil ? nil
                    : OfficialChartService.shared.link(for: airport.airport).map {
                        OfficialChartControl.accessory(link: $0, metrics: .ground, tint: vfrLayer.palette.action)
                    }
                view.rightCalloutAccessoryView = addButton(annotation)
                return view
            }

            if annotation is NavaidAnnotation {
                let id = "BuilderNavaid"
                let navaidView: MKAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) {
                    reused.annotation = annotation
                    navaidView = reused
                } else {
                    navaidView = MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                }
                navaidView.canShowCallout = true
                navaidView.image = aeroMarkerSymbol("hexagon", color: UIColor(red: 1.0, green: 0.72, blue: 0.0, alpha: 1.0), pointSize: 13)
                navaidView.rightCalloutAccessoryView = addButton(annotation)
                return navaidView
            }

            if let rpAnnotation = annotation as? ReportingPointAnnotation {
                let id = "BuilderRP"
                let rpView: MKAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) {
                    reused.annotation = annotation
                    rpView = reused
                } else {
                    rpView = MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                }
                rpView.canShowCallout = true
                rpView.detailCalloutAccessoryView = rpAnnotation.calloutDetailView()   // (6.0.1)
                rpView.rightCalloutAccessoryView = addButton(annotation)
                let symbol = rpAnnotation.point.compulsory ? "triangle.fill" : "triangle"
                rpView.image = aeroMarkerSymbol(symbol, color: UIColor(red: 0.85, green: 0.2, blue: 0.6, alpha: 1.0), pointSize: 12)
                return rpView
            }

            if annotation is ObstacleAnnotation {
                let id = "BuilderObstacle"
                let obstacleView: MKAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) {
                    reused.annotation = annotation
                    obstacleView = reused
                } else {
                    obstacleView = MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                }
                obstacleView.canShowCallout = true
                obstacleView.image = aeroMarkerSymbol("exclamationmark.triangle.fill", color: UIColor(red: 0.95, green: 0.5, blue: 0.1, alpha: 1.0), pointSize: 13)
                return obstacleView
            }

            return nil
        }

        /// The callout's "+": the builder adds the point. Planning only: nil without `onPointAdd`.
        private func addButton(_ annotation: MKAnnotation) -> UIView? {
            guard parent.onPointAdd != nil, routePoint(for: annotation) != nil else { return nil }
            let button = UIButton(type: .contactAdd)
            button.accessibilityLabel = L10n.Nav.addToRoute
            return button
        }

        private func routePoint(for annotation: MKAnnotation?) -> RoutePoint? {
            switch annotation {
            case let airport as AirportAnnotation: return .aerodrome(airport.airport)
            case let navaid as NavaidAnnotation: return .navaid(navaid.navaid)
            case let point as ReportingPointAnnotation: return .reportingPoint(point.point, point.label)
            default: return nil
            }
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            // The official chart opens in the browser and adds nothing. (6.2.0)
            if let chart = control as? OfficialChartControl, let link = chart.link {
                parent.onOpenOfficialChart?(link.url)
                return
            }
            guard let point = routePoint(for: view.annotation) else { return }
            parent.onPointAdd?(point)
            mapView.deselectAnnotation(view.annotation, animated: true)
        }

        // Tap empty map → add a free waypoint. Taps on an annotation are handled by the callout.
        // MARK: Live drag handling (flight-plan revamp #3 + deliberate add)

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            switch gesture.state {
            case .began:
                beginDrag(mapView, at: point)                 // move / insert on a waypoint or the line
                if dragMode == nil { schedulePendingAdd(mapView, at: point) } // empty → deferred add
            case .changed:
                if dragMode == nil {
                    // Still before the deliberate-add threshold; movement here means the user is panning.
                    if let anchor = pendingAddAnchor, hypot(point.x - anchor.x, point.y - anchor.y) > 16 {
                        cancelPendingAdd()
                    }
                    return
                }
                let coord = mapView.convert(point, toCoordinateFrom: mapView)
                if case .append = dragMode {
                    // A dropped point previews where it will actually land (cheapest insertion),
                    // recomputed as the finger moves — not stuck appended to the end. (smart-insert feedback)
                    rebuildAppendPreview(mapView, coord: coord)
                    return
                }
                guard dragIndex < dragCoords.count else { return }
                dragCoords[dragIndex] = coord
                dragAnnotation?.coordinate = coord
                redrawDragRoute(mapView)
            case .ended:
                if dragMode == nil { cancelPendingAdd(); return } // released before the add threshold
                endDrag(mapView, at: point)
            case .cancelled, .failed:
                cancelPendingAdd()
                cancelDrag(mapView)
            default:
                break
            }
        }

        /// Arm a deferred add: after a longer hold on empty map (without panning), drop a new waypoint
        /// under the finger and let the user drag it before release. (tap-add feedback)
        private func schedulePendingAdd(_ mapView: MKMapView, at point: CGPoint) {
            guard parent.onAddWaypoint != nil else { return }
            cancelPendingAdd()
            pendingAddAnchor = point
            let work = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView, self.pendingAddAnchor != nil, self.dragMode == nil else { return }
                self.startAppendDrag(mapView, at: point)
            }
            pendingAddWork = work
            // ~0.2 s recognizer threshold + 0.45 s ≈ a deliberate two-thirds-second hold before it adds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }

        private func cancelPendingAdd() {
            pendingAddWork?.cancel()
            pendingAddWork = nil
            pendingAddAnchor = nil
        }

        private func startAppendDrag(_ mapView: MKMapView, at point: CGPoint) {
            pendingAddWork = nil
            pendingAddAnchor = nil
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            dragMode = .append
            let temp = RouteWaypointAnnotation(coordinate: coord, index: 0, name: "")
            mapView.addAnnotation(temp)
            dragAnnotation = temp
            dragCreatedTempAnnotation = true
            grabbed(mapView, deselect: nil)
            rebuildAppendPreview(mapView, coord: coord) // place it at the cheapest-insertion position
        }

        /// Rebuild the live preview for a dropped point: splice it into the route at the cheapest
        /// insertion index for its current position, so the line shows how it will actually link in.
        private func rebuildAppendPreview(_ mapView: MKMapView, coord: CLLocationCoordinate2D) {
            let idx = FlightPlanManager.bestInsertionIndex(for: coord, in: parent.waypoints)
            var coords = parent.waypoints.map { $0.coordinate }
            let at = min(idx, coords.count)
            coords.insert(coord, at: at)
            dragCoords = coords
            dragIndex = at
            dragAnnotation?.coordinate = coord
            redrawDragRoute(mapView)
        }

        /// Grab a waypoint (move) if the press is on one, else the nearest route segment (insert).
        private func beginDrag(_ mapView: MKMapView, at point: CGPoint) {
            let wpts = parent.waypoints
            guard !wpts.isEmpty else { return }
            if parent.onMoveWaypoint != nil,
               let idx = waypointIndex(near: point, mapView: mapView, maxPointDistance: 34),
               let anno = routeAnnotation(at: idx, in: mapView) {
                dragMode = .move(idx)
                dragCoords = wpts.map { $0.coordinate }
                dragIndex = idx
                dragAnnotation = anno
                dragCreatedTempAnnotation = false
                grabbed(mapView, deselect: anno)
                return
            }
            if parent.onInsertWaypoint != nil, wpts.count >= 2,
               let seg = closestSegment(to: point, mapView: mapView, maxPointDistance: 22) {
                let coord = mapView.convert(point, toCoordinateFrom: mapView)
                let insertAt = seg + 1
                dragMode = .insert(seg)
                dragCoords = wpts.map { $0.coordinate }
                dragCoords.insert(coord, at: insertAt)
                dragIndex = insertAt
                let temp = RouteWaypointAnnotation(coordinate: coord, index: insertAt, name: "")
                mapView.addAnnotation(temp)
                dragAnnotation = temp
                dragCreatedTempAnnotation = true
                grabbed(mapView, deselect: nil)
                redrawDragRoute(mapView)
            }
        }

        private func grabbed(_ mapView: MKMapView, deselect: MKAnnotation?) {
            mapView.isScrollEnabled = false
            if let deselect = deselect { mapView.deselectAnnotation(deselect, animated: false) }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        private func endDrag(_ mapView: MKMapView, at point: CGPoint) {
            guard let mode = dragMode else { return }
            let finalCoord = mapView.convert(point, toCoordinateFrom: mapView)
            if dragCreatedTempAnnotation, let temp = dragAnnotation { mapView.removeAnnotation(temp) }
            finishDrag(mapView)
            switch mode {
            case .move(let index): parent.onMoveWaypoint?(index, finalCoord)
            case .insert(let afterIndex): parent.onInsertWaypoint?(afterIndex, finalCoord)
            case .append: parent.onAddWaypoint?(finalCoord)
            }
        }

        private func cancelDrag(_ mapView: MKMapView) {
            finishDrag(mapView)
            // Rebuilds markers + line from the model, dropping any temp insert/append marker and
            // resetting a moved marker to its committed position.
            redrawCommittedRoute(mapView)
        }

        private func finishDrag(_ mapView: MKMapView) {
            dragMode = nil
            dragAnnotation = nil
            dragCoords = []
            dragCreatedTempAnnotation = false
            mapView.isScrollEnabled = true
        }

        /// Redraw the magenta route from the live working geometry (move/insert preview).
        private func redrawDragRoute(_ mapView: MKMapView) {
            RouteBuilderMapView.removeRouteOverlays(from: mapView)
            guard dragCoords.count >= 2 else { return }
            let casing = RouteCasingPolyline(coordinates: dragCoords, count: dragCoords.count)
            mapView.addOverlay(casing, level: .aboveLabels)
            let line = RouteLinePolyline(coordinates: dragCoords, count: dragCoords.count)
            mapView.addOverlay(line, level: .aboveLabels)
        }

        /// Rebuild markers + route from the committed model (used after a cancelled drag).
        private func redrawCommittedRoute(_ mapView: MKMapView) {
            let old = mapView.annotations.compactMap { $0 as? RouteWaypointAnnotation }
            mapView.removeAnnotations(old)
            RouteBuilderMapView.removeRouteOverlays(from: mapView)
            let wpts = parent.waypoints
            for (i, w) in wpts.enumerated() {
                mapView.addAnnotation(RouteWaypointAnnotation(coordinate: w.coordinate, index: i, name: w.name))
            }
            if wpts.count >= 2 {
                let coords = wpts.map { $0.coordinate }
                mapView.addOverlay(RouteCasingPolyline(coordinates: coords, count: coords.count), level: .aboveLabels)
                mapView.addOverlay(RouteLinePolyline(coordinates: coords, count: coords.count), level: .aboveLabels)
            }
            lastRouteSignature = wpts.map { "\($0.id.uuidString)\($0.latitude),\($0.longitude)" }.joined(separator: "|")
        }

        // MARK: Drag hit-testing

        /// Index of the waypoint whose marker is closest to `point` (within `maxPointDistance` px), or nil.
        private func waypointIndex(near point: CGPoint, mapView: MKMapView, maxPointDistance: CGFloat) -> Int? {
            var best: (index: Int, dist: CGFloat)?
            for (i, w) in parent.waypoints.enumerated() {
                let p = mapView.convert(w.coordinate, toPointTo: mapView)
                // The marker balloon sits above its coordinate tip — bias the hit centre up.
                let centre = CGPoint(x: p.x, y: p.y - 14)
                let d = hypot(point.x - centre.x, point.y - centre.y)
                if best == nil || d < best!.dist { best = (i, d) }
            }
            if let best = best, best.dist <= maxPointDistance { return best.index }
            return nil
        }

        private func routeAnnotation(at index: Int, in mapView: MKMapView) -> RouteWaypointAnnotation? {
            mapView.annotations.compactMap { $0 as? RouteWaypointAnnotation }.first { $0.index == index }
        }

        /// Start index of the route segment closest to `point` (within `maxPointDistance` px), or nil.
        private func closestSegment(to point: CGPoint, mapView: MKMapView, maxPointDistance: CGFloat) -> Int? {
            let wpts = parent.waypoints
            guard wpts.count >= 2 else { return nil }
            var best: (index: Int, dist: CGFloat)?
            for i in 0..<(wpts.count - 1) {
                let a = mapView.convert(wpts[i].coordinate, toPointTo: mapView)
                let b = mapView.convert(wpts[i + 1].coordinate, toPointTo: mapView)
                let d = distance(from: point, toSegment: a, b)
                if best == nil || d < best!.dist { best = (i, d) }
            }
            if let best = best, best.dist <= maxPointDistance { return best.index }
            return nil
        }

        private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let ap = CGPoint(x: p.x - a.x, y: p.y - a.y)
            let len2 = ab.x * ab.x + ab.y * ab.y
            let t = len2 == 0 ? 0 : max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / len2))
            let proj = CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
            return hypot(p.x - proj.x, p.y - proj.y)
        }

        // Let the tap coexist with the map's own pan/zoom recognizers.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

// MARK: - Route overlays

/// Black casing drawn underneath the magenta route core (a distinct subclass so the renderer can tell
/// the two `MKPolyline`s apart). Mirrors the in-flight navigation map's route styling.
final class RouteCasingPolyline: MKPolyline {}
/// The route's magenta core. Its own class, so the redraws take off the route and nothing else on the
/// map that is a polyline (the traffic circuits and VFR routes). (6.2.0)
final class RouteLinePolyline: MKPolyline {}
/// The halo under the leg selected in the route editor. (planning proposal D3)
final class SelectedLegPolyline: MKPolyline {}

// MARK: - Route waypoint annotation

/// A numbered route waypoint marker. `coordinate` is KVO-observable so MapKit can move it in place.
final class RouteWaypointAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let index: Int
    let title: String?
    /// The leg from this waypoint has a conflict: the pin is amber. (planning proposal D2)
    var hasConflict = false

    init(coordinate: CLLocationCoordinate2D, index: Int, name: String) {
        self.coordinate = coordinate
        self.index = index
        self.title = name.isEmpty ? "WPT\(index + 1)" : name
    }
}

// MARK: - Route altitude profile + cross-section (flight-plan revamp #4 redesign)

/// Piecewise-linear planned-altitude profile along the route, extrapolated from the waypoints that
/// carry a planned altitude (clamped at the ends). Shared by the builder (terrain clearance) and the
/// route-profile view (the altitude line). Distances use the same haversine NM as the airspace scan.
struct RouteAltitudeProfile {
    let cumNM: [Double]      // cumulative along-track distance per waypoint
    let totalNM: Double
    private let known: [(d: Double, alt: Double)]
    var hasData: Bool { !known.isEmpty }
    /// True only when at least two waypoints carry a planned altitude — i.e. there is a real,
    /// non-flat profile to judge terrain clearance against. A single known altitude extrapolates to a
    /// flat line across the whole route, which over rising terrain produces a false clearance bust.
    var hasUsableProfile: Bool { known.count >= 2 }

    init(_ waypoints: [FlightPlanWaypoint]) {
        var c: [Double] = []
        for (i, w) in waypoints.enumerated() {
            if i == 0 { c.append(0); continue }
            let a = waypoints[i - 1].coordinate, b = w.coordinate
            let leg = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852.0
            c.append(c[i - 1] + leg)
        }
        cumNM = c
        totalNM = c.last ?? 0
        var k: [(Double, Double)] = []
        for (i, w) in waypoints.enumerated() where i < c.count {
            if let alt = w.altitude { k.append((c[i], alt)) }
        }
        known = k.sorted { $0.0 < $1.0 }
    }

    func altitude(atNM d: Double) -> Double? {
        guard let first = known.first, let last = known.last else { return nil }
        if d <= first.d { return first.alt }
        if d >= last.d { return last.alt }
        for k in 1..<known.count where d <= known[k].d {
            let p0 = known[k - 1], p1 = known[k]
            let t = (d - p0.d) / max(0.0001, p1.d - p0.d)
            return p0.alt + (p1.alt - p0.alt) * t
        }
        return last.alt
    }
}

/// Vertical route cross-section: terrain silhouette + the extrapolated altitude line + the airspaces
/// the route enters (conflicts solid, "context" zones the route clears vertically drawn faded) + red
/// ticks where terrain clearance busts 150 m. The VFR-standard way to read vertical separation at a
/// glance. (flight-plan revamp #4 redesign)
private struct RouteProfileView: View {
    let waypoints: [FlightPlanWaypoint]
    let terrain: [(distance: Double, elevation: Double)]
    let blocks: [AirspaceProfileBlock]
    var selectedId: String? = nil          // tapped conflict — emphasised here too (#4)
    var terrainId: String = "terrain"
    var visibleRegion: MKCoordinateRegion? = nil   // shade the route window the map currently shows (#9)
    /// The leg selected in the table or on the map (from waypoint n to n+1): banded here, where it
    /// stands. (planning proposal D3)
    var selectedLeg: Int? = nil
    /// Drag a waypoint dot to set its altitude (waypoint index, snapped ft MSL). (R3)
    var onSetAltitude: ((Int, Double) -> Void)? = nil
    /// Tap an empty spot to drop a point on the route line (along-track NM, snapped ft). (R3)
    var onAddAtDistance: ((Double, Double) -> Void)? = nil

    @State private var dragKind: DragKind?
    @State private var draggingIndex: Int?
    @State private var draggingAltitude: Double?
    @State private var addHoldWork: DispatchWorkItem?   // deferred create: only after a short hold
    @State private var addAnchor: CGPoint?
    @State private var creatingNM: Double?              // a new point being held-then-dragged into place
    @State private var creatingAltitude: Double?
    private enum DragKind { case altitude(Int); case add; case creating }

    private let leftPad: CGFloat = 38
    private let bottomPad: CGFloat = 16
    private let topPad: CGFloat = 6
    private let rightPad: CGFloat = 8
    private static let warnFt: Double = 150 * 3.28084
    private static let magenta = Color(red: 1.0, green: 0.08, blue: 0.8)
    private static let altSnap: Double = 100
    /// VFR is excluded from Class A worldwide; above ~FL195 (EU/CH) is effectively IFR-only, and the US
    /// Class A floor is FL180 — so FL195 is the worldwide VFR ceiling. Caps the draggable altitude and
    /// the y-axis so the profile can't be scaled to impossible flight levels. (feedback)
    private static let maxAltitudeFt: Double = 19500   // FL195
    private static let profileCeilingFt: Double = 21000

    /// Everything the drawing and the gestures need, in one coordinate system so they can't drift. The
    /// y-axis (`yMax`) comes from the COMMITTED altitudes so it stays put while you drag a dot.
    private struct Geometry {
        let size: CGSize
        let plot: CGRect
        let totalNM: Double
        let yMax: Double
        let prof: RouteAltitudeProfile                 // effective (includes any live drag override)
        let terrainFt: [(nm: Double, ft: Double)]
        let lineFt: [(nm: Double, ft: Double)]
        func px(_ nm: Double) -> CGFloat { plot.minX + CGFloat(min(max(nm / totalNM, 0), 1)) * plot.width }
        func py(_ ft: Double) -> CGFloat { plot.minY + plot.height - CGFloat(min(max(ft / yMax, 0), 1)) * plot.height }
        func nm(forX x: CGFloat) -> Double { Double(min(max((x - plot.minX) / plot.width, 0), 1)) * totalNM }
        func ftRaw(forY y: CGFloat) -> Double { yMax * Double(1 - min(max((y - plot.minY) / plot.height, 0), 1)) }
    }

    var body: some View {
        GeometryReader { geo in
            let g = makeGeometry(size: geo.size)
            Canvas { ctx, _ in draw(ctx, g) }
                .contentShape(Rectangle())
                .gesture(editGesture(g))
        }
    }

    private func effectiveWaypoints() -> [FlightPlanWaypoint] {
        guard let i = draggingIndex, let a = draggingAltitude, i < waypoints.count else { return waypoints }
        var w = waypoints; w[i].altitude = a; return w
    }

    private func makeGeometry(size: CGSize) -> Geometry {
        let prof = RouteAltitudeProfile(effectiveWaypoints())
        let totalNM = max(prof.totalNM, 0.0001)
        let terrMax = terrain.last?.distance ?? 0
        let terrainFt: [(nm: Double, ft: Double)] = terrMax > 0
            ? terrain.map { (nm: ($0.distance / terrMax) * totalNM, ft: $0.elevation * 3.28084) } : []
        let lineFt: [(nm: Double, ft: Double)] = prof.hasData
            ? prof.cumNM.map { (nm: $0, ft: prof.altitude(atNM: $0) ?? 0) } : []
        // Stable axis: y-scale from the committed altitudes, so dragging a dot doesn't rescale mid-drag.
        let committed = RouteAltitudeProfile(waypoints)
        let committedLine: [(nm: Double, ft: Double)] = committed.hasData
            ? committed.cumNM.map { (nm: $0, ft: committed.altitude(atNM: $0) ?? 0) } : []
        let yMax = computeYMax(terrainFt: terrainFt, lineFt: committedLine)
        let plot = CGRect(x: leftPad, y: topPad, width: size.width - leftPad - rightPad, height: size.height - topPad - bottomPad)
        return Geometry(size: size, plot: plot, totalNM: totalNM, yMax: yMax, prof: prof, terrainFt: terrainFt, lineFt: lineFt)
    }

    private func draw(_ ctx: GraphicsContext, _ g: Geometry) {
        ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: g.size), cornerRadius: 8),
                 with: .color(Color(red: 0.10, green: 0.10, blue: 0.13)))

        // gridlines + altitude labels
        for frac in [0.0, 0.34, 0.67, 1.0] {
            let gy = g.plot.minY + g.plot.height * CGFloat(1 - frac)
            var line = Path(); line.move(to: CGPoint(x: g.plot.minX, y: gy)); line.addLine(to: CGPoint(x: g.plot.maxX, y: gy))
            ctx.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
            ctx.draw(Text(altLabel(g.yMax * frac)).font(.aero(size: 8, design: .monospaced)).foregroundColor(.dimText),
                     at: CGPoint(x: leftPad - 4, y: gy), anchor: .trailing)
        }

        // the selected leg: a band behind everything, so nothing moves or hides. (proposal D3)
        if let leg = selectedLeg, leg + 1 < g.prof.cumNM.count {
            let x0 = g.px(g.prof.cumNM[leg]), x1 = g.px(g.prof.cumNM[leg + 1])
            ctx.fill(Path(CGRect(x: x0, y: g.plot.minY, width: max(3, x1 - x0), height: g.plot.height)),
                     with: .color(Self.magenta.opacity(0.18)))
        }

        // airspace blocks (conflicts solid, context faded/dashed; the selected one emphasised)
        for b in blocks where b.floorFt <= g.yMax {
            let color = Color(red: b.airspace.mapColor.red, green: b.airspace.mapColor.green, blue: b.airspace.mapColor.blue)
            let path = bandPath(b, g, outer: false)
            let sel = b.id == selectedId
            if b.isVerticallyUncertain {
                // Possible conflict: only a limit in ft AGL over unknown terrain, or a flight level,
                // stands between the route and the airspace. Amber dashed edge, and how far the
                // airspace may really reach dotted around it. (APP-11)
                ctx.fill(path, with: .color(color.opacity(sel ? 0.32 : 0.14)))
                ctx.stroke(path, with: .color(Color.aviationAmber.opacity(sel ? 1.0 : 0.9)),
                           style: StrokeStyle(lineWidth: sel ? 2.5 : 1.25, dash: [5, 3]))
                ctx.stroke(bandPath(b, g, outer: true), with: .color(Color.aviationAmber.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            } else if b.isConflict {
                ctx.fill(path, with: .color(color.opacity(sel ? 0.42 : 0.22)))
                ctx.stroke(path, with: .color(color.opacity(sel ? 1.0 : 0.85)), lineWidth: sel ? 2.5 : 1)
            } else {
                ctx.fill(path, with: .color(color.opacity(sel ? 0.20 : 0.07)))
                ctx.stroke(path, with: .color(color.opacity(sel ? 0.9 : 0.35)),
                           style: StrokeStyle(lineWidth: sel ? 2 : 0.75, dash: sel ? [] : [4, 3]))
            }
        }

        // terrain silhouette
        let terrainFt = g.terrainFt
        if terrainFt.count >= 2 {
            var t = Path()
            t.move(to: CGPoint(x: g.px(terrainFt[0].nm), y: g.plot.maxY))
            for p in terrainFt { t.addLine(to: CGPoint(x: g.px(p.nm), y: g.py(p.ft))) }
            t.addLine(to: CGPoint(x: g.px(terrainFt.last!.nm), y: g.plot.maxY)); t.closeSubpath()
            ctx.fill(t, with: .color(Color(red: 0.42, green: 0.35, blue: 0.24).opacity(0.85)))
            var top = Path()
            top.move(to: CGPoint(x: g.px(terrainFt[0].nm), y: g.py(terrainFt[0].ft)))
            for p in terrainFt.dropFirst() { top.addLine(to: CGPoint(x: g.px(p.nm), y: g.py(p.ft))) }
            ctx.stroke(top, with: .color(Color(red: 0.54, green: 0.45, blue: 0.31)), lineWidth: 1)
        }

        // extrapolated altitude line + waypoint dots (the dragged one enlarged)
        let lineFt = g.lineFt
        if lineFt.count >= 2 {
            var l = Path()
            l.move(to: CGPoint(x: g.px(lineFt[0].nm), y: g.py(lineFt[0].ft)))
            for p in lineFt.dropFirst() { l.addLine(to: CGPoint(x: g.px(p.nm), y: g.py(p.ft))) }
            ctx.stroke(l, with: .color(Self.magenta), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            for (i, p) in lineFt.enumerated() {
                let r: CGFloat = (i == draggingIndex) ? 5 : 3
                ctx.fill(Path(ellipseIn: CGRect(x: g.px(p.nm) - r, y: g.py(p.ft) - r, width: r * 2, height: r * 2)), with: .color(Self.magenta))
            }
        }

        // terrain-clearance warning ticks (< 150 m); emphasised when the terrain row is selected
        if !terrainFt.isEmpty, g.prof.hasData {
            let terrSel = selectedId == terrainId
            for p in terrainFt {
                guard let alt = g.prof.altitude(atNM: p.nm), alt - p.ft < Self.warnFt else { continue }
                var m = Path(); m.move(to: CGPoint(x: g.px(p.nm), y: g.py(alt))); m.addLine(to: CGPoint(x: g.px(p.nm), y: g.py(p.ft)))
                ctx.stroke(m, with: .color(Color.aviationRed.opacity(terrSel ? 1.0 : 0.85)), lineWidth: terrSel ? 3.5 : 2)
            }
        }

        // conflicts, marked above the plot where they start: the rectangles below say how long and how
        // high, this says "here" at a glance. (planning proposal D2)
        for b in blocks where b.isConflict {
            // "?" for a possible conflict (a limit in ft AGL or a flight level decides). (APP-11)
            ctx.draw(Text(b.isVerticallyUncertain ? "?" : "⚠")
                        .font(.aero(size: 10, weight: b.isVerticallyUncertain ? .bold : nil))
                        .foregroundColor(.aviationAmber),
                     at: CGPoint(x: min(max(g.px((b.startNM + b.endNM) / 2), g.plot.minX + 6), g.plot.maxX - 6),
                                 y: g.plot.minY + 7), anchor: .center)
        }

        // x-axis waypoint labels: numbered like the pins on the map, named only where the name fits
        // before the next waypoint. Every name used to be drawn, and they ran into one line
        // ("SamedanWPTWPT…"). (planning proposal D1)
        let xs = g.prof.cumNM.prefix(waypoints.count).map { g.px($0) }
        var lastRight: CGFloat = -.infinity
        for (i, x) in xs.enumerated() {
            let isEnd = i == 0 || i == xs.count - 1
            let color: Color = i == 0 ? .aviationGreen : (i == xs.count - 1 ? .aviationGold : .secondaryText)
            let number = ctx.resolve(Text("\(i + 1)").font(.aero(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(color))
            let numberWidth = number.measure(in: CGSize(width: 60, height: 20)).width
            guard x - numberWidth / 2 > lastRight + 3 || isEnd else { continue }
            let y = g.size.height - 6
            ctx.draw(number, at: CGPoint(x: x, y: y), anchor: .center)
            lastRight = x + numberWidth / 2
            let rawName = waypoints[i].name
            guard !rawName.isEmpty, !rawName.hasPrefix("WPT") else { continue }
            let name = ctx.resolve(Text(rawName).font(.aero(size: 10, design: .monospaced)).foregroundColor(color))
            let nameWidth = name.measure(in: CGSize(width: 200, height: 20)).width
            let nextX = i + 1 < xs.count ? xs[i + 1] : g.size.width
            let room = (i == xs.count - 1 ? g.size.width - rightPad : nextX - 10) - (lastRight + 3)
            if nameWidth <= room {
                ctx.draw(name, at: CGPoint(x: lastRight + 3, y: y), anchor: .leading)
                lastRight += 3 + nameWidth
            } else if i == xs.count - 1, nameWidth <= x - numberWidth / 2 - 4 - (lastRight - numberWidth) {
                // The destination's name, left of its number when there's no room after it.
                ctx.draw(name, at: CGPoint(x: x - numberWidth / 2 - 3, y: y), anchor: .trailing)
            }
        }

        // "You are looking here" — the along-track window the map above currently shows. (#9)
        //
        // Drawn LAST (only the live drag readouts go on top) and inverted: instead of tinting the
        // visible window, everything OUTSIDE it is dimmed. The old version painted a 5%-white band
        // UNDER the airspace blocks, so the conflict rectangles covered it and what survived was
        // indistinguishable from another faint context block — the one thing it must never look like.
        // Dimming the off-route parts is the minimap/range-selector convention: it removes emphasis
        // rather than adding another coloured box, so it cannot be misread as a hazard, and the
        // white bracket along the top says which slice of the route is on screen.
        // (device-test feedback, v4.4.0)
        if let region = visibleRegion, waypoints.count >= 2,
           let (lo, hi) = visibleWindowNM(region, cumNM: g.prof.cumNM), hi > lo,
           (hi - lo) / g.totalNM < 0.98 {   // covers the whole route → nothing to point at
            let x0 = g.px(lo), x1 = max(g.px(hi), g.px(lo) + 2)
            let scrim = GraphicsContext.Shading.color(.black.opacity(0.5))
            ctx.fill(Path(CGRect(x: 0, y: 0, width: x0, height: g.size.height)), with: scrim)
            ctx.fill(Path(CGRect(x: x1, y: 0, width: max(0, g.size.width - x1), height: g.size.height)), with: scrim)

            let bracket = GraphicsContext.Shading.color(.white.opacity(0.9))
            ctx.fill(Path(CGRect(x: x0, y: g.plot.minY, width: x1 - x0, height: 3)), with: bracket)
            for edge in [x0, x1 - 1] {
                ctx.fill(Path(CGRect(x: edge, y: g.plot.minY, width: 1, height: 9)), with: bracket)
            }
        }

        // live altitude readout while dragging an existing dot
        if let i = draggingIndex, let a = draggingAltitude, i < lineFt.count {
            drawReadout(ctx, g: g, at: CGPoint(x: g.px(lineFt[i].nm), y: g.py(lineFt[i].ft)), altitude: a)
        }

        // a new point being held-then-dragged into place: a dot on the finger, dashed connectors to the
        // waypoints it will sit between, and its altitude readout. (feedback)
        if let nm = creatingNM, let a = creatingAltitude {
            let dot = CGPoint(x: g.px(nm), y: g.py(a))
            if !lineFt.isEmpty {
                var leftIdx = 0
                for (i, p) in lineFt.enumerated() where p.nm <= nm { leftIdx = i }
                let rightIdx = min(leftIdx + 1, lineFt.count - 1)
                for idx in Set([leftIdx, rightIdx]) {
                    let np = CGPoint(x: g.px(lineFt[idx].nm), y: g.py(lineFt[idx].ft))
                    var seg = Path(); seg.move(to: dot); seg.addLine(to: np)
                    ctx.stroke(seg, with: .color(Self.magenta.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 5, y: dot.y - 5, width: 10, height: 10)), with: .color(Self.magenta))
            drawReadout(ctx, g: g, at: dot, altitude: a)
        }
    }

    /// An airspace block's outline on the profile: its band sample by sample, so a limit in ft AGL
    /// follows the ground instead of being drawn as a flat line; a plain rectangle when there is only
    /// one sample. `outer` draws how far the band may really reach instead. (APP-11)
    private func bandPath(_ b: AirspaceProfileBlock, _ g: Geometry, outer: Bool) -> Path {
        let pts = b.outline
        guard pts.count >= 2 else {
            let top = g.py(min(outer ? b.outerCeilingFt : b.ceilingFt, g.yMax))
            let bottom = g.py(outer ? b.outerFloorFt : b.floorFt)
            return Path(CGRect(x: g.px(b.startNM), y: top,
                               width: max(2, g.px(b.endNM) - g.px(b.startNM)), height: bottom - top))
        }
        var path = Path()
        for (i, p) in pts.enumerated() {
            let at = CGPoint(x: g.px(p.nm), y: g.py(min(outer ? p.outerCeilingFt : p.ceilingFt, g.yMax)))
            if i == 0 { path.move(to: at) } else { path.addLine(to: at) }
        }
        for p in pts.reversed() {
            path.addLine(to: CGPoint(x: g.px(p.nm), y: g.py(outer ? p.outerFloorFt : p.floorFt)))
        }
        path.closeSubpath()
        return path
    }

    private func drawReadout(_ ctx: GraphicsContext, g: Geometry, at p: CGPoint, altitude a: Double) {
        let resolved = ctx.resolve(Text(altLabel(a) + (a >= 10000 ? "" : " ft"))
            .font(.aero(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.black))
        let sz = resolved.measure(in: CGSize(width: 140, height: 30))
        let cx = min(max(p.x, g.plot.minX + sz.width / 2 + 8), g.plot.maxX - sz.width / 2 - 8)
        let cy = (p.y - 16 < g.plot.minY + 10) ? p.y + 18 : p.y - 16
        let pill = CGRect(x: cx - sz.width / 2 - 5, y: cy - sz.height / 2 - 2, width: sz.width + 10, height: sz.height + 4)
        ctx.fill(Path(roundedRect: pill, cornerRadius: 5), with: .color(Self.magenta))
        ctx.draw(resolved, at: CGPoint(x: cx, y: cy), anchor: .center)
    }

    // MARK: Editing gestures (R3)

    private func editGesture(_ g: Geometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragKind == nil {
                    if onSetAltitude != nil, let i = nearestDot(to: v.startLocation, g: g) {
                        dragKind = .altitude(i); draggingIndex = i
                    } else {
                        // Not on a dot — a short hold creates a point you then drag into place; a quick
                        // tap or the start of a scrub does nothing. (feedback)
                        dragKind = .add
                        if onAddAtDistance != nil { armCreate(at: v.startLocation, g: g) }
                    }
                }
                switch dragKind {
                case .altitude:
                    draggingAltitude = snapAlt(g.ftRaw(forY: v.location.y))
                case .add:
                    if let a = addAnchor, hypot(v.location.x - a.x, v.location.y - a.y) > 16 { cancelCreate() }
                case .creating:
                    creatingNM = g.nm(forX: v.location.x)
                    creatingAltitude = snapAlt(g.ftRaw(forY: v.location.y))
                case .none: break
                }
            }
            .onEnded { _ in
                switch dragKind {
                case .altitude(let i):
                    if let a = draggingAltitude { onSetAltitude?(i, a) }
                case .creating:
                    if let nm = creatingNM, let a = creatingAltitude { onAddAtDistance?(nm, a) }
                case .add, .none: break // released before the hold fired → no point
                }
                cancelCreate()
                dragKind = nil; draggingIndex = nil; draggingAltitude = nil
                creatingNM = nil; creatingAltitude = nil
            }
    }

    /// After a short ~0.2 s hold on an empty spot, materialise a new point under the finger (haptic);
    /// the finger then drags it into place (distance ← x, altitude ← y) before release commits it. A
    /// quick tap or the start of a scrub cancels before it fires, so nothing is created by accident.
    private func armCreate(at p: CGPoint, g: Geometry) {
        cancelCreate()
        addAnchor = p
        let work = DispatchWorkItem {
            dragKind = .creating
            creatingNM = g.nm(forX: p.x)
            creatingAltitude = snapAlt(g.ftRaw(forY: p.y))
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        addHoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func cancelCreate() {
        addHoldWork?.cancel(); addHoldWork = nil; addAnchor = nil
    }

    /// Waypoint index whose dot is within ~28 pt of `p`, or nil.
    private func nearestDot(to p: CGPoint, g: Geometry) -> Int? {
        guard !g.lineFt.isEmpty else { return nil }
        var best: (i: Int, d: CGFloat)?
        for (i, pt) in g.lineFt.enumerated() {
            let d = hypot(p.x - g.px(pt.nm), p.y - g.py(pt.ft))
            if best == nil || d < best!.d { best = (i, d) }
        }
        if let b = best, b.d <= 28 { return b.i }
        return nil
    }

    private func snapAlt(_ ft: Double) -> Double {
        min(Self.maxAltitudeFt, max(0, (ft / Self.altSnap).rounded() * Self.altSnap))
    }

    private func computeYMax(terrainFt: [(nm: Double, ft: Double)], lineFt: [(nm: Double, ft: Double)]) -> Double {
        var top = terrainFt.map { $0.ft }.max() ?? 0
        let routeTop = lineFt.map { $0.ft }.max() ?? 0
        top = max(top, routeTop)
        for b in blocks where b.isConflict { top = max(top, b.ceilingFt) }
        top = max(top, routeTop + 4000) // headroom to show nearby context-zone floors above the route
        return min(Self.profileCeilingFt, max(2000, top * 1.1)) // never scale beyond the VFR ceiling
    }

    private func altLabel(_ ft: Double) -> String {
        if ft <= 0 { return "GND" }
        if ft >= 10000 { return "FL\(Int((ft / 100).rounded()))" }
        return "\(Int((ft / 100).rounded()) * 100)"
    }

    /// The min/max along-track distance (NM) of the route currently inside the map's visible bounds,
    /// by sampling each leg ~every 2 NM. Nil when no part of the route is visible. (#9)
    private func visibleWindowNM(_ region: MKCoordinateRegion, cumNM: [Double]) -> (Double, Double)? {
        guard cumNM.count == waypoints.count, waypoints.count >= 2 else { return nil }
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2
        var lo = Double.infinity, hi = -Double.infinity
        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i].coordinate, b = waypoints[i + 1].coordinate
            let segNM = cumNM[i + 1] - cumNM[i]
            let steps = max(1, Int((segNM / 2).rounded(.up)))
            for s in 0...steps {
                let t = Double(s) / Double(steps)
                let lat = a.latitude + (b.latitude - a.latitude) * t
                let lon = a.longitude + (b.longitude - a.longitude) * t
                if lat >= minLat, lat <= maxLat, lon >= minLon, lon <= maxLon {
                    let d = cumNM[i] + segNM * t
                    lo = min(lo, d); hi = max(hi, d)
                }
            }
        }
        guard lo.isFinite else { return nil }
        // Don't draw the band when the whole route is already on screen — it would cover everything. (feedback)
        let total = cumNM.last ?? 0
        if lo <= total * 0.02, hi >= total * 0.98 { return nil }
        return (lo, hi)
    }
}
