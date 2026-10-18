import Foundation
import CoreLocation

/// Post-flight track reconciliation (decision D2 — review diff, never silently change
/// confirmed events).
///
/// Live detection has a ceiling: confirmation prompts auto-dismiss after 20 s while the
/// pilot is hand-flying the circuit, and single-pilot ops will always miss some. At
/// flight end this pass re-runs the validated v2 detector over the WHOLE recorded track
/// (offline — no real-time constraints, includes the end-of-flight flush) and builds a
/// diff against what the pilot confirmed in flight. The pilot reviews the diff in
/// `FlightReconciliationView`: one tap accepts the track's version, each event's type can
/// be overridden (TG ↔ GA ↔ FS — the <15 ft ambiguity band gets its human resolution
/// here), and "keep as recorded" leaves the logbook untouched.
///
/// Also derives track-based block times (same first-move / final-stillness rules the
/// club-billing validation used) to BACK-FILL flights whose engine-checklist events were
/// never tapped — 19 of the 53 corpus flights had no block off at all. Back-fill is
/// additive: existing block times are never overwritten.
enum FlightReconciliation {

    // MARK: - Models

    /// One row of the review diff.
    struct EventRow: Identifiable, Equatable {
        enum Source: Equatable {
            /// Pilot-confirmed in flight, and the track agrees (or has no opinion).
            case confirmed
            /// Detected in the track but never confirmed — the usual missed-prompt case.
            case detectedOnly
            /// Pilot-confirmed one type, the track reads another (`suggestedType`).
            case typeMismatch(recorded: FlightEventType)
            /// Recorded by the app as it saw it, with no card, and still to confirm (6.4.0).
            case taken
            /// Marked by the pilot a while after the touchdown the track shows, with nothing between them
            /// (`TrackTimes.isSameLanding`): FULL STOP held late, a lap's full stop at NEW CIRCUIT. The row
            /// has the track's time and the pilot's type; `at` is when it was marked. (6.4.1)
            case markedLater(at: Date)
        }

        let id: UUID
        /// The type the row will be applied as (starts at the track's reading; the pilot
        /// can override it in the sheet).
        var type: FlightEventType
        let timestamp: Date
        let airportIdent: String?
        let source: Source
        /// Whether the row is applied. Detected-only rows start included (accept-all
        /// semantics); the pilot can exclude any row.
        var included: Bool

        init(type: FlightEventType, timestamp: Date, airportIdent: String?, source: Source, included: Bool = true) {
            self.id = UUID()
            self.type = type
            self.timestamp = timestamp
            self.airportIdent = airportIdent
            self.source = source
            self.included = included
        }
    }

    /// The full analysis of one finished flight.
    struct Result: Equatable {
        let flightId: UUID
        /// Merged timeline, chronological.
        var events: [EventRow]
        /// Track-derived block times (nil when the track can't tell).
        let trackBlockOff: Date?
        let trackBlockOn: Date?
        /// Whether the flight was missing each block time (candidates for back-fill).
        let backfillsBlockOff: Bool
        let backfillsBlockOn: Bool

        /// True when applying would change the flight's EVENTS (not mere block-time
        /// back-fill): any detected-only, type-mismatch, or excluded row.
        var hasEventDiff: Bool {
            events.contains { row in
                switch row.source {
                case .confirmed: return false
                case .detectedOnly, .typeMismatch, .taken, .markedLater: return true
                }
            }
        }
    }

    // MARK: - Tunables

    /// A detected and a recorded event within this window are the same physical event.
    /// Wide enough to absorb the old +40 s emission lag and a late manual tap, narrow
    /// enough that consecutive circuit landings (≥90 s apart in the corpus) never merge.
    static let matchWindow: TimeInterval = 120
    /// Two landings closer than this are one physical event (same bar as AppState's
    /// entry-time guard) — reconciliation refuses the impossible pair.
    static let duplicateWindow: TimeInterval = 60

    // MARK: - Analysis

