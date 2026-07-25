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

    // MARK: - PR-17: additive per-registration listing

    func testMetadataDecodesRegistrationsArray() throws {
        let json = """
        {"id":"dr400-140b","aircraftType":"DR400","registration":"HB-KFD","modelName":"Robin DR400",
         "shortModelName":"DR400","aeroclub":"Lausanne Aéroclub","version":"1.0","lastUpdated":"2025",
         "isFree":false,"stallSpeed":50,"pageCount":4,"hasAccess":true,
         "registrations":[
           {"registration":"HB-KFD","modelName":"Robin DR400","shortModelName":"DR400","aeroclub":null,"version":"1.0","lastUpdated":"2025","availableLanguages":["en","fr"]},
           {"registration":"HB-KFI","modelName":"Robin DR400","shortModelName":"DR400","aeroclub":null,"version":"1.0","lastUpdated":"2025","availableLanguages":["en","fr"]}
         ]}
        """
        let m = try JSONDecoder().decode(RemoteAircraftMetadata.self, from: Data(json.utf8))
        XCTAssertEqual(m.registration, "HB-KFD", "Top-level stays the first registration")
        XCTAssertEqual(m.registrations?.map { $0.registration }, ["HB-KFD", "HB-KFI"])
    }

    func testMetadataOmittingRegistrationsStaysBackwardCompatible() throws {
        let json = """
        {"id":"pa28-181","aircraftType":"PA28","registration":"HB-PFA","modelName":"Piper Archer II",
         "shortModelName":"PA-28-181","aeroclub":null,"version":"1.0","lastUpdated":"2025",
         "isFree":false,"stallSpeed":53,"pageCount":4,"hasAccess":false}
        """
        let m = try JSONDecoder().decode(RemoteAircraftMetadata.self, from: Data(json.utf8))
        XCTAssertNil(m.registrations)
    }

    // MARK: - Per-registration expansion (each tail is its own selectable aircraft)

    private func multiRegMetadata() throws -> RemoteAircraftMetadata {
        try JSONDecoder().decode(RemoteAircraftMetadata.self, from: Data(#"""
        {"id":"dr400-140b-gvmn","aircraftType":"DR400","registration":"HB-KFO",
         "modelName":"Robin DR400/140B","shortModelName":"DR400-140B",
         "aeroclub":"Groupe de Vol à Moteur Neuchâtel","version":"9","lastUpdated":"January 2023",
         "isFree":false,"stallSpeed":54,"pageCount":4,"hasAccess":true,
         "registrations":[
           {"registration":"HB-KFO","modelName":"Robin DR400/140B","shortModelName":"DR400-140B","aeroclub":"Groupe de Vol à Moteur Neuchâtel","version":"9","lastUpdated":"January 2023","availableLanguages":["en"]},
           {"registration":"HB-KFP","modelName":"Robin DR400/140B","shortModelName":"DR400-140B","aeroclub":"Groupe de Vol à Moteur Neuchâtel","version":"9","lastUpdated":"January 2023","availableLanguages":["en"]}
         ]}
        """#.utf8))
    }

    func testTokenSplitRoundTrip() {
        let token = AircraftRegistrationToken.make(aircraftId: "dr400-140b-gvmn", registration: "HB-KFP")
        XCTAssertEqual(token, "dr400-140b-gvmn~HB-KFP")
        let (id, reg) = AircraftRegistrationToken.split(token)
        XCTAssertEqual(id, "dr400-140b-gvmn")
        XCTAssertEqual(reg, "HB-KFP")
    }

    func testTokenSplitPassesPlainIdThrough() {
        let (id, reg) = AircraftRegistrationToken.split("pa28-181")
        XCTAssertEqual(id, "pa28-181")
        XCTAssertNil(reg)
    }

    /// '~' survives a widget deep-link URL unencoded — '#' (the previous candidate) would have
    /// been parsed as a fragment and silently truncated the aircraft query parameter.
    func testTokenSurvivesDeepLinkURL() {
        let token = AircraftRegistrationToken.make(aircraftId: "dr400-140b-gvmn", registration: "HB-KFP")
        let url = URL(string: "aerocheck://start-flight?aircraft=\(token)")
        let value = URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "aircraft" })?.value
        XCTAssertEqual(value, token)
    }

    func testExpansionYieldsOneEntryPerTail() throws {
        let expanded = try multiRegMetadata().expandedPerRegistration()

        XCTAssertEqual(expanded.count, 2)
        // First tail keeps the plain server id so existing selections/caches stay valid.
        XCTAssertEqual(expanded[0].id, "dr400-140b-gvmn")
        XCTAssertEqual(expanded[0].registration, "HB-KFO")
        // Additional tails get the composite token and their own metadata.
        XCTAssertEqual(expanded[1].id, "dr400-140b-gvmn~HB-KFP")
        XCTAssertEqual(expanded[1].registration, "HB-KFP")
        XCTAssertEqual(expanded[1].hasAccess, true)
        XCTAssertEqual(expanded[1].isFree, false)
        XCTAssertEqual(expanded[1].availableLanguages, ["en"])
    }

    func testExpansionIsIdempotentAndPassesSingletonsThrough() throws {
        // Single/absent registrations array → unchanged.
        let single = try premiumMetadata()
        XCTAssertEqual(single.expandedPerRegistration(), [single])
        // Expanded entries carry registrations == nil, so re-expanding is a no-op (cached
        // metadata written after expansion must not multiply).
        let expanded = try multiRegMetadata().expandedPerRegistration()
        XCTAssertEqual(expanded.flatMap { $0.expandedPerRegistration() }, expanded)
    }

    /// A tail token flows out of the service as path id + `reg` query, so the server serves that
    /// tail's own file (checklist and version endpoints).
    func testTailTokenBecomesRegQueryParameter() async throws {
        let checklistJSON = #"""
        {"success":true,"data":{"id":"dr400-140b-gvmn","aircraftType":"DR400",
         "registration":"HB-KFP","modelName":"Robin DR400/140B","shortModelName":"DR400-140B",
         "aeroclub":null,"version":"9","lastUpdated":"January 2023","isFree":false,"stallSpeed":54,
         "pageCount":4,"hasParachute":false,"language":"en","requestedLanguage":"en",
         "languageFallback":false,"crosswindLimits":{"takeoff":"22 kt","landing":"22 kt"},
         "speeds":[],"targetSpeeds":{},"learningModeVisibleCount":{},"phases":{}}}
        """#
        let http = FakeHTTPClient(responseData: Data(checklistJSON.utf8))
        let service = AircraftDataService(
            subscriptionManager: FakeGating(), httpClient: http
        )
        service.availableAircraft = try multiRegMetadata().expandedPerRegistration()
        // Unique cache key per test run isn't needed: assert on the outbound URLs, not the cache.
        let token = "dr400-140b-gvmn~HB-KFP"
        service.clearCache(for: token)
        defer { service.clearCache(for: token) }

        let checklist = await service.fetchChecklist(for: token)

        XCTAssertEqual(checklist?.registration, "HB-KFP")
        let urls = http.capturedRequests.compactMap { $0.url?.absoluteString }
        XCTAssertFalse(urls.isEmpty)
        for url in urls {
            XCTAssertTrue(url.contains("/aircraft/dr400-140b-gvmn/"),
                          "Path must use the base id, got \(url)")
            XCTAssertTrue(url.contains("reg=HB-KFP"), "Tail must be requested via reg=, got \(url)")
            XCTAssertFalse(url.contains("~"), "The token separator must never reach the URL: \(url)")
        }
    }

    /// A plain (first-tail or single-reg) id keeps today's URL shape — no reg parameter.
    func testPlainIdOmitsRegQueryParameter() async throws {
        let checklistJSON = #"""
        {"success":true,"data":{"id":"dr400-140b-gvmn","aircraftType":"DR400",
         "registration":"HB-KFO","modelName":"Robin DR400/140B","shortModelName":"DR400-140B",
         "aeroclub":null,"version":"9","lastUpdated":"January 2023","isFree":false,"stallSpeed":54,
         "pageCount":4,"hasParachute":false,"language":"en","requestedLanguage":"en",
         "languageFallback":false,"crosswindLimits":{"takeoff":"22 kt","landing":"22 kt"},
         "speeds":[],"targetSpeeds":{},"learningModeVisibleCount":{},"phases":{}}}
        """#
        let http = FakeHTTPClient(responseData: Data(checklistJSON.utf8))
        let service = AircraftDataService(
            subscriptionManager: FakeGating(), httpClient: http
        )
        service.availableAircraft = try multiRegMetadata().expandedPerRegistration()
        service.clearCache(for: "dr400-140b-gvmn")
        defer { service.clearCache(for: "dr400-140b-gvmn") }

        let checklist = await service.fetchChecklist(for: "dr400-140b-gvmn")

        XCTAssertEqual(checklist?.registration, "HB-KFO")
        let urls = http.capturedRequests.compactMap { $0.url?.absoluteString }
        XCTAssertFalse(urls.isEmpty)
        for url in urls {
            XCTAssertFalse(url.contains("reg="), "Plain id must not send a reg parameter: \(url)")
        }
    }

    // MARK: - Aircraft id validation (SA-23)
    //
    // The id reaches two sinks that both trusted it: a filesystem path component
    // (cacheDirectory.appendingPathComponent("\(id).json")) and a URL path segment. It arrives from
    // the API *and* from a synced CloudKit Settings record, whose clampedForIngest() validated no
    // string at all — so `../../../Documents/leak` resolved outside the cache and inside the
    // UIFileSharingEnabled-exposed Documents folder. `.urlPathAllowed` preserves `/` and `..`, so
    // percent-encoding did not stop it either.

    func testWellFormedIdsAreAccepted() {
        for id in ["wt9-dynamic", "pa28-181", "dr400-140b-gvmn", "dr400-140b-gvmn~HB-KFP",
                   "a", "PS28_Cruiser", "id.with.dots"] {
            XCTAssertTrue(AircraftRegistrationToken.isWellFormed(id), "should accept \(id)")
        }
    }

    func testPathTraversalIsRejected() {
        for id in ["../../../Documents/leak", "..", "../x", "a/b", "a\\b",
                   "wt9/../../etc/passwd", "foo/bar~REG"] {
            XCTAssertFalse(AircraftRegistrationToken.isWellFormed(id), "should reject \(id)")
        }
    }

    func testHiddenFilesAndEmptyPartsAreRejected() {
        for id in ["", ".hidden", "~", "~REG", "wt9~", ".", "a~b~c"] {
            XCTAssertFalse(AircraftRegistrationToken.isWellFormed(id), "should reject \(id)")
        }
    }

    func testCharactersNeedingEncodingAreRejected() {
        for id in ["a b", "a?b", "a#b", "a%2e%2e", "a&b=1", "a\u{0000}b", "é"] {
            XCTAssertFalse(AircraftRegistrationToken.isWellFormed(id), "should reject \(id)")
        }
    }

    func testOverlongIdsAreRejected() {
        XCTAssertTrue(AircraftRegistrationToken.isWellFormed(String(repeating: "a", count: 64)))
        XCTAssertFalse(AircraftRegistrationToken.isWellFormed(String(repeating: "a", count: 65)))
    }

    func testIngestClampNullsOutAnUnsafeAircraftId() {
        var settings = AppSettings()
        settings.selectedRemoteAircraftId = "../../../Documents/leak"
        XCTAssertNil(settings.clampedForIngest().selectedRemoteAircraftId,
                     "a traversal id from a synced record must not be applied")

        settings.selectedRemoteAircraftId = "pa28-181"
        XCTAssertEqual(settings.clampedForIngest().selectedRemoteAircraftId, "pa28-181",
                       "a legitimate id must survive ingest")
    }
}
