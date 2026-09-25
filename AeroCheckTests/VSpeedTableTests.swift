import XCTest
@testable import AeroCheck

/// The Cockpit's V-SPEEDS table (`VSpeedTable`): one layout for every phase, the phase's speeds
/// highlighted where they stand, every speed exactly once. (V-SPEEDS proposal, D1–D8)
final class VSpeedTableTests: XCTestCase {

    private func speed(_ name: String, _ value: String, _ description: String = "") -> SpeedReference {
        SpeedReference(name: name, description: description, value: value)
    }

    /// The WT9, as bundled.
    private var wt9: [SpeedReference] { WT9ChecklistData.speeds }

    /// Every name the 16 checklists use, with their repeats and range formats, plus one no rule knows.
    private var everyName: [SpeedReference] {
        [
            speed("Vso", "50", "stall full flaps"), speed("Vs", "57", "stall clean"),
            speed("Vr", "84-88", "lift off (flaps 0°)"), speed("Vr", "69 - 72", "lift off (flaps 25°)"),
            speed("Vinitial", "57-60", "initial climb"), speed("Vx", "63", "best angle (clean)"),
            speed("Vx", "57", "flaps 2nd notch"), speed("Vy", "75", "best rate"), speed("Vcc", "87", "en route climb"),
            speed("VA", "113", "2550 lbs"), speed("VA", "89", "1634 lbs"), speed("Vbg", "70", "best glide"),
            speed("Vapp", "90", "initial"), speed("Vapp", "80", "intermediate"), speed("Vfinal", "65 – 55", "gate (F40°)"),
            speed("Vref", "62", "reference landing speed"), speed("Vgo", "59", "go around max"),
            speed("Vfe", "81", "max flaps 1"), speed("Vfe", "65", "max flaps 2"), speed("Vfo", "102", "flaps operating"),
            speed("VNO", "98", "max structural cruise"), speed("VNE", "108", "never exceed"),
            speed("Vmystery", "42", "a name no rule knows"),
        ]
    }

    /// No Vr and no Vx, as on the Velis.
    private var noVrNoVx: [SpeedReference] {
        [speed("Vso", "50"), speed("Vs", "57"), speed("Vinitial", "57-60", "initial climb"), speed("Vy", "75"), speed("Vbg", "70")]
    }

    private func layout(_ speeds: [SpeedReference], _ phase: ChecklistPhase, agl: Double?) -> [[Int]] {
        VSpeedTable.rows(speeds: speeds, phase: phase, aglFeet: agl).map { $0.cells.map(\.id) }
    }

    private func highlighted(_ speeds: [SpeedReference], _ phase: ChecklistPhase, agl: Double? = nil) -> [String] {
        VSpeedTable.rows(speeds: speeds, phase: phase, aglFeet: agl)
            .flatMap(\.cells).filter(\.highlighted).map { "\($0.name) \($0.value)" }
    }

    // MARK: - Layout

    func testEverySpeedAppearsExactlyOnce() {
        for speeds in [wt9, everyName, noVrNoVx] {
            let ids = VSpeedTable.rows(speeds: speeds, phase: .cruise, aglFeet: nil).flatMap { $0.cells.map(\.id) }
            XCTAssertEqual(ids.sorted(), Array(speeds.indices))
        }
    }

    /// The point of the design (D6, D8): the same rows and cells, in the same order, in every phase and
    /// at every height. Only the highlight may differ.
    func testTheLayoutIsTheSameInEveryPhase() {
        for speeds in [wt9, everyName, noVrNoVx] {
            let reference = layout(speeds, .preflight, agl: nil)
            for phase in ChecklistPhase.allCases {
                for agl in [nil, 120, 2000] as [Double?] {
                    XCTAssertEqual(layout(speeds, phase, agl: agl), reference, "\(phase) at \(String(describing: agl)) ft")
                }
            }
        }
    }

    func testRowsKeepTheirOrderAndEmptyOnesAreLeftOut() {
        XCTAssertEqual(VSpeedTable.rows(speeds: everyName, phase: .taxi, aglFeet: nil).map(\.group),
                       [.stallGlide, .takeoffClimb, .approachLanding, .limits, .other])
        XCTAssertEqual(VSpeedTable.rows(speeds: wt9, phase: .taxi, aglFeet: nil).map(\.group),
                       [.stallGlide, .takeoffClimb, .approachLanding, .limits])
    }

    func testStallAndGlideFirstTheClimbAsFlownTheApproachAsListed() {
        let rows = VSpeedTable.rows(speeds: everyName, phase: .taxi, aglFeet: nil)
        XCTAssertEqual(rows[0].cells.map(\.name), ["Vso", "Vs", "Vbg", "VNE"])
        XCTAssertEqual(rows[0].cells.map(\.tone), [.stall, .stall, .plain, .neverExceed])
        XCTAssertEqual(rows[1].cells.map(\.name), ["Vr", "Vr", "Vinitial", "Vx", "Vx", "Vy", "Vcc"])
        XCTAssertEqual(rows[2].cells.map(\.name), ["Vapp", "Vapp", "Vfinal", "Vref", "Vgo"])
        XCTAssertTrue(rows[2].isSequence)
        XCTAssertFalse(rows[1].isSequence)
        XCTAssertEqual(rows.last?.cells.map(\.name), ["Vmystery"])   // unknown names are kept, last
    }

