import Foundation
import CoreLocation

// MARK: - Airport Type

/// Type of airport from OurAirports data
enum AirportType: String, Codable, CaseIterable {
    case largeAirport = "large_airport"
    case mediumAirport = "medium_airport"
    case smallAirport = "small_airport"
    case heliport = "heliport"
    case seaplaneBase = "seaplane_base"
    case closed = "closed"
    case balloonport = "balloonport"

    /// SF Symbol name for map display
    var iconName: String {
        switch self {
        case .largeAirport:
            return "airplane.circle.fill"
        case .mediumAirport:
            return "airplane.circle"
        case .smallAirport:
            return "airplane"
        case .heliport:
            return "helm"
        case .seaplaneBase:
            return "drop.circle"
        case .closed:
            return "xmark.circle"
        case .balloonport:
            return "balloon"
        }
    }

    /// Whether this type should be shown by default
    var shownByDefault: Bool {
        switch self {
        case .largeAirport, .mediumAirport, .smallAirport:
            return true
        case .heliport, .seaplaneBase, .closed, .balloonport:
            return false
        }
    }
}

// MARK: - Airport

/// An airport from the OurAirports database
struct Airport: Codable, Identifiable, Equatable {
    let id: Int                     // OurAirports ID
    let ident: String               // ICAO code (e.g., "LSZH")
    let type: AirportType
    let name: String
    let latitude: Double
    let longitude: Double
    let elevation: Int?             // feet
    let continent: String?
    let isoCountry: String
    let isoRegion: String
    let municipality: String?
    let scheduledService: Bool
    let gpsCode: String?
    let iataCode: String?
    let localCode: String?

    /// CLLocationCoordinate2D for MapKit
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Display name with ICAO code
    var displayName: String {
        "\(name) (\(ident))"
    }

    /// Distance from a given coordinate in nautical miles
    func distance(from coordinate: CLLocationCoordinate2D) -> Double {
        let location1 = CLLocation(latitude: latitude, longitude: longitude)
        let location2 = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let distanceMeters = location1.distance(from: location2)
        return distanceMeters / 1852.0 // Convert meters to nautical miles
    }
}

// MARK: - Airport Frequency

/// A radio frequency for an airport
struct AirportFrequency: Codable, Identifiable, Equatable {
    let id: Int
    let airportRef: Int             // Foreign key to Airport.id
    let airportIdent: String        // ICAO code
    let type: String                // ATIS, TWR, GND, APP, DEP, etc.
    let description: String?
    let frequencyMhz: Double

    /// Formatted frequency string (e.g., "118.100")
    var formattedFrequency: String {
        String(format: "%.3f", frequencyMhz)
    }

    /// Display string with type and frequency
    var displayString: String {
        if let desc = description, !desc.isEmpty {
            return "\(type): \(formattedFrequency) - \(desc)"
        }
        return "\(type): \(formattedFrequency)"
    }
}

// MARK: - Runway

/// A runway at an airport
struct Runway: Codable, Identifiable, Equatable {
    let id: Int
    let airportRef: Int             // Foreign key to Airport.id
    let airportIdent: String        // ICAO code
    let lengthFt: Int?
    let widthFt: Int?
    let surface: String?
    let lighted: Bool
    let closed: Bool

    // Low-end (LE) runway designation (e.g., "09")
    let leIdent: String?
    let leLatitude: Double?
    let leLongitude: Double?
    let leElevationFt: Int?
    let leHeadingDegT: Double?
    let leDisplacedThresholdFt: Int?

    // High-end (HE) runway designation (e.g., "27")
    let heIdent: String?
    let heLatitude: Double?
    let heLongitude: Double?
    let heElevationFt: Int?
    let heHeadingDegT: Double?
    let heDisplacedThresholdFt: Int?

    /// Combined runway identifier (e.g., "09/27")
    var identifier: String {
        let le = leIdent ?? "?"
        let he = heIdent ?? "?"
        return "\(le)/\(he)"
    }

    /// Length in meters
    var lengthMeters: Int? {
        guard let ft = lengthFt else { return nil }
        return Int(Double(ft) * 0.3048)
    }

    /// Width in meters
    var widthMeters: Int? {
        guard let ft = widthFt else { return nil }
        return Int(Double(ft) * 0.3048)
    }

    /// Description string (e.g., "1200m x 30m - Asphalt - Lighted")
    var descriptionString: String {
        var parts: [String] = []

        if let length = lengthMeters, let width = widthMeters {
            parts.append("\(length)m x \(width)m")
        } else if let length = lengthMeters {
            parts.append("\(length)m")
        }

        if let surf = surface, !surf.isEmpty {
            parts.append(surf.capitalized)
        }

        if lighted {
            parts.append("Lighted")
        }

        if closed {
            parts.append("CLOSED")
        }

        return parts.joined(separator: " - ")
    }

    /// Calculate headwind/crosswind components for given wind
    /// - Parameters:
    ///   - windDirection: Wind direction in degrees (from)
    ///   - windSpeed: Wind speed in knots
    ///   - useHighEnd: Whether to use high-end runway heading
    /// - Returns: (headwind, crosswind) components in knots (positive = headwind/right crosswind)
    func windComponents(windDirection: Double, windSpeed: Double, useHighEnd: Bool) -> (headwind: Double, crosswind: Double)? {
        let runwayHeading: Double?
        if useHighEnd {
            runwayHeading = heHeadingDegT
        } else {
            runwayHeading = leHeadingDegT
        }

        guard let heading = runwayHeading else { return nil }

        // Calculate relative wind angle
        let relativeAngle = (windDirection - heading) * .pi / 180.0

        let headwind = windSpeed * cos(relativeAngle)
        let crosswind = windSpeed * sin(relativeAngle)

        return (headwind: headwind, crosswind: crosswind)
    }
}

