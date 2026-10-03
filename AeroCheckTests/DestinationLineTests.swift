import SwiftUI
import XCTest
@testable import AeroCheck

/// The DEST line (6.2.0), drawn from `DestinationEstimate`: one height whatever its figures do, nothing
/// cut at the in-flight sizes, the route's notches where `RouteTrack` puts them, and what VoiceOver reads.
/// The estimate's own rules are in `DestinationEstimateTests`.
@MainActor
final class DestinationLineTests: XCTestCase {

    /// ROUTE's width for the line: an iPad Air in portrait less 16 pt each side, an iPhone 17 Pro less 12.
    private enum Width {
        static let iPad: CGFloat = 820 - 32
        static let phone: CGFloat = 402 - 24
    }

    private typealias Sample = DestinationLineSample

    // MARK: - One height

    /// Every state with the track's row: the figures change, appear and go, the line doesn't move. On
    /// both devices and in both languages.
    func testTheLineKeepsOneHeightWhateverItsFiguresDo() {
        for (scale, width) in [(CockpitScale.kneeboard, Width.iPad), (.phone, Width.phone)] {
            for language in ["en", "fr"] {
                let reference = height(Sample.behind, scale, width, language)
                XCTAssertGreaterThan(reference, 0)
                for state in trackRowStates {
                    XCTAssertEqual(height(state.estimate, scale, width, language, resumes: state.resumes),
                                   reference, accuracy: 0.5, "\(state.name), \(scale), \(language)")
                }
            }
        }
    }

    /// Diverting: "Resume route" in the track's place, one height whatever the field and its figures.
    /// Without the button (a viewer), the line keeps the track's height.
    func testDivertingKeepsOneHeightToo() {
        let states: [(String, DestinationEstimate)] = [
            ("diverting", Sample.diverting),
            ("diverting below 30 kt", Sample.route(live: 12.4, gs: 20, diversion: "LSZG")),
            ("diverting with no fix", Sample.route(live: nil, diversion: "LSZG")),
            ("diverting to SAIGNELÉGIER", Sample.long(diverting: true)),
        ]
        for (scale, width) in [(CockpitScale.kneeboard, Width.iPad), (.phone, Width.phone)] {
            for language in ["en", "fr"] {
                let reference = height(Sample.diverting, scale, width, language)
                for (name, estimate) in states {
                    XCTAssertEqual(height(estimate, scale, width, language), reference, accuracy: 0.5,
                                   "\(name), \(scale), \(language)")
                }
                XCTAssertGreaterThan(reference, height(Sample.behind, scale, width, language),
                                     "the button is taller than the track (\(scale))")
                XCTAssertEqual(height(Sample.diverting, scale, width, language, resumes: false),
                               height(Sample.behind, scale, width, language), accuracy: 0.5,
                               "no button: the track's height (\(scale))")
            }
        }
    }

    /// Each figure in a cell as wide as its widest value: 10 → 9 NM, 59 min → 1:00 h, a figure → "—",
    /// ▲ → ▼ move nothing beside them.
    func testEachFigureKeepsItsCell() {
        for scale in [CockpitScale.kneeboard, .phone] {
            let size = DestinationLine.Metrics(scale).figureSize
            let font = Font.aero(size: size, design: .monospaced)
            let bold = Font.aero(size: size, weight: .bold, design: .monospaced)
            assertOneSize(["—", "9 NM", "83 NM", "105 NM"], DestinationLine.distanceTemplates, font, scale)
            assertOneSize(["—", "9 min", "59 min", "1:00 h", "1:05 h"], DestinationLine.eteTemplates, font, scale)
            assertOneSize(["ETA —", "ETA " + DestinationFormat.clock(Sample.at(9, 5)),
                           "ETO " + DestinationFormat.clock(Sample.at(22, 58))],
                          DestinationLine.clockTemplates, font, scale)
            assertOneSize(["", "±0", "▲3", "▼12"], DestinationLine.deltaTemplates, bold, scale)
        }
    }

