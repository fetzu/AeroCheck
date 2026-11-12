import XCTest
@testable import AeroCheck

/// "Fees paid" (6.11.0): what a fee line keeps, the totals per currency, the invoices still to come,
/// where a flight's landings were, and what a device on an older build may do with all of it.
/// Pure: no service, no clock, no file. Every amount here is invented.
final class FeesPaidTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_763_000_000)

    private func costed(rate: Double = 300, hours: Double = 1, currency: String = "CHF") -> FlightCostEntry {
        var entry = FlightCostEntry()
        entry.currency = currency
        entry.hourlyRate = rate
        entry.basis = .block
        entry.billedHours = hours
        return entry
    }

    // MARK: - The fee line

    func testSettlingAFeeKeepsTheAnswerTheAmountAndTheAerodromeOnOneLine() {
        var entry = costed()
        entry.settleFee(at: "lszs", label: "Landing fee LSZS", status: .paid, amount: 62, currency: "CHF", landings: 1, at: day)

        XCTAssertEqual(entry.fees.count, 1)
        let line = try! XCTUnwrap(entry.feeLine(for: "LSZS"))
        XCTAssertEqual(line.icao, "LSZS")
        XCTAssertEqual(line.status, .paid)
        XCTAssertEqual(line.amount, 62)
        XCTAssertEqual(line.hasAmount, true)
        XCTAssertNil(line.currency, "the flight's own currency is not repeated on the line")
        XCTAssertEqual(line.landings, 1)
        XCTAssertEqual(line.settledAt, day)
        XCTAssertEqual(entry.total, 362)
    }

    func testAnsweringAgainChangesTheSameLine() {
        var entry = costed()
        entry.settleFee(at: "LSZS", label: "Landing fee LSZS", status: .invoice, amount: nil, currency: nil, landings: 1, at: day)
        XCTAssertEqual(entry.feeLine(for: "LSZS")?.hasAmount, false)
        XCTAssertEqual(entry.total, 300, "an invoice with no figure yet adds nothing")

        entry.settleFee(at: "LSZS", label: "Landing fee LSZS", status: .paid, amount: 58.5, currency: nil, landings: nil, at: day.addingTimeInterval(86_400))
        XCTAssertEqual(entry.fees.count, 1, "the same line, not a second one")
        XCTAssertEqual(entry.feeLine(for: "LSZS")?.status, .paid)
        XCTAssertEqual(entry.feeLine(for: "LSZS")?.landings, 1, "the count stays when the answer changes")
        XCTAssertEqual(entry.total, 358.5, accuracy: 1e-9)
    }

    func testOnTheClubsBillAndNoFeeAddNothing() {
        var entry = costed()
        entry.settleFee(at: "LSZQ", label: "Landing fee LSZQ", status: .club, amount: 25, currency: nil, landings: 6, at: day)
        entry.settleFee(at: "LSGE", label: "Landing fee LSGE", status: FeeStatus.none, amount: nil, currency: nil, landings: 1, at: day)
        XCTAssertEqual(entry.total, 300)
        XCTAssertEqual(entry.totalsByCurrency, ["CHF": 300])
        XCTAssertTrue(entry.hasCost)
    }

    func testAFeeInAnotherCurrencyIsNeverAddedToTheFlights() {
        var entry = costed(rate: 395)
        entry.settleFee(at: "LSZS", label: "Landing fee LSZS", status: .paid, amount: 62, currency: "CHF", landings: 1, at: day)
        entry.settleFee(at: "LFSM", label: "Landing fee LFSM", status: .paid, amount: 18, currency: "EUR", landings: 2, at: day)

        XCTAssertEqual(entry.feeLine(for: "LFSM")?.currency, "EUR")
        XCTAssertEqual(entry.feesTotal, 62, "only the francs")
        XCTAssertEqual(entry.total, 457)
        XCTAssertEqual(entry.totalsByCurrency, ["CHF": 457, "EUR": 18])
        XCTAssertEqual(FlightCostCalculator.formatTotals(entry.totalsByCurrency, first: entry.currency), "CHF 457 + EUR 18")
    }

    func testTotalsAreWrittenWithTheFlightsCurrencyFirst() {
        XCTAssertEqual(FlightCostCalculator.formatTotals(["GBP": 30, "EUR": 18, "CHF": 400], first: "EUR"), "EUR 18 + CHF 400 + GBP 30")
        XCTAssertEqual(FlightCostCalculator.formatTotals([:], first: "CHF"), "CHF 0")
    }

    // MARK: - Older and later builds

    func testALineWrittenBeforeTheAnswersExistedStillDecodesAndCounts() throws {
        let old = Data(#"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","label":"Landing","amount":20,"icao":"LSGY"}"#.utf8)
        let line = try JSONDecoder().decode(FeeItem.self, from: old)
        XCTAssertNil(line.status)
        XCTAssertFalse(line.carriesAnswer)
        XCTAssertTrue(line.countsInTotals)
        XCTAssertFalse(line.isInvoiceToCome)
    }

    func testAnAnswerALaterBuildAddsDoesNotBreakTheFlight() throws {
        let later = Data(#"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","label":"Landing","amount":20,"status":"disputed"}"#.utf8)
        let line = try JSONDecoder().decode(FeeItem.self, from: later)
        XCTAssertNil(line.status, "a word this build doesn't know is no answer here")
        XCTAssertEqual(line.statusRaw, "disputed", "and it is kept as written")
        let again = try JSONDecoder().decode(FeeItem.self, from: JSONEncoder().encode(line))
        XCTAssertEqual(again.statusRaw, "disputed")
    }

    func testAnAnsweredLineReadsBackWhole() throws {
        var entry = costed()
        entry.settleFee(at: "LFSM", label: "Landing fee LFSM", status: .invoice, amount: 18, currency: "EUR", landings: 2, at: day)
        let again = try JSONDecoder().decode(FlightCostEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(again, entry)
    }

    // MARK: - The record's version (the author, 12 Nov 2026: a 6.10 device doesn't show such a flight)

    func testOnlyAFlightThatCarriesAnAnswerGetsTheNewerStamp() {
        var flight = Flight(airplane: "dr400-140b")
        XCTAssertEqual(flight.schemaVersion, Flight.baseSchemaVersion, "a new flight is one every build since 5.0.0 reads")

        var entry = costed()
        entry.fees = [FeeItem(label: "Parking", amount: 10)]
        flight.costEntry = entry
        flight.stampForContent()
        XCTAssertEqual(flight.schemaVersion, Flight.baseSchemaVersion, "a line of the old shape needs nothing newer")

        entry.settleFee(at: "LSZS", label: "Landing fee LSZS", status: .paid, amount: 62, currency: nil, landings: 1, at: day)
        flight.costEntry = entry
        flight.stampForContent()
        XCTAssertEqual(flight.schemaVersion, 3)
        XCTAssertGreaterThan(flight.schemaVersion, Flight.baseSchemaVersion, "which a 6.10 build refuses on ingest")
        XCTAssertNotNil(flight.validatedForIngest(), "and this build reads")
    }

    func testTheStampIsNeverLowered() {
        var flight = Flight(airplane: "dr400-140b")
        var entry = costed()
        entry.settleFee(at: "LSZS", label: "Landing fee LSZS", status: .paid, amount: 62, currency: nil, landings: 1, at: day)
        flight.costEntry = entry
        flight.stampForContent()
        flight.costEntry = costed()
        flight.stampForContent()
        XCTAssertEqual(flight.schemaVersion, 3, "an older build must not get the flight back with a stale copy to strip")
    }

    func testTheStampSurvivesTheFlightsOwnRoundTrip() throws {
        var flight = Flight(airplane: "dr400-140b")
        var entry = costed()
        entry.settleFee(at: "LSZS", label: "Landing fee LSZS", status: .club, amount: nil, currency: nil, landings: 1, at: day)
        flight.costEntry = entry
        flight.stampForContent()
        let again = try JSONDecoder().decode(Flight.self, from: JSONEncoder().encode(flight))
        XCTAssertEqual(again.schemaVersion, 3)
        XCTAssertEqual(again.costEntry?.feeLine(for: "LSZS")?.status, .club)
    }

    func testACopyAnOlderBuildEditedCannotEraseTheAnswers() {
        // The iPad (6.11) holds the flight with its fee answer. The iPhone (6.10) still holds its older
        // copy, renames the flight and uploads it: stamped 2, newer date, no answer.
        var onTheIPad = Flight(airplane: "dr400-140b")
        var entry = costed()
        entry.settleFee(at: "LSZS", label: "Landing fee LSZS", status: .paid, amount: 62, currency: nil, landings: 1, at: day)
        onTheIPad.costEntry = entry
        onTheIPad.stampForContent()
        onTheIPad.modifiedAt = day

        var fromTheIPhone = onTheIPad
        fromTheIPhone.costEntry = costed()
        fromTheIPhone.schemaVersion = Flight.baseSchemaVersion
        fromTheIPhone.name = "Samedan with Anna"
        fromTheIPhone.modifiedAt = day.addingTimeInterval(3_600)

        for merged in [Flight.merge(onTheIPad, fromTheIPhone), Flight.merge(fromTheIPhone, onTheIPad)] {
            XCTAssertEqual(merged.name, "Samedan with Anna", "the rename is the newer edit and wins")
            XCTAssertEqual(merged.costEntry?.feeLine(for: "LSZS")?.status, .paid, "the answer it couldn't read stays")
            XCTAssertEqual(merged.schemaVersion, 3)
        }
    }

    func testTwoCopiesOfTheSameVersionAreTakenAtTheirWord() {
        // Removing an answer on a 6.11 device is an edit like any other: the newer copy wins.
        var older = Flight(airplane: "dr400-140b")
        var entry = costed()
        entry.settleFee(at: "LSZS", label: "Landing fee LSZS", status: .paid, amount: 62, currency: nil, landings: 1, at: day)
        older.costEntry = entry
        older.stampForContent()
        older.modifiedAt = day

        var newer = older
        newer.costEntry = costed()
        newer.modifiedAt = day.addingTimeInterval(60)

        XCTAssertNil(Flight.merge(older, newer).costEntry?.feeLine(for: "LSZS"))
    }

    // MARK: - The ledger

    func testTheLedgerListsEveryCurrencyAndTheInvoicesStillToCome() {
        func flown(_ offset: TimeInterval, _ build: (inout FlightCostEntry) -> Void) -> Flight {
            var flight = Flight(airplane: "dr400-140b")
            flight.startTime = day.addingTimeInterval(offset)
            var entry = costed()
            build(&entry)
            flight.costEntry = entry
            return flight
        }
        let later = flown(86_400) { $0.settleFee(at: "LFSM", label: "Landing fee LFSM", status: .invoice, amount: 18, currency: "EUR", landings: 1, at: self.day) }
        let earlier = flown(0) { $0.settleFee(at: "LSZS", label: "Landing fee LSZS", status: .invoice, amount: nil, currency: nil, landings: 1, at: self.day) }
        let paid = flown(172_800) { $0.settleFee(at: "LSGE", label: "Landing fee LSGE", status: .paid, amount: 30, currency: nil, landings: 1, at: self.day) }

        let summary = CostLedger.summarize(flights: [later, paid, earlier])

        XCTAssertEqual(summary.totalsByCurrency, ["CHF": 930, "EUR": 18])
        XCTAssertEqual(summary.fees, 30, accuracy: 1e-9, "the franc fees only, as the franc total")
        XCTAssertEqual(summary.invoicesToCome.map(\.icao), ["LSZS", "LFSM"], "oldest first")
        XCTAssertNil(summary.invoicesToCome.first?.amount, "no figure yet")
        XCTAssertEqual(summary.invoicesToCome.last?.amount, 18)
        XCTAssertEqual(summary.invoicesToCome.last?.currency, "EUR")
    }

    // MARK: - The Costs CSV

    func testTheCostsFileHasOneRowPerFlightAndPerFee() {
        var flight = Flight(airplane: "dr400-140b", aircraftRegistration: "HB-KFD")
        flight.startTime = day
        var entry = costed(rate: 395)
        entry.settleFee(at: "LSZS", label: "Landing fee LSZS", status: .paid, amount: 62, currency: nil, landings: 1, at: day)
        entry.settleFee(at: "LFSM", label: "Landing fee LFSM", status: .invoice, amount: nil, currency: "EUR", landings: 2, at: day)
        flight.costEntry = entry
        let uncosted = Flight(airplane: "dr400-140b")

        let words = CostsCSV.Words(header: ["Date", "Flight", "Aircraft", "Item", "Aerodrome", "Landings", "Settled", "Amount", "Currency"],
                                   aircraft: "Aircraft", status: { $0?.rawValue ?? "" })
        let rows = CostsCSV.csv(flights: [uncosted, flight], rates: [:], words: words).components(separatedBy: "\n")

        XCTAssertEqual(rows.count, 4, "the header, the aircraft and two fees; a flight with no cost has no row")
        XCTAssertEqual(rows[0], "Date,Flight,Aircraft,Item,Aerodrome,Landings,Settled,Amount,Currency")
        XCTAssertTrue(rows[1].hasSuffix(",HB-KFD,Aircraft,,,,395.00,CHF"), rows[1])
        XCTAssertTrue(rows[2].hasSuffix(",HB-KFD,Landing fee LSZS,LSZS,1,paid,62.00,CHF"), rows[2])
        XCTAssertTrue(rows[3].hasSuffix(",HB-KFD,Landing fee LFSM,LFSM,2,invoice,,"), "no figure yet: no amount and no currency")
    }

    // MARK: - Where the landings were

    /// A track point every 10 s along a list of (seconds, latitude) legs; the fake lookup names the
    /// aerodrome by latitude band: 47.4 home, 47.0 the other field.
    private func track(_ points: [(TimeInterval, Double)]) -> [GPSPoint] {
        points.map { GPSPoint(latitude: $0.1, longitude: 7.0, altitude: 500, timestamp: day.addingTimeInterval($0.0)) }
    }

    private func aerodrome(_ latitude: Double, _ longitude: Double) -> String? {
        if abs(latitude - 47.4) < 0.01 { return "LSZQ" }
        if abs(latitude - 47.0) < 0.01 { return "LSGN" }
        return nil
    }

    func testATouchAndGoElsewhereAndBackGetsItsLineAndTheHomeFieldDoesNot() {
        var flight = Flight(airplane: "dr400-140b", departureAirportIdent: "LSZQ", arrivalAirportIdent: "LSZQ")
        flight.gpsTrack = track([(0, 47.4), (900, 47.2), (1_800, 47.0), (1_900, 47.0), (2_700, 47.2), (3_600, 47.4)])
        flight.touchAndGoTimes = [day.addingTimeInterval(1_800), day.addingTimeInterval(1_905)]
        flight.fullStopTimes = [day.addingTimeInterval(3_600)]

        XCTAssertEqual(LandingFeeLines.visits(for: flight, nearestAerodrome: aerodrome),
                       [LandingFeeLines.Visit(icao: "LSGN", landings: 2)])
    }

    func testALandingLoggedTwiceCountsOnceAndOneNowhereNearATrackPointIsNotPlaced() {
        var flight = Flight(airplane: "dr400-140b", departureAirportIdent: "LSZQ", arrivalAirportIdent: "LSGN")
        flight.gpsTrack = track([(0, 47.4), (1_800, 47.0)])
        flight.touchAndGoTimes = [day.addingTimeInterval(1_795), day.addingTimeInterval(1_810)]
        flight.fullStopTimes = [day.addingTimeInterval(4_000)] // no track point within two minutes

        XCTAssertEqual(LandingFeeLines.visits(for: flight, nearestAerodrome: aerodrome),
                       [LandingFeeLines.Visit(icao: "LSGN", landings: 1)])
    }

    func testAFlightWithoutATrackKeepsItsArrivalField() {
        let away = Flight(airplane: "dr400-140b", departureAirportIdent: "LSZQ", arrivalAirportIdent: "LSGN")
        XCTAssertEqual(LandingFeeLines.visits(for: away, nearestAerodrome: aerodrome),
                       [LandingFeeLines.Visit(icao: "LSGN", landings: 1)])
        let local = Flight(airplane: "dr400-140b", departureAirportIdent: "LSZQ", arrivalAirportIdent: "LSZQ")
        XCTAssertTrue(LandingFeeLines.visits(for: local, nearestAerodrome: aerodrome).isEmpty)
    }

    func testTheStartCurrencyComesFromTheAerodromesCountry() {
        XCTAssertEqual(LandingFeeLines.currency(forCountry: "CH"), "CHF")
        XCTAssertEqual(LandingFeeLines.currency(forCountry: "fr"), "EUR")
        XCTAssertEqual(LandingFeeLines.currency(forCountry: "GB"), "GBP")
        XCTAssertNil(LandingFeeLines.currency(forCountry: "ZZ"), "no guess")
        XCTAssertNil(LandingFeeLines.currency(forCountry: nil))
    }
}
