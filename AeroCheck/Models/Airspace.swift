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

// MARK: - Airspace Profile Block

/// One airspace as it appears on the route-profile cross-section: the along-track distance band it
/// spans (NM) and its vertical band (ft MSL), plus whether the route actually conflicts with it
/// (within ± a separation buffer) or merely passes it horizontally while clearing it vertically
/// ("context", drawn faded). (flight-plan revamp #4 redesign)
///
/// A limit in ft AGL or a flight level has no single height in ft MSL (see `AirspaceVerticalBand`),
/// so the block carries the band sample by sample (`outline`) and, when the route may be inside it
/// only because such a limit could not be pinned down, why (`verticalUncertainty`). Such a block is
/// a conflict too: never reported clear on a guess. (APP-11)
struct AirspaceProfileBlock: Identifiable {
    /// The vertical band at one sample of the route, ft MSL.
    struct BandPoint: Equatable {
        let nm: Double
        /// Drawn band: the best figure there is (see `AirspaceVerticalBand.drawnFloorFt`).
        let floorFt: Double
        let ceilingFt: Double
        /// The furthest the limits can really be: lowest floor, highest ceiling (infinite for an AGL
        /// ceiling over unknown terrain).
        let outerFloorFt: Double
        let outerCeilingFt: Double
    }

    let airspace: Airspace
    let startNM: Double
    let endNM: Double
    /// The drawn band over the whole span: lowest floor, highest ceiling.
    let floorFt: Double
    let ceilingFt: Double
    let isConflict: Bool
    /// The band per sample inside the footprint, in route order. An AGL limit follows the ground, so
    /// its top is not a straight line.
    var outline: [BandPoint] = []
    /// Non-empty when the block is a conflict ONLY because a limit could not be pinned down (ft AGL
    /// over unknown terrain, a flight level with no QNH): the route may be inside, or not.
    var verticalUncertainty: Set<AirspaceVerticalUncertainty> = []

    var id: String { airspace.id }
    var isVerticallyUncertain: Bool { !verticalUncertainty.isEmpty }
    /// The furthest the band can reach over the span (the ceiling may be infinite).
    var outerFloorFt: Double { outline.map(\.outerFloorFt).min() ?? floorFt }
    var outerCeilingFt: Double { outline.map(\.outerCeilingFt).max() ?? ceilingFt }
}

// MARK: - Vertical band at a point of a route

/// Why an airspace's vertical band at a point cannot be pinned down in feet MSL.
enum AirspaceVerticalUncertainty: Hashable {
    /// A limit in ft AGL over ground the app has no elevation for.
    case terrainUnknown
    /// A flight level: where it sits on a QNH altimeter depends on the day's QNH.
    case flightLevel
}

/// One vertical limit resolved to feet MSL at a point of a route.
struct ResolvedAltitudeLimit: Equatable {
    /// Lowest and highest the limit can really be here. `high` is infinite for an AGL limit over
    /// unknown terrain.
    let low: Double
    let high: Double
    /// The figure a planned altitude is compared with, nil when there is none to give (AGL over
    /// unknown terrain).
    let nominal: Double?
    /// Set when `low` and `high` are apart for want of data.
    let uncertainty: AirspaceVerticalUncertainty?
}

/// An airspace's vertical band at one point of a route, as far as the data allows and no further.
///
/// Only a limit in feet MSL compares directly with a planned altitude:
/// - a limit in ft AGL follows the ground: terrain + value where the terrain is known; where it is
///   not, anywhere from `value` ft MSL (ground at sea level) upwards;
/// - a flight level is FL × 100 ft on 1013.25 hPa, and the app has no QNH for the time of a planned
///   flight, so it can sit `AltitudeLimit.flightLevelUncertaintyFt` either side of that.
///
/// Reading either as feet MSL is what put routes above a 2000 ft AGL ceiling drawn at 2000 ft MSL,
/// over ground at 1400 ft. `verdict` says `.possiblyInside` wherever the answer hangs on a limit
/// that could not be pinned down, and callers must show that, never clear it. (APP-11, restores
/// the fail-safe PERF-08 had put in the old AirspaceAnalyzer)
struct AirspaceVerticalBand: Equatable {
    let floor: ResolvedAltitudeLimit
    let ceiling: ResolvedAltitudeLimit

