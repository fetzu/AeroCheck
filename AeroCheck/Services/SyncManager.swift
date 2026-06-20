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
        pendingFlightDeletions.insert(flightId)

        // Delete both the metadata record and its separate track record.
        let metaID = CKRecord.ID(recordName: flightId.uuidString, zoneID: recordZone.zoneID)
        let trackID = CKRecord.ID(recordName: Self.trackRecordName(flightId), zoneID: recordZone.zoneID)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(metaID), .deleteRecord(trackID)])

        AppLog.sync.debugLine("Queued flight \(flightId) (+ track) for deletion")
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
    nonisolated static func buildFlightRecord(_ flight: Flight, recordID: CKRecord.ID) -> CKRecord? {
        let record = CKRecord(recordType: SyncRecordType.flight.rawValue, recordID: recordID)
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
    nonisolated static func buildFlightTrackRecord(_ flight: Flight, recordID: CKRecord.ID) -> CKRecord? {
        let record = CKRecord(recordType: SyncRecordType.flightTrack.rawValue, recordID: recordID)
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
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            AppLog.sync.debugLine("Failed to stage flight asset: \(error)")
            return nil
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
            await handleRecordZoneChanges(fetchedChanges)

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
        let flightRecordIDs: [(flight: Flight, recordID: CKRecord.ID)]
        let trackRecordIDs: [(flight: Flight, recordID: CKRecord.ID)]
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
        for entry in pending.trackRecordIDs {
            if let record = SyncManager.buildFlightTrackRecord(entry.flight, recordID: entry.recordID) {
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
        var trackRecordIDs: [(flight: Flight, recordID: CKRecord.ID)] = []
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
                    trackRecordIDs.append((flight, recordID))
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
            trackRecordIDs: trackRecordIDs,
            settingsRecord: settingsRecord,
            deletions: deletions
        )
    }

    // MARK: - Event Handlers

    @MainActor
    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            AppLog.sync.debugLine("User signed into iCloud")
        case .signOut:
            AppLog.sync.debugLine("User signed out of iCloud")
        case .switchAccounts:
            AppLog.sync.debugLine("iCloud account switched")
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
    private func handleRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        var deletedFlightIds: [UUID] = []

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
            }
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
            if record.recordID.recordName == "settings" {
                manager?.clearPendingSettings()
                manager?.cachedSettingsRecord = record // Update cache with new change tag
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
            
            // Handle server record changed error (code 14) - settings record already exists
            let nsError = error as NSError
            let errorCode = nsError.code
            if errorCode == CKError.serverRecordChanged.rawValue || nsError.userInfo["CKErrorServerErrorCode"] as? Int == 2004 {
                // For settings record, this is OK - it means the record was already created
                if recordName == "settings" {
                    AppLog.sync.debugLine("Settings record conflict detected. Updating cache from server record.")
                    manager?.settingsRecordExists = true
                    UserDefaults.standard.set(true, forKey: "settingsRecordExists")
                    
                    // Extract server record to get the latest change tag
                    if let serverRecord = nsError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
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
                }

                // Flight conflict: another device's edit won the race. Previously this fell through
                // to a bare print and the local edit was dropped (devices diverged permanently).
                // Now we merge the server record with our pending local flight and re-queue. (ARCH-02)
                if let flightId = UUID(uuidString: recordName) {
                    if let serverRecord = nsError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
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

            AppLog.sync.debugLine("Failed to save record: \(recordName), error: \(error)")
        }
    }
}
