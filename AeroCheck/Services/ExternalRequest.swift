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

    /// Strips sensitive headers across a cross-host redirect.
    ///
    /// SEC-C33: CFNetwork strips `Authorization` automatically on a cross-origin redirect, but not
    /// a CUSTOM header, so `x-openaip-api-key` would have been replayed to whatever host a 3xx
    /// pointed at. Nothing in the app implemented `willPerformHTTPRedirection` at all.
    ///
    /// This delegate used to carry the declared-length early-out as well (SEC-C32), in
    /// `urlSession(_:dataTask:didReceive:)`. That callback is never delivered to the task delegate
    /// of `bytes(for:delegate:)` (nor of `data(for:delegate:)`): the async APIs consume the data-task
    /// callbacks themselves and pass on only the task-level ones (redirects, challenges, metrics).
    /// Probed 1 Oct 2026 on a real swisstopo tile: the response arrived, the method never ran. The
    /// check now runs on the response `bytes(for:)` returns, in `data(for:)`, which is just as early
    /// (see there).
    private final class RequestGuardDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        /// Headers that must never survive a redirect to a different host.
        private static let sensitiveHeaders = ["Authorization", OpenAIPConfig.apiKeyHeader]

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

    /// Whether a response's declared `Content-Length` is over `limit`. An unknown length (no header,
    /// or a chunked body) is never over: the streaming count is the cap for those.
    static func declaresTooLarge(_ expectedContentLength: Int64, limit: Int) -> Bool {
        expectedContentLength != NSURLSessionTransferSizeUnknown && expectedContentLength > Int64(limit)
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
    /// The response body is size-bounded (SA-32): a declared length over the limit is refused as
    /// soon as the response arrives, before a byte of the body is read, and a body with no declared
    /// length (or a lying one) is refused while it streams, the moment it passes the limit.
    static func data(
        for request: URLRequest,
        session: URLSession = session,
        maxRetries: Int = maxRetries,
        maxResponseBytes: Int = maxResponseBytes
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        let requestGuard = RequestGuardDelegate()
        while true {
            try Task.checkCancellation()
            do {
                // SEC-C32: stream and count, so the cap bounds what is ALLOCATED rather than
                // being applied to an already-buffered body. This is what makes the ceiling real
                // for a chunked or Content-Length-less response.
                let (byteStream, response) = try await session.bytes(for: request, delegate: requestGuard)
                guard let http = response as? HTTPURLResponse else {
                    byteStream.task.cancel()
                    throw URLError(.badServerResponse)
                }

                // The early-out, before a byte of the body is read. URLSession hands the response
                // over only once the first 512 bytes of the body are in (its content-sniffing
                // buffer, whatever the Content-Type; the whole body when shorter), never at the
                // headers: probed 1 Oct 2026, `bytes(for:)` and a data delegate alike waited for a
                // server holding its body back. `bytes(for:)` returns right then, so cancelling here
                // stops the transfer after that first chunk. This check used to sit in a delegate
                // method the async API never calls, so it never ran.
                let declared = http.expectedContentLength
                if declaresTooLarge(declared, limit: maxResponseBytes) {
                    byteStream.task.cancel()
                    AppLog.general.publicLine("Refused a response declaring \(declared) bytes (limit \(maxResponseBytes))")
                    throw SizeError.tooLarge(declared: declared, limit: maxResponseBytes)
                }

                // The backstop: counting while it streams caps a body with no declared length or
                // a lying one.
                var data = Data()
                if declared > 0 {
                    data.reserveCapacity(Int(declared))
                }
                for try await byte in byteStream {
                    data.append(byte)
                    if data.count > maxResponseBytes {
                        byteStream.task.cancel()
                        AppLog.general.publicLine("Refused a response body past \(maxResponseBytes) bytes")
                        throw SizeError.tooLarge(declared: declared >= 0 ? declared : nil, limit: maxResponseBytes)
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
