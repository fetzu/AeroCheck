import Foundation
import CoreLocation

// MARK: - Airport Type

/// Type of airport from OurAirports data
enum AirportType: String, Codable, CaseIterable, Sendable {
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

    /// Airport types relevant to fixed-wing flight planning. The flight-plan builder filters its map
    /// and search results to this set so heliports, seaplane bases, balloonports and closed fields
    /// don't clutter route building. To support rotorcraft later, add `.heliport` here (and to the
    /// builder's map-type filter in `FlightPlanMapBuilderView`). See CLAUDE.md "Re-enabling heliports".
    static let fixedWing: Set<AirportType> = [.largeAirport, .mediumAirport, .smallAirport]
}

// MARK: - Airport

/// An airport from the OurAirports database
struct Airport: Codable, Identifiable, Equatable, Sendable {
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
struct AirportFrequency: Codable, Identifiable, Equatable, Sendable {
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
struct Runway: Codable, Identifiable, Equatable, Sendable {
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

    // Richer data available from OpenAIP (nil for OurAirports runways). Additive optionals → cached
    // OurAirports records (encoded without these keys) decode as nil, so no migration. Declared
    // distances are PER-DIRECTION (TORA/LDA for the LE end differ from the HE end). (v4.1.0 runway merge)
    let pcn: String?                // Pavement Classification Number, e.g. "35/F/B/X/T" (shared pavement)
    let leToraFt: Int?              // Take-off run / landing distance available, LE end (feet)
    let leLdaFt: Int?
    let heToraFt: Int?              // HE end
    let heLdaFt: Int?

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

    /// Declared distances line (feet). Collapses to one value when both ends match, else labels per end.
    /// e.g. "TORA 1120 · LDA 1120 ft" or "10 TORA 1120 LDA 1120 · 28 TORA 1300 LDA 1300 ft". Nil if none.
    var declaredDistancesString: String? {
        func line(_ tora: Int?, _ lda: Int?) -> String? {
            var p: [String] = []
            if let t = tora { p.append("TORA \(t)") }
            if let l = lda { p.append("LDA \(l)") }
            return p.isEmpty ? nil : p.joined(separator: " · ")
        }
        let le = line(leToraFt, leLdaFt)
        let he = line(heToraFt, heLdaFt)
        switch (le, he) {
        case let (l?, r?) where l == r: return "\(l) ft"
        case let (l?, r?): return "\(leIdent ?? "LE") \(l) · \(heIdent ?? "HE") \(r) ft"
        case let (l?, nil): return "\(l) ft"
        case let (nil, r?): return "\(r) ft"
        default: return nil
        }
    }

    /// Secondary briefing line combining the OpenAIP-only extras (PCN + declared distances), or nil.
    /// Abbreviations (PCN/TORA/LDA…) are ICAO-standard and shown verbatim in every language.
    var extraInfoLine: String? {
        var parts: [String] = []
        if let pcn, !pcn.isEmpty { parts.append("PCN \(pcn)") }
        if let dd = declaredDistancesString { parts.append(dd) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

        // OurAirports CSV has no PCN / declared distances — those come from OpenAIP.
        self.pcn = nil
        self.leToraFt = nil
        self.leLdaFt = nil
        self.heToraFt = nil
        self.heLdaFt = nil
    }
}

// MARK: - MapKit Annotation Support

import MapKit

/// Annotation for displaying airports on the map
class AirportAnnotation: NSObject, MKAnnotation {
    let airport: Airport
    let frequencyLines: String?

    init(airport: Airport, frequencyLines: String? = nil) {
        self.airport = airport
        self.frequencyLines = frequencyLines
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
