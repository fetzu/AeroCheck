import SwiftUI
import XCTest
@testable import AeroCheck

/// The read band (6.2.0): the strip with NEXT and its figures, NOW | NEXT, and on the phone the next line
/// and the NOW line. One height and every cell in its frame, whatever the flight does (no route, a route, a
/// diversion, no fix, GPS lost, 9.9 → 10.0 NM, 59 → 60 min, a long name, a long typed frequency); nothing
/// cut at the in-flight sizes; what VoiceOver and the replays read.
///
/// Until 6.2 the iPad's strip had three cells with no route and four with one (`nextWaypoint` nil or not),
/// so they divided again at the arming of a route, and the next waypoint's figures were on the map's card,
/// on MAP only.
@MainActor
final class ReadBandLayoutTests: XCTestCase {

    private typealias Sample = ReadBandSample

    /// The widths the band is laid out at: an iPad Air in portrait and on its side, an iPhone 17 Pro and a
    /// 6.1" iPhone 17e.
    private static let layouts: [(name: String, layout: CockpitLayout, width: CGFloat)] = [
        ("iPad portrait", .wide, 820), ("iPad landscape", .wide, 1_180),
        ("iPhone 17 Pro", .narrow, 402), ("iPhone 17e", .narrow, 390),
    ]

    // MARK: - One height, every cell in its frame

    func testTheBandHoldsStillThroughEveryState() {
        for (name, layout, width) in Self.layouts {
            for language in ["en", "fr"] {
                let reference = parts(Sample.states[0], layout, width, language)
                let referenceHeight = height(Sample.states[0], layout, width, language)
                XCTAssertFalse(reference.isEmpty)
                for state in Sample.states.dropFirst() {
                    XCTAssertEqual(height(state, layout, width, language), referenceHeight, accuracy: 0.5,
                                   "\(state.name): the band's height, \(name), \(language)")
                    let frames = parts(state, layout, width, language)
                    XCTAssertEqual(Set(frames.keys), Set(reference.keys), "\(state.name): the same parts, \(name)")
                    for (part, frame) in reference {
                        guard let other = frames[part] else { continue }
                        assertSameFrame(other, frame, "\(state.name): \(part), \(name), \(language)")
                    }
                }
            }
        }
    }

    /// The iPad's strip has its four cells in every state: NEXT is there with no route ("—"), so GS, ALT
    /// and TRK never divide the strip again, and they keep their widest values' width.
    func testTheIPadStripKeepsFourCellsWithOrWithoutARoute() throws {
        for width in [CGFloat(820), 1_180] {
            let withRoute = parts(Sample.states[0], .wide, width, "en")
            let noRoute = parts(try XCTUnwrap(Sample.states.first { $0.name == "no route" }), .wide, width, "en")
            for part in [ReadBandPart.speed, .altitude, .track, .next] {
                let a = try XCTUnwrap(withRoute[part], "\(part) at \(width)")
                let b = try XCTUnwrap(noRoute[part], "\(part) with no route at \(width)")
                assertSameFrame(a, b, "\(part) at \(width)")
            }
            let next = try XCTUnwrap(withRoute[.next])
            let track = try XCTUnwrap(withRoute[.track])
            XCTAssertGreaterThan(next.minX, track.maxX - 1, "NEXT after TRK")
            XCTAssertGreaterThan(next.width, width == 820 ? 300 : 650, "NEXT takes what GS, ALT and TRK leave (\(next.width))")
        }
    }

    // MARK: - Nothing cut

