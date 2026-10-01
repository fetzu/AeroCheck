import XCTest
@testable import AeroCheck

/// The checks in the debrief (6.1, "Checks in flight", build plan 6): one flight's checks on its page in the
/// Flight Log (`CheckDebrief`), the phase bar kept on the flight at END FLIGHT (`Flight.checkOutcomes`),
/// and what keeps coming back across the last flights in the Logbook (`CheckTrend`).
final class CheckDebriefTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 812_000_000)
    private func minutes(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    /// A flight whose phase bar ended with every check done, but for `overrides`.
    private func flight(_ overrides: [ChecklistPhase: CheckOutcome.Status] = [:], circuits: Bool = false,
                        records: [CheckRecord]? = nil, fredas: [FredaCheck]? = nil) -> Flight {
        var flight = Flight(airplane: "wt9-dynamic")
        flight.checkOutcomes = ChecklistPhase.allCases
            .filter { !$0.isSkippedInCircuitMode(circuits) }
            .map { CheckOutcome(phase: $0, status: overrides[$0] ?? .done) }
        flight.checkRecords = records
        flight.fredaChecks = fredas
        return flight
    }

    private func row(_ debrief: CheckDebrief?, _ phase: ChecklistPhase) -> CheckDebrief.Row? {
        debrief?.rows.first { $0.phase == phase }
    }

    // MARK: Before 6.1

    func testAFlightFromBefore61ShowsNothing() {
        XCTAssertNil(CheckDebrief.make(for: Flight(airplane: "wt9-dynamic")), "no record: no section, never a false owed")
    }

    func testAFlightFileFromBefore61DecodesWithoutOutcomes() throws {
        let json = #"{"id":"6F0E6C1B-9D3C-4B8B-9E0B-6E3C2A3F4B11","airplane":"wt9-dynamic"}"#
        let flight = try JSONDecoder().decode(Flight.self, from: Data(json.utf8))
        XCTAssertNil(flight.checkOutcomes)
        XCTAssertNil(CheckDebrief.make(for: flight))
    }

    // MARK: Quiet when everything was done

    func testAFlightWithEveryCheckDoneIsOneLine() throws {
        let debrief = try XCTUnwrap(CheckDebrief.make(for: flight(
            [.climb: .doneFromMemory, .hangar: .nothingToDo, .landing: .confirmedAfterLanding],
            records: [CheckRecord(phase: .landing, kind: .confirmedAfterLanding, at: minutes(40))],
            fredas: [.done(at: minutes(20), due: FredaSchedule.Due(since: minutes(19), waypoint: nil))])))
        XCTAssertTrue(debrief.isComplete)
        XCTAssertTrue(debrief.allDone, "done, done from memory, nothing to do, confirmed after landing")
        XCTAssertEqual(debrief.rows.count, 16)
        XCTAssertEqual(debrief.noted.map(\.phase), [.landing], "the outline's distinction is kept")
        XCTAssertEqual(row(debrief, .landing)?.at, minutes(40))
        XCTAssertEqual(debrief.othersCount, 15)
    }

    func testAMissedFredaIsNotAllDone() throws {
        let debrief = try XCTUnwrap(CheckDebrief.make(for: flight(fredas: [
            .missed(FredaSchedule.Due(since: minutes(30), waypoint: "SEGNELÉGIER"))])))
        XCTAssertFalse(debrief.allDone)
        XCTAssertTrue(debrief.noted.isEmpty, "every check done: only FREDA to look at")
    }

    // MARK: Each status

    func testDoneAndDoneFromMemoryAndNothingToDo() throws {
        let debrief = CheckDebrief.make(for: flight([.climb: .doneFromMemory, .preflight: .nothingToDo]))
        XCTAssertEqual(row(debrief, .cruise)?.status, .done)
        XCTAssertEqual(row(debrief, .climb)?.status, .doneFromMemory)
        XCTAssertEqual(row(debrief, .preflight)?.status, .nothingToDo)
        XCTAssertEqual(debrief?.noted, [])
    }

    func testOwedAndNeverDoneKeepsTheCueThatPassedItAndItsTime() throws {
        let debrief = CheckDebrief.make(for: flight([.climb: .skipped], records: [
            CheckRecord(phase: .climb, kind: .owed, at: minutes(5), cue: .levelOff),
            CheckRecord(phase: .climb, kind: .skipped, at: minutes(8)),
        ]))
        let climb = try XCTUnwrap(row(debrief, .climb))
        XCTAssertEqual(climb.status, .owed)
        XCTAssertEqual(climb.cue, .levelOff)
        XCTAssertEqual(climb.owedAt, minutes(5))
        XCTAssertEqual(climb.at, minutes(8), "and when it was skipped")
        XCTAssertEqual(climb.owedCount, 1)
        XCTAssertTrue(climb.isNoted)
        XCTAssertFalse(debrief?.allDone ?? true)
    }

    func testOwedWhenTheFlightEndedOnItIsOwed() throws {
        let debrief = CheckDebrief.make(for: flight([.cruise: .open, .descent: .notReached],
                                                    records: [CheckRecord(phase: .cruise, kind: .owed, at: minutes(9), cue: .descent)]))
        XCTAssertEqual(row(debrief, .cruise)?.status, .owed)
        XCTAssertEqual(row(debrief, .cruise)?.cue, .descent)
        XCTAssertEqual(row(debrief, .descent)?.status, .notReached)
    }

    func testOwedThenDoneIsDoneLate() throws {
        let debrief = CheckDebrief.make(for: flight([.climb: .doneFromMemory], records: [
            CheckRecord(phase: .climb, kind: .owed, at: minutes(5), cue: .levelOff),
            CheckRecord(phase: .climb, kind: .doneLate, at: minutes(6)),
        ]))
        let climb = try XCTUnwrap(row(debrief, .climb))
        XCTAssertEqual(climb.status, .doneLate)
        XCTAssertEqual(climb.owedAt, minutes(5))
        XCTAssertEqual(climb.at, minutes(6))
        XCTAssertTrue(climb.isNoted)
        XCTAssertFalse(debrief?.allDone ?? true, "owed on the way is worth a look")
    }

    func testNotSureAndConfirmedAfterLandingCarryTheAnswersTime() throws {
        let notSure = CheckDebrief.make(for: flight([.landing: .notSure], records: [
            CheckRecord(phase: .landing, kind: .notSure, at: minutes(44))]))
        XCTAssertEqual(row(notSure, .landing)?.status, .notSure)
        XCTAssertEqual(row(notSure, .landing)?.at, minutes(44))
        XCTAssertFalse(notSure?.allDone ?? true)

        let yes = CheckDebrief.make(for: flight([.landing: .confirmedAfterLanding], records: [
            CheckRecord(phase: .landing, kind: .confirmedAfterLanding, at: minutes(45))]))
        XCTAssertEqual(row(yes, .landing)?.status, .confirmedAfterLanding)
        XCTAssertTrue(yes?.allDone ?? false)
    }

    func testSkippedActionMissingOpenAndNotReached() throws {
        let debrief = CheckDebrief.make(for: flight(
            [.runup: .skipped, .engineStart: .actionMissing, .shutdown: .open, .hangar: .notReached],
            records: [CheckRecord(phase: .runup, kind: .skipped, at: minutes(-10))]))
        XCTAssertEqual(row(debrief, .runup)?.status, .skipped)
        XCTAssertEqual(row(debrief, .runup)?.at, minutes(-10))
        XCTAssertEqual(row(debrief, .engineStart)?.status, .actionMissing)
        XCTAssertEqual(row(debrief, .shutdown)?.status, .open)
        XCTAssertEqual(row(debrief, .hangar)?.status, .notReached)
        XCTAssertEqual(debrief?.noted.map(\.phase), [.engineStart, .runup, .shutdown, .hangar], "in flight order")
        XCTAssertEqual(debrief?.othersCount, 12)
        XCTAssertFalse(debrief?.allDone ?? true)
    }

    func testADeferredCheckRunLaterIsDone() throws {
        // CHECK LATER, then run from the deferred list: the skip was a choice, the check got done.
        let debrief = CheckDebrief.make(for: flight(records: [CheckRecord(phase: .runup, kind: .skipped, at: minutes(-10))]))
        XCTAssertEqual(row(debrief, .runup)?.status, .done)
        XCTAssertTrue(debrief?.allDone ?? false)
    }

    func testCircuitsHaveNoCruiseNorDescentAndCountEachTimeOwed() throws {
        let debrief = CheckDebrief.make(for: flight([.approach: .done], circuits: true, records: [
            CheckRecord(phase: .approach, kind: .owed, at: minutes(5), cue: .levelOff),
            CheckRecord(phase: .approach, kind: .owed, at: minutes(12), cue: .levelOff),
        ]))
        XCTAssertNil(row(debrief, .cruise))
        XCTAssertNil(row(debrief, .descent))
        let approach = try XCTUnwrap(row(debrief, .approach))
        XCTAssertEqual(approach.status, .doneLate, "owed on two circuits, done on the last")
        XCTAssertEqual(approach.owedCount, 2)
        XCTAssertEqual(approach.owedAt, minutes(12), "the last time")
    }

    // MARK: FREDA

    func testFredaCountsDoneAndMissedInTheOrderTheyCame() throws {
        let debrief = try XCTUnwrap(CheckDebrief.make(for: flight(fredas: [
            .done(at: minutes(34), due: FredaSchedule.Due(since: minutes(33), waypoint: "SEGNELÉGIER")),
            .done(at: minutes(24), due: nil),
            .missed(FredaSchedule.Due(since: minutes(44), waypoint: nil)),
            .done(at: minutes(54), due: FredaSchedule.Due(since: minutes(54), waypoint: nil)),
        ])))
        let freda = try XCTUnwrap(debrief.freda)
        XCTAssertEqual(freda.done.count, 3)
        XCTAssertEqual(freda.missed.count, 1)
        XCTAssertEqual(freda.done.map(\.doneAt), [minutes(24), minutes(34), minutes(54)])
        XCTAssertEqual(freda.done[1].waypoint, "SEGNELÉGIER")
        XCTAssertEqual(freda.missed.first?.dueAt, minutes(44))
        XCTAssertFalse(debrief.allDone)
    }

    func testAFlightWithoutFredaHasNone() {
        XCTAssertNil(CheckDebrief.make(for: flight())?.freda)
    }

    // MARK: Recorded by a 6.1 build before the phase bar was kept

    func testRecordsAloneListOnlyWhatTheySay() throws {
        var flight = Flight(airplane: "wt9-dynamic")
        flight.checkRecords = [
            CheckRecord(phase: .climb, kind: .owed, at: minutes(5), cue: .levelOff),
            CheckRecord(phase: .landing, kind: .confirmedAfterLanding, at: minutes(44)),
            CheckRecord(phase: .descent, kind: .owed, at: minutes(30), cue: .approach),
            CheckRecord(phase: .descent, kind: .doneLate, at: minutes(31)),
            CheckRecord(phase: .runup, kind: .skipped, at: minutes(-5)),
        ]
        let debrief = try XCTUnwrap(CheckDebrief.make(for: flight))
        XCTAssertFalse(debrief.isComplete)
        XCTAssertFalse(debrief.allDone, "nothing is claimed of the other checks")
        XCTAssertEqual(debrief.rows.map(\.phase), [.runup, .climb, .descent, .landing])
        XCTAssertEqual(debrief.rows.map(\.status), [.skipped, .owed, .doneLate, .confirmedAfterLanding])
    }

    func testFredaAloneIsADebriefToo() throws {
        var flight = Flight(airplane: "wt9-dynamic")
        flight.fredaChecks = [.done(at: minutes(10), due: nil)]
        let debrief = try XCTUnwrap(CheckDebrief.make(for: flight))
        XCTAssertTrue(debrief.rows.isEmpty)
        XCTAssertFalse(debrief.allDone)
        XCTAssertEqual(debrief.freda?.done.count, 1)
    }

    // MARK: The record on the flight

    func testOutcomesRoundTrip() throws {
        let original = flight([.climb: .doneFromMemory, .landing: .notSure, .hangar: .open])
        let decoded = try JSONDecoder().decode(Flight.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.checkOutcomes, original.checkOutcomes)
        XCTAssertEqual(CheckDebrief.make(for: decoded), CheckDebrief.make(for: original))
    }

    func testAnOutcomeFromANewerBuildNeverFailsTheFlight() throws {
        let json = #"{"id":"6F0E6C1B-9D3C-4B8B-9E0B-6E3C2A3F4B11","airplane":"wt9-dynamic","checkOutcomes":"#
            + #"[{"phaseRawValue":8,"status":"someNewStatus"},{"phaseRawValue":99,"status":"done"},{"phaseRawValue":9,"status":"done"},{}]}"#
        let flight = try JSONDecoder().decode(Flight.self, from: Data(json.utf8))
        XCTAssertEqual(flight.checkOutcomes?.count, 4)
        XCTAssertEqual(CheckDebrief.make(for: flight)?.rows.map(\.phase), [.cruise], "what can't be read is left out")
    }

    func testMergeKeepsTheOutcomes() {
        var a = Flight(airplane: "wt9-dynamic", modifiedAt: Date(timeIntervalSince1970: 10))
        a.checkOutcomes = [CheckOutcome(phase: .climb, status: .done)]
        var b = a
        b.modifiedAt = Date(timeIntervalSince1970: 20)
        b.checkOutcomes = nil                                          // a copy stripped by an older build
        XCTAssertEqual(Flight.merge(a, b).checkOutcomes, a.checkOutcomes)
        XCTAssertEqual(Flight.merge(b, a).checkOutcomes, a.checkOutcomes)
    }

    func testOutcomesAreBounded() {
        var flight = Flight(airplane: "wt9-dynamic")
        flight.checkOutcomes = (0..<(CheckOutcome.maxPerFlight + 10)).map { _ in CheckOutcome(phase: .climb, status: .done) }
        XCTAssertEqual(flight.validatedForIngest()?.checkOutcomes?.count, CheckOutcome.maxPerFlight)
    }

    func testEveryRecordedStatusMapsToAnOutcome() {
        let mapped: [PhaseCompletionStatus: CheckOutcome.Status] = [
            .completed: .done, .doneFromMemory: .doneFromMemory, .confirmedAfterLanding: .confirmedAfterLanding,
            .notSure: .notSure, .skipped: .skipped, .missingAction: .actionMissing, .empty: .nothingToDo,
            .notStarted: .notReached,
        ]
        for (recorded, expected) in mapped {
            XCTAssertEqual(CheckOutcome(phase: .climb, recorded: recorded).status, expected, "\(recorded)")
        }
    }

    // MARK: The words

    func testTheDebriefsStringsHaveTheirFrench() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "fr", ofType: "lproj"))
        let french = try XCTUnwrap(Bundle(path: path))
        let missing = "\u{1}missing"
        let expected = [
            "debrief.allDone": "Toutes les vérifications faites",
            "debrief.status.owed": "en retard, jamais fait",
            "debrief.cue.levelOff": "mise en palier",
            "debrief.trend.owed": "en retard sur %lld des %lld vols",
            "debrief.trend.notSure": "« pas sûr » sur %lld des %lld vols",
            "debrief.freda.missed": "manqué %lld×",
        ]
        for (key, value) in expected {
            XCTAssertEqual(french.localizedString(forKey: key, value: missing, table: nil), value, key)
        }
        XCTAssertEqual(String(format: expected["debrief.trend.owed"]!, 4, 10), "en retard sur 4 des 10 vols")
    }
}

