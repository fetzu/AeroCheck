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
        /// The FIS stations over a point from the downloaded data (`FISSectors.station(of:)`); none where
        /// it has no FIS sector, and the Swiss split built in answers instead.
        var fisSectors: (CLLocationCoordinate2D) -> [Entry] = { _ in [] }
    }

    /// A station and its frequency.
    struct Entry: Equatable {
        let station: String
        let freq: String
        /// Listen-only, shown in NEXT in its window: the destination's ATIS, an aerodrome on the way (the radio
        /// timeline, 6.4.2). The read band tags it LISTEN.
        var listen = false
        /// An airspace named beside the station: a TMA the FIS clears ("TMA GENEVA"). (6.4.2)
        var note: String? = nil

        /// One frequency is one station: what NOW and NEXT compare. "LSZQ AFIS" from the database and "LSZQ",
        /// the same 122.050 the route builder wrote on the waypoint, are one call, never NOW and NEXT at once
        /// (the author's device check dr-3, 6.4.1). Numbers compare to the kHz ("122.05" is "122.050").
        func isSameStation(as other: Entry?) -> Bool {
            guard let other else { return false }
            return RouteRadioPlanner.Station.normalized(freq) == RouteRadioPlanner.Station.normalized(other.freq)
        }
    }

    /// What the Cockpit knows of the flight besides where it is: the radio timeline of its route, its ground
    /// speed, whether its departure is over. Plan › Map has none of it. (6.4.2)
    struct Situation {
        /// The active route's (`RouteRadioPlanner.plan`), when it has been built for it.
        var timeline: RadioTimeline?
        /// GPS ground speed; unknown or slow, the leg's planned speed.
        var groundSpeedKt: Double?
        /// The level-off came (`FlightCueState`): the departure field is no longer NOW.
        var departureOver = false
        /// Aerodromes on the way shown in NEXT (Settings › Checklist & Flight).
        var fieldsOnTheWay = true
    }

    /// What the planner gives.
    struct Plan {
        /// The one to talk to now.
        let current: Entry?
        /// The one to call next.
        let next: Entry?
        /// Plan › Map's panel, as it always was: NOW and NEXT, then the nearest field, the route, the
        /// FIS on the way and the CTRs around, then Emergency. Everything but NOW, NEXT and Emergency is `.other`,
        /// behind "All frequencies".
        let panel: [PhaseFrequency]
        /// ROUTE's RADIO: every frequency in the order of use, Emergency last (the plan's Q6). NOW and
        /// NEXT; the field the aircraft is at; the field diverted to; the route's stations from the
        /// waypoint flown to onward (the fields passed are dropped); the FIS of each sector on the way
        /// (`fisAlongTheWay`); the CTRs around.
        let route: [PhaseFrequency]
    }

    /// Within this of a field, the field is NOW (about the size of a CTR or an RMZ).
    static let nearFieldNM = 10.0
    /// A route with a waypoint this far from the field it starts at leaves its circuit (the circuit cue's
    /// 3 NM, `FlightCueTracker.circuitNm`).
    static let circuitRadiusNM = 3.0
    static let nearestFieldLimit = 6
    static let nearestFieldRadiusNM = 40.0
    static let ctrRadiusNM = 25.0
    /// How finely the way ahead is walked for the areas it crosses.
    static let areaStepNM = 5.0

    /// Points from `start` to `end`, `areaStepNM` apart at most, `end` included and `start` not.
    static func steps(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let nm = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude)) / 1852.0
        let count = max(1, Int((nm / areaStepNM).rounded(.up)))
        return (1...count).map { step in
            let t = Double(step) / Double(count)
            return CLLocationCoordinate2D(latitude: start.latitude + (end.latitude - start.latitude) * t,
                                          longitude: start.longitude + (end.longitude - start.longitude) * t)
        }
    }

    /// NOW, NEXT and both lists. With no fix or no airport database, NOW and NEXT follow the plan's
    /// order: the departure's frequency, then the first waypoint after it that has one. A circuits flight
    /// (`circuits`) stays with its field: nothing is NEXT.
    static func plan(position: CLLocationCoordinate2D?, plan: FlightPlan?, circuits: Bool = false,
                     situation: Situation = Situation(), sources: Sources) -> Plan {
        let context = Context(position: position, plan: plan, circuits: circuits, situation: situation, sources: sources)
        let (current, next) = context.currentAndNext()
        return Plan(current: current, next: next,
                    panel: context.panel(current: current, next: next),
                    route: context.route(current: current, next: next))
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

    /// A timeline station as the Cockpit names it: a field's as the database has it ("LSZQ AFIS"), an area's or a
    /// zone's as RADIO always wrote them ("Zürich Info", "Grenchen TWR"), "HX" after a zone active by NOTAM. (6.4.2)
    static func entry(_ station: RadioTimeline.Station, kind: RadioTimeline.Kind?, listen: Bool = false,
                      note: String? = nil) -> Entry {
        var name = station.callSign
        switch kind {
        case .fis?, .unit?, .tmaViaFIS?: name = FISSectors.displayName(name)
        case .departure?, .destination?, nil: break
        }
        if station.isHX { name += " HX" }
        return Entry(station: name, freq: station.frequency, listen: listen, note: note)
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
        let circuits: Bool
        let situation: Situation
        let sources: Sources
        let nearField: Field?
        let nearDistanceNM: Double?
        /// Where the flight is on its route's radio timeline, when it is on it. (6.4.2)
        let onTimeline: (timeline: RadioTimeline, moment: RadioTimeline.Moment)?

        init(position: CLLocationCoordinate2D?, plan: FlightPlan?, circuits: Bool, situation: Situation,
             sources: Sources) {
            self.position = position
            self.plan = plan
            self.circuits = circuits
            self.situation = situation
            self.sources = sources
            onTimeline = Self.place(position: position, plan: plan, circuits: circuits, situation: situation)
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

        /// The flight on its route's timeline: a timeline built for this route, a fix, no circuits, no diversion,
        /// within `RadioTimeline.offRouteNM` of the leg flown. The minutes before a boundary at the GPS ground
        /// speed from 30 kt, else the leg's planned speed, else 100 kt. (6.4.2)
        static func place(position: CLLocationCoordinate2D?, plan: FlightPlan?, circuits: Bool,
                          situation: Situation) -> (timeline: RadioTimeline, moment: RadioTimeline.Moment)? {
            guard !circuits, let position, let plan, plan.diversion == nil, let timeline = situation.timeline,
                  !timeline.isEmpty, timeline.waypointNM.count == plan.waypoints.count else { return nil }
            let index = plan.currentWaypointIndex
            guard let progress = timeline.progress(of: position, flyingTo: index, waypoints: plan.waypoints.map(\.coordinate)),
                  progress.offRouteNM <= RadioTimeline.offRouteNM else { return nil }
            var speed = situation.groundSpeedKt.flatMap { $0 >= RadioTimeline.minimumSpeedKt ? $0 : nil }
            if speed == nil, plan.waypoints.indices.contains(index), index > 0,
               let seconds = plan.waypoints[index - 1].estimatedElapsedTime, seconds > 0 {
                speed = (timeline.waypointNM[index] - timeline.waypointNM[index - 1]) / seconds * 3600
            }
            let moment = RadioTimeline.Moment(progressNM: progress.nm, speedKt: speed ?? 100,
                                              departureOver: situation.departureOver,
                                              fieldsOnTheWay: situation.fieldsOnTheWay)
            return (timeline, moment)
        }

        /// NOW and NEXT off the timeline. (6.4.2)
        func fromTimeline(_ timeline: RadioTimeline, _ moment: RadioTimeline.Moment) -> (Entry?, Entry?) {
            let reading = timeline.reading(moment)
            let now = reading.now.map { PhaseFrequencyPlanner.entry($0.station, kind: $0.kind, note: $0.note) }
            let next = reading.next.map {
                PhaseFrequencyPlanner.entry($0, kind: reading.nextKind, listen: reading.nextIsListen)
            }
            return (now, next)
        }

        /// Whether a waypoint from the one flown to on lies beyond `circuitRadiusNM` of the field the
        /// aircraft is near (of the aircraft, away from any).
        func leavesTheCircuit(_ plan: FlightPlan, from index: Int) -> Bool {
            guard let centre = nearField?.coordinate ?? position else { return false }
            let here = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
            return plan.waypoints.indices.contains { i in
                guard i >= index else { return false }
                let point = plan.waypoints[i].coordinate
                return here.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude)) / 1852
                    > PhaseFrequencyPlanner.circuitRadiusNM
            }
        }

        /// Whether a waypoint already flown (before `index`) lies beyond `circuitRadiusNM` of the field the
        /// aircraft is near: the flight has been away from it, and is coming back or arriving. The mirror of
        /// `leavesTheCircuit`. (6.4.1)
        func hasBeenAway(_ plan: FlightPlan, before index: Int) -> Bool {
            guard let centre = nearField?.coordinate ?? position else { return false }
            let here = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
            return plan.waypoints.indices.contains { i in
                guard i < index else { return false }
                let point = plan.waypoints[i].coordinate
                return here.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude)) / 1852
                    > PhaseFrequencyPlanner.circuitRadiusNM
            }
        }

        /// Whether the field the aircraft is near is where the route ends: its ident, or within its circuit.
        func nearFieldEnds(_ plan: FlightPlan) -> Bool {
            guard let nearField, let last = plan.waypoints.last else { return false }
            if last.name.uppercased() == nearField.ident.uppercased() { return true }
            return CLLocation(latitude: nearField.coordinate.latitude, longitude: nearField.coordinate.longitude)
                .distance(from: CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)) / 1852
                <= PhaseFrequencyPlanner.circuitRadiusNM
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
        /// field's ATIS and contact from the database. The contact the route builder wrote on an aerodrome's
        /// waypoint is the database's, under its name ("LSZQ AFIS", not "LSZQ"). (6.4.1)
        func waypointFrequencies(_ waypoint: FlightPlanWaypoint) -> [(label: String, freq: String)] {
            let name = waypoint.name.isEmpty ? nil : waypoint.name
            if let typed = waypoint.frequency, !typed.isEmpty {
                if let ident = name, sources.hasAirportData {
                    let field = labelled(ident)
                    let same = RouteRadioPlanner.Station.normalized(typed)
                    if field.contains(where: { RouteRadioPlanner.Station.normalized($0.freq) == same }) { return field }
                }
                return [(label: name ?? "WPT", freq: typed)]
            }
            if let ident = name, sources.hasAirportData {
                return labelled(ident)
            }
            return []
        }

        /// The FIS over a point: the data's sectors, else the Swiss split built in (none outside it).
        func fis(at point: CLLocationCoordinate2D) -> [Entry] {
            let fromData = sources.fisSectors(point)
            if !fromData.isEmpty { return fromData }
            return FISSectors.swiss(at: point).map { [$0] } ?? []
        }

        /// The FIS where the aircraft is.
        var fisHere: [Entry] {
            position.map(fis(at:)) ?? []
        }

        /// The FIS of every sector on the way, in the order they come, each FIS once: the aircraft's,
        /// then each one the way ahead enters (to the waypoint flown to and along the legs after it, or
        /// to the field diverted to), walked every `areaStepNM`. Until 6.2 only the aircraft's: on the
        /// ground in the Engadine, a Jura route's RADIO listed Zurich Info and never Geneva Info, which
        /// works two thirds of it (device check, 5 Oct). A FIS with several sectors (Bale Info 130.900
        /// over the Ajoie and 135.855 over Franche-Comté, Langen Info's 126.950 and 120.650) is listed
        /// once, with the frequency of the sector the aircraft is in or reaches first: RADIO is computed
        /// again as the aircraft moves, so it changes on entering the next one (device check, 6 Oct).
        var fisAlongTheWay: [Entry] {
            var way: [CLLocationCoordinate2D] = position.map { [$0] } ?? []
            if let diversion = plan?.diversion {
                way.append(CLLocationCoordinate2D(latitude: diversion.latitude, longitude: diversion.longitude))
            } else if let plan, plan.currentWaypointIndex < plan.waypoints.count {
                way += plan.waypoints[max(0, plan.currentWaypointIndex)...].map(\.coordinate)
            }
            var points = Array(way.prefix(1))
            for (start, end) in zip(way, way.dropFirst()) {
                points += PhaseFrequencyPlanner.steps(from: start, to: end)
            }
            var stations: [Entry] = []
            for point in points {
                for station in fis(at: point)
                where !stations.contains(where: { $0.freq == station.freq || $0.station == station.station }) {
                    stations.append(station)
                }
            }
            return stations
        }

        var ctrs: [(station: String, frequency: String?)] {
            position.map(sources.nearbyCTRs) ?? []
        }

        /// CURRENT: near a field, the field; else the area's FIS. NEXT: the field diverted to; else the
        /// next field of the route; else, near a field, the area's FIS; else the nearest CTR; else the
        /// hand-off between the FIS and the field. Nothing in circuits, at the route's end, or arriving (rule
        /// A: the field NOW names is the next aerodrome of the route, and a waypoint already flown lies outside
        /// its circuit). The contact frequency, not the ATIS. (v4 UI/UX Revamp; 6.4.0; 6.4.1)
        func currentAndNext() -> (Entry?, Entry?) {
            // No usable position: the plan's order (the departure now, the next field of the route next).
            guard position != nil, sources.hasAirportData else {
                guard let plan, !plan.waypoints.isEmpty else { return (nil, nil) }
                let current = PhaseFrequencyPlanner.contact(waypointFrequencies(plan.waypoints[0]))
                let next = plan.waypoints.dropFirst().lazy
                    .compactMap { PhaseFrequencyPlanner.contact(self.waypointFrequencies($0)) }.first
                return (current, next)
            }
            // On the route: its radio timeline, the calls in the order the flight makes them. (6.4.2)
            if let onTimeline { return fromTimeline(onTimeline.timeline, onTimeline.moment) }
            let nearEntry = nearField.flatMap { PhaseFrequencyPlanner.contact(labelled($0.ident)) }
            let fisEntry = fisHere.first

            let current = nearActive ? (nearEntry ?? fisEntry) : (fisEntry ?? nearEntry)

            var next: Entry?
            // At the route's end: the field flown to is NOW, nothing after it. No CTR around is the next call
            // (on final at Bressaucourt, NEXT read Les Eplatures, 20 NM off). (6.4.0)
            var atRouteEnd = false
            // Arriving: back at, or coming into, the field the route goes to after being away from it. (6.4.1)
            var arriving = false
            // Diverting: the field the aircraft is going to is the next call, whatever the route says. (v5.1)
            if let diversion = plan?.diversion {
                next = PhaseFrequencyPlanner.contact(labelled(diversion.ident))
            }
            if next == nil, plan?.diversion == nil, let plan {
                let index = plan.currentWaypointIndex
                // The field flown to is the next call, until it is NOW (within its 10 NM); then the field
                // after it. Until 6.2 the field flown to was always passed over: 15 NM out from Les
                // Eplatures, NEXT read Bressaucourt.
                let flownTo = plan.waypoints.indices.contains(index)
                    ? PhaseFrequencyPlanner.contact(waypointFrequencies(plan.waypoints[index])) : nil
                let fieldAhead = plan.waypoints.indices.contains { $0 > index && !waypointFrequencies(plan.waypoints[$0]).isEmpty }
                if let flownTo, !flownTo.isSameStation(as: current) {
                    next = flownTo
                } else if flownTo != nil, !fieldAhead, index == plan.waypoints.count - 1 {
                    atRouteEnd = true
                } else if index >= plan.waypoints.count, nearActive, nearFieldEnds(plan) {
                    // The route flown: landed at its end (`followLanding` takes the index past the last waypoint),
                    // or still near it in the air. Until 6.4.1 the empty NEXT took the area's Info (after landing at
                    // Samedan, Zürich Info). Beyond its 10 NM, a flight with no route's rules. (6.4.1)
                    atRouteEnd = true
                } else if let ahead = plan.waypoints.indices.first(where: {
                    $0 > index && !waypointFrequencies(plan.waypoints[$0]).isEmpty
                }) {
                    let field = PhaseFrequencyPlanner.contact(waypointFrequencies(plan.waypoints[ahead]))
                    // A local flight back to the field it is at: that field is NOW, not NEXT. Once the route
                    // leaves the circuit, NEXT is the area's Info, the station called once out of the field's
                    // zone (at Bressaucourt, Bâle Information, not Grenchen's CTR 22 NM off the route); a CTR
                    // around only where no Info is known. Circuits flown on a plan keep none. (6.4.0, the
                    // author's dry run checks, st-12 and 17 Oct)
                    if field.map({ !$0.isSameStation(as: current) }) ?? true || !leavesTheCircuit(plan, from: index) {
                        next = field
                    } else if hasBeenAway(plan, before: index) {
                        // Arriving, rule A (the author, 18 Oct): the field NOW names is the next aerodrome of the
                        // route and a waypoint already flown lies outside its circuit. Nothing is NEXT, whatever the
                        // route still has ahead in the field's zone: 8 NM out from Samedan, Julier and Silvaplana
                        // ahead, NEXT read Zürich Info; coming home from a local flight's turn points, Bâle Info. The
                        // way out keeps the area's Info, even on a leg heading further out. (6.4.1)
                        arriving = true
                    } else if let fisEntry, !fisEntry.isSameStation(as: current) {
                        next = fisEntry
                    }
                }
            }
            // Circuits stay with the field: in free practice circuits at Bressaucourt, with no route, NEXT
            // read Les Eplatures, the nearest CTR. (6.4.0, the author's dry run checks, 18 Oct)
            if atRouteEnd || arriving || circuits { return (current, nil) }
            // No call from the route, near a field: the area's Info, the station called once out of the
            // field's zone, as on a route that leaves the circuit; a CTR around only where no Info is known.
            // The nearest CTR is within 25 NM in any direction, not the one the flight enters.
            if next == nil, nearActive, let fisEntry, !fisEntry.isSameStation(as: current) {
                next = fisEntry
            }
            if next == nil, let ctr = ctrs.first, let frequency = ctr.frequency {
                next = Entry(station: ctr.station, freq: frequency)
            }
            if next == nil { next = nearActive ? fisEntry : nearEntry }
            if let candidate = next, candidate.isSameStation(as: current) { next = nil }
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
            for station in fisAlongTheWay { list.add(station, role: .other) }
            for ctr in ctrs { if let frequency = ctr.frequency { list.add(ctr.station, frequency) } }
            list.addEmergency()
            return list.items
        }

        /// ROUTE's RADIO, in the order of use. On the route, the timeline from NOW on (the LISTEN items in their
        /// place, the zones it may enter after them), then the CTRs around. (6.4.2)
        func route(current: Entry?, next: Entry?) -> [PhaseFrequency] {
            var list = FrequencyList()
            list.add(current, role: .current)
            list.add(next, role: .next)
            if let onTimeline {
                let (timeline, moment) = onTimeline
                if nearActive, let nearField, moment.progressNM <= 0 {
                    for frequency in labelled(nearField.ident) { list.add(frequency.label, frequency.freq) }
                }
                for item in timeline.ahead(moment) {
                    let kind = timeline.calls.first { $0.station == item.station }?.kind
                    list.add(PhaseFrequencyPlanner.entry(item.station, kind: item.listen ? nil : kind, listen: item.listen),
                             role: .other)
                }
                for zone in timeline.possible where timeline.end(of: zone, departureOver: true) > moment.progressNM {
                    list.add(PhaseFrequencyPlanner.entry(zone.station, kind: .unit), role: .other)
                }
                for ctr in ctrs { if let frequency = ctr.frequency { list.add(ctr.station, frequency) } }
                list.addEmergency()
                return list.items
            }
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
            for station in fisAlongTheWay { list.add(station, role: .other) }
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
            if let entry { add(entry.station, entry.freq, role: role, listen: entry.listen, note: entry.note) }
        }

        mutating func add(_ station: String, _ freq: String, role: FreqRole = .other, emergency: Bool = false,
                          listen: Bool = false, note: String? = nil) {
            guard seen.insert(freq + "|" + station).inserted else { return }
            items.append(PhaseFrequency(station: station, freq: freq, highlighted: role == .current,
                                        isEmergency: emergency, role: emergency ? .emergency : role,
                                        listen: listen, note: note))
        }

        /// 121.500, always last.
        mutating func addEmergency() {
            add(SwissCommonFrequency.emergency.name, SwissCommonFrequency.emergency.frequency, emergency: true)
        }
    }
}

