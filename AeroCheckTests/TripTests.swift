import XCTest
@testable import AeroCheck

/// Multi-leg trips (v5.x).
///
/// Two things carry the design and are worth most of this suite: which tasks are shared, and when a
/// shared tick stops covering the next leg.
final class TripTests: XCTestCase {

    private func utc(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    // MARK: - Scope

    func testTheThingsYouDoOnceAreSharedAndTheRestAreNot() {
        for key in [ThreadTaskKey.aircraftReserved, .weatherBriefed, .dabsChecked, .gaforChecked,
                    .notamChecked, .debriefWritten] {
            XCTAssertEqual(key.scope, .trip, "\(key) should be answered once for the trip")
        }
        for key in [ThreadTaskKey.routePlanned, .fuelPlanned, .flightPlanFiled, .pprObtained,
                    .customsNotified, .navLogReady, .flightPlanClosed, .feesPaid, .logbookEntry] {
            XCTAssertEqual(key.scope, .leg, "\(key) differs leg by leg")
        }
    }

    func testMassAndBalanceIsPerLegBecauseTheLoadChangesAtEveryStop() {
        // It looks like trip preparation and it is not. A fuel stop exists precisely to change the
        // aircraft's weight, so a shared tick would imply an envelope still holds after uplifting
        // eighty litres — on exactly the flights where it matters most.
        XCTAssertEqual(ThreadTaskKey.massAndBalance.scope, .leg)
    }

    func testEveryTaskKeyHasAScope() {
        // A key added later without a scope would silently take whatever `default` gives it.
        for key in ThreadTaskKey.allCases {
            XCTAssertTrue([.trip, .leg].contains(key.scope), "\(key)")
        }
    }

    func testOnlyBriefingsExpire() {
        // A booking does not go stale; a briefing does. Nothing leg-scoped can, because a leg is
        // asked its own questions anyway.
        XCTAssertTrue(ThreadTaskKey.notamChecked.goesStale)
        XCTAssertTrue(ThreadTaskKey.weatherBriefed.goesStale)
        XCTAssertFalse(ThreadTaskKey.aircraftReserved.goesStale)
        XCTAssertFalse(ThreadTaskKey.debriefWritten.goesStale)
        for key in ThreadTaskKey.allCases where key.scope == .leg {
            XCTAssertFalse(key.goesStale, "\(key) is per-leg and cannot go stale")
        }
    }

    // MARK: - Freshness

    func testASameDayFuelStopDoesNotAskTwice() {
        // The busywork this feature exists to remove.
        XCTAssertFalse(TripTaskFreshness.isStale(tickedAt: utc("2026-09-12T08:00:00Z"),
                                                 forLegDeparting: utc("2026-09-12T12:00:00Z")))
    }

    func testAnOvernightTourAsksAgain() {
        // Yesterday's NOTAM briefing does not cover today.
        XCTAssertTrue(TripTaskFreshness.isStale(tickedAt: utc("2026-09-12T18:00:00Z"),
                                                forLegDeparting: utc("2026-09-13T09:00:00Z")))
    }

    func testSixHoursIsTheLimitWithinOneDay() {
        // The same-day test alone would let an 06:00 tick cover a 23:00 leg on a long summer day.
        XCTAssertFalse(TripTaskFreshness.isStale(tickedAt: utc("2026-09-12T06:00:00Z"),
                                                 forLegDeparting: utc("2026-09-12T11:59:00Z")))
        XCTAssertTrue(TripTaskFreshness.isStale(tickedAt: utc("2026-09-12T06:00:00Z"),
                                                forLegDeparting: utc("2026-09-12T23:00:00Z")))
    }

    func testTenMinutesAcrossMidnightIsStale() {
        // The six-hour test alone would let a 23:50 tick cover a 00:10 departure. Both halves of the
        // rule are needed; each catches what the other misses.
        XCTAssertTrue(TripTaskFreshness.isStale(tickedAt: utc("2026-09-12T23:50:00Z"),
                                                forLegDeparting: utc("2026-09-13T00:10:00Z")))
    }

    func testFreshnessIsMeasuredInUTCNotTheDeviceTimeZone() {
        // Aviation days are UTC days. A local calendar would make the same trip stale or fresh
        // depending on which side of midnight the pilot's time zone happened to fall.
        XCTAssertEqual(TripTaskFreshness.calendar.timeZone.secondsFromGMT(), 0)
    }

    func testALegWithNoDepartureIsNeverStale() {
        // Inventing a departure to measure against would manufacture a staleness nobody can act on.
        XCTAssertFalse(TripTaskFreshness.isStale(tickedAt: utc("2026-01-01T00:00:00Z"),
                                                 forLegDeparting: nil))
        XCTAssertFalse(TripTaskFreshness.isStale(tickedAt: nil,
                                                 forLegDeparting: utc("2026-09-12T09:00:00Z")))
    }

    // MARK: - What a leg sees

    private func trip(ticked: Date) -> Trip {
        var notam = ThreadTask(key: .notamChecked, kind: .check)
        notam.state = .done
        notam.completedAt = ticked
        var booking = ThreadTask(key: .aircraftReserved, kind: .check)
        booking.state = .done
        booking.completedAt = ticked
        return Trip(legIds: [UUID(), UUID()], sharedTasks: [notam, booking])
    }

    func testAStaleTickReadsAsPendingButKeepsItsTimestamp() {
        let t = trip(ticked: utc("2026-09-12T08:00:00Z"))
        let seen = t.tasks(forLegDeparting: utc("2026-09-13T09:00:00Z"))

        let notam = seen.first { $0.key == .notamChecked }
        XCTAssertEqual(notam?.state, .pending, "an expired briefing must be asked again")
        // Kept so the row can say "checked 08:12 — re-check for this leg" rather than looking like
        // something nobody has touched.
        XCTAssertNotNil(notam?.completedAt)
    }

    func testABookingSurvivesTheNight() {
        let t = trip(ticked: utc("2026-09-12T08:00:00Z"))
        let seen = t.tasks(forLegDeparting: utc("2026-09-13T09:00:00Z"))
        XCTAssertEqual(seen.first { $0.key == .aircraftReserved }?.state, .done,
                       "you booked the aeroplane; the night does not un-book it")
    }

    func testNothingExpiresWithinTheSameDayWindow() {
        let t = trip(ticked: utc("2026-09-12T08:00:00Z"))
        let seen = t.tasks(forLegDeparting: utc("2026-09-12T11:00:00Z"))
        XCTAssertTrue(seen.allSatisfy { $0.state == .done })
    }

    // MARK: - Order

    func testLegOrderLivesOnTheTripAndIsOneBasedForDisplay() {
        let a = UUID(), b = UUID()
        let t = Trip(legIds: [a, b])
        XCTAssertEqual(t.legNumber(of: a), 1)
        XCTAssertEqual(t.legNumber(of: b), 2)
        XCTAssertNil(t.legNumber(of: UUID()), "a thread outside the trip has no leg number")
    }

    func testATripOfOneLegIsJustAFlight() {
        XCTAssertTrue(Trip(legIds: [UUID()]).isDegenerate)
        XCTAssertTrue(Trip(legIds: []).isDegenerate)
        XCTAssertFalse(Trip(legIds: [UUID(), UUID()]).isDegenerate)
    }

    // MARK: - Forming and dissolving

    @MainActor
    private func plan(_ from: String, _ to: String) -> FlightPlan {
        var plan = FlightPlan(name: "\(from) → \(to)")
        plan.waypoints = [
            FlightPlanWaypoint(name: from, coordinate: .init(latitude: 47.4247, longitude: 7.1869)),
            FlightPlanWaypoint(name: to, coordinate: .init(latitude: 46.7619, longitude: 6.6141)),
        ]
        return plan
    }

    @MainActor
    func testFormingATripLiftsSharedPreparationOffTheFirstLeg() {
        // This is the "add a leg later" path: a standalone flight already has its booking and its
        // weather ticked, and promoting it to a trip must carry that up rather than re-ask.
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZQ", "LFSB"))
        let b = m.createThread(from: plan("LFSB", "LSGY"))
        defer { m.deleteThread(threadId: a.id); m.deleteThread(threadId: b.id) }

        guard let booking = a.tasks.first(where: { $0.key == .aircraftReserved }) else {
            return XCTFail("no booking task")
        }
        m.setTaskState(.done, taskId: booking.id, threadId: a.id)

        let trip = m.formTrip(from: [a.id, b.id])
        XCTAssertNotNil(trip)
        XCTAssertEqual(m.trip(forThreadId: b.id)?.id, trip?.id, "both legs belong to the trip")

        let shared = m.trip(withId: trip!.id)?.sharedTasks ?? []
        XCTAssertTrue(shared.contains { $0.key == .aircraftReserved && $0.state == .done },
                      "the tick made before the trip existed must survive the promotion")

        for leg in [a.id, b.id] {
            let legTasks = m.thread(withId: leg)?.tasks ?? []
            XCTAssertFalse(legTasks.contains { $0.key.scope == .trip },
                           "a leg must not keep its own copy of a shared task")
        }
    }

    @MainActor
    func testATripNeedsTwoLegs() {
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZQ", "LSGY"))
        defer { m.deleteThread(threadId: a.id) }
        XCTAssertNil(m.formTrip(from: [a.id]), "one leg is a flight, not a trip")
        XCTAssertNil(m.thread(withId: a.id)?.tripId)
    }

    @MainActor
    func testRemovingALegDissolvesTheTripAndGivesThePreparationBack() {
        // A trip of one leg is just a flight. Without handing the shared tasks back, deleting one leg
        // would take the survivor's whole preparation with it.
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZQ", "LFSB"))
        let b = m.createThread(from: plan("LFSB", "LSGY"))
        defer { m.deleteThread(threadId: b.id) }
        let trip = m.formTrip(from: [a.id, b.id])!

        m.removeLeg(threadId: a.id)

        XCTAssertNil(m.trip(withId: trip.id), "a one-leg trip should not survive")
        let survivor = m.thread(withId: b.id)
        XCTAssertNil(survivor?.tripId, "the survivor is a standalone flight again")
        XCTAssertTrue(survivor?.tasks.contains { $0.key == .aircraftReserved } ?? false,
                      "its shared preparation must come back with it")
    }

    @MainActor
    func testTickingASharedTaskIsSeenFromEveryLeg() {
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZQ", "LFSB"))
        let b = m.createThread(from: plan("LFSB", "LSGY"))
        defer { m.deleteThread(threadId: a.id); m.deleteThread(threadId: b.id) }
        let trip = m.formTrip(from: [a.id, b.id])!

        guard let notam = trip.sharedTasks.first(where: { $0.key == .notamChecked }) else {
            return XCTFail("no NOTAM task")
        }
        m.setSharedTaskState(.done, taskId: notam.id, tripId: trip.id)

        // Reached from leg B, though it was ticked while looking at the trip.
        let fromB = m.trip(forThreadId: b.id)?.sharedTasks.first { $0.key == .notamChecked }
        XCTAssertEqual(fromB?.state, .done)
        XCTAssertNotNil(fromB?.completedAt, "the timestamp is what later legs measure staleness against")
    }

    @MainActor
    func testALegDoesNotGenerateTripScopedTasks() {
        // Otherwise "aircraft reserved" would appear on every leg and have to be ticked on each —
        // the busywork trips exist to remove.
        var context = ThreadTaskEngine.Context(profile: .full, homeCountry: "CH")
        context.hasRoute = true
        context.isLeg = true
        let tasks = ThreadTaskEngine.generate(context: context)

        XCTAssertFalse(tasks.contains { $0.key.scope == .trip }, "got \(tasks.map(\.key))")
        XCTAssertTrue(tasks.contains { $0.key == .flightPlanFiled }, "leg tasks still appear")
        XCTAssertTrue(tasks.contains { $0.key == .massAndBalance }, "W&B is per leg")
    }

    // MARK: - Migration safety

    func testAThreadPersistedBeforeTripsStillDecodes() throws {
        // `tripId` is the only trip field on a thread, and it is optional, so JSON written before
        // this release must still decode. A non-optional field with a default would not fail
        // loudly here — it would silently lose every saved flight.
        let json = """
        {"id":"\(UUID().uuidString)","profile":"full","state":"planned",
         "routeLabel":"LSZQ → LSGY","tasks":[],
         "createdAt":768000000,"updatedAt":768000000}
        """.data(using: .utf8)!
        let thread = try JSONDecoder().decode(FlightThread.self, from: json)
        XCTAssertNil(thread.tripId)
        XCTAssertEqual(thread.routeLabel, "LSZQ → LSGY")
    }
}

// MARK: - Cumulative review regressions (v5.0.1)

/// The defects that only appear when separately reasonable commits meet.
extension TripTests {

