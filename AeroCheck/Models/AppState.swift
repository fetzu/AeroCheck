import Foundation
import SwiftUI

/// Phase completion status
enum PhaseCompletionStatus {
    case notStarted
    case completed       // User pressed NEXT
    case skipped         // User jumped past without pressing NEXT
    case missingAction   // Phase with required button (e.g., engine start) was skipped without pressing button
}

/// Application-wide settings
struct AppSettings: Codable {
    var selectedAircraft: AircraftType = .wt9Dynamic
    var keepScreenOn: Bool = true
    var gpsRecordingInterval: Double = 5.0 // seconds
    var showSpeedReference: Bool = true
    var stepByStepHighlighting: Bool = true // Highlight items one by one
    var learningMode: Bool = false // Hide memorizable checks
    var forceICAOChartLayer: Bool = false // When true, ICAO layer stays at all zoom levels
    var offlineMode: Bool = false // When true, use cached ICAO chart only
    var alwaysUseUTC: Bool = false // When true, all times are displayed in UTC
    var showEstimatedAirspeed: Bool = false // When true, shows estimated IAS based on wind data (experimental)

    // Flight Planning (Beta)
    var enableFlightPlanning: Bool = false // Beta feature toggle
    var waypointProximityThreshold: Double = 500 // meters, for auto-advancing waypoints
    var terrainAltitudeUnit: TerrainAltitudeUnit = .feet // feet, meters, or dual

    // Marketing mode is NOT persisted - it resets to false on app restart
    var marketingMode: Bool = false // When true, enables shake gesture to show marketing location controls

    /// Aircraft registration (derived from selected aircraft)
    var defaultAirplane: String {
        selectedAircraft.registration
    }

    // Custom coding keys to exclude marketingMode from persistence
    enum CodingKeys: String, CodingKey {
        case selectedAircraft
        case keepScreenOn
        case gpsRecordingInterval
        case showSpeedReference
        case stepByStepHighlighting
        case learningMode
        case forceICAOChartLayer
        case offlineMode
        case alwaysUseUTC
        case showEstimatedAirspeed
        case enableFlightPlanning
        case waypointProximityThreshold
        case terrainAltitudeUnit
        // marketingMode is intentionally excluded
    }
}

/// Unit for displaying terrain profile altitude
enum TerrainAltitudeUnit: String, Codable, CaseIterable, Identifiable {
    case feet = "Feet"
    case meters = "Meters"
    case dual = "Both"

    var id: String { rawValue }
}

/// Saved state for an active flight session
/// Used to restore flight state when app is closed and reopened
struct ActiveFlightState: Codable {
    let flight: Flight
    let currentPhaseRawValue: Int
    let engineStartTime: Date?
    let lineUpTime: Date?
    let landingTime: Date?
    let engineShutdownTime: Date?
    let phaseCompletionStatus: [Int: String] // Phase raw value -> status string
    let highestCompletedPhaseRawValue: Int
    let currentHighlightedItem: [Int: Int] // Phase raw value -> highlighted item index
    let hasLandingBeenDetected: Bool
    let savedAt: Date

    @MainActor
    init(from appState: AppState) {
        self.flight = appState.currentFlight!
        self.currentPhaseRawValue = appState.currentPhase.rawValue
        self.engineStartTime = appState.engineStartTime
        self.lineUpTime = appState.lineUpTime
        self.landingTime = appState.landingTime
        self.engineShutdownTime = appState.engineShutdownTime

        // Convert phase completion status to codable format
        var statusDict: [Int: String] = [:]
        for (phase, status) in appState.phaseCompletionStatus {
            let statusString: String
            switch status {
            case .notStarted: statusString = "notStarted"
            case .completed: statusString = "completed"
            case .skipped: statusString = "skipped"
            case .missingAction: statusString = "missingAction"
            }
            statusDict[phase.rawValue] = statusString
        }
        self.phaseCompletionStatus = statusDict

        self.highestCompletedPhaseRawValue = appState.highestCompletedPhase.rawValue

        // Convert highlighted items
        var highlightedDict: [Int: Int] = [:]
        for (phase, index) in appState.currentHighlightedItem {
            highlightedDict[phase.rawValue] = index
        }
        self.currentHighlightedItem = highlightedDict

        self.hasLandingBeenDetected = appState.hasLandingBeenDetected
        self.savedAt = Date()
    }

