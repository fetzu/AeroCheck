import Foundation

/// Turns a flight's shape into the list of admin tasks it deserves.
///
/// Deliberately pure and free of services: everything it needs arrives in a `ThreadTaskContext`, so
/// the rules are unit-testable without a plan manager, a network, or a simulator. The manager owns
/// the side effects (persistence, notifications); this owns the "which tasks, and are they done".
///
/// Regeneration is non-destructive: a task the pilot already ticked keeps its state, note and
/// timestamp as long as its (key, subject) pair survives the edit. Editing a route therefore never
/// silently un-ticks a PPR call that has already been made.
enum ThreadTaskEngine {

    /// Everything the rules need to know about one flight. Populated by `FlightThreadManager` from
    /// the plan, the airport data and the app's own settings.
    struct Context: Equatable {
        var profile: ThreadProfile = .full
        /// True once the route has at least a departure and a destination.
        var hasRoute: Bool = false
        var departureIdent: String?
        var arrivalIdent: String?
        /// Aerodromes where a landing fee is plausible: every landing away from the departure field.
        var feeIdents: [String] = []
        /// ISO-2 countries the route touches, departure first.
        var countries: [String] = []
        /// The pilot's home country — a route that stays inside it needs no customs prompt.
        var homeCountry: String = "CH"
        /// Aerodromes flagged PPR upstream. Empty until the openAIP `ppr` field is parsed; a pilot can
        /// still add the task by hand, so an empty set costs correctness nothing.
        var pprIdents: [String] = []
        var fuelRequiredLitres: Double = 0
        var fuelOnBoardLitres: Double = 0
        /// A one-line weather summary for the route, when one has been fetched.
        var weatherSummary: String?
        /// Fuel grades reported at the destination, e.g. ["AVGAS", "UL91"]. Empty when the airport
        /// layer is not downloaded or the aerodrome reports none — absent is "not stated", never
        /// "none available". (v5.0.0)
        var destinationFuels: [String] = []
        /// True when this thread is one leg of a trip. Trip-scoped tasks then live on the trip and
        /// are NOT emitted here — otherwise the pilot would see "aircraft reserved" on every leg and
        /// have to tick it on each, which is the busywork trips exist to remove. (v5.x)
        var isLeg: Bool = false
        /// Whether the pilot tracks what a flight costs. Off hides the fee tasks; the logbook line
        /// stands on its own without them. (v5.0.0)
        var tracksCost: Bool = true
        /// Whether a flight plan has been filed for this thread — the close-out reminder only exists
        /// once there is something to close.
        var flightPlanFiled: Bool = false

        /// DABS and GAFOR are Swiss products, so they only appear on a route that touches Switzerland.
        var touchesSwitzerland: Bool { countries.contains("CH") }

        /// Countries other than home that the route touches. Drives the customs prompt.
        var foreignCountries: [String] { countries.filter { $0 != homeCountry } }
    }

    // MARK: - Generation

    /// Build the task list for a context, carrying over the state of any task that still applies.
    static func generate(context: Context, existing: [ThreadTask] = []) -> [ThreadTask] {
        let previous = Dictionary(existing.map { ($0.matchToken, $0) }, uniquingKeysWith: { first, _ in first })

        let specs: [Spec] = context.profile == .local
            ? localSpecs(context)
            : fullSpecs(context)

        // A leg's own tasks only. The shared ones are the trip's, and the leg screen shows them in
        // its own band rather than duplicating them into every leg's chapters.
        let scoped = context.isLeg ? specs.filter { $0.key.scope == .leg } : specs

        return scoped.map { spec in
            var task = ThreadTask(key: spec.key, subject: spec.subject, kind: spec.kind)
            task.detail = spec.detail
            task.isUrgent = spec.isUrgent

            if let old = previous[task.matchToken] {
                // Carry the pilot's work across a regeneration.
                task.id = old.id
                task.state = old.state
                task.completedAt = old.completedAt
                task.note = old.note
            }

            if spec.kind == .auto {
                // An auto task has no pilot input: its state IS the computation, recomputed on every
                // regeneration even for a task carried over above. The fuel row must never keep
                // claiming a plan is fuelled after the route grew by 40 NM.
                task.state = spec.autoSatisfied ? .done : .pending
                task.completedAt = spec.autoSatisfied ? (previous[task.matchToken]?.completedAt ?? Date()) : nil
            }
            return task
        }
    }

    // MARK: - Rule sets

    /// One task the rules decided to emit.
    private struct Spec {
        let key: ThreadTaskKey
        var subject: String?
        var kind: ThreadTaskKind
        var detail: String?
        var autoSatisfied: Bool = false
        var isUrgent: Bool = false
    }

