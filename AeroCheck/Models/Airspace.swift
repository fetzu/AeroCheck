import Foundation
import CoreLocation
import MapKit

// MARK: - Airspace Frequency

/// A radio frequency associated with an airspace from OpenAIP
struct AirspaceFrequency: Codable {
    let value: String       // Frequency MHz as string (e.g., "118.100")
    let name: String?       // Callsign (e.g., "ZUERICH TOWER") — optional, some airspaces omit this
    let primary: Bool
    let unit: Int?
}

// MARK: - Airspace Model

/// Represents an airspace region from OpenAIP
struct Airspace: Codable, Identifiable {
    let id: String
    let name: String
    let type: Int                        // OpenAIP airspace type code
    let icaoClass: Int?                  // OpenAIP ICAO class code (0-8)
    let country: String                  // ISO alpha-2 country code
    let upperCeiling: AltitudeLimit
    let lowerCeiling: AltitudeLimit
    let geometry: AirspaceGeometry
    let activity: Int?                   // Activity type code
    let frequencies: [AirspaceFrequency]? // Radio frequencies (e.g., tower freq for CTRs)

    /// Decoded polygon coordinates for map rendering. Memoized ONCE at decode time (PR-11): this was
    /// a computed property that re-decoded + re-validated the GeoJSON ring on every access — once per
    /// render and per spatial query, for every airspace on screen.
    let polygonCoordinates: [CLLocationCoordinate2D]

    /// Precomputed lat/lon bounding box (nil when the ring is empty). Lets bounds/contains queries
    /// reject an airspace without iterating its coordinate ring. (PR-11)
    let boundingBox: AirspaceBoundingBox?

