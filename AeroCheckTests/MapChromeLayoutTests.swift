import SwiftUI
import XCTest
import MapKit
@testable import AeroCheck

/// The MAP page's chrome (6.2.0): the right-edge stack, the status slot, the edge arrow and the scale over
/// the chart. Its frames come from the chart's size and the device alone (`MapChromeGeometry`), so
/// nothing moves whatever it shows; every state fits its slot in English and French at the in-flight
/// sizes; and it leaves the chart free. The rules that pick the state are in `CockpitStatusTests`.
@MainActor
final class MapChromeLayoutTests: XCTestCase {

    private typealias Sample = MapChromeSample
    private typealias Chart = MapChromeSample.Chart
    private typealias Control = MapChromeGeometry.Control

    // MARK: - Frames that never move

    /// The stack's frames are the geometry's whatever the chrome shows: centre filled or not, N↑ or TRK,
    /// a state in the slot or none, the stale-airspace triangle or not, the scale or not.
    func testTheStackKeepsItsFramesWhateverTheChromeShows() {
        for chart in Chart.allCases {
            let geometry = MapChromeGeometry(size: chart.size, scale: chart.scale)
            for variant in variants(chart) {
                let placed = placedFrames(variant.model, chart, scaleShown: variant.scaleShown)
                let controls = placed.compactMapKeys { element -> Control? in
                    if case .control(let control) = element { return control }
                    return nil
                }
                XCTAssertEqual(Set(controls.keys), Set(geometry.controls), "\(chart.rawValue), \(variant.name)")
                for control in geometry.controls {
                    assertEqual(controls[control], geometry.frame(control), "\(control), \(chart.rawValue), \(variant.name)")
                }
            }
        }
    }

    /// One slot, one size, whatever state it holds: UNDO with any message, GPS, OFF ROUTE, CHART OFFLINE,
    /// TELL FIS, SIGMET, BRIEFING. And per device, not per orientation: the iPad's is the same on its side.
    func testTheSlotKeepsOneFrameWhateverStateItHolds() {
        for chart in Chart.allCases {
            let geometry = MapChromeGeometry(size: chart.size, scale: chart.scale)
            for language in ["en", "fr"] {
                for state in allStates(language: language) {
                    for panned in [false, true] {
                        let placed = placedFrames(Sample.model(status: state.status, undo: state.undo, panned: panned),
                                                  chart, language: language)
                        assertEqual(placed[.status], geometry.statusSlot, "\(state.name), \(chart.rawValue), \(language)")
                    }
                }
                XCTAssertNil(placedFrames(Sample.model(), chart, language: language)[.status], "a dark slot draws nothing")
            }
        }
        let portrait = MapChromeGeometry(size: Chart.iPadPortrait.size, scale: .kneeboard).statusSlot.size
        let landscape = MapChromeGeometry(size: Chart.iPadLandscape.size, scale: .kneeboard).statusSlot.size
        XCTAssertEqual(portrait, landscape, "the iPad's slot: one size in both orientations")
        XCTAssertEqual(portrait, CGSize(width: 480, height: 78))
        XCTAssertEqual(MapChromeGeometry(size: Chart.phone.size, scale: .phone).statusSlot.size,
                       CGSize(width: 286, height: 92), "the phone's: all the width beside the stack")
    }

    /// Zoom + and − on the iPad only (the author's Q6): the phone pinches.
    func testZoomIsOnTheIPadOnly() {
        XCTAssertEqual(MapChromeGeometry.controls(for: .kneeboard), [.orientation, .layers, .centre, .zoomIn, .zoomOut])
        XCTAssertEqual(MapChromeGeometry.controls(for: .phone), [.orientation, .layers, .centre])
        for chart in Chart.allCases {
            let placed = placedFrames(Sample.model(), chart)
            let hasZoom = placed[.control(.zoomIn)] != nil && placed[.control(.zoomOut)] != nil
            XCTAssertEqual(hasZoom, chart.scale == .kneeboard, chart.rawValue)
            XCTAssertNotNil(placed[.control(.orientation)], chart.rawValue)
            XCTAssertNotNil(placed[.control(.layers)], chart.rawValue)
            XCTAssertNotNil(placed[.control(.centre)], chart.rawValue)
        }
    }

