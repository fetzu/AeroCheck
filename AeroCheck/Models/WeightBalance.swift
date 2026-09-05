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
    var weightKg: Double

    var moment: Double { armMeters * weightKg }
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

    init(emptyWeightKg: Double = 0,
         emptyArmMeters: Double = 0,
         maxTakeoffWeightKg: Double = 0,
         stations: [WeightBalanceStation] = [],
         envelope: [EnvelopePoint]? = nil) {
        self.emptyWeightKg = emptyWeightKg
        self.emptyArmMeters = emptyArmMeters
        self.maxTakeoffWeightKg = maxTakeoffWeightKg
        self.stations = stations
        self.envelope = envelope
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

    var isOverweight: Bool { maxTakeoffWeightKg > 0 && totalWeightKg > maxTakeoffWeightKg }
    var remainingPayloadKg: Double { max(0, maxTakeoffWeightKg - totalWeightKg) }

    /// True only when everything checked actually passed. An unknown envelope is not a pass.
    var isWithinLimits: Bool? {
        if isOverweight { return false }
        guard let inside = isInsideEnvelope else { return nil }
        return inside
    }
}

enum WeightBalanceCalculator {

    /// Mass, moment, CG and — when an envelope was entered — whether the point falls inside it.
    static func compute(profile: WeightBalanceProfile) -> WeightBalanceResult {
        let emptyMoment = profile.emptyWeightKg * profile.emptyArmMeters
        let stationWeight = profile.stations.reduce(0) { $0 + $1.weightKg }
        let stationMoment = profile.stations.reduce(0) { $0 + $1.moment }

        let totalWeight = profile.emptyWeightKg + stationWeight
        let totalMoment = emptyMoment + stationMoment
        let cg = totalWeight > 0 ? totalMoment / totalWeight : nil

        var inside: Bool?
        if let envelope = profile.envelope, envelope.count >= 3, let cg {
            inside = isPoint(arm: cg, weight: totalWeight, insideEnvelope: envelope)
        }

        return WeightBalanceResult(
            totalWeightKg: totalWeight,
            totalMoment: totalMoment,
            centreOfGravityMeters: cg,
            maxTakeoffWeightKg: profile.maxTakeoffWeightKg,
            isInsideEnvelope: inside
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
