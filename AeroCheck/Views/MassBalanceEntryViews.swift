import SwiftUI

// MARK: - Entering the load (6.11.0)
//
// Kilograms and litres are typed; the handbook's units sit beside each figure. A blank box is "not
// entered", never zero: a seat is a person, said empty, or not entered.

/// A figure typed in kilograms or litres. Empty stays empty.
struct MassBalanceQuantityField: View {
    @Binding var value: Double?
    let unit: String
    /// The same quantity in the handbook's unit, when that isn't the one typed.
    var alternative: String?
    var flagged: Bool = false
    let label: String
    var identifier: String?

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("—", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .scaledFont(size: 22, design: .monospaced, relativeTo: .title3)
                .foregroundColor(flagged ? .aviationRed : .primaryText)
                .frame(width: 84)
                .frame(minHeight: 52)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(flagged ? Color.aviationRed : Color.white.opacity(0.08), lineWidth: flagged ? 1.5 : 1))
                .focused($focused)
                .accessibilityLabel("\(label), \(unit)")
                .accessibilityIdentifier(identifier ?? "")
            VStack(alignment: .leading, spacing: 1) {
                Text(unit)
                    .scaledFont(size: 15, relativeTo: .subheadline)
                    .foregroundColor(.secondaryText)
                if let alternative {
                    Text(alternative)
                        .scaledFont(size: 13, design: .monospaced, relativeTo: .caption)
                        .foregroundColor(.dimText)
                }
            }
            .frame(minWidth: 26, alignment: .leading)
        }
        .onAppear { text = Self.display(value) }
        .onChange(of: value) { _, new in if !focused { text = Self.display(new) } }
        .onChange(of: text) { _, new in
            guard focused else { return }
            let cleaned = new.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            if cleaned.isEmpty { value = nil } else if let typed = Double(cleaned), typed.isFinite, typed >= 0 { value = typed }
        }
        .onChange(of: focused) { _, isFocused in if !isFocused { text = Self.display(value) } }
    }

    private static func display(_ value: Double?) -> String {
        guard let value else { return "" }
        return value == value.rounded() ? String(Int(value)) : MassBalanceWords.plain(value, decimals: 1)
    }
}

/// One seat: its mass in kilograms, or "Empty".
struct MassBalanceSeatControl: View {
    let seat: AircraftMassBalance.Seat
    let data: AircraftMassBalance
    let flagged: Bool
    @Binding var load: MassBalanceLoad
    var vertical: Bool = false

    private var state: MassBalanceSeatLoad { load.seats[seat.id] ?? .unset }
    private var kilograms: Binding<Double?> {
        Binding(get: { if case .person(let kg) = state { return kg } else { return nil } },
                set: { load.seats[seat.id] = $0.map { .person(kg: $0) } ?? .unset })
    }
    private var name: String { MassBalanceWords.seatName(seat, in: data) }

    var body: some View {
        let field = MassBalanceQuantityField(
            value: kilograms, unit: "kg",
            alternative: alternative, flagged: flagged, label: name, identifier: "mb.seat.\(seat.id)")
        let empty = Button {
            load.seats[seat.id] = state == .empty ? .unset : .empty
        } label: {
            // A tick as well as the frame: "said empty" doesn't depend on a colour.
            Label(L10n.MassBalance.buttonEmpty, systemImage: state == .empty ? "checkmark.circle.fill" : "circle")
                .scaledFont(size: 15, weight: state == .empty ? .semibold : .regular, relativeTo: .subheadline)
                .foregroundColor(.primaryText)
                .padding(.horizontal, 12)
                .frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(state == .empty ? Color.altimeterBlue : Color.white.opacity(0.08), lineWidth: state == .empty ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name): \(L10n.MassBalance.buttonEmpty)")
        .accessibilityAddTraits(state == .empty ? .isSelected : [])
        .accessibilityIdentifier("mb.empty.\(seat.id)")

        VStack(alignment: vertical ? .center : .leading, spacing: 6) {
            Text(name)
                .scaledFont(size: 15, relativeTo: .subheadline)
                .foregroundColor(.secondaryText)
            if vertical {
                field
                empty
            } else {
                HStack(spacing: 8) { field; empty }
            }
        }
    }

    private var alternative: String? {
        guard data.units.mass != .kg, case .person(let kg) = state else { return nil }
        return "\(MassBalanceWords.plain(kg * data.units.mass.perKilogram, decimals: 0)) \(data.units.mass.rawValue)"
    }
}

/// The fuel in the tanks at engine start and the trip fuel, with what this load lets the pilot take.
struct MassBalanceFuelControls: View {
    let data: AircraftMassBalance
    let result: MassBalanceResult
    @Binding var load: MassBalanceLoad
    var vertical: Bool = false