    // MARK: - Nothing cut

    /// The widest line (a 12-letter field, 105 NM, "1:05 h", an evening ETA, ▼12) and every other state
    /// fit at their full size: the width the line asks for with nothing scaled, and room for a 12-hour
    /// clock, is within ROUTE's, on an iPad in portrait and on a phone, in English and in French
    /// ("Reprendre la route").
    func testNothingIsCutAtTheInFlightSizes() {
        let states = trackRowStates + [LineCase("diverting", Sample.diverting),
                                       LineCase("diverting to SAIGNELÉGIER", Sample.long(diverting: true))]
        for (scale, width) in [(CockpitScale.kneeboard, Width.iPad), (.phone, Width.phone)] {
            for language in ["en", "fr"] {
                for state in states {
                    let wanted = idealWidth(state.estimate, scale, language, resumes: state.resumes)
                        + twelveHourClockAllowance(scale)
                    XCTAssertLessThanOrEqual(wanted, width, "\(state.name), \(scale), \(language): \(wanted) pt wanted")
                }
            }
        }
    }

    func testTheLineIsNeverUnderTheInFlightTextSize() {
        for scale in [CockpitScale.kneeboard, .phone] {
            let metrics = DestinationLine.Metrics(scale)
            let floor = CockpitType.label(for: scale)
            XCTAssertEqual(floor, scale == .kneeboard ? 20 : 17)
            XCTAssertGreaterThanOrEqual(metrics.labelSize, floor)
            XCTAssertGreaterThanOrEqual(metrics.identSize, floor)
            XCTAssertGreaterThanOrEqual(metrics.figureSize, floor)
        }
        XCTAssertEqual(RouteTrackBar.Metrics(.kneeboard).barHeight, 6)
        XCTAssertEqual(RouteTrackBar.Metrics(.phone).barHeight, 5)
    }

    // MARK: - The route to scale

    /// The notches sit at `RouteTrack`'s fractions along the track, the aircraft at the flown one, half an
    /// aircraft in from each end. The proposal's route: LSGC at 29.6 of 82.6 NM, 12 NM flown.
    func testTheNotchesSitWhereRouteTrackPutsThem() throws {
        let track = try XCTUnwrap(Sample.behind.track)
        XCTAssertEqual(track.notches[1], 29.6 / 82.6, accuracy: 1e-9)
        XCTAssertEqual(track.flownNM, 12, accuracy: 1e-6)
        for scale in [CockpitScale.kneeboard, .phone] {
            let metrics = RouteTrackBar.Metrics(scale)
            let width: CGFloat = scale == .kneeboard ? Width.iPad - 32 : Width.phone - 24
            let place = RouteTrackBar.placement(track, width: width, metrics: metrics)
            let length = width - 2 * metrics.inset
            XCTAssertEqual(place.notches.count, 6)
            for (x, fraction) in zip(place.notches, track.notches) {
                XCTAssertEqual(x, metrics.inset + CGFloat(fraction) * length, accuracy: 1e-6)
            }
            XCTAssertEqual(place.notches.first, metrics.inset)
            XCTAssertEqual(try XCTUnwrap(place.notches.last), width - metrics.inset, accuracy: 1e-6)
            XCTAssertEqual(place.next, 1)
            XCTAssertEqual(place.aircraft, metrics.inset + CGFloat(track.flown) * length, accuracy: 1e-6)
        }
        let done = try XCTUnwrap(Sample.completed.track)
        let place = RouteTrackBar.placement(done, width: 500, metrics: .init(.kneeboard))
        XCTAssertNil(place.next, "no magenta notch once the destination is marked")
        XCTAssertEqual(place.aircraft, place.end, "the aircraft at the end")
    }

