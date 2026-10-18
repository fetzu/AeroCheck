import XCTest
import CoreLocation
@testable import AeroCheck

/// Tests for the post-flight reconciliation pass (decision D2): the offline
/// re-segmentation of a finished flight's track, the diff against confirmed events, and
/// its application to the logbook. The detector core itself is pinned by the corpus
/// fixtures in FlightEventDetectorTests — these tests exercise the diff/apply layer on
/// top of it, using a real corpus fixture as the track source.
@MainActor
final class FlightReconciliationTests: XCTestCase {

    // MARK: - Fixture plumbing (mirrors FlightEventDetectorTests)

    private struct FixtureAirport: Decodable {
        let ident: String
        let name: String
        let lat: Double
        let lon: Double
        let elev: Int?
        let type: String
    }

    private struct FixtureEvent: Decodable {
        let type: String
        let t: Double
    }

    private struct CorpusFixture: Decodable {
        let name: String
        let vso: Double
        let vr: Double
        let airports: [FixtureAirport]
        /// [t, lat, lon, alt m, speed m/s, hacc], and the course (null) and the barometer on a flight recorded with one.
        let track: [[Double?]]
        let expectedEvents: [FixtureEvent]
        let expectedTakeoffs: [Double]
    }

    /// The strong-wind circuit session: 7 landings, the canonical missed-prompt flight.
    private func loadCircuitFixture() throws -> CorpusFixture {
        try loadFixture("20260430_1053")
    }

    private func loadFixture(_ name: String) throws -> CorpusFixture {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.urls(forResourcesWithExtension: "json", subdirectory: "FlightEventFixtures")?
            .first(where: { $0.lastPathComponent.contains(name) }) else {
            throw XCTSkip("Fixture \(name) missing from test bundle")
        }
        return try JSONDecoder().decode(CorpusFixture.self, from: Data(contentsOf: url))
    }

    private func airports(from fixture: CorpusFixture) -> [Airport] {
        fixture.airports.enumerated().map { index, fx in
            Airport(id: index, ident: fx.ident, type: AirportType(rawValue: fx.type) ?? .smallAirport,
                    name: fx.name, latitude: fx.lat, longitude: fx.lon, elevation: fx.elev,
                    continent: nil, isoCountry: "", isoRegion: "", municipality: nil,
                    scheduledService: false, gpsCode: nil, iataCode: nil, localCode: nil)
        }
    }

    private func nearestQuery(_ all: [Airport]) -> (CLLocationCoordinate2D) -> [Airport] {
        { coordinate in
            let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return all
                .map { ($0, here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) }
                .filter { $0.1 / 1852.0 <= 5.0 }
                .sorted { $0.1 < $1.1 }
                .prefix(3)
                .map(\.0)
        }
    }

    private func speeds(vso: Double, vr: Double) -> [SpeedReference] {
        [SpeedReference(name: "Vso", description: "", value: String(Int(vso))),
         SpeedReference(name: "Vr", description: "", value: String(Int(vr)))]
    }

    /// A Flight carrying the fixture's track and the given recorded events.
    private func flight(from fixture: CorpusFixture,
                        goArounds: [Date] = [], touchAndGos: [Date] = [], fullStops: [Date] = []) -> Flight {
        var flight = Flight()
        flight.gpsTrack = fixture.track.compactMap { sample in
            guard let t = sample[0], let lat = sample[1], let lon = sample[2], let alt = sample[3],
                  let speed = sample[4] else { return nil }
            return GPSPoint(latitude: lat, longitude: lon, altitude: alt, timestamp: Date(timeIntervalSince1970: t),
                            speed: speed, course: 0, horizontalAccuracy: sample[5],
                            baroAltitude: sample.count > 7 ? sample[7] : nil)
        }
        flight.goAroundTimes = goArounds
        flight.touchAndGoTimes = touchAndGos
        flight.fullStopTimes = fullStops
        flight.goAroundCount = goArounds.count
        flight.touchAndGoCount = touchAndGos.count
        flight.fullStopCount = fullStops.count
        return flight
    }

    // MARK: - Diff behaviour

