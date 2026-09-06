import XCTest
@testable import AeroCheck

/// The v5.0.0 "numbers": the EASA logbook line, the cost ledger and the mass & balance calculator.
/// All three are pure, so this suite never touches a service, a clock or the filesystem.
final class FlightNumbersTests: XCTestCase {

    // MARK: - Helpers

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    /// A Bressaucourt → Yverdon hop: block 13:02z to 14:31z, one full stop.
    private func flight(
        blockOff: String = "2026-09-06T13:02:00Z",
        blockOn: String = "2026-09-06T14:31:00Z",
        registration: String? = "HB-KFD",
        type: String? = "DR400/140B",
        instructor: String? = nil,
        touchAndGo: Int = 0,
        fullStop: Int = 1,
        engineHours: (Double, Double)? = nil
    ) -> Flight {
        var f = Flight(airplane: "dr400-140b",
                       aircraftRegistration: registration,
                       aircraftType: type)
        f.blockOffTime = date(blockOff)
        f.blockOnTime = date(blockOn)
        f.lineUpTime = date(blockOff).addingTimeInterval(5 * 60)
        f.landingTime = date(blockOn).addingTimeInterval(-5 * 60)
        f.departureAirportIdent = "LSZQ"
        f.arrivalAirportIdent = "LSGY"
        f.touchAndGoCount = touchAndGo
        f.fullStopCount = fullStop
        if let engineHours {
            f.engineHourStart = engineHours.0
            f.engineHourEnd = engineHours.1
        }
        if let instructor {
            var plan = FlightPlan(name: "Test")
            plan.instructor = instructor
            f.flightPlan = plan
        }
        return f
    }

    // MARK: - Logbook line

    func testLineDerivesTheColumnsTheFlightActuallyKnows() {
        let line = LogbookLineBuilder.build(flight: flight())

        XCTAssertEqual(line.date, "06.09.2026")
        XCTAssertEqual(line.departurePlace, "LSZQ")
        XCTAssertEqual(line.arrivalPlace, "LSGY")
        XCTAssertEqual(line.departureTimeUTC, "13:02")
        XCTAssertEqual(line.arrivalTimeUTC, "14:31")
        XCTAssertEqual(line.totalTime, "1:29")
        XCTAssertEqual(line.aircraftRegistration, "HB-KFD")
        XCTAssertEqual(line.landingsDay, 1)
    }

    // MARK: - The line laid out as the form (v5.x)

    func testFormRowPutsEachValueUnderTheFormsOwnHeading() {
        let row = LogbookFormRow.build(from: LogbookLineBuilder.build(flight: flight()))

        func cells(_ title: String) -> [LogbookFormRow.Cell] {
            row.groups.first { $0.title == title }?.cells ?? []
        }

        XCTAssertEqual(row.groups.count, 12, "AMC1 FCL.050 has twelve column groups")
        XCTAssertEqual(cells("DATE").first?.value, "06.09.2026")
        XCTAssertEqual(cells("DEPARTURE").map(\.value), ["LSZQ", "13:02"])
        XCTAssertEqual(cells("ARRIVAL").map(\.value), ["LSGY", "14:31"])
        XCTAssertEqual(cells("AIRCRAFT").map(\.value), ["DR400/140B", "HB-KFD"])
        XCTAssertEqual(cells("TOTAL TIME").first?.value, "1:29")
        XCTAssertEqual(cells("LANDINGS").map(\.label), ["DAY", "NIGHT"])
    }

    /// The form has one column per pilot role and the time belongs under exactly one. The rest stay
    /// BLANK, not "0:00" — a zero claims the pilot logged nothing in that role, which is a different
    /// statement from not having flown in it.
    func testFormRowPutsFunctionTimeUnderOneRoleAndLeavesTheOthersBlank() {
        let solo = LogbookFormRow.build(from: LogbookLineBuilder.build(flight: flight()))
        let soloFunction = solo.groups.first { $0.title == "PILOT FUNCTION TIME" }
        XCTAssertEqual(soloFunction?.cells.map(\.label), ["PIC", "CO-PILOT", "DUAL", "INSTR"])
        XCTAssertEqual(soloFunction?.cells.map(\.value), ["1:29", "", "", ""])

        let dual = LogbookFormRow.build(
            from: LogbookLineBuilder.build(flight: flight(instructor: "M. Dupont")))
        let dualFunction = dual.groups.first { $0.title == "PILOT FUNCTION TIME" }
        XCTAssertEqual(dualFunction?.cells.map(\.value), ["", "", "1:29", ""])
    }

