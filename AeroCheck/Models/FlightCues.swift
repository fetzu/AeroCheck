import Foundation
import CoreLocation

// MARK: - Cues from the flight (6.1, "Checks in flight", build plan 4)
//
// The flight says when a check is due; the pilot does it. Five moments time the check slot's reminders:
//
// | Cue        | Detected                                                                  | Due        |
// |------------|---------------------------------------------------------------------------|------------|
// | take-off   | 500 ft above the field, after a detected take-off                         | climb      |
// | level-off  | within ±200 fpm over 60 s, 1,000 ft or more above the field               | cruise     |
// | descent    | −300 fpm over 30 s and 300 ft lost in the last minute, after the level-off| descent    |
// | approach   | 5 NM from the route's destination; without a route, descending within 5 NM | approach   |
// |            | of an aerodrome, 2,500 ft or less above it; or the detector's approach window |          |
// | circuit    | 3 NM from that aerodrome at circuit height (1,300 ft or less), or the     | landing,   |
// |            | approach window                                                           | shown only |
//
// A later cue brings the earlier ones with it (a descent says the level-off happened). A descent the
// flight climbs back from (300 ft above where it fired) is withdrawn, so a dip in cruise doesn't end
// FREDA for the rest of the flight. The numbers were tuned against the 53 corpus flights and the 70
// flights exported on 29.09.2026 (CLAUDE/review/flight-events/cue_referee.py).
//
// None of this is a landing event. `FlightCueTracker` reads the landing state machine after each fix and
// never writes to it, so take-off, touch-and-go, go-around and full-stop detection, the corpus scores and
// the post-flight reconciliation are what they were. It is a port of `FlightCues` in detector_v2.py, pinned
// to it by the corpus fixtures' `expectedCues`. A cue never ticks an item and never changes the phase.

/// A moment of the flight that makes a check due, in flight order.
enum FlightCue: Int, CaseIterable, Codable, Comparable {
    case takeoff
    case levelOff
    case descent
    case approach
    case circuit

    static func < (lhs: FlightCue, rhs: FlightCue) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The Python prototype's and the fixtures' name.
    var code: String {
        switch self {
        case .takeoff: return "takeoff"
        case .levelOff: return "levelOff"
        case .descent: return "descent"
        case .approach: return "approach"
        case .circuit: return "circuit"
        }
    }

    /// The check the cue makes due. Circuits fly no cruise and no descent: the level-off at circuit
    /// height is the downwind, where the approach check is due, and from the descent onto base the
    /// landing check is shown.
    func phase(circuitMode: Bool) -> ChecklistPhase {
        switch self {
        case .takeoff: return .climb
        case .levelOff: return circuitMode ? .approach : .cruise
        case .descent: return circuitMode ? .landing : .descent
        case .approach: return circuitMode ? .landing : .approach
        case .circuit: return .landing
        }
    }
}

/// What the tracker reports, fix by fix.
struct FlightCueEvent: Equatable {
    enum Kind: Equatable {
        /// A take-off roll or a climb-away (touch-and-go, go-around): the cues start again.
        case leg
        case fired(FlightCue)
        /// A descent the flight climbed back from.
        case withdrawn(FlightCue)
    }

    let kind: Kind
    let time: Date
    /// Fired together with a later cue, which says it happened.
    let implied: Bool
    /// The aerodrome it was for: the take-off field for a leg and the take-off, the one approached for
    /// the approach and the circuit. "DEST" for the route's destination.
    let aerodrome: String?
}

/// The cues, port of `FlightCues` in CLAUDE/review/flight-events/detector_v2.py. Pure: it is fed each fix
/// the landing detector processed, with that detector's state after it, and keeps no reference to it.
struct FlightCueTracker {
    /// The landing detector's state, as far as the cues care.
    enum DetectorPhase: Equatable {
        case ground, climbout, airborne, approach, rollout
        var isFlying: Bool { self == .climbout || self == .airborne || self == .approach }
    }

