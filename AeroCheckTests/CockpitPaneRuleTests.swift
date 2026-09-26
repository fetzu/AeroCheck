import XCTest
@testable import AeroCheck

/// Which pane the Cockpit shows by itself (v6.0 · P2): the map en route once the phase's checklist is
/// done, the checklist everywhere else and whenever one is open.
final class CockpitPaneRuleTests: XCTestCase {

    func testEnRouteTheMapOnceTheChecklistIsDone() {
        for phase in [ChecklistPhase.climb, .cruise, .descent] {
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: true), .map, "\(phase)")
        }
    }

    func testEnRouteTheChecklistWhileItIsOpen() {
        // Entering climb shows the climb checklist; a cruise check come due brings the list back.
        for phase in [ChecklistPhase.climb, .cruise, .descent] {
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: false), .checklist, "\(phase)")
        }
    }

    func testTheStripShowsWhileTheAircraftMoves() {
        let moving: [ChecklistPhase] = [.taxi, .runup, .beforeDeparture, .lineUp, .climb, .cruise, .descent,
                                        .approach, .landing, .afterLanding]
        for phase in ChecklistPhase.allCases {
            XCTAssertEqual(CockpitStripRule.showsStrip(in: phase), moving.contains(phase), "\(phase)")
        }
    }

    func testOnTheGroundAndAroundTakeOffAndLandingTheChecklist() {
        let enRoute: Set<ChecklistPhase> = [.climb, .cruise, .descent]
        for phase in ChecklistPhase.allCases where !enRoute.contains(phase) {
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: true), .checklist, "\(phase)")
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: false), .checklist, "\(phase)")
        }
    }

    // MARK: Layout (iPhone pass, I1 and I7)

    func testTheIPadStacksTheZonesInBothOrientations() {
        XCTAssertEqual(CockpitLayout.make(width: 820, height: 1110), .wide)   // iPad Air 11", portrait
        XCTAssertEqual(CockpitLayout.make(width: 1180, height: 750), .wide)   // and landscape
    }

    func testAPhoneInPortraitStacksThemNarrow() {
        XCTAssertEqual(CockpitLayout.make(width: 402, height: 790), .narrow)  // iPhone 17
        XCTAssertEqual(CockpitLayout.make(width: 375, height: 700), .narrow)  // a small phone
        XCTAssertEqual(CockpitLayout.make(width: 320, height: 1110), .narrow) // an iPad in Slide Over
    }

    func testAPhoneOnItsSideFoldsThemIntoColumns() {
        XCTAssertEqual(CockpitLayout.make(width: 750, height: 381), .columns) // iPhone 17, inside its insets
        XCTAssertEqual(CockpitLayout.make(width: 932, height: 430), .columns) // a Pro Max
    }

    func testTheDrawersLeaveThePhoneItsStripButGrowInColumns() {
        XCTAssertEqual(CockpitLayout.wide.drawerHeightFraction, 0.6)
        XCTAssertEqual(CockpitLayout.narrow.drawerHeightFraction, 0.66)
        XCTAssertGreaterThan(CockpitLayout.columns.drawerHeightFraction, CockpitLayout.narrow.drawerHeightFraction)
    }

    // MARK: Scale (iPhone pass, I6)

    func testThePhoneScaleIsPickedByDevice() {
        XCTAssertEqual(CockpitType.size(kneeboard: 24, phone: 20, scale: .kneeboard), 24)
        XCTAssertEqual(CockpitType.size(kneeboard: 24, phone: 20, scale: .phone), 20)
    }

    func testTheTestHostIsAnIPadSoItsSizesAreTheKneeboardOnes() {
        // The suite runs on an iPad simulator: the Cockpit's approved kneeboard sizes, unchanged.
        guard CockpitScale.current == .kneeboard else { return }
        XCTAssertEqual(CockpitType.row, 24)
        XCTAssertEqual(CockpitType.item, 42)
        XCTAssertEqual(CockpitType.value, 48)
        XCTAssertEqual(CockpitTarget.thumb, 104)
    }
}
