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
        XCTAssertTrue(produced.contains(.aircraftReserved))
        // The debrief is the flight's notes, optional, since 6.4.0: never a task (st-18).
        XCTAssertFalse(produced.contains(.debriefWritten))
    }

    /// A thread from before 6.4.0 kept a debrief task: the next regeneration drops it, so CLOSE counts the
    /// logbook line alone and the debrief is the optional notes field (st-18).
    func testAnOlderThreadsDebriefTaskGoesAtTheNextRegeneration() {
        let existing = [ThreadTask(key: .logbookEntry, kind: .check), ThreadTask(key: .debriefWritten, kind: .check)]
        let tasks = ThreadTaskEngine.generate(context: context(profile: .local), existing: existing)
        XCTAssertFalse(tasks.contains { $0.key == .debriefWritten })
        XCTAssertEqual(tasks.filter { $0.chapter == .close }.map(\.key), [.logbookEntry])
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

    func testTheBorderBlockIsTheCountryTheFlightLandsIn() {
        // The route's countries reach 10 NM past it, for the data; the border block is the arrival's alone. (6.6.0)
        var c = context(countries: ["CH", "DE", "FR"])
        c.homeCountry = "CH"
        c.arrivalCountry = "FR"
        let customs = ThreadTaskEngine.generate(context: c).filter { $0.key == .customsNotified }
        XCTAssertEqual(customs.map(\.subject), ["FR"])
    }

    func testNoBorderBlockBetweenTwoEUCountriesInSchengen() {
        // No customs and no passport control between them (the author's answer, 24 Oct 2026). (6.6.0)
        func border(_ home: String, _ arrival: String) -> [String?] {
            var c = context(countries: [home, arrival])
            c.homeCountry = home
            c.arrivalCountry = arrival
            return ThreadTaskEngine.generate(context: c).filter { $0.key == .customsNotified }.map(\.subject)
        }
        XCTAssertEqual(border("DE", "FR"), [])
        XCTAssertEqual(border("FR", "IT"), [])
        XCTAssertEqual(border("DE", "IE"), ["IE"], "Ireland is outside Schengen")
        XCTAssertEqual(border("CY", "GR"), ["GR"], "so is Cyprus")
        XCTAssertEqual(border("NO", "DE"), ["DE"], "Norway is in Schengen, not in the EU")
        XCTAssertEqual(border("CH", "FR"), ["FR"])
        XCTAssertEqual(border("FR", "CH"), ["CH"])
        XCTAssertEqual(border("GB", "FR"), ["FR"])
    }

    func testNoCustomsTaskWhenTheRouteStaysHome() {
        XCTAssertTrue(ThreadTaskEngine.generate(context: context(countries: ["CH"]))
            .filter { $0.key == .customsNotified }.isEmpty)
        // A neighbour 10 NM off the route is no border.
        var c = context(countries: ["CH", "FR"])
        c.arrivalCountry = "CH"
        XCTAssertTrue(ThreadTaskEngine.generate(context: c).filter { $0.key == .customsNotified }.isEmpty)
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

    /// READY once every task before the flight is ticked or set aside, PLANNED again when one is unticked; the
    /// flight's own states left alone. It used to say PLANNED with everything ticked. (6.4.0)
    func testAFlightIsReadyOnceEverythingBeforeItIsSettled() {
        var thread = FlightThread(routeLabel: "LSZQ → LSGY")
        thread.tasks = ThreadTaskEngine.generate(context: context())
        thread.settleReadiness()
        XCTAssertEqual(thread.state, .planned)

        for task in thread.tasks where (task.chapter == .plan || task.chapter == .prepare) && task.state == .pending {
            thread.setState(task.key == .pprObtained ? .notApplicable : .done, forTaskWithId: task.id)
        }
        thread.settleReadiness()
        XCTAssertEqual(thread.state, .ready, "everything ticked or set aside")

        let weather = thread.tasks.first { $0.key == .weatherBriefed }!
        thread.setState(.pending, forTaskWithId: weather.id)
        thread.settleReadiness()
        XCTAssertEqual(thread.state, .planned, "unticked again")

        thread.state = .closeOut
        thread.settleReadiness()
        XCTAssertEqual(thread.state, .closeOut, "after the flight, the flight's state")
    }

    @MainActor
    func testTheManagerMovesAFlightToReadyAsItsTasksAreTicked() {
        let manager = makeTestThreadManager()
        let thread = manager.createThread(from: swissPlan(), profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }
        XCTAssertEqual(manager.thread(withId: thread.id)?.state, .planned)
        for task in thread.tasks where (task.chapter == .plan || task.chapter == .prepare) && task.kind != .auto {
            manager.setTaskState(.done, taskId: task.id, threadId: thread.id)
        }
        let after = manager.thread(withId: thread.id)
        let progress = after?.preFlightProgress
        XCTAssertEqual(after?.state, progress.map { $0.done >= $0.total } == true ? .ready : .planned,
                       "READY exactly when the ring is full (\(String(describing: progress)))")
    }

    // MARK: - Briefing by country (6.5.0)

    /// A registry like the server's, three countries: Switzerland's DABS by day, France's pages behind a free
    /// account, Italy's airspace from the EAUP (a general page) and no NOTAM page, Sweden's plan activated by the
    /// pilot, Belarus closed.
    private let registry: BriefingRegistry = {
        typealias Link = BriefingRegistry.Link
        func url(_ s: String) -> URL { URL(string: s)! }
        let dabs = Link(name: "DABS", url: url("https://www.skybriefing.com/o/dabs?today"),
                        byDay: .init(tomorrow: url("https://www.skybriefing.com/o/dabs?tomorrow"), from: "16:00", tz: "Europe/Zurich"))
        let eaup = Link(name: "EUROCONTROL EAUP", url: url("https://www.public.nm.eurocontrol.int/PUBPORTAL/gateway/spec/index.html"))
        return BriefingRegistry(countries: [
            "CH": .init(weather: [Link(name: "skybriefing", url: url("https://www.skybriefing.com/services/weather-briefing"), access: .paid),
                                  Link(name: "MeteoSwiss", url: url("https://www.meteoswiss.admin.ch/aviation"),
                                       names: ["fr": "MétéoSuisse", "de": "MeteoSchweiz"])],
                        notam: [Link(name: "skybriefing", url: url("https://www.skybriefing.com/services/notam-briefing"), access: .paid)],
                        airspace: [dabs],
                        forecast: [Link(name: "MeteoSwiss", url: url("https://www.meteoswiss.admin.ch/aviation"))],
                        filing: [Link(name: "skybriefing", url: url("https://www.skybriefing.com/services/flightplan-services"), access: .paid)]),
            "FR": .init(weather: [Link(name: "Aéroweb (Météo-France)", url: url("https://aviation.meteo.fr"), access: .account)],
                        notam: [Link(name: "SOFIA-Briefing (DGAC)", url: url("https://sofia-briefing.aviation-civile.gouv.fr"))],
                        airspace: [Link(name: "SIA AZBA", url: url("https://www.sia.aviation-civile.gouv.fr/azba"))],
                        forecast: [Link(name: "Aéroweb (Météo-France)", url: url("https://aviation.meteo.fr"), access: .account)],
                        filing: [Link(name: "SOFIA-Briefing (DGAC)", url: url("https://sofia-briefing.aviation-civile.gouv.fr"), access: .account)]),
            "IT": .init(weather: [Link(name: "MeteoAM", url: url("https://www.meteoam.it/aero"))],
                        airspace: [eaup], generic: ["airspace"]),
            "SE": .init(filing: [Link(name: "AROWeb (LFV)", url: url("https://aro.lfv.se"), access: .account)], activation: "no-ats"),
            "BY": .init(prohibited: Link(name: "EASA SD-2021-02", url: url("https://ad.easa.europa.eu/ad/SD-2021-02"))),
        ])
    }()

    /// Airspace activity and the area forecast, one task per country that publishes them, on the keys they had as
    /// Swiss tasks: Switzerland's without a subject (as before, so a tick carries over and a 6.4 build adds no
    /// twin), another country's with its code. Weather and NOTAMs stay one task each. (q2)
    func testAirspaceAndForecastAreOneTaskPerCountryThatPublishesThem() {
        var c = context(countries: ["CH", "FR", "IT", "AT"])
        c.registry = registry
        let tasks = ThreadTaskEngine.generate(context: c)
        XCTAssertEqual(tasks.filter { $0.key == .dabsChecked }.map(\.subject), [nil, "FR", "IT"], "AT isn't in this registry")
        XCTAssertEqual(tasks.filter { $0.key == .gaforChecked }.map(\.subject), [nil, "FR"], "Italy publishes no forecast here")
        XCTAssertEqual(tasks.filter { $0.key == .weatherBriefed }.count, 1)
        XCTAssertEqual(tasks.filter { $0.key == .notamChecked }.count, 1)
        // Prepare's order, as the decision's mockup: weather, NOTAMs, airspace by country, forecast by country, filing.
        let prepare = tasks.filter { $0.chapter == .prepare }.map(\.key)
        XCTAssertEqual(Array(prepare.prefix(7)), [.weatherBriefed, .notamChecked, .dabsChecked, .dabsChecked, .dabsChecked,
                                                  .gaforChecked, .gaforChecked])
        // A Swiss tick from 6.4 carries over.
        var ticked = ThreadTask(key: .dabsChecked, kind: .check)
        ticked.state = .done
        let again = ThreadTaskEngine.generate(context: c, existing: [ticked])
        XCTAssertEqual(again.first { $0.key == .dabsChecked && $0.subject == nil }?.state, .done)
        XCTAssertEqual(again.first { $0.key == .dabsChecked && $0.subject == "FR" }?.state, .pending)
        // A local flight: its country's airspace activity alone.
        var local = context(profile: .local, countries: ["FR"])
        local.registry = registry
        XCTAssertEqual(ThreadTaskEngine.generate(context: local).filter { $0.key == .dabsChecked }.map(\.subject), ["FR"])
    }

    func testTheBriefingTasksAreTitledByTheirCountry() {
        var fr = ThreadTask(key: .dabsChecked, kind: .check)
        fr.subject = "FR"
        XCTAssertEqual(ThreadTaskPresentation.make(for: fr).title, L10n.Thread.taskAirspace("FR"))
        XCTAssertEqual(ThreadTaskPresentation.make(for: ThreadTask(key: .gaforChecked, kind: .check)).title,
                       L10n.Thread.taskForecast("CH"))
        XCTAssertTrue(L10n.Thread.taskAirspace("FR").hasSuffix("FR"))
    }

    /// Weather and NOTAMs: a chip per country's page, the departure's first, a page two countries share once;
    /// under a name, what it takes in words. (q2)
    func testWeatherAndNotamsLinkEachCountrysPages() {
        let briefing = ThreadBriefing(registry: registry, countries: ["CH", "FR", "IT"], departureCountry: "CH", language: "en")
        let weather = ThreadTaskPresentation.links(for: ThreadTask(key: .weatherBriefed, kind: .check), briefing: briefing)
        XCTAssertEqual(weather.map(\.label), ["skybriefing", "MeteoSwiss", "Aéroweb (Météo-France)", "MeteoAM"])
        XCTAssertEqual(weather.map(\.detail), [L10n.Thread.accessPaid, nil, L10n.Thread.accessAccount, nil])
        let notam = ThreadTaskPresentation.links(for: ThreadTask(key: .notamChecked, kind: .check), briefing: briefing)
        XCTAssertEqual(notam.map(\.label), ["skybriefing", "SOFIA-Briefing (DGAC)"], "Italy has no NOTAM page here: no chip")
        // The publisher's own name in the app's language.
        let german = ThreadBriefing(registry: registry, countries: ["CH"], language: "de")
        XCTAssertEqual(german.links(.weather, in: ["CH"]).last?.label, "MeteoSchweiz")
        // A general page says so.
        var italy = ThreadTask(key: .dabsChecked, kind: .check)
        italy.subject = "IT"
        XCTAssertEqual(ThreadTaskPresentation.links(for: italy, briefing: briefing).map(\.detail), [L10n.Thread.linkGeneral])
        // No registry, no links: never a guess.
        XCTAssertTrue(ThreadTaskPresentation.links(for: ThreadTask(key: .weatherBriefed, kind: .check)).isEmpty)
    }

    /// Filing opens the departure country's portal, wherever the flight goes. (q2)
    func testFilingOpensTheDeparturesPortal() {
        let filed = ThreadTask(key: .flightPlanFiled, kind: .check)
        let fromFrance = ThreadBriefing(registry: registry, countries: ["FR", "CH"], departureCountry: "FR", language: "en")
        XCTAssertEqual(ThreadTaskPresentation.links(for: filed, briefing: fromFrance).map(\.label), ["SOFIA-Briefing (DGAC)"])
        let fromSwitzerland = ThreadBriefing(registry: registry, countries: ["CH", "FR"], departureCountry: "CH", language: "en")
        XCTAssertEqual(ThreadTaskPresentation.links(for: filed, briefing: fromSwitzerland).map(\.label), ["skybriefing"])
    }

    /// The DABS by the flight's day, in plain words (the author's v65-2, 22 Oct 2026): the link opens the flight's day
    /// once it is out (16:00 in Zurich, the day before) and isn't there before; the hint says which day's it opens, or
    /// when the flight's comes out. (decided with the registry, 18 Oct)
    func testTheDABSOpensTheFlightsDay() throws {
        var zurich = Calendar(identifier: .gregorian)
        zurich.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Zurich"))
        func at(_ day: Int, _ hour: Int) throws -> Date {
            try XCTUnwrap(zurich.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour)))
        }
        let dabs = ThreadTask(key: .dabsChecked, kind: .check)
        func page(flying day: Date?, now: Date) -> (link: String?, hint: String?) {
            let briefing = ThreadBriefing(registry: registry, countries: ["CH"], flightDay: day, language: "en", now: now)
            return (ThreadTaskPresentation.links(for: dabs, briefing: briefing).first?.url.absoluteString,
                    ThreadTaskPresentation.make(for: dabs, briefing: briefing).hint)
        }
        let four = ThreadBriefing.localTime("16:00", tz: "Europe/Zurich")
        // Today's flight: today's DABS, and nothing about tomorrow's.
        let today = page(flying: try at(22, 15), now: try at(22, 12))
        XCTAssertEqual(today.link, "https://www.skybriefing.com/o/dabs?today")
        XCTAssertEqual(today.hint, L10n.Thread.byDayToday("DABS"))
        XCTAssertEqual(page(flying: nil, now: try at(22, 12)).hint, L10n.Thread.byDayToday("DABS"), "no day: today's")
        // Tomorrow's, at noon: not out yet, so no link (today's isn't the flight's), and when it comes.
        let noon = page(flying: try at(23, 10), now: try at(22, 12))
        XCTAssertNil(noon.link)
        XCTAssertEqual(noon.hint, L10n.Thread.byDayLaterToday("DABS", at: four))
        // Tomorrow's, in the evening: out.
        let evening = page(flying: try at(23, 10), now: try at(22, 17))
        XCTAssertEqual(evening.link, "https://www.skybriefing.com/o/dabs?tomorrow")
        XCTAssertEqual(evening.hint, L10n.Thread.byDayTomorrow("DABS"))
        // Saturday's, on Thursday: out on Friday at four.
        let saturday = page(flying: try at(24, 10), now: try at(22, 17))
        XCTAssertNil(saturday.link)
        let words = try XCTUnwrap(saturday.hint)
        XCTAssertTrue(words.contains("Saturday") && words.contains("Friday") && words.contains(four), words)
    }

    /// The weather block's pages: each country's weather, then its area forecast, a page once with what it gives, and
    /// its country named on a route through several. (the author's v65-1, 22 Oct 2026)
    func testTheWeatherBlockListsEachCountrysPagesOnce() {
        let briefing = ThreadBriefing(registry: registry, countries: ["CH", "FR"], departureCountry: "CH", language: "en")
        let links = briefing.weatherLinks()
        let both = "\(L10n.Thread.linkWeather) · \(L10n.Thread.linkForecast)"
        XCTAssertEqual(links.map(\.label), ["skybriefing", "MeteoSwiss", "Aéroweb (Météo-France)"])
        XCTAssertEqual(links.map(\.purpose), [L10n.Thread.linkWeather, both, both])
        XCTAssertEqual(links.map(\.country), ["CH", "CH", "FR"])
        XCTAssertEqual(links.map(\.detail), [L10n.Thread.accessPaid, nil, L10n.Thread.accessAccount])
        XCTAssertNil(ThreadBriefing(registry: registry, countries: ["CH"], language: "en").weatherLinks().first?.country,
                     "one country: whose goes without saying")
        XCTAssertTrue(ThreadBriefing(countries: ["CH"]).weatherLinks().isEmpty, "no registry, no links")
    }

    /// The weather block's one tick: "Weather briefed" and every area forecast at once. A forecast marked not applicable
    /// stays so; the whole block marked not applicable, then ticked, comes back whole. (the author's v65-1, q4)
    @MainActor
    func testTheWeatherBlockTicksAsOne() throws {
        let manager = makeTestThreadManager()
        let thread = manager.createThread(from: swissPlan(), profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }
        let index = try XCTUnwrap(manager.threads.firstIndex { $0.id == thread.id })
        var france = ThreadTask(key: .gaforChecked, kind: .check)
        france.subject = "FR"
        manager.threads[index].tasks.append(france)
        func block() -> [ThreadTask] { manager.thread(withId: thread.id)?.tasks.filter { $0.key.isWeatherBlock } ?? [] }
        XCTAssertGreaterThanOrEqual(block().count, 2)

        manager.setWeatherState(.done, threadId: thread.id)
        XCTAssertTrue(block().allSatisfy { $0.state == .done && $0.completedAt != nil })
        XCTAssertEqual(manager.thread(withId: thread.id)?.tasks.first { $0.key == .notamChecked }?.state, .pending,
                       "the weather's tick, not the NOTAMs'")

        manager.setTaskState(.notApplicable, taskId: france.id, threadId: thread.id)
        manager.setWeatherState(.pending, threadId: thread.id)
        XCTAssertEqual(block().first { $0.id == france.id }?.state, .notApplicable)
        XCTAssertTrue(block().filter { $0.id != france.id }.allSatisfy { $0.state == .pending })

        manager.setWeatherState(.notApplicable, threadId: thread.id)
        XCTAssertTrue(block().allSatisfy { $0.state == .notApplicable })
        manager.setWeatherState(.done, threadId: thread.id)
        XCTAssertTrue(block().allSatisfy { $0.state == .done })
    }

    /// A plan from a field without ATS, where the country wants the pilot to activate it: the line, from the
    /// field's frequencies; never for a field the data doesn't know. (q4)
    func testAPlanFromAFieldWithoutATSIsActivatedByThePilot() {
        let sweden = registry.country("SE")
        XCTAssertTrue(ThreadBriefing.needsActivation(country: sweden, fieldKnown: true, frequencyTypes: ["A/G", "CTAF"]))
        XCTAssertTrue(ThreadBriefing.needsActivation(country: sweden, fieldKnown: true, frequencyTypes: []))
        XCTAssertFalse(ThreadBriefing.needsActivation(country: sweden, fieldKnown: true, frequencyTypes: ["TWR", "GND"]))
        XCTAssertFalse(ThreadBriefing.needsActivation(country: sweden, fieldKnown: true, frequencyTypes: ["AFIS"]))
        XCTAssertFalse(ThreadBriefing.needsActivation(country: sweden, fieldKnown: false, frequencyTypes: []))
        XCTAssertFalse(ThreadBriefing.needsActivation(country: registry.country("FR"), fieldKnown: true, frequencyTypes: []))
        XCTAssertTrue(L10n.Thread.activateWithoutATS("ESKT").hasPrefix("ESKT"))
    }

    // MARK: - Closing the plan by country (6.5.0)

    /// The close-out kinds the registry has: an alerting delay (CH), a deadline (SE), neither (DE, with only a
    /// controlled aerodrome closing it), an aerodrome's own number (Spain), nothing checked (Italy).
    private let closing: BriefingRegistry = {
        typealias Phone = BriefingRegistry.Phone
        var ch = BriefingRegistry.Country()
        ch.closing = .init(phones: [Phone(number: "+41800437837", name: "skyguide ARO")], alertMinutes: 30, atsClose: .sera,
                           links: [.init(name: "Swiss SAR Alerts (FOCA)", url: URL(string: "https://apps.apple.com/ch/app/id1496031677")!)])
        var se = BriefingRegistry.Country()
        se.closing = .init(phones: [Phone(number: "+46858554505", name: "Stockholm ACC"), Phone(number: "+4640613350", name: "Malmö ACC")],
                           reportMinutes: 30, atsClose: .sera)
        var de = BriefingRegistry.Country()
        de.closing = .init(phones: [Phone(number: "+4961037075500", name: "AIS-C (DFS)")], atsClose: .controlled)
        var es = BriefingRegistry.Country()
        es.closing = .init(atsClose: .sera, aerodromes: ["LEIG": [Phone(number: "+34918603561", name: "Centralised ARO, area 6")]])
        return BriefingRegistry(countries: ["CH": ch, "SE": se, "DE": de, "ES": es, "IT": .init()])
    }()

    func testTheCloseOutSaysTheRuleOfTheCountryLandedIn() {
        func name(_ code: String) -> String { OpenAIPConfig.countryName(for: code) }
        let ch = CloseOut.make(registry: closing, country: "CH", aerodrome: "LSZQ")
        XCTAssertEqual(ch.rule, L10n.CloseOut.ruleAlert(name("CH"), minutes: 30))
        XCTAssertEqual(ch.phones.map(\.number), ["+41800437837"])
        XCTAssertEqual(ch.atsLine, L10n.CloseOut.atsSera)
        XCTAssertEqual(ch.reminderDelay, 15 * 60, "half the alerting delay")

        let se = CloseOut.make(registry: closing, country: "SE", aerodrome: "ESKT")
        XCTAssertEqual(se.rule, L10n.CloseOut.ruleReport(name("SE"), minutes: 30), "a deadline, not an alerting delay")
        XCTAssertEqual(se.phones.map(\.name), ["Stockholm ACC", "Malmö ACC"])
        XCTAssertEqual(se.reminderDelay, NotificationService.landingDelay)

        let de = CloseOut.make(registry: closing, country: "DE", aerodrome: "EDTF", aerodromeHasTower: false)
        XCTAssertEqual(de.rule, L10n.CloseOut.ruleReportTo(name("DE"), "AIS-C (DFS)"))
        XCTAssertEqual(de.atsLine, "\(L10n.CloseOut.atsControlled) \(L10n.CloseOut.notControlled("EDTF"))")
        XCTAssertEqual(CloseOut.make(registry: closing, country: "DE", aerodrome: "EDNY", aerodromeHasTower: true).atsLine,
                       L10n.CloseOut.atsControlled)

        let es = CloseOut.make(registry: closing, country: "ES", aerodrome: "LEIG")
        XCTAssertEqual(es.phones.map(\.name), ["Centralised ARO, area 6"], "the aerodrome's own ARO")
        XCTAssertEqual(es.rule, L10n.CloseOut.ruleReportTo(name("ES"), "Centralised ARO, area 6"))
        XCTAssertEqual(CloseOut.make(registry: closing, country: "ES", aerodrome: "LEZZ").rule, L10n.CloseOut.ruleUnknown,
                       "a Spanish field the registry has no number for: nothing checked, the rule for everywhere")

        let italy = CloseOut.make(registry: closing, country: "IT", aerodrome: "LIMJ")
        XCTAssertEqual(italy.rule, L10n.CloseOut.ruleUnknown)
        XCTAssertTrue(italy.phones.isEmpty, "never another country's number")
        XCTAssertEqual(CloseOut.make(registry: nil, country: "CH", aerodrome: "LSZQ").rule, L10n.CloseOut.ruleUnknown)
    }

    /// The country landed in: the diversion's after a diversion, else the route's end; a thread from before 6.5.0
    /// reads its arrival from its label. The task and the red card call its numbers.
    func testTheCloseOutFollowsWhereTheFlightLanded() {
        var thread = FlightThread(routeLabel: "LSZQ → LSGS")
        thread.arrivalIdent = "LSGS"
        thread.arrivalCountry = "CH"
        XCTAssertEqual(FlightThreadManager.closeOut(for: thread, registry: closing).country, "CH")
        thread.landedElsewhere = LandedElsewhere(plannedIdent: "LSGS", landedIdent: "EDTF", landedName: "Freiburg")
        let diverted = FlightThreadManager.closeOut(for: thread, registry: closing) { _ in false }
        XCTAssertEqual(diverted.country, "DE")
        XCTAssertEqual(diverted.aerodrome, "EDTF")
        XCTAssertEqual(diverted.aerodromeHasTower, false)

        let old = FlightThread(routeLabel: "LSGS → LSZQ")
        XCTAssertEqual(FlightThreadManager.closeOut(for: old, registry: closing).aerodrome, "LSZQ")
        XCTAssertEqual(FlightThreadManager.closeOut(for: old, registry: closing).country, "CH")
        XCTAssertNil(FlightThreadManager.arrival(inLabel: "Rhine valley"))

        let briefing = ThreadBriefing(registry: closing, language: "en",
                                      closeOut: CloseOut.make(registry: closing, country: "CH", aerodrome: "LSZQ"))
        let links = ThreadTaskPresentation.links(for: ThreadTask(key: .flightPlanClosed, kind: .reminder), briefing: briefing)
        XCTAssertEqual(links.map(\.url.absoluteString), ["tel:+41800437837", "https://apps.apple.com/ch/app/id1496031677"])
        XCTAssertEqual(links.first?.label, L10n.CloseOut.call("skyguide ARO"))
        XCTAssertEqual(ThreadTaskPresentation.make(for: ThreadTask(key: .flightPlanClosed, kind: .reminder), briefing: briefing).hint,
                       briefing.closeOut?.rule)
    }

    /// A route through a closed country: its row, with the directive; nothing else changes. (q5)
    func testAProhibitedCountryOnTheRouteIsNamed() {
        let briefing = ThreadBriefing(registry: registry, countries: ["PL", "BY"])
        XCTAssertEqual(briefing.prohibited.map(\.country), ["BY"])
        XCTAssertEqual(briefing.prohibited.first?.directive.name, "EASA SD-2021-02")
        XCTAssertTrue(ThreadBriefing(registry: registry, countries: ["CH", "FR"]).prohibited.isEmpty)
    }

    /// The Settings row has its page's name: the page holds the pilot, the home aerodrome and the cost, not
    /// only the planning. (6.4.0)
    func testTheFlightsSettingsRowIsNamedAsItsPage() {
        XCTAssertEqual(SettingsView.Section.flightPlanning.title, L10n.Flights.title)
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

    /// The flight page's gold NEXT card and its red open-plan card both said "close the flight plan".
    /// While the red card is up it carries that task, so NEXT moves on to the one after it.
    func testTheNextCardLeavesAnOpenFlightPlanToTheRedCard() {
        var thread = FlightThread(routeLabel: "LSZQ → LSGY")
        var c = context()
        c.flightPlanFiled = true
        c.feeIdents = ["LSGY"]
        thread.tasks = ThreadTaskEngine.generate(context: c)
        // Settle everything before the flight, the filing included.
        for task in thread.tasks where task.chapter != .close {
            thread.setState(.done, forTaskWithId: task.id)
        }
        thread.state = .closeOut

        XCTAssertTrue(thread.hasOpenFlightPlanAfterFlight)
        XCTAssertEqual(thread.nextTask?.key, .flightPlanClosed, "Home has no red card, so it still leads with it")
        XCTAssertEqual(thread.nextTaskBesideOpenFlightPlan?.key, .feesPaid)

        // Only the plan left: the red card is the page's next task, and NEXT has nothing to add.
        for task in thread.tasks where task.chapter == .close && task.key != .flightPlanClosed {
            thread.setState(.done, forTaskWithId: task.id)
        }
        XCTAssertNil(thread.nextTaskBesideOpenFlightPlan)

        // Finished with the plan still open: no red card any more, so NEXT must say it.
        thread.state = .done
        XCTAssertFalse(thread.hasOpenFlightPlanAfterFlight)
        XCTAssertEqual(thread.nextTaskBesideOpenFlightPlan?.key, .flightPlanClosed)
    }

    // MARK: - Files written by older builds

    /// Encoded and decoded as `DataPersistenceManager` does (ISO 8601 dates).
    private func encoded(_ thread: FlightThread) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(thread)) as? [String: Any])
    }

    private func decoded(_ json: [String: Any]) throws -> FlightThread {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FlightThread.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// Every field away from its default, with whole-second dates (ISO 8601 drops the fraction).
    private func populatedThread() -> FlightThread {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var task = ThreadTask(key: .weatherBriefed, subject: "CH", kind: .check)
        task.state = .done
        task.completedAt = date
        task.note = "GAFOR 0700"
        task.detail = "VFR"
        task.isUrgent = true
        task.acknowledgedLegIds = [UUID()]
        var thread = FlightThread(routeLabel: "LSZQ → LSZE")
        thread.flightPlanId = UUID()
        thread.flightId = UUID()
        thread.profile = .local
        thread.state = .closeOut
        thread.name = "Alps, home"
        thread.aircraftRegistration = "HB-KFD"
        thread.scheduledDeparture = date
        thread.countries = ["CH", "FR"]
        thread.tripId = UUID()
        thread.landedElsewhere = LandedElsewhere(plannedIdent: "LSZE", landedIdent: "LSZS", landedName: "Samedan")
        thread.skippedStop = SkippedStop(ident: "LSGE", filedPlanToCancel: "LSGE → LSGN")
        thread.homeCountry = "CH"
        thread.arrivalIdent = "LSZE"
        thread.arrivalCountry = "CH"
        thread.tasks = [task]
        thread.flightPlanFiledAt = date
        thread.flightPlanClosedAt = date.addingTimeInterval(3600)
        thread.createdAt = date
        thread.updatedAt = date.addingTimeInterval(60)
        return thread
    }

    /// Four threads written on 6 Sep 2026 stopped loading: their tasks predate `acknowledgedLegIds`,
    /// which the synthesised decoder required ("The data couldn't be read because it is missing").
    func testAThreadWrittenBeforeAcknowledgedLegIdsLoads() throws {
        let thread = populatedThread()
        var json = try encoded(thread)
        json["tasks"] = (json["tasks"] as? [[String: Any]])?.map { task in
            var task = task
            task.removeValue(forKey: "acknowledgedLegIds")
            return task
        }
        for key in ["name", "tripId", "landedElsewhere", "countries", "homeCountry"] {
            json.removeValue(forKey: key)
        }

        let loaded = try decoded(json)

        XCTAssertEqual(loaded.id, thread.id)
        XCTAssertEqual(loaded.tasks.count, 1)
        XCTAssertEqual(loaded.tasks.first?.state, .done)
        XCTAssertEqual(loaded.tasks.first?.acknowledgedLegIds, [])
        XCTAssertNil(loaded.tripId)
    }

    /// Only what a thread and a task can't exist without is required: a field added later decodes as
    /// its default from a file that lacks it.
    func testOnlyARouteLabelAndEachTasksKeyAndKindAreRequired() throws {
        let loaded = try decoded(["routeLabel": "LSZQ → LSGY",
                                  "tasks": [["key": ThreadTaskKey.fuelPlanned.rawValue,
                                             "kind": ThreadTaskKind.auto.rawValue]]])

        XCTAssertEqual(loaded.routeLabel, "LSZQ → LSGY")
        XCTAssertEqual(loaded.profile, .full)
        XCTAssertEqual(loaded.state, .planned)
        XCTAssertEqual(loaded.tasks.first?.key, .fuelPlanned)
        XCTAssertEqual(loaded.tasks.first?.state, .pending)
        XCTAssertEqual(loaded.tasks.first?.isUrgent, false)
        XCTAssertEqual(loaded.updatedAt, loaded.createdAt, "an undated file is as old as it is")

        XCTAssertThrowsError(try decoded(["tasks": []]), "a thread without its route label")
    }

    func testEveryFieldSurvivesARoundTrip() throws {
        let thread = populatedThread()

        XCTAssertEqual(try decoded(encoded(thread)), thread)
    }

    /// The decoders are written by hand: a stored property they don't read decodes as its default,
    /// silently. A new one fails here until it is read in `init(from:)` (with `decodeIfPresent`, so
    /// files written before it still load) and listed below.
    func testTheDecodersReadEveryStoredProperty() {
        let threadFields = Set(Mirror(reflecting: populatedThread()).children.compactMap(\.label))
        XCTAssertEqual(threadFields, ["id", "flightPlanId", "flightId", "profile", "state", "routeLabel", "name",
                                      "aircraftRegistration", "scheduledDeparture", "countries", "tripId",
                                      "landedElsewhere", "skippedStop", "homeCountry", "arrivalIdent", "arrivalCountry", "tasks",
                                      "flightPlanFiledAt",
                                      "flightPlanClosedAt", "createdAt", "updatedAt"])
        let taskFields = Set(Mirror(reflecting: ThreadTask(key: .routePlanned, kind: .check)).children.compactMap(\.label))
        XCTAssertEqual(taskFields, ["id", "key", "subject", "kind", "state", "completedAt", "note", "detail",
                                    "isUrgent", "acknowledgedLegIds"])
    }

    /// A device still on an older build reads what a newer one wrote to the shared iCloud datastore. A task key it
    /// doesn't know made `ThreadTask.init(from:)` throw, the whole thread failed, and a thread that fails is not
    /// shown at all. Now the task is skipped and the thread stays, for a thread and for a trip's shared tasks. (6.5.0)
    func testATaskThisBuildCannotReadIsSkippedNotItsThread() throws {
        var json = try encoded(populatedThread())
        var tasks = try XCTUnwrap(json["tasks"] as? [[String: Any]])
        let kept = tasks.count
        var future = try XCTUnwrap(tasks.first)
        future["key"] = "prepare.somethingNewer"
        future["id"] = UUID().uuidString
        tasks.insert(future, at: 0)
        json["tasks"] = tasks
        let thread = try decoded(json)
        XCTAssertEqual(thread.tasks.count, kept, "every task but the unknown one")
        XCTAssertEqual(thread.routeLabel, populatedThread().routeLabel)

        let trip = Trip(legIds: [UUID(), UUID()], sharedTasks: [ThreadTask(key: .notamChecked, kind: .check)])
        var tripJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trip)) as? [String: Any])
        var shared = try XCTUnwrap(tripJSON["sharedTasks"] as? [[String: Any]])
        var newer = try XCTUnwrap(shared.first)
        newer["key"] = "prepare.somethingNewer"
        shared.append(newer)
        tripJSON["sharedTasks"] = shared
        let read = try JSONDecoder().decode(Trip.self, from: JSONSerialization.data(withJSONObject: tripJSON))
        XCTAssertEqual(read.sharedTasks.map(\.key), [.notamChecked])
        XCTAssertEqual(read.legIds, trip.legIds)
        XCTAssertEqual(try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(trip)), trip, "a round trip unchanged")
        let tripFields = Set(Mirror(reflecting: trip).children.compactMap(\.label))
        XCTAssertEqual(tripFields, ["id", "legIds", "name", "sharedTasks", "createdAt", "updatedAt", "scheduledStart"],
                       "a new trip field is read in Trip's init(from:) too")
    }

    /// An aerodrome's country comes from its ICAO code: the boundary polygons put Bressaucourt in Switzerland and
    /// France, and the route's countries (alphabetical, widened by 10 NM) gave Basel-Mulhouse to Switzerland. (6.5.0)
    func testAnAerodromesCountryComesFromItsICAOCode() {
        let expected = ["LSZQ": "CH", "LFSB": "FR", "EDTF": "DE", "ETSN": "DE", "LOWS": "AT", "EGNS": "IM", "EGKA": "GB",
                        "EKVG": "FO", "EKRK": "DK", "BIRK": "IS", "LEIG": "ES", "GCLP": "ES", "LYPG": "ME", "LYBE": "RS",
                        "UMMS": "BY", "KPAO": "US", "PANC": "US", "YSSY": "AU", "NZAA": "NZ", "CYUL": "CA"]
        for (ident, country) in expected {
            XCTAssertEqual(ICAOCountry.country(of: ident), country, ident)
        }
        XCTAssertNil(ICAOCountry.country(of: "JORAT VOR"))
        XCTAssertNil(ICAOCountry.country(of: "1N7"), "a US location identifier without an ICAO code")
        XCTAssertNil(ICAOCountry.country(of: nil))
        XCTAssertEqual(ICAOCountry.country(of: " lfsb "), "FR")
    }

    @MainActor
    func testADepartureNearABorderIsInItsOwnCountry() {
        var plan = FlightPlan(name: "Basel")
        plan.waypoints = [waypoint("LSZQ", lat: 47.4489, lon: 7.1003), waypoint("LFSB", lat: 47.5896, lon: 7.5299)]
        XCTAssertEqual(FlightThreadManager.departureCountry(of: plan), "CH")
        XCTAssertEqual(FlightThreadManager.arrivalCountry(of: plan), "FR")
        let c = FlightThreadManager.context(for: plan, profile: .full)
        XCTAssertEqual(c.homeCountry, "CH")
        XCTAssertEqual(c.departureCountry, "CH")
        XCTAssertEqual(c.arrivalCountry, "FR")
        XCTAssertEqual(c.countries.first, "CH", "the departure's country first")
        XCTAssertTrue(c.countries.contains("FR"))
        // A waypoint that is no aerodrome falls back to the polygon it lies in.
        XCTAssertEqual(FlightThreadManager.aerodromeCountry(ident: "JORAT VOR", latitude: 46.58, longitude: 6.71), "CH")
        XCTAssertEqual(FlightThreadManager.ordered(["CH", "DE", "FR"], departure: "FR", arrival: "IT"), ["FR", "CH", "DE", "IT"])
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
        let manager = makeTestThreadManager()
        let thread = manager.createThread(from: swissPlan(), profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        XCTAssertEqual(manager.currentThreadId, thread.id)
        XCTAssertFalse(thread.tasks.isEmpty)
        XCTAssertEqual(thread.routeLabel, "LSZQ → LSGY")
    }

    @MainActor
    func testCloseOutRaisesTheOpenFlightPlanNoticeOnlyWhenOneWasFiled() {
        let manager = makeTestThreadManager()
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

    // MARK: - Regeneration from the plan (v5.x)

    /// The defect this guards: `regenerateTasks` had NO callers, so the AUTO rows kept the values
    /// they were generated with. A flight created before the tanks were entered showed REQ 0 / FOB 0
    /// for ever and never ticked its own fuel row.
    @MainActor
    func testFuelRowFollowsThePlanAfterTheTanksAreEntered() {
        let manager = makeTestThreadManager()
        // A flight created before any fuel figures exist — which is the normal case, since the
        // creation sheet asks for a route and a time, not for tanks.
        var plan = swissPlan()
        plan.tripFuel = nil
        plan.fuelOnBoard = nil
        let thread = manager.createThread(from: plan, profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        let before = manager.thread(withId: thread.id)?.tasks.first { $0.key == .fuelPlanned }
        XCTAssertEqual(before?.state, .pending, "no figures yet, so nothing to claim")
        XCTAssertNil(before?.detail, "and nothing to state either")

        // fuelRequired is computed: trip + reserve + additional + extra.
        plan.tripFuel = 40
        plan.reserveFuel = 10
        plan.additionalFuel = 10
        plan.extraFuel = 0
        plan.fuelOnBoard = 80
        manager.regenerateTasks(threadId: thread.id, plan: plan)

        let after = manager.thread(withId: thread.id)?.tasks.first { $0.key == .fuelPlanned }
        XCTAssertEqual(after?.state, .done, "enough on board — the AUTO row settles itself")
        XCTAssertEqual(after?.detail, "REQ 60 L · FOB 80 L")
    }

    @MainActor
    func testNotEnoughFuelLeavesTheRowPendingRatherThanTicked() {
        let manager = makeTestThreadManager()
        var plan = swissPlan()
        let thread = manager.createThread(from: plan, profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        plan.tripFuel = 60
        plan.reserveFuel = 15
        plan.additionalFuel = 15
        plan.extraFuel = 0
        plan.fuelOnBoard = 40
        manager.regenerateTasks(threadId: thread.id, plan: plan)

        let row = manager.thread(withId: thread.id)?.tasks.first { $0.key == .fuelPlanned }
        XCTAssertEqual(row?.state, .pending)
        XCTAssertEqual(row?.detail, "REQ 90 L · FOB 40 L")
    }

    /// `weatherSummary` and `pprIdents` used to default to nil/empty, so a caller that did not know
    /// to pass them erased the pilot's own briefing text. Regeneration must never lose work.
    @MainActor
    func testRegenerationKeepsTicksAndTheBriefingItWasGiven() {
        let manager = makeTestThreadManager()
        let plan = swissPlan()
        let thread = manager.createThread(from: plan, profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        guard let weather = manager.thread(withId: thread.id)?.tasks.first(where: { $0.key == .weatherBriefed })
        else { return XCTFail("expected a weather task") }
        manager.setTaskState(.done, taskId: weather.id, threadId: thread.id)
        manager.regenerateTasks(threadId: thread.id, plan: plan, weatherSummary: "SW 8 kt, CAVOK")
        manager.regenerateTasks(threadId: thread.id, plan: plan)   // the caller that knows nothing

        let after = manager.thread(withId: thread.id)?.tasks.first { $0.key == .weatherBriefed }
        XCTAssertEqual(after?.state, .done, "a tick survives regeneration")
        XCTAssertEqual(after?.detail, "SW 8 kt, CAVOK", "and so does the briefing it was given")
    }

    /// The stale cached date is what made a flight moved to tomorrow keep being offered as today's.
    @MainActor
    func testTheCachedDepartureFollowsThePlan() {
        let manager = makeTestThreadManager()
        var plan = swissPlan()
        plan.plannedDepartureTime = Date(timeIntervalSince1970: 1_790_000_000)
        let thread = manager.createThread(from: plan, profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        let moved = Date(timeIntervalSince1970: 1_790_500_000)
        plan.plannedDepartureTime = moved
        manager.regenerateTasks(threadId: thread.id, plan: plan)

        XCTAssertEqual(manager.thread(withId: thread.id)?.scheduledDeparture, moved)
    }

    // MARK: - Attaching at flight start (v5.x)

    @MainActor
    func testAttachingResolvesFromTheArmedPlanOrAnExplicitChoice() {
        let manager = makeTestThreadManager()
        let plan = swissPlan()
        let followed = manager.createThread(from: plan, profile: .full)
        defer { manager.deleteThread(threadId: followed.id) }

        // The armed plan names it — this is the Home / widget / deep-link path.
        XCTAssertEqual(manager.threadToAttach(explicitThreadId: nil, planId: plan.id), followed.id)
        // Pressing START FLIGHT inside it names it directly.
        XCTAssertEqual(manager.threadToAttach(explicitThreadId: followed.id, planId: nil), followed.id)
    }

    /// The critical asymmetry with `threadToCloseOut`: attaching states a fact, and once stated the
    /// close-out lookup trusts it absolutely. A guess made here would be cemented, not re-examined.
    @MainActor
    func testAttachingNeverGuessesFromTheCurrentFollowedFlight() {
        let manager = makeTestThreadManager()
        let followed = manager.createThread(from: swissPlan(), profile: .full)
        defer { manager.deleteThread(threadId: followed.id) }

        XCTAssertEqual(manager.currentThreadId, followed.id, "it is current…")
        XCTAssertNil(manager.threadToAttach(explicitThreadId: nil, planId: nil),
                     "…but a flight with no plan and no explicit choice must not claim it")
    }

    @MainActor
    func testAttachingMovesItIntoFlyAndMakesCloseOutExact() {
        let manager = makeTestThreadManager()
        let plan = swissPlan()
        let followed = manager.createThread(from: plan, profile: .full)
        defer { manager.deleteThread(threadId: followed.id) }
        let flightId = UUID()

        manager.attachFlight(flightId, toThreadId: followed.id)

        XCTAssertEqual(manager.thread(withId: followed.id)?.state, .flying)
        XCTAssertEqual(manager.thread(withId: followed.id)?.flightId, flightId)
        // Close-out now resolves on the exact flight, without needing the plan or the fallback.
        XCTAssertEqual(manager.threadToCloseOut(flightId: flightId, planId: nil), followed.id)
    }

    /// A finished flight is not a candidate to fly again.
    @MainActor
    func testAttachingIgnoresAFinishedFollowedFlight() {
        let manager = makeTestThreadManager()
        let followed = manager.createThread(from: swissPlan(), profile: .full)
        defer { manager.deleteThread(threadId: followed.id) }
        manager.finishThread(threadId: followed.id)

        XCTAssertNil(manager.threadToAttach(explicitThreadId: followed.id, planId: nil))
    }

    // MARK: - Circuits and close-out resolution (v5.x)

    /// The regression this guards: circuits are flown with no plan, so END FLIGHT falls through to
    /// "the thread the pilot is currently following" — which, with a cross-country planned for
    /// Saturday, was that thread. A session of touch-and-gos would push it into close-out and raise
    /// its close-your-flight-plan banner for a flight that had not happened.
    @MainActor
    func testCircuitsNeverCloseOutACrossCountryThread() {
        let manager = makeTestThreadManager()
        let planned = manager.createThread(from: swissPlan(), profile: .full)
        defer { manager.deleteThread(threadId: planned.id) }

        XCTAssertNil(manager.threadToCloseOut(flightId: UUID(), planId: nil, isCircuitMode: true))

        // The same flight, NOT flown as circuits, still adopts it — that is the widget/deep-link path.
        XCTAssertEqual(manager.threadToCloseOut(flightId: UUID(), planId: nil, isCircuitMode: false),
                       planned.id)
    }

    /// A planned circuit session IS the flight being flown, so it is still adopted.
    @MainActor
    func testCircuitsDoCloseOutALocalThread() {
        let manager = makeTestThreadManager()
        let local = manager.createThread(from: nil, profile: .local, routeLabel: "Circuits LSZQ")
        defer { manager.deleteThread(threadId: local.id) }

        XCTAssertEqual(manager.threadToCloseOut(flightId: UUID(), planId: nil, isCircuitMode: true),
                       local.id)
    }

    @MainActor
    func testCircuitCloseOutIsOfferedNotCreated() {
        let manager = makeTestThreadManager()
        let flightId = UUID()

        manager.offerCircuitCloseOut(flightId: flightId,
                                     departureIdent: "lszq",
                                     aircraftRegistration: "HB-KFD")

        // An offer changes nothing until it is taken: no thread, nothing current.
        XCTAssertEqual(manager.circuitCloseOutOffer?.flightId, flightId)
        XCTAssertTrue(manager.threads.isEmpty)
        XCTAssertNil(manager.currentThreadId)

        guard let offer = manager.circuitCloseOutOffer else { return XCTFail("expected an offer") }
        let thread = manager.acceptCircuitCloseOut(offer)
        defer { manager.deleteThread(threadId: thread.id) }

        XCTAssertNil(manager.circuitCloseOutOffer)
        XCTAssertEqual(manager.thread(withId: thread.id)?.profile, .local)
        // Straight to CLOSE — the flying already happened.
        XCTAssertEqual(manager.thread(withId: thread.id)?.state, .closeOut)
        XCTAssertEqual(manager.thread(withId: thread.id)?.flightId, flightId)
        XCTAssertTrue(thread.routeLabel.contains("LSZQ"), "ident should be normalised for display")

        // The light profile: a logbook line (the debrief is the flight's notes, optional), and nothing
        // about flight plans or customs.
        let keys = Set(manager.thread(withId: thread.id)?.tasks.map(\.key) ?? [])
        XCTAssertTrue(keys.contains(.logbookEntry))
        XCTAssertFalse(keys.contains(.debriefWritten))
        XCTAssertFalse(keys.contains(.flightPlanFiled))
    }

    /// A circuit session has no filed plan, so accepting the offer must stay silent — the red banner
    /// and the RCC reminder belong to an open flight plan and nothing else.
    @MainActor
    func testAcceptingACircuitCloseOutRaisesNoOpenPlanNotice() {
        let manager = makeTestThreadManager()
        manager.offerCircuitCloseOut(flightId: UUID(), departureIdent: "LSZQ", aircraftRegistration: nil)

        guard let offer = manager.circuitCloseOutOffer else { return XCTFail("expected an offer") }
        let thread = manager.acceptCircuitCloseOut(offer)
        defer { manager.deleteThread(threadId: thread.id) }

        XCTAssertNil(manager.openFlightPlanNotice)
    }

    @MainActor
    func testFilingATaskAddsTheCloseOutTask() {
        let manager = makeTestThreadManager()
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

    /// The merge releases the OpenAIP airport array right after reading it at launch; the fuel row
    /// read that array, so it almost never named the destination's grades. The kept index survives
    /// the release, follows a new download, and goes with a delete. (6.2.0)
    @MainActor
    func testTheDestinationFuelsSurviveTheMergeReleasingTheAirports() async throws {
        var fuelCodes = [1, 3]
        let layer = makeTestOpenAIPAirportLayer { _ in
            let json = """
            {"features":[{"type":"Feature","properties":{
              "_id":"lsgy","name":"YVERDON","icaoCode":"LSGY","type":2,"country":"CH",
              "services":{"fuelTypes":\(fuelCodes)},"frequencies":[],"runways":[]
            },"geometry":{"type":"Point","coordinates":[6.61,46.76]}}]}
            """
            return try OpenAIPAirport.parse(geoJSON: Data(json.utf8))
        }
        let store = makeTestAirportStore(openAIPAirports: layer)
        store.followOpenAIPAirports()
        var plan = FlightPlan(name: "To Yverdon")
        plan.waypoints = [("LSZQ", 7.03), ("LSGY", 6.61)].map {
            FlightPlanWaypoint(name: $0.0, coordinate: .init(latitude: 47.0, longitude: $0.1),
                               altitude: 4000, plannedGroundSpeed: 100)
        }

        await layer.downloadData(for: ["CH"])
        await store.waitForPendingPasses()
        XCTAssertFalse(layer.isLoaded, "the merge released the array")
        XCTAssertTrue(layer.allLoadedAirports().isEmpty)
        XCTAssertEqual(FlightThreadManager.destinationFuels(on: plan, aerodromes: layer), ["AVGAS", "Jet A1"])

        fuelCodes = [6]
        await layer.downloadData(for: ["CH"])
        await store.waitForPendingPasses()
        XCTAssertEqual(FlightThreadManager.destinationFuels(on: plan, aerodromes: layer), ["UL91"])

        layer.deleteData()
        XCTAssertEqual(FlightThreadManager.destinationFuels(on: plan, aerodromes: layer), [])
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
        let manager = makeTestThreadManager()
        let thread = manager.createThread(from: slovakToGermanPlan(), profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        XCTAssertFalse(thread.countries?.contains("CH") ?? true, "got \(thread.countries ?? [])")
        // Since 6.5.0 each country's own airspace activity and forecast, never Switzerland's (no subject).
        XCTAssertNil(thread.tasks.first { $0.key == .dabsChecked && $0.subject == nil }, "DABS is a Swiss product")
        XCTAssertNil(thread.tasks.first { $0.key == .gaforChecked && $0.subject == nil }, "GAFOR is a Swiss product")
    }

    @MainActor
    func testFilingAFlightPlanDoesNotConjureSwitzerlandOntoAForeignRoute() {
        // The reported defect, exactly: the tasks were right until the pilot ticked "flight plan
        // filed", at which point the regeneration rebuilt the country list as home + foreign — with
        // home hard-coded to CH — and DABS, GAFOR and a "Swiss side" link appeared.
        let manager = makeTestThreadManager()
        let thread = manager.createThread(from: slovakToGermanPlan(), profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        guard let filed = thread.tasks.first(where: { $0.key == .flightPlanFiled }) else {
            return XCTFail("no filing task")
        }
        manager.setTaskState(.done, taskId: filed.id, threadId: thread.id)

        let after = manager.thread(withId: thread.id)
        XCTAssertNotNil(after?.tasks.first { $0.key == .flightPlanClosed },
                        "filing should still add the close-out reminder")
        XCTAssertNil(after?.tasks.first { $0.key == .dabsChecked && $0.subject == nil }, "DABS appeared after filing")
        XCTAssertNil(after?.tasks.first { $0.key == .gaforChecked && $0.subject == nil }, "GAFOR appeared after filing")
        XCTAssertEqual(after?.tasks.filter { $0.key == .dabsChecked }.map(\.subject),
                       thread.tasks.filter { $0.key == .dabsChecked }.map(\.subject), "the same countries after filing")
        XCTAssertFalse(after?.countries?.contains("CH") ?? true, "got \(after?.countries ?? [])")
    }

    @MainActor
    func testTheDepartureCountryIsNotTreatedAsForeign() {
        // Departing Slovakia, you do not clear customs INTO Slovakia. With home hard-coded to CH it
        // raised a Slovak customs task on a Slovak departure. Košice to Uzhhorod: Ukraine, outside the EU, is a
        // border; Germany, since 6.6.0, is none from Slovakia.
        var plan = FlightPlan(name: "LZKZ → UKLU")
        plan.waypoints = [waypoint("LZKZ", lat: 48.6631, lon: 21.2411), waypoint("UKLU", lat: 48.6342, lon: 22.2633)]
        let manager = makeTestThreadManager()
        let thread = manager.createThread(from: plan, profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        XCTAssertEqual(thread.homeCountry, "SK", "home should follow the departure aerodrome")
        XCTAssertEqual(thread.borderCountries, ["UA"])
    }

    /// France's facts were checked for flights to or from Switzerland: from the UK its "not required" is wrong, the
    /// préavis catching a flight from outside Schengen. Only the line then, the official link kept. (6.6.0)
    func testTheBorderFactsShowOnlyWhenSwitzerlandIsOneEnd() {
        let france = ThreadTask(key: .customsNotified, subject: "FR", kind: .check)
        let fromSwitzerland = ThreadTaskPresentation.make(for: france, briefing: ThreadBriefing(departureCountry: "CH")).hint ?? ""
        XCTAssertTrue(fromSwitzerland.contains(L10n.Border.priorNotification), fromSwitzerland)

        let fromTheUK = ThreadBriefing(departureCountry: "GB")
        XCTAssertEqual(ThreadTaskPresentation.make(for: france, briefing: fromTheUK).hint, L10n.Border.swissCrossingsOnly)
        XCTAssertTrue(ThreadTaskPresentation.links(for: france, briefing: fromTheUK).contains { $0.label == L10n.Border.openOfficial })

        let britain = ThreadTask(key: .customsNotified, subject: "GB", kind: .check)
        XCTAssertEqual(ThreadTaskPresentation.make(for: britain, briefing: ThreadBriefing(departureCountry: "FR")).hint,
                       L10n.Border.swissCrossingsOnly)
        XCTAssertNotEqual(ThreadTaskPresentation.make(for: britain, briefing: ThreadBriefing(departureCountry: "CH")).hint,
                          L10n.Border.swissCrossingsOnly)
    }

    func testTheSwissLinkIsOnlyOfferedWhenSwitzerlandIsInvolved() {
        let task = ThreadTask(key: .customsNotified, subject: "DE", kind: .check)
        let away = ThreadTaskPresentation.links(for: task, touchesSwitzerland: false)
        XCTAssertFalse(away.contains { $0.label == L10n.Border.swissSide })
        XCTAssertTrue(away.contains { $0.label == L10n.Border.openOfficial })

        let swiss = ThreadTaskPresentation.links(for: task, touchesSwitzerland: true)
        XCTAssertTrue(swiss.contains { $0.label == L10n.Border.swissSide })
    }

    /// The customs task warns exactly when the country's rule has an open question (review F28):
    /// the German customs-airport dispute gets the warning, a settled rule does not.
    func testTheCustomsHintWarnsExactlyWhenTheRuleHasAnOpenQuestion() {
        for code in BorderCrossingGuide.rules.keys.sorted() {
            let rule = try! XCTUnwrap(BorderCrossingGuide.rule(for: code))
            let task = ThreadTask(key: .customsNotified, subject: code, kind: .check)
            let hint = try! XCTUnwrap(ThreadTaskPresentation.make(for: task).hint)
            XCTAssertEqual(hint.contains(L10n.Border.unknownWarning), rule.hasOpenQuestion, "\(code): \(hint)")
        }
        // Both sides of the rule must actually be exercised by the curated data.
        XCTAssertTrue(try! XCTUnwrap(BorderCrossingGuide.rule(for: "DE")).hasOpenQuestion)
        XCTAssertFalse(try! XCTUnwrap(BorderCrossingGuide.rule(for: "FR")).hasOpenQuestion)
    }
}


// MARK: - Cumulative review regressions (v5.0.1)

extension FlightThreadTests {

    @MainActor
    private func datedPlan(_ departure: Date?) -> FlightPlan {
        var plan = FlightPlan(name: "Test")
        plan.waypoints = [
            FlightPlanWaypoint(name: "LSZQ",
                               coordinate: CLLocationCoordinate2D(latitude: 47.4247, longitude: 7.1869),
                               altitude: 3000),
            FlightPlanWaypoint(name: "LSGY",
                               coordinate: CLLocationCoordinate2D(latitude: 46.7619, longitude: 6.6141),
                               altitude: 3000),
        ]
        plan.plannedDepartureTime = departure
        return plan
    }

    /// F2. The `currentThread` fallback cannot see WHICH flight was flown, and had no date check — so
    /// a Thursday evening hop pushed Saturday's cross-country into close-out, complete with its
    /// close-your-flight-plan banner for a flight that had not happened. Guarding only the circuits
    /// case was not enough: Home offers no "not this one" button on a day with no hero flight.
    @MainActor
    func testTheCloseOutFallbackRefusesAThreadScheduledForAnotherDay() {
        let manager = makeTestThreadManager()
        let saturday = manager.createThread(from: datedPlan(Date().addingTimeInterval(2 * 24 * 3600)))
        defer { manager.deleteThread(threadId: saturday.id) }
        manager.setCurrentThread(saturday.id)

        XCTAssertNil(manager.threadToCloseOut(flightId: UUID(), planId: nil,
                                              isCircuitMode: false, isUnplanned: false),
                     "a flight two days out is not the flight that was just flown")
    }

    @MainActor
    func testTheCloseOutFallbackStillAdoptsTodaysFlight() {
        let manager = makeTestThreadManager()
        let today = manager.createThread(from: datedPlan(Date()))
        defer { manager.deleteThread(threadId: today.id) }
        manager.setCurrentThread(today.id)

        XCTAssertEqual(manager.threadToCloseOut(flightId: UUID(), planId: nil), today.id)
    }

    @MainActor
    func testTheCloseOutFallbackStillAdoptsAnUndatedFlight() {
        // No date at all is the widget/deep-link case the fallback exists for; it carries nothing to
        // contradict, so it must stay eligible.
        let manager = makeTestThreadManager()
        let undated = manager.createThread(from: datedPlan(nil))
        defer { manager.deleteThread(threadId: undated.id) }
        manager.setCurrentThread(undated.id)

        XCTAssertEqual(manager.threadToCloseOut(flightId: UUID(), planId: nil), undated.id)
    }

    /// F4. Finishing a thread is optional, so one that already flew and closed out is still
    /// `!isFinished` and `thread(forPlanId:)` hands it back when the pilot re-arms the same saved
    /// route. Carrying the first flight's filing latches into the second made `hasOpenFlightPlan`
    /// false for a plan that was genuinely open — no banner and no reminder on the second flight.
    @MainActor
    func testReFlyingAThreadStartsAFreshCloseChapter() {
        let manager = makeTestThreadManager()
        let thread = manager.createThread(from: swissPlan(), profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        guard let filed = manager.thread(withId: thread.id)?.tasks
            .first(where: { $0.key == .flightPlanFiled }) else {
            return XCTFail("no flight-plan-filed task")
        }
        manager.setTaskState(.done, taskId: filed.id, threadId: thread.id)
        let firstFlight = UUID()
        manager.attachFlight(firstFlight, toThreadId: thread.id)
        manager.beginCloseOut(threadId: thread.id, flightId: firstFlight)
        manager.markFlightPlanClosed(threadId: thread.id)
        XCTAssertFalse(manager.thread(withId: thread.id)?.hasOpenFlightPlan ?? true)

        // Same thread, next weekend, same saved route.
        manager.attachFlight(UUID(), toThreadId: thread.id)

        let after = manager.thread(withId: thread.id)
        XCTAssertNil(after?.flightPlanFiledAt, "the new flight has filed nothing yet")
        XCTAssertNil(after?.flightPlanClosedAt, "and must not inherit the last one's close stamp")
        XCTAssertEqual(after?.tasks.first { $0.key == .flightPlanFiled }?.state, .pending,
                       "the task and the latch must never disagree")
    }

    /// F5. `regenerateAfterFilingChange` never set `isLeg`, so ticking "flight plan filed" on a trip
    /// leg re-created the trip's own rows on it as pending duplicates — dropping a 6/6 leg to 6/11
    /// and diverting START to the outstanding-tasks prompt.
    @MainActor
    func testFilingAPlanOnATripLegDoesNotResurrectTheTripsTasks() {
        let manager = makeTestThreadManager()
        let a = manager.createThread(from: swissPlan(), profile: .full)
        let b = manager.createThread(from: swissPlan(), profile: .full)
        defer { manager.deleteThread(threadId: a.id); manager.deleteThread(threadId: b.id) }
        _ = manager.formTrip(from: [a.id, b.id])

        let before = manager.thread(withId: a.id)?.tasks.count ?? 0
        guard let filed = manager.thread(withId: a.id)?.tasks
            .first(where: { $0.key == .flightPlanFiled }) else {
            return XCTFail("no flight-plan-filed task on the leg")
        }
        manager.setTaskState(.done, taskId: filed.id, threadId: a.id)

        let after = manager.thread(withId: a.id)?.tasks ?? []
        XCTAssertTrue(after.allSatisfy { $0.key.scope == .leg },
                      "a leg must never carry a trip-scoped row — those live on the trip")
        XCTAssertEqual(after.count, before + 1,
                       "filing adds the close-out task and nothing else")
    }

    // MARK: - Starting a flight planned for another day (round 6)

    func testAFlightIsDueOnItsDayOrWhenUndated() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 23, minute: 2))!
        var thread = FlightThread(routeLabel: "LZPE → EDME")

        XCTAssertTrue(thread.isDueToday(now: now, calendar: calendar), "undated: START FLIGHT")
        thread.scheduledDeparture = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 7))
        XCTAssertTrue(thread.isDueToday(now: now, calendar: calendar), "earlier today")
        thread.scheduledDeparture = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 10))
        XCTAssertFalse(thread.isDueToday(now: now, calendar: calendar), "tomorrow at 10:00: Start now, with a question")
        thread.scheduledDeparture = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 10))
        XCTAssertFalse(thread.isDueToday(now: now, calendar: calendar), "yesterday's, not flown")
    }

    // MARK: - Cancel flight takes its own copy of the route (v6.0 review)

    private func threadFlying(_ plan: FlightPlan) -> FlightThread {
        var thread = FlightThread(routeLabel: plan.name)
        thread.flightPlanId = plan.id
        return thread
    }

    func testCancellingAFlightDeletesTheCopyMadeForIt() {
        var copy = swissPlan()
        copy.flightOwned = true
        let thread = threadFlying(copy)
        XCTAssertEqual(FlightThreadManager.planToDelete(withThread: thread.id, threads: [thread],
                                                        plans: [copy], logbookPlanIds: [])?.id, copy.id)
    }

    func testARouteFromTheLibraryIsNeverDeleted() {
        let route = swissPlan()                                   // flightOwned nil: a route
        let thread = threadFlying(route)
        XCTAssertNil(FlightThreadManager.planToDelete(withThread: thread.id, threads: [thread],
                                                      plans: [route], logbookPlanIds: []))
    }

    func testACopyStillUsedElsewhereIsKept() {
        var copy = swissPlan()
        copy.flightOwned = true
        let cancelled = threadFlying(copy)
        let other = threadFlying(copy)
        XCTAssertNil(FlightThreadManager.planToDelete(withThread: cancelled.id, threads: [cancelled, other],
                                                      plans: [copy], logbookPlanIds: []),
                     "another flight follows it")
        XCTAssertNil(FlightThreadManager.planToDelete(withThread: cancelled.id, threads: [cancelled],
                                                      plans: [copy], logbookPlanIds: [copy.id]),
                     "the logbook exports it with its flight")
    }

    // MARK: - Another flight's page while one is flying (6.2.0)
    //
    // The device report: in At the Hangar, "Flight tomorrow" opened, "Start now", confirmed, and the
    // pilot was back on the running flight's Cockpit without a word.

    private func offer(_ thread: FlightThread, canStart: Bool = true, isDue: Bool,
                       running: Flight?) -> ThreadStartOffer {
        ThreadStartOffer.make(for: thread, canStart: canStart, isDue: isDue,
                              isFlightActive: running != nil, runningFlight: running)
    }

    func testAFlightInProgressTakesTheStartButtonsPlaceAndNamesItsAircraft() {
        let tomorrow = FlightThread(routeLabel: "LSZQ → LSGY")
        let running = Flight(aircraftRegistration: "F-HVXA")
        XCTAssertEqual(offer(tomorrow, isDue: false, running: running), .flightInProgress(registration: "F-HVXA"),
                       "no Start now: its question led to a refusal nobody saw")
        XCTAssertEqual(offer(tomorrow, isDue: true, running: running), .flightInProgress(registration: "F-HVXA"),
                       "today's flight neither")
        XCTAssertEqual(offer(tomorrow, isDue: true, running: Flight(aircraftRegistration: " ")),
                       .flightInProgress(registration: nil), "no registration: the note without one")
    }

    func testOnTheGroundItsDayDecidesTheButton() {
        let thread = FlightThread(routeLabel: "LSZQ → LSGY")
        XCTAssertEqual(offer(thread, isDue: true, running: nil), .start)
        XCTAssertEqual(offer(thread, isDue: false, running: nil), .startEarly)
        XCTAssertEqual(offer(thread, canStart: false, isDue: true, running: nil), .none,
                       "a presenter that can't start one (the logbook) offers nothing")
    }

    func testTheRunningFlightsOwnPageOffersNothing() {
        let plan = swissPlan()
        var started = FlightThread(routeLabel: "LSZQ → LSGY")
        started.flightId = UUID()
        XCTAssertEqual(offer(started, isDue: true, running: Flight(id: started.flightId!, aircraftRegistration: "F-HVXA")),
                       .none, "attached at START FLIGHT")
        var armed = FlightThread(routeLabel: "LSZQ → LSGY")
        armed.flightPlanId = plan.id
        XCTAssertEqual(offer(armed, isDue: true, running: Flight(aircraftRegistration: "F-HVXA", flightPlanId: plan.id)),
                       .none, "started from the widget with its route armed: it is the one flying")
    }

    /// A flight started without a page (the widget, no route) closes out the FOLLOWED flight at END
    /// FLIGHT. The reminder used to make tomorrow's flight the followed one, in flight.
    @MainActor
    func testAReminderOpenedInFlightOpensItsPageButKeepsTheFollowedFlight() {
        let manager = makeTestThreadManager()
        let appState = makeTestAppState()
        let today = manager.createThread(from: swissPlan(), profile: .full)
        let tomorrow = manager.createThread(from: swissPlan(), profile: .full)
        defer { manager.deleteThread(threadId: today.id); manager.deleteThread(threadId: tomorrow.id) }
        manager.setCurrentThread(today.id)
        appState.isFlightActive = true
        defer { appState.isFlightActive = false }

        ReminderTap.open(tomorrow.id, appState: appState, threads: manager)

        XCTAssertEqual(appState.pendingThreadToOpen, tomorrow.id, "its page opens, to read")
        XCTAssertEqual(manager.currentThreadId, today.id, "the followed flight is still the one flying")
        XCTAssertEqual(manager.threadToCloseOut(flightId: UUID(), planId: nil), today.id,
                       "END FLIGHT closes out the flight flown")
    }

    @MainActor
    func testAReminderOpenedOnTheGroundFollowsItsFlight() {
        let manager = makeTestThreadManager()
        let appState = makeTestAppState()
        let today = manager.createThread(from: swissPlan(), profile: .full)
        let tomorrow = manager.createThread(from: swissPlan(), profile: .full)
        defer { manager.deleteThread(threadId: today.id); manager.deleteThread(threadId: tomorrow.id) }
        manager.setCurrentThread(today.id)

        ReminderTap.open(tomorrow.id, appState: appState, threads: manager)

        XCTAssertEqual(appState.pendingThreadToOpen, tomorrow.id)
        XCTAssertEqual(manager.currentThreadId, tomorrow.id)
    }
}


// MARK: - Border blocks: where the flight lands (6.6.0)

/// One border block, for the arrival's country (the author's answer, 24 Oct 2026): the route's 10 NM `countries` are
/// the data's margin and stay so. Real coordinates, on the bundled borders.
extension FlightThreadTests {

    private func route(_ points: [(String, Double, Double)]) -> FlightPlan {
        var plan = FlightPlan(name: points.map(\.0).joined(separator: " → "))
        plan.waypoints = points.map { waypoint($0.0, lat: $0.1, lon: $0.2) }
        return plan
    }

    private var bressaucourt: (String, Double, Double) { ("LSZQ", 47.392408, 7.028956) }
    private var toColmar: FlightPlan { route([bressaucourt, ("LFGA", 48.109901, 7.35901)]) }
    private var toFreiburg: FlightPlan { route([bressaucourt, ("EDTF", 48.022778, 7.8325)]) }

    @MainActor
    func testBressaucourtToColmarHasFranceOnly() {
        // West of the Rhine, Germany within 10 NM: it gave a German block.
        let manager = makeTestThreadManager()
        let thread = manager.createThread(from: toColmar, profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        XCTAssertEqual(thread.borderCountries, ["FR"])
        XCTAssertTrue(thread.countries?.contains("DE") ?? false, "the data keeps its margin: \(thread.countries ?? [])")
    }

    @MainActor
    func testBressaucourtToFreiburgHasGermanyOnly() {
        // Over Alsace on the way, landing in Germany: customs follows the landing.
        let manager = makeTestThreadManager()
        let thread = manager.createThread(from: toFreiburg, profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        XCTAssertEqual(thread.borderCountries, ["DE"])
        XCTAssertTrue(thread.countries?.contains("FR") ?? false, "got \(thread.countries ?? [])")
    }

    @MainActor
    func testALocalFlightAtBressaucourtHasNoBorderBlock() {
        // The guided dry run's triangle, 6 NM out with France 3 NM away, gave a French block; circuits there too.
        let manager = makeTestThreadManager()
        let triangle = manager.createThread(from: DryRunChapters.route(from: .lszq), profile: .full)
        let circuits = manager.createThread(from: nil, profile: .local)
        defer { manager.deleteThread(threadId: triangle.id); manager.deleteThread(threadId: circuits.id) }

        XCTAssertEqual(triangle.borderCountries, [])
        XCTAssertTrue(triangle.countries?.contains("FR") ?? false, "got \(triangle.countries ?? [])")
        XCTAssertEqual(circuits.borderCountries, [])
    }

    @MainActor
    func testInsideTheEUAndSchengenThereIsNoBorderBlock() {
        // Freiburg to Colmar, and Basel-Mulhouse (in France) to Freiburg: no customs, no passport control.
        let freiburg = ("EDTF", 48.022778, 7.8325)
        let manager = makeTestThreadManager()
        let colmar = manager.createThread(from: route([freiburg, ("LFGA", 48.109901, 7.35901)]), profile: .full)
        let basel = manager.createThread(from: route([("LFSB", 47.60068, 7.521117), freiburg]), profile: .full)
        let dublin = manager.createThread(from: route([freiburg, ("EIDW", 53.421333, -6.27)]), profile: .full)
        defer { [colmar, basel, dublin].forEach { manager.deleteThread(threadId: $0.id) } }

        XCTAssertEqual(colmar.borderCountries, [])
        XCTAssertEqual(basel.homeCountry, "FR")
        XCTAssertEqual(basel.borderCountries, [])
        XCTAssertEqual(dublin.borderCountries, ["IE"], "Ireland is outside Schengen")
    }

    @MainActor
    func testTheWayHomeHasTheHomeCountrysBlock() {
        let manager = makeTestThreadManager()
        let thread = manager.createThread(from: route([("LFGA", 48.109901, 7.35901), bressaucourt]), profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }

        XCTAssertEqual(thread.homeCountry, "FR")
        XCTAssertEqual(thread.borderCountries, ["CH"])
    }

    @MainActor
    func testFilingTheFlightPlanKeepsTheBorderBlock() throws {
        // Filing rebuilds the tasks without the plan, from what the thread recorded.
        let manager = makeTestThreadManager()
        let thread = manager.createThread(from: toColmar, profile: .full)
        defer { manager.deleteThread(threadId: thread.id) }
        let filed = try XCTUnwrap(thread.tasks.first { $0.key == .flightPlanFiled })

        manager.setTaskState(.done, taskId: filed.id, threadId: thread.id)

        let after = try XCTUnwrap(manager.thread(withId: thread.id))
        XCTAssertTrue(after.tasks.contains { $0.key == .flightPlanClosed }, "the filing went through")
        XCTAssertEqual(after.borderCountries, ["FR"])
    }

    @MainActor
    func testABorderBlockThatNoLongerAppliesGoesTickedOrNot() {
        // A flight to Colmar made before 6.6.0 had a German block too. The next rebuild drops it, ticked as it is,
        // and France keeps its tick.
        var france = ThreadTask(key: .customsNotified, subject: "FR", kind: .check)
        france.state = .done
        var germany = ThreadTask(key: .customsNotified, subject: "DE", kind: .check)
        germany.state = .done
        germany.note = "Called Freiburg"

        let rebuilt = ThreadTaskEngine.generate(context: FlightThreadManager.context(for: toColmar, profile: .full),
                                                existing: [france, germany])

        let customs = rebuilt.filter { $0.key == .customsNotified }
        XCTAssertEqual(customs.map(\.subject), ["FR"])
        XCTAssertEqual(customs.first?.id, france.id)
        XCTAssertEqual(customs.first?.state, .done)
    }
}
