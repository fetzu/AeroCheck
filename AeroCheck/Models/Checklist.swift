import Foundation

/// Represents a flight phase with its associated checklist
enum ChecklistPhase: Int, CaseIterable, Identifiable, Codable {
    case preflight = 0
    case beforeEngineStart
    case engineStart
    case afterEngineStart
    case taxi
    case runup
    case beforeDeparture
    case lineUp
    case climb
    case cruise
    case descent
    case approach
    case landing
    case afterLanding
    case shutdown
    case hangar
    
    var id: Int { rawValue }
    
    var title: String {
        switch self {
        case .preflight: return "PREFLIGHT CHECK"
        case .beforeEngineStart: return "CHECK BEFORE ENGINE START"
        case .engineStart: return "ENGINE START"
        case .afterEngineStart: return "CHECK AFTER ENGINE START"
        case .taxi: return "TAXI CHECK"
        case .runup: return "RUNUP"
        case .beforeDeparture: return "CHECK BEFORE DEPARTURE"
        case .lineUp: return "LINE UP CHECK"
        case .climb: return "CLIMB CHECK"
        case .cruise: return "CRUISE CHECK"
        case .descent: return "DESCENT CHECK"
        case .approach: return "APPROACH CHECK"
        case .landing: return "LANDING CHECK"
        case .afterLanding: return "AFTER LANDING CHECK"
        case .shutdown: return "ENGINE SHUTDOWN AND PARKING CHECK"
        case .hangar: return "AT THE HANGAR"
        }
    }
    
    var pageNumber: Int {
        switch self {
        case .preflight, .beforeEngineStart, .engineStart: return 1
        case .afterEngineStart, .taxi, .runup, .beforeDeparture: return 2
        case .lineUp, .climb, .cruise, .descent, .approach, .landing: return 3
        case .afterLanding, .shutdown, .hangar: return 4
        }
    }
    
    var completionText: String {
        switch self {
        case .hangar:
            return ""
        default:
            return "\(shortTitle) COMPLETED"
        }
    }
    
    var shortTitle: String {
        switch self {
        case .preflight: return "PREFLIGHT CHECK"
        case .beforeEngineStart: return "CHECK BEFORE ENGINE START"
        case .engineStart: return "ENGINE START"
        case .afterEngineStart: return "CHECK AFTER ENGINE START"
        case .taxi: return "TAXI CHECK"
        case .runup: return "RUNUP"
        case .beforeDeparture: return "CHECK BEFORE DEPARTURE"
        case .lineUp: return "LINE UP CHECK"
        case .climb: return "CLIMB CHECK"
        case .cruise: return "CRUISE CHECK"
        case .descent: return "DESCENT CHECK"
        case .approach: return "APPROACH CHECK"
        case .landing: return "LANDING CHECK"
        case .afterLanding: return "AFTER LANDING CHECK"
        case .shutdown: return "PARKING CHECK"
        case .hangar: return "AT THE HANGAR"
        }
    }
    
    /// Whether this phase shows the "Engine Start" button
    var showsEngineStartButton: Bool {
        self == .engineStart
    }
    
    /// Whether this phase shows the "Ready for Line Up" button
    var showsLineUpButton: Bool {
        self == .beforeDeparture
    }
    
    /// Whether this phase shows the "Engine Shutdown" button
    var showsEngineShutdownButton: Bool {
        self == .shutdown
    }

    /// Whether this phase shows the "Go Around" and "Touch-and-Go" buttons
    var showsGoAroundButtons: Bool {
        self == .landing
    }

    /// Whether this phase shows the "Landed" button
    var showsLandedButton: Bool {
        self == .afterLanding
    }
    
    /// Target speed for the phase (nil means no speed display, e.g. during taxi)
    var targetSpeed: Int? {
        switch self {
        case .preflight, .beforeEngineStart, .engineStart, .afterEngineStart:
            return nil // Ground operations before taxi
        case .taxi:
            return nil // Taxiing
        case .runup, .beforeDeparture:
            return nil // Ground operations
        case .lineUp:
            return nil // On ground, preparing for takeoff
        case .climb:
            return 55 // Vx - best angle of climb
        case .cruise:
            return 100 // Cruise speed
        case .descent:
            return 85 // Vcc - cruise descent
        case .approach:
            return 65 // Initial approach with F1
        case .landing:
            return 55 // Final approach speed F3
        case .afterLanding:
            return nil // On ground
        case .shutdown, .hangar:
            return nil // Ground operations
        }
    }
    
