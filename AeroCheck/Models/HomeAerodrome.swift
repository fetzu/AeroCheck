import Foundation
import CoreLocation

// MARK: - Home aerodrome (v6.1)
//
// Where the pilot, and the aircraft they fly, are based. The nav log's "Landings (base / total)"
// counts the landings made there, like the club form it copies ("Atterrissages LSZQ / total").
// It is optional: without one the count at base is unknown, never 0. A 0 would say that no landing
// was made there, and the rule that filled it until 6.1 (base = total, on every flight) said they
// all were. A plausible wrong number on a form is worse than an empty box the pilot fills in.

enum HomeAerodrome {

    /// The app's "at an aerodrome" radius: the nearest aerodrome within 5 NM names a flight's
    /// departure and arrival (block off, block on) and anchors the landing detector.
    static let radiusNm: Double = 5.0

    /// A landing is placed at the track fix nearest its time, when one is this close: the window in
    /// which the post-flight review takes a recorded and a detected event for the same one.
    static let fixWindow: TimeInterval = 120

    /// `ident` trimmed and upper-cased, or nil when it can't be an aerodrome's code (empty, too long,
    /// or characters no ident uses). Also the check on a value that arrives by sync (SA-23).
    static func normalized(_ ident: String?) -> String? {
        guard let ident else { return nil }
        let trimmed = ident.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard (3...8).contains(trimmed.count),
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    /// For a pilot who hasn't set one: the aerodrome where most of their flying days begin (each
    /// day's first departure), the most recent day breaking a tie. The most frequent departure alone
    /// can't tell home from a field visited on a day out: LSZQ → LSGE → LSGN → LSZQ departs from
    /// each of them once. Nil with no flight to go by.
    static func suggestion(from flights: [Flight], calendar: Calendar = .current) -> String? {
        // Each day's first flight that knows where it departed from
        var firstOfDay: [Date: (start: Date, ident: String)] = [:]
        for flight in flights {
            guard let start = flight.startTime,
                  let ident = normalized(flight.departureAirportIdent) else { continue }
            let day = calendar.startOfDay(for: start)
            if let known = firstOfDay[day], known.start <= start { continue }
            firstOfDay[day] = (start, ident)
        }
        // Days per aerodrome, and the latest of them for the tie
        var days: [String: (count: Int, latest: Date)] = [:]
        for (day, first) in firstOfDay {
            let known = days[first.ident] ?? (0, .distantPast)
            days[first.ident] = (known.count + 1, max(known.latest, day))
        }
        return days.max { a, b in
            a.value.count != b.value.count ? a.value.count < b.value.count : a.value.latest < b.value.latest
        }?.key
    }
}

// MARK: - Counting the landings

/// A flight's landings as the nav log counts them. (v6.1)
struct LandingTally: Equatable {
    /// Touch-and-goes and full stops, as confirmed (`Flight.totalLandings`). Go-arounds aren't landings.
    let total: Int
    /// Those at the home aerodrome. Nil when that can't be known: no home aerodrome set, no airport
    /// data to place the landings with, or a landing the track can't place.
    let atHome: Int?

    /// Count `flight`'s landings.
    /// - Parameters:
    ///   - home: the home aerodrome's ident, nil when none is set.
    ///   - aerodromeAt: the aerodrome at a position (the nearest within `HomeAerodrome.radiusNm`), nil
    ///     where there is none (a field landing counts away from home). Pass nil when the airport data
    ///     can't answer, not loaded or without the home aerodrome in it: the count at home is then unknown.
    static func of(_ flight: Flight, home: String?,
                   aerodromeAt: ((CLLocationCoordinate2D) -> String?)?) -> LandingTally {
        let total = flight.totalLandings
        guard let home = HomeAerodrome.normalized(home), let aerodromeAt else {
            return LandingTally(total: total, atHome: nil)
        }
        // Every landing needs its time to be placed. An import can carry the counts without them.
        let times = flight.touchAndGoTimes + flight.fullStopTimes
        guard times.count == total else { return LandingTally(total: total, atHome: nil) }

        var atHome = 0
        for time in times {
            // The touchdown: the fix nearest the landing's time (the detector stamps the fix on the runway)
            let fix = flight.gpsTrack.min {
                abs($0.timestamp.timeIntervalSince(time)) < abs($1.timestamp.timeIntervalSince(time))
            }
            guard let fix, abs(fix.timestamp.timeIntervalSince(time)) <= HomeAerodrome.fixWindow else {
                return LandingTally(total: total, atHome: nil)
            }
            if aerodromeAt(fix.coordinate)?.uppercased() == home { atHome += 1 }
        }
        return LandingTally(total: total, atHome: atHome)
    }
}

extension AirportDataService {

    /// `LandingTally.of` against the airport data: an aerodrome is the nearest fixed-wing one within the
    /// app's 5 NM. Load the data first (`ensureLoaded()`); until then the count at home is unknown.
    func landingTally(for flight: Flight, home: String?) -> LandingTally {
        let homeIsKnown = HomeAerodrome.normalized(home).flatMap { findAirport(byIdent: $0) } != nil
        return LandingTally.of(flight, home: home, aerodromeAt: homeIsKnown ? { [self] coordinate in
            nearestAirport(to: coordinate, maxDistanceNm: HomeAerodrome.radiusNm, types: AirportType.fixedWing)?.ident
        } : nil)
    }
}

// MARK: - The plan's counters

extension FlightPlan {

    /// END FLIGHT, and again when the post-flight review changes the flight's landings: the counters
    /// take the flight's. A counter is written when it is empty (nil or 0), or when it still holds what
    /// the app wrote before (`previous`); a number the pilot typed stays.
    func settlingLandings(_ tally: LandingTally, replacing previous: LandingTally? = nil) -> FlightPlan {
        var plan = self
        if (plan.totalLandings ?? 0) == 0 || (previous != nil && plan.totalLandings == previous?.total) {
            plan.totalLandings = tally.total
        }
        if (plan.landingsAtBase ?? 0) == 0 || (previous != nil && plan.landingsAtBase == previous?.atHome) {
            plan.landingsAtBase = tally.atHome
        }
        return plan
    }

    /// The Flight Log's nav log: both counters from the flight, whatever the stored copy says. That copy
    /// was only ever written by END FLIGHT (the Flight Log's sheet saves nothing), which until 6.1 wrote
    /// base = total on every flight, and 0 when the landing was confirmed after END FLIGHT. Computed on
    /// display like the ATOs (`withActualTimesOver(from:)`), so flights already logged read right
    /// without rewriting a synced record.
    func showingLandings(_ tally: LandingTally) -> FlightPlan {
        var plan = self
        plan.totalLandings = tally.total
        plan.landingsAtBase = tally.atHome
        return plan
    }

    /// "base / total" for the printed nav log: blank when neither is known (a plan not flown yet: the
    /// pilot writes them in, as in the other after-flight boxes), "–" for a count at base that can't be
    /// known.
    var landingsText: String {
        guard landingsAtBase != nil || totalLandings != nil else { return "" }
        return "\(landingsAtBase.map(String.init) ?? "–") / \(totalLandings.map(String.init) ?? "–")"
    }
}