    /// What is drawn is what `placement` says: a grey notch at each waypoint, the next one magenta and
    /// taller, nothing between them, the flown part green up to the aircraft, the aircraft over it.
    func testTheTrackIsDrawnWhereThePlacementSays() throws {
        let estimate = Sample.behind
        let track = try XCTUnwrap(estimate.track)
        let theme = CockpitTheme.day
        let metrics = RouteTrackBar.Metrics(.kneeboard)
        let width: CGFloat = 756
        let place = RouteTrackBar.placement(track, width: width, metrics: metrics)
        let pixels = try render(RouteTrackBar(track: track, nextIdent: estimate.nextIdent, scale: .kneeboard),
                                width: width, height: metrics.rowHeight)
        let mid = metrics.rowHeight / 2
        let aboveTheBar = mid - metrics.notchHeight / 2 + 2
        let aboveTheNotches = mid - metrics.nextNotchHeight / 2 + 1.5
        for (index, x) in place.notches.enumerated() where index != place.next {
            XCTAssertTrue(pixels.matches(theme.textSecondary, x: x - 0.25, y: aboveTheBar), "notch \(index) at \(x)")
            XCTAssertTrue(pixels.isClear(x: x - 0.25, y: aboveTheNotches), "notch \(index) is the short kind")
        }
        let next = place.notches[1]
        XCTAssertTrue(pixels.matches(theme.route, x: next - 0.25, y: aboveTheNotches), "the next notch, magenta and taller")
        for (left, right) in zip(place.notches, place.notches.dropFirst()) where right - left > 40 {
            let between = (left + right) / 2
            guard abs(between - place.aircraft) > metrics.aircraftSize else { continue }
            XCTAssertTrue(pixels.isClear(x: between, y: aboveTheBar), "nothing between the notches at \(between)")
        }
        XCTAssertTrue(pixels.matches(theme.onTarget, x: place.start + 20, y: mid), "flown")
        XCTAssertFalse(pixels.matches(theme.onTarget, x: (place.notches[4] + place.notches[5]) / 2, y: mid), "not flown")
        XCTAssertTrue(pixels.matches(theme.textPrimary, x: place.aircraft - 2, y: mid), "the aircraft")
    }

    // MARK: - What VoiceOver reads

    func testVoiceOverReadsTheLineAsOneSentence() {
        let clock = DestinationFormat.clock
        // French puts a no-break space between the figure and the unit.
        let milles = { (nm: Double) in DestinationSpeech.distance(nm, language: "fr") }
        XCTAssertEqual(milles(71).replacingOccurrences(of: "\u{A0}", with: " ")
                           .replacingOccurrences(of: "\u{202F}", with: " "), "71 milles marins")
        let behind = Sample.behind
        XCTAssertEqual(DestinationSpeech.line(behind, language: "en"),
                       "Destination LSZB, 71 nautical miles, 41 minutes, overhead at \(clock(behind.eta!)), "
                       + "3 minutes behind the plan. Planned arrival")
        XCTAssertEqual(DestinationSpeech.line(behind, language: "fr"),
                       "Destination LSZB, \(milles(71)), 41 minutes, à la verticale à \(clock(behind.eta!)), "
                       + "3 minutes de retard sur le plan. Arrivée prévue")
        XCTAssertEqual(DestinationSpeech.line(Sample.ahead, language: "en"),
                       "Destination LSZB, 71 nautical miles, 41 minutes, overhead at \(clock(Sample.ahead.eta!)), "
                       + "2 minutes ahead of the plan. Planned arrival")
        XCTAssertEqual(DestinationSpeech.line(Sample.slow, language: "en"),
                       "Destination LSZB, 83 nautical miles, planned overhead at \(clock(Sample.at(11, 55))). Planned arrival")
        XCTAssertEqual(DestinationSpeech.line(Sample.slow, language: "fr"),
                       "Destination LSZB, \(milles(83)), verticale prévue à \(clock(Sample.at(11, 55))). Arrivée prévue")
        XCTAssertEqual(DestinationSpeech.line(Sample.diverting, language: "en"),
                       "Diverting to LSZG, 12 nautical miles, 7 minutes, overhead at \(clock(Sample.diverting.eta!))")
        XCTAssertEqual(DestinationSpeech.line(Sample.diverting, language: "fr"),
                       "Déroutement vers LSZG, \(milles(12)), 7 minutes, à la verticale à \(clock(Sample.diverting.eta!))")
        XCTAssertEqual(DestinationSpeech.line(Sample.completed, language: "en"),
                       "Destination LSZB reached, planned overhead at \(clock(Sample.at(11, 55))), "
                       + "2 minutes ahead of the plan. Planned arrival")
        XCTAssertEqual(DestinationSpeech.line(Sample.completed, language: "fr"),
                       "Destination LSZB atteinte, verticale prévue à \(clock(Sample.at(11, 55))), "
                       + "2 minutes d’avance sur le plan. Arrivée prévue")
    }

