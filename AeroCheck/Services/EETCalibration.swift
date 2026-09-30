import Foundation
import CoreLocation

// MARK: - Cruise speed (6.1)
//
// A plan's leg times used to fly every aircraft at a flat 100 kt true airspeed. Each aircraft now has a
// cruise speed as INDICATED (knots), from the pilot, from its own flights or from its data, and each leg
// converts it into a true airspeed at the level it is flown. Analysis of 29 Sep 2026
// (`CLAUDE/proposals-2026-09-29/eet-accuracy.md`, `cruise-speeds.md`): 100 kt was right for F-HVXA at low
// level and 14 minutes long on the 8,500 ft Alpine leg, where the same power gives ~108 kt TAS.

/// The standard atmosphere and the cruise model. PURE.
///
/// The figure is a KIAS at 65 % power at 5,000 ft (the basis of the aircraft data). Pilots set an rpm and
/// leave it, so the power falls with the air density and the TAS barely changes with altitude: a constant
/// IAS converted by altitude overstates the TAS above 5,000 ft and understates it below (97 KIAS gives
/// 110 KTAS at 8,500 ft, F-HVXA flew 107). The model keeps the power of the reference level instead,
/// which puts the TAS between the two: TAS(h) = KIAS / √σ(5,000 ft) × (σ(5,000 ft) / σ(h))^(1/3).
/// Approved by the author on 30 Sep 2026.
enum CruiseSpeedModel {
    /// The level a cruise KIAS is given at.
    static let referenceAltitudeFt = 5_000.0
    /// The last resort, as every aircraft planned before 6.1 (then as a TAS).
    static let standardKIAS = 100.0
    /// What an aircraft's cruise can be (the checklists' validator agrees).
    static let plausibleKIAS: ClosedRange<Double> = 40...250
    /// Beyond these a light aircraft does not cruise, and σ stays meaningful.
    private static let altitudeRangeFt: ClosedRange<Double> = -1_500...25_000

    /// σ, the ISA air density over the sea-level density, at a pressure altitude in feet.
    static func densityRatio(altitudeFt: Double) -> Double {
        let h = min(max(altitudeFt.isFinite ? altitudeFt : referenceAltitudeFt, altitudeRangeFt.lowerBound),
                    altitudeRangeFt.upperBound)
        return pow(1 - 6.8756e-6 * h, 4.2559)
    }

    /// The true airspeed a cruise KIAS gives at `altitudeFt`.
    static func trueAirspeed(kias: Double, altitudeFt: Double) -> Double {
        let reference = densityRatio(altitudeFt: referenceAltitudeFt)
        return kias / reference.squareRoot() * pow(reference / densityRatio(altitudeFt: altitudeFt), 1.0 / 3.0)
    }

    /// The inverse: the cruise KIAS a true airspeed measured at `altitudeFt` stands for. What a flight's
    /// cruise is learned in, so it can be weighed against the aircraft's figure.
    static func basisKIAS(trueAirspeed: Double, altitudeFt: Double) -> Double {
        let reference = densityRatio(altitudeFt: referenceAltitudeFt)
        return trueAirspeed * reference.squareRoot() * pow(densityRatio(altitudeFt: altitudeFt) / reference, 1.0 / 3.0)
    }
}

/// An aircraft's planning cruise speed, indicated, in knots, and where it comes from. Stored on the plan
/// it was computed with (`FlightPlan.plannedCruise`) and shown in the Aircraft tab. (6.1)
struct CruiseSpeed: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        /// Set by the pilot for this registration (Aircraft tab).
        case manual
        /// Learned from the pilot's own flights in this registration (`EETCalibration`).
        case learned
        /// The aircraft's data, through the server (`RemoteAircraftMetadata.cruiseSpeedKIAS`).
        case aircraftData
        /// None of those: 100 kt.
        case standard

        /// A source a newer build adds reads as the standard one rather than failing the whole plan.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Source(rawValue: raw) ?? .standard
        }
    }

    var kias: Double
    var source: Source
    /// The flights a learned figure stands on; 0 otherwise.
    var flights: Int = 0

    static let standard = CruiseSpeed(kias: CruiseSpeedModel.standardKIAS, source: .standard)

    /// The true airspeed at `altitudeFt` (`CruiseSpeedModel`).
    func trueAirspeed(atAltitudeFt altitudeFt: Double) -> Double {
        CruiseSpeedModel.trueAirspeed(kias: kias, altitudeFt: altitudeFt)
    }

    /// Whole knots, as the pilot reads and types them.
    var roundedKIAS: Int { kias.safeRoundedInt(or: Int(CruiseSpeedModel.standardKIAS)) }

    /// In precedence order: the pilot's own figure, what the flights taught (5 qualifying flights at
    /// least, drawn towards the aircraft's figure), the aircraft's figure, 100 kt. A figure no aircraft
    /// cruises at is skipped, whichever it is.
    static func resolve(manualKIAS: Double?, aircraftDataKIAS: Double?,
                        learnedSamples: [EETCalibration.Sample]) -> CruiseSpeed {
        func plausible(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && CruiseSpeedModel.plausibleKIAS.contains($0) ? $0 : nil }
        }
        if let manual = plausible(manualKIAS) {
            return CruiseSpeed(kias: manual, source: .manual)
        }
        let aircraftData = plausible(aircraftDataKIAS)
        let seed = aircraftData ?? CruiseSpeedModel.standardKIAS
        if let learned = EETCalibration.learnedCruise(learnedSamples, seedKIAS: seed) {
            return CruiseSpeed(kias: learned.kias, source: .learned, flights: learned.flights)
        }
        if let aircraftData { return CruiseSpeed(kias: aircraftData, source: .aircraftData) }
        return .standard
    }

    /// The key a registration is kept under: trimmed and upper-cased, nil when there is none.
    static func key(for registration: String?) -> String? {
        guard let reg = registration?.trimmingCharacters(in: .whitespaces).uppercased(), !reg.isEmpty
        else { return nil }
        return reg
    }
}

