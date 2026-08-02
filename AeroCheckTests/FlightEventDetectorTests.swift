import XCTest
import CoreLocation
@testable import AeroCheck

/// Tests for the v2 flight-event detector — a Swift port of the validated Python prototype
/// (CLAUDE/review/flight-events/detector_v2.py, 19/20 labeled flights, 43/49 exact landing
/// counts vs the club's billing export).
///
/// The heart of the suite is the CORPUS REPLAY: 17 real flights (the 10 pilot-labeled
/// flights, the circuit sessions, and the ground-effect / slow-flight / strong-wind
/// ambiguity cases) committed as downsampled fixtures, each carrying the full event
/// sequence the authoritative Python detector produced on exactly that data. The Swift
/// port must reproduce every sequence — event types in order, timestamps within ±90 s.
/// Any change to the detector that shifts these sequences must be re-validated against
/// the Python harness (the referee) before the fixtures are regenerated.
@MainActor
final class FlightEventDetectorTests: XCTestCase {

    // MARK: - Corpus fixtures

    private struct FixtureAirport: Decodable {
        let ident: String
        let name: String
        let lat: Double
        let lon: Double
        let elev: Int?
        let type: String
    }

    private struct FixtureEvent: Decodable {
        let type: String   // "FS" | "TG" | "GA"
        let t: Double      // epoch seconds
    }

    private struct CorpusFixture: Decodable {
        let name: String
        let registration: String?
        let vso: Double
        let vr: Double
        let airports: [FixtureAirport]
        /// [epochSeconds, lat, lon, altitudeM, speedMS, horizontalAccuracy]
        let track: [[Double]]
        let expectedEvents: [FixtureEvent]
        let expectedTakeoffs: [Double]
    }

