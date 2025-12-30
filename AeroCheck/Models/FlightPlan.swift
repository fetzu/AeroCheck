import Foundation
import CoreLocation

// MARK: - Flight Plan Waypoint

/// A waypoint in a flight plan route
struct FlightPlanWaypoint: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String                          // User-editable name (e.g., "LSZQ", "JORAT VOR")
    var latitude: Double                      // Stored separately for Codable compliance
    var longitude: Double
    var altitude: Double?                     // Planned altitude in feet (user-editable)
    var frequency: String?                    // Radio frequency if applicable
    var callSign: String?                     // Callsign/identifier
    var remarks: String                       // User notes

    // Leg data (to next waypoint)
    var magneticCourse: Double?              // Computed MC to next waypoint (degrees)
    var distance: Double?                    // Distance to next waypoint in NM
    var plannedGroundSpeed: Int?             // User-editable GS for this leg (knots)
    var windDirection: Double?               // Wind direction (degrees, from)
    var windSpeed: Double?                   // Wind speed (knots)
    var estimatedElapsedTime: TimeInterval?  // EET - leg time to next waypoint (minutes)
    var legEETExtra: TimeInterval?           // Extra time to add (+5 min for first/last waypoint)
    var cumulativeEET: TimeInterval?         // Cumulative EET from departure to this waypoint
    var estimatedTimeOver: Date?             // ETO - estimated time over this waypoint
    var actualTimeOver: Date?                // ATO - actual time over (recorded during flight)

    init(
        id: UUID = UUID(),
        name: String = "",
        coordinate: CLLocationCoordinate2D,
        altitude: Double? = nil,
        frequency: String? = nil,
        callSign: String? = nil,
        remarks: String = "",
        magneticCourse: Double? = nil,
        distance: Double? = nil,
        plannedGroundSpeed: Int? = nil,
        windDirection: Double? = nil,
        windSpeed: Double? = nil,
        estimatedElapsedTime: TimeInterval? = nil,
        legEETExtra: TimeInterval? = nil,
        cumulativeEET: TimeInterval? = nil,
        estimatedTimeOver: Date? = nil,
        actualTimeOver: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.altitude = altitude
        self.frequency = frequency
        self.callSign = callSign
        self.remarks = remarks
        self.magneticCourse = magneticCourse
        self.distance = distance
        self.plannedGroundSpeed = plannedGroundSpeed
        self.windDirection = windDirection
        self.windSpeed = windSpeed
        self.estimatedElapsedTime = estimatedElapsedTime
        self.legEETExtra = legEETExtra
        self.cumulativeEET = cumulativeEET
        self.estimatedTimeOver = estimatedTimeOver
        self.actualTimeOver = actualTimeOver
    }

    /// CLLocationCoordinate2D representation
    var coordinate: CLLocationCoordinate2D {
        get { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
        set {
            latitude = newValue.latitude
            longitude = newValue.longitude
        }
    }

    /// Formatted coordinate string (e.g., "46°56'N 7°09'E")
    var formattedCoordinate: String {
        let latDirection = latitude >= 0 ? "N" : "S"
        let lonDirection = longitude >= 0 ? "E" : "W"

        let latDegrees = Int(abs(latitude))
        let latMinutes = Int((abs(latitude) - Double(latDegrees)) * 60)

        let lonDegrees = Int(abs(longitude))
        let lonMinutes = Int((abs(longitude) - Double(lonDegrees)) * 60)

        return String(format: "%d°%02d'%@ %d°%02d'%@",
                     latDegrees, latMinutes, latDirection,
                     lonDegrees, lonMinutes, lonDirection)
    }

    /// Formatted EET string (e.g., "15" for 15 minutes, "15 + 5" for first/last waypoints)
    var formattedEET: String? {
        let hasLegEET = estimatedElapsedTime != nil && estimatedElapsedTime! > 0
        let hasExtra = legEETExtra != nil && legEETExtra! > 0

        if !hasLegEET && !hasExtra {
            return nil
        }

        let minutes = hasLegEET ? Int(estimatedElapsedTime! / 60) : 0

        // Check if there's extra time (+5 min for first/last waypoint)
        if hasExtra {
            let extraMinutes = Int(legEETExtra! / 60)
            if hasLegEET {
                return "\(minutes) + \(extraMinutes)"
            } else {
                // Last waypoint - only show +5
                return "+ \(extraMinutes)"
            }
        }

        return "\(minutes)"
    }

    /// Total EET including extra time (for calculations)
    var totalLegEET: TimeInterval {
        return (estimatedElapsedTime ?? 0) + (legEETExtra ?? 0)
    }

    /// Formatted ETO string (e.g., "14:35")
    var formattedETO: String? {
        guard let eto = estimatedTimeOver else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: eto)
    }

    /// Formatted ATO string (e.g., "14:37")
    var formattedATO: String? {
        guard let ato = actualTimeOver else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: ato)
    }

    static func == (lhs: FlightPlanWaypoint, rhs: FlightPlanWaypoint) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Flight Type

