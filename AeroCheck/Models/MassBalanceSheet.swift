import Foundation

// MARK: - The mass and balance sheet (6.11.0)
//
// The load of one flight, and what it gives against the aircraft's data: the take-off, landing and
// empty-tanks points, the margins, and one of five states.
//
// The states are ordered, and the order is the point of this file:
//
//   1. outside limits     a limit is passed, whatever else is missing
//   2. incomplete         a seat, the baggage or the fuel is not entered
//   3. not confirmed      the aircraft's data or its empty mass is not confirmed by the pilot
//   4. last time's load   the load comes from an earlier flight and was not said to be today's
//   5. inside limits      everything entered, confirmed, said to be today's, and inside
//
// "Inside limits" is the only state that claims anything, so it is the last one reached. A blank
// seat is unknown, never zero (review F22 of the 5.0.0 calculator); a load carried over from last
// week is not this flight's until the pilot says so; and the app never ticks the task.
//
// The arithmetic runs in the data's own units. The pilot types kilograms and litres.

/// What a seat holds.
enum MassBalanceSeatLoad: Equatable, Sendable {
    /// Not entered: unknown, never zero.
    case unset
    /// Said to be empty.
    case empty
    /// A person, in kilograms, with what they carry.
    case person(kg: Double)
}

extension MassBalanceSeatLoad: Codable {
    private enum CodingKeys: String, CodingKey { case state, kg }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decodeIfPresent(String.self, forKey: .state) ?? "unset"
        let kg = try container.decodeIfPresent(Double.self, forKey: .kg)
        switch (state, kg) {
        case ("person", let kg?) where kg.isFinite && kg >= 0: self = .person(kg: kg)
        case ("empty", _): self = .empty
        default: self = .unset
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unset: try container.encode("unset", forKey: .state)
        case .empty: try container.encode("empty", forKey: .state)
        case .person(let kg):
            try container.encode("person", forKey: .state)
            try container.encode(kg, forKey: .kg)
        }
    }
}

/// The load of one flight, as the pilot types it: kilograms and litres.
struct MassBalanceLoad: Codable, Equatable, Sendable {
    /// By seat id. A seat with no entry is unset.
    var seats: [String: MassBalanceSeatLoad] = [:]
    /// By baggage station id, in kilograms. An area with no entry is unset; 0 is an answer.
    var baggageKg: [String: Double] = [:]
    /// In the tanks at engine start, in litres. Nil is unset.
    var fuelLitres: Double?
    /// What the flight burns between take-off and landing, in litres. Nil draws no landing point.
    var tripLitres: Double?
    /// Whether the pilot said this is today's load. A load copied from an earlier flight starts
    /// false, and no state better than "last time's load" is reached until it is true.
    var isTodays: Bool = false
    /// The day of the flight this load was copied from, when it was.
    var copiedFrom: Date?

    init(seats: [String: MassBalanceSeatLoad] = [:], baggageKg: [String: Double] = [:],
         fuelLitres: Double? = nil, tripLitres: Double? = nil, isTodays: Bool = false, copiedFrom: Date? = nil) {
        self.seats = seats
        self.baggageKg = baggageKg
        self.fuelLitres = fuelLitres
        self.tripLitres = tripLitres
        self.isTodays = isTodays
        self.copiedFrom = copiedFrom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seats = try container.decodeIfPresent([String: MassBalanceSeatLoad].self, forKey: .seats) ?? [:]
        baggageKg = try container.decodeIfPresent([String: Double].self, forKey: .baggageKg) ?? [:]
        fuelLitres = try container.decodeIfPresent(Double.self, forKey: .fuelLitres)
        tripLitres = try container.decodeIfPresent(Double.self, forKey: .tripLitres)
        isTodays = try container.decodeIfPresent(Bool.self, forKey: .isTodays) ?? false
        copiedFrom = try container.decodeIfPresent(Date.self, forKey: .copiedFrom)
    }

