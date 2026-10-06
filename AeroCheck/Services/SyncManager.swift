import Foundation
import CloudKit
import Combine

/// Record types stored in CloudKit
enum SyncRecordType: String {
    case settings = "Settings"
    case flight = "Flight"
    /// The GPS track of a flight, in its own record so a metadata edit doesn't re-upload/re-download
    /// the whole track on other devices. recordName = "track-<flightId>". (sync optimization)
    case flightTrack = "FlightTrack"
}

/// The part of `CKSyncEngine` that `SyncManager` drives, so the switch's start and stop, and what
/// it queues, can be tested without an iCloud account. `CKSyncEngine` is the only real one.
protocol SyncEngineDriving: AnyObject, Sendable {
    func queue(_ changes: [CKSyncEngine.PendingRecordZoneChange])
    func unqueue(_ changes: [CKSyncEngine.PendingRecordZoneChange])
    func queue(_ changes: [CKSyncEngine.PendingDatabaseChange])
    func fetch() async throws
    func send() async throws
}

extension CKSyncEngine: SyncEngineDriving {
    func queue(_ changes: [CKSyncEngine.PendingRecordZoneChange]) { state.add(pendingRecordZoneChanges: changes) }
    func unqueue(_ changes: [CKSyncEngine.PendingRecordZoneChange]) { state.remove(pendingRecordZoneChanges: changes) }
    func queue(_ changes: [CKSyncEngine.PendingDatabaseChange]) { state.add(pendingDatabaseChanges: changes) }
    func fetch() async throws { try await fetchChanges() }
    func send() async throws { try await sendChanges() }
}

/// Where `SyncManager` gets its account status and its engine: CloudKit (`CloudKitSyncBackend`), or
/// a stand-in in the tests.
@MainActor
protocol SyncBackend: AnyObject {
    /// Throws when CloudKit is not configured (no entitlement, no container).
    func accountStatus() async throws -> CKAccountStatus
    /// An engine on the private database, resuming from `state`.
    func makeEngine(state: CKSyncEngine.State.Serialization?, delegate: SyncEngineDelegate) -> SyncEngineDriving
}

/// The app's CloudKit container, created anew by each start: at launch with the switch on, when it
/// turns on, after an iCloud account change.
@MainActor
final class CloudKitSyncBackend: SyncBackend {
    private let identifier: String
    private var container: CKContainer?

    init(identifier: String) {
        self.identifier = identifier
    }

    func accountStatus() async throws -> CKAccountStatus {
        let container = CKContainer(identifier: identifier)
        self.container = container
        return try await container.accountStatus()
    }

    func makeEngine(state: CKSyncEngine.State.Serialization?, delegate: SyncEngineDelegate) -> SyncEngineDriving {
        let container = self.container ?? CKContainer(identifier: identifier)
        return CKSyncEngine(CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                       stateSerialization: state, delegate: delegate))
    }
}

/// Manages iCloud sync using CKSyncEngine (iOS 17+)
@MainActor
class SyncManager: ObservableObject {
    // MARK: - Singleton

    static let shared = SyncManager()

    // MARK: - Published Properties

    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var syncError: String?
    /// The switch. AppState sets it on every settings save; only a change acts.
    ///
    /// On: CloudKit comes up right away. It used to wait for the next launch: the container was only
    /// resolved at launch, and only with the switch already on, so a switch turned on mid-session
    /// synced nothing until the app was relaunched. Off: the engine stops (`stopSync`).
    @Published var isSyncEnabled: Bool {
        didSet {
            defaults.set(isSyncEnabled, forKey: syncEnabledKey)
            guard isSyncEnabled != oldValue else { return }
            if isSyncEnabled {
                startSync()
            } else {
                stopSync()
            }
        }
    }

    // MARK: - CloudKit Configuration

    private static let containerIdentifier = "iCloud.com.fetzu.aerocheck"
    private let zoneName = "AeroCheckZone"
    private let syncEnabledKey = "iCloudSyncEnabled"
    private let syncStateKey = "syncEngineState"
    private let lastSyncDateKey = "lastSyncDate"
    private let settingsRecordExistsKey = "settingsRecordExists"
    private let settingsRecordKey = "cachedSettingsRecord"
    private let lastSyncedModifiedAtKey = "lastSyncedFlightModifiedAt"
    private let lastSyncedTrackCountKey = "lastSyncedFlightTrackCount"
    private let recordSystemFieldsKey = "syncedRecordSystemFields"

    /// recordName → archived CKRecord **system fields** (recordID, change tag, zone) for records the
    /// server has acknowledged.
    ///
    /// Without this a flight record was rebuilt from scratch on every send — `CKRecord(recordType:
    /// recordID:)` carries no `recordChangeTag`, so CloudKit treats every save as an INSERT and
    /// answers an existing record with `serverRecordChanged` / "record to insert already exists".
    /// The conflict handler then merged and re-queued... another tag-less record, so it could never
    /// converge, and the GPS track record failed alongside it with "Atomic failure" because the two
    /// share an atomic batch. Net effect: a flight that needed re-sending never reached iCloud.
    ///
    /// The settings record never had this problem because it reuses `cachedSettingsRecord`
    /// specifically to keep its change tag. Flights were the one record type that didn't.
    private var recordSystemFields: [String: Data] = [:]

    /// flightId → the `modifiedAt` last CONFIRMED-sent to CloudKit, so `syncAllFlights` can skip flights
    /// that haven't changed (a miss only ever causes a harmless re-upload, never a skipped change).
    private var lastSyncedModifiedAt: [String: Date] = [:]

    /// flightId → the GPS-track point count last CONFIRMED-sent, so the (large) track record is only
    /// re-uploaded when the track itself changed — a metadata edit (rename) leaves it untouched.
    private var lastSyncedTrackCount: [String: Int] = [:]

    // MARK: - Private Properties

    /// Where this device keeps its sync state. `.standard` for the app; a suite of its own in tests,
    /// since the test host IS the app and `.standard` holds its real change tokens and fingerprints.
    private let defaults: UserDefaults
    private let backend: SyncBackend
    private var syncEngine: SyncEngineDriving?
    private var syncEngineDelegate: SyncEngineDelegate?
    private var recordZone: CKRecordZone?

    /// The engine start in progress, so a second trigger (the switch, an account change) joins it
    /// instead of building a second engine.
    private var engineStart: Task<Void, Never>?

    /// Set when the engine came up but its first fetch failed: the catch-up (`queueWhatCloudKitLacks`)
    /// waits for a fetch that succeeds, or it would re-upload records CloudKit already holds.
    private var catchUpOwed = false

    /// Callback when settings are updated from sync. Awaited, like `onFlightsUpdated`, so an event is
    /// applied before the next one, and before the catch-up reads the settings.
    var onSettingsUpdated: (@MainActor (AppSettings) async -> Void)?

    /// Callback when flights are updated from sync. Awaited: the catch-up after the first fetch must
    /// see the logbook with the fetched changes applied, or it would send back a flight another
    /// device has just deleted or edited.
    var onFlightsUpdated: (@MainActor ([Flight]) async -> Void)?

    /// What this device holds, for the catch-up when the engine comes up: the logbook and the
    /// settings as they are now. AppState provides it; nil queues nothing.
    var localSnapshot: (@MainActor () async -> (flights: [Flight], settings: AppSettings)?)?

    /// The flight deletion records of the store in use (6.1), read when the engine comes up and with
    /// each fetch that brings flights. AppState provides it; nil reads none.
    var flightDeletionRecords: (@MainActor () async -> DeletionLedger)?

    /// CloudKit deleted these flights: another device did. Each comes with the content stamp of this
    /// device's copy, when it held one. AppState records them (6.1), so a copy in the other store, or
    /// one put back by an older build, stays deleted too.
    var onFlightsDeletedInCloudKit: (@MainActor ([(id: UUID, stamp: Date?)]) -> Void)?

    /// Callback when a sync conflict was resolved (or could not be), so the UI can surface it
    /// instead of the conflict being silent. (ARCH-02)
    var onSyncConflict: ((String) -> Void)?

    /// Upper bound on a single ingested CloudKit record's encoded `data` blob. A real flight (even
    /// multi-hour) is a few MB; anything larger is corrupt/malicious and is rejected. (SEC-17)
    nonisolated static let maxIngestRecordBytes = 16 * 1024 * 1024

    /// Inline-field budget for a flight record. CloudKit caps a record's *inline* fields at ~1 MB
    /// total; a long GPS track (multi-hour flight = tens of thousands of points) blows past that and
    /// the save fails with `limitExceeded` — so the flight silently never syncs and CKSyncEngine
    /// retries the same doomed record forever. Above this threshold the full encoded flight is moved
    /// into a file-backed `CKAsset` (no practical size cap) and only a track-stripped copy stays
    /// inline, keeping the record's queryable metadata intact and still readable by older clients.
    /// Kept well under the 1 MB hard cap to leave room for the other inline fields. (PERF-13)
    nonisolated static let maxInlineFlightBytes = 700 * 1024

    /// Pending changes to sync - using dictionaries to preserve data for batch operations
    private var pendingSettingsChange: AppSettings?
    
    /// Track whether the settings record has been created on the server
    var settingsRecordExists: Bool = false
    private var pendingFlights: [UUID: Flight] = [:]  // Map of flight ID to flight data

    private let owedFlightDeletionsKey = "owedFlightDeletions_v1"
    private let settingsOwedKey = "settingsOwedToCloudKit_v1"