// MARK: - The FIS (6.2)

/// Who gives the flight information service where. The downloaded data's FIS sectors (OpenAIP type 33)
/// wherever it has them, Swiss or not (Bâle Information over Franche-Comté and Alsace, Langen Information
/// beyond the Rhine); else, in Switzerland, the published split built in (`SwissAirspaceSectors`): Zürich
/// Information 124.700 and Geneva Information 126.350, either side of the line from the Doubs to Binn. They
/// are the only two Swiss FIS. Until 6.2 a line at 7.45° E, and with each Info a "FIS West" 119.175 (Alps
/// Radar, the Geneva side's class C, no FIS) or a "FIS East" 125.225 (no Swiss frequency: Langen Radar, in
/// Germany).
enum FISSectors {
    /// A sector reaching this low or lower is worked from low level. One that starts higher (SIV GENEVE 1
    /// from 6,500 ft, SIV LYON 1 from FL85) is not a VFR flight's station near the ground.
    static let lowLevelFeet = 3_000.0

    /// A data sector's station: its primary frequency under its name as RADIO shows it ("BALE
    /// INFORMATION" → "Bale Info"); nil without a frequency, or starting above `lowLevelFeet`.
    static func station(of sector: Airspace) -> PhaseFrequencyPlanner.Entry? {
        guard sector.airspaceType == .fisSector, sector.lowerCeiling.asFeetMSL <= lowLevelFeet,
              let frequency = sector.primaryFrequency else { return nil }
        let name = frequency.name.flatMap { $0.isEmpty ? nil : $0 } ?? sector.name
        return PhaseFrequencyPlanner.Entry(station: displayName(name), freq: frequency.value)
    }

