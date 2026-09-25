import XCTest
import CoreLocation
@testable import AeroCheck

/// `WaypointPassage`: actual times over, reconstructed from a GPS track.
///
/// Synthetic flights east along 47°N at 100 kt, one fix every 10 s. 0.1° of longitude is 4.09 NM
/// there, so a waypoint every 0.3° is 12.3 NM (7.4 min) apart.
final class WaypointPassageTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let nmPerDegLon = 60 * cos(47.0 * .pi / 180)

    private func route(_ points: [(lat: Double, lon: Double)]) -> [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    /// Fixes along `path` (lat, lon corners) at 100 kt from `t0`.
    private func track(_ path: [(lat: Double, lon: Double)]) -> [WaypointPassage.Fix] {
        var fixes: [WaypointPassage.Fix] = []
        var t = t0
        let step = 100.0 / 3600 * 10   // NM per 10 s
        for k in 0..<(path.count - 1) {
            let a = path[k], b = path[k + 1]
            let dx = (b.lon - a.lon) * nmPerDegLon, dy = (b.lat - a.lat) * 60
            let n = max(1, Int((hypot(dx, dy) / step).rounded(.up)))
            for i in 0..<n {
                let f = Double(i) / Double(n)
                fixes.append(.init(time: t, coordinate: .init(latitude: a.lat + (b.lat - a.lat) * f,
                                                              longitude: a.lon + (b.lon - a.lon) * f), speed: 51))
                t = t.addingTimeInterval(10)
            }
        }
        let last = path[path.count - 1]
        fixes.append(.init(time: t, coordinate: .init(latitude: last.lat, longitude: last.lon), speed: 51))
        return fixes
    }

    /// Seconds after `t0` at which a 100 kt flight from `startLon` reaches `lon` along 47°N.
    private func seconds(from startLon: Double, to lon: Double) -> Double {
        (lon - startLon) * nmPerDegLon / 100 * 3600
    }

    func testWaypointsFlownOneMileToTheSideAreStillPassed() {
        let r = route([(47.0, 7.0), (47.0, 7.3), (47.0, 7.6), (47.0, 7.9)])
        // Flown the whole way 1 NM north of the line — the old 500 m radius saw none of it.
        let fixes = track([(47.0, 7.0), (47.0 + 1.0 / 60, 7.05), (47.0 + 1.0 / 60, 7.85), (47.0, 7.9)])
        let times = WaypointPassage.timesOver(route: r, track: fixes, takeoff: t0, landing: fixes.last!.time)

        XCTAssertEqual(times[0], t0, "departure = takeoff")
        XCTAssertEqual(times[3], fixes.last!.time, "destination = landing")
        for (i, lon) in [(1, 7.3), (2, 7.6)] {
            let expected = seconds(from: 7.0, to: lon)
            XCTAssertEqual(times[i]?.timeIntervalSince(t0) ?? -1, expected, accuracy: 20, "waypoint \(i)")
        }
    }

    func testAWaypointPassedTooFarAwayStaysEmptyAndTheRestStillMatch() {
        // The second turning point sits 3 NM north of where the aircraft actually flew.
        let r = route([(47.0, 7.0), (47.0, 7.3), (47.05, 7.6), (47.0, 7.9)])
        let fixes = track([(47.0, 7.0), (47.0, 7.9)])
        let times = WaypointPassage.timesOver(route: r, track: fixes, takeoff: t0, landing: fixes.last!.time)
        XCTAssertNotNil(times[1])
        XCTAssertNil(times[2], "3 NM off is beyond the tolerance")
        XCTAssertNotNil(times[3])
    }

    func testADiversionLeavesTheRestOfTheRouteWithoutTimes() {
        let r = route([(47.0, 7.0), (47.0, 7.3), (47.0, 7.6), (47.0, 7.9)])
        // Turned south after the first waypoint and landed 10 NM away from the route.
        let fixes = track([(47.0, 7.0), (47.0, 7.35), (46.85, 7.4)])
        let times = WaypointPassage.timesOver(route: r, track: fixes, takeoff: t0, landing: fixes.last!.time)
        XCTAssertNotNil(times[1])
        XCTAssertNil(times[2])
        XCTAssertNil(times[3], "landed somewhere else: no time at the planned destination")
    }

    func testCuttingTheCornerCountsAsPassingTheTurn() {
        // East, then a 90° turn north at 7.3; the aircraft turns 1 NM early.
        let r = route([(47.0, 7.0), (47.0, 7.3), (47.3, 7.3)])
        let fixes = track([(47.0, 7.0), (47.0, 7.3 - 1 / nmPerDegLon), (47.0 + 1.0 / 60, 7.3), (47.3, 7.3)])
        let times = WaypointPassage.timesOver(route: r, track: fixes, takeoff: t0, landing: fixes.last!.time)
        XCTAssertNotNil(times[1])
        XCTAssertEqual(times[1]?.timeIntervalSince(t0) ?? -1, seconds(from: 7.0, to: 7.3), accuracy: 60)
    }

    func testWithoutATakeoffTimeTheFirstFastFixCounts() {
        let r = route([(47.0, 7.0), (47.0, 7.3), (47.0, 7.6)])
        var fixes = track([(47.0, 7.0), (47.0, 7.6)])
        // Taxiing: two slow fixes before the roll.
        fixes.insert(.init(time: t0.addingTimeInterval(-60), coordinate: .init(latitude: 47.0, longitude: 7.0), speed: 3), at: 0)
        let times = WaypointPassage.timesOver(route: r, track: fixes, takeoff: nil, landing: nil)
        XCTAssertEqual(times[0], t0)
        XCTAssertNotNil(times[1])
        XCTAssertNil(times[2], "still flying: no landing, no destination time")
    }

    func testATimeRecordedInFlightIsKept() {
        var plan = FlightPlan(name: "Kept")
        plan.waypoints = [(47.0, 7.0), (47.0, 7.3), (47.0, 7.6)].map {
            FlightPlanWaypoint(coordinate: .init(latitude: $0.0, longitude: $0.1))
        }
        let tapped = t0.addingTimeInterval(123)
        plan.waypoints[1].actualTimeOver = tapped
        let gps = track([(47.0, 7.0), (47.0, 7.6)]).map {
            GPSPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, altitude: 1500,
                     timestamp: $0.time, speed: $0.speed)
        }
        let filled = plan.withActualTimesOver(fromTrack: gps, takeoff: t0, landing: gps.last!.timestamp)
        XCTAssertEqual(filled.waypoints[1].actualTimeOver, tapped)
        XCTAssertEqual(filled.waypoints[0].actualTimeOver, t0)
        XCTAssertNotNil(filled.waypoints[2].actualTimeOver)
    }

    func testETOAtAWaypointIsTheArrivingLegs() {
        var plan = FlightPlan(name: "ETO", plannedDepartureTime: t0)
        plan.waypoints = [(47.0, 7.0), (47.0, 7.3), (47.0, 7.6)].map {
            FlightPlanWaypoint(coordinate: .init(latitude: $0.0, longitude: $0.1), plannedGroundSpeed: 100)
        }
        plan.calculateRouteData()
        XCTAssertEqual(plan.estimatedTimeOver(at: 0), t0)
        XCTAssertEqual(plan.estimatedTimeOver(at: 1), plan.waypoints[0].estimatedTimeOver)
        XCTAssertEqual(plan.estimatedTimeOver(at: 2), plan.waypoints[2].estimatedTimeOver)
        XCTAssertGreaterThan(plan.estimatedTimeOver(at: 2)!, plan.estimatedTimeOver(at: 1)!)
    }
}
