import Foundation
import CoreGraphics
import CoreLocation
import MapKit

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
    var distance: String { distance(kilometers: flight.distanceKilometers) }

    /// A length in the unit chosen in Settings, as `distance` writes it: the journey card's total
    /// goes through here too. (6.1)
    func distance(kilometers: Double) -> String {
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

    /// Under the row of times, once for all of them: "Local time · UTC+2", or "Times in UTC". The
    /// card printed either without saying which. (6.1)
    var timeNote: String {
        guard !useUTC else { return L10n.ShareCard.timesInUTC }
        let reference = flight.lineUpTime ?? flight.blockOffTime ?? flight.startTime ?? Date()
        return L10n.ShareCard.localTimeNote(Self.utcOffset(localTimeZone.secondsFromGMT(for: reference)))
    }

    /// "UTC+2", "UTC+5:30", "UTC-3", "UTC".
    static func utcOffset(_ seconds: Int) -> String {
        guard seconds != 0 else { return "UTC" }
        let sign = seconds > 0 ? "+" : "-"
        let minutes = abs(seconds) / 60
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "UTC\(sign)\(hours)" : String(format: "UTC%@%d:%02d", sign, hours, rest)
    }

    /// The words under the take-off to landing span of the Full map style: "LOCAL TIME" or "UTC".
    var timeZoneLabel: String { useUTC ? "UTC" : L10n.ShareCard.localTimeLabel }

    // MARK: - The tuned card's figures (6.1)

    /// Block time as logged, "0:42"; nil without a block off and a block on in order.
    var blockTime: String? { flight.blockMinutes.map(Self.formattedDuration(minutes:)) }

    /// The highest ground speed of the track, in whole knots. CoreLocation's -1 ("unknown") and
    /// anything not finite are left out; nil when no fix knows its speed.
    var maxGroundSpeedKnots: Int? {
        let speeds = flight.gpsTrack.map(\.speed).filter { $0.isFinite && $0 >= 0 }
        return speeds.max().flatMap { ($0 * 1.943_844).safeRoundedInt() }
    }

    /// "113 kt". Speeds stay in knots whatever the distance unit, as everywhere in the cockpit.
    var maxGroundSpeed: String? { maxGroundSpeedKnots.map { "\(number($0)) kt" } }

    /// "11:46–12:19": take-off to landing, for the Full map style. Nil without both.
    var airborneSpan: String? {
        guard let takeoff = flight.lineUpTime, let landing = flight.landingTime, landing >= takeoff else { return nil }
        return "\(time(takeoff))–\(time(landing))"
    }

    /// One time of the row under the profile.
    struct TimeCell: Equatable {
        enum Kind: Equatable { case blockOff, takeoff, landing, blockOn }
        let kind: Kind
        let value: String
    }

    /// Block off, take-off, landing, block on: the four times a pilot logs, the ones the flight has.
    var timeCells: [TimeCell] {
        let times: [(TimeCell.Kind, Date?)] = [(.blockOff, flight.blockOffTime), (.takeoff, flight.lineUpTime),
                                               (.landing, flight.landingTime), (.blockOn, flight.blockOnTime)]
        return times.compactMap { kind, date in date.map { TimeCell(kind: kind, value: time($0)) } }
    }

    /// Whether the card needs its row of counts: only when something happened besides the one
    /// landing the times already show (touch-and-goes, go-arounds, stop-and-goes, stops elsewhere).
    var showsCounts: Bool {
        let counts = self.counts
        return counts.touchAndGoes + counts.goArounds + counts.stopAndGoes + counts.stops > 0
    }

    /// The aircraft beside the registration: the plan's model name ("WT9 Dynamic") when the plan was
    /// made for this aircraft, else the flight's type ("WT9").
    var aircraftModel: String? {
        if let plan = flight.flightPlan, let registration = flight.aircraftRegistration,
           !registration.isEmpty, plan.aircraftRegistration == registration,
           let model = Flight.nonBlank(plan.aircraftModelName) {
            return model
        }
        return flight.aircraftType.flatMap(Flight.nonBlank)
    }

    /// The line under the title: the aerodromes' names, in the title's order. "Bressaucourt →
    /// Ecuvillens", "Bressaucourt · circuits", "Bressaucourt" for a round flight. `name` gives an
    /// aerodrome's name by its ident (nil when unknown, and the ident stands in for it). Nil when no
    /// name is known: the title already says the idents.
    static func aerodromeLine(for flight: Flight, name: (String) -> String?) -> String? {
        let circuits = L10n.Flights.circuits.localizedLowercase
        func named(_ ident: String?) -> String? { ident.flatMap(name).map(shortAerodromeName) }
        switch flight.routeShape {
        case let .between(departure, arrival, withCircuits):
            let from = named(departure), to = named(arrival)
            guard from != nil || to != nil else { return withCircuits ? circuits : nil }
            let line = "\(from ?? departure) → \(to ?? arrival)"
            return withCircuits ? "\(line) · \(circuits)" : line
        case let .circuits(at):
            return named(at).map { "\($0) · \(circuits)" } ?? circuits
        case let .roundTrip(at):
            return named(at)
        case let .oneEnd(departure, arrival):
            guard named(departure) != nil || named(arrival) != nil else { return nil }
            return "\(named(departure) ?? departure ?? Flight.unknownAerodrome) → \(named(arrival) ?? arrival ?? Flight.unknownAerodrome)"
        case .unnamed:
            return nil
        }
    }

    /// "Bressaucourt" for "Bressaucourt Airfield": the name without the word that says it is one
    /// (OurAirports), and OpenAIP's capitals set in title case, as the briefing does.
    static func shortAerodromeName(_ name: String) -> String {
        var short = name.trimmingCharacters(in: .whitespaces)
        for suffix in [" Airfield", " Airport", " Aerodrome", " Airstrip", " Aeródromo", " Flugplatz"]
        where short.count > suffix.count && short.hasSuffix(suffix) {
            // "La Gruyère  Airport" (two spaces, OurAirports) kept one of them. (6.1)
            short = String(short.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if short == short.uppercased(), short.contains(where: \.isLetter) {
            short = short.capitalized(with: Locale(identifier: "en_US_POSIX"))
        }
        return short
    }

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
        credit(map: mapLayer?.credit, terrain: terrain)
    }

    /// The credit for the map actually drawn, which is not always the layer picked: a circuit on
    /// an aviation chart is drawn on the national map (`ShareCardMapZoom.choice`). (6.1)
    static func credit(map: ShareCardMapCredit?, terrain: ElevationService.TrackTerrainSource?) -> String? {
        credit(map: map, terrains: terrain.map { [$0] } ?? [])
    }

    /// The same for several tracks' terrain (the journey card): each source named once, swisstopo
    /// first. (6.1)
    static func credit(map: ShareCardMapCredit?, terrains: [ElevationService.TrackTerrainSource]) -> String? {
        var parts: [String] = []
        switch map {
        case .chart?: parts.append(L10n.ShareCard.creditChart)
        case .imagery?: parts.append(L10n.ShareCard.creditImagery)
        case .nationalMap?: parts.append(L10n.ShareCard.creditNationalMap)
        case .appleMaps?: parts.append(L10n.ShareCard.creditAppleMaps)
        case nil: break
        }
        if terrains.contains(.swisstopo) { parts.append(L10n.ShareCard.creditTerrainSwisstopo) }
        if terrains.contains(.openMeteo) { parts.append(L10n.ShareCard.creditTerrainOpenMeteo) }
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
/// image is twice its frame on the card in points (2032 × 1500 pt for a 1016 × 750 frame), drawn at
/// half size on a card rendered at 2×, so one point of the image is one pixel of the shared image.
/// It is rendered at a fixed scale whatever the screen, so a 3× iPhone no longer draws a thicker
/// track and bigger dots than an iPad, and at 1×: at 2× it was 4 times the pixels the card keeps
/// (85 MB for the Full map band). Sizes are in the image's points: half of it on the card. (6.1)
struct ShareCardMapStyle: Equatable {
    static let renderScale: CGFloat = 1
    /// The map image's points per point of its frame on the card.
    static let imagePointsPerCardPoint: CGFloat = 2

    /// 7 pt on the card.
    var trackWidth: CGFloat = 14
    /// 20 pt on the card, with a 2 pt white rim.
    var markerDiameter: CGFloat = 40
    var markerRim: CGFloat = 4
    /// A waypoint's diamond: an 11 pt square on its corner, with a 2.5 pt rim of the card's navy.
    var waypointSide: CGFloat = 22
    var waypointRim: CGFloat = 5
    /// Its name beside it, in B612 Mono Bold 17 on the card, over a 2.5 pt halo.
    var waypointFontSize: CGFloat = 34
    var waypointHalo: CGFloat = 10

    /// The tuned card (A): the mockup's 7 pt track and 20 pt dots.
    static let standard = ShareCardMapStyle()
    /// Full map (C): the chart is bigger, and so are the track and the dots (8 pt, 26 pt).
    static let fullMap = ShareCardMapStyle(trackWidth: 16, markerDiameter: 52, markerRim: 5)

    /// The size of the image for a frame on the card.
    static func imageSize(for frame: CGSize) -> CGSize {
        CGSize(width: (frame.width * imagePointsPerCardPoint).rounded(),
               height: (frame.height * imagePointsPerCardPoint).rounded())
    }
}

// MARK: - Style and format (6.1)

/// The card's two looks: the tuned card (A), and the chart edge to edge (C). (6.1, Q4)
enum ShareCardStyle: String, CaseIterable, Identifiable {
    case standard
    case fullMap

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return L10n.ShareCard.styleStandard
        case .fullMap: return L10n.ShareCard.styleFullMap
        }
    }
}

/// The card's two shapes: 9:16 for stories, 4:5 for feed posts. (6.1, Q7)
enum ShareCardFormat: String, CaseIterable, Identifiable {
    case story
    case feed

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .story: return CGSize(width: 1080, height: 1920)
        case .feed: return CGSize(width: 1080, height: 1350)
        }
    }

    /// "9:16", "4:5": numbers, the same in every language.
    var ratioLabel: String {
        switch self {
        case .story: return "9:16"
        case .feed: return "4:5"
        }
    }

    var accessibilityName: String {
        switch self {
        case .story: return L10n.ShareCard.formatStory
        case .feed: return L10n.ShareCard.formatFeed
        }
    }
}