    /// iPad in portrait: "E (LSGC)" whole at the name's full size, "SAIGNELÉGIER" at the label's size at
    /// least, and DIVERT / DÉROUTEMENT whole, in the name's column; with a 12-hour clock too, should
    /// "10:58 PM" ever be wider than the distance.
    func testTheIPadNameColumnHoldsTheNamesAtTheirSizes() throws {
        let metrics = ReadBandMetrics(.kneeboard)
        let figures = [NextFigureTemplates.bearing, NextFigureTemplates.distance, NextFigureTemplates.ete,
                       NextFigureTemplates.clock].map { templateWidth($0, metrics) }.max() ?? 0
        let twelveHour = max(0, textWidth("10:58 PM", size: metrics.figureSize, bold: true, mono: true) - figures)
        for width in [CGFloat(820), 1_180] {
            for language in ["en", "fr"] {
                let column = try XCTUnwrap(parts(Sample.states[0], .wide, width, language)[.nextName]).width - twelveHour
                XCTAssertLessThanOrEqual(textWidth("E (LSGC)", size: metrics.identSize, bold: true, mono: true), column,
                                         "\"E (LSGC)\" at \(metrics.identSize) pt, \(width), \(language)")
                XCTAssertLessThanOrEqual(textWidth("SAIGNELÉGIER", size: metrics.labelSize, bold: true, mono: true), column,
                                         "\"SAIGNELÉGIER\" at \(metrics.labelSize) pt, \(width), \(language)")
                XCTAssertLessThanOrEqual(textWidth(L10n.Read.divertTag(language: language), size: metrics.labelSize, bold: true) + 12,
                                         column, "the DIVERT tag, \(width), \(language)")
            }
        }
    }

    /// The phone's next line: "SAIGNELÉGIER" and DÉROUTEMENT whole at the phone's label size beside the
    /// figures, on a 6.1" phone too, with a 12-hour clock too.
    func testThePhoneNextLineHoldsTheNamesAtTheirSizes() {
        let metrics = ReadBandMetrics(.phone)
        for (_, layout, width) in Self.layouts where layout == .narrow {
            // The card's and the line's padding, the figures' column, the gap.
            let figures = max(templateWidth(NextFigureTemplates.bearing, metrics) + metrics.figureGap
                                + templateWidth(NextFigureTemplates.distance, metrics),
                              templateWidth(NextFigureTemplates.ete, metrics) + metrics.figureGap
                                + templateWidth(NextFigureTemplates.clock, metrics) + twelveHourClockAllowance(metrics))
            let column = width - 24 - 2 * metrics.cellPadding - figures - metrics.figureGap
            for language in ["en", "fr"] {
                XCTAssertLessThanOrEqual(textWidth("SAIGNELÉGIER", size: metrics.labelSize, bold: true, mono: true), column,
                                         "\"SAIGNELÉGIER\" at \(width), \(language)")
                XCTAssertLessThanOrEqual(textWidth(L10n.Read.divertTag(language: language), size: metrics.labelSize, bold: true) + 12,
                                         column, "the DIVERT tag at \(width), \(language)")
                XCTAssertLessThanOrEqual(textWidth(L10n.Read.nextColumn(language: language), size: metrics.labelSize), column)
            }
        }
    }

    /// NOW | NEXT with the stations the planner gives (a field's "LSGC TWR", the area's "Zurich Info"): the
    /// frequency and the station whole, at their sizes, in an iPad's half, on the phone's NOW line.
    func testAFrequencyAndItsStationFitTheirCell() {
        for (scale, cell) in [(CockpitScale.kneeboard, CGFloat(820 - 32) / 2), (.phone, CGFloat(390 - 24))] {
            let metrics = ReadBandMetrics(scale)
            let tag = max(textWidth("NOW", size: metrics.labelSize, bold: true), textWidth("NEXT", size: metrics.labelSize, bold: true),
                          textWidth("ACT", size: metrics.labelSize, bold: true), textWidth("SUIV", size: metrics.labelSize, bold: true))
            for station in ["Zurich Info", "LSGC TWR", "Geneva Info", "LSZQ AFIS"] {
                let wanted = 2 * metrics.cellPadding + tag + metrics.figureGap
                    + textWidth("120.375", size: metrics.frequencySize, bold: true, mono: true) + metrics.figureGap
                    + textWidth(station, size: metrics.labelSize)
                XCTAssertLessThanOrEqual(wanted, cell, "\(station), \(scale): \(wanted) pt in \(cell)")
            }
        }
    }

