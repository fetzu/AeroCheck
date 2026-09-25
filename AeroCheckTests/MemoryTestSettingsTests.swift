import XCTest
@testable import AeroCheck

/// "Memory test" (learning mode off, memorisable checks hidden) is off by default since 6.0, and an
/// install that inherited the old default gets every check back once. (v6.0 · A7)
final class MemoryTestSettingsTests: XCTestCase {

    /// A settings file as a pre-6.0 build saved it: schema 2, `learningMode` at the old default.
    private func pre6Settings() -> AppSettings {
        var settings = AppSettings()
        settings.schemaVersion = 2
        settings.learningMode = false
        return settings
    }

    func testANewInstallShowsEveryCheck() {
        XCTAssertTrue(AppSettings().learningMode)
        XCTAssertEqual(AppSettings().schemaVersion, 3)
    }

    func testSettingsWithoutTheKeyShowEveryCheck() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.learningMode)
    }

    func testSettingsFromBefore6ShowEveryCheckOnce() {
        let migrated = pre6Settings().migratedLocally()
        XCTAssertTrue(migrated.learningMode)
        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)

        var chosen = migrated
        chosen.learningMode = false                                   // the pilot turns the memory test on
        XCTAssertFalse(chosen.migratedLocally().learningMode, "a choice made on 6.0 sticks")
    }

    func testAnOlderDeviceCannotHideTheChecksAgain() {
        let local = AppSettings()                                     // 6.0, every check shown
        let merged = local.preservingFieldsUnknownTo(pre6Settings())
        XCTAssertTrue(merged.learningMode)
    }

    func testA6PeerIsTakenAtItsWord() {
        var incoming = AppSettings()
        incoming.learningMode = false                                 // memory test chosen on the iPhone
        XCTAssertFalse(AppSettings().preservingFieldsUnknownTo(incoming).learningMode)
    }

    @MainActor
    func testLaunchingOnAPre6FileShowsEveryCheckAndSavesTheChange() throws {
        let datastore = makeTestDatastore()
        datastore.saveSettings(pre6Settings())

        let appState = makeTestAppState(datastore: datastore)

        XCTAssertTrue(appState.settings.learningMode)
        let saved = try XCTUnwrap(datastore.loadSettings())
        XCTAssertEqual(saved.schemaVersion, AppSettings.currentSchemaVersion, "migrated once, not every launch")
        XCTAssertTrue(saved.learningMode)
    }
}