    private func utcDate(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    /// F12. `createTrip` gives ONLY the first leg a departure, so before the trip-level fallback
    /// every later leg answered "not stale" and yesterday's briefing showed a green tick on today's
    /// flight. The rule was inert on exactly the legs it was written for.
    func testAnUndatedLegFallsBackToTheTripsOwnDate() {
        var trip = Trip(legIds: [UUID(), UUID()])
        trip.scheduledStart = utcDate("2026-09-12T08:00:00Z")
        var task = ThreadTask(key: .notamChecked, kind: .check)
        task.state = .done
        task.completedAt = utcDate("2026-09-11T18:00:00Z")   // the day BEFORE the trip
        trip.sharedTasks = [task]

        let seen = trip.tasks(forLegDeparting: nil)
        XCTAssertEqual(seen.first?.state, .pending,
                       "an undated leg must still measure against the trip's own date")
        XCTAssertNotNil(seen.first?.completedAt,
                        "the stamp is kept so the row can say 're-check' rather than look untouched")
    }

    func testAnUndatedLegOnAFreshlyTickedTripIsNotStale() {
        var trip = Trip(legIds: [UUID(), UUID()])
        trip.scheduledStart = utcDate("2026-09-12T08:00:00Z")
        var task = ThreadTask(key: .notamChecked, kind: .check)
        task.state = .done
        task.completedAt = utcDate("2026-09-12T06:00:00Z")   // same UTC day, inside the window
        trip.sharedTasks = [task]

        XCTAssertEqual(trip.tasks(forLegDeparting: nil).first?.state, .done)
    }

    func testATripWithNoDateAtAllFallsBackToWhenItWasCreated() {
        // `freshnessReference` degrades to `createdAt`, which is still a real date the rule can use.
        var trip = Trip(legIds: [UUID(), UUID()])
        trip.createdAt = utcDate("2026-09-12T08:00:00Z")
        var task = ThreadTask(key: .weatherBriefed, kind: .check)
        task.state = .done
        task.completedAt = utcDate("2026-09-10T08:00:00Z")
        trip.sharedTasks = [task]

        XCTAssertEqual(trip.tasks(forLegDeparting: nil).first?.state, .pending)
    }

    /// F13. A stale row renders as pending, so ticking it re-stamped `completedAt` to now — which
    /// the rule then measured against the SAME leg departure and called stale again. The row was
    /// untickable, forever.
    func testATickAcknowledgedForALegCoversItEvenWhenTheClockSaysStale() {
        let legA = UUID(), legB = UUID()
        var trip = Trip(legIds: [legA, legB])
        var task = ThreadTask(key: .notamChecked, kind: .check)
        task.state = .done
        // Ticked on Saturday evening for a leg departing Sunday: a different UTC day, so the rule
        // calls it stale however recently it was stamped.
        task.completedAt = utcDate("2026-09-12T20:00:00Z")
        task.acknowledgedLegIds = [legB]
        trip.sharedTasks = [task]

        let departure = utcDate("2026-09-13T10:00:00Z")
        XCTAssertEqual(trip.tasks(forLegDeparting: departure, legId: legB).first?.state, .done,
                       "a tick made from this leg covers this leg, whatever the clock says")
        XCTAssertEqual(trip.tasks(forLegDeparting: departure, legId: legA).first?.state, .pending,
                       "and only that leg — the others still go stale on their own terms")
    }

    /// The manager is what records the acknowledgement, from whichever leg the pilot ticked.
    @MainActor
    func testTickingFromALegRecordsThatLeg() {
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZQ", "LFSB"))
        let b = m.createThread(from: plan("LFSB", "LSGY"))
        defer { m.deleteThread(threadId: a.id); m.deleteThread(threadId: b.id) }
        let trip = m.formTrip(from: [a.id, b.id])!
        guard let notam = trip.sharedTasks.first(where: { $0.key == .notamChecked }) else {
            return XCTFail("no NOTAM task")
        }
        m.setSharedTaskState(.done, taskId: notam.id, tripId: trip.id, fromLegId: b.id)

        let stored = m.trip(withId: trip.id)?.sharedTasks.first { $0.key == .notamChecked }
        XCTAssertEqual(stored?.acknowledgedLegIds, [b.id])
    }

    @MainActor
    func testUntickingRetractsTheAcknowledgementEverywhere() {
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZQ", "LFSB"))
        let b = m.createThread(from: plan("LFSB", "LSGY"))
        defer { m.deleteThread(threadId: a.id); m.deleteThread(threadId: b.id) }
        let trip = m.formTrip(from: [a.id, b.id])!
        guard let notam = trip.sharedTasks.first(where: { $0.key == .notamChecked }) else {
            return XCTFail("no NOTAM task")
        }
        m.setSharedTaskState(.done, taskId: notam.id, tripId: trip.id, fromLegId: b.id)
        m.setSharedTaskState(.pending, taskId: notam.id, tripId: trip.id, fromLegId: b.id)

        let task = m.trip(withId: trip.id)?.sharedTasks.first { $0.key == .notamChecked }
        XCTAssertEqual(task?.state, .pending)
        XCTAssertTrue(task?.acknowledgedLegIds.isEmpty ?? false,
                      "an un-tick must not leave the row green on the leg it was ticked from")
    }

    /// F14. The app's only delete affordance called `deleteThread`, which knows nothing about trips.
    @MainActor
    func testDeletingALegNeverLeavesADanglingIdInTheTrip() {
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZQ", "LFSB"))
        let b = m.createThread(from: plan("LFSB", "LSGY"))
        let c = m.createThread(from: plan("LSGY", "LSZQ"))
        defer { m.deleteThread(threadId: b.id); m.deleteThread(threadId: c.id) }
        let trip = m.formTrip(from: [a.id, b.id, c.id])!

        // The raw path, as any caller that is not `removeLeg` would take it.
        m.deleteThread(threadId: a.id)

        let after = m.trip(withId: trip.id)
        XCTAssertEqual(after?.legIds.count, 2, "a deleted leg must not stay in legIds")
        XCTAssertFalse(after?.legIds.contains(a.id) ?? true)
        XCTAssertEqual(after?.legNumber(of: c.id), 2, "the survivors renumber")
    }

    /// F15. `sharedTasks` was captured from leg 1 alone, so a row leg 1 never needed could not be
    /// produced by any later leg either — it existed nowhere.
    @MainActor
    func testFormingATripCarriesUpEveryLegsTicksNotJustTheFirsts() {
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZQ", "LFSB"))
        let b = m.createThread(from: plan("LFSB", "LSGY"))
        defer { m.deleteThread(threadId: a.id); m.deleteThread(threadId: b.id) }

        // Tick a trip-scoped row on the SECOND leg, before the trip exists.
        guard let notamOnB = m.thread(withId: b.id)?.tasks.first(where: { $0.key == .notamChecked })
        else { return XCTFail("no NOTAM task on leg B") }
        m.setTaskState(.done, taskId: notamOnB.id, threadId: b.id)

        let trip = m.formTrip(from: [a.id, b.id])!
        let promoted = trip.sharedTasks.first { $0.key == .notamChecked }
        XCTAssertEqual(promoted?.state, .done,
                       "a tick made before the trip existed is carried up from ANY leg, not only the first")
    }

    /// F-formTrip. The guard was a bare count, so a repeated or unknown id still landed in legIds.
    @MainActor
    func testFormTripRefusesDuplicateAndUnknownIds() {
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZQ", "LFSB"))
        defer { m.deleteThread(threadId: a.id) }

        XCTAssertNil(m.formTrip(from: [a.id, a.id]), "the same flight twice is not a trip")
        XCTAssertNil(m.formTrip(from: [a.id, UUID()]), "an id that resolves to nothing is not a leg")
    }

    // MARK: - Legs decided after a landing (v5.1)

    @MainActor
    private func fly(_ m: FlightThreadManager, _ id: UUID) {
        m.attachFlight(UUID(), toThreadId: id)
        m.beginCloseOut(threadId: id, flightId: nil)
    }

    @MainActor
    func testALegPlannedAfterALandingJoinsTheFlightThatLanded() {
        // `formTrip` refuses a flight that has flown, on purpose. A continuation is exactly that:
        // the next leg of a journey, planned at the aerodrome the weather chose.
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZS", "LSZE"))
        fly(m, a.id)
        let b = m.createThread(from: plan("LSZE", "LSZQ"))
        defer { m.deleteThread(threadId: a.id); m.deleteThread(threadId: b.id) }

        let trip = m.insertLeg(b.id, after: a.id)
        XCTAssertEqual(trip?.legIds, [a.id, b.id])
        XCTAssertEqual(m.thread(withId: a.id)?.state, .closeOut, "joining a trip does not reopen a flight")
        XCTAssertEqual(m.trip(forThreadId: b.id)?.id, trip?.id)
    }

    @MainActor
    func testAfterADiversionTheBriefingsComeBackUnticked() {
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZS", "LSZQ"))
        for key in [ThreadTaskKey.weatherBriefed, .notamChecked, .aircraftReserved] {
            if let task = m.thread(withId: a.id)?.tasks.first(where: { $0.key == key }) {
                m.setTaskState(.done, taskId: task.id, threadId: a.id)
            }
        }
        fly(m, a.id)
        let b = m.createThread(from: plan("LSZE", "LSZQ"))
        defer { m.deleteThread(threadId: a.id); m.deleteThread(threadId: b.id) }

        let trip = m.insertLeg(b.id, after: a.id, rebrief: true)!
        let weather = trip.sharedTasks.first { $0.key == .weatherBriefed }
        XCTAssertEqual(weather?.state, .pending, "a diversion is evidence the weather changed")
        XCTAssertNotNil(weather?.completedAt, "kept, so the row reads as a re-check, not as never done")
        XCTAssertEqual(trip.sharedTasks.first { $0.key == .notamChecked }?.state, .pending)
        XCTAssertEqual(trip.sharedTasks.first { $0.key == .aircraftReserved }?.state, .done,
                       "the booking does not go stale")
    }

    @MainActor
    func testANewLegGoesRightAfterTheOneItFollows() {
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZQ", "LSZE"))
        let c = m.createThread(from: plan("LSPV", "LSZS"))
        let b = m.createThread(from: plan("LSZE", "LSPV"))
        defer { [a, b, c].forEach { m.deleteThread(threadId: $0.id) } }
        _ = m.formTrip(from: [a.id, c.id])

        let trip = m.insertLeg(b.id, after: a.id)
        XCTAssertEqual(trip?.legIds, [a.id, b.id, c.id])
        XCTAssertEqual(m.leg(after: a.id)?.id, b.id)
    }

    @MainActor
    func testAfterLandingAtAStopTheNextLegIsTodaysFlight() {
        // Only the first leg has a firm date. Without this rule, START FLIGHT after landing at the
        // stop started an unplanned flight: the leg with a route and a nav log waiting flew without.
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZS", "LSZE"))
        let b = m.createThread(from: plan("LSZE", "LSZQ"))
        defer { m.deleteThread(threadId: a.id); m.deleteThread(threadId: b.id) }
        _ = m.formTrip(from: [a.id, b.id])

        XCTAssertNil(m.nextTripLeg(), "nothing has landed yet")
        fly(m, a.id)
        XCTAssertEqual(m.nextTripLeg()?.id, b.id)
        XCTAssertEqual(m.startableFlightToday?.id, b.id)
    }

    @MainActor
    func testAnEstimatedDepartureIsNotAFirmDate() {
        let m = makeTestThreadManager()
        var later = plan("LSZE", "LSZQ")
        later.plannedDepartureTime = Date().addingTimeInterval(3600)
        later.departureIsEstimate = true
        let b = m.createThread(from: later)
        defer { m.deleteThread(threadId: b.id) }
        XCTAssertNil(m.thread(withId: b.id)?.scheduledDeparture,
                     "an estimate prints ETOs; it must not arm a reminder or claim a day")
    }

    // MARK: - Adding and removing a stop (v5.1)

    @MainActor
    func testAddingAStopMakesTwoLegsAndJoiningTakesItBack() {
        let datastore = makeTestDatastore()
        let plans = makeTestPlanManager(datastore: datastore)
        let m = makeTestThreadManager(datastore: datastore)
        plans.nextLegPlanId = { m.nextLegPlanId(after: $0) }

        var route = FlightPlan(name: "Return", plannedDepartureTime: Date().addingTimeInterval(86_400),
                               fuelFlow: 20, fuelOnBoard: 80)
        route.waypoints = [("LSZS", 7.0), ("W1", 7.3), ("W2", 7.6), ("LSZQ", 7.9)].map {
            FlightPlanWaypoint(name: $0.0, coordinate: .init(latitude: 47.0, longitude: $0.1),
                               altitude: 5000, plannedGroundSpeed: 100)
        }
        route.calculateRouteData()
        plans.add(route)
        let thread = m.createThread(from: route)
        var created: [UUID] = [route.id]
        var createdThreads: [UUID] = [thread.id]
        // Only what this test made, never everything the managers hold. The datastore goes with the
        // test; deleting the threads also cancels any reminder `createThread` armed in the host app.
        defer {
            for id in created { if let p = plans.flightPlans.first(where: { $0.id == id }) { plans.deleteFlightPlan(p) } }
            createdThreads.forEach { m.deleteThread(threadId: $0) }
        }

        let field = TripPlanner.Aerodrome(ident: "LSZE", name: "Bad Ragaz", latitude: 47.04, longitude: 7.45,
                                          elevationFeet: 1617, frequency: nil, isPPR: false)
        guard let candidate = TripPlanner.stopCandidates(along: route.waypoints, aerodromes: [field]).first,
              let leg = FlightCreator.addStop(to: thread.id, at: candidate, stopover: Stopover(),
                                              plans: plans, threads: m)
        else { return XCTFail("no stop added") }
        if let id = leg.flightPlanId { created.append(id) }
        createdThreads.append(leg.id)

        XCTAssertEqual(m.trip(forThreadId: thread.id)?.legIds, [thread.id, leg.id])
        XCTAssertEqual(m.thread(withId: thread.id)?.routeLabel, "LSZS → LSZE")
        XCTAssertEqual(leg.routeLabel, "LSZE → LSZQ")
        XCTAssertNil(leg.scheduledDeparture, "the second leg's departure is an estimate")
        let second = plans.flightPlans.first { $0.id == leg.flightPlanId }
        XCTAssertEqual(second?.departureIsEstimate, true)
        XCTAssertNotNil(second?.plannedDepartureTime)
        XCTAssertEqual(m.startableFlightToday?.id, nil, "tomorrow's trip is not today's flight")

        // Moving leg 1 moves leg 2's estimate.
        var first = plans.flightPlans.first { $0.id == route.id }!
        let before = second?.plannedDepartureTime
        first.plannedDepartureTime = first.plannedDepartureTime?.addingTimeInterval(1800)
        first.calculateRouteData()
        plans.updateFlightPlan(first)
        XCTAssertEqual(plans.flightPlans.first { $0.id == leg.flightPlanId }?.plannedDepartureTime,
                       before?.addingTimeInterval(1800))

        XCTAssertTrue(FlightCreator.joinWithNextLeg(thread.id, plans: plans, threads: m))
        XCTAssertNil(m.trip(forThreadId: thread.id), "one leg left is just a flight again")
        XCTAssertNil(m.thread(withId: leg.id))
        XCTAssertEqual(plans.flightPlans.first { $0.id == route.id }?.waypoints.map(\.name),
                       ["LSZS", "W1", "LSZE", "W2", "LSZQ"],
                       "the stop stays on the route as a waypoint; only the landing is gone")
        XCTAssertEqual(m.thread(withId: thread.id)?.routeLabel, "LSZS → LSZQ")
    }

    // MARK: - Continuing after a diversion (v5.1)

    @MainActor
    func testLandingElsewhereRenamesTheFlightAndOffersTheRest() {
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZS", "LSZQ"))
        defer { m.deleteThread(threadId: a.id) }
        m.recordLanding(threadId: a.id, plannedIdent: "LSZQ", landedIdent: "LSZE", landedName: "Bad Ragaz")
        let after = m.thread(withId: a.id)
        XCTAssertEqual(after?.routeLabel, "LSZS → LSZE", "the flight as flown, for the banner and the trip label")
        XCTAssertEqual(after?.landedElsewhere?.plannedIdent, "LSZQ")
        m.dismissContinuation(threadId: a.id)
        XCTAssertEqual(m.thread(withId: a.id)?.landedElsewhere?.offerDismissed, true)
    }

    @MainActor
    func testContinuingMakesTheNextLegFromTheDiversionField() {
        let datastore = makeTestDatastore()
        let plans = makeTestPlanManager(datastore: datastore)
        let m = makeTestThreadManager(datastore: datastore)
        let airports = AirportDataService()

        var flown = FlightPlan(name: "Return")
        flown.waypoints = [("LSZS", 7.0), ("W1", 7.3), ("W2", 7.6), ("W3", 7.9), ("LSZQ", 8.2)].map {
            FlightPlanWaypoint(name: $0.0, coordinate: .init(latitude: 47.0, longitude: $0.1),
                               altitude: 5000, plannedGroundSpeed: 100)
        }
        flown.diversion = Diversion(ident: "LSZE", name: "Bad Ragaz", latitude: 46.94, longitude: 7.62,
                                    elevationFeet: 1617, frequency: nil, startedAt: Date(), leftRouteAt: 2,
                                    landedAt: Date())
        flown.calculateRouteData()
        plans.add(flown)
        let a = m.createThread(from: flown)
        fly(m, a.id)
        m.recordLanding(threadId: a.id, plannedIdent: "LSZQ", landedIdent: "LSZE", landedName: "Bad Ragaz")
        var created = [flown.id]
        var createdThreads = [a.id]
        defer {
            for id in created { if let p = plans.flightPlans.first(where: { $0.id == id }) { plans.deleteFlightPlan(p) } }
            createdThreads.forEach { m.deleteThread(threadId: $0) }
        }

        guard let leg = FlightCreator.continueAfterDiversion(from: a.id, plans: plans, threads: m, airports: airports)
        else { return XCTFail("no continuation") }
        if let id = leg.flightPlanId { created.append(id) }
        createdThreads.append(leg.id)

        XCTAssertEqual(leg.routeLabel, "LSZE → LSZQ")
        XCTAssertEqual(plans.flightPlans.first { $0.id == leg.flightPlanId }?.waypoints.map(\.name),
                       ["LSZE", "W3", "LSZQ"], "rejoins past the field")
        XCTAssertEqual(m.trip(forThreadId: a.id)?.legIds, [a.id, leg.id])
        XCTAssertEqual(m.startableFlightToday?.id, leg.id, "the continuation is what START FLIGHT is about now")
        XCTAssertNil(FlightCreator.continueAfterDiversion(from: a.id, plans: plans, threads: m, airports: airports),
                     "one continuation per landing")
    }

    @MainActor
    func testADiversionOnTheFirstLegGoesBackToTheStopBeforeTheNextLeg() {
        // Found on the simulator: leg 1 of LSZQ → LSMM → LSZS landed at LSPG. Home then offered
        // LSMM → LSZS as today's flight to an aircraft standing at LSPG, and the continuation was
        // hidden because a next leg existed.
        let datastore = makeTestDatastore()
        let plans = makeTestPlanManager(datastore: datastore)
        let m = makeTestThreadManager(datastore: datastore)

        var first = FlightPlan(name: "Trip")
        first.waypoints = [("LSZQ", 7.0), ("W1", 7.3), ("W2", 7.6), ("LSMM", 7.9)].map {
            FlightPlanWaypoint(name: $0.0, coordinate: .init(latitude: 47.0, longitude: $0.1), altitude: 5000)
        }
        first.diversion = Diversion(ident: "LSPG", name: "Kägiswil", latitude: 47.05, longitude: 7.45,
                                    elevationFeet: 1525, frequency: nil, startedAt: Date(), leftRouteAt: 2)
        first.calculateRouteData()
        plans.add(first)
        let a = m.createThread(from: first)
        let b = m.createThread(from: plan("LSMM", "LSZS"))
        _ = m.formTrip(from: [a.id, b.id])
        fly(m, a.id)
        m.recordLanding(threadId: a.id, plannedIdent: "LSMM", landedIdent: "LSPG", landedName: "Kägiswil")
        var created = [first.id]
        var createdThreads = [a.id, b.id]
        defer {
            for id in created { if let p = plans.flightPlans.first(where: { $0.id == id }) { plans.deleteFlightPlan(p) } }
            createdThreads.forEach { m.deleteThread(threadId: $0) }
        }

        XCTAssertNil(m.nextTripLeg(), "LSMM → LSZS cannot start from LSPG")

        guard let leg = FlightCreator.continueAfterDiversion(from: a.id, plans: plans, threads: m,
                                                             airports: AirportDataService())
        else { return XCTFail("no continuation while a later leg exists") }
        if let id = leg.flightPlanId { created.append(id) }
        createdThreads.append(leg.id)
        XCTAssertEqual(leg.routeLabel, "LSPG → LSMM", "back to the stop the next leg leaves from")
        XCTAssertEqual(m.trip(forThreadId: a.id)?.legIds, [a.id, leg.id, b.id])
        XCTAssertEqual(m.nextTripLeg()?.id, leg.id)
        XCTAssertEqual(m.thread(withId: a.id)?.landedElsewhere?.continued, true)
    }

    // MARK: - Persistence of what 5.1 adds

    func testALandingRecordedBeforeAFieldExistedStillDecodes() throws {
        // A file written by a build without `continued` must not fail to decode: when it did, the
        // loader fell back to an older file of the same thread and a landed flight came back as
        // "in flight".
        let json = #"{"plannedIdent":"LSMM","landedIdent":"LSPG","landedName":"Kägiswil","offerDismissed":false}"#
        let landed = try JSONDecoder().decode(LandedElsewhere.self, from: Data(json.utf8))
        XCTAssertEqual(landed.landedIdent, "LSPG")
        XCTAssertFalse(landed.continued)
        let stopover = try JSONDecoder().decode(Stopover.self, from: Data("{}".utf8))
        XCTAssertEqual(stopover, Stopover())
    }

    func testARenamedThreadKeepsOneFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var thread = FlightThread(routeLabel: "LSZQ → LSMM")
        DataPersistenceManager.writeFlightThreadFiles([thread], to: directory)
        thread.routeLabel = "LSZQ → LSPG"
        thread.touch()
        DataPersistenceManager.writeFlightThreadFiles([thread], to: directory)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1, "the file named after the old label must go: \(files)")
        XCTAssertEqual(DataPersistenceManager.decodeFlightThreads(in: directory).first?.routeLabel, "LSZQ → LSPG")
    }

