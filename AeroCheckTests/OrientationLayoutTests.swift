import SwiftUI
import XCTest
@testable import AeroCheck

/// The layouts a screen picks from the size it is given (the route builder's portrait and two columns,
/// the Logbook's list and detail, the root's rotation prompt, the map's landscape legs panel, its thumb
/// buttons, and the legs beside or above the frequencies), and the on-screen keyboard, which takes its
/// height off that size. With the keys up,
/// an iPad in portrait is wider than it is tall. (6.1.0)
final class OrientationLayoutTests: XCTestCase {

    // MARK: Route builder

    func testTheBuilderStaysInOneColumnOnAnIPadInPortrait() {
        XCTAssertFalse(RouteBuilderLayout.isTwoColumn(regularWidth: true, size: CGSize(width: 820, height: 1074)))
        // What its reader measured with the keyboard up, before it ignored the keyboard: the reason
        // it must.
        XCTAssertTrue(RouteBuilderLayout.isTwoColumn(regularWidth: true, size: CGSize(width: 820, height: 757)))
    }

    func testTheBuilderUsesTwoColumnsOnAnIPadInLandscapeOnly() {
        XCTAssertTrue(RouteBuilderLayout.isTwoColumn(regularWidth: true, size: CGSize(width: 1180, height: 714)))
        XCTAssertFalse(RouteBuilderLayout.isTwoColumn(regularWidth: false, size: CGSize(width: 874, height: 360)))
    }

    func testPortraitStacksFromToTheMapTheProfileAndTheLegs() {
        let size = CGSize(width: 820, height: 1074)
        let f = RouteBuilderLayout.frames(in: size, twoColumn: false, hasRoute: true,
                                          fromToHeight: 112, profileHeight: 188)
        XCTAssertEqual(f.fromTo, CGRect(x: 0, y: 0, width: 820, height: 112))
        XCTAssertEqual(f.map.minY, 112)
        XCTAssertEqual(f.map.height, 1074 * 0.40, accuracy: 0.001)
        XCTAssertEqual(f.profile.minY, f.map.maxY + 1, "a 1 pt divider")
        XCTAssertEqual(f.profile.height, 188)
        XCTAssertEqual(f.legs.minY, f.profile.maxY + 1)
        XCTAssertEqual(f.legs.maxY, 1074, accuracy: 0.001, "the legs take the rest")
    }

    func testBeforeThereIsARouteTheMapTakesMoreAndThereIsNoProfile() {
        let f = RouteBuilderLayout.frames(in: CGSize(width: 820, height: 1074), twoColumn: false, hasRoute: false,
                                          fromToHeight: 60, profileHeight: 188)
        XCTAssertEqual(f.map.height, 1074 * 0.62, accuracy: 0.001)
        XCTAssertEqual(f.profile, .zero)
        XCTAssertEqual(f.legs.minY, f.map.maxY + 1)
    }

    func testThePortraitMapNeverGoesUnder240Points() {
        let f = RouteBuilderLayout.frames(in: CGSize(width: 375, height: 500), twoColumn: false, hasRoute: true,
                                          fromToHeight: 112, profileHeight: 152)
        XCTAssertEqual(f.map.height, 240)
        XCTAssertEqual(f.legs.height, 0, "squeezed out, never negative")
    }

    func testTwoColumnsPutTheMapLeftAtFullHeightAndTheRestDownTheRight() {
        let f = RouteBuilderLayout.frames(in: CGSize(width: 1180, height: 714), twoColumn: true, hasRoute: true,
                                          fromToHeight: 112, profileHeight: 188)
        XCTAssertEqual(f.map, CGRect(x: 0, y: 0, width: 684, height: 714))   // 58 %, rounded
        XCTAssertEqual(f.fromTo, CGRect(x: 685, y: 0, width: 495, height: 112))
        XCTAssertEqual(f.profile.minY, 113)
        XCTAssertEqual(f.legs.minX, 685)
        XCTAssertEqual(f.legs.maxY, 714)
    }

    // MARK: Screens that keep the keyboard's avoidance (Logbook, root)

    func testAnIPadInPortraitIsNotLandscapeWithTheKeyboardUp() {
        // The root reader, measured on an iPad Air 11" in portrait: keys down, then up.
        XCTAssertFalse(KeyboardProofOrientation.isLandscape(size: CGSize(width: 820, height: 1128), bottomInset: 20))
        XCTAssertFalse(KeyboardProofOrientation.isLandscape(size: CGSize(width: 820, height: 811), bottomInset: 337))
    }

