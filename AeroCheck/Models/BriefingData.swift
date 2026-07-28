import Foundation
import CoreLocation

// MARK: - Aircraft Speeds

/// Parsed aircraft speeds for briefing display
struct AircraftSpeeds {
    let vs: Int?    // Stall clean
    let vso: Int?   // Stall landing config
    let vr: Int?    // Rotation
    let vx: Int?    // Best angle climb
    let vy: Int?    // Best rate climb
    let vbg: Int?   // Best glide
    let vfe: Int?   // Max flap extended
    let vapp: Int?  // Initial approach speed
    let vfinal: Int? // Final approach speed

    /// Initialize from SpeedReference array (local checklist format)
    init(from speeds: [SpeedReference]) {
        // Parse speeds by name (case-insensitive matching)
        var vsValue: Int?
        var vsoValue: Int?
        var vrValue: Int?
        var vxValue: Int?
        var vyValue: Int?
        var vbgValue: Int?
        var vfeValue: Int?
        var vappValue: Int?
        var vfinalValue: Int?

        for speed in speeds {
            let name = speed.name.lowercased()
            // Extract numeric value from speed.value (handles "70" or "60-55")
            let numericValue = Int(speed.value.components(separatedBy: CharacterSet.decimalDigits.inverted).first ?? "")

            switch name {
            case "vs":
                vsValue = numericValue
            case "vso":
                vsoValue = numericValue
            case "vr":
                vrValue = numericValue
            case "vx":
                vxValue = numericValue
            case "vy":
                vyValue = numericValue
            case "vbg":
                vbgValue = numericValue
            case "vfe":
                vfeValue = numericValue
            case "vapp":
                // Take the first Vapp entry (usually initial approach)
                if vappValue == nil {
                    vappValue = numericValue
                }
            case "vfinal":
                vfinalValue = numericValue
            default:
                break
            }
        }

        self.vs = vsValue
        self.vso = vsoValue
        self.vr = vrValue
        self.vx = vxValue
        self.vy = vyValue
        self.vbg = vbgValue
        self.vfe = vfeValue
        self.vapp = vappValue
        self.vfinal = vfinalValue
    }

    /// Empty speeds (for when no checklist is available)
    static let empty = AircraftSpeeds(from: [])
}

// MARK: - Briefing Phase

/// Type of briefing being displayed
enum BriefingPhase {
    case departure
    case approach
}

// MARK: - Briefing Context

/// Complete context for rendering a briefing view
struct BriefingContext {
    let aircraftRegistration: String
    let aircraftType: String
    let speeds: AircraftSpeeds
    let hasParachute: Bool

    // Departure info
    let departureAirport: Airport?
    let departureRunways: [Runway]
    let suggestedDepartureRunway: Runway?

    // Destination info
    let destinationAirport: Airport?
    let destinationRunways: [Runway]
    let suggestedArrivalRunway: Runway?

    // Nearby VFR reporting points (OpenAIP, v4.1.0) — empty when the layer isn't downloaded
    let departureReportingPoints: [ReportingPoint]
    let destinationReportingPoints: [ReportingPoint]

    // Departure procedure derived from the active flight plan's first leg (nil with no plan).
    let departureInitialTrack: Double?      // first-leg magnetic course (departure → first fix)
    let departureFirstFix: String?          // name of the first en-route waypoint
    let departureCruiseAltitude: Int?       // planned cruise altitude (feet)

    /// The briefing wind, WITH its provenance.
    ///
    /// Was a bare `(direction, speed)` pair, which was safe only while there was exactly one
    /// source. With three of quite different authority — an aerodrome METAR, a MeteoSwiss station,
    /// and a model grid cell — a value that has lost track of where it came from can be shown to a
    /// pilot with more confidence than it earns. `BriefingWind` keeps the two together.
    let currentWind: BriefingWind?

    /// Aerodrome forecast for the field this briefing is about, when one exists.
    ///
    /// Most GA fields have no TAF at all, so absence is the normal case and the row simply does not
    /// render. The RAW text is carried deliberately: pilots read a TAF in its native form, and any
    /// prose rendering is a paraphrase that can be wrong in ways the original cannot.
    let taf: TafSummary?

    struct TafSummary: Equatable {
        let icao: String
        let issuedAt: Date?
        let validFrom: Date?
        let validTo: Date?
        let raw: String

        /// `"issued 2325Z, valid 00-06"` — the qualifier, in the same value-then-provenance shape
        /// the wind row uses.
        var validity: String {
            let z = DateFormatter()
            z.dateFormat = "HHmm"
            z.timeZone = TimeZone(identifier: "UTC")
            let hour = DateFormatter()
            hour.dateFormat = "HH"
            hour.timeZone = TimeZone(identifier: "UTC")

            var parts: [String] = []
            if let issuedAt { parts.append("issued \(z.string(from: issuedAt))Z") }
            if let validFrom, let validTo {
                parts.append("valid \(hour.string(from: validFrom))-\(hour.string(from: validTo))")
            }
            return parts.joined(separator: ", ")
        }
    }

