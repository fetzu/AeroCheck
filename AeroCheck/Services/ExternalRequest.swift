import Foundation

/// Shared networking for the third-party geo/weather endpoints (swisstopo / geo.admin, MeteoSwiss,
/// Open-Meteo). Provides a descriptive `User-Agent`, an explicit short request timeout, and
/// retry/backoff with jitter that honors `Retry-After` on 429/5xx — so operators can identify the
/// app, a stuck request can't hang for the default 60 s, and transient throttling is retried rather
/// than silently surfaced as a hard failure. Task cancellation is propagated. (SEC-15 / PERF-23)
enum ExternalRequest {

    /// Default retry budget for a single logical request.
    static let maxRetries = 3

    /// Descriptive User-Agent so swisstopo/MeteoSwiss/Open-Meteo operators can identify/whitelist us.
    static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "AeroCheck/\(version) (+https://aerocheck.app)"
    }()

    /// Shared session: descriptive User-Agent + a 15 s request deadline (vs the 60 s default).
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    /// Builds a session configuration carrying the User-Agent, for callers that need their own
    /// session tuning (e.g. the bulk tile downloader's per-host connection cap).
    static func configuredSession(_ configure: (URLSessionConfiguration) -> Void) -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        configure(config)
        return URLSession(configuration: config)
    }

    // MARK: - Pure policy (unit-tested)

    /// Whether an HTTP status warrants a retry (transient throttling/server error) within budget.
    static func shouldRetry(status: Int, attempt: Int, maxRetries: Int = maxRetries) -> Bool {
        guard attempt < maxRetries else { return false }
        return status == 429 || (500...599).contains(status)
    }

    /// Parses a `Retry-After` header value expressed in seconds. The HTTP-date form is unsupported
    /// (returns nil → fall back to exponential backoff).
    static func parseRetryAfter(_ value: String?) -> Double? {
        guard let value, let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 else {
            return nil
        }
        return seconds
    }

    /// Backoff seconds: honor `Retry-After` (capped) when present, else exponential (base 0.5 s,
    /// doubling, capped at 8 s) scaled by `jitter` (0...1, "full jitter"). `jitter` is injected so
    /// the policy is deterministic under test; production passes `Double.random(in: 0...1)`.
    static func backoffSeconds(attempt: Int, retryAfter: Double?, jitter: Double) -> Double {
        if let retryAfter, retryAfter > 0 {
            return min(retryAfter, 30)
        }
        let base = min(0.5 * pow(2.0, Double(attempt)), 8.0)
        return base * jitter
    }

    // MARK: - Requests

    /// GET a URL with retry/backoff. Returns the final `(data, response)` (success or the last
    /// non-retryable response). Throws `CancellationError` if the surrounding Task is cancelled,
    /// or a `URLError` if the request keeps failing transiently past the retry budget.
    static func data(from url: URL, session: URLSession = session, maxRetries: Int = maxRetries) async throws -> (Data, HTTPURLResponse) {
        try await data(for: URLRequest(url: url), session: session, maxRetries: maxRetries)
    }

    /// Perform a request with retry/backoff on 429/5xx and transient `URLError`s.
    static func data(for request: URLRequest, session: URLSession = session, maxRetries: Int = maxRetries) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                if shouldRetry(status: http.statusCode, attempt: attempt, maxRetries: maxRetries) {
                    let retryAfter = parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
                    try await sleep(backoffSeconds(attempt: attempt, retryAfter: retryAfter, jitter: Double.random(in: 0...1)))
                    attempt += 1
                    continue
                }
                return (data, http)
            } catch let error as URLError {
                guard attempt < maxRetries, isTransient(error) else { throw error }
                try await sleep(backoffSeconds(attempt: attempt, retryAfter: nil, jitter: Double.random(in: 0...1)))
                attempt += 1
            }
        }
    }

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .dnsLookupFailed, .notConnectedToInternet, .cannotFindHost:
            return true
        default:
            return false
        }
    }

    private static func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
