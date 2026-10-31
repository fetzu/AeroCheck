import CryptoKit
import DeviceCheck
import Foundation

/// The Atlas gate, the app's side (option H, decided 31 Oct 2026; the server's `src/services/atlas-gate.ts` says
/// what the gate is). (6.8.0)
///
/// Reading the Atlas online: every range read of an archive on tiles.aerocheck.app carries today's day value,
/// which this hands out once a day from `POST /api/v3/atlas/access`. Downloads: one-hour links to Cloudflare's
/// storage from `POST /api/v3/atlas/links`, counted per device and month on the server.
///
/// Both requests are signed with an App Attest key, created and vouched for by Apple once per install. Its
/// identifier is kept in UserDefaults; the key itself never leaves the Secure Enclave. The Simulator can't attest:
/// a Debug build there uses the developer token from `Secrets.xcconfig` instead, which the sandbox accepts.
///
/// Until the server has the gate (503, or a route it doesn't know), reads go without a day value and downloads
/// from tiles.aerocheck.app, as before.
actor AtlasAccess {
    static let shared = AtlasAccess()

    /// The header the firewall rule reads on archive reads.
    nonisolated static let dayHeader = "X-AeroCheck-Atlas"

    enum Links: Equatable, Sendable {
        /// A link per archive asked for, `<region>/<file>` → URL.
        case links([String: URL])
        /// This month's downloads are used up.
        case ceiling(limit: Int, resetsAt: Date?)
        /// The gate isn't there (yet), or not reachable: download as before.
        case unavailable
    }

    /// One API request; the tests replace it.
    typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let attesting: AtlasAttesting
    private let send: Send
    private let defaults: UserDefaults
    private let baseURL: String
    private let devToken: String?
    private let sessionToken: @Sendable () -> String?
    private let now: @Sendable () -> Date

    private var inFlight: Task<[String: String], Never>?
    private var lastAttempt: Date?
    private var lastRefresh: Date?

    nonisolated static let keyIdKey = "atlas.appAttestKeyId"
    nonisolated static let valuesKey = "atlas.dayValues"
    /// After a failed fetch, the next try waits this long: reads go on without a value meanwhile.
    nonisolated static let retryInterval: TimeInterval = 60
    /// A 403 asks for a fresh value at most this often, so a rule that refuses every value can't make each read
    /// a request to the API.
    nonisolated static let refreshInterval: TimeInterval = 300

    init(attesting: AtlasAttesting = AppAttestService(),
         send: @escaping Send = AtlasAccess.urlSessionSend,
         defaults: UserDefaults = .standard,
         baseURL: String = APIConfig.baseURL,
         devToken: String? = AtlasAccess.developerToken,
         sessionToken: @escaping @Sendable () -> String? = { KeychainStore.app.get(.apiSessionToken) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.attesting = attesting
        self.send = send
        self.defaults = defaults
        self.baseURL = baseURL
        self.devToken = devToken
        self.sessionToken = sessionToken
        self.now = now
    }

    // MARK: - Day values

    /// Today's value (UTC), from the copy kept here or the server; nil when it can't be had now.
    func dayValue() async -> String? {
        let today = Self.utcDay(now())
        if let value = stored()[today] { return value }
        return await fetchValues()[today]
    }

    /// After a 403 on an archive read: the kept value is stale (a rotated secret, a clock far off). Fetches again,
    /// at most every five minutes.
    func refreshDayValue() async -> String? {
        if let lastRefresh, now().timeIntervalSince(lastRefresh) < Self.refreshInterval { return nil }
        lastRefresh = now()
        lastAttempt = nil
        defaults.removeObject(forKey: Self.valuesKey)
        return await fetchValues()[Self.utcDay(now())]
    }

    private func stored() -> [String: String] {
        defaults.dictionary(forKey: Self.valuesKey) as? [String: String] ?? [:]
    }

    /// One fetch at a time; the callers waiting on it share its answer.
    private func fetchValues() async -> [String: String] {
        if let inFlight { return await inFlight.value }
        if let lastAttempt, now().timeIntervalSince(lastAttempt) < Self.retryInterval { return stored() }
        lastAttempt = now()
        let task = Task { await self.requestValues() }
        inFlight = task
        let values = await task.value
        inFlight = nil
        return values
    }

    private func requestValues() async -> [String: String] {
        guard let (data, response) = try? await signed("access", body: [:]) else { return stored() }
        guard response.statusCode == 200,
              let answer = try? JSONDecoder().decode(AccessAnswer.self, from: data) else { return stored() }
        let values = Dictionary(answer.data.values.map { ($0.day, $0.value) }, uniquingKeysWith: { first, _ in first })
        defaults.set(values, forKey: Self.valuesKey)
        lastAttempt = nil
        return values
    }

    // MARK: - Download links

    /// One-hour links for archives (`<region>/<file>`, at most four).
    func links(_ files: [String]) async -> Links {
        let response: (Data, HTTPURLResponse)
        do {
            response = try await signed("links", body: ["files": files], clientExtra: ["files": files], bearer: sessionToken())
        } catch {
            return .unavailable
        }
        let (data, http) = response
        switch http.statusCode {
        case 200:
            guard let answer = try? JSONDecoder().decode(LinksAnswer.self, from: data) else { return .unavailable }
            var links: [String: URL] = [:]
            for link in answer.data.links { if let url = URL(string: link.url) { links[link.file] = url } }
            return links.count == files.count ? .links(links) : .unavailable
        case 429:
            guard let refusal = try? JSONDecoder().decode(CeilingAnswer.self, from: data), refusal.code == "ATLAS_CEILING"
            else { return .unavailable }
            return .ceiling(limit: refusal.limit, resetsAt: refusal.resetsAt.flatMap(Self.isoDate))
        default:
            return .unavailable
        }
    }

    // MARK: - Signed requests

    /// A request to `/api/v3/atlas/<path>`, signed with this install's key (attested first if there is none), or
    /// with the developer token where App Attest isn't available. A key the server no longer knows, or one the
    /// Secure Enclave lost (a backup restored on another device), is replaced once.
    private func signed(_ path: String, body: [String: [String]], clientExtra: [String: [String]] = [:],
                        bearer: String? = nil) async throws -> (Data, HTTPURLResponse) {
        if !attesting.isSupported {
            guard let devToken else { throw AtlasError.unsupported }
            var request = try apiRequest(path, json: body)
            request.setValue(devToken, forHTTPHeaderField: "X-AeroCheck-Atlas-Dev")
            if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
            return try await send(request)
        }
        for attempt in 0..<2 {
            let keyId = try await ensureKey()
            // The exact bytes signed are the bytes sent: the server checks the signature over them, then reads them.
            var object: [String: Any] = ["purpose": path, "ts": Self.milliseconds(now())]
            for (key, value) in clientExtra { object[key] = value }
            let clientData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let assertion: Data
            do {
                assertion = try await attesting.generateAssertion(keyId, clientDataHash: Data(SHA256.hash(data: clientData)))
            } catch let error as DCError where error.code == .invalidKey && attempt == 0 {
                defaults.removeObject(forKey: Self.keyIdKey)
                continue
            }
            var request = try apiRequest(path, json: ["keyId": keyId, "clientData": clientData.base64EncodedString(),
                                                      "assertion": assertion.base64EncodedString()])
            if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await send(request)
            if response.statusCode == 401, attempt == 0,
               (try? JSONDecoder().decode(ErrorAnswer.self, from: data))?.code == "ATLAS_KEY_UNKNOWN" {
                defaults.removeObject(forKey: Self.keyIdKey)
                continue
            }
            return (data, response)
        }
        throw AtlasError.keyRefused
    }

    /// This install's key, created and attested the first time.
    private func ensureKey() async throws -> String {
        if let keyId = defaults.string(forKey: Self.keyIdKey) { return keyId }
        let keyId = try await attesting.generateKey()
        let (challengeData, challengeResponse) = try await send(try apiRequest("challenge", json: [String: String]()))
        guard challengeResponse.statusCode == 200,
              let challenge = (try? JSONDecoder().decode(ChallengeAnswer.self, from: challengeData))?.data.challenge
        else { throw AtlasError.http(challengeResponse.statusCode) }
        let attestation = try await attesting.attestKey(keyId, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
        let (_, response) = try await send(try apiRequest("attest", json: [
            "keyId": keyId, "attestation": attestation.base64EncodedString(), "challenge": challenge,
        ]))
        guard response.statusCode == 200 else { throw AtlasError.http(response.statusCode) }
        defaults.set(keyId, forKey: Self.keyIdKey)
        return keyId
    }

    private func apiRequest(_ path: String, json: Any) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/api/v3/atlas/\(path)") else { throw AtlasError.http(0) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret = APIConfig.appClientSecret { request.setValue(secret, forHTTPHeaderField: "X-AeroCheck-Client") }
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return request
    }

    // MARK: - Helpers

    enum AtlasError: Error, Equatable { case unsupported, keyRefused, http(Int) }

    private struct ChallengeAnswer: Decodable { struct Body: Decodable { let challenge: String }; let data: Body }
    private struct AccessAnswer: Decodable {
        struct Value: Decodable { let day: String; let value: String }
        struct Body: Decodable { let values: [Value] }
        let data: Body
    }
    private struct LinksAnswer: Decodable {
        struct Link: Decodable { let file: String; let url: String }
        struct Body: Decodable { let links: [Link] }
        let data: Body
    }
    private struct CeilingAnswer: Decodable { let code: String; let limit: Int; let resetsAt: String? }
    private struct ErrorAnswer: Decodable { let code: String }

    nonisolated static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    nonisolated static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    nonisolated static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    nonisolated static let urlSessionSend: Send = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// Debug builds only: the developer token that stands in for App Attest where the device can't attest (the
    /// Simulator). From the untracked `Secrets.xcconfig` (`ATLAS_DEV_TOKEN`); Release builds never carry one.
    nonisolated static let developerToken: String? = {
        #if DEBUG
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "AtlasDevToken") as? String else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.count >= 16 && !token.hasPrefix("$") ? token : nil
        #else
        return nil
        #endif
    }()
}

/// What the Atlas gate needs of App Attest; the tests replace it.
protocol AtlasAttesting: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// Apple's App Attest service.
struct AppAttestService: AtlasAttesting {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }
    func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}