/// Where everything sits on the card, for a style and a format. Every block has a fixed height, and
/// the map takes what is left, so the card has no empty band (the old card left up to 388 pt above
/// the footer) and the map image can be made at the exact shape of its frame. Pure. (6.1)
struct ShareCardLayout: Equatable {
    let style: ShareCardStyle
    let format: ShareCardFormat
    /// The route strip is drawn (the flight has a route of two aerodromes or more).
    let hasRouteStrip: Bool
    /// The row of counts is drawn (circuits: touch-and-goes, go-arounds…).
    let hasCounts: Bool

    var canvas: CGSize { format.size }
    private var isStory: Bool { format == .story }

    // Margins: 48 pt for text, 32 pt for the boxes (map, tiles, profile, times).
    let textMargin: CGFloat = 48
    let boxMargin: CGFloat = 32

    // The top and the title.
    var topPadding: CGFloat { isStory ? 48 : 40 }
    let topBarHeight: CGFloat = 44
    var titleGap: CGFloat { isStory ? 26 : 18 }
    var titleFont: CGFloat {
        switch (style, format) {
        case (.standard, .story): return 66
        case (.standard, .feed): return 54
        case (.fullMap, .story): return 78
        case (.fullMap, .feed): return 64
        }
    }
    var durationFont: CGFloat { (titleFont * 0.88).rounded() }
    var subtitleFont: CGFloat { isStory ? 25 : 22 }
    var titleBlockHeight: CGFloat { (titleFont * 1.12 + 10 + subtitleFont * 1.3).rounded(.up) }

