import Foundation
import CoreLocation

// MARK: - Route radio plan (printed nav log)

/// Who a VFR pilot talks to on each leg of a planned route, for the printed nav log.
///
/// PURE, like `ThreadTaskEngine`: the route, the airspace along it and what is known about the two
/// aerodromes go in; a station and remarks per nav-log row come out. No services inside, so the rules
/// are unit-testable, and the in-flight FREQ panel can adopt them later.
///
/// Rows follow the nav log: row `i` is the leg that ENDS at waypoint `i`; row 0 is the departure.
///
/// The route is sampled every `sampleStepNM` against the airspace at the planned altitude (the same
/// piecewise-linear profile the builder's cross-section draws). On each leg the station is, in order:
/// 1. the controlled or radio-mandatory airspace the leg starts in or enters (CTR, TMA/CTA class A–D,
///    RMZ/FIZ/ATZ/TIZ);
/// 2. otherwise the area FIS;
/// 3. on the first and last rows, the aerodrome's own contact frequency.
/// A frequency typed on a waypoint always wins for its row.
enum RouteRadioPlanner {

    /// A radio station as printed: frequency + call sign.
    struct Station: Equatable, Hashable {
        let frequency: String
        let callSign: String
        /// The sibling airspace whose frequency was borrowed because this one publishes none. The
        /// nav log prints a † and a "verify" footnote for it.
        var inferredFrom: String?
        /// Active by NOTAM / schedule only (OpenAIP's "(HX)").
        var isHX = false

        func hasSameFrequency(as other: Station?) -> Bool {
            guard let other else { return false }
            return Self.normalized(frequency) == Self.normalized(other.frequency)
        }

        /// "121.03" and "121.025" style differences collapse to one three-decimal form.
        static func normalized(_ frequency: String) -> String {
            Double(frequency.trimmingCharacters(in: .whitespaces)).map { String(format: "%.3f", $0) } ?? frequency
        }
    }

    /// What the caller knows about the aerodrome at one end of the route.
    struct Aerodrome: Equatable {
        let ident: String
        let contact: Station?
        let atis: String?
        let ground: String?
    }

    struct Context {
        var waypoints: [FlightPlanWaypoint]
        /// Airspace near the route; the planner does the geometry itself.
        var airspaces: [Airspace]
        var departure: Aerodrome?
        var destination: Aerodrome?
        /// The area FIS for a position, or nil where none is known.
        var fis: (CLLocationCoordinate2D) -> Station?
        /// Countries the route crosses with no airspace data on the device.
        var missingAirspaceCountries: [String] = []
        /// Provenance line for the Radio box ("OpenAIP CH · 08.09.2026").
        var airspaceSource: String?
        /// Remark tag for areas to check before flight: "DABS" for Swiss routes, else "NOTAM".
        var checkAreaTag = "NOTAM"
        var sampleStepNM = 0.1
        /// Time before a boundary under which the call moves to the leg before.
        var leadTime: TimeInterval = 120
        /// When the destination ATIS is placed: the last row reached at least this long before arrival.
        var atisLeadTime: TimeInterval = 600
    }

    /// One nav-log row's radio column.
    struct Row: Equatable {
        var station: Station?
        /// False when the station repeats the row above; the nav log prints a ditto mark.
        var changed = false
        /// Typed on the waypoint — printed as entered.
        var isManual = false
        var remarks: [String] = []
    }

    /// One line of the Radio box's station list.
    struct Listing: Equatable, Hashable {
        let label: String
        let frequency: String
        var marker = ""
    }

    struct Plan: Equatable {
        var rows: [Row] = []
        /// Stations in route order, with the aerodromes' ATIS/GND and 121.500 appended.
        var stations: [Listing] = []
        /// Areas to check before flight (DABS/NOTAM) and airspace active by NOTAM (HX).
        var checkAreas: [String] = []
        /// Footnotes and data gaps, printed in the Radio box.
        var notes: [String] = []
        var source: String?
        /// "DABS" on Swiss routes, else "NOTAM".
        var checkAreaTag = "NOTAM"

        static let empty = Plan()
    }

    static let emergency = Listing(label: "EMERGENCY", frequency: "121.500")

    // MARK: - Planning

