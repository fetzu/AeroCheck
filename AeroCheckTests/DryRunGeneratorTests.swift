import XCTest
import CoreLocation
@testable import AeroCheck

/// The dry run's flight generator (6.4.0): the aerodromes it flies, and its flights refereed by the app's
/// own detector, fed as LocationManager feeds it in flight (a fix every 5 s from ENGINE START, the
/// fixed-wing aerodromes within 5 NM, the take-off time from the line-up, the approach cue's destination),
/// over many seeds.
@MainActor
final class DryRunGeneratorTests: XCTestCase {

    /// LSGC as scripts/flightsim lays it out (no thresholds there): 241° true, 1,130 m, a right-hand circuit.
    private let lsgc = DryRunAerodrome.make(
        ident: "LSGC", name: "Les Eplatures", reference: CLLocationCoordinate2D(latitude: 47.0839, longitude: 6.79284),
        elevationFt: 3368, heading: 241, lengthM: 1130, circuitSide: .right)
    private let ins = CLLocationCoordinate2D(latitude: 47.0240, longitude: 7.1620)

    // MARK: - The aerodromes

    func testLSZQFliesRunway07WithItsPublishedLeftHandCircuitAt2900Feet() {
        let lszq = DryRunAerodrome.lszq
        XCTAssertEqual(lszq.runwayHeading, 70, accuracy: 1)
        XCTAssertEqual(lszq.runwayLengthM, 757, accuracy: 10)
        XCTAssertEqual(lszq.circuitSide, .left)
        XCTAssertEqual(lszq.patternAltitudeFt, 2900)
        XCTAssertEqual(lszq.downwindOffsetM, 2377, accuracy: 60, "as far out as the published downwind")
        XCTAssertGreaterThan(lszq.downwindStart.latitude, lszq.farEnd.latitude + 0.015, "the downwind north of the runway")
        XCTAssertLessThan(DryRunGeo.distance(lszq.touchdownPoint, lszq.threshold), 70)
    }

    func testWithoutACircuitItIsLeftHand09NMOutAt1000FeetAboveTheField() {
        let plain = DryRunAerodrome.make(ident: "LSZQ", name: "Bressaucourt", reference: DryRunAerodrome.lszq.reference,
                                         elevationFt: 1866, threshold: DryRunAerodrome.lszq.threshold,
                                         farEnd: DryRunAerodrome.lszq.farEnd)
        XCTAssertEqual(plain.circuitSide, .left)
        XCTAssertEqual(plain.patternAltitudeFt, 2866)
        XCTAssertEqual(plain.downwindOffsetM, 0.9 * 1852, accuracy: 1)
    }

    func testARunwayLaidOutOnItsReferencePointRunsAlongItsHeading() {
        XCTAssertEqual(lsgc.runwayHeading, 241, accuracy: 0.5)
        XCTAssertEqual(lsgc.runwayLengthM, 1130, accuracy: 2)
        XCTAssertLessThan(DryRunGeo.distance(lsgc.runwayCentre, lsgc.reference), 5)
        XCTAssertEqual(lsgc.circuitSide, .right)
    }

    // MARK: - Circuits

