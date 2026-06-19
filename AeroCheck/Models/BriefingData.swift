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

    // Wind data (if available)
    let currentWind: WindData?

    /// Wind data structure
    struct WindData {
        let direction: Double  // Degrees
        let speed: Double      // Knots
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
            currentWind: nil
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
        windDirection: Double? = nil,
        windSpeed: Double? = nil,
        destinationIdent: String? = nil
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
                suggestedDepartureRunway = service.suggestRunway(for: airport, windDirection: windDirection)
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
                suggestedArrivalRunway = service.suggestRunway(for: airport, windDirection: windDirection)
            }
        }

        // Nearby VFR reporting points around each field (OpenAIP, v4.1.0). Empty when the layer isn't
        // downloaded; the briefing UI hides the section in that case.
        let rpService = OpenAIPReportingPointDataService.shared
        let departureReportingPoints = departureAirport
            .map { rpService.reportingPointsNear(to: $0.coordinate, maxDistanceNm: 8, limit: 6) } ?? []
        let destinationReportingPoints = destinationAirport
            .map { rpService.reportingPointsNear(to: $0.coordinate, maxDistanceNm: 8, limit: 6) } ?? []

        // Build wind data if available
        var windData: BriefingContext.WindData?
        if let direction = windDirection, let speed = windSpeed {
            windData = BriefingContext.WindData(direction: direction, speed: speed)
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
            currentWind: windData
        )
    }
}
