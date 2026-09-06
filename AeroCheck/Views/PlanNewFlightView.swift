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
    private let onCreate: (NewFlightIntent) -> Void
    private let onCancel: () -> Void

    /// The airport layer, for completing what the pilot types. Injected so this view stays testable
    /// and so the caller decides whether the data is loaded.
    @EnvironmentObject private var airports: AirportDataService
    @State private var suggestions: [Airport] = []
    @State private var isLoadingAirports = false

    @FocusState private var focused: Field?
    private enum Field { case from, to }

    init(intent: NewFlightIntent,
         aircraft: [AircraftOption],
         onCreate: @escaping (NewFlightIntent) -> Void,
         onCancel: @escaping () -> Void) {
        _intent = State(initialValue: intent)
        _hasDepartureTime = State(initialValue: intent.departureTime != nil)
        self.aircraft = aircraft
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    whenSection
                    aircraftSection
                    routeSection
                    createButton
                }
                .padding()
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
            HStack(spacing: 10) {
                identField(L10n.Flights.from, text: $intent.departureIdent, field: .from)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.dimText)
                identField(L10n.Flights.to, text: $intent.arrivalIdent, field: .to)
            }

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
            }

            // The route is genuinely optional — this is the whole point of planning a flight before
            // you have drawn one.
            Text(L10n.Flights.routeOptional)
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
        .onChange(of: intent.departureIdent) { _, _ in if focused == .from { search() } }
        .onChange(of: intent.arrivalIdent) { _, _ in if focused == .to { search() } }
        .onChange(of: focused) { _, _ in search() }
    }

    /// Completion is by ICAO **or name**, because a pilot heading somewhere new knows "Grenchen"
    /// long before they know "LSZG". `searchAirports` already matches ident, IATA, name and
    /// municipality, and ranks exact-ident matches first, so typing a code still wins.
    private func search() {
        guard let focused else { suggestions = []; return }
        let typed = (focused == .from ? intent.departureIdent : intent.arrivalIdent)
            .trimmingCharacters(in: .whitespaces)
        // One or two characters match half of Europe; the list is noise until the third.
        guard typed.count >= 2 else { suggestions = []; return }
        // An exact code the pilot has already finished typing needs no menu under it.
        if typed.count == 4, airports.findAirport(byIdent: typed) != nil, suggestions.isEmpty { return }
        suggestions = airports.searchAirports(query: typed, limit: 5, types: AirportType.fixedWing)
    }

    private func accept(_ airport: Airport) {
        if focused == .from { intent.departureIdent = airport.ident }
        else { intent.arrivalIdent = airport.ident }
        suggestions = []
        focused = nil
    }

    private var createButton: some View {
        Button {
            onCreate(normalised())
        } label: {
            Text(L10n.Flights.createFlight)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!intent.isCreatable)
        .padding(.top, 4)
    }

    // MARK: - Pieces

    private func identField(_ label: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .scaledFont(size: 11, relativeTo: .caption2)
                .foregroundColor(.dimText)
            TextField(L10n.Flights.identPlaceholder, text: text)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundColor(.primaryText)
                .focused($focused, equals: field)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardBackground))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
        var result = intent
        result.departureIdent = intent.departureIdent.trimmingCharacters(in: .whitespaces).uppercased()
        result.arrivalIdent = intent.arrivalIdent.trimmingCharacters(in: .whitespaces).uppercased()
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