    /// Single-engine time is known; the ME column is not the app's to fill.
    func testFormRowLeavesColumnsTheAppCannotKnowEmpty() {
        let row = LogbookFormRow.build(from: LogbookLineBuilder.build(flight: flight()))

        XCTAssertEqual(row.groups.first { $0.title == "SINGLE-PILOT TIME" }?.cells.map(\.value),
                       ["1:29", ""])
        XCTAssertEqual(row.groups.first { $0.title == "MULTI-PILOT" }?.cells.map(\.value), [""])
        XCTAssertEqual(row.groups.first { $0.title == "OPERATIONAL CONDITION TIME" }?.cells.map(\.value),
                       ["", ""], "night and IFR are the pilot's to enter")
    }

    func testTimesAreUTCNotLocal() {
        // AMC1 FCL.050 is explicit that logbook times are UTC. A local time silently written into
        // that column is the error nobody catches until an audit.
        let summer = flight(blockOff: "2026-07-01T13:02:00Z", blockOn: "2026-07-01T14:00:00Z")
        XCTAssertEqual(LogbookLineBuilder.build(flight: summer).departureTimeUTC, "13:02",
                       "must not shift by the device's timezone or DST")
    }

    func testFunctionDefaultsToPICAndFlipsToDualWithAnInstructor() {
        XCTAssertEqual(LogbookLineBuilder.build(flight: flight()).functionLabel, L10n.Logbook.functionPIC)

        let dual = LogbookLineBuilder.build(flight: flight(instructor: "M. Dupont"))
        XCTAssertEqual(dual.functionLabel, L10n.Logbook.functionDual)
        // On a dual flight the PIC is the instructor; logging "SELF" there would be a false entry.
        XCTAssertEqual(dual.picName, "M. Dupont")
    }

    func testPilotNameIsUsedForASoloFlight() {
        let line = LogbookLineBuilder.build(flight: flight(), defaultPilotName: "J. Bono")
        XCTAssertEqual(line.picName, "J. Bono")

        let anonymous = LogbookLineBuilder.build(flight: flight(), defaultPilotName: "   ")
        XCTAssertEqual(anonymous.picName, "SELF", "the convention when the writer is the PIC")
    }

    func testOverridesWinOverEverythingDerived() {
        var overrides = LogbookOverrides()
        overrides.function = .instructor
        overrides.picName = "SELF"
        overrides.nightMinutes = 45
        overrides.ifrMinutes = 20
        overrides.remarks = "Night currency"

        let line = LogbookLineBuilder.build(flight: flight(instructor: "M. Dupont"),
                                            overrides: overrides,
                                            defaultPilotName: "J. Bono")

        XCTAssertEqual(line.functionLabel, L10n.Logbook.functionInstructor)
        XCTAssertEqual(line.picName, "SELF")
        XCTAssertEqual(line.nightTime, "0:45")
        XCTAssertEqual(line.ifrTime, "0:20")
        XCTAssertEqual(line.remarks, "Night currency")
    }

    func testNightAndIFRAreEmptyUntilThePilotEntersThem() {
        // Deliberately not computed: EASA night runs from the end of evening civil twilight, and a
        // plausible wrong number in a logbook column is worse than an empty one.
        let line = LogbookLineBuilder.build(flight: flight())
        XCTAssertEqual(line.nightTime, "")
        XCTAssertEqual(line.ifrTime, "")
        XCTAssertEqual(line.landingsNight, 0)
    }

    func testTouchAndGosCountAsLandingsAndAreRemarked() {
        let line = LogbookLineBuilder.build(flight: flight(touchAndGo: 5, fullStop: 1))
        XCTAssertEqual(line.landingsDay, 6, "a logbook counts landings, and a touch-and-go is one")
        XCTAssertTrue(line.remarks.contains("5"))
    }

