import Foundation

// MARK: - One flight's mass and balance (6.11.0)
//
// A flight being prepared keeps its own load, on its thread. Two flights with the same aircraft, a
// solo one tomorrow and one with a passenger on Saturday, must not read each other's sheet: a load
// kept only per aircraft would show Saturday's flight "inside limits" for tomorrow's load.
//
// The fuel is the plan's fuel on board: one figure for one fact. The sheet opens with it and writes
// it back, and the state shown on the flight's page follows a change made in the plan.

/// The load of one flight being prepared, kept on its thread.
struct ThreadMassBalance: Codable, Equatable, Sendable {
    /// The aircraft it was worked for. A thread whose aircraft changes starts again.
    var registration: String
    var load: MassBalanceLoad
    var updatedAt: Date
}

/// The sheet's last state for a flight, in one line on its page and on Today. (the author's m12)
enum MassBalanceFlightState: Equatable, Sendable {
    /// No load for this flight, and none of an earlier flight to start from.
    case notDone
    /// Only an earlier flight's load: nothing is said of this one yet.
    case lastTimesLoad
    case incomplete
    case notConfirmed
    case outsideLimits(at: Date)
    case insideLimits(at: Date)
}

/// The sheet as it was when the flight started, kept with the flight. (the author's m13)
///
/// It carries what the pilot sees when they open it later, and nothing more (the author's d2): their
/// load, the three points, the verdict and its words, the envelope it was judged against, the data's
/// revision and the empty mass's date. Never the club's whole file: the flight's record is a plain
/// file in iCloud Drive, synced, backed up and written whole by every export, and the file is served
/// to subscribers only. (review SEC11-04) The verdict and the points are kept as they were, and are
/// never worked out again for display.
struct FlightMassBalance: Equatable, Sendable {
    var registration: String
    var load: MassBalanceLoad
    /// Whether the figures were the pilot's own rather than the aircraft's file.
    var isPilots: Bool
    var isConfirmed: Bool
    var verdict: MassBalanceVerdict
    var takeoff: MassBalancePoint?
    var landing: MassBalancePoint?
    var emptyTanks: MassBalancePoint?
    /// When the sheet was last changed, and when it was kept: the start of the flight.
    var sheetAt: Date
    var keptAt: Date
    /// The revision of the figures it was worked with, and the date of the empty mass's record line.
    var revision: Int
    var emptyDate: String?
    var drawing: KeptDrawing
    var words: KeptWords

    /// What the chart, the point cards and the words draw: the units, the envelope judged against, and
    /// the load's rows as places (their kind, layout and roles), to name them. No arm, no limit, no
    /// empty mass, no source.
    struct KeptDrawing: Codable, Equatable, Sendable {
        var units: AircraftMassBalance.Units
        var categoryId: String
        var maxTakeoff: Double
        var envelope: [MassBalanceCorner]
        var rows: [Row]

        struct Row: Codable, Equatable, Sendable {
            var id: String
            var kind: AircraftMassBalance.StationKind
            var layout: AircraftMassBalance.SeatLayout?
            var seats: [Seat]?
        }

        struct Seat: Codable, Equatable, Sendable {
            var id: String
            var role: AircraftMassBalance.SeatRole
        }

        init(units: AircraftMassBalance.Units, categoryId: String, maxTakeoff: Double,
             envelope: [MassBalanceCorner], rows: [Row]) {
            self.units = units
            self.categoryId = categoryId
            self.maxTakeoff = maxTakeoff
            self.envelope = envelope
            self.rows = rows
        }

        init(_ data: AircraftMassBalance) {
            let category = data.mainCategory
            self.init(units: data.units, categoryId: category?.id ?? "normal",
                      maxTakeoff: category?.maxTakeoff ?? data.limits.maxTakeoff,
                      envelope: category?.envelope ?? [],
                      rows: data.stations.map { station in
                          Row(id: station.id, kind: station.kind, layout: station.layout,
                              seats: station.seats?.map { Seat(id: $0.id, role: $0.role) })
                      })
        }