// MARK: - Allowances (6.1)

/// The minutes a plan adds for the departure (take-off to the first waypoint, beyond the leg time) or
/// the arrival (over the destination to the landing), and where they come from. Stored on the plan they
/// were computed with (`FlightPlan.departureAllowance`, `arrivalAllowance`), for the nav log and the
/// editor to say so.
struct EETAllowance: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        /// Learned from the pilot's flights at this aerodrome.
        case aerodrome
        /// Learned from the pilot's flights at every aerodrome: this one has too few.
        case allAerodromes
        /// Too few flights: the 5 minutes every plan used before 6.1.
        case standard

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Source(rawValue: raw) ?? .standard
        }
    }

    var minutes: Int
    /// The aerodrome it was looked up for, when the plan names one.
    var aerodrome: String?
    var source: Source
    /// The flights it stands on; 0 for the standard one.
    var flights: Int = 0

    var seconds: TimeInterval { TimeInterval(minutes * 60) }

    static let standardMinutes = 5

    static func standard(at aerodrome: String?) -> EETAllowance {
        EETAllowance(minutes: standardMinutes, aerodrome: aerodrome, source: .standard)
    }
}

// MARK: - Learning from the logbook (6.1)

/// What the pilot's own flights say about planning: the departure allowance at each departure aerodrome,
/// the arrival allowance at each arrival aerodrome (any aircraft), and the cruise speed of each
/// registration. PURE: flights in, samples out. `EETCalibrationStore` runs it at END FLIGHT and when the
/// logbook changes, and keeps the result.
///
/// Definitions, as the 29 Sep analysis measured them:
/// - Departure, flown with a plan from its departure: the time over its first waypoint, minus the
///   take-off, minus the planned first leg. Without a usable plan: the time to 5 NM from the take-off,
///   minus 5 NM at the flight's own cruise ground speed.
/// - Arrival: the landing minus the moment the aircraft was over the destination (its progress along the
///   route reached it, abeam within 2.5 NM, or it came within 0.5 NM of it). Without a plan, the route
///   is the straight line from the take-off to the landing.
/// - Cruise: the true airspeed on level cruise segments, the ground speed with the wind taken out (the
///   wind-triangle fit where the courses spread over 120° or more, else the wind the plan stored for
///   the leg), converted to the cruise KIAS basis (`CruiseSpeedModel.basisKIAS`).
///
/// A flight teaches nothing it cannot measure cleanly: circuits, several landings, a GPS gap over 60 s in
/// the air, a touch-and-go or go-around within the part measured (the ends), and, for what the plan
/// says, a diversion, a waypoint taken back, fewer than 60 % of the waypoints passed or a track to the
/// destination more than 1.3 times the planned distance.
///
/// Allowances are for PREPARING a flight only: nothing logged is computed from them.
enum EETCalibration {

    // MARK: Rules

    /// The flights looked at: the most recent ones.
    static let recentFlights = 20
    /// An aerodrome needs this many flights for its own allowance…
    static let aerodromeMinimumFlights = 3
    /// …otherwise the pilot's flights at every aerodrome, this many of them, give one.
    static let pilotMinimumFlights = 5
    /// Below this many flights a learned allowance is drawn towards the standard 5 minutes.
    static let allowanceFullWeightFlights = 5
    static let departureMinutes: ClosedRange<Double> = 0...6
    static let arrivalMinutes: ClosedRange<Double> = 0...15

    /// A registration needs this many flights for a learned cruise speed…
    static let cruiseMinimumFlights = 5
    /// …drawn towards the aircraft's figure until this many…
    static let cruiseFullWeightFlights = 10
    /// …and never further from it than this.
    static let cruiseMaxDeviation = 0.15

