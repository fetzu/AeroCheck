import XCTest
import CoreLocation
@testable import AeroCheck

/// The cues from the flight (6.1, "Checks in flight", build plan 4), on synthetic tracks: when each fires
/// (take-off, level-off, descent, approach, circuit), what a later cue brings with it, and the descent a
/// flight climbs back from. The corpus flights pin the same rules to the Python prototype in
/// `FlightEventDetectorTests`; these show each rule on its own.
@MainActor
final class FlightCueTrackerTests: XCTestCase {

    private static func field(_ ident: String, northNm: Double = 0) -> Airport {
        Airport(id: ident.hashValue, ident: ident, type: .smallAirport, name: ident,
                latitude: 47.0 + northNm / 60.0, longitude: 8.0, elevation: 0, continent: "EU",
                isoCountry: "CH", isoRegion: "CH-JU", municipality: nil, scheduledService: false,
                gpsCode: nil, iataCode: nil, localCode: nil)
    }

    /// Feeds the detector at a 5 s cadence, the airports within 5 NM nearest first, as LocationManager
    /// does. Heights are above the take-off field: the parked calibration reads GPS 20 ft low.
    @MainActor
    private final class Driver {
        let detector = FlightEventDetector()
        let airports: [Airport]
        private(set) var now = Date(timeIntervalSince1970: 2_000_000)
        private(set) var northNm = 0.0

        init(airports: [Airport]) {
            self.airports = airports
            detector.configure(vsoKts: 33, vrKts: 40)
            detector.clock = { [unowned self] in self.now }
        }

        /// `count` fixes at `heightFt` (above the field) and `speedKts`, moving `nmEach` north per fix.
        func fly(heightFt: Double, speedKts: Double, count: Int, nmEach: Double = 0) {
            for _ in 0..<count { fix(heightFt: heightFt, speedKts: speedKts, nmEach: nmEach) }
        }

        /// A steady climb or descent at `fpm` for `seconds`.
        func vertical(from heightFt: Double, fpm: Double, seconds: Int, speedKts: Double = 90, nmEach: Double = 0) -> Double {
            var h = heightFt
            for _ in 0..<(seconds / 5) {
                h += fpm / 12
                fix(heightFt: h, speedKts: speedKts, nmEach: nmEach)
            }
            return h
        }

        private func fix(heightFt: Double, speedKts: Double, nmEach: Double) {
            northNm += nmEach
            let coordinate = CLLocationCoordinate2D(latitude: 47.0 + northNm / 60.0, longitude: 8.0)
            let location = CLLocation(coordinate: coordinate, altitude: (heightFt - 20) * 0.3048,
                                      horizontalAccuracy: 5, verticalAccuracy: 5, course: 0,
                                      speed: speedKts / 1.94384, timestamp: now)
            let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let near = airports
                .map { ($0, here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) / 1852) }
                .filter { $0.1 <= 5 }.sorted { $0.1 < $1.1 }.prefix(3).map(\.0)
            detector.processLocation(location, nearbyAirports: Array(near))
            now = now.addingTimeInterval(5)
        }

        /// Parked, the take-off roll, lifted off: the leg starts.
        func takeOff() {
            fly(heightFt: 0, speedKts: 0, count: 6)
            fly(heightFt: 0, speedKts: 30, count: 1)
            fly(heightFt: 10, speedKts: 55, count: 2)
        }

        var fired: [FlightCue] {
            detector.cueEvents.compactMap { if case .fired(let cue) = $0.kind { return cue } else { return nil } }
        }

