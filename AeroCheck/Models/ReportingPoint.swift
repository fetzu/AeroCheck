import Foundation
import CoreLocation
import MapKit

/// A VFR reporting point (mandatory or on-request) from OpenAIP's keyless per-country GeoJSON export
/// (`{cc}_rpp.geojson`). Read-only nav-map markers (and, later, briefing context). (v4.1.0)
struct ReportingPoint: Codable, Identifiable, Equatable {
    let id: String
    let name: String?
    let compulsory: Bool
    let elevationFeetMSL: Int?
    let remarks: String?
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    func distanceNM(from coord: CLLocationCoordinate2D) -> Double {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        let there = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return here.distance(from: there) / 1852.0
    }

    /// Parse OpenAIP's per-country reporting-point GeoJSON export into `[ReportingPoint]`.
    static func parse(geoJSON data: Data) throws -> [ReportingPoint] {
        let collection = try JSONDecoder().decode(RPFeatureCollection.self, from: data)
        return collection.features.compactMap { ReportingPoint(feature: $0) }
    }

    fileprivate init?(feature: RPFeatureCollection.Feature) {
        guard feature.geometry.coordinates.count >= 2 else { return nil }
        let p = feature.properties
        self.id = p.oaipId
        self.name = p.name
        self.compulsory = p.compulsory ?? false
        self.elevationFeetMSL = p.elevation?.asFeetMSL
        self.remarks = p.remarks
        self.longitude = feature.geometry.coordinates[0]   // GeoJSON is [lon, lat]
        self.latitude = feature.geometry.coordinates[1]
    }
}

/// MapKit annotation wrapper for a reporting point (read-only nav-map marker). Mirrors `NavaidAnnotation`.
final class ReportingPointAnnotation: NSObject, MKAnnotation {
    let point: ReportingPoint
    init(point: ReportingPoint) { self.point = point }

    var coordinate: CLLocationCoordinate2D { point.coordinate }
    var title: String? { point.name ?? String(localized: "Reporting point") }
    var subtitle: String? {
        if let remarks = point.remarks, !remarks.isEmpty { return remarks }
        return point.compulsory ? String(localized: "Compulsory") : String(localized: "On request")
    }
}

private struct RPFeatureCollection: Decodable {
    let features: [Feature]

    struct Feature: Decodable {
        let properties: Properties
        let geometry: Geometry
    }
    struct Properties: Decodable {
        let oaipId: String
        let name: String?
        let compulsory: Bool?
        let elevation: MeasuredValue?
        let remarks: String?
        enum CodingKeys: String, CodingKey {
            case oaipId = "_id"
            case name, compulsory, elevation, remarks
        }
    }
    struct Geometry: Decodable { let coordinates: [Double] }

    /// OpenAIP `{value, unit, ...}` measure. `unit == 0` is meters; else feet.
    struct MeasuredValue: Decodable {
        let value: Double
        let unit: Int
        var asFeetMSL: Int { unit == 0 ? Int((value * 3.28084).rounded()) : Int(value.rounded()) }
    }
}