    /// `terrainFt`: lowest and highest ground around the point, ft MSL, nil where unknown.
    init(_ airspace: Airspace, terrainFt: ClosedRange<Double>?) {
        floor = airspace.lowerCeiling.resolved(as: .floor, terrainFt: terrainFt)
        ceiling = airspace.upperCeiling.resolved(as: .ceiling, terrainFt: terrainFt)
    }

    enum Verdict: Equatable {
        case inside
        /// Inside if a limit the app could not pin down falls the wrong way, and why.
        case possiblyInside(Set<AirspaceVerticalUncertainty>)
        case outside
    }

    /// Where a planned altitude (ft MSL) stands against the band, within ± `bufferFt`.
    func verdict(altitudeFt alt: Double, bufferFt: Double = 0) -> Verdict {
        // Each limit on its own: surely on the airspace's side of it, maybe, or surely not.
        let overFloor: Bool? = floor.nominal.map { alt + bufferFt >= $0 } == true ? true
            : (alt + bufferFt >= floor.low ? nil : false)
        let underCeiling: Bool? = ceiling.nominal.map { alt - bufferFt <= $0 } == true ? true
            : (alt - bufferFt <= ceiling.high ? nil : false)
        if overFloor == false || underCeiling == false { return .outside }
        if overFloor == true && underCeiling == true { return .inside }
        var why: Set<AirspaceVerticalUncertainty> = []
        if overFloor == nil, let u = floor.uncertainty { why.insert(u) }
        if underCeiling == nil, let u = ceiling.uncertainty { why.insert(u) }
        return .possiblyInside(why)
    }

    /// The band as drawn: the nominal figure where there is one, else the lowest the limit can be
    /// (an AGL limit over unknown terrain is at least its value above sea level).
    var drawnFloorFt: Double { floor.nominal ?? floor.low }
    var drawnCeilingFt: Double { ceiling.nominal ?? ceiling.low }
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

    /// The value in feet, with NO datum applied: metres converted, a flight level × 100.
    ///
    /// Only an MSL limit comes out as feet MSL. "2000 ft GND" comes out as 2000, which is too low
    /// by the height of the ground: as a ceiling, that clears routes that are inside the airspace.
    /// A flight level comes out on 1013.25 hPa. Compare limits with a planned altitude through
    /// `resolved(as:terrainFt:)` / `AirspaceVerticalBand`, never through this. (APP-11)
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
        return feetValue
    }

    /// How far a flight level can sit from FL × 100 ft on a QNH altimeter. 1000 ft is 37 hPa at
    /// 27 ft/hPa, i.e. any QNH from 976 to 1050 hPa. The app has no QNH for the time of a planned
    /// flight, so a flight-level limit is only known to within this. (APP-11)
    static let flightLevelUncertaintyFt: Double = 1000

    enum Role { case floor, ceiling }

    /// This limit in feet MSL at one point of a route, for comparing with a planned altitude.
    ///
    /// `terrainFt` is the lowest and highest ground around the point, nil where unknown. An AGL
    /// limit takes the lowest ground as a floor and the highest as a ceiling, so it errs on the side
    /// of a bigger airspace between terrain samples. "GND" (0 ft AGL) stays 0: a floor at the
    /// surface is below anything flying, and a planned altitude a few feet under a terrain sample
    /// must not put the route outside a CTR it departs from. (APP-11)
    func resolved(as role: Role, terrainFt: ClosedRange<Double>?) -> ResolvedAltitudeLimit {
        let feet = asFeetMSL
        // Pressure-referenced: FL × 100 on 1013.25 hPa, QNH unknown.
        if unit == 6 || referenceDatum == 2 {
            let margin = Self.flightLevelUncertaintyFt
            return ResolvedAltitudeLimit(low: feet - margin, high: feet + margin, nominal: feet,
                                         uncertainty: .flightLevel)
        }
        // Above the ground: needs the terrain under the point.
        if referenceDatum == 0 && value != 0 {
            guard let terrain = terrainFt else {
                return ResolvedAltitudeLimit(low: feet, high: .infinity, nominal: nil, uncertainty: .terrainUnknown)
            }
            let low = terrain.lowerBound + feet, high = terrain.upperBound + feet
            return ResolvedAltitudeLimit(low: low, high: high, nominal: role == .floor ? low : high,
                                         uncertainty: nil)
        }
        // MSL, or the ground itself.
        return ResolvedAltitudeLimit(low: feet, high: feet, nominal: feet, uncertainty: nil)
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