    func testTheTextIsNeverUnderTheInFlightSize() {
        for scale in [CockpitScale.kneeboard, .phone] {
            let metrics = ReadBandMetrics(scale)
            let floor = CockpitType.label(for: scale)
            XCTAssertEqual(floor, scale == .kneeboard ? 20 : 17)
            XCTAssertGreaterThanOrEqual(metrics.labelSize, floor)
            XCTAssertGreaterThanOrEqual(metrics.figureSize, floor)
            XCTAssertGreaterThanOrEqual(metrics.frequencySize, floor)
            XCTAssertGreaterThanOrEqual(metrics.identSize * metrics.identMinimumScale, floor - 0.001,
                                        "the name never scales under the label's size")
        }
    }

    /// Each figure in a cell as wide as its widest value: 9.9 → 10.0 NM, 59 min → 1:00 h, a figure → "—"
    /// move nothing beside them.
    func testEachFigureKeepsItsCell() {
        for scale in [CockpitScale.kneeboard, .phone] {
            let metrics = ReadBandMetrics(scale)
            assertOneSize(["—", "206°", "006°", "359°"], NextFigureTemplates.bearing, metrics)
            assertOneSize(["— NM", "9.9 NM", "10.0 NM", "105.0 NM"], NextFigureTemplates.distance, metrics)
            assertOneSize(["— min", "7 min", "59 min", "1:00 h", "9:59 h"], NextFigureTemplates.ete, metrics)
            assertOneSize(["—", DestinationFormat.clock(DestinationLineSample.at(9, 5)),
                           DestinationFormat.clock(DestinationLineSample.at(22, 58))], NextFigureTemplates.clock, metrics)
        }
    }

    // MARK: - The figures

    /// The text the cells show: the map card's formats, "—" where there is none.
    func testTheFiguresReadAsTheMapsCardWroteThem() {
        let next = Sample.next()
        XCTAssertEqual(next.bearingText, "206°")
        XCTAssertEqual(next.distanceText, "17.6 NM")
        XCTAssertEqual(next.eteText, "10 min", "17.6 NM at 104 kt")
        XCTAssertEqual(NextFigures.none.bearingText, "—")
        XCTAssertEqual(NextFigures.none.distanceText, "— NM")
        XCTAssertEqual(NextFigures.none.eteText, "— min")
        XCTAssertEqual(NextFigures.none.etaClock, "—")
        XCTAssertEqual(Sample.next(distance: 104).eteText, "1:00 h")
        XCTAssertNil(Sample.next(gs: 29).live, "no ETE under 30 kt")
        XCTAssertEqual(Sample.next(ident: "E", full: "E (LSGC)").fullIdent, "E (LSGC)")
        XCTAssertEqual(Sample.next(ident: "LSGC").fullIdent, "LSGC", "the plain name when there is no other")
    }

    /// What a pilot typed for a waypoint is read as the number to dial and its words, the words in the
    /// station's place: "119.175 Bern Information" never runs out of its cell as "119.175 Bern Inform…".
    func testATypedFrequencyIsSplitIntoItsNumberAndItsWords() {
        func shown(_ freq: String, station: String = "SAIGNELÉGIER") -> ReadBandFrequencyText {
            ReadBandFrequencyText(PhaseFrequency(station: station, freq: freq, highlighted: true, isEmergency: false))
        }
        XCTAssertEqual(shown("119.175 Bern Information"), .init(frequency: "119.175", station: "Bern Information"))
        XCTAssertEqual(shown("Bern Info 120.100"), .init(frequency: "120.100", station: "Bern Info"))
        XCTAssertEqual(shown("Info 124.705 / Tower 118.125 / Ground 121.900"), .init(frequency: "124.705", station: "Info"),
                       "of several, the first")
        XCTAssertEqual(shown("118.125", station: "LSGC TWR"), .init(frequency: "118.125", station: "LSGC TWR"))
        XCTAssertEqual(shown("120,375"), .init(frequency: "120,375", station: "SAIGNELÉGIER"), "a comma, as typed")
        XCTAssertEqual(shown("Bern Information"), .init(frequency: "Bern Information", station: "SAIGNELÉGIER"),
                       "no number: as typed")
        XCTAssertEqual(ReadBandFrequencyText(nil), .init(frequency: "—", station: ""))
    }