    /// A touch-and-go, a go-around, a full stop and away again, a full stop and off the runway: the detector
    /// sees each, at LSZQ, about when the generator flew it, whatever the GPS's noise.
    func testCircuitsAtLSZQAreSeenAsTheyAreFlown() {
        for seed in UInt64(1)...12 {
            var landings: [DryRunGenerator.Landing] = [.touchAndGo, .goAround, .fullStop, .fullStop]
            var afterStops: [DryRunGenerator.AfterFullStop] = [.goAgain, .vacate]
            var stoppedFor = 0
            var pilot = DryRunGenerator.Pilot()
            pilot.landing = { _ in landings.removeFirst() }
            // Stopped 25 s before the pilot answers, as a card and a check take.
            pilot.afterFullStop = { _ in
                stoppedFor += 1
                guard stoppedFor > 25 else { return nil }
                stoppedFor = 0
                return afterStops.removeFirst()
            }
            let generator = DryRunGenerator(departure: .lszq, mission: .circuits, seed: seed, pilot: pilot)
            let flown = fly(generator)

            XCTAssertEqual(flown.events.map(\.type), [.touchAndGo, .goAround, .fullStop, .fullStop], "seed \(seed)")
            XCTAssertEqual(Set(flown.events.compactMap(\.airportIdent)), ["LSZQ"], "seed \(seed)")
            XCTAssertTrue(generator.isParkedForGood, "parked at the end, seed \(seed)")
            let touchdowns = generator.marks.filter { $0.name == "touchdown" }.map(\.t)
            let goAround = generator.mark("goAround") ?? -1
            let flownAt = [touchdowns[0], goAround, touchdowns[1], touchdowns[2]]
            for (event, t) in zip(flown.events, flownAt) {
                XCTAssertEqual(flown.seconds(event.timestamp), Double(t), accuracy: 30,
                               "\(event.type) at \(Int(flown.seconds(event.timestamp))) s, flown at \(t) s (seed \(seed))")
            }
            XCTAssertEqual(flown.takeoffs, 2, "the take-off and the stop-and-go's, from a standstill (seed \(seed))")
        }
    }

    // MARK: - A route

    /// LSZQ → INS → LSGC at 5,500 ft: the take-off, the level-off, the descent, the approach and the circuit
    /// come in that order, and the one landing is at LSGC.
    func testACrossCountryClimbsCruisesDescendsAndLandsWhereItIsGoing() {
        for seed in UInt64(20)...25 {
            let generator = DryRunGenerator(departure: .lszq,
                                            mission: .route(waypoints: [ins], destination: lsgc, cruiseAltitudeFt: 5500),
                                            seed: seed)
            let flown = fly(generator, destination: lsgc.reference)
            XCTAssertEqual(flown.events.map(\.type), [.fullStop], "seed \(seed)")
            XCTAssertEqual(flown.events.first?.airportIdent, "LSGC", "seed \(seed)")
            XCTAssertEqual(flown.firedCues, [.takeoff, .levelOff, .descent, .approach, .circuit], "seed \(seed)")
            XCTAssertNotNil(generator.mark("wp1"), "INS passed")
            XCTAssertEqual(generator.aerodrome.ident, "LSGC")
        }
    }

    // MARK: - The pilot and the route under it

    func testItWaitsParkedUntilThePilotStartsTheEngine() {
        var pilot = DryRunGenerator.Pilot()
        pilot.mayGo = { $0 != .engineStart }
        let generator = DryRunGenerator(departure: .lszq, mission: .circuits, seed: 7, pilot: pilot)
        let fixes = (0..<600).map { _ in generator.nextFix() }
        let first = fixes[0].coordinate
        XCTAssertLessThan(fixes.map { DryRunGeo.distance(first, $0.coordinate) }.max() ?? 0, 15, "the GPS wanders, the aircraft doesn't")
        XCTAssertLessThan(fixes.map(\.speedMS).max() ?? 0, 0.3)
        XCTAssertTrue(fixes.allSatisfy { $0.course == -1 }, "no course standing still")
        XCTAssertNil(generator.mark("lineUp"))
    }

    /// The same seed flies the same flight; another flies the same one with other noise.
    func testTheSameSeedFliesTheSameFlight() {
        func track(_ seed: UInt64) -> [DryRunFix] {
            let generator = DryRunGenerator(departure: .lszq, mission: .circuits, seed: seed)
            return (0..<900).map { _ in generator.nextFix() }
        }
        XCTAssertEqual(track(3), track(3))
        XCTAssertNotEqual(track(3), track(4))
        XCTAssertEqual(track(3).last!.altitudeM, track(4).last!.altitudeM, accuracy: 15, "the same flight underneath")
    }

