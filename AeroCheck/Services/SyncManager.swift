import Foundation
import CloudKit
import Combine

/// Record types stored in CloudKit
enum SyncRecordType: String {
    case settings = "Settings"
    case flight = "Flight"
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
        // Load sync preference (default to enabled)
        self.isSyncEnabled = UserDefaults.standard.object(forKey: syncEnabledKey) as? Bool ?? true

        // Load last sync date
        self.lastSyncDate = UserDefaults.standard.object(forKey: lastSyncDateKey) as? Date

        // Load whether settings record exists on server
        self.settingsRecordExists = UserDefaults.standard.bool(forKey: settingsRecordExistsKey)

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
            print("[AéroCheck Sync] CloudKit initialization timed out - will retry later")
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

            print("[AéroCheck Sync] CloudKit initialized successfully, account status: \(status)")

            if status == .available {
                initializeSyncEngine()
            } else {
                syncError = "iCloud account not available"
                print("[AéroCheck Sync] iCloud account not available: \(status)")
            }
        } catch {
            isCloudKitAvailable = false
            syncError = "CloudKit not configured"
            print("[AéroCheck Sync] CloudKit not available: \(error.localizedDescription)")
            print("[AéroCheck Sync] To enable iCloud sync, configure CloudKit in Xcode's Signing & Capabilities")
        }
    }

    // MARK: - Sync Engine Lifecycle

    private func initializeSyncEngine() {
        guard syncEngine == nil, isCloudKitAvailable else { return }
        guard let container = container, let database = database else {
            print("[AéroCheck Sync] Cannot initialize sync engine: CloudKit not available")
            return
        }

        Task {
            do {
                // Check iCloud account status
                let status = try await container.accountStatus()
                guard status == .available else {
                    syncError = "iCloud account not available"
                    print("[AéroCheck Sync] iCloud account not available: \(status)")
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

                print("[AéroCheck Sync] Sync engine initialized")

                // Ensure zone exists
                await ensureZoneExists()

            } catch {
                syncError = "Failed to initialize sync: \(error.localizedDescription)"
                print("[AéroCheck Sync] Failed to initialize: \(error)")
            }
        }
    }

    private func shutdownSyncEngine() {
        syncEngine = nil
        syncEngineDelegate = nil
        print("[AéroCheck Sync] Sync engine shutdown")
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
            print("[AéroCheck Sync] Loaded sync state")
            return state
        } catch {
            print("[AéroCheck Sync] Failed to load sync state: \(error)")
            return nil
        }
    }

    func saveSyncState(_ state: CKSyncEngine.State.Serialization) {
        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: syncStateKey)
        } catch {
            print("[AéroCheck Sync] Failed to save sync state: \(error)")
        }
    }

    // MARK: - Sync Operations

    /// Sync settings to iCloud
    func syncSettings(_ settings: AppSettings) {
        guard isSyncEnabled, let engine = syncEngine, let recordZone = recordZone else { return }

        pendingSettingsChange = settings

        let recordID = CKRecord.ID(recordName: "settings", zoneID: recordZone.zoneID)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

        print("[AéroCheck Sync] Queued settings for sync")
        
        // Immediately trigger sync to ensure settings changes are pushed to other devices
        Task.detached {
            await self.syncNow()
        }
    }

    /// Sync a flight to iCloud
    func syncFlight(_ flight: Flight, allFlights: [Flight]) {
        guard isSyncEnabled, let engine = syncEngine, let recordZone = recordZone else { return }

        // Store the flight data so it's available when the batch is created
        pendingFlights[flight.id] = flight

        let recordID = CKRecord.ID(recordName: flight.id.uuidString, zoneID: recordZone.zoneID)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

        print("[AéroCheck Sync] Queued flight \(flight.id) for sync")
    }

    /// Sync all flights to iCloud
    func syncAllFlights(_ flights: [Flight]) {
        guard isSyncEnabled, let engine = syncEngine, let recordZone = recordZone else { return }

        // Store all flight data so it's available when batches are created
        for flight in flights {
            pendingFlights[flight.id] = flight
        }

        let changes: [CKSyncEngine.PendingRecordZoneChange] = flights.map { flight in
            let recordID = CKRecord.ID(recordName: flight.id.uuidString, zoneID: recordZone.zoneID)
            return .saveRecord(recordID)
        }

        if !changes.isEmpty {
            engine.state.add(pendingRecordZoneChanges: changes)
            print("[AéroCheck Sync] Queued \(flights.count) flights for sync")
        }
    }

    /// Delete a flight from iCloud
    func deleteFlight(_ flightId: UUID) {
        guard isSyncEnabled, let engine = syncEngine, let recordZone = recordZone else { return }

        pendingFlightDeletions.insert(flightId)

        let recordID = CKRecord.ID(recordName: flightId.uuidString, zoneID: recordZone.zoneID)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])

        print("[AéroCheck Sync] Queued flight \(flightId) for deletion")
    }

    /// Force a sync now
    func syncNow() async {
        guard isSyncEnabled, let engine = syncEngine else { return }

        isSyncing = true
        syncError = nil

        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: lastSyncDateKey)
            print("[AéroCheck Sync] Manual sync completed")
        } catch {
            syncError = "Sync failed: \(error.localizedDescription)"
            print("[AéroCheck Sync] Manual sync failed: \(error)")
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
            print("[AéroCheck Sync] Failed to encode settings: \(error)")
            return nil
        }
    }

    /// Splits a flight into its CloudKit field payloads: the `inline` blob for `record["data"]`
    /// (the full flight when it fits the inline budget, otherwise a track-stripped copy) and, when
    /// the flight is oversized, the `asset` blob (the full flight) to be written to a `CKAsset`.
    /// Pure and side-effect-free so the size/round-trip behaviour is unit-testable. (PERF-13)
    nonisolated static func flightRecordPayload(_ flight: Flight) throws -> (inline: Data, asset: Data?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let full = try encoder.encode(flight)
        guard full.count > maxInlineFlightBytes else { return (full, nil) }

        var trimmed = flight
        trimmed.gpsTrack = []
        let inline = try encoder.encode(trimmed)
        return (inline, full)
    }

    /// Reconstructs a flight from its CloudKit field blobs, preferring the asset payload (the
    /// authoritative full flight, with the track) over the track-stripped inline blob. Applies the
    /// same size cap and ingest validation as a directly-decoded record. (PERF-13 / SEC-17)
    nonisolated static func flightFromPayload(inline: Data?, asset: Data?) -> Flight? {
        guard let data = asset ?? inline else { return nil }
        guard data.count <= maxIngestRecordBytes else {
            print("[AéroCheck Sync] Rejecting oversized flight record (\(data.count) bytes)")
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let flight = try? decoder.decode(Flight.self, from: data) else {
            print("[AéroCheck Sync] Failed to decode flight payload")
            return nil
        }
        guard let validated = flight.validatedForIngest() else {
            print("[AéroCheck Sync] Rejecting invalid flight record: \(flight.id)")
            return nil
        }
        return validated
    }

    func createFlightRecord(_ flight: Flight) -> CKRecord? {
        guard let recordZone = recordZone else { return nil }
        let recordID = CKRecord.ID(recordName: flight.id.uuidString, zoneID: recordZone.zoneID)
        return Self.buildFlightRecord(flight, recordID: recordID)
    }

    /// Encodes a flight into a CKRecord. `nonisolated static` (the JSON encode + GPS-track payload is
    /// the expensive part) so the sync-batch path can build records OFF the main actor instead of
    /// inside a `DispatchQueue.main.sync`. (PR-24 / PERF-13)
    nonisolated static func buildFlightRecord(_ flight: Flight, recordID: CKRecord.ID) -> CKRecord? {
        let record = CKRecord(recordType: SyncRecordType.flight.rawValue, recordID: recordID)
        do {
            let payload = try flightRecordPayload(flight)
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
            print("[AéroCheck Sync] Failed to encode flight: \(error)")
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
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("[AéroCheck Sync] Failed to stage flight asset: \(error)")
            return nil
        }
    }

    func settingsFromRecord(_ record: CKRecord) -> AppSettings? {
        guard let data = record["data"] as? Data else { return nil }
        // Bound the payload before decoding so a corrupt/oversized record can't exhaust memory. (SEC-17)
        guard data.count <= Self.maxIngestRecordBytes else {
            print("[AéroCheck Sync] Rejecting oversized settings record (\(data.count) bytes)")
            return nil
        }

        do {
            let decoder = JSONDecoder()
            // Clamp flight-relevant numerics to sane ranges before applying. (SEC-17)
            return try decoder.decode(AppSettings.self, from: data).clampedForIngest()
        } catch {
            print("[AéroCheck Sync] Failed to decode settings: \(error)")
            return nil
        }
    }

    func flightFromRecord(_ record: CKRecord) -> Flight? {
        // Prefer the file-backed asset (full flight, with track) over the inline blob (which is
        // track-stripped for oversized flights). CKSyncEngine downloads the asset before delivering
        // the record, so its fileURL is readable here. (PERF-13 / SEC-17)
        let inline = record["data"] as? Data
        var assetData: Data?
        if let asset = record["dataAsset"] as? CKAsset, let url = asset.fileURL {
            assetData = try? Data(contentsOf: url)
        }
        return Self.flightFromPayload(inline: inline, asset: assetData)
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
            handleRecordZoneChanges(fetchedChanges)

        case .sentDatabaseChanges(let sentChanges):
            handleSentDatabaseChanges(sentChanges)

        case .sentRecordZoneChanges(let sentChanges):
            handleSentRecordZoneChanges(sentChanges)

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .willSendChanges, .didSendChanges, .didFetchChanges:
            // Informational events - no action needed
            break

        @unknown default:
            print("[AéroCheck Sync] Unknown event type")
        }
    }

    /// Gathered, ready-to-encode contents of one pending batch. `flights` are Sendable value types;
    /// the small settings record is built on the main actor (it has main-actor side effects), the
    /// expensive flight encoding happens off-main. (PR-24)
    private struct PendingBatch {
        let flightRecordIDs: [(flight: Flight, recordID: CKRecord.ID)]
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
            if let record = SyncManager.buildFlightRecord(entry.flight, recordID: entry.recordID) {
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

        var flightRecordIDs: [(flight: Flight, recordID: CKRecord.ID)] = []
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
                } else if let flightId = UUID(uuidString: recordID.recordName),
                          let flight = manager.getPendingFlight(for: flightId) {
                    flightRecordIDs.append((flight, recordID))
                }

            case .deleteRecord(let recordID):
                deletions.append(recordID)

            @unknown default:
                break
            }
        }

        return PendingBatch(
            flightRecordIDs: flightRecordIDs,
            settingsRecord: settingsRecord,
            deletions: deletions
        )
    }

    // MARK: - Event Handlers

    @MainActor
    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            print("[AéroCheck Sync] User signed into iCloud")
        case .signOut:
            print("[AéroCheck Sync] User signed out of iCloud")
        case .switchAccounts:
            print("[AéroCheck Sync] iCloud account switched")
        @unknown default:
            break
        }
    }

    @MainActor
    private func handleDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
        for deletion in changes.deletions {
            print("[AéroCheck Sync] Zone deleted: \(deletion.zoneID.zoneName)")
        }
    }

    @MainActor
    private func handleRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        var updatedFlights: [Flight] = []
        var deletedFlightIds: [UUID] = []

        for modification in changes.modifications {
            let record = modification.record

            switch record.recordType {
            case SyncRecordType.settings.rawValue:
                if let settings = manager?.settingsFromRecord(record) {
                    // Cache the record to preserve change tag for future updates
                    manager?.cachedSettingsRecord = record
                    
                    print("[AéroCheck Sync] Received settings update from cloud")
                    manager?.onSettingsUpdated?(settings)
                }

            case SyncRecordType.flight.rawValue:
                if let flight = manager?.flightFromRecord(record) {
                    print("[AéroCheck Sync] Received flight update from cloud: \(flight.id)")
                    updatedFlights.append(flight)
                }

            default:
                break
            }
        }

        for deletion in changes.deletions {
            if deletion.recordType == SyncRecordType.flight.rawValue,
               let flightId = UUID(uuidString: deletion.recordID.recordName) {
                print("[AéroCheck Sync] Flight deleted from cloud: \(flightId)")
                deletedFlightIds.append(flightId)
            }
        }

        // Notify about flight updates
        if !updatedFlights.isEmpty || !deletedFlightIds.isEmpty {
            // Get current flights and merge changes
            let persistence = DataPersistenceManager.shared
            var currentFlights = persistence.loadFlights()

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

            // Update last sync date when we receive changes
            manager?.updateLastSyncDate()
        }
    }

    @MainActor
    private func handleSentDatabaseChanges(_ changes: CKSyncEngine.Event.SentDatabaseChanges) {
        for zone in changes.savedZones {
            print("[AéroCheck Sync] Zone saved: \(zone.zoneID.zoneName)")
        }

        if !changes.failedZoneSaves.isEmpty {
            print("[AéroCheck Sync] Failed to save \(changes.failedZoneSaves.count) zones")
        }
    }

    @MainActor
    private func handleSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        print("[AéroCheck Sync] Saved \(changes.savedRecords.count) records, deleted \(changes.deletedRecordIDs.count)")

        // Clear pending data for successfully saved records
        for record in changes.savedRecords {
            if record.recordID.recordName == "settings" {
                manager?.clearPendingSettings()
                manager?.cachedSettingsRecord = record // Update cache with new change tag
            } else if let flightId = UUID(uuidString: record.recordID.recordName) {
                manager?.clearPendingFlight(flightId)
            }
        }

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
            
            // Handle server record changed error (code 14) - settings record already exists
            let nsError = error as NSError
            let errorCode = nsError.code
            if errorCode == CKError.serverRecordChanged.rawValue || nsError.userInfo["CKErrorServerErrorCode"] as? Int == 2004 {
                // For settings record, this is OK - it means the record was already created
                if recordName == "settings" {
                    print("[AéroCheck Sync] Settings record conflict detected. Updating cache from server record.")
                    manager?.settingsRecordExists = true
                    UserDefaults.standard.set(true, forKey: "settingsRecordExists")
                    
                    // Extract server record to get the latest change tag
                    if let serverRecord = nsError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                        manager?.cachedSettingsRecord = serverRecord
                        // Re-queue the sync immediately with the updated change tag
                        if let pendingSettings = manager?.getPendingSettings() {
                            print("[AéroCheck Sync] Re-queueing settings sync with updated change tag")
                            manager?.syncSettings(pendingSettings)
                        }
                    } else {
                        manager?.clearPendingSettings()
                    }
                    
                    manager?.updateLastSyncDate()
                    continue
                }

                // Flight conflict: another device's edit won the race. Previously this fell through
                // to a bare print and the local edit was dropped (devices diverged permanently).
                // Now we merge the server record with our pending local flight and re-queue. (ARCH-02)
                if let flightId = UUID(uuidString: recordName) {
                    if let serverRecord = nsError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
                       let serverFlight = manager?.flightFromRecord(serverRecord),
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
                }
            }

            // Non-conflict failure. CKSyncEngine auto-retries transient errors (network, server
            // busy, rate limit) and keeps the change pending, so for those the pending flight is
            // left untouched so the retry still has its data. Only act on permanent failures, so
            // they don't loop forever as a silent no-op. (PERF-13)
            switch CKError.Code(rawValue: nsError.code) {
            case .limitExceeded:
                // Record still too large even after the GPS track was offloaded to a CKAsset.
                // Retrying the identical record is futile — drop the pending change and surface it.
                if let flightId = UUID(uuidString: recordName) {
                    manager?.clearPendingFlight(flightId)
                }
                manager?.onSyncConflict?("A flight was too large to sync to iCloud and was skipped.")
            case .quotaExceeded:
                manager?.onSyncConflict?("iCloud storage is full — a flight couldn't be synced.")
            default:
                break
            }

            print("[AéroCheck Sync] Failed to save record: \(recordName), error: \(error)")
        }
    }
}
