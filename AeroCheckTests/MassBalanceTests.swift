import XCTest
@testable import AeroCheck

/// The mass and balance sheet's data and arithmetic (6.11.0). Pure: no service, no clock, no file.
///
/// Both aircraft here are invented. No real aircraft's figure belongs in this repository; the real
/// files come from the server, one per registration.
final class MassBalanceTests: XCTestCase {

    // MARK: - Two invented aircraft

    /// A two-seater in kilograms and metres, with a sloped lower edge, a minimum pilot mass and one
    /// maximum mass. Its handbook asks for take-off and empty tanks.
    private let metricJSON = """
    {
      "schema": 1, "aircraftId": "test-two", "registration": "T-EST1", "revision": 2, "updated": "2026-01-15",
      "identity": { "designation": "Test Two", "serialNumber": "TT-001", "handbook": "TT-POH-1" },
      "units": { "mass": "kg", "arm": "m", "fuel": "l" },
      "datum": { "en": "2.000 m forward of the firewall" },
      "limits": { "maxTakeoff": 600, "maxLanding": 600, "minFlying": 400 },
      "categories": [
        { "id": "normal", "maxTakeoff": 600,
          "envelope": [[2.70, 400], [2.70, 540], [2.75, 600], [2.85, 600], [2.85, 460], [2.72, 400]] }
      ],
      "stations": [
        { "id": "row1", "kind": "seats", "arm": 3.10, "layout": "side-by-side",
          "seats": [ { "id": "pilot", "role": "pilot", "min": 55, "max": 120 },
                     { "id": "passenger", "role": "passenger", "max": 120 } ] },
        { "id": "baggage", "kind": "baggage", "arm": 3.80, "max": 40 },
        { "id": "fuel", "kind": "fuel", "arm": 2.50, "usable": 90, "density": 0.72 }
      ],
      "emptyCheck": { "cgRange": [2.60, 2.66] },
      "handbookChecks": ["takeoff", "zeroFuel"],
      "empty": { "mass": 330, "moment": 867.9, "date": "2025-03-10", "entry": "weighed" },
      "sources": [ { "what": "everything", "document": "an invented handbook" } ]
    }
    """

    /// A four-seater in pounds, inches and US gallons, with a ramp mass, taxi fuel and a utility
    /// category that allows the front seats and the fuel only.
    private let imperialJSON = """
    {
      "schema": 1, "aircraftId": "test-four", "registration": "T-EST4", "revision": 1, "updated": "2026-02-01",
      "identity": { "designation": "Test Four", "serialNumber": "TF-004" },
      "units": { "mass": "lb", "arm": "in", "fuel": "usgal" },
      "limits": { "maxTakeoff": 2400, "maxRamp": 2410, "taxiFuel": 10 },
      "categories": [
        { "id": "normal", "maxTakeoff": 2400, "maxRamp": 2410,
          "envelope": [[80, 1200], [80, 2000], [86, 2400], [92, 2400], [92, 1200]] },
        { "id": "utility", "maxTakeoff": 2000, "maxRamp": 2010,
          "envelope": [[80, 1200], [80, 2000], [92, 2000], [92, 1200]], "only": ["row1", "fuel"] }
      ],
      "stations": [
        { "id": "row1", "kind": "seats", "arm": 80, "layout": "side-by-side",
          "seats": [ { "id": "pilot", "role": "pilot" }, { "id": "front", "role": "passenger" } ] },
        { "id": "row2", "kind": "seats", "arm": 118, "layout": "side-by-side",
          "seats": [ { "id": "rearLeft", "role": "passenger" }, { "id": "rearRight", "role": "passenger" } ] },
        { "id": "baggage", "kind": "baggage", "arm": 140, "max": 200 },
        { "id": "fuel", "kind": "fuel", "arm": 95, "usable": 50, "density": 6.0 }
      ],
      "handbookChecks": ["takeoff"],
      "sources": [ { "what": "everything", "document": "an invented handbook" } ]
    }
    """

    private func decode(_ json: String) throws -> AircraftMassBalance {
        try JSONDecoder().decode(AircraftMassBalance.self, from: Data(json.utf8))
    }

    private var metric: AircraftMassBalance { try! decode(metricJSON) }
    private var imperial: AircraftMassBalance { try! decode(imperialJSON) }
    private var imperialEmpty: AircraftMassBalance.EmptyMass {
        .init(mass: 1500, moment: 130_500, date: "2025-02-18", entry: "calculated")
    }