        /// As data for the views the sheet shares with the record (chart, cards, words). Every figure
        /// not kept is absent: no arm (0), no limit beyond the envelope's, no fuel figure.
        func asData(registration: String, revision: Int) -> AircraftMassBalance {
            AircraftMassBalance(
                schema: AircraftMassBalance.supportedSchema, aircraftId: "kept", registration: registration,
                revision: revision, updated: "", identity: nil, units: units, datum: nil,
                limits: .init(maxTakeoff: maxTakeoff),
                categories: [.init(id: categoryId, maxTakeoff: maxTakeoff, envelope: envelope)],
                stations: rows.map { row in
                    AircraftMassBalance.Station(id: row.id, kind: row.kind, arm: 0, layout: row.layout,
                                                seats: row.seats?.map { .init(id: $0.id, role: $0.role) })
                },
                emptyCheck: nil, handbookChecks: nil, empty: nil, sources: nil)
        }
    }

    /// The verdict in words, as worked at START: what `MassBalanceWords.lines` writes from.
    struct KeptWords: Codable, Equatable, Sendable {
        var failures: [MassBalanceFailure] = []
        var unset: [String] = []
        var massMargin: Double?
        var forwardLimit: Double?
        var aftLimit: Double?
        var notBelowLitres: Double?
        var notBelowReason: MassBalanceOutside?
        var otherCategories: [MassBalanceCategoryNote] = []

        init(_ result: MassBalanceResult) {
            failures = result.failures
            unset = result.unset
            massMargin = result.massMargin
            forwardLimit = result.limitsAtTakeoff?.forward
            aftLimit = result.limitsAtTakeoff?.aft
            notBelowLitres = result.notBelowLitres
            notBelowReason = result.notBelowReason
            otherCategories = result.otherCategories
        }
    }

    /// The data the record's views draw with (`KeptDrawing.asData`).
    var drawnData: AircraftMassBalance { drawing.asData(registration: registration, revision: revision) }

    /// The result the record shows: the kept verdict, points and words.
    var keptResult: MassBalanceResult {
        MassBalanceResult(
            verdict: verdict, takeoff: takeoff, landing: landing, emptyTanks: emptyTanks, rampMass: nil,
            failures: words.failures, unset: words.unset, massMargin: words.massMargin,
            limitsAtTakeoff: words.forwardLimit.flatMap { forward in words.aftLimit.map { (forward, $0) } },
            mostFuelLitres: nil, notBelowLitres: words.notBelowLitres, notBelowReason: words.notBelowReason,
            otherCategories: words.otherCategories)
    }

    /// The state it reads as, in one line.
    var state: MassBalanceFlightState {
        switch verdict {
        case .outsideLimits: return .outsideLimits(at: sheetAt)
        case .incomplete: return .incomplete
        case .notConfirmed: return .notConfirmed
        case .lastTimesLoad: return .lastTimesLoad
        case .insideLimits: return .insideLimits(at: sheetAt)
        }
    }

    /// The sheet as it is kept at START, from the figures and the result worked then.
    init(registration: String, load: MassBalanceLoad, data: AircraftMassBalance, empty: AircraftMassBalance.EmptyMass?,
         isPilots: Bool, isConfirmed: Bool, result: MassBalanceResult, sheetAt: Date, keptAt: Date) {
        self.registration = registration
        self.load = load
        self.isPilots = isPilots
        self.isConfirmed = isConfirmed
        verdict = result.verdict
        takeoff = result.takeoff
        landing = result.landing
        emptyTanks = result.emptyTanks
        self.sheetAt = sheetAt
        self.keptAt = keptAt
        revision = data.revision
        emptyDate = empty?.date
        drawing = KeptDrawing(data)
        words = KeptWords(result)
    }
}

