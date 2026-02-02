import Foundation
import CoreLocation

/// Current export format version
/// - v1: Original format (no fullStopCount, fullStopTimes, flightPlanId, flightPlan)
/// - v2: Added fullStopCount, fullStopTimes, flightPlanId, flightPlan, export metadata
let currentExportFormatVersion = 2

/// Represents a recorded flight with all tracking data
struct Flight: Identifiable, Codable {
    let id: UUID
    var name: String // Custom flight name
    var airplane: String // Aircraft ID (e.g., "pa28-181", "wt9-dynamic")
    var aircraftRegistration: String? // Aircraft tail number (e.g., "HB-PFA", "F-HVXA")
    var aircraftType: String? // Aircraft type identifier (e.g., "WT9", "PA28")
    var checklistVersion: String? // Checklist version used (e.g., "2.1e")
    var flightPlanId: UUID? // Associated flight plan ID (if using navigation planning)
    var flightPlan: FlightPlan? // Full flight plan data (saved with the flight)
    var startTime: Date?
    var stopTime: Date?
    var engineStartTime: Date?
    var lineUpTime: Date?
    var landingTime: Date?
    var engineShutdownTime: Date?
    var gpsTrack: [GPSPoint]
    var notes: String
    var goAroundCount: Int
    var touchAndGoCount: Int
    var fullStopCount: Int
    var goAroundTimes: [Date]
    var touchAndGoTimes: [Date]
    var fullStopTimes: [Date]

    // MARK: - Coding Keys

    enum CodingKeys: String, CodingKey {
        case id, name, airplane, aircraftRegistration, aircraftType, checklistVersion
        case flightPlanId, flightPlan
        case startTime, stopTime, engineStartTime, lineUpTime, landingTime, engineShutdownTime
        case gpsTrack, notes
        case goAroundCount, touchAndGoCount, fullStopCount
        case goAroundTimes, touchAndGoTimes, fullStopTimes
    }

    // MARK: - Custom Decodable for backward compatibility

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        airplane = try container.decode(String.self, forKey: .airplane)
        aircraftRegistration = try container.decodeIfPresent(String.self, forKey: .aircraftRegistration)
        aircraftType = try container.decodeIfPresent(String.self, forKey: .aircraftType)
        checklistVersion = try container.decodeIfPresent(String.self, forKey: .checklistVersion)

        // New fields in v2 - provide defaults for backward compatibility
        flightPlanId = try container.decodeIfPresent(UUID.self, forKey: .flightPlanId)
        flightPlan = try container.decodeIfPresent(FlightPlan.self, forKey: .flightPlan)

        startTime = try container.decodeIfPresent(Date.self, forKey: .startTime)
        stopTime = try container.decodeIfPresent(Date.self, forKey: .stopTime)
        engineStartTime = try container.decodeIfPresent(Date.self, forKey: .engineStartTime)
        lineUpTime = try container.decodeIfPresent(Date.self, forKey: .lineUpTime)
        landingTime = try container.decodeIfPresent(Date.self, forKey: .landingTime)
        engineShutdownTime = try container.decodeIfPresent(Date.self, forKey: .engineShutdownTime)

        gpsTrack = try container.decodeIfPresent([GPSPoint].self, forKey: .gpsTrack) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""

        goAroundCount = try container.decodeIfPresent(Int.self, forKey: .goAroundCount) ?? 0
        touchAndGoCount = try container.decodeIfPresent(Int.self, forKey: .touchAndGoCount) ?? 0
        // New in v2 - default to 0 for backward compatibility
        fullStopCount = try container.decodeIfPresent(Int.self, forKey: .fullStopCount) ?? 0

