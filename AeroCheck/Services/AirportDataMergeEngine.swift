import Foundation
import CoreLocation

/// Pure, testable engine that folds OpenAIP airports into the OurAirports `Airport` backbone. Computed
/// ONCE at load (never per-query), then cached in `AirportDataService`. (v4.1.0)
///
/// Produces three outputs, each UNION-merged by `AirportDataService` (OpenAIP wins on a match, OurAirports
/// gap-fills): airport identity+position (`mergeOutcome`), frequencies (`openAIPFrequencies`), and runways
/// (`mergedRunways`: OpenAIP's per-direction entries paired into le/he `Runway`s by `openAIPRunways`, then
/// matched to the OurAirports runway lying on the same strip by `unionRunways`, so one physical runway
/// keeps OpenAIP's PCN and declared distances AND OurAirports' thresholds, under the designators most
/// sources give it, `RunwayDesignatorOverrides` having the last word).
enum AirportDataMergeEngine {
    /// Two airports sharing an ICAO but more than this far apart are treated as DISTINCT fields
    /// (closed/moved/relocated), not the same airport, so neither overwrites the other.
    static let positionToleranceNm = 1.0

    /// Two runways whose true headings agree within this (either end, modulo 180) lie on the same axis.
    /// Wide enough for the two sources' rounding and survey differences (LSGE: 093 vs 095), narrow enough
    /// that a crossing runway never qualifies.
    static let runwayHeadingToleranceDegrees = 12.0

    /// What the airport merge produced: the airports, and which OpenAIP records it folded in.
    struct MergeOutcome {
        let airports: [Airport]
        /// `_id` of every OpenAIP record that became an airport in `airports`: matched to an OurAirports
        /// field within `positionToleranceNm`, or appended as a field OurAirports lacks. A record kept apart
        /// (same ICAO, farther than the tolerance) is NOT in it: it describes another field, so its runways
        /// and frequencies must not land on the OurAirports one that kept the ident.
        let foldedOpenAIPIds: Set<String>
    }

    /// The merged airports (see `mergeOutcome`).
    static func merge(ourAirports: [Airport], openAIP: [OpenAIPAirport]) -> [Airport] {
        mergeOutcome(ourAirports: ourAirports, openAIP: openAIP).airports
    }

    /// Merge result: OurAirports as the base; an OpenAIP airport that matches an OurAirports ICAO within
    /// tolerance replaces it (OpenAIP's position/elevation/name win; OurAirports' IATA/local/region are
    /// preserved). OpenAIP airports with a usable ICAO and no match are appended (gap-fill). OpenAIP
    /// airports without an ICAO are skipped (the app keys airports on `ident`).
    static func mergeOutcome(ourAirports: [Airport], openAIP: [OpenAIPAirport]) -> MergeOutcome {
        var result = ourAirports
        var folded = Set<String>()
        var indexByIcao: [String: Int] = [:]
        for (i, a) in result.enumerated() {
            let key = a.ident.uppercased()
            if !key.isEmpty { indexByIcao[key] = i }
        }

        for oa in openAIP {
            guard let icaoRaw = oa.icaoCode, !icaoRaw.isEmpty else { continue }
            // Drop invalid coordinates at ingest: a NaN/infinity, or a finite-but-out-of-range magnitude
            // (e.g. `1e30`), would later TRAP in AirportDataService's spatial-grid `Int(...)` conversion and
            // crash every user. `CLLocationCoordinate2DIsValid` rejects all three. (v4.1.0 pre-tag hardening)
            guard CLLocationCoordinate2DIsValid(oa.coordinate) else { continue }
            let icao = icaoRaw.uppercased()
            if let idx = indexByIcao[icao] {
                let existing = result[idx]
                // Same ICAO + close enough → OpenAIP wins (more current European data).
                if existing.distance(from: oa.coordinate) <= positionToleranceNm {
                    result[idx] = makeAirport(from: oa, preserving: existing)
                    folded.insert(oa.id)
                }
                // Else: keep both apart; leave OurAirports in place, don't append a colliding ident.
            } else {
                let new = makeAirport(from: oa, preserving: nil)
                indexByIcao[icao] = result.count
                result.append(new)
                folded.insert(oa.id)
            }
        }
        return MergeOutcome(airports: result, foldedOpenAIPIds: folded)
    }