    /// Whether this phase should show the speed indicator
    var showsSpeedIndicator: Bool {
        targetSpeed != nil
    }
    
    /// Whether this phase has an interactive briefing
    var hasBriefing: Bool {
        switch self {
        case .beforeDeparture, .descent:
            return true
        default:
            return false
        }
    }
    
    /// Briefing type for this phase
    var briefingType: BriefingType? {
        switch self {
        case .beforeDeparture:
            return .departure
        case .descent:
            return .approach
        default:
            return nil
        }
    }
    
    /// Notes or briefing text to show before the checklist
    var briefingText: String? {
        switch self {
        case .beforeDeparture:
            return "*** Departure briefing *** (tap to view)"
        case .descent:
            return "*** Approach briefing *** (tap to view)"
        default:
            return nil
        }
    }
}

/// Briefing types
enum BriefingType {
    case departure
    case approach
}

/// A single checklist item
struct ChecklistItem: Identifiable {
    let id = UUID()
    let number: Int?
    let challenge: String
    let response: String
    let isHeader: Bool
    
    init(number: Int? = nil, challenge: String, response: String = "", isHeader: Bool = false) {
        self.number = number
        self.challenge = challenge
        self.response = response
        self.isHeader = isHeader
    }
}

/// Complete checklist data from the WT9 F-HVXA document
struct ChecklistData {
    
    static func items(for phase: ChecklistPhase) -> [ChecklistItem] {
        switch phase {
        case .preflight:
            return preflightItems
        case .beforeEngineStart:
            return beforeEngineStartItems
        case .engineStart:
            return engineStartItems
        case .afterEngineStart:
            return afterEngineStartItems
        case .taxi:
            return taxiItems
        case .runup:
            return runupItems
        case .beforeDeparture:
            return beforeDepartureItems
        case .lineUp:
            return lineUpItems
        case .climb:
            return climbItems
        case .cruise:
            return cruiseItems
        case .descent:
            return descentItems
        case .approach:
            return approachItems
        case .landing:
            return landingItems
        case .afterLanding:
            return afterLandingItems
        case .shutdown:
            return shutdownItems
        case .hangar:
            return hangarItems
        }
    }
    
    // MARK: - Learning Mode Support
    
    /// Returns the number of visible items in learning mode (items to show before hiding)
    /// Returns nil if all items should be shown (not a memorizable phase)
    static func learningModeVisibleCount(for phase: ChecklistPhase) -> Int? {
        switch phase {
        case .engineStart:
            return 2  // Show items 1-2, hide from item 3 ("Engine is hot")
        case .taxi:
            return 0  // Hide all
        case .runup:
            return 3  // Show items 1-3, hide from item 4 ("Throttle")
        case .lineUp:
            return 0  // Hide all
        case .climb:
            return 0  // Hide all
        case .descent:
            return 0  // Hide all
        case .approach:
            return 0  // Hide all
        case .landing:
            return 0  // Hide all
        case .afterLanding:
            return 0  // Hide all
        default:
            return nil  // Show all items (not a memorizable phase)
        }
    }
    
    /// Returns items for display based on learning mode
    /// When learningMode is ON: show all items (for studying)
    /// When learningMode is OFF: hide memorizable items (to test memory)
    static func visibleItems(for phase: ChecklistPhase, learningMode: Bool) -> [ChecklistItem] {
        let allItems = items(for: phase)
        
        // Learning mode ON = show everything for studying
        if learningMode {
            return allItems
        }
        
        // Learning mode OFF = hide memorizable items to test memory
        guard let visibleCount = learningModeVisibleCount(for: phase) else {
            return allItems
        }
        
        if visibleCount == 0 {
            return []
        }
        
        return Array(allItems.prefix(visibleCount))
    }
    
