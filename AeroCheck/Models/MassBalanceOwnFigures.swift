import Foundation

// MARK: - The pilot's own figures (6.11.0)
//
// For an aircraft the app has no data for, or whose data the pilot said isn't the aircraft's: the
// pilot types what the flight manual and the mass and balance record say, once, in the manual's own
// units. The result is the same `AircraftMassBalance` the server's files decode into, so the sheet,
// the chart and the arithmetic don't know the difference; the sheet names the source as "your
// figures", and nothing here is ever checked against anything but itself.
//
// A draft is what is being typed. It becomes data only when nothing is missing: a figure left blank
// is never read as zero.

struct MassBalanceOwnDraft: Equatable {

    struct SeatRow: Identifiable, Equatable {
        var id = UUID()
        var arm: Double?
        /// One or two seats.
        var seats: Int = 2
    }

    struct Baggage: Identifiable, Equatable {
        var id = UUID()
        var arm: Double?
        var max: Double?
    }

    struct Corner: Identifiable, Equatable {
        var id = UUID()
        var arm: Double?
        var mass: Double?
    }

    var units = AircraftMassBalance.Units(mass: .kg, arm: .m, fuel: .litre)
    var maxTakeoff: Double?
    /// Front to back. Three at most.
    var rows: [SeatRow] = [SeatRow()]
    /// Which row the pilot sits in (0 is the front one): the rear seat on some tandem types.
    var pilotRow = 0
    var baggage: [Baggage] = []
    var fuelArm: Double?
    /// In the fuel unit.
    var fuelUsable: Double?
    /// Typed in kilograms per litre whatever the units, as fuel densities are quoted.
    var fuelDensityKgPerLitre: Double? = MassBalanceOwnDraft.avgasKgPerLitre
    var corners: [Corner] = [Corner(), Corner(), Corner(), Corner()]
    var emptyMass: Double?
    var emptyMoment: Double?
    var emptyDate = Date()

    static let avgasKgPerLitre = 0.72
    static let maximumRows = 3
    static let maximumBaggageAreas = 3
    /// The registry id of figures no file stands behind.
    static let aircraftId = "own"

    /// What still keeps the draft from being data, in the order of the form.
    enum Missing: Equatable {
        case maxTakeoff
        case seatArm(row: Int)
        case baggage(area: Int)
        case fuel
        case envelope
        case empty
        /// The moment and the mass give a CG far from the envelope: the record's column is often
        /// the moment divided by 100 or 1000.
        case emptyImplausible
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// The corners that are whole, in the order typed.
    var enteredCorners: [MassBalanceCorner] {
        corners.compactMap { corner in
            guard let arm = Self.finite(corner.arm), let mass = Self.positive(corner.mass) else { return nil }
            return MassBalanceCorner(arm: arm, mass: mass)
        }
    }

    var missing: [Missing] {
        var missing: [Missing] = []
        if Self.positive(maxTakeoff) == nil { missing.append(.maxTakeoff) }
        for (index, row) in rows.enumerated() where Self.finite(row.arm) == nil { missing.append(.seatArm(row: index + 1)) }
        for (index, area) in baggage.enumerated() where Self.finite(area.arm) == nil || Self.positive(area.max) == nil {
            missing.append(.baggage(area: index + 1))
        }
        if Self.finite(fuelArm) == nil || Self.positive(fuelUsable) == nil || Self.positive(fuelDensityKgPerLitre) == nil {
            missing.append(.fuel)
        }
        // Every row of the envelope is whole or blank, and three whole ones make a shape.
        let half = corners.contains { ($0.arm == nil) != ($0.mass == nil) }
        if half || enteredCorners.count < 3 { missing.append(.envelope) }
        if Self.positive(emptyMass) == nil || Self.finite(emptyMoment) == nil {
            missing.append(.empty)
        } else if missing.isEmpty, let data = data(registration: "X"), let empty = empty(), !empty.isPlausible(for: data) {
            missing.append(.emptyImplausible)
        }
        return missing
    }

    /// The record's line as typed, or nil while it isn't whole.
    func empty() -> AircraftMassBalance.EmptyMass? {
        guard let mass = Self.positive(emptyMass), let moment = Self.finite(emptyMoment) else { return nil }
        return .init(mass: mass, moment: moment, date: Self.day(emptyDate), entry: nil)
    }

    private static func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }

