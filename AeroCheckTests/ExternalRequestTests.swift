import XCTest
@testable import AeroCheck

/// Unit tests for the retry/backoff policy used on third-party geo/weather endpoints. The pure
/// decision functions are injected with a deterministic `jitter` so the policy is testable without
/// any network. (SEC-15 / PERF-23)
final class ExternalRequestTests: XCTestCase {

    func testShouldRetryOnThrottlingAnd5xxWithinBudget() {
        XCTAssertTrue(ExternalRequest.shouldRetry(status: 429, attempt: 0, maxRetries: 3))
        XCTAssertTrue(ExternalRequest.shouldRetry(status: 500, attempt: 1, maxRetries: 3))
        XCTAssertTrue(ExternalRequest.shouldRetry(status: 503, attempt: 2, maxRetries: 3))
    }

    func testShouldNotRetryOnSuccessOrClientError() {
        XCTAssertFalse(ExternalRequest.shouldRetry(status: 200, attempt: 0, maxRetries: 3))
        XCTAssertFalse(ExternalRequest.shouldRetry(status: 404, attempt: 0, maxRetries: 3))
        XCTAssertFalse(ExternalRequest.shouldRetry(status: 403, attempt: 0, maxRetries: 3))
    }

    func testShouldNotRetryOnceBudgetExhausted() {
        XCTAssertFalse(ExternalRequest.shouldRetry(status: 429, attempt: 3, maxRetries: 3))
        XCTAssertFalse(ExternalRequest.shouldRetry(status: 503, attempt: 5, maxRetries: 3))
    }

    func testParseRetryAfterSeconds() {
        XCTAssertEqual(ExternalRequest.parseRetryAfter("5"), 5)
        XCTAssertEqual(ExternalRequest.parseRetryAfter("  12 "), 12)
        XCTAssertEqual(ExternalRequest.parseRetryAfter("0"), 0)
    }

    func testParseRetryAfterRejectsNonNumericAndNegative() {
        XCTAssertNil(ExternalRequest.parseRetryAfter(nil))
        XCTAssertNil(ExternalRequest.parseRetryAfter(""))
        XCTAssertNil(ExternalRequest.parseRetryAfter("Wed, 21 Oct 2099 07:28:00 GMT")) // http-date unsupported
        XCTAssertNil(ExternalRequest.parseRetryAfter("-3"))
    }

    func testBackoffHonorsRetryAfterCappedAt30() {
        XCTAssertEqual(ExternalRequest.backoffSeconds(attempt: 0, retryAfter: 5, jitter: 0.5), 5, accuracy: 0.0001)
        XCTAssertEqual(ExternalRequest.backoffSeconds(attempt: 9, retryAfter: 120, jitter: 1), 30, accuracy: 0.0001)
    }

