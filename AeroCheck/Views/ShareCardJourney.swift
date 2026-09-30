import Foundation
import CoreGraphics
import CoreLocation
import MapKit

// MARK: - The journey (6.1)

/// Several flights on one card: a day of the Logbook, or the legs of a trip (proposal of 29 Sep,
/// part 3, J1, approved as recommended). Everything the journey card prints is worked out here, so
/// it agrees with the Logbook and with each leg's own card: the totals are each leg's logged figures
/// summed (the minute rule applies per leg, never to a rounded total), the chain and the stops come
/// from where each leg left and landed, and the times take the single card's zone. Pure: flights and
/// the settings in, figures out. (6.1)
struct ShareCardJourney {
    /// The flights in the order they were flown, whatever order they came in (the Logbook lists the
    /// newest first).
    let legs: [Flight]
    var nauticalMiles: Bool = true
    var useUTC: Bool = false
    var locale: Locale = .current
    var localTimeZone: TimeZone = .current

    init(flights: [Flight], nauticalMiles: Bool = true, useUTC: Bool = false,
         locale: Locale = .current, localTimeZone: TimeZone = .current) {
        self.legs = Self.flownOrder(flights)
        self.nauticalMiles = nauticalMiles
        self.useUTC = useUTC
        self.locale = locale
        self.localTimeZone = localTimeZone
    }

    /// Two flights or more: a journey card needs something to join.
    var isJourney: Bool { legs.count >= 2 }

    /// The single card's figures for one leg, in this journey's settings.
    func figures(_ flight: Flight) -> ShareCardFigures {
        ShareCardFigures(flight: flight, nauticalMiles: nauticalMiles, useUTC: useUTC,
                         locale: locale, localTimeZone: localTimeZone)
    }

    /// The journey's own number format and times: the first leg's figures (every leg's are the same
    /// settings).
    private var anyFigures: ShareCardFigures? { legs.first.map(figures) }

    // MARK: Order

