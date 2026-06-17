import Foundation
import CoreLocation

/// Current export format version
/// - v1: Original format (no fullStopCount, fullStopTimes, flightPlanId, flightPlan)
/// - v2: Added fullStopCount, fullStopTimes, flightPlanId, flightPlan, export metadata
/// - v3: Added block times, departure/arrival airports
/// - v4: Added engine hour meter readings
let currentExportFormatVersion = 4

/// Hard limits for data ingested from untrusted sources (CloudKit records, GPX/JSON import).
/// Shared so the CloudKit ingest cap (SEC-17) and the import caps (SEC-13) never diverge.
enum FlightDataLimits {
    /// Max GPS points in a single flight. A multi-hour flight at 1 Hz is ~tens of thousands, well
    /// under this; exceeding it indicates a corrupt or malicious record.
    static let maxGPSPoints = 100_000
    /// Max waypoints in an imported route.
    static let maxRouteWaypoints = 500
}

/// Pure flight-clock formatting, extracted from `AppState` so the timer/time-of-day rules are
/// unit-testable and de-duplicated. `AppState` keeps the timestamps and delegates formatting.
/// (Phase 4 — AppState decomposition)
enum FlightClock {
    /// Elapsed flight time as `HH:MM:SS` (negative intervals — clock skew — clamp to zero rather
    /// than rendering "-1:-1:..").
    static func formattedDuration(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// A timestamp as a short time-of-day string, with a `" (UTC)"` suffix when the pilot has
    /// forced UTC. The locale/time format itself is left to `DateFormatter`.
    static func formattedTimeOfDay(_ date: Date, useUTC: Bool) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        if useUTC {
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: date) + " (UTC)"
        }
        return formatter.string(from: date)
    }
}

