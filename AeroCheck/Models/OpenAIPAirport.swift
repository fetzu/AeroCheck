import Foundation
import CoreLocation

/// An airport from OpenAIP's keyless per-country GeoJSON export (`{cc}_apt.geojson`). Distinct from the
/// OurAirports-shaped `Airport` struct — this is the raw OpenAIP record that the (flag-gated)
/// `AirportDataMergeEngine` folds into the `Airport` backbone. (v4.1.0, increment 9)
struct OpenAIPAirport: Codable, Identifiable, Equatable {
    let id: String              // OpenAIP `_id`
    let name: String
    let icaoCode: String?       // absent for some minor fields
    let typeRaw: Int            // OpenAIP airport type code
    let elevationFeetMSL: Int?
    let magneticDeclination: Double?
    let country: String?        // ISO-2, for the merge's OpenAIP-only airports
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    /// Best-effort mapping of OpenAIP's `type` code onto the app's `AirportType`. Coarse — used only to
    /// keep the fixed-wing filter sensible after a merge.
    var airportType: AirportType {
        switch typeRaw {
        case 3: return .largeAirport               // International airport
        case 0, 9: return .mediumAirport           // Airport / IFR airfield
        case 4, 7: return .heliport                // Heliport (mil / civil)
        case 8: return .closed
        case 10: return .seaplaneBase
        default: return .smallAirport              // airfields, ULM, glider, strips, altiports…
        }
    }

    /// Parse OpenAIP's per-country airport GeoJSON export into `[OpenAIPAirport]`.
    static func parse(geoJSON data: Data) throws -> [OpenAIPAirport] {
        let collection = try JSONDecoder().decode(AirportFeatureCollection.self, from: data)
        return collection.features.compactMap { OpenAIPAirport(feature: $0) }
    }

    fileprivate init?(feature: AirportFeatureCollection.Feature) {
        guard feature.geometry.coordinates.count >= 2 else { return nil }
        let p = feature.properties
        self.id = p.oaipId
        self.name = p.name
        self.icaoCode = p.icaoCode
        self.typeRaw = p.type
        self.elevationFeetMSL = p.elevation?.asFeetMSL
        self.magneticDeclination = p.magneticDeclination
        self.country = p.country
        self.longitude = feature.geometry.coordinates[0]   // GeoJSON is [lon, lat]
        self.latitude = feature.geometry.coordinates[1]
    }
}

private struct AirportFeatureCollection: Decodable {
    let features: [Feature]

    struct Feature: Decodable {
        let properties: Properties
        let geometry: Geometry
    }
    struct Properties: Decodable {
        let oaipId: String
        let name: String
        let icaoCode: String?
        let type: Int
        let elevation: MeasuredValue?
        let magneticDeclination: Double?
        let country: String?
        enum CodingKeys: String, CodingKey {
            case oaipId = "_id"
            case name, icaoCode, type, elevation, magneticDeclination, country
        }
    }
    struct Geometry: Decodable { let coordinates: [Double] }

    struct MeasuredValue: Decodable {
        let value: Double
        let unit: Int
        var asFeetMSL: Int { unit == 0 ? Int((value * 3.28084).rounded()) : Int(value.rounded()) }
    }
}
