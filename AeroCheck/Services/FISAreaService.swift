import Foundation
import CoreLocation

// MARK: - The FIS areas (6.4.2)
//
// Where another FIS than the area's works low-level VFR traffic, from the server's weekly VFR data job
// (`/data/fis/v1/areas.json`). One area since 6.4.2: Bâle Information 130.900 over TMA BALE ZURICH AZ4, the Ajoie
// and the northern Jura east to Olten, from 2,000 ft AGL, which Zurich ACC delegates to Basel APP (the author's
// answer q4 of 18 Oct 2026; French eAIP AD 2 LFSB 2.18 and 2.20). Over it the Swiss split, and the data's Swiss
// sectors, give Zürich Information. The file names the OpenAIP airspace that draws an area; its shape and limits
// come from this device's own OpenAIP data. Asked first: at the planned altitude on a route's radio timeline (the
// Cockpit and the nav log), at the GPS altitude without a route.

/// The server's file.
struct FISAreaFile: Codable, Equatable {
    static let schema = 1

    struct Area: Codable, Equatable {
        /// The OpenAIP airspace that draws an area: its name, type and class, as OpenAIP writes them.
        struct Airspace: Codable, Equatable {
            let name: String
            let type: Int
            let icaoClass: Int?
        }

        let id: String
        let country: String
        /// "BALE INFORMATION".
        let station: String
        let frequency: String
        let airspace: Airspace
        let source: String?
    }

    let v: Int
    let generated: String?
    let areas: [Area]
}

/// An area on this device: its station, and the airspaces of the device's OpenAIP data that draw it.
struct FISArea {
    /// As the nav log names a FIS: "BALE INFO".
    let station: RouteRadioPlanner.Station
    let airspaces: [Airspace]

    /// The areas of a file found in a set of airspaces (the device's OpenAIP data), by name, type and class and in
    /// the area's country. An area the data doesn't have (its country not downloaded, a part renamed) is left out:
    /// the sectors as before.
    static func areas(of file: FISAreaFile?, in airspaces: [Airspace]) -> [FISArea] {
        (file?.areas ?? []).compactMap { area in
            let drawn = airspaces.filter {
                $0.name == area.airspace.name && $0.airspaceType.rawValue == area.airspace.type
                    && $0.icaoClass == area.airspace.icaoClass && $0.country.uppercased() == area.country.uppercased()
            }
            guard !drawn.isEmpty else { return nil }
            return FISArea(station: .init(frequency: RouteRadioPlanner.Station.normalized(area.frequency),
                                          callSign: RouteRadioPlanner.callSign(area.station)),
                           airspaces: drawn)
        }
    }

    /// Whether a point at an altitude (ft MSL) is in it: inside one of its airspaces, and surely within that
    /// airspace's band over this ground (a floor in ft AGL needs the ground; unknown, it doesn't count).
    func contains(_ point: CLLocationCoordinate2D, altitudeFt: Double, groundFt: ClosedRange<Double>?) -> Bool {
        airspaces.contains { airspace in
            guard airspace.containsPoint(point) else { return false }
            if case .inside = AirspaceVerticalBand(airspace, terrainFt: groundFt).verdict(altitudeFt: altitudeFt) {
                return true
            }
            return false
        }
    }

    /// The first area holding a point at an altitude.
    static func first(of areas: [FISArea], at point: CLLocationCoordinate2D, altitudeFt: Double?,
                      groundFt: ClosedRange<Double>?) -> FISArea? {
        guard let altitudeFt else { return nil }
        return areas.first { $0.contains(point, altitudeFt: altitudeFt, groundFt: groundFt) }
    }
}

/// Fetches and caches the FIS areas, as `OfficialChartService` does the chart registry: on disk, refreshed when a
/// week old, silent on failure. Without it, the sectors as before 6.4.2.
@MainActor
final class FISAreaService: ObservableObject {
    static let shared = FISAreaService()

    static let fileURL = APIConfig.dataURL("fis/v1/areas.json")
    static let allowedHosts = Set([fileURL.host?.lowercased()].compactMap { $0 })
    /// Under 1 KB with one area.
    static let maxBytes = 64 * 1024
    /// A week, the job's own rhythm.
    nonisolated static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var file: FISAreaFile?
    private(set) var lastFetch: Date?
    private var isLoading = false
    /// The areas found in the airspace data last asked about, with the data's size then: found again when it
    /// changes.
    private var resolved: (count: Int, file: FISAreaFile?, areas: [FISArea])?