        func event(_ cue: FlightCue) -> FlightCueEvent? {
            detector.cueEvents.last { $0.kind == .fired(cue) }
        }
    }

    // MARK: Take-off

    func testTheClimbCheckIsDueAt500FeetNotAtTheRoll() {
        let d = Driver(airports: [Self.field("TEST")])
        d.takeOff()
        XCTAssertEqual(d.detector.cueEvents.map(\.kind), [.leg], "the leg starts at the take-off roll")
        d.fly(heightFt: 300, speedKts: 65, count: 2)
        d.fly(heightFt: 480, speedKts: 70, count: 2)
        XCTAssertEqual(d.fired, [], "not at 300 ft ('has flown'), not below 500")
        let at500 = d.now
        d.fly(heightFt: 510, speedKts: 70, count: 1)
        XCTAssertEqual(d.fired, [.takeoff])
        XCTAssertEqual(d.event(.takeoff)?.time, at500)
        XCTAssertEqual(d.event(.takeoff)?.aerodrome, "TEST")
    }

    // MARK: Level-off

    func testLevelForAMinuteAbove1000FeetIsTheLevelOff() {
        let d = Driver(airports: [Self.field("TEST")])
        d.takeOff()
        let top = d.vertical(from: 0, fpm: 800, seconds: 150)          // to 2,000 ft
        XCTAssertFalse(d.fired.contains(.levelOff), "climbing")
        let levelled = d.now
        d.fly(heightFt: top, speedKts: 95, count: 16)
        let event = d.event(.levelOff)
        XCTAssertNotNil(event)
        XCTAssertLessThanOrEqual(event!.time.timeIntervalSince(levelled), 60, "within the minute of level flight")
    }

    func testACircuitAt900FeetIsNoLevelOff() {
        let d = Driver(airports: [Self.field("TEST")])
        d.takeOff()
        let top = d.vertical(from: 0, fpm: 800, seconds: 65)          // about 870 ft
        d.fly(heightFt: top, speedKts: 80, count: 36)                   // three minutes downwind
        XCTAssertEqual(d.fired, [.takeoff], "below 1,000 ft above the field: a circuit, not a cruise")
    }

    // MARK: Descent

    private func cruising(_ d: Driver, at height: Double = 3000) {
        d.takeOff()
        let top = d.vertical(from: 0, fpm: 900, seconds: Int(height / 900 * 60))
        d.fly(heightFt: top, speedKts: 100, count: 18)
        XCTAssertTrue(d.fired.contains(.levelOff))
    }

    func testTheDescentIsDueOnceItHasLost300Feet() {
        let d = Driver(airports: [Self.field("TEST")])
        cruising(d)
        let begun = d.now
        _ = d.vertical(from: 2990, fpm: -600, seconds: 60)
        let event = d.event(.descent)
        XCTAssertNotNil(event)
        let after = event!.time.timeIntervalSince(begun)
        XCTAssertTrue((25...45).contains(after), "−300 fpm over 30 s and 300 ft lost: \(after) s in")
    }

    func testADipInTheCruiseIsNoDescent() {
        let d = Driver(airports: [Self.field("TEST")])
        cruising(d)
        let low = d.vertical(from: 2990, fpm: -600, seconds: 15)      // 150 ft down in turbulence…
        d.fly(heightFt: low, speedKts: 100, count: 12)                  // …and level again
        XCTAssertFalse(d.fired.contains(.descent))
    }

    func testADescentTheFlightClimbsBackFromIsWithdrawnAndComesAgain() {
        let d = Driver(airports: [Self.field("TEST")])
        cruising(d)
        d.fly(heightFt: 3000, speedKts: 100, count: 25, nmEach: 0.3)    // en route, no aerodrome within 5 NM
        var h = d.vertical(from: 2990, fpm: -700, seconds: 60)
        XCTAssertTrue(d.fired.contains(.descent))
        h = d.vertical(from: h, fpm: 900, seconds: 60)                  // back up, above where it fired
        XCTAssertTrue(d.detector.cueEvents.contains { $0.kind == .withdrawn(.descent) })
        d.fly(heightFt: h, speedKts: 100, count: 12)
        _ = d.vertical(from: h, fpm: -700, seconds: 60)
        XCTAssertEqual(d.fired.filter { $0 == .descent }.count, 2, "due again on the real descent")
    }

    // MARK: Approach and circuit

    func testTheApproachIsDue5NmFromTheRoutesDestination() {
        let d = Driver(airports: [Self.field("TEST")])
        d.detector.cueDestination = CLLocationCoordinate2D(latitude: 47.0 + 12.0 / 60.0, longitude: 8.0)
        cruising(d)
        d.fly(heightFt: 3000, speedKts: 100, count: 20, nmEach: 0.3)    // 6 NM north: 6 NM to go
        XCTAssertFalse(d.fired.contains(.approach))
        d.fly(heightFt: 3000, speedKts: 100, count: 4, nmEach: 0.3)     // 4.8 NM to go
        XCTAssertEqual(d.event(.approach)?.aerodrome, FlightCueTracker.destinationMarker)
        XCTAssertTrue(d.detector.cueEvents.contains { $0.kind == .fired(.descent) && $0.implied },
                      "an approach says the descent began, even from level flight")
    }

    func testARoundTripsDestinationWaitsUntilTheFlightHasLeftIt() {
        let d = Driver(airports: [Self.field("TEST")])
        d.detector.cueDestination = CLLocationCoordinate2D(latitude: 47.0, longitude: 8.0)
        cruising(d)
        XCTAssertFalse(d.fired.contains(.approach), "just taken off from it")
        d.fly(heightFt: 3000, speedKts: 100, count: 25, nmEach: 0.3)    // 7.5 NM out…
        d.fly(heightFt: 3000, speedKts: 100, count: 10, nmEach: -0.3)   // …4.5 NM back
        XCTAssertNotNil(d.event(.approach))
    }

    func testWithoutARouteTheApproachIsDescendingNearAnAerodromeThenTheCircuitThere() {
        let d = Driver(airports: [Self.field("TEST"), Self.field("DEST", northNm: 10)])
        cruising(d)
        d.fly(heightFt: 3000, speedKts: 100, count: 24, nmEach: 0.3)    // 7.2 NM north, DEST 2.8 NM ahead
        XCTAssertFalse(d.fired.contains(.approach), "level near an aerodrome is no approach")
        var h = d.vertical(from: 2990, fpm: -700, seconds: 60, speedKts: 90)
        XCTAssertEqual(d.event(.approach)?.aerodrome, "DEST", "descending below 2,500 ft above it, within 5 NM")
        XCTAssertFalse(d.fired.contains(.circuit))
        h = d.vertical(from: h, fpm: -700, seconds: 90, speedKts: 80)   // down to circuit height
        XCTAssertEqual(d.event(.circuit)?.aerodrome, "DEST")
        XCTAssertEqual(d.fired, [.takeoff, .levelOff, .descent, .approach, .circuit], "each once, in order")
    }

    func testTheApproachWindowBringsTheApproachAndTheCircuit() {
        let d = Driver(airports: [Self.field("TEST")])
        d.takeOff()
        d.fly(heightFt: 400, speedKts: 70, count: 14)                    // past the 60 s suppression
        d.fly(heightFt: 800, speedKts: 75, count: 6)
        _ = d.vertical(from: 800, fpm: -600, seconds: 50, speedKts: 65)  // into the window: < 400 ft, descending
        XCTAssertNotNil(d.event(.approach))
        XCTAssertNotNil(d.event(.circuit))
        XCTAssertTrue(d.event(.levelOff)?.implied == true, "never levelled above 1,000 ft: implied")
    }

    func testEveryClimbAwayStartsANewLeg() {
        let d = Driver(airports: [Self.field("TEST")])
        d.takeOff()
        d.fly(heightFt: 400, speedKts: 70, count: 14)
        d.fly(heightFt: 800, speedKts: 75, count: 6)
        _ = d.vertical(from: 800, fpm: -600, seconds: 50, speedKts: 65)  // on final
        d.detector.notifyManualEvent(.goAround)                          // GO AROUND pressed: a climb-away
        d.fly(heightFt: 450, speedKts: 70, count: 2)
        XCTAssertEqual(d.detector.cueEvents.filter { $0.kind == .leg }.count, 2)
        XCTAssertEqual(d.fired.last, .circuit, "the new leg has nothing due yet")
        XCTAssertEqual(d.detector.emittedEvents, [], "the cues never emit a landing event")
    }
}