    // OpenAIP API returns _id, upperLimit, lowerLimit
    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name, type, icaoClass, country, geometry, activity, frequencies
        case upperCeiling = "upperLimit"
        case lowerCeiling = "lowerLimit"
    }

    init(id: String, name: String, type: Int, icaoClass: Int?, country: String,
         upperCeiling: AltitudeLimit, lowerCeiling: AltitudeLimit, geometry: AirspaceGeometry,
         activity: Int?, frequencies: [AirspaceFrequency]?) {
        self.id = id
        self.name = name
        self.type = type
        self.icaoClass = icaoClass
        self.country = country
        self.upperCeiling = upperCeiling
        self.lowerCeiling = lowerCeiling
        self.geometry = geometry
        self.activity = activity
        self.frequencies = frequencies
        let coords = Self.decodePolygon(from: geometry)
        self.polygonCoordinates = coords
        self.boundingBox = AirspaceBoundingBox(coordinates: coords)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            type: try c.decode(Int.self, forKey: .type),
            icaoClass: try c.decodeIfPresent(Int.self, forKey: .icaoClass),
            country: try c.decode(String.self, forKey: .country),
            upperCeiling: try c.decode(AltitudeLimit.self, forKey: .upperCeiling),
            lowerCeiling: try c.decode(AltitudeLimit.self, forKey: .lowerCeiling),
            geometry: try c.decode(AirspaceGeometry.self, forKey: .geometry),
            activity: try c.decodeIfPresent(Int.self, forKey: .activity),
            frequencies: try c.decodeIfPresent([AirspaceFrequency].self, forKey: .frequencies)
        )
    }

    /// Decode + validate the first ring of the GeoJSON geometry into coordinates.
    /// GeoJSON uses [longitude, latitude] order. PR-04: a position array with fewer than 2 elements
    /// (or NaN/out-of-range values) is valid JSON but traps on subscript — validate count and range
    /// at this single choke point so malformed network/cache data can never crash the airspace paths.
    static func decodePolygon(from geometry: AirspaceGeometry) -> [CLLocationCoordinate2D] {
        guard let firstRing = geometry.coordinates.first else { return [] }
        return firstRing.compactMap { pair in
            guard pair.count >= 2, GeoValidation.isValidLatLon(pair[1], pair[0]) else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
    }

    /// Human-readable airspace type
    var airspaceType: AirspaceTypeCategory {
        AirspaceTypeCategory(rawValue: type) ?? .other
    }

    /// Human-readable ICAO class
    var airspaceClass: AirspaceClassCategory? {
        guard let icaoClass else { return nil }
        return AirspaceClassCategory(rawValue: icaoClass)
    }

    /// Color for map rendering based on type and class
    var mapColor: (red: Double, green: Double, blue: Double) {
        // Prioritize type for restricted/prohibited/danger
        switch airspaceType {
        case .prohibited:
            return (0.85, 0.1, 0.1)    // Red
        case .restricted:
            return (0.85, 0.2, 0.2)    // Red
        case .danger:
            return (0.9, 0.5, 0.1)     // Orange
        case .ctr:
            return (0.2, 0.4, 0.9)     // Blue
        case .tma, .cta:
            // Color by class
            switch airspaceClass {
            case .classA: return (0.2, 0.2, 0.9)   // Blue
            case .classB: return (0.2, 0.4, 0.9)   // Blue
            case .classC: return (0.0, 0.7, 0.7)   // Cyan
            case .classD: return (0.7, 0.2, 0.7)   // Magenta
            case .classE: return (0.2, 0.7, 0.3)   // Green
            default: return (0.5, 0.5, 0.5)        // Gray
            }
        case .tmz:
            return (0.5, 0.5, 0.5)     // Gray
        case .rmz:
            return (0.3, 0.3, 0.8)     // Light blue
        case .fir, .uir:
            return (0.4, 0.4, 0.4)     // Dark gray
        case .wave:
            return (0.2, 0.7, 0.3)     // Green
        case .gliderSector:
            return (0.2, 0.8, 0.2)     // Bright green
        default:
            // Fall back to class-based coloring
            switch airspaceClass {
            case .classA: return (0.2, 0.2, 0.9)
            case .classB: return (0.2, 0.4, 0.9)
            case .classC: return (0.0, 0.7, 0.7)
            case .classD: return (0.7, 0.2, 0.7)
            case .classE: return (0.2, 0.7, 0.3)
            case .classF: return (0.5, 0.5, 0.3)
            case .classG: return (0.5, 0.5, 0.5)
            default: return (0.5, 0.5, 0.5)
            }
        }
    }

    /// Display string for the airspace type and class
    var typeDisplayString: String {
        let typeStr = airspaceType.displayName
        if let cls = airspaceClass {
            return "\(typeStr) (Class \(cls.letter))"
        }
        return typeStr
    }

    /// Whether this airspace is considered restrictive (requires clearance or avoidance)
    var isRestrictive: Bool {
        switch airspaceType {
        case .prohibited, .restricted, .danger:
            return true
        default:
            return false
        }
    }

    /// Check if a given altitude (feet MSL) is within this airspace's vertical limits
    func containsAltitude(_ altitudeFeetMSL: Double) -> Bool {
        let lower = lowerCeiling.asFeetMSL
        let upper = upperCeiling.asFeetMSL
        return altitudeFeetMSL >= lower && altitudeFeetMSL <= upper
    }

    /// True if either vertical limit can't be precisely compared against an MSL altitude
    /// without terrain/QNH data (AGL or FL referenced). Used to fail safe: such an airspace
    /// is never silently ruled out vertically — the pilot is asked to verify. (PERF-08)
    var altitudeIsUncertain: Bool {
        lowerCeiling.isDatumUncertain || upperCeiling.isDatumUncertain
    }

    /// Check if a coordinate falls within this airspace's polygon using ray casting algorithm
    func containsPoint(_ point: CLLocationCoordinate2D) -> Bool {
        // Fast reject via the precomputed bounding box before the O(n) ray cast. (PR-11)
        if let box = boundingBox, !box.contains(point) { return false }
        let polygon = polygonCoordinates
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].longitude, yi = polygon[i].latitude
            let xj = polygon[j].longitude, yj = polygon[j].latitude
            if ((yi > point.latitude) != (yj > point.latitude)) &&
                (point.longitude < (xj - xi) * (point.latitude - yi) / (yj - yi) + xi) {
                inside = !inside
            }
            j = i
        }
        return inside
    }

    /// Primary radio frequency for this airspace (e.g., tower frequency for CTRs)
    var primaryFrequency: AirspaceFrequency? {
        frequencies?.first(where: { $0.primary }) ?? frequencies?.first
    }

    /// Whether this is a military airspace (HX suffix in OpenAIP naming)
    var isMilitary: Bool {
        name.contains("(HX)")
    }

    /// Clean display name, stripping the airspace type prefix (e.g., "CTR ZURICH" → "ZURICH")
    var shortName: String {
        let prefixes = ["CTR ", "TMA ", "CTA ", "ATZ "]
        for prefix in prefixes {
            if name.hasPrefix(prefix) {
                return String(name.dropFirst(prefix.count))
            }
        }
        return name
    }

    /// Centroid coordinate of the airspace polygon
    var centroid: CLLocationCoordinate2D? {
        let coords = polygonCoordinates
        guard !coords.isEmpty else { return nil }
        let avgLat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
        let avgLon = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
        return CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
    }

    /// Altitude range display string (e.g., "GND → 4500 ft MSL")
    var altitudeRangeString: String {
        "\(lowerCeiling.displayString) → \(upperCeiling.displayString)"
    }
}