    func testDurationsAndDeltaAreSpeltOut() {
        XCTAssertEqual(DestinationSpeech.duration(minutes: 1, language: "en"), "1 minute")
        XCTAssertEqual(DestinationSpeech.duration(minutes: 65, language: "en"), "1 hour, 5 minutes")
        XCTAssertEqual(DestinationSpeech.duration(minutes: 60, language: "en"), "1 hour")
        XCTAssertEqual(DestinationSpeech.delta(-12 * 60, language: "en"), "12 minutes behind the plan")
        XCTAssertEqual(DestinationSpeech.delta(20, language: "en"), "on time")
        XCTAssertEqual(DestinationSpeech.delta(20, language: "fr"), "à l’heure")
        XCTAssertEqual(DestinationSpeech.delta(61, language: "fr"), "1 minute d’avance sur le plan")
        XCTAssertEqual(DestinationSpeech.distance(1, language: "en"), "1 nautical mile")
    }

    /// The line's value is the Flight Log's DEST ETO, the arrival allowance in, as the device writes a
    /// time: `CockpitPilot.destinationETA()` reads it there (eet-3, eet-4). None while diverting.
    func testTheLinesValueIsThePlansDestinationETO() {
        XCTAssertEqual(DestinationSpeech.testHook(Sample.behind), DestinationFormat.clock(Sample.at(12, 0)))
        XCTAssertEqual(DestinationSpeech.testHook(Sample.slow), DestinationFormat.clock(Sample.at(12, 0)))
        XCTAssertEqual(DestinationSpeech.testHook(Sample.completed), DestinationFormat.clock(Sample.at(12, 0)))
        XCTAssertEqual(DestinationSpeech.testHook(Sample.diverting), "")
    }

    func testVoiceOverReadsTheTrackAsHowFarAlong() throws {
        let track = try XCTUnwrap(Sample.behind.track)
        XCTAssertEqual(Sample.behind.nextIdent, "LSGC")
        XCTAssertEqual(RouteTrackBar.spoken(track, next: "LSGC", language: "en"), "12 of 83 NM flown, next LSGC")
        XCTAssertEqual(RouteTrackBar.spoken(track, next: "LSGC", language: "fr"), "12 NM parcourus sur 83, prochain LSGC")
        let done = try XCTUnwrap(Sample.completed.track)
        XCTAssertNil(Sample.completed.nextIdent)
        XCTAssertEqual(RouteTrackBar.spoken(done, next: nil, language: "en"), "83 of 83 NM flown")
        XCTAssertEqual(RouteTrackBar.spoken(done, next: nil, language: "fr"), "83 NM parcourus sur 83")
    }

    func testResumeRouteSaysWhatTheMapsCardSays() {
        XCTAssertEqual(L10n.Dest.resumeRoute(language: "en"), "Resume route")
        XCTAssertEqual(L10n.Dest.resumeRoute(language: "fr"), "Reprendre la route")
        XCTAssertEqual(L10n.Dest.resumeRoute(), L10n.Trip.resumeRoute)
    }

    // MARK: - Stack