    /// Flights deleted here that CloudKit has not confirmed deleting yet. Persisted, and sent again
    /// whenever the engine comes up.
    ///
    /// A delete made while no engine was running (the seconds CloudKit takes to come up, a start
    /// that failed) used to be dropped: the flight stayed in CloudKit and on every other device.
    ///
    /// A delete made while the switch is OFF does not come here at once (AppState calls with it on
    /// only): it leaves its deletion record (6.1), and the catch-up turns the record into a delete
    /// owed here when CloudKit comes up, after the first fetch (`flightDeletionsOwed`). Deciding
    /// after the fetch is what lets an edit made elsewhere after the deletion win, rather than be
    /// deleted from CloudKit unseen. A fetched copy the records say is dead becomes one too.
    private(set) var owedFlightDeletions: Set<UUID> {
        get { Set((defaults.stringArray(forKey: owedFlightDeletionsKey) ?? []).compactMap(UUID.init(uuidString:))) }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: owedFlightDeletionsKey)
            } else {
                defaults.set(newValue.map(\.uuidString).sorted(), forKey: owedFlightDeletionsKey)
            }
        }
    }

    /// Settings saved here that CloudKit has not confirmed yet. `pendingSettingsChange` is memory
    /// only, so a save made before the engine was up (turning the switch on is one) or not sent
    /// before the app quit was never sent. The catch-up sends the settings as they are then.
    private(set) var settingsOwed: Bool {
        get { defaults.bool(forKey: settingsOwedKey) }
        set { defaults.set(newValue, forKey: settingsOwedKey) }
    }

    /// Cached settings record to preserve change tag for updates
    var cachedSettingsRecord: CKRecord? {
        get {
            guard let data = defaults.data(forKey: settingsRecordKey) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
        }
        set {
            if let record = newValue,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true) {
                defaults.set(data, forKey: settingsRecordKey)
            }
        }
    }

    // MARK: - Initialization

    private convenience init() {
        self.init(defaults: .standard, backend: CloudKitSyncBackend(identifier: Self.containerIdentifier))
        // SEC-C27: reclaim staged CKAsset payloads orphaned by a previous session (crash, or a
        // permanently-failed upload). Cheap, off the hot path, and bounded by an age cutoff so it
        // can never touch an upload in progress.
        Task.detached(priority: .utility) { SyncManager.sweepStagedFlightAssets() }
        observeAccountChanges()
    }

    /// `CKAccountChanged` → `accountDidChange`. The app's instance only: the tests call it directly.
    private func observeAccountChanges() {
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.accountDidChange()
            }
        }
    }

    /// `defaults` and `backend` are injectable for the tests; the app uses `shared`.
    init(defaults: UserDefaults, backend: SyncBackend) {
        self.defaults = defaults
        self.backend = backend

        // Load sync preference (default to enabled)
        self.isSyncEnabled = defaults.object(forKey: syncEnabledKey) as? Bool ?? true

        // Load last sync date
        self.lastSyncDate = defaults.object(forKey: lastSyncDateKey) as? Date

        // Load whether settings record exists on server
        self.settingsRecordExists = defaults.bool(forKey: settingsRecordExistsKey)

        // Load the synced-flight fingerprint maps (skip-unchanged guards for the send side)
        if let data = defaults.data(forKey: lastSyncedModifiedAtKey),
           let map = try? JSONDecoder().decode([String: Date].self, from: data) {
            self.lastSyncedModifiedAt = map
        }
        if let data = defaults.data(forKey: lastSyncedTrackCountKey),
           let map = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.lastSyncedTrackCount = map
        }
        self.recordSystemFields =
            defaults.dictionary(forKey: recordSystemFieldsKey) as? [String: Data] ?? [:]

        // CloudKit comes up in a task of its own, so it never holds up the launch.
        if isSyncEnabled { startSync() }
    }

    // MARK: - Sync Engine Lifecycle

    /// Brings CloudKit up: at launch, when the switch turns on, after an iCloud sign-in. Joins a
    /// start already under way; does nothing while an engine is running.
    ///
    /// The container and the account are resolved here every time, not once at launch: a switch
    /// turned on mid-session (or a launch whose account check failed) found no container and never
    /// started the engine before the next launch.
    ///
    /// Detached: the start awaits the engine's first fetch, and an account change starts it from a
    /// delegate callback. A task started there inherits the callback's context, and iOS 27 traps an
    /// await into the engine made with it ("BUG IN CLIENT OF CLOUDKIT"): 6.1.1 crashed at launch in
    /// App Review, on the `.signIn` a fresh install's engine delivers first.
    private func startSync() {
        guard isSyncEnabled, syncEngine == nil, engineStart == nil else { return }
        engineStart = Task.detached(priority: .utility) { @MainActor [weak self] in
            await self?.initializeCloudKit()
            // A start cancelled by `stopSync` leaves the field to whatever replaced it.
            if !Task.isCancelled { self?.engineStart = nil }
        }
    }

    /// Stops the engine: the switch went off. Cancels a start under way and the sync in flight,
    /// and drops the engine, so nothing more is sent or fetched. The engine's saved state (change
    /// tokens, its pending changes) is kept: turning the switch back on resumes from it, and
    /// receives what other devices changed meanwhile.
    private func stopSync() {
        engineStart?.cancel()
        engineStart = nil
        inFlightSync?.cancel()
        inFlightSync = nil
        catchUpOwed = false
        shutdownSyncEngine()
        isSyncing = false
    }

    /// Checks the account, then starts the engine when it is available.
    private func initializeCloudKit() async {
        do {
            let status = try await backend.accountStatus()
            guard !Task.isCancelled, isSyncEnabled else { return }
            AppLog.sync.publicLine("CloudKit initialized successfully, account status: \(status)")
            guard status == .available else {
                syncError = "iCloud account not available"
                AppLog.sync.publicLine("iCloud account not available: \(status)")
                return
            }
            await startEngine()
        } catch {
            syncError = "CloudKit not configured"
            AppLog.sync.debugLine("CloudKit not available: \(error.localizedDescription)")
            AppLog.sync.debugLine("To enable iCloud sync, configure CloudKit in Xcode's Signing & Capabilities")
        }
    }

    /// Builds the engine from its saved state, then: the zone, the deletes still owed, the first
    /// fetch, and the catch-up.
    private func startEngine() async {
        guard syncEngine == nil, isSyncEnabled, !Task.isCancelled else { return }
        let zone = recordZone ?? CKRecordZone(zoneName: zoneName)
        recordZone = zone
        let engine = backend.makeEngine(state: loadSyncState(), delegate: createDelegate())
        syncEngine = engine
        syncError = nil
        AppLog.sync.publicLine("Sync engine initialized")

        engine.queue([.saveZone(zone)])
        let owed = owedFlightDeletions
        if !owed.isEmpty {
            engine.queue(owed.sorted { $0.uuidString < $1.uuidString }.flatMap { deletions(for: $0, in: zone) })
            AppLog.sync.debugLine("Re-queued \(owed.count) flight deletion(s) not confirmed yet")
        }

        // Pull existing records on launch. CKSyncEngine only auto-syncs to SEND pending local
        // changes (and to fetch in response to a remote push); a fresh install has an empty
        // local store and nothing to send, so without this explicit fetch the logbook stays
        // empty until a push happens to arrive — or the user taps Sync Now. (fresh-install fix)
        let fetched = await performInitialFetch(using: engine)
        guard syncEngine === engine, isSyncEnabled, !Task.isCancelled else { return }
        if fetched {
            await queueWhatCloudKitLacks()
        } else {
            catchUpOwed = true
        }
    }

    /// One-shot fetch when the engine comes up, so records that already exist on the server (e.g. a
    /// logbook synced from another device, or this device's own pre-reinstall data) land without
    /// waiting for a remote push or a manual Sync Now. (fresh-install fix)
    private func performInitialFetch(using engine: SyncEngineDriving) async -> Bool {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await engine.fetch()
            lastSyncDate = Date()
            defaults.set(lastSyncDate, forKey: lastSyncDateKey)
            AppLog.sync.publicLine("Initial fetch on launch completed")
            return true
        } catch {
            AppLog.sync.debugLine("Initial fetch on launch failed: \(error)")
            return false
        }
    }

    /// Queues what this device holds that CloudKit lacks: every flight not confirmed-sent as it is
    /// now, and the settings when a save of them is still owed. Runs each time the engine comes up,
    /// after its first fetch.
    ///
    /// Nothing else did it. `syncAllFlights` ran only on an import, so flights recorded while the
    /// switch was off (or while CloudKit was down, or whose queued save was lost with the app: the
    /// flight to send lives in memory) never reached CloudKit until edited.
    ///
    /// Nothing is sent twice: `syncAllFlights` skips a flight whose `modifiedAt` and track count
    /// match what CloudKit confirmed, and the fetch before this marks every record it received
    /// that way. Hence the order: the fetch's events are applied first (`eventsHandled`), or this
    /// would send back what the fetch just brought, or a flight another device just deleted.
    ///
    /// Deletion records (6.1): the flights deleted here that CloudKit still holds become deletes
    /// owed (a delete made with the switch off reaches CloudKit this way), and no flight the records
    /// say is dead is sent.
    private func queueWhatCloudKitLacks() async {
        catchUpOwed = false
        await syncEngineDelegate?.eventsHandled()
        guard isSyncEnabled, syncEngine != nil, let snapshot = await localSnapshot?() else { return }
        let deletions = await flightDeletionRecords?() ?? .empty
        // The switch may have gone off while the snapshot waited on the logbook load.
        guard isSyncEnabled, syncEngine != nil else { return }
        let owed = Self.flightDeletionsOwed(deletions: deletions, cloudKitStamps: cloudKitStamps(of: deletions),
                                            logbook: snapshot.flights, alreadyOwed: owedFlightDeletions)
        for id in owed.sorted(by: { $0.uuidString < $1.uuidString }) { deleteFlight(id) }
        if !owed.isEmpty {
            AppLog.sync.publicLine("Owed \(owed.count) flight deletion(s) from the deletion records")
        }
        syncAllFlights(snapshot.flights.filter { !deletions.isDead(.flight, id: $0.id, stamp: $0.modifiedAt) })
        if settingsOwed { syncSettings(snapshot.settings) }
    }

    /// The flights whose deletion records here CloudKit may still hold a copy of, with that copy's
    /// stamp as far as this device knows: the `modifiedAt` last confirmed sent or received. A flight
    /// known by its track or its record's identity only stamps `.distantPast`.
    private func cloudKitStamps(of deletions: DeletionLedger) -> [UUID: Date] {
        var stamps: [UUID: Date] = [:]
        for key in deletions.marks.keys where key.kind == .flight {
            let name = key.id.uuidString
            if let stamp = lastSyncedModifiedAt[name] {
                stamps[key.id] = stamp
            } else if lastSyncedTrackCount[name] != nil || recordSystemFields[name] != nil
                        || recordSystemFields[Self.trackRecordName(key.id)] != nil {
                stamps[key.id] = .distantPast
            }
        }
        return stamps
    }

    /// The deletes CloudKit is owed from the deletion records (6.1). Pure, like `classifySendFailure`.
    ///
    /// A flight is owed one when this device deleted it (or received its deletion through iCloud
    /// Drive), CloudKit still holds a copy (`cloudKitStamps`: confirmed sent or received, and not
    /// deleted since), that copy is dead by the rule (not edited after the deletion), and the
    /// logbook holds no live copy (one there is sent instead, and replaces it). A record not
    /// downloaded yet decides nothing.
    nonisolated static func flightDeletionsOwed(deletions: DeletionLedger, cloudKitStamps: [UUID: Date],
                                                logbook: [Flight], alreadyOwed: Set<UUID>) -> Set<UUID> {
        guard deletions.contains(.flight) else { return [] }
        let live = Set(logbook.lazy.filter { !deletions.isDead(.flight, id: $0.id, stamp: $0.modifiedAt) }.map(\.id))
        var owed = Set<UUID>()
        for key in deletions.marks.keys where key.kind == .flight {
            guard !alreadyOwed.contains(key.id), !live.contains(key.id), let stamp = cloudKitStamps[key.id],
                  deletions.isDead(.flight, id: key.id, stamp: stamp) else { continue }
            owed.insert(key.id)
        }
        return owed
    }

    private func shutdownSyncEngine() {
        syncEngine = nil
        syncEngineDelegate = nil
        AppLog.sync.publicLine("Sync engine shutdown")
    }

    /// Whether an engine is running. For the tests and the logs.
    var isEngineRunning: Bool { syncEngine != nil }

    /// Whether `delegate` is the running engine's. One delegate is built per engine.
    func isCurrent(_ delegate: SyncEngineDelegate) -> Bool {
        syncEngine != nil && syncEngineDelegate === delegate
    }

    /// The start under way, if any: the account check, the engine, its first fetch and the
    /// catch-up. For the tests, which await it.
    var engineStartTask: Task<Void, Never>? { engineStart }

    /// Discards every piece of account-scoped sync state. (RES-05)
    ///
    /// All of this describes the *previous* account's server side: the persisted
    /// `CKSyncEngine.State.Serialization` holds that account's change tokens and pending changes;
    /// `cachedSettingsRecord` holds one of its record change tags; `settingsRecordExists` asserts a
    /// record exists in a database we can no longer see; and the fingerprint maps record what was
    /// confirmed-sent *there*. Carried into a different account, each one is actively wrong — the
    /// fingerprints in particular would make `syncAllFlights` skip flights as "already synced" that
    /// the new account has never seen, so the pilot's logbook would silently never upload.
    private func clearAccountScopedState() {
        defaults.removeObject(forKey: syncStateKey)
        defaults.removeObject(forKey: settingsRecordKey)
        defaults.removeObject(forKey: settingsRecordExistsKey)
        defaults.removeObject(forKey: lastSyncedModifiedAtKey)
        defaults.removeObject(forKey: lastSyncedTrackCountKey)
        defaults.removeObject(forKey: recordSystemFieldsKey)
        defaults.removeObject(forKey: lastSyncDateKey)
        // Deletes of the previous account's records: that account is not this one.
        owedFlightDeletions = []

        settingsRecordExists = false
        lastSyncedModifiedAt = [:]
        lastSyncedTrackCount = [:]
        recordSystemFields = [:]
        lastSyncDate = nil
        pendingSettingsChange = nil
        pendingFlights = [:]
        AppLog.sync.publicLine("Cleared account-scoped sync state")
    }

    private func createDelegate() -> SyncEngineDelegate {
        let delegate = SyncEngineDelegate(manager: self)
        self.syncEngineDelegate = delegate
        return delegate
    }

    // MARK: - State Persistence

    private func loadSyncState() -> CKSyncEngine.State.Serialization? {
        guard let data = defaults.data(forKey: syncStateKey) else {
            return nil
        }

        do {
            let state = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            AppLog.sync.publicLine("Loaded sync state")
            return state
        } catch {
            AppLog.sync.debugLine("Failed to load sync state: \(error)")
            return nil
        }
    }

    func saveSyncState(_ state: CKSyncEngine.State.Serialization) {
        do {
            let data = try JSONEncoder().encode(state)
            defaults.set(data, forKey: syncStateKey)
        } catch {
            AppLog.sync.debugLine("Failed to save sync state: \(error)")
        }
    }

    // MARK: - Sync Operations

    /// Sync settings to iCloud. Owed (`settingsOwed`) until CloudKit confirms the record, so a save
    /// made before the engine is up (turning the switch on is one) is sent once it is.
    func syncSettings(_ settings: AppSettings) {
        guard isSyncEnabled else { return }

        pendingSettingsChange = settings
        settingsOwed = true
        guard let engine = syncEngine, let recordZone = recordZone else { return }

        let recordID = CKRecord.ID(recordName: "settings", zoneID: recordZone.zoneID)
        engine.queue([.saveRecord(recordID)])

        AppLog.sync.debugLine("Queued settings for sync")
        
        // Immediately trigger sync to ensure settings changes are pushed to other devices
        Task.detached {
            await self.syncNow()
        }
    }

    /// The pending record-zone changes for a flight: a metadata record when its metadata changed since
    /// the last CONFIRMED sync, and a separate track record when the GPS track grew. Splitting the
    /// track into its own record means a metadata edit (rename) no longer re-uploads — and other
    /// devices no longer re-download — the whole track. A stale fingerprint only ever causes a harmless
    /// re-upload, never a skipped change. Stores the flight in `pendingFlights` for the off-main encode.
    private func pendingChanges(for flight: Flight, in zone: CKRecordZone) -> [CKSyncEngine.PendingRecordZoneChange] {
        let idStr = flight.id.uuidString
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        if lastSyncedModifiedAt[idStr] != flight.modifiedAt {
            changes.append(.saveRecord(CKRecord.ID(recordName: idStr, zoneID: zone.zoneID)))
        }
        if lastSyncedTrackCount[idStr] != flight.gpsTrack.count {
            changes.append(.saveRecord(CKRecord.ID(recordName: Self.trackRecordName(flight.id), zoneID: zone.zoneID)))
        }
        if !changes.isEmpty {
            pendingFlights[flight.id] = flight
            // The logbook holds it again (an import of its export, an edit made elsewhere after the
            // deletion): the save replaces the delete, never goes out in the same batch with it.
            retractFlightDeletion(flight.id)
        }
        return changes
    }

    /// Sync a flight to iCloud
    func syncFlight(_ flight: Flight, allFlights: [Flight]) {
        guard isSyncEnabled, let engine = syncEngine, let recordZone = recordZone else { return }

        let changes = pendingChanges(for: flight, in: recordZone)
        guard !changes.isEmpty else { return }
        engine.queue(changes)
        AppLog.sync.debugLine("Queued flight \(flight.id) for sync (\(changes.count) record(s))")
    }

    /// Sync all flights to iCloud
    func syncAllFlights(_ flights: [Flight]) {
        guard isSyncEnabled, let engine = syncEngine, let recordZone = recordZone else { return }

        // Queue only the records that changed since the last CONFIRMED sync — re-uploading every flight
        // on each batch (e.g. importing one) is what made "sync all" slow.
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for flight in flights {
            changes.append(contentsOf: pendingChanges(for: flight, in: recordZone))
        }
        guard !changes.isEmpty else { return }
        engine.queue(changes)
        AppLog.sync.debugLine("Queued \(changes.count) record(s) for \(flights.count) flights")
    }

    /// Delete a flight from iCloud. Owed (`owedFlightDeletions`) until CloudKit confirms it: sent
    /// now when the engine runs, and again whenever it comes up, so a delete made before it was up
    /// is no longer dropped. With the switch off, nothing: the deletion record stands for it, and
    /// becomes this call when CloudKit comes up (`queueWhatCloudKitLacks`).
    func deleteFlight(_ flightId: UUID) {
        guard isSyncEnabled else { return }

        unmarkFlightSynced(flightId)   // so a future flight reusing this id re-uploads
        // Drop the stored change tag too: once the delete lands the record no longer exists, and a
        // stale tag would make a later insert look like an update to something that is gone.
        forgetSystemFields(forFlight: flightId)
        // A save still queued for it would re-create the record the delete removes.
        clearPendingFlight(flightId)
        owedFlightDeletions.insert(flightId)

        guard let engine = syncEngine, let recordZone = recordZone else {
            AppLog.sync.debugLine("Flight \(flightId) deletion kept for when CloudKit is up")
            return
        }
        engine.unqueue(saves(for: flightId, in: recordZone))
        engine.queue(deletions(for: flightId, in: recordZone))

        AppLog.sync.debugLine("Queued flight \(flightId) (+ track) for deletion")
    }

    /// A flight owed a delete is alive again: a copy edited after its deletion came back (a later
    /// edit beats an older delete, 6.1). The delete, if not sent yet, would remove that edit from
    /// CloudKit and from every other device.
    func retractFlightDeletion(_ flightId: UUID) {
        guard owedFlightDeletions.contains(flightId) else { return }
        owedFlightDeletions.remove(flightId)
        if let engine = syncEngine, let recordZone {
            engine.unqueue(deletions(for: flightId, in: recordZone))
        }
        AppLog.sync.debugLine("Flight \(flightId) is alive again: its owed deletion is withdrawn")
    }

    /// What a fetch brings in, against this device's deletion records (6.1).
    struct InboundFlights {
        /// The copies to merge.
        var live: [Flight]
        /// Flights deleted here whose fetched copy is not later than the deletion: dropped, so the
        /// fetch cannot bring them back.
        var dead: Set<UUID> = []
        /// Flights deleted here that an edit made after the deletion brings back.
        var revived: Set<UUID> = []
    }

    /// Sorts the flights a fetch decoded by the deletion records here. Pure, like
    /// `classifySendFailure`, so the rule is tested without a live `CKSyncEngine`.
    ///
    /// The rule is #242's: a copy is dead when its stamp is not later than the record's `deletedAt`.
    /// It is decided per flight, on the latest stamp among its fetched copies (the metadata record
    /// and the track record both decode to a flight, and a metadata edit leaves the track record's
    /// stamp behind) and the copy in `local`, so a live flight never loses its track. A record not
    /// downloaded yet drops nothing.
    nonisolated static func filterInboundFlights(_ inbound: [Flight], local: [Flight],
                                                 deletions: DeletionLedger) -> InboundFlights {
        guard !inbound.isEmpty, deletions.contains(.flight) else { return InboundFlights(live: inbound) }
        var stamps: [UUID: Date] = [:]
        for flight in inbound { stamps[flight.id] = max(stamps[flight.id] ?? flight.modifiedAt, flight.modifiedAt) }
        for flight in local {
            if let stamp = stamps[flight.id] { stamps[flight.id] = max(stamp, flight.modifiedAt) }
        }
        var result = InboundFlights(live: [])
        for (id, stamp) in stamps {
            switch deletions.verdict(.flight, id: id, stamp: stamp) {
            case .dead:
                result.dead.insert(id)
            case .alive where deletions.mark(.flight, id: id)?.deletedAt != nil:
                result.revived.insert(id)
            case .alive, .unknown:
                break
            }
        }
        result.live = inbound.filter { !result.dead.contains($0.id) }
        return result
    }

    /// Applies the deletion records here to what a fetch brought (6.1), before it is merged: a dead
    /// copy is dropped, and CloudKit, which still holds it, is owed its delete; a flight brought back
    /// by a later edit has its owed delete withdrawn.
    func applyingDeletionRecords(toInbound inbound: [Flight], local: [Flight]) async -> InboundFlights {
        guard !inbound.isEmpty, let flightDeletionRecords else { return InboundFlights(live: inbound) }
        let result = Self.filterInboundFlights(inbound, local: local, deletions: await flightDeletionRecords())
        for id in result.revived { retractFlightDeletion(id) }
        let owed = owedFlightDeletions
        for id in result.dead.subtracting(owed).sorted(by: { $0.uuidString < $1.uuidString }) { deleteFlight(id) }
        if !result.dead.isEmpty {
            AppLog.sync.publicLine("Dropped \(result.dead.count) deleted flight(s) from a fetch")
        }
        return result
    }

    /// The two records of a flight: its metadata and its separate track.
    private func recordIDs(for flightId: UUID, in zone: CKRecordZone) -> [CKRecord.ID] {
        [CKRecord.ID(recordName: flightId.uuidString, zoneID: zone.zoneID),
         CKRecord.ID(recordName: Self.trackRecordName(flightId), zoneID: zone.zoneID)]
    }

    private func deletions(for flightId: UUID, in zone: CKRecordZone) -> [CKSyncEngine.PendingRecordZoneChange] {
        recordIDs(for: flightId, in: zone).map { .deleteRecord($0) }
    }

    private func saves(for flightId: UUID, in zone: CKRecordZone) -> [CKSyncEngine.PendingRecordZoneChange] {
        recordIDs(for: flightId, in: zone).map { .saveRecord($0) }
    }

    /// The sync currently in flight, so concurrent callers join it instead of starting another. (CQ-06)
    private var inFlightSync: Task<Void, Never>?

    /// Tears the engine down on sign-out, leaving local data untouched. (RES-05)
    ///
    /// Local flights and settings are deliberately NOT deleted: signing out of iCloud must not cost
    /// a pilot their logbook. The data stays on device and re-uploads if they sign back in.
    func stopSyncForSignOut() {
        engineStart?.cancel()
        engineStart = nil
        inFlightSync?.cancel()
        inFlightSync = nil
        catchUpOwed = false
        shutdownSyncEngine()
        clearAccountScopedState()
        isSyncing = false
    }

    /// The engine met the iCloud account (`.signIn`): it is already working on it, so it is kept.
    ///
    /// An engine only runs once the account check said available, and a sign-out tears it down, so
    /// its `.signIn` is its own first start with this account: a fresh install, or the first launch
    /// after a sign-out. 6.1.1 and 6.1.2 restarted the engine here. The state that knows the account
    /// comes after `.signIn`, from the engine just stopped, and was ignored: every new engine started
    /// without it, signed in again and was restarted again, for as long as the app ran, and a fresh
    /// install never finished its first fetch.
    ///
    /// During the start, its first fetch and catch-up cover the account. With the engine already up,
    /// a fetch and the catch-up run now. Not awaited by the delegate: the catch-up waits for the
    /// events handled so far, the one calling here among them.
    func engineSignedIn() async {
        guard isSyncEnabled, syncEngine != nil, engineStart == nil else { return }
        catchUpOwed = true
        await syncNow()
    }

    /// The iCloud account changed (`CKAccountChanged`). With no engine running, sync starts:
    /// signing back in after a sign-out, or an account that wasn't available at launch, used to
    /// wait for the next launch. A running engine reports its own account changes (`.signOut`,
    /// `.switchAccounts`), and `startSync` leaves it alone.
    func accountDidChange() {
        startSync()
    }

    /// Restarts sync on a different account (`.switchAccounts`), discarding the previous account's
    /// state when `clearState`: its server side means every cached token, change tag and fingerprint
    /// is stale. (RES-05)
    func restartSyncForAccountChange(clearState: Bool) {
        stopSync()
        if clearState { clearAccountScopedState() }
        // The catch-up then sends the logbook to the new account: its fingerprints were cleared.
        startSync()
    }

    /// Force a sync now.
    ///
    /// Concurrent callers are **coalesced** onto the in-flight sync rather than each driving the
    /// engine. `syncSettings()` is called from ~28 UI sites and fires this on every settings change,
    /// so two toggles in one interaction — or a settings change racing a manual "Sync Now" — used to
    /// invoke `fetchChanges()`/`sendChanges()` concurrently on the same `CKSyncEngine`. That also
    /// made `isSyncing` unreliable: whichever task finished first cleared it while the other was
    /// still running, so the UI showed sync as complete while it wasn't.
    ///
    /// Awaiting the existing task (rather than returning early) means a caller that awaits
    /// `syncNow()` still observes a completed sync, which an early `return` would have broken.
    func syncNow() async {
        if let existing = inFlightSync {
            await existing.value
            return
        }
        guard isSyncEnabled, syncEngine != nil else { return }

        // Detached, like the engine start (`startSync`): never inside a delegate callback's context.
        let task = Task.detached { @MainActor [weak self] in
            guard let self else { return }
            await self.performSync()
        }
        inFlightSync = task
        await task.value
        inFlightSync = nil
    }

    @MainActor
    private func performSync() async {
        guard isSyncEnabled, let engine = syncEngine else { return }

        isSyncing = true
        syncError = nil

        do {
            try await engine.fetch()
            // The engine came up but its first fetch failed: this one stands in for it.
            if catchUpOwed { await queueWhatCloudKitLacks() }
            try await engine.send()
            lastSyncDate = Date()
            defaults.set(lastSyncDate, forKey: lastSyncDateKey)
            AppLog.sync.publicLine("Manual sync completed")
        } catch {
            syncError = "Sync failed: \(error.localizedDescription)"
            AppLog.sync.debugLine("Manual sync failed: \(error)")
        }

        isSyncing = false
    }

    // MARK: - Record Conversion

    func createSettingsRecord(_ settings: AppSettings) -> CKRecord? {
        guard let recordZone = recordZone else { return nil }
        
        let record: CKRecord
        if let cached = cachedSettingsRecord {
            record = cached
        } else {
            let recordID = CKRecord.ID(recordName: "settings", zoneID: recordZone.zoneID)
            record = CKRecord(recordType: SyncRecordType.settings.rawValue, recordID: recordID)
        }

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(settings)
            record["data"] = data as CKRecordValue
            record["lastModified"] = Date() as CKRecordValue
            
            // Mark that we've created the settings record
            if !settingsRecordExists {
                settingsRecordExists = true
            }
            
            return record
        } catch {
            AppLog.sync.debugLine("Failed to encode settings: \(error)")
            return nil
        }
    }

    /// The recordName of a flight's separate GPS-track record. (sync optimization)
    nonisolated static func trackRecordName(_ id: UUID) -> String { "track-" + id.uuidString }


    /// How a failed record save should be resolved.
    ///
    /// This is the conflict-resolution decision extracted out of `handleSentRecordZoneChanges` as a
    /// pure value, so every branch can be unit-tested without a live `CKSyncEngine`. (CQ-04)
    ///
    /// The decision logic was previously inline, interleaved with `manager?` side effects, and had
    /// zero test coverage — only the pure `Flight.merge` / `validatedForIngest` helpers it calls
    /// were tested. It is the code that decides whether a pilot's edit survives a sync race, so it
    /// is the last place that should be exercised for the first time in production.
    enum SendFailure: Equatable {
        /// The settings record conflicted. Requeue with the server's change tag when we have it,
        /// otherwise drop the pending settings.
        case settingsConflict(hasServerRecord: Bool)
        /// A flight metadata record conflicted. Merge when both sides are available.
        case flightConflict(flightId: UUID, hasServerRecord: Bool)
        /// Permanently oversized. Retrying the identical record is futile, so drop the pending
        /// change. `flightId` is nil for records whose name is not a bare flight UUID.
        case tooLarge(flightId: UUID?)
        /// iCloud storage is full.
        case quotaExceeded
        /// Nothing to do: either a transient error CKSyncEngine will retry with the change still
        /// pending, or a conflict on a record type with no special handling.
        case leavePending
    }

    /// Classifies one `failedRecordSaves` entry. Pure — no CloudKit types, no side effects. (CQ-04)
    ///
    /// - Parameters:
    ///   - errorCode: `NSError.code` of the failure.
    ///   - serverErrorCode: `userInfo["CKErrorServerErrorCode"]`, which surfaces 2004 for a
    ///     server-record-changed conflict that did not set the top-level code.
    ///   - recordName: the failed record's name — `"settings"`, a flight UUID, or a track name.
    ///   - hasServerRecord: whether `CKRecordChangedErrorServerRecordKey` carried a server record.
    nonisolated static func classifySendFailure(
        errorCode: Int,
        serverErrorCode: Int?,
        recordName: String,
        hasServerRecord: Bool
    ) -> SendFailure {
        let isConflict = errorCode == CKError.serverRecordChanged.rawValue || serverErrorCode == 2004
        if isConflict {
            if recordName == "settings" {
                return .settingsConflict(hasServerRecord: hasServerRecord)
            }
            if let flightId = UUID(uuidString: recordName) {
                return .flightConflict(flightId: flightId, hasServerRecord: hasServerRecord)
            }
            // A conflict on a record we do not special-case (e.g. a track record, whose name is not
            // a bare UUID) falls through to the permanent-failure check below, exactly as before.
        }

        switch CKError.Code(rawValue: errorCode) {
        case .limitExceeded:
            return .tooLarge(flightId: UUID(uuidString: recordName))
        case .quotaExceeded:
            return .quotaExceeded
        default:
            return .leavePending
        }
    }
    /// The flightId encoded in a `flightTrack` recordName, or nil if it isn't one.
    nonisolated static func flightId(fromTrackRecordName name: String) -> UUID? {
        guard name.hasPrefix("track-") else { return nil }
        return UUID(uuidString: String(name.dropFirst("track-".count)))
    }

    /// zlib-compress a payload, tagged with a 1-byte marker (0x01) so `zDecompress` can tell a
    /// compressed blob from a legacy raw-JSON one (which starts with `{` = 0x7B). GPS tracks are
    /// verbose JSON arrays that compress ~5–10×, cutting the sync download. (sync optimization)
    nonisolated static func zCompress(_ data: Data) -> Data {
        guard let compressed = try? (data as NSData).compressed(using: .zlib) as Data else { return data }
        var out = Data([0x01])
        out.append(compressed)
        return out
    }

    /// Inverse of `zCompress`. Backward-compatible: a blob without the 0x01 marker (a legacy raw-JSON
    /// record written before compression) is returned unchanged.
    nonisolated static func zDecompress(_ data: Data) -> Data {
        guard data.first == 0x01 else { return data }
        guard let restored = try? (Data(data.dropFirst()) as NSData).decompressed(using: .zlib) as Data else {
            return data
        }
        return restored
    }

    /// Splits a flight into its CloudKit field payloads: the `inline` blob for `record["data"]`
    /// (the full flight when it fits the inline budget, otherwise a track-stripped copy) and, when
    /// the flight is oversized, the `asset` blob (the full flight) to be written to a `CKAsset`.
    /// Both blobs are zlib-compressed; the inline/asset split decision is made on the *uncompressed*
    /// size so it's independent of how well a given track compresses. Pure and side-effect-free so
    /// the size/round-trip behaviour is unit-testable. (PERF-13 / sync optimization)
    nonisolated static func flightRecordPayload(_ flight: Flight) throws -> (inline: Data, asset: Data?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let rawFull = try encoder.encode(flight)
        guard rawFull.count > maxInlineFlightBytes else { return (zCompress(rawFull), nil) }

        var trimmed = flight
        trimmed.gpsTrack = []
        let inline = zCompress(try encoder.encode(trimmed))
        return (inline, zCompress(rawFull))
    }

    /// Reconstructs a flight from its CloudKit field blobs, preferring the asset payload (the
    /// authoritative full flight, with the track) over the track-stripped inline blob. Applies the
    /// same size cap and ingest validation as a directly-decoded record. (PERF-13 / SEC-17)
    nonisolated static func flightFromPayload(inline: Data?, asset: Data?) -> Flight? {
        guard let raw = asset ?? inline else { return nil }
        // Bound the compressed input, then the decompressed output, so neither a huge record nor a
        // zlib "zip bomb" can exhaust memory before we even decode. (SEC-17 / sync optimization)
        guard raw.count <= maxIngestRecordBytes else {
            AppLog.sync.debugLine("Rejecting oversized flight record (\(raw.count) compressed bytes)")
            return nil
        }
        let data = zDecompress(raw)
        guard data.count <= maxIngestRecordBytes else {
            AppLog.sync.debugLine("Rejecting oversized flight record (\(data.count) decompressed bytes)")
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let flight = try? decoder.decode(Flight.self, from: data) else {
            AppLog.sync.debugLine("Failed to decode flight payload")
            return nil
        }
        guard let validated = flight.validatedForIngest() else {
            AppLog.sync.debugLine("Rejecting invalid flight record: \(flight.id)")
            return nil
        }
        return validated
    }

    /// Encodes a flight into a CKRecord. `nonisolated static` (the JSON encode + GPS-track payload is
    /// the expensive part) so the sync-batch path can build records OFF the main actor instead of
    /// inside a `DispatchQueue.main.sync`. (PR-24 / PERF-13)
    /// Rebuilds a `CKRecord` from previously-stored **system fields**, falling back to a fresh record.
    ///
    /// A record decoded from system fields carries the server's `recordChangeTag`, so CloudKit treats
    /// the save as an UPDATE. A freshly-constructed one has no tag and is treated as an INSERT, which
    /// fails with `serverRecordChanged` the moment the record already exists.
    ///
    /// Falls back to a fresh record when there are no stored fields, when they fail to decode, or when
    /// they describe a different `recordID` — a fresh record is exactly the right thing for a genuinely
    /// new flight, so the fallback is correct rather than merely safe.
    nonisolated static func baseRecord(
        recordType: String,
        recordID: CKRecord.ID,
        systemFields: Data?
    ) -> CKRecord {
        if let systemFields,
           let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) {
            coder.requiresSecureCoding = true
            let restored = CKRecord(coder: coder)
            coder.finishDecoding()
            if let restored, restored.recordID == recordID, restored.recordType == recordType {
                return restored
            }
        }
        return CKRecord(recordType: recordType, recordID: recordID)
    }

    /// Archives a record's system fields (identity + change tag only — never its data).
    nonisolated static func encodedSystemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    nonisolated static func buildFlightRecord(
        _ flight: Flight,
        recordID: CKRecord.ID,
        systemFields: Data? = nil
    ) -> CKRecord? {
        let record = baseRecord(
            recordType: SyncRecordType.flight.rawValue, recordID: recordID, systemFields: systemFields)
        do {
            // The GPS track ships in a separate FlightTrack record, so the metadata record is always
            // track-stripped — small enough to stay inline. (sync optimization)
            var metadata = flight
            metadata.gpsTrack = []
            let payload = try flightRecordPayload(metadata)
            if let assetData = payload.asset {
                // Oversized flight: stage the full payload as a file-backed asset and keep only the
                // track-stripped copy inline. If staging the temp file fails, fall back to storing
                // the full payload inline so the GPS track is never silently dropped (it may exceed
                // CloudKit's inline cap, but that's no worse than the pre-asset behaviour). (PERF-13)
                if let url = stageFlightAsset(assetData, flightId: flight.id) {
                    record["dataAsset"] = CKAsset(fileURL: url)
                    record["data"] = payload.inline as CKRecordValue
                } else {
                    record["data"] = assetData as CKRecordValue
                }
            } else {
                record["data"] = payload.inline as CKRecordValue
            }
            record["flightId"] = flight.id.uuidString as CKRecordValue
            record["airplane"] = flight.airplane as CKRecordValue
            record["startTime"] = flight.startTime as CKRecordValue?
            // Queryable conflict-resolution metadata, mirroring the settings record. (ARCH-02)
            record["modifiedAt"] = flight.modifiedAt as CKRecordValue
            record["schemaVersion"] = flight.schemaVersion as CKRecordValue
            return record
        } catch {
            AppLog.sync.debugLine("Failed to encode flight: \(error)")
            return nil
        }
    }

    /// Encodes a flight's GPS track into its own `flightTrack` CKRecord (recordName `track-<id>`).
    /// The blob is the full flight (so the record stands alone on first fetch / as an orphan), but it
    /// is only ever *re-uploaded* when the track point count changes — a metadata edit leaves it put,
    /// so other devices don't re-download the track. `flightFromPayload` decodes it like any flight
    /// and `Flight.merge` folds its (richer) track onto the metadata record. (sync optimization)
    nonisolated static func buildFlightTrackRecord(
        _ flight: Flight,
        recordID: CKRecord.ID,
        systemFields: Data? = nil
    ) -> CKRecord? {
        let record = baseRecord(
            recordType: SyncRecordType.flightTrack.rawValue, recordID: recordID, systemFields: systemFields)
        do {
            let payload = try flightRecordPayload(flight)
            if let assetData = payload.asset {
                if let url = stageFlightAsset(assetData, flightId: flight.id) {
                    record["dataAsset"] = CKAsset(fileURL: url)
                    record["data"] = payload.inline as CKRecordValue
                } else {
                    record["data"] = assetData as CKRecordValue
                }
            } else {
                record["data"] = payload.inline as CKRecordValue
            }
            record["flightId"] = flight.id.uuidString as CKRecordValue
            // The fingerprint the send-side guard confirms, so a track is re-sent only when it grows.
            record["trackCount"] = flight.gpsTrack.count as CKRecordValue
            record["modifiedAt"] = flight.modifiedAt as CKRecordValue
            record["schemaVersion"] = flight.schemaVersion as CKRecordValue
            return record
        } catch {
            AppLog.sync.debugLine("Failed to encode flight track: \(error)")
            return nil
        }
    }

    /// Writes an oversized flight payload to a temp file for use as a `CKAsset` fileURL. CKSyncEngine
    /// reads the file during upload; the OS reclaims the temp directory afterward. Returns nil on a
    /// write failure so the caller can fall back to an inline payload. (PERF-13)
    nonisolated static func stageFlightAsset(_ data: Data, flightId: UUID) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CKFlightAssets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(flightId.uuidString).json")
            // SEC-C27: staged assets carry the same flight data (incl. the full GPS track) as the
            // durable copy, so they get the same at-rest protection — they were written with a bare
            // .atomic, i.e. weaker protection than the file they duplicate.
            try data.write(to: url, options: DataPersistenceManager.protectedWriteOptions)
            return url
        } catch {
            AppLog.sync.debugLine("Failed to stage flight asset: \(error)")
            return nil
        }
    }

    /// Directory holding staged CKAsset payloads awaiting upload. (SEC-C27)
    nonisolated static var stagedAssetsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CKFlightAssets", isDirectory: true)
    }

    /// Removes one staged asset once CloudKit has confirmed its record saved. (SEC-C27)
    nonisolated static func removeStagedFlightAsset(flightId: UUID) {
        let url = stagedAssetsDirectory.appendingPathComponent("\(flightId.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    /// Sweeps staged assets left behind by a previous session — a crash or a permanent upload
    /// failure between staging and confirmation would otherwise leak one file per flight forever.
    /// (SEC-C27)
    nonisolated static func sweepStagedFlightAssets() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: stagedAssetsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        // Anything older than a day cannot belong to an in-flight upload from this session.
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in entries {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }
            try? fm.removeItem(at: url)
        }
    }

    func settingsFromRecord(_ record: CKRecord) -> AppSettings? {
        guard let data = record["data"] as? Data else { return nil }
        // Bound the payload before decoding so a corrupt/oversized record can't exhaust memory. (SEC-17)
        guard data.count <= Self.maxIngestRecordBytes else {
            AppLog.sync.debugLine("Rejecting oversized settings record (\(data.count) bytes)")
            return nil
        }

        do {
            let decoder = JSONDecoder()
            // Clamp flight-relevant numerics to sane ranges before applying. (SEC-17)
            return try decoder.decode(AppSettings.self, from: data).clampedForIngest()
        } catch {
            AppLog.sync.debugLine("Failed to decode settings: \(error)")
            return nil
        }
    }

    func flightFromRecord(_ record: CKRecord) async -> Flight? {
        // Prefer the file-backed asset (full flight, with track) over the inline blob (which is
        // track-stripped for oversized flights). CKSyncEngine downloads the asset before delivering
        // the record, so its fileURL is readable here. (PERF-13 / SEC-17)
        // The asset disk read + JSON decode of a long flight's GPS track is heavy; run it off the
        // main actor so a large incoming flight doesn't hitch the UI during sync. Inputs are Sendable
        // value types and Flight is Sendable, mirroring the off-main encode on the send side. (v4.0.0
        // review P1)
        let inline = record["data"] as? Data
        let assetURL = (record["dataAsset"] as? CKAsset)?.fileURL
        return await Task.detached(priority: .utility) {
            var assetData: Data?
            if let url = assetURL { assetData = try? Data(contentsOf: url) }
            return Self.flightFromPayload(inline: inline, asset: assetData)
        }.value
    }

    // MARK: - Pending Changes Access

    func getPendingSettings() -> AppSettings? {
        return pendingSettingsChange
    }

    /// The settings record was confirmed (or dropped): nothing is owed any more.
    func clearPendingSettings() {
        pendingSettingsChange = nil
        settingsOwed = false
    }

    /// The server holds a settings record already (a conflict told us).
    func markSettingsRecordExists() {
        settingsRecordExists = true
        defaults.set(true, forKey: settingsRecordExistsKey)
    }

    func getPendingFlight(for id: UUID) -> Flight? {
        return pendingFlights[id]
    }

    func clearPendingFlight(_ id: UUID) {
        pendingFlights.removeValue(forKey: id)
    }

    /// CloudKit confirmed the delete, or the record is gone anyway.
    func clearPendingFlightDeletion(_ id: UUID) {
        guard owedFlightDeletions.contains(id) else { return }
        owedFlightDeletions.remove(id)
    }

    /// Record a flight's confirmed-synced metadata fingerprint in memory (caller persists once per
    /// batch via `persistSyncedFingerprints()`), so the metadata record is skipped next time it's
    /// unchanged. (sync optimization)
    func markFlightSynced(_ id: UUID, modifiedAt: Date) {
        lastSyncedModifiedAt[id.uuidString] = modifiedAt
    }

    /// Record a flight's confirmed-synced track fingerprint, so the (large) track record is skipped
    /// next time the track is unchanged. (sync optimization)
    func markFlightTrackSynced(_ id: UUID, count: Int) {
        lastSyncedTrackCount[id.uuidString] = count
    }

    /// Drop a deleted flight's fingerprints (+ persist) so a future flight reusing the id re-uploads.
    func unmarkFlightSynced(_ id: UUID) {
        let hadMeta = lastSyncedModifiedAt.removeValue(forKey: id.uuidString) != nil
        let hadTrack = lastSyncedTrackCount.removeValue(forKey: id.uuidString) != nil
        if hadMeta || hadTrack { persistSyncedFingerprints() }
    }

    func persistSyncedFingerprints() {
        if let data = try? JSONEncoder().encode(lastSyncedModifiedAt) {
            defaults.set(data, forKey: lastSyncedModifiedAtKey)
        }
        if let data = try? JSONEncoder().encode(lastSyncedTrackCount) {
            defaults.set(data, forKey: lastSyncedTrackCountKey)
        }
    }

    /// Applies a conflict-merged flight to local state and re-queues it so the cloud converges on
    /// the merged result. Best-effort CloudKit conflict resolution. (ARCH-02)
    func resolveFlightConflict(_ merged: Flight) async {
        var flights = DataPersistenceManager.shared.loadFlights()
        if let index = flights.firstIndex(where: { $0.id == merged.id }) {
            flights[index] = merged
        } else {
            flights.append(merged)
        }
        await onFlightsUpdated?(flights)
        syncFlight(merged, allFlights: flights)
    }

    // MARK: - Record system fields (change-tag preservation)

    /// Stored system fields for a record name, if the server has acknowledged it before.
    func systemFields(forRecordName recordName: String) -> Data? {
        recordSystemFields[recordName]
    }

    /// Remembers a server-acknowledged record's identity + change tag.
    ///
    /// Called both when a save succeeds and when a conflict hands back the SERVER's record — the
    /// latter matters most, because it is what lets the retry after a conflict actually converge
    /// instead of re-sending another tag-less insert.
    func rememberSystemFields(of record: CKRecord) {
        recordSystemFields[record.recordID.recordName] = SyncManager.encodedSystemFields(of: record)
        persistRecordSystemFields()
    }

    /// Drops the stored fields for a flight and its track record — the record no longer exists
    /// server-side, so a later flight reusing the id must be sent as a genuine insert.
    func forgetSystemFields(forFlight id: UUID) {
        recordSystemFields.removeValue(forKey: id.uuidString)
        recordSystemFields.removeValue(forKey: SyncManager.trackRecordName(id))
        persistRecordSystemFields()
    }

    private func persistRecordSystemFields() {
        defaults.set(recordSystemFields, forKey: recordSystemFieldsKey)
    }

    /// Update last sync date (called when sync operations complete)
    func updateLastSyncDate() {
        lastSyncDate = Date()
        defaults.set(lastSyncDate, forKey: lastSyncDateKey)
    }
}

