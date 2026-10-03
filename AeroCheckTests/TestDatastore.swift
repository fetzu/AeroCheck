import XCTest
@testable import AeroCheck

/// Throwaway storage for any test that builds an `AppState`, a `FlightThreadManager`, a
/// `FlightPlanManager`, an `AircraftDataService` or a `SubscriptionManager`.
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

    /// A fresh temporary directory, removed when the test finishes.
    func makeTestDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AeroCheckTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A datastore in a fresh temporary directory, removed when the test finishes.
    @MainActor
    func makeTestDatastore() -> DataPersistenceManager {
        DataPersistenceManager(rootDirectory: makeTestDirectory())
    }

    /// A defaults suite of its own, removed when the test finishes.
    func makeTestDefaults() -> UserDefaults {
        let suite = "AeroCheckTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    /// A Keychain service of its own (the host shares the app's Keychain), emptied when the test
    /// finishes.
    func makeTestKeychain() -> KeychainStore {
        let keychain = KeychainStore(service: "AeroCheckTests.\(UUID().uuidString)")
        addTeardownBlock { KeychainStore.Key.allCases.forEach(keychain.remove) }
        return keychain
    }

    /// A SubscriptionManager on its own defaults suite and Keychain service.
    @MainActor
    func makeTestSubscriptionManager(deferLoadProducts: Bool = false) -> SubscriptionManager {
        SubscriptionManager(defaults: makeTestDefaults(), keychain: makeTestKeychain(),
                            deferLoadProducts: deferLoadProducts)
    }

    /// Pass the same `datastore` to both managers when a test needs them to share one, as the app's do.
    @MainActor
    func makeTestThreadManager(datastore: DataPersistenceManager? = nil) -> FlightThreadManager {
        FlightThreadManager(defaults: makeTestDefaults(), persistence: datastore ?? makeTestDatastore())
    }

    /// Pass the same `datastore` and `defaults` to a second one to model a relaunch: the active plan
    /// lives in the defaults, the plans in the datastore.
    @MainActor
    func makeTestPlanManager(datastore: DataPersistenceManager? = nil,
                             defaults: UserDefaults? = nil) -> FlightPlanManager {
        FlightPlanManager(defaults: defaults ?? makeTestDefaults(), persistence: datastore ?? makeTestDatastore())
    }

    /// An AppState on its own datastore and defaults suite, and therefore off CloudKit. Pass the same
    /// `datastore` and `defaults` to a second one to model a relaunch on the same device.
    ///
    /// On `.shared`, `AppState()` restored the simulator app's real in-progress flight (or deleted its
    /// checkpoint), wrote into its logbook and settings, and pushed test data to the pilot's iCloud.
    ///
    /// `syncManager`: one built on a stand-in engine (`SyncManager(defaults:backend:)`), for the
    /// tests that drive "Sync to iCloud" through AppState. Never `SyncManager.shared`.
    @MainActor
    func makeTestAppState(datastore: DataPersistenceManager? = nil,
                          defaults: UserDefaults? = nil,
                          syncManager: SyncManager? = nil) -> AppState {
        let appState = AppState(defaults: defaults ?? makeTestDefaults(),
                                persistence: datastore ?? makeTestDatastore(),
                                syncManager: syncManager)
        // Registered after the datastore and the suite, so it runs before they are removed: a
        // checkpoint still queued would otherwise land afterwards and re-create the suite's plist.
        addTeardownBlock { @MainActor in appState.flushPendingCheckpoint() }
        return appState
    }

    /// An AircraftDataService caching checklists in its own temporary directory, and telling the
    /// home-screen widget nothing. Omit `httpClient` to keep the production transport.
    ///
    /// On the defaults a test cached an empty aircraft list over the simulator app's real one,
    /// cleared its downloaded premium checklists, and republished its widget with only the WT9.
    @MainActor
    func makeTestAircraftDataService(subscriptionManager: SubscriptionGating,
                                     httpClient: HTTPClient? = nil) -> AircraftDataService {
        let cacheDirectory = makeTestDirectory().appendingPathComponent("Checklists", isDirectory: true)
        guard let httpClient else {
            return AircraftDataService(subscriptionManager: subscriptionManager,
                                       cacheDirectory: cacheDirectory, publishToWidget: { _ in })
        }
        return AircraftDataService(subscriptionManager: subscriptionManager, httpClient: httpClient,
                                   cacheDirectory: cacheDirectory, publishToWidget: { _ in })
    }

    /// An OpenAIP airport layer caching in `root` (a fresh temporary directory by default) and fetching
    /// through `fetch`, never the network. `OpenAIPAirportDataService.shared` holds the simulator app's
    /// own aerodromes: deleting them or downloading over them is the real data. (6.2.0)
    @MainActor
    func makeTestOpenAIPAirportLayer(root: URL? = nil,
                                     fetch: @escaping (String) async throws -> [OpenAIPAirport]) -> OpenAIPAirportDataService {
        OpenAIPAirportDataService(cache: OpenAIPLayerCache<OpenAIPAirport>(
            directoryName: OpenAIPAirportDataService.directoryName, filePrefix: "airports",
            endpointSuffix: "apt", restPath: "airports", logLabel: "test",
            parse: OpenAIPAirport.parse(geoJSON:), fetch: fetch,
            rootDirectory: root ?? makeTestDirectory()))
    }

    /// An open flightmaps service caching in `root` (a fresh temporary directory by default) and fetching
    /// through `fetch`, never the network, on `now`'s clock. `OFMDataService.shared` holds the simulator
    /// app's own files: downloading over them or deleting them is the real data. (6.2.0)
    @MainActor
    func makeTestOFMService(root: URL? = nil, now: @escaping () -> Date = Date.init,
                            fetch: @escaping (URL) async throws -> Data) -> OFMDataService {
        OFMDataService(rootDirectory: root ?? makeTestDirectory(), baseURL: OFMConfig.defaultBaseURL,
                       allowedHosts: OFMConfig.allowedHosts(override: nil), fetch: fetch, now: now)
    }

    /// An airport store whose OurAirports files live in `root` (a fresh temporary directory by default),
    /// folding in `openAIPAirports`. The app's store reads and deletes the real `AirportData`. (6.2.0)
    @MainActor
    func makeTestAirportStore(openAIPAirports: OpenAIPAirportDataService, root: URL? = nil) -> AirportDataService {
        AirportDataService(openAIPAirports: openAIPAirports, rootDirectory: root ?? makeTestDirectory())
    }
}
