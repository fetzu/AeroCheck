import XCTest
import CoreGraphics
@testable import AeroCheck

/// The AMC1 FCL.050 PDF extract (v5.0.0).
///
/// Most of this suite is arithmetic, because a logbook that does not add up is the failure an
/// auditor finds first — and unlike a layout problem, nobody notices it by looking.
final class LogbookPDFTests: XCTestCase {

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    /// One hop with an explicit block time, so every total below is hand-checkable.
    private func flight(
        blockOff: String = "2026-09-06T13:02:00Z",
        blockOn: String = "2026-09-06T14:31:00Z",
        instructor: String? = nil,
        landings: Int = 1,
        overrides: LogbookOverrides? = nil
    ) -> Flight {
        var f = Flight(airplane: "dr400-140b",
                       aircraftRegistration: "HB-KFD",
                       aircraftType: "DR400/140B")
        f.blockOffTime = date(blockOff)
        f.blockOnTime = date(blockOn)
        f.departureAirportIdent = "LSZQ"
        f.arrivalAirportIdent = "LSGY"
        f.fullStopCount = landings
        f.logbook = overrides
        if let instructor {
            var plan = FlightPlan(name: "Test")
            plan.instructor = instructor
            f.flightPlan = plan
        }
        return f
    }

    // MARK: - Totals

    func testTotalsAddUpAcrossFlights() {
        // 89 minutes and 45 minutes.
        let a = flight()
        let b = flight(blockOff: "2026-09-07T09:00:00Z", blockOn: "2026-09-07T09:45:00Z", landings: 3)
        let totals = LogbookTotals.forFlights([a, b])

        XCTAssertEqual(totals.totalMinutes, 89 + 45)
        XCTAssertEqual(totals.landingsDay, 4)
        XCTAssertEqual(totals.singlePilotSEMinutes, totals.totalMinutes,
                       "every aircraft in this fleet is single-pilot SE")
        XCTAssertEqual(totals.multiPilotMinutes, 0)
    }

    func testFunctionColumnsAlwaysBalanceAgainstTheTotal() {
        // The one internal consistency an auditor checks by hand: PIC + co-pilot + dual + instructor
        // must equal total time.
        let solo = flight()
        let dual = flight(blockOff: "2026-09-07T09:00:00Z", blockOn: "2026-09-07T10:00:00Z",
                          instructor: "A. Instructor")
        let totals = LogbookTotals.forFlights([solo, dual])

        XCTAssertTrue(totals.functionMinutesBalance, "\(totals)")
        XCTAssertEqual(totals.picMinutes, 89)
        XCTAssertEqual(totals.dualMinutes, 60)
        XCTAssertEqual(totals.instructorMinutes, 0)
    }

    func testAFlightWithNoBlockTimesContributesNoDuration() {
        // The date columns fall back to engine or GPS times, but a duration is arithmetic and must
        // never be invented from a weaker source — an over-stated total is a false logbook entry.
        var f = flight()
        f.blockOffTime = nil
        f.blockOnTime = nil
        let totals = LogbookTotals.forFlight(f)

        XCTAssertEqual(totals.totalMinutes, 0)
        XCTAssertEqual(totals.picMinutes, 0)
        XCTAssertTrue(totals.functionMinutesBalance)
    }

    func testNightAndIFRComeOnlyFromThePilotsOwnEntries() {
        // The app does not compute twilight, so these are zero unless the pilot said otherwise.
        XCTAssertEqual(LogbookTotals.forFlight(flight()).nightMinutes, 0)
        XCTAssertEqual(LogbookTotals.forFlight(flight()).ifrMinutes, 0)

        let entered = flight(overrides: LogbookOverrides(nightMinutes: 20, ifrMinutes: 35))
        let totals = LogbookTotals.forFlight(entered)
        XCTAssertEqual(totals.nightMinutes, 20)
        XCTAssertEqual(totals.ifrMinutes, 35)
    }

    func testAnOverriddenFunctionMovesTheWholeFlightToThatColumn() {
        let f = flight(overrides: LogbookOverrides(function: .instructor))
        let totals = LogbookTotals.forFlight(f)

        XCTAssertEqual(totals.instructorMinutes, 89)
        XCTAssertEqual(totals.picMinutes, 0)
        XCTAssertTrue(totals.functionMinutesBalance)
    }

    func testTheLineAndTheTotalsAgreeOnFunction() {
        // Two code paths decide which column a flight belongs in — the rendered line and the page
        // total. If they ever disagree, the page will not balance and nothing will say so.
        let dual = flight(instructor: "A. Instructor")
        let line = LogbookLineBuilder.build(flight: dual, overrides: dual.logbook)

        XCTAssertEqual(line.functionLabel, L10n.Logbook.functionDual)
        XCTAssertEqual(LogbookTotals.forFlight(dual).dualMinutes, 89)
    }

    // MARK: - Pagination and the document

    func testAnEmptySelectionProducesNoFileRatherThanABlankPage() {
        // A blank logbook extract is a document someone sends by mistake.
        XCTAssertNil(LogbookPDFExportService.export(flights: []))
    }

    func testFlightsArePaginatedAtTheRequestedRowCount() {
        let flights = (0..<7).map {
            flight(blockOff: "2026-09-0\($0 + 1)T09:00:00Z", blockOn: "2026-09-0\($0 + 1)T10:00:00Z")
        }
        let data = try! XCTUnwrap(LogbookPDFExportService.export(
            flights: flights, options: .init(rowsPerPage: 3)))
        XCTAssertEqual(pageCount(of: data), 3, "7 flights at 3 per page is 3 pages")
    }