    private func loadFixtures() throws -> [CorpusFixture] {
        let bundle = Bundle(for: Self.self)
        guard let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: "FlightEventFixtures"),
              !urls.isEmpty else {
            XCTFail("FlightEventFixtures resources missing from the test bundle")
            return []
        }
        let decoder = JSONDecoder()
        return try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try decoder.decode(CorpusFixture.self, from: Data(contentsOf: $0)) }
    }

    /// Mirror of the shipping feed: the 3 nearest fixed-wing airports within 5 nm.
    private func nearestAirports(lat: Double, lon: Double, in airports: [Airport]) -> [Airport] {
        let here = CLLocation(latitude: lat, longitude: lon)
        return airports
            .map { (airport: $0, meters: here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) }
            .filter { $0.meters / 1852.0 <= 5.0 }
            .sorted { $0.meters < $1.meters }
            .prefix(3)
            .map(\.airport)
    }

    private func airport(from fx: FixtureAirport, id: Int) -> Airport {
        let type = AirportType(rawValue: fx.type) ?? .smallAirport
        return Airport(id: id, ident: fx.ident, type: type, name: fx.name,
                       latitude: fx.lat, longitude: fx.lon, elevation: fx.elev,
                       continent: nil, isoCountry: "", isoRegion: "", municipality: nil,
                       scheduledService: false, gpsCode: nil, iataCode: nil, localCode: nil)
    }

    /// Replays a fixture through the detector exactly the way the harness replays it
    /// through the Python prototype: every valid fix in order, clock pinned to the
    /// sample's timestamp, end-of-flight flush at the last sample.
    private func replay(_ fixture: CorpusFixture) -> FlightEventDetector {
        let detector = FlightEventDetector()
        detector.configure(vsoKts: fixture.vso, vrKts: fixture.vr)
        let airports = fixture.airports.enumerated().map { airport(from: $1, id: $0) }
        var now = Date()
        detector.clock = { now }
        for sample in fixture.track {
            let (t, lat, lon, altM, speedMS, hacc) = (sample[0], sample[1], sample[2], sample[3], sample[4], sample[5])
            if hacc < 0 { continue }   // unusable fix, mirrors PR-37 and the harness
            now = Date(timeIntervalSince1970: t)
            let location = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                altitude: altM, horizontalAccuracy: hacc, verticalAccuracy: 10,
                course: 0, speed: speedMS, timestamp: now
            )
            detector.processLocation(location, nearbyAirports: nearestAirports(lat: lat, lon: lon, in: airports))
        }
        _ = detector.flushEndOfFlight()
        return detector
    }

    /// The pinned score: every fixture's full event SEQUENCE (type + time ±90 s), not
    /// just counts. 17 real flights: labels, circuits, and the ambiguity-band cases.
    func testCorpusFixturesReproduceValidatedEventSequences() throws {
        let fixtures = try loadFixtures()
        XCTAssertEqual(fixtures.count, 17, "Expected the 17 committed corpus fixtures")
        for fixture in fixtures {
            let detector = replay(fixture)
            let got = detector.emittedEvents
            let expected = fixture.expectedEvents

            XCTAssertEqual(
                got.map(\.type.corpusCode), expected.map(\.type),
                "\(fixture.name): event sequence mismatch — got \(got.map { "\($0.type.corpusCode)@\($0.timestamp)" })"
            )
            for (event, want) in zip(got, expected) where event.type.corpusCode == want.type {
                XCTAssertEqual(
                    event.timestamp.timeIntervalSince1970, want.t, accuracy: 90,
                    "\(fixture.name): \(want.type) timestamp off by more than 90 s"
                )
            }
        }
    }

    /// Takeoffs are first-class events: the detected liftoffs must match the harness.
    func testCorpusFixturesReproduceTakeoffTimes() throws {
        for fixture in try loadFixtures() {
            let detector = replay(fixture)
            XCTAssertEqual(detector.takeoffTimes.count, fixture.expectedTakeoffs.count,
                           "\(fixture.name): takeoff count mismatch")
            for (got, want) in zip(detector.takeoffTimes, fixture.expectedTakeoffs) {
                XCTAssertEqual(got.timeIntervalSince1970, want, accuracy: 90,
                               "\(fixture.name): takeoff time off by more than 90 s")
            }
        }
    }

    // MARK: - Full-corpus referee (dev machine only)

    /// Replays ALL 53 corpus flights against the Python referee's expected sequences.
    /// The full corpus lives outside the repo (BUFFER is never committed); regenerate the
    /// local fixtures with CLAUDE/review/flight-events/make_fixtures.py. Sequence equality
    /// on all 53 is what transitively pins the validated scores (19/20 labels, 43/49 exact
    /// vs club billing): the Python harness is the referee, this test is the handshake.
    /// Skips cleanly on any machine without the local corpus (CI, other checkouts).
    func testFullCorpusMatchesPythonReferee() throws {
        let corpusDir = URL(fileURLWithPath: "/Users/fetzu/Dev/AeroCheck/CLAUDE/review/flight-events/fixtures-all")
        guard FileManager.default.fileExists(atPath: corpusDir.path) else {
            throw XCTSkip("Local referee corpus not present — regenerate with make_fixtures.py")
        }
        let urls = try FileManager.default.contentsOfDirectory(at: corpusDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(urls.count, 50, "Corpus should hold the 53 flights")
        let decoder = JSONDecoder()
        for url in urls {
            let fixture = try decoder.decode(CorpusFixture.self, from: Data(contentsOf: url))
            let detector = replay(fixture)
            XCTAssertEqual(detector.emittedEvents.map(\.type.corpusCode),
                           fixture.expectedEvents.map(\.type),
                           "\(fixture.name): sequence diverges from the Python referee")
            for (event, want) in zip(detector.emittedEvents, fixture.expectedEvents) {
                XCTAssertEqual(event.timestamp.timeIntervalSince1970, want.t, accuracy: 90,
                               "\(fixture.name): \(want.type) timestamp diverges")
            }
        }
    }

    // MARK: - Scripted trajectories (unit-level)

    /// A flat test field at sea level (so altitude MSL == AGL ft) the trajectory flies over.
    private func testField() -> Airport {
        Airport(id: 1, ident: "TEST", type: .smallAirport, name: "Test Field",
                latitude: 47.0, longitude: 8.0, elevation: 0, continent: "EU",
                isoCountry: "CH", isoRegion: "CH-ZH", municipality: nil,
                scheduledService: false, gpsCode: nil, iataCode: nil, localCode: nil)
    }

    /// Drives the detector with scripted (altFt, speed kt) readings at a 5 s cadence on an
    /// injected clock. Position defaults to the field itself; `offsetNm` moves it north.
    /// Vso 33 / Vr 40 (WT9): touchdown < 45 kt, rollout dip < 28 kt, liftoff > 48 kt.
    @MainActor
    private final class TrajectoryDriver {
        let detector = FlightEventDetector()
        let field: Airport
        private(set) var now = Date(timeIntervalSince1970: 1_000_000)
        private let interval: TimeInterval = 5

        init(field: Airport) {
            self.field = field
            detector.configure(vsoKts: 33, vrKts: 40)
            detector.clock = { [weak self] in self?.now ?? Date() }
        }

        func fly(altFt: Double, speedKts: Double, count: Int, offsetNm: Double = 0,
                 baroAglFt: Double? = nil) {
            let coordinate = CLLocationCoordinate2D(
                latitude: field.latitude + offsetNm / 60.0,
                longitude: field.longitude
            )
            for _ in 0..<count {
                let location = CLLocation(
                    coordinate: coordinate,
                    altitude: altFt * 0.3048,
                    horizontalAccuracy: 5, verticalAccuracy: 5,
                    course: 0, speed: speedKts / 1.94384,
                    timestamp: now
                )
                // Baro rides on a CMAltimeter-style relative datum offset by −500 ft, so a
                // test can never pass by conflating relative baro with absolute altitude.
                let baro = baroAglFt.map { BaroAltitudeSample(relativeAltitudeFt: $0 - 500, timestamp: now) }
                detector.processLocation(location, nearbyAirports: [field], baroSample: baro)
                now = now.addingTimeInterval(interval)
            }
        }

        /// Parked calibration + takeoff + climb-out, ending airborne past the 60 s
        /// suppression window — shared preamble for the approach-phase tests.
        func takeoffAndClimb(baro: Bool = false) {
            fly(altFt: -20, speedKts: 0, count: 6, baroAglFt: baro ? 0 : nil)   // parked: bias ⇒ −20 ft, baro zero
            fly(altFt: -20, speedKts: 30, count: 1, baroAglFt: baro ? 0 : nil)  // roll start (>25 kt)
            fly(altFt: -10, speedKts: 55, count: 2, baroAglFt: baro ? 5 : nil)  // through Vr+5 ×2 ⇒ liftoff
            fly(altFt: 400, speedKts: 70, count: 14, baroAglFt: baro ? 420 : nil) // climb-out ⇒ hasFlown, 70 s
        }
    }

    /// Full pattern: takeoff, approach, touchdown, 10 s stillness ⇒ full stop stamped at
    /// the TOUCHDOWN time (not at the end of the stillness dwell).
    func testFullStopIsStampedAtTouchdown() {
        let d = TrajectoryDriver(field: testField())
        d.takeoffAndClimb()
        d.fly(altFt: 300, speedKts: 70, count: 2)    // descending trend into the window
        d.fly(altFt: 150, speedKts: 65, count: 2)
        d.fly(altFt: 40, speedKts: 55, count: 2)     // approach
        let touchdownStart = d.now
        d.fly(altFt: -20, speedKts: 40, count: 2)    // below touchdown speed ⇒ rollout
        d.fly(altFt: -20, speedKts: 3, count: 4)     // stillness ≥ 10 s ⇒ FS

        XCTAssertEqual(d.detector.emittedEvents.map(\.type), [.fullStop])
        let event = d.detector.emittedEvents[0]
        XCTAssertEqual(event.timestamp.timeIntervalSince(touchdownStart), 0, accuracy: 6,
                       "FS must carry the touchdown time, not the stillness-confirmation time")
        XCTAssertNotNil(d.detector.pendingFullStop)
        XCTAssertEqual(d.detector.pendingFullStop?.timestamp, event.timestamp)
    }

    /// A rollout in progress when recording stops is still a landing (end-of-flight flush;
    /// six of the 53 corpus flights need it).
    func testEndOfFlightFlushEmitsLandingInProgress() {
        let d = TrajectoryDriver(field: testField())
        d.takeoffAndClimb()
        d.fly(altFt: 300, speedKts: 70, count: 2)
        d.fly(altFt: 150, speedKts: 65, count: 2)
        d.fly(altFt: 40, speedKts: 55, count: 2)
        d.fly(altFt: -20, speedKts: 40, count: 2)    // rollout entered…
        d.fly(altFt: -20, speedKts: 15, count: 1)    // …still rolling when recording stops

        XCTAssertEqual(d.detector.emittedEvents, [], "No FS yet — stillness never completed")
        let flushed = d.detector.flushEndOfFlight()
        XCTAssertEqual(flushed?.type, .fullStop, "The interrupted rollout IS the landing")
        XCTAssertEqual(d.detector.emittedEvents.map(\.type), [.fullStop])
        XCTAssertNil(d.detector.flushEndOfFlight(), "Flush must be one-shot")
    }

    /// Ground-effect discrimination is the barometer's job (decision D3): the same 40 ft
    /// GPS pass classifies GA without baro, but TG when fresh baro shows a flat run below
    /// 15 ft — GPS bias error can hide a rolling touch, the baro cannot.
    func testBaroFlatRunReclassifiesLowPassAsTouchAndGo() {
        // Without baro: GPS says the pass bottomed at 40 ft corrected — go-around.
        let noBaro = TrajectoryDriver(field: testField())
        noBaro.takeoffAndClimb()
        noBaro.fly(altFt: 300, speedKts: 70, count: 2)
        noBaro.fly(altFt: 150, speedKts: 65, count: 2)
        noBaro.fly(altFt: 20, speedKts: 60, count: 4)    // GPS corrected AGL 40 ft, fast pass
        noBaro.fly(altFt: 250, speedKts: 70, count: 3)   // climb away ≥150 ft off the minimum
        XCTAssertEqual(noBaro.detector.emittedEvents.map(\.type), [.goAround])

        // With baro: identical GPS, but the barometer reads a flat run at 8 ft ⇒ wheels on.
        let baro = TrajectoryDriver(field: testField())
        baro.takeoffAndClimb(baro: true)
        baro.fly(altFt: 300, speedKts: 70, count: 2, baroAglFt: 320)
        baro.fly(altFt: 150, speedKts: 65, count: 2, baroAglFt: 160)
        baro.fly(altFt: 20, speedKts: 60, count: 4, baroAglFt: 8)   // flat pairs below 15 ft
        baro.fly(altFt: 250, speedKts: 70, count: 3, baroAglFt: 260)
        XCTAssertEqual(baro.detector.emittedEvents.map(\.type), [.touchAndGo],
                       "A baro flat run below 15 ft is ground contact regardless of GPS altitude")
    }

    /// Manual-event dedupe: after the pilot presses TOUCH AND GO, the detector's own
    /// classification of the same physical touch must not emit a duplicate.
    func testManualLandingSuppressesAutoDuplicate() {
        let d = TrajectoryDriver(field: testField())
        d.takeoffAndClimb()
        d.fly(altFt: 300, speedKts: 70, count: 2)
        d.fly(altFt: 150, speedKts: 65, count: 2)
        d.fly(altFt: 40, speedKts: 55, count: 2)
        d.fly(altFt: -20, speedKts: 40, count: 2)          // rollout, wheels on
        d.detector.notifyManualEvent(.touchAndGo)          // pilot logs it manually
        d.fly(altFt: -20, speedKts: 55, count: 2)          // accelerates…
        d.fly(altFt: 200, speedKts: 65, count: 3)          // …and climbs away

        XCTAssertEqual(d.detector.emittedEvents, [],
                       "The climb-away classification duplicates the manual T&G and must be suppressed")
    }

    /// The manual notify returns the PHYSICAL touchdown time while a rollout is in
    /// progress, so a LANDED tap while vacating records the real touchdown.
    func testManualNotifyReturnsTouchdownTime() {
        let d = TrajectoryDriver(field: testField())
        d.takeoffAndClimb()
        d.fly(altFt: 300, speedKts: 70, count: 2)
        d.fly(altFt: 150, speedKts: 65, count: 2)
        d.fly(altFt: 40, speedKts: 55, count: 2)
        let touchdownStart = d.now
        d.fly(altFt: -20, speedKts: 40, count: 2)
        d.fly(altFt: -20, speedKts: 8, count: 1)           // vacating
        let physical = d.detector.notifyManualEvent(.fullStop)
        XCTAssertNotNil(physical)
        XCTAssertEqual(physical!.timeIntervalSince(touchdownStart), 0, accuracy: 6)
    }

    /// An aborted takeoff (acceleration, then deceleration, never 300 ft) is a non-event
    /// by construction — no takeoff logged, no landing possible.
    func testAbortedTakeoffIsANonEvent() {
        let d = TrajectoryDriver(field: testField())
        d.fly(altFt: -20, speedKts: 0, count: 6)     // parked
        d.fly(altFt: -20, speedKts: 30, count: 1)
        d.fly(altFt: -15, speedKts: 55, count: 2)    // accelerates through Vr ⇒ climbout
        d.fly(altFt: -20, speedKts: 10, count: 3)    // rejects: decelerates on the runway
        d.fly(altFt: -20, speedKts: 3, count: 10)    // taxis back

        XCTAssertEqual(d.detector.emittedEvents, [], "A rejected takeoff must log nothing")
        XCTAssertNil(d.detector.pendingFullStop)
    }
}

