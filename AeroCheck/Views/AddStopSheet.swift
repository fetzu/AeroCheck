import SwiftUI
import CoreLocation

// MARK: - Add a stop (v5.1)

/// Add a stop to a flight that has not flown: pick an aerodrome along the route, say how long the
/// aircraft stays and whether it refuels, and the flight becomes two legs of one trip.
///
/// A ground screen, so it can afford detail: every aerodrome within 5 NM of the route in the order it
/// is reached, with its distance and time from departure, its contact frequency and a PPR chip. A
/// field further away is one search away.
struct AddStopSheet: View {
    let threadId: UUID
    /// Called with the new leg's thread id, or nil when the pilot cancelled.
    let onDone: (UUID?) -> Void

    @EnvironmentObject var threadManager: FlightThreadManager
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var airportDataService: AirportDataService

    @State private var candidates: [TripPlanner.StopCandidate] = []
    @State private var searchResults: [TripPlanner.StopCandidate] = []
    @State private var query = ""
    @State private var selected: TripPlanner.StopCandidate?
    @State private var groundMinutes = Stopover.defaultGroundMinutes
    @State private var refuel = false
    @State private var isLoading = true

    private var plan: FlightPlan? {
        guard let planId = threadManager.thread(withId: threadId)?.flightPlanId else { return nil }
        return flightPlanManager.flightPlans.first { $0.id == planId }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.Trip.addStopExplainer)
                        .scaledFont(size: 13, relativeTo: .footnote)
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    searchField
                    if !searchResults.isEmpty {
                        list(searchResults)
                    }
                    candidatesSection
                    if selected != nil { stopoverCard }
                    splitButton
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.cockpitBackground)
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
            Text(L10n.Trip.addStopHint)
                .scaledFont(size: 12, relativeTo: .caption)
                .foregroundColor(.dimText)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if candidates.isEmpty {
                Text(L10n.Trip.noCandidates)
                    .scaledFont(size: 13, relativeTo: .footnote)
                    .foregroundColor(.secondaryText)
                    .padding(.vertical, 8)
            } else {
                list(candidates)
            }
        }
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

    private func row(_ candidate: TripPlanner.StopCandidate) -> some View {
        let isSelected = selected?.aerodrome.ident == candidate.aerodrome.ident
        return Button {
            selected = candidate
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .scaledFont(size: 18, relativeTo: .body)
                    .foregroundColor(isSelected ? .aviationGold : .dimText)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(candidate.aerodrome.ident)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primaryText)
                        if candidate.aerodrome.isPPR { chip("PPR") }
                    }
                    Text("\(candidate.aerodrome.name) · \(placement(candidate))")
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
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.primaryText)
                    Text(duration(candidate.alongNM))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.dimText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .background(isSelected ? Color.aviationGold.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var stopoverCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(value: $groundMinutes, in: 0...720, step: 15) {
                Text(L10n.Trip.groundTime(groundMinutes))
                    .scaledFont(size: 15, relativeTo: .body)
                    .foregroundColor(.primaryText)
            }
            Toggle(isOn: $refuel) {
                Text(L10n.Trip.refuel)
                    .scaledFont(size: 15, relativeTo: .body)
                    .foregroundColor(.primaryText)
            }
            .tint(.aviationGold)
            if !refuel {
                Text(L10n.Trip.refuelHint)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let preview {
                VStack(alignment: .leading, spacing: 4) {
                    legLine(preview.first)
                    legLine(preview.second)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.cockpitBackground))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.panelBackground))
    }

    private var splitButton: some View {
        Button {
            guard let selected else { return }
            let leg = FlightCreator.addStop(to: threadId, at: selected,
                                            stopover: Stopover(groundMinutes: groundMinutes, refuel: refuel),
                                            plans: flightPlanManager, threads: threadManager)
            onDone(leg?.id)
        } label: {
            Text(L10n.Trip.split).frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(selected == nil)
    }

    // MARK: - Pieces

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundColor(.aviationAmber)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.aviationAmber, lineWidth: 1))
    }

    private func legLine(_ leg: FlightPlan) -> some View {
        Text("\(FlightThreadManager.routeLabel(for: leg)) · \(String(format: "%.1f NM", leg.totalDistance)) · \(leg.formattedTotalEET)")
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(.primaryText)
    }

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

    /// The two legs the current choice would make.
    private var preview: (first: FlightPlan, second: FlightPlan)? {
        guard let plan, let selected else { return nil }
        let (route, index) = TripPlanner.routeStopping(at: selected, in: plan)
        return TripPlanner.split(route, at: index,
                                 stopover: Stopover(groundMinutes: groundMinutes, refuel: refuel),
                                 stopIdent: selected.aerodrome.ident,
                                 fieldElevationFeet: selected.aerodrome.elevationFeet)
    }

    // MARK: - Data

    private func load() async {
        await airportDataService.ensureLoaded()
        defer { isLoading = false }
        guard let plan, plan.waypoints.count >= 2 else { return }
        let aerodromes = airportDataService.planningAerodromes(around: plan.waypoints.map(\.coordinate),
                                                               marginNM: 6)
        candidates = TripPlanner.stopCandidates(along: plan.waypoints, aerodromes: aerodromes)
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2, let plan else { searchResults = []; return }
        let found = airportDataService.searchAirports(query: term, limit: 8,
                                                      near: plan.waypoints.first?.coordinate,
                                                      types: AirportType.fixedWing)
            .filter(AirportDataService.isPlanningLandingSite)
            .map(airportDataService.planningAerodrome)
        searchResults = TripPlanner.stopCandidates(along: plan.waypoints, aerodromes: found,
                                                   corridorNM: .greatestFiniteMagnitude)
    }
}