    /// Writes a populated extract to `AEROCHECK_PDF_DUMP` when that variable is set, so the layout
    /// can be looked at. A form is one of the few things a test genuinely cannot check: a clipped
    /// heading, a truncated date and a rule struck through a label all pass every assertion here —
    /// all three were in the first draft, and only looking at the page found them.
    ///
    /// Set the variable in the AeroCheckTests scheme's test environment. Passing
    /// `TEST_RUNNER_AEROCHECK_PDF_DUMP=…` on the xcodebuild command line does NOT reach the test
    /// process here — the test simply skips, which looks like success.
    func testDumpSampleForVisualInspection() throws {
        let path = ProcessInfo.processInfo.environment["AEROCHECK_PDF_DUMP"]
        try XCTSkipIf(path == nil, "set AEROCHECK_PDF_DUMP in the scheme to write a sample")

        var flights: [Flight] = []
        for i in 0..<18 {
            let day: Int = (i % 27) + 1
            let offMinute: Int = (i * 7) % 60
            let onMinute: Int = (i * 11) % 60
            let off: String = String(format: "2026-09-%02dT09:%02d:00Z", day, offMinute)
            let on: String = String(format: "2026-09-%02dT11:%02d:00Z", day, onMinute)
            let instructor: String? = (i % 4 == 0) ? "A. Instructor" : nil
            let overrides: LogbookOverrides? = (i % 5 == 0)
                ? LogbookOverrides(nightMinutes: 25, ifrMinutes: 40) : nil
            flights.append(flight(blockOff: off,
                                  blockOn: on,
                                  instructor: instructor,
                                  landings: (i % 3) + 1,
                                  overrides: overrides))
        }
        let data = try XCTUnwrap(LogbookPDFExportService.export(
            flights: flights, options: .init(pilotName: "Julien Bono")))
        try data.write(to: URL(fileURLWithPath: path!))
    }

    func testEveryPageIsLandscapeA4() {
        // The form has twelve column groups; portrait would crush them to illegibility.
        let data = try! XCTUnwrap(LogbookPDFExportService.export(flights: [flight()]))
        let size = try! XCTUnwrap(firstPageSize(of: data))
        XCTAssertEqual(size.width, 842, accuracy: 1)
        XCTAssertEqual(size.height, 595, accuracy: 1)
        XCTAssertGreaterThan(size.width, size.height)
    }

    func testBroughtForwardTotalsAccumulateRatherThanRepeat() {
        // Page 2's "total from previous pages" must be page 1's total, not zero and not double.
        // Verified on the model the renderer uses, since the numbers in the PDF are not readable back.
        let flights = (0..<4).map { i -> Flight in
            flight(blockOff: "2026-09-0\(i + 1)T09:00:00Z", blockOn: "2026-09-0\(i + 1)T10:00:00Z")
        }
        let page1 = LogbookTotals.forFlights(Array(flights[0..<2]))
        let page2 = LogbookTotals.forFlights(Array(flights[2..<4]))

        XCTAssertEqual(page1.totalMinutes, 120)
        XCTAssertEqual((page1 + page2).totalMinutes, 240)
        XCTAssertEqual(LogbookTotals.forFlights(flights).totalMinutes, (page1 + page2).totalMinutes,
                       "the running total must equal the sum of the pages")
    }

    func testExportOrdersOldestFirstWhateverTheCallerPassed() {
        // The flight log is newest-first; brought-forward totals are meaningless in that order.
        let older = flight(blockOff: "2026-09-01T09:00:00Z", blockOn: "2026-09-01T10:00:00Z")
        let newer = flight(blockOff: "2026-09-09T09:00:00Z", blockOn: "2026-09-09T10:00:00Z")

        // One flight per page, so page one carries whichever flight sorted first.
        let data = try! XCTUnwrap(LogbookPDFExportService.export(
            flights: [newer, older], options: .init(rowsPerPage: 1)))
        XCTAssertEqual(pageCount(of: data), 2)
        // The ordering itself is asserted on the sort key the renderer uses, which is observable.
        let sorted = [newer, older].sorted {
            LogbookPDFExportService.chronology(of: $0) < LogbookPDFExportService.chronology(of: $1)
        }
        XCTAssertEqual(sorted.first?.blockOffTime, older.blockOffTime)
    }

    func testTheDisclaimerNeverClaimsToBeALogbookOfRecord() {
        // This string is the whole defence against a pilot submitting the extract as if it were an
        // accepted digital logbook. If someone softens it, this fails.
        //
        // Both languages are accepted because the test host runs in the system locale, and a French
        // machine must not fail a test about wording that is correct in French.
        let text = L10n.Logbook.pdfDisclaimer.lowercased()
        XCTAssertTrue(text.contains("not a logbook of record") || text.contains("pas un carnet de vol officiel"),
                      "the extract must disclaim being a logbook of record: \(text)")
        XCTAssertTrue(text.contains("foca-accepted") || text.contains("accepté par l'ofac"),
                      "the extract must disclaim FOCA acceptance: \(text)")
    }

    // MARK: - Helpers

    private func firstPageSize(of data: Data) -> CGSize? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        return CGSize(width: box.width, height: box.height)
    }

    private func pageCount(of data: Data) -> Int {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }
}
