import Foundation

/// Checklist data for Piper Archer II PA-28-181 (HB-PFA)
/// Version 1.6e - July 2020 - GVMP
struct PA28ChecklistData {

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
    /// Items with black vertical line in PDF are hidden when learning mode is OFF
    static func learningModeVisibleCount(for phase: ChecklistPhase) -> Int? {
        switch phase {
        case .afterEngineStart:
            return 0  // All items have black line
        case .taxi:
            return 0  // All items have black line
        case .runup:
            return 3  // Items 1-3 visible, 4+ hidden (black line starts at "Power")
        case .lineUp:
            return 0  // All items have black line (except "When lined up" header)
        case .climb:
            return 0  // All items have black line
        case .cruise:
            return 0  // All items have black line
        case .descent:
            return 0  // All items have black line
        case .approach:
            return 0  // All items have black line
        case .landing:
            return 0  // All items have black line
        case .afterLanding:
            return 0  // All items have black line
        default:
            return nil  // Show all items
        }
    }

    // MARK: - Target Speeds

    static func targetSpeed(for phase: ChecklistPhase) -> Int? {
        switch phase {
        case .preflight, .beforeEngineStart, .engineStart, .afterEngineStart:
            return nil
        case .taxi:
            return nil
        case .runup, .beforeDeparture:
            return nil
        case .lineUp:
            return nil
        case .climb:
            return 76  // Vy - best rate of climb
        case .cruise:
            return 110  // Cruise speed (estimated)
        case .descent:
            return 90  // Vinitial approach
        case .approach:
            return 80  // Vintermediate approach
        case .landing:
            return 70  // Vfinal approach
        case .afterLanding:
            return nil
        case .shutdown, .hangar:
            return nil
        }
    }

    // MARK: - Speed Reference

    static let speeds: [SpeedReference] = [
        SpeedReference(name: "Vso", description: "flaps down", value: "47"),
        SpeedReference(name: "Vs", description: "stall clean", value: "53"),
        SpeedReference(name: "Vr", description: "rotation", value: "53"),
        SpeedReference(name: "Vx", description: "best angle", value: "64"),
        SpeedReference(name: "Vy", description: "best rate", value: "76"),
        SpeedReference(name: "Vcc", description: "cruise climb", value: "87"),
        SpeedReference(name: "Vfe", description: "flaps ext.", value: "103"),
        SpeedReference(name: "VA", description: "2550 lbs", value: "113"),
        SpeedReference(name: "VA", description: "1634 lbs", value: "89"),
        SpeedReference(name: "Vbg", description: "best glide", value: "76"),
        SpeedReference(name: "Vapp", description: "initial", value: "90"),
        SpeedReference(name: "Vapp", description: "intermediate", value: "80"),
        SpeedReference(name: "Vfinal", description: "final/short", value: "70/66"),
    ]

    // MARK: - Page 1

