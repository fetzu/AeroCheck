import Foundation

// MARK: - The words and figures of the mass and balance sheet (6.11.0)
//
// The arithmetic gives states and numbers; this turns them into what the pilot reads. Every figure is
// written in the data's own units, with kilograms beside a mass in pounds: the pilot types kg and
// litres, and holds the result against a handbook that may be in pounds and inches.

enum MassBalanceWords {

    // MARK: Figures

    /// A mass in the data's unit: "456.0 kg", or "2441 lb (1107 kg)".
    static func mass(_ value: Double, _ units: AircraftMassBalance.Units, withKilograms: Bool = true) -> String {
        switch units.mass {
        case .kg:
            return "\(plain(value, decimals: 1)) kg"
        case .lb:
            let pounds = "\(plain(value, decimals: 0)) lb"
            return withKilograms ? "\(pounds) (\(plain(value / units.mass.perKilogram, decimals: 0)) kg)" : pounds
        }
    }

    /// A mass with no unit, for a table's cell.
    static func massFigure(_ value: Double, _ units: AircraftMassBalance.Units) -> String {
        plain(value, decimals: units.mass == .kg ? 1 : 0)
    }

    static func massUnit(_ units: AircraftMassBalance.Units) -> String { units.mass.rawValue }

    static func armUnit(_ units: AircraftMassBalance.Units) -> String { units.arm.rawValue }

    /// An arm in the data's unit: "2.728 m", "90.4 in", "2728 mm".
    static func arm(_ value: Double, _ units: AircraftMassBalance.Units) -> String {
        "\(armFigure(value, units)) \(units.arm.rawValue)"
    }

    static func armFigure(_ value: Double, _ units: AircraftMassBalance.Units) -> String {
        switch units.arm {
        case .m: return plain(value, decimals: 3)
        case .mm: return plain(value, decimals: 0)
        case .inch: return plain(value, decimals: 1)
        }
    }

    static func momentFigure(_ value: Double, _ units: AircraftMassBalance.Units) -> String {
        plain(value, decimals: units.arm == .m ? 2 : 0)
    }

    /// A distance between a CG and a limit: centimetres for a handbook in metres or millimetres,
    /// inches otherwise.
    static func gap(_ value: Double, _ units: AircraftMassBalance.Units) -> String {
        switch units.arm {
        case .m: return "\(plain(abs(value) * 100, decimals: 1)) cm"
        case .mm: return "\(plain(abs(value) / 10, decimals: 1)) cm"
        case .inch: return "\(plain(abs(value), decimals: 1)) in"
        }
    }

    /// A quantity of fuel in the data's unit, beside the litres typed: "40.0 US gal".
    static func fuel(litres: Double, _ units: AircraftMassBalance.Units) -> String? {
        switch units.fuel {
        case .litre: return nil
        case .usGallon: return "\(plain(litres * units.fuel.perLitre, decimals: 1)) US gal"
        }
    }

    static func fuelCapacity(_ value: Double, _ units: AircraftMassBalance.Units) -> String {
        switch units.fuel {
        case .litre: return "\(plain(value, decimals: 0)) L"
        case .usGallon: return "\(plain(value, decimals: 0)) US gal"
        }
    }

