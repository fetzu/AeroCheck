import Foundation
import CoreGraphics
import CoreLocation

/// Every figure the flight share card prints, worked out here so the card agrees with the Logbook
/// and with itself: the minute rule for durations, one number format, the pilot's distance unit, a
/// time zone on every time, and counts that say what happened. Pure: a flight and the settings in,
/// text out. (6.1)
struct ShareCardFigures {
    let flight: Flight
    /// Distances in NM, else km: the Settings choice the Logbook follows too.
    var nauticalMiles: Bool = true
    /// Times in UTC, else local time (`alwaysUseUTC`).
    var useUTC: Bool = false
    /// Grouping and decimal marks. The words follow the app's language, the digits the region.
    var locale: Locale = .current
    /// What "local time" means: the device's zone, as everywhere else in the app.
    var localTimeZone: TimeZone = .current

    // MARK: - The duration beside the title

    /// Which interval the big figure is. Only `.flight` may be called flight time.
    enum DurationKind: Equatable {
        case flight, block, engine, session
    }

    struct Duration: Equatable {
        let kind: DurationKind
        let minutes: Int
    }

    /// Flight time as logged: take-off to landing, each time to the minute (`Flight.flightMinutes`).
    /// Without a take-off or a landing, the next interval the flight does have, named for what it is:
    /// block, then engine, then the recording itself. Both ends always come from the same interval
    /// (the card used to pair a take-off with a block on), and one out of order is skipped, never
    /// shown negative.
    static func headlineDuration(for flight: Flight) -> Duration? {
        if let minutes = flight.flightMinutes { return Duration(kind: .flight, minutes: minutes) }
        if let minutes = flight.blockMinutes { return Duration(kind: .block, minutes: minutes) }
        if let minutes = loggedMinutes(flight.engineStartTime, flight.engineShutdownTime) {
            return Duration(kind: .engine, minutes: minutes)
        }
        if let minutes = loggedMinutes(flight.startTime, flight.stopTime) {
            return Duration(kind: .session, minutes: minutes)
        }
        return nil
    }

    private static func loggedMinutes(_ start: Date?, _ end: Date?) -> Int? {
        guard let start, let end, end >= start else { return nil }
        return Flight.loggedMinutes(from: start, to: end)
    }