    private var flagged: Bool { result.failures.contains { $0.stationOrSeatId == MassBalanceResult.fuelRowId } }

    var body: some View {
        let fuel = MassBalanceQuantityField(value: $load.fuelLitres, unit: "L",
                                            alternative: load.fuelLitres.flatMap { MassBalanceWords.fuel(litres: $0, data.units) },
                                            flagged: flagged, label: L10n.MassBalance.rowFuel, identifier: "mb.fuel")
        let full = Button(L10n.MassBalance.buttonFullTanks) {
            if let usable = data.usableFuelLitres { load.fuelLitres = usable.rounded(.down) }
        }
        .buttonStyle(.plain)
        .scaledFont(size: 15, relativeTo: .subheadline)
        .foregroundColor(.altimeterBlue)
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
        .accessibilityIdentifier("mb.fullTanks")
        let trip = MassBalanceQuantityField(value: $load.tripLitres, unit: "L",
                                            alternative: load.tripLitres.flatMap { MassBalanceWords.fuel(litres: $0, data.units) },
                                            label: L10n.MassBalance.rowTrip, identifier: "mb.trip")

        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 16) { fuelBlock(fuel, full); tripBlock(trip) }
                VStack(alignment: .leading, spacing: 10) { fuelBlock(fuel, full); tripBlock(trip) }
            }
            Text(tip)
                .scaledFont(size: 15, weight: flagged || result.mostFuelLitres == nil ? .semibold : .regular, relativeTo: .subheadline)
                .foregroundColor(flagged || result.mostFuelLitres == nil ? .aviationRed : .altimeterBlue)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fuelBlock(_ fuel: MassBalanceQuantityField, _ full: some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(L10n.MassBalance.rowFuel), \(L10n.MassBalance.rowFuelStart)")
                .scaledFont(size: 15, relativeTo: .subheadline)
                .foregroundColor(.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { fuel; full }
        }
    }

    private func tripBlock(_ trip: MassBalanceQuantityField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.MassBalance.rowTrip)
                .scaledFont(size: 15, relativeTo: .subheadline)
                .foregroundColor(.secondaryText)
            trip
        }
    }

    /// What the pilot asks on the apron when a third person turns up: how much fuel can I take?
    private var tip: String {
        if let failure = result.failures.first(where: { $0.stationOrSeatId == MassBalanceResult.fuelRowId }) {
            return MassBalanceWords.failure(failure, in: data)
        }
        guard let most = result.mostFuelLitres else { return L10n.MassBalance.tipNone }
        let usable = (data.usableFuelLitres ?? 0).rounded(.down)
        return most < usable ? L10n.MassBalance.tipMost(Int(most)) : L10n.MassBalance.tipFull(Int(usable))
    }
}

/// The failures of one row, under it: a limit passed shows where it was passed.
private struct MassBalanceRowFlags: View {
    let ids: [String]
    let data: AircraftMassBalance
    let result: MassBalanceResult

    var body: some View {
        let failures = result.failures.filter { failure in failure.stationOrSeatId.map(ids.contains) ?? false }
        ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
            Label(MassBalanceWords.failure(failure, in: data), systemImage: "exclamationmark.triangle.fill")
                .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                .foregroundColor(.aviationRed)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MassBalanceBaggageControl: View {
    let station: AircraftMassBalance.Station
    let data: AircraftMassBalance
    let result: MassBalanceResult
    @Binding var load: MassBalanceLoad

    var body: some View {
        let kilograms = Binding<Double?>(get: { load.baggageKg[station.id] }, set: { load.baggageKg[station.id] = $0 })
        let flagged = result.failures.contains { $0.stationOrSeatId == station.id }
        MassBalanceQuantityField(
            value: kilograms, unit: "kg",
            alternative: data.units.mass == .kg ? nil : load.baggageKg[station.id].map {
                "\(MassBalanceWords.plain($0 * data.units.mass.perKilogram, decimals: 0)) \(data.units.mass.rawValue)"
            },
            flagged: flagged, label: MassBalanceWords.rowName(station, in: data), identifier: "mb.baggage.\(station.id)")
    }
}

private func stationCaption(_ station: AircraftMassBalance.Station, _ data: AircraftMassBalance) -> String {
    var parts = [L10n.MassBalance.rowArm(MassBalanceWords.arm(station.arm, data.units))]
    if station.kind == .baggage, let maximum = station.max {
        parts.append(L10n.MassBalance.rowAtMost(MassBalanceWords.mass(maximum, data.units, withKilograms: false)))
    }
    return parts.joined(separator: " · ")
}

private struct MassBalanceEmptyLine: View {
    let data: AircraftMassBalance
    let empty: AircraftMassBalance.EmptyMass?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.MassBalance.rowEmpty)
                    .scaledFont(size: 17, relativeTo: .body)
                    .foregroundColor(.primaryText)
                if let empty {
                    Text(L10n.MassBalance.rowRecordOf(MassBalanceWords.day(empty.date)))
                        .scaledFont(size: 14, relativeTo: .footnote)
                        .foregroundColor(.dimText)
                }
            }
            Spacer(minLength: 8)
            Text(empty.map { MassBalanceWords.mass($0.mass, data.units) } ?? "—")
                .scaledFont(size: 20, design: .monospaced, relativeTo: .title3)
                .foregroundColor(.secondaryText)
        }
    }
}

