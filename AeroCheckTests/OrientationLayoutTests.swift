import SwiftUI
import XCTest
@testable import AeroCheck

/// The layouts a screen picks from the size it is given (the route builder's portrait and two columns,
/// the Logbook's list and detail, the root's rotation prompt, the map's landscape legs panel and its
/// thumb buttons), and the on-screen keyboard, which takes its height off that size. With the keys up,
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
}
