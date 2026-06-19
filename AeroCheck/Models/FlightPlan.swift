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
    var aircraftTypeId: String
    var aircraftRegistration: String
    var aircraftModelName: String

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

    // ICAO flight plan fields
    var icaoAircraftType: String?        // e.g., "DY20", "P28A"
    var wakeTurbulenceCategory: String?  // "L" (light), "M" (medium), "H" (heavy)
    var equipmentCodes: String?          // e.g., "S" (standard VHF/VOR/ILS)
    var surveillanceCodes: String?       // e.g., "N" (nil) or "S" (Mode S)
    var alternateAerodrome: String?      // ICAO ident of alternate
    var personsOnBoard: Int?             // POB count
    var aircraftColour: String?          // e.g., "WHITE RED"

    // Active flight tracking
    var isActive: Bool
    var currentWaypointIndex: Int
    var chronometerStartTime: Date?

    init(
        id: UUID = UUID(),
        name: String = "",
        waypoints: [FlightPlanWaypoint] = [],
        aircraftTypeId: String = "WT9",
        aircraftRegistration: String = "F-HVXA",
        aircraftModelName: String = "WT9 Dynamic",
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
        icaoAircraftType: String? = nil,
        wakeTurbulenceCategory: String? = nil,
        equipmentCodes: String? = nil,
        surveillanceCodes: String? = nil,
        alternateAerodrome: String? = nil,
        personsOnBoard: Int? = nil,
        aircraftColour: String? = nil,
        isActive: Bool = false,
        currentWaypointIndex: Int = 0,
        chronometerStartTime: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.waypoints = waypoints
        self.aircraftTypeId = aircraftTypeId
        self.aircraftRegistration = aircraftRegistration
        self.aircraftModelName = aircraftModelName
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
        self.icaoAircraftType = icaoAircraftType
        self.wakeTurbulenceCategory = wakeTurbulenceCategory
        self.equipmentCodes = equipmentCodes
        self.surveillanceCodes = surveillanceCodes
        self.alternateAerodrome = alternateAerodrome
        self.personsOnBoard = personsOnBoard
        self.aircraftColour = aircraftColour
        self.isActive = isActive
        self.currentWaypointIndex = currentWaypointIndex
        self.chronometerStartTime = chronometerStartTime
    }

    // MARK: - Codable Migration

    private enum CodingKeys: String, CodingKey {
        case id, name, waypoints
        case aircraftTypeId, aircraftRegistration, aircraftModelName
        case aircraftType // Legacy key for migration
        case pilot, instructor, flightType, runwayInUse
        case plannedDepartureTime, announcementDate, announcementTime
        case fuelFlow, tripFuel, reserveFuel, additionalFuel, extraFuel, fuelOnBoard
        case blockOff, timeOff, timeOn, blockOn
        case counterStart, counterStop, landingsAtBase, totalLandings
        case remarks, debriefing, createdAt, updatedAt
        case icaoAircraftType, wakeTurbulenceCategory, equipmentCodes, surveillanceCodes
        case alternateAerodrome, personsOnBoard, aircraftColour
        case isActive, currentWaypointIndex, chronometerStartTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        // Structurally-required but individually non-essential fields decode with a sensible
        // default rather than dropping the entire plan on one missing key. (ARCH-08 / PERF-26)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        waypoints = try container.decode([FlightPlanWaypoint].self, forKey: .waypoints)

        // Migration: try new aircraftTypeId first, fall back to legacy aircraftType enum
        if let typeId = try container.decodeIfPresent(String.self, forKey: .aircraftTypeId) {
            aircraftTypeId = typeId
        } else if let legacyType = try container.decodeIfPresent(AircraftType.self, forKey: .aircraftType) {
            aircraftTypeId = legacyType.rawValue
        } else {
            aircraftTypeId = "WT9"
        }

        aircraftRegistration = try container.decodeIfPresent(String.self, forKey: .aircraftRegistration) ?? "F-HVXA"

        // Migration: aircraftModelName may not exist in old data
        if let modelName = try container.decodeIfPresent(String.self, forKey: .aircraftModelName) {
            aircraftModelName = modelName
        } else if let legacyType = AircraftType(rawValue: aircraftTypeId) {
            aircraftModelName = legacyType.modelName
        } else {
            aircraftModelName = aircraftTypeId
        }

        pilot = try container.decodeIfPresent(String.self, forKey: .pilot) ?? ""
        instructor = try container.decodeIfPresent(String.self, forKey: .instructor)
        flightType = try container.decodeIfPresent(FlightType.self, forKey: .flightType) ?? .vfr
        runwayInUse = try container.decodeIfPresent(String.self, forKey: .runwayInUse)
        plannedDepartureTime = try container.decodeIfPresent(Date.self, forKey: .plannedDepartureTime)
        announcementDate = try container.decodeIfPresent(Date.self, forKey: .announcementDate)
        announcementTime = try container.decodeIfPresent(Date.self, forKey: .announcementTime)
        fuelFlow = try container.decodeIfPresent(Double.self, forKey: .fuelFlow)
        tripFuel = try container.decodeIfPresent(Double.self, forKey: .tripFuel)
        reserveFuel = try container.decodeIfPresent(Double.self, forKey: .reserveFuel)
        additionalFuel = try container.decodeIfPresent(Double.self, forKey: .additionalFuel)
        extraFuel = try container.decodeIfPresent(Double.self, forKey: .extraFuel)
        fuelOnBoard = try container.decodeIfPresent(Double.self, forKey: .fuelOnBoard)
        blockOff = try container.decodeIfPresent(Date.self, forKey: .blockOff)
        timeOff = try container.decodeIfPresent(Date.self, forKey: .timeOff)
        timeOn = try container.decodeIfPresent(Date.self, forKey: .timeOn)
        blockOn = try container.decodeIfPresent(Date.self, forKey: .blockOn)
        counterStart = try container.decodeIfPresent(Double.self, forKey: .counterStart)
        counterStop = try container.decodeIfPresent(Double.self, forKey: .counterStop)
        landingsAtBase = try container.decodeIfPresent(Int.self, forKey: .landingsAtBase)
        totalLandings = try container.decodeIfPresent(Int.self, forKey: .totalLandings)
        remarks = try container.decodeIfPresent(String.self, forKey: .remarks) ?? ""
        debriefing = try container.decodeIfPresent(String.self, forKey: .debriefing) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        icaoAircraftType = try container.decodeIfPresent(String.self, forKey: .icaoAircraftType)
        wakeTurbulenceCategory = try container.decodeIfPresent(String.self, forKey: .wakeTurbulenceCategory)
        equipmentCodes = try container.decodeIfPresent(String.self, forKey: .equipmentCodes)
        surveillanceCodes = try container.decodeIfPresent(String.self, forKey: .surveillanceCodes)
        alternateAerodrome = try container.decodeIfPresent(String.self, forKey: .alternateAerodrome)
        personsOnBoard = try container.decodeIfPresent(Int.self, forKey: .personsOnBoard)
        aircraftColour = try container.decodeIfPresent(String.self, forKey: .aircraftColour)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        currentWaypointIndex = try container.decodeIfPresent(Int.self, forKey: .currentWaypointIndex) ?? 0
        chronometerStartTime = try container.decodeIfPresent(Date.self, forKey: .chronometerStartTime)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(waypoints, forKey: .waypoints)
        try container.encode(aircraftTypeId, forKey: .aircraftTypeId)
        try container.encode(aircraftRegistration, forKey: .aircraftRegistration)
        try container.encode(aircraftModelName, forKey: .aircraftModelName)
        try container.encode(pilot, forKey: .pilot)
        try container.encodeIfPresent(instructor, forKey: .instructor)
        try container.encode(flightType, forKey: .flightType)
        try container.encodeIfPresent(runwayInUse, forKey: .runwayInUse)
        try container.encodeIfPresent(plannedDepartureTime, forKey: .plannedDepartureTime)
        try container.encodeIfPresent(announcementDate, forKey: .announcementDate)
        try container.encodeIfPresent(announcementTime, forKey: .announcementTime)
        try container.encodeIfPresent(fuelFlow, forKey: .fuelFlow)
        try container.encodeIfPresent(tripFuel, forKey: .tripFuel)
        try container.encodeIfPresent(reserveFuel, forKey: .reserveFuel)
        try container.encodeIfPresent(additionalFuel, forKey: .additionalFuel)
        try container.encodeIfPresent(extraFuel, forKey: .extraFuel)
        try container.encodeIfPresent(fuelOnBoard, forKey: .fuelOnBoard)
        try container.encodeIfPresent(blockOff, forKey: .blockOff)
        try container.encodeIfPresent(timeOff, forKey: .timeOff)
        try container.encodeIfPresent(timeOn, forKey: .timeOn)
        try container.encodeIfPresent(blockOn, forKey: .blockOn)
        try container.encodeIfPresent(counterStart, forKey: .counterStart)
        try container.encodeIfPresent(counterStop, forKey: .counterStop)
        try container.encodeIfPresent(landingsAtBase, forKey: .landingsAtBase)
        try container.encodeIfPresent(totalLandings, forKey: .totalLandings)
        try container.encode(remarks, forKey: .remarks)
        try container.encode(debriefing, forKey: .debriefing)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(icaoAircraftType, forKey: .icaoAircraftType)
        try container.encodeIfPresent(wakeTurbulenceCategory, forKey: .wakeTurbulenceCategory)
        try container.encodeIfPresent(equipmentCodes, forKey: .equipmentCodes)
        try container.encodeIfPresent(surveillanceCodes, forKey: .surveillanceCodes)
        try container.encodeIfPresent(alternateAerodrome, forKey: .alternateAerodrome)
        try container.encodeIfPresent(personsOnBoard, forKey: .personsOnBoard)
        try container.encodeIfPresent(aircraftColour, forKey: .aircraftColour)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(currentWaypointIndex, forKey: .currentWaypointIndex)
        try container.encodeIfPresent(chronometerStartTime, forKey: .chronometerStartTime)
    }

    // MARK: - Computed Properties

    /// Total route distance in nautical miles
    var totalDistance: Double {
        waypoints.compactMap { $0.distance }.reduce(0, +)
    }

    /// The id of the current waypoint, or nil if the index is out of range. Compare row identities
    /// against this instead of a filtered-list position — a frequency-less waypoint filtered out of
    /// the FREQ panel otherwise shifts the "current" highlight onto the wrong row. (UX-11)
    var currentWaypointId: UUID? {
        waypoints.indices.contains(currentWaypointIndex) ? waypoints[currentWaypointIndex].id : nil
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
        let additional = additionalFuel ?? (fuelFlow ?? FlightPlan.defaultFuelFlow(for: aircraftTypeId)) * 0.75
        let extra = extraFuel ?? 0
        return trip + reserve + additional + extra
    }

    /// Endurance in hours based on FOB (or fuel required if FOB not set) and fuel flow
    var endurance: Double? {
        guard let flow = fuelFlow, flow > 0 else { return nil }
        // Use FOB if set, otherwise fall back to fuel required
        let fuel = fuelOnBoard ?? fuelRequired
        guard let fuelAmount = fuel, fuelAmount > 0 else { return nil }
        return fuelAmount / flow
    }

    /// Formatted endurance string
    var formattedEndurance: String? {
        guard let endurance = endurance else { return nil }
        let hours = Int(endurance)
        let minutes = Int((endurance - Double(hours)) * 60)
        return String(format: "%d:%02d", hours, minutes)
    }

    /// Default fuel flow based on aircraft type ID
    static func defaultFuelFlow(for aircraftTypeId: String) -> Double {
        switch aircraftTypeId {
        case "WT9": return 20.0  // L/h
        default: return 25.0  // L/h - reasonable default
        }
    }

    /// Default cruise speed based on aircraft type ID
    static func defaultCruiseSpeed(for aircraftTypeId: String) -> Int {
        switch aircraftTypeId {
        case "WT9": return 100  // knots
        default: return 100  // knots - reasonable default
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
                let trueCourse = from.bearing(to: to)

                // Convert to magnetic course
                let magneticCourse = (trueCourse - magneticDeclination + 360).truncatingRemainder(dividingBy: 360)
                waypoints[i].magneticCourse = magneticCourse

                // Calculate EET for this leg (time to next waypoint only)
                let groundSpeed = waypoints[i].plannedGroundSpeed ?? FlightPlan.defaultCruiseSpeed(for: aircraftTypeId)
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
        if let flow = fuelFlow ?? FlightPlan.defaultFuelFlow(for: aircraftTypeId) as Double? {
            let tripTimeHours = totalEET / 3600
            tripFuel = tripTimeHours * flow
        }

        updatedAt = Date()
    }

    /// The waypoint carrying the leg data (MC, distance, EET) for the leg ARRIVING at the
    /// waypoint at `index`. Each leg's data is stored on its DEPARTURE waypoint
    /// (`waypoints[i]` holds leg `i → i+1`), so the inbound leg to `index` lives on
    /// `waypoints[index - 1]`. Returns nil for the departure waypoint (index 0) and for
    /// out-of-range indices. In-flight HUDs display the leg being flown TO the next
    /// waypoint, so they must read leg data through this accessor, not off the arrival
    /// waypoint itself (UX-01).
    func legArriving(at index: Int) -> FlightPlanWaypoint? {
        guard index > 0, index - 1 < waypoints.count else { return nil }
        return waypoints[index - 1]
    }
}

