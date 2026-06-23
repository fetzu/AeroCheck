import Foundation
import CoreLocation
import MapKit

/// A radio navigation aid (VOR / DME / NDB / VOR-DME …) from OpenAIP's keyless per-country GeoJSON
/// export. Stored in our own compact form (the export is re-encoded to disk as `[Navaid]`). Each navaid
/// carries a `magneticDeclination`, which is the value the flight-plan declination fix uses. (v4.1.0)
struct Navaid: Codable, Identifiable, Equatable {
    let id: String              // OpenAIP `_id`
    let name: String
    let identifier: String      // ident, e.g. "CVA"
    let typeRaw: Int            // OpenAIP navaid type enum (mapped leniently via `type`)
    let frequencyValue: String? // MHz string, e.g. "112.050" (kHz for NDB)
    let frequencyUnit: Int?
    let channel: String?        // paired VOR/TACAN channel, e.g. "57Y"
    let elevationFeet: Int?     // MSL
    let magneticDeclination: Double?   // degrees (east positive); fractional in the source
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var type: NavaidType { NavaidType(rawValue: typeRaw) ?? .unknown }

    /// Great-circle distance in nautical miles (haversine on stored doubles, no allocation).
    func distanceNM(from coord: CLLocationCoordinate2D) -> Double {
        let earthRadiusNm = 3440.065
        let dLat = (coord.latitude - latitude) * .pi / 180
        let dLon = (coord.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(coord.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusNm * asin(min(1, sqrt(a)))
    }
}

/// OpenAIP navaid type codes (best-effort: the CH export only exercises 0 and 7). Unknown codes map to
/// `.unknown` rather than failing decode — verify the exact codes against a multi-country export before
/// relying on the display labels. (v4.1.0)
enum NavaidType: Int {
    case dme = 0, tacan = 1, ndb = 2, vor = 3, vorDme = 4, vortac = 5, dvor = 6, dvorDme = 7, dvortac = 8
    case unknown = -1

    /// Short label for map symbols / waypoint naming.
    var shortLabel: String {
        switch self {
        case .dme: return "DME"
        case .tacan: return "TACAN"
        case .ndb: return "NDB"
        case .vor, .dvor: return "VOR"
        case .vorDme, .dvorDme: return "VOR/DME"
        case .vortac, .dvortac: return "VORTAC"
        case .unknown: return "NAVAID"
        }
    }
}

/// MapKit annotation for displaying a navaid on the map (mirrors AirportAnnotation). (v4.1.0)
class NavaidAnnotation: NSObject, MKAnnotation {
    let navaid: Navaid
    init(navaid: Navaid) {
        self.navaid = navaid
        super.init()
    }
    var coordinate: CLLocationCoordinate2D { navaid.coordinate }
    var title: String? { navaid.identifier }
    var subtitle: String? { "\(navaid.type.shortLabel) · \(navaid.name)" }
}

// MARK: - GeoJSON parsing (OpenAIP keyless export)

extension Navaid {
    /// Parse OpenAIP's per-country navaid GeoJSON export (`{cc}_nav.geojson`) into `[Navaid]`.
    /// Features with malformed geometry are skipped, not fatal.
    static func parse(geoJSON data: Data) throws -> [Navaid] {
        let collection = try JSONDecoder().decode(NavaidFeatureCollection.self, from: data)
        return collection.features.compactMap { Navaid(feature: $0) }
    }

    fileprivate init?(feature: NavaidFeatureCollection.Feature) {
        guard feature.geometry.coordinates.count >= 2,
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: feature.geometry.coordinates[1],
                                                                   longitude: feature.geometry.coordinates[0])) else { return nil }
        let p = feature.properties
        self.id = p.oaipId
        self.name = p.name
        self.identifier = p.identifier
        self.typeRaw = p.type
        self.frequencyValue = p.frequency?.value
        self.frequencyUnit = p.frequency?.unit
        self.channel = p.channel
        self.elevationFeet = p.elevation?.asFeetMSL
        self.magneticDeclination = p.magneticDeclination
        self.longitude = feature.geometry.coordinates[0]   // GeoJSON is [lon, lat]
        self.latitude = feature.geometry.coordinates[1]
    }
}

/// Wraps a `Decodable` element so a single malformed element in an array decodes to `nil` instead of
/// aborting the whole array decode. The element boundary is still consumed (the wrapper's own decode
/// always succeeds), so per-feature failures are skipped rather than throwing. (v4.1.0 pre-tag fix — M1)
private struct FailableDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Wrapped.self)
    }
}

private struct NavaidFeatureCollection: Decodable {
    let features: [Feature]

    // Lossy per-feature decode: one malformed feature (a missing required Property, or a non-Point
    // geometry whose `coordinates` isn't a flat [Double]) must be SKIPPED, not abort the whole-country
    // decode — which would yield zero navaids and silently disable the region's declination provider.
    private enum CodingKeys: String, CodingKey { case features }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lossy = try container.decodeIfPresent([FailableDecodable<Feature>].self, forKey: .features) ?? []
        features = lossy.compactMap(\.value)
    }

    struct Feature: Decodable {
        let properties: Properties
        let geometry: Geometry
    }

    struct Properties: Decodable {
        let oaipId: String
        let name: String
        let identifier: String
        let type: Int
        let frequency: Frequency?
        let channel: String?
        let elevation: Elevation?
        let magneticDeclination: Double?   // Double: the source mixes integer (4) and fractional (2.83…)

        enum CodingKeys: String, CodingKey {
            case oaipId = "_id"
            case name, identifier, type, frequency, channel, elevation, magneticDeclination
        }

        struct Frequency: Decodable {
            let value: String?   // String in the source, e.g. "112.050"
            let unit: Int?
        }
        struct Elevation: Decodable {
            let value: Double         // OpenAIP serves fractional measured values — Int would abort the whole-country decode (review #1)
            let unit: Int             // 0 = meters (matches AltitudeLimit), 1 = feet
            let referenceDatum: Int?
            var asFeetMSL: Int { unit == 0 ? Int((value * 3.28084).rounded()) : Int(value.rounded()) }
        }
    }

    struct Geometry: Decodable { let coordinates: [Double] }
}