    // MARK: - Where everything goes

    /// The stack hangs from the foot of the right edge, where the thumb is and where the chart shows least
    /// of what is ahead in track up: a column where the chart is tall enough (the iPad in portrait, the
    /// phone), else a row along the chart's foot, at the right (the iPad on its side).
    func testTheStackHangsFromTheFootOfTheRightEdge() throws {
        let portrait = MapChromeGeometry(size: Chart.iPadPortrait.size, scale: .kneeboard)
        XCTAssertTrue(portrait.isColumn)
        XCTAssertEqual(portrait.frame(.orientation), CGRect(x: 726, y: 114, width: 78, height: 78))
        XCTAssertEqual(portrait.frame(.zoomOut), CGRect(x: 726, y: 466, width: 78, height: 78))
        XCTAssertEqual(portrait.stack.maxX, 820 - 16)
        XCTAssertEqual(portrait.stack.maxY, 560 - 16)
        XCTAssertEqual(portrait.controls, [.orientation, .layers, .centre, .zoomIn, .zoomOut])
        let order = portrait.controls.map { portrait.frame($0).minY }
        XCTAssertEqual(order, order.sorted(), "N↑, layers, centre, +, − from the top")

        // On its side, today's chart (270 pt) and the plan's estimate (320): no room for five controls
        // up the edge (462 pt), so a row at the foot, − before + as on the map's row.
        for height in [CGFloat(270), 320] {
            let side = MapChromeGeometry(size: CGSize(width: 1180, height: height), scale: .kneeboard)
            XCTAssertFalse(side.isColumn, "\(height)")
            XCTAssertEqual(side.controls, [.orientation, .layers, .centre, .zoomOut, .zoomIn])
            XCTAssertEqual(side.frame(.zoomIn), CGRect(x: 1086, y: height - 94, width: 78, height: 78))
            XCTAssertEqual(side.frame(.orientation), CGRect(x: 734, y: height - 94, width: 78, height: 78))
            let across = side.controls.map { side.frame($0).minX }
            XCTAssertEqual(across, across.sorted(), "N↑, layers, centre, −, + from the left")
            XCTAssertEqual(side.statusSlot.size, CGSize(width: 480, height: 78))
        }

        let phone = MapChromeGeometry(size: Chart.phone.size, scale: .phone)
        XCTAssertTrue(phone.isColumn, "three 72 pt controls fit a 6.1-inch phone's chart")
        XCTAssertEqual(phone.frame(.orientation), CGRect(x: 306, y: 16, width: 72, height: 72))
        XCTAssertEqual(phone.frame(.centre).maxY, 256 - 12)
        // A chart shorter than the column: a row, the slot then as wide as the chart, the scale over the row.
        let short = MapChromeGeometry(size: CGSize(width: 390, height: 240), scale: .phone)
        XCTAssertFalse(short.isColumn)
        XCTAssertEqual(short.statusSlot.width, 390 - 24)
        XCTAssertFalse(short.scale.intersects(short.stack))

        for chart in Chart.allCases {
            let geometry = MapChromeGeometry(size: chart.size, scale: chart.scale)
            let bounds = CGRect(origin: .zero, size: chart.size)
            let pieces = geometry.controls.map { ("\($0)", geometry.frame($0)) }
                + [("slot", geometry.statusSlot)]
            for (name, frame) in pieces {
                XCTAssertTrue(bounds.contains(frame), "\(name) on the chart, \(chart.rawValue)")
            }
            for (index, (name, frame)) in pieces.enumerated() {
                for (other, otherFrame) in pieces.dropFirst(index + 1) {
                    XCTAssertFalse(frame.intersects(otherFrame), "\(name) and \(other) apart, \(chart.rawValue)")
                }
                XCTAssertFalse(geometry.arrowBounds.intersects(frame), "the arrow's room clear of \(name), \(chart.rawValue)")
            }
            XCTAssertEqual(geometry.statusSlot.origin, CGPoint(x: geometry.metrics.margin, y: geometry.metrics.margin),
                           "the slot at the top left, \(chart.rawValue)")
            XCTAssertEqual(geometry.scale.minX, geometry.metrics.margin)
            XCTAssertEqual(geometry.scale.maxY, chart.size.height - geometry.metrics.margin, "the scale at the foot, left")
            for control in geometry.controls {
                XCTAssertFalse(geometry.scale.intersects(geometry.frame(control)), "the scale clear of \(control)")
            }
        }
    }