    static func plan(_ ctx: Context) -> Plan {
        let wps = ctx.waypoints
        let n = wps.count
        var plan = Plan(rows: Array(repeating: Row(), count: n))
        plan.source = ctx.airspaceSource
        plan.checkAreaTag = ctx.checkAreaTag
        guard n >= 2 else {
            applyManual(wps, to: &plan.rows)
            markChanges(&plan.rows)
            plan.stations = listings(plan, departure: ctx.departure, destination: ctx.destination)
            return plan
        }

        var cum: [Double] = [0]
        for i in 1..<n { cum.append(cum[i - 1] + distanceNM(wps[i - 1].coordinate, wps[i].coordinate)) }
        let profile = RouteAltitudeProfile(wps)
        let samples = samplePoints(wps, cum: cum, step: ctx.sampleStepNM)
        let legSeconds = (0..<(n - 1)).map { k -> TimeInterval in
            if let t = wps[k].estimatedElapsedTime, t > 0 { return t }
            return (cum[k + 1] - cum[k]) / 100 * 3600   // no timing yet: 100 kt
        }

        // Where the aircraft is inside each airspace, horizontally and at the planned altitude.
        let tracks = ctx.airspaces.compactMap { track($0, samples: samples, profile: profile) }
        let units = tracks.filter { kind(of: $0.airspace) == .unit && $0.anyVertical }
        let checks = tracks.filter { kind(of: $0.airspace) == .check && $0.anyVertical }
        let overhead = tracks.filter {
            kind(of: $0.airspace) == .unit
                || (kind(of: $0.airspace) == .check && $0.airspace.airspaceType != .gliderSector)
        }

        // Station timeline: the most recently entered unit the aircraft is inside of, if any.
        var stack: [Int] = []   // indices into `units`
        var active: [Int?] = []
        for s in samples.indices {
            for (u, t) in units.enumerated() {
                let inside = t.vertical[s]
                let wasInside = stack.contains(u)
                if inside && !wasInside { stack.append(u) } else if !inside && wasInside { stack.removeAll { $0 == u } }
            }
            active.append(stack.last)
        }
        func stationOf(unit u: Int) -> Station {
            unitStation(units[u].airspace, among: ctx.airspaces)
        }

        // Per leg: station, and the events worth a remark.
        struct Pending { let station: Station; let remark: String }
        var carried: [Int: Pending] = [:]   // row → call moved in from the leg after it
        var unitRow = [Bool](repeating: false, count: n)   // row's station comes from an airspace

        for k in 0..<(n - 1) {
            let row = k + 1
            let legRange = samples.indices.filter { samples[$0].leg == k }
            guard let first = legRange.first else { continue }
            let legStart = cum[k]
            let legNM = cum[k + 1] - cum[k]
            let speed = legSeconds[k] > 0 ? legNM / legSeconds[k] : 100.0 / 3600
            var remarks: [String] = []
            var station: Station?

            // Unit changes along the leg. A leg "starts inside" only if the aircraft was already in the
            // unit before the waypoint (or departs from inside it); an entry right AT the waypoint is
            // still an entry, so it can be called for on the leg before.
            var startUnit: Int? = k == 0 ? active[first] : active[first - 1]
            if k > 0, active[first] != startUnit, active[first] == nil { startUnit = nil }
            var transitions: [(s: Int, to: Int?, from: Int?)] = []
            var current = startUnit
            for s in legRange where active[s] != current {
                transitions.append((s, active[s], current))
                current = active[s]
            }
            func offset(_ s: Int) -> String { String(format: "+%.1f NM", samples[s].d - legStart) }
            func entryRemarks(_ u: Int, _ s: Int, withStation: Bool) -> [String] {
                let st = stationOf(unit: u)
                var head = "▸ \(label(units[u].airspace)) \(offset(s))"
                if withStation { head += " · \(st.callSign) \(st.frequency)" }
                if st.isHX { head += " · HX" }
                var out = [head]
                var detail = "\(compactLimit(units[u].airspace.lowerCeiling))–\(compactLimit(units[u].airspace.upperCeiling))"
                let span = units[u].vertical.enumerated().filter { $0.element }.map { samples[$0.offset].d }
                if let lo = span.first, let hi = span.last, hi - lo < 2 {
                    detail = String(format: "%.1f NM clip · ", hi - lo) + detail
                }
                out.append(detail)
                return out
            }

            if let u = startUnit {
                station = stationOf(unit: u)
                unitRow[row] = true
                if k == 0, station?.isHX == true { remarks.append("HX · check activity") }
            } else if let entry = transitions.first, let u = entry.to {
                station = stationOf(unit: u)
                unitRow[row] = true
                let entryNM = samples[entry.s].d - legStart
                if k > 0, entryNM / speed < ctx.leadTime {
                    // Too close behind the waypoint to call on this leg: the call goes on the leg before.
                    let wptName = displayName(wps[k], index: k)
                    let at = entryNM < 0.5 ? "at \(wptName)" : String(format: "+%.1f NM after %@", entryNM, wptName)
                    let hx = station?.isHX == true ? " · HX" : ""
                    carried[k] = Pending(station: stationOf(unit: u), remark: "▸ \(label(units[u].airspace)) \(at)\(hx)")
                } else {
                    remarks.append(contentsOf: entryRemarks(u, entry.s, withStation: false))
                }
                transitions.removeFirst()
            } else {
                let mid = CLLocationCoordinate2D(
                    latitude: (wps[k].latitude + wps[k + 1].latitude) / 2,
                    longitude: (wps[k].longitude + wps[k + 1].longitude) / 2)
                station = ctx.fis(mid)
            }
            for t in transitions {
                if let to = t.to {
                    let same = stationOf(unit: to).hasSameFrequency(as: station)
                    remarks.append(entryRemarks(to, t.s, withStation: !same)[0])
                } else if let from = t.from {
                    remarks.append("leave \(shortLabel(units[from].airspace)) \(offset(t.s))")
                }
            }

            // Airspace just above the leg (within 500 ft under its floor) — the route may never enter it.
            let below = overhead
                .filter { t in legRange.contains { t.below[$0] } && !legRange.contains { t.vertical[$0] } }
            remarks.append(contentsOf: belowRemarks(below.map {
                (kind(of: $0.airspace) == .check ? checkAreaName($0.airspace) : cleanName($0.airspace.name),
                 Int($0.airspace.lowerCeiling.asFeetMSL.rounded()))
            }))

            // Areas to check before flight, where the leg enters them.
            for t in checks {
                guard let s = legRange.first(where: { t.vertical[$0] && ($0 == 0 || !t.vertical[$0 - 1]) }) else { continue }
                var text = "\(checkAreaName(t.airspace)) " + String(format: "+%.1f NM", samples[s].d - legStart)
                    + " · \(ctx.checkAreaTag)"
                if let f = t.airspace.primaryFrequency { text += " · \(Station.normalized(f.value))" }
                remarks.append(text)
                if !plan.checkAreas.contains(checkAreaName(t.airspace)) { plan.checkAreas.append(checkAreaName(t.airspace)) }
            }

            plan.rows[row].station = station
            plan.rows[row].remarks = remarks
        }

        // Calls carried back one leg. A row that already talks to an airspace keeps it and notes the
        // next call; a FIS row gives way.
        for (row, pending) in carried.sorted(by: { $0.key < $1.key }) where row >= 1 {
            if unitRow[row] && !pending.station.hasSameFrequency(as: plan.rows[row].station) {
                plan.rows[row].remarks.append("then \(pending.station.callSign) \(pending.station.frequency)")
            } else {
                plan.rows[row].station = pending.station
                unitRow[row] = true
            }
            plan.rows[row].remarks.insert(pending.remark, at: 0)
        }

        // Departure: the field's own contact.
        if let contact = ctx.departure?.contact {
            plan.rows[0].station = contact
        } else if let u = active.first ?? nil {
            plan.rows[0].station = stationOf(unit: u)
        }

        // Destination: its contact on the last leg unless an airspace already governs it. A last leg
        // under three minutes moves the call one leg earlier.
        let lastLeg = n - 2
        if let dest = ctx.destination, let contact = dest.contact, !unitRow[n - 1] {
            if n >= 3, legSeconds[lastLeg] < 3 * 60, !unitRow[n - 2] {
                plan.rows[n - 2].station = contact
                plan.rows[n - 2].remarks.insert("▸ call \(dest.ident) before \(displayName(wps[n - 2], index: n - 2))", at: 0)
            }
            plan.rows[n - 1].station = contact
        }
        if let ground = ctx.destination?.ground { plan.rows[n - 1].remarks.append("GND \(ground)") }

        // Destination ATIS on the last row reached at least `atisLeadTime` before arrival.
        if let dest = ctx.destination, let atis = dest.atis {
            var reached: [TimeInterval] = [0]
            for k in 0..<(n - 1) { reached.append(reached[k] + legSeconds[k]) }
            let arrival = reached[n - 1]
            if let row = (1..<n).last(where: { reached[$0] <= arrival - ctx.atisLeadTime }) {
                plan.rows[row].remarks.append("ATIS \(dest.ident) \(atis)")
            }
        }

        // HX airspace entered anywhere goes on the check list too.
        for t in units where t.airspace.isMilitary {
            let name = shortLabel(t.airspace) + " (HX)"
            if !plan.checkAreas.contains(name) { plan.checkAreas.append(name) }
        }

        applyManual(wps, to: &plan.rows)
        markChanges(&plan.rows)
        plan.stations = listings(plan, departure: ctx.departure, destination: ctx.destination)
        plan.notes = notes(plan, ctx)
        return plan
    }