    /// Restore state to AppState
    @MainActor
    func restore(to appState: AppState) {
        appState.currentFlight = flight
        appState.isFlightActive = true
        appState.currentPhase = ChecklistPhase(rawValue: currentPhaseRawValue) ?? .preflight
        appState.engineStartTime = engineStartTime
        appState.lineUpTime = lineUpTime
        appState.landingTime = landingTime
        appState.engineShutdownTime = engineShutdownTime

        // Restore phase completion status
        var statusDict: [ChecklistPhase: PhaseCompletionStatus] = [:]
        for (rawValue, statusString) in phaseCompletionStatus {
            if let phase = ChecklistPhase(rawValue: rawValue) {
                let status: PhaseCompletionStatus
                switch statusString {
                case "completed": status = .completed
                case "skipped": status = .skipped
                case "missingAction": status = .missingAction
                default: status = .notStarted
                }
                statusDict[phase] = status
            }
        }
        appState.phaseCompletionStatus = statusDict

        appState.highestCompletedPhase = ChecklistPhase(rawValue: highestCompletedPhaseRawValue) ?? .preflight

        // Restore highlighted items
        var highlightedDict: [ChecklistPhase: Int] = [:]
        for (rawValue, index) in currentHighlightedItem {
            if let phase = ChecklistPhase(rawValue: rawValue) {
                highlightedDict[phase] = index
            }
        }
        appState.currentHighlightedItem = highlightedDict

        appState.hasLandingBeenDetected = hasLandingBeenDetected
    }
}

/// Main application state manager
@MainActor
class AppState: ObservableObject {
    // MARK: - Published Properties

    @Published var currentPhase: ChecklistPhase = .preflight
    @Published var isFlightActive: Bool = false
    @Published var currentFlight: Flight?
    @Published var flights: [Flight] = []
    @Published var settings: AppSettings = AppSettings()
    @Published var showFlightLog: Bool = false
    
    // Recorded times during flight
    @Published var engineStartTime: Date?
    @Published var lineUpTime: Date?
    @Published var landingTime: Date?
    @Published var engineShutdownTime: Date?
    
    // Phase completion tracking
    @Published var phaseCompletionStatus: [ChecklistPhase: PhaseCompletionStatus] = [:]
    @Published var highestCompletedPhase: ChecklistPhase = .preflight
    
    // Step-by-step highlighting tracking
    @Published var currentHighlightedItem: [ChecklistPhase: Int] = [:]
    
    // Landing detection
    @Published var hasLandingBeenDetected: Bool = false
    private var consecutiveLowSpeedReadings: Int = 0
    private let lowSpeedThreshold: Double = 2.0 // m/s (about 4 knots)
    private let requiredLowSpeedReadings: Int = 3
    
    // MARK: - Private Properties

    private let flightsKey = "savedFlights"
    private let settingsKey = "appSettings"
    private let activeFlightStateKey = "activeFlightState"
    
    // MARK: - Initialization

    init() {
        loadFlights()
        loadSettings()
        syncAircraftType()
        // Try to restore active flight state if app was closed during a flight
        restoreActiveFlightState()
    }

    /// Sync the current aircraft type to ChecklistData
    private func syncAircraftType() {
        ChecklistData.currentAircraft = settings.selectedAircraft
    }
    
    // MARK: - Flight Management
    
    func startFlight() {
        startFlight(withAircraft: settings.defaultAirplane, flightPlanId: nil)
    }