    /// Build an `Airport` from an OpenAIP record, preserving OurAirports-only fields (IATA, region,
    /// municipality, continent, the stable OurAirports id) when a matched record is supplied.
    private static func makeAirport(from oa: OpenAIPAirport, preserving our: Airport?) -> Airport {
        Airport(
            id: our?.id ?? stableNegativeID(oa.id),
            // Uppercase so an OpenAIP-only airport's ident matches the case-normalised airportsByIdent
            // key + frequency keys + findAirport(byIdent:) (which uppercases the query). (review #6)
            ident: oa.icaoCode?.uppercased() ?? our?.ident ?? oa.id,
            type: oa.airportType,
            name: oa.name,
            latitude: oa.latitude,
            longitude: oa.longitude,
            elevation: oa.elevationFeetMSL ?? our?.elevation,
            continent: our?.continent,
            isoCountry: our?.isoCountry ?? (oa.country ?? ""),
            isoRegion: our?.isoRegion ?? "",
            municipality: our?.municipality,
            scheduledService: our?.scheduledService ?? false,
            gpsCode: our?.gpsCode ?? oa.icaoCode,
            iataCode: our?.iataCode,            // OurAirports wins on IATA (the export rarely has it)
            localCode: our?.localCode
        )
    }

    /// Convert OpenAIP airport frequencies into the app's `AirportFrequency` rows, keyed by ICAO (the
    /// frequency store is looked up by ident). Skips airports without an ICAO or frequencies with a
    /// non-numeric value. Used to give OpenAIP airports full callouts when the merge is on. (v4.1.0)
    static func openAIPFrequencies(from airports: [OpenAIPAirport]) -> [AirportFrequency] {
        var result: [AirportFrequency] = []
        for apt in airports {
            guard let icaoRaw = apt.icaoCode, !icaoRaw.isEmpty else { continue }
            let icao = icaoRaw.uppercased()
            let ref = stableNegativeID(apt.id)
            for (i, freq) in apt.frequencies.enumerated() {
                guard let mhz = Double(freq.value) else { continue }
                result.append(AirportFrequency(
                    id: stableNegativeID("\(apt.id)_freq_\(i)"),
                    airportRef: ref,
                    airportIdent: icao,
                    type: freq.typeLabel,
                    description: freq.name,
                    frequencyMhz: mhz))
            }
        }
        return result
    }

    // MARK: - Runways

    /// The runway list of every airport the merge took from OpenAIP, keyed by ident, ready to replace
    /// `runwaysByAirport[ident]`: `unionRunways` of the two sources, then `RunwayDesignatorOverrides`.
    /// Only the records in `foldedOpenAIPIds` contribute: a same-ICAO record the merge kept apart
    /// describes another field, and its runways used to be unioned onto the OurAirports one all the same.
    static func mergedRunways(
        ourRunwaysByIdent: [String: [Runway]],
        openAIP: [OpenAIPAirport],
        foldedOpenAIPIds: Set<String>
    ) -> [String: [Runway]] {
        let folded = openAIP.filter { foldedOpenAIPIds.contains($0.id) }
        var result: [String: [Runway]] = [:]
        for (ident, rwys) in Dictionary(grouping: openAIPRunways(from: folded), by: { $0.airportIdent }) {
            let union = unionRunways(our: ourRunwaysByIdent[ident] ?? [], openAIP: rwys)
            result[ident] = RunwayDesignatorOverrides.apply(to: union, ident: ident)
        }
        return result
    }