    /// Exclusions (§7 of the analysis).
    static let maxAirborneGap: TimeInterval = 60
    static let minimumWaypointsPassed = 0.6
    static let maxStretch = 1.3
    /// Take-off and landing closer than this: a local flight, with no departure or arrival to measure
    /// without a plan.
    static let localFlightNM = 8.0
    /// The plan-free departure is measured to this distance from the take-off.
    static let departureRadiusNM = 5.0
    /// A plan-free departure this long is circuits or airwork before leaving, not a departure.
    static let maxPlanFreeDepartureMinutes = 10.0
    /// Within this of the destination is over it.
    static let overheadNM = 0.5
    /// What one flight's departure or arrival can plausibly measure, minutes.
    static let plausibleDepartureMinutes: ClosedRange<Double> = -5...15
    static let plausibleArrivalMinutes: ClosedRange<Double> = 0...30

    /// Cruise segments (the cruise-speed study's filters).
    static let cruiseMinimumGroundSpeedKt = 40.0
    static let cruiseMaxVerticalSpeedFpm = 200.0
    static let cruiseMaxTurnRate = 2.0          // degrees per second
    static let cruiseMaxCourseChange = 10.0     // degrees within one segment
    static let cruiseClearOfAerodromesNM = 3.0
    static let cruiseAboveAerodromesFt = 1_000.0
    static let cruiseSettleSeconds: TimeInterval = 30
    static let cruiseMinimumSegment: TimeInterval = 120
    static let windFitMinimumSpread = 120.0     // degrees of ground course
    static let windFitMaxRMS = 4.0
    static let windFitMaxWind = 60.0

    private static let metresPerNM = 1852.0
    private static let knotsPerMetrePerSecond = 1.94384

    // MARK: Samples

    /// One flight's value: minutes for an allowance, knots for a cruise speed.
    struct Sample: Codable, Equatable, Sendable {
        var date: Date
        var value: Double
    }

    /// What the logbook taught, kept between launches. Only the most recent `recentFlights` samples of
    /// each aerodrome and registration are kept: the most recent `recentFlights` of the pilot overall are
    /// always among them.
    struct Snapshot: Codable, Equatable, Sendable {
        static let currentVersion = 1

        var version = Snapshot.currentVersion
        /// Departure aerodrome → departure allowances, oldest first.
        var departures: [String: [Sample]] = [:]
        /// Arrival aerodrome → arrival allowances, oldest first.
        var arrivals: [String: [Sample]] = [:]
        /// Registration → cruise KIAS, oldest first.
        var cruise: [String: [Sample]] = [:]
        /// Which logbook it was computed from (`fingerprint(of:)`).
        var logbookFingerprint = ""

        static let empty = Snapshot()
    }

    /// What one flight says.
    struct Measures: Equatable {
        var date: Date?
        var departureAerodrome: String?
        var departureMinutes: Double?
        var arrivalAerodrome: String?
        var arrivalMinutes: Double?
        var registration: String?
        var cruiseKIAS: Double?
    }

    /// The logbook, as a key that changes when a flight is added, edited or removed.
    static func fingerprint(of flights: [Flight]) -> String {
        let latest = flights.map(\.modifiedAt.timeIntervalSince1970).max() ?? 0
        return "\(Snapshot.currentVersion)|\(flights.count)|\(Int(latest))"
    }

    /// Every flight's measures, kept per aerodrome and per registration.
    static func snapshot(from flights: [Flight]) -> Snapshot {
        var snapshot = Snapshot()
        func add(_ value: Double?, at key: String?, date: Date?, to table: inout [String: [Sample]]) {
            guard let value, value.isFinite, let key, let date else { return }
            table[key, default: []].append(Sample(date: date, value: value))
        }
        for flight in flights {
            let m = measure(flight)
            add(m.departureMinutes, at: m.departureAerodrome, date: m.date, to: &snapshot.departures)
            add(m.arrivalMinutes, at: m.arrivalAerodrome, date: m.date, to: &snapshot.arrivals)
            add(m.cruiseKIAS, at: m.registration, date: m.date, to: &snapshot.cruise)
        }
        func recent(_ table: [String: [Sample]]) -> [String: [Sample]] {
            table.mapValues { Array($0.sorted { $0.date < $1.date }.suffix(recentFlights)) }
        }
        snapshot.departures = recent(snapshot.departures)
        snapshot.arrivals = recent(snapshot.arrivals)
        snapshot.cruise = recent(snapshot.cruise)
        snapshot.logbookFingerprint = fingerprint(of: flights)
        return snapshot
    }

    // MARK: Resolution

    /// The departure allowance at `aerodrome`: its own flights (3 at least), else the pilot's at every
    /// aerodrome (5 at least), else 5 minutes.
    static func departureAllowance(at aerodrome: String?, in snapshot: Snapshot) -> EETAllowance {
        allowance(at: aerodrome, from: snapshot.departures, clamp: departureMinutes)
    }

    /// The arrival allowance at `aerodrome`, by the same rule.
    static func arrivalAllowance(at aerodrome: String?, in snapshot: Snapshot) -> EETAllowance {
        allowance(at: aerodrome, from: snapshot.arrivals, clamp: arrivalMinutes)
    }