/// What the Cockpit makes of the cues: due, owed once, and the mapping to the checks, circuits included.
final class FlightCueStateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    func testWithoutAnyLegAnOpenCheckIsDueAsBefore() {
        let state = FlightCueState()
        XCTAssertEqual(state.timing(for: .climb, circuitMode: false), .due)
        XCTAssertEqual(state.timing(for: .taxi, circuitMode: false), .due)
    }

    func testWithAFieldToAnchorTheTakeoffTheClimbCheckWaitsForItsCue() {
        var state = FlightCueState()
        state.noteCueSource()
        XCTAssertTrue(state.hasCueSource)
        XCTAssertEqual(state.timing(for: .climb, circuitMode: false), .notYet, "on the runway, before the roll")
        XCTAssertEqual(state.timing(for: .beforeDeparture, circuitMode: false), .due, "not a cued check")
        state.startLeg()
        XCTAssertEqual(state.timing(for: .climb, circuitMode: false), .notYet, "the roll: still not yet")
        _ = state.fire(.takeoff, at: t0, circuitMode: false) { _ in true }
        XCTAssertEqual(state.timing(for: .climb, circuitMode: false), .due, "500 ft")
    }

    func testACheckpointFromBeforeTheCueSourceStillDecodes() throws {
        // A 6.1 build's checkpoint has no `cueSource` key, as a state without one encodes today: a
        // flight restored from one decodes as before.
        let old = try JSONEncoder().encode(FlightCueState())
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("cueSource"))
        let decoded = try JSONDecoder().decode(FlightCueState.self, from: old)
        XCTAssertFalse(decoded.hasCueSource)
        XCTAssertEqual(decoded.timing(for: .climb, circuitMode: false), .due)
    }

    func testACheckIsNotYetDueUntilItsCue() {
        var state = FlightCueState()
        state.startLeg()
        XCTAssertEqual(state.timing(for: .climb, circuitMode: false), .notYet)
        XCTAssertEqual(state.timing(for: .afterLanding, circuitMode: false), .due, "not a cued check")
        _ = state.fire(.takeoff, at: t0, circuitMode: false) { _ in true }
        XCTAssertEqual(state.timing(for: .climb, circuitMode: false), .due)
        XCTAssertEqual(state.timing(for: .cruise, circuitMode: false), .notYet)
    }

    func testAnOpenCheckTurnsOwedOnceAndStays() {
        var state = FlightCueState()
        state.startLeg()
        _ = state.fire(.takeoff, at: t0, circuitMode: false) { _ in true }
        let byLevelOff = state.fire(.levelOff, at: t0 + 60, circuitMode: false) { _ in true }
        XCTAssertEqual(byLevelOff, [.climb])
        XCTAssertEqual(state.timing(for: .climb, circuitMode: false), .owed)
        let byDescent = state.fire(.descent, at: t0 + 600, circuitMode: false) { _ in true }
        XCTAssertEqual(byDescent, [.cruise], "the climb check is not owed a second time")
        XCTAssertEqual(state.owed[.climb]?.cue, .levelOff)
        XCTAssertEqual(state.owed[.climb]?.at, t0 + 60)
    }

    func testADoneCheckIsNeverOwed() {
        var state = FlightCueState()
        state.startLeg()
        _ = state.fire(.takeoff, at: t0, circuitMode: false) { _ in true }
        XCTAssertEqual(state.fire(.levelOff, at: t0 + 60, circuitMode: false) { $0 != .climb }, [])
    }

    func testCuesArrivingTogetherOweNothing() {
        var state = FlightCueState()
        state.startLeg()
        // The approach window with nothing before it: every earlier cue implied at the same instant.
        for cue in [FlightCue.takeoff, .levelOff, .descent, .approach, .circuit] {
            XCTAssertEqual(state.fire(cue, at: t0, circuitMode: false) { _ in true }, [], "\(cue)")
        }
        XCTAssertTrue(state.landingShown(circuitMode: false))
    }

    func testANewLegForgetsWhatWasDueAndOwed() {
        var state = FlightCueState()
        state.startLeg()
        _ = state.fire(.takeoff, at: t0, circuitMode: false) { _ in true }
        _ = state.fire(.levelOff, at: t0 + 60, circuitMode: false) { _ in true }
        state.startLeg()
        XCTAssertEqual(state.timing(for: .climb, circuitMode: false), .notYet)
        XCTAssertTrue(state.owed.isEmpty)
    }

    func testAWithdrawnDescentIsNoLongerDueButWhatItMadeOwedStays() {
        var state = FlightCueState()
        state.startLeg()
        _ = state.fire(.takeoff, at: t0, circuitMode: false) { _ in true }
        _ = state.fire(.levelOff, at: t0 + 60, circuitMode: false) { _ in true }
        _ = state.fire(.descent, at: t0 + 600, circuitMode: false) { _ in true }
        XCTAssertTrue(state.descentBegun)
        state.withdraw(.descent)
        XCTAssertFalse(state.descentBegun)
        XCTAssertEqual(state.timing(for: .descent, circuitMode: false), .notYet)
        XCTAssertEqual(state.timing(for: .cruise, circuitMode: false), .owed)
    }

    func testInCircuitsTheDownwindMakesTheApproachDueAndTheBaseShowsTheLanding() {
        var state = FlightCueState()
        state.startLeg()
        _ = state.fire(.takeoff, at: t0, circuitMode: true) { _ in true }
        let owed = state.fire(.levelOff, at: t0 + 60, circuitMode: true) { _ in true }
        XCTAssertEqual(owed, [.climb])
        XCTAssertEqual(state.timing(for: .approach, circuitMode: true), .due)
        XCTAssertFalse(state.landingShown(circuitMode: true))
        let byBase = state.fire(.descent, at: t0 + 180, circuitMode: true) { _ in true }
        XCTAssertEqual(byBase, [.approach], "cruise and descent aren't flown in circuits")
        XCTAssertTrue(state.landingShown(circuitMode: true))
    }

    func testTheStateSurvivesTheCheckpointsEncoding() throws {
        var state = FlightCueState()
        state.startLeg()
        _ = state.fire(.takeoff, at: t0, circuitMode: false) { _ in true }
        _ = state.fire(.levelOff, at: t0 + 60, circuitMode: false) { _ in true }
        let decoded = try JSONDecoder().decode(FlightCueState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)

        var armed = FlightCueState()
        armed.noteCueSource()
        XCTAssertTrue(try JSONDecoder().decode(FlightCueState.self, from: JSONEncoder().encode(armed)).hasCueSource)
    }
}

