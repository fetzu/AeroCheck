import XCTest
import CoreLocation
@testable import AeroCheck

/// Flight Thread (v5.0.0): the task engine's rules, the thread model's own bookkeeping, and the
/// manager's lifecycle. The engine and the model are pure, so most of this runs without touching a
/// service, the network or the filesystem.
final class FlightThreadTests: XCTestCase {

    // MARK: - Helpers

    private func waypoint(_ name: String, lat: Double, lon: Double) -> FlightPlanWaypoint {
        FlightPlanWaypoint(name: name,
                           coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                           altitude: 3000)
    }

    /// LSZQ (Bressaucourt) → LSGY (Yverdon): a real, entirely Swiss leg.
    private func swissPlan() -> FlightPlan {
        var plan = FlightPlan(name: "Test")
        plan.waypoints = [
            waypoint("LSZQ", lat: 47.4247, lon: 7.1869),
            waypoint("LSGY", lat: 46.7619, lon: 6.6141)
        ]
        plan.fuelFlow = 25
        plan.fuelOnBoard = 80
        plan.tripFuel = 20
        return plan
    }

    private func context(profile: ThreadProfile = .full,
                         countries: [String] = ["CH"],
                         hasRoute: Bool = true) -> ThreadTaskEngine.Context {
        var c = ThreadTaskEngine.Context(profile: profile)
        c.hasRoute = hasRoute
        c.departureIdent = "LSZQ"
        c.arrivalIdent = "LSGY"
        c.countries = countries
        return c
    }

    private func keys(_ tasks: [ThreadTask]) -> [ThreadTaskKey] { tasks.map(\.key) }

    // MARK: - Engine: profiles

    func testFullProfileCoversTheWholeAdminBracket() {
        let tasks = ThreadTaskEngine.generate(context: context())
        let produced = Set(keys(tasks))

        XCTAssertTrue(produced.contains(.routePlanned))
        XCTAssertTrue(produced.contains(.fuelPlanned))
        XCTAssertTrue(produced.contains(.massAndBalance))
        XCTAssertTrue(produced.contains(.aircraftReserved))
        XCTAssertTrue(produced.contains(.weatherBriefed))
        XCTAssertTrue(produced.contains(.flightPlanFiled))
        XCTAssertTrue(produced.contains(.logbookEntry))
    }

    func testLocalProfileStaysMinimal() {
        let tasks = ThreadTaskEngine.generate(context: context(profile: .local))
        let produced = Set(keys(tasks))

        // The point of the local profile: a circuit session should not be asked about flight plans,
        // customs or nav logs.
        XCTAssertFalse(produced.contains(.flightPlanFiled))
        XCTAssertFalse(produced.contains(.customsNotified))
        XCTAssertFalse(produced.contains(.navLogReady))
        XCTAssertFalse(produced.contains(.massAndBalance))

        // But the parts that still pay off are there.
        XCTAssertTrue(produced.contains(.weatherBriefed))
        XCTAssertTrue(produced.contains(.logbookEntry))
        XCTAssertTrue(produced.contains(.debriefWritten))
        XCTAssertTrue(produced.contains(.aircraftReserved))
    }

    // MARK: - Engine: conditional rules

    func testSwissProductsOnlyAppearOnASwissRoute() {
        let swiss = ThreadTaskEngine.generate(context: context(countries: ["CH"]))
        XCTAssertTrue(Set(keys(swiss)).contains(.dabsChecked))
        XCTAssertTrue(Set(keys(swiss)).contains(.gaforChecked))

        let french = ThreadTaskEngine.generate(context: context(countries: ["FR"]))
        XCTAssertFalse(Set(keys(french)).contains(.dabsChecked), "DABS is a Swiss product")
        XCTAssertFalse(Set(keys(french)).contains(.gaforChecked), "GAFOR is a Swiss product")
    }

    func testCustomsTaskAppearsOncePerForeignCountry() {
        var c = context(countries: ["CH", "FR", "DE"])
        c.homeCountry = "CH"
        let tasks = ThreadTaskEngine.generate(context: c)
        let customs = tasks.filter { $0.key == .customsNotified }

        XCTAssertEqual(customs.count, 2)
        XCTAssertEqual(Set(customs.compactMap(\.subject)), ["FR", "DE"])
    }

