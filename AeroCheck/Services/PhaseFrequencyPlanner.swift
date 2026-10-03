import Foundation
import CoreLocation
import Observation

// MARK: - The frequencies to have to hand (6.2: out of the map)
//
// NOW and NEXT, and every station along the way, from the aircraft's position, the active route and
// what the airport database and the OpenAIP airspace know. Until 6.2 this lived in the map's view
// (`NavigationMapView.recomputePhaseFrequencies`), which recomputed it only when the map's region moved:
// with the CHECKLIST page showing, NOW and NEXT never changed. The rules are here now, pure, with the
// data sources passed in as closures; `CockpitRadio` runs them for the Cockpit on every page, and Plan ›
// Map calls them itself.

/// The frequencies a VFR pilot needs, from where the aircraft is and where it is going. Pure: the
/// position, the plan and the data sources in, the lists out.
enum PhaseFrequencyPlanner {
    /// An aerodrome near the aircraft.
    struct Field {
        let ident: String
        let coordinate: CLLocationCoordinate2D
    }

    /// Where the frequencies come from. `live(airports:openAIP:)` reads the app's services; the tests
    /// pass their own.
    struct Sources {
        /// Whether the airport database is loaded: without it, the plan's order (see `plan`).
        var hasAirportData: Bool
        /// The fields nearest a point, nearest first: at most six, within 40 NM.
        var nearestFields: (CLLocationCoordinate2D) -> [Field]
        /// A field's frequencies as the airport database lists them: their type ("TWR", "ATIS") and
        /// the frequency as written ("118.125").
        var fieldFrequencies: (String) -> [(type: String, frequency: String)]
        /// The CTRs within 25 NM, nearest first: their name and primary frequency, if they have one.
        var nearbyCTRs: (CLLocationCoordinate2D) -> [(station: String, frequency: String?)]
    }

    /// A station and its frequency.
    struct Entry: Equatable {
        let station: String
        let freq: String
    }

    /// What the planner gives.
    struct Plan {
        /// The one to talk to now.
        let current: Entry?
        /// The one to call next.
        let next: Entry?
        /// Plan › Map's panel, as it always was: NOW and NEXT, then the nearest field, the route, the
        /// area and the CTRs around, then Emergency. Everything but NOW, NEXT and Emergency is `.other`,
        /// behind "All frequencies".
        let panel: [PhaseFrequency]
        /// ROUTE's RADIO: every frequency in the order of use, Emergency last (the plan's Q6). NOW and
        /// NEXT; the field the aircraft is at; the field diverted to; the route's stations from the
        /// waypoint flown to onward (the fields passed are dropped); the area's FIS; the CTRs around.
        let route: [PhaseFrequency]
    }

    /// Within this of a field, the field is NOW (about the size of a CTR or an RMZ).
    static let nearFieldNM = 10.0
    static let nearestFieldLimit = 6
    static let nearestFieldRadiusNM = 40.0
    static let ctrRadiusNM = 25.0

    /// NOW, NEXT and both lists. With no fix or no airport database, NOW and NEXT follow the plan's
    /// order: the departure's frequency, then the first waypoint after it that has one.
    static func plan(position: CLLocationCoordinate2D?, plan: FlightPlan?, sources: Sources) -> Plan {
        let context = Context(position: position, plan: plan, sources: sources)
        let (current, next) = context.currentAndNext()
        return Plan(current: current, next: next,
                    panel: context.panel(current: current, next: next),
                    route: context.route(current: current, next: next))
    }

    /// The Swiss area's FIS and Info, the Info first: what the area is worked on.
    static func areaFrequencies(for sector: SwissAirspaceSector) -> [SwissCommonFrequency] {
        switch sector {
        case .zurich: return [.zurichInfo, .fisEast]
        case .geneva: return [.genevaInfo, .fisWest]
        case .east: return [.fisEast]
        case .west: return [.fisWest]
        }
    }

    /// A field's VFR frequencies: its ATIS first when it has one (the first to listen to), then its
    /// contact frequency (TWR, then AFIS, INFO, A/G…: `AirportDataService.fieldContactPriority`, never
    /// an APP or a GND); its first frequency when it has neither.
    static func fieldFrequencies(_ all: [(type: String, frequency: String)]) -> [(type: String, frequency: String)] {
        guard !all.isEmpty else { return [] }
        var out: [(type: String, frequency: String)] = []
        if let atis = all.first(where: { $0.type.uppercased().contains("ATIS") }) {
            out.append(atis)
        }
        for type in AirportDataService.fieldContactPriority {
            if let contact = all.first(where: { $0.type.uppercased().contains(type) }) {
                out.append(contact)
                break
            }
        }
        if out.isEmpty, let first = all.first { out.append(first) }
        return out
    }

