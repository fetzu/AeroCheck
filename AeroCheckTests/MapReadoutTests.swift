import SwiftUI
import XCTest
@testable import AeroCheck

/// The map's readouts in flight hold still as their values change (6.1): the next-waypoint card's
/// figures, its one-line version on the phone, the NOW / NEXT frequencies, and the open panel's list of
/// frequencies, whatever a pilot typed for a waypoint.
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

    /// Several typed frequencies too long for the card: the first one whole, not the end of the text cut
    /// in its digits ("….125 / Ground 121.900"). (6.1.0 device check)
    func testSeveralTypedFrequenciesShowTheFirstWhole() {
        XCTAssertEqual(FrequencyLineText.firstOfSeveral(FrequencyRow.parts(of: "Info 124.705 / Tower 118.125 / Ground 121.900")),
                       "Info 124.705 / …")
        XCTAssertEqual(FrequencyLineText.firstOfSeveral(FrequencyRow.parts(of: "119.175")), "119.175")
        let font = Font.aero(size: CockpitType.response, weight: .bold, design: .monospaced)
        let typed = "Info 124.705 / Tower 118.125 / Ground 121.900"
        let first = size(Text("Info 124.705 / …").font(font).fixedSize()).width
        let room = first + 10
        XCTAssertGreaterThan(size(Text(typed).font(font).fixedSize()).width, room, "the whole text doesn't fit")
        let card = size(FrequencyLineText(text: typed, font: font, color: .white), width: room)
        XCTAssertEqual(card.width, first, accuracy: 1, "the first frequency and the sign, at full size")
    }

    func testTheWordsGiveWayBeforeTheDigits() {
        XCTAssertFalse(FrequencyLineText.cutsAtStart("119.175 Bern Info"), "cut at the end: the digits lead")
        XCTAssertTrue(FrequencyLineText.cutsAtStart("Bern Info 119.175"), "cut at the start: the digits end it")
        XCTAssertTrue(FrequencyLineText.cutsAtStart("Info 121,5 "))
        XCTAssertFalse(FrequencyLineText.cutsAtStart("119.175"))
        XCTAssertFalse(FrequencyLineText.cutsAtStart("Bern Info"))
    }

    // MARK: The open panel's frequencies (6.1)

    private let typed = "Info 124.705 / Tower 118.125 / Ground 121.900"

    private func row(_ station: String, _ freq: String, role: FreqRole = .other) -> FrequencyRow {
        FrequencyRow(item: PhaseFrequency(station: station, freq: freq, highlighted: role == .current,
                                          isEmergency: role == .emergency, role: role))
    }

    /// The frequency column beside the legs.
    private let column: CGFloat = 300

    func testATypedFrequencyNeverWidensItsRow() {
        // The frequency at its full width made the row, the column, Emergency under it and the panel
        // wider than the screen: the map pane moved right.
        for role in [FreqRole.other, .current, .next] {
            for freq in [typed, "Bern Information 119.175 call on the ground", "LSZQ Home 123.456 / Tower 118.125"] {
                XCTAssertLessThanOrEqual(size(row("LSZQ", freq, role: role), width: column).width, column,
                                         "\(role) \"\(freq)\"")
            }
        }
    }

    func testATypedTextGoesUnderTheStationOnePartALine() {
        let oneLine = size(row("LSZB ATIS", "125.130"), width: column).height
        // Too long for the station's line, all three: one part, two, three.
        let heights = ["Bern Information 119.175", "Info 124.705 / Tower 118.125", typed].map {
            size(row("LSZQ", $0), width: column).height
        }
        XCTAssertGreaterThan(heights[0], oneLine, "under the station, a line of its own")
        XCTAssertGreaterThan(heights[1] - heights[0], 0)
        XCTAssertEqual(heights[2] - heights[1], heights[1] - heights[0], accuracy: 0.5, "one line a part")
    }

    func testEachPartKeepsOneLineHoweverNarrow() {
        // A little smaller, then cut: never "121." over "900".
        let wide = size(row("LSZQ", typed, role: .next), width: column).height
        for width: CGFloat in [220, 160] {
            XCTAssertEqual(size(row("LSZQ", typed, role: .next), width: width).height, wide, "at \(width) pt")
        }
    }

    func testWhatFitsBesideTheStationStaysOnItsLine() {
        let oneLine = size(row("LSZB ATIS", "125.130"), width: column).height
        XCTAssertEqual(size(row("LSZQ", "Info 124.705"), width: column).height, oneLine)
        // A long station gives way to its frequency rather than send it under itself.
        XCTAssertEqual(size(row("Zurich Information East Sector", "124.700", role: .next), width: column).height,
                       oneLine)
    }

    func testTypedTextSplitsAtTheSlashes() {
        XCTAssertEqual(FrequencyRow.parts(of: typed), ["Info 124.705", "Tower 118.125", "Ground 121.900"])
        XCTAssertEqual(FrequencyRow.parts(of: "Bern Information 119.175"), ["Bern Information 119.175"])
        XCTAssertEqual(FrequencyRow.parts(of: "118.125/121.900"), ["118.125", "121.900"])
        XCTAssertEqual(FrequencyRow.parts(of: "Tower 118.125 / "), ["Tower 118.125"])
        XCTAssertEqual(FrequencyRow.parts(of: " / "), [" / "], "nothing to split: as typed")
    }

    /// "130.355" and its kind look exactly as they did: the row is drawn the same, pixel for pixel.
    func testAStationAndItsFrequencyLookAsTheyDid() throws {
        func pixels(_ view: some View) throws -> Data {
            let renderer = ImageRenderer(content: view.frame(width: column).background(Color.black))
            renderer.scale = 2
            return try XCTUnwrap(renderer.uiImage?.pngData())
        }
        let items = [
            PhaseFrequency(station: "LSZQ AFIS", freq: "122.050", highlighted: true, isEmergency: false, role: .current),
            PhaseFrequency(station: "LSGN AFIS", freq: "123.605", highlighted: false, isEmergency: false, role: .next),
            PhaseFrequency(station: "LSZB ATIS", freq: "125.130", highlighted: false, isEmergency: false),
            PhaseFrequency(station: "Emergency", freq: "121.500", highlighted: false, isEmergency: true, role: .emergency),
            PhaseFrequency(station: "Zurich Information East Sector", freq: "130.355", highlighted: false,
                           isEmergency: false, role: .next),
        ]
        for item in items {
            XCTAssertEqual(try pixels(FrequencyRow(item: item)), try pixels(RowAsItWas(item: item)), item.station)
        }
    }
}

/// The frequency row as 6.1 drew it, for `testAStationAndItsFrequencyLookAsTheyDid`.
private struct RowAsItWas: View {
    let item: PhaseFrequency
    @Environment(\.cockpitTheme) private var theme

    private var tag: (String, Color)? {
        switch item.role {
        case .current: return (L10n.Nav.freqCurrent, theme.onTarget)
        case .next: return (L10n.Nav.freqNext, theme.info)
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if let tag {
                Text(tag.0)
                    .font(.aero(size: 16, weight: .bold)).tracking(0.3)
                    .foregroundColor(tag.1)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(tag.1.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
            }
            Text(item.station)
                .font(.aero(size: CockpitType.label, weight: item.highlighted ? .semibold : .regular))
                .foregroundColor(item.isEmergency ? theme.danger : theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 6)
            Text(item.freq)
                .font(.aero(size: CockpitType.row, weight: item.highlighted ? .bold : .regular, design: .monospaced))
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 8)
    }
}