    private static func allowance(at aerodrome: String?, from table: [String: [Sample]],
                                  clamp: ClosedRange<Double>) -> EETAllowance {
        let key = aerodromeKey(aerodrome)
        let standard = Double(EETAllowance.standardMinutes)
        func learned(_ samples: [Sample], source: EETAllowance.Source) -> EETAllowance {
            let recent = Array(samples.sorted { $0.date < $1.date }.suffix(recentFlights))
            let weight = min(1, Double(recent.count) / Double(allowanceFullWeightFlights))
            let value = standard + weight * (median(recent.map(\.value)) - standard)
            let minutes = min(max(value, clamp.lowerBound), clamp.upperBound).safeRoundedInt(or: EETAllowance.standardMinutes)
            return EETAllowance(minutes: minutes, aerodrome: key, source: source, flights: recent.count)
        }
        if let key, let own = table[key], own.count >= aerodromeMinimumFlights {
            return learned(own, source: .aerodrome)
        }
        let everywhere = table.values.flatMap { $0 }
        if everywhere.count >= pilotMinimumFlights {
            return learned(everywhere, source: .allAerodromes)
        }
        return .standard(at: key)
    }

    /// The cruise speed the flights teach, when there are enough of them: their median, drawn towards the
    /// aircraft's figure (`seedKIAS`) with fewer than 10 flights, never more than 15 % from it.
    static func learnedCruise(_ samples: [Sample], seedKIAS: Double) -> (kias: Double, flights: Int)? {
        let recent = Array(samples.filter { $0.value.isFinite }.sorted { $0.date < $1.date }.suffix(recentFlights))
        guard recent.count >= cruiseMinimumFlights, seedKIAS.isFinite, seedKIAS > 0 else { return nil }
        let weight = min(1, Double(recent.count) / Double(cruiseFullWeightFlights))
        let value = seedKIAS + weight * (median(recent.map(\.value)) - seedKIAS)
        let bound = seedKIAS * cruiseMaxDeviation
        return (min(max(value, seedKIAS - bound), seedKIAS + bound), recent.count)
    }