    /// Only what was typed on the waypoints — the export's fallback when no radio plan was built.
    static func manualOnly(_ waypoints: [FlightPlanWaypoint]) -> Plan {
        var plan = Plan(rows: Array(repeating: Row(), count: waypoints.count))
        applyManual(waypoints, to: &plan.rows)
        markChanges(&plan.rows)
        plan.stations = listings(plan, departure: nil, destination: nil)
        return plan
    }

    // MARK: - Rows

    private static func applyManual(_ wps: [FlightPlanWaypoint], to rows: inout [Row]) {
        for (i, wp) in wps.enumerated() where i < rows.count {
            guard let f = wp.frequency?.trimmingCharacters(in: .whitespaces), !f.isEmpty else { continue }
            rows[i].station = Station(frequency: f, callSign: wp.callSign ?? "")
            rows[i].isManual = true
        }
    }

    private static func markChanges(_ rows: inout [Row]) {
        var previous: Station?
        for i in rows.indices {
            guard let station = rows[i].station else { rows[i].changed = false; previous = nil; continue }
            rows[i].changed = !station.hasSameFrequency(as: previous)
            previous = station
        }
    }

    private static func listings(_ plan: Plan, departure: Aerodrome?, destination: Aerodrome?) -> [Listing] {
        var out: [Listing] = []
        func add(_ l: Listing) {
            if !out.contains(where: { $0.label == l.label && Station.normalized($0.frequency) == Station.normalized(l.frequency) }) {
                out.append(l)
            }
        }
        if let dep = departure {
            if let atis = dep.atis { add(Listing(label: "\(dep.ident) ATIS", frequency: atis)) }
            if let gnd = dep.ground { add(Listing(label: "\(dep.ident) GND", frequency: gnd)) }
        }
        var seen: [Station] = []
        for row in plan.rows {
            guard let st = row.station, !seen.contains(where: { $0.hasSameFrequency(as: st) }) else { continue }
            seen.append(st)
            add(Listing(label: st.callSign.isEmpty ? "—" : st.callSign, frequency: st.frequency,
                        marker: (st.inferredFrom != nil ? "†" : "") + (st.isHX ? " (HX)" : "")))
        }
        if let dest = destination {
            if let atis = dest.atis { add(Listing(label: "\(dest.ident) ATIS", frequency: atis)) }
            if let gnd = dest.ground { add(Listing(label: "\(dest.ident) GND", frequency: gnd)) }
        }
        add(emergency)
        return out
    }

