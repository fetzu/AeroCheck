import XCTest
import CoreLocation
@testable import AeroCheck

/// `AltitudePlanner`: the builder's "Set altitudes".
///
/// Four waypoints east along 47°N; terrain is flat at 1500 ft except a 4000 ft ridge in the MIDDLE of
/// the B→C leg — higher than the ground under either end, which is exactly the case the default basis
/// exists for.
final class AltitudePlannerTests: XCTestCase {

    private func route(_ altitudes: [Double?] = [1500, 3000, 3000, 1500]) -> [FlightPlanWaypoint] {
        [7.0, 7.3, 7.6, 7.9].enumerated().map { i, lon in
            FlightPlanWaypoint(name: "W\(i)", coordinate: .init(latitude: 47.0, longitude: lon), altitude: altitudes[i])
        }
    }

    private func terrain(for wps: [FlightPlanWaypoint]) -> [AltitudePlanner.TerrainSample] {
        let cum = AltitudePlanner.cumulativeNM(wps)
        let ridge = (cum[1] + cum[2]) / 2
        return stride(from: 0.0, through: cum[3], by: 0.1).map { d in
            AltitudePlanner.TerrainSample(distanceNM: d, elevationFt: abs(d - ridge) < 0.5 ? 4000 : 1500)
        }
    }

    func testDefaultBasisClearsTheHighestTerrainOnEitherLeg() {
        let wps = route()
        let t = terrain(for: wps)
        let mode = AltitudePlanner.Mode.aboveTerrain(clearanceFt: 1000, basis: .highestOnAdjacentLegs, roundToFt: 100)
        let alts = AltitudePlanner.proposedAltitudes(for: wps, selected: [1, 2], mode: mode, terrain: t)
        XCTAssertEqual(alts, [1500, 5000, 5000, 1500])
        let clearances = AltitudePlanner.legClearances(for: wps, altitudes: alts, terrain: t)
        XCTAssertEqual(clearances[1] ?? 0, 1000, accuracy: 1, "the ridge leg gets exactly the clearance asked for")
    }

    func testGroundAtTheWaypointMissesARidgeBetweenThem() {
        let wps = route()
        let t = terrain(for: wps)
        let mode = AltitudePlanner.Mode.aboveTerrain(clearanceFt: 1000, basis: .groundAtWaypoint, roundToFt: 100)
        let alts = AltitudePlanner.proposedAltitudes(for: wps, selected: [1, 2], mode: mode, terrain: t)
        XCTAssertEqual(alts, [1500, 2500, 2500, 1500])
        let clearances = AltitudePlanner.legClearances(for: wps, altitudes: alts, terrain: t)
        XCTAssertLessThan(clearances[1] ?? 0, 0, "why this basis is not the default")
    }

    func testRoundingIsUpwards() {
        let wps = route()
        let mode = AltitudePlanner.Mode.aboveTerrain(clearanceFt: 1100, basis: .highestOnAdjacentLegs, roundToFt: 500)
        let alts = AltitudePlanner.proposedAltitudes(for: wps, selected: [1], mode: mode, terrain: terrain(for: wps))
        XCTAssertEqual(alts[1], 5500)
    }

    func testFixedAltitudeOnlyTouchesTheSelection() {
        let wps = route()
        let alts = AltitudePlanner.proposedAltitudes(for: wps, selected: [1], mode: .fixed(feet: 7500), terrain: [])
        XCTAssertEqual(alts, [1500, 7500, 3000, 1500])
    }

    func testDepartureAndDestinationAreNeverChanged() {
        let wps = route()
        let alts = AltitudePlanner.proposedAltitudes(for: wps, selected: [0, 1, 2, 3], mode: .fixed(feet: 7500), terrain: [])
        XCTAssertEqual(alts.first, 1500)
        XCTAssertEqual(alts.last, 1500)
    }

    func testNoTerrainKeepsTheCurrentAltitude() {
        let wps = route()
        let mode = AltitudePlanner.Mode.aboveTerrain(clearanceFt: 1000, basis: .highestOnAdjacentLegs, roundToFt: 100)
        XCTAssertEqual(AltitudePlanner.proposedAltitudes(for: wps, selected: [1, 2], mode: mode, terrain: []),
                       [1500, 3000, 3000, 1500])
    }

    func testTerrainIsMappedOntoTheRouteDistance() {
        let samples = AltitudePlanner.samples(fromMetres: [(0, 1000), (5, 500), (10, 0)], routeNM: 20)
        XCTAssertEqual(samples.map(\.distanceNM), [0, 10, 20])
        XCTAssertEqual(samples[0].elevationFt, 3280.84, accuracy: 0.01)
    }
}
