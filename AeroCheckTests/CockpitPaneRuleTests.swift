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

    func testOnTheGroundAndAroundTakeOffAndLandingTheChecklist() {
        let enRoute: Set<ChecklistPhase> = [.climb, .cruise, .descent]
        for phase in ChecklistPhase.allCases where !enRoute.contains(phase) {
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: true), .checklist, "\(phase)")
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: false), .checklist, "\(phase)")
        }
    }
}