    // The route strip.
    var routeGap: CGFloat { isStory ? 30 : 20 }
    var routeHeight: CGFloat { isStory ? 84 : 72 }
    var routeNameFont: CGFloat { isStory ? 19 : 17 }
    var routeTimeFont: CGFloat { isStory ? 16 : 14 }

    // The map, then the figures under it (Standard).
    var mapGap: CGFloat { hasRouteStrip ? (isStory ? 16 : 14) : (isStory ? 28 : 20) }
    var tilesGap: CGFloat { isStory ? 16 : 12 }
    var tileHeight: CGFloat { isStory ? 112 : 92 }
    var tileValueFont: CGFloat { isStory ? 30 : 26 }
    /// "ALTITUDE PROFILE … PEAK": on the story only (the feed has the peak in its tiles).
    var hasProfileHeader: Bool { isStory }
    var profileGap: CGFloat { isStory ? 20 : 12 }
    let profileHeaderHeight: CGFloat = 18
    let profileHeaderGap: CGFloat = 12
    var profileHeight: CGFloat { isStory ? 270 : 150 }
    var timesGap: CGFloat { isStory ? 22 : 12 }
    var timesHeight: CGFloat { isStory ? 112 : 88 }
    var timeValueFont: CGFloat { isStory ? 32 : 26 }
    var noteGap: CGFloat { isStory ? 10 : 6 }
    var noteHeight: CGFloat { isStory ? 18 : 16 }
    var countsGap: CGFloat { isStory ? 12 : 10 }
    var countsHeight: CGFloat { isStory ? 76 : 64 }
    var footerGap: CGFloat { isStory ? 22 : 16 }
    let footerHeight: CGFloat = 50
    var bottomPadding: CGFloat { isStory ? 44 : 32 }

