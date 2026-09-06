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
                    kindSection
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

    /// Kind comes first because it changes what the rest of the sheet asks for: circuits need one
    /// aerodrome, not two.
    private var kindSection: some View {
        card(L10n.Flights.kind) {
            Picker(L10n.Flights.kind, selection: $intent.kind) {
                Text(L10n.Flights.crossCountry).tag(FlightKind.crossCountry)
                Text(L10n.Flights.circuits).tag(FlightKind.circuits)
            }
            .pickerStyle(.segmented)
        }
    }

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
        card(intent.kind == .circuits ? L10n.Flights.aerodrome : L10n.Flights.fromTo) {
            HStack(spacing: 10) {
                identField(L10n.Flights.from, text: $intent.departureIdent, field: .from)
                if intent.kind != .circuits {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.dimText)
                    identField(L10n.Flights.to, text: $intent.arrivalIdent, field: .to)
                }
            }
            // The route is genuinely optional — this is the whole point of planning a flight before
            // you have drawn one.
            Text(intent.kind == .circuits ? L10n.Flights.circuitsHint : L10n.Flights.routeOptional)
                .scaledFont(size: 12, relativeTo: .caption)
                .foregroundColor(.dimText)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            TextField("ICAO", text: text)
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