    /// Sorted by when each flight began, the order they came in when two began together.
    static func flownOrder(_ flights: [Flight]) -> [Flight] {
        flights.enumerated().sorted { a, b in
            switch (began(a.element), began(b.element)) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// When a flight began: the recording's start, which every flight has, else its first logged time.
    static func began(_ flight: Flight) -> Date? {
        flight.startTime ?? flight.blockOffTime ?? flight.lineUpTime ?? flight.engineStartTime
    }

    /// Where a leg's time on the ground begins and ends: block on and block off, else the landing and
    /// the take-off, else the engine, else the recording.
    static func arrived(_ flight: Flight) -> Date? {
        flight.blockOnTime ?? flight.landingTime ?? flight.engineShutdownTime ?? flight.stopTime
    }

    static func departed(_ flight: Flight) -> Date? {
        flight.blockOffTime ?? flight.lineUpTime ?? flight.engineStartTime ?? flight.startTime
    }

    // MARK: Totals, each leg's as logged

    /// Flight time: each leg's take-off to landing as logged, summed. 0:33 + 0:27 + 0:26 = 1:26 on
    /// 29 Sep. A leg without both times adds nothing (it adds nothing to a logbook either). Nil when
    /// no leg has one.
    var flightMinutes: Int? { Self.sum(legs.map(\.flightMinutes)) }

    /// Block time, the same way: 0:42 + 0:35 + 0:34 = 1:51.
    var blockMinutes: Int? { Self.sum(legs.map(\.blockMinutes)) }

    private static func sum(_ values: [Int?]) -> Int? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    var flightTime: String { flightMinutes.map(ShareCardFigures.formattedDuration(minutes:)) ?? "--:--" }
    var blockTime: String { blockMinutes.map(ShareCardFigures.formattedDuration(minutes:)) ?? "--:--" }

    /// Every leg's track, end to end.
    var distanceKilometers: Double { legs.reduce(0) { $0 + max(0, $1.distanceKilometers) } }

    /// "132 NM": the total, rounded once (not the rounded legs added up).
    var distance: String { anyFigures?.distance(kilometers: distanceKilometers) ?? "—" }

    /// The Logbook's landings, every leg's (touch-and-goes and full stops).
    var landings: Int { legs.reduce(0) { $0 + max(0, $1.totalLandings) } }

    /// The highest point of the day, in whole feet.
    var maxAltitudeFeet: Int? { legs.compactMap { figures($0).maxAltitudeFeet }.max() }

    var maxAltitude: String? {
        guard let feet = maxAltitudeFeet, let figures = anyFigures else { return nil }
        return "\(figures.number(feet)) ft"
    }

    // MARK: Where each leg left and landed

    /// Each leg's two ends, an end the flight does not know taken from its neighbour: a leg whose
    /// arrival was never found landed where the next one left from (29 Sep, leg 1, before its
    /// arrival was back-filled). Nil where neither knows.
    var ends: [(departure: String?, arrival: String?)] {
        let known = legs.map { ($0.departureAirportIdent.flatMap(Flight.nonBlank),
                                $0.arrivalAirportIdent.flatMap(Flight.nonBlank)) }
        return known.indices.map { index in
            let departure = known[index].0 ?? (index > 0 ? known[index - 1].1 : nil)
            let arrival = known[index].1 ?? (index + 1 < known.count ? known[index + 1].0 : nil)
            return (departure, arrival)
        }
    }

    /// One piece of the route chain.
    enum ChainItem: Equatable {
        case aerodrome(String)
        /// The next leg left from somewhere else than the last one landed: a flight not in the set.
        case gap
    }

    /// The aerodromes in the order the day went through them, each once in a row: "LSZQ → LSGE →
    /// LSGN → LSZQ". Circuits at the field the aircraft is at add nothing. "?" for an end nobody
    /// knows.
    var chain: [ChainItem] {
        var items: [ChainItem] = []
        var here: String?
        for (departure, arrival) in ends {
            let from = departure ?? Flight.unknownAerodrome
            if items.isEmpty {
                items.append(.aerodrome(from))
            } else if departure != nil, from != here {
                items.append(.gap)
                items.append(.aerodrome(from))
            }
            let to = arrival ?? Flight.unknownAerodrome
            if to != (items.isEmpty ? nil : lastAerodrome(items)) || arrival == nil {
                items.append(.aerodrome(to))
            }
            here = arrival
        }
        return items
    }

    private func lastAerodrome(_ items: [ChainItem]) -> String? {
        for item in items.reversed() { if case let .aerodrome(ident) = item { return ident } }
        return nil
    }

    /// The chain as the title writes it. `fits` says whether a candidate fits the title's width;
    /// past that the middle folds into one "··· +3", keeping as many aerodromes as fit from both ends
    /// (one more at the start), as #238's route strip folds.
    func chainText(fits: (String) -> Bool = { _ in true }) -> String {
        Self.chainText(chain, fits: fits)
    }

    static func chainText(_ items: [ChainItem], fits: (String) -> Bool) -> String {
        let full = write(items)
        guard !fits(full) else { return full }
        let idents = items.compactMap { item -> String? in
            if case let .aerodrome(ident) = item { return ident }
            return nil
        }
        guard idents.count > 2 else { return full }
        for kept in stride(from: idents.count - 1, through: 2, by: -1) {
            let head = (kept + 1) / 2, tail = kept - head
            let text = (Array(idents.prefix(head)) + ["··· +\(idents.count - kept)"] + Array(idents.suffix(tail)))
                .joined(separator: " → ")
            if fits(text) || kept == 2 { return text }
        }
        return full
    }

    private static func write(_ items: [ChainItem]) -> String {
        var text = ""
        for item in items {
            switch item {
            case let .aerodrome(ident):
                if !text.isEmpty, !text.hasSuffix(" … ") { text += " → " }
                text += ident
            case .gap:
                text += " … "
            }
        }
        return text
    }

    /// The chain's aerodromes, each once, in the order first reached.
    var aerodromes: [String] {
        var seen: [String] = []
        for case let .aerodrome(ident) in chain where ident != Flight.unknownAerodrome && !seen.contains(ident) {
            seen.append(ident)
        }
        return seen
    }

    /// Whether every flight went from one aerodrome to another: then they are "legs". A day with
    /// circuits or a local flight in it has "flights".
    var isAllLegs: Bool {
        ends.allSatisfy { end in
            guard let departure = end.departure, let arrival = end.arrival else { return true }
            return departure != arrival
        }
    }

    /// Under the title: "3 legs · Bressaucourt · Ecuvillens · Neuchâtel". `name` gives an
    /// aerodrome's name by its ident; the ident stands in for one it does not know.
    func subtitle(name: (String) -> String?) -> String {
        let count = isAllLegs ? L10n.Flights.legCount(legs.count) : L10n.ShareCard.flightCount(legs.count)
        let names = aerodromes.map { ident in name(ident).map(ShareCardFigures.shortAerodromeName) ?? ident }
        return ([count] + names).joined(separator: " · ")
    }

    /// A leg as its row says it: "LSZQ → LSGE", "LSZQ · circuits", "LSZQ" for a local flight.
    func route(ofLeg index: Int) -> String {
        let end = ends[index]
        let flight = legs[index]
        switch (end.departure, end.arrival) {
        case let (departure?, arrival?) where departure == arrival:
            // "· circuits" as the single card's line under its title: B612 has no "↻".
            return flight.touchAndGoCount > 0
                ? "\(departure) · \(L10n.Flights.circuits.localizedLowercase)" : departure
        case (nil, nil):
            return flight.title
        default:
            return "\(end.departure ?? Flight.unknownAerodrome) → \(end.arrival ?? Flight.unknownAerodrome)"
        }
    }

    // MARK: The stops between the legs

    struct GroundStop: Equatable {
        /// The leg it follows (0 = between legs 1 and 2).
        let afterLeg: Int
        /// Where: the leg's arrival, else the next one's departure.
        let ident: String?
        /// On the ground, as logged: block on to the next block off, each time to the minute.
        let minutes: Int?
    }

    /// Between each two legs: where, and for how long. LSGE 12:21 → 12:45 is 24 min, LSGN 13:20 →
    /// 14:11 is 51 min. Nil minutes when the times are missing or out of order.
    var groundStops: [GroundStop] {
        legs.indices.dropLast().map { index in
            let minutes: Int?
            if let landed = Self.arrived(legs[index]), let left = Self.departed(legs[index + 1]), left >= landed {
                minutes = Flight.loggedMinutes(from: landed, to: left)
            } else {
                minutes = nil
            }
            return GroundStop(afterLeg: index, ident: ends[index].arrival ?? ends[index + 1].departure,
                              minutes: minutes)
        }
    }

    /// "24 min", "1 h 05", "18 h 20": the same in English and French.
    static func groundDuration(minutes: Int) -> String {
        let minutes = max(0, minutes)
        return minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d", minutes / 60, minutes % 60)
    }

    // MARK: A leg's row

    /// "11:46 – 12:19": take-off to landing, else block off to block on; nil without either pair.
    func span(ofLeg index: Int) -> String? {
        let flight = legs[index], figures = self.figures(flight)
        if let takeoff = flight.lineUpTime, let landing = flight.landingTime, landing >= takeoff {
            return "\(figures.time(takeoff)) – \(figures.time(landing))"
        }
        if let off = flight.blockOffTime, let on = flight.blockOnTime, on >= off {
            return "\(figures.time(off)) – \(figures.time(on))"
        }
        return nil
    }

    /// "0:33 · 52 NM · 5’688 ft", or "0:33 · no track" for a leg without one.
    func figuresLine(ofLeg index: Int) -> String {
        let flight = legs[index], figures = self.figures(flight)
        let time = flight.flightMinutes.map(ShareCardFigures.formattedDuration(minutes:)) ?? "--:--"
        guard flight.gpsTrack.count >= 2 else { return "\(time) · \(L10n.ShareCard.noTrack)" }
        return ([time, figures.distance] + [figures.maxAltitude].compactMap { $0 }).joined(separator: " · ")
    }

    /// A leg in the grid under a wide map, on one line: "10:46 – 12:26 · 1:40", the registration
    /// after it on a day on several aircraft.
    func gridLine(ofLeg index: Int) -> String {
        let flight = legs[index]
        var parts = [span(ofLeg: index) ?? "—",
                     flight.flightMinutes.map(ShareCardFigures.formattedDuration(minutes:)) ?? "--:--"]
        if namesAircraftPerLeg { parts.append(flight.aircraftRegistration.flatMap(Flight.nonBlank) ?? flight.airplane) }
        return parts.joined(separator: " · ")
    }

    // MARK: Aircraft

    /// The registrations flown, each once, in the order flown.
    var registrations: [String] {
        var seen: [String] = []
        for flight in legs {
            let registration = flight.aircraftRegistration.flatMap(Flight.nonBlank) ?? flight.airplane
            if !seen.contains(registration) { seen.append(registration) }
        }
        return seen
    }

    /// Beside the registration: the model, for a day on one aircraft only.
    var aircraftModel: String? {
        guard registrations.count == 1 else { return nil }
        return legs.lazy.compactMap { figures($0).aircraftModel }.first
    }

    /// The badge: "F-HVXA", "F-HVXA · HB-PFA" for a day on two aircraft, "F-HVXA +2" past that.
    var badge: String {
        switch registrations.count {
        case 0: return ""
        case 1, 2: return registrations.joined(separator: " · ")
        default: return "\(registrations[0]) +\(registrations.count - 1)"
        }
    }

    /// On a day flown on more than one aircraft, each leg's row names its own.
    var namesAircraftPerLeg: Bool { registrations.count > 1 }

    // MARK: Date and time zone

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = useUTC ? TimeZone(identifier: "UTC")! : localTimeZone
        return calendar
    }

    private var firstDate: Date? { legs.first.flatMap(Self.began) }
    private var lastDate: Date? { legs.last.flatMap { Self.arrived($0) ?? Self.began($0) } }

    /// Whether the journey ran past midnight (in the card's zone): a trip over two days.
    var spansDays: Bool {
        guard let first = firstDate, let last = lastDate else { return false }
        return !calendar.isDate(first, inSameDayAs: last)
    }

    /// "29 SEP 2026", "29–30 SEP 2026", "30 SEP – 2 OCT 2026", "31 DEC 2026 – 1 JAN 2027": the
    /// single card's date, as a range when the journey ran past midnight.
    var dateText: String {
        guard let first = firstDate else { return "" }
        func format(_ date: Date, _ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = pattern
            return formatter.string(from: date).uppercased(with: locale)
        }
        guard spansDays, let last = lastDate else { return format(first, "d MMM yyyy") }
        let a = calendar.dateComponents([.year, .month], from: first)
        let b = calendar.dateComponents([.year, .month], from: last)
        if a.year == b.year, a.month == b.month { return "\(format(first, "d"))–\(format(last, "d MMM yyyy"))" }
        if a.year == b.year { return "\(format(first, "d MMM")) – \(format(last, "d MMM yyyy"))" }
        return "\(format(first, "d MMM yyyy")) – \(format(last, "d MMM yyyy"))"
    }

    /// The zone of every time on the card, said once: "Local time · UTC+2", "Local time · UTC+2 →
    /// UTC+1" across a change of summer time, "Times in UTC".
    var timeNote: String {
        guard !useUTC else { return L10n.ShareCard.timesInUTC }
        let start = legs.first.flatMap { $0.lineUpTime ?? Self.departed($0) } ?? Date()
        let end = legs.last.flatMap { $0.landingTime ?? Self.arrived($0) } ?? start
        let a = ShareCardFigures.utcOffset(localTimeZone.secondsFromGMT(for: start))
        let b = ShareCardFigures.utcOffset(localTimeZone.secondsFromGMT(for: end))
        return L10n.ShareCard.localTimeNote(a == b ? a : "\(a) → \(b)")
    }

    // MARK: The timeline

    struct TimelineSegment: Equatable {
        enum Kind: Equatable {
            /// Block off to take-off, landing to block on.
            case taxi
            /// Take-off to landing, with the leg's number (1-based).
            case air(leg: Int)
            /// Between two legs, with the stop's index in `groundStops`.
            case ground(stop: Int)
        }
        let kind: Kind
        let start: Date
        let end: Date
    }

    struct Timeline: Equatable {
        let start: Date
        let end: Date
        let segments: [TimelineSegment]
    }

    /// Past these the timeline would be mostly a night on the ground, the legs slivers at its ends:
    /// a journey longer than 12 h, or with a stop longer than 6 h, has no timeline, and its room goes
    /// to the map. The stops' times stay in the leg list.
    static let timelineMaxSpan: TimeInterval = 12 * 3600
    static let timelineMaxStop: TimeInterval = 6 * 3600

    /// Air against ground, from the first block off to the last block on: taxi, each leg in the air,
    /// and the stops. A leg with block times only is drawn in the air from block to block. Nil when
    /// the journey has no times, or a night in it (`timelineMaxSpan`, `timelineMaxStop`).
    var timeline: Timeline? {
        var segments: [TimelineSegment] = []
        func add(_ kind: TimelineSegment.Kind, _ start: Date?, _ end: Date?) {
            guard let start, let end, end > start else { return }
            segments.append(TimelineSegment(kind: kind, start: start, end: end))
        }
        for (index, flight) in legs.enumerated() {
            let takeoff = flight.lineUpTime, landing = flight.landingTime
            if let takeoff, let landing, landing > takeoff {
                add(.taxi, flight.blockOffTime, takeoff)
                add(.air(leg: index + 1), takeoff, landing)
                add(.taxi, landing, flight.blockOnTime)
            } else {
                add(.air(leg: index + 1), flight.blockOffTime, flight.blockOnTime)
            }
            if index + 1 < legs.count {
                add(.ground(stop: index), Self.arrived(flight), Self.departed(legs[index + 1]))
            }
        }
        guard let start = segments.map(\.start).min(), let end = segments.map(\.end).max(),
              end.timeIntervalSince(start) <= Self.timelineMaxSpan,
              !segments.contains(where: { segment in
                  if case .ground = segment.kind { return segment.end.timeIntervalSince(segment.start) > Self.timelineMaxStop }
                  return false
              }) else { return nil }
        return Timeline(start: start, end: end, segments: segments)
    }

    // MARK: The profile, in the air

    struct ProfileSegment {
        /// The leg's number, 1-based.
        let leg: Int
        /// The airborne part of the track: a minute before the take-off to a minute after the
        /// landing, else the whole track.
        let track: [GPSPoint]
        let takeoff: Date?
        let landing: Date?
    }

    /// The legs with a track, each cut to its time in the air: the profile joins them, with the stops
    /// between as gaps (J1). A leg without a track has no segment.
    var profileSegments: [ProfileSegment] {
        legs.enumerated().compactMap { index, flight in
            guard flight.gpsTrack.count >= 2 else { return nil }
            var track = flight.gpsTrack
            if let takeoff = flight.lineUpTime, let landing = flight.landingTime, landing > takeoff {
                let airborne = track.filter {
                    $0.timestamp >= takeoff.addingTimeInterval(-60) && $0.timestamp <= landing.addingTimeInterval(60)
                }
                if airborne.count >= 2 { track = airborne }
            }
            return ProfileSegment(leg: index + 1, track: track, takeoff: flight.lineUpTime, landing: flight.landingTime)
        }
    }

    /// The words in each gap of the profile: the stop and its time on the ground, "LSGE" over "24
    /// min", when the two segments are consecutive legs; nothing when a leg without a track is
    /// between them.
    var profileGaps: [(ident: String, detail: String?)?] {
        let segments = profileSegments
        let stops = groundStops
        return zip(segments, segments.dropFirst()).map { a, b in
            guard b.leg == a.leg + 1, let stop = stops.first(where: { $0.afterLeg == a.leg - 1 }),
                  let ident = stop.ident else { return nil }
            return (ident, stop.minutes.map(Self.groundDuration(minutes:)))
        }
    }

    // MARK: The map

    /// How wide the legs' tracks are together against how tall, on the map (Web Mercator). Nil
    /// without two fixes.
    var trackAspect: Double? {
        let coordinates = legs.flatMap { $0.gpsTrack.map(\.coordinate) }
        guard coordinates.count >= 2 else { return nil }
        let box = MKPolyline(coordinates: coordinates, count: coordinates.count).boundingMapRect
        guard box.size.height > 0 else { return .infinity }
        return box.size.width / box.size.height
    }

    /// Past this the journey runs east–west, and a map beside the leg list would be mostly chart the
    /// tracks never reach (and outside Switzerland, no chart at all): the map takes the card's width
    /// and the legs go under it. 29 Sep (north–south) stays beside its list, as J1.
    static let wideAspect = 1.25

    var arrangement: ShareCardJourneyLayout.Arrangement {
        (trackAspect ?? 0) >= Self.wideAspect ? .under : .beside
    }

    /// Each leg's track for the map. "Hide where I parked" cuts where the day started and where it
    /// ended: the first leg's start and the last leg's end, never the stops between. (approved Q7)
    func mapTracks(hideParking: Bool) -> [[GPSPoint]] {
        legs.enumerated().map { index, flight in
            ShareCardPrivacy.trimmingParking(flight.gpsTrack, start: hideParking && index == 0,
                                             end: hideParking && index == legs.count - 1)
        }
    }

    /// Whether the journey came back where it started: one gold "home" marker then, rather than a
    /// green start and a red end on the same field.
    var endsWhereItStarted: Bool {
        guard let first = ends.first?.departure, let last = ends.last?.arrival else { return false }
        return first == last
    }

    /// The markers on the map: home (or start and end), and each stop between two legs, named.
    func mapMarkers(tracks: [[GPSPoint]]) -> [ShareCardMapMarker] {
        var markers: [ShareCardMapMarker] = []
        let home = endsWhereItStarted ? ends.first?.departure : nil
        let departure = ends.first?.departure
        if let first = tracks.first(where: { $0.count >= 2 })?.first {
            markers.append(ShareCardMapMarker(kind: home != nil ? .home : .start, coordinate: first.coordinate,
                                              label: departure))
        }
        // Each aerodrome named once: a stop back at the start is already marked there.
        var named: Set<String> = departure.map { [$0] } ?? []
        for stop in groundStops {
            guard let track = tracks[stop.afterLeg].count >= 2 ? tracks[stop.afterLeg] : nil,
                  let last = track.last else { continue }
            if let ident = stop.ident {
                guard !named.contains(ident) else { continue }
                named.insert(ident)
            }
            markers.append(ShareCardMapMarker(kind: .stop, coordinate: last.coordinate, label: stop.ident))
        }
        if home == nil, let last = tracks.last(where: { $0.count >= 2 })?.last {
            let label = ends.last?.arrival
            markers.append(ShareCardMapMarker(kind: .end, coordinate: last.coordinate,
                                              label: label.flatMap { named.contains($0) ? nil : $0 }))
        }
        return markers
    }

    /// What the renderer draws: each leg with a track, numbered, and the markers.
    func mapJourney(hideParking: Bool) -> ShareCardMapJourney {
        let tracks = mapTracks(hideParking: hideParking)
        let legs = tracks.enumerated().compactMap { index, track in
            track.count >= 2 ? ShareCardMapJourney.Leg(number: index + 1, track: track.map(\.coordinate)) : nil
        }
        return ShareCardMapJourney(legs: legs, markers: mapMarkers(tracks: tracks))
    }

    // MARK: Sharing

    /// One image of the share.
    struct ShareItem: Equatable {
        enum Kind: Equatable {
            case journey
            /// A leg's own card (#238's), by its index.
            case leg(Int)
        }
        let kind: Kind
        let filename: String
        /// "Hide where I parked" at this image's start and end.
        let trimsStart: Bool
        let trimsEnd: Bool
    }

    /// What the share sends: the journey card, then, with "Add each leg's card", each leg's own card
    /// in the order flown, as one multi-image share. "Hide where I parked" cuts the day's first
    /// departure and last arrival on every image that shows them: the journey, leg 1's start and the
    /// last leg's end.
    func shareItems(eachLeg: Bool, hideParking: Bool) -> [ShareItem] {
        var items = [ShareItem(kind: .journey, filename: exportFilename, trimsStart: hideParking, trimsEnd: hideParking)]
        guard eachLeg else { return items }
        for (index, flight) in legs.enumerated() {
            items.append(ShareItem(kind: .leg(index), filename: flight.exportFilename,
                                   trimsStart: hideParking && index == 0,
                                   trimsEnd: hideParking && index == legs.count - 1))
        }
        return items
    }

    /// `AeroCheck_20260929_1134_LSZQ-LSGE-LSGN-LSZQ_F-HVXA`: the flights' own pattern
    /// (`Flight.exportFilename`), with the chain for the route and every registration.
    var exportFilename: String {
        let start = legs.first?.startTime ?? Date()
        let date = DateFormatter(), time = DateFormatter()
        date.dateFormat = "yyyyMMdd"
        time.dateFormat = "HHmm"
        let route = chain.compactMap { item -> String? in
            if case let .aerodrome(ident) = item { return ident == Flight.unknownAerodrome ? "ZZZZ" : ident }
            return nil
        }.joined(separator: "-")
        let parts = ([route] + registrations).map(Flight.fileSafe).filter { !$0.isEmpty }
        return (["AeroCheck", date.string(from: start), time.string(from: start)] + parts).joined(separator: "_")
    }
}

// MARK: - The leg list's fold (6.1)

/// Which rows of the leg list fit beside the map: every leg with its stop between, in full; else the
/// same rows compact; else, compact, the first legs and the last with the middle folded into one
/// "··· +3 legs" row. Pure: the heights come in.
enum ShareCardJourneyList {
    enum Row: Equatable {
        case leg(Int)
        /// The stop after this leg.
        case ground(Int)
        /// Legs left out, with how many.
        case more(Int)
    }

