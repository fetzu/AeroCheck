import XCTest
@testable import AeroCheck

/// The pilot's map's monthly online allowance (6.8.0, t3 A): free 1,500 reads, Pro and lifetime 15,000, per device
/// and calendar month, the offer at 80 %, the stop at 100 %.
final class PilotMapAllowanceTests: XCTestCase {

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ iso: String) { now = ISO8601DateFormatter().date(from: iso)! }
    }

    private let zurich = TimeZone(identifier: "Europe/Zurich")!

    private func allowance(_ clock: Clock, defaults: UserDefaults? = nil) -> PilotMapAllowance {
        PilotMapAllowance(defaults: defaults ?? makeTestDefaults(), now: { clock.now }, timeZone: zurich)
    }

    func testFreeAllowanceOffersAt80AndStopsAt100Percent() {
        let a = allowance(Clock("2026-11-10T10:00:00Z"))
        XCTAssertEqual(a.limit, 1_500)
        XCTAssertEqual(a.level, .open)
        for _ in 0..<1_199 { XCTAssertTrue(a.reserve()) }
        XCTAssertEqual(a.level, .open)
        XCTAssertTrue(a.reserve())
        XCTAssertEqual(a.level, .nearLimit, "1,200 of 1,500")
        for _ in 0..<300 { XCTAssertTrue(a.reserve()) }
        XCTAssertEqual(a.level, .exhausted)
        XCTAssertFalse(a.reserve())
        XCTAssertEqual(a.used, 1_500)
        XCTAssertEqual(a.remaining, 0)
    }

    func testProGetsTenTimesAsMany() {
        let a = allowance(Clock("2026-11-10T10:00:00Z"))
        a.plan = .pro
        XCTAssertEqual(a.limit, 15_000)
        for _ in 0..<1_600 { XCTAssertTrue(a.reserve()) }
        XCTAssertEqual(a.level, .open)
        // Pro lapses (never in flight: the hold keeps the plan): the free allowance is already spent.
        a.plan = .free
        XCTAssertEqual(a.level, .exhausted)
        XCTAssertFalse(a.reserve())
    }

    func testTheMonthTurnsInLocalTime() {
        let clock = Clock("2026-11-30T22:30:00Z")   // 23:30 in Zurich, still November
        let a = allowance(clock)
        for _ in 0..<1_500 { _ = a.reserve() }
        XCTAssertEqual(a.level, .exhausted)
        clock.now = ISO8601DateFormatter().date(from: "2026-11-30T23:30:00Z")!   // 00:30 on 1 December
        XCTAssertEqual(a.used, 0)
        XCTAssertEqual(a.level, .open)
        XCTAssertTrue(a.reserve())
    }

    func testCountSurvivesARelaunch() {
        let clock = Clock("2026-11-10T10:00:00Z")
        let defaults = makeTestDefaults()
        let first = allowance(clock, defaults: defaults)
        for _ in 0..<42 { _ = first.reserve() }
        XCTAssertEqual(allowance(clock, defaults: defaults).used, 42)
        clock.now = ISO8601DateFormatter().date(from: "2026-12-02T10:00:00Z")!
        XCTAssertEqual(allowance(clock, defaults: defaults).used, 0, "a relaunch in the next month starts afresh")
    }

    func testRefundGivesBackAFailedRead() {
        let a = allowance(Clock("2026-11-10T10:00:00Z"))
        XCTAssertTrue(a.reserve())
        a.refund()
        XCTAssertEqual(a.used, 0)
        a.refund()
        XCTAssertEqual(a.used, 0, "never below zero")
    }

    func testLevelChangeIsAnnounced() {
        let a = allowance(Clock("2026-11-10T10:00:00Z"))
        for _ in 0..<1_199 { _ = a.reserve() }
        let announced = expectation(forNotification: PilotMapAllowance.levelChanged, object: a)
        _ = a.reserve()
        wait(for: [announced], timeout: 2)
    }

    func testConcurrentReadsNeverPassTheLimit() {
        let a = allowance(Clock("2026-11-10T10:00:00Z"))
        let granted = ManagedCounter()
        DispatchQueue.concurrentPerform(iterations: 4_000) { _ in if a.reserve() { granted.add() } }
        XCTAssertEqual(granted.value, 1_500)
        XCTAssertEqual(a.used, 1_500)
    }

    private final class ManagedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