// MARK: - ICAO Type Mapping

extension FlightPlan {
    /// Known ICAO type designators for common GA aircraft
    static let icaoTypeMap: [String: String] = [
        "WT9": "DY20",
        "wt9-dynamic": "DY20",
        "pa28-181": "P28A",
        "ps28-cruiser": "P28A",
        "c172": "C172",
        "c152": "C152",
        "c182": "C182",
        "dr400": "DR40",
        "pa28-161": "P28A",
        "pa28r-201": "P28R",
    ]

    /// Resolve the ICAO aircraft type designator
    var resolvedICAOType: String {
        if let explicit = icaoAircraftType, !explicit.isEmpty {
            return explicit.uppercased()
        }
        return FlightPlan.icaoTypeMap[aircraftTypeId] ?? "ZZZZ"
    }

    /// Generate ICAO flight plan text message (ICAO Doc 4444 format)
    func toICAOFlightPlan() -> String {
        // Field 7 - Aircraft identification (registration without hyphen)
        let acId = aircraftRegistration.replacingOccurrences(of: "-", with: "")

        // Field 8 - Flight rules and type
        let flightRules: String
        switch flightType {
        case .vfr, .training, .local, .crossCountry, .checkFlight:
            flightRules = "VG" // VFR General aviation
        }

        // Field 9 - Number and type of aircraft, wake turbulence category
        let acType = resolvedICAOType
        let wtc = (wakeTurbulenceCategory ?? "L").uppercased()

        // Field 10 - Equipment and surveillance
        let equip = (equipmentCodes ?? "S").uppercased()
        let surv = (surveillanceCodes ?? "N").uppercased()

        // Field 13 - Departure aerodrome and time
        let depAerodrome: String
        if let firstWP = waypoints.first, !firstWP.name.isEmpty {
            depAerodrome = firstWP.name.count == 4 ? firstWP.name.uppercased() : "ZZZZ"
        } else {
            depAerodrome = "ZZZZ"
        }

        let depTime: String
        if let dep = plannedDepartureTime {
            let fmt = DateFormatter()
            fmt.dateFormat = "HHmm"
            fmt.timeZone = TimeZone(identifier: "UTC")
            depTime = fmt.string(from: dep)
        } else {
            depTime = "0000"
        }

        // Field 15 - Cruising speed, level, and route
        // Speed: "N" + 4-digit TAS in knots
        let avgGS = waypoints.compactMap { $0.plannedGroundSpeed }.first
            ?? FlightPlan.defaultCruiseSpeed(for: aircraftTypeId)
        let speedStr = String(format: "N%04d", avgGS)

        // Level: "VFR" or "A" + 3-digit altitude in hundreds of feet
        let levelStr: String
        let cruiseAlt = waypoints.dropFirst().dropLast().compactMap { $0.altitude }.first
        if let alt = cruiseAlt {
            let hundreds = Int(alt) / 100
            levelStr = String(format: "A%03d", hundreds)
        } else {
            levelStr = "VFR"
        }

        // Route string: waypoint names joined by DCT
        let routeWaypoints = waypoints.dropFirst().dropLast()
        let routeStr: String
        if routeWaypoints.isEmpty {
            routeStr = "DCT"
        } else {
            let names = routeWaypoints.map { wp -> String in
                let name = wp.name.uppercased()
                    .replacingOccurrences(of: " ", with: "")
                return name.isEmpty ? "ZZZZ" : String(name.prefix(11))
            }
            routeStr = "DCT " + names.joined(separator: " DCT ") + " DCT"
        }

        // Field 16 - Destination aerodrome, total EET, alternate(s)
        let destAerodrome: String
        if let lastWP = waypoints.last, !lastWP.name.isEmpty {
            destAerodrome = lastWP.name.count == 4 ? lastWP.name.uppercased() : "ZZZZ"
        } else {
            destAerodrome = "ZZZZ"
        }

        // EET in HHMM format
        let totalSeconds = Int(totalEET)
        let eetHours = totalSeconds / 3600
        let eetMinutes = (totalSeconds % 3600) / 60
        let eetStr = String(format: "%02d%02d", eetHours, eetMinutes)

        // Alternate(s)
        let altAerodrome = (alternateAerodrome ?? "").uppercased()
        let altStr = altAerodrome.isEmpty ? "" : " \(altAerodrome)"

        // Field 18 - Other information
        var otherInfo: [String] = []
        if depAerodrome == "ZZZZ", let firstWP = waypoints.first {
            otherInfo.append("DEP/\(firstWP.name.uppercased())")
        }
        if destAerodrome == "ZZZZ", let lastWP = waypoints.last {
            otherInfo.append("DEST/\(lastWP.name.uppercased())")
        }
        if let pob = personsOnBoard {
            otherInfo.append("0/\(pob)")
        }
        let pic = pilot.isEmpty ? "UNKNOWN" : pilot.uppercased()
        otherInfo.append("PIC/\(pic)")

        // Field 19 - Supplementary information
        var suppInfo: [String] = []
        if let endur = endurance {
            let endurHours = Int(endur)
            let endurMinutes = Int((endur - Double(endurHours)) * 60)
            suppInfo.append(String(format: "E/%02d%02d", endurHours, endurMinutes))
        }
        if let pob = personsOnBoard {
            suppInfo.append("P/\(pob)")
        }
        if let colour = aircraftColour, !colour.isEmpty {
            suppInfo.append("A/\(colour.uppercased())")
        }
        suppInfo.append("C/\(pic)")

        // Build the FPL message
        var fpl = "(FPL-\(acId)-\(flightRules)\n"
        fpl += "-\(acType)/\(wtc)-\(equip)/\(surv)\n"
        fpl += "-\(depAerodrome)\(depTime)\n"
        fpl += "-\(speedStr)\(levelStr)\n"
        fpl += "-\(routeStr)\n"
        fpl += "-\(destAerodrome)\(eetStr)\(altStr)\n"

        if !otherInfo.isEmpty {
            fpl += "-\(otherInfo.joined(separator: " "))\n"
        } else {
            fpl += "-0\n"
        }

        if !suppInfo.isEmpty {
            fpl += "-\(suppInfo.joined(separator: " ")))"
        } else {
            fpl += "-)"
        }

        return fpl
    }
}