// MARK: - The load sheet (iPhone)

struct MassBalanceLoadRows: View {
    let data: AircraftMassBalance
    let empty: AircraftMassBalance.EmptyMass?
    let result: MassBalanceResult
    @Binding var load: MassBalanceLoad

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MassBalanceEmptyLine(data: data, empty: empty).padding(14)
            ForEach(data.stations.filter { $0.kind != .fuel }) { station in
                Divider().overlay(Color.white.opacity(0.06))
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MassBalanceWords.rowName(station, in: data))
                            .scaledFont(size: 17, relativeTo: .body)
                            .foregroundColor(.primaryText)
                        Text(stationCaption(station, data))
                            .scaledFont(size: 14, relativeTo: .footnote)
                            .foregroundColor(.dimText)
                    }
                    if station.kind == .seats {
                        ForEach(station.seats ?? []) { seat in
                            MassBalanceSeatControl(seat: seat, data: data,
                                                   flagged: result.failures.contains { $0.stationOrSeatId == seat.id },
                                                   load: $load)
                        }
                        MassBalanceRowFlags(ids: (station.seats ?? []).map(\.id), data: data, result: result)
                    } else {
                        MassBalanceBaggageControl(station: station, data: data, result: result, load: $load)
                        MassBalanceRowFlags(ids: [station.id], data: data, result: result)
                    }
                }
                .padding(14)
            }
            Divider().overlay(Color.white.opacity(0.06))
            MassBalanceFuelControls(data: data, result: result, load: $load).padding(14)
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.cardBackground))
    }
}

// MARK: - The seat plan (iPad)

/// The cabin from above, drawn from the data's stations: rows side by side or in tandem, the baggage
/// behind them, the fuel under it. No artwork per type.
struct MassBalanceSeatPlan: View {
    let data: AircraftMassBalance
    let empty: AircraftMassBalance.EmptyMass?
    let result: MassBalanceResult
    @Binding var load: MassBalanceLoad

    var body: some View {
        VStack(spacing: 14) {
            Label(L10n.MassBalance.rowFrontSeats, systemImage: "arrowtriangle.up.fill")
                .labelStyle(.iconOnly)
                .scaledFont(size: 13, relativeTo: .caption)
                .foregroundColor(.dimText)
                .accessibilityHidden(true)
            VStack(spacing: 14) {
                ForEach(data.stations.filter { $0.kind != .fuel }) { station in
                    if station.kind == .seats {
                        let seats = station.seats ?? []
                        let layout = station.layout == .tandem ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                        layout {
                            ForEach(seats) { seat in
                                MassBalanceSeatControl(seat: seat, data: data,
                                                       flagged: result.failures.contains { $0.stationOrSeatId == seat.id },
                                                       load: $load, vertical: true)
                                    .padding(12)
                                    .frame(maxWidth: .infinity)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.panelBackground.opacity(0.6)))
                            }
                        }
                        MassBalanceRowFlags(ids: seats.map(\.id), data: data, result: result)
                    } else {
                        VStack(spacing: 6) {
                            Text("\(MassBalanceWords.rowName(station, in: data)) · \(stationCaption(station, data))")
                                .scaledFont(size: 15, relativeTo: .subheadline)
                                .foregroundColor(.secondaryText)
                                .multilineTextAlignment(.center)
                            MassBalanceBaggageControl(station: station, data: data, result: result, load: $load)
                            MassBalanceRowFlags(ids: [station.id], data: data, result: result)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.panelBackground.opacity(0.6)))
                    }
                }
            }
            .padding(.top, 34)
            .padding([.horizontal, .bottom], 18)
            .frame(maxWidth: 520)
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 110, bottomLeadingRadius: 26, bottomTrailingRadius: 26, topTrailingRadius: 110)
                .strokeBorder(Color.dimText.opacity(0.7), lineWidth: 2))

            MassBalanceFuelControls(data: data, result: result, load: $load)
                .frame(maxWidth: 620, alignment: .leading)
            MassBalanceEmptyLine(data: data, empty: empty)
                .frame(maxWidth: 620)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.cardBackground))
    }
}

