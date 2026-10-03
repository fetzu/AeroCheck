import XCTest
@testable import AeroCheck

/// Settings sync between builds of different generations (6.1).
///
/// Settings sync as one last-writer-wins record. Review F8 stamped each record with its writer's
/// schema so a newer device keeps what an older one can't express. But an older build keeps the stamp
/// it read: a 6.0 device that received a schema-6 record sent "6" back, without the home aerodrome, and
/// a 6.1 device took that record whole. A record now counts as expressing a protected field only if it
/// carries the field's key, the merged record goes back to CloudKit, and a device stamps what it writes
/// with its own schema.
@MainActor
final class SettingsSyncTests: XCTestCase {

    // MARK: - Fixtures

    /// This device: every protected field away from its default.
    private func local() -> AppSettings {
        var settings = AppSettings()
        settings.pilotName = "J. Bono"
        settings.isStudentPilot = true
        settings.instructorName = "M. Durand"
        settings.sunlightBoost = true
        settings.aircraftRates = ["HB-PFA": AircraftRateProfile(hourlyRate: 280)]
        settings.weightBalanceProfiles = ["HB-PFA": WeightBalanceProfile(emptyWeightKg: 620, maxTakeoffWeightKg: 1000)]
        settings.enableCostTracking = false
        settings.learningMode = false
        settings.stepByStepHighlighting = false
        settings.fullTanksLitres = ["F-HVXA": 100]
        settings.homeAerodromeIdent = "LSZQ"
        settings.cruiseSpeedKIAS = ["F-HVXA": 97]
        settings.showVFRCircuitsOnMap = true
        settings.showVFRRoutesOnMap = true
        settings.showNonPoweredCircuitsOnMap = true
        return settings
    }

    /// `settings` as a device that doesn't know `dropping` writes it back: the same record without
    /// those keys, and the stamp it read (`stamp`), then decoded as sync decodes it.
    private func record(_ settings: AppSettings, dropping: [String] = [], stamp: Int? = nil,
                        extra: [String: Any] = [:]) throws -> AppSettings {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        dropping.forEach { object.removeValue(forKey: $0) }
        if let stamp { object["schemaVersion"] = stamp }
        extra.forEach { object[$0.key] = $0.value }
        return try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
            .clampedForIngest()
    }

    // MARK: - An older record

    /// The case that erased the home aerodrome: a 6.0 device relays a schema-6 record with the "6" it
    /// read, but without the key it doesn't know. What it does know still wins.
    func testAnOlderBuildRelayingANewerRecordKeepsTheNewerFields() throws {
        var remote = local()
        remote.alwaysUseUTC = true
        let relayed = try record(remote, dropping: ["homeAerodromeIdent"], stamp: 6)

        let merged = local().preservingFieldsUnknownTo(relayed)

        XCTAssertEqual(merged.homeAerodromeIdent, "LSZQ", "kept: the record couldn't carry it")
        XCTAssertTrue(merged.alwaysUseUTC, "what the older build knows still wins")
        XCTAssertEqual(merged.schemaVersion, AppSettings.currentSchemaVersion)
    }

    /// Generic: whichever protected field a record lacks, this device's value stays, whatever stamp
    /// the record claims. Each field starts away from its default, so the test sees the difference.
    func testEveryProtectedFieldIsKeptWhenTheRecordLacksIt() throws {
        let mine = local()
        for field in AppSettings.protectedFields {
            XCTAssertTrue(field.differs(mine, AppSettings()), "\(field.key): set it away from its default here")
            let relayed = try record(AppSettings(), dropping: [field.key], stamp: AppSettings.currentSchemaVersion)
            let merged = mine.preservingFieldsUnknownTo(relayed)
            XCTAssertFalse(field.differs(merged, mine), "\(field.key) was taken from a record that lacked it")
        }
    }

    /// The rule rests on every protected key being written whatever its value: a missing key has to
    /// mean "couldn't express it", never "empty". A new field that leaves out `nil` fails here.
    func testEveryProtectedKeyIsWrittenEvenWhenEmpty() throws {
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        for field in AppSettings.protectedFields {
            XCTAssertNotNil(written[field.key], "\(field.key) is left out when empty")
        }
    }

    /// Schema 8 (6.2): a 6.1 device relays a record without the aerodrome procedures' switches; the ones
    /// this pilot turned on stay on. And a settings file from before 6.2 reads them as off.
    func testTheAerodromeProceduresSwitchesSurviveAnOlderRecord() throws {
        XCTAssertEqual(AppSettings.currentSchemaVersion, 8)
        let keys = ["showVFRCircuitsOnMap", "showVFRRoutesOnMap", "showNonPoweredCircuitsOnMap"]
        XCTAssertTrue(keys.allSatisfy { key in AppSettings.protectedFields.contains { $0.key == key } })

        var remote = local()
        remote.alwaysUseUTC = true
        let relayed = try record(remote, dropping: keys, stamp: 7)
        XCTAssertFalse(relayed.showVFRCircuitsOnMap, "an older record reads them as off")
        let merged = local().preservingFieldsUnknownTo(relayed)
        XCTAssertTrue(merged.showVFRCircuitsOnMap)
        XCTAssertTrue(merged.showVFRRoutesOnMap)
        XCTAssertTrue(merged.showNonPoweredCircuitsOnMap)
        XCTAssertTrue(merged.alwaysUseUTC)

        // A wrong type doesn't throw the whole settings away.
        let odd = try record(local(), extra: ["showVFRRoutesOnMap": "yes"])
        XCTAssertFalse(odd.showVFRRoutesOnMap)
        XCTAssertEqual(odd.homeAerodromeIdent, "LSZQ")
    }

