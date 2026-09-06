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

struct PlanNewFlightView: View {

    /// Pre-filled for "Plan this again"; near-empty for a flight planned from scratch.
    @State private var intent: NewFlightIntent
    @State private var hasDepartureTime: Bool

    private let aircraft: [AircraftOption]
    private let onCreate: ([String], NewFlightIntent) -> Void
    private let onCancel: () -> Void

    /// The airport layer, for completing what the pilot types. Injected so this view stays testable
    /// and so the caller decides whether the data is loaded.
    @EnvironmentObject private var airports: AirportDataService
    @State private var suggestions: [Airport] = []
    /// Scroll target for the completion list, so the keyboard never covers it.
    private static let suggestionsAnchor = "aerocheck.plan.suggestions"
    @State private var isLoadingAirports = false

    /// Aerodromes in order. Two is a flight; three or more is a trip, and the button says so.
    @State private var stops: [String]

    @FocusState private var focused: Int?

    init(intent: NewFlightIntent,
         aircraft: [AircraftOption],
         onCreate: @escaping ([String], NewFlightIntent) -> Void,
         onCancel: @escaping () -> Void) {
        _intent = State(initialValue: intent)
        _stops = State(initialValue: [intent.departureIdent, intent.arrivalIdent])
        _hasDepartureTime = State(initialValue: intent.departureTime != nil)
        self.aircraft = aircraft
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ScrollViewReader { proxy in
                    VStack(spacing: 16) {
                        whenSection
                        aircraftSection
                        routeSection
                        createButton
                    }
                    .padding()
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
            .navigationTitle(L10n.Flights.planNewFlight)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { onCancel() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var whenSection: some View {
        card(L10n.Flights.when) {
            Toggle(isOn: $hasDepartureTime.animation(.easeInOut(duration: 0.2))) {
                Text(L10n.Flights.knowWhen)
                    .scaledFont(size: 15, relativeTo: .body)
                    .foregroundColor(.primaryText)
            }
            .tint(.aviationGold)

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
                // The T−24h preparation reminder only exists once there is a departure to count back
                // from, so it is worth saying why this toggle matters.
                Text(L10n.Flights.whenHint)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
            }
        }
        .onChange(of: hasDepartureTime) { _, on in
            intent.departureTime = on ? (intent.departureTime ?? Self.defaultDeparture()) : nil
        }
    }

    private var aircraftSection: some View {
        card(L10n.Flights.aircraft) {
            if aircraft.isEmpty {
                Text(intent.aircraftRegistration.isEmpty ? "—" : intent.aircraftRegistration)
                    .scaledFont(size: 17, weight: .semibold, relativeTo: .title3)
                    .foregroundColor(.primaryText)
            } else {
                Menu {
                    ForEach(aircraft) { option in
                        Button {
                            intent.aircraftTypeId = option.aircraftType
                            intent.aircraftRegistration = option.registration
                            intent.aircraftModelName = option.modelName
                        } label: {
                            Text("\(option.registration) · \(option.modelName)")
                        }
                    }
                } label: {
                    HStack {
                        Text(intent.aircraftRegistration.isEmpty ? "—" : intent.aircraftRegistration)
                            .scaledFont(size: 17, weight: .semibold, relativeTo: .title3)
                            .foregroundColor(.primaryText)
                        if !intent.aircraftModelName.isEmpty {
                            Text(intent.aircraftModelName)
                                .scaledFont(size: 12, relativeTo: .caption)
                                .foregroundColor(.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12))
                            .foregroundColor(.dimText)
                    }
                }
            }
        }
    }

    private var routeSection: some View {
        card(L10n.Flights.fromTo) {
            ForEach(Array(stops.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.aviationGold)
                        .frame(width: 14, alignment: .leading)
                    TextField(L10n.Flights.identPlaceholder, text: binding(for: index))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primaryText)
                        .focused($focused, equals: index)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardBackground))
                    // The first two stops are the flight itself and cannot be removed; anything
                    // beyond them is a stop the pilot added and can take away again.
                    if stops.count > 2 {
                        Button {
                            stops.remove(at: index)
                            focused = nil
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.dimText)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                stops.append("")
                focused = stops.count - 1
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                    Text(L10n.Flights.addStop)
                }
                .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                .foregroundColor(.aviationGold)
            }
            .buttonStyle(.plain)

            if focused != nil, !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions.prefix(5), id: \.ident) { airport in
                        Button { accept(airport) } label: {
                            HStack(spacing: 8) {
                                Text(airport.ident)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.aviationGold)
                                    .frame(width: 46, alignment: .leading)
                                Text(airport.name)
                                    .scaledFont(size: 13, relativeTo: .footnote)
                                    .foregroundColor(.primaryText)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        if airport.ident != suggestions.prefix(5).last?.ident {
                            Divider().overlay(Color.white.opacity(0.06))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardBackground))
                .id(Self.suggestionsAnchor)
            }

            Text(legCount > 1 ? L10n.Flights.legsExplainer(stops.count, legCount)
                              : L10n.Flights.routeOptional)
                .scaledFont(size: 12, relativeTo: .caption)
                .foregroundColor(.dimText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            // Loaded on demand, so completion works even on a cold start — without this the field
            // silently offers nothing and the pilot concludes the aerodrome is unknown.
            isLoadingAirports = true
            await airports.ensureLoaded()
            isLoadingAirports = false
            search()
        }
        .onChange(of: stops) { _, _ in search() }
        .onChange(of: focused) { _, _ in search() }
    }

    /// Two aerodromes make one leg, three make two. A trip needs at least two legs.
    private var legCount: Int {
        max(0, stops.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count - 1)
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { index < stops.count ? stops[index] : "" },
            set: { if index < stops.count { stops[index] = $0 } }
        )
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

    private var createButton: some View {
        Button {
            onCreate(normalisedStops(), normalised())
        } label: {
            Text(legCount > 1 ? L10n.Flights.createFlights(legCount) : L10n.Flights.createFlight)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(legCount < 1)
        .padding(.top, 4)
    }

    // MARK: - Pieces

    private func card<Content: View>(_ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                .tracking(0.8)
                .foregroundColor(.secondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.panelBackground))
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
