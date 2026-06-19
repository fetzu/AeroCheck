import Foundation
import CoreLocation
import MapKit

/// A vertical obstacle (tower / mast / wind turbine / building) from OpenAIP's keyless per-country
/// GeoJSON export. Surfaced for situational awareness — pairs with the terrain-clearance feature. (v4.1.0)
struct Obstacle: Codable, Identifiable, Equatable {
    let id: String
    let name: String?
    let typeRaw: Int            // OpenAIP obstacle type code (kept raw; 0 == wind turbine in CH)
    let elevationFeetMSL: Int?  // top of the obstacle, MSL
    let heightFeetAGL: Int?     // height above ground (optional in the source)
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    /// Parse OpenAIP's per-country obstacle GeoJSON export (`{cc}_obs.geojson`) into `[Obstacle]`.
    static func parse(geoJSON data: Data) throws -> [Obstacle] {
        let collection = try JSONDecoder().decode(ObstacleFeatureCollection.self, from: data)
        return collection.features.compactMap { Obstacle(feature: $0) }
    }

    fileprivate init?(feature: ObstacleFeatureCollection.Feature) {
        guard feature.geometry.coordinates.count >= 2 else { return nil }
        let p = feature.properties
        self.id = p.oaipId
        self.name = p.name
        self.typeRaw = p.type
        self.elevationFeetMSL = p.elevation?.asFeetMSL
        self.heightFeetAGL = p.height?.asFeetMSL
        self.longitude = feature.geometry.coordinates[0]   // GeoJSON is [lon, lat]
        self.latitude = feature.geometry.coordinates[1]
    }
}

/// MapKit annotation wrapper for an obstacle (read-only nav-map marker). Mirrors `NavaidAnnotation`.
final class ObstacleAnnotation: NSObject, MKAnnotation {
    let obstacle: Obstacle
    init(obstacle: Obstacle) { self.obstacle = obstacle }

    var coordinate: CLLocationCoordinate2D { obstacle.coordinate }
    var title: String? { obstacle.name ?? String(localized: "Obstacle") }
    var subtitle: String? {
        var parts: [String] = []
        if let top = obstacle.elevationFeetMSL { parts.append("\(top) ft MSL") }
        if let agl = obstacle.heightFeetAGL { parts.append("\(agl) ft AGL") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct ObstacleFeatureCollection: Decodable {
    let features: [Feature]

    struct Feature: Decodable {
        let properties: Properties
        let geometry: Geometry
    }
    struct Properties: Decodable {
        let oaipId: String
        let name: String?
        let type: Int
        let elevation: MeasuredValue?   // top of obstacle, MSL
        let height: MeasuredValue?      // height AGL (optional)
        enum CodingKeys: String, CodingKey {
            case oaipId = "_id"
            case name, type, elevation, height
        }
    }
    struct Geometry: Decodable { let coordinates: [Double] }

    /// OpenAIP `{value, unit, ...}` measure. `unit == 0` is meters (matches AltitudeLimit); else feet.
    struct MeasuredValue: Decodable {
        let value: Double
        let unit: Int
        var asFeetMSL: Int { unit == 0 ? Int((value * 3.28084).rounded()) : Int(value.rounded()) }
    }
}