// MARK: - CKSyncEngineDelegate

@MainActor
class SyncEngineDelegate: NSObject, CKSyncEngineDelegate {
    private weak var manager: SyncManager?

    init(manager: SyncManager) {
        self.manager = manager
        super.init()
    }

    /// The last event handed to the main actor. Each event waits for the one before it.
    ///
    /// The engine delivers events in order, but each used to become an independent main-actor task,
    /// and those interleave at every `await` (decoding a fetched batch awaits): a later event could
    /// be applied before an earlier one, and nothing could tell when a fetch had been applied. The
    /// catch-up after the first fetch needs exactly that (`eventsHandled`).
    private nonisolated let eventLock = NSLock()
    private nonisolated(unsafe) var lastEvent: Task<Void, Never>?

    /// Hands the event to the main actor, after the one before it. Detached, so nothing the event
    /// leads to (an engine restart, Sync Now) carries the callback's context into an await on the
    /// engine, which iOS 27 traps (`SyncManager.startSync`).
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        eventLock.withLock {
            let previous = lastEvent
            lastEvent = Task.detached { @MainActor in
                await previous?.value
                await self.handleEventAsync(event, syncEngine: syncEngine)
            }
        }
    }

    /// Returns once every event delivered so far has been handled.
    func eventsHandled() async {
        let last = eventLock.withLock { lastEvent }
        await last?.value
    }

    @MainActor
    private func handleEventAsync(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // An engine the switch (or an account change) has stopped may still deliver what it had
        // under way. Its state and its changes belong to no running engine: the next one resumes
        // from the state saved before, and fetches them again.
        guard manager?.isCurrent(self) == true else {
            AppLog.sync.publicLine("Ignoring an event from a stopped sync engine")
            return
        }
        switch event {
        case .stateUpdate(let stateUpdate):
            // Save the sync state for resuming later
            manager?.saveSyncState(stateUpdate.stateSerialization)

        case .accountChange(let accountChange):
            handleAccountChange(accountChange)

        case .fetchedDatabaseChanges(let fetchedChanges):
            handleDatabaseChanges(fetchedChanges)

        case .fetchedRecordZoneChanges(let fetchedChanges):
            await handleRecordZoneChanges(fetchedChanges, syncEngine: syncEngine)

        case .sentDatabaseChanges(let sentChanges):
            handleSentDatabaseChanges(sentChanges)

        case .sentRecordZoneChanges(let sentChanges):
            await handleSentRecordZoneChanges(sentChanges)

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .willSendChanges, .didSendChanges, .didFetchChanges:
            // Informational events - no action needed
            break

        @unknown default:
            AppLog.sync.debugLine("Unknown event type")
        }
    }

    /// Gathered, ready-to-encode contents of one pending batch. `flights` are Sendable value types;
    /// the small settings record is built on the main actor (it has main-actor side effects), the
    /// expensive flight encoding happens off-main. (PR-24)
    private struct PendingBatch {
        /// `systemFields` is the record's stored identity + change tag, read on the main actor while
        /// gathering so the off-main encoder below stays free of main-actor state.
        let flightRecordIDs: [(flight: Flight, recordID: CKRecord.ID, systemFields: Data?)]
        let trackRecordIDs: [(flight: Flight, recordID: CKRecord.ID, systemFields: Data?)]
        let settingsRecord: CKRecord?
        let deletions: [CKRecord.ID]
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) -> CKSyncEngine.RecordZoneChangeBatch? {
        // CKSyncEngine calls this synchronously on its OWN (background) thread. We hop to the main
        // actor only to *gather* the pending data (cheap: copies Flight value types + builds the
        // small settings record), then release the main thread and do the expensive flight-record
        // encoding (JSON + full GPS tracks) here off-main — so a sync push during an active flight
        // no longer encodes large tracks inside a main-thread `DispatchQueue.main.sync`. (PR-24)
        var pending: PendingBatch?
        DispatchQueue.main.sync {
            pending = self.gatherPendingBatch(syncEngine: syncEngine)
        }
        guard let pending else { return nil }

        var recordsToSave: [CKRecord] = []
        if let settingsRecord = pending.settingsRecord {
            recordsToSave.append(settingsRecord)
        }
        for entry in pending.flightRecordIDs {
            if let record = SyncManager.buildFlightRecord(
                entry.flight, recordID: entry.recordID, systemFields: entry.systemFields) {
                recordsToSave.append(record)
            }
        }
        for entry in pending.trackRecordIDs {
            if let record = SyncManager.buildFlightTrackRecord(
                entry.flight, recordID: entry.recordID, systemFields: entry.systemFields) {
                recordsToSave.append(record)
            }
        }

        guard !recordsToSave.isEmpty || !pending.deletions.isEmpty else {
            return nil
        }

        return CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: recordsToSave,
            recordIDsToDelete: pending.deletions,
            atomicByZone: true
        )
    }

    /// Gathers the pending changes on the main actor without encoding any flight track. Pairs each
    /// pending flight with its (zone-scoped) record id so the caller can encode off-main. (PR-24)
    @MainActor
    private func gatherPendingBatch(syncEngine: CKSyncEngine) -> PendingBatch? {
        guard let manager = manager else { return nil }

        let pendingChanges = syncEngine.state.pendingRecordZoneChanges

        var flightRecordIDs: [(flight: Flight, recordID: CKRecord.ID, systemFields: Data?)] = []
        var trackRecordIDs: [(flight: Flight, recordID: CKRecord.ID, systemFields: Data?)] = []
        var settingsRecord: CKRecord?
        var deletions: [CKRecord.ID] = []
        var processedSettingsRecord = false

        for change in pendingChanges {
            switch change {
            case .saveRecord(let recordID):
                if recordID.recordName == "settings" {
                    if !processedSettingsRecord,
                       let settings = manager.getPendingSettings(),
                       let record = manager.createSettingsRecord(settings) {
                        settingsRecord = record
                        processedSettingsRecord = true
                    }
                } else if let flightId = SyncManager.flightId(fromTrackRecordName: recordID.recordName),
                          let flight = manager.getPendingFlight(for: flightId) {
                    trackRecordIDs.append(
                        (flight, recordID, manager.systemFields(forRecordName: recordID.recordName)))
                } else if let flightId = UUID(uuidString: recordID.recordName),
                          let flight = manager.getPendingFlight(for: flightId) {
                    flightRecordIDs.append(
                        (flight, recordID, manager.systemFields(forRecordName: recordID.recordName)))
                }

            case .deleteRecord(let recordID):
                deletions.append(recordID)

            @unknown default:
                break
            }
        }

        return PendingBatch(
            flightRecordIDs: flightRecordIDs,
            trackRecordIDs: trackRecordIDs,
            settingsRecord: settingsRecord,
            deletions: deletions
        )
    }

    // MARK: - Event Handlers

    @MainActor
    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        // RES-05: every case here used to be a bare log line. The engine, container and database
        // built against the OLD account were never torn down, and account-scoped local state — the
        // persisted sync-state serialization, the cached settings record's change tag, and the
        // confirmed-sent fingerprint maps — was carried straight into the new account, where it is
        // wrong in a way that fails silently rather than loudly. This matters here specifically
        // because the app runs on shared aeroclub hardware, where account switching is routine.
        switch change.changeType {
        case .signIn:
            AppLog.sync.publicLine("Sync engine signed into iCloud — keeping it")
            // Detached and not awaited (`engineSignedIn`).
            let manager = self.manager
            Task.detached { await manager?.engineSignedIn() }
        case .signOut:
            AppLog.sync.publicLine("User signed out of iCloud — tearing down sync engine")
            manager?.stopSyncForSignOut()
        case .switchAccounts:
            AppLog.sync.publicLine("iCloud account switched — resetting sync state")
            manager?.restartSyncForAccountChange(clearState: true)
        @unknown default:
            break
        }
    }

    @MainActor
    private func handleDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
        for deletion in changes.deletions {
            AppLog.sync.debugLine("Zone deleted: \(deletion.zoneID.zoneName)")
        }
    }

    @MainActor
    private func handleRecordZoneChanges(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async {
        var deletedFlightIds: [UUID] = []
        var deletedZoneIDs: [UUID: CKRecordZone.ID] = [:]

        // Settings records are handled inline on the main actor (cheap). Flight records are decoded
        // CONCURRENTLY off the main actor below — their asset disk read + GPS-track JSON decode is the
        // expensive part, and decoding 50+ inbound flights serially is what made the initial sync slow.
        var flightPayloads: [(inline: Data?, assetURL: URL?)] = []
        // The server fingerprints of records we just RECEIVED, so we can mark them synced and not echo
        // them straight back up on the next syncAllFlights. (sync optimization)
        var receivedMeta: [UUID: Date] = [:]
        var receivedTrack: [UUID: Int] = [:]
        for modification in changes.modifications {
            let record = modification.record
            switch record.recordType {
            case SyncRecordType.settings.rawValue:
                if let settings = manager?.settingsFromRecord(record) {
                    manager?.cachedSettingsRecord = record   // preserve the change tag
                    AppLog.sync.debugLine("Received settings update from cloud")
                    await manager?.onSettingsUpdated?(settings)
                }
            case SyncRecordType.flight.rawValue:
                // The track-stripped metadata record. Pull the Sendable payload on the main actor;
                // decode it off-main below. (sync optimization)
                flightPayloads.append((record["data"] as? Data, (record["dataAsset"] as? CKAsset)?.fileURL))
                if let id = UUID(uuidString: record.recordID.recordName), let m = record["modifiedAt"] as? Date {
                    receivedMeta[id] = m
                }
            case SyncRecordType.flightTrack.rawValue:
                // The separate track record. It also decodes to a Flight; the merge loop folds its
                // (richer) track onto the metadata record, so a track that arrives before/after its
                // metadata still lands. (sync optimization)
                flightPayloads.append((record["data"] as? Data, (record["dataAsset"] as? CKAsset)?.fileURL))
                if let id = SyncManager.flightId(fromTrackRecordName: record.recordID.recordName),
                   let c = record["trackCount"] as? Int {
                    receivedTrack[id] = c
                }
            default:
                break
            }
        }

        // Decode the inbound flights concurrently off the main actor (asset read + track JSON decode).
        let decodedFlights: [Flight] = await withTaskGroup(of: Flight?.self) { group in
            for payload in flightPayloads {
                group.addTask {
                    var assetData: Data?
                    if let url = payload.assetURL { assetData = try? Data(contentsOf: url) }
                    return SyncManager.flightFromPayload(inline: payload.inline, asset: assetData)
                }
            }
            var decoded: [Flight] = []
            for await flight in group { if let flight { decoded.append(flight) } }
            return decoded
        }

        for deletion in changes.deletions {
            if deletion.recordType == SyncRecordType.flight.rawValue,
               let flightId = UUID(uuidString: deletion.recordID.recordName) {
                AppLog.sync.debugLine("Flight deleted from cloud: \(flightId)")
                deletedFlightIds.append(flightId)
                deletedZoneIDs[flightId] = deletion.recordID.zoneID
            }
        }

        // RES-04: a deletion from another device must also cancel THIS device's own queued edit for
        // the same flight. Removing it from local state is not enough — an unsent `.saveRecord` still
        // sitting in the engine's pending changes (e.g. the edit was made offline) is sent on the next
        // sendChanges() and re-creates the record server-side, so the flight the pilot deleted
        // reappears on every device. Both records matter: the metadata record and the separate track
        // record are each resurrected by the same mechanism.
        for flightId in deletedFlightIds {
            manager?.clearPendingFlight(flightId)
            // Deleted already: a delete this device still owes for it has nothing left to do.
            manager?.clearPendingFlightDeletion(flightId)
            // The records are gone server-side: a later flight reusing this id must be a real insert,
            // and CloudKit no longer holds a copy for a deletion record to delete (6.1).
            manager?.forgetSystemFields(forFlight: flightId)
            manager?.unmarkFlightSynced(flightId)
            guard let zoneID = deletedZoneIDs[flightId] else { continue }
            syncEngine.state.remove(pendingRecordZoneChanges: [
                .saveRecord(CKRecord.ID(recordName: flightId.uuidString, zoneID: zoneID)),
                .saveRecord(CKRecord.ID(recordName: SyncManager.trackRecordName(flightId), zoneID: zoneID)),
            ])
        }

        // Notify about flight updates
        if !decodedFlights.isEmpty || !deletedFlightIds.isEmpty {
            // Load the current set OFF the main actor (decoding a 50-flight logbook is heavy); merge on
            // the main actor where the conflict callback runs. The persistence write is batched off-main
            // in the onFlightsUpdated handler, not per-flight on the main actor.
            var currentFlights = await DataPersistenceManager.shared.loadFlightsOffMain()

            // Deletion records (6.1), before the merge: a copy of a flight deleted here and not edited
            // since (deleted with the switch off, its delete not sent yet) is dropped, or the fetch
            // would bring it back. An edit made after the deletion still comes through.
            let inbound = await manager?.applyingDeletionRecords(toInbound: decodedFlights, local: currentFlights)
                ?? SyncManager.InboundFlights(live: decodedFlights)
            let updatedFlights = inbound.live
            // The copies CloudKit deleted, with this device's stamp, for their deletion records.
            let deletedHere = deletedFlightIds.map { id in
                (id: id, stamp: currentFlights.first { $0.id == id }?.modifiedAt)
            }

            // Apply updates. Merge rather than blindly overwrite, so a concurrent local edit (or a
            // longer locally-recorded track) is never silently dropped by an inbound record. (ARCH-02)
            for flight in updatedFlights {
                if let index = currentFlights.firstIndex(where: { $0.id == flight.id }) {
                    let local = currentFlights[index]
                    let merged = Flight.merge(local, flight)
                    currentFlights[index] = merged
                    // If both sides had been edited (neither modifiedAt strictly dominates by a
                    // clear margin and content differs), tell the UI the conflict was auto-merged.
                    if local.modifiedAt != flight.modifiedAt,
                       local.notes != flight.notes || local.name != flight.name {
                        manager?.onSyncConflict?("A flight edited on another device was merged.")
                    }
                } else {
                    currentFlights.append(flight)
                }
            }

            // Apply deletions
            currentFlights.removeAll { deletedFlightIds.contains($0.id) }

            // Sort by start time (newest first)
            currentFlights.sort { ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast) }

            await manager?.onFlightsUpdated?(currentFlights)

            // A device that deleted with CloudKit but no iCloud Drive leaves no record here: one is
            // written now, unless the deleting device's own record came first (6.1).
            if !deletedHere.isEmpty { manager?.onFlightsDeletedInCloudKit?(deletedHere) }

            // Mark the just-received records as synced so the next syncAllFlights doesn't echo all of
            // them — including the large track records — back up to the server. Marking with the
            // SERVER's fingerprints is safe: if a local copy is actually richer (merge kept a longer
            // local track), its count/modifiedAt won't match and it still re-uploads. (sync optimization)
            // A dropped dead copy is not marked: its delete is owed, and the fingerprint is gone with it.
            receivedMeta = receivedMeta.filter { !inbound.dead.contains($0.key) }
            receivedTrack = receivedTrack.filter { !inbound.dead.contains($0.key) }
            if !receivedMeta.isEmpty || !receivedTrack.isEmpty {
                for (id, m) in receivedMeta { manager?.markFlightSynced(id, modifiedAt: m) }
                for (id, c) in receivedTrack { manager?.markFlightTrackSynced(id, count: c) }
                manager?.persistSyncedFingerprints()
            }

            // Update last sync date when we receive changes
            manager?.updateLastSyncDate()
        }
    }

    @MainActor
    private func handleSentDatabaseChanges(_ changes: CKSyncEngine.Event.SentDatabaseChanges) {
        for zone in changes.savedZones {
            AppLog.sync.debugLine("Zone saved: \(zone.zoneID.zoneName)")
        }

        if !changes.failedZoneSaves.isEmpty {
            AppLog.sync.debugLine("Failed to save \(changes.failedZoneSaves.count) zones")
        }
    }

    @MainActor
    private func handleSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) async {
        AppLog.sync.debugLine("Saved \(changes.savedRecords.count) records, deleted \(changes.deletedRecordIDs.count)")

        // Clear pending data for successfully saved records
        var didMarkSynced = false
        for record in changes.savedRecords {
            // The server has acknowledged this record — keep its change tag so the NEXT save is an
            // update rather than an insert that collides with itself. (CloudKit change-tag fix)
            manager?.rememberSystemFields(of: record)
            if record.recordID.recordName == "settings" {
                manager?.clearPendingSettings()
                manager?.cachedSettingsRecord = record // Update cache with new change tag
            } else if record.recordType == SyncRecordType.flight.rawValue {
                // SEC-C27: the staged CKAsset temp file has served its purpose. Nothing ever
                // removed these, so one unreclaimed copy of every long flight's track accumulated
                // in tmp/CKFlightAssets indefinitely.
                if let id = UUID(uuidString: record.recordID.recordName) {
                    SyncManager.removeStagedFlightAsset(flightId: id)
                }
            } else if record.recordType == SyncRecordType.flightTrack.rawValue {
                // Track record confirmed → fingerprint its point count so it isn't re-sent unchanged.
                if let id = SyncManager.flightId(fromTrackRecordName: record.recordID.recordName),
                   let count = record["trackCount"] as? Int {
                    manager?.markFlightTrackSynced(id, count: count)
                    didMarkSynced = true
                    manager?.clearPendingFlight(id)
                }
            } else if let flightId = UUID(uuidString: record.recordID.recordName) {
                // Metadata record confirmed → fingerprint modifiedAt so it's skipped while unchanged.
                if let modAt = record["modifiedAt"] as? Date {
                    manager?.markFlightSynced(flightId, modifiedAt: modAt)
                    didMarkSynced = true
                }
                manager?.clearPendingFlight(flightId)
            }
        }
        if didMarkSynced { manager?.persistSyncedFingerprints() }

        // Clear pending deletions for successfully deleted records
        for recordID in changes.deletedRecordIDs {
            if let flightId = UUID(uuidString: recordID.recordName) {
                manager?.clearPendingFlightDeletion(flightId)
                // CloudKit holds no copy any more. Unmarked when the delete was queued already; a copy
                // a later edit brought back meanwhile is then sent again by the next catch-up (6.1).
                manager?.unmarkFlightSynced(flightId)
            }
        }
        // A delete sent again (it was owed) for a record already gone has nothing left to do; any
        // other failure keeps it owed, for the engine's own retry or the next start.
        for (recordID, error) in changes.failedRecordDeletes where error.code == .unknownItem {
            if let flightId = UUID(uuidString: recordID.recordName) {
                manager?.clearPendingFlightDeletion(flightId)
            }
        }

        // Update last sync date if any changes were made
        if !changes.savedRecords.isEmpty || !changes.deletedRecordIDs.isEmpty {
            manager?.updateLastSyncDate()
        }

        for failedSave in changes.failedRecordSaves {
            let recordName = failedSave.record.recordID.recordName
            let error = failedSave.error
            let nsError = error as NSError
            let serverRecord = nsError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord

            // The decision itself is pure and unit-tested; this switch only performs it. (CQ-04)
            switch SyncManager.classifySendFailure(
                errorCode: nsError.code,
                serverErrorCode: nsError.userInfo["CKErrorServerErrorCode"] as? Int,
                recordName: recordName,
                hasServerRecord: serverRecord != nil
            ) {
            case .settingsConflict:
                // The record already exists server-side, which is fine — adopt its change tag.
                AppLog.sync.debugLine("Settings record conflict detected. Updating cache from server record.")
                manager?.markSettingsRecordExists()

                if let serverRecord {
                    manager?.cachedSettingsRecord = serverRecord
                    // Re-queue the sync immediately with the updated change tag
                    if let pendingSettings = manager?.getPendingSettings() {
                        AppLog.sync.debugLine("Re-queueing settings sync with updated change tag")
                        manager?.syncSettings(pendingSettings)
                    }
                } else {
                    manager?.clearPendingSettings()
                }
                manager?.updateLastSyncDate()
                continue

            case .flightConflict(let flightId, _):
                // Another device's edit won the race. Merge the server record with our pending local
                // flight and re-queue rather than dropping the local edit (which used to diverge the
                // devices permanently). (ARCH-02)
                // Adopt the SERVER's change tag before doing anything else. Without this the merge
                // below re-queues another tag-less record and the conflict repeats forever — the
                // retry could never converge, which is what made a failing flight never sync at all.
                if let serverRecord { manager?.rememberSystemFields(of: serverRecord) }

                if let serverRecord,
                   let serverFlight = await manager?.flightFromRecord(serverRecord),
                   let localFlight = manager?.getPendingFlight(for: flightId) {
                    let merged = Flight.merge(localFlight, serverFlight)
                    await manager?.resolveFlightConflict(merged)
                    manager?.onSyncConflict?("A flight edited on two devices was merged.")
                } else {
                    // Can't merge — keep the cloud version rather than overwrite it, and surface
                    // the conflict instead of silently dropping it.
                    manager?.clearPendingFlight(flightId)
                    manager?.onSyncConflict?(
                        "A flight sync conflict couldn't be auto-merged; the cloud version was kept."
                    )
                }
                manager?.updateLastSyncDate()
                continue

            case .tooLarge(let flightId):
                // Record still too large even after the GPS track was offloaded to a CKAsset.
                // Retrying the identical record is futile — drop the pending change and surface it.
                if let flightId { manager?.clearPendingFlight(flightId) }
                manager?.onSyncConflict?("A flight was too large to sync to iCloud and was skipped.")

            case .quotaExceeded:
                manager?.onSyncConflict?("iCloud storage is full — a flight couldn't be synced.")

            case .leavePending:
                // CKSyncEngine auto-retries transient errors (network, server busy, rate limit) and
                // keeps the change pending, so the pending flight is left untouched and the retry
                // still has its data. (PERF-13)
                break
            }

            AppLog.sync.debugLine("Failed to save record: \(recordName), error: \(error)")
        }
    }
}