/// The Cockpit on the cues: the slot's timing, owed once and what happens to it, FREDA giving way to the
/// descent check, the landing check shown from circuit height, and the record on the flight.
@MainActor
final class FlightCueCockpitTests: XCTestCase {

    private func flight(memoryTest: Bool = true, circuits: Bool = false) -> AppState {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.learningMode = !memoryTest
        appState.settings.stepByStepHighlighting = true
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9",
                             circuitMode: circuits)
        addTeardownBlock { @MainActor in appState.cancelFlight() }
        return appState
    }

    /// Every check before `phase` done, and the Cockpit on `phase`.
    private func onPhase(_ appState: AppState, _ phase: ChecklistPhase) {
        for earlier in ChecklistPhase.allCases where earlier.rawValue < phase.rawValue {
            let count = appState.activeChecklist.visibleItemCount(for: earlier, learningMode: true)
            appState.currentHighlightedItem[earlier] = ChecklistHighlighting.lastItemComplete(visibleCount: count)
            appState.phaseCompletionStatus[earlier] = earlier.isSkippedInCircuitMode(appState.isCircuitMode) ? .skipped : .completed
        }
        appState.highestCompletedPhase = phase
        appState.currentPhase = phase
    }

    private func requireMemory(_ appState: AppState, _ phases: [ChecklistPhase]) throws {
        for phase in phases {
            try XCTSkipUnless(appState.isMemoryCheck(phase, learningMode: false), "needs the WT9's memory \(phase)")
        }
    }

    /// The detector's cues, a minute apart, ending now; a leg first.
    private func cues(_ appState: AppState, _ list: [FlightCue], leg: Bool = true) {
        let now = Date()
        if leg { appState.noteFlightCue(FlightCueEvent(kind: .leg, time: now.addingTimeInterval(-900), implied: false, aerodrome: "LSGN")) }
        for (i, cue) in list.enumerated() {
            appState.noteFlightCue(FlightCueEvent(kind: .fired(cue), time: now.addingTimeInterval(Double(i - list.count + 1) * 60),
                                                  implied: false, aerodrome: nil))
        }
    }

    private func records(_ appState: AppState, _ kind: CheckRecord.Kind, _ phase: ChecklistPhase) -> [CheckRecord] {
        (appState.currentFlight?.checkRecords ?? []).filter { $0.kind == kind && $0.phase == phase }
    }

    private func slot(_ appState: AppState) -> CheckSlot { CockpitCheckSlot.slot(for: appState) }

    // MARK: Due

    func testTheClimbCheckGoesAmberAtTheTakeoffCueNotBefore() throws {
        let appState = flight()
        try requireMemory(appState, [.climb])
        onPhase(appState, .climb)
        XCTAssertEqual(slot(appState).tone, .due, "no cue source yet: due as before")
        cues(appState, [])
        XCTAssertEqual(slot(appState).tone, .idle, "the leg has started: not yet")
        XCTAssertEqual(slot(appState).action, .confirmFromMemory, "still one tap if the pilot does it early")
        cues(appState, [.takeoff], leg: false)
        XCTAssertEqual(slot(appState).tone, .due)
        XCTAssertEqual(slot(appState).line, .fromMemory)
    }

    func testWithAFieldNearbyTheClimbCheckIsNotAmberOnTheRunway() throws {
        // READY FOR LINE UP's one tap puts the Cockpit on CLIMB, on the runway. (6.1.0 ground replay, flight-3)
        let appState = flight()
        try requireMemory(appState, [.climb])
        onPhase(appState, .climb)
        appState.noteCueSourceReady()   // the detector's first fix near the departure field
        XCTAssertEqual(slot(appState).tone, .idle, "lined up: not yet")
        cues(appState, [])
        XCTAssertEqual(slot(appState).tone, .idle, "the roll: still not yet, no flicker")
        cues(appState, [.takeoff], leg: false)
        XCTAssertEqual(slot(appState).tone, .due, "500 ft")
    }

    func testANewFlightStartsWithoutACueSource() {
        let appState = flight()
        appState.noteCueSourceReady()
        appState.cancelFlight()
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
        XCTAssertFalse(appState.flightCues.hasCueSource)
    }

    // MARK: Owed

    func testLevellingOffWithTheClimbCheckOpenMakesItOwedOnce() throws {
        let appState = flight()
        try requireMemory(appState, [.climb])
        onPhase(appState, .climb)
        cues(appState, [.takeoff, .levelOff])
        XCTAssertEqual(slot(appState).tone, .owed)
        XCTAssertEqual(slot(appState).line, .owed(.levelOff))
        XCTAssertEqual(records(appState, .owed, .climb).count, 1)
        XCTAssertEqual(records(appState, .owed, .climb).first?.cue, .levelOff)
        appState.noteFlightCue(FlightCueEvent(kind: .fired(.descent), time: Date().addingTimeInterval(60), implied: false, aerodrome: nil))
        XCTAssertEqual(records(appState, .owed, .climb).count, 1, "never twice")
        XCTAssertEqual(slot(appState).line, .owed(.levelOff), "nothing changes on the slot either")
    }

    func testAnOwedCheckDoneIsRecordedLateAndUndoPutsItBack() throws {
        let appState = flight()
        try requireMemory(appState, [.climb])
        onPhase(appState, .climb)
        cues(appState, [.takeoff, .levelOff])
        appState.confirmMemoryCheck()
        XCTAssertNotEqual(appState.cueTiming(for: .climb), .owed)
        XCTAssertEqual(records(appState, .doneLate, .climb).count, 1)
        let confirmation = try XCTUnwrap(appState.memoryConfirmation)
        appState.undoMemoryConfirmation(confirmation.id)
        XCTAssertEqual(appState.cueTiming(for: .climb), .owed, "owed again")
        XCTAssertTrue(records(appState, .doneLate, .climb).isEmpty, "the late record goes with the undo")
    }

    func testAnOwedCheckStaysUntilSkippedExplicitly() throws {
        let appState = flight()
        try requireMemory(appState, [.climb])
        onPhase(appState, .climb)
        cues(appState, [.takeoff, .levelOff])
        appState.evaluateFreda()
        XCTAssertEqual(appState.cueTiming(for: .climb), .owed, "time passing changes nothing")
        appState.nextPhase()                                           // NEXT's review: CONTINUE, CHECK LATER
        XCTAssertEqual(appState.phaseCompletionStatus[.climb], .skipped)
        XCTAssertEqual(records(appState, .skipped, .climb).count, 1)
        XCTAssertNil(appState.flightCues.owed[.climb])
    }

    // MARK: FREDA gives way to the descent check

    private func cruiseWithFreda(_ appState: AppState) {
        onPhase(appState, .cruise)
        appState.markLastItemComplete(learningMode: appState.effectiveLearningMode)
        XCTAssertTrue(appState.freda.isRunning)
    }

    func testTheDescentCueInCruiseBringsTheDescentCheckToTheSlot() throws {
        let appState = flight()
        try requireMemory(appState, [.descent])
        cruiseWithFreda(appState)
        appState.evaluateFreda(now: Date().addingTimeInterval(11 * 60))
        XCTAssertTrue(appState.fredaDue)
        cues(appState, [.takeoff, .levelOff, .descent])
        XCTAssertFalse(appState.freda.isRunning, "FREDA gives way")
        XCTAssertEqual(appState.currentFlight?.fredaChecks?.last?.outcome, .missed, "the one due, as when cruise is left")
        appState.evaluateFreda(now: Date().addingTimeInterval(12 * 60))
        XCTAssertFalse(appState.freda.isRunning, "and doesn't start again on its own")
        let s = slot(appState)
        XCTAssertEqual(s.phase, .descent)
        XCTAssertEqual(s.action, .advanceAndConfirm)
        XCTAssertEqual(s.tone, .due)
        XCTAssertEqual(appState.currentPhase, .cruise, "the pane and the phase never change on their own")
    }

    func testTheSlotsOneTapGoesToTheDescentCheckAndUndoComesBack() throws {
        let appState = flight()
        try requireMemory(appState, [.descent])
        cruiseWithFreda(appState)
        cues(appState, [.takeoff, .levelOff, .descent])
        CockpitCheckSlot.perform(slot(appState).action, appState: appState, onShowChecklist: {})
        XCTAssertEqual(appState.currentPhase, .descent)
        XCTAssertEqual(appState.phaseCompletionStatus[.descent], .doneFromMemory)
        XCTAssertEqual(appState.phaseCompletionStatus[.cruise], .completed)
        let confirmation = try XCTUnwrap(appState.memoryConfirmation)
        appState.undoMemoryConfirmation(confirmation.id)
        XCTAssertEqual(appState.currentPhase, .cruise)
        XCTAssertNil(appState.phaseCompletionStatus[.descent])
    }

    func testAWithdrawnDescentLetsFredaCountAgain() {
        let appState = flight()
        cruiseWithFreda(appState)
        cues(appState, [.takeoff, .levelOff, .descent])
        appState.noteFlightCue(FlightCueEvent(kind: .withdrawn(.descent), time: Date(), implied: false, aerodrome: nil))
        appState.evaluateFreda()
        XCTAssertTrue(appState.freda.isRunning)
        XCTAssertEqual(slot(appState).action, .showChecklist, "FREDA counting again")
    }

    func testTheApproachCueOffersTheApproachCheckFromTheDescent() throws {
        let appState = flight()
        try requireMemory(appState, [.descent, .approach])
        onPhase(appState, .descent)
        appState.confirmMemoryCheck()
        cues(appState, [.takeoff, .levelOff, .descent])
        XCTAssertEqual(slot(appState).line, .next, "the next check, idle, before its cue")
        XCTAssertEqual(slot(appState).tone, .idle)
        cues(appState, [.approach], leg: false)
        XCTAssertEqual(slot(appState).phase, .approach)
        XCTAssertEqual(slot(appState).action, .advanceAndConfirm)
    }

    // MARK: The landing check, shown from circuit height

    func testFromCircuitHeightTheLandingCheckIsShownDashed() throws {
        let appState = flight()
        try requireMemory(appState, [.approach, .landing])
        onPhase(appState, .approach)
        cues(appState, [.takeoff, .levelOff, .descent, .approach, .circuit])
        let s = slot(appState)
        XCTAssertEqual(s.phase, .landing)
        XCTAssertEqual(s.tone, .quiet)
        XCTAssertEqual(s.line, .fromMemoryQuiet)
        XCTAssertEqual(s.action, .goToLanding)
        XCTAssertTrue(appState.landingCheckShown)
        XCTAssertEqual(records(appState, .owed, .approach).count, 1, "the open approach check, owed, not asked")
        CockpitCheckSlot.perform(s.action, appState: appState, onShowChecklist: {})
        XCTAssertEqual(appState.currentPhase, .landing)
        XCTAssertEqual(slot(appState).tone, .quiet, "still nothing to press")
    }

    func testCircuitsKeepTheirPhasesAndShowTheLandingOnBase() throws {
        let appState = flight(circuits: true)
        try requireMemory(appState, [.approach])
        onPhase(appState, .approach)
        cues(appState, [.takeoff, .levelOff])
        XCTAssertEqual(appState.cueTiming(for: .approach), .due, "the downwind")
        cues(appState, [.descent], leg: false)
        XCTAssertTrue(appState.landingCheckShown, "the base")
        XCTAssertFalse(appState.flightCues.owed.keys.contains(.cruise))
    }
}

