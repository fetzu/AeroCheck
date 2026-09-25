import XCTest
import CoreLocation
@testable import AeroCheck

/// `TrackTimes`: block off, take-off and block on measured from the recorded track. (v5.2)
///
/// Synthetic tracks shaped like the six September 2026 flights they were checked against: a fix
/// every 6 s while moving, none while standing (the tracker's 5 m distance filter), walking-pace
/// taxi out of and into the parking spot, a stop at the runway exit.
final class TrackTimesTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let knot = 0.514444

    /// Builds a track northwards from 47°N 7°E, one fix per `step` seconds.
    private struct Track {
        var points: [GPSPoint] = []
        var time: Date
        var northMetres = 0.0
        var altitude = 500.0

        mutating func move(_ seconds: TimeInterval, speed: Double, climb: Double = 0, step: TimeInterval = 6,
                           baro: Bool = false) {
            var elapsed = 0.0
            while elapsed < seconds {
                time = time.addingTimeInterval(step)
                northMetres += speed * step
                altitude += climb * step
                points.append(GPSPoint(latitude: 47 + northMetres / 111_320, longitude: 7, altitude: altitude,
                                       timestamp: time, speed: speed, horizontalAccuracy: 3.5,
                                       baroAltitude: baro ? altitude - 480 : nil))
                elapsed += step
            }
        }

        /// Standing still: no fixes, only time passing.
        mutating func stand(_ seconds: TimeInterval) { time = time.addingTimeInterval(seconds) }
    }

    // MARK: - Block off

    func testLeavingTheParkingSpotAtWalkingPaceIsBlockOff() {
        var track = Track(time: t0.addingTimeInterval(180))      // engine started at t0
        track.move(18, speed: 1.6)                                // ~3 kt, 10 m per fix
        let firstFix = track.points[0].timestamp
        track.move(60, speed: 5 * knot + 1)                       // taxi
        let times = TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil)
        XCTAssertEqual(times.blockOff, firstFix,
                       "the old rule waited for two fixes at 4 kt: 18 s late on this track")
    }

    func testAShortMoveThenTheRunUpStillStartsTheBlock() {
        // Out of parking, four fixes, then four minutes at the run-up with no fix at all.
        var track = Track(time: t0.addingTimeInterval(120))
        track.move(24, speed: 2.8)
        let firstFix = track.points[0].timestamp
        track.stand(240)
        track.move(60, speed: 4)
        XCTAssertEqual(TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil).blockOff,
                       firstFix)
    }

    func testBeingPushedOutBeforeTheEngineStartsIsNotBlockTime() {
        var track = Track(time: t0)
        track.move(30, speed: 1.2)                                // hangar push-out
        track.stand(300)
        let engineStart = track.time
        track.stand(120)
        track.move(12, speed: 2)
        let taxi = track.points[track.points.count - 2].timestamp
        track.move(60, speed: 4)
        XCTAssertEqual(TrackTimes.analyze(track: track.points, engineStart: engineStart, engineShutdown: nil).blockOff,
                       taxi)
    }

    // MARK: - Block on

    func testTheStopAtTheRunwayExitIsNotBlockOn() {
        var track = Track(time: t0)
        track.move(60, speed: 5)                                  // taxi out
        track.move(60, speed: 20)                                 // (flight, flattened)
        track.move(12, speed: 1.3)                                // slowing at the runway exit
        track.stand(38)                                           // after-landing checks
        track.move(84, speed: 2.5)                                // taxi to parking at walking pace
        let lastFix = track.points.last!.timestamp
        let times = TrackTimes.analyze(track: track.points, engineStart: t0,
                                       engineShutdown: lastFix.addingTimeInterval(29))
        XCTAssertEqual(times.blockOn, lastFix, "the old rule stopped the block at the runway exit")
    }

    func testTheAircraftSeenStandingAfterItsLastMoveIsBlockOn() {
        var track = Track(time: t0)
        track.move(60, speed: 4)
        let seenStanding = track.time.addingTimeInterval(7)
        track.points.append(GPSPoint(latitude: track.points.last!.latitude, longitude: 7, altitude: 500,
                                     timestamp: seenStanding, speed: 0, horizontalAccuracy: 3.5))
        XCTAssertEqual(TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil).blockOn,
                       seenStanding)
    }

    func testBeingPushedIntoTheHangarAfterShutdownIsNotBlockTime() {
        var track = Track(time: t0)
        track.move(60, speed: 4)
        let parked = track.points.last!.timestamp
        let shutdown = parked.addingTimeInterval(30)
        track.stand(180)
        track.move(30, speed: 1.2)                                // pushed in by hand
        XCTAssertEqual(TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: shutdown).blockOn,
                       parked)
    }

    // MARK: - Take-off

    func testTakeoffIsWhereTheAltitudeLeavesTheRunway() throws {
        var track = Track(time: t0)
        track.move(60, speed: 4)                                  // taxi
        track.move(6, speed: 30 * knot)                           // roll through 25 kt
        track.move(6, speed: 48 * knot)                           // last fix on the runway
        let lastOnRunway = track.points.last!.timestamp
        track.move(6, speed: 53 * knot, climb: 3.5)               // +69 ft six seconds later
        track.move(60, speed: 60 * knot, climb: 3.5)
        let takeoff = try XCTUnwrap(TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil).takeoff)
        // 10 ft of the first 69 ft: 0.87 s after the last fix on the runway.
        XCTAssertEqual(takeoff.timeIntervalSince(lastOnRunway), 6 * (10.0 / 69.0), accuracy: 0.3)
    }

    func testAFastTaxiIsNotATakeoff() {
        var track = Track(time: t0)
        track.move(60, speed: 30 * knot)                          // fast, but never climbs
        XCTAssertNil(TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil).takeoff)
    }

    func testTheFirstTakeoffCountsOnACircuitsFlight() throws {
        var track = Track(time: t0)
        track.move(6, speed: 30 * knot)
        track.move(6, speed: 50 * knot)
        let first = track.points.last!.timestamp
        track.move(120, speed: 55 * knot, climb: 3)
        track.move(120, speed: 55 * knot, climb: -3)              // back down: a touch-and-go…
        track.move(120, speed: 55 * knot, climb: 3)               // …and away again
        let takeoff = try XCTUnwrap(TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil).takeoff)
        XCTAssertLessThan(abs(takeoff.timeIntervalSince(first)), 6)
    }

    func testTheBarometerIsPreferredWhenItWasRecorded() throws {
        var track = Track(time: t0)
        track.move(6, speed: 30 * knot, baro: true)
        track.move(6, speed: 48 * knot, baro: true)
        let lastOnRunway = track.points.last!.timestamp
        track.move(66, speed: 55 * knot, climb: 3.5, baro: true)
        // GPS altitude jumps 40 ft on the ground roll; the barometer does not.
        let noisy = track.points[1]
        track.points[1] = GPSPoint(latitude: noisy.latitude, longitude: noisy.longitude, altitude: noisy.altitude + 12,
                                   timestamp: noisy.timestamp, speed: noisy.speed, horizontalAccuracy: 3.5,
                                   baroAltitude: noisy.baroAltitude)
        let takeoff = try XCTUnwrap(TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil).takeoff)
        XCTAssertGreaterThan(takeoff, lastOnRunway, "a GPS jump on the runway is not a liftoff")
    }
}