    /// The figures as the data the sheet computes with, or nil while a limit, a station or the
    /// envelope is missing. The empty mass is asked for separately (`empty()`): the data stands
    /// without it, and the sheet then says it has none.
    func data(registration: String, updated: Date = Date()) -> AircraftMassBalance? {
        guard let maxTakeoff = Self.positive(maxTakeoff),
              let fuelArm = Self.finite(fuelArm), let fuelUsable = Self.positive(fuelUsable),
              let density = Self.positive(fuelDensityKgPerLitre) else { return nil }
        let envelope = enteredCorners
        guard envelope.count >= 3, !corners.contains(where: { ($0.arm == nil) != ($0.mass == nil) }) else { return nil }

        var stations: [AircraftMassBalance.Station] = []
        let pilot = min(max(pilotRow, 0), rows.count - 1)
        for (index, row) in rows.enumerated() {
            guard let arm = Self.finite(row.arm) else { return nil }
            let count = min(max(row.seats, 1), 2)
            let seats = (0..<count).map { position in
                AircraftMassBalance.Seat(id: "row\(index + 1)seat\(position + 1)",
                                         role: index == pilot && position == 0 ? .pilot : .passenger)
            }
            stations.append(.init(id: "row\(index + 1)", kind: .seats, arm: arm,
                                  layout: count == 2 ? .sideBySide : (rows.count > 1 ? .tandem : .single), seats: seats))
        }
        for (index, area) in baggage.enumerated() {
            guard let arm = Self.finite(area.arm), let max = Self.positive(area.max) else { return nil }
            stations.append(.init(id: "baggage\(index + 1)", kind: .baggage, arm: arm, max: max))
        }
        // Density in the data's own units: mass unit per fuel unit.
        let fileDensity = density * units.mass.perKilogram / units.fuel.perLitre
        stations.append(.init(id: "fuel", kind: .fuel, arm: fuelArm, usable: fuelUsable, density: fileDensity))

        let data = AircraftMassBalance(
            schema: AircraftMassBalance.supportedSchema, aircraftId: Self.aircraftId,
            registration: MassBalanceSettings.key(for: registration), revision: 0, updated: Self.day(updated),
            identity: nil, units: units, datum: nil, limits: .init(maxTakeoff: maxTakeoff),
            categories: [.init(id: "normal", maxTakeoff: maxTakeoff, envelope: envelope)],
            stations: stations, emptyCheck: nil, handbookChecks: nil, empty: empty(), sources: nil)
        return data.isUsable ? data : nil
    }

    /// The envelope alone, for the form's drawing while the rest is still being typed.
    func envelopePreview() -> AircraftMassBalance? {
        let envelope = enteredCorners
        guard envelope.count >= 3 else { return nil }
        let top = envelope.map(\.mass).max() ?? 1
        return AircraftMassBalance(
            schema: AircraftMassBalance.supportedSchema, aircraftId: Self.aircraftId, registration: "", revision: 0,
            updated: "", identity: nil, units: units, datum: nil, limits: .init(maxTakeoff: top),
            categories: [.init(id: "normal", maxTakeoff: top, envelope: envelope)], stations: [], emptyCheck: nil,
            handbookChecks: nil, empty: nil, sources: nil)
    }
}

extension MassBalanceOwnDraft {

    /// To change figures typed before: the draft they came from.
    init(data: AircraftMassBalance, empty: AircraftMassBalance.EmptyMass?) {
        units = data.units
        maxTakeoff = data.mainCategory?.maxTakeoff ?? data.limits.maxTakeoff
        let seatRows = data.seatStations
        rows = seatRows.isEmpty ? [SeatRow()] : seatRows.prefix(Self.maximumRows).map { SeatRow(arm: $0.arm, seats: min(max($0.seats?.count ?? 1, 1), 2)) }
        pilotRow = seatRows.firstIndex { ($0.seats ?? []).contains { $0.role == .pilot } } ?? 0
        baggage = data.baggageStations.prefix(Self.maximumBaggageAreas).map { Baggage(arm: $0.arm, max: $0.max) }
        if let fuel = data.fuelStation {
            fuelArm = fuel.arm
            fuelUsable = fuel.usable
            fuelDensityKgPerLitre = fuel.density.map { ($0 * data.units.fuel.perLitre / data.units.mass.perKilogram * 1000).rounded() / 1000 }
        }
        corners = (data.mainCategory?.envelope ?? []).map { Corner(arm: $0.arm, mass: $0.mass) }
        while corners.count < 3 { corners.append(Corner()) }
        if let empty {
            emptyMass = empty.mass
            emptyMoment = empty.moment
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withFullDate]
            emptyDate = parser.date(from: empty.date) ?? Date()
        }
    }

    /// What the 5.0.0 calculator's figures give without a guess: kilograms and metres, the maximum
    /// mass, the envelope, the empty aircraft (its moment is its mass times its arm) and the arm of
    /// the station the pilot marked as fuel. Its other stations have a name and an arm but no kind:
    /// which is a seat row and which a baggage area is the pilot's to say, so they are not taken.
    init(profile: WeightBalanceProfile) {
        if profile.maxTakeoffWeightKg > 0 { maxTakeoff = profile.maxTakeoffWeightKg }
        if let envelope = profile.envelope, envelope.count >= 3 {
            corners = envelope.map { Corner(arm: $0.armMeters, mass: $0.weightKg) }
        }
        if profile.emptyWeightKg > 0 {
            emptyMass = profile.emptyWeightKg
            emptyMoment = ((profile.emptyWeightKg * profile.emptyArmMeters) * 100).rounded() / 100
        }
        if let fuel = profile.stations.first(where: { $0.id == profile.fuelStationId }) { fuelArm = fuel.armMeters }
    }
}