    func startFlight(withAircraft aircraft: String, flightPlanId: UUID? = nil) {
        currentFlight = Flight(
            airplane: aircraft,
            aircraftType: settings.selectedAircraft.rawValue,
            checklistVersion: settings.selectedAircraft.checklistVersion,
            flightPlanId: flightPlanId,
            startTime: Date()
        )
        currentPhase = .preflight
        isFlightActive = true
        engineStartTime = nil
        lineUpTime = nil
        landingTime = nil
        engineShutdownTime = nil
        phaseCompletionStatus = [:]
        highestCompletedPhase = .preflight
        hasLandingBeenDetected = false
        consecutiveLowSpeedReadings = 0
        currentHighlightedItem = [:] // Reset highlighting
    }
    
    func endFlight(withFlightPlan flightPlan: FlightPlan? = nil) {
        guard var flight = currentFlight else { return }

        flight.stopTime = Date()
        flight.engineStartTime = engineStartTime
        flight.lineUpTime = lineUpTime
        flight.landingTime = landingTime
        flight.engineShutdownTime = engineShutdownTime
        flight.flightPlan = flightPlan

        flights.insert(flight, at: 0)
        saveFlights()

        currentFlight = nil
        isFlightActive = false
        engineStartTime = nil
        lineUpTime = nil
        landingTime = nil
        engineShutdownTime = nil
        phaseCompletionStatus = [:]
        currentPhase = .preflight
        hasLandingBeenDetected = false

        // Clear saved flight state since flight ended normally
        clearActiveFlightState()
    }
    
    func cancelFlight() {
        currentFlight = nil
        isFlightActive = false
        engineStartTime = nil
        lineUpTime = nil
        landingTime = nil
        engineShutdownTime = nil
        phaseCompletionStatus = [:]
        currentPhase = .preflight
        hasLandingBeenDetected = false
        currentHighlightedItem = [:]

        // Clear saved flight state since flight was cancelled
        clearActiveFlightState()
    }
    
    // MARK: - Step-by-Step Highlighting
    
    /// Get the current highlighted item index for a phase (0-based)
    func getHighlightedItem(for phase: ChecklistPhase) -> Int {
        return currentHighlightedItem[phase] ?? 0
    }
    
    /// Advance to the next item in the current phase
    func advanceHighlightedItem() {
        let currentIndex = currentHighlightedItem[currentPhase] ?? 0
        
        // Get visible items count based on learning mode
        let visibleCount = ChecklistData.visibleItemCount(for: currentPhase, learningMode: settings.learningMode)
        
        if currentIndex < visibleCount - 1 {
            currentHighlightedItem[currentPhase] = currentIndex + 1
        }
        // If at last item, don't advance (user should press NEXT)
    }
    
    /// Mark the last item as complete (moves index past the last item)
    func markLastItemComplete() {
        let visibleCount = ChecklistData.visibleItemCount(for: currentPhase, learningMode: settings.learningMode)
        currentHighlightedItem[currentPhase] = visibleCount
    }
    
    /// Check if all items in current phase are completed
    func areAllItemsCompleted() -> Bool {
        let visibleCount = ChecklistData.visibleItemCount(for: currentPhase, learningMode: settings.learningMode)
        let currentIndex = currentHighlightedItem[currentPhase] ?? 0
        return currentIndex >= visibleCount
    }
    
    /// Reset highlighted item for a phase
    func resetHighlightedItem(for phase: ChecklistPhase) {
        currentHighlightedItem[phase] = 0
    }
    
    func recordEngineStart() {
        engineStartTime = Date()
        currentFlight?.engineStartTime = engineStartTime
    }
    
    func recordLineUpTime() {
        // Adds 2 minutes to current time as specified
        lineUpTime = Date().addingTimeInterval(120)
        currentFlight?.lineUpTime = lineUpTime
    }
    
    func recordLanding() {
        // Removes 1 minute (while vacating the runway)
        landingTime = Date().addingTimeInterval(-60)
        currentFlight?.landingTime = landingTime
        hasLandingBeenDetected = true
    }