    /// A Direct To in the air: the aircraft turns for the new leg at once (3° a second), the leg it was on
    /// left.
    func testADirectToTurnsItForTheNewLegAtOnce() throws {
        let far = CLLocationCoordinate2D(latitude: 47.20, longitude: 7.40)
        let generator = DryRunGenerator(departure: .lszq,
                                        mission: .route(waypoints: [ins, far], destination: lsgc, cruiseAltitudeFt: 5500),
                                        seed: 11)
        // Fly until well on the leg to INS.
        var fix = generator.nextFix()
        while generator.mark("liftoff") == nil || fix.t < (generator.mark("liftoff") ?? 0) + 300 { fix = generator.nextFix() }
        generator.directTo(waypointAt: 1)
        for _ in 0..<90 { fix = generator.nextFix() }
        let toFar = DryRunGeo.bearing(from: fix.coordinate, to: far)
        XCTAssertLessThan(abs(DryRunGeo.angleDifference(from: fix.course, to: toFar)), 10, "heading for the new leg")
        let flown = fly(generator, destination: lsgc.reference)
        XCTAssertEqual(flown.events.last?.airportIdent, "LSGC")
        XCTAssertNil(generator.mark("wp1"), "INS never passed")
    }

    /// A divert in the air: straight to the other aerodrome, and the landing there.
    func testADivertTakesItToTheOtherAerodromesCircuit() {
        let generator = DryRunGenerator(departure: .lszq,
                                        mission: .route(waypoints: [ins], destination: lsgc, cruiseAltitudeFt: 5500),
                                        seed: 12)
        var fix = generator.nextFix()
        while generator.mark("liftoff") == nil || fix.t < (generator.mark("liftoff") ?? 0) + 420 { fix = generator.nextFix() }
        generator.divert(to: .lszq)
        let flown = fly(generator, destination: DryRunAerodrome.lszq.reference)
        XCTAssertEqual(flown.events.map(\.type), [.fullStop])
        XCTAssertEqual(flown.events.first?.airportIdent, "LSZQ", "landed where it diverted to")
        XCTAssertEqual(generator.aerodrome.ident, "LSZQ")
    }

    /// Another aircraft at its own speeds, the detector set up with them: the take-off and the landings are
    /// still seen.
    func testAnotherAircraftFliesItsOwnSpeeds() {
        let performance = DryRunPerformance.scaled(vso: 48, vr: 55, cruise: 120)
        XCTAssertEqual(performance.finalApproach, 92)
        XCTAssertLessThan(performance.downwind, performance.cruise)
        for seed in UInt64(30)...35 {
            var landings: [DryRunGenerator.Landing] = [.touchAndGo, .fullStop]
            var pilot = DryRunGenerator.Pilot()
            pilot.landing = { _ in landings.removeFirst() }
            let generator = DryRunGenerator(departure: .lszq, mission: .circuits, performance: performance,
                                            seed: seed, pilot: pilot)
            let flown = fly(generator, vso: 48, vr: 55)
            XCTAssertEqual(flown.events.map(\.type), [.touchAndGo, .fullStop], "seed \(seed)")
        }
    }

    // MARK: - The published circuit

    /// LSZQ's circuit as open flightmaps draws it, read leg by leg: on along the runway past its far end, the
    /// crosswind to the north, the downwind, the base, the final (its corner included).
    func testLSZQsCircuitLegsAreReadFromItsLine() {
        XCTAssertEqual(DryRunAerodrome.lszq.circuitLegs,
                       [.upwind, .upwind, .crosswind, .downwind, .downwind, .downwind, .base, .final, .final])
    }

