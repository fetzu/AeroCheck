import SwiftUI

// MARK: - Set altitudes (builder)

/// Sets the planned altitude of many waypoints at once: a fixed altitude, or a clearance above the
/// terrain. The rules live in `AltitudePlanner`; this sheet fetches the terrain, previews the result
/// (lowest clearance per leg, airspace the new profile runs into) and hands the chosen altitudes back
/// in one batch. Cancel changes nothing.
struct SetAltitudesSheet: View {
    let plan: FlightPlan
    let onApply: ([UUID: Double]) -> Void

    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @Environment(\.dismiss) private var dismiss

    private enum ModeChoice: Hashable { case terrain, fixed }
    private enum TerrainState { case loading, ready, failed }

    @State private var mode: ModeChoice = .terrain
    @State private var clearanceFt: Double = 1000
    @State private var roundToFt: Double = 100
    @State private var basis: AltitudePlanner.Basis = .highestOnAdjacentLegs
    @State private var fixedText = "5500"
    @State private var selected: Set<Int>
    @State private var terrain: [AltitudePlanner.TerrainSample] = []
    @State private var terrainState: TerrainState = .loading
    private let elevationService = ElevationService()

    /// 150 m, the builder's terrain-clearance warning.
    private static let warnFt: Double = 150 * 3.28084

    init(plan: FlightPlan, onApply: @escaping ([UUID: Double]) -> Void) {
        self.plan = plan
        self.onApply = onApply
        let inner = plan.waypoints.count >= 3 ? Set(1..<(plan.waypoints.count - 1)) : []
        _selected = State(initialValue: inner)
    }

    private var waypoints: [FlightPlanWaypoint] { plan.waypoints }
    private var innerIndices: [Int] { waypoints.count >= 3 ? Array(1..<(waypoints.count - 1)) : [] }

    private var planMode: AltitudePlanner.Mode? {
        switch mode {
        case .terrain:
            guard terrainState == .ready else { return nil }
            return .aboveTerrain(clearanceFt: clearanceFt, basis: basis, roundToFt: roundToFt)
        case .fixed:
            guard let feet = Double(fixedText.trimmingCharacters(in: .whitespaces)),
                  PlausibleRange.isPlausible(feet, in: PlausibleRange.altitudeFeet) else { return nil }
            return .fixed(feet: feet)
        }
    }

    private var proposed: [Double?] {
        guard let planMode else { return waypoints.map(\.altitude) }
        return AltitudePlanner.proposedAltitudes(for: waypoints, selected: selected, mode: planMode, terrain: terrain)
    }