extension FlightMassBalance: Codable {
    private enum CodingKeys: String, CodingKey {
        case registration, load, isPilots, isConfirmed, verdict, takeoff, landing, emptyTanks, sheetAt, keptAt
        case revision, emptyDate, drawing, words
        /// The shape the stack wrote before the review of 14 Nov 2026: the whole file and the empty
        /// mass. Read once, never written again.
        case data, empty
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        registration = try c.decode(String.self, forKey: .registration)
        load = try c.decodeIfPresent(MassBalanceLoad.self, forKey: .load) ?? MassBalanceLoad()
        isPilots = try c.decodeIfPresent(Bool.self, forKey: .isPilots) ?? false
        isConfirmed = try c.decodeIfPresent(Bool.self, forKey: .isConfirmed) ?? false
        verdict = try c.decode(MassBalanceVerdict.self, forKey: .verdict)
        takeoff = try c.decodeIfPresent(MassBalancePoint.self, forKey: .takeoff)
        landing = try c.decodeIfPresent(MassBalancePoint.self, forKey: .landing)
        emptyTanks = try c.decodeIfPresent(MassBalancePoint.self, forKey: .emptyTanks)
        sheetAt = try c.decode(Date.self, forKey: .sheetAt)
        keptAt = try c.decode(Date.self, forKey: .keptAt)
        if let drawing = try c.decodeIfPresent(KeptDrawing.self, forKey: .drawing) {
            self.drawing = drawing
            revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
            emptyDate = try c.decodeIfPresent(String.self, forKey: .emptyDate)
            words = try c.decodeIfPresent(KeptWords.self, forKey: .words) ?? KeptWords(MassBalanceResult(verdict: verdict))
        } else {
            // A sheet the stack's head kept during the device checks: the whole file. What the record
            // shows is taken from it, and the file goes at the flight's next save.
            let data = try c.decode(AircraftMassBalance.self, forKey: .data)
            let empty = try c.decodeIfPresent(AircraftMassBalance.EmptyMass.self, forKey: .empty)
            drawing = KeptDrawing(data)
            revision = data.revision
            emptyDate = empty?.date
            words = KeptWords(MassBalanceCalculator.compute(data: data, empty: empty, load: load, isConfirmed: isConfirmed))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(registration, forKey: .registration)
        try c.encode(load, forKey: .load)
        try c.encode(isPilots, forKey: .isPilots)
        try c.encode(isConfirmed, forKey: .isConfirmed)
        try c.encode(verdict, forKey: .verdict)
        try c.encodeIfPresent(takeoff, forKey: .takeoff)
        try c.encodeIfPresent(landing, forKey: .landing)
        try c.encodeIfPresent(emptyTanks, forKey: .emptyTanks)
        try c.encode(sheetAt, forKey: .sheetAt)
        try c.encode(keptAt, forKey: .keptAt)
        try c.encode(revision, forKey: .revision)
        try c.encodeIfPresent(emptyDate, forKey: .emptyDate)
        try c.encode(drawing, forKey: .drawing)
        try c.encode(words, forKey: .words)
    }
}

enum MassBalanceFlight {

    /// What is kept with a flight at its start: the followed flight's own sheet; for a flight with
    /// no flight followed (circuits, a flight without a plan), the aircraft's sheet when it was
    /// worked that day and said to be the day's. Nil when there is no such sheet, or no figures to
    /// work it with. Nothing is made up for a flight nobody prepared a sheet for.
    static func record(thread: FlightThread?, registration: String, shipped: AircraftMassBalance?,
                       setup: MassBalanceSetup, plan: FlightPlan?, now: Date = Date(),
                       calendar: Calendar = .current) -> FlightMassBalance? {
        guard let basis = setup.basis(shipped: shipped, now: now) else { return nil }
        let load: MassBalanceLoad
        let sheetAt: Date
        if let thread {
            guard let own = ownLoad(of: thread),
                  own.registration.caseInsensitiveCompare(registration) == .orderedSame else { return nil }
            load = startingLoad(for: thread, setup: setup, plan: plan) ?? own.load
            sheetAt = own.updatedAt
        } else {
            guard let last = setup.lastLoad, !last.isBlank, last.isTodays, let day = setup.lastLoadDay,
                  calendar.isDate(day, inSameDayAs: now) else { return nil }
            load = last
            sheetAt = day
        }
        let result = MassBalanceCalculator.compute(data: basis.data, empty: basis.empty, load: load,
                                                   isConfirmed: basis.isConfirmed)
        return FlightMassBalance(registration: registration, load: load, data: basis.data, empty: basis.empty,
                                 isPilots: basis.source == .pilot, isConfirmed: basis.isConfirmed,
                                 result: result, sheetAt: sheetAt, keptAt: now)
    }

