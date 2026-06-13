import XCTest
@testable import AeroCheck

/// Tests the owned `ActiveChecklist` value that replaced the global `ChecklistData` statics.
/// The core guarantee (ARCH-01): a premium checklist never falls back to the bundled WT9's
/// items or speeds, and an unresolved premium selection exposes nothing at all.
@MainActor
final class ActiveChecklistTests: XCTestCase {

    /// A minimal premium (PA-28) checklist whose content is deliberately distinct from the WT9:
    /// it only populates the `preflight` phase and uses a different stall speed and speed set.
    private func makePA28Checklist() -> RemoteAircraftChecklist {
        RemoteAircraftChecklist(
            id: "pa28-181",
            aircraftType: "PA28",
            registration: "HB-PFA",
            modelName: "Piper Archer II",
            shortModelName: "PA-28-181",
            aeroclub: nil,
            version: "1.0",
            lastUpdated: "2026-01-01",
            isFree: false,
            stallSpeed: 50, // WT9 is 42 — must never be confused
            pageCount: 4,
            hasParachute: false,
            language: nil,
            requestedLanguage: nil,
            languageFallback: nil,
            crosswindLimits: RemoteCrosswindLimits(takeoff: "17 kt", landing: "17 kt"),
            speeds: [RemoteSpeedReference(name: "Vr-PA28", description: "Rotation", value: "55")],
            targetSpeeds: ["climb": 79],
            learningModeVisibleCount: [:],
            phases: [
                "preflight": RemoteChecklistPhase(
                    title: "Preflight",
                    pageNumber: 1,
                    items: [RemoteChecklistItem(number: 1, challenge: "PA28 PREFLIGHT ITEM", response: "CHECK", isHeader: false)]
                )
            ]
        )
    }

    func testPremiumChecklistNeverExposesWT9Items() {
        let active = ActiveChecklist(source: .remote(makePA28Checklist()))

        // The populated phase shows the PA-28 item, never a WT9 one.
        let preflight = active.items(for: .preflight)
        XCTAssertEqual(preflight.map(\.challenge), ["PA28 PREFLIGHT ITEM"])

        // A phase the WT9 *does* have items for, but the PA-28 doesn't, must be empty —
        // never a fallback to the bundled aircraft's content.
        XCTAssertFalse(AircraftType.wt9Dynamic.items(for: .engineStart).isEmpty,
                       "Precondition: the WT9 has engine-start items")
        XCTAssertTrue(active.items(for: .engineStart).isEmpty,
                      "A premium checklist must not borrow WT9 items for an unpopulated phase")
    }

    func testPremiumChecklistNeverExposesWT9Speeds() {
        let active = ActiveChecklist(source: .remote(makePA28Checklist()))

        XCTAssertEqual(active.stallSpeed, 50)
        XCTAssertNotEqual(active.stallSpeed, AircraftType.wt9Dynamic.stallSpeed,
                          "Premium stall speed must not be the WT9's")
        XCTAssertEqual(active.speeds.map(\.name), ["Vr-PA28"])
        XCTAssertEqual(active.registration, "HB-PFA")
        XCTAssertEqual(active.targetSpeed(for: .climb), 79)
    }

    func testUnresolvedChecklistExposesNothing() {
        let active = ActiveChecklist(source: .unresolved)

        XCTAssertFalse(active.isResolved)
        XCTAssertTrue(active.items(for: .preflight).isEmpty)
        XCTAssertTrue(active.speeds.isEmpty)
        XCTAssertEqual(active.stallSpeed, 0)
        XCTAssertNil(active.targetSpeed(for: .climb))
        XCTAssertEqual(active.visibleItemCount(for: .preflight, learningMode: true), 0)
    }

    func testBundledChecklistExposesWT9Content() {
        let active = ActiveChecklist.bundledDefault

        XCTAssertTrue(active.isResolved)
        XCTAssertEqual(active.stallSpeed, AircraftType.wt9Dynamic.stallSpeed)
        XCTAssertEqual(active.registration, "F-HVXA")
        XCTAssertFalse(active.items(for: .preflight).isEmpty)
    }

    // MARK: - ChecklistHighlighting (extracted from AppState, Phase 4)

    func testAdvanceMovesToNextItemButClampsAtTheLast() {
        XCTAssertEqual(ChecklistHighlighting.advanced(current: 0, visibleCount: 3), 1)
        XCTAssertEqual(ChecklistHighlighting.advanced(current: 1, visibleCount: 3), 2)
        // At the last visible item it must NOT advance — the pilot presses NEXT to leave the phase.
        XCTAssertEqual(ChecklistHighlighting.advanced(current: 2, visibleCount: 3), 2)
    }

    func testLastItemCompleteIsOnePastTheLastVisibleItem() {
        XCTAssertEqual(ChecklistHighlighting.lastItemComplete(visibleCount: 3), 3)
        XCTAssertTrue(ChecklistHighlighting.allItemsCompleted(current: 3, visibleCount: 3))
    }

    func testAllItemsCompletedOnlyWhenIndexReachesTheCount() {
        XCTAssertFalse(ChecklistHighlighting.allItemsCompleted(current: 2, visibleCount: 3))
        XCTAssertTrue(ChecklistHighlighting.allItemsCompleted(current: 3, visibleCount: 3))
        XCTAssertTrue(ChecklistHighlighting.allItemsCompleted(current: 4, visibleCount: 3))
    }