    /// The scale shows only when asked (a change of zoom, `ScaleVisibility`), at its place, under nothing.
    func testTheScaleShowsOnlyWhenAskedAtTheFootOfTheLeftEdge() {
        for chart in Chart.allCases {
            let geometry = MapChromeGeometry(size: chart.size, scale: chart.scale)
            XCTAssertNil(placedFrames(Sample.model(), chart)[.scale], "no change of zoom, no scale (\(chart.rawValue))")
            assertEqual(placedFrames(Sample.model(), chart, scaleShown: true)[.scale], geometry.scale, chart.rawValue)
        }
    }

    // MARK: - The edge arrow

    /// Off the chart in any direction, or hidden under a control, the arrow sits on the edge of its room
    /// (never over the stack or the slot) and points straight at the aircraft; while the aircraft can be
    /// seen, there is none.
    func testTheEdgeArrowPointsAtTheAircraftAndKeepsClearOfTheChrome() throws {
        for chart in Chart.allCases {
            let geometry = MapChromeGeometry(size: chart.size, scale: chart.scale)
            let w = chart.size.width, h = chart.size.height
            let off: [(String, CGPoint)] = [
                ("north", CGPoint(x: w / 2, y: -600)), ("north-east", CGPoint(x: w + 400, y: -400)),
                ("east", CGPoint(x: w + 900, y: h / 2)), ("south-east", CGPoint(x: w + 300, y: h + 300)),
                ("south", CGPoint(x: w / 3, y: h + 700)), ("south-west", CGPoint(x: -300, y: h + 300)),
                ("west", CGPoint(x: -900, y: h / 2)), ("north-west", CGPoint(x: -400, y: -400)),
                ("under centre", CGPoint(x: geometry.frame(.centre).midX, y: geometry.frame(.centre).midY)),
            ]
            for (name, point) in off {
                let arrow = try XCTUnwrap(geometry.edgeArrow(toward: point), "\(name), \(chart.rawValue)")
                let side = geometry.metrics.arrowSize
                let frame = CGRect(x: arrow.point.x - side / 2, y: arrow.point.y - side / 2, width: side, height: side)
                XCTAssertTrue(geometry.arrowBounds.insetBy(dx: -0.01, dy: -0.01).contains(frame), "\(name), \(chart.rawValue)")
                for control in geometry.controls {
                    XCTAssertFalse(frame.intersects(geometry.frame(control)), "\(name) clear of \(control), \(chart.rawValue)")
                }
                XCTAssertFalse(frame.intersects(geometry.statusSlot), "\(name) clear of the slot, \(chart.rawValue)")
                var toAircraft = atan2(point.x - arrow.point.x, -(point.y - arrow.point.y)) * 180 / .pi
                if toAircraft < 0 { toAircraft += 360 }
                XCTAssertEqual(arrow.degrees, toAircraft, accuracy: 0.01, "\(name) points at it, \(chart.rawValue)")
            }
            XCTAssertNil(geometry.edgeArrow(toward: CGPoint(x: w / 2, y: h / 2)), "in sight, \(chart.rawValue)")
            XCTAssertNil(geometry.edgeArrow(toward: CGPoint(x: geometry.statusSlot.maxX - 10, y: 50)),
                         "in sight, at the top, \(chart.rawValue)")
        }
    }

