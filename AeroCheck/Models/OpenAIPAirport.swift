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

/// A single runway DIRECTION from an OpenAIP airport (OpenAIP lists each end separately, e.g. "10" and
/// "28"). The `AirportDataMergeEngine` pairs opposite directions into one OurAirports-shaped `Runway`.
/// (v4.1.0 runway merge)
struct OpenAIPRunway: Codable, Equatable {
    let designator: String          // e.g. "10", "16L"
    let trueHeading: Double?
    let mainRunway: Bool
    let surfaceLabel: String?       // mapped from the composition code
    let pcn: String?
    let lengthFeet: Int?
    let widthFeet: Int?
    let toraFeet: Int?              // this direction's declared TORA/LDA (feet)
    let ldaFeet: Int?
    let lighted: Bool
}

/// Best-effort mapping of OpenAIP runway surface `composition`/`mainComposite` codes to a display string.
enum OpenAIPRunwaySurface {
    static func label(for code: Int?) -> String? {
        guard let code else { return nil }
        switch code {
        case 0: return "Asphalt"
        case 1: return "Concrete"
        case 2: return "Grass"
        case 3: return "Sand"
        case 4: return "Water"
        case 5: return "Bituminous"
        case 6: return "Brick"
        case 7: return "Macadam"
        case 8: return "Stone"
        case 9: return "Coral"
        case 10: return "Clay"
        case 11: return "Laterite"
        case 12: return "Gravel"
        case 13: return "Earth"
        case 14: return "Ice"
        case 15: return "Snow"
        case 17: return "Metal"
        case 18: return "Landing mat"
        case 19: return "Pierced steel planking"
        case 20: return "Wood"
        default: return nil
        }
    }
}

/// OpenAIP's `services.fuelTypes` integer enum.
///
/// OpenAIP does not publish this ordering anywhere citable, so it was established twice, from
/// independent directions, and the two agree:
///
///  1. **Label pairing.** LSGY and LSZB return `[0,1,3]` and their OpenAIP page lists AVGAS,
///     Super PLUS and Jet A1; LSZQ and LSGL return `[1,3,6]` and list AVGAS, AVGAS UL91 and Jet A1.
///     The sets differ in exactly one code and one label, which pins `0 = Super PLUS` and
///     `6 = AVGAS UL91`, leaving `{1,3} = {AVGAS, Jet A1}`.
///  2. **Airline hubs settle the rest.** Frankfurt (EDDF) and Paris CDG (LFPG) both return `[3]`
///     alone. A major hub sells jet fuel and no piston fuel, so `3 = Jet A1`, and therefore
///     `1 = AVGAS`.
///
/// Both results match the documented value set (Super PLUS, AVGAS, Jet A, Jet A1, Jet B, Diesel,
/// AVGAS UL91) read in order, which is the third agreement.
///
/// Note this settles the CODES, not the per-aerodrome DATA: OpenAIP is community-maintained and
/// claims Jet A1 at several grass fields that certainly do not sell it. Treat a chip as "OpenAIP
/// says so", the same community provenance `DataStatusManager` already assigns this source.
enum OpenAIPFuelType: Int, CaseIterable, Sendable {
    case superPlus = 0
    case avgas = 1
    case jetA = 2
    case jetA1 = 3
    case jetB = 4
    case diesel = 5
    case avgasUL91 = 6

    /// Fuel grades are trade names and deliberately NOT localized, like the aviation abbreviations
    /// elsewhere in the app.
    var label: String {
        switch self {
        case .superPlus:  return "Super PLUS"
        case .avgas:      return "AVGAS"
        case .jetA:       return "Jet A"
        case .jetA1:      return "Jet A1"
        case .jetB:       return "Jet B"
        case .diesel:     return "Diesel"
        case .avgasUL91:  return "UL91"
        }
    }