    func testNoCustomsTaskWhenTheRouteStaysHome() {
        let tasks = ThreadTaskEngine.generate(context: context(countries: ["CH"]))
        XCTAssertTrue(tasks.filter { $0.key == .customsNotified }.isEmpty)
    }

    func testPPRTaskIsPerAerodrome() {
        var c = context()
        c.pprIdents = ["LSGY", "LSTB"]
        let tasks = ThreadTaskEngine.generate(context: c)
        let ppr = tasks.filter { $0.key == .pprObtained }

        XCTAssertEqual(ppr.count, 2)
        XCTAssertEqual(ppr.compactMap(\.subject).sorted(), ["LSGY", "LSTB"])
    }

    func testCloseTaskForTheFlightPlanExistsOnlyOnceFiled() {
        var notFiled = context()
        notFiled.flightPlanFiled = false
        XCTAssertFalse(Set(keys(ThreadTaskEngine.generate(context: notFiled))).contains(.flightPlanClosed),
                       "Nothing to close until a plan has been filed — this is what keeps circuits quiet")

        var filed = context()
        filed.flightPlanFiled = true
        let tasks = ThreadTaskEngine.generate(context: filed)
        let closeTask = tasks.first { $0.key == .flightPlanClosed }
        XCTAssertNotNil(closeTask)
        XCTAssertEqual(closeTask?.kind, .reminder)
        XCTAssertTrue(closeTask?.isUrgent == true)
    }

    // MARK: - Engine: auto tasks

    func testFuelTaskIsSatisfiedOnlyWhenOnBoardCoversRequired() {
        var short = context()
        short.fuelRequiredLitres = 60
        short.fuelOnBoardLitres = 50
        let shortTask = ThreadTaskEngine.generate(context: short).first { $0.key == .fuelPlanned }
        XCTAssertEqual(shortTask?.state, .pending)

        var enough = context()
        enough.fuelRequiredLitres = 54
        enough.fuelOnBoardLitres = 80
        let enoughTask = ThreadTaskEngine.generate(context: enough).first { $0.key == .fuelPlanned }
        XCTAssertEqual(enoughTask?.state, .done)
        XCTAssertEqual(enoughTask?.detail, "REQ 54 L · FOB 80 L")
    }

    func testRouteTaskFollowsWhetherARouteExists() {
        let without = ThreadTaskEngine.generate(context: context(hasRoute: false)).first { $0.key == .routePlanned }
        XCTAssertEqual(without?.state, .pending)

        let with = ThreadTaskEngine.generate(context: context(hasRoute: true)).first { $0.key == .routePlanned }
        XCTAssertEqual(with?.state, .done)
        XCTAssertEqual(with?.detail, "LSZQ → LSGY")
    }

    // MARK: - Engine: regeneration

    func testRegenerationKeepsWorkThePilotAlreadyDid() {
        var tasks = ThreadTaskEngine.generate(context: context())
        guard let index = tasks.firstIndex(where: { $0.key == .aircraftReserved }) else {
            return XCTFail("expected a reservation task")
        }
        let originalId = tasks[index].id
        tasks[index].state = .done
        tasks[index].note = "Booked 13:00-17:30"

        // The route grew a waypoint; everything regenerates.
        var changed = context()
        changed.arrivalIdent = "LSGL"
        let regenerated = ThreadTaskEngine.generate(context: changed, existing: tasks)

        let reservation = regenerated.first { $0.key == .aircraftReserved }
        XCTAssertEqual(reservation?.state, .done, "a tick must survive a route edit")
        XCTAssertEqual(reservation?.note, "Booked 13:00-17:30")
        XCTAssertEqual(reservation?.id, originalId, "identity is stable so SwiftUI doesn't re-animate the row")
    }

    func testRegenerationRecomputesAutoTasksEvenWhenCarriedOver() {
        var enough = context()
        enough.fuelRequiredLitres = 40
        enough.fuelOnBoardLitres = 80
        let first = ThreadTaskEngine.generate(context: enough)
        XCTAssertEqual(first.first { $0.key == .fuelPlanned }?.state, .done)

        // The route got longer and now needs more fuel than is on board.
        var short = context()
        short.fuelRequiredLitres = 95
        short.fuelOnBoardLitres = 80
        let second = ThreadTaskEngine.generate(context: short, existing: first)

        XCTAssertEqual(second.first { $0.key == .fuelPlanned }?.state, .pending,
                       "an auto task must never keep claiming a stale computation")
    }