/// The landed card (M4): after a full-stop landing on a flight that isn't circuits, one question, two
/// answers, and AFTER LANDING next. It waits; circuits keep their full-stop card and TAXI.
@MainActor
final class LandedCardTests: XCTestCase {

    private let touchdown = Date().addingTimeInterval(-45)

    private func flight(onPhase phase: ChecklistPhase = .landing, circuits: Bool = false) -> AppState {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.learningMode = false                          // the Memory test on
        appState.settings.stepByStepHighlighting = true
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9",
                             circuitMode: circuits)
        addTeardownBlock { @MainActor in appState.cancelFlight() }
        for earlier in ChecklistPhase.allCases where earlier.rawValue < phase.rawValue {
            let count = appState.activeChecklist.visibleItemCount(for: earlier, learningMode: true)
            appState.currentHighlightedItem[earlier] = ChecklistHighlighting.lastItemComplete(visibleCount: count)
            appState.phaseCompletionStatus[earlier] = earlier.isSkippedInCircuitMode(circuits) ? .skipped : .completed
        }
        appState.currentPhase = phase
        return appState
    }

    private func fullStop() -> DetectedFlightEvent {
        DetectedFlightEvent(type: .fullStop, timestamp: touchdown, airport: nil, message: "")
    }

    private func land(_ appState: AppState) {
        XCTAssertTrue(appState.takeFullStopForLandedCard(fullStop()))
        appState.presentLandedCard(touchdown: touchdown, aerodrome: "LSZQ")
    }

    func testAFullStopOnAFlightIsTheLandedCard() {
        let appState = flight()
        XCTAssertTrue(appState.takeFullStopForLandedCard(fullStop()))
        XCTAssertEqual(appState.landedCard?.touchdown, touchdown)
        XCTAssertFalse(appState.landingCheckSettled)
        XCTAssertEqual(appState.currentPhase, .landing, "nothing moves before the answer")
        XCTAssertEqual(appState.currentFlight?.fullStopCount, 0)
    }

    func testCircuitsKeepTheirFullStopCard() {
        let appState = flight(circuits: true)
        XCTAssertFalse(appState.takeFullStopForLandedCard(fullStop()))
        XCTAssertNil(appState.landedCard)
    }

    func testYesRecordsTheLandingCheckConfirmedAfterLanding() {
        let appState = flight()
        land(appState)
        appState.answerLandedCard(.yes)
        XCTAssertNil(appState.landedCard)
        XCTAssertEqual(appState.currentPhase, .afterLanding)
        XCTAssertEqual(appState.phaseCompletionStatus[.landing], .confirmedAfterLanding, "an outline, never solid green")
        XCTAssertFalse(appState.deferredChecks.contains(.landing))
        XCTAssertNil(appState.deferredItems[.landing])
        XCTAssertEqual(appState.currentFlight?.checkRecords?.last?.kind, .confirmedAfterLanding)
        XCTAssertEqual(appState.currentFlight?.fullStopCount, 1, "the landing, as CONFIRM recorded it")
        XCTAssertEqual(appState.landingTime, touchdown)
    }

    func testNotSureGoesToTheDebrief() {
        let appState = flight()
        land(appState)
        appState.answerLandedCard(.notSure)
        XCTAssertEqual(appState.currentPhase, .afterLanding)
        XCTAssertEqual(appState.phaseCompletionStatus[.landing], .notSure)
        XCTAssertFalse(appState.deferredChecks.contains(.landing), "nothing to fly after the landing")
        XCTAssertEqual(appState.currentFlight?.checkRecords?.last?.kind, .notSure)
        XCTAssertEqual(appState.currentFlight?.fullStopCount, 1)
    }

    func testALandingCheckDoneBeforeTouchdownIsNotAsked() {
        let appState = flight()
        appState.confirmMemoryCheck()
        land(appState)
        XCTAssertTrue(appState.landingCheckSettled)
        appState.answerLandedCard(.next)
        XCTAssertEqual(appState.currentPhase, .afterLanding)
        XCTAssertEqual(appState.phaseCompletionStatus[.landing], .doneFromMemory, "solid green: flown before touchdown")
        XCTAssertNil(appState.currentFlight?.checkRecords?.first { $0.kind == .confirmedAfterLanding })
    }

    func testChecksPassedOnTheWayAreSkippedNotDone() {
        let appState = flight(onPhase: .approach)
        land(appState)
        appState.answerLandedCard(.yes)
        XCTAssertEqual(appState.currentPhase, .afterLanding)
        XCTAssertEqual(appState.phaseCompletionStatus[.approach], .skipped, "the detection never ticks a check")
        XCTAssertEqual(appState.phaseCompletionStatus[.landing], .confirmedAfterLanding)
        XCTAssertTrue((appState.currentFlight?.checkRecords ?? []).contains { $0.kind == .skipped && $0.phase == .approach })
    }

    func testAfterTheAnswerTheAfterLandingCheckIsDueInTheSlot() {
        let appState = flight()
        land(appState)
        appState.answerLandedCard(.yes)
        let slot = CockpitCheckSlot.slot(for: appState)
        XCTAssertEqual(slot.phase, .afterLanding)
        XCTAssertEqual(slot.tone, .due)
    }

    func testTheCardWaitsUntilTheNextTakeoffRoll() {
        let appState = flight()
        land(appState)
        appState.evaluateFreda(now: Date().addingTimeInterval(3600))
        XCTAssertNotNil(appState.landedCard, "no timeout")
        appState.noteFlightCue(FlightCueEvent(kind: .leg, time: Date(), implied: false, aerodrome: "LSZQ"))
        XCTAssertNil(appState.landedCard, "gone at the take-off roll, unanswered")
        XCTAssertEqual(appState.currentFlight?.fullStopCount, 0, "and nothing recorded: END FLIGHT's review offers it")
    }

    func testTheAnswerSurvivesACrash() throws {
        let appState = flight()
        land(appState)
        appState.answerLandedCard(.yes)
        let flight = try XCTUnwrap(appState.currentFlight)
        let state = ActiveFlightState(flight: flight, from: appState)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(state.phaseCompletionStatus[.landing], .completed, "what an older build reads")
        let decoded = try JSONDecoder().decode(ActiveFlightState.self, from: data)
        let restored = makeTestAppState()
        decoded.restore(to: restored)
        XCTAssertEqual(restored.phaseCompletionStatus[.landing], .confirmedAfterLanding)
        restored.cancelFlight()
    }

    func testAnUnknownStatusFromANewerBuildReadsAsSkipped() throws {
        let decoded = try JSONDecoder().decode([PhaseCompletionStatus].self, from: Data(#"["confirmedAfterLanding","notSure","someday"]"#.utf8))
        XCTAssertEqual(decoded, [.confirmedAfterLanding, .notSure, .skipped])
    }
}

/// The record on the flight, for the debrief PR: optional, tolerant, append-only under sync.
final class CheckRecordTests: XCTestCase {

    private func flightJSON(records: String?) -> Data {
        var json = #"{"id":"6F0E6C1B-9D3C-4B8B-9E0B-6E3C2A3F4B11","airplane":"wt9-dynamic""#
        if let records { json += #","checkRecords":"# + records }
        return Data((json + "}").utf8)
    }

    func testAFlightWithoutRecordsDecodes() throws {
        let flight = try JSONDecoder().decode(Flight.self, from: flightJSON(records: nil))
        XCTAssertNil(flight.checkRecords)
    }

    func testRecordsRoundTrip() throws {
        var flight = Flight(airplane: "wt9-dynamic")
        flight.checkRecords = [CheckRecord(phase: .climb, kind: .owed, at: Date(timeIntervalSince1970: 100), cue: .levelOff),
                               CheckRecord(phase: .landing, kind: .confirmedAfterLanding, at: Date(timeIntervalSince1970: 200))]
        let decoded = try JSONDecoder().decode(Flight.self, from: JSONEncoder().encode(flight))
        XCTAssertEqual(decoded.checkRecords, flight.checkRecords)
    }

    func testARecordFromANewerBuildNeverFailsTheFlight() throws {
        let flight = try JSONDecoder().decode(Flight.self, from: flightJSON(records:
            #"[{"phaseRawValue":8,"kind":"someNewKind","at":0,"cue":99},{"phaseRawValue":42}]"#))
        XCTAssertEqual(flight.checkRecords?.count, 2)
        XCTAssertEqual(flight.checkRecords?.first?.kind, .owed, "an unknown kind reads as owed")
        XCTAssertNil(flight.checkRecords?.first?.cue)
        XCTAssertNil(flight.checkRecords?.last?.phase, "an unknown phase has none")
    }

    func testMergeKeepsTheLongerRecord() {
        var a = Flight(airplane: "wt9-dynamic", modifiedAt: Date(timeIntervalSince1970: 10))
        var b = a
        b.modifiedAt = Date(timeIntervalSince1970: 20)
        a.checkRecords = [CheckRecord(phase: .climb, kind: .owed, at: Date()), CheckRecord(phase: .climb, kind: .doneLate, at: Date())]
        b.checkRecords = nil                                             // a copy stripped by an older build
        XCTAssertEqual(Flight.merge(a, b).checkRecords?.count, 2)
    }

    func testRecordsAreBounded() {
        var flight = Flight(airplane: "wt9-dynamic")
        flight.checkRecords = (0..<(CheckRecord.maxPerFlight + 50)).map { _ in CheckRecord(phase: .climb, kind: .skipped, at: Date()) }
        XCTAssertEqual(flight.validatedForIngest()?.checkRecords?.count, CheckRecord.maxPerFlight)
    }
}

/// The Companion iPhone mirrors the slot and the landed card: snapshot fields and two commands, which an
/// older iPad neither sends nor takes.
@MainActor
final class FlightCueCompanionTests: XCTestCase {

    private func flight() -> AppState {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.learningMode = false                          // the Memory test on
        appState.settings.stepByStepHighlighting = true
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
        addTeardownBlock { @MainActor in appState.cancelFlight() }
        return appState
    }

    func testTheSnapshotCarriesTheSlotAndTheCard() throws {
        let appState = flight()
        appState.currentPhase = .climb
        appState.presentLandedCard(touchdown: Date(timeIntervalSince1970: 500), aerodrome: "LSZQ")
        let snapshot = CompanionConnectivityManager.checklistSnapshot(of: appState, mayStreamItemText: false)
        let wire = try JSONDecoder().decode(CompanionChecklistSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertTrue(wire.supportsFlightCues)
        let slot = try JSONDecoder().decode(CheckSlot.self, from: try XCTUnwrap(wire.checkSlotData))
        XCTAssertEqual(slot, CockpitCheckSlot.slot(for: appState))
        XCTAssertEqual(wire.landedCard?.aerodrome, "LSZQ")
        XCTAssertEqual(wire.landedCard?.id, appState.landedCard?.id)
    }

    func testAnOlderIPadsSnapshotHasNeither() throws {
        let old = try JSONDecoder().decode(CompanionChecklistSnapshot.self, from: Data(#"{"phaseTitle":"CLIMB","phaseRawValue":8}"#.utf8))
        XCTAssertFalse(old.supportsFlightCues)
        XCTAssertNil(old.checkSlotData)
        XCTAssertNil(old.landedCard)
    }

    func testAMalformedCardDoesNotLoseTheSnapshot() throws {
        let json = #"{"phaseTitle":"CLIMB","phaseRawValue":8,"landedCard":{"id":"x"},"supportsFlightCues":true}"#
        let snapshot = try JSONDecoder().decode(CompanionChecklistSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.landedCard)
        XCTAssertEqual(snapshot.phaseRawValue, 8)
    }

    func testThePhonesSlotTapIsTheIPadsWhileTheSlotIsTheSame() throws {
        let appState = flight()
        appState.settings.learningMode = false                          // the Memory test on
        appState.currentPhase = .climb
        let manager = makeTestPlanManager()
        let slot = CockpitCheckSlot.slot(for: appState)
        try XCTSkipUnless(slot.action == .confirmFromMemory, "needs the WT9's memory climb")
        CompanionConnectivityManager.apply(.checkSlotTap(phaseRawValue: ChecklistPhase.cruise.rawValue, action: slot.action.rawValue),
                                           appState: appState, flightPlanManager: manager)
        XCTAssertFalse(appState.currentCheckIsDone, "a tap for another check does nothing")
        CompanionConnectivityManager.apply(.checkSlotTap(phaseRawValue: slot.phase.rawValue, action: "advance"),
                                           appState: appState, flightPlanManager: manager)
        XCTAssertEqual(appState.currentPhase, .climb, "nor a tap for what the slot no longer does")
        CompanionConnectivityManager.apply(.checkSlotTap(phaseRawValue: slot.phase.rawValue, action: slot.action.rawValue),
                                           appState: appState, flightPlanManager: manager)
        XCTAssertTrue(appState.currentCheckIsDone)
    }

    func testThePhoneAnswersThatCardOnly() {
        let appState = flight()
        appState.currentPhase = .landing
        appState.presentLandedCard(touchdown: Date().addingTimeInterval(-30), aerodrome: "LSZQ")
        let manager = makeTestPlanManager()
        CompanionConnectivityManager.apply(.answerLandedCard(cardId: UUID(), answer: "yes"), appState: appState, flightPlanManager: manager)
        XCTAssertNotNil(appState.landedCard, "another card's answer")
        let id = appState.landedCard!.id
        CompanionConnectivityManager.apply(.answerLandedCard(cardId: id, answer: "notSure"), appState: appState, flightPlanManager: manager)
        XCTAssertNil(appState.landedCard)
        XCTAssertEqual(appState.phaseCompletionStatus[.landing], .notSure)
        XCTAssertEqual(appState.currentPhase, .afterLanding)
    }

    func testTheNewCommandsRoundTrip() throws {
        let id = UUID()
        for command in [CompanionCommand.checkSlotTap(phaseRawValue: 10, action: "advanceAndConfirm"),
                        .answerLandedCard(cardId: id, answer: "yes")] {
            let decoded = try JSONDecoder().decode(CompanionCommand.self, from: JSONEncoder().encode(command))
            XCTAssertEqual(String(describing: decoded), String(describing: command))
        }
    }
}
