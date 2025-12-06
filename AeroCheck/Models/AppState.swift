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

    /// Aircraft registration (derived from selected aircraft)
    var defaultAirplane: String {
        selectedAircraft.registration
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
    
    // MARK: - Initialization

    init() {
        loadFlights()
        loadSettings()
        syncAircraftType()
    }

    /// Sync the current aircraft type to ChecklistData
    private func syncAircraftType() {
        ChecklistData.currentAircraft = settings.selectedAircraft
    }
    
    // MARK: - Flight Management
    
    func startFlight() {
        currentFlight = Flight(airplane: settings.defaultAirplane, startTime: Date())
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
    
    func endFlight() {
        guard var flight = currentFlight else { return }
        
        flight.stopTime = Date()
        flight.engineStartTime = engineStartTime
        flight.lineUpTime = lineUpTime
        flight.landingTime = landingTime
        flight.engineShutdownTime = engineShutdownTime
        
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
        landingTime = Date()
        currentFlight?.landingTime = landingTime
        hasLandingBeenDetected = true
    }

    /// Update landing time to current time (for long-press update)
    func updateLandingTime() {
        landingTime = Date()
        currentFlight?.landingTime = landingTime
    }
    
    func recordEngineShutdown() {
        engineShutdownTime = Date()
        currentFlight?.engineShutdownTime = engineShutdownTime
    }

    /// Record a go-around and return to climb phase, resetting subsequent phases
    func recordGoAround() {
        currentFlight?.goAroundCount += 1

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
        currentFlight?.touchAndGoCount += 1

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
                // Plane has stopped - record landing time (minus 2 minutes)
                landingTime = Date().addingTimeInterval(-120)
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
        if let flight = Flight.fromJSON(data) {
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
        if let encoded = try? JSONEncoder().encode(flights) {
            UserDefaults.standard.set(encoded, forKey: flightsKey)
        }
    }
    
    private func loadFlights() {
        if let data = UserDefaults.standard.data(forKey: flightsKey),
           let decoded = try? JSONDecoder().decode([Flight].self, from: data) {
            flights = decoded
        }
    }
    
    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: settingsKey)
        }
        syncAircraftType()
    }
    
    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        }
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
    
    /// Flight duration from engine start to now (or engine shutdown)
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
        let end = engineShutdownTime ?? Date()
        let duration = end.timeIntervalSince(start)
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
    
    var formattedEngineStartTime: String? {
        guard let time = engineStartTime else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: time)
    }
    
    var formattedLineUpTime: String? {
        guard let time = lineUpTime else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: time)
    }
    
    var formattedLandingTime: String? {
        guard let time = landingTime else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: time)
    }
    
    var formattedEngineShutdownTime: String? {
        guard let time = engineShutdownTime else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: time)
    }
}