    /// Prompts auto-dismiss in the circuit: only 2 of 7 landings were confirmed. The
    /// reconciliation must surface the other 5 as detected-only rows, and applying must
    /// bring the logbook to the track's 7.
    func testMissedEventsSurfaceAsDiffAndApply() throws {
        let fixture = try loadCircuitFixture()
        let expected = fixture.expectedEvents
        XCTAssertGreaterThanOrEqual(expected.count, 5, "circuit fixture should be event-rich")

        // Pilot confirmed the first and last expected events, at their exact times/types.
        let confirmed = [expected.first!, expected.last!]
        var flight = self.flight(
            from: fixture,
            goArounds: confirmed.filter { $0.type == "GA" }.map { Date(timeIntervalSince1970: $0.t) },
            touchAndGos: confirmed.filter { $0.type == "TG" }.map { Date(timeIntervalSince1970: $0.t) },
            fullStops: confirmed.filter { $0.type == "FS" }.map { Date(timeIntervalSince1970: $0.t) }
        )

        let result = FlightReconciliation.analyze(
            flight: flight, speeds: speeds(vso: fixture.vso, vr: fixture.vr),
            stallSpeed: 42, nearbyAirports: nearestQuery(airports(from: fixture))
        )

        XCTAssertTrue(result.hasEventDiff)
        XCTAssertEqual(result.events.count, expected.count, "one row per physical event")
        let detectedOnly = result.events.filter { $0.source == .detectedOnly }
        XCTAssertEqual(detectedOnly.count, expected.count - confirmed.count)
        let rowCodes = result.events.map { row -> String in
            switch row.type {
            case .fullStop: return "FS"
            case .touchAndGo: return "TG"
            case .goAround: return "GA"
            }
        }
        XCTAssertEqual(rowCodes, expected.map(\.type), "row types must follow the track's reading")

        FlightReconciliation.apply(result, to: &flight)
        XCTAssertEqual(flight.fullStopCount + flight.touchAndGoCount,
                       expected.filter { $0.type != "GA" }.count)
        XCTAssertEqual(flight.goAroundCount, expected.filter { $0.type == "GA" }.count)
        XCTAssertEqual(flight.landingTime, flight.fullStopTimes.max())
    }

    /// When the pilot confirmed everything the track shows, there is nothing to review.
    func testFullAgreementProducesNoDiff() throws {
        let fixture = try loadCircuitFixture()
        let flight = self.flight(
            from: fixture,
            goArounds: fixture.expectedEvents.filter { $0.type == "GA" }.map { Date(timeIntervalSince1970: $0.t) },
            touchAndGos: fixture.expectedEvents.filter { $0.type == "TG" }.map { Date(timeIntervalSince1970: $0.t) },
            fullStops: fixture.expectedEvents.filter { $0.type == "FS" }.map { Date(timeIntervalSince1970: $0.t) }
        )
        let result = FlightReconciliation.analyze(
            flight: flight, speeds: speeds(vso: fixture.vso, vr: fixture.vr),
            stallSpeed: 42, nearbyAirports: nearestQuery(airports(from: fixture))
        )
        XCTAssertFalse(result.hasEventDiff, "full agreement must not raise the review sheet")
        XCTAssertTrue(result.events.allSatisfy { $0.source == .confirmed })
    }

    /// What the app took in flight with no card is listed for the pilot to confirm, and the review, applied,
    /// leaves nothing taken to confirm (6.4.0).
    func testEventsTheAppTookAreListedToConfirm() throws {
        let fixture = try loadCircuitFixture()
        let times = fixture.expectedEvents.map { Date(timeIntervalSince1970: $0.t) }
        var flight = self.flight(
            from: fixture,
            goArounds: fixture.expectedEvents.filter { $0.type == "GA" }.map { Date(timeIntervalSince1970: $0.t) },
            touchAndGos: fixture.expectedEvents.filter { $0.type == "TG" }.map { Date(timeIntervalSince1970: $0.t) },
            fullStops: fixture.expectedEvents.filter { $0.type == "FS" }.map { Date(timeIntervalSince1970: $0.t) }
        )
        flight.takenEventTimes = times
        let result = FlightReconciliation.analyze(
            flight: flight, speeds: speeds(vso: fixture.vso, vr: fixture.vr),
            stallSpeed: 42, nearbyAirports: nearestQuery(airports(from: fixture))
        )
        XCTAssertTrue(result.hasEventDiff, "the review asks about what the app took")
        XCTAssertTrue(result.events.allSatisfy { $0.source == .taken }, "\(result.events.map(\.source))")
        FlightReconciliation.apply(result, to: &flight)
        XCTAssertNil(flight.takenEventTimes)
        XCTAssertEqual(flight.goAroundTimes.count + flight.touchAndGoTimes.count + flight.fullStopTimes.count, times.count)
    }

