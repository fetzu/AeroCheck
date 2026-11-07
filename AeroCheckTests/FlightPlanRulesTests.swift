import CoreLocation
import XCTest
@testable import AeroCheck

/// When a flight needs an ATC plan, and the server's block as the app reads it.
final class FlightPlanRulesTests: XCTestCase {
    private var rules: FlightPlanRules {
        var r = FlightPlanRules()
        let border = FlightPlanRules.Predicate(when: "border")
        let night = FlightPlanRules.Predicate(when: "night")
        r.countries["CH"] = .init(depRequired: true, alertingWithoutDep: true, planNeeded: [
            border, night, .init(when: "aerodromes", icao: ["LSGG", "LSZH"])])
        r.countries["FR"] = .init(depRequired: true, planNeeded: [border, night])
        r.countries["DE"] = .init(depRequired: true, planNeeded: [
            .init(when: "border", waived: [.init(states: ["AT", "CH", "FR"]), .init(states: ["IT"], nonStop: true)]), night])
        r.countries["AT"] = .init(planNeeded: [.init(when: "border", waived: [.init(classes: ["E", "G"], day: true)]), night])
        r.countries["RS"] = .init(planNeeded: [.init(when: "all")])
        r.countries["BG"] = .init()
        r.aerodromeDeparture = ["LFSB": "CH"]
        return r
    }

    private func flight(_ states: [String], departure: String? = nil, arrival: String? = nil, night: Bool = false) -> FlightPlanRules.Flight {
        .init(states: states, departure: departure, arrival: arrival, isNight: night)
    }

    func testADomesticDayFlightNeedsNone() {
        XCTAssertNil(rules.need(for: flight(["CH"], departure: "LSZQ", arrival: "LSGC")))
    }

    func testABorderNeedsOne() {
        XCTAssertEqual(rules.need(for: flight(["CH", "FR"])), .border("FR"))
    }

    func testOneYesIsEnough() {
        // Germany waives Switzerland; Switzerland doesn't waive Germany.
        XCTAssertEqual(rules.need(for: flight(["CH", "DE"])), .border("DE"))
        XCTAssertEqual(rules.need(for: flight(["DE", "CH"])), .border("CH"))
    }

    func testBothSidesWaivingNeedsNone() {
        var r = rules
        r.countries["FR"] = .init(planNeeded: [.init(when: "border", waived: [.init(states: ["DE"])])])
        XCTAssertNil(r.need(for: flight(["DE", "FR"])))
    }

    func testAWaiverByClassCantBeProvenSoItDoesntHold() {
        XCTAssertEqual(rules.need(for: flight(["AT", "DE"])), .border("DE"))
    }

    func testANonStopWaiverFailsWhenTheFlightLandsThere() {
        var r = rules
        r.countries["IT"] = .init(planNeeded: [.init(when: "border", waived: [.init(states: ["DE"])])])
        XCTAssertEqual(r.need(for: flight(["DE", "IT"])), .border("IT"))
        XCTAssertNil(r.need(for: flight(["DE", "IT", "DE"])))
    }

    func testNightNeedsOne() {
        XCTAssertEqual(rules.need(for: flight(["CH"], night: true)), .night)
    }

    func testTheSwissAirportsNeedOne() {
        XCTAssertEqual(rules.need(for: flight(["CH"], departure: "LSZQ", arrival: "LSZH")), .aerodrome("LSZH"))
    }

    func testSerbiaAsksEveryFlight() {
        XCTAssertEqual(rules.need(for: flight(["RS"])), .everyFlight("RS"))
    }

    func testACountryNotReadAsksOnlyAtABorderOrAtNight() {
        XCTAssertNil(rules.need(for: flight(["BG"])))
        XCTAssertEqual(rules.need(for: flight(["BG"], night: true)), .night)
        XCTAssertEqual(rules.need(for: flight(["BG", "RO"])), .border("RO"))
    }

    func testACountryOutsideTheBlockReadsLikeOneNotRead() {
        XCTAssertNil(rules.need(for: flight(["XX"])))
        XCTAssertEqual(rules.need(for: flight(["XX"], night: true)), .night)
    }