// MARK: - Airspace Bounding Box

/// Axis-aligned lat/lon bounding box of an airspace ring, precomputed once so bounds/contains
/// queries can reject without walking the coordinate ring. (PR-11)
struct AirspaceBoundingBox: Equatable {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    init?(coordinates: [CLLocationCoordinate2D]) {
        guard let first = coordinates.first else { return nil }
        var minLa = first.latitude, maxLa = first.latitude
        var minLo = first.longitude, maxLo = first.longitude
        for c in coordinates.dropFirst() {
            minLa = Swift.min(minLa, c.latitude); maxLa = Swift.max(maxLa, c.latitude)
            minLo = Swift.min(minLo, c.longitude); maxLo = Swift.max(maxLo, c.longitude)
        }
        minLat = minLa; maxLat = maxLa; minLon = minLo; maxLon = maxLo
    }

    func contains(_ p: CLLocationCoordinate2D) -> Bool {
        p.latitude >= minLat && p.latitude <= maxLat && p.longitude >= minLon && p.longitude <= maxLon
    }

    /// Whether this box overlaps the given lat/lon ranges (a visible map region).
    func intersects(latRange: ClosedRange<Double>, lonRange: ClosedRange<Double>) -> Bool {
        maxLat >= latRange.lowerBound && minLat <= latRange.upperBound &&
        maxLon >= lonRange.lowerBound && minLon <= lonRange.upperBound
    }
}

// MARK: - Airspace Geometry

struct AirspaceGeometry: Codable {
    let type: String                     // "Polygon"
    let coordinates: [[[Double]]]        // Array of rings, each ring is array of [lon, lat] pairs
}

// MARK: - Altitude Limit

struct AltitudeLimit: Codable {
    let value: Int
    let unit: Int                        // 0 = M, 1 = FT, 6 = FL (OpenAIP schema)
    let referenceDatum: Int              // 0 = GND, 1 = MSL, 2 = STD

    /// Convert to feet MSL for comparison (approximate for GND reference)
    var asFeetMSL: Double {
        let feetValue: Double
        switch unit {
        case 0: // Meters (OpenAIP unit code 0)
            feetValue = Double(value) * 3.28084
        case 6: // Flight Level (OpenAIP unit code 6)
            feetValue = Double(value) * 100
        default: // Feet (OpenAIP unit code 1, and fallback)
            feetValue = Double(value)
        }

        // For GND (AGL) reference, we can't convert to MSL without terrain data.
        // Return the raw feet value as an approximation — for a lower limit of
        // "0 ft GND" this correctly returns 0, and for non-zero AGL values this
        // is a reasonable conservative estimate.
        // STD (standard pressure) is effectively MSL for comparison purposes.
        return feetValue
    }

    /// True when converting this limit to MSL is only approximate without external data:
    /// a flight level (needs QNH) or an AGL value above ground (needs terrain elevation).
    /// A 0 ft / GND lower limit is treated as certain (ground ≈ 0 ft MSL for our purposes).
    var isDatumUncertain: Bool {
        if unit == 6 { return true }                          // Flight level — needs QNH
        if referenceDatum == 0 && value != 0 { return true }  // AGL above ground — needs terrain
        return false
    }

    /// Human-readable display string
    var displayString: String {
        switch unit {
        case 0: // Meters
            let datum = referenceDatum == 0 ? "AGL" : "MSL"
            return "\(value) m \(datum)"
        case 6: // Flight Level
            return "FL \(value)"
        default: // Feet
            if value == 0 && referenceDatum == 0 {
                return "GND"
            }
            let datum = referenceDatum == 0 ? "AGL" : "MSL"
            return "\(value) ft \(datum)"
        }
    }
}

// MARK: - Airspace Type Categories

/// OpenAIP airspace type codes
enum AirspaceTypeCategory: Int, Codable {
    case other = 0
    case restricted = 1
    case danger = 2
    case prohibited = 3
    case ctr = 4
    case tmz = 5
    case rmz = 6
    case tma = 7          // Terminal Maneuvering Area
    case tra = 8          // Temporary Reserved Area
    case tsa = 9          // Temporary Segregated Area
    case fir = 10         // Flight Information Region
    case uir = 11         // Upper Information Region
    case adiz = 12        // Air Defense Identification Zone
    case atz = 13         // Aerodrome Traffic Zone
    case matz = 14        // Military ATZ
    case airway = 15
    case mtr = 16         // Military Training Route
    case alertArea = 17
    case warningArea = 18
    case protectedArea = 19
    case htz = 20         // Helicopter Traffic Zone
    case gliderSector = 21
    case trp = 22         // Transponder Mandatory Zone
    case tiz = 23         // Traffic Information Zone
    case tia = 24         // Traffic Information Area
    case mta = 25         // Military Training Area
    case cta = 26         // Control Area
    case acc = 27         // Area Control Center
    case aerial = 28      // Aerial Sporting/Recreational
    case lowAltitude = 29
    case mrt = 30         // Military Route
    case tsaTemp = 31     // TSA Temporary
    case traTemp = 32     // TRA Temporary
    case wave = 33        // Mountain Wave
    case interditP = 34   // Interdit (Prohibited)
    case interditR = 35   // Interdit (Restricted)

