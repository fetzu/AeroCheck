import XCTest
@testable import AeroCheck

/// What the mass and balance sheet writes (6.11.0): figures in the handbook's units with kilograms
/// beside them, seats named from where they sit, and a line for every state. Invented aircraft only.
final class MassBalanceWordsTests: XCTestCase {

    private func aircraft(mass: String, arm: String, fuel: String, rows: String) -> AircraftMassBalance {
        let json = """
        {"schema":1,"aircraftId":"test","registration":"T-EST","revision":1,"updated":"2026-01-01",
         "units":{"mass":"\(mass)","arm":"\(arm)","fuel":"\(fuel)"},"limits":{"maxTakeoff":2400},
         "categories":[{"id":"normal","maxTakeoff":2400,"envelope":[[80,1200],[80,2000],[86,2400],[92,2400],[92,1200]]},
                       {"id":"utility","maxTakeoff":2000,"envelope":[[80,1200],[80,2000],[92,2000],[92,1200]],"only":["row1","fuel"]}],
         "stations":[\(rows),
                     {"id":"bagA","kind":"baggage","arm":140,"max":200},{"id":"bagB","kind":"baggage","arm":170,"max":100},
                     {"id":"fuel","kind":"fuel","arm":95,"usable":50,"density":6.0}],
         "handbookChecks":["takeoff"],"sources":[{"what":"all","document":"invented"}]}
        """
        return try! JSONDecoder().decode(AircraftMassBalance.self, from: Data(json.utf8))
    }

    private let fourSeats = """
        {"id":"row1","kind":"seats","arm":80,"layout":"side-by-side","seats":[{"id":"p","role":"pilot"},{"id":"f","role":"passenger"}]},
        {"id":"row2","kind":"seats","arm":118,"layout":"side-by-side","seats":[{"id":"rl","role":"passenger"},{"id":"rr","role":"passenger"}]}
        """
    private let tandem = """
        {"id":"row1","kind":"seats","arm":11,"layout":"tandem","seats":[{"id":"front","role":"pilot"}]},
        {"id":"row2","kind":"seats","arm":37,"layout":"tandem","seats":[{"id":"rear","role":"pilot"}]}
        """

    func testAMassInPoundsHasItsKilogramsBesideItAndNoGrouping() {
        let pounds = aircraft(mass: "lb", arm: "in", fuel: "usgal", rows: fourSeats).units
        XCTAssertEqual(MassBalanceWords.mass(2441.3, pounds), "2441 lb (1107 kg)")
        XCTAssertEqual(MassBalanceWords.mass(2441.3, pounds, withKilograms: false), "2441 lb")
        let metric = aircraft(mass: "kg", arm: "m", fuel: "l", rows: fourSeats).units
        XCTAssertEqual(MassBalanceWords.mass(1107.26, metric), "1107.3 kg")
    }

    func testArmsAndGapsFollowTheHandbooksUnit() {
        let inches = aircraft(mass: "lb", arm: "in", fuel: "usgal", rows: fourSeats).units
        XCTAssertEqual(MassBalanceWords.arm(90.41, inches), "90.4 in")
        XCTAssertEqual(MassBalanceWords.gap(-2.64, inches), "2.6 in")
        let metres = aircraft(mass: "kg", arm: "m", fuel: "l", rows: fourSeats).units
        XCTAssertEqual(MassBalanceWords.arm(2.7279, metres), "2.728 m")
        XCTAssertEqual(MassBalanceWords.gap(0.0279, metres), "2.8 cm")
        let millimetres = aircraft(mass: "kg", arm: "mm", fuel: "l", rows: fourSeats).units
        XCTAssertEqual(MassBalanceWords.arm(2727.9, millimetres), "2728 mm")
        XCTAssertEqual(MassBalanceWords.gap(27.9, millimetres), "2.8 cm")
    }

    func testFuelTypedInLitresShowsTheHandbooksGallons() {
        let gallons = aircraft(mass: "lb", arm: "in", fuel: "usgal", rows: fourSeats).units
        XCTAssertEqual(MassBalanceWords.fuel(litres: 151.416, gallons), "40.0 US gal")
        XCTAssertNil(MassBalanceWords.fuel(litres: 60, aircraft(mass: "kg", arm: "m", fuel: "l", rows: fourSeats).units))
    }