    /// Convert OpenAIP airport runways into the app's `Runway` rows, keyed by ICAO. OpenAIP lists each
    /// runway DIRECTION separately (e.g. "10" and "28"); this pairs opposite directions into one le/he
    /// `Runway`, carrying OpenAIP's richer data (PCN + per-direction declared distances). A direction whose
    /// designated reciprocal is missing pairs with a lone direction on the reciprocal true heading instead
    /// (LSPM lists "10" and "27", a typo for 28); one with no partner at all becomes an LE-only runway.
    /// A repeated designator keeps one entry (`preferredDuplicate`). Skips airports without an ICAO.
    /// (v4.1.0 runway merge)
    static func openAIPRunways(from airports: [OpenAIPAirport]) -> [Runway] {
        var result: [Runway] = []
        for apt in airports {
            guard let icaoRaw = apt.icaoCode, !icaoRaw.isEmpty else { continue }
            let icao = icaoRaw.uppercased()
            let ref = stableNegativeID(apt.id)

            // Index this airport's directions by canonical "<number><suffix>" key (e.g. "10", "16L").
            var byKey: [String: OpenAIPDirection] = [:]
            var order: [String] = []
            for rwy in apt.runways {
                guard let (num, suffix) = parseDesignator(rwy.designator) else { continue }
                let key = "\(num)\(suffix)"
                let direction = OpenAIPDirection(entry: rwy, number: num, suffix: suffix)
                if let kept = byKey[key] {
                    if preferredDuplicate(rwy, over: kept.entry) { byKey[key] = direction }
                } else {
                    byKey[key] = direction
                    order.append(key)
                }
            }

            var consumed = Set<String>()
            var pairs: [OpenAIPDirectionPair] = []
            for key in order {
                guard !consumed.contains(key), let this = byKey[key] else { continue }
                consumed.insert(key)
                let (oppNum, oppSuffix) = oppositeDesignator(number: this.number, suffix: this.suffix)
                let oppKey = "\(oppNum)\(oppSuffix)"
                if let opp = byKey[oppKey], !consumed.contains(oppKey) {
                    consumed.insert(oppKey)
                    pairs.append(lowerNumberFirst(this, opp))
                } else {
                    pairs.append(OpenAIPDirectionPair(le: this, he: nil))
                }
            }
            for pair in pairingLoneDirectionsByHeading(pairs) {
                result.append(makeRunway(aptId: apt.id, ref: ref, icao: icao, le: pair.le.entry, he: pair.he?.entry))
            }
        }
        return result
    }

    /// Which of two entries under the same designator to keep: the main runway, else the longer one, else
    /// the first. LSZG lists "06"/"24" twice, a 700 m grass strip (OpenAIP's 06R/24L again) before the
    /// 1000 m main asphalt, and first-wins made Grenchen's main runway that grass strip.
    private static func preferredDuplicate(_ candidate: OpenAIPRunway, over kept: OpenAIPRunway) -> Bool {
        if candidate.mainRunway != kept.mainRunway { return candidate.mainRunway }
        return (candidate.lengthFeet ?? 0) > (kept.lengthFeet ?? 0)
    }

    /// One OpenAIP runway direction with its parsed designator.
    private struct OpenAIPDirection {
        let entry: OpenAIPRunway
        let number: Int
        let suffix: String
    }

    /// Two OpenAIP directions paired into one runway (`he` nil while it has no partner).
    private struct OpenAIPDirectionPair {
        let le: OpenAIPDirection
        let he: OpenAIPDirection?
    }

    /// Lower runway number is the LE end (e.g. "10" before "28", "16L" before "34R").
    private static func lowerNumberFirst(_ a: OpenAIPDirection, _ b: OpenAIPDirection) -> OpenAIPDirectionPair {
        a.number <= b.number ? OpenAIPDirectionPair(le: a, he: b) : OpenAIPDirectionPair(le: b, he: a)
    }

    /// Pairs the directions the designator pairing left alone when their true headings are reciprocal
    /// (within `runwayHeadingToleranceDegrees`) and their suffixes mirror each other, closest first.
    private static func pairingLoneDirectionsByHeading(_ pairs: [OpenAIPDirectionPair]) -> [OpenAIPDirectionPair] {
        let lone = pairs.indices.filter { pairs[$0].he == nil }
        guard lone.count > 1 else { return pairs }
        var couples: [(deviation: Double, a: Int, b: Int)] = []
        for (n, a) in lone.enumerated() {
            for b in lone[(n + 1)...] {
                let first = pairs[a].le, second = pairs[b].le
                guard let h1 = finiteHeading(first.entry.trueHeading), let h2 = finiteHeading(second.entry.trueHeading),
                      suffixesCompatible(oppositeSuffix(first.suffix), second.suffix) else { continue }
                let deviation = abs(angularDifference(h1, h2) - 180)
                if deviation <= runwayHeadingToleranceDegrees { couples.append((deviation, a, b)) }
            }
        }
        var out = pairs
        var used = Set<Int>(), dropped = Set<Int>()
        for couple in couples.sorted(by: { ($0.deviation, $0.a, $0.b) < ($1.deviation, $1.a, $1.b) })
        where !used.contains(couple.a) && !used.contains(couple.b) {
            out[couple.a] = lowerNumberFirst(pairs[couple.a].le, pairs[couple.b].le)
            used.formUnion([couple.a, couple.b])
            dropped.insert(couple.b)
        }
        return out.indices.filter { !dropped.contains($0) }.map { out[$0] }
    }