    /// One person, the other seat said empty, no bags, 50 litres, said to be today's.
    private func soloMetric(pilotKg: Double = 80, fuel: Double? = 50, trip: Double? = 20) -> MassBalanceLoad {
        MassBalanceLoad(seats: ["pilot": .person(kg: pilotKg), "passenger": .empty],
                        baggageKg: ["baggage": 10], fuelLitres: fuel, tripLitres: trip, isTodays: true)
    }

    private func compute(_ data: AircraftMassBalance, _ load: MassBalanceLoad,
                         empty: AircraftMassBalance.EmptyMass? = nil, confirmed: Bool = true) -> MassBalanceResult {
        MassBalanceCalculator.compute(data: data, empty: empty ?? data.empty, load: load, isConfirmed: confirmed)
    }

    // MARK: - The file

    func testAFileDecodesWithItsCornersStationsAndEmptyMass() throws {
        let data = try decode(metricJSON)
        XCTAssertTrue(data.isUsable)
        XCTAssertEqual(data.mainCategory?.envelope.count, 6)
        XCTAssertEqual(data.mainCategory?.envelope.first, MassBalanceCorner(arm: 2.70, mass: 400))
        XCTAssertEqual(data.seatStations.first?.seats?.map(\.id), ["pilot", "passenger"])
        XCTAssertEqual(data.usableFuelLitres, 90)
        XCTAssertEqual(data.empty?.arm ?? 0, 2.63, accuracy: 1e-9)
        // A round trip keeps the corners as arrays, the file's own form.
        let again = try JSONDecoder().decode(AircraftMassBalance.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(again, data)
    }

    func testUsableFuelInLitresFromAFileInGallons() {
        XCTAssertEqual(imperial.usableFuelLitres ?? 0, 50 * 3.785411784, accuracy: 1e-6)
    }

    func testAUnitThisBuildDoesNotKnowFailsTheDecodeRatherThanBeingGuessed() {
        let stones = metricJSON.replacingOccurrences(of: "\"mass\": \"kg\"", with: "\"mass\": \"stone\"")
        XCTAssertThrowsError(try decode(stones))
    }

    func testAFileOfALaterSchemaOrWithoutUsableFuelIsNotUsed() throws {
        XCTAssertFalse(try decode(metricJSON.replacingOccurrences(of: "\"schema\": 1", with: "\"schema\": 2")).isUsable)
        XCTAssertFalse(try decode(metricJSON.replacingOccurrences(of: "\"usable\": 90, ", with: "")).isUsable)
        let noPilot = metricJSON.replacingOccurrences(of: "\"role\": \"pilot\"", with: "\"role\": \"passenger\"")
        XCTAssertFalse(try decode(noPilot).isUsable)
    }

    // MARK: - The empty mass

    func testAMomentTypedAsARecordWritesItDividedBy100IsCaught() {
        let data = imperial
        XCTAssertTrue(imperialEmpty.isPlausible(for: data))
        XCTAssertEqual(imperialEmpty.arm ?? 0, 87, accuracy: 1e-9)
        // The record's column reads 1305.00 ("moment / 100"): typed as it stands, the CG is 0.87 in.
        let asWritten = AircraftMassBalance.EmptyMass(mass: 1500, moment: 1305, date: "2025-02-18", entry: nil)
        XCTAssertFalse(asWritten.isPlausible(for: data))
    }

    func testTheHandbooksOwnRangeForTheEmptyCGIsUsedWhenTheFileGivesIt() {
        let data = metric
        XCTAssertTrue(AircraftMassBalance.EmptyMass(mass: 330, moment: 867.9, date: "2025-03-10").isPlausible(for: data))
        // 2.69 m is close to the envelope, but outside the handbook's 2.60 to 2.66 m.
        XCTAssertFalse(AircraftMassBalance.EmptyMass(mass: 330, moment: 887.7, date: "2025-03-10").isPlausible(for: data))
    }

    func testWithoutAnEmptyMassNothingIsComputedAndNothingIsClaimed() {
        var data = metric
        data.empty = nil
        let result = MassBalanceCalculator.compute(data: data, empty: nil, load: soloMetric(), isConfirmed: true)
        XCTAssertEqual(result.verdict, .notConfirmed)
        XCTAssertNil(result.takeoff)
        XCTAssertNil(result.landing)
    }

    // MARK: - The arithmetic, against loads worked by hand

    func testAMetricLoadWorkedByHand() {
        // Empty 330 kg, 867.9 kg·m. Pilot 80 kg at 3.10 = 248. Baggage 10 kg at 3.80 = 38.
        // Fuel 50 l × 0.72 = 36 kg at 2.50 = 90. Take-off 456 kg, 1243.9 kg·m, CG 2.72785 m.
        let result = compute(metric, soloMetric())
        XCTAssertEqual(result.takeoff?.mass ?? 0, 456, accuracy: 1e-9)
        XCTAssertEqual(result.takeoff?.arm ?? 0, 1243.9 / 456, accuracy: 1e-9)
        // Landing after 20 l: 30 l left = 21.6 kg at 2.50 = 54. 441.6 kg, 1207.9 kg·m.
        XCTAssertEqual(result.landing?.mass ?? 0, 441.6, accuracy: 1e-9)
        XCTAssertEqual(result.landing?.arm ?? 0, 1207.9 / 441.6, accuracy: 1e-9)
        XCTAssertEqual(result.landing?.fuelLitres, 30)
        // Empty tanks: 420 kg, 1153.9 kg·m.
        XCTAssertEqual(result.emptyTanks?.mass ?? 0, 420, accuracy: 1e-9)
        XCTAssertEqual(result.emptyTanks?.arm ?? 0, 1153.9 / 420, accuracy: 1e-9)
        XCTAssertEqual(result.massMargin ?? 0, 144, accuracy: 1e-9)
        XCTAssertNil(result.rampMass, "this aircraft has no ramp limit")
    }

    func testAnImperialLoadWorkedByHandWithTheTaxiFuelTakenOff() {
        // Pilot 80 kg = 176.3698 lb at 80. Fuel typed: 151.416 l = 40 US gal = 240 lb at 95.
        // Ramp 1500 + 176.3698 + 240 = 1916.3698 lb. Taxi fuel 10 lb: take-off 1906.3698 lb.
        let litres = 40 * 3.785411784
        let load = MassBalanceLoad(seats: ["pilot": .person(kg: 80), "front": .empty, "rearLeft": .empty, "rearRight": .empty],
                                   baggageKg: ["baggage": 0], fuelLitres: litres, tripLitres: nil, isTodays: true)
        let result = compute(imperial, load, empty: imperialEmpty)
        let pilot = 80 * 2.2046226218
        XCTAssertEqual(result.rampMass ?? 0, 1500 + pilot + 240, accuracy: 1e-6)
        XCTAssertEqual(result.takeoff?.mass ?? 0, 1500 + pilot + 230, accuracy: 1e-6)
        XCTAssertEqual(result.takeoff?.arm ?? 0, (130_500 + pilot * 80 + 230 * 95) / (1500 + pilot + 230), accuracy: 1e-6)
        XCTAssertEqual(result.takeoff?.fuelLitres ?? 0, 230 / 6.0 * 3.785411784, accuracy: 1e-6)
        XCTAssertNil(result.landing, "no trip fuel, no landing point")
        XCTAssertEqual(result.verdict, .insideLimits)
    }

    func testTheRampMassIsCheckedWithTheFuelAsTyped() {
        // 4 × 85 kg = 749.57 lb, full tanks 300 lb: ramp 2549.57 lb, over 2410.
        let load = MassBalanceLoad(seats: ["pilot": .person(kg: 85), "front": .person(kg: 85), "rearLeft": .person(kg: 85), "rearRight": .person(kg: 85)],
                                   baggageKg: ["baggage": 0], fuelLitres: 50 * 3.785411784, isTodays: true)
        let result = compute(imperial, load, empty: imperialEmpty)
        XCTAssertEqual(result.verdict, .outsideLimits)
        guard case .overMaxRamp(let by)? = result.failures.first else { return XCTFail("\(result.failures)") }
        XCTAssertEqual(by, 1500 + 4 * 85 * 2.2046226218 + 300 - 2410, accuracy: 1e-6)
        XCTAssertTrue(result.failures.contains { if case .overMaxTakeoff = $0 { return true } else { return false } })
    }

    // MARK: - The five states, in order

    func testInsideLimitsNeedsEverythingEnteredConfirmedAndSaidToBeTodays() {
        XCTAssertEqual(compute(metric, soloMetric()).verdict, .insideLimits)

        var carried = soloMetric()
        carried.isTodays = false
        XCTAssertEqual(compute(metric, carried).verdict, .lastTimesLoad)
        XCTAssertEqual(compute(metric, carried, confirmed: false).verdict, .notConfirmed)

        var blankSeat = soloMetric()
        blankSeat.seats["passenger"] = nil
        XCTAssertEqual(compute(metric, blankSeat, confirmed: false).verdict, .incomplete)
        XCTAssertEqual(compute(metric, blankSeat).unset, ["passenger"])
    }

    func testAFailureIsReportedBeforeAnythingThatIsMissing() {
        // Two people of 130 kg, 40 kg of bags, no fuel entered: too heavy whatever the fuel.
        let load = MassBalanceLoad(seats: ["pilot": .person(kg: 130), "passenger": .person(kg: 130)],
                                   baggageKg: ["baggage": 40], fuelLitres: nil, isTodays: false)
        let result = compute(metric, load, confirmed: false)
        XCTAssertEqual(result.verdict, .outsideLimits)
        XCTAssertEqual(result.unset, ["fuel"])
        XCTAssertTrue(result.failures.contains { if case .overMaxTakeoff = $0 { return true } else { return false } })
    }

    func testABlankSheetIsIncompleteNotOutside() {
        // The empty aircraft alone is under the minimum flying mass. With every row still to enter,
        // that says nothing about the flight.
        let result = compute(metric, MassBalanceLoad())
        XCTAssertEqual(result.verdict, .incomplete)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(Set(result.unset), ["pilot", "passenger", "baggage", "fuel"])
        XCTAssertNil(result.notBelowLitres)
    }

    func testABlankBoxIsNeverZero() {
        var load = soloMetric()
        load.baggageKg = [:]
        XCTAssertEqual(compute(metric, load).verdict, .incomplete)
        load.baggageKg = ["baggage": 0]
        XCTAssertEqual(compute(metric, load).verdict, .insideLimits, "zero is an answer")
    }

    func testAPilotsSeatSaidEmptyIsNotAnAnswer() {
        let load = MassBalanceLoad(seats: ["pilot": .empty, "passenger": .person(kg: 80)],
                                   baggageKg: ["baggage": 0], fuelLitres: 50, isTodays: true)
        let result = compute(metric, load)
        XCTAssertEqual(result.verdict, .incomplete)
        XCTAssertEqual(result.unset, ["pilot"])
    }

    func testACarriedOverLoadIsNotTodaysUntilSaidSo() {
        let day = Date(timeIntervalSince1970: 1_762_000_000)
        let carried = soloMetric().carriedOver(from: day)
        XCTAssertFalse(carried.isTodays)
        XCTAssertEqual(carried.copiedFrom, day)
        XCTAssertEqual(compute(metric, carried).verdict, .lastTimesLoad)
    }

    // MARK: - Limits

    func testOverTheMaximumMassSaysByHowMuchAndHowMuchFuelFits() {
        // 110 + 110 kg, 10 kg of bags, 90 l (64.8 kg): 624.8 kg, 24.8 over.
        let load = MassBalanceLoad(seats: ["pilot": .person(kg: 110), "passenger": .person(kg: 110)],
                                   baggageKg: ["baggage": 10], fuelLitres: 90, isTodays: true)
        let result = compute(metric, load)
        XCTAssertEqual(result.verdict, .outsideLimits)
        guard case .overMaxTakeoff(let by)? = result.failures.first else { return XCTFail("\(result.failures)") }
        XCTAssertEqual(by, 24.8, accuracy: 1e-9)
        // Without fuel: 560 kg. 40 kg of fuel fit: 55.6 l, so 55 whole litres.
        XCTAssertEqual(result.mostFuelLitres, 55)
    }

    func testExactlyAtTheMaximumMassIsInside() {
        // 330 + 100 + 100 + 34 = 564 kg without fuel; 50 l = 36 kg makes 600 kg exactly.
        let load = MassBalanceLoad(seats: ["pilot": .person(kg: 100), "passenger": .person(kg: 100)],
                                   baggageKg: ["baggage": 34], fuelLitres: 50, isTodays: true)
        let result = compute(metric, load)
        XCTAssertEqual(result.takeoff?.mass ?? 0, 600, accuracy: 1e-9)
        XCTAssertEqual(result.takeoff?.isInside, true)
        XCTAssertEqual(result.massMargin ?? 1, 0, accuracy: 1e-9)
    }

    func testSeatBaggageAndFuelLimitsAreReportedAtTheirRow() {
        let load = MassBalanceLoad(seats: ["pilot": .person(kg: 50), "passenger": .person(kg: 125)],
                                   baggageKg: ["baggage": 45], fuelLitres: 95, isTodays: true)
        let result = compute(metric, load)
        XCTAssertEqual(result.verdict, .outsideLimits)
        XCTAssertEqual(Set(result.failures.compactMap(\.stationOrSeatId)), ["pilot", "passenger", "baggage", "fuel"])
        XCTAssertTrue(result.failures.contains(.seatUnderMinimum(seatId: "pilot", minimum: 55)))
        XCTAssertTrue(result.failures.contains(.seatOverMaximum(seatId: "passenger", maximum: 120)))
        XCTAssertTrue(result.failures.contains(.baggageOverMaximum(stationId: "baggage", maximum: 40)))
        XCTAssertTrue(result.failures.contains(.fuelOverUsable(usableLitres: 90)))
    }

    func testABaggageLimitInPoundsIsHeldAgainstKilogramsTyped() {
        // 200 lb is 90.7 kg: 90 kg passes, 91 kg does not.
        func load(_ bags: Double) -> MassBalanceLoad {
            MassBalanceLoad(seats: ["pilot": .person(kg: 80), "front": .empty, "rearLeft": .empty, "rearRight": .empty],
                            baggageKg: ["baggage": bags], fuelLitres: 100, isTodays: true)
        }
        XCTAssertFalse(compute(imperial, load(90), empty: imperialEmpty).failures.contains { $0.stationOrSeatId == "baggage" })
        XCTAssertTrue(compute(imperial, load(91), empty: imperialEmpty).failures.contains(.baggageOverMaximum(stationId: "baggage", maximum: 200)))
    }

    func testTheCGOutsideSaysWhichSide() {
        // A light pilot alone with full tanks: the fuel sits ahead of the forward limit.
        let forward = compute(metric, MassBalanceLoad(seats: ["pilot": .person(kg: 55), "passenger": .empty],
                                                      baggageKg: ["baggage": 0], fuelLitres: 90, isTodays: true))
        XCTAssertEqual(forward.failures, [.takeoffOutside(.aheadOfForwardLimit)])
        // Two heavy people and full bags with little fuel: behind the aft limit.
        let aft = compute(metric, MassBalanceLoad(seats: ["pilot": .person(kg: 115), "passenger": .person(kg: 115)],
                                                  baggageKg: ["baggage": 40], fuelLitres: 0, isTodays: true))
        XCTAssertEqual(aft.takeoff?.outside, .behindAftLimit)
        XCTAssertEqual(aft.verdict, .outsideLimits)
    }

    // MARK: - Down the tanks

    func testTheSheetSaysBelowHowManyLitresTheAircraftLeavesTheLimits() {
        // Pilot 65 kg alone, no bags: 395 kg without fuel, under the 400 kg minimum. With 18 l it is
        // inside; the tanks may not go below 7 l (5.04 kg makes 400.04 kg; 6 l makes 399.32 kg).
        let load = MassBalanceLoad(seats: ["pilot": .person(kg: 65), "passenger": .empty],
                                   baggageKg: ["baggage": 0], fuelLitres: 18, tripLitres: 5, isTodays: true)
        let result = compute(metric, load)
        XCTAssertEqual(result.verdict, .insideLimits, "take-off and the planned landing decide")
        XCTAssertEqual(result.emptyTanks?.isInside, false)
        let level = try! XCTUnwrap(result.notBelowLitres)
        XCTAssertEqual(level, 7)
        XCTAssertEqual(result.notBelowReason, .underMinimumMass)
        // At that level it is inside; one litre lower it is not.
        var at = load; at.fuelLitres = level; at.tripLitres = 0
        var under = load; under.fuelLitres = level - 1; under.tripLitres = 0
        XCTAssertEqual(compute(metric, at).takeoff?.isInside, true)
        XCTAssertEqual(compute(metric, under).takeoff?.isInside, false)
    }

    func testAPlannedLandingBelowThatLevelIsOutsideLimits() {
        let load = MassBalanceLoad(seats: ["pilot": .person(kg: 65), "passenger": .empty],
                                   baggageKg: ["baggage": 0], fuelLitres: 18, tripLitres: 17, isTodays: true)
        let result = compute(metric, load)
        XCTAssertEqual(result.verdict, .outsideLimits)
        guard case .landingOutside(_, let left)? = result.failures.first else { return XCTFail("\(result.failures)") }
        XCTAssertEqual(left, 1)
    }

    func testAnAircraftThatStaysInsideDownToEmptyTanksHasNoSuchLevel() {
        let result = compute(metric, soloMetric(pilotKg: 90))
        XCTAssertEqual(result.emptyTanks?.isInside, true)
        XCTAssertNil(result.notBelowLitres)
    }

    // MARK: - The file's other limits, the fuel line and the trip (review of 14 Nov 2026)

    /// The two-seater with its JSON changed, for a limit the shipped fixture leaves at its default.
    private func metric(replacing old: String, with new: String) -> AircraftMassBalance {
        XCTAssertTrue(metricJSON.contains(old), old)
        return try! decode(metricJSON.replacingOccurrences(of: old, with: new))
    }

    /// ST11-09. A landing limit under the take-off limit: 570.4 kg at take-off, inside; 563.2 kg at
    /// the landing, inside the envelope but over a 560 kg maximum landing mass.
    func testALandingOverTheMaximumLandingMassIsOutsideLimits() {
        let data = metric(replacing: #""maxLanding": 600"#, with: #""maxLanding": 560"#)
        let load = MassBalanceLoad(seats: ["pilot": .person(kg: 80), "passenger": .person(kg: 100)],
                                   baggageKg: ["baggage": 10], fuelLitres: 70, tripLitres: 10, isTodays: true)
        let result = compute(data, load)
        XCTAssertEqual(result.takeoff?.isInside, true)
        XCTAssertEqual(result.landing?.mass ?? 0, 563.2, accuracy: 1e-9)
        XCTAssertEqual(result.verdict, .outsideLimits)
        XCTAssertEqual(result.landing?.outside, .overMaximumLandingMass)
        XCTAssertEqual(result.failures, [.landingOutside(.overMaximumLandingMass, litresLeft: 60)])
        // The same load on the fixture, where the landing limit is the take-off one: inside.
        XCTAssertEqual(compute(metric, load).verdict, .insideLimits)
    }

    /// ST11-09. A minimum flying mass above the envelope's floor: 456 kg at 2.7125 m is inside the
    /// drawn corners and under a 470 kg minimum.
    func testATakeOffUnderTheMinimumFlyingMassIsOutsideLimits() {
        let data = metric(replacing: #""minFlying": 400"#, with: #""minFlying": 470"#)
        let load = MassBalanceLoad(seats: ["pilot": .person(kg: 90), "passenger": .empty],
                                   baggageKg: ["baggage": 0], fuelLitres: 50, tripLitres: 10, isTodays: true)
        let result = compute(data, load)
        XCTAssertEqual(result.takeoff?.mass ?? 0, 456, accuracy: 1e-9)
        XCTAssertTrue(MassBalanceCalculator.contains(arm: result.takeoff?.arm ?? 0, mass: 456,
                                                     envelope: data.mainCategory!.envelope), "inside the corners")
        XCTAssertEqual(result.verdict, .outsideLimits)
        XCTAssertEqual(result.failures.first, .takeoffOutside(.underMinimumMass))
        XCTAssertEqual(compute(metric, load).verdict, .insideLimits)
    }

    /// An invented single-seater with a notch in its envelope's aft edge, 450 kg at 2.8447 m without
    /// fuel. Take-off with 125 L and the landing with 28 L are both inside; between them, at 83 L, the
    /// fuel line crosses the notch.
    private let notched = """
    { "schema": 1, "aircraftId": "test-notch", "registration": "T-EST2", "revision": 1, "updated": "2026-01-15",
      "units": { "mass": "kg", "arm": "m", "fuel": "l" },
      "limits": { "maxTakeoff": 600 },
      "categories": [ { "id": "normal", "maxTakeoff": 600,
        "envelope": [[2.70, 400], [2.70, 600], [2.85, 600], [2.85, 520], [2.76, 500], [2.85, 480], [2.85, 400]] } ],
      "stations": [
        { "id": "row1", "kind": "seats", "arm": 3.10, "layout": "single", "seats": [ { "id": "pilot", "role": "pilot" } ] },
        { "id": "fuel", "kind": "fuel", "arm": 2.50, "usable": 150, "density": 0.72 } ],
      "empty": { "mass": 370, "moment": 1032.115, "date": "2025-03-10" },
      "sources": [] }
    """

    /// ST11-26. Take-off and the planned landing decide, and so does the flight between them.
    func testAFuelLineLeavingTheEnvelopeBeforeTheLandingIsOutsideLimits() throws {
        let data = try decode(notched)
        let load = MassBalanceLoad(seats: ["pilot": .person(kg: 80)], fuelLitres: 125, tripLitres: 97, isTodays: true)
        let result = MassBalanceCalculator.compute(data: data, empty: data.empty, load: load, isConfirmed: true)
        XCTAssertEqual(result.takeoff?.isInside, true)
        XCTAssertEqual(result.landing?.isInside, true)
        XCTAssertEqual(result.landing?.fuelLitres, 28)
        XCTAssertEqual(result.notBelowLitres, 84)
        XCTAssertEqual(result.verdict, .outsideLimits)
        XCTAssertEqual(result.failures, [.fuelLineOutside(.behindAftLimit, litresLeft: 83)])
        // A trip that lands above the notch is inside, with "not below 84 litres".
        var short = load
        short.tripLitres = 30
        let inside = MassBalanceCalculator.compute(data: data, empty: data.empty, load: short, isConfirmed: true)
        XCTAssertEqual(inside.verdict, .insideLimits)
        XCTAssertEqual(inside.notBelowLitres, 84)
    }

    /// ST11-37. A trip the fuel can't cover: no landing at empty tanks called inside.
    func testATripLargerThanTheFuelAtTakeOffIsOutsideLimits() {
        let result = compute(metric, soloMetric(fuel: 30, trip: 40))
        XCTAssertEqual(result.verdict, .outsideLimits)
        XCTAssertNil(result.landing, "no landing to draw")
        XCTAssertEqual(result.failures, [.tripOverFuel(tripLitres: 40, takeoffLitres: 30)])
        XCTAssertEqual(result.failures.first?.stationOrSeatId, MassBalanceResult.fuelRowId, "the fuel row is marked")
        // A trip of all the fuel lands with empty tanks, which is a landing.
        XCTAssertEqual(compute(metric, soloMetric(fuel: 30, trip: 30)).verdict, .insideLimits)
        // Fuel not entered yet: nothing to compare the trip with.
        XCTAssertEqual(compute(metric, soloMetric(fuel: nil, trip: 40)).verdict, .incomplete)
    }

    /// ST11-05. A usable fuel of nine digits was a countdown of a hundred million steps at every
    /// computation, and from sixteen digits one that never ended. Such a file is not used.
    func testAFileWithAnImplausibleFigureIsNotUsed() {
        XCTAssertTrue(metric.isUsable)
        XCTAssertFalse(metric(replacing: #""usable": 90"#, with: #""usable": 123456789"#).isUsable)
        XCTAssertFalse(metric(replacing: #""maxTakeoff": 600, "maxLanding""#, with: #""maxTakeoff": 6e9, "maxLanding""#).isUsable)
        XCTAssertFalse(metric(replacing: "[2.70, 400], [2.70, 540]", with: "[2.70, 400], [1e9, 540]").isUsable)
        XCTAssertFalse(metric(replacing: #""density": 0.72"#, with: #""density": 720"#).isUsable)
    }

    /// ST11-05. A stored or synced load with a figure no box takes reads that figure as not entered.
    func testAStoredLoadWithAnImplausibleFigureDropsIt() throws {
        let json = #"{"seats": {"pilot": {"state": "person", "kg": 1e9}, "passenger": {"state": "person", "kg": 70}},"#
            + #" "baggageKg": {"baggage": 5000}, "fuelLitres": 1e12, "tripLitres": 6000, "isTodays": true}"#
        let load = try JSONDecoder().decode(MassBalanceLoad.self, from: Data(json.utf8))
        XCTAssertEqual(load.seats["pilot"], .unset)
        XCTAssertEqual(load.seats["passenger"], .person(kg: 70))
        XCTAssertTrue(load.baggageKg.isEmpty)
        XCTAssertNil(load.fuelLitres)
        XCTAssertNil(load.tripLitres)
    }

    // MARK: - Categories

    func testTheFirstCategoryDecidesAndTheOtherGetsItsSentence() {
        func load(rear: MassBalanceSeatLoad, fuelGal: Double) -> MassBalanceLoad {
            MassBalanceLoad(seats: ["pilot": .person(kg: 80), "front": .person(kg: 70), "rearLeft": rear, "rearRight": .empty],
                            baggageKg: ["baggage": 0], fuelLitres: fuelGal * 3.785411784, isTodays: true)
        }
        // Two in front, 20 gal: 1500 + 330.7 + 120 = 1950.7 lb at the ramp. Inside utility too.
        let light = compute(imperial, load(rear: .empty, fuelGal: 20), empty: imperialEmpty)
        XCTAssertEqual(light.verdict, .insideLimits)
        XCTAssertEqual(light.otherCategories, [MassBalanceCategoryNote(categoryId: "utility", isInside: true, loadsForbiddenStation: false)])

        // Full tanks: over utility's 2000 lb, still inside normal.
        let heavy = compute(imperial, load(rear: .empty, fuelGal: 50), empty: imperialEmpty)
        XCTAssertEqual(heavy.verdict, .insideLimits)
        XCTAssertEqual(heavy.otherCategories.first?.isInside, false)
        XCTAssertEqual(heavy.otherCategories.first?.loadsForbiddenStation, false)

        // Somebody in the back: utility does not allow it, whatever the mass.
        let rear = compute(imperial, load(rear: .person(kg: 20), fuelGal: 5), empty: imperialEmpty)
        XCTAssertEqual(rear.otherCategories.first?.loadsForbiddenStation, true)
        XCTAssertEqual(rear.otherCategories.first?.isInside, false)
    }

    // MARK: - Geometry

    func testTheForwardLimitMovesBackAsTheAircraftGetsHeavier() {
        let envelope = imperial.mainCategory!.envelope
        XCTAssertEqual(MassBalanceCalculator.limits(atMass: 1800, envelope: envelope)?.forward, 80)
        XCTAssertEqual(MassBalanceCalculator.limits(atMass: 2200, envelope: envelope)?.forward ?? 0, 83, accuracy: 1e-9)
        XCTAssertEqual(MassBalanceCalculator.limits(atMass: 2200, envelope: envelope)?.aft, 92)
        XCTAssertNil(MassBalanceCalculator.limits(atMass: 2500, envelope: envelope))
    }

    func testAPointOnAnEdgeIsInsideInEitherUnitSystem() {
        XCTAssertTrue(MassBalanceCalculator.contains(arm: 83, mass: 2200, envelope: imperial.mainCategory!.envelope))
        XCTAssertFalse(MassBalanceCalculator.contains(arm: 82.99, mass: 2200, envelope: imperial.mainCategory!.envelope))
        // The sloped lower edge of the metric envelope, from (2.72, 400) to (2.85, 460).
        let metricEnvelope = metric.mainCategory!.envelope
        XCTAssertTrue(MassBalanceCalculator.contains(arm: 2.785, mass: 430, envelope: metricEnvelope))
        XCTAssertFalse(MassBalanceCalculator.contains(arm: 2.80, mass: 430, envelope: metricEnvelope))
        XCTAssertEqual(MassBalanceCalculator.outside(arm: 2.80, mass: 430, category: metric.mainCategory!), .behindAftLimit)
        XCTAssertEqual(MassBalanceCalculator.outside(arm: 2.75, mass: 390, category: metric.mainCategory!), .underMinimumMass)
    }

    // MARK: - Stored loads

    func testALoadWrittenByThisBuildReadsBackAndAnOlderShapeStillDecodes() throws {
        let load = soloMetric()
        XCTAssertEqual(try JSONDecoder().decode(MassBalanceLoad.self, from: JSONEncoder().encode(load)), load)
        // Nothing but a fuel figure: every other field takes its default, and nothing is today's.
        let sparse = try JSONDecoder().decode(MassBalanceLoad.self, from: Data(#"{"fuelLitres": 40}"#.utf8))
        XCTAssertEqual(sparse, MassBalanceLoad(fuelLitres: 40))
        XCTAssertFalse(sparse.isTodays)
        // A seat state this build does not know reads as not entered, never as empty.
        let odd = try JSONDecoder().decode(MassBalanceLoad.self, from: Data(#"{"seats": {"pilot": {"state": "child"}}}"#.utf8))
        XCTAssertEqual(odd.seats["pilot"], .unset)
    }
}