    /// Update landing time to current time minus 1 minute (for long-press update)
    func updateLandingTime() {
        landingTime = Date().addingTimeInterval(-60)
        currentFlight?.landingTime = landingTime
    }
    
    func recordEngineShutdown() {
        engineShutdownTime = Date()
        currentFlight?.engineShutdownTime = engineShutdownTime
    }

    /// Record a go-around and return to climb phase, resetting subsequent phases
    func recordGoAround() {
        let goAroundTime = Date()
        currentFlight?.goAroundCount += 1
        currentFlight?.goAroundTimes.append(goAroundTime)

        // Reset phases from climb onwards
        for phase in ChecklistPhase.allCases {
            if phase.rawValue >= ChecklistPhase.climb.rawValue {
                phaseCompletionStatus[phase] = nil
                currentHighlightedItem[phase] = 0
            }
        }

        // Go to climb phase
        currentPhase = .climb
    }

    /// Record a touch-and-go and return to climb phase, resetting subsequent phases
    func recordTouchAndGo() {
        let touchAndGoTime = Date()
        currentFlight?.touchAndGoCount += 1
        currentFlight?.touchAndGoTimes.append(touchAndGoTime)

        // Reset phases from climb onwards
        for phase in ChecklistPhase.allCases {
            if phase.rawValue >= ChecklistPhase.climb.rawValue {
                phaseCompletionStatus[phase] = nil
                currentHighlightedItem[phase] = 0
            }
        }

        // Go to climb phase
        currentPhase = .climb
    }

    /// Record a full stop landing and return to taxi phase, resetting subsequent phases
    func recordFullStop() {
        let fullStopTime = Date().addingTimeInterval(-60) // Remove 1 minute like landing
        currentFlight?.fullStopCount += 1
        currentFlight?.fullStopTimes.append(fullStopTime)

        // Reset phases from taxi onwards (taxi through afterLanding)
        for phase in ChecklistPhase.allCases {
            if phase.rawValue >= ChecklistPhase.taxi.rawValue && phase.rawValue <= ChecklistPhase.afterLanding.rawValue {
                phaseCompletionStatus[phase] = nil
                currentHighlightedItem[phase] = 0
            }
        }

        // Go to taxi phase
        currentPhase = .taxi
    }

    func addGPSPoint(_ point: GPSPoint) {
        currentFlight?.gpsTrack.append(point)
        
        // Auto-detect landing when in After Landing phase
        if currentPhase == .afterLanding && !hasLandingBeenDetected {
            checkForLanding(speed: point.speed)
        }
    }
    
    private func checkForLanding(speed: Double) {
        if speed >= 0 && speed < lowSpeedThreshold {
            consecutiveLowSpeedReadings += 1
            if consecutiveLowSpeedReadings >= requiredLowSpeedReadings {
                // Plane has stopped - record landing time (minus 1 minute)
                landingTime = Date().addingTimeInterval(-60)
                currentFlight?.landingTime = landingTime
                hasLandingBeenDetected = true
            }
        } else {
            consecutiveLowSpeedReadings = 0
        }
    }
    
    // MARK: - Navigation
    
    func nextPhase() {
        guard let currentIndex = ChecklistPhase.allCases.firstIndex(of: currentPhase),
              currentIndex + 1 < ChecklistPhase.allCases.count else { return }
        
        // Check if current phase had a required action button that wasn't pressed
        if currentPhase.showsEngineStartButton && engineStartTime == nil {
            phaseCompletionStatus[currentPhase] = .missingAction
        } else if currentPhase.showsLineUpButton && lineUpTime == nil {
            phaseCompletionStatus[currentPhase] = .missingAction
        } else if currentPhase.showsEngineShutdownButton && engineShutdownTime == nil {
            phaseCompletionStatus[currentPhase] = .missingAction
        } else {
            // Mark current phase as completed
            phaseCompletionStatus[currentPhase] = .completed
        }
        
        // Update highest completed phase
        if currentPhase.rawValue >= highestCompletedPhase.rawValue {
            highestCompletedPhase = currentPhase
        }
        
        currentPhase = ChecklistPhase.allCases[currentIndex + 1]
    }
    