    // Full map: the band and the panel.
    /// The panel at the foot: the four figures, the profile, the footer.
    var panelMargin: CGFloat { isStory ? 32 : 28 }
    var panelPadding: CGFloat { isStory ? 26 : 22 }
    var panelFiguresHeight: CGFloat { isStory ? 58 : 50 }
    var panelSpacing: CGFloat { isStory ? 18 : 14 }
    var panelProfileHeight: CGFloat { isStory ? 150 : 110 }
    var panelHeight: CGFloat {
        panelPadding + panelFiguresHeight + panelSpacing + panelProfileHeight + panelSpacing + footerHeight + panelPadding
    }
    /// The band starts under the title and stops short of the panel.
    var bandTop: CGFloat { topPadding + topBarHeight + titleGap + titleBlockHeight + (isStory ? 22 : 12) }
    var bandBottom: CGFloat { canvas.height - panelMargin - panelHeight - (isStory ? 34 : 24) }
    /// How far the band fades into the card's colour, top and bottom.
    var fadeTop: CGFloat { isStory ? 120 : 90 }
    var fadeBottom: CGFloat { isStory ? 116 : 86 }

    /// The map's frame on the card. Standard: 1016 pt wide, as tall as the rest leaves. Full map:
    /// the band, edge to edge.
    var mapFrame: CGSize {
        switch style {
        case .standard:
            var used = topPadding + topBarHeight + titleGap + titleBlockHeight + mapGap
            if hasRouteStrip { used += routeGap + routeHeight }
            used += tilesGap + tileHeight
            used += profileGap + (hasProfileHeader ? profileHeaderHeight + profileHeaderGap : 0) + profileHeight
            used += timesGap + timesHeight + noteGap + noteHeight
            if hasCounts { used += countsGap + countsHeight }
            used += footerGap + footerHeight + bottomPadding
            return CGSize(width: canvas.width - 2 * boxMargin, height: max(200, canvas.height - used))
        case .fullMap:
            return CGSize(width: canvas.width, height: max(200, bandBottom - bandTop))
        }
    }

    /// The share of the map's height at the top and the bottom that the track keeps clear of: the
    /// fades of the Full map band, where the chart runs into the title and the panel.
    var mapClearTop: CGFloat { style == .fullMap ? fadeTop / mapFrame.height : 0 }
    var mapClearBottom: CGFloat { style == .fullMap ? fadeBottom / mapFrame.height : 0 }

    var mapStyle: ShareCardMapStyle { style == .fullMap ? .fullMap : .standard }
}

// MARK: - The route as flown (6.1)

/// One point of the route strip: where the flight went, with the time it was there.
struct ShareCardRouteStop: Equatable {
    enum Role: Equatable { case departure, waypoint, arrival }
    /// As the strip writes it: the long form, "E (LSGC)".
    let name: String
    /// As the profile writes it: the compact form, "E".
    let shortName: String
    /// The actual time over (take-off and landing for the ends).
    let time: Date?
    let role: Role
}

/// The route the card shows, which is the one FLOWN (B12): the waypoints the aircraft came abeam of,
/// each with its actual time over, from the aerodrome it took off from to the one it landed at. The
/// plan is only where the names come from. Pure. (6.1)
enum ShareCardRoute {

