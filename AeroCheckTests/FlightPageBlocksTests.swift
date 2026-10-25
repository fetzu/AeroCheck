import XCTest
@testable import AeroCheck

/// The flight's page as blocks (6.6.0): which tasks make which block, in what order, how each chapter shows, what
/// waits for the day of the flight, the status line's facts and the counts in blocks. Route A of the 6.5.0 device
/// check throughout: LSZQ → EDTF through CH, DE and FR.
final class FlightPageBlocksTests: XCTestCase {

    private let zurich = TimeZone(identifier: "Europe/Zurich")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zurich
        return c
    }

    private func local(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func task(_ key: ThreadTaskKey, _ subject: String? = nil, _ state: ThreadTaskState = .pending,
                      kind: ThreadTaskKind = .check, at: Date? = nil) -> ThreadTask {
        ThreadTask(key: key, subject: subject, kind: kind, state: state, completedAt: state == .done ? at ?? local(22, 9) : nil)
    }

    /// Route A before the flight: PLAN done, PREPARE open but the nav log.
    private func routeA(state: FlightThreadState = .planned, departure: Date? = nil) -> FlightThread {
        var thread = FlightThread(state: state, routeLabel: "LSZQ → EDTF")
        thread.scheduledDeparture = departure
        thread.tasks = [
            task(.routePlanned, nil, .done, kind: .auto), task(.fuelPlanned, nil, .done, kind: .auto),
            task(.massAndBalance, nil, .done), task(.aircraftReserved, nil, .done),
            task(.weatherBriefed), task(.dabsChecked), task(.dabsChecked, "DE"), task(.dabsChecked, "FR"),
            task(.gaforChecked), task(.gaforChecked, "DE"), task(.gaforChecked, "FR"), task(.notamChecked),
            task(.flightPlanFiled), task(.customsNotified, "DE"), task(.navLogReady, nil, .done),
        ]
        return thread
    }

    // MARK: - Blocks

    func testEighteenTasksMakeTwelveBlocksInTheirFixedOrder() {
        var thread = routeA()
        thread.tasks += [task(.flightPlanClosed, kind: .reminder), task(.feesPaid, "EDTF"), task(.logbookEntry)]
        let page = FlightPage.make(thread: thread, departure: nil)
        XCTAssertEqual(page.blocks.map(\.kind), [.route, .fuel, .massAndBalance, .aircraftReserved,
                                                 .weather, .notamsAndAirspace, .flightPlan, .border("DE"), .navLog,
                                                 .closeFlightPlan, .fees("EDTF"), .logbook])
        XCTAssertEqual(page.block(.weather)?.tasks.map(\.key), [.weatherBriefed, .gaforChecked, .gaforChecked, .gaforChecked])
        XCTAssertEqual(page.block(.notamsAndAirspace)?.tasks.map(\.key), [.notamChecked, .dabsChecked, .dabsChecked, .dabsChecked])
    }

    func testTheOrderNeverDependsOnWhatIsDone() {
        var thread = routeA()
        let before = FlightPage.make(thread: thread, departure: nil).blocks.map(\.kind)
        for i in thread.tasks.indices { thread.tasks[i].state = .done }
        XCTAssertEqual(FlightPage.make(thread: thread, departure: nil).blocks.map(\.kind), before)
    }

    func testABlockIsDoneOnlyWhenEveryTaskInItIs() {
        var thread = routeA()
        for i in thread.tasks.indices where thread.tasks[i].key.isWeatherBlock && thread.tasks[i].subject != "FR" {
            thread.tasks[i].state = .done
        }
        XCTAssertEqual(FlightPage.make(thread: thread, departure: nil).block(.weather)?.state, .pending,
                       "France's area forecast is still open")
        for i in thread.tasks.indices where thread.tasks[i].key.isWeatherBlock { thread.tasks[i].state = .done }
        XCTAssertEqual(FlightPage.make(thread: thread, departure: nil).block(.weather)?.state, .done)
    }

    func testATaskSetAsideLeavesTheBlockAndAllSetAsideMeansNotApplicable() {
        var thread = routeA()
        for i in thread.tasks.indices where thread.tasks[i].key == .dabsChecked { thread.tasks[i].state = .notApplicable }
        let i = thread.tasks.firstIndex { $0.key == .notamChecked }!
        thread.tasks[i].state = .done
        XCTAssertEqual(FlightPage.make(thread: thread, departure: nil).block(.notamsAndAirspace)?.state, .done)
        thread.tasks[i].state = .notApplicable
        XCTAssertEqual(FlightPage.make(thread: thread, departure: nil).block(.notamsAndAirspace)?.state, .notApplicable)
    }

    func testTheRouteAndTheFuelTickThemselves() {
        let page = FlightPage.make(thread: routeA(), departure: nil)
        XCTAssertTrue(page.block(.route)!.isAuto)
        XCTAssertTrue(page.block(.fuel)!.isAuto)
        XCTAssertFalse(page.block(.massAndBalance)!.isAuto)
    }

    func testTheOldDebriefTaskMakesNoBlock() {
        var thread = routeA()
        thread.tasks.append(task(.debriefWritten))
        XCTAssertFalse(FlightPage.make(thread: thread, departure: nil).blocks.contains { $0.chapter == .close })
    }

    func testTwoBordersAreTwoBlocksInTheirTasksOrder() {
        var thread = routeA()
        thread.tasks.insert(task(.customsNotified, "FR"), at: 13)
        let kinds = FlightPage.make(thread: thread, departure: nil).blocks(in: .prepare).map(\.kind)
        XCTAssertEqual(kinds, [.weather, .notamsAndAirspace, .flightPlan, .border("FR"), .border("DE"), .navLog])
    }

    // MARK: - Chapters (f1 A)

    func testOnTheDayPlanIsALineAndPrepareIsOpen() {
        let page = FlightPage.make(thread: routeA(departure: local(22, 14, 30)), departure: local(22, 14, 30),
                                   now: local(22, 12, 40), calendar: calendar)
        XCTAssertEqual(page.shape(of: .plan), .done)
        XCTAssertEqual(page.shape(of: .prepare), .open)
        XCTAssertEqual(page.shape(of: .fly), .fly)
        XCTAssertEqual(page.shape(of: .close), .notYet)
    }

    func testEveryChapterWithOpenWorkIsOpen() {
        var thread = routeA(departure: local(22, 14, 30))
        thread.tasks[thread.tasks.firstIndex { $0.key == .massAndBalance }!].state = .pending
        let page = FlightPage.make(thread: thread, departure: local(22, 14, 30), now: local(22, 12, 40), calendar: calendar)
        XCTAssertEqual(page.shape(of: .plan), .open)
        XCTAssertEqual(page.shape(of: .prepare), .open)
    }

    func testAfterTheLandingCloseIsOpenAndTheRestAreLines() {
        var thread = routeA(state: .closeOut)
        thread.tasks += [task(.flightPlanClosed, kind: .reminder), task(.logbookEntry)]
        let page = FlightPage.make(thread: thread, departure: nil)
        XCTAssertEqual(page.shape(of: .plan), .done)
        XCTAssertEqual(page.shape(of: .prepare), .done)
        XCTAssertEqual(page.shape(of: .close), .open)
        for i in thread.tasks.indices where thread.tasks[i].chapter == .close { thread.tasks[i].state = .done }
        XCTAssertEqual(FlightPage.make(thread: thread, departure: nil).shape(of: .close), .done)
    }

    // MARK: - The day of the flight (f2 A)

    func testTheEveningBeforeTheWeatherAndTheNotamsWaitForTheDay() {
        let page = FlightPage.make(thread: routeA(departure: local(23, 14, 30)), departure: local(23, 14, 30),
                                   now: local(22, 18, 10), calendar: calendar)
        XCTAssertTrue(page.block(.weather)!.waitsForDay)
        XCTAssertTrue(page.block(.notamsAndAirspace)!.waitsForDay)
        XCTAssertFalse(page.block(.flightPlan)!.waitsForDay, "a plan can be filed the evening before")
        XCTAssertFalse(page.block(.border("DE"))!.waitsForDay)
        XCTAssertEqual(page.shape(of: .prepare), .open)
    }

    func testAChapterWithOnlyTheDaysBlocksLeftWaits() {
        var thread = routeA(departure: local(23, 14, 30))
        for i in thread.tasks.indices where [.flightPlanFiled, .customsNotified].contains(thread.tasks[i].key) {
            thread.tasks[i].state = .done
        }
        let page = FlightPage.make(thread: thread, departure: local(23, 14, 30), now: local(22, 18, 10), calendar: calendar)
        XCTAssertEqual(page.shape(of: .prepare), .waiting)
    }

    func testNothingWaitsOnTheDayOrForAnUndatedFlight() {
        let day = FlightPage.make(thread: routeA(departure: local(22, 14, 30)), departure: local(22, 14, 30),
                                  now: local(22, 0, 5), calendar: calendar)
        XCTAssertFalse(day.blocks.contains(where: \.waitsForDay))
        let undated = FlightPage.make(thread: routeA(), departure: nil, now: local(22, 18, 10), calendar: calendar)
        XCTAssertFalse(undated.blocks.contains(where: \.waitsForDay))
    }

    // MARK: - The status line

    func testBeforeTheFlightTheStatusSaysWhatIsLeftNowAndOnTheDay() {
        let eve = FlightPage.make(thread: routeA(departure: local(23, 14, 30)), departure: local(23, 14, 30),
                                  now: local(22, 18, 10), calendar: calendar)
        XCTAssertEqual(eve.status(departure: local(23, 14, 30)),
                       .before(departure: local(23, 14, 30), now: [.flightPlan, .border("DE")],
                               onTheDay: [.weather, .notamsAndAirspace]))
        let day = FlightPage.make(thread: routeA(departure: local(22, 14, 30)), departure: local(22, 14, 30),
                                  now: local(22, 12, 40), calendar: calendar)
        XCTAssertEqual(day.status(departure: local(22, 14, 30)),
                       .before(departure: local(22, 14, 30),
                               now: [.weather, .notamsAndAirspace, .flightPlan, .border("DE")], onTheDay: []))
    }

    func testEverythingDoneIsReady() {
        var thread = routeA()
        for i in thread.tasks.indices { thread.tasks[i].state = .done }
        XCTAssertTrue(FlightPage.make(thread: thread, departure: nil).status(departure: nil).isReady)
    }

    func testAfterTheLandingTheStatusSaysWhereAndWhatIsOwed() {
        var thread = routeA(state: .closeOut)
        thread.tasks += [task(.flightPlanClosed, kind: .reminder), task(.feesPaid, "EDTF"), task(.logbookEntry)]
        let page = FlightPage.make(thread: thread, departure: nil)
        XCTAssertEqual(page.status(flown: .init(landing: local(22, 15, 4), landedIdent: "EDTF"), departure: nil),
                       .landed(at: "EDTF", time: local(22, 15, 4), left: [.closeFlightPlan, .fees("EDTF"), .logbook]))
    }

    // MARK: - Counts (f9 A)

    func testProgressCountsBlocksForWhatIsOpenNow() {
        let before = FlightPage.make(thread: routeA(), departure: nil)
        XCTAssertEqual(before.progress.done, 5, "four in PLAN and the nav log")
        XCTAssertEqual(before.progress.total, 9)
        var after = routeA(state: .closeOut)
        after.tasks += [task(.flightPlanClosed, nil, .done, kind: .reminder), task(.logbookEntry)]
        let closing = FlightPage.make(thread: after, departure: nil)
        XCTAssertEqual(closing.progress.done, 1)
        XCTAssertEqual(closing.progress.total, 2)
    }

    // MARK: - A trip's shared preparation (round 1, q6 A)

    func testATripsBriefingSitsInTheLegsOwnBlocks() {
        var leg = FlightThread(routeLabel: "LFGA → EDTF")
        leg.tasks = [task(.flightPlanFiled), task(.navLogReady, nil, .done)]
        let shared = [task(.weatherBriefed, nil, .done), task(.notamChecked, nil, .done), task(.gaforChecked, "FR", .done)]
        let page = FlightPage.make(thread: leg, shared: shared, departure: nil)
        XCTAssertEqual(page.blocks(in: .prepare).map(\.kind), [.weather, .notamsAndAirspace, .flightPlan, .navLog])
        XCTAssertTrue(page.block(.weather)!.isShared)
        XCTAssertFalse(page.block(.flightPlan)!.isShared)
    }

    func testABriefingThatNoLongerCoversTheLegAsksAgainSayingWhen() {
        var trip = Trip(legIds: [UUID(), UUID()])
        let ticked = local(22, 8, 10)
        trip.sharedTasks = [task(.weatherBriefed, nil, .done, at: ticked)]
        let leg = FlightThread(routeLabel: "LFGA → EDTF")
        // Seven hours after the tick: the trip's freshness rule (six hours or a new day) opens it again.
        let shared = trip.tasks(forLegDeparting: local(22, 15, 10), legId: leg.id)
        let block = FlightPage.make(thread: leg, shared: shared, departure: nil).block(.weather)!
        XCTAssertEqual(block.state, .pending)
        XCTAssertEqual(block.recheckSince, ticked)
    }

    // MARK: - One tick per block (round 1, q4 A)

    private func plan(_ from: String, _ to: String) -> FlightPlan {
        var plan = FlightPlan(name: "\(from) → \(to)")
        plan.waypoints = [
            FlightPlanWaypoint(name: from, coordinate: .init(latitude: 47.4247, longitude: 7.1869)),
            FlightPlanWaypoint(name: to, coordinate: .init(latitude: 46.7619, longitude: 6.6141)),
        ]
        return plan
    }

    @MainActor
    func testTheBlocksTickTicksEveryTaskInItAndKeepsOneSetAside() throws {
        let m = makeTestThreadManager()
        var created = m.createThread(from: plan("LSZQ", "LSGY"))
        defer { m.deleteThread(threadId: created.id) }
        let index = try XCTUnwrap(m.threads.firstIndex { $0.id == created.id })
        m.threads[index].tasks += [task(.dabsChecked, "FR"), task(.dabsChecked, "DE", .notApplicable)]
        created = m.threads[index]
        let block = try XCTUnwrap(FlightPage.make(thread: created, departure: nil).block(.notamsAndAirspace))
        XCTAssertGreaterThanOrEqual(block.tasks.count, 2)
        m.setBlockState(.done, block: block, threadId: created.id)
        let after = try XCTUnwrap(m.thread(withId: created.id))
        let tasks = after.tasks.filter { FlightBlockKind.of($0) == .notamsAndAirspace }
        XCTAssertTrue(tasks.filter { $0.subject != "DE" }.allSatisfy { $0.state == .done })
        XCTAssertEqual(tasks.first { $0.subject == "DE" }?.state, .notApplicable, "set aside stays set aside")
        let ticked = try XCTUnwrap(FlightPage.make(thread: after, departure: nil).block(.notamsAndAirspace))
        XCTAssertEqual(ticked.state, .done)
        m.setBlockState(.pending, block: ticked, threadId: created.id)
        XCTAssertEqual(FlightPage.make(thread: try XCTUnwrap(m.thread(withId: created.id)), departure: nil)
                        .block(.notamsAndAirspace)?.state, .pending)
    }

    @MainActor
    func testOnALegTheBlocksTickTicksTheTripsBriefingFromThatLeg() throws {
        let m = makeTestThreadManager()
        let a = m.createThread(from: plan("LSZQ", "LFGA"))
        let b = m.createThread(from: plan("LFGA", "EDTF"))
        defer { m.deleteThread(threadId: a.id); m.deleteThread(threadId: b.id) }
        let trip = try XCTUnwrap(m.formTrip(from: [a.id, b.id]))
        let leg = try XCTUnwrap(m.thread(withId: b.id))
        let shared = Trip.sharedTasks(for: leg, in: m.trips)
        let block = try XCTUnwrap(FlightPage.make(thread: leg, shared: shared, departure: nil).block(.notamsAndAirspace))
        XCTAssertTrue(block.isShared)
        m.setBlockState(.done, block: block, threadId: b.id)
        let notam = try XCTUnwrap(m.trips.first { $0.id == trip.id }?.sharedTasks.first { $0.key == .notamChecked })
        XCTAssertEqual(notam.state, .done)
        XCTAssertTrue(notam.acknowledgedLegIds.contains(b.id))
    }

    @MainActor
    func testFilingThroughTheBlockStillAddsTheCloseOut() throws {
        let m = makeTestThreadManager()
        let created = m.createThread(from: plan("LSZQ", "LSGY"))
        defer { m.deleteThread(threadId: created.id) }
        let block = try XCTUnwrap(FlightPage.make(thread: created, departure: nil).block(.flightPlan))
        m.setBlockState(.done, block: block, threadId: created.id)
        let after = try XCTUnwrap(m.thread(withId: created.id))
        XCTAssertNotNil(after.flightPlanFiledAt)
        XCTAssertTrue(after.tasks.contains { $0.key == .flightPlanClosed })
    }

    // MARK: - Deadlines (f7 A)

    func testTheFlightPlanIsDueTheCountrysLeadTimeBeforeOffBlock() {
        XCTAssertEqual(FlightBlockDeadline.fileBy(departure: local(22, 14, 30), leadMinutes: 60), local(22, 13, 30))
        XCTAssertNil(FlightBlockDeadline.fileBy(departure: local(22, 14, 30), leadMinutes: nil),
                     "no time the AIP doesn't give")
        XCTAssertNil(FlightBlockDeadline.fileBy(departure: nil, leadMinutes: 60))
    }

    func testAFlightThatStaysInItsCountryUsesTheShorterDomesticTime() throws {
        let json = #"{"v":1,"countries":{"FR":{"filingLeadMinutes":60,"filingLeadMinutesDomestic":30},"DE":{"filingLeadMinutes":60}}}"#
        let registry = try JSONDecoder().decode(BriefingRegistry.self, from: Data(json.utf8))
        XCTAssertEqual(FlightBlockDeadline.leadMinutes(registry.country("FR"), countries: ["FR"], departureCountry: "FR"), 30)
        XCTAssertEqual(FlightBlockDeadline.leadMinutes(registry.country("FR"), countries: ["FR", "CH"], departureCountry: "FR"), 60,
                       "across a border: the longer time")
        XCTAssertEqual(FlightBlockDeadline.leadMinutes(registry.country("DE"), countries: ["DE"], departureCountry: "DE"), 60)
        XCTAssertNil(FlightBlockDeadline.leadMinutes(registry.country("CH"), countries: ["CH"], departureCountry: "CH"))
    }

    func testTheRegistryReadsALeadTimeAndDropsANonsenseOne() throws {
        let json = #"{"v":1,"countries":{"CH":{"filingLeadMinutes":60},"DE":{"filingLeadMinutes":-5},"FR":{}}}"#
        let registry = try JSONDecoder().decode(BriefingRegistry.self, from: Data(json.utf8))
        XCTAssertEqual(registry.country("CH")?.filingLeadMinutes, 60)
        XCTAssertNil(registry.country("DE")?.filingLeadMinutes)
        XCTAssertNil(registry.country("FR")?.filingLeadMinutes)
    }
}