    /// "0:33", "1:40": hours and minutes, as the logbook line and the nav log write a duration.
    static func formattedDuration(minutes: Int) -> String {
        let minutes = max(0, minutes)
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    var headline: Duration? { Self.headlineDuration(for: flight) }

    /// The big figure, "--:--" when the flight has no interval at all.
    var headlineValue: String { headline.map { Self.formattedDuration(minutes: $0.minutes) } ?? "--:--" }

    /// The words under it: "FLIGHT TIME" only when it is one.
    var headlineLabel: String {
        switch headline?.kind ?? .flight {
        case .flight: return L10n.ShareCard.flightTime
        case .block: return L10n.ShareCard.blockTime
        case .engine: return L10n.ShareCard.engineTime
        case .session: return L10n.ShareCard.sessionTime
        }
    }

    // MARK: - Numbers

    /// The card's one number format: the region's grouping ("5’688" in Switzerland), no decimals
    /// unless asked. Every figure on the card goes through here.
    func number(_ value: Double, fractionDigits: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    func number(_ value: Int) -> String { number(Double(value)) }

    /// The highest GPS altitude in whole feet, as the flight's page shows it (the saved maximum,
    /// rounded). Nil without a track.
    var maxAltitudeFeet: Int? {
        let meters = flight.cachedMaxAltitudeMeters ?? flight.gpsTrack.map(\.altitude).max()
        return meters.flatMap { ($0 * 3.28084).safeRoundedInt() }
    }

    /// "5’688 ft". Units keep their ICAO case everywhere on the card: ft, NM, km.
    var maxAltitude: String? { maxAltitudeFeet.map { "\(number($0)) ft" } }

    /// The track's length in the unit chosen in Settings: "52 NM", "96 km", a tenth under 1.
    var distance: String {
        let kilometers = flight.distanceKilometers
        let value = nauticalMiles ? kilometers / 1.852 : kilometers
        guard value.isFinite, value >= 0 else { return "—" }
        let unit = nauticalMiles ? "NM" : "km"
        if value < 1 { return "\(number(value, fractionDigits: 1)) \(unit)" }
        guard let whole = value.safeRoundedInt() else { return "—" }
        return "\(number(whole)) \(unit)"
    }

    // MARK: - Times

    /// "14:18", in UTC or local time as set. The zone goes beside it (`timeZoneLabel`).
    func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = useUTC ? TimeZone(identifier: "UTC") : localTimeZone
        return formatter.string(from: date)
    }

    /// "UTC", or local time in the app's language ("LT", "HL"). The card printed either without
    /// saying which.
    var timeZoneLabel: String { useUTC ? "UTC" : L10n.ShareCard.localTime }

    // MARK: - Counts

    struct Counts: Equatable {
        var landings = 0
        var touchAndGoes = 0
        var goArounds = 0
        var stopAndGoes = 0
        /// Full stops at another aerodrome, before the last landing.
        var stops = 0
    }

    /// The card's counts. Landings is the Logbook's number (touch-and-goes plus full stops), so the
    /// two never disagree. Touch-and-goes and go-arounds both show when both happened (a go-around
    /// used to hide the touch-and-goes). The full stops before the last are split by
    /// `intermediateFullStops`.
    var counts: Counts {
        let split = Self.intermediateFullStops(of: flight)
        return Counts(landings: flight.totalLandings,
                      touchAndGoes: max(0, flight.touchAndGoCount),
                      goArounds: max(0, flight.goAroundCount),
                      stopAndGoes: split.stopAndGoes,
                      stops: split.stops)
    }

    /// How near a full stop must be to an aerodrome the flight used to count as the same aerodrome.
    /// Wide enough for the longest runway and the taxiways around it, narrower than the gap between
    /// two aerodromes.
    static let sameAerodromeRadiusMeters = 2 * 1852.0

    /// How far from a full stop the nearest fix may be for the track to place it.
    static let placementToleranceSeconds: TimeInterval = 120

    /// The full stops before the last one (the last is the flight's landing), split into
    /// stop-and-goes and stops.
    ///
    /// The rule: a full stop before the last is a stop-and-go when the aircraft is back at an
    /// aerodrome of the flight: within 2 NM of the take-off, of an earlier full stop or of the final
    /// landing. Farther than that from all of them, it is a landing at another aerodrome: a stop.
    /// A full stop the track cannot place (no fix within 2 min, or times missing) stays a
    /// stop-and-go, as every non-final full stop was before (decision D1): only the track can show it
    /// was elsewhere.
    static func intermediateFullStops(of flight: Flight) -> (stopAndGoes: Int, stops: Int) {
        let intermediate = max(0, flight.fullStopCount - 1)
        guard intermediate > 0 else { return (0, 0) }

        // Times that do not match the count cannot say which full stop was the last.
        let times = flight.fullStopTimes.sorted()
        guard times.count == flight.fullStopCount else { return (intermediate, 0) }

        let track = flight.gpsTrack
        func position(at time: Date) -> CLLocationCoordinate2D? {
            guard let nearest = track.min(by: {
                abs($0.timestamp.timeIntervalSince(time)) < abs($1.timestamp.timeIntervalSince(time))
            }), abs(nearest.timestamp.timeIntervalSince(time)) <= placementToleranceSeconds else { return nil }
            return nearest.coordinate
        }
        func coordinate(_ latitude: Double?, _ longitude: Double?) -> CLLocationCoordinate2D? {
            guard let latitude, let longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        let takeoff = flight.lineUpTime.flatMap(position(at:))
            ?? coordinate(flight.blockOffLatitude, flight.blockOffLongitude)
            ?? track.first?.coordinate
        let finalLanding = times.last.flatMap(position(at:))
            ?? coordinate(flight.blockOnLatitude, flight.blockOnLongitude)
            ?? track.last?.coordinate

        var aerodromes = [takeoff, finalLanding].compactMap { $0 }
        var stopAndGoes = 0, stops = 0
        for time in times.dropLast() {
            guard let here = position(at: time) else {
                stopAndGoes += 1
                continue
            }
            let atAnAerodromeOfTheFlight = aerodromes.contains {
                Flight.haversineMeters($0.latitude, $0.longitude, here.latitude, here.longitude)
                    <= sameAerodromeRadiusMeters
            }
            if atAnAerodromeOfTheFlight { stopAndGoes += 1 } else { stops += 1 }
            aerodromes.append(here)
        }
        return (stopAndGoes, stops)
    }

    // MARK: - Credit line

    /// The small print for the map and the terrain actually on the card, nil when there are neither.
    /// The README's attributions: "© swisstopo / BAZL" for the aviation charts, "© swisstopo" for its
    /// imagery and its terrain, "Elevation: Open-Meteo"; Apple Maps is named beside its own logo,
    /// which the snapshot carries and the card never crops. (6.1)
    static func credit(mapLayer: ShareCardMapLayer?, terrain: ElevationService.TrackTerrainSource?) -> String? {
        var parts: [String] = []
        switch mapLayer {
        case .icao?, .segelflugkarte?: parts.append(L10n.ShareCard.creditChart)
        case .swissimage?: parts.append(L10n.ShareCard.creditImagery)
        case .standard?, .satellite?: parts.append(L10n.ShareCard.creditAppleMaps)
        case nil: break
        }
        switch terrain {
        case .swisstopo?: parts.append(L10n.ShareCard.creditTerrainSwisstopo)
        case .openMeteo?: parts.append(L10n.ShareCard.creditTerrainOpenMeteo)
        case nil: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// What the card shows in the map's place when it has no map image. (6.1)
enum ShareCardMapPlaceholder: Equatable {
    /// Still loading: nothing, the sheet draws its spinner over it.
    case loading
    /// Fewer than two fixes: there is nothing to draw.
    case noTrack
    /// The tiles or the snapshot did not come (offline, most of the time).
    case unavailable
}

/// How the track is drawn on the card's map: the same on every layer and every device. The map
/// image is 2032 × 1500 pt, drawn at half size on the card, and rendered at 2× whatever the
/// screen, so a 3× iPhone no longer draws a thicker track and bigger dots than an iPad. (6.1)
enum ShareCardMapStyle {
    static let size = CGSize(width: 2032, height: 1500)
    static let renderScale: CGFloat = 2
    /// 7 pt on the card.
    static let trackWidth: CGFloat = 14
    /// 20 pt on the card, with a 2 pt white rim.
    static let markerDiameter: CGFloat = 40
    static let markerRim: CGFloat = 4
}