    struct Heights: Equatable {
        var leg: CGFloat
        var ground: CGFloat
        var compactLeg: CGFloat
        var compactGround: CGFloat
        var more: CGFloat
    }

    static func rows(legCount: Int, height: CGFloat, heights: Heights) -> (rows: [Row], compact: Bool) {
        guard legCount > 0 else { return ([], false) }
        func all(_ count: Int) -> [Row] {
            (0..<count).flatMap { index in index + 1 < count ? [Row.leg(index), .ground(index)] : [.leg(index)] }
        }
        func total(_ rows: [Row], compact: Bool) -> CGFloat {
            rows.reduce(0) { sum, row in
                switch row {
                case .leg: return sum + (compact ? heights.compactLeg : heights.leg)
                case .ground: return sum + (compact ? heights.compactGround : heights.ground)
                case .more: return sum + heights.more
                }
            }
        }
        let every = all(legCount)
        if total(every, compact: false) <= height { return (every, false) }
        if total(every, compact: true) <= height { return (every, true) }
        // Keep `kept` legs: the first ones with their stops, then the fold, then the last.
        for kept in stride(from: legCount - 1, through: 2, by: -1) {
            let rows = all(kept - 1) + [Row.more(legCount - kept), .leg(legCount - 1)]
            if total(rows, compact: true) <= height { return (rows, true) }
        }
        return ([.leg(0), .more(max(0, legCount - 2)), .leg(legCount - 1)], true)
    }
}

extension ShareCardJourneyList {
    /// A cell of the grid under a wide map.
    enum Cell: Equatable {
        case leg(Int)
        case more(Int)
    }