    /// The frequency to call on, from a station's list: the first that isn't an ATIS (listen only).
    static func contact(_ list: [(label: String, freq: String)]) -> Entry? {
        (list.first { !$0.label.uppercased().contains("ATIS") } ?? list.first)
            .map { Entry(station: $0.label, freq: $0.freq) }
    }

    /// The lists, built once per position: the nearest field and the area are looked up once.
    private struct Context {
        let position: CLLocationCoordinate2D?
        let plan: FlightPlan?
        let sources: Sources
        let nearField: Field?
        let nearDistanceNM: Double?

        init(position: CLLocationCoordinate2D?, plan: FlightPlan?, sources: Sources) {
            self.position = position
            self.plan = plan
            self.sources = sources
            // The nearest field that has VFR frequencies: a grass strip or a heliport without any is
            // passed over, else the area FIS became NOW beside a towered field. (v4 UI/UX Revamp fix)
            let field = position.flatMap { position in
                sources.hasAirportData
                    ? sources.nearestFields(position).first { !Self.frequencies(of: $0.ident, sources).isEmpty }
                    : nil
            }
            nearField = field
            if let position, let field {
                nearDistanceNM = CLLocation(latitude: position.latitude, longitude: position.longitude)
                    .distance(from: CLLocation(latitude: field.coordinate.latitude,
                                               longitude: field.coordinate.longitude)) / 1852.0
            } else {
                nearDistanceNM = nil
            }
        }

        /// Near a field: within `nearFieldNM`.
        var nearActive: Bool { (nearDistanceNM ?? .infinity) <= PhaseFrequencyPlanner.nearFieldNM }

        private static func frequencies(of ident: String, _ sources: Sources) -> [(type: String, frequency: String)] {
            PhaseFrequencyPlanner.fieldFrequencies(sources.fieldFrequencies(ident))
        }

        /// A field's frequencies, labelled "LSGC TWR".
        func labelled(_ ident: String) -> [(label: String, freq: String)] {
            Self.frequencies(of: ident, sources).map { (label: "\(ident) \($0.type)", freq: $0.frequency) }
        }

        /// A waypoint's frequencies: the one typed for it, else, when its name is a field's ident, that
        /// field's ATIS and contact from the database.
        func waypointFrequencies(_ waypoint: FlightPlanWaypoint) -> [(label: String, freq: String)] {
            let name = waypoint.name.isEmpty ? nil : waypoint.name
            if let typed = waypoint.frequency, !typed.isEmpty {
                return [(label: name ?? "WPT", freq: typed)]
            }
            if let ident = name, sources.hasAirportData {
                return labelled(ident)
            }
            return []
        }

        /// The area's FIS and Info, in Switzerland.
        var area: [SwissCommonFrequency] {
            guard let position, SwissAirspaceSectors.isInSwitzerland(position) else { return [] }
            return PhaseFrequencyPlanner.areaFrequencies(for: SwissAirspaceSectors.getSector(for: position))
        }

        var ctrs: [(station: String, frequency: String?)] {
            position.map(sources.nearbyCTRs) ?? []
        }

        /// CURRENT: near a field, the field; else the area's FIS. NEXT: the field diverted to; else the
        /// next field of the route; else the nearest CTR ahead; else the hand-off between the FIS and the
        /// field. The contact frequency, not the ATIS. (v4 UI/UX Revamp)
        func currentAndNext() -> (Entry?, Entry?) {
            // No usable position: the plan's order (the departure now, the next field of the route next).
            guard position != nil, sources.hasAirportData else {
                guard let plan, !plan.waypoints.isEmpty else { return (nil, nil) }
                let current = PhaseFrequencyPlanner.contact(waypointFrequencies(plan.waypoints[0]))
                let next = plan.waypoints.dropFirst().lazy
                    .compactMap { PhaseFrequencyPlanner.contact(self.waypointFrequencies($0)) }.first
                return (current, next)
            }
            let nearEntry = nearField.flatMap { PhaseFrequencyPlanner.contact(labelled($0.ident)) }
            let fisEntry = area.first.map { Entry(station: $0.name, freq: $0.frequency) }

            let current = nearActive ? (nearEntry ?? fisEntry) : (fisEntry ?? nearEntry)

            var next: Entry?
            // Diverting: the field the aircraft is going to is the next call, whatever the route says. (v5.1)
            if let diversion = plan?.diversion {
                next = PhaseFrequencyPlanner.contact(labelled(diversion.ident))
            }
            if next == nil, plan?.diversion == nil, let plan {
                let index = plan.currentWaypointIndex
                // The field flown to is the next call, until it is NOW (within its 10 NM); then the field
                // after it. Until 6.2 the field flown to was always passed over: 15 NM out from Les
                // Eplatures, NEXT read Bressaucourt.
                if plan.waypoints.indices.contains(index),
                   let flownTo = PhaseFrequencyPlanner.contact(waypointFrequencies(plan.waypoints[index])),
                   flownTo != current {
                    next = flownTo
                } else if let ahead = plan.waypoints.indices.first(where: {
                    $0 > index && !waypointFrequencies(plan.waypoints[$0]).isEmpty
                }) {
                    next = PhaseFrequencyPlanner.contact(waypointFrequencies(plan.waypoints[ahead]))
                }
            }
            if next == nil, let ctr = ctrs.first, let frequency = ctr.frequency {
                next = Entry(station: ctr.station, freq: frequency)
            }
            if next == nil { next = nearActive ? fisEntry : nearEntry }
            if let current, let candidate = next, current == candidate { next = nil }
            return (current, next)
        }