    func testLandscapeStaysLandscapeWithTheKeyboardUp() {
        XCTAssertTrue(KeyboardProofOrientation.isLandscape(size: CGSize(width: 1180, height: 768), bottomInset: 20))
        XCTAssertTrue(KeyboardProofOrientation.isLandscape(size: CGSize(width: 1180, height: 400), bottomInset: 388))
        XCTAssertTrue(KeyboardProofOrientation.isLandscape(size: CGSize(width: 667, height: 375), bottomInset: 0))
    }

    func testASmallPhoneTypingInPortraitIsNotAskedToRotate() {
        // An iPhone SE with the keyboard, its suggestions and a keyboard toolbar: 343 pt left of 647.
        XCTAssertFalse(KeyboardProofOrientation.isLandscape(size: CGSize(width: 375, height: 343), bottomInset: 304))
    }

    // MARK: The map on an iPad on its side (6.1)

    func testTheLandscapeLegsPanelStopsBelowTheAircraft() {
        // The Cockpit's map pane on an iPad Air 11" on its side, under the instrument strip, and Plan ›
        // Map, which has no strip.
        for mapHeight: CGFloat in [478, 640] {
            let panel = NavigationMapView.landscapeLegsMaxHeight(mapHeight: mapHeight)
            let panelTop = mapHeight - panel
            // The map centres the aircraft; its symbol is about 28 pt across.
            XCTAssertGreaterThanOrEqual(panelTop, mapHeight / 2 + 20, "the aircraft stays in view at \(mapHeight) pt")
            XCTAssertGreaterThan(panel, mapHeight / 3, "still a panel at \(mapHeight) pt")
        }
        XCTAssertEqual(NavigationMapView.landscapeLegsMaxHeight(mapHeight: 40), 0, "never negative")
    }

    func testDivertAndMoreShareOneWidthWithoutTakingMARKsRoom() {
        // What the two want on a phone in French: "Déroutement" 121 pt, "Plus" its 64 pt minimum.
        let ideals: [CGFloat] = [121, 64]
        // Side by side (the thumb bar): half of both, so the pair takes what the two want.
        XCTAssertEqual(EqualWidthStack.buttonWidth(ideals: ideals, axis: .horizontal), 92.5)
        // One above the other (beside MARK on its side): the wider one's, the width the stack had.
        XCTAssertEqual(EqualWidthStack.buttonWidth(ideals: ideals, axis: .vertical), 121)
        // Divert gone (the route flown): More alone keeps its own.
        XCTAssertEqual(EqualWidthStack.buttonWidth(ideals: [64], axis: .horizontal), 64)
        XCTAssertEqual(EqualWidthStack.buttonWidth(ideals: [], axis: .vertical), 0)
    }

    @MainActor
    func testTheButtonsAreLaidOutAtTheirOneWidth() {
        // Two buttons that fill what they are offered, one wanting 60 pt and the other 100.
        func pair(_ axis: Axis) -> some View {
            EqualWidthStack(axis: axis, spacing: 8) {
                Color.clear.frame(idealWidth: 60, maxWidth: .infinity, idealHeight: 48)
                Color.clear.frame(idealWidth: 100, maxWidth: .infinity, idealHeight: 48)
            }
        }
        let room = CGSize(width: 1_000, height: 1_000)
        XCTAssertEqual(UIHostingController(rootView: pair(.horizontal)).sizeThatFits(in: room),
                       CGSize(width: 2 * 80 + 8, height: 48), "side by side, 80 pt each")
        XCTAssertEqual(UIHostingController(rootView: pair(.vertical)).sizeThatFits(in: room),
                       CGSize(width: 100, height: 2 * 48 + 8), "one above the other, 100 pt each")
        // Short of room, the pair keeps its width, as the buttons did: MARK beside it gives way.
        let tight = CGSize(width: 120, height: 1_000)
        XCTAssertEqual(UIHostingController(rootView: pair(.horizontal)).sizeThatFits(in: tight).width, 168)
    }

    // MARK: The check slot's row (6.1)

    func testTheCheckSlotIsAsWideAsMARKBesideDivertAndMore() {
        // An iPad in portrait: 788 pt of row, Divert and More 252 pt, 12 pt between buttons.
        XCTAssertEqual(CheckSlotRowLayout.slotWidth(rowWidth: 788, reference: 252, spacing: 12), 256)
        XCTAssertEqual(CheckSlotRowLayout.slotWidth(rowWidth: 200, reference: 252, spacing: 12), 0, "never negative")
    }