    /// The legs two by two, in the order flown, as many as `capacity` cells hold: past that, the
    /// first ones, "··· +3" and the last.
    static func grid(legCount: Int, capacity: Int) -> [Cell] {
        guard legCount > capacity, capacity >= 3 else { return (0..<legCount).map(Cell.leg) }
        let head = capacity - 2
        return (0..<head).map(Cell.leg) + [.more(legCount - head - 1), .leg(legCount - 1)]
    }
}

// MARK: - The journey on the map (6.1)

/// A point the journey card names on its map.
struct ShareCardMapMarker: Equatable {
    enum Kind: Equatable {
        /// Where the day started and ended: one gold dot.
        case home
        /// Green, where it started (when it ended elsewhere).
        case start
        /// Red, where it ended.
        case end
        /// A stop between two legs: white, ringed in the route's magenta.
        case stop
    }
    let kind: Kind
    let coordinate: CLLocationCoordinate2D
    let label: String?

    static func == (a: Self, b: Self) -> Bool {
        a.kind == b.kind && a.label == b.label
            && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
    }
}

/// Several tracks on one map, numbered, with the day's aerodromes marked. (6.1)
struct ShareCardMapJourney: Equatable {
    struct Leg: Equatable {
        let number: Int
        let track: [CLLocationCoordinate2D]