    static let takeoffFt = 500.0
    static let levelWindow: TimeInterval = 60
    static let levelFpm = 200.0
    static let levelMinFt = 1000.0
    static let descentWindow: TimeInterval = 30
    static let descentFpm = -300.0
    static let descentLostFt = 300.0
    static let descentRegainFt = 300.0
    static let approachNm = 5.0
    static let approachMaxFt = 2500.0
    static let circuitNm = 3.0
    static let circuitMaxFt = 1300.0
    static let historySeconds: TimeInterval = 65
    static let destinationMarker = "DEST"

    private struct Leg {
        let refFt: Double
        let departure: String
        let departureLatitude: Double
        let departureLongitude: Double
        var fired: [FlightCue: Date] = [:]
        var farFromDeparture = false
        var destinationFar = false
        var descentAltitudeFt: Double?
        var approachAt: String?
    }

    /// The route's destination: the approach is due 5 NM from it.
    var destination: CLLocationCoordinate2D?

    private var history: [(t: TimeInterval, altFt: Double)] = []
    private var previousPhase: DetectorPhase?
    private var leg: Leg?
    /// A climb-away the pilot pressed (GO AROUND, TOUCH-AND-GO): the next fix in the air starts a leg,
    /// even when it is already past the climb-out. (The corpus has no presses: the prototype needs none.)
    private var climbAwayPressed = false

    /// GO AROUND or TOUCH-AND-GO pressed: the cues start again with the next fix.
    mutating func noteClimbAway() {
        climbAwayPressed = true
    }

    /// One fix, after the landing detector processed it. Returns what it cued, in order.
    mutating func observe(phase: DetectorPhase, anchor: Airport?, altBiasFt: Double?, now: Date,
                          latitude: Double, longitude: Double, altitudeM: Double,
                          airports: [Airport]) -> [FlightCueEvent] {
        var out: [FlightCueEvent] = []
        let t = now.timeIntervalSince1970
        let altFt = altitudeM / 0.3048
        history.append((t, altFt))
        history.removeAll { t - $0.t > Self.historySeconds }
        let entered = phase != previousPhase
        previousPhase = phase
        guard phase.isFlying else {
            leg = nil
            return out
        }
        // A leg starts at every take-off roll and every climb-away (touch-and-go, go-around).
        if (phase == .climbout && entered) || climbAwayPressed, let anchor {
            climbAwayPressed = false
            leg = Leg(refFt: Double(anchor.elevation ?? 0) + (altBiasFt ?? 0), departure: anchor.ident,
                      departureLatitude: anchor.latitude, departureLongitude: anchor.longitude)
            out.append(FlightCueEvent(kind: .leg, time: now, implied: false, aerodrome: anchor.ident))
        }
        guard var leg else { return out }
        defer { self.leg = leg }

        let heightFt = altFt - leg.refFt
        if Self.distanceNm(latitude, longitude, leg.departureLatitude, leg.departureLongitude) > Self.approachNm
            || heightFt > Self.approachMaxFt {
            leg.farFromDeparture = true
        }
        let near = airports.first { AirportType.fixedWing.contains($0.type) }
        let nearNm = near.map { Self.distanceNm(latitude, longitude, $0.latitude, $0.longitude) } ?? .infinity
        let nearHeightFt = near.map { altFt - Double($0.elevation ?? 0) } ?? .infinity
        // The departure field counts again only once the leg has left it (5 NM, or 2,500 ft above it).
        let arrived = near.map { $0.ident != leg.departure || leg.farFromDeparture } ?? false

        func fire(_ cue: FlightCue, _ aerodrome: String?) {
            for earlier in FlightCue.allCases where earlier < cue && leg.fired[earlier] == nil {
                leg.fired[earlier] = now
                out.append(FlightCueEvent(kind: .fired(earlier), time: now, implied: true, aerodrome: nil))
            }
            leg.fired[cue] = now
            out.append(FlightCueEvent(kind: .fired(cue), time: now, implied: false, aerodrome: aerodrome))
        }

        if leg.fired[.takeoff] == nil {
            guard heightFt >= Self.takeoffFt else { return out }
            fire(.takeoff, leg.departure)
        }
        if leg.fired[.levelOff] == nil, heightFt >= Self.levelMinFt,
           let fpm = Self.verticalSpeedFpm(history, now: t, window: Self.levelWindow), abs(fpm) <= Self.levelFpm {
            fire(.levelOff, nil)
        }
        let descending = isDescending(now: t, altFt: altFt)
        if leg.fired[.levelOff] != nil, leg.fired[.approach] == nil {
            if leg.fired[.descent] != nil {
                if let cueAltitude = leg.descentAltitudeFt, altFt >= cueAltitude + Self.descentRegainFt {
                    leg.fired[.descent] = nil
                    leg.descentAltitudeFt = nil
                    out.append(FlightCueEvent(kind: .withdrawn(.descent), time: now, implied: false, aerodrome: nil))
                }
            } else if descending {
                fire(.descent, nil)
                leg.descentAltitudeFt = altFt
            }
        }
        if leg.fired[.approach] == nil {
            var why: String?
            if let destination {
                let d = Self.distanceNm(latitude, longitude, destination.latitude, destination.longitude)
                if d > Self.approachNm + 0.5 {
                    leg.destinationFar = true
                } else if d <= Self.approachNm && leg.destinationFar {
                    why = Self.destinationMarker
                }
            }
            // Without a route only: with one, the destination says where the approach is, and an aerodrome
            // passed low on the way is not it.
            if why == nil, destination == nil, descending, arrived, nearNm <= Self.approachNm,
               nearHeightFt <= Self.approachMaxFt {
                why = near?.ident
            }
            if why == nil, phase == .approach {
                why = anchor?.ident
            }
            if let why {
                fire(.approach, why)
                leg.approachAt = why
            }
        }
        if leg.fired[.circuit] == nil {
            let atField = arrived && nearNm <= Self.circuitNm && nearHeightFt <= Self.circuitMaxFt
            // The aerodrome the approach was for: the one named, or the one at the route's destination.
            let destinationField: Bool = {
                guard let destination, let near else { return false }
                return Self.distanceNm(near.latitude, near.longitude, destination.latitude, destination.longitude) <= 1.0
            }()
            let theField = near.map { leg.approachAt == $0.ident
                || (leg.approachAt == Self.destinationMarker && destinationField) } ?? false
            if atField && theField {
                fire(.circuit, near?.ident)
            } else if phase == .approach {
                fire(.circuit, anchor?.ident)
            }
        }
        return out
    }