    /// A confirmed go-around on what the track reads as a touch surfaces as ONE
    /// type-mismatch row (the <15 ft ambiguity band's human-resolution case).
    func testTypeMismatchSurfacesAsSingleRow() throws {
        let fixture = try loadCircuitFixture()
        guard let firstTouch = fixture.expectedEvents.first(where: { $0.type == "TG" }) else {
            throw XCTSkip("fixture has no touch-and-go")
        }
        let flight = self.flight(from: fixture,
                                 goArounds: [Date(timeIntervalSince1970: firstTouch.t)])
        let result = FlightReconciliation.analyze(
            flight: flight, speeds: speeds(vso: fixture.vso, vr: fixture.vr),
            stallSpeed: 42, nearbyAirports: nearestQuery(airports(from: fixture))
        )
        let mismatches = result.events.filter {
            if case .typeMismatch(let recorded) = $0.source { return recorded == .goAround }
            return false
        }
        XCTAssertEqual(mismatches.count, 1, "the confirmed GA and the detected TG are one physical event")
        XCTAssertEqual(mismatches.first?.type, .touchAndGo, "the row starts at the track's reading")
        XCTAssertTrue(result.hasEventDiff)
    }

    /// A recorded double-tap (second landing 30 s after the first — physically
    /// impossible) is refused by the reconciliation.
    func testDuplicateRecordedLandingIsDropped() throws {
        let fixture = try loadCircuitFixture()
        guard let touch = fixture.expectedEvents.first(where: { $0.type != "GA" }) else {
            throw XCTSkip("fixture has no landing")
        }
        let real = Date(timeIntervalSince1970: touch.t)
        let doubleTap = real.addingTimeInterval(30)
        var flight = self.flight(from: fixture,
                                 touchAndGos: touch.type == "TG" ? [real] : [],
                                 fullStops: (touch.type == "FS" ? [real] : []) + [doubleTap])
        let result = FlightReconciliation.analyze(
            flight: flight, speeds: speeds(vso: fixture.vso, vr: fixture.vr),
            stallSpeed: 42, nearbyAirports: nearestQuery(airports(from: fixture))
        )
        XCTAssertFalse(result.events.contains { $0.timestamp == doubleTap },
                       "a landing 30 s after another landing is the same physical event")

        FlightReconciliation.apply(result, to: &flight)
        XCTAssertEqual(flight.fullStopCount + flight.touchAndGoCount,
                       fixture.expectedEvents.filter { $0.type != "GA" }.count)
    }

    /// Applying the review keeps the final landing END FLIGHT measured on the track. The rows carry
    /// the detector's stamp, the first fix on the runway, seconds after the touchdown: taking it back
    /// undid the measurement, and could move the logged minute. (6.1)
    func testApplyingTheReviewKeepsTheMeasuredTouchdown() throws {
        let knot = 0.514444, t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var points: [GPSPoint] = []
        var time = t0
        func at(_ heightFt: Double, _ kt: Double) {
            time = time.addingTimeInterval(6)
            points.append(GPSPoint(latitude: 47 + Double(points.count) * 0.002, longitude: 7,
                                   altitude: 500 + heightFt * 0.3048, timestamp: time, speed: kt * knot,
                                   horizontalAccuracy: 3.5))
        }
        for height in [0.0, 0, 50, 300, 600, 600, 300, 240, 180, 120, 60, 11] { at(height, 60) }
        at(1, 40)
        let detectorStamp = time                                   // the first fix on the runway
        for kt in [30.0, 15, 6] { at(0, kt) }
        let measured = try XCTUnwrap(TrackTimes.analyze(track: points, engineStart: nil, engineShutdown: nil).landing)
        XCTAssertLessThan(measured, detectorStamp)

        var flight = Flight(startTime: t0, landingTime: measured)
        flight.gpsTrack = points
        flight.fullStopTimes = [measured]
        flight.fullStopCount = 1
        let missed = t0.addingTimeInterval(30)
        let result = FlightReconciliation.Result(
            flightId: flight.id,
            events: [.init(type: .goAround, timestamp: missed, airportIdent: nil, source: .detectedOnly),
                     .init(type: .fullStop, timestamp: detectorStamp, airportIdent: nil, source: .confirmed)],
            trackBlockOff: nil, trackBlockOn: nil, backfillsBlockOff: false, backfillsBlockOn: false)

        FlightReconciliation.apply(result, to: &flight)

        XCTAssertEqual(flight.goAroundTimes, [missed], "the review itself is applied")
        XCTAssertEqual(flight.landingTime, measured)
        XCTAssertEqual(flight.fullStopTimes, [measured], "one landing, one time")

        // Without a touchdown in the track, the row's time is all there is.
        var sparse = Flight(startTime: t0)
        FlightReconciliation.apply(result, to: &sparse)
        XCTAssertEqual(sparse.landingTime, detectorStamp)
    }

