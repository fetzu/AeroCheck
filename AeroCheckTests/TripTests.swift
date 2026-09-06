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
    private func manager() -> FlightThreadManager {
        let suite = "TripTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return FlightThreadManager(defaults: defaults)
    }

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
        let m = manager()
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
        let m = manager()
        let a = m.createThread(from: plan("LSZQ", "LSGY"))
        defer { m.deleteThread(threadId: a.id) }
        XCTAssertNil(m.formTrip(from: [a.id]), "one leg is a flight, not a trip")
        XCTAssertNil(m.thread(withId: a.id)?.tripId)
    }

    @MainActor
    func testRemovingALegDissolvesTheTripAndGivesThePreparationBack() {
        // A trip of one leg is just a flight. Without handing the shared tasks back, deleting one leg
        // would take the survivor's whole preparation with it.
        let m = manager()
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
        let m = manager()
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
