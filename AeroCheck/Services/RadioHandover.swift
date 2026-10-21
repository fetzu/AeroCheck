import Foundation

// MARK: - The frequency handover (6.4.3)
//
// The radio timeline (`RadioTimeline`) says where each call comes; it can't know when the pilot actually changes
// frequency, which is often the FIS's or a tower's to give ("frequency change approved"), earlier or later than the
// timeline's call point. The author's answers of 19 Oct 2026 (the proposal "Frequency Handover", q1 to q10):
//
// - Due: where NOW changed in 6.4.2, NEXT comes due instead (`RadioTimeline.Rules.due`). NOW stays.
// - The pilot's switch: a tap on NEXT, due or not, makes it NOW. A tap on a LISTEN in NEXT means heard. A station
//   picked in ROUTE › RADIO is NOW from there.
// - The app's switch: with no tap by the latest point (`Rules.latest`: a zone's boundary, 2 NM past its exit, a FIS
//   boundary, the departure 10 NM out or out of its zone, the destination's zone or arrival point), NOW moves on by
//   itself and says so. Either switch can be undone for 6 s (the Cockpit's radio keeps the state before it).
//
// Switches are ordered by `takenAtNM`, a progress along the route, never by an index into the timeline: the leads are
// minutes, turned into miles at the ground speed of the moment, so the stretches move as the aircraft speeds up or
// slows down.

/// Where the pilot is on the radio timeline: the station they are on. Pure; kept with the flight.
struct RadioHandover: Codable, Equatable {
    typealias Station = RadioTimeline.Station

    /// The station the pilot is on; nil until the flight is first read (then the timeline's NOW, the departure).
    var station: Station?
    /// Its kind on the timeline, for its name ("Zürich Info"); nil for a station picked off the route.
    var kind: RadioTimeline.Kind?
    /// The progress from which the changes ahead are the pilot's still to make: where they switched, or, switching
    /// ahead of a station's stretch (released before it came due), where that stretch comes. Nil: from the start.
    var takenAtNM: Double?
    /// The departure is behind: switched from, or left at its latest point.
    var departureLeft = false
    /// Where leaving the departure came due (the level-off, or a zone's call in the climb): the start of its line.
    var departureDueAtNM: Double?
    /// The LISTEN items heard: their frequency, and the end of their window then.
    var heard: [Heard] = []
    /// The timeline was built again (an edit, a Direct To, the data arriving): the next reading takes the changes
    /// before the aircraft as done, the pilot's station kept.
    var rebase = false
    /// The app's own switch to this station was undone: NEXT shows it due, without the line (the app won't switch
    /// again), until the pilot switches or its stretch ends.
    var declined: Station?

    struct Heard: Codable, Equatable {
        let frequency: String
        let endsNM: Double
    }

    /// What the band shows.
    struct Reading: Equatable {
        /// NOW: the pilot's station, under the timeline's name for it where the timeline has it here (its HX, the TMA
        /// beside it).
        var now: RadioTimeline.Call?
        var next: Station?
        var nextKind: RadioTimeline.Kind?
        var nextIsListen = false
        /// NEXT is due: the pilot is expected to switch now.
        var nextIsDue = false
        /// While due, the share of the way from where it came due to where the app switches by itself still to go, 1
        /// to 0; nil when the app won't switch by itself (no latest point ahead).
        var dueLeft: Double?
        /// The window's end of the LISTEN in NEXT: what a tap on it marks heard.
        var listenEndsNM: Double?
    }

    /// The app's own switch, at a latest point.
    struct Switch: Equatable {
        let from: Station?
        let to: Station
    }

    /// A LISTEN heard is this close to the one in NEXT: the same window, whatever the speed did to its end since.
    static let heardMatchNM = 1.0
    /// The app's own switch never goes to an Info whose stretch is shorter than this at the ground speed: the pilot
    /// stays where they are until the next one. Bâle Info held 20 s before LSZQ in the dr-3 replay with no tap. A
    /// zone is always taken, however briefly crossed: its tower must be called. (6.4.3)
    static let shortestStretch: TimeInterval = 60