        /// Plan › Map's panel, as before 6.2.
        func panel(current: Entry?, next: Entry?) -> [PhaseFrequency] {
            var list = FrequencyList()
            list.add(current, role: .current)
            list.add(next, role: .next)
            if let nearField {
                for frequency in labelled(nearField.ident) { list.add(frequency.label, frequency.freq) }
            }
            for waypoint in plan?.waypoints ?? [] {
                for frequency in waypointFrequencies(waypoint) { list.add(frequency.label, frequency.freq) }
            }
            for common in area { list.add(common.name, common.frequency) }
            for ctr in ctrs { if let frequency = ctr.frequency { list.add(ctr.station, frequency) } }
            list.addEmergency()
            return list.items
        }

        /// ROUTE's RADIO, in the order of use.
        func route(current: Entry?, next: Entry?) -> [PhaseFrequency] {
            var list = FrequencyList()
            list.add(current, role: .current)
            list.add(next, role: .next)
            // The field the aircraft is at, its ATIS with it: in circuits, the only field there is.
            if nearActive, let nearField {
                for frequency in labelled(nearField.ident) { list.add(frequency.label, frequency.freq) }
            }
            if let diversion = plan?.diversion {
                for frequency in labelled(diversion.ident) { list.add(frequency.label, frequency.freq) }
            }
            if let plan, plan.currentWaypointIndex < plan.waypoints.count {
                for waypoint in plan.waypoints[max(0, plan.currentWaypointIndex)...] {
                    for frequency in waypointFrequencies(waypoint) { list.add(frequency.label, frequency.freq) }
                }
            }
            for common in area { list.add(common.name, common.frequency) }
            for ctr in ctrs { if let frequency = ctr.frequency { list.add(ctr.station, frequency) } }
            list.addEmergency()
            return list.items
        }
    }

    /// A list without repeats: a station and frequency given twice is listed once, where it came first.
    private struct FrequencyList {
        private(set) var items: [PhaseFrequency] = []
        private var seen = Set<String>()

        mutating func add(_ entry: Entry?, role: FreqRole) {
            if let entry { add(entry.station, entry.freq, role: role) }
        }

        mutating func add(_ station: String, _ freq: String, role: FreqRole = .other, emergency: Bool = false) {
            guard seen.insert(freq + "|" + station).inserted else { return }
            items.append(PhaseFrequency(station: station, freq: freq, highlighted: role == .current,
                                        isEmergency: emergency, role: emergency ? .emergency : role))
        }

        /// 121.500, always last.
        mutating func addEmergency() {
            add(SwissCommonFrequency.emergency.name, SwissCommonFrequency.emergency.frequency, emergency: true)
        }
    }
}

extension PhaseFrequencyPlanner.Sources {
    /// The app's airport database and OpenAIP airspace.
    @MainActor
    static func live(airports: AirportDataService, openAIP: OpenAIPDataService) -> Self {
        Self(hasAirportData: airports.isDataAvailable,
             nearestFields: { coordinate in
                 airports.findNearestAirports(to: coordinate, limit: PhaseFrequencyPlanner.nearestFieldLimit,
                                              maxDistanceNm: PhaseFrequencyPlanner.nearestFieldRadiusNM)
                     .map { PhaseFrequencyPlanner.Field(ident: $0.ident, coordinate: $0.coordinate) }
             },
             fieldFrequencies: { ident in
                 airports.getFrequencies(for: ident).map { (type: $0.type, frequency: $0.formattedFrequency) }
             },
             nearbyCTRs: { coordinate in
                 openAIP.nearbyCTRs(from: coordinate, withinNM: PhaseFrequencyPlanner.ctrRadiusNM,
                                    requireFrequencies: true)
                     .map { (station: $0.airspace.shortName, frequency: $0.airspace.primaryFrequency?.value) }
             })
    }
}

