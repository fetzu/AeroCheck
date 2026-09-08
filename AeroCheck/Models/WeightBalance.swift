import Foundation

// MARK: - Mass & balance (v5.0.0)
//
// A calculator, and only a calculator. Every number comes from the pilot: the empty mass and empty
// arm from the aircraft's own weighing report, the station arms and the envelope from its AFM. The
// app ships none of it.
//
// That is a deliberate limit, not an unfinished feature. Empty mass is per REGISTRATION and changes
// whenever the aircraft is modified or re-weighed; the envelope is per type but lives in a document
// the app has no licence to reproduce. Shipping a plausible envelope that turns out to be the wrong
// variant is precisely the failure a pilot cannot catch by eye, so the app does the arithmetic and
// the pilot owns the inputs.
//
// The result is advisory. It is a cross-check against the load sheet, never a replacement for it.

/// One mass on the aircraft, at a distance from the datum.
struct WeightBalanceStation: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    /// Distance from the datum, in metres. Signed: a station behind the datum is positive, and some
    /// types genuinely have negative arms.
    var armMeters: Double
    /// Nil until the pilot enters a mass — NOT 0.
    ///
    /// The editor renders 0 as an empty box, so a station nobody had filled in was indistinguishable
    /// from one deliberately loaded to nothing, and the calculator summed it as 0 and still printed
    /// "INSIDE ENVELOPE" in green. Forgetting the rear seats produced a screen that positively
    /// asserted an aircraft was legal while it was over MTOW with the CG well aft of the limit. The
    /// rest of this file is careful to say "unknown" rather than "fine"; this was the hole in it.
    /// (review F22)
    var weightKg: Double?

    /// Contribution to the total moment. Nil weight contributes nothing AND makes the result
    /// incomplete — see `WeightBalanceResult.hasUnsetStations`.
    var moment: Double { armMeters * (weightKg ?? 0) }

    var isSet: Bool { weightKg != nil }

    init(id: UUID = UUID(), name: String, armMeters: Double, weightKg: Double? = nil) {
        self.id = id
        self.name = name
        self.armMeters = armMeters
        self.weightKg = weightKg
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        armMeters = try container.decodeIfPresent(Double.self, forKey: .armMeters) ?? 0
        // A save written before the mass became optional stored 0 for "not entered". Reading that
        // back as an explicit 0 would re-create the very claim this change removes, so a stored 0
        // migrates to "unset". A real zero-mass station is not a thing a pilot enters.
        let stored = try container.decodeIfPresent(Double.self, forKey: .weightKg)
        weightKg = (stored == 0) ? nil : stored
    }
}

/// A point on the CG envelope, in the same units as the stations.
struct EnvelopePoint: Codable, Equatable, Sendable {
    var armMeters: Double
    var weightKg: Double
}

/// The pilot's mass & balance setup for one aircraft, keyed by registration.
struct WeightBalanceProfile: Codable, Equatable, Sendable {
    /// From the aircraft's weighing report — per registration, and re-weighed after modifications.
    var emptyWeightKg: Double
    var emptyArmMeters: Double
    var maxTakeoffWeightKg: Double
    /// Stations with their arms; weights are the ones last entered, so a repeat flight starts filled.
    var stations: [WeightBalanceStation]
    /// The AFM envelope as a closed polygon, entered by the pilot. Optional: without it the
    /// calculator still gives mass and CG, and simply does not claim the result is inside anything.
    var envelope: [EnvelopePoint]?
    /// Which station holds the fuel, so a burn can be taken off the right arm. (review F23)
    var fuelStationId: UUID?
    /// Fuel the pilot expects to burn this flight, in kg. Nil means "no landing case computed" —
    /// the calculator says nothing rather than guessing a trip fuel.
    var fuelBurnKg: Double?

    init(emptyWeightKg: Double = 0,
         emptyArmMeters: Double = 0,
         maxTakeoffWeightKg: Double = 0,
         stations: [WeightBalanceStation] = [],
         envelope: [EnvelopePoint]? = nil,
         fuelStationId: UUID? = nil,
         fuelBurnKg: Double? = nil) {
        self.emptyWeightKg = emptyWeightKg
        self.emptyArmMeters = emptyArmMeters
        self.maxTakeoffWeightKg = maxTakeoffWeightKg
        self.stations = stations
        self.envelope = envelope
        self.fuelStationId = fuelStationId
        self.fuelBurnKg = fuelBurnKg
    }

    var isConfigured: Bool { emptyWeightKg > 0 && maxTakeoffWeightKg > 0 }
}

/// What the calculator concluded.
struct WeightBalanceResult: Equatable, Sendable {
    var totalWeightKg: Double
    var totalMoment: Double
    /// Centre of gravity, metres from the datum. Nil when there is no mass at all.
    var centreOfGravityMeters: Double?
    var maxTakeoffWeightKg: Double
    /// Nil when the pilot has not entered an envelope — "unknown", never "fine".
    var isInsideEnvelope: Bool?
    /// Stations with no mass entered. A result computed over an incomplete load sheet cannot claim
    /// to be within limits, however the arithmetic came out. (review F22)
    var unsetStationNames: [String] = []
    /// The same point after burning `fuelBurnKg`, when the pilot entered one. (review F23)
    var landing: LandingCondition?

