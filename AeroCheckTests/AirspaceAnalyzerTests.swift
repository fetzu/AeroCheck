import XCTest
import CoreLocation
@testable import AeroCheck

/// Tests for route/airspace conflict geometry and the datum-aware vertical check.
/// (PERF-01 exact intersection, PERF-08 fail-safe altitude, PERF-19 severity.)
final class AirspaceAnalyzerTests: XCTestCase {

    /// Builds a rectangular CTR. Ring pairs are [lon, lat] per the OpenAIP geometry schema.
    private func makeCTR(
        latMin: Double, latMax: Double, lonMin: Double, lonMax: Double,
        lower: AltitudeLimit, upper: AltitudeLimit, id: String = "ctr-test"
    ) -> Airspace {
        let ring: [[Double]] = [
            [lonMin, latMin], [lonMax, latMin], [lonMax, latMax], [lonMin, latMax], [lonMin, latMin],
        ]
        return Airspace(
            id: id, name: "TEST CTR", type: 4 /* CTR */, icaoClass: 4, country: "CH",
            upperCeiling: upper, lowerCeiling: lower,
            geometry: AirspaceGeometry(type: "Polygon", coordinates: [ring]),
            activity: nil, frequencies: nil
        )
    }

    private let mslLower = AltitudeLimit(value: 0, unit: 1, referenceDatum: 1)
    private let mslUpper = AltitudeLimit(value: 10000, unit: 1, referenceDatum: 1)

    /// PERF-01: a long leg that clips a tiny CTR between the old fixed 10 sample points must
    /// still be detected as a transit (exact segment/polygon intersection).
    func testCornerClipDetectedAsTransit() {
        // Tiny CTR (~0.004° wide) positioned so the old 10-point sampling of the leg below
        // lands no sample inside it.
        let ctr = makeCTR(latMin: 47.00, latMax: 47.02, lonMin: 8.10, lonMax: 8.104,
                          lower: mslLower, upper: mslUpper)
        let waypoints: [(coordinate: CLLocationCoordinate2D, altitude: Double?)] = [
            (CLLocationCoordinate2D(latitude: 47.01, longitude: 6.0), nil),
            (CLLocationCoordinate2D(latitude: 47.01, longitude: 10.0), nil),
        ]
        let conflicts = AirspaceAnalyzer.analyzeRoute(waypoints: waypoints, airspaces: [ctr])
        XCTAssertTrue(conflicts.contains { $0.conflictType == .transit },
                      "Leg clipping the CTR should be flagged as a transit")
    }

    func testLegFarAwayProducesNoConflict() {
        let ctr = makeCTR(latMin: 47.00, latMax: 47.02, lonMin: 8.10, lonMax: 8.104,
                          lower: mslLower, upper: mslUpper)
        let waypoints: [(coordinate: CLLocationCoordinate2D, altitude: Double?)] = [
            (CLLocationCoordinate2D(latitude: 40.0, longitude: 0.0), nil),
            (CLLocationCoordinate2D(latitude: 40.0, longitude: 1.0), nil),
        ]
        XCTAssertTrue(AirspaceAnalyzer.analyzeRoute(waypoints: waypoints, airspaces: [ctr]).isEmpty)
    }

    /// PERF-08: with AGL/FL-referenced limits the vertical overlap can't be computed precisely,
    /// so the conflict must NOT be dropped — it must be reported with altitudeUncertain == true.
    func testAglLimitsFlagAltitudeUncertain() {
        let aglUpper = AltitudeLimit(value: 3000, unit: 1, referenceDatum: 0) // 3000 ft AGL
        let ctr = makeCTR(latMin: 47.00, latMax: 47.02, lonMin: 8.10, lonMax: 8.104,
                          lower: mslLower, upper: aglUpper)
        let waypoints: [(coordinate: CLLocationCoordinate2D, altitude: Double?)] = [
            (CLLocationCoordinate2D(latitude: 47.01, longitude: 8.101), 2000),
            (CLLocationCoordinate2D(latitude: 47.01, longitude: 8.103), 2000),
        ]
        let conflicts = AirspaceAnalyzer.analyzeRoute(waypoints: waypoints, airspaces: [ctr])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertTrue(conflicts.first?.altitudeUncertain == true,
                      "AGL-limited airspace should be flagged as altitude-uncertain")
    }

    /// MSL limits clearly below the planned altitude → no vertical conflict (precise check).
    func testMslLimitsBelowAltitudeNoConflict() {
        let lowUpper = AltitudeLimit(value: 1000, unit: 1, referenceDatum: 1) // 0–1000 ft MSL
        let ctr = makeCTR(latMin: 47.00, latMax: 47.02, lonMin: 8.10, lonMax: 8.104,
                          lower: mslLower, upper: lowUpper)
        let waypoints: [(coordinate: CLLocationCoordinate2D, altitude: Double?)] = [
            (CLLocationCoordinate2D(latitude: 47.01, longitude: 8.101), 5000),
            (CLLocationCoordinate2D(latitude: 47.01, longitude: 8.103), 5000),
        ]
        XCTAssertTrue(AirspaceAnalyzer.analyzeRoute(waypoints: waypoints, airspaces: [ctr]).isEmpty)
    }
}