    func testCSVEscapesSeparatorsInsideAField() {
        var overrides = LogbookOverrides()
        overrides.remarks = "Circuits, then a diversion"
        let line = LogbookLineBuilder.build(flight: flight(), overrides: overrides)

        let csv = LogbookLineBuilder.csv(for: [line])
        XCTAssertTrue(csv.contains("\"Circuits, then a diversion\""))
        XCTAssertEqual(csv.split(separator: "\n").count, 2, "header plus one row")
    }

    func testPlainTextSkipsEmptyColumns() {
        let text = LogbookLineBuilder.plainText(for: LogbookLineBuilder.build(flight: flight()))
        XCTAssertTrue(text.contains("Total time: 1:29"))
        XCTAssertFalse(text.contains("Night:"), "an empty column is noise on a copied line")
    }

    // MARK: - Cost

    func testBillableHoursFollowTheClubsBasis() {
        let f = flight(engineHours: (1234.0, 1235.6))

        let block = FlightCostCalculator.billableHours(for: f, basis: .block)!
        XCTAssertEqual(block, 89.0 / 60.0, accuracy: 0.001)

        let engine = FlightCostCalculator.billableHours(for: f, basis: .engineHours)!
        XCTAssertEqual(engine, 1.6, accuracy: 0.001)

        // Flight time is line-up to landing, which is shorter than block.
        let air = FlightCostCalculator.billableHours(for: f, basis: .flight)!
        XCTAssertLessThan(air, block)
    }

    func testEngineHoursBasisRefusesToGuessWhenTheCounterWasNotLogged() {
        // A club billing on engine hours cannot be costed from a flight with no counter reading.
        // Inventing one would quietly misstate a year's spending.
        XCTAssertNil(FlightCostCalculator.billableHours(for: flight(), basis: .engineHours))
    }

    func testEntryMultipliesRateByTheBilledHours() {
        let profile = AircraftRateProfile(hourlyRate: 318, currency: "CHF", basis: .block)
        var entry = FlightCostCalculator.makeEntry(for: flight(), profile: profile)
        entry.fees = [FeeItem(label: "Landing", amount: 20, icao: "LSGY")]

        XCTAssertEqual(entry.aircraftCost, 318 * (89.0 / 60.0), accuracy: 0.01)
        XCTAssertEqual(entry.feesTotal, 20)
        XCTAssertEqual(entry.total, entry.aircraftCost + 20, accuracy: 0.01)
    }

    func testEntryIsEmptyWithoutARateProfile() {
        let entry = FlightCostCalculator.makeEntry(for: flight(), profile: nil)
        XCTAssertTrue(entry.isEmpty)
        XCTAssertEqual(entry.total, 0)
    }

    func testRateProfileIsKeyedByRegistrationBecauseTailsDiffer() {
        XCTAssertEqual(FlightCostCalculator.profileKey(for: flight()), "HB-KFD")
        XCTAssertEqual(FlightCostCalculator.profileKey(for: flight(registration: nil)), "DR400/140B")
        XCTAssertNil(FlightCostCalculator.profileKey(for: flight(registration: nil, type: nil)))
    }

    func testLedgerReportsWhatIsMissingAlongsideTheTotal() {
        // A yearly total built from two of five flights is not a yearly total, and a dashboard
        // showing only the sum invites reading it as one.
        var withCost = flight()
        withCost.costEntry = {
            var e = FlightCostEntry()
            e.currency = "CHF"; e.hourlyRate = 300; e.basis = .block; e.billedHours = 1
            e.fees = [FeeItem(label: "Landing", amount: 20)]
            return e
        }()

        let summary = CostLedger.summarize(flights: [withCost, flight(), flight()])

        XCTAssertEqual(summary.aircraftCost, 300, accuracy: 0.01)
        XCTAssertEqual(summary.fees, 20, accuracy: 0.01)
        XCTAssertEqual(summary.total, 320, accuracy: 0.01)
        XCTAssertEqual(summary.flightsWithCost, 1)
        XCTAssertEqual(summary.flightsMissingCost, 2)
    }