/// The status line's words (6.6.0), in English, the test host's language.
final class FlightPageWordsTests: XCTestCase {

    private var context: FlightPageWords.Context {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return FlightPageWords.Context(now: at(22, 12, 40), calendar: calendar, locale: Locale(identifier: "en_GB"))
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testOnTheDayItSaysWhenAndWhatIsLeftWithTheDeadline() {
        var c = context
        c.fileBy = at(22, 13, 30)
        let words = FlightPageWords.status(.before(departure: at(22, 14, 30),
                                                   now: [.weather, .notamsAndAirspace, .flightPlan, .border("DE")],
                                                   onTheDay: []), c)
        XCTAssertEqual(words.title, "Departure in 1h50")
        XCTAssertEqual(words.detail, "4 left: weather, NOTAMs and airspace, the flight plan by 13:30, the border")
    }

    func testTheEveningBeforeItSaysWhatIsForNowAndWhatIsForTheDay() {
        var c = context
        c.now = at(22, 18, 10)
        let words = FlightPageWords.status(.before(departure: at(23, 14, 30), now: [.massAndBalance, .flightPlan],
                                                   onTheDay: [.weather, .notamsAndAirspace]), c)
        XCTAssertEqual(words.title, "Tomorrow at 14:30")
        XCTAssertEqual(words.detail, "Now: mass and balance, the flight plan. 2 more on the day: weather, NOTAMs and airspace.")
    }

    func testFurtherAheadItNamesTheDay() {
        XCTAssertEqual(FlightPageWords.departureWords(at(24, 14, 30), context), "Saturday at 14:30")
        XCTAssertEqual(FlightPageWords.departureWords(at(31, 9, 0), context),
                       "Sat 31 Oct at \(FlightPageWords.time(at(31, 9, 0), context))")
        XCTAssertEqual(FlightPageWords.departureWords(at(22, 11, 0), context), "Today at 11:00", "due, not 'in -1h40'")
        XCTAssertEqual(FlightPageWords.departureWords(nil, context), "No departure time")
    }

    func testReadyAndAfterTheLanding() {
        XCTAssertEqual(FlightPageWords.status(.before(departure: at(22, 13, 20), now: [], onTheDay: []), context).title,
                       "Departure in 40 min · ready")
        let landed = FlightPageWords.status(.landed(at: "EDTF", time: at(22, 15, 4),
                                                    left: [.closeFlightPlan, .logbook, .fees("EDTF")]), context)
        XCTAssertEqual(landed.title, "Landed at EDTF at 15:04")
        XCTAssertEqual(landed.detail, "3 left: close the flight plan, the logbook line, the landing fee")
    }

    func testTwoBordersAreNamedByTheirCountries() {
        var c = context
        c.countryName = { ["DE": "Germany", "FR": "France"][$0] ?? $0 }
        XCTAssertEqual(FlightPageWords.list([.border("FR"), .border("DE")], among: [.border("FR"), .border("DE")], c),
                       "the border (France), the border (Germany)")
        XCTAssertEqual(FlightPageWords.list([.border("DE")], among: [.border("DE")], c), "the border")
    }

    /// The screenshot tour opens a block by its identifier: one per kind, a country's in it.
    func testABlocksIdentifierNamesItsKind() {
        XCTAssertEqual(FlightThreadView.blockIdentifier(.notamsAndAirspace), "flightPage.block.notamsAndAirspace")
        XCTAssertEqual(FlightThreadView.blockIdentifier(.border("FR")), "flightPage.block.border.FR")
        XCTAssertEqual(FlightThreadView.blockIdentifier(.weather), "flightPage.block.weather")
    }
}