    /// Whether nothing is entered: no seat answered, no baggage, no fuel.
    var isBlank: Bool {
        seats.values.allSatisfy { $0 == .unset } && baggageKg.isEmpty && fuelLitres == nil && tripLitres == nil
    }

    /// The same load for another flight: nothing is today's until the pilot says so.
    func carriedOver(from day: Date) -> MassBalanceLoad {
        var copy = self
        copy.isTodays = false
        copy.copiedFrom = day
        return copy
    }
}

enum MassBalanceVerdict: String, Codable, Equatable, Sendable {
    case outsideLimits, incomplete, notConfirmed, lastTimesLoad, insideLimits
}

/// Why a point is outside.
enum MassBalanceOutside: String, Codable, Equatable, Sendable {
    case overMaximumMass, underMinimumMass, aheadOfForwardLimit, behindAftLimit
}

/// A limit that is passed. The view writes the words; the order here is the order shown.
enum MassBalanceFailure: Equatable, Sendable {
    /// By how much, in the data's mass unit.
    case overMaxRamp(by: Double)
    case overMaxTakeoff(by: Double)
    case takeoffOutside(MassBalanceOutside)
    case landingOutside(MassBalanceOutside, litresLeft: Double)
    case seatOverMaximum(seatId: String, maximum: Double)
    case seatUnderMinimum(seatId: String, minimum: Double)
    case baggageOverMaximum(stationId: String, maximum: Double)
    case fuelOverUsable(usableLitres: Double)

    /// The seat or station the failure belongs to, so its row can be marked.
    var stationOrSeatId: String? {
        switch self {
        case .seatOverMaximum(let id, _), .seatUnderMinimum(let id, _), .baggageOverMaximum(let id, _): return id
        case .fuelOverUsable: return MassBalanceResult.fuelRowId
        default: return nil
        }
    }
}

/// One loading condition: a mass and a CG in the data's units.
struct MassBalancePoint: Equatable, Sendable {
    var mass: Double
    var arm: Double
    /// Usable fuel in the tanks at this point, in litres.
    var fuelLitres: Double
    var isInside: Bool
    /// Why not, when it is outside.
    var outside: MassBalanceOutside?
}

/// Whether the take-off point also fits another category (utility, say).
struct MassBalanceCategoryNote: Equatable, Sendable {
    var categoryId: String
    var isInside: Bool
    /// True when a station the category does not allow is loaded (rear seats or baggage in utility).
    var loadsForbiddenStation: Bool
}

struct MassBalanceResult: Equatable, Sendable {
    static let fuelRowId = "fuel"

    var verdict: MassBalanceVerdict
    /// Nil when there is no empty mass to start from.
    var takeoff: MassBalancePoint?
    var landing: MassBalancePoint?
    var emptyTanks: MassBalancePoint?
    /// With the fuel as typed, before the taxi fuel is taken off. Nil where the data has no ramp limit.
    var rampMass: Double?
    var failures: [MassBalanceFailure] = []
    /// Seat ids, baggage station ids and `fuelRowId` that are not entered.
    var unset: [String] = []
    /// Room under the maximum take-off mass, in the data's mass unit (negative when over).
    var massMargin: Double?
    /// The forward and aft limits at the take-off mass.
    var limitsAtTakeoff: (forward: Double, aft: Double)?
    /// The most fuel at engine start this load allows, in whole litres; nil when none fits.
    var mostFuelLitres: Double?
    /// Below this much usable fuel the aircraft leaves the limits; nil when it never does.
    var notBelowLitres: Double?
    var notBelowReason: MassBalanceOutside?
    var otherCategories: [MassBalanceCategoryNote] = []

    /// Whether every row is entered. Until then the points are a sum so far, not a loading
    /// condition, and nothing may call them inside or outside.
    var isComplete: Bool { unset.isEmpty }

    /// Whether everything but the fuel is entered: what "how much fuel can I take" needs.
    var loadIsEntered: Bool { unset.allSatisfy { $0 == Self.fuelRowId } }