    func testQualifiersWhereTheyMatter() {
        let rows = VSpeedTable.rows(speeds: everyName, phase: .taxi, aglFeet: nil)
        let climb = rows[1].cells
        XCTAssertNil(climb.first { $0.name == "Vy" }?.qualifier)   // a standard name, listed once
        XCTAssertEqual(climb.filter { $0.name == "Vx" }.map(\.qualifier), ["best angle (clean)", "flaps 2nd notch"])
        XCTAssertTrue(rows[2].cells.allSatisfy { $0.qualifier != nil })   // approach steps
        XCTAssertTrue(rows[3].cells.allSatisfy { $0.qualifier != nil })   // limits: by weight, by flaps
        XCTAssertTrue(rows[0].cells.allSatisfy { $0.qualifier == nil })   // stall & glide
    }

    func testRangesReadAsOneValue() {
        XCTAssertEqual(VSpeedTable.compactRange("97 – 75"), "97–75")
        XCTAssertEqual(VSpeedTable.compactRange("65-55"), "65–55")
        XCTAssertEqual(VSpeedTable.compactRange("60 - 55"), "60–55")
        XCTAssertEqual(VSpeedTable.compactRange("70"), "70")
    }

    // MARK: - Highlight

    func testTheWT9PhaseByPhase() {
        XCTAssertEqual(highlighted(wt9, .preflight), [])
        XCTAssertEqual(highlighted(wt9, .taxi), [])
        XCTAssertEqual(highlighted(wt9, .beforeDeparture), ["Vr 40"])
        XCTAssertEqual(highlighted(wt9, .lineUp), ["Vr 40"])
        XCTAssertEqual(highlighted(wt9, .climb, agl: 120), ["Vx 55"])     // below 300 ft AGL
        XCTAssertEqual(highlighted(wt9, .climb, agl: 800), ["Vy 70"])
        XCTAssertEqual(highlighted(wt9, .climb), ["Vy 70"])                // height unknown: Vy
        XCTAssertEqual(highlighted(wt9, .cruise), ["VA 97", "VA 75"])      // no Vno on the WT9
        XCTAssertEqual(highlighted(wt9, .descent), ["Vbg 70", "VA 97", "VA 75"])
        XCTAssertEqual(highlighted(wt9, .approach), ["Vapp 70", "Vapp 65", "Vapp 65", "Vfinal 60–55"])
        XCTAssertEqual(highlighted(wt9, .landing), ["Vso 33", "Vfinal 60–55"])
        XCTAssertEqual(highlighted(wt9, .afterLanding), [])
    }

    func testRepeatsVnoAndVgo() {
        XCTAssertEqual(highlighted(everyName, .lineUp), ["Vr 84–88", "Vr 69–72"])           // both Vr
        XCTAssertEqual(highlighted(everyName, .climb, agl: 120), ["Vx 63", "Vx 57"])
        XCTAssertEqual(highlighted(everyName, .cruise), ["VA 113", "VA 89", "VNO 98"])
        XCTAssertFalse(highlighted(everyName, .approach).contains("Vgo 59"))                 // the go-around isn't the approach
        XCTAssertEqual(highlighted(everyName, .landing), ["Vso 50", "Vfinal 65–55"])         // Vfinal before Vref
    }

    func testVinitialStandsInForVrAndVx() {
        XCTAssertEqual(highlighted(noVrNoVx, .lineUp), ["Vinitial 57–60"])
        XCTAssertEqual(highlighted(noVrNoVx, .climb, agl: 120), ["Vinitial 57–60"])
        XCTAssertEqual(highlighted(noVrNoVx, .climb, agl: 800), ["Vy 75"])
    }

    func testTheCrosswindLimitThatApplies() {
        XCTAssertEqual(VSpeedTable.highlightedCrosswind(phase: .beforeDeparture), .takeoff)
        XCTAssertEqual(VSpeedTable.highlightedCrosswind(phase: .lineUp), .takeoff)
        XCTAssertEqual(VSpeedTable.highlightedCrosswind(phase: .landing), .landing)
        XCTAssertNil(VSpeedTable.highlightedCrosswind(phase: .cruise))
        XCTAssertNil(VSpeedTable.highlightedCrosswind(phase: .approach))
    }

    func testARowKnowsItHoldsTheHighlight() {
        let rows = VSpeedTable.rows(speeds: wt9, phase: .climb, aglFeet: 800)
        XCTAssertEqual(rows.filter(\.isHighlighted).map(\.group), [.takeoffClimb])
    }
}
