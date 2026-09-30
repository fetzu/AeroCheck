import SwiftUI
import CoreLocation

// MARK: - Add a stop (v5.1; several at once since 6.1)

/// Add stops to a flight that has not flown: tick the aerodromes to land at, say how long the aircraft
/// stays at each and whether it refuels, and the flight becomes one leg per stretch between them, in
/// one pass. A second stop used to mean opening the new leg and adding it there.
///
/// A ground screen, so it can afford detail: every aerodrome within 5 NM of the route in the order it
/// is reached, with its distance and time from departure, its contact frequency and a PPR chip. A
/// field further away is one search away. A local flight (one aerodrome, out and back) has no route
/// to follow: it lists the aerodromes around its field, nearest first, and flies out to the ones
/// ticked, in the order ticked, and back. (6.1)
struct AddStopSheet: View {
    let threadId: UUID
    /// Called with the first new leg's thread id, or nil when the pilot cancelled.
    let onDone: (UUID?) -> Void

    @EnvironmentObject var threadManager: FlightThreadManager
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var airportDataService: AirportDataService

    @State private var candidates: [TripPlanner.StopCandidate] = []
    @State private var searchResults: [TripPlanner.StopCandidate] = []
    @State private var query = ""
    /// The stops ticked, each with its time on the ground and refuel, in the order ticked: a local
    /// flight lands in that order; a route, in its own.
    @State private var ticked: [TripPlanner.Landing] = []
    @State private var isLoading = true

    private var plan: FlightPlan? {
        guard let planId = threadManager.thread(withId: threadId)?.flightPlanId else { return nil }
        return flightPlanManager.flightPlans.first { $0.id == planId }
    }