    /// UNION an airport's runways from both sources, so that one physical strip shows once. Each OpenAIP
    /// runway is matched to at most one OurAirports runway: first by the exact designator key
    /// (`runwayKey`); then, for the rest, physically (`physicalMatch`: the same parallel suffix AND true
    /// headings within `runwayHeadingToleranceDegrees`, or designator numbers within ±1 when either side has
    /// no heading). Closest pairs first, and an open OurAirports runway before a closed one. A matched pair
    /// becomes one runway (`mergedRunway`); unmatched runways from either side are kept (OpenAIP lacks the
    /// runways of ~62% of airports, and a parallel grass strip is often in one source only). Pure + testable.
    static func unionRunways(our: [Runway], openAIP: [Runway]) -> [Runway] {
        var ourTaken = [Bool](repeating: false, count: our.count)
        var partner: [Int: (ourIndex: Int, straight: Bool)] = [:]
        // Open runways first: a closed OurAirports record (an old strip, a helipad) never takes an open one's match.
        let ourOrder = our.indices.sorted { (our[$0].closed ? 1 : 0, $0) < (our[$1].closed ? 1 : 0, $1) }

        // 1. The same designators (zero padding, end order and case aside).
        let ourKeys = our.map { runwayKey($0) }
        for (j, rwy) in openAIP.enumerated() {
            let key = runwayKey(rwy)
            guard let i = ourOrder.first(where: { !ourTaken[$0] && ourKeys[$0] == key }) else { continue }
            ourTaken[i] = true
            partner[j] = (i, endsAlignStraight(our: our[i], openAIP: rwy))
        }

        // 2. The same strip under other designators (LSGC: OurAirports 05/23, OpenAIP 06/24).
        var candidates: [(closed: Int, score: Double, j: Int, i: Int, straight: Bool)] = []
        for j in openAIP.indices where partner[j] == nil {
            for i in our.indices where !ourTaken[i] {
                guard let match = physicalMatch(our[i], openAIP[j]) else { continue }
                candidates.append((our[i].closed ? 1 : 0, match.score, j, i, match.straight))
            }
        }
        candidates.sort { ($0.closed, $0.score, $0.j, $0.i) < ($1.closed, $1.score, $1.j, $1.i) }
        for candidate in candidates where partner[candidate.j] == nil && !ourTaken[candidate.i] {
            ourTaken[candidate.i] = true
            partner[candidate.j] = (candidate.i, candidate.straight)
        }

        var result = openAIP.indices.map { j -> Runway in
            guard let match = partner[j] else { return openAIP[j] }
            return mergedRunway(our: our[match.ourIndex], openAIP: openAIP[j], straight: match.straight)
        }
        result += our.indices.filter { !ourTaken[$0] }.map { our[$0] }
        return result
    }

    /// Whether two runways lie on the same strip and, if so, how their ends line up (`straight`: the LE of
    /// `a` meets the LE of `b`): the same parallel suffix once lined up (`suffixesCompatible`) AND true
    /// headings within `runwayHeadingToleranceDegrees` (either end, modulo 180), or, when either has no
    /// heading, designator numbers within ±1 (36 meets 01). `score` ranks rival candidates: degrees apart,
    /// a designator step counting as 10°.
    static func physicalMatch(_ a: Runway, _ b: Runway) -> (score: Double, straight: Bool)? {
        guard let endA = leOrientedDesignator(a), let endB = leOrientedDesignator(b) else { return nil }
        let match: (score: Double, straight: Bool)
        if let headingA = leOrientedHeading(a), let headingB = leOrientedHeading(b) {
            let apart = angularDifference(headingA, headingB)
            if apart <= runwayHeadingToleranceDegrees {
                match = (apart, true)
            } else if 180 - apart <= runwayHeadingToleranceDegrees {
                match = (180 - apart, false)
            } else {
                return nil
            }
        } else {
            let direct = designatorDistance(endA.number, endB.number)
            let reversed = designatorDistance(endA.number, reciprocalNumber(endB.number))
            if direct <= 1 {
                match = (Double(direct) * 10, true)
            } else if reversed <= 1 {
                match = (Double(reversed) * 10, false)
            } else {
                return nil
            }
        }
        // Once the ends are lined up, L must meet L (a runway's HE suffix is its LE's mirrored).
        let suffixB = match.straight ? endB.suffix : oppositeSuffix(endB.suffix)
        guard suffixesCompatible(endA.suffix, suffixB) else { return nil }
        return match
    }

