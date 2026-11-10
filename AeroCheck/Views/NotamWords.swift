import Foundation

// MARK: - NOTAMs in words

/// What a NOTAM's rows say, in UTC as a NOTAM is written. Pure: the page, See all, the detail and the tests read the same
/// words. Never "No NOTAMs", never a percentage.
enum NotamWords {
    /// "LFGA", "ON YOUR ROUTE": the row's first words, and the tag beside them.
    static func title(_ entry: NotamEntry) -> (where: String, tag: String?) {
        switch entry.place {
        case .aerodrome(let role)?:
            return (name(entry), roleWord(role))
        case let .route(offset, side, altitude, _)?:
            var parts: [String] = []
            let distance = String(Int(offset.rounded()))
            switch side {
            case .left?: parts.append(L10n.Notams.sideLeft(distance))
            case .right?: parts.append(L10n.Notams.sideRight(distance))
            case nil: break
            }
            if let altitude { parts.append("\(feet(altitude)) FT") }
            let tag = parts.isEmpty ? nil : parts.joined(separator: ", ")
            // An aerodrome's own NOTAM names the place, which the text doesn't.
            let isField = !entry.notam.location.isEmpty && entry.notam.fir.map { $0 != entry.notam.location } ?? false
            return (isField ? name(entry) : L10n.Notams.placeRoute, tag)
        case .region?, nil:
            return (entry.notam.location.isEmpty ? entry.notam.fir ?? "" : name(entry), nil)
        }
    }

    /// "LFBB", "LFBB +4" for a NOTAM that covers other places too.
    private static func name(_ entry: NotamEntry) -> String {
        entry.alsoAt > 0 ? "\(entry.notam.location) +\(entry.alsoAt)" : entry.notam.location
    }

    static func roleWord(_ role: NotamFlight.Role) -> String {
        switch role {
        case .departure: return L10n.Notams.placeDeparture
        case .destination: return L10n.Notams.placeDestination
        case .stop: return L10n.Notams.placeStop
        case .alternate: return L10n.Notams.placeAlternate
        }
    }

    /// "A1872/26 · today 08:00–16:00 UTC · SFC to FL 095".
    static func meta(_ notam: Notam, now: Date, calendar: Calendar = NotamTime.utc) -> String {
        var parts = [notam.number, when(notam, now: now, calendar: calendar)]
        if !notam.isWholeBand { parts.append(band(notam)) }
        return parts.joined(separator: " · ")
    }

    /// A card's header line: when, then how high unless from the ground up ("until 19 Mar 2027 · SFC to FL 011").
    static func facts(_ notam: Notam, now: Date, calendar: Calendar = NotamTime.utc) -> String {
        var parts = [when(notam, now: now, calendar: calendar)]
        if !notam.isWholeBand { parts.append(band(notam)) }
        return parts.joined(separator: " · ")
    }

    /// "SFC to FL 095", "2500 ft to 5000 ft": as items F and G write it, or else from the Q line.
    static func band(_ notam: Notam) -> String {
        L10n.Notams.band(limit(notam, isUpper: false), limit(notam, isUpper: true))
    }

    private static func level(_ fl: Int) -> String { String(format: "FL %03d", fl) }

    /// The tag's limit on the map, as the airspace tags write one: "SFC", "FL 095", "5000 ft", "300 AGL".
    static func limit(_ notam: Notam, isUpper: Bool) -> String {
        if let written = notam.writtenLimits, let words = limit(written: isUpper ? written.upper : written.lower) { return words }
        return isUpper ? (notam.upperFl >= 999 ? "UNL" : level(notam.upperFl)) : (notam.lowerFl <= 0 ? "SFC" : level(notam.lowerFl))
    }

    /// One written limit; nil for a form the app doesn't know, which falls back on the Q line.
    private static func limit(written: String) -> String? {
        let text = written.uppercased()
        if ["SFC", "GND", "UNL"].contains(text) { return text }
        if let match = text.wholeMatch(of: /FL\s*(\d{1,3})/), let fl = Int(match.1) { return level(fl) }
        guard let match = text.wholeMatch(of: /(\d+)\s*FT(?:\s+(AMSL|MSL|AGL|SFC))?/) else { return nil }
        return match.2 == "AGL" || match.2 == "SFC" ? "\(match.1) AGL" : "\(match.1) ft"
    }

    /// "today 08:00–16:00 UTC", "until 12 Nov", "from 7 Nov 08:00 UTC", "permanent", and past an estimated end
    /// "still in force, estimated end today 16:00 UTC".
    static func when(_ notam: Notam, now: Date, calendar: Calendar = NotamTime.utc) -> String {
        let suffix = notam.estimated ? " EST" : ""
        if notam.estimated, let end = notam.end, end < now {
            return L10n.Notams.estimatedEndPassed(dayAndClock(end, now: now, calendar: calendar) + " UTC")
        }
        guard let start = notam.start else {
            guard let end = notam.end else { return L10n.Notams.permanent }
            return L10n.Notams.until(dayMonth(end)) + suffix
        }
        guard let end = notam.end else {
            return start <= now ? L10n.Notams.permanent : L10n.Notams.from(dayAndClock(start, now: now, calendar: calendar) + " UTC")
        }
        if calendar.isDate(start, inSameDayAs: end) {
            return dayWords("\(NotamTime.clock(start))–\(NotamTime.clock(end)) UTC\(suffix)", on: start, now: now, calendar: calendar)
        }
        if start <= now { return L10n.Notams.until(dayMonth(end)) + suffix }
        return "\(dayAndClock(start, now: now, calendar: calendar)) – \(dayMonth(end)) \(NotamTime.clock(end)) UTC\(suffix)"
    }

    private static func dayAndClock(_ date: Date, now: Date, calendar: Calendar) -> String {
        dayWords(NotamTime.clock(date), on: date, now: now, calendar: calendar)
    }

    /// "today 12:00", "tomorrow 12:00", "7 Nov 12:00".
    private static func dayWords(_ text: String, on date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L10n.Notams.today(text) }
        if let next = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: next) {
            return L10n.Notams.tomorrow(text)
        }
        return "\(dayMonth(date)) \(text)"
    }

    /// "12 Nov", in UTC: the day first in every language, as a NOTAM's reader expects.
    static func dayMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppLanguage.current)
        formatter.timeZone = .gmt
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    /// "5500": to the hundred, plain digits as the card and the tags write a height, whatever the region's grouping.
    private static func feet(_ value: Double) -> String { String(Int((value / 100).rounded()) * 100) }

    /// "LSZQ → LFGA · today 11:00–14:10 UTC · up to 6500 ft · 10 NM either side": what the sorting used.
    static func sortedBy(_ flight: NotamFlight, now: Date, calendar: Calendar = NotamTime.utc) -> String {
        var parts = [flight.label]
        let times = "\(NotamTime.clock(flight.start))–\(NotamTime.clock(flight.end)) UTC"
        parts.append(dayWords(times, on: flight.start, now: now, calendar: calendar))
        if let ceiling = flight.ceilingFt { parts.append(L10n.Notams.upTo(feet(ceiling))) }
        parts.append(L10n.Notams.corridor)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "07:15 UTC" fresh, "3 h ago" past the hour, for the list's head.
    static func age(_ copy: NotamCopyState, now: Date) -> String? {
        guard let time = copy.time else { return nil }
        if copy.isOld(now: now) { return L10n.Notams.ageHours(String(copy.ageHours(now: now))) }
        return copyTime(time)
    }

    /// "07:15 UTC".
    static func copyTime(_ time: Date) -> String { NotamTime.clock(time) + " UTC" }
}
