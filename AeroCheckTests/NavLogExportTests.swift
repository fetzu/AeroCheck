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
        FlightPlan.windsAloftProvider = { _, _ in FlightPlan.WindAloft(directionDegTrue: 90, speedKt: 20) }
        let p = FlightPlanExportService.recomputed(plan(3))
        let rows = FlightPlanExportService.navLogRows(p, radio: RouteRadioPlanner.manualOnly(p.waypoints))
        let leg = try! XCTUnwrap(p.legPlanning(from: 1))

        XCTAssertEqual(rows[2].wind, "090/20")
        XCTAssertEqual(rows[2].gs, "\(leg.groundSpeedKt)")
        XCTAssertLessThan(leg.groundSpeedKt, 100, "an easterly slows an eastbound leg")
        XCTAssertEqual(rows[2].eet, "\(Int((leg.distanceNM / Double(leg.groundSpeedKt) * 60).rounded())) + 5")
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