    /// An aerodrome as the tables key it: trimmed and upper-cased.
    static func aerodromeKey(_ ident: String?) -> String? {
        guard let key = ident?.trimmingCharacters(in: .whitespaces).uppercased(), !key.isEmpty else { return nil }
        return key
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    // MARK: One flight

    static func measure(_ flight: Flight) -> Measures {
        var m = Measures()
        m.registration = CruiseSpeed.key(for: flight.aircraftRegistration)
        let fixes = flight.gpsTrack.filter(\.hasPlausibleValues).sorted { $0.timestamp < $1.timestamp }
        let times = TrackTimes.analyze(track: fixes, engineStart: flight.engineStartTime,
                                       engineShutdown: flight.engineShutdownTime)
        guard let takeoff = times.takeoff ?? flight.lineUpTime, let landing = times.landing ?? flight.landingTime,
              landing.timeIntervalSince(takeoff) > 120 else { return m }
        m.date = takeoff
        let air = fixes.filter { $0.timestamp >= takeoff && $0.timestamp <= landing }
        guard air.count >= 2,
              let takeoffFix = nearest(takeoff, in: fixes), let landingFix = nearest(landing, in: fixes) else { return m }

        // Circuits, and a flight that landed more than once (a stop recorded as one flight): no clean
        // departure, arrival or leg.
        if case .circuits = flight.routeShape { return m }
        if flight.fullStopTimes.count > 1 { return m }
        // A gap in the air is a track that cannot say when anything happened.
        if zip(air, air.dropFirst()).contains(where: { $1.timestamp.timeIntervalSince($0.timestamp) > maxAirborneGap }) {
            return m
        }

        let events = flight.touchAndGoTimes + flight.goAroundTimes
        func eventBetween(_ from: Date, _ to: Date) -> Bool { events.contains { $0 >= from && $0 <= to } }
        let passageFixes = fixes.map {
            WaypointPassage.Fix(time: $0.timestamp, coordinate: $0.coordinate, speed: $0.speed)
        }
        let startPoint = takeoffFix.coordinate, endPoint = landingFix.coordinate
        /// The track from the take-off to `time`: how far the aircraft flew to get over the destination.
        /// Not to the landing: a long wait in the circuit is the arrival, not the route. (29 Sep: 10 NM of
        /// circuit at LSGN put the whole leg over 1.3 times the plan.)
        func flownNM(until time: Date) -> Double { pathNM(air.filter { $0.timestamp <= time }) }

        m.cruiseKIAS = cruiseKIAS(air: air, from: startPoint, to: endPoint,
                                  aboveFt: max(takeoffFix.altitude, landingFix.altitude) / 0.3048,
                                  plan: flight.flightPlan)

        // With the plan it was flown with: from its departure, along its route, to its destination.
        let hasPlan = (flight.flightPlan?.waypoints.count ?? 0) >= 2
        if let plan = flight.flightPlan, hasPlan {
            m.departureAerodrome = aerodromeKey(flight.departureAirportIdent) ?? plan.departureAerodromeIdent
            m.arrivalAerodrome = aerodromeKey(flight.arrivalAirportIdent) ?? plan.destinationAerodromeIdent
            let route = plan.waypoints.map(\.coordinate)
            let passed = WaypointPassage.timesOver(route: route, track: passageFixes, takeoff: takeoff, landing: landing)
            let enRoute = Array(1..<(route.count - 1))
            let passedShare = enRoute.isEmpty ? 1 : Double(enRoute.filter { passed[$0] != nil }.count) / Double(enRoute.count)
            let plannedNM = RouteGeometry(route: route).cumulative.last ?? 0
            // Landed there (the destination has the landing for its time over): over it before that.
            let overhead = passed[route.count - 1] == nil ? nil
                : overhead(route: route, track: passageFixes, air: air, takeoff: takeoff, landing: landing)
            // Landed somewhere else is a diversion too, pressed or not (a plan flown before 5.1 has none).
            let usablePlan = plan.diversion == nil && overhead != nil
                && (plan.takenBackWaypointIds ?? []).isEmpty
                && passedShare >= minimumWaypointsPassed
                && plannedNM > 0 && flownNM(until: overhead ?? landing) <= maxStretch * plannedNM
            if usablePlan {
                // From the plan's departure, over its first waypoint: a flight that joined the route
                // further on would count legs it never flew.
                if passed[0] != nil, let first = enRoute.first, let over = passed[first], !eventBetween(takeoff, over) {
                    m.departureMinutes = plausible((over.timeIntervalSince(takeoff) - plannedLegSeconds(plan, from: 0)) / 60,
                                                   plausibleDepartureMinutes)
                }
                if let overhead, !eventBetween(overhead, landing.addingTimeInterval(-1)) {
                    m.arrivalMinutes = plausible(landing.timeIntervalSince(overhead) / 60, plausibleArrivalMinutes)
                }
            }
        } else {
            m.departureAerodrome = aerodromeKey(flight.departureAirportIdent)
            m.arrivalAerodrome = aerodromeKey(flight.arrivalAirportIdent)
        }

        // Without one: measured on the track alone, when the flight went somewhere.
        let directNM = distanceNM(startPoint, endPoint)
        guard directNM >= localFlightNM else { return m }
        if m.departureMinutes == nil, let minutes = planFreeDeparture(air: air, from: startPoint, to: endPoint,
                                                                      takeoff: takeoff, eventBetween: eventBetween) {
            m.departureMinutes = plausible(minutes, plausibleDepartureMinutes)
        }
        if !hasPlan {
            let route = [startPoint, endPoint]
            if let overhead = overhead(route: route, track: passageFixes, air: air, takeoff: takeoff, landing: landing),
               flownNM(until: overhead) <= maxStretch * directNM,
               !eventBetween(overhead, landing.addingTimeInterval(-1)) {
                m.arrivalMinutes = plausible(landing.timeIntervalSince(overhead) / 60, plausibleArrivalMinutes)
            }
        }
        return m
    }

    /// A measure outside what a departure or an arrival can take is a measurement that failed (a route
    /// that ends where it starts confuses the progress along it), not something to learn.
    private static func plausible(_ minutes: Double, _ range: ClosedRange<Double>) -> Double? {
        minutes.isFinite && range.contains(minutes) ? minutes : nil
    }

    /// The leg LEAVING waypoint `index` as planned: its stored time, else its distance at the airspeed
    /// typed on it, else at the old 100 kt.
    private static func plannedLegSeconds(_ plan: FlightPlan, from index: Int) -> TimeInterval {
        if let stored = plan.waypoints[index].estimatedElapsedTime, stored.isFinite, stored > 0 { return stored }
        let a = plan.waypoints[index].coordinate, b = plan.waypoints[index + 1].coordinate
        let speed = Double(plan.waypoints[index].plannedGroundSpeed ?? Int(CruiseSpeedModel.standardKIAS))
        return distanceNM(a, b) / max(speed, 1) * 3600
    }

    /// When the aircraft was over the destination: its progress along the route reached it (abeam,
    /// within 2.5 NM), or it came within 0.5 NM of it, whichever came first; the landing itself when
    /// neither happened before it (a straight-in). Within 0.5 NM only counts once the aircraft is back
    /// from its last time more than 5 NM out: a route that ends where it started is not over its
    /// destination right after the take-off.
    private static func overhead(route: [CLLocationCoordinate2D], track: [WaypointPassage.Fix], air: [GPSPoint],
                                 takeoff: Date, landing: Date) -> Date? {
        guard let destination = route.last else { return nil }
        let abeam = WaypointPassage.timesOver(route: route, track: track, takeoff: takeoff, landing: nil,
                                              includingDestination: true).last ?? nil
        let inbound = air.lastIndex { distanceNM($0.coordinate, destination) > departureRadiusNM }.map { $0 + 1 } ?? 0
        let back = inbound < air.count ? air[inbound].timestamp : landing
        let near = air[min(inbound, air.count)...].first { distanceNM($0.coordinate, destination) <= overheadNM }?.timestamp
        let candidates = [abeam, near].compactMap { $0 }.filter { $0 >= back && $0 <= landing }
        return candidates.min() ?? landing
    }

    /// The departure without a plan: to 5 NM from the take-off, beyond 5 NM at the flight's cruise ground
    /// speed (the median of the fixes more than 5 NM from both ends).
    private static func planFreeDeparture(air: [GPSPoint], from start: CLLocationCoordinate2D,
                                          to end: CLLocationCoordinate2D, takeoff: Date,
                                          eventBetween: (Date, Date) -> Bool) -> Double? {
        guard let exit = air.first(where: { distanceNM($0.coordinate, start) > departureRadiusNM })?.timestamp,
              !eventBetween(takeoff, exit) else { return nil }
        let cruise = air.filter {
            distanceNM($0.coordinate, start) > departureRadiusNM && distanceNM($0.coordinate, end) > departureRadiusNM
        }
        guard cruise.count >= 10 else { return nil }
        let groundSpeed = median(cruise.map { max(0, $0.speed) * knotsPerMetrePerSecond })
        guard groundSpeed > cruiseMinimumGroundSpeedKt else { return nil }
        let minutes = exit.timeIntervalSince(takeoff) / 60 - departureRadiusNM / groundSpeed * 60
        return minutes < maxPlanFreeDepartureMinutes ? minutes : nil
    }

    // MARK: Cruise

    /// The flight's cruise, as a KIAS on the cruise basis: the median over its level cruise segments, or
    /// nil when it has none, or no wind to take out.
    static func cruiseKIAS(air: [GPSPoint], from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D,
                           aboveFt floorFt: Double, plan: FlightPlan?) -> Double? {
        let segments = cruiseSegments(air: air, from: start, to: end, minimumAltitudeFt: floorFt + cruiseAboveAerodromesFt)
        let points = segments.flatMap { $0 }
        guard !points.isEmpty else { return nil }

        // The wind: measured, where the courses flown spread enough for the wind triangle to show it…
        let vectors = points.compactMap(groundVector)
        var tas: [(kt: Double, altitudeFt: Double)] = []
        if let fit = WindTriangleFit.fit(vectors), fit.spreadDegrees >= windFitMinimumSpread,
           fit.rms <= windFitMaxRMS, (50...200).contains(fit.trueAirspeed), hypot(fit.windEast, fit.windNorth) <= windFitMaxWind {
            tas = points.compactMap { point in
                groundVector(point).map { (hypot($0.east - fit.windEast, $0.north - fit.windNorth), point.altitude / 0.3048) }
            }
        } else if let plan, plan.waypoints.count >= 2 {
            // …otherwise the wind the plan was computed with, on the leg the aircraft was on.
            let geometry = RouteGeometry(route: plan.waypoints.map(\.coordinate))
            tas = points.compactMap { point in
                let p = geometry.xy(point.coordinate)
                let leg = (0..<(plan.waypoints.count - 1)).min {
                    geometry.project(p, onto: $0).offset < geometry.project(p, onto: $1).offset
                }
                guard let leg, let wind = plan.waypoints[leg].planningWind, let ground = groundVector(point) else { return nil }
                let toward = (wind.directionDegTrue + 180) * .pi / 180
                let windEast = wind.speedKt * sin(toward), windNorth = wind.speedKt * cos(toward)
                return (hypot(ground.east - windEast, ground.north - windNorth), point.altitude / 0.3048)
            }
        }
        guard tas.count >= 10 else { return nil }
        let kias = median(tas.map { CruiseSpeedModel.basisKIAS(trueAirspeed: $0.kt, altitudeFt: $0.altitudeFt) })
        return CruiseSpeedModel.plausibleKIAS.contains(kias) ? kias : nil
    }

    /// Level, straight (one course within 10°), clear of the aerodromes and well above them, lasting
    /// 2 minutes once settled.
    static func cruiseSegments(air: [GPSPoint], from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D,
                               minimumAltitudeFt: Double) -> [[GPSPoint]] {
        var qualifies = [Bool](repeating: false, count: air.count)
        for i in air.indices {
            let point = air[i]
            guard max(0, point.speed) * knotsPerMetrePerSecond >= cruiseMinimumGroundSpeedKt,
                  point.altitude / 0.3048 >= minimumAltitudeFt,
                  distanceNM(point.coordinate, start) > cruiseClearOfAerodromesNM,
                  distanceNM(point.coordinate, end) > cruiseClearOfAerodromesNM,
                  let vs = verticalSpeedFpm(air, at: i), abs(vs) <= cruiseMaxVerticalSpeedFpm,
                  turnRate(air, at: i) < cruiseMaxTurnRate else { continue }
            qualifies[i] = true
        }
        var segments: [[GPSPoint]] = []
        var run: [GPSPoint] = []
        func close() {
            if let first = run.first {
                let settled = run.filter { $0.timestamp.timeIntervalSince(first.timestamp) >= cruiseSettleSeconds }
                if let a = settled.first, let b = settled.last, b.timestamp.timeIntervalSince(a.timestamp) >= cruiseMinimumSegment {
                    segments.append(settled)
                }
            }
            run = []
        }
        for i in air.indices {
            // A segment is one straight leg: a slow orbit turns under 2°/s too, and at its own speed.
            if qualifies[i], let first = run.first, let last = run.last,
               air[i].timestamp.timeIntervalSince(last.timestamp) > TrackTimes.maxGap
                || courseDifference(air[i].course, first.course) > cruiseMaxCourseChange { close() }
            if qualifies[i] { run.append(air[i]) } else { close() }
        }
        close()
        return segments
    }

    /// Vertical speed at fix `i`: a least-squares line through the fixes within 12 s of it.
    private static func verticalSpeedFpm(_ fixes: [GPSPoint], at i: Int) -> Double? {
        let t0 = fixes[i].timestamp
        var lo = i, hi = i
        while lo > 0, t0.timeIntervalSince(fixes[lo - 1].timestamp) <= 12 { lo -= 1 }
        while hi + 1 < fixes.count, fixes[hi + 1].timestamp.timeIntervalSince(t0) <= 12 { hi += 1 }
        guard hi - lo >= 2 else { return nil }
        let window = fixes[lo...hi]
        let xs = window.map { $0.timestamp.timeIntervalSince(t0) }, ys = window.map { $0.altitude / 0.3048 }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let sxx = xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let sxy = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        return sxy / sxx * 60
    }

    /// The angle between two courses, 0...180.
    private static func courseDifference(_ a: Double, _ b: Double) -> Double {
        guard a >= 0, b >= 0 else { return 0 }
        let delta = abs(a - b).truncatingRemainder(dividingBy: 360)
        return delta > 180 ? 360 - delta : delta
    }

    /// Degrees per second between the neighbours of fix `i`, from their GPS courses (or their positions,
    /// where the course is unknown).
    private static func turnRate(_ fixes: [GPSPoint], at i: Int) -> Double {
        guard i > 0, i + 1 < fixes.count else { return .infinity }
        let a = fixes[i - 1], b = fixes[i + 1]
        let dt = b.timestamp.timeIntervalSince(a.timestamp)
        guard dt > 0 else { return .infinity }
        func course(_ k: Int) -> Double {
            if fixes[k].course >= 0 { return fixes[k].course }
            let from = fixes[max(0, k - 1)].coordinate, to = fixes[min(fixes.count - 1, k + 1)].coordinate
            return from.bearing(to: to)
        }
        var delta = abs(course(i + 1) - course(i - 1)).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        return delta / dt
    }

    /// The ground-speed vector of a fix, knots east and north; nil without a course.
    private static func groundVector(_ point: GPSPoint) -> (east: Double, north: Double)? {
        guard point.course >= 0, point.speed > 0 else { return nil }
        let speed = point.speed * knotsPerMetrePerSecond, course = point.course * .pi / 180
        return (speed * sin(course), speed * cos(course))
    }

    // MARK: Geometry

    static func distanceNM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / metresPerNM
    }

