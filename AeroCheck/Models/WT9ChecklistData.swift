import Foundation

/// Checklist data for WT9 Dynamic (F-HVXA)
/// Version 2.1e - March 2025 - GVMP
struct WT9ChecklistData {

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

    // MARK: - Target Speeds

    static func targetSpeed(for phase: ChecklistPhase) -> Int? {
        switch phase {
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

    // MARK: - Speed Reference

    static let speeds: [SpeedReference] = [
        SpeedReference(name: "Vso", description: "flaps down", value: "33"),
        SpeedReference(name: "Vs", description: "stall clean", value: "42"),
        SpeedReference(name: "Vr", description: "rotation", value: "40"),
        SpeedReference(name: "Vx", description: "best angle", value: "55"),
        SpeedReference(name: "Vy", description: "best rate", value: "70"),
        SpeedReference(name: "Vcc", description: "cruise climb", value: "85"),
        SpeedReference(name: "Vfe", description: "flaps ext.", value: "76"),
        SpeedReference(name: "VA", description: "600kg", value: "97"),
        SpeedReference(name: "VA", description: "410kg", value: "75"),
        SpeedReference(name: "Vbg", description: "best glide", value: "70"),
        SpeedReference(name: "Vapp", description: "init (clean)", value: "70"),
        SpeedReference(name: "Vapp", description: "init (F1)", value: "65"),
        SpeedReference(name: "Vapp", description: "interm (F2)", value: "65"),
        SpeedReference(name: "Vfinal", description: "F2-F3", value: "60-55"),
    ]

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
}