    static func == (a: MassBalanceResult, b: MassBalanceResult) -> Bool {
        a.verdict == b.verdict && a.takeoff == b.takeoff && a.landing == b.landing && a.emptyTanks == b.emptyTanks
            && a.rampMass == b.rampMass && a.failures == b.failures && a.unset == b.unset
            && a.massMargin == b.massMargin && a.limitsAtTakeoff?.forward == b.limitsAtTakeoff?.forward
            && a.limitsAtTakeoff?.aft == b.limitsAtTakeoff?.aft && a.mostFuelLitres == b.mostFuelLitres
            && a.notBelowLitres == b.notBelowLitres && a.notBelowReason == b.notBelowReason
            && a.otherCategories == b.otherCategories
    }
}

enum MassBalanceCalculator {

    /// - Parameters:
    ///   - empty: the empty aircraft from its record. Nil gives no points and "not confirmed".
    ///   - isConfirmed: whether the pilot confirmed this data and this empty mass for the aircraft.
    static func compute(data: AircraftMassBalance,
                        empty: AircraftMassBalance.EmptyMass?,
                        load: MassBalanceLoad,
                        isConfirmed: Bool) -> MassBalanceResult {
        guard data.isUsable, let category = data.mainCategory, let fuelStation = data.fuelStation,
              let density = fuelStation.density, let usable = fuelStation.usable,
              let empty, empty.mass > 0, empty.mass.isFinite, empty.moment.isFinite else {
            // No empty mass, or data the arithmetic cannot run on: nothing is claimed.
            return MassBalanceResult(verdict: .notConfirmed)
        }

        let perKg = data.units.mass.perKilogram
        let perLitre = data.units.fuel.perLitre
        var mass = empty.mass
        var moment = empty.moment
        var failures: [MassBalanceFailure] = []
        var stationFailures: [MassBalanceFailure] = []
        var unset: [String] = []
        var loadedStations: Set<String> = []

        // A pilot's seat said "empty" is only an answer when another pilot's seat is taken (a tandem
        // flown from the rear). Otherwise nobody is flying, and the seat is not entered.
        let allSeats = data.seatStations.flatMap { $0.seats ?? [] }
        let aPilotIsSeated = allSeats.contains { seat in
            if seat.role == .pilot, case .person = load.seats[seat.id] ?? .unset { return true }
            return false
        }

        for station in data.stations {
            switch station.kind {
            case .seats:
                for seat in station.seats ?? [] {
                    switch load.seats[seat.id] ?? .unset {
                    case .unset:
                        unset.append(seat.id)
                    case .empty:
                        if seat.role == .pilot && !aPilotIsSeated {
                            unset.append(seat.id)
                        } else if let minimum = seat.min {
                            stationFailures.append(.seatUnderMinimum(seatId: seat.id, minimum: minimum))
                        }
                    case .person(let kg):
                        let m = kg * perKg
                        mass += m
                        moment += m * station.arm
                        if m > 0 { loadedStations.insert(station.id) }
                        if let maximum = seat.max, m > maximum + massTolerance {
                            stationFailures.append(.seatOverMaximum(seatId: seat.id, maximum: maximum))
                        }
                        if let minimum = seat.min, m < minimum - massTolerance {
                            stationFailures.append(.seatUnderMinimum(seatId: seat.id, minimum: minimum))
                        }
                    }
                }
            case .baggage:
                guard let kg = load.baggageKg[station.id], kg.isFinite, kg >= 0 else {
                    unset.append(station.id)
                    continue
                }
                let m = kg * perKg
                mass += m
                moment += m * station.arm
                if m > 0 { loadedStations.insert(station.id) }
                if let maximum = station.max, m > maximum + massTolerance {
                    stationFailures.append(.baggageOverMaximum(stationId: station.id, maximum: maximum))
                }
            case .fuel:
                break
            }
        }

        let usableLitres = usable / perLitre
        let fuelIsSet = load.fuelLitres.map { $0.isFinite && $0 >= 0 } ?? false
        if !fuelIsSet { unset.append(MassBalanceResult.fuelRowId) }
        let fuelAtStart = fuelIsSet ? (load.fuelLitres ?? 0) : 0
        if fuelIsSet, fuelAtStart > usableLitres + 0.5 {
            stationFailures.append(.fuelOverUsable(usableLitres: usableLitres))
        }

        let taxiLitres = max(0, (data.limits.taxiFuel ?? 0) / density / perLitre)
        let maxRamp = category.maxRamp ?? data.limits.maxRamp

        /// The aircraft with `litres` of usable fuel in the tanks.
        func point(litres: Double) -> MassBalancePoint {
            let fuelMass = litres * perLitre * density
            let m = mass + fuelMass
            let arm = (moment + fuelMass * fuelStation.arm) / m
            let why = outside(arm: arm, mass: m, category: category)
            return MassBalancePoint(mass: m, arm: arm, fuelLitres: litres, isInside: why == nil, outside: why)
        }
        /// Whether starting the engine with `litres` on board is inside every limit at take-off.
        func startIsFine(litres: Double) -> Bool {
            if let maxRamp, mass + litres * perLitre * density > maxRamp + massTolerance { return false }
            return point(litres: max(0, litres - taxiLitres)).isInside
        }

        let rampMass = maxRamp == nil ? nil : mass + fuelAtStart * perLitre * density
        let takeoffLitres = max(0, fuelAtStart - taxiLitres)
        let takeoff = point(litres: takeoffLitres)
        let emptyTanks = point(litres: 0)
        let trip = load.tripLitres.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let landing = trip.map { point(litres: max(0, takeoffLitres - $0)) }

        if let maxRamp, let rampMass, rampMass > maxRamp + massTolerance {
            failures.append(.overMaxRamp(by: rampMass - maxRamp))
        }
        // With something still to enter, only what more load can never cure is a failure: too
        // heavy stays too heavy. Where the CG ends up is not known yet, so it is not judged.
        let isComplete = unset.isEmpty
        if takeoff.mass > category.maxTakeoff + massTolerance {
            failures.append(.overMaxTakeoff(by: takeoff.mass - category.maxTakeoff))
        } else if isComplete, let why = takeoff.outside {
            failures.append(.takeoffOutside(why))
        }
        if isComplete, takeoff.isInside, let landing, let why = landing.outside {
            failures.append(.landingOutside(why, litresLeft: landing.fuelLitres))
        }
        failures += stationFailures

        // The most fuel at engine start this load allows, in whole litres.
        var mostFuel: Double?
        var litres = usableLitres.rounded(.down)
        while litres >= 0 {
            if startIsFine(litres: litres) { mostFuel = litres; break }
            litres -= 1
        }

        // How far down the tanks may go before the aircraft leaves the limits.
        var notBelow: Double?
        var notBelowReason: MassBalanceOutside?
        if isComplete, takeoff.isInside {
            var level = takeoffLitres.rounded(.down)
            while level >= 0 {
                let low = point(litres: level)
                if !low.isInside {
                    notBelow = level + 1
                    notBelowReason = low.outside
                    break
                }
                level -= 1
            }
        }

        let notes = data.categories.dropFirst().map { other -> MassBalanceCategoryNote in
            let forbidden = other.only.map { allowed in !loadedStations.isSubset(of: Set(allowed)) } ?? false
            let fits = outside(arm: takeoff.arm, mass: takeoff.mass, category: other) == nil
            return MassBalanceCategoryNote(categoryId: other.id, isInside: fits && !forbidden,
                                           loadsForbiddenStation: forbidden)
        }

        let verdict: MassBalanceVerdict
        if !failures.isEmpty { verdict = .outsideLimits }
        else if !unset.isEmpty { verdict = .incomplete }
        else if !isConfirmed { verdict = .notConfirmed }
        else if !load.isTodays { verdict = .lastTimesLoad }
        else { verdict = .insideLimits }

        return MassBalanceResult(
            verdict: verdict,
            takeoff: takeoff,
            landing: landing,
            emptyTanks: emptyTanks,
            rampMass: rampMass,
            failures: failures,
            unset: unset,
            massMargin: category.maxTakeoff - takeoff.mass,
            limitsAtTakeoff: limits(atMass: takeoff.mass, envelope: category.envelope),
            mostFuelLitres: mostFuel,
            notBelowLitres: notBelow,
            notBelowReason: notBelowReason,
            otherCategories: notes
        )
    }

