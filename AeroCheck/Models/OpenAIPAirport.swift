import Foundation
import CoreLocation

/// A radio frequency on an OpenAIP airport.
struct OpenAIPFrequency: Codable, Equatable {
    let name: String?
    let value: String       // MHz as a string, e.g. "121.030"
    let typeRaw: Int
    var typeLabel: String { OpenAIPFrequencyType.label(for: typeRaw) }
}

/// Best-effort mapping of OpenAIP frequency `type` codes onto the short labels the app shows (TWR/GND/…).
/// The frequency `name` carries the authoritative description, so an imperfect code mapping is harmless.
enum OpenAIPFrequencyType {
    static func label(for code: Int) -> String {
        switch code {
        case 0: return "APP"
        case 1: return "APRON"
        case 2: return "ARR"
        case 3: return "CTR"
        case 4: return "CTAF"
        case 5: return "DEL"
        case 6: return "DEP"
        case 7: return "FIS"
        case 8: return "GLD"
        case 9: return "GND"
        case 10: return "INFO"
        case 11: return "MULTICOM"
        case 12: return "UNICOM"
        case 13: return "RADAR"
        case 14: return "TWR"
        case 15: return "ATIS"
        case 16: return "RADIO"
        case 18: return "AFIS"
        default: return "RADIO"
        }
    }
}

/// An airport from OpenAIP's keyless per-country GeoJSON export (`{cc}_apt.geojson`). Distinct from the
/// OurAirports-shaped `Airport` struct — this is the raw OpenAIP record that the
/// `AirportDataMergeEngine` folds into the `Airport` backbone. (v4.1.0, increment 9)
struct OpenAIPAirport: Codable, Identifiable, Equatable {
    let id: String              // OpenAIP `_id`
    let name: String
    let icaoCode: String?       // absent for some minor fields
    let typeRaw: Int            // OpenAIP airport type code
    let elevationFeetMSL: Int?
    let magneticDeclination: Double?
    let country: String?        // ISO-2, for the merge's OpenAIP-only airports
    let frequencies: [OpenAIPFrequency]
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
        self.frequencies = (p.frequencies ?? []).map {
            OpenAIPFrequency(name: $0.name, value: $0.value, typeRaw: $0.type)
        }
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
        let frequencies: [FrequencyJSON]?
        enum CodingKeys: String, CodingKey {
            case oaipId = "_id"
            case name, icaoCode, type, elevation, magneticDeclination, country, frequencies
        }
    }
    struct FrequencyJSON: Decodable {
        let name: String?
        let value: String
        let type: Int
    }
    struct Geometry: Decodable { let coordinates: [Double] }

    struct MeasuredValue: Decodable {
        let value: Double
        let unit: Int
        var asFeetMSL: Int { unit == 0 ? Int((value * 3.28084).rounded()) : Int(value.rounded()) }
    }
}