    /// A cross-country flight: the full admin bracket.
    private static func fullSpecs(_ c: Context) -> [Spec] {
        var specs: [Spec] = []

        // --- PLAN ---
        specs.append(Spec(key: .routePlanned,
                          kind: .auto,
                          detail: routeDetail(c),
                          autoSatisfied: c.hasRoute))
        specs.append(Spec(key: .fuelPlanned,
                          kind: .auto,
                          detail: fuelDetail(c),
                          autoSatisfied: fuelIsSufficient(c)))
        // Mass & balance is a reminder, not a calculator: the app carries no weighing report, so
        // claiming an in-envelope result would be inventing data. (Concept decision 5)
        specs.append(Spec(key: .massAndBalance, kind: .check))
        specs.append(Spec(key: .aircraftReserved, kind: .check))

        // --- PREPARE ---
        specs.append(Spec(key: .weatherBriefed, kind: .check, detail: c.weatherSummary))
        if c.touchesSwitzerland {
            specs.append(Spec(key: .dabsChecked, kind: .check))
            specs.append(Spec(key: .gaforChecked, kind: .check))
        }
        specs.append(Spec(key: .notamChecked, kind: .check))

        // PPR is per-aerodrome and only appears where the data says it is needed.
        for ident in c.pprIdents.sorted() {
            specs.append(Spec(key: .pprObtained, subject: ident, kind: .check))
        }
        // One customs task per foreign country touched.
        for country in c.foreignCountries.sorted() {
            specs.append(Spec(key: .customsNotified, subject: country, kind: .check))
        }
        specs.append(Spec(key: .flightPlanFiled, kind: .check))
        specs.append(Spec(key: .navLogReady, kind: .check))

        // --- CLOSE ---
        if c.flightPlanFiled {
            // The one task with a real-world consequence for forgetting it: Zurich RCC alerts 30 min
            // after the ETA on an unclosed plan.
            specs.append(Spec(key: .flightPlanClosed, kind: .reminder, isUrgent: true))
        }
        for ident in c.tracksCost ? c.feeIdents.sorted() : [] {
            specs.append(Spec(key: .feesPaid, subject: ident, kind: .check))
        }
        specs.append(Spec(key: .logbookEntry, kind: .check))
        specs.append(Spec(key: .debriefWritten, kind: .check))

        return specs
    }

    /// A circuit session or local hop: the same thread, minus everything that only makes sense when
    /// you leave the circuit. Still worth having — the logbook line and the cost are just as real.
    private static func localSpecs(_ c: Context) -> [Spec] {
        var specs: [Spec] = [
            Spec(key: .aircraftReserved, kind: .check),
            Spec(key: .weatherBriefed, kind: .check, detail: c.weatherSummary)
        ]
        if c.touchesSwitzerland {
            specs.append(Spec(key: .dabsChecked, kind: .check))
        }
        specs.append(Spec(key: .logbookEntry, kind: .check))
        specs.append(Spec(key: .debriefWritten, kind: .check))
        return specs
    }

    // MARK: - Computed details

    private static func routeDetail(_ c: Context) -> String? {
        guard let departure = c.departureIdent, let arrival = c.arrivalIdent else { return nil }
        return "\(departure) → \(arrival)"
    }

    /// Fuel is "planned" when the plan says more is on board than the flight requires. Both figures
    /// come from the pilot's own plan, so this is a consistency check, not an endorsement.
    static func fuelIsSufficient(_ c: Context) -> Bool {
        c.fuelRequiredLitres > 0 && c.fuelOnBoardLitres >= c.fuelRequiredLitres
    }

    private static func fuelDetail(_ c: Context) -> String? {
        var parts: [String] = []
        if c.fuelRequiredLitres > 0 {
            let required = Int(c.fuelRequiredLitres.rounded())
            let onBoard = Int(c.fuelOnBoardLitres.rounded())
            // "45 L / 60 L" said nothing about which number was which — and got it backwards from
            // the reading most pilots expect, since the smaller figure came first. REQ and FOB are
            // the shorthand already used on the plan editor, and like every aviation abbreviation in
            // this app they stay untranslated, which also keeps this persisted detail language-neutral.
            parts.append("REQ \(required) L · FOB \(onBoard) L")
        }
        // What the destination can actually put in the tanks. This is the "refuelling options on
        // route" the fuel row is the natural home for — a pilot reading a fuel line is already
        // asking whether they can fill up at the far end.
        if let arrival = c.arrivalIdent, !c.destinationFuels.isEmpty {
            parts.append("\(arrival): \(c.destinationFuels.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