    /// Circuits at LSZQ follow the circuit open flightmaps draws (the author's device check g-7, 16 Oct: "it
    /// should enter the downwind and follow the pattern"): once a leg has begun, the aircraft is never more than
    /// 200 m off the line (about 110 on the iPad's seeds), the turns begun before their corners as a pilot
    /// begins them.
    func testCircuitsAtLSZQFollowThePublishedLine() {
        let lszq = DryRunAerodrome.lszq
        for seed in UInt64(1)...4 {
            let track = flownTrack(DryRunGenerator(departure: lszq, mission: .circuits, seed: seed))
            let onLegs = track.filter { [.downwind, .base, .crosswind].contains($0.activity) && $0.intoActivity >= 15 }
            XCTAssertGreaterThan(onLegs.count, 100, "seed \(seed)")
            let worst = onLegs.map { offLine($0.coordinate, lszq.circuitLine) }.max() ?? 0
            XCTAssertLessThan(worst, 200, "seed \(seed)")
        }
    }

    /// From the east, the aircraft comes home by LSZQ's ARR SECTOR EAST: past its points off the circuit, onto
    /// the circuit at the crosswind, then the downwind as drawn, and the full stop seen at LSZQ.
    func testARouteComesHomeByThePublishedArrivalOnItsSide() {
        let lszq = DryRunAerodrome.lszq
        let east = CLLocationCoordinate2D(latitude: 47.36, longitude: 7.25)
        let generator = DryRunGenerator(departure: lszq,
                                        mission: .route(waypoints: [east], destination: lszq, cruiseAltitudeFt: 4400),
                                        seed: 5)
        let track = flownTrack(generator)
        for point in lszq.arrivals[0].line[0...2] {
            XCTAssertLessThan(track.map { DryRunGeo.distance($0.coordinate, point) }.min() ?? .infinity, 400)
        }
        let joining = track.firstIndex { $0.activity == .joining }
        let downwind = track.firstIndex { $0.activity == .downwind }
        XCTAssertNotNil(joining)
        XCTAssertLessThan(joining ?? .max, downwind ?? -1, "joined, then the downwind")
        let flown = fly(DryRunGenerator(departure: lszq,
                                        mission: .route(waypoints: [east], destination: lszq, cruiseAltitudeFt: 4400),
                                        seed: 5), destination: lszq.reference)
        XCTAssertEqual(flown.events.map(\.type), [.fullStop])
        XCTAssertEqual(flown.events.first?.airportIdent, "LSZQ")
    }

    /// Without a published arrival, the downwind is joined at 45° from 1 NM outside the circuit.
    func testWithoutAnArrivalTheDownwindIsJoinedAt45Degrees() throws {
        var lszq = DryRunAerodrome.lszq
        lszq.arrivals = []
        let join = try XCTUnwrap(lszq.joinFromOutside)
        let start = lszq.circuitLine[join.index]
        XCTAssertEqual(DryRunGeo.distance(join.entry, start) / DryRunGeo.metresPerNM, 1, accuracy: 0.01)
        XCTAssertGreaterThan(DryRunGeo.distance(join.entry, lszq.runwayCentre), DryRunGeo.distance(start, lszq.runwayCentre),
                             "outside the circuit")
        let east = CLLocationCoordinate2D(latitude: 47.36, longitude: 7.25)
        let track = flownTrack(DryRunGenerator(departure: lszq,
                                               mission: .route(waypoints: [east], destination: lszq, cruiseAltitudeFt: 4400),
                                               seed: 8))
        XCTAssertLessThan(track.map { DryRunGeo.distance($0.coordinate, join.entry) }.min() ?? .infinity, 400)
    }

    /// A published departure toward the route is flown before its legs.
    func testAPublishedDepartureIsFlownTowardTheRoute() {
        var lszq = DryRunAerodrome.lszq
        let exit = CLLocationCoordinate2D(latitude: 47.43, longitude: 7.09)
        lszq.departures = [.init(name: "DEP NE",
                                 line: [lszq.farEnd, CLLocationCoordinate2D(latitude: 47.41, longitude: 7.07), exit],
                                 offCircuit: 1...2)]
        let far = CLLocationCoordinate2D(latitude: 47.55, longitude: 7.30)
        let generator = DryRunGenerator(departure: lszq,
                                        mission: .route(waypoints: [far], destination: .lszq, cruiseAltitudeFt: 4400),
                                        seed: 6)
        let track = flownTrack(generator, until: { $0.mark("wp1") != nil })
        XCTAssertLessThan(track.map { DryRunGeo.distance($0.coordinate, exit) }.min() ?? .infinity, 400)
    }

