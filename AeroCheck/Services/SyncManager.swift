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

    func createFlightRecord(_ flight: Flight) -> CKRecord? {
        guard let recordZone = recordZone else { return nil }
        let recordID = CKRecord.ID(recordName: flight.id.uuidString, zoneID: recordZone.zoneID)
        let record = CKRecord(recordType: SyncRecordType.flight.rawValue, recordID: recordID)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(flight)
            record["data"] = data as CKRecordValue
            record["flightId"] = flight.id.uuidString as CKRecordValue
            record["airplane"] = flight.airplane as CKRecordValue
            record["startTime"] = flight.startTime as CKRecordValue?
            return record
        } catch {
            print("[AéroCheck Sync] Failed to encode flight: \(error)")
            return nil
        }
    }

    func settingsFromRecord(_ record: CKRecord) -> AppSettings? {
        guard let data = record["data"] as? Data else { return nil }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(AppSettings.self, from: data)
        } catch {
            print("[AéroCheck Sync] Failed to decode settings: \(error)")
            return nil
        }
    }

    func flightFromRecord(_ record: CKRecord) -> Flight? {
        guard let data = record["data"] as? Data else { return nil }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Flight.self, from: data)
        } catch {
            print("[AéroCheck Sync] Failed to decode flight: \(error)")
            return nil
        }
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

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) -> CKSyncEngine.RecordZoneChangeBatch? {
        // CKSyncEngine calls this synchronously on its own thread.
        // We use DispatchQueue.main.sync to safely access @MainActor state.
        // This is safe because CKSyncEngine never calls this from the main thread.
        var result: CKSyncEngine.RecordZoneChangeBatch?

        DispatchQueue.main.sync {
            result = self.createRecordZoneChangeBatchSync(syncEngine: syncEngine)
        }

        return result
    }

    /// Creates the batch synchronously on the main thread.
    /// Called from DispatchQueue.main.sync in nextRecordZoneChangeBatch.
    @MainActor
    private func createRecordZoneChangeBatchSync(
        syncEngine: CKSyncEngine
    ) -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let manager = manager else { return nil }

        let pendingChanges = syncEngine.state.pendingRecordZoneChanges

        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        var processedSettingsRecord = false

        for change in pendingChanges {
            switch change {
            case .saveRecord(let recordID):
                if recordID.recordName == "settings" {
                    if !processedSettingsRecord,
                       let settings = manager.getPendingSettings(),
                       let record = manager.createSettingsRecord(settings) {
                        recordsToSave.append(record)
                        processedSettingsRecord = true
                    }
                } else if let flightId = UUID(uuidString: recordID.recordName),
                          let flight = manager.getPendingFlight(for: flightId),
                          let record = manager.createFlightRecord(flight) {
                    recordsToSave.append(record)
                }

            case .deleteRecord(let recordID):
                recordIDsToDelete.append(recordID)

            @unknown default:
                break
            }
        }

        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else {
            return nil
        }

        return CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: recordsToSave,
            recordIDsToDelete: recordIDsToDelete,
            atomicByZone: true
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

            // Apply updates
            for flight in updatedFlights {
                if let index = currentFlights.firstIndex(where: { $0.id == flight.id }) {
                    currentFlights[index] = flight
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
            }
            
            print("[AéroCheck Sync] Failed to save record: \(recordName), error: \(error)")
        }
    }
}