    func testLedgerDoesNotAddFrancsToEuros() {
        func costed(_ currency: String, _ amount: Double) -> Flight {
            var f = flight()
            var e = FlightCostEntry()
            e.currency = currency; e.hourlyRate = amount; e.basis = .block; e.billedHours = 1
            f.costEntry = e
            return f
        }

        let summary = CostLedger.summarize(flights: [costed("CHF", 300), costed("CHF", 200), costed("EUR", 999)])

        XCTAssertEqual(summary.currency, "CHF", "the most common currency wins")
        XCTAssertEqual(summary.aircraftCost, 500, accuracy: 0.01)
        XCTAssertEqual(summary.flightsMissingCost, 1, "the euro flight is excluded, and said so")
    }

    func testLedgerOfNothingIsHonestRatherThanZero() {
        let summary = CostLedger.summarize(flights: [flight(), flight()])
        XCTAssertEqual(summary.flightsWithCost, 0)
        XCTAssertEqual(summary.flightsMissingCost, 2)
        XCTAssertEqual(summary.total, 0)
    }

    // MARK: - Mass & balance

    /// A plausible four-seater: empty 600 kg at 0.30 m, MTOW 1000 kg.
    private func profile(stations: [WeightBalanceStation], envelope: [EnvelopePoint]? = nil) -> WeightBalanceProfile {
        WeightBalanceProfile(emptyWeightKg: 600,
                             emptyArmMeters: 0.30,
                             maxTakeoffWeightKg: 1000,
                             stations: stations,
                             envelope: envelope)
    }

    func testComputesMassAndCentreOfGravity() {
        let result = WeightBalanceCalculator.compute(profile: profile(stations: [
            WeightBalanceStation(name: "Front", armMeters: 0.40, weightKg: 160),
            WeightBalanceStation(name: "Fuel", armMeters: 0.60, weightKg: 60),
        ]))

        XCTAssertEqual(result.totalWeightKg, 820)
        // (600*0.30 + 160*0.40 + 60*0.60) / 820
        XCTAssertEqual(result.centreOfGravityMeters!, 280.0 / 820.0, accuracy: 0.0001)
        XCTAssertFalse(result.isOverweight)
        XCTAssertEqual(result.remainingPayloadKg, 180)
    }

    func testFlagsOverweight() {
        let result = WeightBalanceCalculator.compute(profile: profile(stations: [
            WeightBalanceStation(name: "Load", armMeters: 0.40, weightKg: 450)
        ]))
        XCTAssertTrue(result.isOverweight)
        XCTAssertEqual(result.isWithinLimits, false)
        XCTAssertEqual(result.remainingPayloadKg, 0)
    }

    func testWithoutAnEnvelopeTheVerdictIsUnknownNotFine() {
        // The single most important behaviour here: no envelope entered must never read as a pass.
        let result = WeightBalanceCalculator.compute(profile: profile(stations: [
            WeightBalanceStation(name: "Front", armMeters: 0.40, weightKg: 160)
        ]))
        XCTAssertNil(result.isInsideEnvelope)
        XCTAssertNil(result.isWithinLimits)
    }

    func testEnvelopeContainment() {
        // A simple trapezoid over (arm, weight).
        let envelope = [
            EnvelopePoint(armMeters: 0.20, weightKg: 600),
            EnvelopePoint(armMeters: 0.50, weightKg: 600),
            EnvelopePoint(armMeters: 0.50, weightKg: 1000),
            EnvelopePoint(armMeters: 0.30, weightKg: 1000),
        ]

        XCTAssertTrue(WeightBalanceCalculator.isPoint(arm: 0.40, weight: 800, insideEnvelope: envelope))
        XCTAssertFalse(WeightBalanceCalculator.isPoint(arm: 0.25, weight: 950, insideEnvelope: envelope),
                       "forward of the sloping limit at high mass")
        XCTAssertFalse(WeightBalanceCalculator.isPoint(arm: 0.60, weight: 800, insideEnvelope: envelope))
        XCTAssertFalse(WeightBalanceCalculator.isPoint(arm: 0.40, weight: 1100, insideEnvelope: envelope))
    }