    /// The thread's own load, when it was worked for the aircraft the thread has now.
    static func ownLoad(of thread: FlightThread) -> ThreadMassBalance? {
        guard let kept = thread.massBalance, let registration = thread.aircraftRegistration,
              kept.registration.caseInsensitiveCompare(registration) == .orderedSame else { return nil }
        return kept
    }

    /// The load a flight's sheet opens with, nil for a sheet started from nothing.
    ///
    /// The flight's own load as it was left; otherwise the aircraft's last load, which belonged to
    /// another flight and is never this one's until the pilot says so, whatever the day. With a
    /// plan, the fuel is the plan's fuel on board (unset while the plan has none) and the trip fuel
    /// the route's.
    static func startingLoad(for thread: FlightThread, setup: MassBalanceSetup, plan: FlightPlan?) -> MassBalanceLoad? {
        var load: MassBalanceLoad?
        if let own = ownLoad(of: thread) {
            load = own.load
        } else if let last = setup.lastLoad, !last.isBlank {
            load = last.carriedOver(from: setup.lastLoadDay ?? Date())
        }
        guard let plan else { return load }
        let trip = routeTrip(of: plan)
        guard load != nil || plan.fuelOnBoard != nil || trip != nil else { return nil }
        var withFuel = load ?? MassBalanceLoad(isTodays: true)
        withFuel.fuelLitres = plan.fuelOnBoard
        if let trip { withFuel.tripLitres = trip }
        return withFuel
    }

    /// The trip fuel a flight's route gives, when it gives one. With it, the sheet's trip is the
    /// route's: shown, marked "from the route", never typed. A trip typed there counted only while
    /// the sheet was open, and the flight's page, Today and the kept sheet used the route's (the
    /// author's d4, review ST11-10). A flight without a route keeps its box.
    static func routeTrip(of plan: FlightPlan?) -> Double? {
        plan?.tripFuel.flatMap { MassBalanceBounds.fuelLitres.contains($0) && $0 > 0 ? $0 : nil }
    }

    /// Whether a flight's sheet works with figures the pilot typed: its line then ends with "your
    /// figures" (the author's d5, review UX11-24). Once the flight has started, the kept sheet's.
    static func isPilotsFigures(for thread: FlightThread, shipped: AircraftMassBalance?, setup: MassBalanceSetup,
                                kept: FlightMassBalance? = nil, now: Date = Date()) -> Bool {
        if thread.flightId != nil { return kept?.isPilots ?? false }
        return setup.basis(shipped: shipped, now: now)?.source == .pilot
    }

    /// The line for the flight's page and Today. Nil where there is nothing to say: no aircraft on
    /// the flight, or no data to compute with (the 5.0.0 calculator keeps no state).
    ///
    /// Once the flight has started, the line is the kept sheet's and nothing else: the sheet of a
    /// running or flown flight is not worked again.
    static func state(for thread: FlightThread, shipped: AircraftMassBalance?, setup: MassBalanceSetup,
                      plan: FlightPlan?, kept: FlightMassBalance? = nil, now: Date = Date()) -> MassBalanceFlightState? {
        if thread.flightId != nil { return kept?.state }
        guard thread.aircraftRegistration?.isEmpty == false,
              let basis = setup.basis(shipped: shipped, now: now) else { return nil }
        guard let own = ownLoad(of: thread) else {
            return (setup.lastLoad.map { !$0.isBlank } ?? false) ? .lastTimesLoad : .notDone
        }
        // With the plan's fuel as it is now, not as it was when the sheet was closed.
        let load = startingLoad(for: thread, setup: setup, plan: plan) ?? own.load
        let result = MassBalanceCalculator.compute(data: basis.data, empty: basis.empty, load: load,
                                                   isConfirmed: basis.isConfirmed)
        switch result.verdict {
        case .outsideLimits: return .outsideLimits(at: own.updatedAt)
        case .incomplete: return .incomplete
        case .notConfirmed: return .notConfirmed
        case .lastTimesLoad: return .lastTimesLoad
        case .insideLimits: return .insideLimits(at: own.updatedAt)
        }
    }
}