// MARK: - Flight Plan Export/Import

extension FlightPlan {
    /// Export flight plan to GPX format
    func toGPX() -> String {
        let dateFormatter = ISO8601DateFormatter()

        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="AéroCheck"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xmlns:ac="http://aerocheck.app/gpx/1"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>\(escapeXML(name))</name>
            <desc>Flight plan created with AéroCheck</desc>
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

                <ac:aircraftType>\(escapeXML(aircraftTypeId))</ac:aircraftType>
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
            AppLog.general.debugLine("Failed to encode flight plan to JSON: \(error.localizedDescription)")
            return nil
        }
    }

    /// Import flight plan from JSON data
    static func fromJSON(_ data: Data) -> FlightPlan? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let plan = try decoder.decode(FlightPlan.self, from: data)
            // Reject NaN/Inf/out-of-range waypoint coordinates (e.g. a "1e999" overflow that
            // decodes to Infinity) before the route reaches the map/analyzer/export. (SEC-08)
            guard plan.waypoints.allSatisfy({ GeoValidation.isValidLatLon($0.latitude, $0.longitude) }) else {
                AppLog.general.debugLine("Rejected flight plan import: invalid coordinates")
                return nil
            }
            return plan
        } catch {
            AppLog.general.debugLine("Failed to decode flight plan from JSON: \(error)")
            return nil
        }
    }

    /// Import flight plan from GPX data
    static func fromGPX(_ data: Data) -> FlightPlan? {
        let parser = FlightPlanGPXParser(data: data)
        return parser.parse()
    }

    /// Escape XML special characters (delegates to the shared `String.xmlEscaped`).
    private func escapeXML(_ string: String) -> String { string.xmlEscaped }

    /// Export filename
    var exportFilename: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStr = dateFormatter.string(from: plannedDepartureTime ?? createdAt)
        let clean: (String) -> String = {
            $0.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
        }
        let cleanName = clean(name.isEmpty ? "FlightPlan" : name)
        // Include the route endpoints (e.g. LSZQ-LSZB) so a file is identifiable at a glance. (#5 feedback)
        var route = ""
        if waypoints.count >= 2 {
            let from = clean(waypoints.first?.name ?? ""), to = clean(waypoints.last?.name ?? "")
            if !from.isEmpty, !to.isEmpty { route = "\(from)-\(to)_" }
        }
        return "AeroCheck_\(dateStr)_\(route)\(cleanName)"
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
    /// Set if any waypoint carries an invalid (NaN/Inf/out-of-range) coordinate, in which
    /// case the whole import is rejected rather than yielding a partial/garbage route. (SEC-08)
    private var hasInvalidCoordinate = false
    /// Set if the route exceeds the hard waypoint cap — rejected, not silently truncated. (SEC-13)
    private var hasTooManyWaypoints = false

    private let dateFormatter = ISO8601DateFormatter()

    init(data: Data) {
        self.data = data
        super.init()
    }

    func parse() -> FlightPlan? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        // Defense-in-depth on an attacker-supplied-file import path: never resolve external
        // entities (XXE), so the safe behavior survives any future refactor. (SEC-20)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.parse()
        return (hasInvalidCoordinate || hasTooManyWaypoints) ? nil : flightPlan
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
               let lat = Double(latStr), let lon = Double(lonStr),
               GeoValidation.isValidLatLon(lat, lon) {
                currentWaypoint = FlightPlanWaypoint(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                )
            } else {
                // A rtept with missing/unparseable/out-of-range coordinates invalidates the import.
                hasInvalidCoordinate = true
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
            flightPlan?.aircraftTypeId = text
        case "aircraftRegistration":
            flightPlan?.aircraftRegistration = text
        case "flightType":
            if let type = FlightType(rawValue: text) {
                flightPlan?.flightType = type
            }
        case "runway":
            flightPlan?.runwayInUse = text
        case "fuelFlow":
            flightPlan?.fuelFlow = GeoValidation.finite(Double(text))
        case "fuelOnBoard":
            flightPlan?.fuelOnBoard = GeoValidation.finite(Double(text))
        case "remarks":
            if currentWaypoint != nil {
                currentWaypoint?.remarks = text
            } else {
                flightPlan?.remarks = text
            }
        case "ele":
            // GPX elevation is in meters, convert to feet
            if let meters = Double(text), meters.isFinite {
                currentWaypoint?.altitude = meters / 0.3048
            }
        case "altitudeFeet":
            currentWaypoint?.altitude = GeoValidation.finite(Double(text))
        case "frequency":
            currentWaypoint?.frequency = text
        case "callSign":
            currentWaypoint?.callSign = text
        case "magneticCourse":
            currentWaypoint?.magneticCourse = GeoValidation.finite(Double(text))
        case "distanceNM":
            currentWaypoint?.distance = GeoValidation.finite(Double(text))
        case "groundSpeed":
            currentWaypoint?.plannedGroundSpeed = Int(text)
        case "eet":
            currentWaypoint?.estimatedElapsedTime = TimeInterval(text)
        case "rtept":
            if let waypoint = currentWaypoint {
                if waypoints.count >= FlightDataLimits.maxRouteWaypoints {
                    hasTooManyWaypoints = true
                } else {
                    waypoints.append(waypoint)
                }
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

// MARK: - Geo helpers

extension CLLocationCoordinate2D {
    /// Initial great-circle bearing from this coordinate to another, in degrees (0–360).
    func bearing(to other: CLLocationCoordinate2D) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)

        let bearing = atan2(y, x) * 180 / .pi
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }
}