    /// −300 fpm over the last 30 s, and 300 ft lost over the last minute.
    private func isDescending(now t: TimeInterval, altFt: Double) -> Bool {
        guard let fpm = Self.verticalSpeedFpm(history, now: t, window: Self.descentWindow), fpm <= Self.descentFpm,
              let minuteAgo = history.last(where: { t - $0.t >= 55 }) else { return false }
        return minuteAgo.altFt - altFt >= Self.descentLostFt
    }

    /// Least-squares vertical speed over the last `window` seconds, in ft/min. Nil unless four samples or
    /// more span `window` − 10 s: a gap in the track is not a level-off.
    static func verticalSpeedFpm(_ history: [(t: TimeInterval, altFt: Double)], now: TimeInterval,
                                 window: TimeInterval) -> Double? {
        let h = history.filter { now - $0.t <= window }
        guard h.count >= 4, let first = h.first, let last = h.last, last.t - first.t >= window - 10 else { return nil }
        let n = Double(h.count)
        let mx = h.reduce(0) { $0 + $1.t } / n
        let my = h.reduce(0) { $0 + $1.altFt } / n
        let sxx = h.reduce(0) { $0 + ($1.t - mx) * ($1.t - mx) }
        guard sxx > 0 else { return nil }
        let sxy = h.reduce(0) { $0 + ($1.t - mx) * ($1.altFt - my) }
        return sxy / sxx * 60
    }

    /// Great-circle distance on the prototype's sphere (6,371 km), so both sides draw the same 5 NM.
    static func distanceNm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(a))) / 1852.0
    }
}