    func testAPredicateThisBuildDoesntKnowCountsAsNo() {
        var r = rules
        r.countries["CH"]?.planNeeded = [.init(when: "overWater")]
        XCTAssertNil(r.need(for: flight(["CH"])))
    }

    func testAClassPredicateCountsAsNoForNow() {
        var r = rules
        r.countries["CH"]?.planNeeded = [.init(when: "classes", classes: ["C", "D"])]
        XCTAssertNil(r.need(for: flight(["CH"])))
    }

    func testBaselMulhouseFilesAsSwiss() {
        XCTAssertEqual(rules.departureState(aerodrome: "LFSB", country: "FR"), "CH")
        XCTAssertEqual(rules.departureState(aerodrome: "LFGA", country: "FR"), "FR")
    }

    func testTheServersBlockReads() throws {
        let json = """
        {"v":1,"countries":{},"flags":[],"flightPlan":{"countries":{
          "CH":{"depRequired":true,"alertingWithoutDep":true,"cancelAfterMinutes":null,
                "planNeeded":[{"when":"border"},{"when":"night"},{"when":"aerodromes","icao":["LSGG","LSZH"]}]},
          "BG":{"depRequired":null,"alertingWithoutDep":null,"cancelAfterMinutes":null,"planNeeded":null}},
          "aerodromeDeparture":{"LFSB":"CH"}}}
        """
        let registry = try JSONDecoder().decode(BriefingRegistry.self, from: Data(json.utf8))
        XCTAssertEqual(registry.flightPlan?.countries["CH"]?.planNeeded?.count, 3)
        XCTAssertEqual(registry.flightPlan?.aerodromeDeparture["LFSB"], "CH")
        XCTAssertNil(registry.flightPlan?.countries["BG"]?.planNeeded)
    }

    func testARegistryWithoutTheBlockStillReads() throws {
        let registry = try JSONDecoder().decode(BriefingRegistry.self, from: Data(#"{"v":1,"countries":{}}"#.utf8))
        XCTAssertNil(registry.flightPlan)
    }

    func testABrokenBlockCostsTheBlockNotTheRegistry() throws {
        let registry = try JSONDecoder().decode(BriefingRegistry.self, from: Data(#"{"v":1,"countries":{},"flightPlan":"x"}"#.utf8))
        XCTAssertNil(registry.flightPlan)
    }

    // MARK: Night

    private let zurich = CLLocationCoordinate2D(latitude: 47.46, longitude: 8.55)

    private func utc(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    func testCivilDuskInZurichInNovember() throws {
        // Sunset about 16:05 UTC on 4 Nov, civil dusk about half an hour later.
        let dusk = try XCTUnwrap(CivilTwilight.times(on: utc(4, 12), at: zurich)).dusk
        XCTAssertEqual(dusk.timeIntervalSince(utc(4, 16, 36)), 0, accuracy: 300)
    }

    func testDayAndNight() {
        XCTAssertFalse(CivilTwilight.isNight(utc(4, 12), at: zurich))
        XCTAssertTrue(CivilTwilight.isNight(utc(4, 18), at: zurich))
        XCTAssertTrue(CivilTwilight.isNight(utc(4, 4), at: zurich))
    }

    func testAFlightLandingAfterDuskIsANightFlight() {
        XCTAssertTrue(CivilTwilight.flightIsNight(departure: utc(4, 15), arrival: utc(4, 17), from: zurich, to: zurich))
        XCTAssertFalse(CivilTwilight.flightIsNight(departure: utc(4, 10), arrival: utc(4, 11), from: zurich, to: zurich))
    }

    func testNoTimesIsNoNight() {
        XCTAssertFalse(CivilTwilight.flightIsNight(departure: nil, arrival: nil, from: zurich, to: zurich))
    }

    func testTheMidnightSunHasNoNight() {
        let north = CLLocationCoordinate2D(latitude: 78, longitude: 15)
        XCTAssertNil(CivilTwilight.times(on: utc(21, 12, month: 6), at: north))
        XCTAssertFalse(CivilTwilight.isNight(utc(21, 0, month: 6), at: north))
    }
}