    /// Re-segment `flight`'s track and diff it against the recorded events.
    /// - Parameters:
    ///   - flight: the finished flight (track + confirmed events).
    ///   - speeds: the aircraft's speed references (checklist).
    ///   - stallSpeed: the aircraft's clean stall speed.
    ///   - nearbyAirports: fixed-wing airport query, mirroring the live detector feed.
    @MainActor
    static func analyze(
        flight: Flight,
        speeds: [SpeedReference],
        stallSpeed: Int,
        nearbyAirports: (CLLocationCoordinate2D) -> [Airport]
    ) -> Result {
        let detected = detectEvents(track: flight.gpsTrack, speeds: speeds,
                                    stallSpeed: stallSpeed, nearbyAirports: nearbyAirports)
        let (blockOff, blockOn) = trackBlockTimes(track: flight.gpsTrack)

        // Recorded events, tagged and chronological.
        var recorded: [(type: FlightEventType, time: Date)] =
            flight.goAroundTimes.map { (.goAround, $0) } +
            flight.touchAndGoTimes.map { (.touchAndGo, $0) } +
            flight.fullStopTimes.map { (.fullStop, $0) }
        recorded.sort { $0.time < $1.time }
        // What the app took in flight with no card is the pilot's to confirm here (6.4.0).
        let taken = flight.takenEventTimes ?? []
        func wasTaken(_ time: Date) -> Bool { taken.contains { abs($0.timeIntervalSince(time)) < 5 } }

        var rows: [EventRow] = []
        var claimed = Set<Int>()   // indices into `recorded` already matched

        for event in detected {
            // Nearest unclaimed recorded event within the window, any type — a pilot who
            // confirmed "go-around" on what the track reads as a touch belongs in ONE row.
            let match = recorded.enumerated()
                .filter { !claimed.contains($0.offset) &&
                          abs($0.element.time.timeIntervalSince(event.timestamp)) < matchWindow }
                .min { abs($0.element.time.timeIntervalSince(event.timestamp)) <
                       abs($1.element.time.timeIntervalSince(event.timestamp)) }
            if let match {
                claimed.insert(match.offset)
                let source: EventRow.Source = match.element.type != event.type
                    ? .typeMismatch(recorded: match.element.type)
                    : wasTaken(match.element.time) ? .taken : .confirmed
                rows.append(EventRow(type: event.type, timestamp: event.timestamp,
                                     airportIdent: event.airportIdent, source: source))
            } else {
                rows.append(EventRow(type: event.type, timestamp: event.timestamp,
                                     airportIdent: event.airportIdent, source: .detectedOnly))
            }
        }

        // A landing marked a while after the touchdown the track shows, with nothing between them that shows another
        // take-off (FULL STOP held minutes later, a lap's full stop counted at NEW CIRCUIT, a touch-and-go pressed
        // in the climb), is that touchdown's: one row, at the track's time, as the pilot called it. Only for the
        // last event detected before it; a press before the touchdown keeps the nearest match above. (6.4.1)
        for (i, event) in detected.enumerated() {
            let next = i + 1 < detected.count ? detected[i + 1].timestamp : .distantFuture
            let marked = recorded.enumerated().filter { index, entry in
                !claimed.contains(index) && entry.type != .goAround
                    && entry.time > event.timestamp && entry.time < next
                    && TrackTimes.isSameLanding(logged: entry.time, as: event.timestamp,
                                                stopped: event.type == .fullStop, track: flight.gpsTrack)
            }
            guard let last = marked.last else { continue }
            marked.forEach { claimed.insert($0.offset) }
            rows[i] = EventRow(type: last.element.type, timestamp: event.timestamp, airportIdent: event.airportIdent,
                               source: .markedLater(at: last.element.time))
        }

        // Recorded events the track has no opinion on: the pilot's manual knowledge wins,
        // they stay confirmed — UNLESS they duplicate another landing within the
        // physical-impossibility window (the corpus's double-taps, 7 s–35 s apart).
        for (index, entry) in recorded.enumerated() where !claimed.contains(index) {
            let duplicatesLanding = entry.type != .goAround && rows.contains { row in
                row.type != .goAround &&
                abs(row.timestamp.timeIntervalSince(entry.time)) < duplicateWindow
            }
            let duplicatesGoAround = entry.type == .goAround && rows.contains { row in
                row.type == .goAround &&
                abs(row.timestamp.timeIntervalSince(entry.time)) < duplicateWindow
            }
            if duplicatesLanding || duplicatesGoAround { continue }
            rows.append(EventRow(type: entry.type, timestamp: entry.time,
                                 airportIdent: nil, source: wasTaken(entry.time) ? .taken : .confirmed))
        }

        rows.sort { $0.timestamp < $1.timestamp }

        return Result(
            flightId: flight.id,
            events: rows,
            trackBlockOff: blockOff,
            trackBlockOn: blockOn,
            backfillsBlockOff: flight.blockOffTime == nil && blockOff != nil,
            backfillsBlockOn: flight.blockOnTime == nil && blockOn != nil
        )
    }

