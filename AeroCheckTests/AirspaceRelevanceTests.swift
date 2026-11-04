import CoreLocation
import XCTest
@testable import AeroCheck

/// Which airspace gets a tag: what it asks, whether it is ahead, whether it is at the aircraft's height (a11 A, a8 A).
final class AirspaceRelevanceTests: XCTestCase {
    private let here = CLLocationCoordinate2D(latitude: 47.0, longitude: 7.0)

    private func limit(_ value: Int, unit: Int = 1, datum: Int = 1) -> AltitudeLimit {
        AltitudeLimit(value: value, unit: unit, referenceDatum: datum)
    }

    /// A square of `side` NM with its south-west corner `north` NM north of `here`.
    private func airspace(_ type: AirspaceTypeCategory, cls: Int? = nil, name: String = "A", lower: AltitudeLimit? = nil,
                          upper: AltitudeLimit? = nil, north: Double = -1, east: Double = -1, side: Double = 2) -> Airspace {
        let scale = 60 * cos(here.latitude * .pi / 180)
        let south = here.latitude + north / 60, west = here.longitude + east / scale
        let top = south + side / 60, right = west + side / scale
        let ring = [[west, south], [right, south], [right, top], [west, top], [west, south]]
        return Airspace(id: name, name: name, type: type.rawValue, icaoClass: cls, country: "CH",
                        upperCeiling: upper ?? limit(10000), lowerCeiling: lower ?? limit(0, datum: 0),
                        geometry: AirspaceGeometry(type: "Polygon", coordinates: [ring]), activity: nil, frequencies: nil)
    }

    private func kind(_ a: Airspace, alt: Double = 3500, vs: Double = 0) -> AirspaceRelevantTag.Kind? {
        AirspaceRelevance.tag(a, altitudeFt: alt, verticalSpeedFpm: vs)?.kind
    }

    // MARK: What it asks

    func testRestrictedAndControlledAirspaceGetAFullTagAtLevel() {
        XCTAssertEqual(kind(airspace(.restricted)), .atLevel)
        XCTAssertEqual(kind(airspace(.tma, cls: 3)), .atLevel)
        XCTAssertEqual(kind(airspace(.tmz)), .atLevel)
        XCTAssertEqual(kind(airspace(.gliderSector)), .atLevel)
    }

    func testClassGNeverGetsATag() {
        XCTAssertNil(kind(airspace(.other, cls: 6)))
    }

    func testAnInformationAreaNeverGetsATag() {
        XCTAssertNil(kind(airspace(.fisSector)))
        XCTAssertNil(kind(airspace(.lta, cls: 3)))
    }

    func testClassEGetsNoFullTagOnlyItsFloor() {
        XCTAssertNil(kind(airspace(.tma, cls: 4)), "inside class E nothing is asked")
        XCTAssertEqual(kind(airspace(.tma, cls: 4, lower: limit(5000)), vs: 500), .floor)
    }

    // MARK: Height

    func testFiveHundredFeetEitherWayIsAtLevel() {
        XCTAssertEqual(kind(airspace(.restricted, lower: limit(4000))), .atLevel)
        XCTAssertEqual(kind(airspace(.restricted, upper: limit(3000))), .atLevel)
    }

    func testClimbingLooksUpAndNotDown() {
        let floor = airspace(.restricted, lower: limit(5900), upper: limit(9000))
        let ceiling = airspace(.restricted, upper: limit(2500))
        XCTAssertEqual(kind(floor, vs: 500), .floor)
        XCTAssertNil(kind(ceiling, vs: 500))
    }

    func testDescendingLooksDownAndNotUp() {
        let floor = airspace(.restricted, lower: limit(5900), upper: limit(9000))
        let ceiling = airspace(.restricted, upper: limit(1100))
        XCTAssertEqual(kind(ceiling, vs: -500), .ceiling)
        XCTAssertNil(kind(floor, vs: -500))
    }