/// Type of flight for the flight plan
enum FlightType: String, Codable, CaseIterable, Identifiable {
    case vfr = "VFR"
    case training = "Training"
    case local = "Local"
    case crossCountry = "Cross-Country"
    case checkFlight = "Check Flight"

    var id: String { rawValue }
}

// MARK: - Flight Plan

/// A complete flight plan with route, fuel, and timing information
struct FlightPlan: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var waypoints: [FlightPlanWaypoint]
    var aircraftType: AircraftType
    var aircraftRegistration: String

    // Crew information
    var pilot: String
    var instructor: String?

    // Flight details
    var flightType: FlightType
    var runwayInUse: String?
    var plannedDepartureTime: Date?
    var announcementDate: Date?              // Date de l'annonce
    var announcementTime: Date?              // Heure de l'annonce

    // Fuel planning
    var fuelFlow: Double?                    // L/h
    var tripFuel: Double?                    // Liters
    var reserveFuel: Double?                 // Alternate fuel (liters)
    var additionalFuel: Double?              // 45-minute reserve (liters)
    var extraFuel: Double?                   // Extra fuel (liters)
    var fuelOnBoard: Double?                 // Total FOB (liters)

    // Timing (Hobbs/Tach)
    var blockOff: Date?                      // Block time off
    var timeOff: Date?                       // Takeoff time
    var timeOn: Date?                        // Landing time
    var blockOn: Date?                       // Block time on
    var counterStart: Double?                // Hobbs/Tach start
    var counterStop: Double?                 // Hobbs/Tach stop
    var landingsAtBase: Int?                 // Landings at home airport
    var totalLandings: Int?                  // Total landings

    // Notes
    var remarks: String
    var debriefing: String

    // Metadata
    var createdAt: Date
    var updatedAt: Date

    // Active flight tracking
    var isActive: Bool
    var currentWaypointIndex: Int
    var chronometerStartTime: Date?

    init(
        id: UUID = UUID(),
        name: String = "",
        waypoints: [FlightPlanWaypoint] = [],
        aircraftType: AircraftType = .wt9Dynamic,
        aircraftRegistration: String? = nil,
        pilot: String = "",
        instructor: String? = nil,
        flightType: FlightType = .vfr,
        runwayInUse: String? = nil,
        plannedDepartureTime: Date? = nil,
        announcementDate: Date? = nil,
        announcementTime: Date? = nil,
        fuelFlow: Double? = nil,
        tripFuel: Double? = nil,
        reserveFuel: Double? = nil,
        additionalFuel: Double? = nil,
        extraFuel: Double? = nil,
        fuelOnBoard: Double? = nil,
        blockOff: Date? = nil,
        timeOff: Date? = nil,
        timeOn: Date? = nil,
        blockOn: Date? = nil,
        counterStart: Double? = nil,
        counterStop: Double? = nil,
        landingsAtBase: Int? = nil,
        totalLandings: Int? = nil,
        remarks: String = "",
        debriefing: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isActive: Bool = false,
        currentWaypointIndex: Int = 0,
        chronometerStartTime: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.waypoints = waypoints
        self.aircraftType = aircraftType
        self.aircraftRegistration = aircraftRegistration ?? aircraftType.registration
        self.pilot = pilot
        self.instructor = instructor
        self.flightType = flightType
        self.runwayInUse = runwayInUse
        self.plannedDepartureTime = plannedDepartureTime
        self.announcementDate = announcementDate
        self.announcementTime = announcementTime
        self.fuelFlow = fuelFlow
        self.tripFuel = tripFuel
        self.reserveFuel = reserveFuel
        self.additionalFuel = additionalFuel
        self.extraFuel = extraFuel
        self.fuelOnBoard = fuelOnBoard
        self.blockOff = blockOff
        self.timeOff = timeOff
        self.timeOn = timeOn
        self.blockOn = blockOn
        self.counterStart = counterStart
        self.counterStop = counterStop
        self.landingsAtBase = landingsAtBase
        self.totalLandings = totalLandings
        self.remarks = remarks
        self.debriefing = debriefing
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isActive = isActive
        self.currentWaypointIndex = currentWaypointIndex
        self.chronometerStartTime = chronometerStartTime
    }

    // MARK: - Computed Properties

    /// Total route distance in nautical miles
    var totalDistance: Double {
        waypoints.compactMap { $0.distance }.reduce(0, +)
    }

    /// Total estimated elapsed time (cumulative EET to final waypoint)
    var totalEET: TimeInterval {
        guard let lastWaypoint = waypoints.last,
              let cumulativeEET = lastWaypoint.cumulativeEET else {
            return 0
        }
        return cumulativeEET
    }

    /// Formatted total EET
    var formattedTotalEET: String {
        let hours = Int(totalEET) / 3600
        let minutes = (Int(totalEET) % 3600) / 60
        return String(format: "%d:%02d", hours, minutes)
    }

    /// Fuel required (trip + reserve + additional + extra)
    var fuelRequired: Double? {
        guard let trip = tripFuel else { return nil }
        let reserve = reserveFuel ?? 0
        // Use 45-minute fuel reserve (0.75 hours of fuel flow) as default if not set
        let additional = additionalFuel ?? (fuelFlow ?? FlightPlan.defaultFuelFlow(for: aircraftType)) * 0.75
        let extra = extraFuel ?? 0
        return trip + reserve + additional + extra
    }

    /// Endurance in hours based on FOB and fuel flow
    var endurance: Double? {
        guard let fob = fuelOnBoard, let flow = fuelFlow, flow > 0 else { return nil }
        return fob / flow
    }

    /// Formatted endurance string
    var formattedEndurance: String? {
        guard let endurance = endurance else { return nil }
        let hours = Int(endurance)
        let minutes = Int((endurance - Double(hours)) * 60)
        return String(format: "%d:%02d", hours, minutes)
    }

    /// Default fuel flow based on aircraft type
    static func defaultFuelFlow(for aircraftType: AircraftType) -> Double {
        switch aircraftType {
        case .wt9Dynamic: return 20.0  // L/h
        case .pa28Archer: return 40.0  // L/h
        }
    }

    /// Default cruise speed based on aircraft type
    static func defaultCruiseSpeed(for aircraftType: AircraftType) -> Int {
        switch aircraftType {
        case .wt9Dynamic: return 100  // knots
        case .pa28Archer: return 110  // knots
        }
    }

    /// Next waypoint (if any remain)
    var nextWaypoint: FlightPlanWaypoint? {
        guard currentWaypointIndex < waypoints.count else { return nil }
        return waypoints[currentWaypointIndex]
    }

    /// Previous waypoint (if any)
    var previousWaypoint: FlightPlanWaypoint? {
        guard currentWaypointIndex > 0 else { return nil }
        return waypoints[currentWaypointIndex - 1]
    }

    /// Progress through waypoints (0.0 to 1.0)
    var progress: Double {
        guard !waypoints.isEmpty else { return 0 }
        return Double(currentWaypointIndex) / Double(waypoints.count)
    }

    static func == (lhs: FlightPlan, rhs: FlightPlan) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Route Calculations

    /// Calculate magnetic course and distance between consecutive waypoints
    mutating func calculateRouteData() {
        guard waypoints.count >= 2 else { return }

        // Magnetic declination for Switzerland (approximately 2° East as of 2024)
        let magneticDeclination = 2.0

        // Extra time to add to first and last waypoint (5 minutes = 300 seconds)
        let extraTimeForTerminalWaypoints: TimeInterval = 300

        var cumulativeEETTotal: TimeInterval = 0

        for i in 0..<waypoints.count {
            if i < waypoints.count - 1 {
                let from = waypoints[i].coordinate
                let to = waypoints[i + 1].coordinate

                // Calculate distance
                let fromLocation = CLLocation(latitude: from.latitude, longitude: from.longitude)
                let toLocation = CLLocation(latitude: to.latitude, longitude: to.longitude)
                let distanceMeters = fromLocation.distance(from: toLocation)
                let distanceNM = distanceMeters / 1852.0
                waypoints[i].distance = distanceNM

                // Calculate true course
                let trueCourse = calculateBearing(from: from, to: to)

                // Convert to magnetic course
                let magneticCourse = (trueCourse - magneticDeclination + 360).truncatingRemainder(dividingBy: 360)
                waypoints[i].magneticCourse = magneticCourse

                // Calculate EET for this leg (time to next waypoint only)
                let groundSpeed = waypoints[i].plannedGroundSpeed ?? FlightPlan.defaultCruiseSpeed(for: aircraftType)
                var legEET: TimeInterval = 0
                if groundSpeed > 0 {
                    let legTimeHours = distanceNM / Double(groundSpeed)
                    legEET = legTimeHours * 3600
                }
                waypoints[i].estimatedElapsedTime = legEET

                // Add +5 minutes to first waypoint (departure)
                if i == 0 {
                    waypoints[i].legEETExtra = extraTimeForTerminalWaypoints
                } else {
                    waypoints[i].legEETExtra = nil
                }

                // Calculate cumulative EET
                cumulativeEETTotal += legEET + (waypoints[i].legEETExtra ?? 0)
                waypoints[i].cumulativeEET = cumulativeEETTotal
            } else {
                // Last waypoint - no distance/course to next
                waypoints[i].distance = nil
                waypoints[i].magneticCourse = nil
                waypoints[i].estimatedElapsedTime = nil

                // Add +5 minutes to last waypoint (arrival)
                waypoints[i].legEETExtra = extraTimeForTerminalWaypoints
                cumulativeEETTotal += extraTimeForTerminalWaypoints
                waypoints[i].cumulativeEET = cumulativeEETTotal
            }

            // Calculate ETO if departure time is set (based on cumulative EET)
            if let departureTime = plannedDepartureTime {
                waypoints[i].estimatedTimeOver = departureTime.addingTimeInterval(waypoints[i].cumulativeEET ?? 0)
            }
        }

        // Calculate trip fuel based on total time
        if let flow = fuelFlow ?? FlightPlan.defaultFuelFlow(for: aircraftType) as Double? {
            let tripTimeHours = totalEET / 3600
            tripFuel = tripTimeHours * flow
        }

        updatedAt = Date()
    }

    /// Calculate bearing between two coordinates (in degrees, 0-360)
    private func calculateBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        var bearing = atan2(y, x) * 180 / .pi
        bearing = (bearing + 360).truncatingRemainder(dividingBy: 360)

        return bearing
    }
}

