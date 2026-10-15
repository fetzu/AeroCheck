import XCTest
@testable import AeroCheck

/// The flight's clock out of DEBUG for dry runs (6.4.0): the wall clock unless a dry run runs one of its
/// own, its rate changed without a jump, a pause that stops it, the pilot's seconds counted at each
/// stretch's own rate, and what reads it on the wall's pace (FREDA's evaluation, the event card).
@MainActor
final class DryRunClockTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        // The clock is global: never leave a test's on for the next.
        FlightClock.endVirtual()
        super.tearDown()
    }

    /// A Release build starts on the wall clock, and so does a test (no replay in its environment).
    func testTheFlightsClockIsTheWallsUnlessADryRunRunsOne() {
        XCTAssertNil(FlightClock.virtual)
        XCTAssertEqual(FlightClock.now.timeIntervalSinceNow, 0, accuracy: 0.5)
        FlightClock.runVirtual(from: start, rate: 4)
        XCTAssertEqual(FlightClock.now.timeIntervalSince(start), 0, accuracy: 4)
        FlightClock.endVirtual()
        XCTAssertNil(FlightClock.virtual)
        XCTAssertEqual(FlightClock.now.timeIntervalSinceNow, 0, accuracy: 0.5)
    }

    /// 4×, paused, then 10×: the time goes on from where it was at each change, and stands still paused.
    func testARateChangeGoesOnFromWhereTheClockIsWithoutAJump() {
        let wall = Date()
        let at4 = FlightClock.Virtual(wallAnchor: wall, virtualAnchor: start, rate: 4)
        XCTAssertEqual(at4.virtual(at: wall.addingTimeInterval(10)), start.addingTimeInterval(40))
        let paused = at4.changingRate(to: 0, atWall: wall.addingTimeInterval(10))
        XCTAssertEqual(paused.virtual(at: wall.addingTimeInterval(100)), start.addingTimeInterval(40), "paused")
        let at10 = paused.changingRate(to: 10, atWall: wall.addingTimeInterval(100))
        XCTAssertEqual(at10.virtual(at: wall.addingTimeInterval(100)), start.addingTimeInterval(40), "no jump")
        XCTAssertEqual(at10.virtual(at: wall.addingTimeInterval(110)), start.addingTimeInterval(140))
        XCTAssertEqual(at10.earlier.map(\.rate), [4, 0])
    }

    func testAPausedDryRunsClockStandsStill() {
        FlightClock.runVirtual(from: start, rate: 10)
        FlightClock.setVirtualRate(0)
        let paused = FlightClock.now
        XCTAssertEqual(FlightClock.now, paused)
        FlightClock.setVirtualRate(4)
        XCTAssertEqual(FlightClock.virtual?.rate, 4)
        XCTAssertEqual(FlightClock.now.timeIntervalSince(paused), 0, accuracy: 1, "on from where it was")
    }

    /// An undo offered at 4× and taken back after the run went to 10×: the pilot's seconds are each
    /// stretch's at its own rate (10 s at 4×, then 10 s at 10×: 20 s), not the whole span at the last rate.
    func testThePilotsSecondsCountEachStretchAtItsOwnRate() {
        FlightClock.virtual = FlightClock.Virtual(
            wallAnchor: Date().addingTimeInterval(-10), virtualAnchor: start.addingTimeInterval(40), rate: 10,
            earlier: [.init(start: start, rate: 4)])
        XCTAssertEqual(FlightClock.pilotSeconds(since: start), 20, accuracy: 0.2)
        XCTAssertEqual(FlightClock.pilotSeconds(since: start.addingTimeInterval(40)), 10, accuracy: 0.2)
        XCTAssertEqual(FlightClock.pilotSeconds(since: FlightClock.now.addingTimeInterval(5)), 0, "not yet")
    }

    /// A paused stretch counts for nothing: an undo offer doesn't run out while the dry run is paused.
    func testAPauseCountsForNothing() {
        FlightClock.virtual = FlightClock.Virtual(
            wallAnchor: Date().addingTimeInterval(-10), virtualAnchor: start.addingTimeInterval(20), rate: 4,
            earlier: [.init(start: start, rate: 4), .init(start: start.addingTimeInterval(20), rate: 0)])
        XCTAssertEqual(FlightClock.pilotSeconds(since: start), 15, accuracy: 0.2, "5 s, a pause, then 10 s")
    }

    /// A test's clock stopped at a moment of its choosing (rate 0, the anchor moved): the seconds since an
    /// earlier moment are the virtual ones, as the undo and circuits tests have always read them.
    func testAStoppedTestClockCountsTheSecondsItWasMovedOn() {
        FlightClock.virtual = FlightClock.Virtual(wallAnchor: Date(), virtualAnchor: start.addingTimeInterval(30), rate: 0)
        XCTAssertEqual(FlightClock.pilotSeconds(since: start), 30, accuracy: 0.001)
    }

    // MARK: - On the wall's pace

    /// FREDA's evaluation every 5 s of the flight's clock, whatever the timer's ticks.
    func testFredaIsEvaluatedEveryFiveSecondsOfTheFlightsClock() {
        let cadence = FredaEvaluationCadence()
        XCTAssertTrue(cadence.isDue(at: start))
        XCTAssertFalse(cadence.isDue(at: start.addingTimeInterval(3)))
        XCTAssertTrue(cadence.isDue(at: start.addingTimeInterval(5)))
        XCTAssertFalse(cadence.isDue(at: start.addingTimeInterval(9.5)))
        XCTAssertTrue(cadence.isDue(at: start.addingTimeInterval(2)), "the clock went back (a new dry run)")
    }

    /// The go-around card's 20 s are the pilot's: shown 50 s of a 10× flight ago is 5 s ago.
    func testTheEventCardCountsThePilotsSeconds() {
        FlightClock.virtual = FlightClock.Virtual(wallAnchor: Date().addingTimeInterval(-5), virtualAnchor: start, rate: 10)
        XCTAssertEqual(EventConfirmationView.secondsLeft(shownAt: start), 15)
        FlightClock.setVirtualRate(0)
        let paused = EventConfirmationView.secondsLeft(shownAt: start)
        XCTAssertEqual(EventConfirmationView.secondsLeft(shownAt: start), paused, "paused: the countdown stands")
        FlightClock.endVirtual()
        XCTAssertEqual(EventConfirmationView.secondsLeft(shownAt: Date().addingTimeInterval(-25)), 0)
    }
}