// MARK: - The phase bar kept at END FLIGHT

/// END FLIGHT keeps the phase bar on the flight: each check as it was recorded, the one the flight ends on
/// as it stands, those after it not reached. Flown on the bundled WT9.
@MainActor
final class CheckOutcomeAtEndOfFlightTests: XCTestCase {

    private func flight(memoryTest: Bool = false, circuits: Bool = false) -> AppState {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.learningMode = !memoryTest
        appState.settings.stepByStepHighlighting = true
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9",
                             circuitMode: circuits)
        addTeardownBlock { @MainActor in if appState.isFlightActive { appState.cancelFlight() } }
        return appState
    }

    /// The current check done: its action pressed, then a memory check confirmed or the list worked through.
    private func complete(_ appState: AppState) {
        switch appState.currentPhase {
        case .engineStart: appState.recordEngineStart()
        case .beforeDeparture: appState.recordLineUpTime()
        case .shutdown: appState.recordEngineShutdown()
        default: break
        }
        if appState.currentCheckAwaitsConfirmation {
            appState.confirmMemoryCheck()
        } else {
            appState.markLastItemComplete(learningMode: appState.effectiveLearningMode)
        }
    }

    /// Every check done and left with NEXT, up to `phase`.
    private func fly(_ appState: AppState, to phase: ChecklistPhase) {
        while appState.currentPhase.rawValue < phase.rawValue {
            let before = appState.currentPhase
            complete(appState)
            appState.nextPhase()
            guard appState.currentPhase != before else { return XCTFail("stuck on \(before)") }
        }
    }

    /// Ends the flight and returns it as the Logbook has it.
    private func end(_ appState: AppState) throws -> Flight {
        let id = try XCTUnwrap(appState.currentFlight?.id)
        appState.endFlight()
        return try XCTUnwrap(appState.flights.first { $0.id == id })
    }

    private func status(_ flight: Flight, _ phase: ChecklistPhase) -> CheckOutcome.Status? {
        flight.checkOutcomes?.first { $0.phase == phase }?.status
    }

    func testAFlightFlownToTheEndKeepsEveryCheckDone() throws {
        let appState = flight()
        fly(appState, to: .hangar)
        complete(appState)
        let saved = try end(appState)
        XCTAssertEqual(saved.checkOutcomes?.count, 16)
        for outcome in saved.checkOutcomes ?? [] {
            XCTAssertTrue([.done, .nothingToDo].contains(outcome.status), "\(String(describing: outcome.phase)): \(String(describing: outcome.status))")
        }
        XCTAssertTrue(CheckDebrief.make(for: saved)?.allDone ?? false, "All checks done")
    }

    func testMemoryChecksConfirmedAreDoneFromMemory() throws {
        let appState = flight(memoryTest: true)
        try XCTSkipUnless(appState.isMemoryCheck(.climb, learningMode: false), "needs the WT9's memory climb")
        fly(appState, to: .hangar)
        complete(appState)
        let saved = try end(appState)
        XCTAssertEqual(status(saved, .climb), .doneFromMemory)
        XCTAssertEqual(status(saved, .cruise), .done, "a read-do list")
        XCTAssertEqual(CheckDebrief.make(for: saved)?.rows.first { $0.phase == .climb }?.status, .doneFromMemory)
    }

    func testEndingOnACheckStillOpenKeepsItOpenAndTheRestNotReached() throws {
        let appState = flight()
        fly(appState, to: .cruise)
        let saved = try end(appState)                                  // from the Menu, in cruise
        XCTAssertEqual(status(saved, .climb), .done)
        XCTAssertEqual(status(saved, .cruise), .open)
        XCTAssertEqual(status(saved, .descent), .notReached)
        XCTAssertEqual(status(saved, .hangar), .notReached)
        XCTAssertFalse(CheckDebrief.make(for: saved)?.allDone ?? true)
    }

    func testEndingOnACheckDoneKeepsItDone() throws {
        let appState = flight()
        fly(appState, to: .afterLanding)
        complete(appState)
        let saved = try end(appState)
        XCTAssertEqual(status(saved, .afterLanding), .done, "worked through, no NEXT needed")
    }

    func testACheckLeftWithItsItemsOpenIsSkipped() throws {
        let appState = flight()
        fly(appState, to: .runup)
        appState.nextPhase()                                           // NEXT's review: CONTINUE
        let saved = try end(appState)
        XCTAssertEqual(status(saved, .runup), .skipped)
        let runup = CheckDebrief.make(for: saved)?.rows.first { $0.phase == .runup }
        XCTAssertEqual(runup?.status, .skipped)
        XCTAssertNotNil(runup?.at, "with the time of the skip")
    }

    func testCircuitsKeepNoCruiseNorDescent() throws {
        let appState = flight(circuits: true)
        fly(appState, to: .hangar)
        complete(appState)
        let saved = try end(appState)
        XCTAssertEqual(saved.checkOutcomes?.count, 14)
        XCTAssertNil(status(saved, .cruise))
        XCTAssertNil(status(saved, .descent))
    }

    func testTheLandedCardsAnswerIsKept() throws {
        let appState = flight(memoryTest: true)
        fly(appState, to: .landing)
        appState.presentLandedCard(touchdown: Date().addingTimeInterval(-40), aerodrome: "LSZQ")
        appState.answerLandedCard(.notSure)
        XCTAssertEqual(appState.currentPhase, .afterLanding)
        let saved = try end(appState)
        XCTAssertEqual(status(saved, .landing), .notSure)
        XCTAssertEqual(CheckDebrief.make(for: saved)?.rows.first { $0.phase == .landing }?.status, .notSure)
    }

    func testAnOwedClimbNeverDoneShowsWithItsCue() throws {
        let appState = flight(memoryTest: true)
        try XCTSkipUnless(appState.isMemoryCheck(.climb, learningMode: false), "needs the WT9's memory climb")
        fly(appState, to: .climb)
        let now = Date()
        appState.noteFlightCue(FlightCueEvent(kind: .leg, time: now.addingTimeInterval(-600), implied: false, aerodrome: "LSZQ"))
        appState.noteFlightCue(FlightCueEvent(kind: .fired(.takeoff), time: now.addingTimeInterval(-300), implied: false, aerodrome: nil))
        appState.noteFlightCue(FlightCueEvent(kind: .fired(.levelOff), time: now.addingTimeInterval(-60), implied: false, aerodrome: nil))
        appState.nextPhase()                                           // left unconfirmed: deferred whole
        let saved = try end(appState)
        let climb = try XCTUnwrap(CheckDebrief.make(for: saved)?.rows.first { $0.phase == .climb })
        XCTAssertEqual(climb.status, .owed)
        XCTAssertEqual(climb.cue, .levelOff)
        XCTAssertEqual(climb.owedAt, now.addingTimeInterval(-60))
    }
}

