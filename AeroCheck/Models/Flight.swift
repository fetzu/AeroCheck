import Foundation
import CoreLocation

/// Represents a recorded flight with all tracking data
struct Flight: Identifiable, Codable {
    let id: UUID
    var name: String // Custom flight name
    var airplane: String
    var startTime: Date?
    var stopTime: Date?
    var engineStartTime: Date?
    var lineUpTime: Date?
    var landingTime: Date?
    var engineShutdownTime: Date?
    var gpsTrack: [GPSPoint]
    var notes: String
    
    init(
        id: UUID = UUID(),
        name: String = "",
        airplane: String = "F-HVXA",
        startTime: Date? = nil,
        stopTime: Date? = nil,
        engineStartTime: Date? = nil,
        lineUpTime: Date? = nil,
        landingTime: Date? = nil,
        engineShutdownTime: Date? = nil,
        gpsTrack: [GPSPoint] = [],
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.airplane = airplane
        self.startTime = startTime
        self.stopTime = stopTime
        self.engineStartTime = engineStartTime
        self.lineUpTime = lineUpTime
        self.landingTime = landingTime
        self.engineShutdownTime = engineShutdownTime
        self.gpsTrack = gpsTrack
        self.notes = notes
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
        return try? encoder.encode(self)
    }
    
    /// Import flight from JSON data
    static func fromJSON(_ data: Data) -> Flight? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Flight.self, from: data)
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
        case "notes":
            flight?.notes = text
        case "time":
            if let date = dateFormatter.date(from: text) {
                if flight?.startTime == nil {
                    flight?.startTime = date
                } else if var point = currentPoint {
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
        case "ele":
            if var point = currentPoint, let alt = Double(text) {
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
            if var point = currentPoint, let spd = Double(text) {
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
            if var point = currentPoint, let crs = Double(text) {
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
            if flight?.stopTime == nil, let lastPoint = points.last {
                flight?.stopTime = lastPoint.timestamp
            }
        default:
            break
        }
    }
}