    func previousPhase() {
        guard let prevIndex = ChecklistPhase.allCases.firstIndex(of: currentPhase)?.advanced(by: -1),
              prevIndex >= 0 else { return }
        currentPhase = ChecklistPhase.allCases[prevIndex]
    }
    
    func goToPhase(_ phase: ChecklistPhase) {
        // When jumping to a phase, mark any skipped phases appropriately
        if let currentIndex = ChecklistPhase.allCases.firstIndex(of: currentPhase),
           let targetIndex = ChecklistPhase.allCases.firstIndex(of: phase) {
            
            if targetIndex > currentIndex {
                // Jumping forward - mark skipped phases
                for i in currentIndex..<targetIndex {
                    let skippedPhase = ChecklistPhase.allCases[i]
                    if phaseCompletionStatus[skippedPhase] == nil {
                        // Check if phase has a required action button
                        if skippedPhase.showsEngineStartButton && engineStartTime == nil {
                            phaseCompletionStatus[skippedPhase] = .missingAction
                        } else if skippedPhase.showsLineUpButton && lineUpTime == nil {
                            phaseCompletionStatus[skippedPhase] = .missingAction
                        } else if skippedPhase.showsEngineShutdownButton && engineShutdownTime == nil {
                            phaseCompletionStatus[skippedPhase] = .missingAction
                        } else {
                            phaseCompletionStatus[skippedPhase] = .skipped
                        }
                    }
                }
            }
        }
        currentPhase = phase
    }
    
    /// Get the completion status for a phase
    func getPhaseStatus(_ phase: ChecklistPhase) -> PhaseCompletionStatus {
        // If we have an explicit status recorded, use it
        if let status = phaseCompletionStatus[phase] {
            return status
        }
        
        // Current phase is always "in progress" (not started)
        if phase == currentPhase {
            return .notStarted
        }
        
        // Future phases (after current) are not started
        if phase.rawValue > currentPhase.rawValue {
            return .notStarted
        }
        
        // Past phases (before current) that weren't marked should be skipped
        // This handles the case where user jumped forward without completing
        if phase.rawValue < currentPhase.rawValue {
            // Check if this phase had a required action
            if phase.showsEngineStartButton && engineStartTime == nil {
                return .missingAction
            } else if phase.showsLineUpButton && lineUpTime == nil {
                return .missingAction
            } else if phase.showsEngineShutdownButton && engineShutdownTime == nil {
                return .missingAction
            }
            return .skipped
        }
        
        return .notStarted
    }
    
    // MARK: - Flight Log Management
    
    func deleteFlight(_ flight: Flight) {
        flights.removeAll { $0.id == flight.id }
        saveFlights()
    }
    
    func deleteFlight(at indexSet: IndexSet) {
        flights.remove(atOffsets: indexSet)
        saveFlights()
    }
    
    func importFlight(from data: Data) -> Bool {
        // Try GPX first, then JSON
        if let flight = Flight.fromGPX(data) {
            flights.insert(flight, at: 0)
            saveFlights()
            return true
        }
        if let flight = Flight.fromJSONOptional(data) {
            flights.insert(flight, at: 0)
            saveFlights()
            return true
        }
        return false
    }
    
    func updateFlightNotes(_ flight: Flight, notes: String) {
        if let index = flights.firstIndex(where: { $0.id == flight.id }) {
            flights[index].notes = notes
            saveFlights()
        }
    }
    
    func updateFlightName(_ flight: Flight, name: String) {
        if let index = flights.firstIndex(where: { $0.id == flight.id }) {
            flights[index].name = name
            saveFlights()
        }
    }
    
    // MARK: - Persistence
    
    private func saveFlights() {
        do {
            let encoded = try JSONEncoder().encode(flights)
            UserDefaults.standard.set(encoded, forKey: flightsKey)
        } catch {
            print("[AeroCheck] Failed to save flights: \(error.localizedDescription)")
        }
    }

