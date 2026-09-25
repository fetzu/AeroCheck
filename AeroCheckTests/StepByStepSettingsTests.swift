import XCTest
@testable import AeroCheck

/// Step-by-step is how every checklist runs since 6.0 (the Cockpit's CHECK), and its switch is gone.
/// An install that had turned it off gets it back once, and an older device can't turn it off again.
/// (v6.0 · P7)
final class StepByStepSettingsTests: XCTestCase {

    /// A settings file as a 6.0 beta before schema 4 saved it, step-by-step switched off.
    private func schema3StepByStepOff() -> AppSettings {
        var settings = AppSettings()
        settings.schemaVersion = 3
        settings.stepByStepHighlighting = false
        return settings
    }

    func testANewInstallRunsStepByStep() {
        XCTAssertTrue(AppSettings().stepByStepHighlighting)
        XCTAssertEqual(AppSettings().schemaVersion, 4)
    }

    func testAFileWithStepByStepOffIsTurnedBackOn() {
        let migrated = schema3StepByStepOff().migratedLocally()
        XCTAssertTrue(migrated.stepByStepHighlighting)
        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)
    }

    func testTheSchema4MigrationLeavesTheMemoryTestChoiceAlone() {
        var settings = schema3StepByStepOff()
        settings.learningMode = false                                 // memory test chosen on 6.0
        XCTAssertFalse(settings.migratedLocally().learningMode, "schema 3 already carried that choice")
    }

    func testAPre6FileGetsBothMigrations() {
        var settings = AppSettings()
        settings.schemaVersion = 2
        settings.learningMode = false
        settings.stepByStepHighlighting = false
        let migrated = settings.migratedLocally()
        XCTAssertTrue(migrated.learningMode)
        XCTAssertTrue(migrated.stepByStepHighlighting)
    }

    func testAnOlderDeviceCannotTurnStepByStepOff() {
        let merged = AppSettings().preservingFieldsUnknownTo(schema3StepByStepOff())
        XCTAssertTrue(merged.stepByStepHighlighting)
    }

    @MainActor
    func testLaunchingOnASchema3FileSavesTheMigration() throws {
        let datastore = makeTestDatastore()
        datastore.saveSettings(schema3StepByStepOff())

        let appState = makeTestAppState(datastore: datastore)

        XCTAssertTrue(appState.settings.stepByStepHighlighting)
        let saved = try XCTUnwrap(datastore.loadSettings())
        XCTAssertEqual(saved.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertTrue(saved.stepByStepHighlighting)
    }
}