    /// The strip's points, departure to arrival.
    ///
    /// - The ends are the flight's own aerodromes (`Flight.title`'s), with the take-off and the
    ///   landing times. A diversion ends at the field landed at; a flight that landed elsewhere than
    ///   planned ends at the aerodrome it landed at, "?" when that one is not known.
    /// - In between, the plan's waypoints with an actual time over, in the plan's order. A waypoint
    ///   the aircraft never came abeam of (a corner cut, the rest of a route left for a diversion, one
    ///   the pilot took back) was not flown and is not shown.
    /// - A point without a name keeps its place as "WPT 3", its number in the route, as the nav map
    ///   calls it: it used to be dropped without a trace.
    ///
    /// Without a plan the strip is the two aerodromes, and nothing when there is only one (circuits,
    /// a round flight): the title already says it.
    static func flown(_ flight: Flight, plan: FlightPlan?) -> [ShareCardRouteStop] {
        let takeoff = flight.lineUpTime, landing = flight.landingTime
        let departureIdent = flight.departureAirportIdent.flatMap(Flight.nonBlank)
        let arrivalIdent = flight.arrivalAirportIdent.flatMap(Flight.nonBlank)

        guard let plan, plan.waypoints.count >= 2 else {
            guard let departureIdent, let arrivalIdent, departureIdent != arrivalIdent else { return [] }
            return [ShareCardRouteStop(name: departureIdent, shortName: departureIdent, time: takeoff, role: .departure),
                    ShareCardRouteStop(name: arrivalIdent, shortName: arrivalIdent, time: landing, role: .arrival)]
        }

        let waypoints = plan.waypoints
        let first = waypoints[0], last = waypoints[waypoints.count - 1]

        // Departure: the plan's when the flight left from it, else the aerodrome it left from.
        let departure: ShareCardRouteStop
        if let departureIdent, !names(first, departureIdent) {
            departure = ShareCardRouteStop(name: departureIdent, shortName: departureIdent,
                                           time: takeoff, role: .departure)
        } else if departureIdent != nil || first.actualTimeOver != nil || takeoff == nil {
            departure = stop(first, at: 0, time: takeoff ?? first.actualTimeOver, role: .departure)
        } else {
            departure = ShareCardRouteStop(name: Flight.unknownAerodrome, shortName: Flight.unknownAerodrome,
                                           time: takeoff, role: .departure)
        }

        let enRoute = waypoints.indices.dropFirst().dropLast().compactMap { index -> ShareCardRouteStop? in
            let waypoint = waypoints[index]
            guard let time = waypoint.actualTimeOver else { return nil }
            return stop(waypoint, at: index, time: time, role: .waypoint)
        }

        // Arrival: the field landed at.
        let arrival: ShareCardRouteStop
        if let diversion = plan.diversion {
            let ident = arrivalIdent ?? diversion.ident
            arrival = ShareCardRouteStop(name: ident, shortName: ident, time: landing ?? diversion.landedAt, role: .arrival)
        } else if let arrivalIdent, !names(last, arrivalIdent) {
            arrival = ShareCardRouteStop(name: arrivalIdent, shortName: arrivalIdent, time: landing, role: .arrival)
        } else if arrivalIdent != nil || last.actualTimeOver != nil || landing == nil {
            arrival = stop(last, at: waypoints.count - 1, time: landing ?? last.actualTimeOver, role: .arrival)
        } else {
            arrival = ShareCardRouteStop(name: Flight.unknownAerodrome, shortName: Flight.unknownAerodrome,
                                         time: landing, role: .arrival)
        }

        let stops = [departure] + enRoute + [arrival]
        // A route with nothing between two ends that are the same aerodrome says nothing.
        if stops.count == 2, departure.name == arrival.name { return [] }
        return stops
    }

    /// A waypoint's name in `form`, "WPT 3" (its number in the route) when it has none.
    static func label(_ waypoint: FlightPlanWaypoint, at index: Int, form: RouteNameForm) -> String {
        let name = waypoint.routeName(form).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "WPT \(index + 1)" : name
    }

    /// The plan's waypoints between its two aerodromes, for the map: where each is and its compact
    /// name. Drawn whether flown or not: the map shows the plan and the track together.
    static func mapWaypoints(_ plan: FlightPlan?) -> [ShareCardMapWaypoint] {
        guard let waypoints = plan?.waypoints, waypoints.count > 2 else { return [] }
        return waypoints.indices.dropFirst().dropLast().map { index in
            ShareCardMapWaypoint(coordinate: waypoints[index].coordinate,
                                 label: label(waypoints[index], at: index, form: .compact))
        }
    }

    /// The plan with each reporting point that has no aerodrome on it given the one `aerodromeICAO`
    /// finds: plans made before 6.0.1 stored "E" without "LSGC". Nothing else changes.
    static func qualifyingReportingPoints(_ plan: FlightPlan,
                                          aerodromeICAO: (FlightPlanWaypoint) -> String?) -> FlightPlan {
        var plan = plan
        for index in plan.waypoints.indices where plan.waypoints[index].pointKind == .vrp
            && (plan.waypoints[index].aerodromeICAO ?? "").isEmpty {
            plan.waypoints[index].aerodromeICAO = aerodromeICAO(plan.waypoints[index])
        }
        return plan
    }

    private static func stop(_ waypoint: FlightPlanWaypoint, at index: Int, time: Date?,
                             role: ShareCardRouteStop.Role) -> ShareCardRouteStop {
        ShareCardRouteStop(name: label(waypoint, at: index, form: .shareCard),
                           shortName: label(waypoint, at: index, form: .compact),
                           time: time, role: role)
    }

    /// Whether a plan's end waypoint is this aerodrome: by its name ("LSZQ") or by the aerodrome it
    /// was made from.
    private static func names(_ waypoint: FlightPlanWaypoint, _ ident: String) -> Bool {
        let ident = ident.uppercased()
        return [waypoint.name, waypoint.sourceId, waypoint.aerodromeICAO]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces).uppercased() }
            .contains(ident)
    }
}

/// A plan's waypoint as the map draws it: a small diamond and its name.
struct ShareCardMapWaypoint: Equatable {
    let coordinate: CLLocationCoordinate2D
    let label: String

    static func == (a: Self, b: Self) -> Bool {
        a.label == b.label && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
    }
}

// MARK: - The route strip's layout (6.1)