// MARK: - CSV Parsing Extensions

extension Airport {
    /// Parse from OurAirports CSV row
    /// Expected columns: id,ident,type,name,latitude_deg,longitude_deg,elevation_ft,continent,iso_country,iso_region,municipality,scheduled_service,gps_code,iata_code,local_code,home_link,wikipedia_link,keywords
    init?(csvRow: [String: String]) {
        guard let idStr = csvRow["id"], let id = Int(idStr),
              let ident = csvRow["ident"],
              let typeStr = csvRow["type"],
              let name = csvRow["name"],
              let latStr = csvRow["latitude_deg"], let lat = Double(latStr),
              let lonStr = csvRow["longitude_deg"], let lon = Double(lonStr),
              let isoCountry = csvRow["iso_country"],
              let isoRegion = csvRow["iso_region"] else {
            return nil
        }

        self.id = id
        self.ident = ident
        self.type = AirportType(rawValue: typeStr) ?? .smallAirport
        self.name = name
        self.latitude = lat
        self.longitude = lon
        self.elevation = csvRow["elevation_ft"].flatMap { Int($0) }
        self.continent = csvRow["continent"]
        self.isoCountry = isoCountry
        self.isoRegion = isoRegion
        self.municipality = csvRow["municipality"]
        self.scheduledService = csvRow["scheduled_service"] == "yes"
        self.gpsCode = csvRow["gps_code"]
        self.iataCode = csvRow["iata_code"]
        self.localCode = csvRow["local_code"]
    }
}

extension AirportFrequency {
    /// Parse from OurAirports CSV row
    /// Expected columns: id,airport_ref,airport_ident,type,description,frequency_mhz
    init?(csvRow: [String: String]) {
        guard let idStr = csvRow["id"], let id = Int(idStr),
              let airportRefStr = csvRow["airport_ref"], let airportRef = Int(airportRefStr),
              let airportIdent = csvRow["airport_ident"],
              let type = csvRow["type"],
              let freqStr = csvRow["frequency_mhz"], let freq = Double(freqStr) else {
            return nil
        }

        self.id = id
        self.airportRef = airportRef
        self.airportIdent = airportIdent
        self.type = type
        self.description = csvRow["description"]
        self.frequencyMhz = freq
    }
}

extension Runway {
    /// Parse from OurAirports CSV row
    /// Expected columns: id,airport_ref,airport_ident,length_ft,width_ft,surface,lighted,closed,le_ident,le_latitude_deg,le_longitude_deg,le_elevation_ft,le_heading_degT,le_displaced_threshold_ft,he_ident,he_latitude_deg,he_longitude_deg,he_elevation_ft,he_heading_degT,he_displaced_threshold_ft
    init?(csvRow: [String: String]) {
        guard let idStr = csvRow["id"], let id = Int(idStr),
              let airportRefStr = csvRow["airport_ref"], let airportRef = Int(airportRefStr),
              let airportIdent = csvRow["airport_ident"] else {
            return nil
        }

        self.id = id
        self.airportRef = airportRef
        self.airportIdent = airportIdent
        self.lengthFt = csvRow["length_ft"].flatMap { Int($0) }
        self.widthFt = csvRow["width_ft"].flatMap { Int($0) }
        self.surface = csvRow["surface"]
        self.lighted = csvRow["lighted"] == "1"
        self.closed = csvRow["closed"] == "1"

        self.leIdent = csvRow["le_ident"]
        self.leLatitude = csvRow["le_latitude_deg"].flatMap { Double($0) }
        self.leLongitude = csvRow["le_longitude_deg"].flatMap { Double($0) }
        self.leElevationFt = csvRow["le_elevation_ft"].flatMap { Int($0) }
        self.leHeadingDegT = csvRow["le_heading_degT"].flatMap { Double($0) }
        self.leDisplacedThresholdFt = csvRow["le_displaced_threshold_ft"].flatMap { Int($0) }

        self.heIdent = csvRow["he_ident"]
        self.heLatitude = csvRow["he_latitude_deg"].flatMap { Double($0) }
        self.heLongitude = csvRow["he_longitude_deg"].flatMap { Double($0) }
        self.heElevationFt = csvRow["he_elevation_ft"].flatMap { Int($0) }
        self.heHeadingDegT = csvRow["he_heading_degT"].flatMap { Double($0) }
        self.heDisplacedThresholdFt = csvRow["he_displaced_threshold_ft"].flatMap { Int($0) }
    }
}

// MARK: - MapKit Annotation Support

import MapKit

/// Annotation for displaying airports on the map
class AirportAnnotation: NSObject, MKAnnotation {
    let airport: Airport

    init(airport: Airport) {
        self.airport = airport
        super.init()
    }

    var coordinate: CLLocationCoordinate2D {
        airport.coordinate
    }

    var title: String? {
        airport.ident
    }

    var subtitle: String? {
        airport.name
    }
}