    /// One aerodrome, out and back: no route to stop along, so the stops are the fields around it.
    private var isLocal: Bool { plan?.waypoints.count == 1 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.AddStops.explainer)
                        .scaledFont(size: 13, relativeTo: .footnote)
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    searchField
                    if !searchResults.isEmpty {
                        list(searchResults)
                    }
                    candidatesSection
                    if !ticked.isEmpty { SeparateView { legsCard } }
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.cockpitBackground)
            // Split, always in reach, with the legs it will make: it sat below a long list. (6.1)
            .safeAreaInset(edge: .bottom, spacing: 0) { splitBar }
            .navigationTitle(L10n.Trip.addStopTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { onDone(nil) }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .onChange(of: query) { _, _ in search() }
    }

    // MARK: - Sections

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.dimText)
            TextField(L10n.Trip.searchAerodrome, text: $query)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .foregroundColor(.primaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
    }

    @ViewBuilder
    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hint)
                .scaledFont(size: 12, relativeTo: .caption)
                .foregroundColor(.dimText)
                .fixedSize(horizontal: false, vertical: true)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if listed.isEmpty {
                Text(isLocal ? L10n.AddStops.noLocalCandidates(Int(TripPlanner.localStopRadiusNM)) : L10n.Trip.noCandidates)
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.secondaryText)
                    .padding(.vertical, 8)
            } else {
                list(listed)
            }
        }
    }

    private var hint: String {
        guard isLocal else { return L10n.Trip.addStopHint }
        return L10n.AddStops.localHint(Int(TripPlanner.localStopRadiusNM), plan?.waypoints.first?.name ?? "")
    }

    /// The list, and any aerodrome ticked from the search, in their place: along the route, or by
    /// distance from a local flight's field.
    private var listed: [TripPlanner.StopCandidate] {
        let extra = ticked.map(\.candidate).filter { stop in
            !candidates.contains { $0.aerodrome.ident == stop.aerodrome.ident }
        }
        return (candidates + extra).sorted { $0.alongNM < $1.alongNM }
    }

    private func list(_ items: [TripPlanner.StopCandidate]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.aerodrome.ident) { index, candidate in
                row(candidate)
                if index < items.count - 1 {
                    Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 44)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
    }

    /// A tick box that shows the stop's number once ticked: where it comes in the trip.
    private func row(_ candidate: TripPlanner.StopCandidate) -> some View {
        let ident = candidate.aerodrome.ident
        let number = stopNumber(of: ident)
        return Button {
            toggle(candidate)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                tickBox(number)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(ident)
                            .font(.aero(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primaryText)
                        if candidate.aerodrome.isPPR { PPRChip() }
                    }
                    Text(isLocal ? candidate.aerodrome.name : "\(candidate.aerodrome.name) · \(placement(candidate))")
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                        .lineLimit(1)
                    Text(candidate.aerodrome.frequency ?? L10n.Trip.noFrequency)
                        .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                        .foregroundColor(candidate.aerodrome.frequency == nil ? .aviationAmber : .dimText)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: "%.1f NM", candidate.alongNM))
                        .font(.aero(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.primaryText)
                    Text(duration(candidate.alongNM))
                        .font(.aero(size: 12, design: .monospaced))
                        .foregroundColor(.dimText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .background(number != nil ? Color.aviationGold.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(number != nil ? .isSelected : [])
        .accessibilityValue(number.map(L10n.PlanFlight.stopLabel) ?? "")
    }

    private func tickBox(_ number: Int?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(number == nil ? Color.clear : Color.aviationGold)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(number == nil ? Color.dimText : Color.aviationGold, lineWidth: 1.5)
            if let number {
                Text("\(number)")
                    .font(.aero(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.onAccent)
            }
        }
        .frame(width: 22, height: 22)
        .padding(.top, 1)
        .accessibilityHidden(true)
    }

    /// The legs the ticked stops make, with each stop's time on the ground and refuel.
    private var legsCard: some View {
        let legs = previewLegs
        let idents = TripLegsCard.idents(of: legs)
        return TripLegsCard(legs: legs,
                            idents: idents,
                            stopovers: legs.dropFirst().map { $0.stopover ?? Stopover() },
                            aside: TripLegsCard.total(legs, direct: isLocal),
                            showsWaypointCount: !isLocal,
                            explainer: L10n.Trip.refuelHint) { index, stopover in
            guard idents.indices.contains(index + 1),
                  let at = ticked.firstIndex(where: { $0.ident == idents[index + 1] }) else { return }
            ticked[at].stopover = stopover
        }
    }

    /// What the split will make, then the button.
    private var splitBar: some View {
        let legs = previewLegs
        return VStack(spacing: 8) {
            Text(ticked.isEmpty ? L10n.AddStops.tickStops : TripLegsCard.idents(of: legs).joined(separator: " → "))
                .scaledFont(size: 14, relativeTo: .subheadline)
                .foregroundColor(.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Button {
                let added = FlightCreator.addStops(to: threadId, landingAt: ticked,
                                                   plans: flightPlanManager, threads: threadManager)
                onDone(added.first?.id)
            } label: {
                Text(L10n.AddStops.splitInto(max(2, legs.count))).frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(ticked.isEmpty || legs.count < 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(Color.panelBackground.shadow(.drop(color: .black.opacity(0.4), radius: 8, y: -2)))
    }

    // MARK: - Pieces

    private func placement(_ candidate: TripPlanner.StopCandidate) -> String {
        candidate.waypointIndex != nil || candidate.offsetNM < TripPlanner.onRouteNM
            ? L10n.Trip.onRoute
            : L10n.Trip.offRoute(String(format: "%.1f", candidate.offsetNM))
    }

    /// Time from departure at the plan's cruise speed, as H:MM. A guide for choosing, not a plan:
    /// the leg's own timing (wind, allowances) is computed when the split is made.
    private func duration(_ nm: Double) -> String {
        let speed = Double(plan?.waypoints.first?.plannedGroundSpeed
                           ?? FlightPlan.defaultCruiseSpeed(for: plan?.aircraftTypeId ?? ""))
        guard speed > 0 else { return "" }
        let minutes = Int((nm / speed * 60).rounded())
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    // MARK: - Choosing

    /// The legs the ticked stops would make, as the split makes them.
    private var previewLegs: [FlightPlan] {
        guard let plan, !ticked.isEmpty else { return plan.map { [$0] } ?? [] }
        return TripPlanner.legs(of: plan, landingAt: ticked)
    }

    /// Where a ticked aerodrome comes among the stops, from 1: its place in the legs.
    private func stopNumber(of ident: String) -> Int? {
        guard ticked.contains(where: { $0.ident == ident }) else { return nil }
        // A slice keeps the indices of the whole list, where the stops start at 1.
        return TripLegsCard.idents(of: previewLegs).dropFirst().dropLast().firstIndex(of: ident)
    }

    private func toggle(_ candidate: TripPlanner.StopCandidate) {
        if let index = ticked.firstIndex(where: { $0.ident == candidate.aerodrome.ident }) {
            ticked.remove(at: index)
        } else {
            ticked.append(TripPlanner.Landing(candidate: candidate))
            // A field found by name joins the list in its place; the search has done its job.
            if searchResults.contains(where: { $0.aerodrome.ident == candidate.aerodrome.ident }) {
                query = ""
            }
        }
    }

    // MARK: - Data

    private func load() async {
        await airportDataService.ensureLoaded()
        defer { isLoading = false }
        guard let plan else { return }
        if plan.waypoints.count >= 2 {
            let aerodromes = airportDataService.planningAerodromes(around: plan.waypoints.map(\.coordinate),
                                                                   marginNM: 6)
            candidates = TripPlanner.stopCandidates(along: plan.waypoints, aerodromes: aerodromes)
        } else if let field = plan.waypoints.first {
            let aerodromes = airportDataService.planningAerodromes(around: [field.coordinate],
                                                                   marginNM: TripPlanner.localStopRadiusNM + 1)
            candidates = TripPlanner.stopCandidates(around: field.coordinate, aerodromes: aerodromes)
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2, let plan, let departure = plan.waypoints.first else { searchResults = []; return }
        let found = airportDataService.searchAirports(query: term, limit: 8,
                                                      near: departure.coordinate,
                                                      types: AirportType.fixedWing)
            .filter(AirportDataService.isPlanningLandingSite)
            .map(airportDataService.planningAerodrome)
        searchResults = isLocal
            ? TripPlanner.stopCandidates(around: departure.coordinate, aerodromes: found,
                                         radiusNM: .greatestFiniteMagnitude)
            : TripPlanner.stopCandidates(along: plan.waypoints, aerodromes: found,
                                         corridorNM: .greatestFiniteMagnitude)
    }
}
