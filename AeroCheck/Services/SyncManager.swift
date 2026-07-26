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

/// Manages iCloud sync using CKSyncEngine (iOS 17+)
@MainActor
class SyncManager: ObservableObject {
    // MARK: - Singleton

    static let shared = SyncManager()

    // MARK: - Published Properties

    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var syncError: String?
    @Published var isSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isSyncEnabled, forKey: syncEnabledKey)
            if isSyncEnabled {
                initializeSyncEngine()
            } else {
                shutdownSyncEngine()
            }
        }
    }

    // MARK: - CloudKit Configuration

    private let containerIdentifier = "iCloud.com.fetzu.aerocheck"
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

    private var container: CKContainer?
    private var database: CKDatabase?
    private var syncEngine: CKSyncEngine?
    private var syncEngineDelegate: SyncEngineDelegate?
    private var recordZone: CKRecordZone?

    /// Whether CloudKit is available (entitlements configured)
    private var isCloudKitAvailable: Bool = false

    /// Callback when settings are updated from sync
    var onSettingsUpdated: ((AppSettings) -> Void)?

    /// Callback when flights are updated from sync
    var onFlightsUpdated: (([Flight]) -> Void)?

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
    private var pendingFlightDeletions: Set<UUID> = []

    /// Cached settings record to preserve change tag for updates
    var cachedSettingsRecord: CKRecord? {
        get {
            guard let data = UserDefaults.standard.data(forKey: settingsRecordKey) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
        }
        set {
            if let record = newValue,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: settingsRecordKey)
            }
        }
    }

    // MARK: - Initialization

    private init() {
        // SEC-C27: reclaim staged CKAsset payloads orphaned by a previous session (crash, or a
        // permanently-failed upload). Cheap, off the hot path, and bounded by an age cutoff so it
        // can never touch an upload in progress.
        Task.detached(priority: .utility) { SyncManager.sweepStagedFlightAssets() }

        // Load sync preference (default to enabled)
        self.isSyncEnabled = UserDefaults.standard.object(forKey: syncEnabledKey) as? Bool ?? true

        // Load last sync date
        self.lastSyncDate = UserDefaults.standard.object(forKey: lastSyncDateKey) as? Date

        // Load whether settings record exists on server
        self.settingsRecordExists = UserDefaults.standard.bool(forKey: settingsRecordExistsKey)

        // Load the synced-flight fingerprint maps (skip-unchanged guards for the send side)
        if let data = UserDefaults.standard.data(forKey: lastSyncedModifiedAtKey),
           let map = try? JSONDecoder().decode([String: Date].self, from: data) {
            self.lastSyncedModifiedAt = map
        }
        if let data = UserDefaults.standard.data(forKey: lastSyncedTrackCountKey),
           let map = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.lastSyncedTrackCount = map
        }
        self.recordSystemFields =
            UserDefaults.standard.dictionary(forKey: recordSystemFieldsKey) as? [String: Data] ?? [:]

        // Defer CloudKit initialization to avoid blocking app startup
        // Use detached task with low priority to not compete with UI rendering
        if isSyncEnabled {
            Task.detached(priority: .utility) { [weak self] in
                await self?.initializeCloudKitWithTimeout()
            }
        }
    }

    /// Initialize CloudKit with a timeout to prevent blocking app startup
    private func initializeCloudKitWithTimeout() async {
        // Use a timeout to prevent indefinite blocking on poor network
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            return false
        }

        let initTask = Task { () -> Bool in
            await initializeCloudKit()
            return true
        }

        // Wait for whichever completes first
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await initTask.value }
            group.addTask { await timeoutTask.value }

            if let result = await group.next() {
                group.cancelAll()
                return result
            }
            return false
        }

        if !completed {
            AppLog.sync.debugLine("CloudKit initialization timed out - will retry later")
        }
    }

    /// Initialize CloudKit container safely
    private func initializeCloudKit() async {
        do {
            // Try to create the container - this will fail if entitlements aren't configured
            let testContainer = CKContainer(identifier: containerIdentifier)

            // Check if we can access the account status (this validates the configuration)
            let status = try await testContainer.accountStatus()

            // If we get here, CloudKit is available
            self.container = testContainer
            self.database = testContainer.privateCloudDatabase
            self.recordZone = CKRecordZone(zoneName: zoneName)
            self.isCloudKitAvailable = true

            AppLog.sync.debugLine("CloudKit initialized successfully, account status: \(status)")

            if status == .available {
                initializeSyncEngine()
            } else {
                syncError = "iCloud account not available"
                AppLog.sync.debugLine("iCloud account not available: \(status)")
            }
        } catch {
            isCloudKitAvailable = false
            syncError = "CloudKit not configured"
            AppLog.sync.debugLine("CloudKit not available: \(error.localizedDescription)")
            AppLog.sync.debugLine("To enable iCloud sync, configure CloudKit in Xcode's Signing & Capabilities")
        }
    }

    // MARK: - Sync Engine Lifecycle

    private func initializeSyncEngine() {
        guard syncEngine == nil, isCloudKitAvailable else { return }
        guard let container = container, let database = database else {
            AppLog.sync.debugLine("Cannot initialize sync engine: CloudKit not available")
            return
        }

        Task {
            do {
                // Check iCloud account status
                let status = try await container.accountStatus()
                guard status == .available else {
                    syncError = "iCloud account not available"
                    AppLog.sync.debugLine("iCloud account not available: \(status)")
                    return
                }

                // Load persisted sync state
                let state = loadSyncState()

                // Create sync engine configuration
                let configuration = CKSyncEngine.Configuration(
                    database: database,
                    stateSerialization: state,
                    delegate: createDelegate()
                )

                // Initialize the sync engine
                let engine = CKSyncEngine(configuration)
                self.syncEngine = engine

                AppLog.sync.debugLine("Sync engine initialized")

                // Ensure zone exists
                await ensureZoneExists()

                // Pull existing records on launch. CKSyncEngine only auto-syncs to SEND pending local
                // changes (and to fetch in response to a remote push); a fresh install has an empty
                // local store and nothing to send, so without this explicit fetch the logbook stays
                // empty until a push happens to arrive — or the user taps Sync Now. (fresh-install fix)
                await performInitialFetch(using: engine)

            } catch {
                syncError = "Failed to initialize sync: \(error.localizedDescription)"
                AppLog.sync.debugLine("Failed to initialize: \(error)")
            }
        }
    }

    /// One-shot fetch when the engine comes up, so records that already exist on the server (e.g. a
    /// logbook synced from another device, or this device's own pre-reinstall data) land without
    /// waiting for a remote push or a manual Sync Now. (fresh-install fix)
    private func performInitialFetch(using engine: CKSyncEngine) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await engine.fetchChanges()
            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: lastSyncDateKey)
            AppLog.sync.debugLine("Initial fetch on launch completed")
        } catch {
            AppLog.sync.debugLine("Initial fetch on launch failed: \(error)")
        }
    }

    private func shutdownSyncEngine() {
        syncEngine = nil
        syncEngineDelegate = nil
        AppLog.sync.debugLine("Sync engine shutdown")
    }

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
        UserDefaults.standard.removeObject(forKey: syncStateKey)
        UserDefaults.standard.removeObject(forKey: settingsRecordKey)
        UserDefaults.standard.removeObject(forKey: settingsRecordExistsKey)
        UserDefaults.standard.removeObject(forKey: lastSyncedModifiedAtKey)
        UserDefaults.standard.removeObject(forKey: lastSyncedTrackCountKey)
        UserDefaults.standard.removeObject(forKey: recordSystemFieldsKey)
        UserDefaults.standard.removeObject(forKey: lastSyncDateKey)

        settingsRecordExists = false
        lastSyncedModifiedAt = [:]
        lastSyncedTrackCount = [:]
        recordSystemFields = [:]
        lastSyncDate = nil
        pendingSettingsChange = nil
        pendingFlights = [:]
        pendingFlightDeletions = []
        AppLog.sync.debugLine("Cleared account-scoped sync state")
    }

    private func createDelegate() -> SyncEngineDelegate {
        let delegate = SyncEngineDelegate(manager: self)
        self.syncEngineDelegate = delegate
        return delegate
    }

    // MARK: - Zone Management

    private func ensureZoneExists() async {
        guard let engine = syncEngine, let recordZone = recordZone else { return }

        // Add pending zone creation
        engine.state.add(pendingDatabaseChanges: [.saveZone(recordZone)])
    }

    // MARK: - State Persistence

    private func loadSyncState() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: syncStateKey) else {
            return nil
        }

        do {
            let state = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            AppLog.sync.debugLine("Loaded sync state")
            return state
        } catch {
            AppLog.sync.debugLine("Failed to load sync state: \(error)")
            return nil
        }
    }

    func saveSyncState(_ state: CKSyncEngine.State.Serialization) {
        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: syncStateKey)
        } catch {
            AppLog.sync.debugLine("Failed to save sync state: \(error)")
        }
    }

    // MARK: - Sync Operations

    /// Sync settings to iCloud
    func syncSettings(_ settings: AppSettings) {
        guard isSyncEnabled, let engine = syncEngine, let recordZone = recordZone else { return }

        pendingSettingsChange = settings

        let recordID = CKRecord.ID(recordName: "settings", zoneID: recordZone.zoneID)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

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
        if !changes.isEmpty { pendingFlights[flight.id] = flight }
        return changes
    }

    /// Sync a flight to iCloud
    func syncFlight(_ flight: Flight, allFlights: [Flight]) {
        guard isSyncEnabled, let engine = syncEngine, let recordZone = recordZone else { return }

        let changes = pendingChanges(for: flight, in: recordZone)
        guard !changes.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: changes)
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
        engine.state.add(pendingRecordZoneChanges: changes)
        AppLog.sync.debugLine("Queued \(changes.count) record(s) for \(flights.count) flights")
    }

    /// Delete a flight from iCloud
    func deleteFlight(_ flightId: UUID) {
        guard isSyncEnabled, let engine = syncEngine, let recordZone = recordZone else { return }

        unmarkFlightSynced(flightId)   // so a future flight reusing this id re-uploads
        // Drop the stored change tag too: once the delete lands the record no longer exists, and a
        // stale tag would make a later insert look like an update to something that is gone.
        forgetSystemFields(forFlight: flightId)
        pendingFlightDeletions.insert(flightId)

        // Delete both the metadata record and its separate track record.
        let metaID = CKRecord.ID(recordName: flightId.uuidString, zoneID: recordZone.zoneID)
        let trackID = CKRecord.ID(recordName: Self.trackRecordName(flightId), zoneID: recordZone.zoneID)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(metaID), .deleteRecord(trackID)])

        AppLog.sync.debugLine("Queued flight \(flightId) (+ track) for deletion")
    }

    /// The sync currently in flight, so concurrent callers join it instead of starting another. (CQ-06)
    private var inFlightSync: Task<Void, Never>?

    /// Tears the engine down on sign-out, leaving local data untouched. (RES-05)
    ///
    /// Local flights and settings are deliberately NOT deleted: signing out of iCloud must not cost
    /// a pilot their logbook. The data stays on device and re-uploads if they sign back in.
    func stopSyncForSignOut() {
        inFlightSync?.cancel()
        inFlightSync = nil
        shutdownSyncEngine()
        clearAccountScopedState()
        isSyncing = false
    }

    /// Restarts sync after an account change, optionally discarding the previous account's state. (RES-05)
    ///
    /// `clearState` is true for `.switchAccounts` — a different account's server side means every
    /// cached token, change tag and fingerprint is stale. It is false for `.signIn`, which resumes
    /// the account the state already belongs to.
    func restartSyncForAccountChange(clearState: Bool) {
        inFlightSync?.cancel()
        inFlightSync = nil
        shutdownSyncEngine()
        if clearState { clearAccountScopedState() }
        isSyncing = false
        guard isSyncEnabled else { return }
        Task { [weak self] in
            await self?.initializeCloudKit()
        }
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

        let task = Task { @MainActor [weak self] in
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
            try await engine.fetchChanges()
            try await engine.sendChanges()
            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: lastSyncDateKey)
            AppLog.sync.debugLine("Manual sync completed")
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

    func clearPendingSettings() {
        pendingSettingsChange = nil
    }

    func getPendingFlight(for id: UUID) -> Flight? {
        return pendingFlights[id]
    }

    func clearPendingFlight(_ id: UUID) {
        pendingFlights.removeValue(forKey: id)
    }

    func clearPendingFlightDeletion(_ id: UUID) {
        pendingFlightDeletions.remove(id)
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
            UserDefaults.standard.set(data, forKey: lastSyncedModifiedAtKey)
        }
        if let data = try? JSONEncoder().encode(lastSyncedTrackCount) {
            UserDefaults.standard.set(data, forKey: lastSyncedTrackCountKey)
        }
    }

    /// Applies a conflict-merged flight to local state and re-queues it so the cloud converges on
    /// the merged result. Best-effort CloudKit conflict resolution. (ARCH-02)
    func resolveFlightConflict(_ merged: Flight) {
        var flights = DataPersistenceManager.shared.loadFlights()
        if let index = flights.firstIndex(where: { $0.id == merged.id }) {
            flights[index] = merged
        } else {
            flights.append(merged)
        }
        onFlightsUpdated?(flights)
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
        UserDefaults.standard.set(recordSystemFields, forKey: recordSystemFieldsKey)
    }

    /// Update last sync date (called when sync operations complete)
    func updateLastSyncDate() {
        lastSyncDate = Date()
        UserDefaults.standard.set(lastSyncDate, forKey: lastSyncDateKey)
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

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        Task { @MainActor in
            await handleEventAsync(event, syncEngine: syncEngine)
        }
    }

    @MainActor
    private func handleEventAsync(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
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
            AppLog.sync.debugLine("User signed into iCloud — restarting sync engine")
            manager?.restartSyncForAccountChange(clearState: false)
        case .signOut:
            AppLog.sync.debugLine("User signed out of iCloud — tearing down sync engine")
            manager?.stopSyncForSignOut()
        case .switchAccounts:
            AppLog.sync.debugLine("iCloud account switched — resetting sync state")
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
                    manager?.onSettingsUpdated?(settings)
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
        let updatedFlights: [Flight] = await withTaskGroup(of: Flight?.self) { group in
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
            // The records are gone server-side: a later flight reusing this id must be a real insert.
            manager?.forgetSystemFields(forFlight: flightId)
            guard let zoneID = deletedZoneIDs[flightId] else { continue }
            syncEngine.state.remove(pendingRecordZoneChanges: [
                .saveRecord(CKRecord.ID(recordName: flightId.uuidString, zoneID: zoneID)),
                .saveRecord(CKRecord.ID(recordName: SyncManager.trackRecordName(flightId), zoneID: zoneID)),
            ])
        }

        // Notify about flight updates
        if !updatedFlights.isEmpty || !deletedFlightIds.isEmpty {
            // Load the current set OFF the main actor (decoding a 50-flight logbook is heavy); merge on
            // the main actor where the conflict callback runs. The persistence write is batched off-main
            // in the onFlightsUpdated handler, not per-flight on the main actor.
            var currentFlights = await DataPersistenceManager.shared.loadFlightsOffMain()

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

            manager?.onFlightsUpdated?(currentFlights)

            // Mark the just-received records as synced so the next syncAllFlights doesn't echo all of
            // them — including the large track records — back up to the server. Marking with the
            // SERVER's fingerprints is safe: if a local copy is actually richer (merge kept a longer
            // local track), its count/modifiedAt won't match and it still re-uploads. (sync optimization)
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
                manager?.settingsRecordExists = true
                UserDefaults.standard.set(true, forKey: "settingsRecordExists")

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
                    manager?.resolveFlightConflict(merged)
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
