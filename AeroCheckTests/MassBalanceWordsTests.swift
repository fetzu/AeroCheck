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
}
