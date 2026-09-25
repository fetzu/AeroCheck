import XCTest
@testable import AeroCheck

/// Throwaway storage for any test that builds an `AppState`, a `FlightThreadManager` or a
/// `FlightPlanManager`.
///
/// The test host IS the app, so `DataPersistenceManager.shared` and `UserDefaults.standard` are the
/// simulator app's own. A manager built on them loads the real threads, plans and trips, and writes
/// back into them. `saveTrips` writes the WHOLE `trips` array, so a test manager whose async load had
/// not landed yet replaced the app's `trips.json` with the test's one trip, and a real two-leg trip
/// disappeared from the app (2026-09-25).
///
/// Build managers through these helpers, never through the initialisers' defaults. Everything they
/// create is removed when the test finishes, and nothing else is touched.
extension XCTestCase {

    /// A datastore in a fresh temporary directory, removed when the test finishes.
    @MainActor
    func makeTestDatastore() -> DataPersistenceManager {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AeroCheckTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return DataPersistenceManager(rootDirectory: root)
    }

    /// A defaults suite of its own, removed when the test finishes.
    func makeTestDefaults() -> UserDefaults {
        let suite = "AeroCheckTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    /// Pass the same `datastore` to both managers when a test needs them to share one, as the app's do.
    @MainActor
    func makeTestThreadManager(datastore: DataPersistenceManager? = nil) -> FlightThreadManager {
        FlightThreadManager(defaults: makeTestDefaults(), persistence: datastore ?? makeTestDatastore())
    }

    @MainActor
    func makeTestPlanManager(datastore: DataPersistenceManager? = nil) -> FlightPlanManager {
        FlightPlanManager(defaults: makeTestDefaults(), persistence: datastore ?? makeTestDatastore())
    }

    /// An AppState on its own datastore and defaults suite, and therefore off CloudKit. Pass the same
    /// `datastore` and `defaults` to a second one to model a relaunch on the same device.
    ///
    /// On `.shared`, `AppState()` restored the simulator app's real in-progress flight (or deleted its
    /// checkpoint), wrote into its logbook and settings, and pushed test data to the pilot's iCloud.
    @MainActor
    func makeTestAppState(datastore: DataPersistenceManager? = nil,
                          defaults: UserDefaults? = nil) -> AppState {
        let appState = AppState(defaults: defaults ?? makeTestDefaults(),
                                persistence: datastore ?? makeTestDatastore())
        // Registered after the datastore and the suite, so it runs before they are removed: a
        // checkpoint still queued would otherwise land afterwards and re-create the suite's plist.
        addTeardownBlock { @MainActor in appState.flushPendingCheckpoint() }
        return appState
    }
}
