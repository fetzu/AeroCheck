import SwiftUI

// MARK: - The pilot's own figures (6.11.0)
//
// One form, top to bottom in the order of a flight manual's mass and balance section: units, the
// maximum mass, the seats, the baggage, the fuel, the envelope with its drawing as it is typed, and
// the empty aircraft from its record. Nothing is saved until nothing is missing, and what is missing
// is said in words above the button. A ground screen: 17 pt text, 52 pt boxes.

/// What an aircraft without data opens with: what the app has not, and the ways on.
struct MassBalanceNoDataView: View {
    let registration: String
    /// The app has data, and the pilot said it isn't this aircraft's.
    let isDeclined: Bool
    var onEnter: () -> Void
    var onLookAgain: () -> Void
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(isDeclined ? L10n.MassBalance.nodataDeclined(registration) : L10n.MassBalance.nodataBody(registration))
                            .scaledFont(size: 17, relativeTo: .body)
                            .foregroundColor(.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L10n.MassBalance.ownWhy)
                            .scaledFont(size: 17, relativeTo: .body)
                            .foregroundColor(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(action: onEnter) { Text(L10n.MassBalance.ownEnter).frame(maxWidth: .infinity) }
                            .buttonStyle(MassBalanceActionStyle())
                            .accessibilityIdentifier("mb.own.enter")
                        if isDeclined {
                            MassBalanceQuietButton(label: L10n.MassBalance.nodataLookAgain, identifier: "mb.own.lookAgain", action: onLookAgain)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("\(registration) · \(L10n.MassBalance.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.Button.close, action: onClose) }
            }
        }
    }
}

struct MassBalanceQuietButton: View {
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .scaledFont(size: 17, relativeTo: .body)
                .foregroundColor(.primaryText)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.panelBackground))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// The form. `onDone` is called after a save and after a cancel.
struct MassBalanceOwnFiguresView: View {
    let registration: String
    let onDone: () -> Void

    @Environment(AppState.self) private var appState
    @State private var draft = MassBalanceOwnDraft()
    @State private var loaded = false
    @State private var tookOver = false

    var body: some View {
        let missing = draft.missing
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        MassBalanceOwnText(text: L10n.MassBalance.ownIntro(registration), colour: .secondaryText)
                        if tookOver { MassBalanceOwnText(text: L10n.MassBalance.ownFromOld, colour: .aviationAmber) }
                        MassBalanceOwnUnits(units: $draft.units)
                        MassBalanceOwnLimit(draft: $draft)
                        MassBalanceOwnSeats(draft: $draft)
                        MassBalanceOwnBaggage(draft: $draft)
                        MassBalanceOwnFuel(draft: $draft)
                        MassBalanceOwnEnvelope(draft: $draft)
                        MassBalanceOwnEmpty(draft: $draft, missing: missing)
                        MassBalanceOwnMissing(missing: missing, draft: draft)
                    }
                    .padding(20)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("\(registration) · \(L10n.MassBalance.ownTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.Button.cancel, action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Button.done, action: save)
                        .disabled(!missing.isEmpty)
                        .accessibilityIdentifier("mb.own.done")
                }
            }
        }
        .pageSizedSheet()
        .onAppear(perform: start)
    }

    /// Figures typed before come back to be changed; otherwise what the 5.0.0 calculator's figures
    /// say without a guess; otherwise a blank form.
    private func start() {
        guard !loaded else { return }
        loaded = true
        let setup = appState.settings.massBalance[registration]
        if let own = setup.ownData {
            draft = MassBalanceOwnDraft(data: own, empty: own.empty)
        } else if let old = appState.settings.weightBalanceProfiles[registration], old.isConfigured {
            draft = MassBalanceOwnDraft(profile: old)
            tookOver = true
        }
    }

    private func save() {
        guard draft.missing.isEmpty, let data = draft.data(registration: registration) else { return }
        var setup = appState.settings.massBalance[registration]
        // The empty mass goes with the figures (`data.empty`), in their datum. Never into `ownEmpty`:
        // that line stands under the app's data, and would come back under it with the wrong datum
        // the day the app's data is used again.
        setup.ownData = data
        // Typing the figures in is saying they are the aircraft's: asked again in a year, like the app's own data.
        setup.ownConfirmedAt = Date()
        appState.settings.massBalance[registration] = setup
        appState.saveSettings()
        onDone()
    }
}