    // MARK: - Geometry

    /// A hundredth of a gram or of a pound: far below anything a pilot types, far above rounding.
    private static let massTolerance = 1e-6

    /// Nil when the point is inside the category, else why it is not.
    static func outside(arm: Double, mass: Double,
                        category: AircraftMassBalance.Category) -> MassBalanceOutside? {
        if mass > category.maxTakeoff + massTolerance { return .overMaximumMass }
        if contains(arm: arm, mass: mass, envelope: category.envelope) { return nil }
        guard let limits = limits(atMass: mass, envelope: category.envelope) else {
            let masses = category.envelope.map(\.mass)
            return mass > (masses.max() ?? 0) ? .overMaximumMass : .underMinimumMass
        }
        return arm < limits.forward ? .aheadOfForwardLimit : .behindAftLimit
    }

    /// Point in polygon over (arm, mass). A point on an edge is inside: an envelope edge is a
    /// published limit, and an aircraft loaded exactly to it is within it.
    static func contains(arm: Double, mass: Double, envelope: [MassBalanceCorner]) -> Bool {
        guard envelope.count >= 3 else { return false }
        // Arms and masses differ by orders of magnitude (2.7 m against 600 kg), so the edge test
        // works on each axis scaled by the envelope's own extent.
        let arms = envelope.map(\.arm), masses = envelope.map(\.mass)
        let sx = max((arms.max() ?? 1) - (arms.min() ?? 0), .leastNonzeroMagnitude)
        let sy = max((masses.max() ?? 1) - (masses.min() ?? 0), .leastNonzeroMagnitude)
        let px = arm / sx, py = mass / sy
        let edge = 1e-9
        for i in envelope.indices {
            let a = envelope[i], b = envelope[(i + 1) % envelope.count]
            let ax = a.arm / sx, ay = a.mass / sy, bx = b.arm / sx, by = b.mass / sy
            let cross = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
            let length = max(((bx - ax) * (bx - ax) + (by - ay) * (by - ay)).squareRoot(), .leastNonzeroMagnitude)
            if abs(cross) / length <= edge,
               px >= min(ax, bx) - edge, px <= max(ax, bx) + edge,
               py >= min(ay, by) - edge, py <= max(ay, by) + edge {
                return true
            }
        }
        var inside = false
        var j = envelope.count - 1
        for i in envelope.indices {
            let pi = envelope[i], pj = envelope[j]
            if (pi.mass > mass) != (pj.mass > mass) {
                let crossingArm = pi.arm + (mass - pi.mass) * (pj.arm - pi.arm) / (pj.mass - pi.mass)
                if arm < crossingArm { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// The forward and aft limits at one mass: where a level line crosses the envelope. Nil when
    /// the mass is above or below every corner.
    static func limits(atMass mass: Double, envelope: [MassBalanceCorner]) -> (forward: Double, aft: Double)? {
        var arms: [Double] = []
        for i in envelope.indices {
            let a = envelope[i], b = envelope[(i + 1) % envelope.count]
            if a.mass == b.mass {
                if abs(a.mass - mass) <= massTolerance { arms += [a.arm, b.arm] }
                continue
            }
            if mass >= min(a.mass, b.mass) - massTolerance, mass <= max(a.mass, b.mass) + massTolerance {
                arms.append(a.arm + (mass - a.mass) * (b.arm - a.arm) / (b.mass - a.mass))
            }
        }
        guard let forward = arms.min(), let aft = arms.max() else { return nil }
        return (forward, aft)
    }
}