        static func == (a: Self, b: Self) -> Bool {
            a.number == b.number && a.track.count == b.track.count
                && zip(a.track, b.track).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        }
    }
    let legs: [Leg]
    let markers: [ShareCardMapMarker]

    /// Every leg's track end to end: what the map is framed on.
    var allCoordinates: [CLLocationCoordinate2D] { legs.flatMap(\.track) }

    /// Where a leg's number goes: halfway along it, or a little either side when that spot is taken
    /// by another number or a marker within `clearance` (in the image's points, after `project`).
    static func badgePoints(_ legs: [Leg], markers: [CGPoint], clearance: CGFloat,
                            project: (CLLocationCoordinate2D) -> CGPoint) -> [CGPoint] {
        var placed: [CGPoint] = []
        for leg in legs {
            let points = leg.track.map(project)
            guard points.count >= 2 else { placed.append(points.first ?? .zero); continue }
            var cumulative: [CGFloat] = [0]
            for (a, b) in zip(points, points.dropFirst()) { cumulative.append(cumulative.last! + hypot(b.x - a.x, b.y - a.y)) }
            let length = cumulative.last!
            func point(at fraction: CGFloat) -> CGPoint {
                let target = length * fraction
                guard let index = cumulative.firstIndex(where: { $0 >= target }), index > 0 else { return points[0] }
                let span = cumulative[index] - cumulative[index - 1]
                let t = span > 0 ? (target - cumulative[index - 1]) / span : 0
                let a = points[index - 1], b = points[index]
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            let taken = placed + markers
            let candidates = [0.5, 0.38, 0.62, 0.28, 0.72, 0.2, 0.8].map { point(at: $0) }
            let free = candidates.first { candidate in
                taken.allSatisfy { hypot($0.x - candidate.x, $0.y - candidate.y) >= clearance }
            }
            placed.append(free ?? candidates[0])
        }
        return placed
    }
}

// MARK: - The journey card's layout (6.1)

/// Where everything sits on the journey card (J1): the top bar, the chain and its names, four
/// tiles, the map with the leg list beside it, the timeline, the profile and the footer. Every block
/// has a fixed height and the map takes what is left, as on the single card (`ShareCardLayout`), so
/// its image is made at the exact shape of its frame. The Full map style takes the single card's own
/// band and panel. Pure.
struct ShareCardJourneyLayout: Equatable {
    /// The leg list beside the map (J1), or two by two under a map the card's width, for a journey
    /// that runs east–west (`ShareCardJourney.arrangement`).
    enum Arrangement: Equatable { case beside, under }

