import SwiftUI
import XCTest
@testable import AeroCheck

/// The map's readouts in flight hold still as their values change (6.1): the next-waypoint card's
/// figures, its one-line version on the phone, and the NOW / NEXT frequencies.
@MainActor
final class MapReadoutTests: XCTestCase {

    private func size(_ view: some View, width: CGFloat = 1_000) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 1_000))
    }

    private func cellWidth(_ label: String, _ reading: NavValueCell.Reading, widest: NavValueCell.Reading,
                           orWidest: NavValueCell.Reading? = nil) -> CGFloat {
        size(NavValueCell(label: label, reading: reading, widest: widest, orWidest: orWidest)).width
    }

    // MARK: The next-waypoint card

    func testTheDistanceCellKeepsOneWidth() {
        let widest = NavValueCell.Reading(NextWaypointReadout.widestDistance, unit: "NM")
        let widths = ["10.0", "9.9", "0.3", "123.4", "—"].map { cellWidth("DIST", .init($0, unit: "NM"), widest: widest) }
        XCTAssertEqual(Set(widths).count, 1, "10.0 → 9.9 NM moved the cells to its left: \(widths)")
        XCTAssertGreaterThan(widths[0], 0)
    }

    func testTheTimeCellKeepsOneWidthAcrossTheHour() {
        let etes: [TimeInterval] = [59 * 60, 60 * 60, 9 * 60, 3 * 3_600 + 7 * 60]
        var readings = etes.map { NavValueCell.Reading(NextWaypointReadout.eteValue($0), unit: NextWaypointReadout.eteUnit($0)) }
        readings.append(NavValueCell.Reading("—"))
        let widths = readings.map {
            cellWidth("ETE", $0, widest: NextWaypointReadout.widestMinutes, orWidest: NextWaypointReadout.widestHours)
        }
        XCTAssertEqual(Set(widths).count, 1, "59 min → 1:00 h, and \"—\" under 30 kt: \(widths)")
    }

    func testTheBearingAndClockCellsKeepOneWidth() {
        let bearings = ["005°", "359°", "—"].map {
            cellWidth("BRG", .init($0), widest: .init(NextWaypointReadout.widestBearing))
        }
        XCTAssertEqual(Set(bearings).count, 1, "\(bearings)")

        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        let clock: [(hour: Int, minute: Int)] = [(9, 5), (10, 58), (23, 59), (0, 1)]
        var times: [String] = clock.map { time in
            NextWaypointReadout.eta(calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)!)
        }
        times.append("—")
        let etas = times.map { cellWidth("ETA", .init($0), widest: .init(NextWaypointReadout.widestETA)) }
        XCTAssertEqual(Set(etas).count, 1, "9:05 → 10:58 gained a digit: \(times) \(etas)")
    }

    func testTheWidestClockTimeIsAsLongAsAnyOther() {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        for hour in 0..<24 {
            let time = NextWaypointReadout.eta(calendar.date(bySettingHour: hour, minute: 47, second: 0, of: day)!)
            XCTAssertLessThanOrEqual(time.count, NextWaypointReadout.widestETA.count, time)
        }
    }

    func testAValueWiderThanItsFormatShrinksRatherThanWidenTheCell() {
        let widest = NavValueCell.Reading(NextWaypointReadout.widestDistance, unit: "NM")
        XCTAssertEqual(cellWidth("DIST", .init("1234.5", unit: "NM"), widest: widest),
                       cellWidth("DIST", .init("9.9", unit: "NM"), widest: widest))
    }

    func testTheTimeReadsInMinutesThenHours() {
        XCTAssertEqual(NextWaypointReadout.eteValue(59 * 60), "59")
        XCTAssertEqual(NextWaypointReadout.eteUnit(59 * 60), "min")
        XCTAssertEqual(NextWaypointReadout.eteValue(60 * 60), "1:00")
        XCTAssertEqual(NextWaypointReadout.eteUnit(60 * 60), "h")
        XCTAssertEqual(NextWaypointReadout.eteValue(67 * 60 + 20), "1:07")
        XCTAssertEqual(NextWaypointReadout.distance(9.94), "9.9")
        XCTAssertEqual(NextWaypointReadout.bearing(5.7), "005°")
    }

    // MARK: The phone's line

    func testThePhonesLineKeepsOneLength() {
        let lines = [
            NextWaypointReadout.phoneLine(bearing: "206°", distance: "10.0", ete: 59 * 60),
            NextWaypointReadout.phoneLine(bearing: "206°", distance: "9.9", ete: 60 * 60),
            NextWaypointReadout.phoneLine(bearing: "206°", distance: "9.9", ete: 9 * 60),
            NextWaypointReadout.phoneLine(bearing: "206°", distance: "30.2", ete: nil),
            NextWaypointReadout.phoneLine(bearing: nil, distance: nil, ete: nil),
        ]
        XCTAssertEqual(Set(lines.map(\.count)).count, 1, "B612 Mono: one length, one width: \(lines)")
        XCTAssertEqual(lines[2], "206° ·  9.9 NM ·  9 min", "each figure right-aligned in its field")
        XCTAssertEqual(lines[3], "206° · 30.2 NM ·      —", "no ETE under 30 kt, its place kept")
    }

    // MARK: NOW / NEXT

    func testAFrequencyStaysOnOneLine() {
        let font = Font.aero(size: CockpitType.response, weight: .bold, design: .monospaced)
        func height(_ text: String) -> CGFloat {
            size(FrequencyLineText(text: text, font: font, color: .white), width: 150).height
        }
        let one = height("126.350")
        XCTAssertGreaterThan(one, 0)
        for typed in ["119.175 Bern Information", "Bern Information 119.175",
                      "119.175 / 121.450 / 120.100 / 118.000"] {
            XCTAssertEqual(height(typed), one, "\"\(typed)\" wrapped and made the card taller")
        }
    }

    func testTheWordsGiveWayBeforeTheDigits() {
        XCTAssertFalse(FrequencyLineText.cutsAtStart("119.175 Bern Info"), "cut at the end: the digits lead")
        XCTAssertTrue(FrequencyLineText.cutsAtStart("Bern Info 119.175"), "cut at the start: the digits end it")
        XCTAssertTrue(FrequencyLineText.cutsAtStart("Info 121,5 "))
        XCTAssertFalse(FrequencyLineText.cutsAtStart("119.175"))
        XCTAssertFalse(FrequencyLineText.cutsAtStart("Bern Info"))
    }
}