    static let preflightItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Outside check (Walk around)", response: "Completed"),
        ChecklistItem(number: 2, challenge: "Baggage door", response: "Locked"),
        ChecklistItem(number: 3, challenge: "Aircraft documents", response: "On board"),
        ChecklistItem(number: 4, challenge: "Aircraft log", response: "Checked"),
        ChecklistItem(number: 5, challenge: "Tow bar", response: "Removed"),
        ChecklistItem(number: 6, challenge: "Cabin", response: "Checked"),
        ChecklistItem(number: 7, challenge: "Loadsheet", response: "Checked"),
    ]

    static let beforeEngineStartItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Preflight check", response: "Completed"),
        ChecklistItem(number: 2, challenge: "Seats, seat belts & harness", response: "Locked & secured"),
        ChecklistItem(number: 3, challenge: "Parking brake", response: "Set"),
        ChecklistItem(number: 4, challenge: "Electrical consumers", response: "OFF"),
        ChecklistItem(number: 5, challenge: "Circuit breakers", response: "All IN"),
        ChecklistItem(number: 6, challenge: "Alternate static source", response: "Closed"),
        ChecklistItem(number: 7, challenge: "Static & Pitot lines", response: "Drained"),
        ChecklistItem(number: 8, challenge: "Battery", response: "ON"),
        ChecklistItem(number: 9, challenge: "Annunciator lights", response: "Checked ON"),
        ChecklistItem(number: 10, challenge: "Fuel quantity", response: "L__ /R__ Checked"),
        ChecklistItem(number: 11, challenge: "Fuel selector valve", response: "__ Tank"),
        ChecklistItem(number: 12, challenge: "Power", response: "Idle"),
        ChecklistItem(number: 13, challenge: "Mixture", response: "Full rich"),
        ChecklistItem(number: 14, challenge: "Carburator heat", response: "OFF"),
        ChecklistItem(number: 15, challenge: "Controls", response: "Free and easy"),
        ChecklistItem(number: 16, challenge: "Trim", response: "Set for take-off"),
        ChecklistItem(number: 17, challenge: "Flaps", response: "As required"),
    ]

    static let engineStartItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Anticollision light", response: "ON"),
        ChecklistItem(number: 2, challenge: "Auxiliary fuel pump", response: "ON"),
        ChecklistItem(number: 3, challenge: "Priming", response: "According AFM"),
        ChecklistItem(number: 4, challenge: "Power", response: "Set for engine start"),
        ChecklistItem(number: 5, challenge: "Propeller area", response: "Free"),
        ChecklistItem(number: 6, challenge: "Ignition switch", response: "Start"),
        ChecklistItem(number: 7, challenge: "Power", response: "1000-1200 RPM"),
        ChecklistItem(number: 8, challenge: "Oil pressure", response: "Within 30 sec & loading"),
        ChecklistItem(number: 9, challenge: "Alternator", response: "ON"),
        ChecklistItem(number: 10, challenge: "Avionics Master", response: "ON"),
    ]

    // MARK: - Page 2

    static let afterEngineStartItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Annunciator lights", response: "OFF"),
        ChecklistItem(number: 2, challenge: "Auxiliary fuel pump", response: "OFF & pressure checked"),
        ChecklistItem(number: 3, challenge: "Primer", response: "Locked"),
        ChecklistItem(number: 4, challenge: "Gyro suction", response: "Green arc"),
        ChecklistItem(number: 5, challenge: "Flight instruments", response: "Set"),
        ChecklistItem(number: 6, challenge: "Avionics", response: "Preselected"),
        ChecklistItem(number: 7, challenge: "121.5 & ATIS", response: "Checked"),
        ChecklistItem(number: 8, challenge: "Vent, heaters & defroster", response: "As required"),
    ]

    static let taxiItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Brakes & steering", response: "Checked"),
        ChecklistItem(number: 2, challenge: "T/C, DG, compass", response: "Checked"),
        ChecklistItem(number: 3, challenge: "Horizon", response: "Stable"),
    ]

    static let runupItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Parking brake", response: "Set"),
        ChecklistItem(number: 2, challenge: "Landing light", response: "OFF"),
        ChecklistItem(number: 3, challenge: "Oil temperature", response: "Green arc"),
        ChecklistItem(number: 4, challenge: "Power", response: "2000 RPM"),
        ChecklistItem(number: 5, challenge: "Annunciator lights", response: "OFF & function check"),
        ChecklistItem(number: 6, challenge: "Gyro suction, engine gauges, alternator", response: "Checked"),
        ChecklistItem(number: 7, challenge: "Magnetos", response: "Max drop 175, max diff 50"),
        ChecklistItem(number: 8, challenge: "Carburator heat", response: "Checked"),
        ChecklistItem(number: 9, challenge: "Mixture", response: "Checked"),
        ChecklistItem(number: 10, challenge: "Power idle", response: "500-700 RPM stable"),
        ChecklistItem(number: 11, challenge: "Power", response: "1000-1200 RPM"),
    ]

    static let beforeDepartureItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Fuel quantity", response: "L__/R__ Checked"),
        ChecklistItem(number: 2, challenge: "Fuel selector valve", response: "Set to L__/R__"),
        ChecklistItem(number: 3, challenge: "Mixture", response: "Rich / as required"),
        ChecklistItem(number: 4, challenge: "Carburator heat", response: "OFF"),
        ChecklistItem(number: 5, challenge: "Magnetos", response: "Both"),
        ChecklistItem(number: 6, challenge: "Controls", response: "Free and easy"),
        ChecklistItem(number: 7, challenge: "Trim", response: "Set for take-off"),
        ChecklistItem(number: 8, challenge: "Flaps", response: "As required"),
        ChecklistItem(number: 9, challenge: "Flight instruments", response: "Set"),
        ChecklistItem(number: 10, challenge: "Avionics", response: "Preselected"),
        ChecklistItem(number: 11, challenge: "Doors & windows", response: "Closed"),
        ChecklistItem(number: 12, challenge: "Seat belts & harness", response: "Fastened"),
        ChecklistItem(number: 13, challenge: "Departure briefing (Rwy, Rtg, Alt, V, Emerg)", response: "Completed"),
    ]

    // MARK: - Page 3

    static let lineUpItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Approach sector", response: "Free"),
        ChecklistItem(number: 2, challenge: "Auxiliary fuel pump", response: "ON"),
        ChecklistItem(number: 3, challenge: "Landing light", response: "ON"),
        ChecklistItem(challenge: "When lined up:", response: "", isHeader: true),
        ChecklistItem(number: 4, challenge: "Directional gyro & runway heading", response: "Checked & identified"),
        ChecklistItem(number: 5, challenge: "Wind", response: "Checked"),
        ChecklistItem(number: 6, challenge: "Transponder", response: "__ Acc. ATC or Standby"),
        ChecklistItem(number: 7, challenge: "Time", response: "Checked"),
    ]

    static let climbItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Flaps", response: "Up"),
        ChecklistItem(number: 2, challenge: "Climb power", response: "Full power set"),
        ChecklistItem(number: 3, challenge: "Auxiliary fuel pump", response: "OFF & pressure checked"),
        ChecklistItem(number: 4, challenge: "Landing light", response: "As required"),
    ]

    static let cruiseItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Altimeter", response: "Set"),
        ChecklistItem(number: 2, challenge: "Directional gyro", response: "Set"),
        ChecklistItem(number: 3, challenge: "Cruise power", response: "Set"),
        ChecklistItem(number: 4, challenge: "Mixture", response: "Set"),
        ChecklistItem(number: 5, challenge: "Fuel system", response: "Checked"),
        ChecklistItem(number: 6, challenge: "Lights", response: "As required"),
    ]

    static let descentItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "ATIS", response: "Noted"),
        ChecklistItem(number: 2, challenge: "Approach briefing", response: "Completed"),
        ChecklistItem(number: 3, challenge: "Avionics", response: "Set & checked"),
        ChecklistItem(number: 4, challenge: "Directional gyro", response: "Set"),
        ChecklistItem(number: 5, challenge: "Cabin & pax", response: "Secured"),
    ]

    static let approachItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Altimeter", response: "QNH"),
        ChecklistItem(number: 2, challenge: "Directional gyro", response: "Heading set"),
        ChecklistItem(number: 3, challenge: "Landing light", response: "ON"),
        ChecklistItem(number: 4, challenge: "Auxiliary fuel pump", response: "ON"),
        ChecklistItem(number: 5, challenge: "Fuel quantity", response: "L__ /R__ Checked"),
        ChecklistItem(number: 6, challenge: "Fuel selector valve", response: "L__ /R__ Tank"),
        ChecklistItem(number: 7, challenge: "Mixture", response: "Rich / as required"),
        ChecklistItem(number: 8, challenge: "Carburator heat", response: "As required"),
    ]

    static let landingItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Flaps", response: "Checked"),
        ChecklistItem(number: 2, challenge: "Carburetor heat", response: "OFF"),
    ]

    // MARK: - Page 4

    static let afterLandingItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Transponder", response: "Standby"),
        ChecklistItem(number: 2, challenge: "Time", response: "Noted"),
        ChecklistItem(number: 3, challenge: "Flaps", response: "Up"),
    ]

    static let shutdownItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Parking brake", response: "Set"),
        ChecklistItem(number: 2, challenge: "Power", response: "1000-1200 RPM"),
        ChecklistItem(number: 3, challenge: "Com", response: "Check 121.5"),
        ChecklistItem(number: 4, challenge: "Electrical consumers & Avionics", response: "OFF"),
        ChecklistItem(number: 5, challenge: "Magnetos grounding", response: "Checked then both"),
        ChecklistItem(number: 6, challenge: "Mixture", response: "Lean / cut-off"),
        ChecklistItem(number: 7, challenge: "Power", response: "Idle"),
        ChecklistItem(number: 8, challenge: "Magnetos", response: "OFF"),
        ChecklistItem(number: 9, challenge: "Anticollision light", response: "OFF"),
        ChecklistItem(number: 10, challenge: "Battery & alternator", response: "OFF"),
        ChecklistItem(number: 11, challenge: "Flight data", response: "Noted"),
        ChecklistItem(number: 12, challenge: "Parking brake", response: "Set as required"),
    ]

    static let hangarItems: [ChecklistItem] = [
        ChecklistItem(number: 1, challenge: "Wheel chocks", response: "In place"),
        ChecklistItem(number: 2, challenge: "Pitot cover", response: "Installed"),
        ChecklistItem(number: 3, challenge: "Control lock", response: "Installed"),
        ChecklistItem(number: 4, challenge: "Tie-downs", response: "As required"),
    ]
}
