import XCTest
import CoreLocation
@testable import AeroCheck

/// Airspace limits against a planned altitude, as the route profile's conflict check reads them
/// (`OpenAIPDataService.airspaceProfileBlocks`).
///
/// Only a limit in feet MSL compares directly with a planned altitude. A limit in ft AGL follows the
/// terrain, and a flight level is on 1013.25 hPa. Read as feet MSL, a 2000 ft AGL ceiling over a
/// 1400 ft aerodrome is drawn 1400 ft too low, and a route drawn above the zone is inside it.
///
/// The route runs east along 47.2°N from 7.30°E to 7.50°E (about 8 NM); the zones sit on its middle
/// half, 7.35°E to 7.45°E.
@MainActor
final class AirspaceVerticalLimitsTests: XCTestCase {

    // MARK: - Fixtures

    private let route = [
        CLLocationCoordinate2D(latitude: 47.2, longitude: 7.30),
        CLLocationCoordinate2D(latitude: 47.2, longitude: 7.50),
    ]

    private func zone(_ name: String, type: Int, icaoClass: Int?,
                      floor: AltitudeLimit, ceiling: AltitudeLimit) -> Airspace {
        let ring: [[Double]] = [[7.35, 47.15], [7.35, 47.25], [7.45, 47.25], [7.45, 47.15], [7.35, 47.15]]
        return Airspace(id: name, name: name, type: type, icaoClass: icaoClass, country: "CH",
                        upperCeiling: ceiling, lowerCeiling: floor,
                        geometry: AirspaceGeometry(type: "Polygon", coordinates: [ring]),
                        activity: nil, frequencies: nil)
    }

    private let ground = AltitudeLimit(value: 0, unit: 1, referenceDatum: 0)
    private func agl(_ feet: Int) -> AltitudeLimit { AltitudeLimit(value: feet, unit: 1, referenceDatum: 0) }
    private func msl(_ feet: Int) -> AltitudeLimit { AltitudeLimit(value: feet, unit: 1, referenceDatum: 1) }
    private func fl(_ level: Int) -> AltitudeLimit { AltitudeLimit(value: level, unit: 6, referenceDatum: 2) }

    /// Like RMZ GRENCHEN: from the ground to 2000 ft AGL.
    private var rmz: Airspace { zone("RMZ GOLF", type: 6, icaoClass: 6, floor: ground, ceiling: agl(2000)) }

    private func blocks(_ airspaces: [Airspace], at altitude: Double?,
                        terrain: [AltitudePlanner.TerrainSample] = []) -> [AirspaceProfileBlock] {
        let service = OpenAIPDataService()
        service.seedForTesting(airspaces)
        return service.airspaceProfileBlocks(route, altitudesFt: [altitude, altitude], terrain: terrain)
    }

    /// The same ground all along the route (about 8 NM; the profile spans a little more).
    private func flat(_ feet: Double) -> [AltitudePlanner.TerrainSample] {
        [.init(distanceNM: 0, elevationFt: feet), .init(distanceNM: 10, elevationFt: feet)]
    }

    // MARK: - The defect