    // MARK: - Saving before the launch load lands

    /// The trip load is async and iCloud-backed. A trip formed before it landed was written as an
    /// array holding only itself, which deleted every trip already on disk: for good when the write
    /// beat the load's read, until the next save otherwise. The same mechanism wiped a real two-leg
    /// trip from the simulator app on 2026-09-25, through a test manager on the real datastore.
    @MainActor
    func testATripFormedDuringTheLaunchLoadKeepsTheTripsOnDisk() async throws {
        let datastore = makeTestDatastore()
        let onDisk = Trip(legIds: [UUID(), UUID()])
        await datastore.saveTripsOffMain([onDisk])

        let m = makeTestThreadManager(datastore: datastore)
        XCTAssertFalse(m.hasLoadedTrips, "this has to happen inside the load window")
        let a = m.createThread(from: plan("LSZQ", "LFSB"))
        let b = m.createThread(from: plan("LFSB", "LSGY"))
        defer { m.deleteThread(threadId: a.id); m.deleteThread(threadId: b.id) }
        let formed = try XCTUnwrap(m.formTrip(from: [a.id, b.id]))

        let deadline = Date().addingTimeInterval(5)
        var saved: [Trip] = []
        while Date() < deadline {
            saved = await datastore.loadTripsOffMain()
            if m.hasLoadedTrips, saved.count == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(Set(saved.map(\.id)), [onDisk.id, formed.id], "the file must keep the trip it already held")
        XCTAssertEqual(Set(m.trips.map(\.id)), [onDisk.id, formed.id])
    }

    // MARK: - Test isolation

    /// A test manager on `.shared` replaced the simulator app's own `trips.json` with the test's one
    /// trip (2026-09-25). A directory-scoped datastore must keep every path under its root, even
    /// after an iCloud account change, and a manager built on it must write there.
    @MainActor
    func testADirectoryScopedDatastoreKeepsThreadsAndTripsInsideIt() async throws {
        let datastore = makeTestDatastore()
        datastore.reresolveUbiquityContainer()
        XCTAssertFalse(datastore.isICloudAvailable)
        let root = datastore.localAppDirectory.standardizedFileURL.path + "/"
        for url in [datastore.flightThreadsDirectory, datastore.tripsFileURL, datastore.legacyLocalTripsFileURL,
                    datastore.navigationPlansDirectory, datastore.flightsDirectory, datastore.mapTilesDirectory,
                    datastore.activeFlightStateURL, datastore.activeFlightTrackDeltaURL] {
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(root), "\(url.path) is outside \(root)")
        }

        let m = makeTestThreadManager(datastore: datastore)
        let a = m.createThread(from: plan("LSZQ", "LFSB"))
        let b = m.createThread(from: plan("LFSB", "LSGY"))
        defer { m.deleteThread(threadId: a.id); m.deleteThread(threadId: b.id) }
        let trip = try XCTUnwrap(m.formTrip(from: [a.id, b.id]))

        // Both writes are off-main; wait for them to land.
        let deadline = Date().addingTimeInterval(5)
        var savedTrips: [Trip] = []
        var savedThreads: [FlightThread] = []
        while Date() < deadline {
            savedTrips = await datastore.loadTripsOffMain()
            savedThreads = DataPersistenceManager.decodeFlightThreads(in: datastore.flightThreadsDirectory)
            if savedTrips.count == 1, savedThreads.count == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(savedTrips.map(\.id), [trip.id])
        XCTAssertEqual(Set(savedThreads.map(\.id)), [a.id, b.id])
    }
}