extension PhaseFrequency {
    /// What the Watch shows of it. (Watch freq sync)
    var watchInfo: FrequencyInfo {
        let role: FrequencyRole = isEmergency ? .emergency
            : self.role == .current ? .now
            : self.role == .next ? .next : .other
        return FrequencyInfo(name: station, frequency: freq, type: .common, role: role)
    }

    /// Its content, for telling a new list from the last: a list is rebuilt with new ids each time.
    var contentKey: String { "\(station)|\(freq)|\(role)|\(isEmergency)" }
}

// MARK: - The Cockpit's radio

/// The Cockpit's one source of frequencies: NOW and NEXT for the map and the read band, every station in
/// the order of use for ROUTE, and the Watch's list. Recomputed on every page, CHECKLIST included, when
/// the phase, the waypoint flown to or the diversion changes, when the airport or airspace data arrives,
/// and when the aircraft moves 0.01° or more. Driven by `CockpitRadioFollower`; owned by `FlightView`.
/// (6.2, ROUTE)
@MainActor
@Observable
final class CockpitRadio {
    /// NOW: the station to talk to.
    private(set) var now: PhaseFrequency?
    /// NEXT: the one to call next.
    private(set) var next: PhaseFrequency?
    /// ROUTE's RADIO, in the order of use, Emergency left out (it is pinned under the list).
    private(set) var stations: [PhaseFrequency] = []
    /// Emergency, 121.500.
    private(set) var emergency: [PhaseFrequency] = []

    /// Where the lists were last computed for.
    @ObservationIgnored private var lastPosition: CLLocationCoordinate2D?
    @ObservationIgnored private var lastKeys: [String]?
    /// Where a new list goes besides the pages: the Watch. The tests catch it instead.
    @ObservationIgnored var publish: ([PhaseFrequency]) -> Void = { items in
        WatchConnectivityManager.shared.updatePanelFrequencies(items.map(\.watchInfo))
    }
    /// How many times the lists were computed: for the tests.
    @ObservationIgnored private(set) var computations = 0

    /// A move under this, in latitude and in longitude, keeps the lists: the map's region threshold,
    /// which used to drive them (`NavigationMapView.spatialRequeryThresholdDegrees`).
    nonisolated static let moveThresholdDegrees = 0.01

    /// Whether the aircraft moved far enough for NOW and NEXT to be looked up again: 0.01° or more in
    /// latitude or longitude (to within a hair, which 7.01 − 7 falls short of in binary), or the fix
    /// found or lost.
    nonisolated static func movedSignificantly(from old: CLLocationCoordinate2D?, to new: CLLocationCoordinate2D?) -> Bool {
        guard let old, let new else { return (old == nil) != (new == nil) }
        let threshold = moveThresholdDegrees - 1e-9
        return abs(old.latitude - new.latitude) >= threshold || abs(old.longitude - new.longitude) >= threshold
    }

    /// Computes the lists now: the phase, the leg, the diversion or the data changed.
    func update(position: CLLocationCoordinate2D?, plan: FlightPlan?, sources: PhaseFrequencyPlanner.Sources) {
        computations += 1
        lastPosition = position
        let result = PhaseFrequencyPlanner.plan(position: position, plan: plan, sources: sources)
        // The pages and the Watch only hear of a list that changed: a recompute every few seconds in
        // cruise would otherwise redraw ROUTE and send the Watch the same list again.
        let keys = result.route.map(\.contentKey)
        guard keys != lastKeys else { return }
        lastKeys = keys
        now = result.route.first { $0.role == .current }
        next = result.route.first { $0.role == .next }
        stations = result.route.filter { !$0.isEmergency }
        emergency = result.route.filter(\.isEmergency)
        publish(result.route)
    }

    /// A new fix: the lists again once the aircraft has moved `moveThresholdDegrees` from where they
    /// were computed.
    func noteMove(to position: CLLocationCoordinate2D?, plan: FlightPlan?, sources: PhaseFrequencyPlanner.Sources) {
        guard Self.movedSignificantly(from: lastPosition, to: position) else { return }
        update(position: position, plan: plan, sources: sources)
    }
}
