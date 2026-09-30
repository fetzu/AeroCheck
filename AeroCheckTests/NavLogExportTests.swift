import XCTest
import CoreLocation
import PDFKit
@testable import AeroCheck

/// The printed nav log (PDF + Excel): every waypoint, rows = the leg ENDING at each waypoint, the wind
/// and ground speed the EET was computed with, and page breaks instead of truncation.
final class NavLogExportTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FlightPlan.windsAloftProvider = nil
        FlightPlan.magneticDeclinationProvider = nil
    }

    override func tearDown() {
        FlightPlan.windsAloftProvider = nil
        FlightPlan.magneticDeclinationProvider = nil
        super.tearDown()
    }

    private let departure = Date(timeIntervalSince1970: 1_790_000_000)   // a whole minute

    /// `count` waypoints zig-zagging east from the Jura, named P01, P02, …
    private func plan(_ count: Int) -> FlightPlan {
        var plan = FlightPlan(name: "Test", plannedDepartureTime: departure, fuelFlow: 20)
        plan.waypoints = (0..<count).map { i in
            FlightPlanWaypoint(name: String(format: "P%02d", i + 1),
                               coordinate: .init(latitude: 47.0 + (i % 2 == 0 ? 0 : 0.05), longitude: 7.0 + Double(i) * 0.1),
                               altitude: i == 0 || i == count - 1 ? 1500 : 5000, plannedGroundSpeed: 100)
        }
        plan.calculateRouteData()
        return plan
    }

    // MARK: - Rows

    func testEachRowPrintsTheLegThatEndsThere() {
        let p = plan(3)
        let rows = FlightPlanExportService.navLogRows(p, radio: RouteRadioPlanner.manualOnly(p.waypoints))

        // Departure: no leg, but the departure time.
        XCTAssertEqual(rows[0].mc, "")
        XCTAssertEqual(rows[0].dist, "")
        XCTAssertEqual(rows[0].eto, DateFormatter.hhmm.string(from: departure))
        // Row 1 is P01→P02 — the leg the old export never printed.
        XCTAssertEqual(rows[1].dist, String(format: "%.1f", p.waypoints[0].distance!))
        XCTAssertEqual(rows[1].mc, String(format: "%03d°", Int(p.waypoints[0].magneticCourse!)))
        XCTAssertTrue(rows[1].eet.hasSuffix("+ 5"), "departure allowance on the first leg")
        XCTAssertEqual(rows[1].eto, p.waypoints[0].formattedETO)
        // Last row: P02→P03 plus the arrival allowance, arriving at the plan's total.
        XCTAssertEqual(rows[2].dist, String(format: "%.1f", p.waypoints[1].distance!))
        XCTAssertTrue(rows[2].eet.hasSuffix("+ 5"))
        XCTAssertEqual(rows[2].eto, p.waypoints[2].formattedETO)
    }

    func testWindAndGroundSpeedAreWhatTheEETUsed() {
        FlightPlan.windsAloftProvider = { _, _, _ in FlightPlan.WindAloft(directionDegTrue: 90, speedKt: 20) }
        let p = FlightPlanExportService.asPlanned(plan(3))
        let rows = FlightPlanExportService.navLogRows(p, radio: RouteRadioPlanner.manualOnly(p.waypoints))
        let leg = try! XCTUnwrap(p.legPlanning(from: 1))

        XCTAssertEqual(rows[2].wind, "090/20")
        XCTAssertEqual(rows[2].gs, "\(leg.groundSpeedKt)")
        XCTAssertLessThan(leg.groundSpeedKt, 100, "an easterly slows an eastbound leg")
        XCTAssertEqual(rows[2].eet, "\(Int((leg.distanceNM / Double(leg.groundSpeedKt) * 60).rounded())) + 5")
    }

    // MARK: - Printed as planned (6.1)

    private func rows(_ plan: FlightPlan) -> [FlightPlanExportService.NavLogRow] {
        let p = FlightPlanExportService.asPlanned(plan)
        return FlightPlanExportService.navLogRows(p, radio: RouteRadioPlanner.manualOnly(p.waypoints))
    }

    /// The 23 Sep "after" nav log, exported on 25 Sep, printed 25 Sep's winds: the export recomputed
    /// the route with whatever the cache held that day. It prints what the plan was computed with.
    func testANavLogPrintedAnotherDayShowsTheWindsItWasPlannedWith() {
        FlightPlan.windsAloftProvider = { _, _, _ in FlightPlan.WindAloft(directionDegTrue: 90, speedKt: 20) }
        let planned = plan(3)
        let before = rows(planned)

        for exportDay in [{ (_: CLLocationCoordinate2D, _: Double, _: Date?) -> FlightPlan.WindAloft? in
                              FlightPlan.WindAloft(directionDegTrue: 270, speedKt: 35) },
                          { (_: CLLocationCoordinate2D, _: Double, _: Date?) -> FlightPlan.WindAloft? in nil }] {
            FlightPlan.windsAloftProvider = exportDay
            let after = rows(planned)
            XCTAssertEqual(after.map(\.wind), before.map(\.wind))
            XCTAssertEqual(after.map(\.gs), before.map(\.gs))
            XCTAssertEqual(after.map(\.eet), before.map(\.eet))
            XCTAssertEqual(after.map(\.eto), before.map(\.eto))
        }
        XCTAssertEqual(before[1].wind, "090/20")
    }

    /// A plan saved before 6.1 carries no planning wind, but its leg times were computed with one:
    /// the ground speeds they stand for are printed, not the airspeed or the day's forecast.
    func testAPlanSavedBeforeThePlanningWindPrintsTheGroundSpeedsOfItsOwnLegTimes() {
        FlightPlan.windsAloftProvider = { _, _, _ in FlightPlan.WindAloft(directionDegTrue: 90, speedKt: 20) }
        var older = plan(3)
        let planned = older.legPlanning(from: 0)!.groundSpeedKt
        for i in older.waypoints.indices { older.waypoints[i].planningWind = nil }
        FlightPlan.windsAloftProvider = { _, _, _ in FlightPlan.WindAloft(directionDegTrue: 270, speedKt: 35) }

        let printed = rows(older)
        XCTAssertEqual(printed[1].gs, "\(planned)")
        XCTAssertLessThan(planned, 100)
        XCTAssertEqual(printed[1].wind, "", "which wind it was is not known any more")
    }

    /// Flown: the departure row keeps the planned departure (the take-off is its ATO beside it), and
    /// every other ETO counts from the take-off, as on paper.
    func testAfterTheTakeoffTheETOsCountFromItAndTheDepartureRowKeepsThePlan() {
        let takeoff = departure.addingTimeInterval(16 * 60 + 17)
        let flown = plan(3).anchoringETOs(on: takeoff)!
        let printed = rows(flown)

        XCTAssertEqual(printed[0].eto, DateFormatter.hhmm.string(from: departure))
        XCTAssertEqual(printed[2].eto,
                       DateFormatter.hhmm.string(from: takeoff.addingTimeInterval(flown.waypoints[2].cumulativeEET! + 30)))
    }

    /// Writes a nav log with planning winds, flown and re-anchored, to `AEROCHECK_NAVLOG_DUMP` when that
    /// variable is set, to look at it: layout defects pass every assertion. Set it in the
    /// AeroCheckTests scheme's test environment (`TEST_RUNNER_…` on the command line does not reach
    /// the test process here, and the test just skips).
    func testDumpANavLogWithPlanningWindsForVisualInspection() throws {
        let path = ProcessInfo.processInfo.environment["AEROCHECK_NAVLOG_DUMP"]
        try XCTSkipIf(path == nil, "set AEROCHECK_NAVLOG_DUMP in the scheme to write a sample")

        FlightPlan.windsAloftProvider = { coordinate, altitude, _ in
            FlightPlan.WindAloft(directionDegTrue: altitude > 3000 ? 240 : 200, speedKt: altitude > 3000 ? 22 : 8)
        }
        var p = plan(8)
        p.name = "Nav log with planning winds"
        p.waypoints[3].windDirection = 310
        p.waypoints[3].windSpeed = 12
        p.calculateRouteData()
        FlightPlan.windsAloftProvider = nil
        p = p.anchoringETOs(on: departure.addingTimeInterval(16 * 60 + 17))!
        for i in 0..<5 { p.waypoints[i].actualTimeOver = p.estimatedTimeOver(at: i)?.addingTimeInterval(-90) }
        p.waypoints[0].actualTimeOver = p.etoAnchor
        p.timeOff = p.etoAnchor
        let data = try XCTUnwrap(FlightPlanExportService.exportToPDF(p))
        try data.write(to: URL(fileURLWithPath: path!))
    }

    func testCalmLegsPrintTheAirspeedAsGroundSpeedAndNoWind() {
        let p = plan(3)
        let rows = FlightPlanExportService.navLogRows(p, radio: RouteRadioPlanner.manualOnly(p.waypoints))
        XCTAssertEqual(rows[1].gs, "100", "printed on every leg, not only where it was typed")
        XCTAssertEqual(rows[1].wind, "")
    }

    func testEETIsRoundedNotTruncated() {
        let wp = FlightPlanWaypoint(coordinate: .init(latitude: 47, longitude: 7), estimatedElapsedTime: 6.7 * 60)
        XCTAssertEqual(wp.formattedEET, "7")
    }

    // MARK: - Pages

    func testShortRouteStaysOnOneSheet() {
        XCTAssertEqual(FlightPlanExportService.NavLogLayout.pages(rowCount: 16, radioHeight: 40).count, 1)
        XCTAssertEqual(FlightPlanExportService.navLogPageCount(plan(8), radio: nil), 1)
    }

    func testLongerRouteMovesTheAdminBlocksToASecondSheet() {
        let pages = FlightPlanExportService.NavLogLayout.pages(rowCount: 26, radioHeight: 60)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].routeRows, 0..<26, "the whole route on the sheet you fly from")
        XCTAssertTrue(pages[0].hasRadio)
        XCTAssertTrue(pages[0].hasNotes)
        XCTAssertFalse(pages[0].hasFuel)
        XCTAssertTrue(pages[1].hasFuel && pages[1].hasDebrief)
        XCTAssertFalse(pages[1].hasNotes)
    }

    func testVeryLongRouteFlowsOverPagesWithoutLosingARow() {
        let pages = FlightPlanExportService.NavLogLayout.pages(rowCount: 90, radioHeight: 60)
        XCTAssertGreaterThanOrEqual(pages.count, 3)
        XCTAssertTrue(pages[0].routeContinues)
        XCTAssertTrue(pages[1].routeIsContinuation)
        let covered = pages.flatMap { Array($0.routeRows) }
        XCTAssertEqual(covered, Array(0..<90))
    }

    func testLongRouteIsPrintedInFull() {
        let p = plan(40)
        let data = try! XCTUnwrap(FlightPlanExportService.exportToPDF(p))
        let document = try! XCTUnwrap(PDFDocument(data: data))
        let text = document.string ?? ""
        XCTAssertTrue(text.contains("P01"))
        XCTAssertTrue(text.contains("P40"), "the destination must be on paper")
        XCTAssertFalse(text.localizedCaseInsensitiveContains("truncated"))
        XCTAssertEqual(document.pageCount, FlightPlanExportService.navLogPageCount(p, radio: nil))
        XCTAssertGreaterThan(document.pageCount, 1)
    }

    func testA5KeepsItsPaperSizeOnEveryPage() {
        let data = try! XCTUnwrap(FlightPlanExportService.exportToPDF(plan(40), paperSize: .a5))
        let document = try! XCTUnwrap(PDFDocument(data: data))
        for i in 0..<document.pageCount {
            let box = try! XCTUnwrap(document.page(at: i)).bounds(for: .mediaBox)
            XCTAssertEqual(box.width, 420, accuracy: 1)
            XCTAssertEqual(box.height, 595, accuracy: 1)
        }
    }

    // MARK: - Excel

    func testExcelListsEveryWaypoint() {
        let data = try! XCTUnwrap(FlightPlanExportService.exportToXLSX(plan(30)))
        let xml = try! XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(xml.contains(">P30<"))
        XCTAssertFalse(xml.localizedCaseInsensitiveContains("truncated"))
    }
}

private extension DateFormatter {
    static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