    func testLevelFlightLooksAThousandFeetEachWay() {
        XCTAssertEqual(kind(airspace(.restricted, lower: limit(4900), upper: limit(9000))), .floor)
        XCTAssertNil(kind(airspace(.restricted, lower: limit(5100), upper: limit(9000))))
        XCTAssertEqual(kind(airspace(.restricted, upper: limit(2100))), .ceiling)
        XCTAssertNil(kind(airspace(.restricted, upper: limit(1900))))
    }

    func testThreeHundredFeetAMinuteIsStillLevel() {
        XCTAssertNil(kind(airspace(.restricted, lower: limit(5500), upper: limit(9000)), vs: 300))
        XCTAssertEqual(kind(airspace(.restricted, lower: limit(5500), upper: limit(9000)), vs: 301), .floor)
    }

    func testALimitAboveTheGroundOverUnknownGroundCountsAsInside() {
        // 2000 ft GND with the ground unknown: its ceiling may be anywhere above, so it can't be cleared (a8 A)
        let high = airspace(.restricted, upper: limit(2000, datum: 0))
        XCTAssertEqual(kind(high, alt: 9000), .atLevel)
    }

    func testAKnownGroundPinsTheLimitDown() {
        let a = airspace(.restricted, upper: limit(2000, datum: 0))
        XCTAssertNil(AirspaceRelevance.tag(a, altitudeFt: 9000, verticalSpeedFpm: 0, terrainFt: 1500...1600))
    }

    func testAFlightLevelCountsTheMarginOfAnUnknownQNH() {
        // FL 75 can sit up to 1000 ft either side of 7500 ft on a QNH altimeter
        XCTAssertEqual(kind(airspace(.restricted, lower: limit(75, unit: 6, datum: 2), upper: limit(100, unit: 6, datum: 2)),
                            alt: 6100), .atLevel)
    }

    // MARK: Ahead

    private func area(track: Double = 0, speed: Double = 100) -> AirspaceAheadArea {
        AirspaceAheadArea.make(at: here, trackDeg: track, groundSpeedKt: speed)
    }

    func testOverTheAircraftIsAhead() {
        XCTAssertEqual(area().distanceNM(to: airspace(.restricted)), 0)
    }

    func testTheTrackForTenMinutesIsAhead() throws {
        // 100 kt: 16.7 NM ahead
        XCTAssertEqual(try XCTUnwrap(area().distanceNM(to: airspace(.restricted, north: 15))), 15, accuracy: 0.01)
        XCTAssertNil(area().distanceNM(to: airspace(.restricted, north: 20.5)))
    }

    func testThreeNauticalMilesEitherSideAreAhead() {
        XCTAssertNotNil(area().distanceNM(to: airspace(.restricted, north: 5, east: 2.5)))
        XCTAssertNil(area().distanceNM(to: airspace(.restricted, north: 5, east: 3.5)))
    }

    func testBehindTheAircraftIsNotAhead() {
        XCTAssertNil(area().distanceNM(to: airspace(.restricted, north: -8)))
    }

    func testTwoNauticalMilesBehindStillCount() {
        XCTAssertNotNil(area().distanceNM(to: airspace(.restricted, north: -3.5)))
    }

    func testBelowThirtyKnotsTheTrackMeansNothing() {
        let still = AirspaceAheadArea.make(at: here, trackDeg: 90, groundSpeedKt: 20)
        XCTAssertEqual(still.radiusNM, 5)
        XCTAssertEqual(still.path.count, 1)
        XCTAssertNotNil(still.distanceNM(to: airspace(.restricted, north: -6)))
        XCTAssertNil(still.distanceNM(to: airspace(.restricted, north: -8)))
    }

    func testOnTheGroundWithARouteTheRouteIsAhead() {
        let scale = 60 * cos(here.latitude * .pi / 180)
        let east = CLLocationCoordinate2D(latitude: here.latitude, longitude: here.longitude + 40 / scale)
        let taxiing = AirspaceAheadArea.make(at: here, trackDeg: 0, groundSpeedKt: 5, route: [east])
        XCTAssertNotNil(taxiing.distanceNM(to: airspace(.restricted, north: -1, east: 10)))
        XCTAssertNil(taxiing.distanceNM(to: airspace(.restricted, north: -1, east: 20)), "past the next 10 minutes")
    }