// MARK: - The same load, as the handbook's form (iPad)

/// The load in the handbook's order and units, with the moments: what is held against the paper form.
struct MassBalanceLoadTable: View {
    let data: AircraftMassBalance
    let empty: AircraftMassBalance.EmptyMass?
    let result: MassBalanceResult
    let load: MassBalanceLoad

    private struct Row: Identifiable {
        let id: Int
        let name: String
        let mass: Double?
        let arm: Double?
        var emphasis: Emphasis = .plain
        enum Emphasis { case plain, sub, total }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        let perKg = data.units.mass.perKilogram
        func add(_ name: String, _ mass: Double?, _ arm: Double?, _ emphasis: Row.Emphasis = .plain) {
            rows.append(Row(id: rows.count, name: name, mass: mass, arm: arm, emphasis: emphasis))
        }
        add(L10n.MassBalance.rowEmpty, empty?.mass, empty?.arm)
        for station in data.stations {
            switch station.kind {
            case .seats:
                var total: Double? = 0
                for seat in station.seats ?? [] {
                    switch load.seats[seat.id] ?? .unset {
                    case .person(let kg): total = total.map { $0 + kg * perKg }
                    case .empty: break
                    case .unset: total = nil
                    }
                }
                add(MassBalanceWords.rowName(station, in: data), total, station.arm)
            case .baggage:
                add(MassBalanceWords.rowName(station, in: data), load.baggageKg[station.id].map { $0 * perKg }, station.arm)
            case .fuel:
                break
            }
        }
        if let none = result.emptyTanks { add(L10n.MassBalance.tableNoFuel, none.mass, none.arm, .sub) }
        if let fuel = data.fuelStation, let density = fuel.density {
            add(L10n.MassBalance.rowFuel, load.fuelLitres.map { $0 * data.units.fuel.perLitre * density }, fuel.arm)
            if let taxi = data.limits.taxiFuel, taxi > 0 { add(L10n.MassBalance.tableTaxi, -taxi, fuel.arm) }
        }
        if let takeoff = result.takeoff { add(L10n.MassBalance.pointTakeoff, takeoff.mass, takeoff.arm, .total) }
        if let landing = result.landing { add(L10n.MassBalance.pointLanding, landing.mass, landing.arm, .sub) }
        return rows
    }

    var body: some View {
        let units = data.units
        Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 0) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                header(L10n.MassBalance.chartMassAxis(MassBalanceWords.massUnit(units)))
                header(L10n.MassBalance.tableArm(MassBalanceWords.armUnit(units)))
                header("\(L10n.MassBalance.tableMoment), \(MassBalanceWords.massUnit(units))·\(MassBalanceWords.armUnit(units))")
            }
            .padding(.vertical, 8)
            ForEach(rows) { row in
                Divider().overlay(Color.white.opacity(0.06))
                GridRow {
                    Text(row.name)
                        .scaledFont(size: 16, weight: row.emphasis == .total ? .bold : .regular, relativeTo: .callout)
                        .foregroundColor(colour(row))
                        .fixedSize(horizontal: false, vertical: true)
                    cell(row.mass.map { MassBalanceWords.massFigure($0, units) }, row)
                    cell(row.arm.map { MassBalanceWords.armFigure($0, units) }, row)
                    cell(row.mass.flatMap { mass in row.arm.map { MassBalanceWords.momentFigure(mass * $0, units) } }, row)
                }
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.cardBackground))
    }

    private func colour(_ row: Row) -> Color {
        switch row.emphasis {
        case .plain: return .primaryText
        case .sub: return .secondaryText
        case .total: return .aviationGold
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 13, relativeTo: .caption)
            .foregroundColor(.dimText)
    }

    private func cell(_ text: String?, _ row: Row) -> some View {
        Text(text ?? "—")
            .scaledFont(size: 18, weight: row.emphasis == .total ? .bold : .regular, design: .monospaced, relativeTo: .body)
            .foregroundColor(colour(row))
    }
}