    /// A writer stamped with an older schema is still caught by its stamp (F8), keys or not.
    func testAnOlderStampStillProtects() throws {
        let older = try record(AppSettings(), stamp: 5)
        XCTAssertEqual(local().preservingFieldsUnknownTo(older).homeAerodromeIdent, "LSZQ")
    }

    // MARK: - The merged result, and the re-push

    /// The merged record is the newer one again: our stamp, and every key, with our values.
    func testTheMergedRecordIsANewerRecord() throws {
        let relayed = try record(local(), dropping: ["homeAerodromeIdent", "fullTanksLitres"], stamp: 6)
        let merged = local().preservingFieldsUnknownTo(relayed)

        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(merged)) as? [String: Any])
        XCTAssertEqual(written["schemaVersion"] as? Int, AppSettings.currentSchemaVersion)
        XCTAssertEqual(written["homeAerodromeIdent"] as? String, "LSZQ")
        XCTAssertEqual(written["fullTanksLitres"] as? [String: Double], ["F-HVXA": 100])
        XCTAssertTrue(merged.restoresFields(missingFrom: relayed))

        // And another 6.1 device, one that had none of it, takes it all from there.
        let elsewhere = AppSettings().preservingFieldsUnknownTo(try record(merged))
        XCTAssertEqual(elsewhere.homeAerodromeIdent, "LSZQ")
        XCTAssertEqual(elsewhere.fullTanksLitres, ["F-HVXA": 100])
    }

    /// Through AppState: a relayed record arrives, and the merged record is queued back to CloudKit.
    func testAMergedRecordGoesBackToCloudKit() async throws {
        let defaults = makeTestDefaults()
        defaults.set(true, forKey: DataPersistenceManager.syncPreferenceKey)
        let manager = SyncManager(defaults: defaults, backend: StubSyncBackend())
        await manager.engineStartTask?.value
        let appState = makeTestAppState(syncManager: manager)
        appState.settings.homeAerodromeIdent = "LSZQ"
        XCTAssertNil(manager.getPendingSettings())

        var remote = AppSettings()
        remote.alwaysUseUTC = true
        await manager.onSettingsUpdated?(try record(remote, dropping: ["homeAerodromeIdent"], stamp: 6))

        XCTAssertEqual(appState.settings.homeAerodromeIdent, "LSZQ")
        XCTAssertTrue(appState.settings.alwaysUseUTC)
        let resent = try XCTUnwrap(manager.getPendingSettings(), "the merged record goes back")
        XCTAssertEqual(resent.homeAerodromeIdent, "LSZQ")
        XCTAssertEqual(resent.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertTrue(manager.settingsOwed)
    }

    /// A record that carried everything goes nowhere: nothing to put back, and no echo between two
    /// current devices.
    func testACompleteRecordIsNotSentBack() async throws {
        let defaults = makeTestDefaults()
        defaults.set(true, forKey: DataPersistenceManager.syncPreferenceKey)
        let manager = SyncManager(defaults: defaults, backend: StubSyncBackend())
        await manager.engineStartTask?.value
        let appState = makeTestAppState(syncManager: manager)
        appState.settings.homeAerodromeIdent = "LSZQ"

        var remote = local()
        remote.homeAerodromeIdent = "LSGN"
        await manager.onSettingsUpdated?(try record(remote))

        XCTAssertEqual(appState.settings.homeAerodromeIdent, "LSGN", "taken at its word")
        XCTAssertNil(manager.getPendingSettings())
        XCTAssertFalse(manager.settingsOwed)
    }

    // MARK: - A newer record

    /// A record from a newer schema, carrying every key we know, is still taken at its word, a cleared
    /// home aerodrome included; it only gets our stamp, so what we write next says what we can express.
    func testANewerRecordIsStillTakenAtItsWord() throws {
        var remote = local()
        remote.pilotName = "Julien Bono"
        remote.homeAerodromeIdent = nil
        let newer = try record(remote, stamp: AppSettings.currentSchemaVersion + 1, extra: ["someFutureField": 42])

        let merged = local().preservingFieldsUnknownTo(newer)

        XCTAssertNil(merged.homeAerodromeIdent, "cleared on purpose, and taken")
        XCTAssertEqual(merged.pilotName, "Julien Bono")
        XCTAssertEqual(merged.schemaVersion, AppSettings.currentSchemaVersion, "our own stamp")
        XCTAssertFalse(merged.restoresFields(missingFrom: newer))
    }

    /// A settings file a newer build left on this device (a downgrade) takes this build's stamp too.
    func testANewerLocalFileTakesThisBuildsStamp() {
        var file = local()
        file.schemaVersion = AppSettings.currentSchemaVersion + 1
        let migrated = file.migratedLocally()
        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertFalse(migrated.learningMode, "nothing else touched")
    }
}