    func testRegenerationDropsTasksThatNoLongerApply() {
        var withPPR = context()
        withPPR.pprIdents = ["LSGY"]
        let first = ThreadTaskEngine.generate(context: withPPR)
        XCTAssertEqual(first.filter { $0.key == .pprObtained }.count, 1)

        // Destination changed to a field with no PPR requirement.
        let second = ThreadTaskEngine.generate(context: context(), existing: first)
        XCTAssertTrue(second.filter { $0.key == .pprObtained }.isEmpty)
    }

    // MARK: - Thread model

    func testFilingAndClosingKeepTheThreadMarkersInSync() {
        var thread = FlightThread(routeLabel: "LSZQ → LSGY")
        thread.tasks = ThreadTaskEngine.generate(context: context())
        guard let filed = thread.tasks.first(where: { $0.key == .flightPlanFiled }) else {
            return XCTFail("expected a filing task")
        }

        XCTAssertFalse(thread.hasOpenFlightPlan)
        thread.setState(.done, forTaskWithId: filed.id)
        XCTAssertNotNil(thread.flightPlanFiledAt)
        XCTAssertTrue(thread.hasOpenFlightPlan, "a filed plan with no close is exactly the risky state")

        // Un-ticking the filing must not leave a close timestamp behind.
        thread.setState(.pending, forTaskWithId: filed.id)
        XCTAssertNil(thread.flightPlanFiledAt)
        XCTAssertNil(thread.flightPlanClosedAt)
        XCTAssertFalse(thread.hasOpenFlightPlan)
    }

    func testNotApplicableTasksLeaveTheReadinessDenominator() {
        var thread = FlightThread(routeLabel: "LSZQ → LSGY")
        thread.tasks = ThreadTaskEngine.generate(context: context())
        let before = thread.preFlightProgress

        guard let ppr = thread.tasks.first(where: { $0.key == .massAndBalance }) else {
            return XCTFail("expected a mass & balance task")
        }
        thread.setState(.notApplicable, forTaskWithId: ppr.id)

        XCTAssertEqual(thread.preFlightProgress.total, before.total - 1,
                       "dismissing a task must move the ring, not strand it")
    }

    func testNextTaskIgnoresCloseOutUntilTheFlightIsOver() {
        var thread = FlightThread(routeLabel: "LSZQ → LSGY")
        var c = context()
        c.flightPlanFiled = true
        thread.tasks = ThreadTaskEngine.generate(context: c)

        // Settle everything before the flight.
        for task in thread.tasks where task.chapter != .close {
            thread.setState(.done, forTaskWithId: task.id)
        }
        XCTAssertNil(thread.nextTask, "close-out work is not the pilot's problem before the flight")

        thread.state = .closeOut
        XCTAssertEqual(thread.nextTask?.chapter, .close)
    }

    // MARK: - Context building

    func testContextFromPlanDerivesRouteFuelAndFees() {
        let plan = swissPlan()
        let c = FlightThreadManager.context(for: plan, profile: .full, countries: ["CH"])

        XCTAssertTrue(c.hasRoute)
        XCTAssertEqual(c.departureIdent, "LSZQ")
        XCTAssertEqual(c.arrivalIdent, "LSGY")
        XCTAssertEqual(c.feeIdents, ["LSGY"], "a landing away from home can attract a fee")
        XCTAssertEqual(c.fuelOnBoardLitres, 80)
        XCTAssertGreaterThan(c.fuelRequiredLitres, 0)
    }

    func testNoFeeTaskWhenTheFlightReturnsToItsDepartureField() {
        var plan = swissPlan()
        plan.waypoints.append(waypoint("LSZQ", lat: 47.4247, lon: 7.1869))
        let c = FlightThreadManager.context(for: plan, profile: .full, countries: ["CH"])

        XCTAssertTrue(c.feeIdents.isEmpty, "landing back home is not an away fee")
    }

    func testFreeTextWaypointsAreNotTreatedAsAerodromes() {
        XCTAssertTrue(FlightThreadManager.looksLikeICAO("LSGY"))
        XCTAssertFalse(FlightThreadManager.looksLikeICAO("JORAT VOR"))
        XCTAssertFalse(FlightThreadManager.looksLikeICAO("lsgy"), "an ident is uppercase")
        XCTAssertFalse(FlightThreadManager.looksLikeICAO("LSG"))
    }

