import CoreLocation
import Foundation

// MARK: - When a VFR flight needs an ATC flight plan (6.9.0)
//
// The server's facts, from each country's own text (`flightPlan` in the briefing registry, `briefing_sources.FLIGHT_PLAN`
// in the private server repository): the app only evaluates them on a route. Whose rule: filing, the departure report
// and delays follow the departure state; closing, the state where you land; "a plan is needed", every state on the route,
// and one yes is enough (Germany waives Switzerland, Switzerland doesn't waive Germany: a plan).

/// Why a flight needs a plan. The task's reason in words (`L10n.Thread`).
enum FlightPlanNeed: Equatable {
    case border(String)
    case night
    case aerodrome(String)
    case everyFlight(String)
}

/// The registry's `flightPlan` block.
struct FlightPlanRules: Codable, Equatable, Sendable {
    struct Waiver: Codable, Equatable, Sendable {
        var states: [String]?
        var from: [String]?
        var classes: [String]?
        var day: Bool?
        var nonStop: Bool?
    }

    struct Predicate: Codable, Equatable, Sendable {
        let when: String
        var waived: [Waiver]?
        var icao: [String]?
        var classes: [String]?
    }

    struct Rule: Codable, Equatable, Sendable {
        var depRequired: Bool?
        var alertingWithoutDep: Bool?
        var cancelAfterMinutes: Int?
        var planNeeded: [Predicate]?
    }

    var countries: [String: Rule] = [:]
    var aerodromeDeparture: [String: String] = [:]

    /// A country whose rule wasn't read: a plan only for a border crossing or at night (the author, 3 Nov 2026).
    static let unread = [Predicate(when: "border"), Predicate(when: "night")]

    /// What the rules need to know of a flight.
    struct Flight: Equatable {
        /// The states under the route, in order, each once in a row.
        var states: [String]
        var departure: String?
        var arrival: String?
        var isNight = false
    }

    /// The state whose rule a departure follows: an aerodrome filed through another state's door (Basel-Mulhouse files
    /// as Swiss), else its own.
    func departureState(aerodrome: String?, country: String?) -> String? {
        aerodrome.flatMap { aerodromeDeparture[$0.uppercased()] } ?? country
    }

    func rule(for state: String?) -> Rule? { state.flatMap { countries[$0] } }

    /// Why this flight needs a plan, or nil. A `when` this build doesn't know counts as no, so a new one is additive.
    func need(for flight: Flight) -> FlightPlanNeed? {
        for state in flight.states {
            for predicate in countries[state]?.planNeeded ?? Self.unread where predicate.when == "all" {
                _ = predicate
                return .everyFlight(state)
            }
        }
        for (from, to) in zip(flight.states, flight.states.dropFirst()) {
            for (state, other) in [(from, to), (to, from)] {
                let predicates = countries[state]?.planNeeded ?? Self.unread
                for predicate in predicates where predicate.when == "border" {
                    if !(predicate.waived ?? []).contains(where: { holds($0, other: other, flight: flight) }) {
                        return .border(to)
                    }
                }
            }
        }
        for state in flight.states {
            let predicates = countries[state]?.planNeeded ?? Self.unread
            for predicate in predicates {
                if predicate.when == "aerodromes", let code = [flight.departure, flight.arrival].compactMap({ $0 })
                    .first(where: { (predicate.icao ?? []).contains($0.uppercased()) }) {
                    return .aerodrome(code)
                }
                if predicate.when == "night", flight.isNight { return .night }
            }
        }
        return nil
    }

    /// A waiver holds when every key it has holds. One the app can't prove doesn't: it can't read the class a route
    /// crosses at, so a waiver by class never holds, and a plan is asked for.
    private func holds(_ waiver: Waiver, other: String, flight: Flight) -> Bool {
        if waiver.classes != nil { return false }
        if let states = waiver.states, !states.contains(other) { return false }
        if let from = waiver.from, !from.contains(flight.states.first ?? "") { return false }
        if waiver.day == true, flight.isNight { return false }
        if waiver.nonStop == true, flight.states.last == other { return false }
        return true
    }
}

// MARK: - Night

/// The end and start of civil twilight, SERA's night, by the usual solar formulae: good to a minute or two, which is all
/// a route's planned times can use. Nil where the sun doesn't reach 6° below the horizon that day.
enum CivilTwilight {
    private static let zenith = 96.0

    /// Morning and evening at a point on the day of `date`, in UTC.
    static func times(on date: Date, at point: CLLocationCoordinate2D) -> (dawn: Date, dusk: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let start = calendar.startOfDay(for: date)
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        guard let dawn = hour(day: day, point: point, rising: true), let dusk = hour(day: day, point: point, rising: false)
        else { return nil }
        return (start.addingTimeInterval(dawn * 3600), start.addingTimeInterval(dusk * 3600))
    }

    private static func hour(day: Double, point: CLLocationCoordinate2D, rising: Bool) -> Double? {
        let rad = Double.pi / 180
        let lngHour = point.longitude / 15
        let t = day + ((rising ? 6 : 18) - lngHour) / 24
        let mean = 0.9856 * t - 3.289
        var longitude = mean + 1.916 * sin(mean * rad) + 0.020 * sin(2 * mean * rad) + 282.634
        longitude = longitude.truncatingRemainder(dividingBy: 360)
        if longitude < 0 { longitude += 360 }
        var ascension = atan(0.91764 * tan(longitude * rad)) / rad
        ascension = ascension.truncatingRemainder(dividingBy: 360)
        if ascension < 0 { ascension += 360 }
        ascension += floor(longitude / 90) * 90 - floor(ascension / 90) * 90
        ascension /= 15
        let sinDeclination = 0.39782 * sin(longitude * rad)
        let cosDeclination = cos(asin(sinDeclination))
        let cosHour = (cos(zenith * rad) - sinDeclination * sin(point.latitude * rad)) / (cosDeclination * cos(point.latitude * rad))
        guard abs(cosHour) <= 1 else { return nil }
        let hourAngle = (rising ? 360 - acos(cosHour) / rad : acos(cosHour) / rad) / 15
        var utc = hourAngle + ascension - 0.06571 * t - 6.622 - lngHour
        utc = utc.truncatingRemainder(dividingBy: 24)
        return utc < 0 ? utc + 24 : utc
    }

    /// Whether a moment is night at a point. Where the sun never reaches the twilight's depth that day, not night.
    static func isNight(_ moment: Date, at point: CLLocationCoordinate2D) -> Bool {
        guard let times = times(on: moment, at: point) else { return false }
        return moment < times.dawn || moment > times.dusk
    }

    /// Whether a flight's planned times fall in the night at either end.
    static func flightIsNight(departure: Date?, arrival: Date?, from: CLLocationCoordinate2D?, to: CLLocationCoordinate2D?) -> Bool {
        var night = false
        if let departure, let from { night = night || isNight(departure, at: from) }
        if let arrival, let to { night = night || isNight(arrival, at: to) }
        return night
    }
}