/// The live flight's timing milestones, grouped as one cohesive value extracted from AppState's
/// four formerly-loose @Published timestamps. Distinct from `Flight`'s own (persisted) timing
/// fields of the same names — this is the in-progress session state. AppState owns it via a single
/// `@Published var flightTiming` and exposes thin forwarding accessors for backward compatibility.
/// (Phase 4 — AppState decomposition: state extraction)
struct FlightTiming: Equatable {
    var engineStartTime: Date?
    var lineUpTime: Date?
    var landingTime: Date?
    var engineShutdownTime: Date?
}

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

    // Block times and airport detection (v3)
    var blockOffTime: Date?           // First movement after ENGINE START
    var blockOffLatitude: Double?     // Latitude at block off
    var blockOffLongitude: Double?    // Longitude at block off
    var blockOnTime: Date?            // Final stop before ENGINE STOP
    var blockOnLatitude: Double?      // Latitude at block on
    var blockOnLongitude: Double?     // Longitude at block on
    var departureAirportIdent: String?  // Nearest airport ICAO code at block off
    var arrivalAirportIdent: String?    // Nearest airport ICAO code at block on

    // Engine hour meter readings (v4)
    var engineHourStart: Double?        // Tachometer/hour meter reading at engine start
    var engineHourEnd: Double?          // Tachometer/hour meter reading at engine stop
    var engineHourStartInputFormat: String?  // Raw input format used ("decimal" or "time")
    var engineHourEndInputFormat: String?    // Raw input format used ("decimal" or "time")

    var gpsTrack: [GPSPoint]
    var notes: String
    var goAroundCount: Int
    var touchAndGoCount: Int
    var fullStopCount: Int
    var goAroundTimes: [Date]
    var touchAndGoTimes: [Date]
    var fullStopTimes: [Date]

    // Sync / integrity (v5)
    /// Monotonic last-local-modification timestamp; the CloudKit conflict tiebreaker. (ARCH-02)
    var modifiedAt: Date
    /// Record schema version, for forward-compatible CloudKit/import ingest validation. (SEC-17)
    var schemaVersion: Int

    // Precomputed summary stats (v5) — computed once at save so the flight-log list never
    // recomputes an O(n) distance per row on every re-render. Optional + backward-compatible:
    // legacy records fall back to a lightweight on-demand computation. (PERF-22)
    var cachedDistanceKm: Double?
    var cachedMaxAltitudeMeters: Double?
    var cachedDurationSeconds: Double?

    /// User-pinned flag. Favorited flights sort to the top of the logbook and show a gold star.
    /// Optional + backward-compatible: legacy records decode to `false`. Toggling bumps `modifiedAt`
    /// so it rides the CloudKit conflict tiebreaker like any other scalar edit. (v4 UI/UX Revamp favorites)
    var isFavorite: Bool

    /// Current flight record schema version. Records claiming a higher version come from a newer
    /// app build and are rejected on ingest rather than mis-applied.
    static let currentSchemaVersion = 1

    // MARK: - Coding Keys

    enum CodingKeys: String, CodingKey {
        case id, name, airplane, aircraftRegistration, aircraftType, checklistVersion
        case flightPlanId, flightPlan
        case startTime, stopTime, engineStartTime, lineUpTime, landingTime, engineShutdownTime
        case blockOffTime, blockOffLatitude, blockOffLongitude
        case blockOnTime, blockOnLatitude, blockOnLongitude
        case departureAirportIdent, arrivalAirportIdent
        case engineHourStart, engineHourEnd, engineHourStartInputFormat, engineHourEndInputFormat
        case gpsTrack, notes
        case goAroundCount, touchAndGoCount, fullStopCount
        case goAroundTimes, touchAndGoTimes, fullStopTimes
        case modifiedAt, schemaVersion
        case cachedDistanceKm, cachedMaxAltitudeMeters, cachedDurationSeconds
        case isFavorite
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

        // Block times and airport detection - new in v3, default to nil for backward compatibility
        blockOffTime = try container.decodeIfPresent(Date.self, forKey: .blockOffTime)
        blockOffLatitude = try container.decodeIfPresent(Double.self, forKey: .blockOffLatitude)
        blockOffLongitude = try container.decodeIfPresent(Double.self, forKey: .blockOffLongitude)
        blockOnTime = try container.decodeIfPresent(Date.self, forKey: .blockOnTime)
        blockOnLatitude = try container.decodeIfPresent(Double.self, forKey: .blockOnLatitude)
        blockOnLongitude = try container.decodeIfPresent(Double.self, forKey: .blockOnLongitude)
        departureAirportIdent = try container.decodeIfPresent(String.self, forKey: .departureAirportIdent)
        arrivalAirportIdent = try container.decodeIfPresent(String.self, forKey: .arrivalAirportIdent)

        // Engine hour meter readings - new in v4, default to nil for backward compatibility
        engineHourStart = try container.decodeIfPresent(Double.self, forKey: .engineHourStart)
        engineHourEnd = try container.decodeIfPresent(Double.self, forKey: .engineHourEnd)
        engineHourStartInputFormat = try container.decodeIfPresent(String.self, forKey: .engineHourStartInputFormat)
        engineHourEndInputFormat = try container.decodeIfPresent(String.self, forKey: .engineHourEndInputFormat)

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

        // New in v5 - legacy records default modifiedAt to their stop/start time (a reasonable
        // "last touched" proxy) and schema version 1.
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
            ?? stopTime ?? startTime ?? Date.distantPast
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1

        // v5 precomputed stats — nil for legacy records (computed lazily on demand).
        cachedDistanceKm = try container.decodeIfPresent(Double.self, forKey: .cachedDistanceKm)
        cachedMaxAltitudeMeters = try container.decodeIfPresent(Double.self, forKey: .cachedMaxAltitudeMeters)
        cachedDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .cachedDurationSeconds)

        // New in 3.3 — legacy records (and imports) default to not-favorited.
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
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
        blockOffTime: Date? = nil,
        blockOffLatitude: Double? = nil,
        blockOffLongitude: Double? = nil,
        blockOnTime: Date? = nil,
        blockOnLatitude: Double? = nil,
        blockOnLongitude: Double? = nil,
        departureAirportIdent: String? = nil,
        arrivalAirportIdent: String? = nil,
        engineHourStart: Double? = nil,
        engineHourEnd: Double? = nil,
        engineHourStartInputFormat: String? = nil,
        engineHourEndInputFormat: String? = nil,
        gpsTrack: [GPSPoint] = [],
        notes: String = "",
        goAroundCount: Int = 0,
        touchAndGoCount: Int = 0,
        fullStopCount: Int = 0,
        goAroundTimes: [Date] = [],
        touchAndGoTimes: [Date] = [],
        fullStopTimes: [Date] = [],
        modifiedAt: Date = Date(),
        schemaVersion: Int = Flight.currentSchemaVersion,
        cachedDistanceKm: Double? = nil,
        cachedMaxAltitudeMeters: Double? = nil,
        cachedDurationSeconds: Double? = nil,
        isFavorite: Bool = false
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
        self.blockOffTime = blockOffTime
        self.blockOffLatitude = blockOffLatitude
        self.blockOffLongitude = blockOffLongitude
        self.blockOnTime = blockOnTime
        self.blockOnLatitude = blockOnLatitude
        self.blockOnLongitude = blockOnLongitude
        self.departureAirportIdent = departureAirportIdent
        self.arrivalAirportIdent = arrivalAirportIdent
        self.engineHourStart = engineHourStart
        self.engineHourEnd = engineHourEnd
        self.engineHourStartInputFormat = engineHourStartInputFormat
        self.engineHourEndInputFormat = engineHourEndInputFormat
        self.gpsTrack = gpsTrack
        self.notes = notes
        self.goAroundCount = goAroundCount
        self.touchAndGoCount = touchAndGoCount
        self.fullStopCount = fullStopCount
        self.goAroundTimes = goAroundTimes
        self.touchAndGoTimes = touchAndGoTimes
        self.fullStopTimes = fullStopTimes
        self.modifiedAt = modifiedAt
        self.schemaVersion = schemaVersion
        self.cachedDistanceKm = cachedDistanceKm
        self.cachedMaxAltitudeMeters = cachedMaxAltitudeMeters
        self.cachedDurationSeconds = cachedDurationSeconds
        self.isFavorite = isFavorite
    }

    /// Stamp the flight as locally modified (drives the CloudKit conflict tiebreaker). (ARCH-02)
    mutating func touch() {
        modifiedAt = Date()
    }

    /// Conflict-merge two versions of the same flight. The newer `modifiedAt` wins for scalar
    /// metadata (name, notes, …), but append-only / monotonic data — the GPS track and landing
    /// counts/times — keeps the **richer** side, so a metadata edit on one device can never drop a
    /// longer track or a higher landing count recorded on the other. (ARCH-02)
    static func merge(_ a: Flight, _ b: Flight) -> Flight {
        var result = a.modifiedAt >= b.modifiedAt ? a : b
        result.gpsTrack = a.gpsTrack.count >= b.gpsTrack.count ? a.gpsTrack : b.gpsTrack
        result.goAroundCount = max(a.goAroundCount, b.goAroundCount)
        result.touchAndGoCount = max(a.touchAndGoCount, b.touchAndGoCount)
        result.fullStopCount = max(a.fullStopCount, b.fullStopCount)
        result.goAroundTimes = a.goAroundTimes.count >= b.goAroundTimes.count ? a.goAroundTimes : b.goAroundTimes
        result.touchAndGoTimes = a.touchAndGoTimes.count >= b.touchAndGoTimes.count ? a.touchAndGoTimes : b.touchAndGoTimes
        result.fullStopTimes = a.fullStopTimes.count >= b.fullStopTimes.count ? a.fullStopTimes : b.fullStopTimes
        result.modifiedAt = max(a.modifiedAt, b.modifiedAt)
        return result
    }

    /// Validate a flight decoded from an untrusted source (CloudKit ingest / file import) before it
    /// is applied to local state. Returns nil when the record is structurally unsafe — a newer
    /// (unknown) schema, an unbounded point count, or any non-finite/out-of-range coordinate — so a
    /// corrupt or divergent-schema record can never silently overwrite or persist. (SEC-17)
    func validatedForIngest() -> Flight? {
        guard schemaVersion <= Flight.currentSchemaVersion else { return nil }
        guard gpsTrack.count <= FlightDataLimits.maxGPSPoints else { return nil }
        for point in gpsTrack {
            guard point.latitude.isFinite, point.longitude.isFinite, point.altitude.isFinite,
                  (-90.0...90.0).contains(point.latitude),
                  (-180.0...180.0).contains(point.longitude) else {
                return nil
            }
        }
        return self
    }

    /// Total landings (touch and go + full stops, which now includes the final landing)
    var totalLandings: Int {
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
    
    /// Block time duration (from first movement to last stop)
    var blockTime: TimeInterval? {
        guard let off = blockOffTime, let on = blockOnTime else { return nil }
        return on.timeIntervalSince(off)
    }

    /// Flight time duration (from lineup/takeoff to landing)
    var flightTime: TimeInterval? {
        guard let takeoff = lineUpTime, let landing = landingTime else { return nil }
        let interval = landing.timeIntervalSince(takeoff)
        // A landing recorded before line-up (clock skew / out-of-order events) would read negative;
        // treat it as unavailable rather than show a garbled duration. (v4.0.0 review P2)
        return interval >= 0 ? interval : nil
    }

    /// Block off location as CLLocationCoordinate2D
    var blockOffLocation: CLLocationCoordinate2D? {
        guard let lat = blockOffLatitude, let lon = blockOffLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Block on location as CLLocationCoordinate2D
    var blockOnLocation: CLLocationCoordinate2D? {
        guard let lat = blockOnLatitude, let lon = blockOnLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Engine hours flown (difference between end and start readings)
    var engineHoursFlown: Double? {
        guard let start = engineHourStart, let end = engineHourEnd else { return nil }
        return end - start
    }

    /// Format engine hours as decimal string (e.g., "1234.5")
    static func formatHoursDecimal(_ hours: Double) -> String {
        String(format: "%.2f", hours)
    }

    /// Format engine hours as time string (e.g., "1234:30")
    static func formatHoursTime(_ hours: Double) -> String {
        let wholePart = Int(hours)
        let minutesPart = Int(round((hours - Double(wholePart)) * 60))
        return String(format: "%d:%02d", wholePart, minutesPart)
    }

    /// Format engine hours flown as dual format (e.g., "1.5 / 1:30")
    var engineHoursFlownFormatted: String? {
        guard let flown = engineHoursFlown else { return nil }
        return "\(Flight.formatHoursDecimal(flown)) / \(Flight.formatHoursTime(flown))"
    }

    var formattedBlockTime: String {
        guard let blockTime = blockTime else { return "--:--" }
        let hours = Int(blockTime) / 3600
        let minutes = (Int(blockTime) % 3600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }

    var formattedFlightTime: String {
        guard let flightTime = flightTime else { return "--:--" }
        let hours = Int(flightTime) / 3600
        let minutes = (Int(flightTime) % 3600) / 60
        return String(format: "%02d:%02d", hours, minutes)
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
    
    /// Total distance travelled in kilometers. Uses the value precomputed at save when available;
    /// otherwise computes on demand with a lightweight haversine (no per-segment CLLocation
    /// allocations), so the flight-log list never pays an O(n) `CLLocation.distance` per row. (PERF-22)
    var distanceKilometers: Double {
        if let cached = cachedDistanceKm { return cached }
        return Flight.computeDistanceKm(gpsTrack)
    }

    /// Haversine great-circle distance in metres between two coordinates (no allocations).
    static func haversineMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    static func computeDistanceKm(_ track: [GPSPoint]) -> Double {
        guard track.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<track.count {
            total += haversineMeters(track[i - 1].latitude, track[i - 1].longitude,
                                     track[i].latitude, track[i].longitude)
        }
        return total / 1000.0
    }

    /// Precomputes the summary stats (distance, max altitude, duration) once — call at save, when
    /// the GPS track is final — so the flight-log list reads cached values instead of recomputing. (PERF-22)
    mutating func computeSummaryStats() {
        cachedDistanceKm = Flight.computeDistanceKm(gpsTrack)
        cachedMaxAltitudeMeters = gpsTrack.map(\.altitude).max()
        if let start = startTime, let stop = stopTime {
            cachedDurationSeconds = stop.timeIntervalSince(start)
        }
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
    let horizontalAccuracy: Double?

    init(
        id: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        altitude: Double,
        timestamp: Date = Date(),
        speed: Double = 0,
        course: Double = 0,
        horizontalAccuracy: Double? = nil
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
    }

    init(from location: CLLocation) {
        self.id = UUID()
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.timestamp = location.timestamp
        self.speed = location.speed
        self.course = location.course
        self.horizontalAccuracy = location.horizontalAccuracy
    }
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - GPX Export/Import

extension Flight {
    /// Export flight to GPX format with all timing data in extensions
    func toGPX() -> String {
        // PR-18: escape user-controlled strings so a flight named "Touch & Go" (or with < > " ')
        // doesn't produce malformed XML that XMLParser aborts on at import.
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
             .replacingOccurrences(of: "\"", with: "&quot;")
             .replacingOccurrences(of: "'", with: "&apos;")
        }
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
            <name>\(esc(displayName)) - \(formattedDate)</name>
            <desc>Flight recorded with AéroCheck app</desc>
        """

        if let start = startTime {
            gpx += "\n    <time>\(dateFormatter.string(from: start))</time>"
        }

        gpx += """

          </metadata>
          <trk>
            <name>\(esc(airplane))</name>
            <extensions>
              <pc:flightData>
                <pc:formatVersion>\(currentExportFormatVersion)</pc:formatVersion>
                <pc:appVersion>\(appVersion)</pc:appVersion>
                <pc:name>\(esc(name))</pc:name>
                <pc:airplane>\(esc(airplane))</pc:airplane>
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

        // Block times and airport detection (v3)
        if let blockOff = blockOffTime {
            gpx += "\n        <pc:blockOffTime>\(dateFormatter.string(from: blockOff))</pc:blockOffTime>"
        }
        if let lat = blockOffLatitude {
            gpx += "\n        <pc:blockOffLatitude>\(lat)</pc:blockOffLatitude>"
        }
        if let lon = blockOffLongitude {
            gpx += "\n        <pc:blockOffLongitude>\(lon)</pc:blockOffLongitude>"
        }
        if let blockOn = blockOnTime {
            gpx += "\n        <pc:blockOnTime>\(dateFormatter.string(from: blockOn))</pc:blockOnTime>"
        }
        if let lat = blockOnLatitude {
            gpx += "\n        <pc:blockOnLatitude>\(lat)</pc:blockOnLatitude>"
        }
        if let lon = blockOnLongitude {
            gpx += "\n        <pc:blockOnLongitude>\(lon)</pc:blockOnLongitude>"
        }
        if let dep = departureAirportIdent {
            gpx += "\n        <pc:departureAirportIdent>\(dep)</pc:departureAirportIdent>"
        }
        if let arr = arrivalAirportIdent {
            gpx += "\n        <pc:arrivalAirportIdent>\(arr)</pc:arrivalAirportIdent>"
        }

        // Engine hour meter readings (v4)
        if let hourStart = engineHourStart {
            gpx += "\n        <pc:engineHourStart>\(String(format: "%.2f", hourStart))</pc:engineHourStart>"
        }
        if let hourEnd = engineHourEnd {
            gpx += "\n        <pc:engineHourEnd>\(String(format: "%.2f", hourEnd))</pc:engineHourEnd>"
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
            // PR-18: a literal "]]>" in notes would terminate the CDATA section early; split it.
            let safeNotes = notes.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
            gpx += "\n        <pc:notes><![CDATA[\(safeNotes)]]></pc:notes>"
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
                  <pc:horizontalAccuracy>\(point.horizontalAccuracy ?? -1)</pc:horizontalAccuracy>
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
        case invalidCoordinates

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let underlying):
                return "Invalid JSON format: \(underlying.localizedDescription)"
            case .invalidGPX:
                return "Invalid GPX format"
            case .invalidCoordinates:
                return "Import contains invalid coordinates (out of range or not a number)"
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

        let imported: Flight
        // Try v2 format first (FlightExportWrapper with metadata)
        if let wrapper = try? decoder.decode(FlightExportWrapper.self, from: data) {
            print("[AéroCheck] Imported flight from v2 format (formatVersion: \(wrapper.metadata.formatVersion))")
            imported = wrapper.flight
        } else if let legacyExport = try? decoder.decode(FlightWithNavigationExport.self, from: data) {
            // Legacy FlightWithNavigationExport format (no metadata)
            print("[AéroCheck] Imported flight from legacy FlightWithNavigationExport format")
            imported = legacyExport.flight
        } else {
            // v1 format (direct Flight object - oldest format)
            do {
                imported = try decoder.decode(Flight.self, from: data)
                print("[AéroCheck] Imported flight from v1 format (direct Flight object)")
            } catch {
                print("[AéroCheck] Failed to decode flight from JSON: \(error)")
                throw ImportError.invalidJSON(underlying: error)
            }
        }

        // Reject NaN/Inf/out-of-range coordinates (e.g. a "1e999" overflow that decodes to
        // Infinity) before the flight can reach the map, analyzer, or export. (SEC-08)
        guard imported.importedCoordinatesAreValid else {
            print("[AéroCheck] Rejected flight import: invalid coordinates")
            throw ImportError.invalidCoordinates
        }
        return imported
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

/// Validation helpers for imported geographic data (SEC-08): reject NaN/Inf/out-of-range
/// so AirspaceAnalyzer / ElevationService / export never operate on garbage coordinates.
enum GeoValidation {
    static func isValidLatLon(_ lat: Double, _ lon: Double) -> Bool {
        lat.isFinite && lon.isFinite && (-90.0...90.0).contains(lat) && (-180.0...180.0).contains(lon)
    }
    /// Returns the latitude if finite and in range, else nil.
    static func validLatitude(_ v: Double?) -> Double? {
        guard let v, v.isFinite, (-90.0...90.0).contains(v) else { return nil }
        return v
    }
    /// Returns the longitude if finite and in range, else nil.
    static func validLongitude(_ v: Double?) -> Double? {
        guard let v, v.isFinite, (-180.0...180.0).contains(v) else { return nil }
        return v
    }
    /// Returns the value if finite, else nil (for optional numeric fields).
    static func finite(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }
}

extension Flight {
    /// True if every imported route coordinate (and any block coordinate pair) is finite
    /// and in range. Used to reject a whole import rather than yield a silently-clean route.
    var importedCoordinatesAreValid: Bool {
        for p in gpsTrack where !GeoValidation.isValidLatLon(p.latitude, p.longitude) {
            return false
        }
        if let lat = blockOffLatitude, let lon = blockOffLongitude,
           !GeoValidation.isValidLatLon(lat, lon) {
            return false
        }
        if let lat = blockOnLatitude, let lon = blockOnLongitude,
           !GeoValidation.isValidLatLon(lat, lon) {
            return false
        }
        return true
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
    /// Set if any track point carries an invalid (NaN/Inf/out-of-range) coordinate, in which
    /// case the whole import is rejected rather than yielding a partial/garbage track. (SEC-08)
    private var hasInvalidCoordinate = false
    /// Set if the track exceeds the hard point cap — a crafted file can't OOM/hang the import; it
    /// is rejected with a clear error rather than silently truncated. (SEC-13)
    private var hasTooManyPoints = false
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
        // Defense-in-depth on an attacker-supplied-file import path: never resolve external
        // entities (XXE), so the safe behavior survives any future refactor. (SEC-20)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.parse()
        return (hasInvalidCoordinate || hasTooManyPoints) ? nil : flight
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
               let lat = Double(latStr), let lon = Double(lonStr),
               GeoValidation.isValidLatLon(lat, lon) {
                currentPoint = GPSPoint(latitude: lat, longitude: lon, altitude: 0)
            } else {
                // A trkpt with missing/unparseable/out-of-range coordinates invalidates the import.
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
                        course: point.course,
                        horizontalAccuracy: point.horizontalAccuracy
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
        case "blockOffTime":
            flight?.blockOffTime = dateFormatter.date(from: text)
        case "blockOffLatitude":
            flight?.blockOffLatitude = GeoValidation.validLatitude(Double(text))
        case "blockOffLongitude":
            flight?.blockOffLongitude = GeoValidation.validLongitude(Double(text))
        case "blockOnTime":
            flight?.blockOnTime = dateFormatter.date(from: text)
        case "blockOnLatitude":
            flight?.blockOnLatitude = GeoValidation.validLatitude(Double(text))
        case "blockOnLongitude":
            flight?.blockOnLongitude = GeoValidation.validLongitude(Double(text))
        case "departureAirportIdent":
            flight?.departureAirportIdent = text
        case "arrivalAirportIdent":
            flight?.arrivalAirportIdent = text
        case "engineHourStart":
            flight?.engineHourStart = Double(text)
        case "engineHourEnd":
            flight?.engineHourEnd = Double(text)
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
            if let point = currentPoint, let alt = Double(text), alt.isFinite {
                currentPoint = GPSPoint(
                    id: point.id,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: alt,
                    timestamp: point.timestamp,
                    speed: point.speed,
                    course: point.course,
                    horizontalAccuracy: point.horizontalAccuracy
                )
            }
        case "speed":
            if let point = currentPoint, let spd = Double(text), spd.isFinite {
                currentPoint = GPSPoint(
                    id: point.id,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: point.altitude,
                    timestamp: point.timestamp,
                    speed: spd,
                    course: point.course,
                    horizontalAccuracy: point.horizontalAccuracy
                )
            }
        case "course":
            if let point = currentPoint, let crs = Double(text), crs.isFinite {
                currentPoint = GPSPoint(
                    id: point.id,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: point.altitude,
                    timestamp: point.timestamp,
                    speed: point.speed,
                    course: crs,
                    horizontalAccuracy: point.horizontalAccuracy
                )
            }
        case "horizontalAccuracy":
            if let point = currentPoint, let acc = Double(text), acc.isFinite {
                currentPoint = GPSPoint(
                    id: point.id,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: point.altitude,
                    timestamp: point.timestamp,
                    speed: point.speed,
                    course: point.course,
                    horizontalAccuracy: acc
                )
            }
        case "trkpt":
            if let point = currentPoint {
                if points.count >= FlightDataLimits.maxGPSPoints {
                    hasTooManyPoints = true // stop appending so a crafted file can't OOM the import
                } else {
                    points.append(point)
                }
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

