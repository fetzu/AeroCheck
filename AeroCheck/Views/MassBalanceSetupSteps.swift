import SwiftUI

/// The first time, per aircraft: three steps with the aircraft's papers at hand. (6.11.0, the author's m4)
///
/// 1. Is this your aircraft? What identifies the data, to compare with the handbook. A plausible
///    envelope of the wrong variant can't be seen on a chart; a serial number or a maximum mass that
///    isn't the handbook's can.
/// 2. The empty mass: the last line of the record with its date. A newer line is typed as the record
///    writes it, a mass and a moment, and the app shows the CG that gives.
/// 3. Confirmed, with what happens next.
///
/// Nothing is confirmed before step 2 is answered, and "something differs" switches this revision of
/// the data off for the aircraft.
struct MassBalanceSetupSteps: View {
    let registration: String
    let shipped: AircraftMassBalance
    let onDone: () -> Void

    @Environment(AppState.self) private var appState
    @State private var step = 1
    @State private var typing = false
    @State private var massText = ""
    @State private var momentText = ""
    @State private var date = Date()

    private var units: AircraftMassBalance.Units { shipped.units }
    private var setup: MassBalanceSetup { appState.settings.massBalance[registration] }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch step {
                        case 1: identity
                        case 2: emptyMass
                        default: confirmed
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("\(registration) · \(L10n.MassBalance.stepOf(step, 3))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == 2 {
                        Button(L10n.Button.back) { step = 1; typing = false }
                    } else if step == 1 {
                        Button(L10n.Button.cancel, action: onDone)
                    }
                }
            }
        }
        .onAppear { typing = shipped.empty == nil }
    }

    // MARK: 1

    private var identity: some View {
        Group {
            title(L10n.MassBalance.step1Title)
            text(L10n.MassBalance.step1Body(registration))
            MassBalanceFacts(rows: identityRows)
            sources
            primary(L10n.MassBalance.step1Matches, identifier: "mb.step.matches") { step = 2 }
            secondary(L10n.MassBalance.step1Differs, identifier: "mb.step.differs") {
                var setup = setup
                setup.decline(revision: shipped.revision)
                appState.settings.massBalance[registration] = setup
                appState.saveSettings()
                onDone()
            }
        }
    }

    private var identityRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let identity = shipped.identity {
            rows.append((L10n.MassBalance.step1Type, identity.designation))
            rows.append((L10n.MassBalance.step1Serial, identity.serialNumber))
        }
        for category in shipped.categories {
            let name = shipped.categories.count > 1 ? " (\(MassBalanceWords.category(category.id)))" : ""
            rows.append((L10n.MassBalance.step1Mtom + name, MassBalanceWords.mass(category.maxTakeoff, units, withKilograms: false)))
        }
        if let datum = shipped.datum {
            let language = Locale.current.language.languageCode?.identifier ?? "en"
            if let text = datum[language] ?? datum["en"] { rows.append((L10n.MassBalance.step1Datum, text)) }
        }
        for station in shipped.stations where station.kind != .fuel {
            var value = MassBalanceWords.arm(station.arm, units)
            if station.kind == .baggage, let maximum = station.max {
                value += " · " + L10n.MassBalance.rowAtMost(MassBalanceWords.mass(maximum, units, withKilograms: false))
            }
            rows.append((MassBalanceWords.rowName(station, in: shipped), value))
        }
        if let fuel = shipped.fuelStation, let usable = fuel.usable {
            rows.append((L10n.MassBalance.step1Fuel,
                         L10n.MassBalance.step1Usable(MassBalanceWords.arm(fuel.arm, units), MassBalanceWords.fuelCapacity(usable, units))))
        }
        return rows
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array((shipped.sources ?? []).enumerated()), id: \.offset) { _, source in
                Text([source.document, source.revision.map { "rev. \($0)" }, source.date.map(MassBalanceWords.day)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .scaledFont(size: 13, relativeTo: .caption)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 2

    @ViewBuilder
    private var emptyMass: some View {
        title(L10n.MassBalance.step2Title)
        if let empty = shipped.empty, !typing {
            text(L10n.MassBalance.step2Body(registration))
            MassBalanceFacts(rows: [
                (L10n.MassBalance.step2Date, MassBalanceWords.day(empty.date)),
                (L10n.MassBalance.step2Mass, MassBalanceWords.mass(empty.mass, units)),
                (L10n.MassBalance.tableMoment, "\(MassBalanceWords.momentFigure(empty.moment, units)) \(units.mass.rawValue)·\(units.arm.rawValue)"),
                (L10n.MassBalance.step2Cg, empty.arm.map { MassBalanceWords.arm($0, units) } ?? "—")
            ])
            text(L10n.MassBalance.step2Question(MassBalanceWords.day(empty.date)))
            primary(L10n.MassBalance.step2Same, identifier: "mb.step.same") { confirm(ownEmpty: nil) }
            secondary(L10n.MassBalance.step2Newer, identifier: "mb.step.newer") { typing = true }
        } else {
            text(shipped.empty == nil ? L10n.MassBalance.step2None(registration)
                                      : L10n.MassBalance.step2AsWritten(units.mass.rawValue, units.arm.rawValue))
            if shipped.empty == nil { text(L10n.MassBalance.step2AsWritten(units.mass.rawValue, units.arm.rawValue)) }
            typedLine
        }
    }

    private var typed: AircraftMassBalance.EmptyMass? {
        func number(_ text: String) -> Double? {
            let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            return Double(cleaned).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        guard let mass = number(massText), let moment = number(momentText) else { return nil }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return .init(mass: mass, moment: moment, date: day.string(from: date), entry: nil)
    }

    @ViewBuilder
    private var typedLine: some View {
        let line = typed
        let plausible = line.map { $0.isPlausible(for: shipped) } ?? false
        VStack(alignment: .leading, spacing: 12) {
            field(L10n.MassBalance.step2Mass, unit: units.mass.rawValue, text: $massText, identifier: "mb.step.mass")
            field(L10n.MassBalance.tableMoment, unit: "\(units.mass.rawValue)·\(units.arm.rawValue)", text: $momentText, identifier: "mb.step.moment")
            DatePicker(L10n.MassBalance.step2Date, selection: $date, in: ...Date(), displayedComponents: .date)
                .scaledFont(size: 17, relativeTo: .body)
                .foregroundColor(.primaryText)
        }
        if let line, let arm = line.arm {
            if plausible {
                MassBalanceFacts(rows: [(L10n.MassBalance.step2Cg, MassBalanceWords.arm(arm, units))])
            } else {
                // The slip a handwritten record invites: the moment as its column writes it, divided by 100.
                Label(L10n.MassBalance.step2Implausible(MassBalanceWords.arm(arm, units)), systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(size: 16, weight: .semibold, relativeTo: .callout)
                    .foregroundColor(.aviationAmber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.aviationAmber, lineWidth: 1.5))
                    .accessibilityIdentifier("mb.step.implausible")
            }
        }
        primary(L10n.MassBalance.step2Use, identifier: "mb.step.use") { confirm(ownEmpty: line) }
            .disabled(!plausible)
            .opacity(plausible ? 1 : 0.45)
    }

    private func confirm(ownEmpty: AircraftMassBalance.EmptyMass?) {
        var setup = setup
        if let ownEmpty { setup.ownEmpty = ownEmpty }
        setup.confirm(revision: shipped.revision, at: Date())
        appState.settings.massBalance[registration] = setup
        appState.saveSettings()
        step = 3
    }

    // MARK: 3

    private var confirmed: some View {
        Group {
            title(L10n.MassBalance.step3Title)
            let empty = setup.basis(shipped: shipped, now: Date())?.empty
            text(L10n.MassBalance.step3Body(registration, empty.map { MassBalanceWords.day($0.date) } ?? "—"))
            text(L10n.MassBalance.step3Again)
            primary(L10n.Button.done, identifier: "mb.step.done", action: onDone)
        }
    }

    // MARK: Pieces

    private func title(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 24, weight: .bold, relativeTo: .title2)
            .foregroundColor(.primaryText)
    }

    private func text(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 17, relativeTo: .body)
            .foregroundColor(.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func primary(_ label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).frame(maxWidth: .infinity)
        }
        .buttonStyle(MassBalanceActionStyle())
        .accessibilityIdentifier(identifier)
    }

    private func secondary(_ label: String, identifier: String, action: @escaping () -> Void) -> some View {
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

    private func field(_ label: String, unit: String, text: Binding<String>, identifier: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .scaledFont(size: 17, relativeTo: .body)
                .foregroundColor(.primaryText)
            Spacer(minLength: 8)
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .scaledFont(size: 20, design: .monospaced, relativeTo: .title3)
                .frame(width: 150)
                .frame(minHeight: 52)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
                .accessibilityLabel("\(label), \(unit)")
                .accessibilityIdentifier(identifier)
            Text(unit)
                .scaledFont(size: 15, relativeTo: .subheadline)
                .foregroundColor(.secondaryText)
                .frame(minWidth: 44, alignment: .leading)
        }
    }
}

/// Label and value pairs, one a line.
struct MassBalanceFacts: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().overlay(Color.white.opacity(0.06)) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0)
                        .scaledFont(size: 16, relativeTo: .callout)
                        .foregroundColor(.secondaryText)
                    Spacer(minLength: 8)
                    Text(row.1)
                        .scaledFont(size: 16, design: .monospaced, relativeTo: .callout)
                        .foregroundColor(.primaryText)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.cardBackground))
    }
}