        goAroundTimes = try container.decodeIfPresent([Date].self, forKey: .goAroundTimes) ?? []
        touchAndGoTimes = try container.decodeIfPresent([Date].self, forKey: .touchAndGoTimes) ?? []
        // New in v2 - default to empty for backward compatibility
        fullStopTimes = try container.decodeIfPresent([Date].self, forKey: .fullStopTimes) ?? []
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        airplane: String = "wt9-dynamic",
        aircraftRegistration: String? = nil,
        aircraftType: String? = nil,
        checklistVersion: String? = nil,
        flightPlanId: UUID? = nil,
        flightPlan: FlightPlan? = nil,
        startTime: Date? = nil,
        stopTime: Date? = nil,
        engineStartTime: Date? = nil,
        lineUpTime: Date? = nil,
        landingTime: Date? = nil,
        engineShutdownTime: Date? = nil,
        gpsTrack: [GPSPoint] = [],
        notes: String = "",
        goAroundCount: Int = 0,
        touchAndGoCount: Int = 0,
        fullStopCount: Int = 0,
        goAroundTimes: [Date] = [],
        touchAndGoTimes: [Date] = [],
        fullStopTimes: [Date] = []
    ) {
        self.id = id
        self.name = name
        self.airplane = airplane
        self.aircraftRegistration = aircraftRegistration
        self.aircraftType = aircraftType
        self.checklistVersion = checklistVersion
        self.flightPlanId = flightPlanId
        self.flightPlan = flightPlan
        self.startTime = startTime
        self.stopTime = stopTime
        self.engineStartTime = engineStartTime
        self.lineUpTime = lineUpTime
        self.landingTime = landingTime
        self.engineShutdownTime = engineShutdownTime
        self.gpsTrack = gpsTrack
        self.notes = notes
        self.goAroundCount = goAroundCount
        self.touchAndGoCount = touchAndGoCount
        self.fullStopCount = fullStopCount
        self.goAroundTimes = goAroundTimes
        self.touchAndGoTimes = touchAndGoTimes
        self.fullStopTimes = fullStopTimes
    }

    /// Total landings (touch and go + full stops + final landing)
    var totalLandings: Int {
        // If flight has ended (has landing time), count 1 for final landing + all touch and gos + full stops
        if landingTime != nil {
            return touchAndGoCount + fullStopCount + 1
        }
        // If flight is still in progress, just count touch and gos + full stops
        return touchAndGoCount + fullStopCount
    }
    
    /// Display name: "Custom Name (Registration)" or just "Registration" if no name
    /// Falls back to airplane ID if registration is not available (for backwards compatibility)
    var displayName: String {
        let displayIdentifier = aircraftRegistration ?? airplane
        if name.isEmpty {
            return displayIdentifier
        }
        return "\(name) (\(displayIdentifier))"
    }
    
    /// Flight duration from engine start to engine shutdown
    var duration: TimeInterval? {
        guard let start = engineStartTime else { return nil }
        let end = engineShutdownTime ?? stopTime ?? Date()
        return end.timeIntervalSince(start)
    }
    
    /// Session duration (total time from app start to stop)
    var sessionDuration: TimeInterval? {
        guard let start = startTime, let stop = stopTime else { return nil }
        return stop.timeIntervalSince(start)
    }
    
    var formattedDuration: String {
        guard let duration = duration else { return "--:--" }
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }
    
    var formattedDate: String {
        guard let start = startTime else { return "No date" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: start)
    }
    
    /// Total distance travelled in kilometers (calculated from GPS track)
    var distanceKilometers: Double {
        guard gpsTrack.count >= 2 else { return 0 }
        
        var totalDistance: Double = 0
        for i in 1..<gpsTrack.count {
            let prev = gpsTrack[i-1]
            let curr = gpsTrack[i]
            
            let prevLocation = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
            let currLocation = CLLocation(latitude: curr.latitude, longitude: curr.longitude)
            
            totalDistance += currLocation.distance(from: prevLocation)
        }
        return totalDistance / 1000.0 // Convert meters to km
    }
    
    var formattedDistance: String {
        if distanceKilometers < 0.1 {
            return "< 0.1 km"
        }
        return String(format: "%.1f km", distanceKilometers)
    }

    /// Export filename in format: AeroCheck_YYYYMMDD_HHMM_FlightName (without extension)
    /// Uses flight start date/time, or current date if unavailable
    /// Includes time component to ensure uniqueness when multiple flights on same day
    var exportFilename: String {
        let dateFormatter = DateFormatter()
        let timeFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        timeFormatter.dateFormat = "HHmm"

        // Use flight start time if available, otherwise current date
        let flightDate = startTime ?? Date()
        let dateStr = dateFormatter.string(from: flightDate)
        let timeStr = timeFormatter.string(from: flightDate)

        // Use flight name if provided, otherwise use airplane name
        let flightIdentifier: String
        if name.isEmpty {
            // Clean airplane name (remove spaces and special characters)
            flightIdentifier = airplane
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "\\", with: "-")
        } else {
            // Clean flight name (replace spaces with underscores, remove problematic chars)
            flightIdentifier = name
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "\\", with: "-")
        }

        return "AeroCheck_\(dateStr)_\(timeStr)_\(flightIdentifier)"
    }
}

