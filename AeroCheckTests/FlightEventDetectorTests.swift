import XCTest
import CoreLocation
@testable import AeroCheck

/// Tests that flight-event detection thresholds scale with the GPS recording interval
/// rather than assuming the legacy 5 s cadence (PERF-05), plus scripted-trajectory fixtures that
/// pin the go-around vs touch-and-go vs full-stop classification (PR-22 / PR-34).
@MainActor
final class FlightEventDetectorTests: XCTestCase {

    func testThresholdsAtDefaultIntervalMatchLegacyConstants() {
        let detector = FlightEventDetector()
        detector.configure(speeds: [], stallSpeed: 50, recordingInterval: 5)
        // 40 s full-stop dwell, 15 s touchdown/smoothing at a 5 s cadence → 8 / 3 / 3.
        XCTAssertEqual(detector.requiredTaxiSpeedReadings, 8)
        XCTAssertEqual(detector.minTouchdownReadings, 3)
        XCTAssertEqual(detector.speedSmoothingReadings, 3)
    }

    func testThresholdsScaleUpAtFastInterval() {
        let detector = FlightEventDetector()
        detector.configure(speeds: [], stallSpeed: 50, recordingInterval: 1)
        // At 1 s, a full stop needs ~40 readings (not 8) so it isn't declared after ~8 s.
        XCTAssertEqual(detector.requiredTaxiSpeedReadings, 40)
        XCTAssertEqual(detector.minTouchdownReadings, 15)
        XCTAssertEqual(detector.speedSmoothingReadings, 15)
    }

    func testThresholdsClampAtSlowInterval() {
        let detector = FlightEventDetector()
        detector.configure(speeds: [], stallSpeed: 50, recordingInterval: 30)
        // ceil(40/30)=2, ceil(15/30)=1 clamped to the minimum of 2 (a single noisy sample
        // must never trigger a transition).
        XCTAssertEqual(detector.requiredTaxiSpeedReadings, 2)
        XCTAssertEqual(detector.minTouchdownReadings, 2)
        XCTAssertGreaterThanOrEqual(detector.speedSmoothingReadings, 2)
    }

    func testInvalidIntervalFallsBackToDefault() {
        let detector = FlightEventDetector()
        detector.configure(speeds: [], stallSpeed: 50, recordingInterval: 0)
        // A non-positive interval is treated as the 5 s default.
        XCTAssertEqual(detector.requiredTaxiSpeedReadings, 8)
    }

    // MARK: - Scripted-trajectory fixtures (PR-34 / PR-22)
    //
    // With `stallSpeed: 50` and the 5 s cadence the derived thresholds are:
    //   touchdown ≈ 60 kt · touch-and-go accel ≈ 60 kt · go-around-min ≈ 47.5 kt · taxi 10 kt
    //   minTouchdownReadings = 3 · requiredTaxiSpeedReadings = 8 · smoothing window = 3
    // Speed is smoothed over the last 3 readings, so each phase feeds several consistent readings.

    /// A flat test field at sea level (so altitude MSL == AGL ft) the trajectory flies over.
    private func testField() -> Airport {
        Airport(id: 1, ident: "TEST", type: .smallAirport, name: "Test Field",
                latitude: 47.0, longitude: 8.0, elevation: 0, continent: "EU",
                isoCountry: "CH", isoRegion: "CH-ZH", municipality: nil,
                scheduledService: false, gpsCode: nil, iataCode: nil, localCode: nil)
    }

    /// Drives a detector with scripted (altAGL ft, ground speed kt) readings over the field at a
    /// fixed 5 s cadence on an injected clock. Position is the field itself (distance ≈ 0), so the
    /// zone/low-approach transitions are driven purely by altitude + speed.
    @MainActor
    private final class TrajectoryDriver {
        let detector = FlightEventDetector()
        let field: Airport
        private var now = Date(timeIntervalSince1970: 1_000_000)
        private let interval: TimeInterval = 5

        init(field: Airport, stallSpeed: Int = 50) {
            self.field = field
            detector.configure(speeds: [], stallSpeed: stallSpeed, recordingInterval: interval)
            detector.clock = { [weak self] in self?.now ?? Date() }
        }

        /// Feed `count` readings at the given altitude/speed, advancing the clock each step.
        /// `offsetNm` places the aircraft that many NM north of the field (0 = over the field), to
        /// drive lateral distance-based zone exits.
        func fly(altFt: Double, speedKts: Double, count: Int, offsetNm: Double = 0) {
            let coordinate = CLLocationCoordinate2D(
                latitude: field.latitude + offsetNm / 60.0, // ~60 NM per degree of latitude
                longitude: field.longitude
            )
            for _ in 0..<count {
                let loc = CLLocation(
                    coordinate: coordinate,
                    altitude: altFt * 0.3048,                 // ft → m (field elevation 0 ⇒ AGL == MSL)
                    horizontalAccuracy: 5, verticalAccuracy: 5,
                    course: 0, speed: speedKts / 1.94384,     // kt → m/s
                    timestamp: now
                )
                detector.processLocation(loc, nearbyAirports: [field])
                now = now.addingTimeInterval(interval)
            }
        }
    }