/// Where each point of the route strip goes. Every point is shown while the names fit side by
/// side; only past that are the middle ones folded into one "···" (the old strip folded anything
/// over seven points, "E (LSGC)" or not). Pure: the widths come in. (6.1)
enum ShareCardRouteStrip {

    enum Item: Equatable {
        case stop(ShareCardRouteStop)
        /// Points folded away, with how many.
        case more(Int)
    }

    struct Placed: Equatable {
        let item: Item
        /// The dot, from the strip's left edge.
        let dotX: CGFloat
        /// The label under it: its left edge and width. The first is left-aligned under its dot, the
        /// last right-aligned, the others centred.
        let labelX: CGFloat
        let labelWidth: CGFloat
    }

    /// The room left between two labels.
    static let minimumGap: CGFloat = 18
    /// The "···" and its "+3".
    static let moreWidth: CGFloat = 44

    /// Evenly spaced dots when the labels fit so; else labels packed with equal gaps; else the
    /// middle points folded, keeping as many as fit from both ends (one more at the start).
    static func layout(_ stops: [ShareCardRouteStop], width: CGFloat,
                       labelWidth: (ShareCardRouteStop) -> CGFloat) -> [Placed] {
        guard stops.count >= 2 else { return [] }
        let widths = stops.map { min(labelWidth($0), width / 2) }
        let all = stops.map { Item.stop($0) }
        if let placed = place(all, widths: widths, width: width) { return placed }

        // Keep `kept` points (both ends included), the rest folded between the two halves.
        for kept in stride(from: stops.count - 1, through: 2, by: -1) {
            let head = (kept + 1) / 2, tail = kept - head
            let hidden = stops.count - kept
            let items = Array(all.prefix(head)) + [.more(hidden)] + Array(all.suffix(tail))
            let itemWidths = Array(widths.prefix(head)) + [moreWidth] + Array(widths.suffix(tail))
            if let placed = place(items, widths: itemWidths, width: width) { return placed }
        }
        // Two names too long for the strip even alone: the ends, packed; the view shrinks them.
        let ends = [all[0], .more(stops.count - 2), all[all.count - 1]]
        return pack(stops.count > 2 ? ends : [all[0], all[all.count - 1]],
                    widths: stops.count > 2 ? [widths[0], moreWidth, widths[widths.count - 1]]
                                            : [widths[0], widths[widths.count - 1]],
                    width: width, force: true) ?? []
    }

    private static func place(_ items: [Item], widths: [CGFloat], width: CGFloat) -> [Placed]? {
        even(items, widths: widths, width: width) ?? pack(items, widths: widths, width: width, force: false)
    }

    /// Dots at equal steps, as the mockup: the labels must not touch.
    private static func even(_ items: [Item], widths: [CGFloat], width: CGFloat) -> [Placed]? {
        let n = items.count
        let step = width / CGFloat(n - 1)
        var placed: [Placed] = []
        for index in items.indices {
            let x = CGFloat(index) * step
            let w = widths[index]
            let labelX = index == 0 ? 0 : (index == n - 1 ? width - w : x - w / 2)
            placed.append(Placed(item: items[index], dotX: x, labelX: labelX, labelWidth: w))
        }
        for (a, b) in zip(placed, placed.dropFirst()) where a.labelX + a.labelWidth + minimumGap > b.labelX {
            return nil
        }
        return placed
    }

    /// Labels side by side with equal gaps, each dot over its label.
    private static func pack(_ items: [Item], widths: [CGFloat], width: CGFloat, force: Bool) -> [Placed]? {
        let n = items.count
        let total = widths.reduce(0, +)
        let gap = (width - total) / CGFloat(n - 1)
        guard force || gap >= minimumGap else { return nil }
        var x: CGFloat = 0
        var placed: [Placed] = []
        for index in items.indices {
            let w = widths[index]
            let dot = index == 0 ? 0 : (index == n - 1 ? width : x + w / 2)
            let labelX = index == n - 1 ? width - w : x
            placed.append(Placed(item: items[index], dotX: dot, labelX: labelX, labelWidth: w))
            x += w + max(gap, 0)
        }
        return placed
    }
}

// MARK: - The map's tiles and zoom (6.1)

/// What the credit line names for the map on the card.
enum ShareCardMapCredit: Equatable {
    /// The aviation charts: "Chart © swisstopo / BAZL".
    case chart
    /// SWISSIMAGE: "Imagery © swisstopo".
    case imagery
    /// The national map: "National map © swisstopo".
    case nationalMap
    /// MapKit: "Map: Apple Maps".
    case appleMaps
}