    /// "GENEVA INFORMATION" → "Geneva Info", "ZÜRICH INFORMATION" → "Zürich Info", "CHAMBERY APP" →
    /// "Chambery APP": as the app has always written the Swiss two, abbreviations kept in capitals.
    static func displayName(_ raw: String) -> String {
        raw.split(separator: " ").map { word -> String in
            let upper = word.uppercased()
            if upper == "INFORMATION" { return "Info" }
            if word.count <= 3 { return upper }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// The stations of the data's sectors over a point, one per FIS, in an order that doesn't depend on
    /// how the data loaded (by id). Another country's sector counts only where the country below has none
    /// of its own: OpenAIP draws SIV BALE 1.2 from the ground over the Swiss Jura, where a pilot calls
    /// Zürich Information, and Bale Info once the way goes into France (the author, 6 Oct; the Basel TMAs
    /// above are units of their own). Before, both were listed there, in the order the downloads happened
    /// to load, so NOW over Bressaucourt could change from launch to launch.
    static func stations(over sectors: [Airspace], countriesBelow: Set<String>) -> [PhaseFrequencyPlanner.Entry] {
        let own = sectors.filter { countriesBelow.contains($0.country.uppercased()) && station(of: $0) != nil }
        let counted = own.isEmpty ? sectors : own
        var stations: [PhaseFrequencyPlanner.Entry] = []
        for station in counted.sorted(by: { $0.id < $1.id }).compactMap(station(of:))
        where !stations.contains(where: { $0.freq == station.freq || $0.station == station.station }) {
            stations.append(station)
        }
        return stations
    }

    /// The Swiss split's station at a point; nil outside Switzerland.
    static func swiss(at point: CLLocationCoordinate2D) -> PhaseFrequencyPlanner.Entry? {
        guard SwissAirspaceSectors.isInSwitzerland(point) else { return nil }
        let common: SwissCommonFrequency = SwissAirspaceSectors.getSector(for: point) == .geneva ? .genevaInfo : .zurichInfo
        return PhaseFrequencyPlanner.Entry(station: common.name, freq: common.frequency)
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
             },
             fisSectors: { coordinate in
                 let sectors = openAIP.fisSectors(containing: coordinate)
                 // The countries below matter only where sectors overlap.
                 let below = sectors.count > 1 ? CountryBoundaries.shared.countries(near: coordinate, bufferNm: 0) : []
                 return FISSectors.stations(over: sectors, countriesBelow: below)
             })
    }
}

