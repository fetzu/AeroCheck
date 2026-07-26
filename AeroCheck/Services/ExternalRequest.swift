import Foundation

/// Shared networking for the third-party geo/weather endpoints (swisstopo / geo.admin, MeteoSwiss,
/// Open-Meteo). Provides a descriptive `User-Agent`, an explicit short request timeout, and
/// retry/backoff with jitter that honors `Retry-After` on 429/5xx — so operators can identify the
/// app, a stuck request can't hang for the default 60 s, and transient throttling is retried rather
/// than silently surfaced as a hard failure. Task cancellation is propagated. (SEC-15 / PERF-23)
enum ExternalRequest {

    /// Default retry budget for a single logical request.
    static let maxRetries = 3

    /// Default ceiling on a single response body.
    ///
    /// SA-32: every external fetch buffered the whole body with no ceiling and no inspection of
    /// `expectedContentLength`. TLS stops a network attacker, so the realistic trigger is a
    /// third-party origin compromise or a misbehaving origin — which could OOM the app *during a
    /// flight*, since trip-aware prefetch runs while airborne. The CloudKit ingest path already
    /// bounds its input (`SyncManager.maxIngestRecordBytes`); this mirrors that.
    ///
    /// Generous by design: the largest legitimate payload is an OurAirports CSV / OpenAIP
    /// per-country GeoJSON, comfortably under this. Callers with a smaller known bound should pass
    /// their own.
    static let maxResponseBytes: Int = 96 * 1024 * 1024

    /// Raised when a response is refused on size grounds.
    enum SizeError: LocalizedError {
        case tooLarge(declared: Int64?, limit: Int)

        var errorDescription: String? {
            switch self {
            case let .tooLarge(declared, limit):
                let declaredText = declared.map { "\($0)" } ?? "unknown"
                return "Response too large (declared \(declaredText) bytes, limit \(limit))"
            }
        }
    }

    /// Cancels a task as soon as the response headers declare a body over the limit, and strips
    /// sensitive headers across a cross-host redirect.
    ///
    /// SEC-C32: the declared-length check alone was NOT a size ceiling. It only fires when
    /// `Content-Length` is present and honest; for a chunked response (the norm on many CDNs) or a
    /// lying small one, the entire body was buffered and the cap applied only afterwards — the
    /// file's own comment conceded it "cannot prevent the allocation". `data(for:)` now streams and
    /// counts, so this delegate is the cheap early-out rather than the whole defence.
    ///
    /// SEC-C33: CFNetwork strips `Authorization` automatically on a cross-origin redirect, but not
    /// a CUSTOM header — so `x-openaip-api-key` would have been replayed to whatever host a 3xx
    /// pointed at. Nothing in the app implemented `willPerformHTTPRedirection` at all.
    private final class SizeLimitingDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        let limit: Int
        init(limit: Int) { self.limit = limit }

        /// Headers that must never survive a redirect to a different host.
        private static let sensitiveHeaders = ["Authorization", OpenAIPConfig.apiKeyHeader]

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse
        ) async -> URLSession.ResponseDisposition {
            if response.expectedContentLength != NSURLSessionTransferSizeUnknown,
               response.expectedContentLength > Int64(limit) {
                return .cancel
            }
            return .allow
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let originalHost = task.originalRequest?.url?.host,
                  let newHost = request.url?.host,
                  originalHost.caseInsensitiveCompare(newHost) != .orderedSame
            else {
                return request // same host — nothing to strip
            }

            var sanitised = request
            for header in Self.sensitiveHeaders {
                sanitised.setValue(nil, forHTTPHeaderField: header)
            }
            AppLog.general.debugLine("Stripped credential headers on cross-host redirect")
            return sanitised
        }
    }

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
    static func data(
        from url: URL,
        session: URLSession = session,
        maxRetries: Int = maxRetries,
        maxResponseBytes: Int = maxResponseBytes
    ) async throws -> (Data, HTTPURLResponse) {
        try await data(for: URLRequest(url: url), session: session, maxRetries: maxRetries,
                       maxResponseBytes: maxResponseBytes)
    }

    /// Perform a request with retry/backoff on 429/5xx and transient `URLError`s.
    ///
    /// The response body is size-bounded (SA-32): an oversized declared length is cancelled before
    /// the body is buffered, and an oversized actual body is refused after the fact.
    static func data(
        for request: URLRequest,
        session: URLSession = session,
        maxRetries: Int = maxRetries,
        maxResponseBytes: Int = maxResponseBytes
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        let sizeLimiter = SizeLimitingDelegate(limit: maxResponseBytes)
        while true {
            try Task.checkCancellation()
            do {
                // SEC-C32: stream and count, so the cap bounds what is ALLOCATED rather than
                // being applied to an already-buffered body. This is what makes the ceiling real
                // for a chunked or Content-Length-less response.
                let (byteStream, response) = try await session.bytes(for: request, delegate: sizeLimiter)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }

                var data = Data()
                if http.expectedContentLength > 0, http.expectedContentLength <= Int64(maxResponseBytes) {
                    data.reserveCapacity(Int(http.expectedContentLength))
                }
                for try await byte in byteStream {
                    data.append(byte)
                    if data.count > maxResponseBytes {
                        throw SizeError.tooLarge(declared: http.expectedContentLength, limit: maxResponseBytes)
                    }
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
