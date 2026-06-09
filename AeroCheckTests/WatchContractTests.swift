import XCTest
@testable import AeroCheck

/// Tests the versioned, tolerant Watch connectivity contract — the iPhone and Watch apps update
/// independently, so a payload must survive being decoded by a different app version. (ARCH)
final class WatchContractTests: XCTestCase {

    func testRoundTripPreservesFieldsAndVersion() throws {
        var data = WatchFlightData()
        data.isFlightActive = true
        data.currentPhaseName = "CLIMB"
        data.speedMPS = 42
        data.altitudeFeet = 3500

        let decoded = try JSONDecoder().decode(WatchFlightData.self, from: JSONEncoder().encode(data))

        XCTAssertEqual(decoded.schemaVersion, WatchFlightData.currentSchemaVersion)
        XCTAssertTrue(decoded.isFlightActive)
        XCTAssertEqual(decoded.currentPhaseName, "CLIMB")
        XCTAssertEqual(decoded.speedMPS, 42)
        XCTAssertEqual(decoded.altitudeFeet, 3500)
    }

    func testDecodesPayloadFromAPreVersioningSender() throws {
        // A legacy payload with no schemaVersion and missing newer fields must still decode.
        let legacy = Data(#"{"isFlightActive":true,"currentPhaseName":"TAXI"}"#.utf8)
        let decoded = try JSONDecoder().decode(WatchFlightData.self, from: legacy)
        XCTAssertEqual(decoded.schemaVersion, 0, "Absent version marks a pre-versioning sender")
        XCTAssertTrue(decoded.isFlightActive)
        XCTAssertEqual(decoded.currentPhaseName, "TAXI")
        XCTAssertFalse(decoded.hasActiveNavPlan, "A missing field falls back to its default")
        XCTAssertNil(decoded.speedMPS)
    }

    func testIgnoresUnknownFieldsFromANewerSender() throws {
        // A newer sender bumps the version and adds a field this build doesn't know — decode must
        // not throw and must surface the version so the receiver can adapt.
        let newer = Data(#"{"schemaVersion":99,"isCircuitMode":true,"someFutureField":123}"#.utf8)
        let decoded = try JSONDecoder().decode(WatchFlightData.self, from: newer)
        XCTAssertEqual(decoded.schemaVersion, 99)
        XCTAssertTrue(decoded.isCircuitMode)
        XCTAssertFalse(decoded.isFlightActive, "Unspecified fields keep their defaults")
    }
}

/// Tests the versioned, tolerant Companion (iPad master ↔ iPhone viewer) connectivity contract. (ARCH)
final class CompanionContractTests: XCTestCase {

    func testMessageRoundTripsWithVersion() throws {
        let inner = Data(#"{"x":1}"#.utf8)
        let msg = CompanionMessage(type: .flightData, payload: inner)
        let decoded = try JSONDecoder().decode(CompanionMessage.self, from: JSONEncoder().encode(msg))
        XCTAssertEqual(decoded.schemaVersion, CompanionMessage.currentSchemaVersion)
        XCTAssertEqual(decoded.type, .flightData)
        XCTAssertEqual(decoded.payload, inner)
    }

    func testMessageDecodesPreVersioningEnvelope() throws {
        // No schemaVersion, no timestamp — still routes because type/payload are present.
        let legacy = Data(#"{"type":"command","payload":""}"#.utf8)
        let decoded = try JSONDecoder().decode(CompanionMessage.self, from: legacy)
        XCTAssertEqual(decoded.schemaVersion, 0)
        XCTAssertEqual(decoded.type, .command)
        XCTAssertEqual(decoded.timestamp, .distantPast)
    }

    func testFlightDataDecodesFromAPartialPayload() throws {
        // A skewed sender omits several fields — decode must not throw; defaults fill in.
        let partial = Data(#"{"isFlightActive":true,"currentPhase":"CRUISE","speedMPS":50}"#.utf8)
        let decoded = try JSONDecoder().decode(CompanionFlightData.self, from: partial)
        XCTAssertTrue(decoded.isFlightActive)
        XCTAssertEqual(decoded.currentPhase, "CRUISE")
        XCTAssertEqual(decoded.speedMPS, 50)
        XCTAssertEqual(decoded.gpsSignalStatus, "unknown", "A missing field falls back to its default")
        XCTAssertEqual(decoded.timestamp, .distantPast, "A missing timestamp reads as stale, not fresh")
    }
}