    /// Returns the count of visible items for a phase based on learning mode
    static func visibleItemCount(for phase: ChecklistPhase, learningMode: Bool) -> Int {
        // Learning mode ON = show everything
        if learningMode {
            return items(for: phase).count
        }
        
        // Learning mode OFF = may hide some items
        if let count = learningModeVisibleCount(for: phase) {
            return count
        }
        return items(for: phase).count
    }
    
    /// Whether a phase has hidden items when learning mode is OFF
    static func hasHiddenItems(for phase: ChecklistPhase, learningMode: Bool) -> Bool {
        if learningMode {
            return false // Learning mode ON shows everything
        }
        return learningModeVisibleCount(for: phase) != nil
    }
    
    // MARK: - Page 1
    
    static let preflightItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Outside check", response: "Completed"),
        ChecklistItem(number: 2, challenge: "Aircraft papers", response: "Checked"),
        ChecklistItem(number: 3, challenge: "Aircraft log", response: "Checked"),
        ChecklistItem(number: 4, challenge: "Tow bar", response: "Removed"),
        ChecklistItem(number: 5, challenge: "Cabin", response: "Checked"),
        ChecklistItem(number: 6, challenge: "Loadsheet", response: "Within limits"),
    ]
    
    static let beforeEngineStartItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Seat belts & harness", response: "Adjusted & locked"),
        ChecklistItem(number: 2, challenge: "Parking brake", response: "Set"),
        ChecklistItem(number: 3, challenge: "Rudder pedals", response: "Set"),
        ChecklistItem(number: 4, challenge: "Electrical consumers", response: "OFF"),
        ChecklistItem(number: 5, challenge: "Circuit breakers", response: "All IN"),
        ChecklistItem(number: 6, challenge: "Master switch", response: "ON"),
        ChecklistItem(number: 7, challenge: "Dynon LHD1000 / RHD1000", response: "Both ON"),
        ChecklistItem(number: 8, challenge: "Starter key", response: "Charge"),
        ChecklistItem(number: 9, challenge: "Annunciator & stick shaker", response: "Checked"),
        ChecklistItem(number: 10, challenge: "Fuel Quantity", response: "L__ R__ end HH:MM @20l/h, tot set"),
        ChecklistItem(number: 11, challenge: "Fuel selector valve", response: "Left"),
        ChecklistItem(number: 12, challenge: "Auxiliary fuel pump", response: "ON… 0.2bar… OFF"),
    ]
    
    static let engineStartItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "NAV - ACL", response: "ON"),
        ChecklistItem(number: 2, challenge: "Carburator heat", response: "OFF"),
        ChecklistItem(number: 3, challenge: "Engine is hot", response: "Throttle 1/4 open, Choke OFF"),
        ChecklistItem(number: 4, challenge: "Engine is cold", response: "Throttle idle, Choke ON"),
        ChecklistItem(number: 5, challenge: "Propeller area", response: "Clear"),
        ChecklistItem(number: 6, challenge: "Magnetos", response: "Both ON"),
        ChecklistItem(number: 7, challenge: "Starter key", response: "Start, max 10 seconds"),
        ChecklistItem(number: 8, challenge: "When engine fires", response: "Close Choke, add throttle"),
        ChecklistItem(number: 9, challenge: "Throttle", response: "2000 RPM, Time Check"),
        ChecklistItem(number: 10, challenge: "Oil pressure", response: "White (2 bar min) within 10''"),
        ChecklistItem(number: 11, challenge: "Throttle", response: "2500 RPM after 2 min if cold"),
    ]
    
    // MARK: - Page 2
    
    static let afterEngineStartItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Alternator output", response: "Checked"),
        ChecklistItem(number: 2, challenge: "Annunciator lights", response: "No lights (or OT rising)"),
        ChecklistItem(number: 3, challenge: "Avionics", response: "ON (check ATIS)"),
        ChecklistItem(number: 4, challenge: "Ventilation, heater", response: "As required"),
        ChecklistItem(number: 5, challenge: "Engine instruments", response: "Checked (OT yellow rising)"),
        ChecklistItem(number: 6, challenge: "Avionics", response: "Set and preselected"),
        ChecklistItem(number: 7, challenge: "Flight instruments", response: "Set"),
        ChecklistItem(number: 8, challenge: "Oil Temperature", response: "Rising, no taxi < 30°C"),
    ]
    
    static let taxiItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Brakes & steering", response: "Checked"),
        ChecklistItem(number: 2, challenge: "Flight instruments", response: "Checked"),
    ]
    
    static let runupItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Parking brake", response: "Max Set"),
        ChecklistItem(number: 2, challenge: "Warm up", response: "Oil Temp ≥ 50°C"),
        ChecklistItem(number: 3, challenge: "Zone behind aircraft", response: "Clear"),
        ChecklistItem(number: 4, challenge: "Throttle", response: "4000 RPM"),
        ChecklistItem(number: 5, challenge: "Engine instr. & amp.", response: "Checked"),
        ChecklistItem(number: 6, challenge: "Magnetos L, R", response: "Max drop 300, diff 115"),
        ChecklistItem(number: 7, challenge: "Carburator heat", response: "Check function"),
        ChecklistItem(number: 8, challenge: "Throttle idle", response: "Max 1800 RPM"),
        ChecklistItem(number: 9, challenge: "Throttle", response: "2500 RPM (cooling)"),
        ChecklistItem(number: 10, challenge: "Annunciator lights", response: "No light"),
    ]
    
    static let beforeDepartureItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Fuel quantity", response: "L__ R__ end HH:MM @20l/h"),
        ChecklistItem(number: 2, challenge: "Fuel selector valve", response: "Left"),
        ChecklistItem(number: 3, challenge: "Carburator heat", response: "OFF"),
        ChecklistItem(number: 4, challenge: "Choke", response: "OFF"),
        ChecklistItem(number: 5, challenge: "Magnetos", response: "Both ON"),
        ChecklistItem(number: 6, challenge: "Trim", response: "Set for departure"),
        ChecklistItem(number: 7, challenge: "Flaps", response: "Set for departure (F1)"),
        ChecklistItem(number: 8, challenge: "Flight instr. & avionics", response: "No flag, set for departure"),
        ChecklistItem(number: 9, challenge: "Cabin & Pax", response: "Secured"),
        ChecklistItem(number: 10, challenge: "Canopy", response: "Closed and locked"),
        ChecklistItem(number: 11, challenge: "Rescue system", response: "Safety lock removed"),
        ChecklistItem(number: 12, challenge: "Flight controls", response: "Free and correct"),
        ChecklistItem(number: 13, challenge: "Departure briefing", response: "Completed"),
    ]
    
    // MARK: - Page 3
    
    static let lineUpItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Canopy & windows", response: "Closed and locked"),
        ChecklistItem(number: 2, challenge: "Time", response: "Noted"),
        ChecklistItem(number: 3, challenge: "Approach sector & Runway", response: "Clear"),
        ChecklistItem(number: 4, challenge: "Auxiliary fuel pump", response: "ON"),
        ChecklistItem(number: 5, challenge: "Landing light", response: "ON"),
    ]
    
    static let climbItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Flaps", response: "Up"),
        ChecklistItem(number: 2, challenge: "Climb power", response: "Set"),
        ChecklistItem(number: 3, challenge: "Auxiliary fuel pump", response: "OFF, pressure checked"),
        ChecklistItem(number: 4, challenge: "Landing light", response: "ON / OFF"),
        ChecklistItem(number: 5, challenge: "Engine parameters", response: "Checked"),
    ]
    
    static let cruiseItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Altimeter", response: "Checked (STD / QNH)"),
        ChecklistItem(number: 2, challenge: "Cruise power", response: "4800 RPM SET"),
        ChecklistItem(number: 3, challenge: "Engine instruments", response: "Oil Press, Oil Temp, CH Temp"),
        ChecklistItem(number: 4, challenge: "Fuel quantity", response: "L__ R__ end HH:MM @20l/h"),
        ChecklistItem(number: 5, challenge: "Fuel selector", response: "As required"),
    ]
    
    static let descentItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "ATIS or AD Information", response: "Noted"),
        ChecklistItem(number: 2, challenge: "Approach briefing", response: "Completed"),
        ChecklistItem(number: 3, challenge: "Avionics", response: "HDG bug SET & Checked"),
        ChecklistItem(number: 4, challenge: "Circuit breakers", response: "All IN"),
        ChecklistItem(number: 5, challenge: "Cabin & Pax", response: "Secured"),
    ]
    
    static let approachItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Altimeter", response: "QNH set"),
        ChecklistItem(number: 2, challenge: "Fuel quantity", response: "L__ R__ end HH:MM @20l/h"),
        ChecklistItem(number: 3, challenge: "Fuel selector", response: "Left"),
        ChecklistItem(number: 4, challenge: "Auxiliary fuel pump", response: "ON"),
        ChecklistItem(number: 5, challenge: "Carburator heat", response: "ON"),
        ChecklistItem(number: 6, challenge: "Landing lights", response: "ON"),
    ]
    
    static let landingItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Flaps", response: "Below 76kt → F2 or F3"),
        ChecklistItem(number: 2, challenge: "Carburator heat", response: "OFF"),
    ]
    
    // MARK: - Page 4
    
    static let afterLandingItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Transponder", response: "Standby"),
        ChecklistItem(number: 2, challenge: "Landing lights", response: "OFF"),
        ChecklistItem(number: 3, challenge: "Flaps", response: "UP"),
        ChecklistItem(number: 4, challenge: "Auxiliary fuel pump", response: "OFF"),
        ChecklistItem(number: 5, challenge: "Time", response: "Noted"),
    ]
    
    static let shutdownItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Parking brake", response: "SET"),
        ChecklistItem(number: 2, challenge: "Throttle", response: "Idle"),
        ChecklistItem(number: 3, challenge: "121.5", response: "Checked"),
        ChecklistItem(number: 4, challenge: "Avionics switch", response: "OFF"),
        ChecklistItem(number: 5, challenge: "Electrical consumers", response: "All OFF, except NAV-ACL"),
        ChecklistItem(number: 6, challenge: "Magnetos", response: "OFF"),
        ChecklistItem(number: 7, challenge: "Nav ACL", response: "OFF"),
        ChecklistItem(number: 8, challenge: "Starter key", response: "OFF"),
        ChecklistItem(number: 9, challenge: "Master switch", response: "OFF"),
        ChecklistItem(number: 10, challenge: "Rescue system", response: "Secured"),
        ChecklistItem(number: 11, challenge: "Flight data & documents", response: "Noted & completed"),
        ChecklistItem(number: 12, challenge: "Aircraft", response: "To be secured"),
    ]
    
    static let hangarItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Parking brake", response: "Released"),
        ChecklistItem(number: 2, challenge: "Flaps", response: "Set F3"),
        ChecklistItem(number: 3, challenge: "External electrical power", response: "When OAT < 5 °C"),
    ]
    
    // MARK: - Speed Reference
    
    static let speeds: [(name: String, description: String, value: String)] = [
        ("Vso", "(flaps down)", "33 KIAS"),
        ("Vs", "(stall clean)", "42 KIAS"),
        ("Vr", "(rotation)", "40 KIAS"),
        ("Vx", "(best angle)", "55 KIAS"),
        ("Vy", "(best rate of climb)", "70 KIAS"),
        ("Vcc", "(cruise climb)", "85 KIAS"),
        ("Vfe", "(flaps extension)", "76 KIAS"),
        ("VA", "600 kg – 410 kg", "97 KIAS – 75 KIAS"),
        ("Vbg", "best glide", "70 KIAS"),
        ("V initial approach", "", "70 KIAS (clean) – 65 KIAS (F1)"),
        ("V intermediate approach", "", "65 KIAS (F2)"),
        ("V final - gate", "", "60 KIAS – 55 KIAS (F2 - F3)"),
        ("Max demo crosswind (TO-LDG)", "", "14 KIAS – 16 KIAS"),
    ]
}