    private let cacheURL: URL
    private let fetchOverride: ((URL) async throws -> Data)?
    private let now: () -> Date

    /// - Parameters:
    ///   - cacheURL: tests only; where the cache lives instead of the app's directory.
    ///   - fetch: tests only; replaces the network (URL in, body out).
    init(cacheURL: URL? = nil, fetch: ((URL) async throws -> Data)? = nil, now: @escaping () -> Date = Date.init) {
        self.cacheURL = cacheURL ?? DataPersistenceManager.shared.localAppDirectory.appendingPathComponent("fis-areas.json")
        fetchOverride = fetch
        self.now = now
        loadCache()
    }

    /// The areas in the device's OpenAIP data.
    func areas(in openAIP: OpenAIPDataService) -> [FISArea] {
        if let resolved, resolved.count == openAIP.airspaceCount, resolved.file == file { return resolved.areas }
        let areas = FISArea.areas(of: file, in: openAIP.airspaces(named: Set((file?.areas ?? []).map(\.airspace.name))))
        resolved = (openAIP.airspaceCount, file, areas)
        return areas
    }

    /// Refresh when a week old (or never fetched). Silent on failure.
    func refreshIfNeeded() async {
        if let lastFetch, now().timeIntervalSince(lastFetch) >= 0, now().timeIntervalSince(lastFetch) < Self.maxAge { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let decoded = try JSONDecoder().decode(FISAreaFile.self, from: try await fetch(Self.fileURL))
            guard decoded.v == FISAreaFile.schema else {
                AppLog.general.publicLine("FIS areas: schema \(decoded.v) not read")
                return
            }
            file = decoded
            lastFetch = now()
            saveCache(decoded)
        } catch {
            AppLog.general.debugLine("FIS areas fetch failed: \(error.localizedDescription)")
        }
    }

    private enum FetchError: Error { case http(Int), tooLarge }

    /// GET the file: on the allow-list, under the size cap, a 200.
    private func fetch(_ url: URL) async throws -> Data {
        guard ExternalRequest.isAllowed(url, hosts: Self.allowedHosts) else { throw ExternalRequest.HostError.notAllowed }
        let data: Data
        if let fetchOverride {
            data = try await fetchOverride(url)
        } else {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // The API's app-client hurdle, as for every /data file: absent in a build without Secrets.xcconfig.
            if let secret = APIConfig.appClientSecret {
                request.setValue(secret, forHTTPHeaderField: "X-AeroCheck-Client")
            }
            let (body, response) = try await ExternalRequest.data(
                for: request, maxResponseBytes: Self.maxBytes, allowedHosts: Self.allowedHosts)
            guard response.statusCode == 200 else { throw FetchError.http(response.statusCode) }
            data = body
        }
        guard data.count <= Self.maxBytes else { throw FetchError.tooLarge }
        return data
    }

    // MARK: Cache

    private struct Cached: Codable {
        let fetchedAt: Date
        let file: FISAreaFile
        /// The address it was read from: one from the other server (TestFlight's, the App Store's) is kept for
        /// offline use but counts as never fetched, so the first refresh replaces it.
        let source: String
    }

    private func loadCache() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? decoder.decode(Cached.self, from: data),
              cached.file.v == FISAreaFile.schema else { return }
        file = cached.file
        lastFetch = cached.source == Self.fileURL.absoluteString ? cached.fetchedAt : nil
    }

    private func saveCache(_ file: FISAreaFile) {
        guard let fetchedAt = lastFetch else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(Cached(fetchedAt: fetchedAt, file: file, source: Self.fileURL.absoluteString))
                .write(to: cacheURL, options: DataPersistenceManager.protectedWriteOptions)
        } catch {
            AppLog.general.debugLine("Failed to cache the FIS areas: \(error.localizedDescription)")
        }
    }

    /// Seeded directly in tests, so no test has to reach the network (nil empties it).
    func seedForTesting(_ seeded: FISAreaFile?) {
        file = seeded
        lastFetch = seeded == nil ? nil : now()
        resolved = nil
    }
}
