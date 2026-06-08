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
}
