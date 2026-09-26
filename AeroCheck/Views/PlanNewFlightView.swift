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

struct PlanNewFlightView: View {

    /// Pre-filled for "Plan this again"; near-empty for a flight planned from scratch.
    @State private var intent: NewFlightIntent
    @State private var hasDepartureTime: Bool

    private let aircraft: [AircraftOption]
    /// The pilot's routes, offered as a starting point (not the plans flights made for themselves,
    /// nor archived ones: `RouteLibrary.activeRoutes`). (v5.x; review #4)
    private let savedRoutes: [FlightPlan]
    /// The third argument is the saved route this flight was built from, when there was one — the
    /// creator copies it wholesale rather than rebuilding from the two end idents.
    private let onCreate: ([String], NewFlightIntent, FlightPlan?) -> Void
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
    @State private var isLoadingAirports = false

    /// Aerodromes in order. Two is a flight; three or more is a trip, and the button says so.
    @State private var stops: [String]

    @FocusState private var focused: Int?

    init(intent: NewFlightIntent,
         aircraft: [AircraftOption],
         savedRoutes: [FlightPlan] = [],
         onCreate: @escaping ([String], NewFlightIntent, FlightPlan?) -> Void,
         onCancel: @escaping () -> Void) {
        var seeded = intent
        // Already set, to tomorrow at 10:00: a date is what the preparation reminder counts back
        // from, and a default a pilot edits beats a switch they have to find. "No date yet" stays
        // one tap away. (planning proposal B1)
        if seeded.departureTime == nil { seeded.departureTime = Self.defaultDeparture() }
        _intent = State(initialValue: seeded)
        _stops = State(initialValue: [intent.departureIdent, intent.arrivalIdent])
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
                    VStack(spacing: 14) {
                        routeSection
                        whenSection
                        aircraftSection
                    }
                    .padding(16)
                    // The suggestions render under the field they belong to, which is right — a
                    // floating overlay over a form is worse to aim at. But the keyboard takes the
                    // bottom half of the sheet, and that is exactly where the list appeared. Scroll
                    // it into view whenever it changes, so it is never behind the keys.
                    .onChange(of: suggestions.map(\.ident)) { _, idents in
                        guard !idents.isEmpty else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.suggestionsAnchor, anchor: .bottom)
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

    private var airportFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(stops.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.aero(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.aviationGold)
                        .frame(width: 18, alignment: .leading)
                    HStack(spacing: 10) {
                        TextField(L10n.Flights.identPlaceholder, text: binding(for: index))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.aero(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.primaryText)
                            .focused($focused, equals: index)
                        // The aerodrome's name once its code is typed: the check that LSZS is Samedan.
                        if let name = aerodromeName(stops[index]) {
                            Text(name)
                                .scaledFont(size: 14, relativeTo: .subheadline)
                                .foregroundColor(.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground))
                    // The first two stops are the flight itself and cannot be removed; anything
                    // beyond them is a stop the pilot added and can take away again.
                    if stops.count > 2 {
                        Button {
                            stops.remove(at: index)
                            focused = nil
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.dimText)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if focused != nil, !suggestions.isEmpty {
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
                            .frame(minHeight: 40)
                        }
                        .buttonStyle(.plain)
                        if airport.ident != suggestions.prefix(5).last?.ident {
                            Divider().overlay(Color.white.opacity(0.06))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground))
                .padding(.leading, 28)
                .id(Self.suggestionsAnchor)
            }

            HStack {
                Button {
                    stops.append("")
                    focused = stops.count - 1
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                        Text(L10n.Flights.addStop)
                    }
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundColor(.altimeterBlue)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                Text(legCount > 1 ? L10n.Flights.legsExplainer(stops.count, legCount)
                                  : L10n.PlanFlight.drawLater)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 28)
        }
        .onChange(of: stops) { _, _ in search() }
        .onChange(of: focused) { _, _ in search() }
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
        card(L10n.Flights.when, aside: L10n.Flights.whenHint) {
            HStack(spacing: 10) {
                if hasDepartureTime {
                    DatePicker(
                        L10n.Flights.when,
                        selection: Binding(
                            get: { intent.departureTime ?? Self.defaultDeparture() },
                            set: { intent.departureTime = $0 }
                        ),
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

    /// What will be created, then the button: confirm what you see.
    private var createBar: some View {
        VStack(spacing: 8) {
            Text(summary)
                .scaledFont(size: 14, relativeTo: .subheadline)
                .foregroundColor(.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Button {
                onCreate(normalisedStops(), normalised(), selectedRoute)
            } label: {
                // Several stops make a trip (one flight per leg); say "trip", not "N flights", which
                // read as N separate outings. (v5.2)
                Text(legCount > 1 ? L10n.Trip.createTrip(legCount) : L10n.Flights.createFlight)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(legCount < 1)
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
            let clean = normalisedStops()
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
        stops = idents.count >= 2 ? [idents[0], idents[idents.count - 1]] : (idents + ["", ""]).prefix(2).map { $0 }
        focused = nil
        suggestions = []
    }

    private func clearRoute() {
        selectedRoute = nil
        stops = ["", ""]
    }

    /// Two aerodromes make one leg, three make two. A trip needs at least two legs.
    private var legCount: Int {
        // A saved route is ONE flight, whatever it passes through: its waypoints are not stops.
        // Counting them as legs is how a 17-waypoint route read "Create 17 flights". (v5.2)
        if fromSavedRoute { return selectedRoute == nil ? 0 : 1 }
        return max(0, stops.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count - 1)
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { index < stops.count ? stops[index] : "" },
            set: { if index < stops.count { stops[index] = $0 } }
        )
    }

    /// The aerodrome's name, once a 4-letter code the database knows is typed.
    private func aerodromeName(_ typed: String) -> String? {
        let ident = typed.trimmingCharacters(in: .whitespaces).uppercased()
        guard ident.count == 4 else { return nil }
        return airports.findAirport(byIdent: ident)?.name
    }

    /// Completion is by ICAO **or name**, because a pilot heading somewhere new knows "Grenchen"
    /// long before they know "LSZG". `searchAirports` already matches ident, IATA, name and
    /// municipality, and ranks exact-ident matches first, so typing a code still wins.
    private func search() {
        guard let focused, focused < stops.count else { suggestions = []; return }
        let typed = stops[focused].trimmingCharacters(in: .whitespaces)
        // One or two characters match half of Europe; the list is noise until the third.
        guard typed.count >= 2 else { suggestions = []; return }
        // An exact code the pilot has already finished typing needs no menu under it.
        if typed.count == 4, airports.findAirport(byIdent: typed) != nil, suggestions.isEmpty { return }
        suggestions = airports.searchAirports(query: typed, limit: 5, types: AirportType.fixedWing)
    }

    private func accept(_ airport: Airport) {
        if let focused, focused < stops.count { stops[focused] = airport.ident }
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
        let clean = normalisedStops()
        var result = intent
        result.departureIdent = clean.first ?? ""
        result.arrivalIdent = clean.count > 1 ? clean[1] : ""
        if !hasDepartureTime { result.departureTime = nil }
        return result
    }

    /// Idents are typed by hand, so they are trimmed and upper-cased once here rather than at every
    /// place that later compares them to an aerodrome. Blank rows are dropped: an empty stop the
    /// pilot added and did not fill in should not become a leg to nowhere.
    private func normalisedStops() -> [String] {
        stops.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
    }

    /// Tomorrow morning: far enough out that the T−24h reminder still has somewhere to land, and a
    /// time a pilot is more likely to edit than to accept blindly.
    static func defaultDeparture(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}
