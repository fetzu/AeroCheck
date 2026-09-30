import SwiftUI

// MARK: - Plan new flight (v5.0.0)
//
// The one place a flight comes into existence. Every door — Home's empty state, the Flights
// destination, "Plan this again" from a flown flight — opens THIS sheet, pre-filled to different
// degrees. A second, quieter creation path is exactly how the thread ended up invisible in the first
// place, so there deliberely isn't one.
//
// It is called "Plan new flight", not "New flight", because "New flight" sitting next to "Start
// flight" reads as two ways to begin flying. This one plans; the other two start.
//
// Planning proposal B (on-device review #4): the route first, as airports or a saved route, since
// it's the one thing only the pilot can supply; then when and the aircraft, already filled in; and
// Create in a bar pinned to the bottom that says what it will create. It used to be the last item
// in the scroll, below the fold in portrait.
//
// Stops (6.1, trips proposal M1): the aerodromes are labelled FROM and TO, fixed at the ends, with
// the stops between them. "Add a stop on the way" always goes just before TO, stops drag into order,
// and a legs card previews each leg and holds each stop's time on the ground and refuel, which a trip
// typed here used to get as a fixed 30 minutes without fuel.
//
// Landing on the way from a saved route (6.1, trips proposal M2): once a route is picked, the
// aerodromes on or near it are listed in flying order, each with a "Land here" switch, and the same
// legs card previews the route split at the ones switched on. The sheet opens at the home aerodrome
// (FROM, and TO back home) when Settings has one and nothing else seeds it.

struct PlanNewFlightView: View {

    /// Pre-filled for "Plan this again"; near-empty for a flight planned from scratch.
    @State private var intent: NewFlightIntent
    @State private var hasDepartureTime: Bool

    private let aircraft: [AircraftOption]
    /// The pilot's routes, offered as a starting point (not the plans flights made for themselves,
    /// nor archived ones: `RouteLibrary.activeRoutes`). (v5.x; review #4)
    private let savedRoutes: [FlightPlan]
    /// What to create: FROM, the stops with their time on the ground and refuel, and TO as typed; or
    /// the saved route this flight is built from, which the creator copies wholesale rather than
    /// rebuilding from the two end idents, and where to land on it.
    private let onCreate: (PlannedFlight) -> Void
    private let onCancel: () -> Void

    /// The airport layer, for completing what the pilot types. Injected so this view stays testable
    /// and so the caller decides whether the data is loaded.
    @EnvironmentObject private var airports: AirportDataService
    @State private var suggestions: [Airport] = []
    /// A saved route this flight starts from. Non-nil means the route is copied whole rather than
    /// rebuilt from the idents below, which is what keeps its waypoints, altitudes and fuel. (v5.x)
    @State private var selectedRoute: FlightPlan?
    /// Airports, or a saved route. (planning proposal B1)
    @State private var fromSavedRoute = false
    @State private var routeSearch = ""
    /// Scroll target for the completion list, so the keyboard never covers it.
    private static let suggestionsAnchor = "aerocheck.plan.suggestions"
    /// Scroll target for "Add a stop on the way", so the pinned bar never covers it. (6.1)
    private static let addStopAnchor = "aerocheck.plan.addStop"
    @State private var isLoadingAirports = false

    /// FROM, the stops, TO. Two aerodromes are a flight; three or more are a trip, and the button says
    /// so. (6.1)
    @State private var stops: PlannedStops
    /// The rows the sheet opened with, which "Airports" comes back to after a saved route. (6.1)
    private let openingStops: PlannedStops

    /// The aerodromes the chosen route passes, and where it lands. (6.1, M2)
    @State private var routeLandings = RouteLandings()
    @State private var isLoadingRouteAerodromes = false
    /// Every aerodrome near a long route, rather than those it was drawn through. (6.1)
    @State private var showsAllRouteAerodromes = false
    /// "Land somewhere else…": the search, open or not, and what it found.
    @State private var isLandingElsewhere = false
    @State private var elsewhereQuery = ""
    @State private var elsewhereResults: [TripPlanner.StopCandidate] = []
    @FocusState private var elsewhereFocused: Bool
    private static let elsewhereAnchor = "aerocheck.plan.landElsewhere"

    /// The row being typed in, by id: rows move, and focus follows the row rather than a position.
    @FocusState private var focused: UUID?

    /// The stop being dragged by its handle. (6.1)
    @State private var drag: StopDrag?
    /// One stop row's height plus the spacing: how far a finger goes to move a stop by one place.
    @State private var rowPitch: CGFloat = 58
    /// FROM, STOP 1, TO: wide enough for "ESCALE 1", and growing with the text.
    @ScaledMetric(relativeTo: .caption2) private var labelWidth: CGFloat = 60
    /// Room for a stop's drag handle and remove button, kept on FROM and TO too so the fields line up.
    private static let stopControlsWidth: CGFloat = 80

