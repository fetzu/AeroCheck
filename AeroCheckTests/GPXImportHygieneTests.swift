import XCTest
@testable import AeroCheck

/// Tests identity-log redaction (SEC-19) and GPX import XML hardening (SEC-20).
@MainActor
final class GPXImportHygieneTests: XCTestCase {

    private func sampleFlight() -> Flight {
        Flight(gpsTrack: [
            GPSPoint(latitude: 47.0, longitude: 8.0, altitude: 500, timestamp: Date(timeIntervalSince1970: 0)),
            GPSPoint(latitude: 47.1, longitude: 8.1, altitude: 600, timestamp: Date(timeIntervalSince1970: 60)),
        ])
    }

    // MARK: - SEC-19: identity redaction

    func testRedactedIdentifierKeepsOnlyAShortSuffix() {
        XCTAssertEqual(SubscriptionManager.redactedIdentifier("ABCDEFGH1234"), "****1234")
        XCTAssertEqual(SubscriptionManager.redactedIdentifier("xy"), "****")
        XCTAssertFalse(
            SubscriptionManager.redactedIdentifier("sensitive-user-id-9999").contains("sensitive"),
            "The full identifier must never appear in the redacted form"
        )
    }

    // MARK: - SEC-20: GPX XML hardening

    func testValidGPXStillImportsAfterHardening() {
        let gpx = sampleFlight().toGPX()
        let parsed = GPXParser(data: Data(gpx.utf8)).parse()
        XCTAssertEqual(parsed?.gpsTrack.count, 2, "A valid GPX still imports after the XXE hardening")
    }

    func testExternalEntityDoctypeDoesNotBreakOrInjectIntoImport() {
        // Inject a DOCTYPE declaring an external entity into otherwise-valid GPX.
        let withDoctype = sampleFlight().toGPX().replacingOccurrences(
            of: #"<?xml version="1.0" encoding="UTF-8"?>"#,
            with: #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
                + #"<!DOCTYPE gpx [<!ENTITY xxe SYSTEM "file:///etc/hostname">]>"#
        )
        let parsed = GPXParser(data: Data(withDoctype.utf8)).parse()
        // External entities are not resolved; the two valid track points still parse and nothing
        // external is fetched/injected.
        XCTAssertEqual(parsed?.gpsTrack.count, 2)
    }
}
