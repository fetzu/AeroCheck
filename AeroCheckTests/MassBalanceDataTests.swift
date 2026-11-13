import XCTest
@testable import AeroCheck

/// Where the mass and balance data comes from and what the app keeps beside it (6.11.0): the revision
/// in the aircraft list, each registration's file fetched and cached, and the pilot's side (the
/// confirmation, a newer empty mass, their own figures, the last load). Every figure is invented.
@MainActor
final class MassBalanceDataTests: XCTestCase {

    typealias Gating = AircraftDataServiceSeamTests.FakeGating
    typealias Routed = AircraftDataServiceSeamTests.RoutedHTTPClient

    // MARK: - Fixtures

    private func file(_ aircraftId: String, _ registration: String, revision: Int = 2, emptyDate: String = "2025-03-10") -> String {
        #"""
        {"schema":1,"aircraftId":"\#(aircraftId)","registration":"\#(registration)","revision":\#(revision),"updated":"2026-01-15",
         "identity":{"designation":"Test Two","serialNumber":"TT-001"},
         "units":{"mass":"kg","arm":"m","fuel":"l"},
         "limits":{"maxTakeoff":600},
         "categories":[{"id":"normal","maxTakeoff":600,"envelope":[[2.70,400],[2.70,540],[2.75,600],[2.85,600],[2.85,460],[2.72,400]]}],
         "stations":[{"id":"row1","kind":"seats","arm":3.10,"layout":"side-by-side",
                      "seats":[{"id":"pilot","role":"pilot"},{"id":"passenger","role":"passenger"}]},
                     {"id":"baggage","kind":"baggage","arm":3.80,"max":40},
                     {"id":"fuel","kind":"fuel","arm":2.50,"usable":90,"density":0.72}],
         "handbookChecks":["takeoff"],
         "empty":{"mass":330,"moment":867.9,"date":"\#(emptyDate)","entry":"weighed"},
         "sources":[{"what":"everything","document":"an invented handbook"}]}
        """#
    }

    private func data(_ json: String) -> AircraftMassBalance {
        try! JSONDecoder().decode(AircraftMassBalance.self, from: Data(json.utf8))
    }

    /// The list: the free two-seater with a file at `free`, and a premium aircraft with two registrations,
    /// the second with a file at `premium`.
    private func list(free: Int?, premium: Int?, hasAccess: Bool = true) -> String {
        let freeRevision = free.map { #","massBalanceRevision":\#($0)"# } ?? ""
        let premiumRevision = premium.map { #","massBalanceRevision":\#($0)"# } ?? ""
        return #"""
        {"success":true,"data":{"aircraft":[
         {"id":"wt9-dynamic","aircraftType":"WT9","registration":"F-HVXA","modelName":"Two","shortModelName":"Two",
          "version":"1.0","lastUpdated":"x","isFree":true,"stallSpeed":40,"pageCount":4,"hasAccess":true\#(freeRevision)},
         {"id":"dr400-140b","aircraftType":"DR400","registration":"HB-KFD","modelName":"Four","shortModelName":"Four",
          "version":"1.0","lastUpdated":"x","isFree":false,"stallSpeed":50,"pageCount":4,"hasAccess":\#(hasAccess),
          "registrations":[
            {"registration":"HB-KFD","modelName":"Four","shortModelName":"Four","version":"1.0","lastUpdated":"x"},
            {"registration":"HB-KFI","modelName":"Four","shortModelName":"Four","version":"1.0","lastUpdated":"x"\#(premiumRevision)}]}]}}
        """#
    }

    /// A service whose server answers the list and each registration's file from `files` (path?reg → body).
    private func service(list: @escaping () -> String, files: @escaping (String) -> (Int, String),
                         gating: Gating? = nil) -> (AircraftDataService, Routed) {
        let http = Routed { request in
            let url = request.url!
            if url.path.hasSuffix("/aircraft/available") { return (200, list()) }
            if url.path.hasSuffix("/mass-balance") {
                let reg = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "reg" }?.value ?? ""
                let (status, body) = files(reg)
                return (status, status == 200 ? #"{"success":true,"data":\#(body)}"# : body)
            }
            return (404, "{}")
        }
        return (makeTestAircraftDataService(subscriptionManager: gating ?? Gating(), httpClient: http), http)
    }

    private func massBalanceRequests(_ http: Routed) -> [String] {
        http.capturedRequests.compactMap { $0.url }.filter { $0.path.hasSuffix("/mass-balance") }.map { $0.path + "?" + ($0.query ?? "") }
    }

    // MARK: - The list

    func testTheRevisionComesWithEachRegistrationOfTheList() async {
        let (service, _) = service(list: { self.list(free: 2, premium: 5) }, files: { _ in (404, "{}") })
        await service.fetchAvailableAircraft()
        XCTAssertEqual(service.aircraft(forRegistration: "f-hvxa")?.massBalanceRevision, 2)
        XCTAssertNil(service.aircraft(forRegistration: "HB-KFD")?.massBalanceRevision, "the first registration has no file")
        XCTAssertEqual(service.aircraft(forRegistration: "HB-KFI")?.massBalanceRevision, 5)
        XCTAssertEqual(service.aircraft(forRegistration: "HB-KFI")?.id, "dr400-140b~HB-KFI")
    }

    // MARK: - The files

    func testAFileIsFetchedOnceForItsRegistrationAndReadFromTheCacheAfterwards() async {
        let (service, http) = service(list: { self.list(free: 2, premium: 5) },
                                      files: { reg in reg == "F-HVXA" ? (200, self.file("wt9-dynamic", "F-HVXA")) : (200, self.file("dr400-140b", "HB-KFI", revision: 5)) })
        await service.fetchAvailableAircraft()

        XCTAssertEqual(Set(massBalanceRequests(http)),
                       ["/api/v3/aircraft/wt9-dynamic/mass-balance?reg=F-HVXA", "/api/v3/aircraft/dr400-140b/mass-balance?reg=HB-KFI"],
                       "the registration is always named, and only registrations with a revision are asked for")
        XCTAssertEqual(service.massBalance(forRegistration: "F-HVXA")?.revision, 2)
        XCTAssertEqual(service.massBalance(forRegistration: "HB-KFI")?.registration, "HB-KFI")
        XCTAssertNil(service.massBalance(forRegistration: "HB-KFD"), "never a sibling's data")

        let before = massBalanceRequests(http).count
        await service.fetchAvailableAircraft()
        XCTAssertEqual(massBalanceRequests(http).count, before, "the same revisions: nothing is fetched again")
    }

    func testANewRevisionInTheListFetchesTheFileAgain() async {
        var revision = 2
        let (service, http) = service(list: { self.list(free: revision, premium: nil) },
                                      files: { _ in (200, self.file("wt9-dynamic", "F-HVXA", revision: revision)) })
        await service.fetchAvailableAircraft()
        let changes = service.massBalanceChangeCount
        revision = 3
        await service.fetchAvailableAircraft()
        XCTAssertEqual(massBalanceRequests(http).count, 2)
        XCTAssertEqual(service.massBalance(forRegistration: "F-HVXA")?.revision, 3)
        XCTAssertGreaterThan(service.massBalanceChangeCount, changes, "a sheet showing it reads it again")
    }

    func testAFileWithdrawnFromTheListIsDroppedHere() async {
        var revision: Int? = 2
        let (service, _) = service(list: { self.list(free: revision, premium: nil) },
                                   files: { _ in (200, self.file("wt9-dynamic", "F-HVXA")) })
        await service.fetchAvailableAircraft()
        XCTAssertNotNil(service.massBalance(forRegistration: "F-HVXA"))
        revision = nil
        await service.fetchAvailableAircraft()
        XCTAssertNil(service.massBalance(forRegistration: "F-HVXA"))
    }

    func testAFileForAnotherRegistrationOrAircraftIsRefused() async {
        for wrong in [file("wt9-dynamic", "F-OTHER"), file("another-type", "F-HVXA")] {
            let (service, _) = service(list: { self.list(free: 2, premium: nil) }, files: { _ in (200, wrong) })
            await service.fetchAvailableAircraft()
            XCTAssertNil(service.massBalance(forRegistration: "F-HVXA"), "not this registration's: not kept, not used")
        }
    }

    func testAFileThisBuildCannotComputeWithIsNotKept() async {
        let stones = file("wt9-dynamic", "F-HVXA").replacingOccurrences(of: #""mass":"kg""#, with: #""mass":"stone""#)
        let (service, _) = service(list: { self.list(free: 2, premium: nil) }, files: { _ in (200, stones) })
        await service.fetchAvailableAircraft()
        XCTAssertNil(service.massBalance(forRegistration: "F-HVXA"))
    }

    func testAPremiumFileIsNotAskedForNorReadWithoutAccess() async {
        // The server lists the aircraft without access, and this device holds no entitlement either.
        let (service, http) = service(list: { self.list(free: nil, premium: 5, hasAccess: false) },
                                      files: { _ in (403, #"{"success":false,"code":"ACCESS_DENIED"}"#) },
                                      gating: Gating(allowPremium: false))
        await service.fetchAvailableAircraft()
        XCTAssertTrue(massBalanceRequests(http).isEmpty)
        XCTAssertNil(service.massBalance(forRegistration: "HB-KFI"))
    }

    func testClearingAnAircraftsCacheTakesItsMassAndBalanceFileToo() async {
        let (service, _) = service(list: { self.list(free: nil, premium: 5) },
                                   files: { _ in (200, self.file("dr400-140b", "HB-KFI", revision: 5)) })
        await service.fetchAvailableAircraft()
        XCTAssertNotNil(service.massBalance(forRegistration: "HB-KFI"))
        service.clearPremiumCaches()
        XCTAssertNil(service.massBalance(forRegistration: "HB-KFI"))
    }

    // MARK: - The pilot's side

    private let now = Date(timeIntervalSince1970: 1_763_000_000)

    func testServerDataIsNotConfirmedUntilThePilotSaysSoAndOnlyForThatRevision() {
        let shipped = data(file("wt9-dynamic", "F-HVXA", revision: 2))
        var setup = MassBalanceSetup()
        XCTAssertEqual(setup.basis(shipped: shipped, now: now)?.unconfirmed, .never)

        setup.confirm(revision: 2, at: now)
        let basis = setup.basis(shipped: shipped, now: now.addingTimeInterval(86_400))
        XCTAssertEqual(basis?.isConfirmed, true)
        XCTAssertEqual(basis?.source, .shipped)
        XCTAssertEqual(basis?.empty?.date, "2025-03-10")

        let newer = data(file("wt9-dynamic", "F-HVXA", revision: 3))
        XCTAssertEqual(setup.basis(shipped: newer, now: now)?.unconfirmed, .dataChanged, "a new revision asks again")
    }

    func testAConfirmationLastsTwelveMonths() {
        let shipped = data(file("wt9-dynamic", "F-HVXA"))
        var setup = MassBalanceSetup()
        setup.confirm(revision: 2, at: now)
        XCTAssertTrue(setup.basis(shipped: shipped, now: now.addingTimeInterval(364 * 86_400))!.isConfirmed)
        XCTAssertEqual(setup.basis(shipped: shipped, now: now.addingTimeInterval(366 * 86_400))?.unconfirmed, .yearPassed)
    }

    func testTheEmptyMassOfOwnFiguresNeverStandsUnderTheAppsData() throws {
        // The pilot said the app's data isn't the aircraft's and typed their own, with their own
        // datum and a line of the record dated later than the app's.
        let shipped = data(file("wt9-dynamic", "F-HVXA", emptyDate: "2025-03-10"))
        var own = data(file("own", "F-HVXA", revision: 0, emptyDate: "2026-11-13"))
        own.empty = .init(mass: 320, moment: 160, date: "2026-11-13", entry: nil)
        var setup = MassBalanceSetup()
        setup.decline(revision: shipped.revision)
        setup.ownData = own
        setup.ownConfirmedAt = now
        let pilots = try XCTUnwrap(setup.basis(shipped: shipped, now: now))
        XCTAssertEqual(pilots.source, .pilot)
        XCTAssertEqual(pilots.empty?.moment, 160)

        // Back on the app's data, by a confirmation or by a new revision: its own line, in its own datum.
        setup.confirm(revision: shipped.revision, at: now)
        let apps = try XCTUnwrap(setup.basis(shipped: shipped, now: now))
        XCTAssertEqual(apps.source, .shipped)
        XCTAssertEqual(apps.empty?.mass, 330)
        XCTAssertFalse(apps.emptyIsPilots)
        setup.decline(revision: shipped.revision)
        let next = data(file("wt9-dynamic", "F-HVXA", revision: 3, emptyDate: "2025-03-10"))
        XCTAssertEqual(setup.basis(shipped: next, now: now)?.empty?.mass, 330)
        // The pilot's figures are kept, for the day they are wanted again.
        XCTAssertNotNil(setup.ownData)
    }

    func testTheNewerLineOfTheRecordWinsWhoeverHoldsIt() {
        let shipped = data(file("wt9-dynamic", "F-HVXA", emptyDate: "2025-03-10"))
        var setup = MassBalanceSetup()
        setup.ownEmpty = .init(mass: 331, moment: 870.5, date: "2026-02-01", entry: "calculated")
        XCTAssertEqual(setup.basis(shipped: shipped, now: now)?.empty?.mass, 331)
        XCTAssertEqual(setup.basis(shipped: shipped, now: now)?.emptyIsPilots, true)

        // The club's next file carries a line newer than the pilot's: theirs is used again.
        let later = data(file("wt9-dynamic", "F-HVXA", revision: 3, emptyDate: "2026-06-20"))
        XCTAssertEqual(setup.basis(shipped: later, now: now)?.empty?.mass, 330)
        XCTAssertEqual(setup.basis(shipped: later, now: now)?.emptyIsPilots, false)
    }

    func testDataThePilotDeclinedIsNotUsedAndALaterRevisionIsOfferedAgain() {
        let shipped = data(file("wt9-dynamic", "F-HVXA", revision: 2))
        var setup = MassBalanceSetup()
        setup.decline(revision: 2)
        XCTAssertNil(setup.basis(shipped: shipped, now: now), "nothing to compute with: the steps ask for the pilot's figures")

        var own = shipped
        own.limits.maxTakeoff = 580
        setup.ownData = own
        XCTAssertEqual(setup.basis(shipped: shipped, now: now)?.source, .pilot)
        XCTAssertEqual(setup.basis(shipped: shipped, now: now)?.unconfirmed, .never)
        setup.ownConfirmedAt = now
        XCTAssertEqual(setup.basis(shipped: shipped, now: now)?.isConfirmed, true)

        let next = data(file("wt9-dynamic", "F-HVXA", revision: 3))
        XCTAssertEqual(setup.basis(shipped: next, now: now)?.source, .shipped)
    }

    func testWithNeitherDataNorOwnFiguresThereIsNothingToComputeWith() {
        XCTAssertNil(MassBalanceSetup().basis(shipped: nil, now: now))
    }

    func testTheLastLoadStartsTheNextFlightsSheetButIsNotTodays() {
        var setup = MassBalanceSetup()
        XCTAssertNil(setup.startingLoad())
        setup.lastLoad = MassBalanceLoad(seats: ["pilot": .person(kg: 82)], fuelLitres: 90, isTodays: true)
        setup.lastLoadDay = now
        XCTAssertEqual(setup.startingLoad()?.isTodays, false)
        XCTAssertEqual(setup.startingLoad()?.copiedFrom, now)
        XCTAssertEqual(setup.startingLoad()?.seats["pilot"], .person(kg: 82))
    }

    /// Typed this morning and reopened at the aircraft, the sheet is as it was left: it was never
    /// last time's load. A sheet opened and left blank is no load at all.
    func testALoadOfTheSameDayComesBackAsItWasAndABlankOneIsNoLoad() {
        var setup = MassBalanceSetup()
        setup.lastLoad = MassBalanceLoad(seats: ["pilot": .person(kg: 82)], fuelLitres: 90, isTodays: true)
        setup.lastLoadDay = now
        let later = now.addingTimeInterval(3600)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(setup.startingLoad(on: later, calendar: utc), setup.lastLoad)
        XCTAssertEqual(setup.startingLoad(on: now.addingTimeInterval(3 * 86_400), calendar: utc)?.isTodays, false)

        setup.lastLoad = MassBalanceLoad(seats: ["pilot": .unset], isTodays: true)
        XCTAssertTrue(setup.lastLoad?.isBlank ?? false)
        XCTAssertNil(setup.startingLoad(on: later, calendar: utc))
        XCTAssertFalse(MassBalanceLoad(seats: ["pilot": .empty]).isBlank, "an empty seat is an answer")
        XCTAssertFalse(MassBalanceLoad(baggageKg: ["bag": 0]).isBlank, "no baggage is an answer")
    }

    // MARK: - One flight's load

    private func thread(_ registration: String? = "F-HVXA") -> FlightThread {
        var thread = FlightThread(routeLabel: "LSZQ → LFSB")
        thread.aircraftRegistration = registration
        return thread
    }

    /// Worked by hand on the invented two-seater: 460.2 kg at 2.714 m with 60 L, 417 kg at 2.737 m
    /// with empty tanks, both inside.
    private let solo = MassBalanceLoad(seats: ["pilot": .person(kg: 82), "passenger": .empty], baggageKg: ["baggage": 5],
                                       fuelLitres: 60, isTodays: true)

    func testAFlightOpensWithItsOwnLoadAndAnotherFlightsLoadIsNeverItsOwn() {
        var setup = MassBalanceSetup()
        var flight = thread()
        XCTAssertNil(MassBalanceFlight.startingLoad(for: flight, setup: setup, plan: nil), "the sheet starts from nothing")

        // The aircraft's last load, another flight's, of a minute ago: taken over, and not this flight's.
        setup.lastLoad = solo
        setup.lastLoadDay = now
        let carried = MassBalanceFlight.startingLoad(for: flight, setup: setup, plan: nil)
        XCTAssertEqual(carried?.isTodays, false)
        XCTAssertEqual(carried?.copiedFrom, now)
        XCTAssertEqual(carried?.seats, solo.seats)

        flight.massBalance = ThreadMassBalance(registration: "f-hvxa", load: solo, updatedAt: now)
        XCTAssertEqual(MassBalanceFlight.startingLoad(for: flight, setup: setup, plan: nil), solo)

        // Another aircraft on the flight: the load was not worked for it.
        flight.aircraftRegistration = "HB-PFA"
        XCTAssertNil(MassBalanceFlight.ownLoad(of: flight))
    }

    func testTheFuelOfAFlightsSheetIsThePlansFuelOnBoard() {
        var flight = thread()
        flight.massBalance = ThreadMassBalance(registration: "F-HVXA", load: solo, updatedAt: now)
        var plan = FlightPlan(name: "Basel")
        // No fuel on board in the plan yet: not entered in the sheet either, whatever the load remembered.
        XCTAssertNil(MassBalanceFlight.startingLoad(for: flight, setup: .init(), plan: plan)?.fuelLitres)

        plan.fuelOnBoard = 75
        plan.tripFuel = 8
        let load = MassBalanceFlight.startingLoad(for: flight, setup: .init(), plan: plan)
        XCTAssertEqual(load?.fuelLitres, 75)
        XCTAssertEqual(load?.tripLitres, 8)
        XCTAssertEqual(load?.seats, solo.seats)

        // A flight with nothing but its plan's fuel starts with that, and is nobody's earlier load.
        let fresh = MassBalanceFlight.startingLoad(for: thread(), setup: .init(), plan: plan)
        XCTAssertEqual(fresh?.fuelLitres, 75)
        XCTAssertEqual(fresh?.isTodays, true)
        XCTAssertNil(MassBalanceFlight.startingLoad(for: thread(), setup: .init(), plan: FlightPlan(name: "Empty")))
    }

    func testAFlightsStateIsOneOfSixAndFollowsThePlansFuel() {
        let shipped = data(file("wt9-dynamic", "F-HVXA", revision: 2))
        var setup = MassBalanceSetup()
        var flight = thread()
        func state(_ plan: FlightPlan? = nil) -> MassBalanceFlightState? {
            MassBalanceFlight.state(for: flight, shipped: shipped, setup: setup, plan: plan, now: now)
        }
        XCTAssertNil(MassBalanceFlight.state(for: flight, shipped: nil, setup: setup, plan: nil, now: now),
                     "no data for the aircraft: the task keeps its plain hint")
        XCTAssertNil(MassBalanceFlight.state(for: thread(nil), shipped: shipped, setup: setup, plan: nil, now: now))

        XCTAssertEqual(state(), .notDone)
        setup.lastLoad = solo
        setup.lastLoadDay = now
        XCTAssertEqual(state(), .lastTimesLoad, "another flight's load says nothing of this one")

        flight.massBalance = ThreadMassBalance(registration: "F-HVXA", load: solo, updatedAt: now)
        XCTAssertEqual(state(), .notConfirmed)
        setup.confirm(revision: 2, at: now)
        XCTAssertEqual(state(), .insideLimits(at: now))

        // The fuel on board changes in the plan after the sheet was closed: the line follows.
        var plan = FlightPlan(name: "Basel")
        plan.fuelOnBoard = 60
        XCTAssertEqual(state(plan), .insideLimits(at: now))
        plan.fuelOnBoard = 95 // the tanks hold 90
        XCTAssertEqual(state(plan), .outsideLimits(at: now))
        plan.fuelOnBoard = nil
        XCTAssertEqual(state(plan), .incomplete)

        var open = solo
        open.seats["passenger"] = .unset
        flight.massBalance = ThreadMassBalance(registration: "F-HVXA", load: open, updatedAt: now)
        XCTAssertEqual(state(), .incomplete, "a seat left blank is never a pass")
    }

    // MARK: - Kept with the flight

    private func confirmed() -> MassBalanceSetup {
        var setup = MassBalanceSetup()
        setup.confirm(revision: 2, at: now)
        return setup
    }

    func testTheFollowedFlightsSheetIsKeptAtTheStartAsItStood() throws {
        let shipped = data(file("wt9-dynamic", "F-HVXA", revision: 2))
        var flight = thread()
        XCTAssertNil(MassBalanceFlight.record(thread: flight, registration: "F-HVXA", shipped: shipped, setup: confirmed(),
                                              plan: nil, now: now), "nobody prepared a sheet for this flight: none is made up")

        let sheetAt = now.addingTimeInterval(-3600)
        flight.massBalance = ThreadMassBalance(registration: "F-HVXA", load: solo, updatedAt: sheetAt)
        var plan = FlightPlan(name: "Basel")
        plan.fuelOnBoard = 70
        let kept = try XCTUnwrap(MassBalanceFlight.record(thread: flight, registration: "F-HVXA", shipped: shipped,
                                                          setup: confirmed(), plan: plan, now: now))
        XCTAssertEqual(kept.verdict, .insideLimits)
        XCTAssertEqual(kept.load.fuelLitres, 70, "the plan's fuel on board, as at the start")
        XCTAssertEqual(kept.takeoff?.mass ?? 0, 330 + 82 + 5 + 70 * 0.72, accuracy: 0.001)
        XCTAssertEqual(kept.data.revision, 2)
        XCTAssertEqual(kept.empty?.date, "2025-03-10")
        XCTAssertEqual(kept.sheetAt, sheetAt)
        XCTAssertEqual(kept.keptAt, now)
        XCTAssertEqual(kept.state, .insideLimits(at: sheetAt))

        // A sheet that was not a pass is kept as what it was.
        XCTAssertEqual(MassBalanceFlight.record(thread: flight, registration: "F-HVXA", shipped: shipped,
                                                setup: MassBalanceSetup(), plan: nil, now: now)?.verdict, .notConfirmed)
        // Another aircraft was started than the one the sheet was worked for.
        XCTAssertNil(MassBalanceFlight.record(thread: flight, registration: "HB-PFA", shipped: shipped, setup: confirmed(),
                                              plan: nil, now: now))
        XCTAssertNil(MassBalanceFlight.record(thread: flight, registration: "F-HVXA", shipped: nil, setup: confirmed(),
                                              plan: nil, now: now), "no figures to work it with")
    }

    /// Circuits and a flight without a plan follow no flight: the aircraft's sheet counts when it was
    /// worked that day and said to be the day's, and no other.
    func testAFlightThatFollowsNoneKeepsTheAircraftsSheetOfTheDay() {
        let shipped = data(file("wt9-dynamic", "F-HVXA", revision: 2))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func kept(_ setup: MassBalanceSetup) -> FlightMassBalance? {
            MassBalanceFlight.record(thread: nil, registration: "F-HVXA", shipped: shipped, setup: setup, plan: nil,
                                     now: now, calendar: utc)
        }
        var setup = confirmed()
        XCTAssertNil(kept(setup))
        setup.lastLoad = solo
        setup.lastLoadDay = now.addingTimeInterval(-1800)
        XCTAssertEqual(kept(setup)?.verdict, .insideLimits)
        setup.lastLoadDay = now.addingTimeInterval(-2 * 86_400)
        XCTAssertNil(kept(setup), "another day's sheet")
        setup.lastLoadDay = now.addingTimeInterval(-1800)
        setup.lastLoad = solo.carriedOver(from: now.addingTimeInterval(-86_400))
        XCTAssertNil(kept(setup), "never said to be the day's")
    }

    func testOnceTheFlightHasStartedTheLineIsTheKeptSheets() throws {
        let shipped = data(file("wt9-dynamic", "F-HVXA", revision: 2))
        var flight = thread()
        flight.massBalance = ThreadMassBalance(registration: "F-HVXA", load: solo, updatedAt: now)
        let record = try XCTUnwrap(MassBalanceFlight.record(thread: flight, registration: "F-HVXA", shipped: shipped,
                                                            setup: confirmed(), plan: nil, now: now))
        flight.flightId = UUID()
        // The aircraft's data changes afterwards, the confirmation with it: what was seen before the flight stays.
        let newer = data(file("wt9-dynamic", "F-HVXA", revision: 3))
        XCTAssertEqual(MassBalanceFlight.state(for: flight, shipped: newer, setup: confirmed(), plan: nil, kept: record, now: now),
                       .insideLimits(at: now))
        XCTAssertNil(MassBalanceFlight.state(for: flight, shipped: newer, setup: confirmed(), plan: nil, kept: nil, now: now),
                     "a flight started without a sheet gets none afterwards")
    }

    func testAFlightWithAKeptSheetIsStampedThreeAndKeepsItThroughAMerge() throws {
        let shipped = data(file("wt9-dynamic", "F-HVXA", revision: 2))
        var followed = thread()
        followed.massBalance = ThreadMassBalance(registration: "F-HVXA", load: solo, updatedAt: now)
        let record = try XCTUnwrap(MassBalanceFlight.record(thread: followed, registration: "F-HVXA", shipped: shipped,
                                                            setup: confirmed(), plan: nil, now: now))
        var onTheIPad = Flight(airplane: "wt9-dynamic", aircraftRegistration: "F-HVXA")
        XCTAssertEqual(onTheIPad.requiredSchemaVersion, Flight.baseSchemaVersion)
        onTheIPad.massBalance = record
        onTheIPad.stampForContent()
        XCTAssertEqual(onTheIPad.schemaVersion, 3, "a 6.10 build doesn't show it, and can't strip it")

        let read = try JSONDecoder().decode(Flight.self, from: JSONEncoder().encode(onTheIPad))
        XCTAssertEqual(read.massBalance, record)

        // A stale copy on a device still on 6.10, renamed there later: the sheet survives both ways round.
        var stale = onTheIPad
        stale.massBalance = nil
        stale.schemaVersion = Flight.baseSchemaVersion
        stale.name = "Renamed"
        stale.modifiedAt = onTheIPad.modifiedAt.addingTimeInterval(600)
        for merged in [Flight.merge(onTheIPad, stale), Flight.merge(stale, onTheIPad)] {
            XCTAssertEqual(merged.massBalance, record)
            XCTAssertEqual(merged.schemaVersion, 3)
            XCTAssertEqual(merged.name, "Renamed")
        }

        // A sheet this build can't read is no sheet: the flight still loads.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(onTheIPad)) as? [String: Any])
        json["massBalance"] = ["registration": 7]
        let odd = try JSONDecoder().decode(Flight.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(odd.massBalance)
        XCTAssertEqual(odd.id, onTheIPad.id)
    }

    @MainActor
    func testTheRunningFlightKeepsTheSheetOnceAndIsStampedForIt() throws {
        let shipped = data(file("wt9-dynamic", "F-HVXA", revision: 2))
        var followed = thread()
        followed.massBalance = ThreadMassBalance(registration: "F-HVXA", load: solo, updatedAt: now)
        let record = try XCTUnwrap(MassBalanceFlight.record(thread: followed, registration: "F-HVXA", shipped: shipped,
                                                            setup: confirmed(), plan: nil, now: now))
        let appState = makeTestAppState()
        appState.keepMassBalance(record)
        XCTAssertNil(appState.currentFlight, "no flight, nothing kept")

        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
        defer { appState.cancelFlight() }
        appState.keepMassBalance(record)
        XCTAssertEqual(appState.currentFlight?.massBalance, record)
        XCTAssertEqual(appState.currentFlight?.schemaVersion, 3)

        var later = record
        later.verdict = .outsideLimits
        appState.keepMassBalance(later)
        XCTAssertEqual(appState.currentFlight?.massBalance?.verdict, .insideLimits, "as it was at the start, not as it is later")
    }

    // MARK: - Settings

    @MainActor
    func testTheAircraftPagesRowSaysWhereTheConfirmationStands() {
        let shipped = data(file("wt9-dynamic", "F-HVXA", revision: 2))
        func summary(_ shipped: AircraftMassBalance?, _ setup: MassBalanceSetup, at date: Date? = nil) -> String {
            MassBalanceAircraftPage.summary(registration: "F-HVXA", shipped: shipped, setup: setup, now: date ?? now)
        }
        var setup = MassBalanceSetup()
        XCTAssertEqual(summary(nil, setup), L10n.MassBalance.settingsOwnFigures)
        XCTAssertEqual(summary(shipped, setup), L10n.MassBalance.settingsNotConfirmed)

        setup.confirm(revision: 2, at: now)
        XCTAssertEqual(summary(shipped, setup),
                       L10n.MassBalance.settingsConfirmedOn(now.formatted(date: .abbreviated, time: .omitted)))
        XCTAssertEqual(summary(data(file("wt9-dynamic", "F-HVXA", revision: 3)), setup), L10n.MassBalance.lineDataChanged("F-HVXA"))
        XCTAssertEqual(summary(shipped, setup, at: now.addingTimeInterval(366 * 86_400)), L10n.MassBalance.lineYearPassed("F-HVXA"))

        setup.decline(revision: 2)
        XCTAssertEqual(summary(shipped, setup), L10n.MassBalance.settingsSwitchedOff)
    }

    @MainActor
    func testTheFiguresToHoldAgainstTheHandbookAreTheSameInTheStepsAndInSettings() {
        let rows = MassBalanceFacts.identityRows(for: data(file("wt9-dynamic", "F-HVXA")))
        XCTAssertEqual(rows.map(\.0), [L10n.MassBalance.step1Type, L10n.MassBalance.step1Serial, L10n.MassBalance.step1Mtom,
                                       rows[3].0, rows[4].0, L10n.MassBalance.step1Fuel])
        XCTAssertEqual(rows[1].1, "TT-001")
        XCTAssertTrue(rows[4].1.contains("40"), "the baggage area's maximum: \(rows[4].1)")
        XCTAssertTrue(rows[5].1.contains("90"), "the usable fuel: \(rows[5].1)")
    }

    // MARK: - Stored

    func testTheSetupsDecoderReadsEveryStoredProperty() {
        let fields = Set(Mirror(reflecting: MassBalanceSetup()).children.compactMap(\.label))
        XCTAssertEqual(fields, ["confirmedRevision", "confirmedAt", "declinedRevision", "ownEmpty", "ownData",
                                "ownConfirmedAt", "lastLoad", "lastLoadDay"],
                       "a new stored property needs its line in MassBalanceSetup.init(from:)")
        XCTAssertEqual(Set(Mirror(reflecting: MassBalanceSettings()).children.compactMap(\.label)), ["setups", "pilotMassKg"])
    }

    func testTheSettingsCarryItThroughARoundTripAndReadARecordWrittenBeforeIt() throws {
        var settings = AppSettings()
        var setup = MassBalanceSetup()
        setup.confirm(revision: 2, at: now)
        setup.ownData = data(file("wt9-dynamic", "F-HVXA"))
        setup.lastLoad = MassBalanceLoad(seats: ["pilot": .person(kg: 82), "passenger": .empty], baggageKg: ["baggage": 5], fuelLitres: 60)
        setup.lastLoadDay = now
        settings.massBalance["f-hvxa"] = setup
        settings.massBalance.pilotMassKg = 82

        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(again.massBalance, settings.massBalance)
        XCTAssertEqual(again.massBalance["F-HVXA"].confirmedRevision, 2, "keyed by the registration in capitals")

        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"pilotName":"J. Bono","schemaVersion":10}"#.utf8))
        XCTAssertEqual(older.massBalance, MassBalanceSettings())
    }

    func testOwnFiguresALaterBuildWroteAreDroppedNotTheWholeRecord() throws {
        let stones = file("wt9-dynamic", "F-HVXA").replacingOccurrences(of: #""mass":"kg""#, with: #""mass":"stone""#)
        let json = #"{"massBalance":{"setups":{"F-HVXA":{"confirmedRevision":2,"ownData":\#(stones)}},"pilotMassKg":82}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.massBalance["F-HVXA"].confirmedRevision, 2)
        XCTAssertNil(settings.massBalance["F-HVXA"].ownData)
        XCTAssertEqual(settings.massBalance.pilotMassKg, 82)
    }
}
