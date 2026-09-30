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

    /// A cue the Python prototype observed (6.1): "leg", "takeoff" … "circuit", "descentWithdrawn".
    private struct FixtureCue: Decodable {
        let type: String
        let t: Double
        let implied: Bool
        let at: String?
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
        let expectedCues: [FixtureCue]?
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
        // 17 from the referee corpus, and the proposal's LSGN → LSZQ leg of 29.09.2026 for the cues (6.1).
        XCTAssertEqual(fixtures.count, 18, "Expected the 18 committed corpus fixtures")
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

    // MARK: - Flight cues (6.1)

    /// The cues, pinned to the Python prototype like the landing events: every fixture's full cue
    /// sequence (kind, implied or not, the aerodrome), times within 30 s. They are observed alongside the
    /// landing state machine and never written back into it: the event sequences above are unchanged.
    func testCorpusFixturesReproduceTheCueSequences() throws {
        for fixture in try loadFixtures() {
            let expected = try XCTUnwrap(fixture.expectedCues, "\(fixture.name): no expectedCues")
            assertCues(replay(fixture).cueEvents, expected, fixture.name)
        }
    }

    private func assertCues(_ got: [FlightCueEvent], _ expected: [FixtureCue], _ name: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.map(\.corpusCode), expected.map(\.type),
                       "\(name): cue sequence diverges from the Python prototype", file: file, line: line)
        for (cue, want) in zip(got, expected) where cue.corpusCode == want.type {
            XCTAssertEqual(cue.implied, want.implied, "\(name): \(want.type) implied", file: file, line: line)
            XCTAssertEqual(cue.aerodrome, want.at, "\(name): \(want.type) aerodrome", file: file, line: line)
            XCTAssertEqual(cue.time.timeIntervalSince1970, want.t, accuracy: 30,
                           "\(name): \(want.type) time", file: file, line: line)
        }
    }

    /// The proposal's worked example ("When each cue fires", LSGN → LSZQ, 29.09.2026): the slot would
    /// have turned at these moments, in this order, all before the touchdown at 14:44.
    func testTheProposalsLegCuesInOrder() throws {
        let fixture = try XCTUnwrap(try loadFixtures().first { $0.name.hasSuffix("20260929_1406_F-HVXA") })
        let detector = replay(fixture)
        let fired = detector.cueEvents.compactMap { event -> (FlightCue, Date)? in
            if case .fired(let cue) = event.kind, !event.implied { return (cue, event.time) }
            return nil
        }
        XCTAssertEqual(fired.map(\.0), [.takeoff, .levelOff, .descent, .approach, .circuit])
        let touchdown = try XCTUnwrap(detector.emittedEvents.last?.timestamp)
        let takeoff = try XCTUnwrap(detector.takeoffTimes.first)
        XCTAssertLessThan(fired[0].1.timeIntervalSince(takeoff), 60, "climb check due within a minute of the take-off")
        XCTAssertEqual(fired[3].1.timeIntervalSince(fired[2].1), 66, accuracy: 30, "approach a minute after the descent")
        XCTAssertGreaterThan(touchdown.timeIntervalSince(fired[4].1), 6 * 60, "circuit height seven minutes out")
        XCTAssertEqual(detector.cueEvents.filter { $0.kind == .fired(.approach) }.first?.aerodrome, "LSZQ")
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
            // And the cues, the same way (6.1). A corpus generated before them has none to compare.
            if let cues = fixture.expectedCues {
                assertCues(detector.cueEvents, cues, fixture.name)
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

    // MARK: - The full-stop card and where it takes the Cockpit (6.1.0)

    /// Take-off, circuit, touchdown, 10 s stopped: the detector's full stop, its card up. Returns
    /// when the touchdown began.
    @discardableResult
    private func landAndStop(_ d: TrajectoryDriver) -> Date {
        d.takeoffAndClimb()
        d.fly(altFt: 300, speedKts: 70, count: 2)
        d.fly(altFt: 150, speedKts: 65, count: 2)
        d.fly(altFt: 40, speedKts: 55, count: 2)
        let touchdown = d.now
        d.fly(altFt: -20, speedKts: 40, count: 2)
        d.fly(altFt: -20, speedKts: 3, count: 4)
        return touchdown
    }

    /// The card waits (6.1.0): no 3-minute expiry for a full stop, however long the pilot takes on
    /// the ground. The next take-off takes it away (dismissed, never confirmed), and what the
    /// detector emitted doesn't change.
    func testTheFullStopCardWaitsUntilTheNextTakeoff() {
        let d = TrajectoryDriver(field: testField())
        landAndStop(d)
        let card = d.detector.pendingFullStop
        XCTAssertNotNil(card)

        d.fly(altFt: -20, speedKts: 0, count: 120)        // ten minutes stopped
        d.fly(altFt: -20, speedKts: 10, count: 12)        // taxiing
        XCTAssertEqual(d.detector.pendingFullStop?.id, card?.id, "the card is still up, the same one")

        d.fly(altFt: -20, speedKts: 30, count: 1)
        d.fly(altFt: -10, speedKts: 55, count: 2)         // rolling for take-off (stop-and-go)
        XCTAssertNil(d.detector.pendingFullStop, "moot at the take-off, and never over the climb")
        XCTAssertEqual(d.detector.emittedEvents.map(\.type), [.fullStop])
    }

    /// Only the full stop waits: the go-around and touch-and-go cards come up in the climb-out and
    /// still go by themselves.
    func testOnlyTheFullStopCardWaits() {
        XCTAssertFalse(EventConfirmationView.dismissesByItself(.fullStop))
        XCTAssertTrue(EventConfirmationView.dismissesByItself(.goAround))
        XCTAssertTrue(EventConfirmationView.dismissesByItself(.touchAndGo))
    }

    /// The card's CONFIRM, on a flight that isn't circuits: AFTER LANDING, the checks kept, the
    /// landing stamped at touchdown, and the Companion iPhone's next snapshot on AFTER LANDING too.
    func testConfirmingTheCardOnAFlightGoesToAfterLanding() throws {
        let d = TrajectoryDriver(field: testField())
        let touchdown = landAndStop(d)
        let event = try XCTUnwrap(d.detector.pendingFullStop)
        let appState = wt9FlightOnLandingCheck(circuits: false)
        let highlights = appState.currentHighlightedItem

        FlightEventConfirmationOverlay.confirm(event, appState: appState, detector: d.detector)

        XCTAssertEqual(appState.currentPhase, .afterLanding)
        XCTAssertNil(d.detector.pendingFullStop, "the card goes")
        for phase in ChecklistPhase.allCases where phase.rawValue < ChecklistPhase.landing.rawValue {
            XCTAssertEqual(appState.phaseCompletionStatus[phase], .completed, "\(phase) kept")
            XCTAssertEqual(appState.currentHighlightedItem[phase], highlights[phase], "\(phase) kept")
        }
        XCTAssertEqual(appState.currentFlight?.fullStopCount, 1)
        XCTAssertEqual(appState.landingTime?.timeIntervalSince(touchdown) ?? 99, 0, accuracy: 6)
        XCTAssertEqual(appState.currentFlight?.landingTime, appState.landingTime)
        let snapshot = CompanionConnectivityManager.checklistSnapshot(of: appState, mayStreamItemText: false)
        XCTAssertEqual(snapshot.phaseRawValue, ChecklistPhase.afterLanding.rawValue, "the Companion follows")
    }

    /// Circuits keep the stop-and-go: the same CONFIRM goes to TAXI with taxi…after landing reset,
    /// and records the same landing.
    func testConfirmingTheCardOnCircuitsGoesToTaxi() throws {
        let d = TrajectoryDriver(field: testField())
        let touchdown = landAndStop(d)
        let event = try XCTUnwrap(d.detector.pendingFullStop)
        let appState = wt9FlightOnLandingCheck(circuits: true)

        FlightEventConfirmationOverlay.confirm(event, appState: appState, detector: d.detector)

        XCTAssertEqual(appState.currentPhase, .taxi)
        for phase in ChecklistPhase.allCases
        where phase.rawValue >= ChecklistPhase.taxi.rawValue && phase.rawValue <= ChecklistPhase.afterLanding.rawValue {
            XCTAssertNil(appState.phaseCompletionStatus[phase], "\(phase) starts again")
            XCTAssertEqual(appState.currentHighlightedItem[phase], 0, "\(phase) starts again")
        }
        XCTAssertEqual(appState.currentFlight?.fullStopCount, 1)
        XCTAssertEqual(appState.landingTime?.timeIntervalSince(touchdown) ?? 99, 0, accuracy: 6)
    }

    /// FULL STOP LANDING held on AFTER LANDING after the card was confirmed is the same landing: no
    /// second count, no landing time moved to "now". The pilot lands right next to that button now.
    func testFullStopLandingAfterTheCardIsTheSameLanding() throws {
        let d = TrajectoryDriver(field: testField())
        landAndStop(d)
        let event = try XCTUnwrap(d.detector.pendingFullStop)
        let appState = wt9FlightOnLandingCheck(circuits: false)
        FlightEventConfirmationOverlay.confirm(event, appState: appState, detector: d.detector)
        let landing = appState.landingTime
        d.fly(altFt: -20, speedKts: 0, count: 24)         // two minutes later, still on the ground

        // What FlightView's FULL STOP LANDING does.
        let physical = d.detector.notifyManualEvent(.fullStop)
        appState.recordLanding(at: physical)

        XCTAssertEqual(physical, event.timestamp, "the landing already detected on this ground")
        XCTAssertEqual(appState.currentFlight?.fullStopCount, 1, "one landing, counted once")
        XCTAssertEqual(appState.landingTime, landing)
        XCTAssertEqual(appState.currentPhase, .afterLanding)
    }

    /// A take-off since ends that landing: after a rejected take-off, back on the ground, a manual
    /// full stop is not stamped with the earlier touchdown.
    func testAManualFullStopAfterATakeoffIsNotTheEarlierLanding() {
        let d = TrajectoryDriver(field: testField())
        landAndStop(d)
        d.fly(altFt: -20, speedKts: 30, count: 1)
        d.fly(altFt: -15, speedKts: 55, count: 2)         // through Vr: a take-off roll…
        d.fly(altFt: -20, speedKts: 10, count: 3)         // …rejected
        d.fly(altFt: -20, speedKts: 0, count: 4)
        XCTAssertEqual(d.detector.emittedEvents.map(\.type), [.fullStop])
        XCTAssertNil(d.detector.notifyManualEvent(.fullStop))
    }
}

private extension FlightCueEvent {
    /// The prototype's name for it.
    var corpusCode: String {
        switch kind {
        case .leg: return "leg"
        case .fired(let cue): return cue.code
        case .withdrawn(let cue): return cue.code + "Withdrawn"
        }
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
        // Its own datastore, so there is no checkpoint to inherit (this used to cancel whatever flight
        // `init` restored, which in the shared simulator container was the app's real one).
        let appState = makeTestAppState()
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

// MARK: - Full-stop landings (6.1.0)

private extension XCTestCase {
    /// A WT9 flight on a confined datastore, flown up to its LANDING check: every check before it
    /// worked through (cruise and descent skipped on circuits), the landing check untouched.
    @MainActor
    func wt9FlightOnLandingCheck(circuits: Bool) -> AppState {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.learningMode = true
        appState.settings.stepByStepHighlighting = true
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9",
                             circuitMode: circuits)
        addTeardownBlock { @MainActor in appState.cancelFlight() }
        for phase in ChecklistPhase.allCases where phase.rawValue < ChecklistPhase.landing.rawValue {
            let count = appState.activeChecklist.visibleItemCount(for: phase, learningMode: true)
            appState.currentHighlightedItem[phase] = ChecklistHighlighting.lastItemComplete(visibleCount: count)
            appState.phaseCompletionStatus[phase] = phase.isSkippedInCircuitMode(circuits) ? .skipped : .completed
        }
        appState.currentPhase = .landing
        return appState
    }
}

/// Where a full-stop landing takes the Cockpit (6.1.0, author decision): on circuits, TAXI for the
/// next circuit (the stop-and-go, as before); on any other flight, AFTER LANDING with every check
/// kept, never back to taxi. The landing itself is recorded the same way on both. The detector's
/// card and FULL STOP LANDING are driven end to end in `FlightEventDetectorTests`.
@MainActor
final class FullStopLandingTests: XCTestCase {

    private let touchdown = Date().addingTimeInterval(-40)

    private func items(_ appState: AppState, _ phase: ChecklistPhase) -> [ChecklistItem] {
        appState.activeChecklist.visibleItems(for: phase, learningMode: true).filter { !$0.isHeader }
    }

    func testAFullStopEndsOnAfterLandingWithTheChecksKept() throws {
        let appState = wt9FlightOnLandingCheck(circuits: false)
        let landing = items(appState, .landing)
        try XCTSkipIf(landing.count < 2, "needs a landing check of two items or more")
        appState.currentHighlightedItem[.landing] = 1               // one item ticked
        let statuses = appState.phaseCompletionStatus
        let highlights = appState.currentHighlightedItem

        appState.recordFullStop(at: touchdown)

        XCTAssertEqual(appState.currentPhase, .afterLanding)
        for phase in ChecklistPhase.allCases where phase.rawValue < ChecklistPhase.landing.rawValue {
            XCTAssertEqual(appState.phaseCompletionStatus[phase], statuses[phase], "\(phase) kept")
            XCTAssertEqual(appState.currentHighlightedItem[phase], highlights[phase], "\(phase) kept")
        }
        XCTAssertEqual(appState.currentHighlightedItem[.landing], 1, "what was ticked stays ticked")
        XCTAssertEqual(appState.phaseCompletionStatus[.landing], .skipped, "left part-way, as NEXT leaves it")
        XCTAssertEqual(appState.deferredItems[.landing], landing.dropFirst().map(\.id), "the rest follows the pilot")
        assertOneLandingAtTouchdown(appState)
    }

    func testCircuitsStillStopAndGoToTaxi() {
        let appState = wt9FlightOnLandingCheck(circuits: true)
        appState.currentHighlightedItem[.landing] = 1
        appState.deferredItems[.approach] = ["x"]

        appState.recordFullStop(at: touchdown)

        XCTAssertEqual(appState.currentPhase, .taxi)
        for phase in ChecklistPhase.allCases
        where phase.rawValue >= ChecklistPhase.taxi.rawValue && phase.rawValue <= ChecklistPhase.afterLanding.rawValue {
            XCTAssertNil(appState.phaseCompletionStatus[phase], "\(phase) starts again")
            XCTAssertEqual(appState.currentHighlightedItem[phase], 0, "\(phase) starts again")
            XCTAssertNil(appState.deferredItems[phase], "\(phase) starts again")
        }
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .completed, "before taxi: kept")
        assertOneLandingAtTouchdown(appState)
    }

    /// The phase is the only difference: count, times and the flight's own landing time match.
    func testTheLandingIsRecordedTheSameOnEitherFlight() {
        let flight = wt9FlightOnLandingCheck(circuits: false)
        let circuits = wt9FlightOnLandingCheck(circuits: true)
        flight.recordFullStop(at: touchdown)
        circuits.recordFullStop(at: touchdown)
        XCTAssertEqual(flight.currentFlight?.fullStopCount, circuits.currentFlight?.fullStopCount)
        XCTAssertEqual(flight.currentFlight?.fullStopTimes, circuits.currentFlight?.fullStopTimes)
        XCTAssertEqual(flight.currentFlight?.landingTime, circuits.currentFlight?.landingTime)
        XCTAssertEqual(flight.landingTime, circuits.landingTime)
        XCTAssertEqual(flight.currentFlight?.touchAndGoCount, circuits.currentFlight?.touchAndGoCount)
    }

    /// Forward only: a pilot already on AFTER LANDING, or past it, stays there with their progress.
    func testAFullStopNeverTakesTheCockpitBack() {
        for phase in [ChecklistPhase.afterLanding, .shutdown, .hangar] {
            let appState = wt9FlightOnLandingCheck(circuits: false)
            appState.currentPhase = phase
            appState.currentHighlightedItem[phase] = 1
            appState.recordFullStop(at: touchdown)
            XCTAssertEqual(appState.currentPhase, phase)
            XCTAssertEqual(appState.currentHighlightedItem[phase], 1, "\(phase)")
            XCTAssertEqual(appState.currentFlight?.fullStopCount, 1, "\(phase)")
        }
    }

    /// Checks never ticked on the way are deferred whole, as a jump on the phase bar defers them:
    /// the detection never marks a check done.
    func testChecksPassedOnTheWayAreDeferredNotDone() throws {
        let appState = wt9FlightOnLandingCheck(circuits: false)
        try XCTSkipIf(items(appState, .approach).isEmpty || items(appState, .landing).isEmpty)
        appState.currentHighlightedItem[.approach] = 0
        appState.phaseCompletionStatus[.approach] = nil
        appState.currentPhase = .approach

        appState.recordFullStop(at: touchdown)

        XCTAssertEqual(appState.currentPhase, .afterLanding)
        XCTAssertEqual(appState.deferredChecks, [.approach, .landing])
        XCTAssertEqual(appState.phaseCompletionStatus[.approach], .skipped)
        XCTAssertEqual(appState.phaseCompletionStatus[.landing], .skipped)
    }

    /// AFTER LANDING has its own "stopped, so landed" fallback. After a full stop it must leave the
    /// landing alone: the phase change doesn't move the landing time or add a landing.
    func testAfterLandingsStopFallbackKeepsTheLanding() {
        let appState = wt9FlightOnLandingCheck(circuits: false)
        appState.recordFullStop(at: touchdown)
        var t = Date()
        for _ in 0..<5 {
            appState.addGPSPoint(GPSPoint(latitude: 47, longitude: 8, altitude: 500, timestamp: t, speed: 0))
            t = t.addingTimeInterval(5)
        }
        assertOneLandingAtTouchdown(appState)
    }

    /// FULL STOP LANDING (the AFTER LANDING page's own button) records the landing and moves nothing,
    /// on circuits as on any other flight.
    func testFullStopLandingOnAfterLandingStaysThere() {
        for circuits in [false, true] {
            let appState = wt9FlightOnLandingCheck(circuits: circuits)
            appState.currentPhase = .afterLanding
            appState.currentHighlightedItem[.afterLanding] = 1
            let statuses = appState.phaseCompletionStatus

            appState.recordLanding(at: touchdown)

            XCTAssertEqual(appState.currentPhase, .afterLanding, "circuits: \(circuits)")
            XCTAssertEqual(appState.currentHighlightedItem[.afterLanding], 1, "circuits: \(circuits)")
            XCTAssertEqual(appState.phaseCompletionStatus, statuses, "circuits: \(circuits)")
            assertOneLandingAtTouchdown(appState)
        }
    }

    /// A relaunch after a crash finds the flight where the full stop left it: on disk at once, not
    /// at the next throttled checkpoint.
    func testTheFullStopSurvivesACrash() throws {
        let datastore = makeTestDatastore()
        let defaults = makeTestDefaults()
        let source = makeTestAppState(datastore: datastore, defaults: defaults)
        source.settings.selectedRemoteAircraftId = nil
        source.settings.selectedAircraft = .wt9Dynamic
        source.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
        source.currentPhase = .landing
        source.recordFullStop(at: touchdown)
        source.flushPendingCheckpoint()

        let relaunched = makeTestAppState(datastore: datastore, defaults: defaults)
        XCTAssertTrue(relaunched.restoreActiveFlightState())
        XCTAssertEqual(relaunched.currentPhase, .afterLanding)
        XCTAssertEqual(relaunched.currentFlight?.fullStopCount, 1)
        XCTAssertEqual(relaunched.landingTime?.timeIntervalSince(touchdown) ?? 99, 0, accuracy: 1)
        relaunched.cancelFlight()
        source.cancelFlight()
    }

    private func assertOneLandingAtTouchdown(_ appState: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(appState.currentFlight?.fullStopCount, 1, file: file, line: line)
        XCTAssertEqual(appState.currentFlight?.fullStopTimes, [touchdown], file: file, line: line)
        XCTAssertEqual(appState.landingTime, touchdown, file: file, line: line)
        XCTAssertEqual(appState.currentFlight?.landingTime, touchdown, file: file, line: line)
        XCTAssertTrue(appState.hasLandingBeenDetected, file: file, line: line)
    }
}
