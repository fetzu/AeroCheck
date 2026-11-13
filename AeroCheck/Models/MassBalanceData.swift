import Foundation

// MARK: - Mass and balance data (6.11.0)
//
// What the mass and balance sheet computes with, for ONE registration: the limits, the envelope of
// each category, the stations with their arms and the usable fuel. It comes from the server, one
// file per registration, or from the pilot's own entry for an aircraft the server has no file for.
//
// Per registration, never per type. Two aircraft of one type differ in tanks, modifications and the
// approval they fly under, and a plausible envelope of the wrong one is the error a pilot cannot see
// on a chart. So nothing here is ever looked up by type, and a registration without data gets the
// pilot's own figures, never a sibling's.
//
// Every figure is in the file's own `units`, as its source gives it. The arithmetic runs in those
// units; only what the pilot types (kg and litres) is converted, once, on the way in.

/// Units a file can be written in. Strict on purpose: a unit this build does not know fails the
/// decode, and the aircraft then works with the pilot's own figures rather than with a guess.
enum MassBalanceMassUnit: String, Codable, Sendable {
    case kg, lb

    /// Kilograms to this unit.
    var perKilogram: Double { self == .kg ? 1 : 2.2046226218 }
}

enum MassBalanceArmUnit: String, Codable, Sendable {
    case m, mm, inch = "in"
}

enum MassBalanceFuelUnit: String, Codable, Sendable {
    case litre = "l", usGallon = "usgal"

    /// Litres to this unit.
    var perLitre: Double { self == .litre ? 1 : 1 / 3.785411784 }
}

/// One corner of an envelope: an arm and a mass, written `[arm, mass]` in the file.
struct MassBalanceCorner: Codable, Equatable, Sendable {
    var arm: Double
    var mass: Double

    init(arm: Double, mass: Double) {
        self.arm = arm
        self.mass = mass
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        arm = try container.decode(Double.self)
        mass = try container.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(arm)
        try container.encode(mass)
    }
}

struct AircraftMassBalance: Codable, Equatable, Sendable {

    struct Identity: Codable, Equatable, Sendable {
        var designation: String
        var serialNumber: String
        var handbook: String?
    }

    struct Units: Codable, Equatable, Sendable {
        var mass: MassBalanceMassUnit
        var arm: MassBalanceArmUnit
        var fuel: MassBalanceFuelUnit
    }

    struct Limits: Codable, Equatable, Sendable {
        var maxTakeoff: Double
        var maxLanding: Double?
        var maxRamp: Double?
        var minFlying: Double?
        /// Fuel for start, taxi and run-up: the difference between ramp and take-off mass.
        var taxiFuel: Double?
    }

    struct Category: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var maxTakeoff: Double
        var maxRamp: Double?
        var envelope: [MassBalanceCorner]
        /// The station ids this category allows a load on; nil allows them all.
        var only: [String]?
    }

    enum StationKind: String, Codable, Sendable {
        case seats, baggage, fuel
    }

    enum SeatLayout: String, Codable, Sendable {
        case sideBySide = "side-by-side", tandem, single
    }

    enum SeatRole: String, Codable, Sendable {
        case pilot, passenger
    }

    struct Seat: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var role: SeatRole
        /// In the file's mass unit.
        var min: Double?
        var max: Double?
    }

    struct Station: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var kind: StationKind
        var arm: Double
        // Seats
        var layout: SeatLayout?
        var seats: [Seat]?
        // Baggage (in the file's mass unit)
        var max: Double?
        var note: [String: String]?
        // Fuel: usable in the file's fuel unit, density in mass unit per fuel unit
        var usable: Double?
        var density: Double?
    }

    struct EmptyCheck: Codable, Equatable, Sendable {
        /// The handbook's range for the empty aircraft's CG, forward first.
        var cgRange: [Double]?
        var maxMass: Double?
    }

    /// The empty aircraft as its record writes it: a mass and a MOMENT, with the date of the line.
    struct EmptyMass: Codable, Equatable, Sendable {
        var mass: Double
        var moment: Double
        /// `YYYY-MM-DD`, the date of the record's line.
        var date: String
        /// "weighed" or "calculated"; kept as text so a word this build doesn't know still decodes.
        var entry: String?
    }

    struct Source: Codable, Equatable, Sendable {
        var what: String
        var document: String
        var revision: String?
        var date: String?
        var sections: String?
    }

    var schema: Int
    var aircraftId: String
    var registration: String
    var revision: Int
    var updated: String
    var identity: Identity?
    var units: Units
    var datum: [String: String]?
    var limits: Limits
    var categories: [Category]
    var stations: [Station]
    var emptyCheck: EmptyCheck?
    var handbookChecks: [String]?
    var empty: EmptyMass?
    var sources: [Source]?

    /// The schema this build reads. A file of a later schema is left alone.
    static let supportedSchema = 1

    /// The category the sheet checks: the first one listed.
    var mainCategory: Category? { categories.first }

    var fuelStation: Station? { stations.first { $0.kind == .fuel } }

    var seatStations: [Station] { stations.filter { $0.kind == .seats } }

    var baggageStations: [Station] { stations.filter { $0.kind == .baggage } }

    /// Usable fuel with full tanks, in litres.
    var usableFuelLitres: Double? {
        guard let usable = fuelStation?.usable, usable > 0 else { return nil }
        return usable / units.fuel.perLitre
    }

    /// Whether the sheet can compute with this file at all. The server's validator holds the files
    /// to much more; this is the floor below which the arithmetic would be meaningless, and it also
    /// guards the pilot's own entry.
    var isUsable: Bool {
        guard schema == Self.supportedSchema, let main = mainCategory else { return false }
        guard categories.allSatisfy({ $0.envelope.count >= 3 && $0.maxTakeoff > 0 }) else { return false }
        guard main.envelope.allSatisfy({ $0.arm.isFinite && $0.mass.isFinite }) else { return false }
        guard let fuel = fuelStation, let usable = fuel.usable, usable > 0,
              let density = fuel.density, density > 0 else { return false }
        guard stations.allSatisfy({ $0.arm.isFinite }) else { return false }
        guard seatStations.contains(where: { ($0.seats ?? []).contains { $0.role == .pilot } }) else { return false }
        return true
    }
}

extension AircraftMassBalance.EmptyMass {
    /// The CG the record's mass and moment give.
    var arm: Double? { mass > 0 ? moment / mass : nil }

    /// Whether that CG can be right for this aircraft: inside the handbook's range for the empty
    /// aircraft when the file gives one, otherwise within one envelope-width of the envelope.
    ///
    /// A record's column is often the moment divided by 100 or 1000, and a moment typed as written
    /// then gives a CG a hundred times too far forward. This is what lets the entry screen say so.
    func isPlausible(for data: AircraftMassBalance) -> Bool {
        guard let arm, mass > 0, mass.isFinite, moment.isFinite else { return false }
        if let range = data.emptyCheck?.cgRange, range.count == 2 {
            return arm >= range[0] && arm <= range[1]
        }
        let arms = data.categories.flatMap { $0.envelope.map(\.arm) }
        guard let low = arms.min(), let high = arms.max(), high > low else { return false }
        let width = high - low
        return arm >= low - width && arm <= high + width
    }
}