    /// Following, no arrow; panned with the aircraft off the chart, the arrow, north-east.
    func testTheArrowShowsOnlyOncePanned() throws {
        for chart in Chart.allCases {
            XCTAssertNil(placedFrames(Sample.model(), chart)[.edgeArrow], chart.rawValue)
            let model = Sample.model(panned: true)
            let frame = try XCTUnwrap(placedFrames(model, chart)[.edgeArrow], chart.rawValue)
            let geometry = MapChromeGeometry(size: chart.size, scale: chart.scale)
            XCTAssertTrue(geometry.arrowBounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), chart.rawValue)
            let point = try XCTUnwrap(OwnshipEdgeArrow.project(Sample.aircraftOffChart, region: Sample.region,
                                                               heading: 0, size: chart.size))
            let arrow = try XCTUnwrap(geometry.edgeArrow(toward: point))
            XCTAssertEqual(arrow.degrees, 45, accuracy: 45, "north-east, \(chart.rawValue)")
        }
        XCTAssertEqual(MapChromeEdgeArrow.clock(0), 12)
        XCTAssertEqual(MapChromeEdgeArrow.clock(44), 1)
        XCTAssertEqual(MapChromeEdgeArrow.clock(46), 2)
        XCTAssertEqual(MapChromeEdgeArrow.clock(90), 3)
        XCTAssertEqual(MapChromeEdgeArrow.clock(180), 6)
        XCTAssertEqual(MapChromeEdgeArrow.clock(271), 9)
        XCTAssertEqual(MapChromeEdgeArrow.clock(359), 12)
    }

    // MARK: - Nothing cut

    /// Every state, in English and French, at the in-flight sizes: what its words need, with no line
    /// limit, is within the slot; titles hold on one line; UNDO and ANNULER fit their button. UNDO with
    /// each kind of message at its longest (a 12-letter waypoint, a 12-hour clock, the longest check).
    func testEveryStateFitsItsSlotInEnglishAndFrench() {
        for chart in Chart.allCases {
            let geometry = MapChromeGeometry(size: chart.size, scale: chart.scale)
            let metrics = geometry.metrics
            let slot = geometry.statusSlot
            for language in ["en", "fr"] {
                for state in allStates(language: language) {
                    let context = "\(state.name), \(chart.rawValue), \(language)"
                    if let offer = state.undo {
                        let face = MapUndoFace(message: offer.message, style: offer.style, metrics: metrics,
                                               language: language, unlimitedLines: true) {}
                        XCTAssertLessThanOrEqual(naturalHeight(face, width: slot.width), slot.height + 0.5, context)
                        let message = Text(offer.message).font(.aero(size: metrics.textSize, weight: .semibold))
                        let lines = naturalHeight(message, width: MapUndoFace.messageWidth(slotWidth: slot.width, metrics: metrics))
                            / lineHeight(metrics.textSize)
                        XCTAssertLessThanOrEqual(lines.rounded(), CGFloat(metrics.undoMessageLines), context)
                    } else {
                        let face = MapStatusFace(status: state.status, metrics: metrics, language: language, unlimitedLines: true)
                        XCTAssertLessThanOrEqual(naturalHeight(face, width: slot.width), slot.height + 0.5, context)
                        let title = Text(verbatim: MapStatusText.title(state.status, language: language))
                            .font(.aero(size: metrics.textSize, weight: .bold))
                        XCTAssertLessThanOrEqual(idealWidth(title), MapStatusFace.textWidth(slotWidth: slot.width, metrics: metrics),
                                                 "\(context): the title on one line")
                    }
                }
                let undo = Text(verbatim: L10n.MapChrome.undo(language: language).uppercased())
                    .font(.aero(size: metrics.textSize, weight: .heavy))
                XCTAssertLessThanOrEqual(idealWidth(undo) + 16, metrics.undoButtonWidth, "\(chart.rawValue), \(language)")
            }
        }
    }

    func testTheChromeIsNeverUnderTheInFlightSizes() {
        for scale in [CockpitScale.kneeboard, .phone] {
            let metrics = MapChromeGeometry.Metrics(scale)
            let text = CockpitType.label(for: scale)
            XCTAssertEqual(text, scale == .kneeboard ? 20 : 17)
            XCTAssertGreaterThanOrEqual(metrics.textSize, text)
            XCTAssertGreaterThanOrEqual(metrics.orientationTextSize, text)
            // UNDO: the 15 mm control, as the toast's (`NavUndoToast.buttonHeight` on each device).
            XCTAssertEqual(metrics.slotHeight, scale == .kneeboard ? 78 : 92)
            XCTAssertGreaterThanOrEqual(metrics.undoButtonWidth, metrics.button)
        }
        XCTAssertGreaterThanOrEqual(MapChromeGeometry.Metrics(.kneeboard).button, 78, "the kneeboard's 15 mm control")
        XCTAssertGreaterThanOrEqual(MapChromeGeometry.Metrics(.phone).button, 72, "the act band's narrowest slot on the phone")
        XCTAssertEqual(MapChromeGeometry.Metrics(.current).slotHeight, NavUndoToast.buttonHeight, "as tall as the toast's UNDO")
    }

    // MARK: - The chart left free

    /// How much chart the chrome leaves: the controls always, the slot while a state shows. Today's chart
    /// sizes, once the read band carries NOW | NEXT (`MapChromeSample.Chart`).
    func testTheChromeLeavesTheChartFree() {
        let free = Chart.allCases.map { chart -> (Chart, Double, Double) in
            let geometry = MapChromeGeometry(size: chart.size, scale: chart.scale)
            return (chart, geometry.freeFraction(statusShown: false), geometry.freeFraction(statusShown: true))
        }
        for (chart, dark, withStatus) in free {
            let minimum: (Double, Double) = chart.scale == .kneeboard ? (0.90, 0.78) : (0.84, 0.57)
            XCTAssertGreaterThanOrEqual(dark, minimum.0, "\(chart.rawValue): \(percent(dark)) free")
            XCTAssertGreaterThanOrEqual(withStatus, minimum.1, "\(chart.rawValue), a state showing: \(percent(withStatus)) free")
        }
    }

    // MARK: - What it says

    func testEachStateSaysWhatItIsInEnglishAndFrench() {
        let expected: [(CockpitStatus, String, String?, String, String?)] = [
            (.gps(.degraded), "GPS DEGRADED", nil, "GPS DÉGRADÉ", nil),
            (.gps(.lost), "NO GPS", nil, "PAS DE GPS", nil),
            (.offRoute(crossTrackNM: 1.24), "OFF ROUTE 1.2 NM", nil, "HORS ROUTE 1.2 NM", nil),
            (.chartOffline, "CHART OFFLINE", nil, "CARTE HORS LIGNE", nil),
            (.tellFIS(field: "LSGC"), "TELL FIS", "Diverting to LSGC", "ANNONCER AU FIS", "Déroutement vers LSGC"),
            (.sigmet(summary: "TS · on route"), "SIGMET", "TS · on route", "SIGMET", "TS · on route"),
            (.briefing(.approach), "BRIEFING", nil, "BRIEFING", nil),
        ]
        for (status, en, enDetail, fr, frDetail) in expected {
            XCTAssertEqual(MapStatusText.title(status, language: "en"), en)
            XCTAssertEqual(MapStatusText.detail(status, language: "en"), enDetail)
            XCTAssertEqual(MapStatusText.title(status, language: "fr"), fr)
            XCTAssertEqual(MapStatusText.detail(status, language: "fr"), frDetail)
            XCTAssertFalse(MapStatusText.hint(status, language: "en").isEmpty, "\(status)")
            XCTAssertFalse(MapStatusText.hint(status, language: "fr").isEmpty, "\(status)")
            XCTAssertNotEqual(MapStatusText.hint(status, language: "en"), MapStatusText.hint(status, language: "fr"), "\(status)")
        }
        XCTAssertEqual(MapStatusText.spoken(.tellFIS(field: "LSGC"), language: "en"), "TELL FIS, Diverting to LSGC")
        XCTAssertEqual(MapStatusText.distance(1.04), "1.0")
        XCTAssertEqual(MapStatusText.distance(9.94), "9.9")
        XCTAssertEqual(MapStatusText.distance(9.96), "10")
        XCTAssertEqual(MapStatusText.distance(150.4), "150")
    }

    /// The controls' names for VoiceOver, and the values the UI tests read (plan §6).
    func testTheControlsSayWhatTheyAreAndWhatTheyShow() {
        let northUp = Sample.model()
        let trackUp = Sample.model(panned: true, orientation: .trackUp, stale: true)
        XCTAssertEqual(MapChromeControlButton.label(.orientation, model: northUp, language: "en"), "North up")
        XCTAssertEqual(MapChromeControlButton.label(.orientation, model: trackUp, language: "fr"), "Route en haut")
        XCTAssertEqual(MapChromeControlButton.value(.orientation, model: northUp, language: "en"), "northUp")
        XCTAssertEqual(MapChromeControlButton.value(.orientation, model: trackUp, language: "en"), "trackUp")
        XCTAssertEqual(MapChromeControlButton.value(.centre, model: northUp, language: "en"), "following")
        XCTAssertEqual(MapChromeControlButton.value(.centre, model: trackUp, language: "en"), "panned")
        XCTAssertEqual(MapChromeControlButton.icon(.centre, model: northUp), "location")
        XCTAssertEqual(MapChromeControlButton.icon(.centre, model: trackUp), "location.fill")
        XCTAssertEqual(MapChromeControlButton.value(.layers, model: northUp, language: "en"), "")
        XCTAssertEqual(MapChromeControlButton.value(.layers, model: trackUp, language: "en"), "Airspace data is out of date")
        XCTAssertEqual(MapChromeControlButton.value(.layers, model: trackUp, language: "fr"), "Données d'espace aérien obsolètes")
        XCTAssertEqual(MapChromeControlButton.label(.layers, model: northUp, language: "fr"), "Carte")
        XCTAssertEqual(MapChromeControlButton.label(.centre, model: northUp, language: "fr"), "Centrer")
        XCTAssertEqual(MapChromeControlButton.label(.zoomIn, model: northUp, language: "en"), "Zoom in")
        XCTAssertEqual(MapChromeControlButton.label(.zoomOut, model: northUp, language: "fr"), "Zoom arrière")
        XCTAssertEqual(Control.allCases.map(MapChromeControlButton.identifier),
                       ["map.orientation", "map.layers", "map.centre", "map.zoomIn", "map.zoomOut"])
        XCTAssertEqual(L10n.MapChrome.aircraftOffScreen(clock: 2, language: "en"), "Aircraft off screen, at 2 o’clock")
        XCTAssertEqual(L10n.MapChrome.aircraftOffScreen(clock: 2, language: "fr"), "Avion hors de l’écran, direction 2 h")
    }

    func testTheUndoRunsOutInSixSeconds() {
        XCTAssertEqual(UndoCountdown.window, AppState.memoryConfirmationUndoWindow)
        XCTAssertEqual(UndoCountdown.remaining(elapsed: 0), 1)
        XCTAssertEqual(UndoCountdown.remaining(elapsed: 3), 0.5, accuracy: 1e-9)
        XCTAssertEqual(UndoCountdown.remaining(elapsed: 6), 0)
        XCTAssertEqual(UndoCountdown.remaining(elapsed: 9), 0)
        XCTAssertEqual(UndoCountdown.remaining(elapsed: -1), 1)
        XCTAssertEqual(UndoCountdown.remaining(elapsed: .nan), 0)
    }

    // MARK: - Stack

    /// The chrome with UNDO and the edge arrow, and with a state, on each device: well under half the
    /// device's main-thread stack, as `ViewStackBudgetTests` measures the screens.
    func testTheChromeRendersWithinHalfTheDeviceStack() {
        let used = StackProbe.bytesUsed {
            for chart in Chart.allCases {
                for model in [Sample.model(status: .undo, undo: Sample.undoOffer(.automatic, language: "fr"), panned: true),
                              Sample.model(status: .tellFIS(field: "LSGC"), panned: true, orientation: .trackUp, stale: true)] {
                    let renderer = ImageRenderer(content: chrome(model, chart, scaleShown: true))
                    renderer.proposedSize = ProposedViewSize(chart.size)
                    _ = renderer.uiImage
                }
            }
        }
        XCTAssertLessThan(used, (1 << 20) / 2, "the map's chrome used \(used / 1_024) KB of stack")
    }

    // MARK: - Renders for review

    /// Writes the chrome over a light chart on each device, in English and French: dark, every state,
    /// panned with the edge arrow and TRK, the scale, and one at night; plus the chart left free, as
    /// text. Into the folder named by MAPCHROME_SHOTS (`TEST_RUNNER_MAPCHROME_SHOTS` on xcodebuild's
    /// command line); skipped without it.
    func testRenderEveryStateForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["MAPCHROME_SHOTS"], !folder.isEmpty else {
            throw XCTSkip("set MAPCHROME_SHOTS to a folder to write the renders")
        }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for chart in Chart.allCases {
            for language in ["en", "fr"] {
                let shots: [(String, MapChromeModel, Bool)] =
                    [("dark-following-northup", Sample.model(), false),
                     ("dark-panned-trackup-scale", Sample.model(panned: true, orientation: .trackUp, stale: true), true)]
                    + allStates(language: language).map { state -> (String, MapChromeModel, Bool) in
                        (state.name, Sample.model(status: state.status, undo: state.undo), false)
                    }
                    + [("off-route-panned", Sample.model(status: .offRoute(crossTrackNM: 1.2), panned: true), false)]
                for (name, model, scale) in shots {
                    try writePNG(model, chart, language: language, scaleShown: scale,
                                 to: directory.appendingPathComponent("\(chart.rawValue)-\(name)-\(language).png"))
                }
            }
            try writePNG(Sample.model(status: .gps(.lost), panned: true), chart, language: "en", theme: .night,
                         to: directory.appendingPathComponent("\(chart.rawValue)-night-gps-lost-en.png"))
        }
        var report = "chart (pt)".padding(toLength: 28, withPad: " ", startingAt: 0) + "free, dark   free, a state showing\n"
        for chart in Chart.allCases.map(Optional.some) + [nil] {
            let size = chart?.size ?? CGSize(width: 1180, height: 320)
            let geometry = MapChromeGeometry(size: size, scale: chart?.scale ?? .kneeboard)
            let name = "\(chart?.rawValue ?? "ipad-landscape-320") \(Int(size.width))x\(Int(size.height))"
            report += name.padding(toLength: 28, withPad: " ", startingAt: 0)
                + percent(geometry.freeFraction(statusShown: false)).padding(toLength: 13, withPad: " ", startingAt: 0)
                + percent(geometry.freeFraction(statusShown: true)) + "\n"
        }
        try report.write(to: directory.appendingPathComponent("free-chart.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private struct Variant {
        let name: String
        let model: MapChromeModel
        var scaleShown = false
    }

    /// The chrome in every way it can be: following or panned, N↑ or TRK, the triangle or not, each
    /// state or none, the scale or not.
    private func variants(_ chart: Chart) -> [Variant] {
        var variants: [Variant] = []
        let states: [(String, CockpitStatus?, NavUndoOffer?)] = [("dark", nil, nil)]
            + allStates(language: "en").map { state -> (String, CockpitStatus?, NavUndoOffer?) in
                (state.name, state.status, state.undo)
            }
        for (name, status, undo) in states {
            for panned in [false, true] {
                for orientation in [MapOrientationMode.northUp, .trackUp] {
                    let model = Sample.model(status: status, undo: undo, panned: panned, orientation: orientation,
                                             stale: panned)
                    variants.append(Variant(name: "\(name), panned \(panned), \(orientation)", model: model,
                                            scaleShown: orientation == .trackUp))
                }
            }
        }
        return variants
    }

    /// The samples' states (UNDO after MARK and after a waypoint marked on its own), then the other undo
    /// messages and the longest of each state: OFF ROUTE at 9.9 and 150 NM, a 12-letter field to tell
    /// FIS about, a long SIGMET overhead, the departure briefing.
    private func allStates(language: String) -> [(name: String, status: CockpitStatus, undo: NavUndoOffer?)] {
        let overhead = localizedString(key: "nav.sigmet.overhead", language: language, defaultValue: "overhead")
        return Sample.states(language: language)
            + [Sample.UndoKind.legTimer, .memory, .freda].map { kind -> (name: String, status: CockpitStatus, undo: NavUndoOffer?) in
                (name: "undo-\(kind)", status: .undo, undo: Sample.undoOffer(kind, language: language))
            }
            + [("off-route-9.9", .offRoute(crossTrackNM: 9.94), nil),
               ("off-route-150", .offRoute(crossTrackNM: 150), nil),
               ("tell-fis-long", .tellFIS(field: "SAIGNELÉGIER"), nil),
               ("sigmet-long", .sigmet(summary: "OBSC TSGR · " + overhead), nil),
               ("briefing-departure", .briefing(.departure), nil)]
    }

    private func chrome(_ model: MapChromeModel, _ chart: Chart, language: String = "en", scaleShown: Bool = false,
                        theme: CockpitTheme = .day,
                        onPlace: ((MapChromeElement, CGRect) -> Void)? = nil) -> some View {
        CockpitMapChrome(model: model, actions: MapChromeActions(), scale: chart.scale, language: language,
                         scaleShownOverride: scaleShown, onPlace: onPlace)
            .frame(width: chart.size.width, height: chart.size.height)
            .environment(\.cockpitTheme, theme)
    }

    private final class Placed {
        var frames: [MapChromeElement: CGRect] = [:]
    }

    /// Each piece's frame as the chrome lays it out over `chart`.
    private func placedFrames(_ model: MapChromeModel, _ chart: Chart, language: String = "en",
                              scaleShown: Bool = false) -> [MapChromeElement: CGRect] {
        let placed = Placed()
        let renderer = ImageRenderer(content: chrome(model, chart, language: language, scaleShown: scaleShown) {
            placed.frames[$0] = $1
        })
        renderer.proposedSize = ProposedViewSize(chart.size)
        _ = renderer.cgImage
        return placed.frames
    }

    private func naturalHeight(_ view: some View, width: CGFloat) -> CGFloat {
        UIHostingController(rootView: view.environment(\.cockpitTheme, .day))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private func idealWidth(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.fixedSize())
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width
    }

    /// B612's line at `size`: its ascent, descent and gap, as the text system sets it.
    private func lineHeight(_ size: CGFloat) -> CGFloat {
        UIFont.aero(size: size, weight: .bold).lineHeight
    }

    private func percent(_ fraction: Double) -> String {
        String(format: "%.1f %%", fraction * 100)
    }

    private func assertEqual(_ frame: CGRect?, _ expected: CGRect, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let frame else {
            XCTFail("not placed: \(message)", file: file, line: line)
            return
        }
        let close = abs(frame.minX - expected.minX) <= 0.5 && abs(frame.minY - expected.minY) <= 0.5
            && abs(frame.width - expected.width) <= 0.5 && abs(frame.height - expected.height) <= 0.5
        XCTAssertTrue(close, "\(frame) != \(expected): \(message)", file: file, line: line)
    }

    private func writePNG(_ model: MapChromeModel, _ chart: Chart, language: String, scaleShown: Bool = false,
                          theme: CockpitTheme = .day, to url: URL) throws {
        let content = chrome(model, chart, language: language, scaleShown: scaleShown, theme: theme)
            .background(Sample.Backdrop(model: model))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(chart.size)
        let data = try XCTUnwrap(renderer.uiImage?.pngData(), "rendered \(url.lastPathComponent)")
        try data.write(to: url)
    }
}

private extension Dictionary {
    /// The entries whose key `transform` maps to a new key.
    func compactMapKeys<NewKey: Hashable>(_ transform: (Key) -> NewKey?) -> [NewKey: Value] {
        var result: [NewKey: Value] = [:]
        for (key, value) in self {
            if let newKey = transform(key) { result[newKey] = value }
        }
        return result
    }
}