    let format: ShareCardFormat
    /// The timeline is drawn (the journey has one: `ShareCardJourney.timeline`).
    let hasTimeline: Bool
    var arrangement: Arrangement = .beside
    /// How many legs the grid under the map holds rows for.
    var legCount: Int = 0

    /// The layout for a journey: its timeline, its shape, its legs.
    static func make(for journey: ShareCardJourney, format: ShareCardFormat) -> ShareCardJourneyLayout {
        ShareCardJourneyLayout(format: format, hasTimeline: journey.timeline != nil,
                               arrangement: journey.arrangement, legCount: journey.legs.count)
    }

    var canvas: CGSize { format.size }
    private var isStory: Bool { format == .story }

    let textMargin: CGFloat = 48
    let boxMargin: CGFloat = 32

    var topPadding: CGFloat { isStory ? 48 : 40 }
    let topBarHeight: CGFloat = 44
    var titleGap: CGFloat { isStory ? 26 : 18 }
    var chainFont: CGFloat { isStory ? 54 : 46 }
    var subtitleFont: CGFloat { isStory ? 25 : 22 }
    var titleBlockHeight: CGFloat { (chainFont * 1.12 + 10 + subtitleFont * 1.3).rounded(.up) }

    var tilesGap: CGFloat { isStory ? 28 : 16 }
    var tileHeight: CGFloat { isStory ? 112 : 92 }
    var tileValueFont: CGFloat { isStory ? 30 : 26 }