// MARK: - The form's parts

private struct MassBalanceOwnText: View {
    let text: String
    let colour: Color

    var body: some View {
        Text(text)
            .scaledFont(size: 17, relativeTo: .body)
            .foregroundColor(colour)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A titled card of the form.
private struct MassBalanceOwnCard<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MassBalanceSectionTitle(text: title, note: nil)
            VStack(alignment: .leading, spacing: 12) {
                if let note {
                    Text(note)
                        .scaledFont(size: 15, relativeTo: .subheadline)
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.cardBackground))
        }
    }
}

/// A label on the left, its box on the right.
private struct MassBalanceOwnRow: View {
    let label: String
    @Binding var value: Double?
    let unit: String
    var decimals = 1
    var identifier: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .scaledFont(size: 17, relativeTo: .body)
                .foregroundColor(.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            MassBalanceQuantityField(value: $value, unit: unit, label: label, identifier: identifier, decimals: decimals, width: 116)
        }
    }
}

private func armDecimals(_ units: AircraftMassBalance.Units) -> Int { units.arm == .m ? 3 : 1 }

private struct MassBalanceOwnUnits: View {
    @Binding var units: AircraftMassBalance.Units

    var body: some View {
        MassBalanceOwnCard(title: L10n.MassBalance.ownUnits, note: L10n.MassBalance.ownUnitsNote) {
            picker(L10n.MassBalance.ownMass, selection: $units.mass, options: [(.kg, "kg"), (.lb, "lb")])
            picker(L10n.MassBalance.ownArm, selection: $units.arm, options: [(.m, "m"), (.mm, "mm"), (.inch, "in")])
            picker(L10n.MassBalance.step1Fuel, selection: $units.fuel, options: [(.litre, "L"), (.usGallon, "US gal")])
        }
    }

    private func picker<Value: Hashable>(_ label: String, selection: Binding<Value>, options: [(Value, String)]) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .scaledFont(size: 17, relativeTo: .body)
                .foregroundColor(.primaryText)
            Spacer(minLength: 8)
            Picker(label, selection: selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in Text(option.1).tag(option.0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
        }
        .frame(minHeight: 44)
    }
}

private struct MassBalanceOwnLimit: View {
    @Binding var draft: MassBalanceOwnDraft

    var body: some View {
        MassBalanceOwnCard(title: L10n.MassBalance.ownLimits) {
            MassBalanceOwnRow(label: L10n.MassBalance.step1Mtom, value: $draft.maxTakeoff, unit: draft.units.mass.rawValue,
                              identifier: "mb.own.mtom")
        }
    }
}

private struct MassBalanceOwnSeats: View {
    @Binding var draft: MassBalanceOwnDraft

