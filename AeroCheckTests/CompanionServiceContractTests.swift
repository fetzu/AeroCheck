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