    func testBackoffIsExponentialWithFullJitter() {
        // base = 0.5 * 2^attempt, capped at 8, scaled by jitter (0...1).
        XCTAssertEqual(ExternalRequest.backoffSeconds(attempt: 0, retryAfter: nil, jitter: 1.0), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ExternalRequest.backoffSeconds(attempt: 0, retryAfter: nil, jitter: 0.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(ExternalRequest.backoffSeconds(attempt: 2, retryAfter: nil, jitter: 1.0), 2.0, accuracy: 0.0001)
        XCTAssertEqual(ExternalRequest.backoffSeconds(attempt: 3, retryAfter: nil, jitter: 1.0), 4.0, accuracy: 0.0001)
        // Capped at 8s no matter how high the attempt.
        XCTAssertEqual(ExternalRequest.backoffSeconds(attempt: 10, retryAfter: nil, jitter: 1.0), 8.0, accuracy: 0.0001)
    }

    func testUserAgentIdentifiesTheApp() {
        XCTAssertTrue(ExternalRequest.userAgent.hasPrefix("AeroCheck/"))
        XCTAssertTrue(ExternalRequest.userAgent.contains("aerocheck.app"))
    }

    // MARK: - Size ceiling (SA-32 / SEC-C32)

    func testOnlyADeclaredLengthOverTheLimitIsTooLarge() {
        XCTAssertTrue(ExternalRequest.declaresTooLarge(1_001, limit: 1_000))
        XCTAssertFalse(ExternalRequest.declaresTooLarge(1_000, limit: 1_000), "exactly the limit is allowed")
        XCTAssertFalse(ExternalRequest.declaresTooLarge(0, limit: 1_000))
        XCTAssertFalse(ExternalRequest.declaresTooLarge(NSURLSessionTransferSizeUnknown, limit: 1_000),
                       "an unknown length is left to the streaming count")
    }

    /// The early-out never ran for a streamed request: it lived in a delegate callback that
    /// `bytes(for:delegate:)` does not deliver. The stub sends the headers and a first chunk under
    /// the limit (URLSession hands over no response before 512 bytes of body), then holds the rest:
    /// only the declared length can end this request, and the count never came into it.
    func testADeclaredLengthOverTheLimitIsRefusedBeforeTheBody() async {
        ExternalRequestStub.reply(.init(declaredLength: 10_000, body: Data(count: 512), holdAfterBody: true),
                                  at: "/declared-huge")
        await assertTooLarge(declared: 10_000, limit: 1_000) {
            _ = try await ExternalRequest.data(for: URLRequest(url: self.stubURL("/declared-huge")),
                                               session: self.session, maxRetries: 0, maxResponseBytes: 1_000)
        }
    }

    /// The other entry point, `data(from:)`, the one the tiles use: same refusal.
    func testADeclaredLengthOverTheLimitIsRefusedBeforeTheBodyFromAURL() async {
        ExternalRequestStub.reply(.init(declaredLength: 10_000, body: Data(count: 512), holdAfterBody: true),
                                  at: "/declared-huge")
        await assertTooLarge(declared: 10_000, limit: 1_000) {
            _ = try await ExternalRequest.data(from: self.stubURL("/declared-huge"), session: self.session,
                                               maxRetries: 0, maxResponseBytes: 1_000)
        }
    }

    /// The declared length is believed when it is over the limit, whatever the body turns out to be:
    /// this one would have passed the count (10 bytes) and did before the fix.
    func testADeclaredLengthOverTheLimitIsRefusedEvenForASmallBody() async {
        ExternalRequestStub.reply(.init(declaredLength: 5_000, body: Data(count: 10)), at: "/declared-big")
        await assertTooLarge(declared: 5_000, limit: 1_000) {
            _ = try await ExternalRequest.data(from: self.stubURL("/declared-big"), session: self.session,
                                               maxRetries: 0, maxResponseBytes: 1_000)
        }
    }

    func testABodyWithNoContentLengthIsStillCappedByTheCount() async {
        ExternalRequestStub.reply(.init(declaredLength: nil, body: Data(count: 5_000)), at: "/undeclared")
        await assertTooLarge(declared: nil, limit: 1_000) {
            _ = try await ExternalRequest.data(from: self.stubURL("/undeclared"), session: self.session,
                                               maxRetries: 0, maxResponseBytes: 1_000)
        }
    }

    func testABodyLongerThanItsDeclaredLengthIsStillCappedByTheCount() async {
        ExternalRequestStub.reply(.init(declaredLength: 100, body: Data(count: 5_000)), at: "/lying-small")
        do {
            _ = try await ExternalRequest.data(from: stubURL("/lying-small"), session: session,
                                               maxRetries: 0, maxResponseBytes: 1_000)
            XCTFail("a body past the limit must be refused, whatever its Content-Length said")
        } catch ExternalRequest.SizeError.tooLarge(_, let limit) {
            XCTAssertEqual(limit, 1_000)
        } catch {
            XCTFail("refused on size, got \(error)")
        }
    }

    func testABodyAtTheLimitPasses() async throws {
        let body = Data((0..<1_000).map { UInt8($0 % 251) })
        ExternalRequestStub.reply(.init(declaredLength: body.count, body: body), at: "/at-limit")

        let (data, response) = try await ExternalRequest.data(from: stubURL("/at-limit"), session: session,
                                                              maxRetries: 0, maxResponseBytes: 1_000)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, body)
    }

    // MARK: - Helpers

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        ExternalRequestStub.reset()
        session = ExternalRequestStub.makeSession()
    }

    override func tearDown() {
        session.invalidateAndCancel()
        super.tearDown()
    }

    private func stubURL(_ path: String) -> URL {
        URL(string: "https://stub.example\(path)")!
    }

    private func assertTooLarge(declared: Int64?, limit: Int, file: StaticString = #filePath, line: UInt = #line,
                                _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("the response must be refused on size", file: file, line: line)
        } catch ExternalRequest.SizeError.tooLarge(let gotDeclared, let gotLimit) {
            XCTAssertEqual(gotDeclared, declared, file: file, line: line)
            XCTAssertEqual(gotLimit, limit, file: file, line: line)
        } catch {
            XCTFail("refused on size, got \(error)", file: file, line: line)
        }
    }
}

/// Answers by URL path instead of the network, and remembers every host it was asked for.
final class ExternalRequestStub: URLProtocol {
    struct Reply {
        var status = 200
        /// The Content-Length header; nil sends none.
        var declaredLength: Int?
        var body = Data()
        /// Send the headers and `body`, then nothing more: the request only ends when the client
        /// cancels it (or times out).
        var holdAfterBody = false
        var redirectTo: URL?
    }

    private static let lock = NSLock()
    private static var replies: [String: Reply] = [:]
    private static var hosts: [String] = []

    static func reset() { lock.withLock { replies = [:]; hosts = [] } }
    static func reply(_ reply: Reply, at path: String) { lock.withLock { replies[path] = reply } }
    static var requestedHosts: [String] { lock.withLock { hosts } }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExternalRequestStub.self]
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let reply = Self.lock.withLock { () -> Reply in
            Self.hosts.append(url.host ?? "")
            return Self.replies[url.path] ?? Reply(status: 404)
        }

        if let target = reply.redirectTo {
            let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        var headers: [String: String] = [:]
        if let declared = reply.declaredLength { headers["Content-Length"] = "\(declared)" }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        // In chunks, as a network delivers it.
        var offset = 0
        while offset < reply.body.count {
            let end = min(offset + 16_384, reply.body.count)
            client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<end))
            offset = end
        }
        if reply.holdAfterBody { return }
        client?.urlProtocolDidFinishLoading(self)
    }
}
