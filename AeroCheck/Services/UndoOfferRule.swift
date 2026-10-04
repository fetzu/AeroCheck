import Foundation

/// Which undo offer the Cockpit shows, and until when (6.2). The offers come from three places: the act
/// band's MARK and leg-timer reset (`CockpitNavState`), a waypoint the flight marked on its own
/// (`FlightPlanManager.autoMarkNotice`), a memory check or a FREDA just done (`AppState`). Each keeps its
/// own, which its UNDO needs; this rule alone says which one shows, and every page asks it
/// (`NavUndoOffer.shown`), so the map's slot and the toasts of CHECKLIST and ROUTE always agree.
///
/// - The newest offer is the one, for six seconds of the pilot's time from when it was made, whichever
///   page shows it and however often the page changes.
/// - A newer offer ends the older ones for good: once it goes (UNDO, its six seconds, or its own source
///   dropping it, as DIRECT drops a waypoint's notice), none of them comes back.
///
/// Until 6.2 each page's toast counted six seconds of its own from when it appeared, and the offers took
/// turns by kind: a FREDA done a minute after a waypoint marked on its own hid that offer, which came back
/// with six fresh seconds once the FREDA's were up, and a page switch started an offer's six seconds over.
enum UndoOfferRule {
    /// Seconds an offer can be taken back: the pilot's (`FlightClock.pilotSeconds`), whatever pace a replay
    /// flies at.
    static let window: TimeInterval = 6

    /// An offer as the rule sees it: which one, and when it was made.
    struct Candidate: Equatable {
        let id: UUID
        let madeAt: Date
    }

    /// The offer to show, or nil. `candidates`: the offers their sources still hold, in the order to prefer
    /// for two made at the same instant. `lastMadeAt`: when the newest offer was made, which each source
    /// remembers after it has dropped its offer; nil when none is known.
    static func current(_ candidates: [Candidate], lastMadeAt: Date?) -> Candidate? {
        var shown: Candidate?
        for candidate in candidates where isLive(candidate.madeAt) {
            // An offer older than the newest made: ended, even when the newest is gone.
            if let lastMadeAt, candidate.madeAt < lastMadeAt { continue }
            if shown.map({ candidate.madeAt > $0.madeAt }) ?? true { shown = candidate }
        }
        return shown
    }

    /// Within its six seconds.
    static func isLive(_ madeAt: Date) -> Bool {
        remaining(madeAt) > 0
    }

    /// The pilot's seconds left to take it back, 0 once over: what a page that shows it waits before it
    /// goes, however late the page came.
    static func remaining(_ madeAt: Date) -> TimeInterval {
        let elapsed = FlightClock.pilotSeconds(since: madeAt)
        guard elapsed.isFinite else { return 0 }
        return min(max(window - elapsed, 0), window)
    }

    /// The newest of the times its sources made an offer at.
    static func lastMadeAt(_ times: Date?...) -> Date? {
        times.compactMap { $0 }.max()
    }
}