    /// 3000 ft MSL is 1000 ft above "2000" read as feet MSL, and inside the zone wherever the ground
    /// under it is higher than 1000 ft: the check cannot rule that out without the terrain.
    func testRouteAboveAnAGLCeilingReadAsMSLIsNotReportedClear() {
        let result = blocks([rmz], at: 3000)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.first?.isConflict ?? false,
                      "a 2000 ft AGL ceiling must not clear a route at 3000 ft MSL over unknown terrain")
    }

    /// FL75 on a low-QNH day sits below 7500 ft on the altimeter: at 985 hPa it is about 6740 ft.
    /// Beyond the 500 ft buffer, a route at 6800 ft was reported clear of it.
    func testRouteJustBelowAFlightLevelFloorIsNotReportedClear() {
        let tma = zone("TMA HOTEL", type: 7, icaoClass: 2, floor: fl(75), ceiling: fl(195))
        let result = blocks([tma], at: 6800)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.first?.isConflict ?? false,
                      "a flight-level floor must not clear a route that low QNH would put inside it")
    }

    // MARK: - Limits in ft AGL

    /// Without the terrain it is a conflict that says why, so the profile and the list can show it
    /// as a possible one rather than a sure one.
    func testAGLCeilingOverUnknownTerrainIsAPossibleConflict() {
        let block = blocks([rmz], at: 3000).first
        XCTAssertEqual(block?.verticalUncertainty, [.terrainUnknown])
        XCTAssertTrue(block?.isVerticallyUncertain ?? false)
        // Drawn from the lowest the ceiling can be, and reaching as high as anything.
        XCTAssertEqual(block?.ceilingFt, 2000)
        XCTAssertEqual(block?.outerCeilingFt, .infinity)
    }

    /// Over Grenchen's 1400 ft the ceiling is at 3400 ft: the route at 3000 ft is inside, surely.
    func testAGLCeilingOverKnownTerrainPutsTheRouteInside() {
        let block = blocks([rmz], at: 3000, terrain: flat(1400)).first
        XCTAssertEqual(block?.isConflict, true)
        XCTAssertEqual(block?.isVerticallyUncertain, false)
        XCTAssertEqual(block?.ceilingFt ?? 0, 3400, accuracy: 0.5)
    }

    /// With the terrain known, a route well above the resolved ceiling is clear again, not a guess.
    func testRouteAboveTheResolvedAGLCeilingIsClear() {
        let block = blocks([rmz], at: 4500, terrain: flat(1400)).first
        XCTAssertEqual(block?.isConflict, false, "3400 ft ceiling, route 1100 ft above it")
    }

    /// A floor in ft AGL over high ground is higher than its value: read as feet MSL, a glider area
    /// from 2000 ft AGL over 3000 ft terrain flagged a route at 4000 ft that passes under it.
    func testAGLFloorOverKnownTerrainClearsARouteUnderIt() {
        let glider = zone("LSR20 GOLF", type: 21, icaoClass: 8, floor: agl(2000), ceiling: fl(90))
        XCTAssertEqual(blocks([glider], at: 4000, terrain: flat(3000)).first?.isConflict, false)
        XCTAssertEqual(blocks([glider], at: 4000).first?.verticalUncertainty, [.terrainUnknown],
                       "without the terrain the floor could be as low as 2000 ft")
    }

    /// An AGL ceiling follows the ground, so it is drawn sample by sample, not as one flat top.
    func testAGLCeilingIsDrawnFollowingTheGround() {
        let rising: [AltitudePlanner.TerrainSample] = [.init(distanceNM: 0, elevationFt: 1000),
                                                       .init(distanceNM: 8.2, elevationFt: 3000)]
        guard let block = blocks([rmz], at: 6000, terrain: rising).first else { return XCTFail("no block") }
        let tops = block.outline.map(\.ceilingFt)
        XCTAssertGreaterThan(tops.count, 2)
        XCTAssertEqual(tops, tops.sorted(), "the ceiling climbs with the ground")
        XCTAssertGreaterThan((tops.last ?? 0) - (tops.first ?? 0), 500)
        XCTAssertEqual(block.ceilingFt, tops.max())
    }

    // MARK: - Flight levels

    func testFlightLevelFloorPossibleConflictSaysWhy() {
        let tma = zone("TMA HOTEL", type: 7, icaoClass: 2, floor: fl(75), ceiling: fl(195))
        let block = blocks([tma], at: 6800).first
        XCTAssertEqual(block?.verticalUncertainty, [.flightLevel])
        XCTAssertEqual(block?.floorFt, 7500, "drawn at FL × 100 on standard pressure")
        XCTAssertEqual(block?.outerFloorFt, 6500)
    }

    func testRouteWellInsideAFlightLevelBandIsAPlainConflict() {
        let tma = zone("TMA HOTEL", type: 7, icaoClass: 2, floor: fl(75), ceiling: fl(195))
        let block = blocks([tma], at: 9500).first
        XCTAssertEqual(block?.isConflict, true)
        XCTAssertEqual(block?.isVerticallyUncertain, false)
    }

    /// 1500 ft under FL75 no plausible QNH (and no 500 ft buffer) reaches the route.
    func testRouteFarUnderAFlightLevelFloorIsClear() {
        let tma = zone("TMA HOTEL", type: 7, icaoClass: 2, floor: fl(75), ceiling: fl(195))
        XCTAssertEqual(blocks([tma], at: 5900).first?.isConflict, false)
    }

    // MARK: - Unchanged

    func testMSLLimitsCompareAsBefore() {
        let ctr = zone("CTR INDIA", type: 4, icaoClass: 3, floor: ground, ceiling: msl(4500))
        XCTAssertEqual(blocks([ctr], at: 3000).first?.isConflict, true)
        XCTAssertEqual(blocks([ctr], at: 3000).first?.isVerticallyUncertain, false)
        XCTAssertEqual(blocks([ctr], at: 4900).first?.isConflict, true, "within the 500 ft buffer")
        XCTAssertEqual(blocks([ctr], at: 5100).first?.isConflict, false)
    }

    /// A route with no planned altitude counts every crossing, as before.
    func testNoAltitudeProfileCountsTheCrossing() {
        let block = blocks([rmz], at: nil).first
        XCTAssertEqual(block?.isConflict, true)
        XCTAssertEqual(block?.isVerticallyUncertain, false)
    }

    // MARK: - Resolving one limit

    func testResolvedLimits() {
        let terrain: ClosedRange<Double> = 1200...1800
        // Feet MSL: exact.
        XCTAssertEqual(msl(4500).resolved(as: .ceiling, terrainFt: terrain),
                       ResolvedAltitudeLimit(low: 4500, high: 4500, nominal: 4500, uncertainty: nil))
        // GND: the surface, whatever the terrain samples say.
        XCTAssertEqual(ground.resolved(as: .floor, terrainFt: terrain).nominal, 0)
        // AGL: the highest ground for a ceiling, the lowest for a floor.
        XCTAssertEqual(agl(2000).resolved(as: .ceiling, terrainFt: terrain).nominal, 3800)
        XCTAssertEqual(agl(2000).resolved(as: .floor, terrainFt: terrain).nominal, 3200)
        // AGL over unknown terrain: at least its value, no upper bound, no nominal figure.
        XCTAssertEqual(agl(2000).resolved(as: .ceiling, terrainFt: nil),
                       ResolvedAltitudeLimit(low: 2000, high: .infinity, nominal: nil, uncertainty: .terrainUnknown))
        // Metres AGL.
        let metres = AltitudeLimit(value: 300, unit: 0, referenceDatum: 0).resolved(as: .ceiling, terrainFt: 1000...1000)
        XCTAssertEqual(metres.nominal ?? 0, 1000 + 300 * 3.28084, accuracy: 0.01)
        // A flight level: FL × 100 on 1013.25 hPa, ± the QNH margin.
        XCTAssertEqual(fl(75).resolved(as: .floor, terrainFt: terrain),
                       ResolvedAltitudeLimit(low: 6500, high: 8500, nominal: 7500, uncertainty: .flightLevel))
    }

    func testVerdict() {
        let tma = zone("TMA HOTEL", type: 7, icaoClass: 2, floor: fl(75), ceiling: msl(12000))
        let band = AirspaceVerticalBand(tma, terrainFt: nil)
        XCTAssertEqual(band.verdict(altitudeFt: 8000), .inside)
        XCTAssertEqual(band.verdict(altitudeFt: 7000), .possiblyInside([.flightLevel]))
        XCTAssertEqual(band.verdict(altitudeFt: 6000), .outside)
        XCTAssertEqual(band.verdict(altitudeFt: 7000, bufferFt: 500), .inside, "within the buffer of FL75")
        XCTAssertEqual(band.verdict(altitudeFt: 12400), .outside, "the MSL ceiling is exact")
    }

    // MARK: - Terrain around a point

    func testTerrainRange() {
        let terrain: [AltitudePlanner.TerrainSample] = [
            .init(distanceNM: 0, elevationFt: 1000), .init(distanceNM: 1, elevationFt: 3000),
            .init(distanceNM: 2, elevationFt: 1000),
        ]
        // A ridge between two route samples is not skipped.
        XCTAssertEqual(AltitudePlanner.terrainRange(terrain, fromNM: 0.5, toNM: 1.5), 2000...3000)
        // Between samples: interpolated at both ends.
        XCTAssertEqual(AltitudePlanner.terrainRange(terrain, fromNM: 0.25, toNM: 0.5), 1500...2000)
        // Clamped to the profile at its ends.
        XCTAssertEqual(AltitudePlanner.terrainRange(terrain, fromNM: -0.5, toNM: 0), 1000...1000)
        // Nothing to say without terrain, or off the profile.
        XCTAssertNil(AltitudePlanner.terrainRange([], fromNM: 0, toNM: 1))
        XCTAssertNil(AltitudePlanner.terrainRange(terrain, fromNM: 3, toNM: 4))
    }
}