    /// For a pair matched by key: LE meets LE, unless one source lists the ends the other way round ("27/09").
    private static func endsAlignStraight(our: Runway, openAIP: Runway) -> Bool {
        guard let ourEnd = leOrientedDesignator(our), let theirEnd = leOrientedDesignator(openAIP) else { return true }
        return designatorDistance(ourEnd.number, theirEnd.number)
            <= designatorDistance(ourEnd.number, reciprocalNumber(theirEnd.number))
    }

    /// Whether two lined-up ends can be the same strip: L meets L and R meets R; no suffix and C are the
    /// same thing (a lone runway is the centre one). OurAirports' "G" (grass, not an ICAO suffix: LSGS
    /// 07G/25G is OpenAIP's 07L/25R) meets any; the exact-key pass runs first, so it never steals a runway
    /// that has its own name.
    private static func suffixesCompatible(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs == "C" ? "" : lhs
        let right = rhs == "C" ? "" : rhs
        return left == right || left == "G" || right == "G"
    }

    /// One end of a runway, as either source describes it.
    private struct RunwayEnd {
        let ident: String?
        let latitude: Double?
        let longitude: Double?
        let elevationFt: Int?
        let headingDegT: Double?
        let displacedThresholdFt: Int?
        let toraFt: Int?
        let ldaFt: Int?

        static func le(of r: Runway) -> RunwayEnd {
            RunwayEnd(ident: r.leIdent, latitude: r.leLatitude, longitude: r.leLongitude,
                      elevationFt: r.leElevationFt, headingDegT: r.leHeadingDegT,
                      displacedThresholdFt: r.leDisplacedThresholdFt, toraFt: r.leToraFt, ldaFt: r.leLdaFt)
        }

        static func he(of r: Runway) -> RunwayEnd {
            RunwayEnd(ident: r.heIdent, latitude: r.heLatitude, longitude: r.heLongitude,
                      elevationFt: r.heElevationFt, headingDegT: r.heHeadingDegT,
                      displacedThresholdFt: r.heDisplacedThresholdFt, toraFt: r.heToraFt, ldaFt: r.heLdaFt)
        }
    }

    /// One runway out of a matched pair, ends lined up by `straight`. Designators: the vote of
    /// `majorityDesignators` (two sources that differ are a tie, which OurAirports wins); an end the winner
    /// leaves unnamed takes the other source's name only when the two agree. Per end, the geometry
    /// (threshold position, elevation, displaced threshold) is OurAirports' (OpenAIP publishes none), the
    /// true heading OpenAIP's when it has one, TORA/LDA OpenAIP's. Shared: length/width/surface from
    /// OpenAIP, OurAirports filling what it lacks; lighting, PCN, `closed` and the stable id from OpenAIP,
    /// as before; `airportRef` from OurAirports, whose id the merged airport keeps.
    private static func mergedRunway(our: Runway, openAIP: Runway, straight: Bool) -> Runway {
        typealias EndPair = (our: RunwayEnd, their: RunwayEnd)
        let ourLE = RunwayEnd.le(of: our), ourHE = RunwayEnd.he(of: our)
        let theirLE = RunwayEnd.le(of: openAIP), theirHE = RunwayEnd.he(of: openAIP)
        let ourVote = RunwayDesignatorVote(source: .ourAirports, leIdent: our.leIdent, heIdent: our.heIdent)
        let theirVote = RunwayDesignatorVote(source: .openAIP, leIdent: openAIP.leIdent, heIdent: openAIP.heIdent)
        let ourNames = majorityDesignators([ourVote, theirVote])?.source != .openAIP
        let agree = designatorVoteKey(ourVote) == designatorVoteKey(theirVote)
        // The merged ends, oriented like the source whose designators win.
        let le: EndPair = ourNames ? (ourLE, straight ? theirLE : theirHE) : (straight ? ourLE : ourHE, theirLE)
        let he: EndPair = ourNames ? (ourHE, straight ? theirHE : theirLE) : (straight ? ourHE : ourLE, theirHE)
        func ident(_ end: EndPair) -> String? {
            let (winning, other) = ourNames ? (end.our.ident, end.their.ident) : (end.their.ident, end.our.ident)
            return winning ?? (agree ? other : nil)
        }
        return Runway(
            id: openAIP.id,
            airportRef: our.airportRef,
            airportIdent: openAIP.airportIdent,
            lengthFt: openAIP.lengthFt ?? our.lengthFt,
            widthFt: openAIP.widthFt ?? our.widthFt,
            surface: nonEmpty(openAIP.surface) ?? our.surface,
            lighted: openAIP.lighted,
            closed: openAIP.closed,
            leIdent: ident(le),
            leLatitude: le.our.latitude, leLongitude: le.our.longitude, leElevationFt: le.our.elevationFt,
            leHeadingDegT: le.their.headingDegT ?? le.our.headingDegT,
            leDisplacedThresholdFt: le.our.displacedThresholdFt,
            heIdent: ident(he),
            heLatitude: he.our.latitude, heLongitude: he.our.longitude, heElevationFt: he.our.elevationFt,
            heHeadingDegT: he.their.headingDegT ?? he.our.headingDegT,
            heDisplacedThresholdFt: he.our.displacedThresholdFt,
            pcn: openAIP.pcn,
            leToraFt: le.their.toraFt, leLdaFt: le.their.ldaFt,
            heToraFt: he.their.toraFt, heLdaFt: he.their.ldaFt
        )
    }

