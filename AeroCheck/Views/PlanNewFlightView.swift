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

struct PlanNewFlightView: View {

    /// Pre-filled for "Plan this again"; near-empty for a flight planned from scratch.
    @State private var intent: NewFlightIntent
    @State private var hasDepartureTime: Bool

    private let aircraft: [AircraftOption]
    /// The pilot's routes, offered as a starting point (not the plans flights made for themselves,
    /// nor archived ones: `RouteLibrary.activeRoutes`). (v5.x; review #4)
    private let savedRoutes: [FlightPlan]
    /// The first argument is what was typed: FROM, the stops with their time on the ground and
    /// refuel, and TO. The third is the saved route this flight was built from, when there was one —
    /// the creator copies it wholesale rather than rebuilding from the two end idents.
    private let onCreate: (PlannedStops, NewFlightIntent, FlightPlan?) -> Void
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

    init(intent: NewFlightIntent,
         aircraft: [AircraftOption],
         savedRoutes: [FlightPlan] = [],
         onCreate: @escaping (PlannedStops, NewFlightIntent, FlightPlan?) -> Void,
         onCancel: @escaping () -> Void) {
        var seeded = intent
        // Already set, to tomorrow at 10:00: a date is what the preparation reminder counts back
        // from, and a default a pilot edits beats a switch they have to find. "No date yet" stays
        // one tap away. (planning proposal B1)
        if seeded.departureTime == nil { seeded.departureTime = Self.defaultDeparture() }
        _intent = State(initialValue: seeded)
        _stops = State(initialValue: PlannedStops(from: intent.departureIdent, to: intent.arrivalIdent))
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

    // MARK: - Legs (6.1, trips proposal M1)

    private var showsLegs: Bool { !fromSavedRoute && stops.legCount >= 2 }

    /// The legs Create will make, built as the creator builds them, so the times here are the times
    /// the legs get. Direct, as they are created: the pilot draws each route later.
    private var previewLegs: [FlightPlan] {
        TripPlanner.typedLegs(idents: stops.idents, stopovers: stops.stopovers, template: normalised()) {
            FlightCreator.place($0, in: airports)
        }
    }

    /// One row per leg, and between two legs the stop: how long on the ground, and whether to refuel.
    /// This is where a typed trip's stops are set; they used to be a fixed 30 minutes without fuel,
    /// with nowhere to change them.
    private var legsSection: some View {
        let legs = previewLegs
        let filled = stops.filledRows
        return card(L10n.Flights.legCount(legs.count), aside: legsTotal(legs)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(legs.enumerated()), id: \.offset) { index, leg in
                    if filled.indices.contains(index + 1) {
                        legRow(leg, number: index + 1,
                               from: filled[index].normalisedIdent, to: filled[index + 1].normalisedIdent)
                        if index < legs.count - 1 { groundRow(filled[index + 1]) }
                    }
                }
            }
            Label(L10n.PlanFlight.legsExplainer, systemImage: "info.circle")
                .scaledFont(size: 13, relativeTo: .footnote)
                .foregroundColor(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                Text(legFacts(leg))
                if let departure = legDeparture(leg, isFirst: number == 1) {
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

    /// "38 NM · 0:33", or a dash while an end can't be placed.
    private func legFacts(_ leg: FlightPlan) -> String {
        guard leg.waypoints.count >= 2 else { return "—" }
        return String(format: "%.0f NM", leg.totalDistance) + " · " + leg.formattedTotalEET
    }

    /// Leg 1 leaves at the time chosen below; the others when the one before lands, plus the time on
    /// the ground: an estimate, and marked as one.
    private func legDeparture(_ leg: FlightPlan, isFirst: Bool) -> String? {
        guard let departure = leg.plannedDepartureTime else { return nil }
        let time = departure.formatted(date: .omitted, time: .shortened)
        return isFirst ? time : "≈ " + time
    }

    /// "80 NM direct · 1:18 flying", once every leg can be measured.
    private func legsTotal(_ legs: [FlightPlan]) -> String? {
        guard !legs.isEmpty, legs.allSatisfy({ $0.waypoints.count >= 2 }) else { return nil }
        let distance = legs.map(\.totalDistance).reduce(0, +)
        let seconds = legs.map(\.totalEET).reduce(0, +).safeInt(or: 0)
        return L10n.PlanFlight.legsTotal(String(format: "%.0f NM", distance),
                                         String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60))
    }

    private func groundRow(_ stop: PlannedStops.Row) -> some View {
        // One line where it fits (iPad), two on a phone.
        SeparateView { ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                groundLabel(stop)
                    .padding(.leading, 34)
                Spacer(minLength: 8)
                groundStepper(stop)
                refuelToggle(stop)
            }
            VStack(alignment: .leading, spacing: 2) {
                groundLabel(stop)
                HStack(spacing: 14) {
                    groundStepper(stop)
                    refuelToggle(stop)
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, 34)
        } }
        .padding(.vertical, 4)
        .overlay(alignment: .top) { dashedRule }
        .overlay(alignment: .bottom) { dashedRule }
    }

    private func groundLabel(_ stop: PlannedStops.Row) -> some View {
        Text(L10n.PlanFlight.onTheGroundAt(stop.normalisedIdent))
            .scaledFont(size: 13, relativeTo: .footnote)
            .foregroundColor(.secondaryText)
            .lineLimit(1)
    }

    /// − 30 min +, 0 to 12 hours in quarter hours, like "Add a stop…".
    private func groundStepper(_ stop: PlannedStops.Row) -> some View {
        let minutes = stop.stopover.groundMinutes
        return HStack(spacing: 0) {
            stepButton("minus", enabled: minutes > 0) { setGroundMinutes(minutes - 15, for: stop) }
            Text(L10n.PlanFlight.groundMinutes(minutes))
                .scaledFont(size: 13, weight: .semibold, design: .monospaced, relativeTo: .footnote)
                .foregroundColor(.primaryText)
                .lineLimit(1)
                .frame(minWidth: 56)
            stepButton("plus", enabled: minutes < 720) { setGroundMinutes(minutes + 15, for: stop) }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.cardBackground).padding(.vertical, 4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.PlanFlight.onTheGroundAt(stop.normalisedIdent))
        .accessibilityValue(L10n.PlanFlight.groundMinutes(minutes))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setGroundMinutes(minutes + 15, for: stop)
            case .decrement: setGroundMinutes(minutes - 15, for: stop)
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

    private func setGroundMinutes(_ minutes: Int, for stop: PlannedStops.Row) {
        var stopover = stop.stopover
        stopover.groundMinutes = min(720, max(0, minutes))
        stops.setStopover(stopover, for: stop.id)
    }

    private func refuelToggle(_ stop: PlannedStops.Row) -> some View {
        Toggle(isOn: Binding(
            get: { stop.stopover.refuel },
            set: { refuel in
                var stopover = stop.stopover
                stopover.refuel = refuel
                stops.setStopover(stopover, for: stop.id)
            }
        )) {
            Text(L10n.PlanFlight.refuel)
        }
        .toggleStyle(CheckboxToggleStyle())
    }

    private var dashedRule: some View {
        HorizontalRule()
            .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
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
                // A saved route makes one flight; its stops are added from the flight. (v5.1)
                Text(L10n.Trip.routeStopsHint)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                onCreate(stops, normalised(), selectedRoute)
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

    /// "LSZS → LFLI · Mon 28 Sep, 10:00 · F-HVXA"
    private var summary: String {
        var parts: [String] = []
        if let selectedRoute {
            parts.append(routeTitle(selectedRoute))
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
    /// describing a trip it was not making. Stops on a route are added to the flight, where the rest
    /// of the route is known. (v5.1)
    private func choose(_ route: FlightPlan) {
        selectedRoute = route
        let idents = route.waypoints.map(\.name).filter { !$0.isEmpty }
        stops = PlannedStops(from: idents.first ?? "", to: idents.count >= 2 ? idents[idents.count - 1] : "")
        focused = nil
        suggestions = []
    }

    private func clearRoute() {
        selectedRoute = nil
        stops = PlannedStops()
    }

    /// Two aerodromes make one leg, three make two. A trip needs at least two legs.
    private var legCount: Int {
        // A saved route is ONE flight, whatever it passes through: its waypoints are not stops.
        // Counting them as legs is how a 17-waypoint route read "Create 17 flights". (v5.2)
        if fromSavedRoute { return selectedRoute == nil ? 0 : 1 }
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

/// A tick box: the stop's refuel. A switch per stop row was too much furniture for a yes/no that is
/// mostly no. VoiceOver reads it as the toggle it is.
private struct CheckboxToggleStyle: ToggleStyle {
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

/// A line across the middle of its frame, for a dashed rule.
private struct HorizontalRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