    /// The reading at a moment, and the state after it: the app's own switch at a latest point, the first reading, a
    /// rebase. Pure.
    func advanced(on timeline: RadioTimeline, at moment: RadioTimeline.Moment) -> (state: RadioHandover, reading: Reading, switched: Switch?) {
        let p = moment.progressNM, v = moment.speedKt
        var state = self
        var switched: Switch?

        // First read: the station the pilot must be on by now. On the ground, the departure; mid-route (a relaunch
        // without the state), where the latest rules put them, a call due from there. The departure's latest point is
        // the one a flight followed from the start has: 10 NM out or its zone left, whatever the level-off (below).
        // Read at the level-off itself, the guided dry run's chapter 5 started on Bâle Info, nothing due, and its
        // card never came (6.4.3 device checks, ho-19).
        if state.station == nil,
           let first = timeline.now(atNM: p, speedKt: v, departureOver: false, rules: .latest) {
            state.station = first.station
            state.kind = first.kind
            state.takenAtNM = p
            state.departureLeft = first.kind != .departure
        }
        if state.rebase {
            state.rebase = false
            state.takenAtNM = p
            if state.kind == .departure, timeline.calls.first(where: { $0.kind == .departure }) == nil { state.departureLeft = true }
        }
        guard let mine = state.station else { return (state, Reading(), nil) }
        let taken = state.takenAtNM ?? -.infinity

        var reading = Reading()
        if !state.departureLeft {
            // The departure: due at the level-off, left by itself 10 NM out (or out of its zone), or into a zone at its
            // boundary.
            if let latest = timeline.now(atNM: p, speedKt: v, departureOver: false, rules: .latest),
               latest.kind != .departure, !latest.station.hasSameFrequency(as: mine),
               !(state.declined?.hasSameFrequency(as: latest.station) ?? false) {
                state.departureLeft = true
                state.station = latest.station
                state.kind = latest.kind
                state.takenAtNM = p
                switched = Switch(from: mine, to: latest.station)
            } else {
                let here = timeline.now(atNM: p, speedKt: v, departureOver: moment.departureOver, rules: .due)
                // NOW is the pilot's station, past its latest point too (the app's switch undone).
                reading.now = [here, timeline.now(atNM: p, speedKt: v, departureOver: false, rules: .due)]
                    .compactMap { $0 }.first { $0.station.hasSameFrequency(as: mine) }
                    ?? timeline.calls.first { $0.station.hasSameFrequency(as: mine) }
                    ?? RadioTimeline.Call(station: mine, kind: state.kind ?? .departure, fromNM: p, toNM: .infinity)
                if let declined = state.declined {
                    reading.next = declined
                    reading.nextKind = timeline.calls.first { $0.station.hasSameFrequency(as: declined) }?.kind
                    reading.nextIsDue = true
                } else if let here, !here.station.hasSameFrequency(as: mine) {
                    if state.departureDueAtNM == nil { state.departureDueAtNM = p }
                    // The latest point: the departure's end, or a zone's boundary in the climb, whichever comes first.
                    let end = timeline.calls.first { $0.kind == .departure }
                        .map { timeline.end(of: $0, departureOver: false, rules: .latest) }
                    let zone = timeline.firstChange(to: here.station, after: p, speedKt: v, departureOver: false, rules: .latest)?.nm
                    reading.next = here.station
                    reading.nextKind = here.kind
                    reading.nextIsDue = true
                    reading.dueLeft = Self.left(from: state.departureDueAtNM, at: p, to: [end, zone].compactMap { $0 }.min())
                } else if let next = timeline.nextCall(after: reading.now, moment) {
                    reading.next = next.station
                    reading.nextKind = next.kind
                }
                state.listen(timeline, moment, into: &reading)
                return (state, reading, switched)
            }
        }

        // En route. The app's own switch: NOW under the latest rules is another station, and its stretch began after
        // the pilot's last switch.
        let pilot = state.station ?? mine
        if switched == nil,
           let latest = timeline.now(atNM: p, speedKt: v, departureOver: true, rules: .latest),
           !latest.station.hasSameFrequency(as: pilot),
           timeline.segmentStart(at: p, speedKt: v, departureOver: true, rules: .latest) > taken,
           !(latest.kind == .fis && Self.isBrief(latest.station, on: timeline, at: p, speedKt: v)) {
            state.station = latest.station
            state.kind = latest.kind
            state.takenAtNM = p
            switched = Switch(from: pilot, to: latest.station)
        }
        let current = state.station ?? pilot
        let takenNow = state.takenAtNM ?? -.infinity
        let latestHere = timeline.now(atNM: p, speedKt: v, departureOver: true, rules: .latest)
        let due = timeline.now(atNM: p, speedKt: v, departureOver: true, rules: .due)

        // NOW under the timeline's name where it has the pilot's frequency here.
        if let due, due.station.hasSameFrequency(as: current) {
            reading.now = due
        } else if let latestHere, latestHere.station.hasSameFrequency(as: current) {
            reading.now = latestHere
        } else {
            reading.now = RadioTimeline.Call(station: current, kind: state.kind ?? .unit, fromNM: p, toNM: .infinity)
        }

        // An undone switch of the app's: its station due in NEXT while it is the due one, without the line.
        if let declined = state.declined {
            if let due, due.station.hasSameFrequency(as: declined), !declined.hasSameFrequency(as: current) {
                reading.next = declined
                reading.nextKind = due.kind
                reading.nextIsDue = true
            } else {
                state.declined = nil
            }
        }

        // NEXT: the due station when it isn't the pilot's and its stretch began after the pilot's last switch, or its
        // change is still to come under the latest rules (a station picked off the route meanwhile); else the next
        // change ahead.
        if reading.next == nil, let due, !due.station.hasSameFrequency(as: current) {
            let dueStart = timeline.segmentStart(at: p, speedKt: v, departureOver: true, rules: .due)
            let latest = latestHere?.station.hasSameFrequency(as: due.station) == true ? nil
                : timeline.firstChange(to: due.station, after: p, speedKt: v, departureOver: true, rules: .latest)
            // A station the pilot skipped (switched past it to a later one) is behind them, its latest point too.
            if dueStart > takenNow || (latest.map { $0.nm > takenNow } ?? false) {
                reading.next = due.station
                reading.nextKind = due.kind
                reading.nextIsDue = true
                reading.dueLeft = Self.left(from: dueStart.isFinite ? dueStart : nil, at: p, to: latest?.nm)
            }
        }
        // From the pilot's stretch on: switched ahead (an early release, inside a zone), the station just left is
        // behind them, not NEXT (the Grenchen replay read LSZG TWR HX in NEXT after an early tap to Zürich Info).
        if reading.next == nil,
           let next = timeline.nextChange(from: current, after: max(p, takenNow), speedKt: v, departureOver: true,
                                          rules: .due) {
            reading.next = next.station
            reading.nextKind = next.kind
        }
        state.listen(timeline, moment, into: &reading)
        return (state, reading, switched)
    }