    // MARK: - Designators

    /// A source of runway designators. The order is the tie-break: on a tie the earliest wins. OurAirports
    /// comes first because it was right in 5 of the 6 Swiss numbering disagreements checked against AD
    /// INFO, NOTAMs and the press on 2026-10-01 (OpenAIP in 3); the magnetic heading is no guide (LSZH
    /// keeps 10/28, 14/32 and 16/34 where it reads 09, 13 and 15).
    enum RunwayDesignatorSource: Int, CaseIterable, Sendable {
        case ourAirports
        case openAIP
        /// The open flightmaps dataset, a third vote planned for 6.2.0. Nothing produces it yet.
        case openFlightmaps
    }

    /// One source's designators for a physical runway, ends as that source lists them.
    struct RunwayDesignatorVote: Equatable, Sendable {
        let source: RunwayDesignatorSource
        let leIdent: String?
        let heIdent: String?
    }

    /// The designators a physical runway shows: those of the most sources (compared by
    /// `designatorVoteKey`, so "9/27" agrees with "09/27" and "27/09"); on a tie, the earliest source in
    /// `RunwayDesignatorSource` order among the tied groups. A pair whose ends aren't reciprocal (OpenAIP's
    /// LSPM "10/27") only votes when no source offers a reciprocal one. Returns the winning group's
    /// earliest vote, nil for no votes.
    static func majorityDesignators(_ votes: [RunwayDesignatorVote]) -> RunwayDesignatorVote? {
        let reciprocal = votes.filter { isReciprocal($0) }
        let voters = reciprocal.isEmpty ? votes : reciprocal
        var best: (size: Int, first: RunwayDesignatorVote)?
        for group in Dictionary(grouping: voters, by: { designatorVoteKey($0) }).values {
            guard let first = group.min(by: { $0.source.rawValue < $1.source.rawValue }) else { continue }
            if let current = best, current.size > group.count
                || (current.size == group.count && current.first.source.rawValue < first.source.rawValue) {
                continue
            }
            best = (group.count, first)
        }
        return best?.first
    }

    /// A vote's designators in a form two sources can be compared on: both ends canonical (zero-padded),
    /// a missing end filled with the other's reciprocal, the pair sorted.
    private static func designatorVoteKey(_ vote: RunwayDesignatorVote) -> String {
        let le = vote.leIdent.flatMap { parseDesignator($0) }
        let he = vote.heIdent.flatMap { parseDesignator($0) }
        let ends = [le ?? he.map { oppositeDesignator(number: $0.number, suffix: $0.suffix) },
                    he ?? le.map { oppositeDesignator(number: $0.number, suffix: $0.suffix) }]
        guard ends.allSatisfy({ $0 != nil }) else {
            return [vote.leIdent, vote.heIdent].map { $0 ?? "" }.joined(separator: "/").uppercased()
        }
        return ends.compactMap { $0 }.map { String(format: "%02d", $0.number) + $0.suffix }.sorted().joined(separator: "/")
    }