    // MARK: - Circuit-mode phase navigation (extracted from AppState, Phase 4)

    func testCruiseAndDescentAreSkippedOnlyInCircuitMode() {
        XCTAssertTrue(ChecklistPhase.cruise.isSkippedInCircuitMode(true))
        XCTAssertTrue(ChecklistPhase.descent.isSkippedInCircuitMode(true))
        XCTAssertFalse(ChecklistPhase.cruise.isSkippedInCircuitMode(false))
        XCTAssertFalse(ChecklistPhase.climb.isSkippedInCircuitMode(true), "Other phases are never skipped")
        XCTAssertFalse(ChecklistPhase.approach.isSkippedInCircuitMode(true))
    }

    func testNextNavigableSkipsCruiseAndDescentInCircuitMode() {
        XCTAssertEqual(ChecklistPhase.climb.nextNavigable(circuitMode: true), .approach)
        XCTAssertEqual(ChecklistPhase.climb.nextNavigable(circuitMode: false), .cruise)
        XCTAssertNil(ChecklistPhase.hangar.nextNavigable(circuitMode: false), "No phase after the last")
    }

    func testPreviousNavigableSkipsCruiseAndDescentInCircuitMode() {
        XCTAssertEqual(ChecklistPhase.approach.previousNavigable(circuitMode: true), .climb)
        XCTAssertEqual(ChecklistPhase.approach.previousNavigable(circuitMode: false), .descent)
        XCTAssertNil(ChecklistPhase.preflight.previousNavigable(circuitMode: false), "No phase before the first")
    }

    func testMissingRequiredActionOnlyForUnpressedButtonPhases() {
        // engineStart requires the engine-start button.
        XCTAssertTrue(ChecklistPhase.engineStart.hasMissingRequiredAction(engineStarted: false, linedUp: true, engineShutDown: true))
        XCTAssertFalse(ChecklistPhase.engineStart.hasMissingRequiredAction(engineStarted: true, linedUp: true, engineShutDown: true))
        // beforeDeparture requires the line-up button; shutdown requires the shutdown button.
        XCTAssertTrue(ChecklistPhase.beforeDeparture.hasMissingRequiredAction(engineStarted: true, linedUp: false, engineShutDown: true))
        XCTAssertTrue(ChecklistPhase.shutdown.hasMissingRequiredAction(engineStarted: true, linedUp: true, engineShutDown: false))
        // A phase with no required button is never .missingAction, whatever the action flags.
        XCTAssertFalse(ChecklistPhase.preflight.hasMissingRequiredAction(engineStarted: false, linedUp: false, engineShutDown: false))
        XCTAssertFalse(ChecklistPhase.climb.hasMissingRequiredAction(engineStarted: false, linedUp: false, engineShutDown: false))
    }
}

/// PR-20 / Task 2.E5: the bundled WT9 EN and FR checklists must carry byte-identical technical /
/// numeric data — aviation data is language-independent (ICAO). Guards the recurring EN/FR
/// `targetSpeeds` divergence on the free default aircraft.
final class BundledChecklistParityTests: XCTestCase {

    func testBundledWT9NumericFieldsAreLanguageIdentical() {
        guard let en = BundledChecklistService.loadBundledChecklist(for: "wt9-dynamic", language: "en"),
              let fr = BundledChecklistService.loadBundledChecklist(for: "wt9-dynamic", language: "fr") else {
            return XCTFail("Both bundled WT9 checklists (en, fr) must load")
        }

        // Parity is only meaningful within the same revision. The version carries a trailing
        // language letter by GVMP convention (2.1e = english, 2.1f = français), so compare the
        // numeric revision only.
        XCTAssertEqual(en.version.trimmingCharacters(in: .letters),
                       fr.version.trimmingCharacters(in: .letters),
                       "EN/FR bundled WT9 must be the same numeric revision (the e/f suffix is the language)")

        // Numeric / technical fields — identical across languages.
        XCTAssertEqual(en.stallSpeed, fr.stallSpeed, "stallSpeed must match")
        XCTAssertEqual(en.pageCount, fr.pageCount, "pageCount must match")
        XCTAssertEqual(en.hasParachute, fr.hasParachute, "hasParachute must match")
        XCTAssertEqual(en.targetSpeeds, fr.targetSpeeds, "targetSpeeds must not diverge between EN and FR")
        XCTAssertEqual(en.learningModeVisibleCount, fr.learningModeVisibleCount, "learningModeVisibleCount must match")
        XCTAssertEqual(en.crosswindLimitsTuple.takeoff, fr.crosswindLimitsTuple.takeoff, "crosswind takeoff limit must match")
        XCTAssertEqual(en.crosswindLimitsTuple.landing, fr.crosswindLimitsTuple.landing, "crosswind landing limit must match")

        // Speed references: same name→value pairs (only the descriptions are localized).
        let enPairs = en.speeds.map { [$0.name, $0.value] }.sorted { $0[0] < $1[0] }
        let frPairs = fr.speeds.map { [$0.name, $0.value] }.sorted { $0[0] < $1[0] }
        XCTAssertEqual(enPairs, frPairs, "Speed reference values must be identical across languages")
    }
}