    func testEverySeatAndRowHasItsOwnName() {
        let four = aircraft(mass: "lb", arm: "in", fuel: "usgal", rows: fourSeats)
        let seats = four.seatStations.flatMap { $0.seats ?? [] }
        let names = seats.map { MassBalanceWords.seatName($0, in: four) }
        XCTAssertEqual(Set(names).count, 4, "four seats, four different names: \(names)")
        let rows = four.stations.map { MassBalanceWords.rowName($0, in: four) }
        XCTAssertEqual(Set(rows).count, rows.count, "two seat rows, two baggage areas and the fuel: \(rows)")

        // Two pilots' seats in tandem: both are "the pilot's", so the row tells them apart.
        let two = aircraft(mass: "lb", arm: "in", fuel: "usgal", rows: tandem)
        XCTAssertNotEqual(MassBalanceWords.rowName(two.stations[0], in: two), MassBalanceWords.rowName(two.stations[1], in: two))
    }

    func testEveryStateHasItsOwnTitleAndShape() {
        let all: [MassBalanceVerdict] = [.outsideLimits, .incomplete, .notConfirmed, .lastTimesLoad, .insideLimits]
        XCTAssertEqual(Set(all.map(MassBalanceWords.title)).count, 5)
        XCTAssertEqual(Set(all.map(MassBalanceWords.symbol)).count, 5, "a shape of its own, so nothing depends on colour")
    }

    func testEveryStateOfAFlightHasItsOwnLineAndShape() {
        let at = Date(timeIntervalSince1970: 1_763_000_000)
        let all: [MassBalanceFlightState] = [.notDone, .lastTimesLoad, .incomplete, .notConfirmed,
                                             .outsideLimits(at: at), .insideLimits(at: at)]
        XCTAssertEqual(Set(all.map { MassBalanceWords.stateLine($0, now: at) }).count, 6)
        XCTAssertEqual(Set(all.map(MassBalanceWords.stateSymbol)).count, 6)
        // A verdict carries the sheet's time; with the day once it isn't today's.
        let sameDay = MassBalanceWords.stateLine(.insideLimits(at: at), now: at)
        let nextDay = MassBalanceWords.stateLine(.insideLimits(at: at), now: at.addingTimeInterval(2 * 86_400))
        XCTAssertTrue(sameDay.contains(at.formatted(date: .omitted, time: .shortened)), sameDay)
        XCTAssertGreaterThan(nextDay.count, sameDay.count, "\(sameDay) / \(nextDay)")
    }

    func testTheLinesNameWhatIsMissingAndWhereALimitIsPassed() {
        let four = aircraft(mass: "lb", arm: "in", fuel: "usgal", rows: fourSeats)
        let empty = AircraftMassBalance.EmptyMass(mass: 1500, moment: 130_500, date: "2025-02-18")
        let basis = MassBalanceBasis(data: four, source: .shipped, empty: empty, emptyIsPilots: false, isConfirmed: true, unconfirmed: nil)

        var load = MassBalanceLoad(seats: ["p": .person(kg: 80), "f": .empty, "rl": .empty], baggageKg: ["bagA": 0, "bagB": 0],
                                   fuelLitres: 100, isTodays: true)
        var result = MassBalanceCalculator.compute(data: four, empty: empty, load: load, isConfirmed: true)
        XCTAssertEqual(result.verdict, .incomplete)
        let missing = MassBalanceWords.lines(for: result, basis: basis, registration: "T-EST", load: load)
        let rearRight = MassBalanceWords.seatName(four.seatStations[1].seats![1], in: four)
        XCTAssertTrue(missing[0].contains(rearRight), "\(missing)")
        XCTAssertEqual(missing.count, 2, "a seat is unset: the rule about empty seats follows. \(missing)")

        // Only the fuel missing: the rule about empty seats has nothing to say.
        var noFuel = load
        noFuel.seats["rr"] = .empty
        noFuel.fuelLitres = nil
        let noFuelResult = MassBalanceCalculator.compute(data: four, empty: empty, load: noFuel, isConfirmed: true)
        XCTAssertEqual(noFuelResult.verdict, .incomplete)
        XCTAssertEqual(MassBalanceWords.lines(for: noFuelResult, basis: basis, registration: "T-EST", load: noFuel).count, 1)

        load.seats["rr"] = .empty
        load.baggageKg["bagA"] = 95 // 209 lb, over the area's 200
        result = MassBalanceCalculator.compute(data: four, empty: empty, load: load, isConfirmed: true)
        let passed = MassBalanceWords.lines(for: result, basis: basis, registration: "T-EST", load: load)
        XCTAssertTrue(passed.contains { $0.contains(MassBalanceWords.rowName(four.stations[2], in: four)) && $0.contains("200 lb") }, "\(passed)")

        load.baggageKg["bagA"] = 0
        result = MassBalanceCalculator.compute(data: four, empty: empty, load: load, isConfirmed: true)
        XCTAssertEqual(result.verdict, .insideLimits)
        let margins = MassBalanceWords.lines(for: result, basis: basis, registration: "T-EST", load: load)
        XCTAssertGreaterThanOrEqual(margins.count, 4, "the mass margin, the CG margins, no landing point, and the utility category: \(margins)")
        XCTAssertTrue(margins[0].contains("lb") && margins[0].contains("kg"))
        XCTAssertFalse(MassBalanceWords.spoken(result, data: four).isEmpty)
    }