    /// Whether a vote's two ends are 18 apart with mirrored suffixes. A single readable end has nothing to
    /// contradict it; an unreadable one isn't a designator.
    private static func isReciprocal(_ vote: RunwayDesignatorVote) -> Bool {
        let le = vote.leIdent.map { parseDesignator($0) }
        let he = vote.heIdent.map { parseDesignator($0) }
        switch (le, he) {
        case let (.some(.some(l)), .some(.some(h))):
            let opposite = oppositeDesignator(number: l.number, suffix: l.suffix)
            return opposite.number == h.number && opposite.suffix == h.suffix
        case (.some(.some(_)), nil), (nil, .some(.some(_))):
            return true
        default:
            return false
        }
    }

    /// The same runway under other designators, the ends turned round first when `straight` is false (the
    /// new LE lies under the old HE). Every other field stays with its end.
    static func renamed(_ r: Runway, leIdent: String, heIdent: String, straight: Bool) -> Runway {
        let le = straight ? RunwayEnd.le(of: r) : RunwayEnd.he(of: r)
        let he = straight ? RunwayEnd.he(of: r) : RunwayEnd.le(of: r)
        return Runway(
            id: r.id, airportRef: r.airportRef, airportIdent: r.airportIdent,
            lengthFt: r.lengthFt, widthFt: r.widthFt, surface: r.surface, lighted: r.lighted, closed: r.closed,
            leIdent: leIdent,
            leLatitude: le.latitude, leLongitude: le.longitude, leElevationFt: le.elevationFt,
            leHeadingDegT: le.headingDegT, leDisplacedThresholdFt: le.displacedThresholdFt,
            heIdent: heIdent,
            heLatitude: he.latitude, heLongitude: he.longitude, heElevationFt: he.elevationFt,
            heHeadingDegT: he.headingDegT, heDisplacedThresholdFt: he.displacedThresholdFt,
            pcn: r.pcn, leToraFt: le.toraFt, leLdaFt: le.ldaFt, heToraFt: he.toraFt, heLdaFt: he.ldaFt
        )
    }

    // MARK: - Geometry helpers

    /// A runway's LE designator, or its HE's reciprocal when the LE is missing or unreadable.
    private static func leOrientedDesignator(_ r: Runway) -> (number: Int, suffix: String)? {
        if let le = r.leIdent.flatMap({ parseDesignator($0) }) { return le }
        if let he = r.heIdent.flatMap({ parseDesignator($0) }) {
            return oppositeDesignator(number: he.number, suffix: he.suffix)
        }
        return nil
    }

    /// A runway's true heading seen from its LE end (the HE's, turned round, when the LE has none).
    private static func leOrientedHeading(_ r: Runway) -> Double? {
        if let le = finiteHeading(r.leHeadingDegT) { return normalizedDegrees(le) }
        if let he = finiteHeading(r.heHeadingDegT) { return normalizedDegrees(he - 180) }
        return nil
    }

    /// The heading if it is a number at all (a CSV "nan" parses as one).
    private static func finiteHeading(_ heading: Double?) -> Double? {
        guard let heading, heading.isFinite else { return nil }
        return heading
    }

    /// Degrees folded into 0..<360 (NaN stays NaN).
    private static func normalizedDegrees(_ degrees: Double) -> Double {
        let folded = degrees.truncatingRemainder(dividingBy: 360)
        return folded < 0 ? folded + 360 : folded
    }

    /// The angle between two headings, 0...180.
    private static func angularDifference(_ a: Double, _ b: Double) -> Double {
        let apart = abs(normalizedDegrees(a) - normalizedDegrees(b))
        return min(apart, 360 - apart)
    }

    /// Steps between two runway numbers round the compass (36 and 01 are one apart).
    private static func designatorDistance(_ a: Int, _ b: Int) -> Int {
        let apart = abs(a - b) % 36
        return min(apart, 36 - apart)
    }

    private static func reciprocalNumber(_ number: Int) -> Int {
        oppositeDesignator(number: number, suffix: "").number
    }