/// A single GPS coordinate with timestamp
struct GPSPoint: Codable, Identifiable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
    let speed: Double
    let course: Double
    
    init(
        id: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        altitude: Double,
        timestamp: Date = Date(),
        speed: Double = 0,
        course: Double = 0
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
        self.speed = speed
        self.course = course
    }
    
    init(from location: CLLocation) {
        self.id = UUID()
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.timestamp = location.timestamp
        self.speed = location.speed
        self.course = location.course
    }
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - GPX Export/Import

extension Flight {
    /// Export flight to GPX format with all timing data in extensions
    func toGPX() -> String {
        let dateFormatter = ISO8601DateFormatter()
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="AéroCheck v\(appVersion)"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xmlns:pc="http://aerocheck.app/gpx/1"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>\(displayName) - \(formattedDate)</name>
            <desc>Flight recorded with AéroCheck app</desc>
        """

        if let start = startTime {
            gpx += "\n    <time>\(dateFormatter.string(from: start))</time>"
        }

        gpx += """

          </metadata>
          <trk>
            <name>\(airplane)</name>
            <extensions>
              <pc:flightData>
                <pc:formatVersion>\(currentExportFormatVersion)</pc:formatVersion>
                <pc:appVersion>\(appVersion)</pc:appVersion>
                <pc:name>\(name)</pc:name>
                <pc:airplane>\(airplane)</pc:airplane>
        """

        if let aircraftType = aircraftType {
            gpx += "\n        <pc:aircraftType>\(aircraftType)</pc:aircraftType>"
        }
        if let checklistVersion = checklistVersion {
            gpx += "\n        <pc:checklistVersion>\(checklistVersion)</pc:checklistVersion>"
        }

        gpx += ""
        
        if let start = startTime {
            gpx += "\n        <pc:startTime>\(dateFormatter.string(from: start))</pc:startTime>"
        }
        if let engineStart = engineStartTime {
            gpx += "\n        <pc:engineStartTime>\(dateFormatter.string(from: engineStart))</pc:engineStartTime>"
        }
        if let lineUp = lineUpTime {
            gpx += "\n        <pc:lineUpTime>\(dateFormatter.string(from: lineUp))</pc:lineUpTime>"
        }
        if let landing = landingTime {
            gpx += "\n        <pc:landingTime>\(dateFormatter.string(from: landing))</pc:landingTime>"
        }
        if let shutdown = engineShutdownTime {
            gpx += "\n        <pc:engineShutdownTime>\(dateFormatter.string(from: shutdown))</pc:engineShutdownTime>"
        }
        if let stop = stopTime {
            gpx += "\n        <pc:stopTime>\(dateFormatter.string(from: stop))</pc:stopTime>"
        }
        
        gpx += "\n        <pc:distanceKm>\(String(format: "%.2f", distanceKilometers))</pc:distanceKm>"

        if goAroundCount > 0 {
            gpx += "\n        <pc:goAroundCount>\(goAroundCount)</pc:goAroundCount>"
            for goAroundTime in goAroundTimes {
                gpx += "\n        <pc:goAroundTime>\(dateFormatter.string(from: goAroundTime))</pc:goAroundTime>"
            }
        }

        if touchAndGoCount > 0 {
            gpx += "\n        <pc:touchAndGoCount>\(touchAndGoCount)</pc:touchAndGoCount>"
            for touchAndGoTime in touchAndGoTimes {
                gpx += "\n        <pc:touchAndGoTime>\(dateFormatter.string(from: touchAndGoTime))</pc:touchAndGoTime>"
            }
        }

        if fullStopCount > 0 {
            gpx += "\n        <pc:fullStopCount>\(fullStopCount)</pc:fullStopCount>"
            for fullStopTime in fullStopTimes {
                gpx += "\n        <pc:fullStopTime>\(dateFormatter.string(from: fullStopTime))</pc:fullStopTime>"
            }
        }

        if !notes.isEmpty {
            gpx += "\n        <pc:notes><![CDATA[\(notes)]]></pc:notes>"
        }
        
        gpx += """
        
              </pc:flightData>
            </extensions>
            <trkseg>
        
        """
        
        for point in gpsTrack {
            gpx += """
              <trkpt lat="\(point.latitude)" lon="\(point.longitude)">
                <ele>\(point.altitude)</ele>
                <time>\(dateFormatter.string(from: point.timestamp))</time>
                <extensions>
                  <pc:speed>\(point.speed)</pc:speed>
                  <pc:course>\(point.course)</pc:course>
                </extensions>
              </trkpt>
            
            """
        }
        
        gpx += """
            </trkseg>
          </trk>
        </gpx>
        """
        
        return gpx
    }
    
    /// Export flight to JSON format (includes all data with metadata)
    func toJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let exportWrapper = FlightExportWrapper(flight: self, flightPlan: nil)
            return try encoder.encode(exportWrapper)
        } catch {
            print("[AéroCheck] Failed to encode flight to JSON: \(error.localizedDescription)")
            return nil
        }
    }

    /// Export flight to JSON format with optional flight plan data
    /// - Parameter flightPlan: Optional flight plan to include in export
    /// - Returns: JSON data including both flight and navigation plan data
    func toJSON(withFlightPlan flightPlan: FlightPlan?) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let exportWrapper = FlightExportWrapper(flight: self, flightPlan: flightPlan)
            return try encoder.encode(exportWrapper)
        } catch {
            print("[AéroCheck] Failed to encode flight with navigation to JSON: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Export metadata structure
struct FlightExportMetadata: Codable {
    let appName: String
    let appVersion: String
    let formatVersion: Int
    let exportDate: Date

    static var current: FlightExportMetadata {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return FlightExportMetadata(
            appName: "AéroCheck",
            appVersion: appVersion,
            formatVersion: currentExportFormatVersion,
            exportDate: Date()
        )
    }
}

/// Wrapper structure for JSON exports with metadata (v2 format)
struct FlightExportWrapper: Codable {
    let metadata: FlightExportMetadata
    let flight: Flight
    let flightPlan: FlightPlan?

    init(flight: Flight, flightPlan: FlightPlan?) {
        self.metadata = .current
        self.flight = flight
        self.flightPlan = flightPlan
    }
}

/// Combined export structure for flight with navigation data (legacy, kept for compatibility)
struct FlightWithNavigationExport: Codable {
    let flight: Flight
    let flightPlan: FlightPlan?
}

// MARK: - Flight Import

extension Flight {
    /// Errors that can occur during flight import
    enum ImportError: Error, LocalizedError {
        case invalidJSON(underlying: Error)
        case invalidGPX

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let underlying):
                return "Invalid JSON format: \(underlying.localizedDescription)"
            case .invalidGPX:
                return "Invalid GPX format"
            }
        }
    }

    /// Import flight from JSON data, supporting multiple format versions:
    /// - v2: FlightExportWrapper with metadata, flight, and optional flightPlan
    /// - v1: Direct Flight object (backward compatibility)
    /// - Legacy: FlightWithNavigationExport with flight and flightPlan (no metadata)
    ///
    /// - Parameter data: JSON data to decode
    /// - Returns: Decoded Flight object
    /// - Throws: ImportError.invalidJSON if decoding fails
    static func fromJSON(_ data: Data) throws -> Flight {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Try v2 format first (FlightExportWrapper with metadata)
        if let wrapper = try? decoder.decode(FlightExportWrapper.self, from: data) {
            print("[AéroCheck] Imported flight from v2 format (formatVersion: \(wrapper.metadata.formatVersion))")
            return wrapper.flight
        }

        // Try legacy FlightWithNavigationExport format (no metadata)
        if let legacyExport = try? decoder.decode(FlightWithNavigationExport.self, from: data) {
            print("[AéroCheck] Imported flight from legacy FlightWithNavigationExport format")
            return legacyExport.flight
        }

        // Try v1 format (direct Flight object - oldest format)
        do {
            let flight = try decoder.decode(Flight.self, from: data)
            print("[AéroCheck] Imported flight from v1 format (direct Flight object)")
            return flight
        } catch {
            print("[AéroCheck] Failed to decode flight from JSON: \(error)")
            throw ImportError.invalidJSON(underlying: error)
        }
    }

    /// Import flight from JSON data (non-throwing version for backward compatibility)
    /// - Parameter data: JSON data to decode
    /// - Returns: Decoded Flight object, or nil if decoding fails
    static func fromJSONOptional(_ data: Data) -> Flight? {
        try? fromJSON(data)
    }

    /// Import flight from GPX data
    static func fromGPX(_ data: Data) -> Flight? {
        let parser = GPXParser(data: data)
        return parser.parse()
    }
}

/// Simple GPX parser for importing flights
class GPXParser: NSObject, XMLParserDelegate {
    private var data: Data
    private var flight: Flight?
    private var currentElement = ""
    private var currentText = ""
    private var currentPoint: GPSPoint?
    private var points: [GPSPoint] = []
    private var attributes: [String: String] = [:]
    private var goAroundTimes: [Date] = []
    private var touchAndGoTimes: [Date] = []
    private var fullStopTimes: [Date] = []

    private let dateFormatter = ISO8601DateFormatter()
    
    init(data: Data) {
        self.data = data
        super.init()
    }
    
    func parse() -> Flight? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return flight
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentText = ""
        self.attributes = attributeDict
        
        if elementName == "trk" {
            flight = Flight()
        } else if elementName == "trkpt" {
            if let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
               let lat = Double(latStr), let lon = Double(lonStr) {
                currentPoint = GPSPoint(latitude: lat, longitude: lon, altitude: 0)
            }
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle both prefixed and non-prefixed element names
        let elementKey = elementName.replacingOccurrences(of: "pc:", with: "")

        switch elementKey {
        case "name":
            if flight != nil && flight?.airplane == "F-HVXA" {
                flight?.airplane = text
            }
        case "airplane":
            flight?.airplane = text
        case "aircraftType":
            flight?.aircraftType = text
        case "checklistVersion":
            flight?.checklistVersion = text
        case "notes":
            flight?.notes = text
        case "time":
            if let date = dateFormatter.date(from: text) {
                if flight?.startTime == nil {
                    flight?.startTime = date
                } else if let point = currentPoint {
                    currentPoint = GPSPoint(
                        id: point.id,
                        latitude: point.latitude,
                        longitude: point.longitude,
                        altitude: point.altitude,
                        timestamp: date,
                        speed: point.speed,
                        course: point.course
                    )
                }
            }
        case "startTime":
            flight?.startTime = dateFormatter.date(from: text)
        case "engineStartTime":
            flight?.engineStartTime = dateFormatter.date(from: text)
        case "lineUpTime":
            flight?.lineUpTime = dateFormatter.date(from: text)
        case "landingTime":
            flight?.landingTime = dateFormatter.date(from: text)
        case "engineShutdownTime":
            flight?.engineShutdownTime = dateFormatter.date(from: text)
        case "stopTime":
            flight?.stopTime = dateFormatter.date(from: text)
        case "goAroundCount":
            flight?.goAroundCount = Int(text) ?? 0
        case "goAroundTime":
            if let date = dateFormatter.date(from: text) {
                goAroundTimes.append(date)
            }
        case "touchAndGoCount":
            flight?.touchAndGoCount = Int(text) ?? 0
        case "touchAndGoTime":
            if let date = dateFormatter.date(from: text) {
                touchAndGoTimes.append(date)
            }
        case "fullStopCount":
            flight?.fullStopCount = Int(text) ?? 0
        case "fullStopTime":
            if let date = dateFormatter.date(from: text) {
                fullStopTimes.append(date)
            }
        case "ele":
            if let point = currentPoint, let alt = Double(text) {
                currentPoint = GPSPoint(
                    id: point.id,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: alt,
                    timestamp: point.timestamp,
                    speed: point.speed,
                    course: point.course
                )
            }
        case "speed":
            if let point = currentPoint, let spd = Double(text) {
                currentPoint = GPSPoint(
                    id: point.id,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: point.altitude,
                    timestamp: point.timestamp,
                    speed: spd,
                    course: point.course
                )
            }
        case "course":
            if let point = currentPoint, let crs = Double(text) {
                currentPoint = GPSPoint(
                    id: point.id,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: point.altitude,
                    timestamp: point.timestamp,
                    speed: point.speed,
                    course: crs
                )
            }
        case "trkpt":
            if let point = currentPoint {
                points.append(point)
            }
            currentPoint = nil
        case "trk":
            flight?.gpsTrack = points
            flight?.goAroundTimes = goAroundTimes
            flight?.touchAndGoTimes = touchAndGoTimes
            flight?.fullStopTimes = fullStopTimes
            if flight?.stopTime == nil, let lastPoint = points.last {
                flight?.stopTime = lastPoint.timestamp
            }
        default:
            break
        }
    }
}