    /// A blank sheet's point is the empty aircraft, far outside every envelope, and a half-filled
    /// one can sit inside by chance. Neither is a loading condition: no word judges it.
    func testWithARowStillToEnterNoPointIsCalledInsideOrOutside() {
        let four = aircraft(mass: "lb", arm: "in", fuel: "usgal", rows: fourSeats)
        let empty = AircraftMassBalance.EmptyMass(mass: 1500, moment: 130_500, date: "2025-02-18")

        var load = MassBalanceLoad()
        var result = MassBalanceCalculator.compute(data: four, empty: empty, load: load, isConfirmed: true)
        XCTAssertFalse(result.isComplete)
        XCTAssertFalse(result.loadIsEntered, "how much fuel fits is not known before the seats are")
        let blank = try! XCTUnwrap(result.takeoff)
        XCTAssertEqual(MassBalanceWords.pointWord(blank, in: result), L10n.MassBalance.pointSoFar)
        let spoken = MassBalanceWords.spoken(result, data: four)
        XCTAssertTrue(spoken.contains(L10n.MassBalance.chartSoFar), spoken)
        XCTAssertFalse(spoken.contains(L10n.MassBalance.pointEmptyTanks), "one point so far, not three: \(spoken)")

        load = MassBalanceLoad(seats: ["p": .person(kg: 80), "f": .empty, "rl": .empty, "rr": .empty],
                               baggageKg: ["bagA": 0, "bagB": 0])
        result = MassBalanceCalculator.compute(data: four, empty: empty, load: load, isConfirmed: true)
        XCTAssertFalse(result.isComplete, "the fuel is still to enter")
        XCTAssertTrue(result.loadIsEntered)
        XCTAssertEqual(MassBalanceWords.pointWord(try! XCTUnwrap(result.takeoff), in: result), L10n.MassBalance.pointSoFar)

        load.fuelLitres = 100
        load.isTodays = true
        result = MassBalanceCalculator.compute(data: four, empty: empty, load: load, isConfirmed: true)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(MassBalanceWords.pointWord(try! XCTUnwrap(result.takeoff), in: result), L10n.MassBalance.pointInside)
    }

    func testADateIsWrittenForTheReaderAndAnOddOneIsLeftAsItIs() {
        XCTAssertNotEqual(MassBalanceWords.day("2025-02-18"), "2025-02-18")
        XCTAssertTrue(MassBalanceWords.day("2025-02-18").contains("2025"))
        XCTAssertEqual(MassBalanceWords.day("spring 2010"), "spring 2010")
    }

    func testTheChartsTicksAreRoundSteps() {
        XCTAssertEqual(MassBalanceChart.step(for: 1400, count: 6), 200)
        XCTAssertEqual(MassBalanceChart.step(for: 12, count: 6), 2)
        XCTAssertEqual(MassBalanceChart.step(for: 0.15, count: 6), 0.02, accuracy: 1e-12)
        XCTAssertEqual(MassBalanceChart.step(for: 0, count: 6), 1)
    }
    // MARK: - The review of 14 Nov 2026

    /// ST11-05: a figure of twenty digits in a failure's sentence used to trap in `Int(…)`.
    func testAFailureWithAnImplausibleFigureIsWordedWithoutATrap() {
        let four = aircraft(mass: "lb", arm: "in", fuel: "usgal", rows: fourSeats)
        for failure: MassBalanceFailure in [.fuelOverUsable(usableLitres: 1e300), .landingOutside(.behindAftLimit, litresLeft: 1e20),
                                            .fuelLineOutside(.behindAftLimit, litresLeft: .infinity),
                                            .tripOverFuel(tripLitres: 1e19, takeoffLitres: -1e19)] {
            XCTAssertFalse(MassBalanceWords.failure(failure, in: four).isEmpty)
        }
        XCTAssertEqual(MassBalanceWords.litres(83.4), 83)
    }