    var mapGap: CGFloat { isStory ? 20 : 14 }
    /// The leg list beside the map, and the room between them.
    var listWidth: CGFloat { isStory ? 352 : 340 }
    var listGap: CGFloat { 24 }

    var sectionGap: CGFloat { isStory ? 28 : 16 }
    let sectionHeaderHeight: CGFloat = 18
    var sectionHeaderGap: CGFloat { isStory ? 12 : 10 }
    var timelineHeight: CGFloat { isStory ? 86 : 72 }
    var profileHeight: CGFloat { isStory ? 300 : 150 }
    var footerGap: CGFloat { isStory ? 22 : 16 }
    let footerHeight: CGFloat = 50
    var bottomPadding: CGFloat { isStory ? 44 : 32 }

    /// The leg list's rows and their fonts.
    var listHeights: ShareCardJourneyList.Heights {
        isStory ? .init(leg: 134, ground: 70, compactLeg: 98, compactGround: 38, more: 60)
                : .init(leg: 116, ground: 56, compactLeg: 84, compactGround: 32, more: 52)
    }
    var legRouteFont: CGFloat { isStory ? 27 : 24 }
    var legTimeFont: CGFloat { isStory ? 23 : 20 }
    var legFiguresFont: CGFloat { isStory ? 18 : 16 }
    var legNumberSize: CGFloat { isStory ? 46 : 40 }

