import Foundation
import CoreLocation

// MARK: - Dry run (6.4.0): what it flies

/// What a dry run flies, with which aircraft, and at what pace: circuits at an aerodrome, or a copy of one of
/// the pilot's routes from its first aerodrome to its last. (6.4.0)
struct DryRunSetup {
    enum Mission {
        case circuits(DryRunAerodrome)
        /// The route as planned (flown in the dry run's world, a copy: the pilot's own is never touched).
        case route(FlightPlan, departure: DryRunAerodrome, destination: DryRunAerodrome)
    }

    var mission: Mission
    /// The aircraft; nil for the WT9, which every install can fly.
    var aircraft: AircraftOption?
    var rate: Double = DryRunSetup.defaultRate
    /// What the aircraft does at the end of the first finals, before the pilot's choice on final (DEBUG's
    /// scripted circuits).
    var landings: [DryRunGenerator.Landing] = []
    /// The guided flight, from this chapter (1 for the whole flight); nil for free practice.
    var guidedChapter: Int?

    var isGuided: Bool { guidedChapter != nil }

    static let defaultRate = 4.0
    /// The paces offered: as the pilot flies, four times, ten times.
    static let rates: [Double] = [1, 4, 10]

    var departure: DryRunAerodrome {
        switch mission {
        case .circuits(let field): return field
        case .route(_, let departure, _): return departure
        }
    }

    var isCircuits: Bool {
        if case .circuits = mission { return true }
        return false
    }

    var plan: FlightPlan? {
        if case .route(let plan, _, _) = mission { return plan }
        return nil
    }

    /// The aerodromes the detector anchors to, the store's or not.
    var aerodromes: [DryRunAerodrome] {
        switch mission {
        case .circuits(let field): return [field]
        case .route(_, let departure, let destination): return [departure, destination]
        }
    }

    /// The route's points between its two aerodromes.
    static func enRoutePoints(of plan: FlightPlan) -> [CLLocationCoordinate2D] {
        Array(plan.waypoints.dropFirst().dropLast())
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// The cruise: the highest altitude the plan gives its legs, else 2,000 ft over the higher circuit.
    static func cruiseAltitudeFt(of plan: FlightPlan, departure: DryRunAerodrome, destination: DryRunAerodrome) -> Double {
        let planned = plan.waypoints.dropFirst().dropLast().compactMap(\.altitude).max()
            ?? plan.waypoints.first?.altitude
        let floor = max(departure.patternAltitudeFt, destination.patternAltitudeFt) + 500
        return max(planned ?? floor + 1500, floor)
    }

    var generatorMission: DryRunGenerator.Mission {
        switch mission {
        case .circuits:
            return .circuits
        case .route(let plan, let departure, let destination):
            return .route(waypoints: Self.enRoutePoints(of: plan), destination: destination,
                          cruiseAltitudeFt: Self.cruiseAltitudeFt(of: plan, departure: departure, destination: destination))
        }
    }

    /// "Circuits at LSZQ", "LSZQ → LSGC", "Your first flight".
    var title: String {
        if isGuided { return L10n.DryRunCoach.flightName }
        switch mission {
        case .circuits(let field): return L10n.DryRun.circuitsAt(field.ident)
        case .route(_, let departure, let destination): return "\(departure.ident) → \(destination.ident)"
        }
    }

    /// The aerodrome a route's waypoint stands for: its ICAO code when it is one, else its name.
    static func aerodromeIdent(of waypoint: FlightPlanWaypoint) -> String {
        let ident = waypoint.pointKind == .aerodrome ? (waypoint.sourceId ?? waypoint.name) : waypoint.name
        return ident.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// "4×", "10×".
    static func paceLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.1f×", rate)
    }
}

// MARK: - The end

/// What a dry run flew, for the page at its end: nothing of it is kept anywhere else. (6.4.0)
struct DryRunSummary: Equatable {
    enum Event: Equatable {
        case takeoff, touchAndGo, goAround, fullStop
    }

    struct Line: Equatable {
        let event: Event
        /// Seconds since the dry run began.
        let seconds: TimeInterval
    }

    var title: String
    var aircraft: String
    /// The guided flight's habits, one per chapter flown.
    var habits: [String] = []
    var checksDone: Int
    var checksTotal: Int
    var lines: [Line]
    var seconds: TimeInterval
    var wasCircuits: Bool
    var diverted: Bool

    var landings: Int { lines.filter { $0.event == .fullStop || $0.event == .touchAndGo }.count }
    var takeoffs: Int { lines.filter { $0.event == .takeoff }.count }
    var goArounds: Int { lines.filter { $0.event == .goAround }.count }

    /// From what the dry run flew (the generator's marks, in seconds since its start): its take-offs, its
    /// touch-and-goes, full stops and go-arounds. What it flew, not what the detector made of it, which a dry
    /// run ended at once after a stop hasn't had the time to see.
    static func make(title: String, aircraft: String, checksDone: Int, wasCircuits: Bool, diverted: Bool,
                     marks: [(name: String, t: Int)], seconds: TimeInterval) -> DryRunSummary {
        let lines = marks.compactMap { mark -> Line? in
            let event: Event
            switch mark.name {
            case "takeoffRoll": event = .takeoff
            case "touchAndGo": event = .touchAndGo
            case "goAround": event = .goAround
            case "stopped": event = .fullStop
            default: return nil
            }
            return Line(event: event, seconds: TimeInterval(mark.t))
        }
        return DryRunSummary(title: title, aircraft: aircraft, checksDone: checksDone,
                             checksTotal: ChecklistPhase.allCases.count - (wasCircuits ? 2 : 0),
                             lines: lines.sorted { $0.seconds < $1.seconds }, seconds: max(0, seconds),
                             wasCircuits: wasCircuits, diverted: diverted)
    }

    /// What to try next time: the one thing this dry run didn't.
    var nextTime: String {
        if !habits.isEmpty { return L10n.DryRunCoach.nextFree }
        if wasCircuits {
            if goArounds == 0 { return L10n.DryRun.nextGoAround }
            if !lines.contains(where: { $0.event == .touchAndGo }) { return L10n.DryRun.nextTouchAndGo }
            return L10n.DryRun.nextRoute
        }
        return diverted ? L10n.DryRun.nextCircuits : L10n.DryRun.nextDivert
    }

    /// "Touch-and-go at 0:12".
    static func text(of line: Line) -> String {
        let time = clock(line.seconds)
        switch line.event {
        case .takeoff: return L10n.DryRun.takeoffAt(time)
        case .touchAndGo: return L10n.DryRun.touchAndGoAt(time)
        case .goAround: return L10n.DryRun.goAroundAt(time)
        case .fullStop: return L10n.DryRun.fullStopAt(time)
        }
    }

    /// "0:41", "1:05": hours and minutes of the dry run's time.
    static func clock(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds)) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
