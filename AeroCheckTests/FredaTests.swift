import XCTest
@testable import AeroCheck

/// FREDA in cruise (6.1, "Checks in flight" Q6): after the cruise check, due every ten minutes or at a
/// waypoint passed five minutes or more after the last one, whichever comes first; one tap done, with
/// undo; recorded on the flight, done or missed; never a page change. The rules first (`FredaSchedule`),
/// then read off a flight on the bundled WT9, whose cruise check is a read-do list.
@MainActor
final class FredaTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func minutes(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    // MARK: The cadence, by time

    func testItDoesNotRunUntilStarted() {
        var schedule = FredaSchedule()
        XCTAssertFalse(schedule.evaluate(now: minutes(60), lastPassage: FredaWaypointPassage(name: "A", at: minutes(30))))
        XCTAssertNil(schedule.due)
        XCTAssertNil(schedule.remaining(now: minutes(1)))
    }

    func testDueTenMinutesAfterTheCruiseCheck() {
        var schedule = FredaSchedule()
        schedule.start(at: t0, after: .cruiseCheck)
        XCTAssertFalse(schedule.evaluate(now: minutes(9.99), lastPassage: nil))
        XCTAssertEqual(schedule.remaining(now: minutes(4)) ?? 0, 6 * 60, accuracy: 0.001)
        XCTAssertTrue(schedule.evaluate(now: minutes(10), lastPassage: nil))
        XCTAssertEqual(schedule.due, FredaSchedule.Due(since: minutes(10), waypoint: nil))
    }

    func testOnceDueItStaysDueUntilDone() {
        var schedule = FredaSchedule()
        schedule.start(at: t0, after: .cruiseCheck)
        schedule.evaluate(now: minutes(10), lastPassage: nil)
        XCTAssertFalse(schedule.evaluate(now: minutes(25), lastPassage: FredaWaypointPassage(name: "B", at: minutes(24))))
        XCTAssertEqual(schedule.due?.since, minutes(10), "when it came due, not when it was looked at")

        schedule.start(at: minutes(26), after: .freda)
        XCTAssertNil(schedule.due)
        XCTAssertEqual(schedule.since, .freda)
        XCTAssertEqual(schedule.nextDueAt, minutes(36))
    }

    // MARK: The cadence, by waypoint

    func testAWaypointFiveMinutesOrMoreAfterMakesItDue() {
        var schedule = FredaSchedule()
        schedule.start(at: t0, after: .cruiseCheck)
        let passage = FredaWaypointPassage(name: "SEGNELÉGIER", at: minutes(7))
        XCTAssertTrue(schedule.evaluate(now: minutes(7.2), lastPassage: passage))
        XCTAssertEqual(schedule.due, FredaSchedule.Due(since: minutes(7), waypoint: "SEGNELÉGIER"))
    }

    func testTheFiveMinuteFloor() {
        var exactly = FredaSchedule()
        exactly.start(at: t0, after: .freda)
        XCTAssertTrue(exactly.evaluate(now: minutes(5.1), lastPassage: FredaWaypointPassage(name: "A", at: minutes(5))))

        var under = FredaSchedule()
        under.start(at: t0, after: .freda)
        let early = FredaWaypointPassage(name: "A", at: minutes(4.9))
        XCTAssertFalse(under.evaluate(now: minutes(6), lastPassage: early), "too soon after the last FREDA")
        XCTAssertTrue(under.evaluate(now: minutes(10), lastPassage: early), "then the ten minutes")
        XCTAssertNil(under.due?.waypoint)
    }

    func testAWaypointPassedBeforeTheLastFredaDoesNotCount() {
        var schedule = FredaSchedule()
        schedule.start(at: minutes(10), after: .freda)
        let passage = FredaWaypointPassage(name: "A", at: minutes(8))
        XCTAssertFalse(schedule.evaluate(now: minutes(16), lastPassage: passage))
        XCTAssertTrue(schedule.evaluate(now: minutes(20), lastPassage: passage))
        XCTAssertNil(schedule.due?.waypoint)
    }

    func testWhicheverComesFirst() {
        // Looked at late (the app in the background): the waypoint came first.
        var byWaypoint = FredaSchedule()
        byWaypoint.start(at: t0, after: .cruiseCheck)
        byWaypoint.evaluate(now: minutes(12), lastPassage: FredaWaypointPassage(name: "A", at: minutes(7)))
        XCTAssertEqual(byWaypoint.due, FredaSchedule.Due(since: minutes(7), waypoint: "A"))

        // The ten minutes came first.
        var byTime = FredaSchedule()
        byTime.start(at: t0, after: .cruiseCheck)
        byTime.evaluate(now: minutes(12), lastPassage: FredaWaypointPassage(name: "A", at: minutes(11)))
        XCTAssertEqual(byTime.due, FredaSchedule.Due(since: minutes(10), waypoint: nil))
    }

    func testStoppingHandsBackTheOneMissed() {
        var schedule = FredaSchedule()
        schedule.start(at: t0, after: .cruiseCheck)
        XCTAssertNil(schedule.stop(), "not due: nothing missed")
        XCTAssertFalse(schedule.isRunning)

        schedule.start(at: t0, after: .cruiseCheck)
        schedule.evaluate(now: minutes(10), lastPassage: nil)
        XCTAssertEqual(schedule.stop(), FredaSchedule.Due(since: minutes(10), waypoint: nil))
        XCTAssertEqual(schedule, FredaSchedule())
    }

    // MARK: The waypoints the flight passed

    func testTheLastWaypointPassedPastTheDeparture() {
        var plan = FlightPlan(name: "Test", waypoints: [
            FlightPlanWaypoint(name: "LSGN", coordinate: .init(latitude: 46.96, longitude: 6.86)),
            FlightPlanWaypoint(name: "SEGNELÉGIER", coordinate: .init(latitude: 47.25, longitude: 7.0)),
            FlightPlanWaypoint(name: "", coordinate: .init(latitude: 47.3, longitude: 7.02)),
            FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.35, longitude: 7.03)),
        ])
        XCTAssertNil(FredaWaypointPassage.latest(in: plan), "nothing passed yet")
        XCTAssertNil(FredaWaypointPassage.latest(in: nil))

        plan.waypoints[0].actualTimeOver = minutes(20)   // the take-off, not a waypoint passed
        XCTAssertNil(FredaWaypointPassage.latest(in: plan))

        plan.waypoints[1].actualTimeOver = minutes(13)
        XCTAssertEqual(FredaWaypointPassage.latest(in: plan), FredaWaypointPassage(name: "SEGNELÉGIER", at: minutes(13)))
        plan.waypoints[2].actualTimeOver = minutes(15)
        XCTAssertEqual(FredaWaypointPassage.latest(in: plan), FredaWaypointPassage(name: "WPT 3", at: minutes(15)))
    }

    // MARK: On a flight

    private func flight(circuits: Bool = false, datastore: DataPersistenceManager? = nil,
                        defaults: UserDefaults? = nil) -> AppState {
        let appState = makeTestAppState(datastore: datastore, defaults: defaults)
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.learningMode = true
        appState.settings.stepByStepHighlighting = true
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9",
                             circuitMode: circuits)
        addTeardownBlock { @MainActor in appState.cancelFlight() }
        return appState
    }

    /// In cruise, the cruise check worked through: FREDA counts from now.
    private func cruiseChecked(_ appState: AppState) throws {
        appState.currentPhase = .cruise
        try XCTSkipIf(appState.activeChecklist.visibleItemCount(for: .cruise, learningMode: true) == 0,
                      "needs the WT9's cruise list")
        appState.markLastItemComplete(learningMode: appState.effectiveLearningMode)
    }

    func testItStartsWithTheCruiseCheck() throws {
        let appState = flight()
        appState.currentPhase = .cruise
        appState.evaluateFreda(now: Date().addingTimeInterval(3_600))
        XCTAssertFalse(appState.freda.isRunning, "not before the cruise check")

        let before = Date()
        try cruiseChecked(appState)
        XCTAssertTrue(appState.freda.isRunning)
        XCTAssertEqual(appState.freda.since, .cruiseCheck)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(appState.freda.anchor), before)
    }

    func testItComesDueWithoutTakingTheMapAway() throws {
        let appState = flight()
        try cruiseChecked(appState)
        let highlight = appState.currentHighlightedItem[.cruise]
        appState.evaluateFreda(now: Date().addingTimeInterval(FredaSchedule.interval + 1))
        XCTAssertTrue(appState.fredaDue)

        // The old reminder reopened the cruise list, which flipped the page to the CHECKLIST by itself.
        XCTAssertEqual(appState.currentHighlightedItem[.cruise], highlight, "the cruise list stays done")
        XCTAssertTrue(appState.currentCheckIsDone)
        XCTAssertEqual(CockpitPageRule.defaultPage(phase: .cruise, checklistDone: appState.currentCheckIsDone,
                                                   memoryCheck: appState.isMemoryCheck(.cruise)), .map)
    }

    func testAWaypointPassedMakesItDue() throws {
        let appState = flight()
        try cruiseChecked(appState)
        let passed = FredaWaypointPassage(name: "LSGC", at: Date().addingTimeInterval(6 * 60))
        appState.evaluateFreda(now: Date().addingTimeInterval(6 * 60 + 10), lastPassage: passed)
        XCTAssertEqual(appState.freda.due?.waypoint, "LSGC")
        let slot = CockpitCheckSlot.slot(for: appState)
        XCTAssertEqual(slot.line, .fredaFlow(waypoint: "LSGC"))
        XCTAssertEqual(slot.action, .confirmFreda)
    }

    func testDoneIsRecordedOnTheFlightAndTheCountStartsAgain() throws {
        let appState = flight()
        try cruiseChecked(appState)
        let due = Date().addingTimeInterval(FredaSchedule.interval + 30)
        appState.evaluateFreda(now: due)
        let dueSince = try XCTUnwrap(appState.freda.due?.since)
        appState.confirmFreda(at: due.addingTimeInterval(20))

        let record = try XCTUnwrap(appState.currentFlight?.fredaChecks?.last)
        XCTAssertEqual(record.outcome, .done)
        XCTAssertEqual(record.dueAt, dueSince)
        XCTAssertEqual(record.doneAt, due.addingTimeInterval(20))
        XCTAssertFalse(appState.fredaDue)
        XCTAssertEqual(appState.freda.since, .freda)
        XCTAssertEqual(appState.freda.anchor, due.addingTimeInterval(20))
        XCTAssertNotNil(appState.fredaConfirmation)
    }

    func testDoneBeforeItWasDueIsRecordedWithoutADueTime() throws {
        let appState = flight()
        try cruiseChecked(appState)
        appState.confirmFreda()
        let record = try XCTUnwrap(appState.currentFlight?.fredaChecks?.first)
        XCTAssertEqual(record.outcome, .done)
        XCTAssertNil(record.dueAt)
    }

    func testUndoTakesItBack() throws {
        let appState = flight()
        try cruiseChecked(appState)
        appState.evaluateFreda(now: Date().addingTimeInterval(FredaSchedule.interval + 1))
        let dueBefore = appState.freda
        appState.confirmFreda()
        appState.undoFredaConfirmation(try XCTUnwrap(appState.fredaConfirmation?.id))
        XCTAssertNil(appState.currentFlight?.fredaChecks, "no record left")
        XCTAssertEqual(appState.freda, dueBefore, "due again, as before the tap")
        XCTAssertNil(appState.fredaConfirmation)
    }

    func testUndoAfterLeavingCruiseLeavesItMissed() throws {
        let appState = flight()
        try cruiseChecked(appState)
        appState.evaluateFreda(now: Date().addingTimeInterval(FredaSchedule.interval + 1))
        appState.confirmFreda()
        let id = try XCTUnwrap(appState.fredaConfirmation?.id)
        appState.nextPhase()
        appState.undoFredaConfirmation(id)
        XCTAssertEqual(appState.currentFlight?.fredaChecks?.map(\.outcome), [.missed])
        XCTAssertFalse(appState.freda.isRunning)
    }

    func testLeavingCruiseWithItDueRecordsItMissed() throws {
        let appState = flight()
        try cruiseChecked(appState)
        appState.evaluateFreda(now: Date().addingTimeInterval(FredaSchedule.interval + 1))
        appState.nextPhase()
        XCTAssertEqual(appState.currentPhase, .descent)
        XCTAssertFalse(appState.freda.isRunning, "leaving cruise stops it")
        let record = try XCTUnwrap(appState.currentFlight?.fredaChecks?.first)
        XCTAssertEqual(record.outcome, .missed)
        XCTAssertNotNil(record.dueAt)
        XCTAssertNil(record.doneAt)
    }

    func testLeavingCruiseWithNothingDueRecordsNothing() throws {
        let appState = flight()
        try cruiseChecked(appState)
        appState.goToPhase(.approach)
        XCTAssertFalse(appState.freda.isRunning)
        XCTAssertNil(appState.currentFlight?.fredaChecks)
        appState.evaluateFreda(now: Date().addingTimeInterval(3_600))
        XCTAssertFalse(appState.fredaDue, "nothing outside cruise")
    }

    func testBackInCruiseItCountsAgainFromThen() throws {
        let appState = flight()
        try cruiseChecked(appState)
        appState.nextPhase()
        appState.previousPhase()
        XCTAssertEqual(appState.currentPhase, .cruise)
        let back = Date().addingTimeInterval(60)
        appState.evaluateFreda(now: back)
        XCTAssertEqual(appState.freda.anchor, back, "the cruise check is still done: FREDA runs from now")
    }

    func testEndingTheFlightWithItDueRecordsItMissed() throws {
        let appState = flight()
        try cruiseChecked(appState)
        appState.evaluateFreda(now: Date().addingTimeInterval(FredaSchedule.interval + 1))
        let id = try XCTUnwrap(appState.currentFlight?.id)
        appState.endFlight()
        let saved = try XCTUnwrap(appState.flights.first { $0.id == id })
        XCTAssertEqual(saved.fredaChecks?.map(\.outcome), [.missed])
        XCTAssertFalse(appState.freda.isRunning)
    }

    func testCircuitsHaveNoFreda() {
        let appState = flight(circuits: true)
        appState.currentPhase = .cruise   // not flown in circuits; even if it were shown
        appState.markLastItemComplete(learningMode: true)
        appState.evaluateFreda(now: Date().addingTimeInterval(3_600))
        XCTAssertFalse(appState.freda.isRunning)
        appState.confirmFreda()
        XCTAssertNil(appState.currentFlight?.fredaChecks)
    }

    // MARK: Across a relaunch (6.2)

    /// The app killed in cruise and launched again on the same device, the flight restored from its
    /// checkpoint.
    private func relaunch(_ appState: AppState, datastore: DataPersistenceManager,
                          defaults: UserDefaults) throws -> AppState {
        appState.flushPendingCheckpoint()
        let relaunched = makeTestAppState(datastore: datastore, defaults: defaults)
        XCTAssertTrue(relaunched.restoreActiveFlightState(), "the flight restored")
        addTeardownBlock { @MainActor in relaunched.cancelFlight() }
        return relaunched
    }

    /// Killed in cruise and launched again: FREDA counts on from the same anchor rather than from the
    /// restore, and one due stays due (and missed when cruise is left without it, as without the
    /// relaunch). Until 6.2 the checkpoint didn't keep it: the ten minutes started again at the restore,
    /// and a FREDA due went without a trace.
    func testARelaunchInCruiseKeepsTheCountAndAFredaDue() throws {
        let datastore = makeTestDatastore(), defaults = makeTestDefaults()
        let appState = flight(datastore: datastore, defaults: defaults)
        try cruiseChecked(appState)
        let anchor = try XCTUnwrap(appState.freda.anchor)

        let counting = try relaunch(appState, datastore: datastore, defaults: defaults)
        XCTAssertEqual(counting.freda.since, .cruiseCheck)
        XCTAssertEqual(try XCTUnwrap(counting.freda.anchor).timeIntervalSince(anchor), 0, accuracy: 1,
                       "counting from the cruise check, not from the restore")
        counting.evaluateFreda(now: anchor.addingTimeInterval(FredaSchedule.interval + 1))
        XCTAssertTrue(counting.fredaDue, "due ten minutes after the cruise check")

        let due = try relaunch(counting, datastore: datastore, defaults: defaults)
        XCTAssertTrue(due.fredaDue, "still due after a second relaunch")
        XCTAssertEqual(CockpitCheckSlot.slot(for: due).action, .confirmFreda)
        due.nextPhase()
        XCTAssertEqual(due.currentFlight?.fredaChecks?.map(\.outcome), [.missed], "left alone: missed")
    }

    /// A checkpoint written before 6.2 has no FREDA: it still restores, and FREDA counts from the restore,
    /// as it did. One written by a newer build, with a value this one can't read, restores too.
    func testACheckpointWithoutFredaOrWithANewerOneStillRestores() throws {
        let datastore = makeTestDatastore(), defaults = makeTestDefaults()
        let appState = flight(datastore: datastore, defaults: defaults)
        try cruiseChecked(appState)
        let flight = try XCTUnwrap(appState.currentFlight)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(ActiveFlightState(flight: flight, from: appState)))
                                 as? [String: Any])
        XCTAssertNotNil(json["freda"], "kept while it runs")

        json.removeValue(forKey: "freda")
        let older = try decoder.decode(ActiveFlightState.self, from: JSONSerialization.data(withJSONObject: json))
        let restored = makeTestAppState()
        older.restore(to: restored)
        addTeardownBlock { @MainActor in restored.cancelFlight() }
        XCTAssertFalse(restored.freda.isRunning)
        let later = Date().addingTimeInterval(60)
        restored.evaluateFreda(now: later)
        XCTAssertEqual(restored.freda.anchor, later, "an older checkpoint: FREDA counts from the restore")

        json["freda"] = ["anchor": "2027-01-15T08:00:00Z", "since": ["afterTurbulence": [:] as [String: Any]]]
        let newer = try decoder.decode(ActiveFlightState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(newer.freda?.since, .cruiseCheck, "a kind this build doesn't know")
        XCTAssertNotNil(newer.freda?.anchor)
    }

    // MARK: Where it shows

    func testTheSlotCountsThenAsks() throws {
        let appState = flight()
        try cruiseChecked(appState)
        let anchor = try XCTUnwrap(appState.freda.anchor)
        let counting = CockpitCheckSlot.slot(for: appState, now: anchor.addingTimeInterval(4 * 60 + 10))
        XCTAssertEqual(counting.title, .fredaCountsFrom(.cruiseCheck, anchor))
        XCTAssertEqual(counting.line, .fredaIn(minutes: 6))
        XCTAssertEqual(counting.tone, .idle)
        XCTAssertEqual(counting.action, .showChecklist, "counting, the checklist: NEXT and FREDA side by side")

        appState.evaluateFreda(now: anchor.addingTimeInterval(FredaSchedule.interval))
        let due = CockpitCheckSlot.slot(for: appState)
        XCTAssertEqual(due.title, .freda)
        XCTAssertEqual(due.line, .fredaFlow(waypoint: nil))
        XCTAssertEqual(due.tone, .due)
        XCTAssertEqual(due.action, .confirmFreda)

        appState.confirmFreda()
        XCTAssertEqual(CockpitCheckSlot.slot(for: appState).title,
                       .fredaCountsFrom(.freda, try XCTUnwrap(appState.freda.anchor)))
    }

    func testTheCruiseCheckStillOpenComesFirst() {
        let appState = flight()
        appState.currentPhase = .cruise
        XCTAssertNil(CockpitCheckSlot.freda(in: appState))
        XCTAssertEqual(CockpitCheckSlot.slot(for: appState).action, .showChecklist)
    }

    // MARK: On the flight record

    func testAFlightWithoutFredaStillDecodes() throws {
        let flight = Flight(airplane: "wt9-dynamic")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(flight)) as? [String: Any])
        XCTAssertNil(json["fredaChecks"], "nothing written when there is none")
        json.removeValue(forKey: "fredaChecks")
        let decoded = try JSONDecoder().decode(Flight.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.fredaChecks)
    }

    func testTheRecordsRoundTrip() throws {
        var flight = Flight(airplane: "wt9-dynamic")
        flight.fredaChecks = [
            .done(at: minutes(12), due: FredaSchedule.Due(since: minutes(10), waypoint: "LSGC")),
            .done(at: minutes(14), due: nil),
            .missed(FredaSchedule.Due(since: minutes(24), waypoint: nil)),
        ]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Flight.self, from: encoder.encode(flight))
        XCTAssertEqual(decoded.fredaChecks, flight.fredaChecks)
    }

    func testARecordFromANewerBuildReadsAsMissed() throws {
        let json = #"[{"outcome":"skippedInTurbulence","dueAt":800000600}, {"id":"8E5B0D8A-6C35-4E0B-9F0E-1D2C3B4A5968","outcome":"done","doneAt":800000700}]"#
        let decoded = try JSONDecoder().decode([FredaCheck].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.map(\.outcome), [.missed, .done])
        XCTAssertEqual(decoded[0].dueAt, Date(timeIntervalSinceReferenceDate: 800_000_600))
    }

    func testMergeKeepsTheLongerList() {
        var recorded = Flight(airplane: "wt9-dynamic", modifiedAt: t0)
        recorded.fredaChecks = [.done(at: minutes(12), due: nil), .done(at: minutes(22), due: nil)]
        // The same flight renamed on a device whose build dropped the field: newer, and without it.
        var stripped = recorded
        stripped.fredaChecks = nil
        stripped.name = "Renamed"
        stripped.modifiedAt = minutes(60)
        let merged = Flight.merge(recorded, stripped)
        XCTAssertEqual(merged.name, "Renamed")
        XCTAssertEqual(merged.fredaChecks, recorded.fredaChecks)
        XCTAssertEqual(Flight.merge(stripped, recorded).fredaChecks, recorded.fredaChecks)
    }

    func testTheRecordsAreBounded() {
        var flight = Flight(airplane: "wt9-dynamic")
        flight.fredaChecks = (0..<(FredaCheck.maxPerFlight + 50)).map { .done(at: minutes(Double($0)), due: nil) }
        XCTAssertEqual(flight.withPlausibleValues().fredaChecks?.count, FredaCheck.maxPerFlight)
    }

    func testTheRecordsSurviveACrash() throws {
        let source = flight()
        try cruiseChecked(source)
        source.confirmFreda()
        let snapshot = ActiveFlightState(flight: try XCTUnwrap(source.currentFlight), from: source)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = makeTestAppState()
        try decoder.decode(ActiveFlightState.self, from: encoder.encode(snapshot)).restore(to: restored)
        // ISO 8601 keeps whole seconds: the records compared by what they are, the time to the second.
        let before = try XCTUnwrap(source.currentFlight?.fredaChecks)
        let after = try XCTUnwrap(restored.currentFlight?.fredaChecks)
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.outcome), [.done])
        XCTAssertEqual(try XCTUnwrap(after.first?.doneAt).timeIntervalSince1970,
                       try XCTUnwrap(before.first?.doneAt).timeIntervalSince1970, accuracy: 1)
        restored.isFlightActive = false
    }
}