    // MARK: - What VoiceOver and the replays read

    /// The phone's next line reads its name as a part of its own, "E", which the replays look for
    /// (rp-9 on the phone), and never the aerodrome.
    func testThePhoneLineReadsThePlainName() {
        let line = ReadBandSpeech.nextLine(Sample.next(ident: "E", full: "E (LSGC)", bearing: 172, distance: 2.4),
                                           language: "en")
        XCTAssertTrue(line.components(separatedBy: ", ").contains("E"), line)
        XCTAssertFalse(line.contains("LSGC"), line)
        XCTAssertTrue(line.hasPrefix("Next, E, bearing 172 degrees, 2.4 nautical miles, 1 minute, overhead at "), line)
        // French figures and units are joined by no-break spaces.
        let french = ReadBandSpeech.nextLine(Sample.next(ident: "E", bearing: 172, distance: 2.4), language: "fr")
            .replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertTrue(french.components(separatedBy: ", ").contains("E"), french)
        XCTAssertTrue(french.hasPrefix("Suivant, E, relèvement 172 degrés, 2,4 milles marins, 1 minute, à la verticale à "), french)
        XCTAssertEqual(ReadBandSpeech.nextLine(.none, language: "en"), "Next, no waypoint ahead")
        XCTAssertEqual(ReadBandSpeech.nextLine(.none, language: "fr"), "Suivant, aucun point à venir")
        let diverting = ReadBandSpeech.nextLine(Sample.next(ident: "LSZG", diverting: true, bearing: nil, distance: nil),
                                                language: "en")
        XCTAssertEqual(diverting, "DIVERT, LSZG")
    }

    /// The iPad's NEXT says what it shows: "Next, E (LSGC)" (a UI test finds the text), "Diverting to LSZG".
    func testTheNextCellSaysWhatItShows() {
        XCTAssertEqual(ReadBandSpeech.ident(Sample.next(ident: "E", full: "E (LSGC)"), shown: "E (LSGC)", language: "en"),
                       "Next, E (LSGC)")
        XCTAssertEqual(ReadBandSpeech.ident(Sample.next(ident: "LSZG", diverting: true), shown: "LSZG", language: "en"),
                       "Diverting to LSZG")
        XCTAssertEqual(ReadBandSpeech.ident(Sample.next(ident: "LSZG", diverting: true), shown: "LSZG", language: "fr"),
                       "Déroutement vers LSZG")
        XCTAssertEqual(ReadBandSpeech.frequency(title: "NOW", item: Sample.nowField), "NOW, 120.375, LSZQ AFIS")
        XCTAssertEqual(ReadBandSpeech.frequency(title: "NEXT", item: nil), "NEXT, —")
        XCTAssertEqual(ReadBandSpeech.distance(10, language: "en"), "10 nautical miles")
    }

    // MARK: - Stack

    func testTheBandRendersWithinHalfTheDeviceStack() {
        let used = StackProbe.bytesUsed {
            for (_, layout, width) in Self.layouts {
                for state in Sample.states.prefix(3) {
                    let renderer = ImageRenderer(content: band(state, layout, width, "en"))
                    renderer.proposedSize = ProposedViewSize(width: width, height: nil)
                    _ = renderer.uiImage
                }
            }
        }
        XCTAssertLessThan(used, (1 << 20) / 2, "the read band used \(used / 1_024) KB of stack")
    }

    // MARK: - Renders for review