    var body: some View {
        let altitudes = proposed
        let clearances = AltitudePlanner.legClearances(for: waypoints, altitudes: altitudes, terrain: terrain)
        let enters = airspaceEntered(altitudes)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("", selection: $mode) {
                        Text(L10n.Altitudes.modeTerrain).tag(ModeChoice.terrain)
                        Text(L10n.Altitudes.modeFixed).tag(ModeChoice.fixed)
                    }
                    .pickerStyle(.segmented)

                    if mode == .terrain { terrainControls } else { fixedControls }
                    summary(altitudes: altitudes, clearances: clearances, enters: enters)
                    waypointTable(altitudes: altitudes, clearances: clearances, enters: enters)
                    Text(L10n.Altitudes.footnote)
                        .scaledFont(size: 12, relativeTo: .footnote)
                        .foregroundColor(.secondaryText)
                }
                .padding()
            }
            .background(Color.cockpitBackground)
            .navigationTitle(L10n.Altitudes.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Altitudes.apply(changes(altitudes).count)) {
                        onApply(changes(altitudes))
                        dismiss()
                    }
                    .disabled(planMode == nil || changes(altitudes).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadTerrain() }
    }

    // MARK: Controls

    private var terrainControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                labelled(L10n.Altitudes.clearance) {
                    Picker(L10n.Altitudes.clearance, selection: $clearanceFt) {
                        ForEach([500.0, 1000, 1500, 2000], id: \.self) { Text("+\(Int($0)) ft").tag($0) }
                    }
                }
                labelled(L10n.Altitudes.roundUp) {
                    Picker(L10n.Altitudes.roundUp, selection: $roundToFt) {
                        ForEach([100.0, 500], id: \.self) { Text("\(Int($0)) ft").tag($0) }
                    }
                }
            }
            labelled(L10n.Altitudes.basis) {
                // Two radio rows: an inline Picker inside a ScrollView renders as a wheel on iOS.
                VStack(alignment: .leading, spacing: 0) {
                    basisOption(.highestOnAdjacentLegs, L10n.Altitudes.basisLegs)
                    basisOption(.groundAtWaypoint, L10n.Altitudes.basisGround)
                }
            }
            switch terrainState {
            case .loading:
                HStack(spacing: 8) { ProgressView(); Text(L10n.Altitudes.loading).foregroundColor(.secondaryText) }
                    .scaledFont(size: 13, relativeTo: .subheadline)
            case .failed:
                Label(L10n.Altitudes.terrainUnavailable, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: 13, relativeTo: .subheadline)
                    .foregroundColor(.aviationAmber)
            case .ready:
                EmptyView()
            }
        }
    }

    private func basisOption(_ option: AltitudePlanner.Basis, _ title: String) -> some View {
        Button { basis = option } label: {
            HStack(spacing: 10) {
                Image(systemName: basis == option ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(.aviationGold)
                Text(title)
                    .scaledFont(size: 14, relativeTo: .body)
                    .foregroundColor(.primaryText)
                Spacer()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(basis == option ? [.isSelected] : [])
    }

    private var fixedControls: some View {
        labelled(L10n.Altitudes.altitudeField) {
            TextField("5500", text: $fixedText)
                .keyboardType(.numberPad)
                .scaledFont(size: 16, weight: .semibold, design: .monospaced, relativeTo: .body)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.panelBackground))
                .frame(maxWidth: 200)
        }
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).scaledFont(size: 12, weight: .semibold, relativeTo: .caption).foregroundColor(.secondaryText)
            content()
        }
    }

    // MARK: Preview

    private func summary(altitudes: [Double?], clearances: [Double?], enters: [[String]]) -> some View {
        // Inner legs only: the first and last are climbs/descents drawn as straight lines.
        let inner = clearances.indices.filter { $0 > 0 && $0 < clearances.count - 1 }
        let worst = inner.compactMap { k in clearances[k].map { (k, $0) } }.min { $0.1 < $1.1 }
        let busts = inner.filter { (clearances[$0] ?? .infinity) < Self.warnFt }.count
        var entered: [String] = []
        for names in enters { for name in names where !entered.contains(name) { entered.append(name) } }
        return VStack(alignment: .leading, spacing: 4) {
            if let worst {
                Text(L10n.Altitudes.lowest(Self.signed(worst.1), name(worst.0), name(worst.0 + 1)))
                    .foregroundColor(worst.1 < Self.warnFt ? .aviationRed : .aviationGreen)
                Text(busts > 0 ? L10n.Altitudes.busts(busts) : L10n.Altitudes.allClear)
                    .foregroundColor(busts > 0 ? .aviationRed : .aviationGreen)
            }
            if !entered.isEmpty {
                Text(L10n.Altitudes.enters(entered.joined(separator: ", ")))
                    .foregroundColor(.aviationAmber)
            }
        }
        .scaledFont(size: 13, weight: .medium, relativeTo: .subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
        .accessibilityElement(children: .combine)
    }

    private func waypointTable(altitudes: [Double?], clearances: [Double?], enters: [[String]]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    selected = selected.count == innerIndices.count ? [] : Set(innerIndices)
                } label: {
                    Image(systemName: selected.count == innerIndices.count ? "checkmark.square.fill" : "square")
                        .foregroundColor(.aviationGold)
                        .frame(width: 44, height: 36)
                }
                .accessibilityLabel(L10n.Altitudes.selectAll)
                Text(L10n.Altitudes.columnWaypoint).frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.Altitudes.columnNow).frame(width: 56, alignment: .trailing)
                Text(L10n.Altitudes.columnNew).frame(width: 56, alignment: .trailing)
                Text(L10n.Altitudes.columnClearance).frame(width: 70, alignment: .trailing)
            }
            .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
            .foregroundColor(.secondaryText)
            .padding(.trailing, 10)
            ForEach(innerIndices, id: \.self) { i in
                Divider().background(Color.subtleOverlay(0.08))
                row(i, altitudes: altitudes, clearances: clearances, enters: enters)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground))
    }

    private func row(_ i: Int, altitudes: [Double?], clearances: [Double?], enters: [[String]]) -> some View {
        let isOn = selected.contains(i)
        let new = altitudes[i]
        let changed = new != waypoints[i].altitude
        let clearance = clearances[i - 1]
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button {
                    if isOn { selected.remove(i) } else { selected.insert(i) }
                } label: {
                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                        .foregroundColor(.aviationGold)
                        .frame(width: 44, height: 36)
                }
                .accessibilityLabel(name(i))
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
                Text(name(i))
                    .foregroundColor(.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.feet(waypoints[i].altitude)).foregroundColor(.secondaryText).frame(width: 56, alignment: .trailing)
                Text(Self.feet(new)).foregroundColor(changed ? .aviationGold : .secondaryText).frame(width: 56, alignment: .trailing)
                // The climb-out leg is a straight line from the runway, so a low figure there says more
                // about the drawing than the plan: amber, and left out of the summary.
                Text(clearance.map(Self.signed) ?? "—")
                    .foregroundColor((clearance ?? .infinity) >= Self.warnFt ? .secondaryText
                                     : (i == 1 ? .aviationAmber : .aviationRed))
                    .frame(width: 70, alignment: .trailing)
            }
            .scaledFont(size: 14, design: .monospaced, relativeTo: .body)
            if i == 1 || !enters[i - 1].isEmpty {
                Text(([i == 1 ? L10n.Altitudes.climbOut : nil].compactMap { $0 } + enters[i - 1]).joined(separator: " · "))
                    .scaledFont(size: 11, relativeTo: .caption2)
                    .foregroundColor(enters[i - 1].isEmpty ? .secondaryText : .aviationAmber)
                    .padding(.leading, 52)
                    .padding(.bottom, 4)
            }
        }
        .padding(.trailing, 10)
    }

    // MARK: Data

    private func name(_ i: Int) -> String { RouteRadioPlanner.displayName(waypoints[i], index: i) }

    private static func feet(_ value: Double?) -> String { value.map { String(Int($0.rounded())) } ?? "—" }
    private static func signed(_ value: Double) -> String { (value >= 0 ? "+" : "") + String(Int(value.rounded())) }

    /// Only what actually changes goes back to the manager.
    private func changes(_ altitudes: [Double?]) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for i in innerIndices where selected.contains(i) {
            if let a = altitudes[i], a != waypoints[i].altitude { out[waypoints[i].id] = a }
        }
        return out
    }

    /// Per leg (k → k+1): controlled or restricted airspace the previewed profile runs into, within the
    /// builder's ±500 ft buffer.
    private func airspaceEntered(_ altitudes: [Double?]) -> [[String]] {
        let n = waypoints.count
        guard n >= 2 else { return [] }
        let cum = AltitudePlanner.cumulativeNM(waypoints)
        let blocks = openAIPDataService.airspaceProfileBlocks(waypoints.map(\.coordinate), altitudesFt: altitudes)
            .filter { $0.isConflict && RouteRadioPlanner.kind(of: $0.airspace) != .ignore
                && $0.airspace.airspaceType != .gliderSector }
        return (0..<(n - 1)).map { k in
            blocks.filter { $0.startNM <= cum[k + 1] && $0.endNM >= cum[k] }
                .map { RouteRadioPlanner.kind(of: $0.airspace) == .check
                    ? RouteRadioPlanner.checkAreaName($0.airspace) : RouteRadioPlanner.label($0.airspace) }
        }
    }

    private func loadTerrain() async {
        await openAIPDataService.ensureLoaded()
        let coords = waypoints.map(\.coordinate)
        let raw = await elevationService.fetchRouteTerrain(waypoints: coords, spacingNM: 0.1)
        let routeNM = AltitudePlanner.cumulativeNM(waypoints).last ?? 0
        terrain = AltitudePlanner.samples(fromMetres: raw, routeNM: routeNM)
        terrainState = terrain.isEmpty ? .failed : .ready
        if terrain.isEmpty { mode = .fixed }
    }
}