    var displayName: String {
        switch self {
        case .other: return "Other"
        case .restricted: return "R - Restricted"
        case .danger: return "D - Danger"
        case .prohibited: return "P - Prohibited"
        case .ctr: return "CTR"
        case .tmz: return "TMZ"
        case .rmz: return "RMZ"
        case .tma: return "TMA"
        case .tra: return "TRA"
        case .tsa: return "TSA"
        case .fir: return "FIR"
        case .uir: return "UIR"
        case .adiz: return "ADIZ"
        case .atz: return "ATZ"
        case .matz: return "MATZ"
        case .airway: return "Airway"
        case .mtr: return "MTR"
        case .alertArea: return "Alert"
        case .warningArea: return "Warning"
        case .protectedArea: return "Protected"
        case .htz: return "HTZ"
        case .gliderSector: return "Glider Sector"
        case .trp: return "TRP"
        case .tiz: return "TIZ"
        case .tia: return "TIA"
        case .mta: return "MTA"
        case .cta: return "CTA"
        case .acc: return "ACC"
        case .aerial: return "Aerial"
        case .lowAltitude: return "Low Altitude"
        case .mrt: return "MRT"
        case .tsaTemp: return "TSA (Temp)"
        case .traTemp: return "TRA (Temp)"
        case .wave: return "Wave"
        case .interditP: return "P - Interdit"
        case .interditR: return "R - Interdit"
        }
    }
}

// MARK: - ICAO Airspace Class

/// OpenAIP ICAO class codes
enum AirspaceClassCategory: Int, Codable {
    case classA = 0
    case classB = 1
    case classC = 2
    case classD = 3
    case classE = 4
    case classF = 5
    case classG = 6
    case sus = 7          // Special Use
    case unclassified = 8

    var letter: String {
        switch self {
        case .classA: return "A"
        case .classB: return "B"
        case .classC: return "C"
        case .classD: return "D"
        case .classE: return "E"
        case .classF: return "F"
        case .classG: return "G"
        case .sus: return "SUA"
        case .unclassified: return "-"
        }
    }
}

// MARK: - OpenAIP API Response Types

/// Wrapper for paginated OpenAIP API responses
struct OpenAIPResponse<T: Codable>: Codable {
    let totalCount: Int
    let totalPages: Int
    let limit: Int
    let page: Int
    let items: [T]
}

/// Airspace data cache metadata
struct OpenAIPCacheMetadata: Codable {
    var lastSyncDates: [String: Date]    // Country code → last sync date
    var airspaceCounts: [String: Int]     // Country code → count
    var lastFullRefresh: Date?

    init() {
        lastSyncDates = [:]
        airspaceCounts = [:]
    }
}

// MARK: - Airspace Conflict (for flight planning)

/// Represents a conflict between a flight plan route and an airspace
struct AirspaceConflict: Identifiable {
    let id = UUID()
    let airspace: Airspace
    let legIndex: Int                    // Which leg of the flight plan
    let conflictType: ConflictType
    let plannedAltitude: Double?         // Feet MSL, if available
    /// True when vertical overlap could not be confirmed precisely (AGL/FL limits, or no
    /// planned altitude) — the pilot must verify the vertical separation manually. (PERF-08)
    var altitudeUncertain: Bool = false

    enum ConflictType {
        case transit                     // Route passes through airspace
        case proximity                   // Route passes near boundary (< 1 NM)

        var displayString: String {
            switch self {
            case .transit: return "Route crosses airspace"
            case .proximity: return "Route near airspace boundary"
            }
        }
    }

    /// Severity level for display
    var severity: ConflictSeverity {
        if airspace.isRestrictive {
            return .high
        }
        switch conflictType {
        case .transit: return .medium
        case .proximity: return .low
        }
    }

    enum ConflictSeverity {
        case high    // Prohibited/Restricted
        case medium  // Transit through controlled airspace
        case low     // Near boundary
    }
}
