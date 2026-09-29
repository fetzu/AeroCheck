import XCTest
@testable import AeroCheck

/// The layouts a screen picks from the size it is given (the route builder's portrait and two columns,
/// the Logbook's list and detail, the root's rotation prompt), and the on-screen keyboard, which takes
/// its height off that size. With the keys up, an iPad in portrait is wider than it is tall. (6.1.0)
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
}