    // MARK: - A landing marked later (6.4.1)

    private func analyze(_ flight: Flight, _ fixture: CorpusFixture) -> FlightReconciliation.Result {
        FlightReconciliation.analyze(flight: flight, speeds: speeds(vso: fixture.vso, vr: fixture.vr),
                                     stallSpeed: 42, nearbyAirports: nearestQuery(airports(from: fixture)))
    }

    private func times(_ fixture: CorpusFixture, _ type: String) -> [Date] {
        fixture.expectedEvents.filter { $0.type == type }.map { Date(timeIntervalSince1970: $0.t) }
    }

    private func isMarkedLater(_ row: FlightReconciliation.EventRow) -> Bool {
        if case .markedLater = row.source { return true }
        return false
    }

    /// LSZQ → LSZS of 23 Sep: the touchdown at Samedan missed live, FULL STOP held seven minutes later and stamped
    /// then. The review listed the track's full stop and the pressed one, applying wrote both: two landings, a
    /// phantom stop-and-go, and a flight time seven minutes long. Now one row, at the touchdown, the pilot's full
    /// stop, "you marked it at …"; applied, one landing at the measured touchdown.
    func testAFullStopMarkedSevenMinutesLateIsOneLandingAtTheTouchdown() throws {
        let fixture = try loadFixture("20260923_1033")
        let touchdown = try XCTUnwrap(times(fixture, "FS").first)
        let pressed = touchdown.addingTimeInterval(7 * 60)
        var flight = self.flight(from: fixture, fullStops: [pressed])
        flight.landingTime = pressed
        let measured = try XCTUnwrap(TrackTimes.analyze(track: flight.gpsTrack, engineStart: nil, engineShutdown: nil).landing)

        let result = analyze(flight, fixture)

        XCTAssertEqual(result.events.count, 1, "one landing: \(result.events.map(\.source))")
        let row = try XCTUnwrap(result.events.first)
        XCTAssertEqual(row.type, .fullStop)
        XCTAssertEqual(row.timestamp.timeIntervalSince(touchdown), 0, accuracy: 90, "at the track's touchdown")
        XCTAssertEqual(row.source, .markedLater(at: pressed))
        XCTAssertTrue(row.included)
        XCTAssertTrue(result.hasEventDiff, "the review shows the time it moves")

        FlightReconciliation.apply(result, to: &flight)
        XCTAssertEqual(flight.fullStopTimes, [measured], "one landing, at the measured touchdown")
        XCTAssertEqual(flight.landingTime, measured, "the flight time ends at the touchdown, not at the press")
        XCTAssertEqual(flight.totalLandings, 1)
        XCTAssertEqual(flight.intermediateFullStops?.count, 0, "no stop-and-go")
    }

    /// A press on final, before the touchdown, keeps the nearest match within two minutes, as before.
    func testAPressOnFinalKeepsTheNearestMatch() throws {
        let fixture = try loadFixture("20260923_1033")
        let touchdown = try XCTUnwrap(times(fixture, "FS").first)
        let result = analyze(self.flight(from: fixture, fullStops: [touchdown.addingTimeInterval(-60)]), fixture)
        XCTAssertEqual(result.events.map(\.source), [.confirmed])
    }