    /// The CG at the end of the flight. A loading legal at take-off can be illegal at landing —
    /// burning a forward tank moves the CG aft, an aft tank moves it forward — which is why the AFM
    /// asks for both points and why checking only one is a cross-check with a hole in it.
    struct LandingCondition: Equatable, Sendable {
        var totalWeightKg: Double
        var centreOfGravityMeters: Double?
        var isInsideEnvelope: Bool?
    }

    var hasUnsetStations: Bool { !unsetStationNames.isEmpty }
    var isOverweight: Bool { maxTakeoffWeightKg > 0 && totalWeightKg > maxTakeoffWeightKg }
    var remainingPayloadKg: Double { max(0, maxTakeoffWeightKg - totalWeightKg) }

    /// True only when everything checked actually passed. An unknown envelope is not a pass, an
    /// incomplete load sheet is not a pass, and a landing point outside the envelope is not a pass.
    var isWithinLimits: Bool? {
        if isOverweight { return false }
        if let landingInside = landing?.isInsideEnvelope, !landingInside { return false }
        if hasUnsetStations { return nil }
        guard let inside = isInsideEnvelope else { return nil }
        return inside
    }
}

enum WeightBalanceCalculator {

    /// Mass, moment, CG and — when an envelope was entered — whether the point falls inside it.
    static func compute(profile: WeightBalanceProfile) -> WeightBalanceResult {
        let emptyMoment = profile.emptyWeightKg * profile.emptyArmMeters
        let stationWeight = profile.stations.reduce(0) { $0 + ($1.weightKg ?? 0) }
        let stationMoment = profile.stations.reduce(0) { $0 + $1.moment }

        let totalWeight = profile.emptyWeightKg + stationWeight
        let totalMoment = emptyMoment + stationMoment
        let cg = totalWeight > 0 ? totalMoment / totalWeight : nil

        let envelope = (profile.envelope?.count ?? 0) >= 3 ? profile.envelope : nil
        var inside: Bool?
        if let envelope, let cg {
            inside = isPoint(arm: cg, weight: totalWeight, insideEnvelope: envelope)
        }

        // The landing point: same stations, less the fuel the pilot expects to burn, at the fuel
        // station's own arm. Burning a FORWARD tank moves the CG aft and an aft tank moves it
        // forward, so this genuinely can fail where take-off passed. (review F23)
        var landing: WeightBalanceResult.LandingCondition?
        if let burn = profile.fuelBurnKg, burn > 0,
           let fuelStation = profile.stations.first(where: { $0.id == profile.fuelStationId }) {
            let burnt = min(burn, fuelStation.weightKg ?? 0)
            let landingWeight = totalWeight - burnt
            let landingMoment = totalMoment - burnt * fuelStation.armMeters
            let landingCG = landingWeight > 0 ? landingMoment / landingWeight : nil
            var landingInside: Bool?
            if let envelope, let landingCG {
                landingInside = isPoint(arm: landingCG, weight: landingWeight, insideEnvelope: envelope)
            }
            landing = WeightBalanceResult.LandingCondition(totalWeightKg: landingWeight,
                                                           centreOfGravityMeters: landingCG,
                                                           isInsideEnvelope: landingInside)
        }

        return WeightBalanceResult(
            totalWeightKg: totalWeight,
            totalMoment: totalMoment,
            centreOfGravityMeters: cg,
            maxTakeoffWeightKg: profile.maxTakeoffWeightKg,
            isInsideEnvelope: inside,
            unsetStationNames: profile.stations.filter { !$0.isSet }.map(\.name),
            landing: landing
        )
    }

    /// Ray-casting point-in-polygon over the (arm, weight) plane.
    ///
    /// A point exactly ON the boundary counts as inside: an envelope edge is a published limit, and
    /// a pilot loaded exactly to it is legal. Floating-point equality makes that a near-miss anyway,
    /// which is why the edge test is explicit rather than left to the crossing count.
    static func isPoint(arm: Double, weight: Double, insideEnvelope polygon: [EnvelopePoint]) -> Bool {
        guard polygon.count >= 3 else { return false }

        // On an edge (within a tolerance far tighter than any real loading) → inside.
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            if isOnSegment(arm: arm, weight: weight, a: a, b: b) { return true }
        }

        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i], pj = polygon[j]
            let intersects = (pi.weightKg > weight) != (pj.weightKg > weight)
            if intersects {
                let slope = (pj.armMeters - pi.armMeters) / (pj.weightKg - pi.weightKg)
                let crossingArm = pi.armMeters + (weight - pi.weightKg) * slope
                if arm < crossingArm { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    private static let edgeTolerance = 1e-9

    private static func isOnSegment(arm: Double, weight: Double, a: EnvelopePoint, b: EnvelopePoint) -> Bool {
        let cross = (b.armMeters - a.armMeters) * (weight - a.weightKg)
            - (b.weightKg - a.weightKg) * (arm - a.armMeters)
        guard abs(cross) <= edgeTolerance else { return false }

        let withinArm = arm >= min(a.armMeters, b.armMeters) - edgeTolerance
            && arm <= max(a.armMeters, b.armMeters) + edgeTolerance
        let withinWeight = weight >= min(a.weightKg, b.weightKg) - edgeTolerance
            && weight <= max(a.weightKg, b.weightKg) + edgeTolerance
        return withinArm && withinWeight
    }
}