private extension FlightEventType {
    /// The two-letter code used by the Python harness and the committed fixtures.
    var corpusCode: String {
        switch self {
        case .fullStop: return "FS"
        case .touchAndGo: return "TG"
        case .goAround: return "GA"
        }
    }
}

/// Block-time stamping (EASA FCL.010): block off = the FIRST moving fix of the movement
/// run (backdated when the 2-reading filter confirms); block on = the START of the final
/// stillness run, never overwritten per stationary sample. Measured on the corpus, the
/// old stamps were +7 s / +55 s median late ≈ +1 min of logged block time per flight.
@MainActor
final class BlockTimeBackdatingTests: XCTestCase {

    private func startedAppState() -> AppState {
        let appState = AppState()
        // AppState.init restores any checkpoint left in the shared simulator container —
        // neutralize an inherited phantom flight so this test starts from a clean slate.
        appState.cancelFlight()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.startFlight(
            withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA",
            aircraftType: "WT9", checklistVersion: nil, flightPlanId: nil, circuitMode: false
        )
        return appState
    }

    private func point(t: Date, speedMS: Double) -> GPSPoint {
        GPSPoint(latitude: 47, longitude: 8, altitude: 500, timestamp: t, speed: speedMS)
    }

    func testBlockOffBackdatesToFirstMovingFix() {
        let appState = startedAppState()
        defer { appState.cancelFlight() }
        appState.engineStartTime = Date(timeIntervalSince1970: 1_000_000)
        let t0 = Date(timeIntervalSince1970: 1_000_100)
        appState.addGPSPoint(point(t: t0, speedMS: 0))
        let firstMoving = t0.addingTimeInterval(5)
        appState.addGPSPoint(point(t: firstMoving, speedMS: 3))
        XCTAssertNil(appState.currentFlight?.blockOffTime, "One moving fix must not confirm block off")
        appState.addGPSPoint(point(t: t0.addingTimeInterval(10), speedMS: 3))
        XCTAssertEqual(appState.currentFlight?.blockOffTime, firstMoving,
                       "Block off must be backdated to the first moving fix of the run")
    }