/// A swisstopo WMTS layer the card's map is made of (EPSG:3857 tiles from wmts.geo.admin.ch).
struct ShareCardTileSource: Equatable {
    let layerIdentifier: String
    let fileExtension: String
    let minZoom: Int
    /// The highest zoom the layer serves with content: ICAO 11 (z12 is a 334-byte blank, probed
    /// 29 Sep 2026), the glider chart 12.
    let maxZoom: Int
    let credit: ShareCardMapCredit
    let isAviationChart: Bool

    static let icaoChart = ShareCardTileSource(layerIdentifier: "ch.bazl.luftfahrtkarten-icao", fileExtension: "png",
                                               minZoom: 7, maxZoom: 11, credit: .chart, isAviationChart: true)
    static let gliderChart = ShareCardTileSource(layerIdentifier: "ch.bazl.segelflugkarte", fileExtension: "png",
                                                 minZoom: 7, maxZoom: 12, credit: .chart, isAviationChart: true)
    static let swissimage = ShareCardTileSource(layerIdentifier: "ch.swisstopo.swissimage", fileExtension: "jpeg",
                                                minZoom: 7, maxZoom: 12, credit: .imagery, isAviationChart: false)
    /// The nav map's Landeskarte: sharp from the country down to a circuit.
    static let nationalMap = ShareCardTileSource(layerIdentifier: "ch.swisstopo.pixelkarte-farbe", fileExtension: "jpeg",
                                                 minZoom: 7, maxZoom: 18, credit: .nationalMap, isAviationChart: false)

    func url(z: Int, x: Int, y: Int) -> URL? {
        SwisstopoTiles.url(layer: layerIdentifier, z: z, x: x, y: y, fileExtension: fileExtension)
    }
}

/// Which tiles, at which zoom. Pure. (6.1)
enum ShareCardMapZoom {
    /// Beyond this the chart's own pixels are blown up on the card: the aviation charts give way to
    /// the national map (approved Q6). A circuit on the ICAO chart was enlarged about 50×.
    static let maxEnlargement = 2.0

    /// The card's rule since 5.x: the highest zoom, up to the layer's, whose tiles across the map are
    /// no more than 1.5 × its width in pixels (tiles are then drawn at 0.67–1.33×). `outputWidth` is
    /// the map's width in the shared image's pixels; `lonSpan` the map's width in degrees.
    static func zoom(lonSpan: Double, outputWidth: Double, minZoom: Int, maxZoom: Int) -> Int {
        for z in stride(from: maxZoom, through: minZoom, by: -1)
        where tilePixels(lonSpan: lonSpan, zoom: z) <= outputWidth * 1.5 {
            return z
        }
        return minZoom
    }

    /// Pixels of the image per pixel of the tiles: above 1 the chart is enlarged.
    static func enlargement(lonSpan: Double, outputWidth: Double, zoom: Int) -> Double {
        let tiles = tilePixels(lonSpan: lonSpan, zoom: zoom)
        return tiles > 0 ? outputWidth / tiles : .infinity
    }

    /// The tiles the map is made of: the picked layer's at its best zoom, unless it is an aviation
    /// chart that would be enlarged past `maxEnlargement`. Then the glider chart (1:300 000, one zoom
    /// further) when it stays within it, as the nav map goes from the ICAO chart to the glider chart
    /// when zooming in; and the national map when both aviation charts would be enlarged past it
    /// (circuits, local flights). The 29 Sep leg 2 (LSGE → LSGN, 41 NM) needs the ICAO chart at 2.3×:
    /// it gets the glider chart at 1.15×, not the national map. Nil for Apple's maps, which MapKit
    /// draws at any scale.
    static func choice(for layer: ShareCardMapLayer, lonSpan: Double,
                       outputWidth: Double) -> (source: ShareCardTileSource, zoom: Int)? {
        guard let picked = layer.tileSource else { return nil }
        func best(_ source: ShareCardTileSource) -> (source: ShareCardTileSource, zoom: Int, sharp: Bool) {
            let z = zoom(lonSpan: lonSpan, outputWidth: outputWidth, minZoom: source.minZoom, maxZoom: source.maxZoom)
            return (source, z, enlargement(lonSpan: lonSpan, outputWidth: outputWidth, zoom: z) <= maxEnlargement)
        }
        let first = best(picked)
        guard picked.isAviationChart, !first.sharp else { return (first.source, first.zoom) }
        if picked != .gliderChart {
            let glider = best(.gliderChart)
            if glider.sharp { return (glider.source, glider.zoom) }
        }
        let national = best(.nationalMap)
        return (national.source, national.zoom)
    }

    private static func tilePixels(lonSpan: Double, zoom: Int) -> Double {
        lonSpan / 360 * pow(2, Double(zoom)) * 256
    }
}