extension PhaseFrequency {
    /// What the Watch shows of it. (Watch freq sync)
    var watchInfo: FrequencyInfo {
        let role: FrequencyRole = isEmergency ? .emergency
            : self.role == .current ? .now
            : self.role == .next ? .next : .other
        return FrequencyInfo(name: station, frequency: freq, type: .common, role: role, listen: listen ? true : nil)
    }

    /// Its content, for telling a new list from the last: a list is rebuilt with new ids each time.
    var contentKey: String { "\(station)|\(freq)|\(role)|\(isEmergency)|\(listen)|\(note ?? "")" }
}

// MARK: - The Cockpit's radio

/// The Cockpit's one source of frequencies: NOW and NEXT for the map, the read band and the Companion
/// iPhone, every station in the order of use for ROUTE, and the Watch's list. Recomputed on every page,
/// CHECKLIST included, when the phase, the waypoint flown to or the diversion changes, when the airport
/// or airspace data arrives, and when the aircraft moves 0.01° or more. Driven by `CockpitRadioFollower`;
/// owned by `FlightView`. (6.2, ROUTE)
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

    /// The active route's radio timeline (`CockpitRadioFollower` builds it when the route changes), and the route
    /// it was built for: a timeline is only read for its own route. (6.4.2)
    @ObservationIgnored private(set) var timeline: RadioTimeline?
    @ObservationIgnored private(set) var timelineRoute: [String]?

    /// The key of a route's timeline: its points and typed frequencies.
    nonisolated static func timelineKey(_ plan: FlightPlan?) -> [String]? {
        plan.map { [$0.id.uuidString] + $0.waypoints.map { "\($0.latitude),\($0.longitude),\($0.frequency ?? "")" } }
    }

    /// A timeline for a route, or none (the route changed, the flight ended).
    func setTimeline(_ timeline: RadioTimeline?, for plan: FlightPlan?) {
        self.timeline = timeline
        timelineRoute = timeline == nil ? nil : Self.timelineKey(plan)
    }

    /// Computes the lists now: the phase, the leg, the diversion or the data changed.
    func update(position: CLLocationCoordinate2D?, plan: FlightPlan?, circuits: Bool = false,
                situation: PhaseFrequencyPlanner.Situation = .init(), sources: PhaseFrequencyPlanner.Sources) {
        computations += 1
        lastPosition = position
        var situation = situation
        if situation.timeline == nil, let timeline, timelineRoute == Self.timelineKey(plan) {
            situation.timeline = timeline
        }
        let result = PhaseFrequencyPlanner.plan(position: position, plan: plan, circuits: circuits,
                                                situation: situation, sources: sources)
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
    func noteMove(to position: CLLocationCoordinate2D?, plan: FlightPlan?, circuits: Bool = false,
                  situation: PhaseFrequencyPlanner.Situation = .init(), sources: PhaseFrequencyPlanner.Sources) {
        guard Self.movedSignificantly(from: lastPosition, to: position) else { return }
        update(position: position, plan: plan, circuits: circuits, situation: situation, sources: sources)
    }
}