    // The grid under a wide map: two legs a row, two lines a leg.
    var gridGap: CGFloat { isStory ? 18 : 12 }
    var gridRowHeight: CGFloat { isStory ? 72 : 60 }
    var gridMaxRows: Int { isStory ? 4 : 3 }
    var gridRows: Int { min(gridMaxRows, (legCount + 1) / 2) }
    var gridRouteFont: CGFloat { isStory ? 23 : 20 }
    var gridTimeFont: CGFloat { isStory ? 17 : 15 }
    var gridNumberSize: CGFloat { isStory ? 38 : 34 }
    /// The time zone's note under the legs, when there is no timeline to carry it.
    let noteHeight: CGFloat = 30
    var gridHeight: CGFloat {
        CGFloat(gridRows) * gridRowHeight + (hasTimeline ? 0 : noteHeight)
    }

    /// What the map and the legs share: the card's height less every other block.
    var band: CGFloat {
        var used = topPadding + topBarHeight + titleGap + titleBlockHeight
        used += tilesGap + tileHeight + mapGap
        if hasTimeline { used += sectionGap + sectionHeaderHeight + sectionHeaderGap + timelineHeight }
        used += sectionGap + sectionHeaderHeight + sectionHeaderGap + profileHeight
        used += footerGap + footerHeight + bottomPadding
        return canvas.height - used
    }

    /// The map's frame: beside the list, as tall as the rest leaves; or the card's width, over the
    /// grid of legs.
    var mapFrame: CGSize {
        switch arrangement {
        case .beside:
            return CGSize(width: canvas.width - 2 * boxMargin - listGap - listWidth, height: max(200, band))
        case .under:
            return CGSize(width: canvas.width - 2 * boxMargin, height: max(200, band - gridGap - gridHeight))
        }
    }
}

// MARK: - The Logbook's days (6.1)

/// The flights of one local calendar day, for the Logbook's day header and its "Share day". Pure.
struct LogbookDay: Identifiable, Equatable {
    /// "2026-09-29".
    let id: String
    /// The day's start, in the calendar it was grouped with.
    let date: Date
    /// The day's flights, in the order they came (the Logbook's: newest first).
    let flights: [Flight]

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.flights.map(\.id) == b.flights.map(\.id)
    }

    /// Only a day of two flights or more has a header: a single flight's day reads as it always did.
    var hasHeader: Bool { flights.count >= 2 }

    /// The flights grouped by the local day each started on, as the Logbook's months are (a flight
    /// over midnight belongs to the day it started). Days keep the flights' order, and so do the
    /// flights within a day. Undated flights have no day.
    static func days(_ flights: [Flight], calendar: Calendar = .current) -> [LogbookDay] {
        var order: [String] = []
        var buckets: [String: (date: Date, flights: [Flight])] = [:]
        for flight in flights {
            guard let start = flight.startTime else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            if buckets[key] == nil {
                buckets[key] = (calendar.startOfDay(for: start), [])
                order.append(key)
            }
            buckets[key]?.flights.append(flight)
        }
        return order.compactMap { key in buckets[key].map { LogbookDay(id: key, date: $0.date, flights: $0.flights) } }
    }

    /// "TUE 29 SEP", "MAR. 29 SEPT.".
    func label(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        // Without the comma some regions put after the weekday ("Tue, 29 Sep" in en_CH).
        return formatter.string(from: date).replacingOccurrences(of: ",", with: "").uppercased(with: locale)
    }

    /// "3 flights · 1:26 flying · 132 NM": the flight time is each flight's as logged, summed (the
    /// journey card's own total), the distance in the Settings unit.
    func summary(nauticalMiles: Bool, locale: Locale = .current) -> String {
        let journey = ShareCardJourney(flights: flights, nauticalMiles: nauticalMiles, locale: locale)
        var parts = [L10n.ShareCard.flightCount(flights.count)]
        if let minutes = journey.flightMinutes {
            parts.append(L10n.ShareCard.flying(ShareCardFigures.formattedDuration(minutes: minutes)))
        }
        if journey.distanceKilometers > 0 { parts.append(journey.distance) }
        return parts.joined(separator: " · ")
    }
}
