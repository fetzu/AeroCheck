import CoreLocation
import Foundation

/// The aerodrome nearest the pilot, for onboarding's "Based at" (the author's answer 2 A on the onboarding page,
/// 31 Oct 2026): from the bundled index (`BundledAerodromes`), offline, since 2 Nov 2026; OpenAIP's online search only
/// if it were missing, by the country's list (a country code, never the position: the privacy policy, 3.4). (6.8.0)
enum NearestAerodrome {

    struct Found: Equatable {
        let ident: String
        let name: String
        /// Nautical miles from the pilot.
        let distanceNM: Double
    }

    /// OpenAIP's aerodrome types that are no base for an aeroplane: military heliport, civil heliport, closed.
    static let excludedTypes: Set<Int> = [4, 7, 8]

    /// The fields read: OpenAIP's full records are ten times the size.
    static let fields = "fields=icaoCode,name,type,geometry"

    /// A country's aerodromes, a page of a thousand, the nearest picked on the device from these: the position never
    /// goes to OpenAIP (6.8.1; its firewall refused position and box searches since late October 2026 anyway). France
    /// is two pages of about 150 KB.
    static func request(country: String, page: Int) -> URLRequest? {
        request("airports?country=\(country)&limit=1000&page=\(page)&\(fields)")
    }

    private static func request(_ path: String) -> URLRequest? {
        guard let url = URL(string: "\(OpenAIPConfig.coreAPIBaseURL)/\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(OpenAIPConfig.apiKey, forHTTPHeaderField: OpenAIPConfig.apiKeyHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        return request
    }

    /// A page's nearest aerodrome with an ICAO code and whether more pages follow; nil when the answer doesn't read.
    static func page(_ data: Data, near coordinate: CLLocationCoordinate2D) -> (nearest: Found?, hasMore: Bool)? {
        struct Response: Decodable {
            let items: [Item]
            let page: Int?
            let totalPages: Int?
        }
        struct Item: Decodable {
            let name: String?
            let icaoCode: String?
            let type: Int?
            let geometry: Geometry?
        }
        struct Geometry: Decodable { let coordinates: [Double] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let nearest = response.items.compactMap { item -> Found? in
            guard let ident = item.icaoCode?.trimmingCharacters(in: .whitespaces).uppercased(), ident.count == 4,
                  !excludedTypes.contains(item.type ?? 0),
                  let point = item.geometry?.coordinates, point.count >= 2 else { return nil }
            let meters = here.distance(from: CLLocation(latitude: point[1], longitude: point[0]))
            return Found(ident: ident, name: displayName(item.name) ?? ident, distanceNM: meters / 1852)
        }
        .min { $0.distanceNM < $1.distanceNM }
        return (nearest, (response.page ?? 1) < (response.totalPages ?? 1))
    }

    /// The nearest from the airport data, else the bundled index, else OpenAIP's list of the country (`country`,
    /// ISO-2); nil offline, on any failure, or with nothing within reach.
    /// `store`: the app's airport data. Once downloaded (OurAirports, with each downloaded country's OpenAIP aerodromes
    /// merged in) it is fresher than the bundled index, which is a snapshot from the last tag, and it answers instead
    /// (the author's question of 2 Nov 2026: the bundle never supersedes fresher data).
    @MainActor
    static func find(near coordinate: CLLocationCoordinate2D, country: String?,
                     store: AirportDataService? = nil) async -> Found? {
        if let store, store.isDataAvailable {
            await store.ensureLoaded()
            if let airport = store.nearestAirport(to: coordinate, maxDistanceNm: 50, types: AirportType.fixedWing) {
                let metres = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    .distance(from: CLLocation(latitude: airport.latitude, longitude: airport.longitude))
                return Found(ident: airport.ident, name: airport.name, distanceNM: metres / 1852)
            }
        }
        // Else the bundled index: on the device, so no signal and no OpenAIP needed (the author's go, 2 Nov 2026).
        let bundled = await Task.detached(priority: .userInitiated) {
            BundledAerodromes.all.isEmpty ? nil : BundledAerodromes.nearest(to: coordinate)
        }.value
        if let bundled { return bundled }
        guard BundledAerodromes.all.isEmpty, let country else { return nil }
        var best: Found?
        for number in 1...3 {
            guard let request = request(country: country, page: number), let data = await fetch(request),
                  let page = page(data, near: coordinate) else { break }
            if let found = page.nearest, found.distanceNM < best?.distanceNM ?? .infinity { best = found }
            if !page.hasMore { break }
        }
        // Within reach of a base: beyond 50 NM it is no suggestion.
        return best.flatMap { $0.distanceNM <= 50 ? $0 : nil }
    }

    /// An aerodrome found by name or code.
    struct Named: Equatable, Hashable {
        let ident: String
        let name: String
    }

    /// Aerodromes whose name or code matches `query`, from OpenAIP's text search, which still answers (its position
    /// search is refused): onboarding's "Based at" offers them while the airports file isn't on the device yet (the
    /// author's answer on 1 Nov 2026 to device check r4-18). Empty offline or on any failure.
    static func search(_ query: String, limit: Int = 6) async -> [Named] {
        let local = await Task.detached(priority: .userInitiated) {
            BundledAerodromes.all.isEmpty ? nil : BundledAerodromes.search(query, limit: limit)
        }.value
        if let local { return local }
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard typed.count >= 2,
              let encoded = typed.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let request = request("airports?search=\(encoded)&limit=\(limit * 2)&fields=icaoCode,name,type"),
              let data = await fetch(request) else { return [] }
        return named(in: data, limit: limit)
    }

    /// The aerodromes with an ICAO code in a text search's answer, at most `limit`.
    static func named(in data: Data, limit: Int) -> [Named] {
        struct Response: Decodable { let items: [Item] }
        struct Item: Decodable {
            let name: String?
            let icaoCode: String?
            let type: Int?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        var seen = Set<String>()
        return response.items.compactMap { item -> Named? in
            guard let ident = item.icaoCode?.trimmingCharacters(in: .whitespaces).uppercased(), ident.count == 4,
                  !excludedTypes.contains(item.type ?? 0), seen.insert(ident).inserted else { return nil }
            return Named(ident: ident, name: displayName(item.name) ?? ident)
        }
        .prefix(limit)
        .map { $0 }
    }

    /// OpenAIP writes most names in capitals: "BRESSAUCOURT" reads "Bressaucourt"; a name in mixed case stays.
    static func displayName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return name == name.uppercased() ? name.capitalized(with: Locale(identifier: "fr_CH")) : name
    }

    private static func fetch(_ request: URLRequest) async -> Data? {
        guard let (data, response) = try? await ExternalRequest.data(for: request, maxRetries: 0,
                                                                    maxResponseBytes: 2_000_000),
              response.statusCode == 200 else { return nil }
        return data
    }
}