    private func loadFlights() {
        guard let data = UserDefaults.standard.data(forKey: flightsKey) else { return }
        do {
            flights = try JSONDecoder().decode([Flight].self, from: data)
        } catch {
            print("[AeroCheck] Failed to load flights: \(error.localizedDescription)")
        }
    }

    func saveSettings() {
        do {
            let encoded = try JSONEncoder().encode(settings)
            UserDefaults.standard.set(encoded, forKey: settingsKey)
        } catch {
            print("[AeroCheck] Failed to save settings: \(error.localizedDescription)")
        }
        syncAircraftType()
    }

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: settingsKey) else { return }
        do {
            settings = try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            print("[AeroCheck] Failed to load settings: \(error.localizedDescription)")
        }
    }

    // MARK: - Active Flight State Persistence

    /// Save the current active flight state for restoration on app restart
    func saveActiveFlightState() {
        guard currentFlight != nil else {
            clearActiveFlightState()
            return
        }

        do {
            let state = ActiveFlightState(from: self)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            UserDefaults.standard.set(data, forKey: activeFlightStateKey)
        } catch {
            print("[AeroCheck] Failed to save active flight state: \(error.localizedDescription)")
        }
    }

    /// Restore the active flight state if one was saved
    /// Returns true if a flight state was restored
    @discardableResult
    func restoreActiveFlightState() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: activeFlightStateKey) else {
            return false
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(ActiveFlightState.self, from: data)

            // Check if the saved state is recent (within 24 hours)
            // Old sessions shouldn't be restored
            let maxAge: TimeInterval = 24 * 60 * 60 // 24 hours
            if Date().timeIntervalSince(state.savedAt) > maxAge {
                clearActiveFlightState()
                return false
            }

            state.restore(to: self)
            print("[AeroCheck] Restored active flight state from \(state.savedAt)")
            return true
        } catch {
            print("[AeroCheck] Failed to restore active flight state: \(error.localizedDescription)")
            clearActiveFlightState()
            return false
        }
    }

    /// Clear the saved active flight state
    func clearActiveFlightState() {
        UserDefaults.standard.removeObject(forKey: activeFlightStateKey)
    }

    /// Check if there is a saved active flight state
    var hasActiveFlightState: Bool {
        UserDefaults.standard.data(forKey: activeFlightStateKey) != nil
    }
}

// MARK: - Computed Properties Extension

extension AppState {
    var canGoToPreviousPhase: Bool {
        currentPhase != .preflight
    }
    
    var canGoToNextPhase: Bool {
        currentPhase != .hangar
    }
    
    var isLastPhase: Bool {
        currentPhase == .hangar
    }
    
    /// Flight duration from engine start to now
    var flightDuration: String {
        guard let start = engineStartTime else {
            // If engine not started, show session time
            guard let sessionStart = currentFlight?.startTime else { return "--:--" }
            let duration = Date().timeIntervalSince(sessionStart)
            let hours = Int(duration) / 3600
            let minutes = (Int(duration) % 3600) / 60
            let seconds = Int(duration) % 60
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        // Always use current time - timer should run until flight is ended
        let duration = Date().timeIntervalSince(start)
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
    
    var formattedEngineStartTime: String? {
        guard let time = engineStartTime else { return nil }
        return formatTime(time)
    }

    var formattedLineUpTime: String? {
        guard let time = lineUpTime else { return nil }
        return formatTime(time)
    }

    var formattedLandingTime: String? {
        guard let time = landingTime else { return nil }
        return formatTime(time)
    }

    var formattedEngineShutdownTime: String? {
        guard let time = engineShutdownTime else { return nil }
        return formatTime(time)
    }

    /// Format a time according to current UTC settings
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        if settings.alwaysUseUTC {
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: date) + " (UTC)"
        }
        return formatter.string(from: date)
    }
}