    /// ST11-09: the first-time step and Settings show the two limits the sheet now holds the points to.
    func testTheFactsToCompareWithTheAFMIncludeTheLandingAndMinimumMasses() throws {
        let json = """
        {"schema":1,"aircraftId":"test","registration":"T-EST","revision":1,"updated":"2026-01-01",
         "units":{"mass":"kg","arm":"m","fuel":"l"},"limits":{"maxTakeoff":600,"maxLanding":570,"minFlying":420},
         "categories":[{"id":"normal","maxTakeoff":600,"envelope":[[2.7,400],[2.7,600],[2.85,600],[2.85,400]]}],
         "stations":[{"id":"row1","kind":"seats","arm":3.1,"layout":"single","seats":[{"id":"p","role":"pilot"}]},
                     {"id":"fuel","kind":"fuel","arm":2.5,"usable":90,"density":0.72}],"sources":[]}
        """
        let data = try JSONDecoder().decode(AircraftMassBalance.self, from: Data(json.utf8))
        let rows = Dictionary(MassBalanceFacts.identityRows(for: data), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(rows[L10n.MassBalance.step1MaxLanding], "570.0 kg")
        XCTAssertEqual(rows[L10n.MassBalance.step1MinFlying], "420.0 kg")
    }

    /// ST11-10, the author's d4: with a route, the sheet's trip is the route's (shown, not typed);
    /// without one, or with no trip in the route, the box stays.
    func testTheTripOfAFlightWithARouteIsTheRoutes() {
        var plan = FlightPlan(name: "Basel")
        XCTAssertNil(MassBalanceFlight.routeTrip(of: nil))
        XCTAssertNil(MassBalanceFlight.routeTrip(of: plan), "a route without a trip keeps the box")
        plan.tripFuel = 12.5
        XCTAssertEqual(MassBalanceFlight.routeTrip(of: plan), 12.5)
        plan.tripFuel = 1e12
        XCTAssertNil(MassBalanceFlight.routeTrip(of: plan), "not a trip")
        var thread = FlightThread(routeLabel: "LSZQ → LFSB")
        thread.aircraftRegistration = "T-EST"
        plan.tripFuel = 12.5
        XCTAssertEqual(MassBalanceFlight.startingLoad(for: thread, setup: .init(), plan: plan)?.tripLitres, 12.5)
    }
    // MARK: - Reading the sheet (review UX11-05, UX11-24)

    private var own: AircraftMassBalance {
        try! JSONDecoder().decode(AircraftMassBalance.self, from: Data("""
        {"schema":1,"aircraftId":"own","registration":"T-OWN","revision":0,"updated":"2026-11-01",
         "units":{"mass":"kg","arm":"m","fuel":"l"},"limits":{"maxTakeoff":600},
         "categories":[{"id":"normal","maxTakeoff":600,"envelope":[[2.7,400],[2.7,600],[2.85,600],[2.85,400]]}],
         "stations":[{"id":"row1","kind":"seats","arm":3.1,"layout":"single","seats":[{"id":"p","role":"pilot"}]},
                     {"id":"fuel","kind":"fuel","arm":2.5,"usable":90,"density":0.72}],
         "empty":{"mass":330,"moment":907.5,"date":"2025-03-10"},"sources":[]}
        """.utf8))
    }

    /// UX11-05: until the pilot says it is today's load, or confirms the data, no card reads as the
    /// pass the verdict withholds. The point stays; its word says what it rests on.
    func testAPointIsNeverJustInsideWhileTheVerdictIsWithheld() throws {
        let load = MassBalanceLoad(seats: ["p": .person(kg: 80)], fuelLitres: 40, tripLitres: 10, isTodays: false)
        let lastTime = MassBalanceCalculator.compute(data: own, empty: own.empty, load: load, isConfirmed: true)
        XCTAssertEqual(lastTime.verdict, .lastTimesLoad)
        let takeoff = try XCTUnwrap(lastTime.takeoff)
        XCTAssertTrue(takeoff.isInside)
        XCTAssertNotEqual(MassBalanceWords.pointWord(takeoff, in: lastTime), L10n.MassBalance.pointInside)
        XCTAssertEqual(MassBalanceWords.pointWord(takeoff, in: lastTime), L10n.MassBalance.pointInsideLastTime)

        var todays = load
        todays.isTodays = true
        let unconfirmed = MassBalanceCalculator.compute(data: own, empty: own.empty, load: todays, isConfirmed: false)
        XCTAssertEqual(unconfirmed.verdict, .notConfirmed)
        XCTAssertNotEqual(MassBalanceWords.pointWord(takeoff, in: unconfirmed), L10n.MassBalance.pointInside)
        XCTAssertEqual(MassBalanceWords.pointWord(takeoff, in: unconfirmed), L10n.MassBalance.pointInsideCalculated)

        let inside = MassBalanceCalculator.compute(data: own, empty: own.empty, load: todays, isConfirmed: true)
        XCTAssertEqual(inside.verdict, .insideLimits)
        XCTAssertEqual(MassBalanceWords.pointWord(takeoff, in: inside), L10n.MassBalance.pointInside)
    }

    /// UX11-24, the author's d5: figures the pilot typed are "entered", not "confirmed", and the line
    /// on Today and the flight's page says the verdict rests on them.
    func testThePilotsOwnFiguresAreEnteredAndTheLineSaysSo() {
        let day = Date(timeIntervalSince1970: 1_763_078_400)
        let setup = MassBalanceSetup(ownData: own, ownConfirmedAt: day)
        let basis = setup.basis(shipped: nil, now: day)!
        XCTAssertEqual(basis.source, .pilot)
        let text = MassBalanceAircraftPage.confirmation(basis, setup: setup, registration: "T-OWN")
        let date = day.formatted(date: .abbreviated, time: .omitted)
        XCTAssertNotEqual(text, L10n.MassBalance.settingsConfirmedOn(date))
        XCTAssertEqual(text, L10n.MassBalance.settingsEnteredOn(date))
        // A year on, it is asked again, as before.
        let later = setup.basis(shipped: nil, now: day.addingTimeInterval(400 * 86_400))!
        XCTAssertEqual(MassBalanceAircraftPage.confirmation(later, setup: setup, registration: "T-OWN"),
                       L10n.MassBalance.lineYearPassed("T-OWN"))

        var thread = FlightThread(routeLabel: "LSZQ → LFSB")
        thread.aircraftRegistration = "T-OWN"
        XCTAssertTrue(MassBalanceFlight.isPilotsFigures(for: thread, shipped: nil, setup: setup, now: day))
        let line = MassBalanceWords.stateLine(.insideLimits(at: day), yourFigures: true, now: day)
        XCTAssertEqual(line, L10n.MassBalance.stateYourFigures(MassBalanceWords.stateLine(.insideLimits(at: day), now: day)))
        XCTAssertEqual(MassBalanceWords.stateLine(.notDone, yourFigures: true), L10n.MassBalance.stateNotDone)
    }

    /// ST11-37, seen on a simulator: with a trip the fuel can't cover, the landing card said "no trip
    /// fuel" under a trip typed as 40 L. It says the trip needs more fuel.
    func testTheLandingCardSaysWhyThereIsNoLanding() {
        let four = aircraft(mass: "lb", arm: "in", fuel: "usgal", rows: fourSeats)
        var noTrip = MassBalanceCalculator.compute(data: four, empty: .init(mass: 1500, moment: 130_500, date: "2025-02-18"),
                                                   load: MassBalanceLoad(), isConfirmed: true)
        XCTAssertEqual(MassBalanceWords.noLandingNote(noTrip), L10n.MassBalance.pointNoTrip)
        noTrip.failures = [.tripOverFuel(tripLitres: 40, takeoffLitres: 30)]
        XCTAssertEqual(MassBalanceWords.noLandingNote(noTrip), L10n.MassBalance.pointTripOverFuel)
    }

    /// UX11-42: the colon belongs to each language. French writes a no-break space before it.
    func testALabelledLineHasEachLanguagesColon() throws {
        XCTAssertEqual(L10n.MassBalance.labelled("Mass and balance", "Inside limits"), "Mass and balance: Inside limits")
        let catalog = try XCTUnwrap(Bundle.main.url(forResource: "fr", withExtension: "lproj")
            .flatMap { Bundle(url: $0) })
        let french = catalog.localizedString(forKey: "mb.labelled %@ %@", value: nil, table: nil)
        XCTAssertEqual(String(format: french, "Masse et centrage", "Dans les limites"), "Masse et centrage\u{00A0}: Dans les limites")
    }
}