    /// True for the grades an aircraft in this app's roster can actually burn. Used for ordering,
    /// not filtering — a pilot scanning chips wants "can I get AVGAS here" answered first, but
    /// hiding the rest would be the app deciding what they may see.
    var isPistonGrade: Bool {
        switch self {
        case .avgas, .avgasUL91, .superPlus: return true
        case .jetA, .jetA1, .jetB, .diesel:  return false
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
    let runways: [OpenAIPRunway]
    let latitude: Double
    let longitude: Double

    // MARK: - Operational flags (v5.0.0)
    //
    // These four are plain booleans carried at the top level of the OpenAIP record and were being
    // dropped on the floor: a Codable struct silently ignores unknown keys, so they arrived with
    // every download and never reached the app. `ppr` is the one the flight thread needs — a
    // destination that requires prior permission gets its own task instead of the pilot having to
    // remember which fields are PPR.

    /// Prior permission required before landing.
    let isPPR: Bool
    /// Private field: permission needed even to be there, not merely to land.
    let isPrivate: Bool
    let hasSkydiveActivity: Bool
    let isWinchOnly: Bool

    /// Raw `services.fuelTypes` codes. Kept alongside the mapped values so an unrecognised future
    /// code is preserved rather than silently dropped.
    let fuelTypeCodes: [Int]

    /// Fuel grades this aerodrome reports, piston grades first — see `OpenAIPFuelType` for how the
    /// enum was established. Unknown codes are skipped rather than guessed at.
    var fuelTypes: [OpenAIPFuelType] {
        fuelTypeCodes
            .compactMap(OpenAIPFuelType.init(rawValue:))
            .sorted { lhs, rhs in
                lhs.isPistonGrade == rhs.isPistonGrade
                    ? lhs.rawValue < rhs.rawValue
                    : lhs.isPistonGrade && !rhs.isPistonGrade
            }
    }

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
        // SEC-C16: same plausibility clamp as the OurAirports parse — this value reaches the
        // same AGL thresholds after AirportDataMergeEngine folds the two sources together.
        self.elevationFeetMSL = (p.elevation?.asFeetMSL ?? nil)
            .flatMap { PlausibleRange.fieldElevationFeet.contains(Double($0)) ? $0 : nil }
        self.magneticDeclination = p.magneticDeclination
        self.country = p.country
        self.frequencies = (p.frequencies ?? []).map {
            OpenAIPFrequency(name: $0.name, value: $0.value, typeRaw: $0.type)
        }
        self.runways = (p.runways ?? []).compactMap { rwy in
            guard let designator = rwy.designator, !designator.isEmpty else { return nil }
            return OpenAIPRunway(
                designator: designator,
                trueHeading: rwy.trueHeading,
                mainRunway: rwy.mainRunway ?? false,
                surfaceLabel: OpenAIPRunwaySurface.label(for: rwy.surface?.mainComposite),
                pcn: rwy.surface?.pcn,
                lengthFeet: rwy.dimension?.length?.asFeet,
                widthFeet: rwy.dimension?.width?.asFeet,
                toraFeet: rwy.declaredDistance?.tora?.asFeet,
                ldaFeet: rwy.declaredDistance?.lda?.asFeet,
                lighted: rwy.pilotCtrlLighting ?? false
            )
        }
        // Absent flags mean "not stated", which for an advisory prompt is the same as false: a
        // missing `ppr` must not manufacture a PPR task the field does not require.
        self.isPPR = p.ppr ?? false
        self.isPrivate = p.private ?? false
        self.hasSkydiveActivity = p.skydiveActivity ?? false
        self.isWinchOnly = p.winchOnly ?? false
        self.fuelTypeCodes = p.services?.fuelTypes ?? []
        self.longitude = feature.geometry.coordinates[0]   // GeoJSON is [lon, lat]
        self.latitude = feature.geometry.coordinates[1]
    }
}

/// Wraps a `Decodable` element so a single malformed element in an array decodes to `nil` instead of
/// aborting the whole array decode. The element boundary is still consumed (the wrapper's own decode
/// always succeeds), so per-feature failures are skipped rather than throwing. (v4.1.0 pre-tag fix)
private struct FailableDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Wrapped.self)
    }
}

private struct AirportFeatureCollection: Decodable {
    let features: [Feature]

    // Lossy per-feature decode: one malformed airport feature must be SKIPPED, not abort the whole
    // country (OpenAIP is now the primary airport provider, so one bad feature would drop every airport
    // for that country). (v4.1.0 pre-tag fix)
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
        let icaoCode: String?
        let type: Int
        let elevation: MeasuredValue?
        let magneticDeclination: Double?
        let country: String?
        let frequencies: [FrequencyJSON]?
        let runways: [RunwayJSON]?
        // v5.0.0: operational flags + services. All optional — the keyless GeoJSON export and the
        // core REST API carry slightly different subsets, and an older cached file has none of them.
        let ppr: Bool?
        let `private`: Bool?
        let skydiveActivity: Bool?
        let winchOnly: Bool?
        let services: ServicesJSON?
        enum CodingKeys: String, CodingKey {
            case oaipId = "_id"
            case name, icaoCode, type, elevation, magneticDeclination, country, frequencies, runways
            case ppr, `private`, skydiveActivity, winchOnly, services
        }
    }
    struct ServicesJSON: Decodable {
        let fuelTypes: [Int]?
    }
    struct FrequencyJSON: Decodable {
        let name: String?
        let value: String
        let type: Int
    }
    struct RunwayJSON: Decodable {
        let designator: String?
        let trueHeading: Double?
        let mainRunway: Bool?
        let surface: SurfaceJSON?
        let dimension: DimensionJSON?
        let declaredDistance: DeclaredDistanceJSON?
        let pilotCtrlLighting: Bool?
    }
    struct SurfaceJSON: Decodable {
        let mainComposite: Int?
        let pcn: String?
    }
    struct DimensionJSON: Decodable {
        let length: MeasuredValue?
        let width: MeasuredValue?
    }
    struct DeclaredDistanceJSON: Decodable {
        let tora: MeasuredValue?
        let toda: MeasuredValue?
        let asda: MeasuredValue?
        let lda: MeasuredValue?
    }
    struct Geometry: Decodable { let coordinates: [Double] }

    struct MeasuredValue: Decodable {
        let value: Double
        let unit: Int
        // unit 0 = metres → feet; unit 1 = already feet. (Same convention as elevation.)
        //
        // SEC-C14: `Int(x.rounded())` TRAPS — kills the process, uncatchably — on a non-finite or
        // out-of-range Double. These values come from OpenAIP's unauthenticated public GeoJSON
        // export, and the trip-aware prefetch that reads it runs while airborne, so one bad
        // feature took the whole app down. Returning nil instead lets the caller drop the single
        // offending feature, which is what the surrounding parse already does for other bad rows.
        private var asFeetValue: Int? {
            let feet = unit == 0 ? value * 3.28084 : value
            return feet.safeRoundedInt()
        }
        var asFeetMSL: Int? { asFeetValue }
        var asFeet: Int? { asFeetValue }
    }
}
