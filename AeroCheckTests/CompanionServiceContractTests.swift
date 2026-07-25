import XCTest
@testable import AeroCheck

/// Locks the Wi-Fi Aware companion service contract.
///
/// The `WiFiAwareServices` Info.plist declaration and the name the code looks up
/// (`companionWiFiAwareServiceName`) must stay in exact sync, and the transport label MUST be
/// `._udp`. A `._tcp` name makes Apple's WiFiAware framework trap with an *uncatchable* assertion
/// while parsing the Info.plist — which crashed the app 100% of the time on flight start whenever
/// companion mode was enabled (the iPad master's `startListening()` forces that parse). These tests
/// guard that regression, since it can never be caught at runtime.
final class CompanionServiceContractTests: XCTestCase {

    func testServiceNameUsesUdpTransport() {
        XCTAssertTrue(
            companionWiFiAwareServiceName.hasSuffix("._udp"),
            "Wi-Fi Aware service name must use the ._udp transport label, not ._tcp — the framework traps on ._tcp")
    }

    func testInfoPlistDeclaresExactlyTheServiceTheCodeLooksUp() throws {
        let services = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "WiFiAwareServices") as? [String: Any],
            "Info.plist must declare a WiFiAwareServices dictionary")

        let entry = try XCTUnwrap(
            services[companionWiFiAwareServiceName] as? [String: Any],
            "WiFiAwareServices must declare '\(companionWiFiAwareServiceName)' — the exact name the code looks up via WAPublishableService/WASubscribableService.aerocheck")

        // The same universal binary publishes (iPad master) and subscribes (iPhone viewer), so the
        // single declared service must advertise both roles. Each role value MUST be a DICTIONARY
        // (empty is fine, per Apple's "Adopting Wi-Fi Aware") — a Bool makes WiFiAware trap with
        // "'Publishable' key ... is malformed (not a dictionary)", which crashed 100% on Pair New
        // Device on iOS/iPadOS 26. (v4.1 fix)
        XCTAssertNotNil(entry["Publishable"] as? [String: Any],
                        "companion service 'Publishable' must be a dictionary (iPad master) — a Bool crashes WiFiAware")
        XCTAssertNotNil(entry["Subscribable"] as? [String: Any],
                        "companion service 'Subscribable' must be a dictionary (iPhone viewer) — a Bool crashes WiFiAware")
    }

    func testNoStaleTcpServiceNameRemains() {
        let services = Bundle.main.object(forInfoDictionaryKey: "WiFiAwareServices") as? [String: Any] ?? [:]
        XCTAssertNil(
            services["_aerocheck._tcp"],
            "A ._tcp service name must never reappear in WiFiAwareServices — it traps the WiFiAware parser on flight start")
    }

    // MARK: - Automatic pairing role (v4.1 — pairing UX simplification)

    func testCompanionRoleIsAutomaticByDeviceType() {
        // Wi-Fi Aware pairing is asymmetric; the role is derived from device type, not a user setting,
        // so two devices can never accidentally take the same role and fail to discover each other.
        XCTAssertEqual(CompanionRole.automatic(for: .pad), .master, "iPad drives / advertises")
        XCTAssertEqual(CompanionRole.automatic(for: .phone), .viewer, "iPhone connects / browses")
    }

    // MARK: - Shared GPS: source election (v4.1)

    func testElectionPrefersOwnGPS() {
        let e = GPSSourceElection()
        XCTAssertEqual(e.elect(ownValid: true, peerValid: true), .own, "own wins even when the peer is also valid")
        XCTAssertEqual(e.elect(ownValid: true, peerValid: false), .own)
    }

    func testElectionFallsBackToPeerWhenOwnInvalid() {
        XCTAssertEqual(GPSSourceElection().elect(ownValid: false, peerValid: true), .peer)
    }

    func testElectionNoneWhenNeitherValid() {
        XCTAssertEqual(GPSSourceElection().elect(ownValid: false, peerValid: false), .none)
    }

    func testFixValidityBoundsAccuracyAndAge() {
        let e = GPSSourceElection(maxFixAge: 5, maxAccuracy: 100)
        XCTAssertTrue(e.isValid(accuracy: 20, age: 2))
        XCTAssertFalse(e.isValid(accuracy: 200, age: 1), "too inaccurate")
        XCTAssertFalse(e.isValid(accuracy: 20, age: 10), "too old (the freshness window doubles as hysteresis)")
        XCTAssertFalse(e.isValid(accuracy: -1, age: 1), "negative accuracy = invalid fix")
        XCTAssertFalse(e.isValid(accuracy: nil, age: 1), "no accuracy = invalid")
        XCTAssertFalse(e.isValid(accuracy: 20, age: nil), "no age = invalid")
        XCTAssertFalse(e.isValid(accuracy: .nan, age: 1), "NaN accuracy = invalid")
        XCTAssertFalse(e.isValid(accuracy: 20, age: .infinity), "non-finite age = invalid")
    }

    // MARK: - Shared GPS: peer-fix geometry (SA-10)
    //
    // A paired peer is a network trust boundary. Accuracy and age alone said nothing about the
    // COORDINATE, so a peer could pair a plausible 10 m accuracy with an out-of-range or non-finite
    // latitude/longitude and be elected — after which the raw values reach MKCoordinateRegion /
    // MKAnnotation, and MapKit raises on an invalid coordinate: a mid-flight crash of the navigation
    // display. The same point also lands in the recorded track, corrupting the flight file.

    private func peerFix(lat: Double, lon: Double, accuracy: Double = 10,
                         altitude: Double? = 500, speed: Double? = 30,
                         course: Double? = 90) -> CompanionPeerGPS {
        CompanionPeerGPS(latitude: lat, longitude: lon, speedMPS: speed, altitudeMeters: altitude,
                         courseDegrees: course, horizontalAccuracy: accuracy,
                         signalStatus: "good", timestamp: Date())
    }

    func testPeerFixGeometryAcceptsARealCoordinate() {
        XCTAssertTrue(peerFix(lat: 47.0, lon: 8.0).hasValidGeometry)
        // Extremes of the valid range must still pass.
        XCTAssertTrue(peerFix(lat: 90, lon: 180).hasValidGeometry)
        XCTAssertTrue(peerFix(lat: -90, lon: -180).hasValidGeometry)
    }

    func testPeerFixGeometryRejectsNonFiniteCoordinates() {
        XCTAssertFalse(peerFix(lat: .nan, lon: 8.0).hasValidGeometry, "NaN latitude")
        XCTAssertFalse(peerFix(lat: 47.0, lon: .nan).hasValidGeometry, "NaN longitude")
        XCTAssertFalse(peerFix(lat: .infinity, lon: 8.0).hasValidGeometry, "+inf latitude")
        XCTAssertFalse(peerFix(lat: 47.0, lon: -.infinity).hasValidGeometry, "-inf longitude")
    }

    func testPeerFixGeometryRejectsOutOfRangeCoordinates() {
        XCTAssertFalse(peerFix(lat: 4.0e9, lon: 8.0).hasValidGeometry, "the report's example value")
        XCTAssertFalse(peerFix(lat: 91, lon: 8.0).hasValidGeometry)
        XCTAssertFalse(peerFix(lat: -90.001, lon: 8.0).hasValidGeometry)
        XCTAssertFalse(peerFix(lat: 47.0, lon: 181).hasValidGeometry)
        XCTAssertFalse(peerFix(lat: 47.0, lon: -180.5).hasValidGeometry)
    }

    func testPeerFixGeometryRejectsNonFiniteMotionValues() {
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, altitude: .nan).hasValidGeometry)
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, speed: .infinity).hasValidGeometry)
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, course: .nan).hasValidGeometry)
        XCTAssertFalse(peerFix(lat: 47.0, lon: 8.0, accuracy: .nan).hasValidGeometry)
    }

    func testPeerFixGeometryAllowsAbsentMotionValues() {
        // Absent is fine — they degrade to CoreLocation's "unknown" sentinels.
        XCTAssertTrue(peerFix(lat: 47.0, lon: 8.0, altitude: nil, speed: nil, course: nil)
            .hasValidGeometry)
    }

    func testPeerFixElectionRequiresBothGeometryAndFreshness() {
        let e = GPSSourceElection(maxFixAge: 5, maxAccuracy: 100)

        XCTAssertTrue(e.isPeerFixValid(peerFix(lat: 47.0, lon: 8.0), age: 1))
        // The attack: plausible accuracy, nonsense coordinate.
        XCTAssertFalse(e.isPeerFixValid(peerFix(lat: 4.0e9, lon: 8.0, accuracy: 10), age: 1),
                       "a plausible accuracy must not launder an invalid coordinate")
        // The pre-existing gates still apply.
        XCTAssertFalse(e.isPeerFixValid(peerFix(lat: 47.0, lon: 8.0, accuracy: 200), age: 1))
        XCTAssertFalse(e.isPeerFixValid(peerFix(lat: 47.0, lon: 8.0), age: 10))
        XCTAssertFalse(e.isPeerFixValid(nil, age: 1), "no fix at all")
        XCTAssertFalse(e.isPeerFixValid(peerFix(lat: 47.0, lon: 8.0), age: nil))
    }

    func testPeerFixGeometryMatchesFlightIngestPredicate() {
        // The two validators must not drift apart: anything the companion path accepts must also
        // survive Flight.validatedForIngest(), or a borrowed fix corrupts the flight file and the
        // record silently fails to sync to the pilot's other devices.
        for (lat, lon) in [(47.0, 8.0), (90.0, 180.0), (-90.0, -180.0),
                           (Double.nan, 8.0), (4.0e9, 8.0), (47.0, 181.0)] {
            let fix = peerFix(lat: lat, lon: lon)
            let flight = Flight(
                gpsTrack: [GPSPoint(latitude: lat, longitude: lon, altitude: 500,
                                    speed: 30, course: 90)]
            )
            XCTAssertEqual(fix.hasValidGeometry, flight.validatedForIngest() != nil,
                           "companion and flight-ingest validators disagree on (\(lat), \(lon))")
        }
    }

    // MARK: - Shared GPS: wire codecs (v4.1)

    func testPeerGPSRoundTrips() throws {
        let gps = CompanionPeerGPS(latitude: 47.0, longitude: 8.0, speedMPS: 30, altitudeMeters: 1000,
                                   courseDegrees: 90, horizontalAccuracy: 5, signalStatus: "good",
                                   timestamp: Date(timeIntervalSince1970: 1000))
        let decoded = try JSONDecoder().decode(CompanionPeerGPS.self, from: JSONEncoder().encode(gps))
        XCTAssertEqual(decoded, gps)
    }

    func testPeerGPSTolerantDecodeDefaults() throws {
        // A skewed/partial payload still decodes (never drops the update); absent accuracy reads invalid.
        let decoded = try JSONDecoder().decode(CompanionPeerGPS.self, from: Data(#"{"latitude":47,"longitude":8}"#.utf8))
        XCTAssertEqual(decoded.horizontalAccuracy, -1, "absent accuracy -> invalid")
        XCTAssertNil(decoded.speedMPS)
    }

    func testFlightDataOwnGPSAvailableDefaultsTrueForLegacyPayload() throws {
        // A pre-shared-GPS master (no ownGPSAvailable field) is assumed to have its own fix.
        let decoded = try JSONDecoder().decode(CompanionFlightData.self, from: Data(#"{"isFlightActive":true}"#.utf8))
        XCTAssertTrue(decoded.ownGPSAvailable)
    }
}