    /// A LISTEN in its window, not heard, takes NEXT unless a call is due: the switch first.
    private func listen(_ timeline: RadioTimeline, _ moment: RadioTimeline.Moment, into reading: inout Reading) {
        guard !reading.nextIsDue else { return }
        let heard = self.heard
        guard let listen = timeline.listening(moment, besides: reading.now?.station, heard: { item, ends in
            heard.contains { RadioTimeline.Station.isSameFrequency($0.frequency, item.station.frequency)
                && abs($0.endsNM - ends) <= Self.heardMatchNM }
        }) else { return }
        reading.next = listen.station
        reading.nextKind = nil
        reading.nextIsListen = true
        reading.listenEndsNM = listen.ends
    }

    /// The latest rules leave `station` again within `shortestStretch` of `progress`.
    static func isBrief(_ station: Station, on timeline: RadioTimeline, at progress: Double, speedKt: Double) -> Bool {
        let horizon = progress + shortestStretch * max(speedKt, RadioTimeline.minimumSpeedKt) / 3600
        for point in timeline.changePoints(speedKt: speedKt, departureOver: true, rules: .latest)
        where point > progress && point <= horizon {
            let after = timeline.now(atNM: point + 1e-6, speedKt: speedKt, departureOver: true, rules: .latest)
            if !(after?.station.hasSameFrequency(as: station) ?? false) { return true }
        }
        return false
    }

    /// The share still to go between where NEXT came due (`from`, else now) and the latest point (`to`).
    static func left(from start: Double?, at progress: Double, to end: Double?) -> Double? {
        guard let end, end.isFinite else { return nil }
        let from = min(start ?? progress, progress)
        guard end > from else { return 0 }
        return min(1, max(0, (end - progress) / (end - from)))
    }

    // MARK: - The pilot's switches

    /// The pilot switched to `station` (NEXT, or a station picked in ROUTE › RADIO): NOW from here. Ahead of its
    /// stretch (released before it came due), the changes before that stretch are taken as done.
    func switching(to station: Station, kind: RadioTimeline.Kind?, on timeline: RadioTimeline,
                   at moment: RadioTimeline.Moment) -> RadioHandover {
        let p = moment.progressNM, v = moment.speedKt
        var state = self
        state.station = station
        state.kind = kind ?? timeline.calls.first { $0.station.hasSameFrequency(as: station) }?.kind
        state.departureLeft = true
        state.declined = nil
        let dueHere = timeline.now(atNM: p, speedKt: v, departureOver: true, rules: .due)
        if dueHere?.station.hasSameFrequency(as: station) == true {
            state.takenAtNM = p
        } else {
            let comes = timeline.firstChange(to: station, after: p, speedKt: v, departureOver: true, rules: .due)?.nm
            state.takenAtNM = max(p, comes ?? p)
        }
        return state
    }

    /// The app's own switch to `station` undone: the pilot stays where they were, the changes before `progress` taken
    /// as done, and `station` stays due in NEXT without the app switching again.
    func declining(_ station: Station, at progress: Double?) -> RadioHandover {
        var state = self
        state.declined = station
        if let progress { state.takenAtNM = max(takenAtNM ?? progress, progress) }
        return state
    }

    /// The pilot heard the LISTEN in NEXT: it leaves NEXT.
    func hearing(_ station: Station, endsNM: Double) -> RadioHandover {
        var state = self
        state.heard.append(Heard(frequency: station.frequency, endsNM: endsNM))
        return state
    }
}