    /// A real stop-and-go is never taken for one landing: a full stop marked after the next take-off stays the
    /// pilot's own row, apart from the one the track shows before it.
    func testAStopAndGoIsNeverPairedAcrossItsTakeOff() throws {
        let fixture = try loadFixture("20260519_1050")        // FS TG FS TG FS, the first two full stops stop-and-goes
        let fullStops = times(fixture, "FS")
        let takeoffs = fixture.expectedTakeoffs.map { Date(timeIntervalSince1970: $0) }
        let secondTakeoff = try XCTUnwrap(takeoffs.first { $0 > fullStops[0] })
        let inTheClimb = secondTakeoff.addingTimeInterval(90)
        let flight = self.flight(from: fixture, touchAndGos: times(fixture, "TG"),
                                 fullStops: [inTheClimb] + fullStops.dropFirst())

        let result = analyze(flight, fixture)

        XCTAssertFalse(result.events.contains(where: isMarkedLater), "nothing paired across the take-off")
        XCTAssertTrue(result.events.contains { $0.source == .detectedOnly && $0.type == .fullStop
            && abs($0.timestamp.timeIntervalSince(fullStops[0])) < 90 }, "the stop-and-go the track shows")
        XCTAssertTrue(result.events.contains { $0.source == .confirmed && $0.timestamp == inTheClimb },
                      "and the pilot's own, apart")
    }

    /// Full-stop circuits whose laps' full stops were counted at NEW CIRCUIT, three minutes after a touchdown the
    /// live detection missed, before the next take-off: one landing per lap, each at its touchdown. Until 6.4.1
    /// each lap gave two (the track's and the lap's), a phantom stop-and-go per lap.
    func testLapFullStopsCountedLateAreOneLandingEach() throws {
        let fixture = try loadFixture("20260519_1050")
        let fullStops = times(fixture, "FS")
        let laps = fullStops.map { $0.addingTimeInterval(180) }
        var flight = self.flight(from: fixture, touchAndGos: times(fixture, "TG"), fullStops: laps)

        let result = analyze(flight, fixture)

        XCTAssertEqual(result.events.count, fixture.expectedEvents.count, "one row per landing")
        XCTAssertEqual(result.events.filter(isMarkedLater).map(\.source), laps.map { .markedLater(at: $0) })
        FlightReconciliation.apply(result, to: &flight)
        XCTAssertEqual(flight.fullStopCount, fullStops.count)
        XCTAssertEqual(flight.touchAndGoCount, times(fixture, "TG").count)
        XCTAssertEqual(flight.intermediateFullStops?.count, fullStops.count - 1, "the real stop-and-goes, no phantom")
        for (applied, touchdown) in zip(flight.fullStopTimes.sorted(), fullStops) {
            XCTAssertEqual(applied.timeIntervalSince(touchdown), 0, accuracy: 90, "each at its touchdown")
        }
    }

    /// The strong-wind circuits (20260430_1053): each touch-and-go pressed late in the climb, past the review's
    /// two-minute match, and the last full stop counted three minutes after its touchdown. One landing per lap.
    func testLandingsMarkedLateInTheCircuitAreOneLandingPerLap() throws {
        let fixture = try loadCircuitFixture()
        let touches = times(fixture, "TG"), fullStops = times(fixture, "FS")
        var flight = self.flight(from: fixture, goArounds: times(fixture, "GA"),
                                 touchAndGos: touches.map { $0.addingTimeInterval(150) },
                                 fullStops: fullStops.map { $0.addingTimeInterval(180) })

        let result = analyze(flight, fixture)

        XCTAssertEqual(result.events.count, fixture.expectedEvents.count, "one row per lap: \(result.events.map(\.source))")
        XCTAssertEqual(result.events.filter(isMarkedLater).count, touches.count + fullStops.count)
        FlightReconciliation.apply(result, to: &flight)
        XCTAssertEqual(flight.touchAndGoCount, touches.count)
        XCTAssertEqual(flight.fullStopCount, fullStops.count)
    }

    /// A touch-and-go pressed in the climb, past the two-minute match, is that touch-and-go: one row.
    func testATouchAndGoPressedLateInTheClimbIsOneRow() throws {
        let fixture = try loadCircuitFixture()
        var touches = times(fixture, "TG")
        let first = touches[0]
        touches[0] = first.addingTimeInterval(150)
        let result = analyze(self.flight(from: fixture, goArounds: times(fixture, "GA"), touchAndGos: touches,
                                         fullStops: times(fixture, "FS")), fixture)
        XCTAssertEqual(result.events.count, fixture.expectedEvents.count)
        let row = try XCTUnwrap(result.events.first { abs($0.timestamp.timeIntervalSince(first)) < 90 })
        XCTAssertEqual(row.type, .touchAndGo)
        XCTAssertEqual(row.source, .markedLater(at: touches[0]))
    }

