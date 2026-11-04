import CoreLocation
import XCTest
@testable import AeroCheck

/// What a tap on the map lists (a12 A).
final class AirspaceStackTests: XCTestCase {
    private let here = CLLocationCoordinate2D(latitude: 47, longitude: 7)

    private func airspace(_ name: String, _ type: AirspaceTypeCategory = .tma, cls: Int? = 3, lower: Int = 0, upper: Int = 3000,
                          frequency: AirspaceFrequency? = nil, away: Bool = false) -> Airspace {
        let west = away ? 8.0 : 6.9, south = 46.9
        let ring = [[west, south], [west + 0.2, south], [west + 0.2, south + 0.2], [west, south + 0.2], [west, south]]
        return Airspace(id: name, name: name, type: type.rawValue, icaoClass: cls, country: "CH",
                        upperCeiling: AltitudeLimit(value: upper, unit: 1, referenceDatum: 1),
                        lowerCeiling: AltitudeLimit(value: lower, unit: 1, referenceDatum: 1),
                        geometry: AirspaceGeometry(type: "Polygon", coordinates: [ring]), activity: nil,
                        frequencies: frequency.map { [$0] })
    }

    func testNothingThereIsNoCard() {
        XCTAssertNil(AirspaceStack.make(at: here, from: [airspace("A", away: true)], altitudeFt: 3000))
    }

    func testTheRowsReadTopDown() throws {
        let stack = try XCTUnwrap(AirspaceStack.make(at: here, from: [
            airspace("low", lower: 0, upper: 2000), airspace("high", lower: 5000, upper: 9000),
            airspace("mid", lower: 2000, upper: 5000)], altitudeFt: 3000))
        XCTAssertEqual(stack.rows.map(\.name), ["high", "mid", "low"])
    }

    func testTheBandThatHoldsTheAircraftIsFramed() throws {
        let stack = try XCTUnwrap(AirspaceStack.make(at: here, from: [
            airspace("low", lower: 0, upper: 2000), airspace("mid", lower: 2000, upper: 5000)], altitudeFt: 3500))
        XCTAssertEqual(stack.rows.filter(\.holdsAircraft).map(\.name), ["mid"])
    }

    func testNoAircraftFramesNothing() throws {
        let stack = try XCTUnwrap(AirspaceStack.make(at: here, from: [airspace("mid")], altitudeFt: nil))
        XCTAssertFalse(stack.rows[0].holdsAircraft)
    }

    func testAnInformationAreaIsLeftOut() {
        XCTAssertNil(AirspaceStack.make(at: here, from: [airspace("FIS", .fisSector, cls: nil),
                                                         airspace("FIR", .fir, cls: nil)], altitudeFt: 3000))
    }

    func testAtMostSixRowsTheClosestToTheAircraft() throws {
        let many = (0..<9).map { airspace("L\($0)", lower: $0 * 1000, upper: $0 * 1000 + 900) }
        let stack = try XCTUnwrap(AirspaceStack.make(at: here, from: many, altitudeFt: 4500))
        XCTAssertEqual(stack.rows.count, 6)
        XCTAssertTrue(stack.rows.contains { $0.name == "L4" })
        XCTAssertFalse(stack.rows.contains { $0.name == "L8" })
    }

    func testAFrequencyGoesWithItsRow() throws {
        let frequency = AirspaceFrequency(value: "118.100", name: "ZURICH TOWER", primary: true, unit: nil)
        let stack = try XCTUnwrap(AirspaceStack.make(at: here, from: [airspace("A", frequency: frequency)], altitudeFt: nil))
        XCTAssertEqual(stack.rows[0].frequency, "118.100")
    }

    func testTheCardOpensOnlyWhereTheMapSaysSo() {
        XCTAssertTrue(MapFeatures.navigation.contains(.airspaceCard))
        XCTAssertTrue(MapFeatures.cockpit.contains(.airspaceCard))
        XCTAssertFalse(MapFeatures.builder.contains(.airspaceCard))
    }
}