// MARK: - The Cockpit's side: due, owed

/// What the Cockpit makes of the cues, leg by leg: which checks the flight says are due, and which it has
/// passed with the check still open ("owed"). Kept by `AppState`, in the crash checkpoint.
///
/// Owed happens once per check and leg ("never twice"): filled amber in the slot until the check is done
/// or skipped explicitly. Nothing pulses, nothing sounds, and the pane never changes.
struct FlightCueState: Equatable, Codable {
    struct Owed: Equatable, Codable {
        /// When the flight moved past it, and with which cue.
        let at: Date
        let cue: FlightCue
    }

    /// The cues of this leg (since the last take-off roll or climb-away), with when they came.
    private(set) var fired: [FlightCue: Date] = [:]
    private(set) var owed: [ChecklistPhase: Owed] = [:]
    /// Checks already turned owed this leg: never a second time.
    private(set) var escalated: Set<ChecklistPhase> = []
    /// Legs seen this flight. None: nothing times the checks (no airport data, no take-off detected
    /// yet), and an open check is due as before 6.1.
    private(set) var legs = 0

    /// The checks the cues time: climb to landing.
    static func isCued(_ phase: ChecklistPhase) -> Bool {
        phase.rawValue >= ChecklistPhase.climb.rawValue && phase.rawValue <= ChecklistPhase.landing.rawValue
    }

    /// A new leg: the take-off roll, a touch-and-go or a go-around. Nothing is due or owed yet.
    mutating func startLeg() {
        fired = [:]
        owed = [:]
        escalated = []
        legs += 1
    }

    /// When the slot shows `phase`'s check: not yet, due, or owed.
    func timing(for phase: ChecklistPhase, circuitMode: Bool) -> CheckSlotTiming {
        if owed[phase] != nil { return .owed }
        guard legs > 0, Self.isCued(phase) else { return .due }
        let due = fired.keys.contains { $0.phase(circuitMode: circuitMode) == phase }
        return due ? .due : .notYet
    }

    /// The flight itself says `phase`'s check is due (or owed): its cue came this leg. Not the "due as
    /// before" of a flight with no cue source, so a check comes to the slot early only on the flight's word.
    func cueHasCome(for phase: ChecklistPhase, circuitMode: Bool) -> Bool {
        guard legs > 0, Self.isCued(phase) else { return false }
        return owed[phase] != nil || fired.keys.contains { $0.phase(circuitMode: circuitMode) == phase }
    }

    /// The landing check is shown: circuit height near the field (or, in circuits, the descent onto base).
    func landingShown(circuitMode: Bool) -> Bool {
        fired.keys.contains { $0.phase(circuitMode: circuitMode) == .landing }
    }

    /// The descent has begun: FREDA gives way to the descent check.
    var descentBegun: Bool { fired[.descent] != nil }

    /// A cue fired at `time`. Every check before its own that was due before now and is still open
    /// (`isOpen`) turns owed, once. Returns the checks that did.
    mutating func fire(_ cue: FlightCue, at time: Date, circuitMode: Bool,
                       isOpen: (ChecklistPhase) -> Bool) -> [ChecklistPhase] {
        let target = cue.phase(circuitMode: circuitMode)
        var newlyOwed: [ChecklistPhase] = []
        for phase in ChecklistPhase.allCases where Self.isCued(phase) && phase.rawValue < target.rawValue
            && !phase.isSkippedInCircuitMode(circuitMode) && !escalated.contains(phase) {
            // Due before this cue: its own cue came earlier (one implied by this one came just now).
            let dueSince = fired.filter { $0.key.phase(circuitMode: circuitMode) == phase }.values.min()
            guard let dueSince, dueSince < time, isOpen(phase) else { continue }
            owed[phase] = Owed(at: time, cue: cue)
            escalated.insert(phase)
            newlyOwed.append(phase)
        }
        if fired[cue] == nil { fired[cue] = time }
        return newlyOwed
    }

    /// A descent the flight climbed back from: not due any more. What it made owed stays owed.
    mutating func withdraw(_ cue: FlightCue) {
        fired[cue] = nil
    }