    /// Writes every state, on an iPad and a phone, in English and French, as PNGs into the folder named by
    /// READBAND_SHOTS (`TEST_RUNNER_READBAND_SHOTS` on xcodebuild's command line). Skipped without it.
    func testRenderEveryStateForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["READBAND_SHOTS"], !folder.isEmpty else {
            throw XCTSkip("set READBAND_SHOTS to a folder to write the renders")
        }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, layout, width) in Self.layouts {
            for language in ["en", "fr"] {
                let all = VStack(alignment: .leading, spacing: 10) {
                    ForEach(Sample.states, id: \.name) { state in
                        Text(verbatim: state.name).font(.caption).foregroundColor(.gray).padding(.horizontal, 16)
                        self.band(state, layout, width, language)
                    }
                }
                .padding(.vertical, 12)
                let file = name.lowercased().replacingOccurrences(of: " ", with: "-") + "-\(language).png"
                try writePNG(all, width: width, to: directory.appendingPathComponent(file))
            }
        }
    }

    // MARK: - Helpers

    private typealias State = (name: String, strip: StripReading, next: NextFigures, now: PhaseFrequency?,
                               nextFrequency: PhaseFrequency?)

    private func band(_ state: State, _ layout: CockpitLayout, _ width: CGFloat, _ language: String,
                      onLayout: ((ReadBandPart, CGRect) -> Void)? = nil) -> some View {
        CockpitReadRows(layout: layout, scale: layout == .wide ? .kneeboard : .phone, strip: state.strip,
                        next: state.next, now: state.now, nextFrequency: state.nextFrequency, onShowRoute: {},
                        onSpeedTap: {}, language: language, onLayout: onLayout)
            .frame(width: width)
            .environment(\.cockpitTheme, CockpitTheme.resolve(.day))
    }

    /// Where each part of the band landed, in its space.
    private func parts(_ state: State, _ layout: CockpitLayout, _ width: CGFloat,
                       _ language: String) -> [ReadBandPart: CGRect] {
        final class Box { var parts: [ReadBandPart: CGRect] = [:] }
        let box = Box()
        let renderer = ImageRenderer(content: band(state, layout, width, language, onLayout: { box.parts[$0] = $1 }))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        _ = renderer.uiImage
        return box.parts
    }

    private func height(_ state: State, _ layout: CockpitLayout, _ width: CGFloat, _ language: String) -> CGFloat {
        UIHostingController(rootView: band(state, layout, width, language))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private func assertSameFrame(_ a: CGRect, _ b: CGRect, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: 0.5, message, file: file, line: line)
    }

    private func textWidth(_ text: String, size: CGFloat, bold: Bool = false, mono: Bool = false) -> CGFloat {
        let font = UIFont.aero(size: size, weight: bold ? .bold : .regular, monospaced: mono)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func templateWidth(_ widest: [String], _ metrics: ReadBandMetrics) -> CGFloat {
        widest.map { textWidth($0, size: metrics.figureSize, bold: true, mono: true) }.max() ?? 0
    }

    /// What a device writing "10:58 PM" adds to the ETA's cell over the simulator's own clock (24-hour in
    /// a Swiss region): the band must fit either way, wherever the tests run.
    private func twelveHourClockAllowance(_ metrics: ReadBandMetrics) -> CGFloat {
        max(0, textWidth("10:58 PM", size: metrics.figureSize, bold: true, mono: true)
                - textWidth(NextWaypointReadout.widestETA, size: metrics.figureSize, bold: true, mono: true))
    }

    private func assertOneSize(_ texts: [String], _ widest: [String], _ metrics: ReadBandMetrics,
                               file: StaticString = #filePath, line: UInt = #line) {
        let sizes = texts.map { text in
            UIHostingController(rootView: DestinationFigureCell(text: text, widest: widest, font: metrics.figureFont,
                                                                color: .white))
                .sizeThatFits(in: CGSize(width: 1_000, height: 1_000))
        }
        for (text, size) in zip(texts, sizes) {
            XCTAssertEqual(size, sizes[0], "\"\(text)\" in \(widest)", file: file, line: line)
        }
    }

    private func writePNG(_ view: some View, width: CGFloat, to url: URL) throws {
        let content = view
            .frame(width: width)
            .background(CockpitTheme.day.background)
            .environment(\.cockpitTheme, .day)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        let data = try XCTUnwrap(renderer.uiImage?.pngData(), "rendered \(url.lastPathComponent)")
        try data.write(to: url)
    }
}