    /// Offline replay of the saved track through the v2 detector — the same core as live
    /// detection, fed at the recorded cadence with the clock pinned to each sample, with the
    /// barometer each fix recorded, plus the end-of-flight flush. Physically-impossible
    /// duplicates are dropped (keep-first).
    @MainActor
    static func detectEvents(
        track: [GPSPoint],
        speeds: [SpeedReference],
        stallSpeed: Int,
        nearbyAirports: (CLLocationCoordinate2D) -> [Airport]
    ) -> [EmittedFlightEvent] {
        guard track.count >= 10 else { return [] }
        let detector = FlightEventDetector()
        detector.configure(speeds: speeds, stallSpeed: stallSpeed)
        var now = Date()
        detector.clock = { now }
        for point in track.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let accuracy = point.horizontalAccuracy, accuracy < 0 { continue }
            now = point.timestamp
            let location = CLLocation(
                coordinate: point.coordinate,
                altitude: point.altitude,
                horizontalAccuracy: point.horizontalAccuracy ?? 0,
                verticalAccuracy: 10,
                course: point.course,
                speed: point.speed,
                timestamp: point.timestamp
            )
            // The barometer the fix recorded, as the live detector had it: live and review agree. (6.4.1)
            detector.processLocation(location, nearbyAirports: nearbyAirports(point.coordinate),
                                     baroSample: BaroAltitudeSample(recordedOn: point))
        }
        _ = detector.flushEndOfFlight()

        var events: [EmittedFlightEvent] = []
        for event in detector.emittedEvents {
            if let last = events.last, event.type != .goAround, last.type != .goAround,
               abs(event.timestamp.timeIntervalSince(last.timestamp)) < duplicateWindow {
                continue   // two landings <60 s apart cannot both be real — keep the first
            }
            events.append(event)
        }
        return events
    }

    /// Track-derived block times: the same rules END FLIGHT now applies (`TrackTimes`) — block
    /// off where the aircraft first leaves its parking spot, block on where the last movement
    /// ends. They replaced "two samples at ≥ 4 kt" in 5.2, which read the walking-pace roll out of
    /// and into a parking spot as standing still (block off 5–21 s late, block on up to 2 min
    /// early on six real flights).
    static func trackBlockTimes(track: [GPSPoint]) -> (blockOff: Date?, blockOn: Date?) {
        guard track.count >= 3 else { return (nil, nil) }
        let times = TrackTimes.analyze(track: track, engineStart: nil, engineShutdown: nil)
        return (times.blockOff, times.blockOn)
    }

    // MARK: - Application

    /// Rewrite `flight`'s events and block times from the reviewed rows. Called only from
    /// the review sheet's explicit apply — never silently (D2).
    static func apply(_ result: Result, to flight: inout Flight) {
        let applied = result.events.filter(\.included)
        flight.goAroundTimes = applied.filter { $0.type == .goAround }.map(\.timestamp)
        flight.touchAndGoTimes = applied.filter { $0.type == .touchAndGo }.map(\.timestamp)
        flight.fullStopTimes = applied.filter { $0.type == .fullStop }.map(\.timestamp)
        flight.goAroundCount = flight.goAroundTimes.count
        flight.touchAndGoCount = flight.touchAndGoTimes.count
        flight.fullStopCount = flight.fullStopTimes.count
        // Reviewed: nothing taken is left to confirm.
        flight.takenEventTimes = nil
        if let finalStop = flight.fullStopTimes.max() {
            // The final landing is the touchdown the track shows, as END FLIGHT measured it
            // (`TrackTimes`, `AppState.refineTimingFromTrack`), whenever that is this landing. The
            // rows carry the detector's stamp, the first fix on the runway, 3 to 10 s after the
            // touchdown: taking it back undid the measurement, and could move the logged minute. (6.1)
            // A full stop marked after the measured touchdown, with no take-off between them, is that touchdown too:
            // never a landing time later than the wheels touched. (6.4.1)
            let measured = TrackTimes.analyze(track: flight.gpsTrack, engineStart: flight.engineStartTime,
                                              engineShutdown: flight.engineShutdownTime).landing
            if let measured, abs(measured.timeIntervalSince(finalStop)) < matchWindow
                || TrackTimes.isSameLanding(logged: finalStop, as: measured, stopped: true, track: flight.gpsTrack),
               let index = flight.fullStopTimes.firstIndex(of: finalStop) {
                flight.fullStopTimes[index] = measured
                flight.landingTime = measured
            } else {
                flight.landingTime = finalStop
            }
        }
        backfillBlockTimes(result, to: &flight)
        flight.modifiedAt = Date()
    }

    /// Back-fill MISSING block times from the track (additive — never overwrites a
    /// recorded value). Safe to apply without review.
    static func backfillBlockTimes(_ result: Result, to flight: inout Flight) {
        if flight.blockOffTime == nil, let blockOff = result.trackBlockOff {
            flight.blockOffTime = blockOff
        }
        if flight.blockOnTime == nil, let blockOn = result.trackBlockOn {
            flight.blockOnTime = blockOn
        }
    }
}
