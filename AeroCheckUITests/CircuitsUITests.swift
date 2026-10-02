import XCTest

/// The 6.1.0 page's circuits (circuits-*), flown as a ground replay: CIRCUITS from Today, four laps at
/// LSZQ (a touch-and-go, two stop-and-goes, a full stop), the Memory test on.
final class CircuitsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testCircuitsWithStopAndGo() {
        let pilot = CockpitPilot(self, scenario: "circuits-stop-and-go")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.departToClimb(circuits: true) else { return XCTFail("could not get to the climb check") }
        var slotWords: [String] = []
        func note() { if let label = pilot.slot?.label { slotWords.append(label) } }

        // circuits-4: no cruise in circuits, so no FREDA anywhere.
        pilot.check("circuits-4", pilot.element("phaseBar.cruise").exists == false, "no cruise segment on the phase bar")

        // Lap 1: the climb check at 500 ft, then circuits-1: the downwind makes the approach check due, base
        // shows the landing check, dashed.
        pilot.slotDue("CLIMB CHECK", by: s.cue("takeoff") ?? 300, notBefore: s.mark("liftoff") + 20)
        let approach = pilot.waitForSlot(timeout: pilot.wallUntil(track: s.mark("base"), margin: 20)) {
            $0.tone == "due" && $0.label.contains("APPROACH CHECK")
        }
        note()
        pilot.shot("circuits-1", "downwind-approach-due")
        pilot.check("circuits-1", approach.ok, "on the downwind (track \(Int(pilot.trackNow)) s, downwind from \(Int(s.mark("downwind"))) s): \(approach.slot?.description ?? "none")")
        pilot.tapSlot()
        let landing = pilot.waitForSlot(timeout: pilot.wallUntil(track: s.mark("final"), margin: 20)) {
            $0.tone == "quiet" && $0.label.contains("LANDING CHECK")
        }
        note()
        pilot.shot("circuits-1", "base-landing-dashed")
        pilot.check("circuits-1", landing.ok && landing.slot?.action == "goToLanding",
                    "on base (track \(Int(pilot.trackNow)) s, base from \(Int(s.mark("base"))) s): \(landing.slot?.description ?? "none")")
        pilot.observed("circuits-1", "nothing to press: dashed on the screenshot")
        pilot.tapSlot()

        // The touch-and-go's card, confirmed: back to the climb check.
        if pilot.waitFor("eventCard.confirm", timeout: pilot.wallUntil(track: s.mark("liftoff2") + 40, margin: 15)) != nil {
            pilot.shot("circuits-2", "touch-and-go-card")
            pilot.tap("eventCard.confirm")
        }
        _ = pilot.waitUntil(timeout: 4) { pilot.currentPhase == "climb" }

        // Lap 2, ending in the first stop-and-go: circuits-2, its full-stop card CONFIRMed: TAXI.
        flyLap(pilot, by: s.mark("touchdown2"), note: note)
        guard pilot.waitFor("eventCard.fullStop", timeout: pilot.wallUntil(track: s.mark("stopped") + 20, margin: 20)) != nil else {
            return pilot.check("circuits-2", false, "no full-stop card at the stop-and-go (track \(Int(pilot.trackNow)) s)")
        }
        pilot.check("circuits-2", pilot.landedCardTitle == nil, "the circuits' own full-stop card, not the landed card")
        pilot.shot("circuits-2", "full-stop-card")
        pilot.tap("eventCard.confirm")
        pilot.check("circuits-2", pilot.waitUntil(timeout: 4) { pilot.currentPhase == "taxi" }, "CONFIRM: \(pilot.currentPhase ?? "?")")
        pilot.shot("circuits-2", "taxi")
        // And the next circuit: the checks to the climb again.
        pilot.workChecks(until: "lineUp")
        if pilot.memoryDone.waitForExistence(timeout: 3) { pilot.tapNow(pilot.memoryDone) }
        pilot.check("circuits-2", pilot.waitUntil(timeout: 5) { pilot.currentPhase == "climb" }, "the next circuit: \(pilot.currentPhase ?? "?")")

        // Lap 3, ending in the second stop-and-go: circuits-3, the card left alone goes on the take-off roll.
        flyLap(pilot, by: s.mark("touchdown3"), note: note)
        guard pilot.waitFor("eventCard.fullStop", timeout: pilot.wallUntil(track: s.mark("stopped2") + 20, margin: 20)) != nil else {
            return pilot.check("circuits-3", false, "no full-stop card at the second stop-and-go")
        }
        pilot.shot("circuits-3", "card-up")
        var goneAt: Double?
        _ = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("liftoff4") + 40, margin: 10)) {
            if !pilot.element("eventCard.fullStop").exists { goneAt = pilot.trackNow; return true }
            return false
        }
        pilot.shot("circuits-3", "card-gone")
        pilot.check("circuits-3", goneAt.map { $0 >= s.mark("takeoffRoll3") - 5 && $0 <= s.mark("liftoff4") + 30 } ?? false,
                    "gone at track \(goneAt.map { String(Int($0)) } ?? "never") s (roll \(Int(s.mark("takeoffRoll3"))) s, lift-off \(Int(s.mark("liftoff4"))) s)")

        // circuits-4: no FREDA in all that.
        let freda = pilot.app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'cockpit.freda'"))
        pilot.check("circuits-4", freda.count == 0 && !slotWords.contains { $0.contains("FREDA") },
                    "no FREDA: \(freda.count) FREDA buttons, slot words \(Set(slotWords).sorted())")
        pilot.shot("circuits-4", "no-freda")
        pilot.endFlight()
    }

    /// A lap from wherever the Cockpit is: the climb check when due, the approach check on the downwind,
    /// then on to the landing check from base. `note` keeps what the slot said.
    private func flyLap(_ pilot: CockpitPilot, by touchdown: Double, note: () -> Void) {
        _ = pilot.waitUntil(timeout: pilot.wallUntil(track: touchdown, margin: 15)) {
            guard let slot = pilot.slot else { return false }
            note()
            if slot.tone == "due" || slot.tone == "owed" { pilot.tapSlot() }
            if slot.action == "goToLanding" { pilot.tapSlot(); return true }
            return pilot.currentPhase == "landing"
        }
    }
}