    private static func pathNM(_ fixes: [GPSPoint]) -> Double {
        zip(fixes, fixes.dropFirst()).map { distanceNM($0.coordinate, $1.coordinate) }.reduce(0, +)
    }

    private static func nearest(_ time: Date, in fixes: [GPSPoint]) -> GPSPoint? {
        fixes.min { abs($0.timestamp.timeIntervalSince(time)) < abs($1.timestamp.timeIntervalSince(time)) }
    }
}

// MARK: - Wind triangle

/// The wind and the true airspeed from ground-speed vectors flown on several courses: at a constant
/// airspeed, the ground-speed vectors lie on a circle whose centre is the wind (the way the air moves)
/// and whose radius is the TAS. An algebraic fit, then Gauss-Newton on the distances to the circle
/// (the study's `windfit.circle_fit`). PURE.
enum WindTriangleFit {
    struct Result: Equatable {
        /// The way the air moves, knots east and north (not the direction it blows from).
        let windEast: Double
        let windNorth: Double
        let trueAirspeed: Double
        /// Root mean square of the distances to the circle, knots.
        let rms: Double
        /// How much of the circle the courses flown cover, degrees.
        let spreadDegrees: Double
    }

    static func fit(_ vectors: [(east: Double, north: Double)]) -> Result? {
        let n = Double(vectors.count)
        guard vectors.count >= 8 else { return nil }
        // x² + y² + D x + E y + F = 0, least squares.
        var sxx = 0.0, syy = 0.0, sxy = 0.0, sx = 0.0, sy = 0.0, szx = 0.0, szy = 0.0, sz = 0.0
        for v in vectors {
            let z = v.east * v.east + v.north * v.north
            sxx += v.east * v.east; syy += v.north * v.north; sxy += v.east * v.north
            sx += v.east; sy += v.north; szx += z * v.east; szy += z * v.north; sz += z
        }
        guard let algebraic = solve([[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, n]], [-szx, -szy, -sz]) else { return nil }
        var cx = -algebraic[0] / 2, cy = -algebraic[1] / 2
        var r = (max(cx * cx + cy * cy - algebraic[2], 1e-9)).squareRoot()
        for _ in 0..<30 {
            var jtj = [[Double]](repeating: [0, 0, 0], count: 3), jtr = [0.0, 0, 0]
            for v in vectors {
                let d = max(hypot(v.east - cx, v.north - cy), 1e-9)
                let residual = d - r
                let j = [-(v.east - cx) / d, -(v.north - cy) / d, -1.0]
                for a in 0..<3 {
                    jtr[a] -= j[a] * residual
                    for b in 0..<3 { jtj[a][b] += j[a] * j[b] }
                }
            }
            guard let step = solve(jtj, jtr) else { break }
            cx += step[0]; cy += step[1]; r += step[2]
            if step.map(abs).max() ?? 0 < 1e-6 { break }
        }
        let rms = (vectors.map { pow(hypot($0.east - cx, $0.north - cy) - r, 2) }.reduce(0, +) / n).squareRoot()
        let angles = vectors.map { (atan2($0.east - cx, $0.north - cy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) }
            .sorted()
        let gaps = angles.indices.map { i in
            ((angles[(i + 1) % angles.count] - angles[i]) + 360).truncatingRemainder(dividingBy: 360)
        }
        let spread = 360 - (gaps.max() ?? 360)
        guard cx.isFinite, cy.isFinite, r.isFinite, rms.isFinite else { return nil }
        return Result(windEast: cx, windNorth: cy, trueAirspeed: r, rms: rms, spreadDegrees: spread)
    }

    /// Gauss-Jordan with partial pivoting, 3 × 3.
    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = zip(a, b).map { $0 + [$1] }
        for i in 0..<3 {
            guard let pivot = (i..<3).max(by: { abs(m[$0][i]) < abs(m[$1][i]) }), abs(m[pivot][i]) > 1e-12 else { return nil }
            m.swapAt(i, pivot)
            for k in 0..<3 where k != i {
                let f = m[k][i] / m[i][i]
                m[k] = zip(m[k], m[i]).map { $0 - f * $1 }
            }
        }
        return (0..<3).map { m[$0][3] / m[$0][$0] }
    }
}