/// What part of the world the map shows. Pure. (6.1)
enum ShareCardMapFraming {
    /// Room around the track, on each side, as a share of its extent.
    static let padding = 0.15
    /// Above and below the track when the fades already frame it (Full map): the track runs up to
    /// them, as in the mockup.
    static let paddingInsideFades = 0.04

    /// The track's bounding box with `padding` around it, widened to the image's shape around its
    /// centre, the track kept out of the top and bottom shares `clearTop` and `clearBottom` (the
    /// Full map band's fades). A track that is a point gets a few hundred metres around it.
    static func rect(for track: [CLLocationCoordinate2D], aspect: Double,
                     clearTop: Double = 0, clearBottom: Double = 0) -> MKMapRect? {
        guard !track.isEmpty, aspect > 0 else { return nil }
        var box = MKPolyline(coordinates: track, count: track.count).boundingMapRect
        let minimum = 500 * MKMapPointsPerMeterAtLatitude(track[0].latitude)
        if box.size.width < minimum || box.size.height < minimum {
            let grow = max(0, minimum - min(box.size.width, box.size.height)) / 2
            box = box.insetBy(dx: -grow, dy: -grow)
        }
        let vertical = clearTop + clearBottom > 0 ? paddingInsideFades : padding
        var rect = box.insetBy(dx: -box.size.width * padding, dy: -box.size.height * vertical)
        let visible = max(0.2, 1 - clearTop - clearBottom)
        let innerAspect = aspect / visible
        if rect.size.width / rect.size.height > innerAspect {
            let height = rect.size.width / innerAspect
            rect.origin.y -= (height - rect.size.height) / 2
            rect.size.height = height
        } else {
            let width = rect.size.height * innerAspect
            rect.origin.x -= (width - rect.size.width) / 2
            rect.size.width = width
        }
        let fullHeight = rect.size.height / visible
        rect.origin.y -= fullHeight * clearTop
        rect.size.height = fullHeight
        return rect
    }
}

// MARK: - Hide where I parked (6.1, Q7)

enum ShareCardPrivacy {
    /// How much of each end of the track "Hide where I parked" takes away.
    static let parkingTrimMeters = 300.0

    /// The track from where the aircraft was first `meters` away from where it started, to where it
    /// was last `meters` away from where it stopped: the ends cut by distance from the parking
    /// places, not along the track, so a winding taxi cannot bring a shown end back near the
    /// aircraft's stand. The cuts are interpolated between fixes. Empty when the track never got
    /// that far from either end: then all of it is "where I parked".
    static func trimmingParking(_ track: [GPSPoint], meters: Double = parkingTrimMeters) -> [GPSPoint] {
        trimmingParking(track, meters: meters, start: true, end: true)
    }

    /// The same, at one end only: a journey hides where the day started and where it ended, not the
    /// stops between its legs, so its first leg loses its start and its last leg its end. (6.1)
    static func trimmingParking(_ track: [GPSPoint], meters: Double = parkingTrimMeters,
                                start trimsStart: Bool, end trimsEnd: Bool) -> [GPSPoint] {
        guard trimsStart || trimsEnd else { return track }
        guard track.count >= 2, let start = track.first, let end = track.last else { return track }
        func distance(_ a: GPSPoint, _ b: GPSPoint) -> Double {
            Flight.haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude)
        }
        let firstOut = trimsStart ? track.firstIndex(where: { distance($0, start) >= meters }) : 0
        let lastOut = trimsEnd ? track.lastIndex(where: { distance($0, end) >= meters }) : track.count - 1
        guard let firstOut, let lastOut, firstOut <= lastOut else { return [] }

        func crossing(from inside: GPSPoint, to outside: GPSPoint, anchor: GPSPoint) -> GPSPoint {
            let d0 = distance(inside, anchor), d1 = distance(outside, anchor)
            let f = d1 > d0 ? max(0, min(1, (meters - d0) / (d1 - d0))) : 1
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
            return GPSPoint(latitude: mix(inside.latitude, outside.latitude),
                            longitude: mix(inside.longitude, outside.longitude),
                            altitude: mix(inside.altitude, outside.altitude),
                            timestamp: inside.timestamp.addingTimeInterval(outside.timestamp.timeIntervalSince(inside.timestamp) * f),
                            speed: mix(inside.speed, outside.speed), course: outside.course)
        }

        var trimmed = Array(track[firstOut...lastOut])
        if firstOut > 0 { trimmed.insert(crossing(from: track[firstOut - 1], to: track[firstOut], anchor: start), at: 0) }
        if lastOut < track.count - 1 { trimmed.append(crossing(from: track[lastOut + 1], to: track[lastOut], anchor: end)) }
        return trimmed
    }
}