    private static func notes(_ plan: Plan, _ ctx: Context) -> [String] {
        var out: [String] = []
        var inferred: [(String, String)] = []
        for row in plan.rows {
            guard let st = row.station, let from = st.inferredFrom,
                  !inferred.contains(where: { $0.1 == from && $0.0 == st.callSign }) else { continue }
            inferred.append((st.callSign, from))
        }
        for (callSign, from) in inferred {
            out.append(L10n.Export.inferredFrequency(callSign, from))
        }
        if !ctx.missingAirspaceCountries.isEmpty {
            out.append(L10n.Export.missingAirspace(ctx.missingAirspaceCountries.joined(separator: ", ")))
        }
        return out
    }

    // MARK: - Geometry

    struct Sample { let coordinate: CLLocationCoordinate2D; let d: Double; let leg: Int }

    static func samplePoints(_ wps: [FlightPlanWaypoint], cum: [Double], step: Double) -> [Sample] {
        var out: [Sample] = []
        for k in 0..<(wps.count - 1) {
            let a = wps[k].coordinate, b = wps[k + 1].coordinate
            let legNM = cum[k + 1] - cum[k]
            let steps = max(1, Int((legNM / max(0.02, step)).rounded(.up)))
            for s in 0..<steps {
                let t = Double(s) / Double(steps)
                out.append(Sample(
                    coordinate: CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                       longitude: a.longitude + (b.longitude - a.longitude) * t),
                    d: cum[k] + legNM * t, leg: k))
            }
        }
        if let last = wps.last { out.append(Sample(coordinate: last.coordinate, d: cum.last ?? 0, leg: wps.count - 2)) }
        return out
    }

    struct Track {
        let airspace: Airspace
        /// Horizontally inside AND at the planned altitude.
        let vertical: [Bool]
        /// Horizontally inside, within 500 ft under the floor.
        let below: [Bool]
        var anyVertical: Bool { vertical.contains(true) }
    }

    private static func track(_ airspace: Airspace, samples: [Sample], profile: RouteAltitudeProfile) -> Track? {
        let floor = airspace.lowerCeiling.asFeetMSL
        let ceiling = airspace.upperCeiling.asFeetMSL
        var vertical = [Bool](repeating: false, count: samples.count)
        var below = [Bool](repeating: false, count: samples.count)
        var any = false
        for (i, s) in samples.enumerated() where airspace.containsPoint(s.coordinate) {
            any = true
            // No altitude profile at all → a horizontal crossing counts (the builder's rule).
            guard let alt = profile.altitude(atNM: s.d) else { vertical[i] = true; continue }
            if alt >= floor && alt <= ceiling {
                vertical[i] = true
            } else if floor > 0, alt < floor, alt >= floor - 500 {
                below[i] = true
            }
        }
        return any ? Track(airspace: airspace, vertical: vertical, below: below) : nil
    }

    private static func distanceNM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852.0
    }

    // MARK: - Classification & naming

    enum Kind { case unit, check, ignore }

    /// `unit`: needs a clearance or a call (it sets the frequency). `check`: active by NOTAM/DABS —
    /// listed, never a frequency. Everything else (class E/G TMA, TMZ, FIR, airways) is ignored.
    static func kind(of airspace: Airspace) -> Kind {
        switch airspace.airspaceType {
        case .ctr, .rmz, .atz, .matz, .tiz, .tia:
            return .unit
        case .tma, .cta:
            switch airspace.airspaceClass {
            case .classA?, .classB?, .classC?, .classD?: return .unit
            default: return .ignore
            }
        case .restricted, .danger, .prohibited, .gliderSector, .tra, .tsa, .traTemp, .tsaTemp,
             .interditP, .interditR, .mta, .alertArea, .warningArea:
            return .check
        default:
            return .ignore
        }
    }

    /// The station for a unit: its own primary frequency, else the frequency of a same-name sibling
    /// (every TMA BERN n publishes none, CTR BERN does), marked as inferred.
    static func unitStation(_ airspace: Airspace, among all: [Airspace]) -> Station {
        if let f = airspace.primaryFrequency {
            return Station(frequency: Station.normalized(f.value),
                           callSign: callSign(f.name ?? airspace.shortName), isHX: airspace.isMilitary)
        }
        let base = baseName(airspace.name)
        let siblings = all.filter { $0.id != airspace.id && $0.primaryFrequency != nil && baseName($0.name) == base }
        if let sibling = siblings.first(where: { $0.airspaceType == .ctr }) ?? siblings.first,
           let f = sibling.primaryFrequency {
            return Station(frequency: Station.normalized(f.value), callSign: callSign(f.name ?? sibling.shortName),
                           // HX is the airspace's own activation: CTR BERN (HX) says nothing about TMA BERN 1.
                           inferredFrom: cleanName(sibling.name), isHX: airspace.isMilitary)
        }
        return Station(frequency: "—", callSign: shortLabel(airspace), isHX: airspace.isMilitary)
    }

    /// "ZUERICH TOWER" → "ZUERICH TWR"; "SAMEDAN INFORMATION" → "SAMEDAN INFO".
    static func callSign(_ name: String) -> String {
        let map = ["TOWER": "TWR", "INFORMATION": "INFO", "APPROACH": "APP", "GROUND": "GND",
                   "DELIVERY": "DEL", "AERODROME": "AD"]
        return name.uppercased().split(separator: " ").map { map[String($0)] ?? String($0) }.joined(separator: " ")
    }

    /// "TMA BERN 1" / "CTR BERN (HX)" → "BERN"; "TMA BALE ZURICH AZ4 T3" → "BALE ZURICH".
    static func baseName(_ name: String) -> String {
        var tokens = cleanName(name).uppercased().split(separator: " ").map(String.init)
        if let first = tokens.first, ["CTR", "TMA", "CTA", "ATZ", "RMZ", "FIZ", "TIZ", "TIA"].contains(first) {
            tokens.removeFirst()
        }
        while let last = tokens.last, tokens.count > 1,
              last.range(of: "^[A-Z]{0,2}[0-9]+[A-Z]?$", options: .regularExpression) != nil {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    /// The name without OpenAIP's parenthesised activation notes ("(HX)", "(NOTAM)").
    static func cleanName(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Vertical limit as a nav log has room for: "GND", "3500 ft", "2000 ft AGL", "FL100".
    static func compactLimit(_ limit: AltitudeLimit) -> String {
        if limit.unit == 6 { return "FL\(limit.value)" }
        if limit.referenceDatum == 0 && limit.value == 0 { return "GND" }
        let feet = limit.unit == 0 ? Int((Double(limit.value) * 3.28084).rounded()) : limit.value
        return limit.referenceDatum == 0 ? "\(feet) ft AGL" : "\(feet) ft"
    }

    /// "TMA BERN 1 (D)", "CTR MEIRINGEN (D)", "FIZ SAMEDAN (RMZ)".
    static func label(_ airspace: Airspace) -> String {
        let name = cleanName(airspace.name)
        switch airspace.airspaceType {
        case .ctr, .tma, .cta:
            return airspace.airspaceClass.map { "\(name) (\($0.letter))" } ?? name
        case .rmz where !name.uppercased().hasPrefix("RMZ"):
            return "\(name) (RMZ)"
        default:
            return name
        }
    }

    static func shortLabel(_ airspace: Airspace) -> String {
        cleanName(airspace.name)
    }

    /// OpenAIP's "LSR29 TAVANNES" → "LS-R29 Tavannes". Names that don't follow the Swiss pattern are
    /// printed as they come.
    static func checkAreaName(_ airspace: Airspace) -> String {
        let name = cleanName(airspace.name)
        guard let match = name.range(of: #"^LS-?([RDP])-?([0-9]+[A-Z]?)\s+(.+)$"#, options: .regularExpression),
              match.lowerBound == name.startIndex else { return name }
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        let ident = parts[0].replacingOccurrences(of: "-", with: "")
        let letter = ident.dropFirst(2).prefix(1)
        let number = ident.dropFirst(3)
        return "LS-\(letter)\(number) " + parts[1].capitalized
    }

    /// "below TMA BERN 2 / 4 (5500)" — airspaces sharing a floor and a name stem are folded together.
    static func belowRemarks(_ airspaces: [(name: String, floor: Int)]) -> [String] {
        var byFloor: [(floor: Int, names: [String])] = []
        for (name, floor) in airspaces {
            if let i = byFloor.firstIndex(where: { $0.floor == floor }) {
                if !byFloor[i].names.contains(name) { byFloor[i].names.append(name) }
            } else {
                byFloor.append((floor, [name]))
            }
        }
        return byFloor.map { "below \(foldNames($0.names)) (\($0.floor))" }
    }

    /// ["TMA BERN 2", "TMA BERN 4"] → "TMA BERN 2 / 4".
    static func foldNames(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        let split = names.map { $0.split(separator: " ").map(String.init) }
        let stems = Set(split.map { $0.dropLast().joined(separator: " ") })
        if stems.count == 1, let stem = stems.first, !stem.isEmpty {
            return stem + " " + split.map { $0.last ?? "" }.joined(separator: " / ")
        }
        return names.joined(separator: " / ")
    }

    static func displayName(_ wp: FlightPlanWaypoint, index: Int) -> String {
        wp.name.isEmpty ? "WP \(index + 1)" : wp.name
    }

    // MARK: - Swiss FIS

    /// The area FIS from the same table and sector split as the in-flight FREQ panel, so paper and
    /// screen agree. Nil outside Switzerland (the caller checks the border).
    static func swissFIS(at coordinate: CLLocationCoordinate2D) -> Station {
        let common: SwissCommonFrequency
        switch SwissAirspaceSectors.getSector(for: coordinate) {
        case .zurich: common = .zurichInfo
        case .geneva: common = .genevaInfo
        case .east: common = .fisEast
        case .west: common = .fisWest
        }
        return Station(frequency: common.frequency, callSign: common.name.uppercased())
    }
}

// MARK: - Service glue

extension RouteRadioPlanner {
    /// Builds the context from the app's airspace and airport data and plans the route. Waits for both
    /// datasets to load (they are lazy); with none downloaded it still returns the aerodrome contacts
    /// and a note saying what is missing.
    @MainActor
    static func plan(for flightPlan: FlightPlan, openAIP: OpenAIPDataService,
                     airports: AirportDataService) async -> Plan {
        let wps = flightPlan.waypoints
        guard wps.count >= 2 else { return .empty }
        await openAIP.ensureLoaded()
        await airports.ensureLoaded()

        let coords = wps.map(\.coordinate)
        let crossed = countriesInside(coords)
        let downloaded = Set(openAIP.downloadedCountries)
        let covered = crossed.filter { downloaded.contains($0) }
        var source: String?
        if !covered.isEmpty {
            let date = openAIP.lastUpdated.map { navLogDateFormatter.string(from: $0) }
            source = "OpenAIP " + covered.joined(separator: ", ") + (date.map { " · \($0)" } ?? "")
        }

        let ctx = Context(
            waypoints: wps,
            airspaces: openAIP.airspacesAlongRoute(coords),
            departure: aerodrome(for: wps[0], airports: airports),
            destination: aerodrome(for: wps[wps.count - 1], airports: airports),
            fis: { coordinate in
                CountryBoundaries.shared.countries(near: coordinate, bufferNm: 0).contains("CH")
                    ? swissFIS(at: coordinate) : nil
            },
            missingAirspaceCountries: crossed.filter { !downloaded.contains($0) },
            airspaceSource: source,
            checkAreaTag: crossed.contains("CH") ? "DABS" : "NOTAM")
        return plan(ctx)
    }

    /// Countries the route actually enters (no border buffer: a frontier skirted at 5 NM is not
    /// airspace data the nav log is missing).
    @MainActor
    static func countriesInside(_ coords: [CLLocationCoordinate2D]) -> [String] {
        var found: [String] = []
        for sample in RouteDataCalculator.sampledPoints(for: coords) {
            for code in CountryBoundaries.shared.countries(near: sample, bufferNm: 0).sorted() where !found.contains(code) {
                found.append(code)
            }
        }
        return found
    }

    /// The aerodrome a route endpoint sits on, matched by position (the name need not be an ICAO code:
    /// SkyDemon calls LSZQ "Bressaucourt").
    @MainActor
    static func aerodrome(for wp: FlightPlanWaypoint, airports: AirportDataService) -> Aerodrome? {
        let byName = airports.findAirport(byIdent: wp.name.uppercased())
            .flatMap { $0.distance(from: wp.coordinate) <= 2 ? $0 : nil }
        guard let airport = byName ?? airports.nearestAirport(to: wp.coordinate, maxDistanceNm: 1.0) else { return nil }
        let freqs = airports.getFrequencies(for: airport.ident)
        var contact: Station?
        for type in AirportDataService.fieldContactPriority {
            if let f = freqs.first(where: { $0.type.uppercased().contains(type) }) {
                contact = Station(frequency: f.formattedFrequency, callSign: "\(airport.ident) \(type)")
                break
            }
        }
        let atis = freqs.first { $0.type.uppercased().contains("ATIS") }?.formattedFrequency
        let ground = freqs.first { $0.type.uppercased().contains("GND") || $0.type.uppercased().contains("GROUND") }?
            .formattedFrequency
        return Aerodrome(ident: airport.ident, contact: contact, atis: atis, ground: ground)
    }

    static let navLogDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()
}
