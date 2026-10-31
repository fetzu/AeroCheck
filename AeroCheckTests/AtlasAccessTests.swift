import CryptoKit
import XCTest
@testable import AeroCheck

/// The Atlas gate, the app's side (6.8.0): a key attested once, the day value fetched once a day and sent on every
/// archive read, a fresh one after a 403, download links and the month's ceiling, the developer token where App
/// Attest isn't available, and the old way while the server has no gate.
final class AtlasAccessTests: XCTestCase {

    /// App Attest as the device has it: a key, and signatures recorded with what they signed.
    private final class FakeAttest: AtlasAttesting, @unchecked Sendable {
        let isSupported: Bool
        private let lock = NSLock()
        private(set) var keysMade = 0
        private(set) var signedHashes: [Data] = []
        var assertionError: Error?
        init(supported: Bool = true) { isSupported = supported }
        func generateKey() async throws -> String {
            lock.withLock { keysMade += 1; return "key-\(keysMade)" }
        }
        func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("att-\(keyId)".utf8) }
        func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
            if let error = lock.withLock({ assertionError }) {
                lock.withLock { assertionError = nil }
                throw error
            }
            lock.withLock { signedHashes.append(clientDataHash) }
            return Data("assert-\(keyId)".utf8)
        }
    }

    /// The API: answers by path, records each request.
    private final class FakeAPI: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        var answers: [String: [(Int, String)]] = [:]
        func paths() -> [String] { lock.withLock { requests.map { $0.url!.lastPathComponent } } }
        func body(_ index: Int) -> [String: Any] {
            lock.withLock { (try? JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data())) as? [String: Any] ?? [:] }
        }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url!.lastPathComponent
            let (status, body): (Int, String) = lock.withLock {
                requests.append(request)
                if var queue = answers[path], !queue.isEmpty {
                    let first = queue.removeFirst()
                    answers[path] = queue.isEmpty ? [first] : queue
                    return first
                }
                return (404, "{}")
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private let today = Date(timeIntervalSince1970: 1_793_448_000) // 31 Oct 2026, 12:00 UTC

    private func access(_ attest: FakeAttest = FakeAttest(), _ api: FakeAPI, devToken: String? = nil,
                        session: String? = nil, defaults: UserDefaults? = nil) -> AtlasAccess {
        let now = today
        return AtlasAccess(attesting: attest, send: { try await api.send($0) }, defaults: defaults ?? makeTestDefaults(),
                           baseURL: "https://api.test", devToken: devToken, sessionToken: { session }, now: { now })
    }

    private func standardAnswers(_ api: FakeAPI) {
        api.answers = [
            "challenge": [(200, #"{"success":true,"data":{"challenge":"c-1"}}"#)],
            "attest": [(200, #"{"success":true}"#)],
            "access": [(200, #"{"success":true,"data":{"values":[{"day":"2026-10-31","value":"today-value"},{"day":"2026-11-01","value":"tomorrow-value"}]}}"#)],
        ]
    }

    // MARK: Day values

    func testAKeyIsAttestedOnceAndTodaysValueKept() async {
        let attest = FakeAttest()
        let api = FakeAPI()
        standardAnswers(api)
        let defaults = makeTestDefaults()
        let gate = access(attest, api, defaults: defaults)
        let first = await gate.dayValue()
        XCTAssertEqual(first, "today-value")
        XCTAssertEqual(api.paths(), ["challenge", "attest", "access"])
        XCTAssertEqual(api.body(1)["challenge"] as? String, "c-1")
        XCTAssertEqual(defaults.string(forKey: AtlasAccess.keyIdKey), "key-1")
        let again = await gate.dayValue()
        XCTAssertEqual(again, "today-value")
        XCTAssertEqual(api.paths().count, 3, "kept for the day: no second request")
        XCTAssertEqual(attest.keysMade, 1)
    }

    func testTheSignedBytesAreTheBytesSent() async throws {
        let attest = FakeAttest()
        let api = FakeAPI()
        standardAnswers(api)
        _ = await access(attest, api).dayValue()
        let sent = try XCTUnwrap(Data(base64Encoded: api.body(2)["clientData"] as? String ?? ""))
        XCTAssertEqual(attest.signedHashes.first, Data(SHA256.hash(data: sent)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        XCTAssertEqual(json["purpose"] as? String, "access")
        XCTAssertEqual(json["ts"] as? Int64, AtlasAccess.milliseconds(today))
        XCTAssertEqual(api.body(2)["keyId"] as? String, "key-1")
    }

    func testAKeyTheServerForgotIsReplacedOnce() async {
        let attest = FakeAttest()
        let api = FakeAPI()
        standardAnswers(api)
        api.answers["access"] = [(401, #"{"code":"ATLAS_KEY_UNKNOWN"}"#),
                                 (200, #"{"success":true,"data":{"values":[{"day":"2026-10-31","value":"v"}]}}"#)]
        let defaults = makeTestDefaults()
        defaults.set("old-key", forKey: AtlasAccess.keyIdKey)
        let value = await access(attest, api, defaults: defaults).dayValue()
        XCTAssertEqual(value, "v")
        XCTAssertEqual(api.paths(), ["access", "challenge", "attest", "access"])
        XCTAssertEqual(defaults.string(forKey: AtlasAccess.keyIdKey), "key-1")
    }

    func testWithoutTheGateReadsGoOnWithoutAValueAndDontAskEachTime() async {
        let api = FakeAPI()
        api.answers = ["challenge": [(503, #"{"code":"ATLAS_UNAVAILABLE"}"#)]]
        let gate = access(FakeAttest(), api)
        let first = await gate.dayValue()
        let second = await gate.dayValue()
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(api.paths(), ["challenge"], "one try a minute")
    }

    func testARefreshAfterA403IsPaced() async {
        let api = FakeAPI()
        standardAnswers(api)
        let gate = access(FakeAttest(), api)
        _ = await gate.dayValue()
        let fresh = await gate.refreshDayValue()
        XCTAssertEqual(fresh, "today-value")
        let paced = await gate.refreshDayValue()
        XCTAssertNil(paced, "a second refresh within five minutes asks nothing")
        XCTAssertEqual(api.paths().filter { $0 == "access" }.count, 2)
    }

    func testTheDeveloperTokenStandsInWhereAppAttestIsMissing() async {
        let api = FakeAPI()
        standardAnswers(api)
        let value = await access(FakeAttest(supported: false), api, devToken: "dev-token-0123456789").dayValue()
        XCTAssertEqual(value, "today-value")
        XCTAssertEqual(api.paths(), ["access"])
        XCTAssertEqual(api.requests.first?.value(forHTTPHeaderField: "X-AeroCheck-Atlas-Dev"), "dev-token-0123456789")
        let none = await access(FakeAttest(supported: false), FakeAPI()).dayValue()
        XCTAssertNil(none, "no App Attest and no token: no value, and no request")
    }

    // MARK: Download links

    func testLinksCarryTheFilesSignedAndTheSessionToken() async throws {
        let api = FakeAPI()
        standardAnswers(api)
        api.answers["links"] = [(200, #"{"success":true,"data":{"links":[{"file":"ch/map-0123456789abcdef.pmtiles","url":"https://r2.test/a"}],"used":1,"limit":120}}"#)]
        let result = await access(FakeAttest(), api, session: "session-1").links(["ch/map-0123456789abcdef.pmtiles"])
        XCTAssertEqual(result, .links(["ch/map-0123456789abcdef.pmtiles": URL(string: "https://r2.test/a")!]))
        let request = try XCTUnwrap(api.requests.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-1")
        let sent = try XCTUnwrap(Data(base64Encoded: api.body(api.requests.count - 1)["clientData"] as? String ?? ""))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        XCTAssertEqual(json["files"] as? [String], ["ch/map-0123456789abcdef.pmtiles"])
        XCTAssertEqual(json["purpose"] as? String, "links")
    }

    func testTheCeilingAndAMissingGate() async {
        let api = FakeAPI()
        standardAnswers(api)
        api.answers["links"] = [(429, #"{"code":"ATLAS_CEILING","used":39,"limit":40,"resetsAt":"2026-11-01T00:00:00.000Z"}"#)]
        let ceiling = await access(FakeAttest(), api).links(["ch/map-0123456789abcdef.pmtiles"])
        XCTAssertEqual(ceiling, .ceiling(limit: 40, resetsAt: Date(timeIntervalSince1970: 1_793_491_200)))
        let missing = FakeAPI()
        standardAnswers(missing)
        missing.answers["links"] = [(404, "Not Found")]
        let unavailable = await access(FakeAttest(), missing).links(["ch/map-0123456789abcdef.pmtiles"])
        XCTAssertEqual(unavailable, .unavailable)
    }

    // MARK: Archive reads

    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        var values: [String?] = []
        var statuses: [Int] = []
        func add(_ value: String?) { lock.withLock { values.append(value) } }
        func next() -> Int { lock.withLock { statuses.isEmpty ? 206 : statuses.removeFirst() } }
    }

    private func read(_ url: String, value: String?, refresh: String?, sent: Sent) async throws -> Int {
        let request = URLRequest(url: URL(string: url)!)
        let (_, response) = try await PilotMapConfig.fetch(request, dayValue: { value }, refresh: { refresh }, send: { request in
            sent.add(request.value(forHTTPHeaderField: AtlasAccess.dayHeader))
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: sent.next(), httpVersion: nil, headerFields: nil)!)
        })
        return response.statusCode
    }

    func testAnArchiveReadCarriesTheDayValueAndRetriesOnceAfterA403() async throws {
        let sent = Sent()
        let status = try await read("https://tiles.aerocheck.app/v1/ch/map-0123456789abcdef.pmtiles", value: "old",
                                    refresh: "new", sent: sent)
        XCTAssertEqual(status, 206)
        XCTAssertEqual(sent.values, ["old"])

        let refused = Sent()
        refused.statuses = [403, 206]
        let retried = try await read("https://tiles.aerocheck.app/v1/ch/map-0123456789abcdef.pmtiles", value: "old",
                                     refresh: "new", sent: refused)
        XCTAssertEqual(retried, 206)
        XCTAssertEqual(refused.values, ["old", "new"])

        let noFresh = Sent()
        noFresh.statuses = [403]
        let gaveUp = try await read("https://tiles.aerocheck.app/v1/ch/map-0123456789abcdef.pmtiles", value: "old",
                                    refresh: nil, sent: noFresh)
        XCTAssertEqual(gaveUp, 403)
        XCTAssertEqual(noFresh.values, ["old"])
    }

    func testListsGoWithoutTheDayValue() async throws {
        let sent = Sent()
        _ = try await read("https://tiles.aerocheck.app/v1/index.json?h=1", value: "today", refresh: nil, sent: sent)
        XCTAssertEqual(sent.values, [nil])
    }

    func testUTCDays() {
        XCTAssertEqual(AtlasAccess.utcDay(today), "2026-10-31")
        XCTAssertEqual(AtlasAccess.utcDay(Date(timeIntervalSince1970: 1_793_491_199)), "2026-10-31")
        XCTAssertEqual(AtlasAccess.utcDay(Date(timeIntervalSince1970: 1_793_491_200)), "2026-11-01")
    }
}
