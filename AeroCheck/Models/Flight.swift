import Foundation
import CoreLocation

/// Represents a recorded flight with all tracking data
struct Flight: Identifiable, Codable {
    let id: UUID
    var name: String // Custom flight name
    var airplane: String
    var aircraftType: String? // Aircraft type identifier (e.g., "WT9", "PA28")
    var checklistVersion: String? // Checklist version used (e.g., "2.1e")
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
    var goAroundTimes: [Date]
    var touchAndGoTimes: [Date]

    init(
        id: UUID = UUID(),
        name: String = "",
        airplane: String = "F-HVXA",
        aircraftType: String? = nil,
        checklistVersion: String? = nil,
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
        goAroundTimes: [Date] = [],
        touchAndGoTimes: [Date] = []
    ) {
        self.id = id
        self.name = name
        self.airplane = airplane
        self.aircraftType = aircraftType
        self.checklistVersion = checklistVersion
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
        self.goAroundTimes = goAroundTimes
        self.touchAndGoTimes = touchAndGoTimes
    }
    
    /// Display name: "Custom Name (Airplane)" or just "Airplane" if no name
    var displayName: String {
        if name.isEmpty {
            return airplane
        }
        return "\(name) (\(airplane))"
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
        
        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="AeroCheck"
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
    
    /// Export flight to JSON format (includes all data)
    func toJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(self)
        } catch {
            print("[AeroCheck] Failed to encode flight to JSON: \(error.localizedDescription)")
            return nil
        }
    }

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

    /// Import flight from JSON data
    /// - Parameter data: JSON data to decode
    /// - Returns: Decoded Flight object
    /// - Throws: ImportError.invalidJSON if decoding fails
    static func fromJSON(_ data: Data) throws -> Flight {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Flight.self, from: data)
        } catch {
            print("[AeroCheck] Failed to decode flight from JSON: \(error)")
            throw ImportError.invalidJSON(underlying: error)
        }
    }

    /// Import flight from JSON data (non-throwing version for backward compatibility)
    /// - Parameter data: JSON data to decode
    /// - Returns: Decoded Flight object, or nil if decoding fails
    static func fromJSON(_ data: Data) -> Flight? {
        try? fromJSON(data) as Flight
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
            if flight?.stopTime == nil, let lastPoint = points.last {
                flight?.stopTime = lastPoint.timestamp
            }
        default:
            break
        }
    }
}