    func testBlockOnIsStartOfFinalStillnessRun() {
        let appState = startedAppState()
        defer { appState.cancelFlight() }
        appState.engineStartTime = Date(timeIntervalSince1970: 1_000_000)
        var t = Date(timeIntervalSince1970: 1_000_100)
        func feed(_ speedMS: Double) {
            appState.addGPSPoint(point(t: t, speedMS: speedMS))
            t = t.addingTimeInterval(5)
        }
        feed(3); feed(3)                      // movement run ⇒ block off recorded
        feed(3)                               // taxi in after landing
        let firstStop = t
        feed(0); feed(0)                      // after-landing-check stop confirms
        XCTAssertEqual(appState.currentFlight?.blockOnTime, firstStop,
                       "Block on candidate is the START of the stillness run")
        feed(3); feed(3)                      // rolls to parking (2 moving samples break the run)
        let finalStop = t
        feed(0); feed(0); feed(0)             // comes to rest
        XCTAssertEqual(appState.currentFlight?.blockOnTime, finalStop,
                       "A later stillness run supersedes the earlier candidate")
        feed(3); feed(0)                      // one noisy moving sample while parked
        XCTAssertEqual(appState.currentFlight?.blockOnTime, finalStop,
                       "A single noisy sample must not restart the block-on clock")
    }
}
