import CoreLocation
import Foundation

/// The aerodrome nearest the pilot, for onboarding's "Based at": asked of OpenAIP's online search, since on a fresh
/// install no aerodrome database is on the device yet (the author's answer 2 A on the onboarding page, 31 Oct 2026).
/// The position goes rounded to about a kilometre, as the online airspace's does. (6.8.0)
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

    static func request(near coordinate: CLLocationCoordinate2D, radiusMeters: Int = 40_000) -> URLRequest? {
        let position = String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
        return request("airports?pos=\(position)&dist=\(radiusMeters)&limit=30&\(fields)")
    }

    /// A country's aerodromes, a page of a thousand: since late October 2026 OpenAIP's firewall refuses position and
    /// box searches (403) and answers country ones, so the nearest is picked on the device from these. France is two
    /// pages of about 150 KB.
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

    /// The nearest aerodrome with an ICAO code in OpenAIP's answer, nil when none or the answer doesn't read.
    static func nearest(in data: Data, to coordinate: CLLocationCoordinate2D) -> Found? {
        page(data, near: coordinate)?.nearest
    }

    /// A page's nearest aerodrome and whether more pages follow.
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

    /// Asks OpenAIP around the pilot, else the country's list (`country`, ISO-2) for the nearest; nil offline, on any
    /// failure, or with nothing within reach.
    static func find(near coordinate: CLLocationCoordinate2D, country: String?) async -> Found? {
        if let request = request(near: coordinate), let data = await fetch(request),
           let found = nearest(in: data, to: coordinate) {
            return found
        }
        guard let country else { return nil }
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