    /// Every state on an iPad and on a phone, rendered once, as `ViewStackBudgetTests` measures the
    /// screens: well under half the device's main-thread stack.
    func testTheLineRendersWithinHalfTheDeviceStack() {
        let used = StackProbe.bytesUsed {
            for scale in [CockpitScale.kneeboard, .phone] {
                let renderer = ImageRenderer(content: allStates(scale))
                renderer.proposedSize = ProposedViewSize(width: scale == .kneeboard ? 820 : 402, height: nil)
                _ = renderer.uiImage
            }
        }
        XCTAssertLessThan(used, (1 << 20) / 2, "the DEST line used \(used / 1_024) KB of stack")
    }

    // MARK: - Renders for review

    /// Writes each state, on an iPad and a phone, in English and French, as PNGs into the folder named by
    /// DESTLINE_SHOTS (`TEST_RUNNER_DESTLINE_SHOTS` on xcodebuild's command line). Skipped without it.
    func testRenderEveryStateForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["DESTLINE_SHOTS"], !folder.isEmpty else {
            throw XCTSkip("set DESTLINE_SHOTS to a folder to write the renders")
        }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (device, scale, width) in [("ipad", CockpitScale.kneeboard, CGFloat(820)), ("phone", .phone, 402)] {
            for language in ["en", "fr"] {
                for state in Sample.states {
                    let line = DestinationLine(estimate: state.estimate, scale: scale, onResumeRoute: {}, language: language)
                        .padding(scale == .kneeboard ? 16 : 12)
                    try writePNG(line, width: width, to: directory.appendingPathComponent("\(device)-\(state.name)-\(language).png"))
                }
                try writePNG(allStates(scale, language: language), width: width,
                             to: directory.appendingPathComponent("\(device)-all-\(language).png"))
            }
        }
    }

    // MARK: - Helpers

    /// The states that show the track's row (or its room): the samples, then the moments a figure turns
    /// over (29 → 31 kt, 59 → 60 min, ▲ ↔ ±0 ↔ ▼), no fix, a route with no length, and the widest line.
    private var trackRowStates: [LineCase] {
        [LineCase("ahead", Sample.ahead), LineCase("behind", Sample.behind),
         LineCase("on time", Sample.route(plannedOver: Sample.at(11, 58))), LineCase("slow", Sample.slow),
         LineCase("29 kt", Sample.route(gs: 29)), LineCase("31 kt", Sample.route(gs: 31)),
         LineCase("59 min", Sample.route(live: 49.2)), LineCase("60 min", Sample.route(live: 51.2)),
         LineCase("no fix", Sample.route(next: 2, live: nil)), LineCase("completed", Sample.completed),
         LineCase("no length", noLengthRoute()), LineCase("SAIGNELÉGIER", Sample.long()),
         LineCase("diverting, a viewer's (no button)", Sample.diverting, resumes: false)]
    }

    /// A line to measure, with or without its "Resume route".
    private struct LineCase {
        let name: String
        let estimate: DestinationEstimate
        var resumes = true

        init(_ name: String, _ estimate: DestinationEstimate, resumes: Bool = true) {
            self.name = name
            self.estimate = estimate
            self.resumes = resumes
        }
    }

    private func noLengthRoute() -> DestinationEstimate {
        DestinationEstimator.estimate(DestinationInput(
            names: ["LSZQ", "LSZB"], legDistanceNM: [nil, nil], legEET: [nil, nil], nextIndex: 1,
            plannedOverDestination: nil, plannedDestinationETO: nil, destinationATO: nil, diversionIdent: nil,
            liveDistanceNM: 20, groundSpeedKnots: 100, now: Sample.at(11, 0)))!
    }

    private func line(_ estimate: DestinationEstimate, _ scale: CockpitScale, _ language: String,
                      resumes: Bool = true) -> some View {
        DestinationLine(estimate: estimate, scale: scale, onResumeRoute: resumes ? {} : nil, language: language)
            .environment(\.cockpitTheme, .day)
    }

    private func height(_ estimate: DestinationEstimate, _ scale: CockpitScale, _ width: CGFloat, _ language: String,
                        resumes: Bool = true) -> CGFloat {
        UIHostingController(rootView: line(estimate, scale, language, resumes: resumes))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// What a device writing "10:58 PM" adds to the clock's cell, over the simulator's own clock (24-hour
    /// in a Swiss region): the line must fit either way, wherever the tests run.
    private func twelveHourClockAllowance(_ scale: CockpitScale) -> CGFloat {
        let font = Font.aero(size: DestinationLine.Metrics(scale).figureSize, design: .monospaced)
        func width(_ widest: [String]) -> CGFloat {
            UIHostingController(rootView: DestinationFigureCell(text: "", widest: widest, font: font, color: .white))
                .sizeThatFits(in: CGSize(width: 1_000, height: 1_000)).width
        }
        return max(0, width(["ETA 10:58 PM", "ETO 10:58 PM"]) - width(DestinationLine.clockTemplates))
    }

    /// The width the line asks for with every text at its full size.
    private func idealWidth(_ estimate: DestinationEstimate, _ scale: CockpitScale, _ language: String,
                            resumes: Bool) -> CGFloat {
        UIHostingController(rootView: line(estimate, scale, language, resumes: resumes).fixedSize())
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width
    }

    private func assertOneSize(_ texts: [String], _ widest: [String], _ font: Font, _ scale: CockpitScale,
                               file: StaticString = #filePath, line: UInt = #line) {
        let sizes = texts.map { text in
            UIHostingController(rootView: DestinationFigureCell(text: text, widest: widest, font: font, color: .white))
                .sizeThatFits(in: CGSize(width: 1_000, height: 1_000))
        }
        for (text, size) in zip(texts, sizes) {
            XCTAssertEqual(size, sizes[0], "\"\(text)\" in \(widest), \(scale)", file: file, line: line)
        }
    }

    private func allStates(_ scale: CockpitScale, language: String = "en") -> some View {
        VStack(spacing: 12) {
            ForEach(Sample.states, id: \.name) { state in
                DestinationLine(estimate: state.estimate, scale: scale, onResumeRoute: {}, language: language)
            }
        }
        .padding(scale == .kneeboard ? 16 : 12)
        .environment(\.cockpitTheme, .day)
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

    // MARK: Pixels

    private func render(_ view: some View, width: CGFloat, height: CGFloat) throws -> Pixels {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height).environment(\.cockpitTheme, .day))
        renderer.scale = 2
        return try XCTUnwrap(Pixels(try XCTUnwrap(renderer.cgImage), scale: 2))
    }

    /// An image's pixels, RGBA, read at points.
    private struct Pixels {
        let width: Int
        let height: Int
        let scale: CGFloat
        let bytes: [UInt8]

        init?(_ image: CGImage, scale: CGFloat) {
            width = image.width
            height = image.height
            self.scale = scale
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drawn else { return nil }
            self.bytes = bytes
        }

        /// RGBA at a point, the top-left origin of the view.
        func rgba(x: CGFloat, y: CGFloat) -> (r: Int, g: Int, b: Int, a: Int) {
            let px = min(max(Int(x * scale), 0), width - 1)
            let py = min(max(Int(y * scale), 0), height - 1)
            let i = (py * width + px) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
        }

        func isClear(x: CGFloat, y: CGFloat) -> Bool { rgba(x: x, y: y).a == 0 }

        /// Opaque and within a few levels of `color`.
        func matches(_ color: Color, x: CGFloat, y: CGFloat) -> Bool {
            let pixel = rgba(x: x, y: y)
            let resolved = UIColor(color).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                            intent: .defaultIntent, options: nil)?.components ?? []
            guard pixel.a > 250, resolved.count >= 3 else { return false }
            let target = resolved.prefix(3).map { Int(($0 * 255).rounded()) }
            return abs(pixel.r - target[0]) <= 6 && abs(pixel.g - target[1]) <= 6 && abs(pixel.b - target[2]) <= 6
        }
    }
}