    /// The slot keeps one frame whatever follows it: MARK with Divert and More, GO AROUND and
    /// TOUCH-AND-GO from circuit height, or Routes with no route. It moved to the middle every lap.
    @MainActor
    func testTheCheckSlotKeepsItsFrameWhateverFollowsIt() {
        final class Box { var frame: CGRect = .zero }
        func slotFrame(_ rest: some View) -> CGRect {
            let box = Box()
            let row = CheckSlotRowLayout(spacing: 12) {
                GeometryReader { proxy in
                    let _ = { box.frame = proxy.frame(in: .named("row")) }()
                    Color.clear
                }
                .frame(height: 104)
                Color.clear.frame(width: 252, height: 10)   // Divert and More, measured, unseen
                rest
            }
            .frame(width: 788)
            .coordinateSpace(name: "row")
            _ = ImageRenderer(content: row).uiImage
            return box.frame
        }
        let mark = slotFrame(HStack(spacing: 12) {
            Color.blue.frame(maxWidth: .infinity).frame(height: 104)
            Color.green.frame(width: 252, height: 104)
        })
        let flightEvents = slotFrame(HStack(spacing: 12) {
            Color.red.frame(maxWidth: .infinity).frame(height: 104)
            Color.red.frame(maxWidth: .infinity).frame(height: 104)
        })
        let routes = slotFrame(Color.gray.frame(maxWidth: .infinity).frame(height: 104))
        XCTAssertEqual(mark, CGRect(x: 0, y: 0, width: 256, height: 104), "the slot first, MARK's width")
        XCTAssertEqual(flightEvents, mark, "GO AROUND and TOUCH-AND-GO after it")
        XCTAssertEqual(routes, mark, "Routes after it")
    }

    // MARK: The legs and frequencies, open (6.1)

    /// The panel's content width: the screen's, less 16 pt each side. The iPad on its side has the
    /// panel beside its 420 pt column.
    private enum PanelWidth {
        static let iPadAir11Portrait: CGFloat = 820 - 32
        static let iPadMiniPortrait: CGFloat = 744 - 32
        static let iPadAir11OnItsSide: CGFloat = 1180 - 420 - 32
        static let iPhone17Pro: CGFloat = 402 - 32
        static let iPhone17ProMax: CGFloat = 440 - 32
        /// A Pro Max on its side, beside the Cockpit's 402 pt column.
        static let iPhone17ProMaxOnItsSide: CGFloat = 956 - 402 - 32
    }

    func testTheLegsAndFrequenciesSitSideBySideOnEveryIPadInPortrait() {
        XCTAssertTrue(LegsPanelColumns.isSideBySide(width: PanelWidth.iPadAir11Portrait))
        XCTAssertTrue(LegsPanelColumns.isSideBySide(width: PanelWidth.iPadMiniPortrait))
        XCTAssertTrue(LegsPanelColumns.isSideBySide(width: PanelWidth.iPadAir11OnItsSide))
    }

    func testThePhoneKeepsThemOneAboveTheOther() {
        XCTAssertFalse(LegsPanelColumns.isSideBySide(width: PanelWidth.iPhone17Pro))
        XCTAssertFalse(LegsPanelColumns.isSideBySide(width: PanelWidth.iPhone17ProMax))
        XCTAssertFalse(LegsPanelColumns.isSideBySide(width: PanelWidth.iPhone17ProMaxOnItsSide))
    }

    func testBesideTheFrequenciesTheLegsKeepTheirTimesAndAShortName() {
        for width in [PanelWidth.iPadAir11Portrait, PanelWidth.iPadMiniPortrait, PanelWidth.iPadAir11OnItsSide] {
            let legs = LegsPanelColumns.frequencyColumn(width: width, hasLegs: true).minX - LegsPanelColumns.columnSpacing
            XCTAssertGreaterThanOrEqual(legs - LegRowMetrics.fixedWidth, LegRowMetrics.shortNameWidth,
                                        "the times and \"LSZQ\" at \(width) pt")
        }
        // PLAN, ACT and Δ, the index, the icon, the gaps and the row's padding.
        XCTAssertEqual(LegRowMetrics.fixedWidth, 328)
    }

    @MainActor
    func testEveryLegIconFitsItsColumn() {
        let room = CGSize(width: 1_000, height: 1_000)
        for symbol in ["circle.fill", "location.fill", "circle"] {
            let icon = Image(systemName: symbol).font(.aero(size: 14))
            XCTAssertLessThanOrEqual(UIHostingController(rootView: icon).sizeThatFits(in: room).width,
                                     LegRowMetrics.iconWidth, symbol)
        }
    }

    /// Where the legs and the frequencies land, with legs that want more than the room beside the
    /// frequencies: a long name, SAIGNELÉGIER, at full size. They stacked on an iPad in portrait, the
    /// frequencies out of view.
    @MainActor
    private func columnFrames(width: CGFloat) -> (legs: CGRect, frequencies: CGRect, size: CGSize) {
        final class Box { var legs: CGRect = .zero; var frequencies: CGRect = .zero }
        let box = Box()
        let columns = LegsPanelColumns {
            GeometryReader { proxy in
                let _ = { box.legs = proxy.frame(in: .named("panel")) }()
                Color.clear
            }
            .frame(idealWidth: 700, maxWidth: .infinity)
            .frame(height: 200)
            GeometryReader { proxy in
                let _ = { box.frequencies = proxy.frame(in: .named("panel")) }()
                Color.clear
            }
            .frame(height: 120)
        }
        let panel = columns.frame(width: width).coordinateSpace(name: "panel")
        _ = ImageRenderer(content: panel).uiImage
        let size = UIHostingController(rootView: columns).sizeThatFits(in: CGSize(width: width, height: 2_000))
        return (box.legs, box.frequencies, size)
    }

