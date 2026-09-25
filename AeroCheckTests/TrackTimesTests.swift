import XCTest
import CoreLocation
@testable import AeroCheck

/// `TrackTimes`: block off, take-off, landing and block on measured from the recorded track. (v5.2)
///
/// Synthetic tracks shaped like the six September 2026 flights they were checked against: a fix
/// every 6 s while moving, none while standing (the tracker's 5 m distance filter), walking-pace
/// taxi out of and into the parking spot, a stop at the runway exit, a flare before touchdown.
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

        /// One fix `heightFt` above the runway (500 m), 6 s after the last; `baroFt` likewise.
        mutating func at(_ heightFt: Double, speed: Double, baroFt: Double? = nil) {
            time = time.addingTimeInterval(6)
            northMetres += speed * 6
            altitude = 500 + heightFt * 0.3048
            points.append(GPSPoint(latitude: 47 + northMetres / 111_320, longitude: 7, altitude: altitude,
                                   timestamp: time, speed: speed, horizontalAccuracy: 3.5,
                                   baroAltitude: baroFt.map { 20 + $0 * 0.3048 }))
        }
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

    func testAFastTaxiIsNeitherATakeoffNorALanding() {
        var track = Track(time: t0)
        track.move(60, speed: 30 * knot)                          // fast, but never climbs
        let times = TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil)
        XCTAssertNil(times.takeoff)
        XCTAssertNil(times.landing)
    }

    func testTheLiftoffIsFoundBelowTheFirstAirborneFix() throws {
        var track = Track(time: t0)
        track.at(0, speed: 30 * knot)
        track.at(2, speed: 48 * knot)
        let lastOnRunway = track.points.last!.timestamp
        track.at(20, speed: 53 * knot)                            // off the runway, not yet 25 ft
        track.at(90, speed: 55 * knot)
        track.at(180, speed: 55 * knot)
        let takeoff = try XCTUnwrap(TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil).takeoff)
        // 10 ft is 8 ft into the first 18 ft: 2.7 s after the last fix on the runway. It used to be
        // stamped at the +20 ft fix, 6 s after it (flight 1437).
        XCTAssertEqual(takeoff.timeIntervalSince(lastOnRunway), 6 * (8.0 / 18.0), accuracy: 0.3)
    }

    func testOneGPSJumpOnTheRollIsNotALiftoff() throws {
        var track = Track(time: t0)
        track.at(0, speed: 30 * knot)
        track.at(0, speed: 40 * knot)
        track.at(35, speed: 45 * knot)                            // one wild GPS altitude on the runway
        track.at(0, speed: 50 * knot)
        let lastOnRunway = track.points.last!.timestamp
        for height in [60.0, 150, 250] { track.at(height, speed: 55 * knot) }
        let takeoff = try XCTUnwrap(TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil).takeoff)
        XCTAssertGreaterThan(takeoff, lastOnRunway)
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

    // MARK: - Landing

    /// Final, a flare, and the roll-out. `baroFt` is the cabin barometer as the September flights
    /// recorded it: 2–3 s behind, and still +28 ft at the first fix on the runway.
    private func approach(into track: inout Track, withBarometer: Bool = false) -> (flaring: Date, onRunway: Date) {
        for height in [300.0, 240, 180, 120, 60] {
            track.at(height, speed: 60 * knot, baroFt: withBarometer ? height + 40 : nil)
        }
        track.at(11, speed: 50 * knot, baroFt: withBarometer ? 60 : nil)      // the last fix in the air
        let flaring = track.points.last!.timestamp
        track.at(1, speed: 40 * knot, baroFt: withBarometer ? 28 : nil)       // the detector's stamp
        let onRunway = track.points.last!.timestamp
        for (speed, baro) in [(30.0, 8.0), (15, 2), (6, 0)] {
            track.at(0, speed: speed * knot, baroFt: withBarometer ? baro : nil)
        }
        return (flaring, onRunway)
    }

    func testTouchdownIsWhereTheAltitudeReachesTheRunway() throws {
        var track = Track(time: t0)
        let (flaring, _) = approach(into: &track)
        let landing = try XCTUnwrap(TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil).landing)
        // 5 ft above the runway is 6 ft into the last 10: 3.6 s after the last fix in the air, where
        // the detector's stamp is 6 s after it.
        XCTAssertEqual(landing.timeIntervalSince(flaring), 6 * (6.0 / 10.0), accuracy: 0.3)
    }

    func testTheFinalLandingIsTheLastTouchdownNotATouchAndGo() throws {
        var track = Track(time: t0)
        for height in [0.0, 0, 50, 300, 600, 300, 60, 2, 0, 60, 300, 600] {   // take-off, a touch-and-go
            track.at(height, speed: 55 * knot)
        }
        let (flaring, onRunway) = approach(into: &track)
        let landing = try XCTUnwrap(TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil).landing)
        XCTAssertGreaterThan(landing, flaring)
        XCTAssertLessThan(landing, onRunway)
    }

    func testATrackThatEndsInTheAirHasNoLanding() {
        var track = Track(time: t0)
        for height in [0.0, 0, 50, 300, 600, 900] { track.at(height, speed: 55 * knot) }
        XCTAssertNil(TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil).landing)
    }

    func testALaggingBarometerDoesNotDelayTheLanding() throws {
        var track = Track(time: t0)
        let (flaring, onRunway) = approach(into: &track, withBarometer: true)
        let landing = try XCTUnwrap(TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil).landing)
        XCTAssertGreaterThan(landing, flaring)
        XCTAssertLessThan(landing, onRunway, "the barometer still read +28 ft on the runway: GPS altitude decides")
    }

    // MARK: - Where the times go

    @MainActor
    func testEndingTheFlightMovesTheLandingAndItsFullStopToTheTouchdown() throws {
        var track = Track(time: t0)
        for height in [0.0, 0, 50, 300, 600, 600, 600] { track.at(height, speed: 55 * knot) }
        let (_, detectorStamp) = approach(into: &track)
        let measured = try XCTUnwrap(TrackTimes.analyze(track: track.points, engineStart: t0, engineShutdown: nil).landing)

        let appState = makeTestAppState()
        var flight = Flight(airplane: "wt9-dynamic", startTime: t0, engineStartTime: t0, landingTime: detectorStamp)
        flight.gpsTrack = track.points
        flight.fullStopCount = 1
        flight.fullStopTimes = [detectorStamp]
        appState.currentFlight = flight
        appState.landingTime = detectorStamp

        appState.refineTimingFromTrack()

        XCTAssertEqual(appState.currentFlight?.landingTime, measured)
        XCTAssertEqual(appState.landingTime, measured, "END FLIGHT hands this one to the nav log")
        XCTAssertEqual(appState.currentFlight?.fullStopTimes, [measured], "one landing, one time")
    }

    @MainActor
    func testTheNavLogTimesAreTakeoffAndLandingNeverTheEngine() {
        let plans = makeTestPlanManager()
        let plan = FlightPlan(name: "Nav log")
        plans.add(plan)
        let takeoff = t0.addingTimeInterval(400), landing = t0.addingTimeInterval(1_800)
        let flight = Flight(airplane: "wt9-dynamic", startTime: t0, engineStartTime: t0,
                            engineShutdownTime: t0.addingTimeInterval(2_000))

        plans.populateTimingFromFlight(plan.id, flight: flight, takeoff: takeoff, landing: landing)

        let filled = plans.flightPlans.first { $0.id == plan.id }
        XCTAssertEqual(filled?.timeOff, takeoff, "Time OFF is wheels off")
        XCTAssertEqual(filled?.timeOn, landing, "Time ON is wheels on")
    }
}