    /// A plain figure: no grouping, a point for the decimals, as a handbook prints it.
    static func plain(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// `YYYY-MM-DD` as the pilot's region writes a date; the text itself when it isn't one.
    static func day(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    // MARK: Names

    /// What a seat is called, from where it sits: the data has no display text of its own.
    static func seatName(_ seat: AircraftMassBalance.Seat, in data: AircraftMassBalance) -> String {
        let rows = data.seatStations
        guard let rowIndex = rows.firstIndex(where: { ($0.seats ?? []).contains { $0.id == seat.id } }) else {
            return L10n.MassBalance.seatPassenger
        }
        let row = rows[rowIndex]
        let seats = row.seats ?? []
        let position = seats.firstIndex { $0.id == seat.id } ?? 0
        if seat.role == .pilot { return L10n.MassBalance.seatPilot }
        if rowIndex == 0 { return rows.count > 1 ? L10n.MassBalance.seatFrontPassenger : L10n.MassBalance.seatPassenger }
        if rowIndex == 1 {
            if seats.count == 1 { return L10n.MassBalance.seatRear }
            if seats.count == 2 { return position == 0 ? L10n.MassBalance.seatRearLeft : L10n.MassBalance.seatRearRight }
        }
        return L10n.MassBalance.seatRow(rowIndex + 1, position + 1)
    }

    static func rowName(_ station: AircraftMassBalance.Station, in data: AircraftMassBalance) -> String {
        switch station.kind {
        case .fuel:
            return L10n.MassBalance.rowFuel
        case .baggage:
            let areas = data.baggageStations
            guard areas.count > 1, let index = areas.firstIndex(where: { $0.id == station.id }) else {
                return L10n.MassBalance.rowBaggage
            }
            return L10n.MassBalance.rowBaggageN(index + 1)
        case .seats:
            let rows = data.seatStations
            guard rows.count > 1, let index = rows.firstIndex(where: { $0.id == station.id }) else {
                return L10n.MassBalance.rowSeats
            }
            if index == 0 { return L10n.MassBalance.rowFrontSeats }
            if index == 1, rows.count == 2 { return L10n.MassBalance.rowRearSeats }
            return L10n.MassBalance.rowSeatRow(index + 1)
        }
    }

    /// The name of a seat id, a baggage station id or the fuel row, as `MassBalanceResult.unset` lists them.
    static func name(ofId id: String, in data: AircraftMassBalance) -> String {
        if id == MassBalanceResult.fuelRowId { return L10n.MassBalance.rowFuel }
        for station in data.stations {
            if station.id == id { return rowName(station, in: data) }
            if let seat = station.seats?.first(where: { $0.id == id }) { return seatName(seat, in: data) }
        }
        return id
    }

    static func category(_ id: String) -> String {
        switch id {
        case "normal": return L10n.MassBalance.catNormal
        case "utility": return L10n.MassBalance.catUtility
        case "aerobatic": return L10n.MassBalance.catAerobatic
        default: return id
        }
    }

    // MARK: The verdict

    static func title(_ verdict: MassBalanceVerdict) -> String {
        switch verdict {
        case .insideLimits: return L10n.MassBalance.verdictInside
        case .outsideLimits: return L10n.MassBalance.verdictOutside
        case .incomplete: return L10n.MassBalance.verdictIncomplete
        case .notConfirmed: return L10n.MassBalance.verdictNotConfirmed
        case .lastTimesLoad: return L10n.MassBalance.verdictLastTime
        }
    }

    /// The shape that goes with a verdict, so that nothing depends on its colour.
    static func symbol(_ verdict: MassBalanceVerdict) -> String {
        switch verdict {
        case .insideLimits: return "checkmark"
        case .outsideLimits: return "xmark"
        case .incomplete: return "ellipsis"
        case .notConfirmed: return "questionmark"
        case .lastTimesLoad: return "arrow.counterclockwise"
        }
    }

    // MARK: A flight's state, in one line

    /// The sheet's last state for a flight, with the sheet's time where it gave a verdict.
    static func stateLine(_ state: MassBalanceFlightState, now: Date = Date(), calendar: Calendar = .current) -> String {
        func time(_ date: Date) -> String {
            calendar.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened)
                                                    : date.formatted(date: .abbreviated, time: .shortened)
        }
        switch state {
        case .notDone: return L10n.MassBalance.stateNotDone
        case .lastTimesLoad: return L10n.MassBalance.stateLastTime
        case .incomplete: return L10n.MassBalance.stateIncomplete
        case .notConfirmed: return L10n.MassBalance.stateNotConfirmed
        case .outsideLimits(let at): return L10n.MassBalance.stateOutside(time(at))
        case .insideLimits(let at): return L10n.MassBalance.stateInside(time(at))
        }
    }

    /// The same shapes as the sheet's verdicts, and a plain ring for a sheet not started.
    static func stateSymbol(_ state: MassBalanceFlightState) -> String {
        switch state {
        case .notDone: return "circle.dashed"
        case .lastTimesLoad: return symbol(.lastTimesLoad)
        case .incomplete: return symbol(.incomplete)
        case .notConfirmed: return symbol(.notConfirmed)
        case .outsideLimits: return symbol(.outsideLimits)
        case .insideLimits: return symbol(.insideLimits)
        }
    }

    static func why(_ reason: MassBalanceOutside) -> String {
        switch reason {
        case .overMaximumMass: return L10n.MassBalance.whyOverMax
        case .underMinimumMass: return L10n.MassBalance.whyUnderMin
        case .aheadOfForwardLimit: return L10n.MassBalance.whyForward
        case .behindAftLimit: return L10n.MassBalance.whyAft
        }
    }

    static func failure(_ failure: MassBalanceFailure, in data: AircraftMassBalance) -> String {
        let units = data.units
        switch failure {
        case .overMaxRamp(let by):
            return L10n.MassBalance.failOverRamp(mass(by, units))
        case .overMaxTakeoff(let by):
            return L10n.MassBalance.failOverMTOM(mass(by, units))
        case .takeoffOutside(let reason):
            return L10n.MassBalance.failTakeoff(why(reason))
        case .landingOutside(let reason, let litresLeft):
            return L10n.MassBalance.failLanding(Int(litresLeft.rounded()), why(reason))
        case .seatOverMaximum(let seatId, let maximum):
            return L10n.MassBalance.failSeatMax(name(ofId: seatId, in: data), mass(maximum, units, withKilograms: false))
        case .seatUnderMinimum(let seatId, let minimum):
            return L10n.MassBalance.failSeatMin(name(ofId: seatId, in: data), mass(minimum, units, withKilograms: false))
        case .baggageOverMaximum(let stationId, let maximum):
            return L10n.MassBalance.failBaggageMax(name(ofId: stationId, in: data), mass(maximum, units, withKilograms: false))
        case .fuelOverUsable(let usableLitres):
            return L10n.MassBalance.failFuelMax(Int(usableLitres.rounded()))
        }
    }

    /// The lines under the verdict's title: what is wrong, what is missing, or the margins.
    static func lines(for result: MassBalanceResult, basis: MassBalanceBasis, registration: String,
                      load: MassBalanceLoad) -> [String] {
        let data = basis.data
        switch result.verdict {
        case .outsideLimits:
            return result.failures.prefix(4).map { failure($0, in: data) }
        case .incomplete:
            let names = result.unset.map { name(ofId: $0, in: data) }.joined(separator: ", ")
            return [L10n.MassBalance.lineIncomplete(names), L10n.MassBalance.lineEmptySeat]
        case .notConfirmed:
            if basis.empty == nil { return [L10n.MassBalance.lineNoEmpty(registration)] }
            let first: String
            switch basis.unconfirmed {
            case .dataChanged: first = L10n.MassBalance.lineDataChanged(registration)
            case .yearPassed: first = L10n.MassBalance.lineYearPassed(registration)
            default: first = L10n.MassBalance.lineNotConfirmed(registration)
            }
            return [first, L10n.MassBalance.lineCalculationOnly]
        case .lastTimesLoad:
            var lines: [String] = []
            if let from = load.copiedFrom {
                lines.append(L10n.MassBalance.lineLastTime(from.formatted(date: .abbreviated, time: .omitted)))
            }
            lines.append(L10n.MassBalance.lineLastTimeHow)
            return lines
        case .insideLimits:
            return margins(for: result, data: data)
        }
    }

    /// The margins in words, so nobody reads a distance off a chart.
    static func margins(for result: MassBalanceResult, data: AircraftMassBalance) -> [String] {
        var lines: [String] = []
        if let margin = result.massMargin {
            lines.append(L10n.MassBalance.lineUnderMTOM(mass(margin, data.units)))
        }
        if let limits = result.limitsAtTakeoff, let takeoff = result.takeoff {
            lines.append(L10n.MassBalance.lineCg(gap(takeoff.arm - limits.forward, data.units),
                                                 gap(limits.aft - takeoff.arm, data.units)))
        }
        if let level = result.notBelowLitres, let reason = result.notBelowReason {
            lines.append(L10n.MassBalance.lineNotBelow(Int(level.rounded()), why(reason)))
        }
        if result.landing == nil { lines.append(L10n.MassBalance.lineNoTrip) }
        for note in result.otherCategories {
            let name = category(note.categoryId)
            if note.loadsForbiddenStation { lines.append(L10n.MassBalance.categoryForbidden(name)) }
            else if note.isInside { lines.append(L10n.MassBalance.categoryInside(name)) }
            else { lines.append(L10n.MassBalance.categoryOutside(name)) }
        }
        return lines
    }

    /// What is said of a point: inside or outside, and neither while a row is still to enter. The
    /// figures are then a sum so far, and where the CG ends up is not known.
    static func pointWord(_ point: MassBalancePoint, in result: MassBalanceResult) -> String {
        guard result.isComplete else { return L10n.MassBalance.pointSoFar }
        return point.isInside ? L10n.MassBalance.pointInside : L10n.MassBalance.pointOutside
    }

    /// One sentence per point, for VoiceOver: the chart without sight of it.
    static func spoken(_ result: MassBalanceResult, data: AircraftMassBalance) -> String {
        func sentence(_ name: String, _ point: MassBalancePoint?) -> String? {
            guard let point else { return nil }
            return L10n.MassBalance.chartPoint(name, mass(point.mass, data.units), arm(point.arm, data.units),
                                               pointWord(point, in: result))
        }
        guard result.isComplete else {
            return [L10n.MassBalance.chartLabel, sentence(L10n.MassBalance.chartSoFar, result.takeoff)].compactMap { $0 }.joined(separator: " ")
        }
        return [L10n.MassBalance.chartLabel,
                sentence(L10n.MassBalance.pointTakeoff, result.takeoff),
                sentence(L10n.MassBalance.pointLanding, result.landing),
                sentence(L10n.MassBalance.pointEmptyTanks, result.emptyTanks)].compactMap { $0 }.joined(separator: " ")
    }
}
