import CoreLocation
import XCTest
@testable import AeroCheck

/// What a tag says and where it goes (a11 A).
final class AirspaceTagsTests: XCTestCase {
    private func airspace(_ type: AirspaceTypeCategory, cls: Int? = nil, name: String = "LSR7 HONGRIN",
                          lower: AltitudeLimit = AltitudeLimit(value: 0, unit: 1, referenceDatum: 0),
                          upper: AltitudeLimit = AltitudeLimit(value: 4500, unit: 1, referenceDatum: 1)) -> Airspace {
        Airspace(id: name, name: name, type: type.rawValue, icaoClass: cls, country: "CH", upperCeiling: upper,
                 lowerCeiling: lower, geometry: AirspaceGeometry(type: "Polygon", coordinates: []), activity: nil,
                 frequencies: nil)
    }

    private func square(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat) -> [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + side, y: y), CGPoint(x: x + side, y: y + side), CGPoint(x: x, y: y + side)]
    }

    private let bounds = CGRect(x: 0, y: 0, width: 820, height: 604)
    private let size = CGSize(width: 120, height: 78)

    func testTheLimitsReadAsTheChartWritesThem() {
        XCTAssertEqual(AirspaceTagContent.limit(AltitudeLimit(value: 0, unit: 1, referenceDatum: 0)), "GND")
        XCTAssertEqual(AirspaceTagContent.limit(AltitudeLimit(value: 130, unit: 6, referenceDatum: 2)), "FL 130")
        XCTAssertEqual(AirspaceTagContent.limit(AltitudeLimit(value: 4500, unit: 1, referenceDatum: 1)), "4500 ft")
        XCTAssertEqual(AirspaceTagContent.limit(AltitudeLimit(value: 2000, unit: 1, referenceDatum: 0)), "2000 AGL")
        XCTAssertEqual(AirspaceTagContent.limit(AltitudeLimit(value: 1000, unit: 0, referenceDatum: 1)), "3281 ft")
    }

    func testTheBoundaryReadsGroundFirstAndEachLimitKeepsItsUnit() {
        let lsr27 = airspace(.gliderSector, lower: AltitudeLimit(value: 2000, unit: 1, referenceDatum: 0),
                             upper: AltitudeLimit(value: 4000, unit: 1, referenceDatum: 1))
        XCTAssertEqual(AirspaceTagContent.boundaryText(lsr27), "GLD 2000 AGL – 4000 ft")
    }

    func testTheBadges() {
        XCTAssertEqual(AirspaceTagContent.badge(airspace(.restricted)), "R")
        XCTAssertEqual(AirspaceTagContent.badge(airspace(.danger)), "D")
        XCTAssertEqual(AirspaceTagContent.badge(airspace(.gliderSector)), "GLD")
        XCTAssertEqual(AirspaceTagContent.badge(airspace(.tma, cls: 3)), "D")
        XCTAssertEqual(AirspaceTagContent.badge(airspace(.tmz)), "TMZ")
    }

    func testAFullTagIsTallerThanAnArrow() {
        let full = AirspaceTagContent(AirspaceRelevantTag(airspace: airspace(.restricted), kind: .atLevel, weight: 0, distanceNM: 0))
        let arrow = AirspaceTagContent(AirspaceRelevantTag(airspace: airspace(.restricted), kind: .floor, weight: 0.5, distanceNM: 0))
        XCTAssertEqual(AirspaceTagImage.size(full, scale: 1).height, 78)
        XCTAssertEqual(AirspaceTagImage.size(arrow, scale: 1).height, 36)
        XCTAssertEqual(arrow.arrowText, "▲ GND")
    }

    func testATagGoesInsideItsAirspace() throws {
        let ring = square(200, 100, 300)
        let placed = AirspaceTagPlacer.place([.init(id: "a", ring: ring, size: size)], in: bounds, keepOut: [])
        XCTAssertTrue(AirspaceTagPlacer.inside(try XCTUnwrap(placed["a"]), ring))
    }

    func testATagKeepsClearOfTheAircraftAndTheControls() throws {
        let ring = square(0, 0, 600)
        let keepOut = [CGRect(x: 250, y: 250, width: 92, height: 92), CGRect(x: 0, y: 0, width: 496, height: 94)]
        let point = try XCTUnwrap(AirspaceTagPlacer.place([.init(id: "a", ring: ring, size: size)], in: bounds, keepOut: keepOut)["a"])
        let rect = CGRect(x: point.x - 60, y: point.y - 39, width: 120, height: 78)
        XCTAssertFalse(keepOut.contains { $0.intersects(rect) })
    }

    func testTwoTagsNeverOverlap() throws {
        let ring = square(100, 100, 400)
        let placed = AirspaceTagPlacer.place([.init(id: "a", ring: ring, size: size), .init(id: "b", ring: ring, size: size)],
                                             in: bounds, keepOut: [])
        let a = try XCTUnwrap(placed["a"]), b = try XCTUnwrap(placed["b"])
        XCTAssertFalse(CGRect(x: a.x - 60, y: a.y - 39, width: 120, height: 78)
            .intersects(CGRect(x: b.x - 60, y: b.y - 39, width: 120, height: 78)))
    }

    func testATagStaysWhereItIsWhileThatStillWorks() {
        let ring = square(100, 100, 400)
        let held = CGPoint(x: 180, y: 160)
        let placed = AirspaceTagPlacer.place([.init(id: "a", ring: ring, size: size, previous: held)], in: bounds, keepOut: [])
        XCTAssertEqual(placed["a"], held)
    }

    func testATagMovesWhenTheAircraftReachesIt() {
        let ring = square(100, 100, 400)
        let held = CGPoint(x: 180, y: 160)
        let placed = AirspaceTagPlacer.place([.init(id: "a", ring: ring, size: size, previous: held)], in: bounds,
                                             keepOut: [CGRect(x: 150, y: 130, width: 92, height: 92)])
        XCTAssertNotEqual(placed["a"], held)
        XCTAssertNotNil(placed["a"])
    }

    func testASmallAreaGetsATagOverItWiderThanItself() throws {
        let ring = square(300, 300, 40)
        let point = try XCTUnwrap(AirspaceTagPlacer.place([.init(id: "a", ring: ring, size: size)], in: bounds, keepOut: [])["a"])
        XCTAssertTrue(AirspaceTagPlacer.inside(point, ring))
    }

    func testAnAirspaceOffTheMapGetsNoTag() {
        XCTAssertNil(AirspaceTagPlacer.place([.init(id: "a", ring: square(900, 700, 100), size: size)], in: bounds, keepOut: [])["a"])
    }

    func testTheSameAirGivesTheSamePlaces() {
        let requests = [AirspaceTagPlacer.Request(id: "a", ring: square(50, 50, 500), size: size),
                        AirspaceTagPlacer.Request(id: "b", ring: square(100, 200, 500), size: size)]
        XCTAssertEqual(AirspaceTagPlacer.place(requests, in: bounds, keepOut: []),
                       AirspaceTagPlacer.place(requests, in: bounds, keepOut: []))
    }

    func testTheCockpitDrawsTagsAndPlanMapDrawsBoundaryLabels() {
        XCTAssertTrue(MapFeatures.cockpit.contains(.airspaceTags))
        XCTAssertFalse(MapFeatures.cockpit.contains(.airspaceLabels))
        XCTAssertTrue(MapFeatures.navigation.contains(.airspaceLabels))
        XCTAssertFalse(MapFeatures.navigation.contains(.airspaceTags))
        XCTAssertTrue(MapFeatures.dryRun.contains(.airspaceTags))
        XCTAssertTrue(MapFeatures.builder.contains(.airspaceLabels))
    }

    func testAllLimitsSwapsTheTagsForBoundaryLabels() {
        let all = MapFeatures.cockpit.showingAllLimits()
        XCTAssertTrue(all.contains(.airspaceLabels))
        XCTAssertFalse(all.contains(.airspaceTags))
    }

    func testTheChromeKeepsItsOwnFramesFromTheTags() {
        let geometry = MapChromeGeometry(size: CGSize(width: 820, height: 604), scale: .kneeboard)
        XCTAssertTrue(geometry.tagKeepOut.contains(geometry.statusSlot))
        XCTAssertTrue(geometry.tagKeepOut.contains(geometry.stack))
    }

    func testAnOlderRecordKeepsTheLimitsOn() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.showAirspaceLimits)
    }

    func testAnOlderWriterCantTurnTheLimitsBackOn() {
        var local = AppSettings()
        local.showAirspaceLimits = false
        var older = AppSettings()
        older.schemaVersion = 8
        XCTAssertFalse(local.preservingFieldsUnknownTo(older).showAirspaceLimits)
    }
}