    /// (1) Approach → touchdown → sustained taxi ⇒ a single full stop.
    func testApproachThenTouchdownThenTaxiEmitsFullStop() {
        let d = TrajectoryDriver(field: testField())
        d.fly(altFt: 300, speedKts: 70, count: 4)   // airborne, in airport zone
        d.fly(altFt: 60, speedKts: 70, count: 3)    // descend into low approach
        d.fly(altFt: 5, speedKts: 45, count: 4)     // touchdown (slows below 60)
        d.fly(altFt: 0, speedKts: 3, count: 12)     // sustained taxi/stop ≥ 8 readings

        XCTAssertNotNil(d.detector.pendingFullStop, "Sustained near-zero speed on the field is a full stop")
        XCTAssertNil(d.detector.pendingTouchAndGo)
        XCTAssertNil(d.detector.pendingGoAround)
    }

    /// (2) Approach → brief touchdown → re-accelerate at low altitude ⇒ touch-and-go.
    func testTouchdownThenReaccelLowEmitsTouchAndGo() {
        let d = TrajectoryDriver(field: testField())
        d.fly(altFt: 300, speedKts: 70, count: 4)   // airborne, airport zone
        d.fly(altFt: 50, speedKts: 70, count: 3)    // low approach (altitude-confirmed)
        d.fly(altFt: 20, speedKts: 45, count: 4)    // touchdown, no real ground roll
        d.fly(altFt: 25, speedKts: 70, count: 4)    // re-accelerate, staying low (< 50 ft climb)

        XCTAssertNotNil(d.detector.pendingTouchAndGo, "Re-accel at low altitude after touchdown is a T&G")
        XCTAssertNil(d.detector.pendingGoAround, "A low re-accel must not be classed as a go-around")
    }

    /// (3) Low approach that never slows to landing speed ⇒ go-around.
    func testLowApproachWithoutSlowingEmitsGoAround() {
        let d = TrajectoryDriver(field: testField())
        d.fly(altFt: 300, speedKts: 75, count: 4)   // airborne, airport zone
        d.fly(altFt: 60, speedKts: 75, count: 3)    // low approach, stays fast (never below 60)
        d.fly(altFt: 250, speedKts: 80, count: 4)   // climb out above the low-approach exit

        XCTAssertNotNil(d.detector.pendingGoAround, "A fast low pass that climbs away is a go-around")
        XCTAssertNil(d.detector.pendingTouchAndGo)
        XCTAssertNil(d.detector.pendingFullStop)
    }

    /// (3b) PR-23 descent-then-climb gate: a fast low pass that leaves the zone LATERALLY at the
    /// same low altitude (never climbs out) must NOT be classed as a go-around.
    func testLowLateralPassWithoutClimbDoesNotEmitGoAround() {
        let d = TrajectoryDriver(field: testField())
        d.fly(altFt: 300, speedKts: 75, count: 4)               // airborne, airport zone
        d.fly(altFt: 60, speedKts: 75, count: 3)                // low approach, stays fast
        d.fly(altFt: 60, speedKts: 80, count: 4, offsetNm: 2.0) // depart laterally, no climb

        XCTAssertNil(d.detector.pendingGoAround,
                     "A low lateral pass with no climb-out is not a go-around (PR-23)")
        XCTAssertNil(d.detector.pendingTouchAndGo)
    }

    /// (4) THE PR-22 regression: touchdown then a 150+ ft climb-out ⇒ go-around, NOT touch-and-go.
    func testTouchdownThenClimbOutEmitsGoAroundNotTouchAndGo() {
        let d = TrajectoryDriver(field: testField())
        d.fly(altFt: 300, speedKts: 70, count: 4)   // airborne, airport zone
        d.fly(altFt: 50, speedKts: 70, count: 3)    // low approach
        d.fly(altFt: 20, speedKts: 50, count: 4)    // brief dip below touchdown, no ground roll
        d.fly(altFt: 120, speedKts: 70, count: 3)   // power up, climbing through 100 ft
        d.fly(altFt: 220, speedKts: 75, count: 3)   // 200 ft above touchdown

        XCTAssertNotNil(d.detector.pendingGoAround, "A balked landing that climbs away is a go-around")
        XCTAssertNil(d.detector.pendingTouchAndGo, "It must NOT be mislabelled a touch-and-go (PR-22)")
    }

    /// (5) Speed-based touchdown high above the field (altitude unconfirmed) then re-accel ⇒ NOT a T&G.
    func testHighAltitudeSpeedFallbackDoesNotEmitTouchAndGo() {
        let d = TrajectoryDriver(field: testField())
        d.fly(altFt: 300, speedKts: 70, count: 4)   // airborne, airport zone (above 100 ft AGL)
        d.fly(altFt: 300, speedKts: 45, count: 4)   // speed-based touchdown, altitude NOT confirmed
        d.fly(altFt: 300, speedKts: 70, count: 4)   // re-accel, still high, no ground evidence

        XCTAssertNil(d.detector.pendingTouchAndGo,
                     "A high-altitude speed dip with no ground evidence must not become a T&G")
    }
}
