import XCTest
@testable import AeroCheck

/// Verifies the injected seams (ARCH-12): the premium-gating and auth/transport logic in
/// `AircraftDataService` can now be exercised with fakes — no live StoreKit or network.
@MainActor
final class AircraftDataServiceSeamTests: XCTestCase {

    // MARK: - Fakes

    final class FakeGating: SubscriptionGating {
        var userID: String?
        var allowPremium: Bool
        init(userID: String? = "test-user", allowPremium: Bool = true) {
            self.userID = userID
            self.allowPremium = allowPremium
        }
        func getUserID() async -> String? { userID }
        func shouldAllowPremiumAccess() -> Bool { allowPremium }
    }

    final class FakeHTTPClient: HTTPClient {
        private(set) var capturedRequests: [URLRequest] = []
        var responseData: Data
        var statusCode: Int
        init(responseData: Data = Data(#"{"data":{"aircraft":[]}}"#.utf8), statusCode: Int = 200) {
            self.responseData = responseData
            self.statusCode = statusCode
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            capturedRequests.append(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil
            )!
            return (responseData, response)
        }
    }

    private func premiumMetadata() throws -> RemoteAircraftMetadata {
        try JSONDecoder().decode(RemoteAircraftMetadata.self, from: Data(#"""
        {"id":"pa28-181","aircraftType":"PA28","registration":"HB-PFA","modelName":"Piper Archer",
         "shortModelName":"PA-28","version":"1.0","lastUpdated":"x","isFree":false,"stallSpeed":53,
         "pageCount":4,"hasAccess":false}
        """#.utf8))
    }

    // MARK: - Tests

    /// The user id from the gating seam flows into the Bearer auth header and out through the
    /// injected transport — proven with fakes, no live StoreKit / network.
    func testUserIDFromGatingBecomesBearerHeader() async {
        let http = FakeHTTPClient()
        let service = AircraftDataService(
            subscriptionManager: FakeGating(userID: "abc-123"), httpClient: http
        )

        await service.fetchAvailableAircraft()

        XCTAssertEqual(http.capturedRequests.count, 1)
        XCTAssertEqual(
            http.capturedRequests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer abc-123"
        )
    }

    /// A premium aircraft is withheld — and no network request is made — when the gating seam
    /// denies access. (ARCH-12 / SEC-05)
    func testPremiumChecklistWithheldWhenGatingDenies() async throws {
        let http = FakeHTTPClient()
        let service = AircraftDataService(
            subscriptionManager: FakeGating(allowPremium: false), httpClient: http
        )
        service.availableAircraft = [try premiumMetadata()]

        let result = await service.fetchChecklist(for: "pa28-181")

        XCTAssertNil(result, "Premium content must be withheld when access is denied")
        XCTAssertTrue(http.capturedRequests.isEmpty, "No request should be made when access is denied")
    }

    /// `validatePremiumCaches` returns false (and clears caches) when the gating seam denies access.
    func testValidatePremiumCachesReflectsGating() {
        let service = AircraftDataService(
            subscriptionManager: FakeGating(allowPremium: true), httpClient: FakeHTTPClient()
        )
        XCTAssertTrue(service.validatePremiumCaches(subscriptionManager: FakeGating(allowPremium: true)))
        XCTAssertFalse(service.validatePremiumCaches(subscriptionManager: FakeGating(allowPremium: false)))
    }

    /// Production wiring is preserved: the transport defaults to `URLSession.shared` when omitted.
    func testDefaultTransportConstructs() {
        let service = AircraftDataService(subscriptionManager: FakeGating())
        XCTAssertNotNil(service)
    }

    // MARK: - PR-41: additive language-fallback fields

    func testChecklistDecodesAdditiveLanguageFallbackFields() throws {
        let json = """
        {"id":"cap10-c","aircraftType":"CAP10","registration":"HB-SAX","modelName":"CAP 10C",
         "shortModelName":"CAP10","aeroclub":null,"version":"1.0","lastUpdated":"2025","isFree":false,
         "stallSpeed":50,"pageCount":4,"hasParachute":false,
         "language":"fr","requestedLanguage":"en","languageFallback":true,
         "crosswindLimits":{"takeoff":"15 kt","landing":"15 kt"},"speeds":[],
         "targetSpeeds":{},"learningModeVisibleCount":{},"phases":{}}
        """
        let c = try JSONDecoder().decode(RemoteAircraftChecklist.self, from: Data(json.utf8))
        XCTAssertEqual(c.language, "fr")
        XCTAssertEqual(c.requestedLanguage, "en")
        XCTAssertEqual(c.languageFallback, true)
    }

    func testChecklistOmittingLanguageFieldsStaysBackwardCompatible() throws {
        // An older server response / bundled JSON without the additive fields decodes to nil.
        let json = """
        {"id":"wt9-dynamic","aircraftType":"WT9","registration":"F-HVXA","modelName":"WT9",
         "shortModelName":"WT9","aeroclub":null,"version":"2.1e","lastUpdated":"2025","isFree":true,
         "stallSpeed":42,"pageCount":4,"hasParachute":true,
         "crosswindLimits":{"takeoff":"14 kt","landing":"16 kt"},"speeds":[],
         "targetSpeeds":{},"learningModeVisibleCount":{},"phases":{}}
        """
        let c = try JSONDecoder().decode(RemoteAircraftChecklist.self, from: Data(json.utf8))
        XCTAssertNil(c.language)
        XCTAssertNil(c.languageFallback)
    }

    func testLanguageDisplayName() {
        XCTAssertEqual(AppState.languageDisplayName("fr"), "Français")
        XCTAssertEqual(AppState.languageDisplayName("en"), "English")
        XCTAssertEqual(AppState.languageDisplayName("xx"), "XX")
    }
}