// MARK: - Flight Plan Export/Import

extension FlightPlan {
    /// Export flight plan to GPX format
    func toGPX() -> String {
        let dateFormatter = ISO8601DateFormatter()

        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="AeroCheck"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xmlns:ac="http://aerocheck.app/gpx/1"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>\(escapeXML(name))</name>
            <desc>Flight plan created with AeroCheck</desc>
        """

        if let departureTime = plannedDepartureTime {
            gpx += "\n    <time>\(dateFormatter.string(from: departureTime))</time>"
        }

        gpx += """

          </metadata>
          <rte>
            <name>\(escapeXML(name))</name>
            <extensions>
              <ac:flightPlan>
                <ac:pilot>\(escapeXML(pilot))</ac:pilot>
        """

        if let instructor = instructor {
            gpx += "\n        <ac:instructor>\(escapeXML(instructor))</ac:instructor>"
        }

        gpx += """

                <ac:aircraftType>\(aircraftType.rawValue)</ac:aircraftType>
                <ac:aircraftRegistration>\(escapeXML(aircraftRegistration))</ac:aircraftRegistration>
                <ac:flightType>\(flightType.rawValue)</ac:flightType>
        """

        if let runway = runwayInUse {
            gpx += "\n        <ac:runway>\(escapeXML(runway))</ac:runway>"
        }

        if let fuelFlow = fuelFlow {
            gpx += "\n        <ac:fuelFlow>\(fuelFlow)</ac:fuelFlow>"
        }

        if let fob = fuelOnBoard {
            gpx += "\n        <ac:fuelOnBoard>\(fob)</ac:fuelOnBoard>"
        }

        if !remarks.isEmpty {
            gpx += "\n        <ac:remarks><![CDATA[\(remarks)]]></ac:remarks>"
        }

        gpx += """

              </ac:flightPlan>
            </extensions>

        """

        // Add route points
        for waypoint in waypoints {
            gpx += """
                <rtept lat="\(waypoint.latitude)" lon="\(waypoint.longitude)">
                  <name>\(escapeXML(waypoint.name))</name>
            """

            if let altitude = waypoint.altitude {
                // Convert feet to meters for GPX standard
                let altitudeMeters = altitude * 0.3048
                gpx += "\n      <ele>\(String(format: "%.1f", altitudeMeters))</ele>"
            }

            gpx += "\n      <extensions>"

            if let frequency = waypoint.frequency {
                gpx += "\n        <ac:frequency>\(escapeXML(frequency))</ac:frequency>"
            }

            if let callSign = waypoint.callSign {
                gpx += "\n        <ac:callSign>\(escapeXML(callSign))</ac:callSign>"
            }

            if let altitude = waypoint.altitude {
                gpx += "\n        <ac:altitudeFeet>\(Int(altitude))</ac:altitudeFeet>"
            }

            if let mc = waypoint.magneticCourse {
                gpx += "\n        <ac:magneticCourse>\(Int(mc))</ac:magneticCourse>"
            }

            if let distance = waypoint.distance {
                gpx += "\n        <ac:distanceNM>\(String(format: "%.1f", distance))</ac:distanceNM>"
            }

            if let gs = waypoint.plannedGroundSpeed {
                gpx += "\n        <ac:groundSpeed>\(gs)</ac:groundSpeed>"
            }

            if let eet = waypoint.estimatedElapsedTime {
                gpx += "\n        <ac:eet>\(Int(eet))</ac:eet>"
            }

            if !waypoint.remarks.isEmpty {
                gpx += "\n        <ac:remarks><![CDATA[\(waypoint.remarks)]]></ac:remarks>"
            }

            gpx += """

                  </extensions>
                </rtept>

            """
        }

        gpx += """
          </rte>
        </gpx>
        """

        return gpx
    }

    /// Export flight plan to JSON format
    func toJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(self)
        } catch {
            print("[AeroCheck] Failed to encode flight plan to JSON: \(error.localizedDescription)")
            return nil
        }
    }

    /// Import flight plan from JSON data
    static func fromJSON(_ data: Data) -> FlightPlan? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(FlightPlan.self, from: data)
        } catch {
            print("[AeroCheck] Failed to decode flight plan from JSON: \(error)")
            return nil
        }
    }

    /// Import flight plan from GPX data
    static func fromGPX(_ data: Data) -> FlightPlan? {
        let parser = FlightPlanGPXParser(data: data)
        return parser.parse()
    }

    /// Escape XML special characters
    private func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Export filename
    var exportFilename: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStr = dateFormatter.string(from: plannedDepartureTime ?? createdAt)
        let cleanName = name.isEmpty ? "FlightPlan" : name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        return "AeroCheck_\(dateStr)_\(cleanName)"
    }
}

// MARK: - Flight Plan GPX Parser

/// Parser for importing flight plans from GPX format
class FlightPlanGPXParser: NSObject, XMLParserDelegate {
    private var data: Data
    private var flightPlan: FlightPlan?
    private var currentElement = ""
    private var currentText = ""
    private var currentWaypoint: FlightPlanWaypoint?
    private var waypoints: [FlightPlanWaypoint] = []
    private var attributes: [String: String] = [:]

    private let dateFormatter = ISO8601DateFormatter()

    init(data: Data) {
        self.data = data
        super.init()
    }

    func parse() -> FlightPlan? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return flightPlan
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        self.attributes = attributeDict

        if elementName == "rte" {
            flightPlan = FlightPlan()
        } else if elementName == "rtept" {
            if let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
               let lat = Double(latStr), let lon = Double(lonStr) {
                currentWaypoint = FlightPlanWaypoint(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                )
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let elementKey = elementName.replacingOccurrences(of: "ac:", with: "")

        switch elementKey {
        case "name":
            if currentWaypoint != nil {
                currentWaypoint?.name = text
            } else if flightPlan != nil {
                flightPlan?.name = text
            }
        case "pilot":
            flightPlan?.pilot = text
        case "instructor":
            flightPlan?.instructor = text
        case "aircraftType":
            if let type = AircraftType(rawValue: text) {
                flightPlan?.aircraftType = type
            }
        case "aircraftRegistration":
            flightPlan?.aircraftRegistration = text
        case "flightType":
            if let type = FlightType(rawValue: text) {
                flightPlan?.flightType = type
            }
        case "runway":
            flightPlan?.runwayInUse = text
        case "fuelFlow":
            flightPlan?.fuelFlow = Double(text)
        case "fuelOnBoard":
            flightPlan?.fuelOnBoard = Double(text)
        case "remarks":
            if currentWaypoint != nil {
                currentWaypoint?.remarks = text
            } else {
                flightPlan?.remarks = text
            }
        case "ele":
            // GPX elevation is in meters, convert to feet
            if let meters = Double(text) {
                currentWaypoint?.altitude = meters / 0.3048
            }
        case "altitudeFeet":
            currentWaypoint?.altitude = Double(text)
        case "frequency":
            currentWaypoint?.frequency = text
        case "callSign":
            currentWaypoint?.callSign = text
        case "magneticCourse":
            currentWaypoint?.magneticCourse = Double(text)
        case "distanceNM":
            currentWaypoint?.distance = Double(text)
        case "groundSpeed":
            currentWaypoint?.plannedGroundSpeed = Int(text)
        case "eet":
            currentWaypoint?.estimatedElapsedTime = TimeInterval(text)
        case "rtept":
            if let waypoint = currentWaypoint {
                waypoints.append(waypoint)
            }
            currentWaypoint = nil
        case "rte":
            flightPlan?.waypoints = waypoints
            flightPlan?.calculateRouteData()
        case "time":
            if let date = dateFormatter.date(from: text) {
                flightPlan?.plannedDepartureTime = date
            }
        default:
            break
        }
    }
}

