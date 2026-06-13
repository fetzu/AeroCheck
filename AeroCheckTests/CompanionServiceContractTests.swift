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
        // single declared service must advertise both roles.
        XCTAssertEqual(entry["Publishable"] as? Bool, true, "companion service must be Publishable (iPad master)")
        XCTAssertEqual(entry["Subscribable"] as? Bool, true, "companion service must be Subscribable (iPhone viewer)")
    }

    func testNoStaleTcpServiceNameRemains() {
        let services = Bundle.main.object(forInfoDictionaryKey: "WiFiAwareServices") as? [String: Any] ?? [:]
        XCTAssertNil(
            services["_aerocheck._tcp"],
            "A ._tcp service name must never reappear in WiFiAwareServices — it traps the WiFiAware parser on flight start")
    }
}