    var body: some View {
        MassBalanceOwnCard(title: L10n.MassBalance.rowSeats, note: L10n.MassBalance.ownSeatsNote) {
            ForEach($draft.rows) { $row in
                let index = draft.rows.firstIndex { $0.id == row.id } ?? 0
                VStack(alignment: .leading, spacing: 8) {
                    MassBalanceOwnRow(label: L10n.MassBalance.ownRowArm(index + 1), value: $row.arm,
                                      unit: draft.units.arm.rawValue, decimals: armDecimals(draft.units),
                                      identifier: "mb.own.row\(index + 1)")
                    HStack(spacing: 10) {
                        Picker(L10n.MassBalance.rowSeats, selection: $row.seats) {
                            Text(L10n.MassBalance.ownOneSeat).tag(1)
                            Text(L10n.MassBalance.ownTwoSeats).tag(2)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                        Spacer(minLength: 0)
                        if draft.rows.count > 1 {
                            Button(L10n.MassBalance.ownRemove) {
                                draft.rows.removeAll { $0.id == row.id }
                                draft.pilotRow = min(draft.pilotRow, draft.rows.count - 1)
                            }
                            .scaledFont(size: 15, relativeTo: .subheadline)
                            .foregroundColor(.aviationRed)
                            .frame(minHeight: 44)
                        }
                    }
                }
            }
            if draft.rows.count > 1 {
                HStack(spacing: 10) {
                    Text(L10n.MassBalance.ownPilotRow)
                        .scaledFont(size: 17, relativeTo: .body)
                        .foregroundColor(.primaryText)
                    Spacer(minLength: 8)
                    Picker(L10n.MassBalance.ownPilotRow, selection: $draft.pilotRow) {
                        ForEach(draft.rows.indices, id: \.self) { index in Text(L10n.MassBalance.ownRow(index + 1)).tag(index) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
            }
            if draft.rows.count < MassBalanceOwnDraft.maximumRows {
                MassBalanceOwnAdd(label: L10n.MassBalance.ownAddRow, identifier: "mb.own.addRow") { draft.rows.append(.init()) }
            }
        }
    }
}

private struct MassBalanceOwnAdd: View {
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: "plus")
                .scaledFont(size: 17, relativeTo: .body)
                .foregroundColor(.altimeterBlue)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

private struct MassBalanceOwnBaggage: View {
    @Binding var draft: MassBalanceOwnDraft

    var body: some View {
        MassBalanceOwnCard(title: L10n.MassBalance.rowBaggage) {
            ForEach($draft.baggage) { $area in
                let index = draft.baggage.firstIndex { $0.id == area.id } ?? 0
                VStack(alignment: .leading, spacing: 8) {
                    MassBalanceOwnRow(label: L10n.MassBalance.ownAreaArm(index + 1), value: $area.arm,
                                      unit: draft.units.arm.rawValue, decimals: armDecimals(draft.units))
                    MassBalanceOwnRow(label: L10n.MassBalance.ownAreaMax, value: $area.max, unit: draft.units.mass.rawValue)
                    Button(L10n.MassBalance.ownRemove) { draft.baggage.removeAll { $0.id == area.id } }
                        .scaledFont(size: 15, relativeTo: .subheadline)
                        .foregroundColor(.aviationRed)
                        .frame(minHeight: 44)
                }
            }
            if draft.baggage.count < MassBalanceOwnDraft.maximumBaggageAreas {
                MassBalanceOwnAdd(label: L10n.MassBalance.ownAddBaggage, identifier: "mb.own.addBaggage") { draft.baggage.append(.init()) }
            }
        }
    }
}

private struct MassBalanceOwnFuel: View {
    @Binding var draft: MassBalanceOwnDraft

    var body: some View {
        MassBalanceOwnCard(title: L10n.MassBalance.step1Fuel) {
            MassBalanceOwnRow(label: L10n.MassBalance.ownArm, value: $draft.fuelArm, unit: draft.units.arm.rawValue,
                              decimals: armDecimals(draft.units), identifier: "mb.own.fuelArm")
            MassBalanceOwnRow(label: L10n.MassBalance.ownUsable, value: $draft.fuelUsable,
                              unit: draft.units.fuel == .litre ? "L" : "US gal", identifier: "mb.own.usable")
            MassBalanceOwnRow(label: L10n.MassBalance.ownDensity, value: $draft.fuelDensityKgPerLitre, unit: "kg/L", decimals: 3)
        }
    }
}

private struct MassBalanceOwnEnvelope: View {
    @Binding var draft: MassBalanceOwnDraft

    var body: some View {
        MassBalanceOwnCard(title: L10n.MassBalance.ownEnvelope, note: L10n.MassBalance.ownEnvelopeNote) {
            ForEach($draft.corners) { $corner in
                let index = draft.corners.firstIndex { $0.id == corner.id } ?? 0
                // Two boxes and the button fit an iPhone's width as they are: no number in front, the
                // drawing below shows the order.
                HStack(spacing: 8) {
                    MassBalanceQuantityField(value: $corner.arm, unit: draft.units.arm.rawValue,
                                             label: "\(L10n.MassBalance.ownArm) \(index + 1)", decimals: armDecimals(draft.units), width: 76)
                    MassBalanceQuantityField(value: $corner.mass, unit: draft.units.mass.rawValue,
                                             label: "\(L10n.MassBalance.ownMass) \(index + 1)", width: 76)
                    Spacer(minLength: 0)
                    if draft.corners.count > 3 {
                        Button { draft.corners.removeAll { $0.id == corner.id } } label: {
                            Image(systemName: "minus.circle")
                                .scaledFont(size: 20, relativeTo: .title3)
                                .foregroundColor(.aviationRed)
                                .frame(width: 36, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(L10n.MassBalance.ownRemove) \(index + 1)")
                    }
                }
            }
            MassBalanceOwnAdd(label: L10n.MassBalance.ownAddCorner, identifier: "mb.own.addCorner") { draft.corners.append(.init()) }
            if let preview = draft.envelopePreview() {
                // Drawn as it is typed: a corner out of order shows at once as a crossed shape.
                MassBalanceChart(data: preview, result: MassBalanceResult(verdict: .incomplete), compact: true)
                    .frame(height: 200)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct MassBalanceOwnEmpty: View {
    @Binding var draft: MassBalanceOwnDraft
    let missing: [MassBalanceOwnDraft.Missing]

    var body: some View {
        let units = draft.units
        MassBalanceOwnCard(title: L10n.MassBalance.step2Title,
                           note: L10n.MassBalance.step2AsWritten(units.mass.rawValue, units.arm.rawValue)) {
            MassBalanceOwnRow(label: L10n.MassBalance.step2Mass, value: $draft.emptyMass, unit: units.mass.rawValue,
                              identifier: "mb.own.emptyMass")
            MassBalanceOwnRow(label: L10n.MassBalance.tableMoment, value: $draft.emptyMoment,
                              unit: "\(units.mass.rawValue)·\(units.arm.rawValue)", decimals: 2, identifier: "mb.own.emptyMoment")
            DatePicker(L10n.MassBalance.step2Date, selection: $draft.emptyDate, in: ...Date(), displayedComponents: .date)
                .scaledFont(size: 17, relativeTo: .body)
                .foregroundColor(.primaryText)
            if let empty = draft.empty(), let arm = empty.arm {
                if missing.contains(.emptyImplausible) {
                    Label(L10n.MassBalance.step2Implausible(MassBalanceWords.arm(arm, units)), systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(size: 16, weight: .semibold, relativeTo: .callout)
                        .foregroundColor(.aviationAmber)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("mb.own.implausible")
                } else {
                    Text("\(L10n.MassBalance.step2Cg) \(MassBalanceWords.arm(arm, units))")
                        .scaledFont(size: 17, relativeTo: .body)
                        .foregroundColor(.secondaryText)
                }
            }
        }
    }
}

/// What still keeps the form from being saved, in words; nothing when it is whole.
private struct MassBalanceOwnMissing: View {
    let missing: [MassBalanceOwnDraft.Missing]
    let draft: MassBalanceOwnDraft

    var body: some View {
        if missing.isEmpty {
            Label(L10n.MassBalance.ownWhole, systemImage: "checkmark")
                .scaledFont(size: 17, weight: .semibold, relativeTo: .body)
                .foregroundColor(.aviationGreen)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(L10n.MassBalance.ownMissing(Self.names(missing).joined(separator: " · ")))
                .scaledFont(size: 17, relativeTo: .body)
                .foregroundColor(.aviationAmber)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("mb.own.missing")
        }
    }

    static func names(_ missing: [MassBalanceOwnDraft.Missing]) -> [String] {
        missing.map { item in
            switch item {
            case .maxTakeoff: return L10n.MassBalance.step1Mtom
            case .seatArm(let row): return L10n.MassBalance.ownRowArm(row)
            case .baggage(let area): return L10n.MassBalance.rowBaggageN(area)
            case .fuel: return L10n.MassBalance.step1Fuel
            case .envelope: return L10n.MassBalance.ownEnvelope
            case .empty, .emptyImplausible: return L10n.MassBalance.step2Title
            }
        }
    }
}