    /// Field elevation at departure (feet)
    var departureElevation: Int? {
        departureAirport?.elevation
    }

    /// Empty context for when no data is available
    static func empty(aircraftRegistration: String = "Unknown", aircraftType: String = "Unknown") -> BriefingContext {
        BriefingContext(
            aircraftRegistration: aircraftRegistration,
            aircraftType: aircraftType,
            speeds: .empty,
            hasParachute: false,
            departureAirport: nil,
            departureRunways: [],
            suggestedDepartureRunway: nil,
            destinationAirport: nil,
            destinationRunways: [],
            suggestedArrivalRunway: nil,
            departureReportingPoints: [],
            destinationReportingPoints: [],
            departureInitialTrack: nil,
            departureFirstFix: nil,
            departureCruiseAltitude: nil,
            currentWind: nil,
            taf: nil
        )
    }
}

// MARK: - Briefing Context Builder

/// Builder for creating BriefingContext from available data sources
struct BriefingContextBuilder {

    /// Build briefing context from current app state
    @MainActor
    static func build(
        speeds: [SpeedReference],
        hasParachute: Bool,
        aircraftRegistration: String,
        aircraftType: String,
        currentLocation: CLLocationCoordinate2D?,
        airportDataService: AirportDataService?,
        wind: BriefingWind? = nil,
        taf: BriefingContext.TafSummary? = nil,
        destinationIdent: String? = nil,
        flightPlan: FlightPlan? = nil
    ) -> BriefingContext {
        // Parse speeds
        let aircraftSpeeds = AircraftSpeeds(from: speeds)

        // Find departure airport (nearest to current location)
        var departureAirport: Airport?
        var departureRunways: [Runway] = []
        var suggestedDepartureRunway: Runway?

        if let location = currentLocation, let service = airportDataService {
            let nearestAirports = service.findNearestAirports(to: location, limit: 1, maxDistanceNm: 5.0)
            departureAirport = nearestAirports.first

            if let airport = departureAirport {
                departureRunways = service.getRunways(for: airport.ident).filter { !$0.closed }
                // nil for a variable wind: with no direction there is no favoured runway, and
                // inventing one is worse than offering none.
                suggestedDepartureRunway = service.suggestRunway(
                    for: airport, windDirection: wind?.directionDeg.map(Double.init)
                )
            }
        }

        // Find destination airport
        var destinationAirport: Airport?
        var destinationRunways: [Runway] = []
        var suggestedArrivalRunway: Runway?

        if let service = airportDataService {
            if let destIdent = destinationIdent {
                // Use specified destination
                destinationAirport = service.findAirport(byIdent: destIdent)
            } else {
                // Default to departure airport if no destination specified
                destinationAirport = departureAirport
            }

            if let airport = destinationAirport {
                destinationRunways = service.getRunways(for: airport.ident).filter { !$0.closed }
                suggestedArrivalRunway = service.suggestRunway(
                    for: airport, windDirection: wind?.directionDeg.map(Double.init)
                )
            }
        }

        // Nearby VFR reporting points around each field (OpenAIP, v4.1.0). Empty when the layer isn't
        // downloaded; the briefing UI hides the section in that case.
        let rpService = OpenAIPReportingPointDataService.shared
        let departureReportingPoints = departureAirport
            .map { rpService.reportingPointsNear(to: $0.coordinate, maxDistanceNm: 8, limit: 6) } ?? []
        let destinationReportingPoints = destinationAirport
            .map { rpService.reportingPointsNear(to: $0.coordinate, maxDistanceNm: 8, limit: 6) } ?? []

        // Departure procedure from the active flight plan's first leg + planned cruise altitude.
        // `magneticCourse` on a waypoint is the course TO the next one, so the first leg = waypoints[0].
        var departureInitialTrack: Double?
        var departureFirstFix: String?
        var departureCruiseAltitude: Int?
        if let plan = flightPlan, plan.waypoints.count >= 2 {
            departureInitialTrack = plan.waypoints.first?.magneticCourse
            departureFirstFix = plan.waypoints.dropFirst().first?.name
            departureCruiseAltitude = plan.waypoints.dropFirst().dropLast()
                .compactMap { $0.altitude }.first.map { Int($0) }
        }


        return BriefingContext(
            aircraftRegistration: aircraftRegistration,
            aircraftType: aircraftType,
            speeds: aircraftSpeeds,
            hasParachute: hasParachute,
            departureAirport: departureAirport,
            departureRunways: departureRunways,
            suggestedDepartureRunway: suggestedDepartureRunway,
            destinationAirport: destinationAirport,
            destinationRunways: destinationRunways,
            suggestedArrivalRunway: suggestedArrivalRunway,
            departureReportingPoints: departureReportingPoints,
            destinationReportingPoints: destinationReportingPoints,
            departureInitialTrack: departureInitialTrack,
            departureFirstFix: departureFirstFix,
            departureCruiseAltitude: departureCruiseAltitude,
            currentWind: wind,
            taf: taf
        )
    }
}