// MARK: - Where the EET comes from (6.1)

extension FlightPlan {
    /// The parts of the EET besides the legs, one phrase each, as the plan was computed:
    /// "departure +1 at LSZQ (6 flights)", "arrival +8 at LSGN (default)", "cruise 97 KIAS (aircraft
    /// data)". A plan computed before 6.1 stored none of it and says what it used: +5 at each end.
    /// Shown wherever the EET is prepared from (the plan editor, the nav log's header).
    var eetProvenanceParts: [String] {
        guard waypoints.count >= 2 else { return [] }
        func legacy(_ extra: TimeInterval?, at aerodrome: String?) -> EETAllowance {
            EETAllowance(minutes: ((extra ?? 300) / 60).safeRoundedInt(or: EETAllowance.standardMinutes),
                         aerodrome: aerodrome, source: .standard)
        }
        func source(_ allowance: EETAllowance) -> String {
            switch allowance.source {
            case .aerodrome: return L10n.EETPlanning.flights(allowance.flights)
            case .allAerodromes: return L10n.EETPlanning.allAerodromes(allowance.flights)
            case .standard: return L10n.EETPlanning.standard
            }
        }
        let departure = departureAllowance ?? legacy(waypoints.first?.legEETExtra, at: departureAerodromeIdent)
        let arrival = arrivalAllowance ?? legacy(waypoints.last?.legEETExtra, at: destinationAerodromeIdent)
        var parts = [
            L10n.EETPlanning.departure("+\(departure.minutes)", at: departure.aerodrome, source(departure)),
            L10n.EETPlanning.arrival("+\(arrival.minutes)", at: arrival.aerodrome, source(arrival)),
        ]
        // The cruise speed, when a leg was timed with it: one the pilot typed an airspeed on was not.
        if let cruise = plannedCruise, waypoints.dropLast().contains(where: { $0.plannedGroundSpeed == nil }) {
            let from: String
            switch cruise.source {
            case .manual: from = L10n.EETPlanning.cruiseManual
            case .learned: from = L10n.EETPlanning.cruiseLearned(cruise.flights)
            case .aircraftData: from = L10n.EETPlanning.cruiseAircraftData
            case .standard: from = L10n.EETPlanning.standard
            }
            parts.append(L10n.EETPlanning.cruise("\(cruise.roundedKIAS)", from))
        }
        return parts
    }

    /// `eetProvenanceParts` on one line; nil without a route.
    var eetProvenance: String? {
        let parts = eetProvenanceParts
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