    private static func oppositeSuffix(_ suffix: String) -> String {
        oppositeDesignator(number: 1, suffix: suffix).suffix
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    /// Normalised match key for a runway: the sorted pair of end designators (case/order-insensitive),
    /// so "10/28" and "28/10" collide. Designators are zero-padded to two digits so the OpenAIP form ("9")
    /// and the OurAirports form ("09") of the same runway also collide (otherwise unionRunways would keep
    /// both and the airport would show one physical runway twice). Single-ended runways key on their one end.
    static func runwayKey(_ r: Runway) -> String {
        [r.leIdent, r.heIdent]
            .compactMap { $0 }
            .map { canonicalRunwayIdent($0) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "/")
    }

    /// Canonical runway-end form: number zero-padded to two digits + any L/C/R suffix (e.g. "9"→"09",
    /// "16l"→"16L"). Falls back to the trimmed/uppercased raw string when it isn't a parseable designator.
    private static func canonicalRunwayIdent(_ ident: String) -> String {
        if let (number, suffix) = parseDesignator(ident) {
            return String(format: "%02d", number) + suffix
        }
        return ident.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// Build one `Runway` from a paired (or single) OpenAIP direction. Physical fields (length/width/
    /// surface/PCN) are shared by both ends, taken from the `mainRunway` entry when known, else the LE.
    /// OpenAIP publishes no threshold positions or displaced thresholds, so those stay nil here;
    /// `unionRunways` brings OurAirports' in when it lists the same strip.
    private static func makeRunway(aptId: String, ref: Int, icao: String, le: OpenAIPRunway, he: OpenAIPRunway?) -> Runway {
        let primary: OpenAIPRunway = (he?.mainRunway == true && !le.mainRunway) ? he! : le
        let heIdent = he?.designator
        return Runway(
            id: stableNegativeID("\(aptId)_rwy_\(le.designator)_\(heIdent ?? "")"),
            airportRef: ref,
            airportIdent: icao,
            lengthFt: primary.lengthFeet,
            widthFt: primary.widthFeet,
            surface: primary.surfaceLabel,
            lighted: le.lighted || (he?.lighted ?? false),
            closed: false,
            leIdent: le.designator,
            leLatitude: nil, leLongitude: nil, leElevationFt: nil,
            leHeadingDegT: le.trueHeading, leDisplacedThresholdFt: nil,
            heIdent: heIdent,
            heLatitude: nil, heLongitude: nil, heElevationFt: nil,
            heHeadingDegT: he?.trueHeading, heDisplacedThresholdFt: nil,
            pcn: primary.pcn,
            leToraFt: le.toraFeet, leLdaFt: le.ldaFeet,
            heToraFt: he?.toraFeet, heLdaFt: he?.ldaFeet
        )
    }

    /// Parse a runway designator into (number 1–36, suffix L/C/R/""). Nil if it has no valid number.
    static func parseDesignator(_ d: String) -> (number: Int, suffix: String)? {
        let trimmed = d.trimmingCharacters(in: .whitespaces).uppercased()
        let digits = String(trimmed.prefix { $0.isNumber })
        let suffix = String(trimmed.drop { $0.isNumber })
        guard let n = Int(digits), (1...36).contains(n) else { return nil }
        return (n, suffix)
    }

    /// The reciprocal designator: number + 18 (mod 36), with L↔R swapped (C and "" unchanged).
    private static func oppositeDesignator(number: Int, suffix: String) -> (number: Int, suffix: String) {
        let oppNum = ((number - 1 + 18) % 36) + 1
        let oppSuffix: String
        switch suffix {
        case "L": oppSuffix = "R"
        case "R": oppSuffix = "L"
        default: oppSuffix = suffix
        }
        return (oppNum, oppSuffix)
    }

    /// Deterministic, strictly-negative id from the OpenAIP `_id`, so OpenAIP-only airports never collide
    /// with positive OurAirports ids and stay stable across launches (FNV-1a — `Hasher` is per-run salted).
    static func stableNegativeID(_ s: String) -> Int {
        var hash: UInt64 = 14695981039346656037   // FNV-1a 64-bit offset basis
        for byte in s.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let positive = Int(hash & 0x3FFF_FFFF_FFFF_FFFF)   // 62 bits → always fits a positive Int
        return -(positive + 1)                              // strictly negative
    }
}