    // MARK: - The track

    private struct Point {
        let coordinate: CLLocationCoordinate2D
        let activity: DryRunGenerator.Activity
        /// Seconds since the activity began.
        let intoActivity: Int
    }

    /// The generator's fixes to the end (or `until`), each with what the aircraft was doing.
    private func flownTrack(_ generator: DryRunGenerator,
                            until done: (DryRunGenerator) -> Bool = { $0.isParkedForGood }) -> [Point] {
        var track: [Point] = []
        for _ in 0..<(3 * 3600) where !done(generator) {
            let fix = generator.nextFix()
            track.append(Point(coordinate: fix.coordinate, activity: generator.activity,
                               intoActivity: generator.t - generator.activitySince))
        }
        return track
    }

    /// Metres from `point` to the nearest segment of `line` (a local flat projection, plenty for a circuit).
    private func offLine(_ point: CLLocationCoordinate2D, _ line: [CLLocationCoordinate2D]) -> Double {
        let metresPerDegree = 111_320.0
        let k = cos(point.latitude * .pi / 180)
        func xy(_ c: CLLocationCoordinate2D) -> (Double, Double) {
            ((c.longitude - point.longitude) * metresPerDegree * k, (c.latitude - point.latitude) * metresPerDegree)
        }
        return zip(line, line.dropFirst()).map { a, b -> Double in
            let (ax, ay) = xy(a), (bx, by) = xy(b)
            let dx = bx - ax, dy = by - ay
            let t = max(0, min(1, -(ax * dx + ay * dy) / max(dx * dx + dy * dy, 1)))
            return hypot(ax + t * dx, ay + t * dy)
        }.min() ?? .infinity
    }

    // MARK: - The referee

    private struct Flown {
        let start: Date
        let events: [EmittedFlightEvent]
        let cues: [FlightCueEvent]
        let takeoffs: Int

        func seconds(_ date: Date) -> Double { date.timeIntervalSince(start) }

        var firedCues: [FlightCue] {
            cues.compactMap { event in
                if case .fired(let cue) = event.kind, !event.implied { return cue }
                return nil
            }
        }
    }

    /// The generator flown to its end, the detector fed as the app feeds it.
    private func fly(_ generator: DryRunGenerator, vso: Double = 33, vr: Double = 40,
                     destination: CLLocationCoordinate2D? = nil) -> Flown {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let aerodromes = [DryRunAerodrome.lszq, lsgc].map(\.airport)
        let detector = FlightEventDetector()
        detector.configure(vsoKts: vso, vrKts: vr)
        detector.cueDestination = destination
        var now = start
        detector.clock = { now }
        var lastFed: Int?
        var takeoffSet = false
        var parkedFor = 0
        // To the end, and a minute parked after, as long as a whole flight might take.
        for _ in 0..<(5 * 3600) {
            let fix = generator.nextFix()
            now = start.addingTimeInterval(TimeInterval(fix.t))
            if generator.isParkedForGood { parkedFor += 1 }
            if parkedFor > 60 { break }
            guard lastFed.map({ fix.t - $0 >= 5 }) ?? true else { continue }
            lastFed = fix.t
            if !takeoffSet, let lineUp = generator.mark("lineUp") {
                detector.setTakeoffTime(start.addingTimeInterval(TimeInterval(lineUp)))
                takeoffSet = true
            }
            let near = aerodromes.filter { $0.distance(from: fix.coordinate) <= 5 }
            detector.processLocation(fix.location(at: now), nearbyAirports: near)
        }
        _ = detector.flushEndOfFlight()
        return Flown(start: start, events: detector.emittedEvents, cues: detector.cueEvents,
                     takeoffs: detector.takeoffTimes.count)
    }
}