// MARK: - The trend

/// What keeps coming back across the last flights, in the Logbook: patterns only.
final class CheckTrendTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 812_000_000)

    /// A 6.1 flight, every check done but for `overrides`.
    private func flight(_ overrides: [ChecklistPhase: CheckOutcome.Status] = [:],
                        owed: [ChecklistPhase] = [], fredaMissed: Int = 0) -> Flight {
        var flight = Flight(airplane: "wt9-dynamic")
        flight.checkOutcomes = ChecklistPhase.allCases.map { CheckOutcome(phase: $0, status: overrides[$0] ?? .done) }
        let records = owed.map { CheckRecord(phase: $0, kind: .owed, at: t0, cue: .levelOff) }
        flight.checkRecords = records.isEmpty ? nil : records
        if fredaMissed > 0 {
            flight.fredaChecks = (0..<fredaMissed).map { _ in .missed(FredaSchedule.Due(since: t0, waypoint: nil)) }
        }
        return flight
    }

    private func patterns(_ trend: CheckTrend?) -> [String] {
        (trend?.patterns ?? []).map { pattern in
            switch pattern.subject {
            case .check(let phase, let kind): return "\(phase) \(kind) \(pattern.count)"
            case .fredaMissed: return "freda \(pattern.count)"
            }
        }
    }

    func testAnEmptyLogbookHasNoTrend() {
        XCTAssertNil(CheckTrend.make([]))
    }

    func testFlightsFromBefore61SayNothing() {
        XCTAssertNil(CheckTrend.make(Array(repeating: Flight(airplane: "wt9-dynamic"), count: 20)))
    }

    func testCleanFlightsHaveNoPattern() {
        XCTAssertNil(CheckTrend.make(Array(repeating: flight(), count: 10)))
    }

    func testOnceIsNotAPattern() {
        let flights = [flight(owed: [.climb])] + Array(repeating: flight(), count: 9)
        XCTAssertNil(CheckTrend.make(flights))
    }

    func testFewerThanThreeFlightsSayNothingYet() {
        XCTAssertNil(CheckTrend.make([flight(owed: [.climb]), flight(owed: [.climb])]))
        XCTAssertEqual(patterns(CheckTrend.make([flight(owed: [.climb]), flight(owed: [.climb]), flight()])), ["climb owed 2"])
    }

    func testWhatKeepsComingBackMostFrequentFirst() throws {
        let flights = [
            flight([.climb: .doneFromMemory], owed: [.climb]),              // owed, done late: still owed
            flight([.landing: .notSure], owed: [.climb]),
            flight([.climb: .skipped, .landing: .notSure], owed: [.climb]),  // owed then skipped: counted owed
            flight([.approach: .skipped], owed: [.climb], fredaMissed: 1),
            flight([.landing: .notSure, .approach: .actionMissing]),
            flight(fredaMissed: 1),
            flight(), flight(), flight(), flight(),
        ]
        let trend = try XCTUnwrap(CheckTrend.make(flights))
        XCTAssertEqual(trend.flights, 10)
        XCTAssertEqual(patterns(trend), ["climb owed 4", "landing notSure 3", "approach skipped 2", "freda 2"])
    }

    func testOnlyTheLastTenFlightsCount() {
        let flights = Array(repeating: flight(), count: 10) + [flight(owed: [.climb]), flight(owed: [.climb])]
        XCTAssertNil(CheckTrend.make(flights), "the two oldest are out of the window")
        XCTAssertEqual(CheckTrend.make(flights, window: 12)?.flights, 12)
    }

    func testFlightsFromBefore61ArePassedOverNotCounted() throws {
        let old = Flight(airplane: "wt9-dynamic")
        let flights = [flight(owed: [.descent]), old, old, flight(owed: [.descent]), old, flight()] + Array(repeating: old, count: 20)
        let trend = try XCTUnwrap(CheckTrend.make(flights))
        XCTAssertEqual(trend.flights, 3, "of the last 3 flights that recorded checks")
        XCTAssertEqual(patterns(trend), ["descent owed 2"])
    }

    func testOneFredaMissedIsNoPatternTwoAre() {
        XCTAssertNil(CheckTrend.make([flight(fredaMissed: 1), flight(), flight()]))
        XCTAssertEqual(patterns(CheckTrend.make([flight(fredaMissed: 2), flight(), flight()])), ["freda 2"])
    }

    func testTheTrendsWords() {
        XCTAssertEqual(L10n.Debrief.trend(.owed, 4, of: 10), String(format: String(localized: "debrief.trend.owed"), 4, 10))
        XCTAssertFalse(L10n.Debrief.trend(.notSure, 3, of: 10).hasPrefix("debrief."), "the key has a value")
    }
}