    @MainActor
    func testTheLegsGiveWayBesideTheFrequencies() {
        let iPad = columnFrames(width: PanelWidth.iPadAir11Portrait)
        XCTAssertEqual(iPad.legs, CGRect(x: 0, y: 0, width: 464, height: 200), "the legs take what is left")
        XCTAssertEqual(iPad.frequencies, CGRect(x: 488, y: 0, width: 300, height: 120), "300 pt at the right")
        XCTAssertEqual(iPad.size, CGSize(width: PanelWidth.iPadAir11Portrait, height: 200))

        let phone = columnFrames(width: PanelWidth.iPhone17Pro)
        XCTAssertEqual(phone.legs, CGRect(x: 0, y: 0, width: 370, height: 200))
        XCTAssertEqual(phone.frequencies, CGRect(x: 0, y: 216, width: 370, height: 120), "under the legs")
        XCTAssertEqual(phone.size, CGSize(width: PanelWidth.iPhone17Pro, height: 336))
    }

    @MainActor
    func testThePanelIsNeverWiderThanItIsOffered() {
        let offered = CGSize(width: PanelWidth.iPadAir11Portrait, height: 2_000)
        // What a row too wide for its column would report: the legs and the frequencies both.
        let columns = LegsPanelColumns {
            Color.clear.frame(width: 1_200, height: 50)
            Color.clear.frame(width: 900, height: 50)
        }
        XCTAssertEqual(UIHostingController(rootView: columns).sizeThatFits(in: offered).width, offered.width)
        let foot = LegsPanelColumns(content: .frequencyFoot(hasLegs: true)) {
            Color.clear.frame(width: 900, height: 50)
        }
        XCTAssertEqual(UIHostingController(rootView: foot).sizeThatFits(in: offered).width, offered.width)
    }

    /// The open panel is one scroll; opened, it brings the leg being flown into view, scrolling only as
    /// far as it needs. On a route of eight waypoints, the legs had a scroll of their own inside the
    /// panel's, and a leg far down the route opened out of view. (6.1, device check)
    func testTheOpenPanelShowsTheLegBeingFlown() {
        XCTAssertEqual(LegsPanelReveal.row(currentWaypointIndex: 6, waypointCount: 8), 6)
        XCTAssertEqual(LegsPanelReveal.row(currentWaypointIndex: 1, waypointCount: 8), 1)
        XCTAssertEqual(LegsPanelReveal.row(currentWaypointIndex: 8, waypointCount: 8), 7, "the route flown: its last row")
        XCTAssertEqual(LegsPanelReveal.row(currentWaypointIndex: -1, waypointCount: 8), 0)
        XCTAssertNil(LegsPanelReveal.row(currentWaypointIndex: 0, waypointCount: 0), "no legs")
    }

    @MainActor
    func testEmergencyLinesUpWithTheFrequencyColumn() {
        final class Box { var frame: CGRect = .zero }
        func footFrame(width: CGFloat, hasLegs: Bool) -> CGRect {
            let box = Box()
            let foot = LegsPanelColumns(content: .frequencyFoot(hasLegs: hasLegs)) {
                GeometryReader { proxy in
                    let _ = { box.frame = proxy.frame(in: .named("panel")) }()
                    Color.clear
                }
                .frame(height: 44)
            }
            _ = ImageRenderer(content: foot.frame(width: width).coordinateSpace(name: "panel")).uiImage
            return box.frame
        }
        let column = columnFrames(width: PanelWidth.iPadAir11Portrait).frequencies
        XCTAssertEqual(footFrame(width: PanelWidth.iPadAir11Portrait, hasLegs: true),
                       CGRect(x: column.minX, y: 0, width: column.width, height: 44),
                       "under the frequency column, beside the legs")
        XCTAssertEqual(footFrame(width: PanelWidth.iPadAir11Portrait, hasLegs: false),
                       CGRect(x: 0, y: 0, width: PanelWidth.iPadAir11Portrait, height: 44), "no route: the width")
        XCTAssertEqual(footFrame(width: PanelWidth.iPhone17Pro, hasLegs: true),
                       CGRect(x: 0, y: 0, width: PanelWidth.iPhone17Pro, height: 44), "a phone: the width")
    }
}