    /// `homeAerodrome` (Settings) opens the sheet at home when nothing else seeds it. (6.1)
    init(intent: NewFlightIntent,
         aircraft: [AircraftOption],
         savedRoutes: [FlightPlan] = [],
         homeAerodrome: String? = nil,
         onCreate: @escaping (PlannedFlight) -> Void,
         onCancel: @escaping () -> Void) {
        var seeded = intent
        // Already set, to tomorrow at 10:00: a date is what the preparation reminder counts back
        // from, and a default a pilot edits beats a switch they have to find. "No date yet" stays
        // one tap away. (planning proposal B1)
        if seeded.departureTime == nil { seeded.departureTime = Self.defaultDeparture() }
        _intent = State(initialValue: seeded)
        let opening = PlannedStops.opening(for: intent, home: homeAerodrome)
        _stops = State(initialValue: opening)
        openingStops = opening
        _hasDepartureTime = State(initialValue: true)
        self.aircraft = aircraft
        self.savedRoutes = savedRoutes
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ScrollViewReader { proxy in
                    // Each card is its own view value, so the body doesn't carry all of them inline on
                    // the main thread's stack (see `SeparateView`).
                    VStack(spacing: 14) {
                        SeparateView { routeSection }
                        if showsLegs { SeparateView { legsSection } }
                        SeparateView { whenSection }
                        SeparateView { aircraftSection }
                    }
                    .padding(16)
                    // The suggestions render under the field they belong to, which is right — a
                    // floating overlay over a form is worse to aim at. But the keyboard takes the
                    // bottom half of the sheet, and that is exactly where the list appeared. Scroll
                    // it into view whenever it changes, so it is never behind the keys.
                    .onChange(of: suggestions.map(\.ident)) { _, idents in
                        guard !idents.isEmpty else {
                            // The list closed (an exact code closes it): bring back what it pushed
                            // away, "Add a stop on the way" first. (6.1)
                            keepAddStopInView(proxy)
                            return
                        }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.suggestionsAnchor, anchor: .bottom)
                        }
                    }
                    // A stop being typed has "Add a stop on the way" right under it. On an iPhone with
                    // the keyboard up, scrolling to the field alone left the button under the pinned
                    // bar from the third row on, so the next stop couldn't be added without dismissing
                    // the keyboard. Once the keyboard has settled, bring the button up too. (6.1)
                    .onChange(of: focused) { _, id in
                        guard let id, isTypingAStop else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            guard focused == id else { return }
                            keepAddStopInView(proxy)
                        }
                    }
                    // "Land somewhere else…" lists what it finds under its field: above the keys too.
                    .onChange(of: elsewhereResults.map(\.aerodrome.ident)) { _, idents in
                        guard !idents.isEmpty else { return }
                        // Once the rows are laid out: scrolled at once, the list stayed under the bar.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(120))
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(Self.elsewhereAnchor, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.cockpitBackground)
            // Create, always in reach, with what it will create. (planning proposal B2)
            .safeAreaInset(edge: .bottom, spacing: 0) { createBar }
            .navigationTitle(L10n.Flights.planNewFlight)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { onCancel() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Loaded on demand, so completion works even on a cold start — without this the field
            // silently offers nothing and the pilot concludes the aerodrome is unknown.
            isLoadingAirports = true
            await airports.ensureLoaded()
            isLoadingAirports = false
            search()
        }
        // The aerodromes a chosen route passes, listed once it is chosen. (6.1, M2)
        .task(id: selectedRoute?.id) { await loadRouteAerodromes() }
    }

    // MARK: - Route (planning proposal B1)

    private var routeSection: some View {
        card(L10n.PlanFlight.route) {
            if !savedRoutes.isEmpty {
                Picker(L10n.PlanFlight.route, selection: $fromSavedRoute.animation(.easeInOut(duration: 0.15))) {
                    Text(L10n.PlanFlight.airports).tag(false)
                    Text(L10n.PlanFlight.savedRoute).tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: fromSavedRoute) { _, saved in
                    if !saved { clearRoute() }
                    focused = nil
                    elsewhereFocused = false
                }
            }
            if fromSavedRoute {
                savedRoutePicker
            } else {
                airportFields
            }
        }
    }

    /// FROM, the stops, TO. (6.1, trips proposal M1)
    private var airportFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(stops.rows.enumerated()), id: \.element.id) { index, row in
                // Always between the last stop and TO: a stop is somewhere on the way, never after
                // the destination.
                if index == stops.rows.count - 1 { addStopButton }
                stopRow(row, at: index)
                if focused == row.id, !suggestions.isEmpty { suggestionList }
            }

            if let note = routeNote {
                Label(note, systemImage: "info.circle")
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, labelWidth + 10)
            } else if stops.legCount < 2 {
                // With stops, the legs card says it ("direct until you draw it").
                Text(L10n.PlanFlight.drawLater)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, labelWidth + 10)
            }
        }
        .onChange(of: stops) { _, _ in search() }
        // Leaving a field settles what was typed there: a name that matches one aerodrome becomes its
        // code, so "Grenchen" isn't kept as an ident nothing can find. (v6.0 review)
        .onChange(of: focused) { previous, _ in
            if let previous { resolveTyped(previous) }
        }
        .onChange(of: focused) { _, _ in search() }
    }

    /// A stop's field has the keyboard.
    private var isTypingAStop: Bool {
        guard let focused, let index = stops.index(of: focused) else { return false }
        return stops.stopIndices.contains(index)
    }

    /// Keep "Add a stop on the way" in view above the pinned bar while a field is typed in, unless the
    /// completion list is open: that comes first. It sits right under a stop, so the stop's field and
    /// the button end above the bar; TO sits right under it, so TO's field does.
    private func keepAddStopInView(_ proxy: ScrollViewProxy) {
        guard let focused, suggestions.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            if isTypingAStop {
                proxy.scrollTo(Self.addStopAnchor, anchor: .bottom)
            } else {
                proxy.scrollTo(focused, anchor: .bottom)
            }
        }
    }

    /// Whether any row sits between FROM and TO, typed in or not.
    private var hasStopRows: Bool { !stops.stopIndices.isEmpty }

    private func stopRow(_ row: PlannedStops.Row, at index: Int) -> some View {
        let role = stops.role(at: index)
        let isStop = stops.stopIndices.contains(index)
        let isDragged = drag?.id == row.id
        return HStack(spacing: 10) {
            Text(roleLabel(role).uppercased())
                .scaledFont(size: 11, weight: .bold, design: .monospaced, relativeTo: .caption2)
                .tracking(0.8)
                .foregroundColor(isStop ? .altimeterBlue : .aviationGold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: labelWidth, alignment: .leading)
                .accessibilityHidden(true)
            field(row, role: role, index: index)
            if isStop {
                HStack(spacing: 0) {
                    dragHandle(row)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { stops.removeStop(row.id) }
                        focused = nil
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.dimText)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.PlanFlight.removeStop)
                }
                .frame(width: Self.stopControlsWidth, alignment: .trailing)
            } else if hasStopRows {
                Color.clear.frame(width: Self.stopControlsWidth, height: 1)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground)
                .shadow(color: .black.opacity(isDragged ? 0.5 : 0), radius: 8, y: 3)
                .padding(-4)
        )
        .offset(y: isDragged ? dragOffset(for: row.id) : 0)
        .zIndex(isDragged ? 1 : 0)
        .id(row.id)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if isStop, height > 0 { rowPitch = height + 10 }
        }
    }

    private func field(_ row: PlannedStops.Row, role: PlannedStops.Role, index: Int) -> some View {
        HStack(spacing: 10) {
            TextField(L10n.Flights.identPlaceholder, text: binding(for: row.id))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.aero(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(.primaryText)
                .focused($focused, equals: row.id)
                .onSubmit { resolveTyped(row.id) }
                // Room for a code, and the rest for the aerodrome's name.
                .frame(minWidth: 72)
                .accessibilityLabel(roleLabel(role))
                .accessibilityActions { moveActions(row, at: index) }
            // What the stop resolves to: the aerodrome's name (the check that LSZS is Samedan), or
            // that it can't be found, rather than a flight that silently loses it. Not while typing:
            // "GREN" is not unknown yet. (v6.0 review)
            switch stopState(row.ident) {
            case .resolved(let name):
                // Back where it started: said in the field, so a round trip reads as one. (6.1)
                Text(role == .to && isBackHome ? L10n.PlanFlight.backHome(name) : name)
                    .scaledFont(size: 14, relativeTo: .subheadline)
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
            case .loading:
                Text(L10n.PlanFlight.loadingAerodromes)
                    .scaledFont(size: 14, relativeTo: .subheadline)
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
            case .unknown where focused != row.id:
                Label(L10n.PlanFlight.unknownAerodrome, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundColor(.aviationAmber)
                    .lineLimit(1)
            default:
                EmptyView()
            }
            // Typing over an aerodrome already there (home, back home, "Plan this again") is one tap
            // away rather than four backspaces. (6.1)
            if focused == row.id, !row.ident.isEmpty {
                Button { stops.setIdent("", for: row.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 16, relativeTo: .body)
                        .foregroundColor(.dimText)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Button.clear)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground))
    }

    /// TO is FROM again: the flight comes back to where it left.
    private var isBackHome: Bool {
        let from = stops.rows.first?.normalisedIdent ?? ""
        return !from.isEmpty && stops.rows.last?.normalisedIdent == from
    }

    private func roleLabel(_ role: PlannedStops.Role) -> String {
        switch role {
        case .from: return L10n.Flights.from
        case .stop(let number): return L10n.PlanFlight.stopLabel(number)
        case .to: return L10n.Flights.to
        }
    }

    /// "Add a stop on the way": a new stop just before TO, ready to type in.
    private var addStopButton: some View {
        Button {
            let id = withAnimation(.easeInOut(duration: 0.15)) { stops.addStop() }
            focused = id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                Text(L10n.PlanFlight.addStopOnTheWay)
                    .multilineTextAlignment(.leading)
            }
            .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
            .foregroundColor(.altimeterBlue)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.altimeterBlue.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, labelWidth + 10)
        .id(Self.addStopAnchor)
    }

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(suggestions.prefix(5), id: \.ident) { airport in
                Button { accept(airport) } label: {
                    HStack(spacing: 8) {
                        Text(airport.ident)
                            .font(.aero(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.aviationGold)
                            .frame(width: 52, alignment: .leading)
                        Text(airport.name)
                            .scaledFont(size: 14, relativeTo: .footnote)
                            .foregroundColor(.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                if airport.ident != suggestions.prefix(5).last?.ident {
                    Divider().overlay(Color.white.opacity(0.06))
                }
            }
        }
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground))
        .padding(.leading, labelWidth + 10)
        .id(Self.suggestionsAnchor)
    }

    // MARK: - Reordering the stops (6.1)

    private struct StopDrag: Equatable {
        let id: UUID
        /// Where the stop was when the drag began.
        let startIndex: Int
        /// How far the finger has moved, in the window, since then.
        var translation: CGFloat
    }

    /// The handle a stop is dragged by. It moves at once, with no long press: the handle is there for
    /// nothing else, and the field beside it keeps its tap for typing.
    private func dragHandle(_ row: PlannedStops.Row) -> some View {
        Image(systemName: "line.3.horizontal")
            .scaledFont(size: 16, weight: .semibold, relativeTo: .subheadline)
            .foregroundColor(.dimText)
            .frame(width: 36, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in dragMoved(row.id, by: value.translation.height) }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.15)) { drag = nil }
                    }
            )
            // VoiceOver moves a stop with the field's Move up / Move down actions instead.
            .accessibilityHidden(true)
    }

    /// The stop follows the finger; the others make room as it passes half of a row.
    private func dragMoved(_ id: UUID, by translation: CGFloat) {
        if drag?.id != id {
            guard let start = stops.index(of: id) else { return }
            drag = StopDrag(id: id, startIndex: start, translation: 0)
            // The completion list sits between rows and would throw the arithmetic off.
            focused = nil
            suggestions = []
        }
        drag?.translation = translation
        guard let drag, let current = stops.index(of: id), rowPitch > 0 else { return }
        let range = stops.stopIndices
        let target = min(max(drag.startIndex + Int((translation / rowPitch).rounded()), range.lowerBound),
                         range.upperBound - 1)
        if target != current {
            withAnimation(.easeInOut(duration: 0.15)) { stops.moveStop(id, to: target) }
        }
    }

    /// The dragged stop is laid out in its new place; this keeps it under the finger.
    private func dragOffset(for id: UUID) -> CGFloat {
        guard let drag, let current = stops.index(of: id) else { return 0 }
        return drag.translation - CGFloat(current - drag.startIndex) * rowPitch
    }

    @ViewBuilder
    private func moveActions(_ row: PlannedStops.Row, at index: Int) -> some View {
        let range = stops.stopIndices
        if range.contains(index) {
            if index > range.lowerBound {
                Button(L10n.Nav.moveUp) { stops.moveStop(row.id, to: index - 1) }
            }
            if index < range.upperBound - 1 {
                Button(L10n.Nav.moveDown) { stops.moveStop(row.id, to: index + 1) }
            }
        }
    }

    // MARK: - Legs (6.1, trips proposal M1, M2)

    private var showsLegs: Bool {
        fromSavedRoute ? (selectedRoute != nil && !routeLandings.landings.isEmpty) : stops.legCount >= 2
    }

    /// The legs Create will make, built as the creator builds them, so the times here are the times
    /// the legs get. Direct, as they are created: the pilot draws each route later.
    private var previewLegs: [FlightPlan] {
        TripPlanner.typedLegs(idents: stops.idents, stopovers: stops.stopovers, template: normalised()) {
            FlightCreator.place($0, in: airports)
        }
    }

    /// The chosen route split at its landings: the flight's copy of the route (`FlightCreator`'s), split
    /// as `createTrip(fromRoute:)` splits it, so each leg shows its own waypoints and times.
    private var previewRouteLegs: [FlightPlan] {
        guard let selectedRoute else { return [] }
        return TripPlanner.legs(of: FlightCreator.plan(fromRoute: selectedRoute, intent: normalised()),
                                landingAt: routeLandings.landings)
    }

    /// One row per leg, and between two legs the stop: how long on the ground, and whether to refuel.
    /// This is where a trip's stops are set; a typed trip's used to be a fixed 30 minutes without fuel,
    /// with nowhere to change them.
    @ViewBuilder
    private var legsSection: some View {
        if fromSavedRoute {
            let legs = previewRouteLegs
            TripLegsCard(legs: legs,
                         idents: TripLegsCard.idents(of: legs),
                         stopovers: legs.dropFirst().map { $0.stopover ?? Stopover() },
                         aside: selectedRoute.map { L10n.PlanFlight.splitFrom(routeTitle($0)) },
                         showsWaypointCount: true,
                         explainer: L10n.PlanFlight.routeLegsExplainer) { index, stopover in
                let idents = TripLegsCard.idents(of: legs)
                if idents.indices.contains(index + 1) { routeLandings.setStopover(stopover, at: idents[index + 1]) }
            }
        } else {
            let legs = previewLegs
            let filled = stops.filledRows
            TripLegsCard(legs: legs,
                         idents: filled.map(\.normalisedIdent),
                         stopovers: stops.stopovers,
                         aside: TripLegsCard.total(legs, direct: true),
                         explainer: L10n.PlanFlight.legsExplainer) { index, stopover in
                if filled.indices.contains(index + 1) { stops.setStopover(stopover, for: filled[index + 1].id) }
            }
        }
    }

    /// The pilot's routes, searchable, with their maps; one tap chooses. Start from a route already
    /// built rather than typing its ends again: a saved route is worth having because of the work
    /// inside it — waypoints placed by hand, altitudes, fuel figures. (v5.x; proposal B1)
    private var savedRoutePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.dimText)
                TextField(L10n.Routes.searchPrompt, text: $routeSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .scaledFont(size: 16, relativeTo: .body)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground))

            let matches = savedRoutes.filter { RouteLibrary.matches($0, query: routeSearch) }
            if matches.isEmpty {
                Text(L10n.Routes.noMatch(routeSearch))
                    .scaledFont(size: 14, relativeTo: .subheadline)
                    .foregroundColor(.secondaryText)
                    .padding(.vertical, 6)
            }
            ForEach(matches.prefix(4)) { route in
                let isChosen = selectedRoute?.id == route.id
                Button { choose(route) } label: {
                    HStack(spacing: 12) {
                        RouteThumbnail(waypoints: route.waypoints)
                            .frame(width: 72, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(routeTitle(route))
                                .scaledFont(size: 16, weight: .semibold, relativeTo: .body)
                                .foregroundColor(.primaryText)
                                .lineLimit(1)
                            Text(routeFacts(route))
                                .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                                .foregroundColor(.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if isChosen {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.aviationGold)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(isChosen ? Color.aviationGold.opacity(0.14) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isChosen ? Color.aviationGold.opacity(0.6) : Color.clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if selectedRoute != nil {
                routeLandingsList
            }
        }
    }

    // MARK: - Landing on the way (6.1, trips proposal M2)

    /// The aerodromes on or near the chosen route, in flying order, each with "Land here"; then "Land
    /// somewhere else…". It used to be a 12 pt line pointing to "Add a stop…" once the flight existed.
    private var routeLandingsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.PlanFlight.aerodromesOnRoute)
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .foregroundColor(.secondaryText)
                Spacer(minLength: 8)
                Text(L10n.PlanFlight.inFlyingOrder)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
                    .lineLimit(1)
            }
            .padding(.top, 6)
            if isLoadingRouteAerodromes {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 6)
            } else if routeLandings.candidates.isEmpty {
                Text(L10n.PlanFlight.noAerodromesOnRoute)
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    let shown = shownRouteCandidates
                    ForEach(Array(shown.enumerated()), id: \.element.aerodrome.ident) { index, candidate in
                        landHereRow(candidate)
                        if index < shown.count - 1 {
                            Divider().overlay(Color.white.opacity(0.06))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground))
                let hidden = routeLandings.candidates.count - shownRouteCandidates.count
                if hidden > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showsAllRouteAerodromes = true }
                    } label: {
                        Text(L10n.PlanFlight.moreNearRoute(hidden))
                            .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                            .foregroundColor(.altimeterBlue)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            landElsewhere
        }
    }

    /// Up to six, all of them; beyond, the ones on the route (drawn through it, or right under it) and
    /// the ones landed at, with the rest one tap away: a long route passes dozens of fields within
    /// 5 NM, and the list pushed When and Aircraft out of sight.
    private var shownRouteCandidates: [TripPlanner.StopCandidate] {
        let all = routeLandings.candidates
        guard !showsAllRouteAerodromes, all.count > 6 else { return all }
        return all.filter {
            $0.waypointIndex != nil || $0.offsetNM < TripPlanner.onRouteNM
                || routeLandings.isLanding(at: $0.aerodrome.ident)
        }
    }

    private func landHereRow(_ candidate: TripPlanner.StopCandidate) -> some View {
        let ident = candidate.aerodrome.ident
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ident)
                        .scaledFont(size: 15, weight: .bold, design: .monospaced, relativeTo: .body)
                        .foregroundColor(.primaryText)
                    if candidate.aerodrome.isPPR { PPRChip() }
                }
                // Two lines on a phone, where one cut "on route" off.
                Text("\(candidate.aerodrome.name) · \(StopPlacement.text(candidate))")
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(isOn: Binding(
                get: { routeLandings.isLanding(at: ident) },
                set: { on in
                    withAnimation(.easeInOut(duration: 0.15)) { routeLandings.setLanding(on, at: ident) }
                }
            )) {
                Text(L10n.PlanFlight.landHere)
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
            }
            .toggleStyle(.switch)
            .tint(.aviationGreen)
            .fixedSize()
            .accessibilityLabel(L10n.PlanFlight.landAt(ident))
        }
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        // The whole row is the switch's target, not just its 51 pt.
        .contentShape(Rectangle())
        .onTapGesture {
            let landing = !routeLandings.isLanding(at: ident)
            withAnimation(.easeInOut(duration: 0.15)) { routeLandings.setLanding(landing, at: ident) }
        }
    }

    /// "Land somewhere else…": any aerodrome, placed where it lengthens the route least.
    @ViewBuilder
    private var landElsewhere: some View {
        if isLandingElsewhere {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(.dimText)
                    TextField(L10n.Trip.searchAerodrome, text: $elsewhereQuery)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($elsewhereFocused)
                        .foregroundColor(.primaryText)
                    Button {
                        closeLandElsewhere()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.dimText)
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.Button.close)
                }
                .scaledFont(size: 16, relativeTo: .body)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground))
                if !elsewhereResults.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(elsewhereResults.prefix(5), id: \.aerodrome.ident) { candidate in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { routeLandings.add(candidate) }
                                closeLandElsewhere()
                            } label: {
                                HStack(spacing: 8) {
                                    Text(candidate.aerodrome.ident)
                                        .font(.aero(size: 14, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.aviationGold)
                                        .frame(width: 52, alignment: .leading)
                                    Text("\(candidate.aerodrome.name) · \(StopPlacement.text(candidate))")
                                        .scaledFont(size: 14, relativeTo: .footnote)
                                        .foregroundColor(.primaryText)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if candidate.aerodrome.ident != elsewhereResults.prefix(5).last?.aerodrome.ident {
                                Divider().overlay(Color.white.opacity(0.06))
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground))
                }
            }
            .id(Self.elsewhereAnchor)
            .onChange(of: elsewhereQuery) { _, _ in searchElsewhere() }
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isLandingElsewhere = true }
                elsewhereFocused = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                    Text(L10n.PlanFlight.landElsewhere)
                }
                .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                .foregroundColor(.altimeterBlue)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.altimeterBlue.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selectedRoute.map { $0.waypoints.count < 2 } ?? true)
        }
    }

    private func closeLandElsewhere() {
        elsewhereFocused = false
        elsewhereQuery = ""
        elsewhereResults = []
        withAnimation(.easeInOut(duration: 0.15)) { isLandingElsewhere = false }
    }

    /// Any fixed-wing landing site by code or name, nearest the route's departure first, placed along
    /// the route. One behind the departure or past the destination can't be a stop on the way.
    private func searchElsewhere() {
        let term = elsewhereQuery.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2, let route = selectedRoute, route.waypoints.count >= 2 else {
            elsewhereResults = []
            return
        }
        let found = airports.searchAirports(query: term, limit: 8, near: route.waypoints.first?.coordinate,
                                            types: AirportType.fixedWing)
            .filter(AirportDataService.isPlanningLandingSite)
            .map(airports.planningAerodrome)
        elsewhereResults = TripPlanner.stopCandidates(along: route.waypoints, aerodromes: found,
                                                      corridorNM: .greatestFiniteMagnitude)
    }

    /// The aerodromes within the corridor "Add a stop…" uses (5 NM), for the route just chosen.
    private func loadRouteAerodromes() async {
        showsAllRouteAerodromes = false
        closeLandElsewhere()
        guard let route = selectedRoute, route.waypoints.count >= 2 else {
            routeLandings = RouteLandings()
            return
        }
        isLoadingRouteAerodromes = true
        defer { isLoadingRouteAerodromes = false }
        await airports.ensureLoaded()
        guard selectedRoute?.id == route.id else { return }
        let aerodromes = airports.planningAerodromes(around: route.waypoints.map(\.coordinate), marginNM: 6)
        routeLandings = RouteLandings(candidates: TripPlanner.stopCandidates(along: route.waypoints,
                                                                             aerodromes: aerodromes))
    }

    // MARK: - When (planning proposal B1)

    private var whenSection: some View {
        // With stops, the date and time are leg 1's; the other legs leave when the one before lands.
        card(L10n.Flights.when, aside: showsLegs ? L10n.PlanFlight.leg1Departure : L10n.Flights.whenHint) {
            HStack(spacing: 10) {
                if hasDepartureTime {
                    DatePicker(
                        L10n.Flights.when,
                        selection: Binding(
                            get: { intent.departureTime ?? Self.defaultDeparture() },
                            set: { intent.departureTime = $0 }
                        ),
                        // From today on: a flight planned for a day already gone lands straight under
                        // "Date passed". Earlier today is still fine. (v6.0 review)
                        in: Calendar.current.startOfDay(for: Date())...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(.aviationGold)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { hasDepartureTime.toggle() }
                    if hasDepartureTime, intent.departureTime == nil { intent.departureTime = Self.defaultDeparture() }
                } label: {
                    Label(hasDepartureTime ? L10n.PlanFlight.noDateYet : L10n.PlanFlight.pickADate,
                          systemImage: hasDepartureTime ? "calendar.badge.minus" : "calendar.badge.plus")
                        .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundColor(hasDepartureTime ? .secondaryText : .aviationGold)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Aircraft (planning proposal B1)

    /// The pilot's aircraft as chips: one tap, and every choice in view. A menu hid them.
    private var aircraftSection: some View {
        card(L10n.Flights.aircraft) {
            if aircraft.isEmpty {
                Text(intent.aircraftRegistration.isEmpty ? "—" : intent.aircraftRegistration)
                    .scaledFont(size: 17, weight: .semibold, design: .monospaced, relativeTo: .title3)
                    .foregroundColor(.primaryText)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(aircraft) { option in
                        let isChosen = option.registration == intent.aircraftRegistration
                        Button {
                            intent.aircraftTypeId = option.aircraftType
                            intent.aircraftRegistration = option.registration
                            intent.aircraftModelName = option.modelName
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    if isChosen {
                                        Image(systemName: "checkmark")
                                            .scaledFont(size: 12, weight: .bold, relativeTo: .caption)
                                            .foregroundColor(.aviationGold)
                                    }
                                    Text(option.registration)
                                        .scaledFont(size: 16, weight: .bold, design: .monospaced, relativeTo: .body)
                                        .foregroundColor(.primaryText)
                                }
                                Text(option.modelName)
                                    .scaledFont(size: 12, relativeTo: .caption)
                                    .foregroundColor(.secondaryText)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(minWidth: 128, minHeight: 52, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(isChosen ? Color.aviationGold.opacity(0.14) : Color.clear))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(isChosen ? Color.aviationGold : Color.white.opacity(0.14), lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isChosen ? .isSelected : [])
                    }
                }
            }
        }
    }

    // MARK: - Create (planning proposal B2)

    /// What will be created, then the button: confirm what you see. While a stop can't be found, what
    /// stops it instead, and no Create. (v6.0 review)
    private var createBar: some View {
        VStack(spacing: 8) {
            if !unknownStops.isEmpty {
                Label(L10n.PlanFlight.unknownInSummary(unknownStops.joined(separator: ", ")),
                      systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundColor(.aviationAmber)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            } else {
                Text(summary)
                    .scaledFont(size: 14, relativeTo: .subheadline)
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Button {
                onCreate(PlannedFlight(stops: stops, intent: normalised(), route: selectedRoute,
                                       landings: selectedRoute == nil ? [] : routeLandings.landings))
            } label: {
                // Several stops make a trip (one flight per leg); say "trip", not "N flights", which
                // read as N separate outings. (v5.2)
                Text(legCount > 1 ? L10n.Trip.createTrip(legCount) : L10n.Flights.createFlight)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(legCount < 1 || !unknownStops.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color.panelBackground.shadow(.drop(color: .black.opacity(0.4), radius: 8, y: -2)))
    }

    /// "LSZS → LFLI · Mon 28 Sep, 10:00 · F-HVXA"; "Tour du Jura, landing at LSGE and LSGN · …"
    private var summary: String {
        var parts: [String] = []
        if let selectedRoute {
            let landings = routeLandings.landings.map(\.ident)
            parts.append(landings.isEmpty
                         ? routeTitle(selectedRoute)
                         : L10n.PlanFlight.routeLandingAt(routeTitle(selectedRoute),
                                                          ListFormatter.localizedString(byJoining: landings)))
        } else if fromSavedRoute {
            // Not the airports rows (the home field, say) while no route is chosen.
            parts.append(L10n.PlanFlight.noRouteYet)
        } else {
            let clean = stops.idents
            parts.append(clean.isEmpty ? L10n.PlanFlight.noRouteYet : clean.joined(separator: " → "))
        }
        if hasDepartureTime, let departure = intent.departureTime {
            parts.append(departure.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
        } else {
            parts.append(L10n.PlanFlight.noDateYet)
        }
        if !intent.aircraftRegistration.isEmpty { parts.append(intent.aircraftRegistration) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Routes

    private func routeLabel(_ route: FlightPlan) -> String {
        let names = route.waypoints.map(\.name).filter { !$0.isEmpty }
        if let first = names.first, let last = names.last, names.count >= 2 { return "\(first) → \(last)" }
        return route.name.isEmpty ? (names.first ?? L10n.Thread.untitledFlight) : route.name
    }

    /// The route's name when it has one of its own, else its ends: as the Routes list shows it.
    private func routeTitle(_ route: FlightPlan) -> String {
        let name = route.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? routeLabel(route) : name
    }

    private func routeFacts(_ route: FlightPlan) -> String {
        var parts = [routeLabel(route), "\(route.waypoints.count) wpt"]
        if route.totalDistance > 0 { parts.append(String(format: "%.0f NM", route.totalDistance)) }
        if route.totalEET > 0 { parts.append(route.formattedTotalEET) }
        return parts.joined(separator: " · ")
    }

    /// Picking a route fills in its two ends, so the flight reads as the route the pilot chose.
    ///
    /// The ENDS only. Every named waypoint used to land in this list, so a 26-point route showed
    /// "Create 24 flights" and "24 legs, sharing one preparation" while creating one flight — the app
    /// describing a trip it was not making. A landing on the way is the pilot's "Land here", below the
    /// route. (v5.1; 6.1)
    private func choose(_ route: FlightPlan) {
        if selectedRoute?.id != route.id { routeLandings = RouteLandings() }
        selectedRoute = route
        let idents = route.waypoints.map(\.name).filter { !$0.isEmpty }
        stops = PlannedStops(from: idents.first ?? "", to: idents.count >= 2 ? idents[idents.count - 1] : "")
        focused = nil
        suggestions = []
    }

    /// Back to Airports: the rows the sheet opened with (home, or what "Plan this again" brought).
    private func clearRoute() {
        selectedRoute = nil
        routeLandings = RouteLandings()
        stops = openingStops
    }

    /// Two aerodromes make one leg, three make two. A trip needs at least two legs.
    private var legCount: Int {
        // A saved route is ONE flight, whatever it passes through: its waypoints are not stops.
        // Counting them as legs is how a 17-waypoint route read "Create 17 flights". Each "Land here"
        // switched on adds a leg. (v5.2; 6.1)
        if fromSavedRoute { return selectedRoute == nil ? 0 : routeLandings.legCount }
        return stops.legCount
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { stops.index(of: id).map { stops.rows[$0].ident } ?? "" },
            set: { stops.setIdent($0, for: id) }
        )
    }

    // MARK: - Resolving the stops (v6.0 review)
    //
    // A stop the airport data can't find used to be dropped when the flight was built (no guessed
    // position, rightly), and nothing said so: "LSZG → GRENCHEN" became a flight with one waypoint or
    // none, no map, no nav log, and without coordinates no customs, DABS or GAFOR.

    private enum StopState: Equatable {
        case empty
        case loading
        case resolved(String)
        case unknown
    }

    private func stopState(_ typed: String) -> StopState {
        let ident = typed.trimmingCharacters(in: .whitespaces).uppercased()
        guard !ident.isEmpty else { return .empty }
        if isLoadingAirports { return .loading }
        if let airport = airports.findAirport(byIdent: ident) { return .resolved(airport.name) }
        // Without the airport data nothing can be checked: say so once, below the fields, and let
        // the flight be created (its route is drawn later), rather than block every stop.
        return airports.isDataAvailable ? .unknown : .empty
    }

    /// The stops that stop Create: typed, and not found.
    private var unknownStops: [String] {
        guard !fromSavedRoute else { return [] }
        return stops.idents.filter { stopState($0) == .unknown }
    }

    /// A name typed in full (or enough of one) that matches exactly one aerodrome, or one whose name it
    /// is, becomes that aerodrome's code.
    private func resolveTyped(_ id: UUID) {
        guard let index = stops.index(of: id), stopState(stops.rows[index].ident) == .unknown else { return }
        let typed = stops.rows[index].ident.trimmingCharacters(in: .whitespaces)
        let hits = airports.searchAirports(query: typed, limit: 5, types: AirportType.fixedWing)
        if hits.count == 1 {
            stops.setIdent(hits[0].ident, for: id)
        } else if let exact = hits.first(where: { $0.name.compare(typed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            stops.setIdent(exact.ident, for: id)
        }
    }

    /// Below the fields: no airport data to check against, or the same aerodrome twice in a row. The
    /// second says what the pilot can do: fly it as a local flight, or land somewhere on the way. It
    /// used to steer to "add a turning point", away from stops. (6.1)
    private var routeNote: String? {
        guard !fromSavedRoute else { return nil }
        if !isLoadingAirports, !airports.isDataAvailable, !stops.idents.isEmpty {
            return L10n.PlanFlight.noAirportData
        }
        return stops.repeatedIdent.map(L10n.PlanFlight.sameAerodrome)
    }

    /// Completion is by ICAO **or name**, because a pilot heading somewhere new knows "Grenchen"
    /// long before they know "LSZG". `searchAirports` already matches ident, IATA, name and
    /// municipality, and ranks exact-ident matches first, so typing a code still wins.
    private func search() {
        guard let focused, let index = stops.index(of: focused) else { suggestions = []; return }
        let typed = stops.rows[index].ident.trimmingCharacters(in: .whitespaces)
        // One or two characters match half of Europe; the list is noise until the third.
        guard typed.count >= 2 else { suggestions = []; return }
        // An exact code the pilot has already finished typing needs no menu under it: the menu would
        // only offer it again, and on a phone it pushed "Add a stop on the way" under the Create bar.
        // It closes too when the code is finished after a list opened on its first letters. (6.1)
        if typed.count == 4, airports.findAirport(byIdent: typed) != nil { suggestions = []; return }
        suggestions = airports.searchAirports(query: typed, limit: 5, types: AirportType.fixedWing)
    }

    private func accept(_ airport: Airport) {
        if let focused { stops.setIdent(airport.ident, for: focused) }
        suggestions = []
        focused = nil
    }

    // MARK: - Pieces

    private func card<Content: View>(_ title: String, aside: String? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .scaledFont(size: 13, weight: .bold, design: .monospaced, relativeTo: .caption)
                    .tracking(1.2)
                    .foregroundColor(.aviationGold)
                Spacer(minLength: 8)
                if let aside {
                    Text(aside)
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.dimText)
                        .lineLimit(1)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.panelBackground))
    }

    // MARK: - Helpers

    /// Idents are typed by hand, so they are trimmed and upper-cased once here rather than at every
    /// place that later compares them to an aerodrome.
    private func normalised() -> NewFlightIntent {
        let clean = stops.idents
        var result = intent
        result.departureIdent = clean.first ?? ""
        result.arrivalIdent = clean.count > 1 ? clean[1] : ""
        if !hasDepartureTime { result.departureTime = nil }
        return result
    }

    /// Tomorrow morning: far enough out that the T−24h reminder still has somewhere to land, and a
    /// time a pilot is more likely to edit than to accept blindly.
    static func defaultDeparture(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

// MARK: - Pieces for the legs card (6.1)

/// The legs a trip will be made of, and between two legs the stop: how long on the ground, and
/// whether to refuel. Plan new flight shows it for typed stops and for a saved route landed on the way,
/// and "Add a stop…" for the stops ticked there, so the three read (and set their stops) the same way.
struct TripLegsCard: View {
    let legs: [FlightPlan]
    /// FROM, each stop, TO: where the legs start and end, as typed or as the route names them.
    let idents: [String]
    /// The stop in front of each leg after the first: `stopovers[i]` is at `idents[i + 1]`.
    let stopovers: [Stopover]
    var aside: String? = nil
    /// "4 wpt · 52 NM · 0:31" for legs that keep a route; direct legs read "38 NM · 0:33".
    var showsWaypointCount = false
    let explainer: String
    /// A stop's time on the ground or refuel changed: the stop's index in `stopovers`, and its value.
    let onStopover: (Int, Stopover) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.Flights.legCount(legs.count).uppercased())
                    .scaledFont(size: 13, weight: .bold, design: .monospaced, relativeTo: .caption)
                    .tracking(1.2)
                    .foregroundColor(.aviationGold)
                Spacer(minLength: 8)
                if let aside {
                    Text(aside)
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.dimText)
                        .lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(legs.enumerated()), id: \.offset) { index, leg in
                    if idents.indices.contains(index + 1) {
                        legRow(leg, number: index + 1, from: idents[index], to: idents[index + 1])
                        if index < legs.count - 1, stopovers.indices.contains(index) {
                            StopoverRow(label: L10n.PlanFlight.onTheGroundAt(idents[index + 1]),
                                        stopover: stopovers[index]) { onStopover(index, $0) }
                                .padding(.vertical, 4)
                                .overlay(alignment: .top) { DashedRule() }
                                .overlay(alignment: .bottom) { DashedRule() }
                        }
                    }
                }
            }
            Label(explainer, systemImage: "info.circle")
                .scaledFont(size: 13, relativeTo: .footnote)
                .foregroundColor(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.panelBackground))
    }

    private func legRow(_ leg: FlightPlan, number: Int, from: String, to: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .scaledFont(size: 12, weight: .bold, design: .monospaced, relativeTo: .caption)
                .foregroundColor(.primaryText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.12)))
            Text("\(from) → \(to)")
                .scaledFont(size: 16, weight: .bold, design: .monospaced, relativeTo: .body)
                .foregroundColor(.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(facts(leg))
                if let departure = departure(leg) {
                    Text(departure)
                }
            }
            .scaledFont(size: 12.5, design: .monospaced, relativeTo: .caption)
            .foregroundColor(.secondaryText)
            .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// "38 NM · 0:33" (or "4 wpt · 52 NM · 0:31"), or a dash while an end can't be placed.
    private func facts(_ leg: FlightPlan) -> String {
        guard leg.waypoints.count >= 2 else { return "—" }
        var parts: [String] = []
        if showsWaypointCount { parts.append("\(leg.waypoints.count) wpt") }
        parts.append(String(format: "%.0f NM", leg.totalDistance))
        parts.append(leg.formattedTotalEET)
        return parts.joined(separator: " · ")
    }

    /// A chosen time as it is; an estimate (the leg before lands, plus the time on the ground) marked
    /// as one, the first leg's too when the flight split is itself a later leg of a trip.
    private func departure(_ leg: FlightPlan) -> String? {
        guard let departure = leg.plannedDepartureTime else { return nil }
        let time = departure.formatted(date: .omitted, time: .shortened)
        return leg.departureIsEstimate == true ? "≈ " + time : time
    }

    /// The ends of `legs` in order, as their routes name them.
    static func idents(of legs: [FlightPlan]) -> [String] {
        guard let first = legs.first?.waypoints.first?.name else { return [] }
        return [first] + legs.map { $0.waypoints.last?.name ?? "" }
    }

    /// "80 NM direct · 1:18 flying" (or without "direct", for legs that keep a route), once every leg
    /// can be measured.
    static func total(_ legs: [FlightPlan], direct: Bool) -> String? {
        guard !legs.isEmpty, legs.allSatisfy({ $0.waypoints.count >= 2 }) else { return nil }
        let distance = String(format: "%.0f NM", legs.map(\.totalDistance).reduce(0, +))
        let seconds = legs.map(\.totalEET).reduce(0, +).safeInt(or: 0)
        let eet = String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60)
        return direct ? L10n.PlanFlight.legsTotal(distance, eet) : L10n.PlanFlight.legsTotalRoute(distance, eet)
    }
}

/// A stop between two legs: "On the ground at LSGE  − 30 min +  ☐ Refuel". On one line where it fits
/// (iPad), two on a phone. The legs card and a leg's page use the same row. (6.1)
struct StopoverRow: View {
    let label: String
    let stopover: Stopover
    /// Nil shows the stop without controls: a leg that has flown keeps what it was planned with.
    let onChange: ((Stopover) -> Void)?
    var indent: CGFloat = 34
    /// Behind the stepper: a shade apart from the card the row sits on.
    var stepperFill: Color = .cardBackground

    init(label: String, stopover: Stopover, indent: CGFloat = 34, stepperFill: Color = .cardBackground,
         onChange: ((Stopover) -> Void)?) {
        self.label = label
        self.stopover = stopover
        self.indent = indent
        self.stepperFill = stepperFill
        self.onChange = onChange
    }

    var body: some View {
        if onChange == nil {
            Text(readOnly)
                .scaledFont(size: 13, relativeTo: .footnote)
                .foregroundColor(.secondaryText)
                .padding(.leading, indent)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    labelText
                        .padding(.leading, indent)
                    Spacer(minLength: 8)
                    stepper
                    refuelToggle
                }
                VStack(alignment: .leading, spacing: 2) {
                    labelText
                    HStack(spacing: 14) {
                        stepper
                        refuelToggle
                        Spacer(minLength: 0)
                    }
                }
                .padding(.leading, indent)
            }
        }
    }

    /// "On the ground at LSGE: 30 min · refuel"
    private var readOnly: String {
        var text = label + ": " + L10n.PlanFlight.groundMinutes(stopover.groundMinutes)
        if stopover.refuel { text += " · " + L10n.PlanFlight.refuel.lowercased() }
        return text
    }

    private var labelText: some View {
        Text(label)
            .scaledFont(size: 13, relativeTo: .footnote)
            .foregroundColor(.secondaryText)
            .lineLimit(1)
    }

    /// − 30 min +, 0 to 12 hours in quarter hours, like "Add a stop…" always had.
    private var stepper: some View {
        let minutes = stopover.groundMinutes
        return HStack(spacing: 0) {
            stepButton("minus", enabled: minutes > 0) { setGroundMinutes(minutes - 15) }
            Text(L10n.PlanFlight.groundMinutes(minutes))
                .scaledFont(size: 13, weight: .semibold, design: .monospaced, relativeTo: .footnote)
                .foregroundColor(.primaryText)
                .lineLimit(1)
                .frame(minWidth: 56)
            stepButton("plus", enabled: minutes < 720) { setGroundMinutes(minutes + 15) }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(stepperFill).padding(.vertical, 4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(L10n.PlanFlight.groundMinutes(minutes))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setGroundMinutes(minutes + 15)
            case .decrement: setGroundMinutes(minutes - 15)
            @unknown default: break
            }
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 13, weight: .bold, relativeTo: .footnote)
                .foregroundColor(enabled ? .aviationGold : .dimText.opacity(0.5))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func setGroundMinutes(_ minutes: Int) {
        var updated = stopover
        updated.groundMinutes = min(720, max(0, minutes))
        onChange?(updated)
    }

    private var refuelToggle: some View {
        Toggle(isOn: Binding(
            get: { stopover.refuel },
            set: { refuel in
                var updated = stopover
                updated.refuel = refuel
                onChange?(updated)
            }
        )) {
            Text(L10n.PlanFlight.refuel)
        }
        .toggleStyle(CheckboxToggleStyle())
    }
}

/// A tick box: the stop's refuel. A switch per stop row was too much furniture for a yes/no that is
/// mostly no. VoiceOver reads it as the toggle it is.
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .scaledFont(size: 18, relativeTo: .body)
                    .foregroundColor(configuration.isOn ? .aviationGold : .dimText)
                configuration.label
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// The amber PPR tag beside an aerodrome that asks for prior permission.
struct PPRChip: View {
    var body: some View {
        Text("PPR")
            .font(.aero(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundColor(.aviationAmber)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.aviationAmber, lineWidth: 1))
    }
}

/// Where an aerodrome sits against a route: "on route", or "3.1 NM off".
enum StopPlacement {
    static func text(_ candidate: TripPlanner.StopCandidate) -> String {
        candidate.waypointIndex != nil || candidate.offsetNM < TripPlanner.onRouteNM
            ? L10n.Trip.onRoute
            : L10n.Trip.offRoute(String(format: "%.1f", candidate.offsetNM))
    }
}

/// A dashed line across the top or bottom of a stop row.
private struct DashedRule: View {
    var body: some View {
        HorizontalRule()
            .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
    }
}

/// A line across the middle of its frame, for a dashed rule.
private struct HorizontalRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