    func testAPointExactlyOnTheEnvelopeEdgeCountsAsInside() {
        // An envelope edge is a published limit; a pilot loaded exactly to it is legal.
        let envelope = [
            EnvelopePoint(armMeters: 0.20, weightKg: 600),
            EnvelopePoint(armMeters: 0.50, weightKg: 600),
            EnvelopePoint(armMeters: 0.50, weightKg: 1000),
            EnvelopePoint(armMeters: 0.20, weightKg: 1000),
        ]
        XCTAssertTrue(WeightBalanceCalculator.isPoint(arm: 0.50, weight: 800, insideEnvelope: envelope))
        XCTAssertTrue(WeightBalanceCalculator.isPoint(arm: 0.35, weight: 600, insideEnvelope: envelope))
    }

    func testDegenerateEnvelopeIsNotTreatedAsContaining() {
        let twoPoints = [EnvelopePoint(armMeters: 0.2, weightKg: 600),
                         EnvelopePoint(armMeters: 0.5, weightKg: 900)]
        XCTAssertFalse(WeightBalanceCalculator.isPoint(arm: 0.3, weight: 700, insideEnvelope: twoPoints))

        let result = WeightBalanceCalculator.compute(
            profile: profile(stations: [], envelope: twoPoints)
        )
        XCTAssertNil(result.isInsideEnvelope, "fewer than three corners is not an envelope")
    }

    func testEmptyProfileHasNoCentreOfGravity() {
        let bare = WeightBalanceProfile()
        let result = WeightBalanceCalculator.compute(profile: bare)
        XCTAssertNil(result.centreOfGravityMeters)
        XCTAssertFalse(bare.isConfigured)
    }

    func testInsideEnvelopeButOverweightIsStillAFailure() {
        let envelope = [
            EnvelopePoint(armMeters: 0.20, weightKg: 600),
            EnvelopePoint(armMeters: 0.60, weightKg: 600),
            EnvelopePoint(armMeters: 0.60, weightKg: 1200),
            EnvelopePoint(armMeters: 0.20, weightKg: 1200),
        ]
        let result = WeightBalanceCalculator.compute(profile: profile(
            stations: [WeightBalanceStation(name: "Load", armMeters: 0.40, weightKg: 460)],
            envelope: envelope
        ))

        XCTAssertEqual(result.isInsideEnvelope, true)
        XCTAssertTrue(result.isOverweight)
        XCTAssertEqual(result.isWithinLimits, false, "the envelope does not excuse being over MTOW")
    }

    // MARK: - Persistence

    func testCostAndLogbookSurviveAFlightRoundTrip() {
        var f = flight()
        var entry = FlightCostEntry()
        entry.hourlyRate = 318; entry.basis = .block; entry.billedHours = 1.48
        entry.fees = [FeeItem(label: "Landing LSGY", amount: 20, icao: "LSGY")]
        f.costEntry = entry
        var overrides = LogbookOverrides()
        overrides.nightMinutes = 30
        f.logbook = overrides

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try! decoder.decode(Flight.self, from: try! encoder.encode(f))

        XCTAssertEqual(restored.costEntry?.hourlyRate, 318)
        XCTAssertEqual(restored.costEntry?.fees.first?.amount, 20)
        XCTAssertEqual(restored.logbook?.nightMinutes, 30)
    }

    func testAFlightSavedBeforeV5DecodesWithNoNumbers() {
        // Every existing record in every user's iCloud container looks like this.
        let legacy = """
        {"id":"\(UUID().uuidString)","airplane":"wt9-dynamic","isFavorite":false,
         "goAroundCount":0,"touchAndGoCount":0,"fullStopCount":0,
         "goAroundTimes":[],"touchAndGoTimes":[],"fullStopTimes":[],
         "gpsTrack":[],"notes":"","name":"","schemaVersion":1}
        """.data(using: .utf8)!

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let flight = try! decoder.decode(Flight.self, from: legacy)

        XCTAssertNil(flight.costEntry)
        XCTAssertNil(flight.logbook)
    }
}