    /// Applying never logs a landing after the measured touchdown when nothing took off after it: the regression
    /// that made the flight time seven minutes long (here kept as recorded, a row the review didn't pair).
    func testApplyingNeverLogsTheLandingAfterTheMeasuredTouchdown() throws {
        let knot = 0.514444, t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var points: [GPSPoint] = []
        var time = t0
        func at(_ heightFt: Double, _ kt: Double, seconds: TimeInterval = 6) {
            time = time.addingTimeInterval(seconds)
            points.append(GPSPoint(latitude: 47 + Double(points.count) * 0.0005, longitude: 7,
                                   altitude: 500 + heightFt * 0.3048, timestamp: time, speed: kt * knot,
                                   horizontalAccuracy: 3.5))
        }
        for height in [0.0, 0, 50, 300, 600, 600, 300, 240, 180, 120, 60, 11] { at(height, 60) }
        at(1, 40)
        for kt in [30.0, 15, 6, 8, 8, 8] { at(0, kt) }
        let measured = try XCTUnwrap(TrackTimes.analyze(track: points, engineStart: nil, engineShutdown: nil).landing)
        let pressed = time.addingTimeInterval(6 * 60)

        var flight = Flight(startTime: t0, landingTime: pressed)
        flight.gpsTrack = points
        flight.fullStopTimes = [pressed]
        flight.fullStopCount = 1
        let kept = FlightReconciliation.Result(
            flightId: flight.id,
            events: [.init(type: .fullStop, timestamp: pressed, airportIdent: nil, source: .confirmed)],
            trackBlockOff: nil, trackBlockOn: nil, backfillsBlockOff: false, backfillsBlockOn: false)
        FlightReconciliation.apply(kept, to: &flight)
        XCTAssertEqual(flight.landingTime, measured)
        XCTAssertEqual(flight.fullStopTimes, [measured])
    }

    // MARK: - Block-time back-fill

    /// 19 of 53 corpus flights had no block off (engine checklist never tapped) — the
    /// track knows better, and back-fill is additive only.
    func testBlockTimesBackfilledOnlyWhenMissing() throws {
        let fixture = try loadCircuitFixture()
        var flight = self.flight(from: fixture)
        XCTAssertNil(flight.blockOffTime)
        let result = FlightReconciliation.analyze(
            flight: flight, speeds: speeds(vso: fixture.vso, vr: fixture.vr),
            stallSpeed: 42, nearbyAirports: nearestQuery(airports(from: fixture))
        )
        XCTAssertNotNil(result.trackBlockOff)
        XCTAssertNotNil(result.trackBlockOn)
        XCTAssertTrue(result.backfillsBlockOff)
        XCTAssertTrue(result.trackBlockOff! < result.trackBlockOn!)

        FlightReconciliation.backfillBlockTimes(result, to: &flight)
        XCTAssertEqual(flight.blockOffTime, result.trackBlockOff)
        XCTAssertEqual(flight.blockOnTime, result.trackBlockOn)

        // A recorded value is never overwritten.
        let pilotEntered = Date(timeIntervalSince1970: 1)
        flight.blockOffTime = pilotEntered
        FlightReconciliation.backfillBlockTimes(result, to: &flight)
        XCTAssertEqual(flight.blockOffTime, pilotEntered)
    }

    /// The track rules, on a synthetic track: block off = first of two consecutive moving
    /// samples; block on = first stationary sample after the last moving pair.
    func testTrackBlockTimeRules() {
        var points: [GPSPoint] = []
        var t = Date(timeIntervalSince1970: 0)
        func add(_ speedMS: Double) {
            points.append(GPSPoint(latitude: 47, longitude: 8, altitude: 500, timestamp: t, speed: speedMS))
            t = t.addingTimeInterval(5)
        }
        add(0); add(0)                  // parked
        let firstMove = t; add(3); add(3); add(30)   // taxi + takeoff roll
        add(40); add(3); add(3)         // "flight" + taxi back
        let lastMovingPairEnd = t; add(3)   // last moving sample
        let cameToRest = t; add(0); add(0)  // final stillness
        _ = lastMovingPairEnd

        let (blockOff, blockOn) = FlightReconciliation.trackBlockTimes(track: points)
        XCTAssertEqual(blockOff, firstMove)
        XCTAssertEqual(blockOn, cameToRest)
    }
}
