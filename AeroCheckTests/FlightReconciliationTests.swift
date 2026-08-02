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
        let track: [[Double]]
        let expectedEvents: [FixtureEvent]
    }

    /// The strong-wind circuit session: 7 landings, the canonical missed-prompt flight.
    private func loadCircuitFixture() throws -> CorpusFixture {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.urls(forResourcesWithExtension: "json", subdirectory: "FlightEventFixtures")?
            .first(where: { $0.lastPathComponent.contains("20260430_1053") }) else {
            throw XCTSkip("Circuit fixture missing from test bundle")
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
        flight.gpsTrack = fixture.track.map { sample in
            GPSPoint(latitude: sample[1], longitude: sample[2], altitude: sample[3],
                     timestamp: Date(timeIntervalSince1970: sample[0]),
                     speed: sample[4], course: 0, horizontalAccuracy: sample[5])
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