    /// The check was done, or skipped: no longer owed.
    @discardableResult
    mutating func resolve(_ phase: ChecklistPhase) -> Owed? {
        owed.removeValue(forKey: phase)
    }

    /// UNDO on a confirmation made while it was owed: owed again.
    mutating func restoreOwed(_ phase: ChecklistPhase, _ entry: Owed) {
        owed[phase] = entry
        escalated.insert(phase)
    }

    #if DEBUG
    /// DEV-ONLY (`AEROCHECK_CUES`, captures).
    mutating func owe(_ phase: ChecklistPhase, cue: FlightCue, at time: Date) {
        owed[phase] = Owed(at: time, cue: cue)
        escalated.insert(phase)
    }
    #endif
}

// MARK: - The record, for the debrief

/// What happened to a check that wasn't simply done in time, kept on the flight for the debrief (6.1):
/// an append-only log, like the landings, so `Flight.merge` keeps the longer one.
struct CheckRecord: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        /// The flight moved past it with the check still open (`cue` says how).
        case owed
        /// Left open by the pilot: NEXT past it, a jump over it, the landed card's move to AFTER LANDING.
        case skipped
        /// Done after it was owed.
        case doneLate
        /// The landing check, "yes, it was done" on the landed card: green outline, never solid green.
        case confirmedAfterLanding
        /// The landing check, "not sure" on the landed card.
        case notSure
    }

    let id: UUID
    /// `ChecklistPhase.rawValue`, so a record never fails the flight's decode.
    let phaseRawValue: Int
    let kind: Kind
    let at: Date
    /// For `owed`: the moment of the flight that passed it.
    let cue: FlightCue?

    var phase: ChecklistPhase? { ChecklistPhase(rawValue: phaseRawValue) }

    /// A bound on what a synced or imported flight can carry.
    static let maxPerFlight = 200

    init(id: UUID = UUID(), phase: ChecklistPhase, kind: Kind, at: Date, cue: FlightCue? = nil) {
        self.id = id
        self.phaseRawValue = phase.rawValue
        self.kind = kind
        self.at = at
        self.cue = cue
    }

    /// Tolerant, as a flight file must be: a kind or cue this build doesn't know (a newer build's) reads
    /// as owed and no cue, something to look at, rather than failing the whole flight.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        phaseRawValue = try c.decodeIfPresent(Int.self, forKey: .phaseRawValue) ?? -1
        kind = Kind(rawValue: try c.decodeIfPresent(String.self, forKey: .kind) ?? "") ?? .owed
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
        cue = (try? c.decodeIfPresent(Int.self, forKey: .cue)).flatMap { FlightCue(rawValue: $0) }
    }
}

// MARK: - The landed card (M4)

/// After a full-stop landing on a flight that isn't circuits, once slow for 10 s: "LANDED · LSZQ · 14:44 —
/// Was the landing check done before touchdown?" It waits for an answer and never times out; the next
/// take-off roll takes it away, unanswered. (6.1)
struct LandedCard: Equatable, Identifiable {
    let id: UUID
    /// The touchdown, as the detector stamped it.
    let touchdown: Date
    let aerodrome: String?

    init(id: UUID = UUID(), touchdown: Date, aerodrome: String?) {
        self.id = id
        self.touchdown = touchdown
        self.aerodrome = aerodrome
    }
}

/// The landed card's answers.
enum LandedAnswer: String, Codable {
    /// "YES, IT WAS DONE": the landing check recorded confirmed after landing.
    case yes
    /// "NOT SURE": recorded for the debrief.
    case notSure
    /// The landing check was done before touchdown already: only on to AFTER LANDING.
    case next
}

extension FlightPlan {
    /// Where the flight is going, for the approach cue: the aerodrome it diverted to, or its route's end.
    var cueDestination: CLLocationCoordinate2D? {
        if let diversion { return CLLocationCoordinate2D(latitude: diversion.latitude, longitude: diversion.longitude) }
        guard let last = waypoints.last else { return nil }
        return CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
    }
}