    // MARK: Ranking

    func testFiveAtMostRankedByWhatTheyAsk() {
        let all = [airspace(.tma, cls: 4, name: "E", lower: limit(4900)), airspace(.gliderSector, name: "GLD"),
                   airspace(.tma, cls: 3, name: "TMA"), airspace(.tmz, name: "TMZ"), airspace(.restricted, name: "R1"),
                   airspace(.danger, name: "D1"), airspace(.ctr, cls: 3, name: "CTR")]
        let tags = AirspaceRelevance.tags(in: all, area: area(), altitudeFt: 3500, verticalSpeedFpm: 500)
        XCTAssertEqual(tags.map(\.airspace.name), ["D1", "R1", "CTR", "TMA", "GLD"])
    }

    func testAtLevelComesBeforeAnArrowOfTheSameKind() {
        let all = [airspace(.restricted, name: "above", lower: limit(4900), upper: limit(9000)),
                   airspace(.restricted, name: "level", north: 10)]
        let tags = AirspaceRelevance.tags(in: all, area: area(), altitudeFt: 3500, verticalSpeedFpm: 0)
        XCTAssertEqual(tags.map(\.airspace.name), ["level", "above"])
    }

    func testTheNearestComesFirstWithinAKind() {
        let all = [airspace(.restricted, name: "far", north: 10), airspace(.restricted, name: "near", north: 3)]
        let tags = AirspaceRelevance.tags(in: all, area: area(), altitudeFt: 3500, verticalSpeedFpm: 0)
        XCTAssertEqual(tags.map(\.airspace.name), ["near", "far"])
    }

    // MARK: Tiers

    func testTheTiers() {
        XCTAssertEqual(AirspaceRelevance.tier(airspace(.restricted), altitudeFt: 3500), .atLevel)
        XCTAssertEqual(AirspaceRelevance.tier(airspace(.restricted, lower: limit(5000), upper: limit(9000)), altitudeFt: 3500), .near)
        XCTAssertEqual(AirspaceRelevance.tier(airspace(.restricted, upper: limit(2600)), altitudeFt: 3500), .near)
        XCTAssertEqual(AirspaceRelevance.tier(airspace(.restricted, lower: limit(6000), upper: limit(9000)), altitudeFt: 3500), .far)
    }

    // MARK: The trend

    func testATrendNeedsTenSecondsOfFixes() {
        var trend = AirspaceVerticalTrend()
        trend.add(altitudeFt: 3000, at: 0)
        trend.add(altitudeFt: 3100, at: 5)
        XCTAssertEqual(trend.verticalSpeedFpm, 0)
    }

    func testAClimbReads() {
        var trend = AirspaceVerticalTrend()
        for second in stride(from: 0.0, through: 30, by: 5) { trend.add(altitudeFt: 3000 + second * 10, at: second) }
        XCTAssertEqual(trend.verticalSpeedFpm, 600, accuracy: 1)
    }

    func testOneBadFixDoesNotTurnTheTrend() {
        var trend = AirspaceVerticalTrend()
        for second in stride(from: 0.0, through: 30, by: 2) {
            trend.add(altitudeFt: second == 30 ? 3080 : 3000, at: second)
        }
        XCTAssertLessThan(abs(trend.verticalSpeedFpm), AirspaceVerticalTrend.thresholdFpm)
    }

    func testOldFixesLeaveTheWindow() {
        var trend = AirspaceVerticalTrend()
        for second in stride(from: 0.0, through: 60, by: 5) {
            trend.add(altitudeFt: second <= 30 ? 3000 + second * 10 : 3300, at: second)
        }
        XCTAssertEqual(trend.verticalSpeedFpm, 0, accuracy: 1)
    }
}