    func testContextWithoutAPlanStillOffersTheHomeCountryProducts() {
        let c = FlightThreadManager.context(for: nil, profile: .local, countries: [])
        XCTAssertEqual(c.countries, ["CH"])
        XCTAssertFalse(c.hasRoute)
        XCTAssertTrue(c.touchesSwitzerland)
    }

    // MARK: - Manager lifecycle

    @MainActor
    func testCreatingAThreadMakesItCurrentAndGeneratesTasks() {
        let manager = FlightThreadManager(defaults: throwawayDefaults())
        let thread = manager.createThread(from: swissPlan(), profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        XCTAssertEqual(manager.currentThreadId, thread.id)
        XCTAssertFalse(thread.tasks.isEmpty)
        XCTAssertEqual(thread.routeLabel, "LSZQ → LSGY")
    }

    @MainActor
    func testCloseOutRaisesTheOpenFlightPlanNoticeOnlyWhenOneWasFiled() {
        let manager = FlightThreadManager(defaults: throwawayDefaults())
        let thread = manager.createThread(from: swissPlan(), profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        // Landing with no filed plan: nothing to nag about.
        manager.beginCloseOut(threadId: thread.id, flightId: UUID())
        XCTAssertNil(manager.openFlightPlanNotice)

        // File it, land again: now the notice is exactly the point.
        guard let filed = manager.thread(withId: thread.id)?.tasks.first(where: { $0.key == .flightPlanFiled }) else {
            return XCTFail("expected a filing task")
        }
        manager.setTaskState(.done, taskId: filed.id, threadId: thread.id)
        manager.beginCloseOut(threadId: thread.id, flightId: UUID())
        XCTAssertEqual(manager.openFlightPlanNotice?.threadId, thread.id)

        manager.markFlightPlanClosed(threadId: thread.id)
        XCTAssertNil(manager.openFlightPlanNotice)
        XCTAssertFalse(manager.thread(withId: thread.id)?.hasOpenFlightPlan ?? true)
    }

    @MainActor
    func testFilingATaskAddsTheCloseOutTask() {
        let manager = FlightThreadManager(defaults: throwawayDefaults())
        let thread = manager.createThread(from: swissPlan(), profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        XCTAssertNil(manager.thread(withId: thread.id)?.tasks.first { $0.key == .flightPlanClosed })

        guard let filed = thread.tasks.first(where: { $0.key == .flightPlanFiled }) else {
            return XCTFail("expected a filing task")
        }
        manager.setTaskState(.done, taskId: filed.id, threadId: thread.id)

        XCTAssertNotNil(manager.thread(withId: thread.id)?.tasks.first { $0.key == .flightPlanClosed },
                        "filing a plan is what creates the obligation to close it")
    }

    // MARK: - Fuel type enum (v5.0.0)

    /// The mapping was established twice from independent directions; these pin it so a future edit
    /// cannot quietly renumber it. See `OpenAIPFuelType` for the derivation.
    func testFuelTypeCodesMapToTheGradesTheyWereProvenToBe() {
        XCTAssertEqual(OpenAIPFuelType(rawValue: 0)?.label, "Super PLUS")
        XCTAssertEqual(OpenAIPFuelType(rawValue: 1)?.label, "AVGAS")
        XCTAssertEqual(OpenAIPFuelType(rawValue: 3)?.label, "Jet A1")
        XCTAssertEqual(OpenAIPFuelType(rawValue: 6)?.label, "UL91")
        XCTAssertNil(OpenAIPFuelType(rawValue: 7), "an unknown code must not resolve to a grade")
    }

    func testAirlineHubReportsJetFuelAlone() throws {
        // EDDF and LFPG both return [3] and nothing else — the observation that pinned 3 = Jet A1.
        let json = """
        {"features":[{"type":"Feature","properties":{
          "_id":"eddf","name":"FRANKFURT MAIN","icaoCode":"EDDF","type":3,"country":"DE",
          "services":{"fuelTypes":[3]},"frequencies":[],"runways":[]
        },"geometry":{"type":"Point","coordinates":[8.57,50.03]}}]}
        """.data(using: .utf8)!

        let airport = try XCTUnwrap(try OpenAIPAirport.parse(geoJSON: json).first)
        XCTAssertEqual(airport.fuelTypes.map(\.label), ["Jet A1"])
    }

    func testPistonGradesAreListedFirst() throws {
        // A pilot scanning chips is asking "can I get AVGAS here", so the answer leads.
        let json = """
        {"features":[{"type":"Feature","properties":{
          "_id":"lsgy","name":"YVERDON","icaoCode":"LSGY","type":2,"country":"CH",
          "services":{"fuelTypes":[3,0,1]},"frequencies":[],"runways":[]
        },"geometry":{"type":"Point","coordinates":[6.61,46.76]}}]}
        """.data(using: .utf8)!

        let airport = try XCTUnwrap(try OpenAIPAirport.parse(geoJSON: json).first)
        XCTAssertEqual(airport.fuelTypes.map(\.label), ["Super PLUS", "AVGAS", "Jet A1"])
    }

    func testUnknownFuelCodeIsSkippedButKeptRaw() throws {
        let json = """
        {"features":[{"type":"Feature","properties":{
          "_id":"x","name":"SOMEWHERE","icaoCode":"LSZZ","type":2,"country":"CH",
          "services":{"fuelTypes":[1,99]},"frequencies":[],"runways":[]
        },"geometry":{"type":"Point","coordinates":[7.0,47.0]}}]}
        """.data(using: .utf8)!

        let airport = try XCTUnwrap(try OpenAIPAirport.parse(geoJSON: json).first)
        XCTAssertEqual(airport.fuelTypes.map(\.label), ["AVGAS"])
        XCTAssertEqual(airport.fuelTypeCodes, [1, 99], "an unrecognised code is preserved, not dropped")
    }

    func testFuelTaskDetailNamesWhatTheDestinationSells() {
        var c = context()
        c.fuelRequiredLitres = 54
        c.fuelOnBoardLitres = 80
        c.destinationFuels = ["AVGAS", "UL91"]

        let fuel = ThreadTaskEngine.generate(context: c).first { $0.key == .fuelPlanned }
        XCTAssertEqual(fuel?.detail, "REQ 54 L · FOB 80 L · LSGY: AVGAS, UL91")
    }

    func testFuelTaskOmitsTheDestinationWhenNothingIsKnown() {
        var c = context()
        c.fuelRequiredLitres = 54
        c.fuelOnBoardLitres = 80

        let fuel = ThreadTaskEngine.generate(context: c).first { $0.key == .fuelPlanned }
        XCTAssertEqual(fuel?.detail, "REQ 54 L · FOB 80 L", "absent data is not 'no fuel available'")
    }

    // MARK: - OpenAIP operational flags (v5.0.0)

    /// Shaped from a real `api.core.openaip.net` response for LSGY (Yverdon), which genuinely is
    /// flagged PPR — these keys were arriving with every download and being dropped at the parser.
    func testOperationalFlagsAreParsedFromTheAirportRecord() throws {
        let json = """
        {"features":[{"type":"Feature","properties":{
          "_id":"abc123","name":"YVERDON-LES-BAINS","icaoCode":"LSGY","type":2,
          "elevation":{"value":433,"unit":0},"country":"CH",
          "ppr":true,"private":true,"skydiveActivity":true,"winchOnly":false,
          "services":{"fuelTypes":[0,1,3]},
          "frequencies":[],"runways":[]
        },"geometry":{"type":"Point","coordinates":[6.6141,46.7619]}}]}
        """.data(using: .utf8)!

        let airports = try OpenAIPAirport.parse(geoJSON: json)
        let lsgy = try XCTUnwrap(airports.first)

        XCTAssertEqual(lsgy.icaoCode, "LSGY")
        XCTAssertTrue(lsgy.isPPR)
        XCTAssertTrue(lsgy.isPrivate)
        XCTAssertTrue(lsgy.hasSkydiveActivity)
        XCTAssertFalse(lsgy.isWinchOnly)
        XCTAssertEqual(lsgy.fuelTypeCodes, [0, 1, 3])
    }

    /// An older cached file, or a source that omits the flags, must not manufacture requirements.
    func testMissingFlagsDefaultToNotRequired() throws {
        let json = """
        {"features":[{"type":"Feature","properties":{
          "_id":"x","name":"SOMEWHERE","icaoCode":"LSZZ","type":2,"country":"CH",
          "frequencies":[],"runways":[]
        },"geometry":{"type":"Point","coordinates":[7.0,47.0]}}]}
        """.data(using: .utf8)!

        let airport = try XCTUnwrap(try OpenAIPAirport.parse(geoJSON: json).first)
        XCTAssertFalse(airport.isPPR, "an absent flag is 'not stated', never a manufactured PPR task")
        XCTAssertFalse(airport.isPrivate)
        XCTAssertTrue(airport.fuelTypeCodes.isEmpty)
    }

    /// The test host shares the app's bundle id, so a manager built against `.standard` would write
    /// its pointer into the real app's slot on that simulator. (Same trap as FlightPlanManager.)
    // MARK: - The route decides the country, not the app's origin (device-pass regression)

    /// Prievidza (LZPE) → Eggenfelden (EDME): Slovakia to Germany across Austria, ~300 km from the
    /// nearest Swiss border.
    private func slovakToGermanPlan() -> FlightPlan {
        var plan = FlightPlan(name: "LZPE → EDME")
        plan.waypoints = [
            waypoint("LZPE", lat: 48.7742, lon: 18.5942),
            waypoint("EDME", lat: 48.3961, lon: 12.7236)
        ]
        plan.fuelFlow = 25
        plan.fuelOnBoard = 80
        plan.tripFuel = 20
        return plan
    }

    @MainActor
    func testAForeignRouteNeverAcquiresSwissProducts() {
        let manager = FlightThreadManager(defaults: throwawayDefaults())
        let thread = manager.createThread(from: slovakToGermanPlan(), profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        XCTAssertFalse(thread.countries?.contains("CH") ?? true, "got \(thread.countries ?? [])")
        XCTAssertNil(thread.tasks.first { $0.key == .dabsChecked }, "DABS is a Swiss product")
        XCTAssertNil(thread.tasks.first { $0.key == .gaforChecked }, "GAFOR is a Swiss product")
    }

    @MainActor
    func testFilingAFlightPlanDoesNotConjureSwitzerlandOntoAForeignRoute() {
        // The reported defect, exactly: the tasks were right until the pilot ticked "flight plan
        // filed", at which point the regeneration rebuilt the country list as home + foreign — with
        // home hard-coded to CH — and DABS, GAFOR and a "Swiss side" link appeared.
        let manager = FlightThreadManager(defaults: throwawayDefaults())
        let thread = manager.createThread(from: slovakToGermanPlan(), profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        guard let filed = thread.tasks.first(where: { $0.key == .flightPlanFiled }) else {
            return XCTFail("no filing task")
        }
        manager.setTaskState(.done, taskId: filed.id, threadId: thread.id)

        let after = manager.thread(withId: thread.id)
        XCTAssertNotNil(after?.tasks.first { $0.key == .flightPlanClosed },
                        "filing should still add the close-out reminder")
        XCTAssertNil(after?.tasks.first { $0.key == .dabsChecked }, "DABS appeared after filing")
        XCTAssertNil(after?.tasks.first { $0.key == .gaforChecked }, "GAFOR appeared after filing")
        XCTAssertFalse(after?.countries?.contains("CH") ?? true, "got \(after?.countries ?? [])")
    }

    @MainActor
    func testTheDepartureCountryIsNotTreatedAsForeign() {
        // Departing Slovakia, you do not clear customs INTO Slovakia. With home hard-coded to CH it
        // raised a Slovak customs task on a Slovak departure.
        let manager = FlightThreadManager(defaults: throwawayDefaults())
        let thread = manager.createThread(from: slovakToGermanPlan(), profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        XCTAssertEqual(thread.homeCountry, "SK", "home should follow the departure aerodrome")
        let customs = thread.tasks.filter { $0.key == .customsNotified }.compactMap(\.subject)
        XCTAssertFalse(customs.contains("SK"), "got \(customs)")
        XCTAssertTrue(customs.contains("DE"), "got \(customs)")
    }

    func testTheSwissLinkIsOnlyOfferedWhenSwitzerlandIsInvolved() {
        let task = ThreadTask(key: .customsNotified, subject: "DE", kind: .check)
        let away = ThreadTaskPresentation.links(for: task, touchesSwitzerland: false)
        XCTAssertFalse(away.contains { $0.label == L10n.Border.swissSide })
        XCTAssertTrue(away.contains { $0.label == L10n.Border.openOfficial })

        let swiss = ThreadTaskPresentation.links(for: task, touchesSwitzerland: true)
        XCTAssertTrue(swiss.contains { $0.label == L10n.Border.swissSide })
    }

    private func throwawayDefaults() -> UserDefaults {
        let suite = "FlightThreadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }
}
