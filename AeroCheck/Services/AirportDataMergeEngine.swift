import Foundation
import CoreLocation

/// Pure, testable engine that folds OpenAIP airports into the OurAirports `Airport` backbone. Computed
/// ONCE at load (never per-query), then cached in `AirportDataService`. (v4.1.0)
///
/// Produces three outputs, each UNION-merged by `AirportDataService` (OpenAIP wins on a match, OurAirports
/// gap-fills): airport identity+position (`merge`), frequencies (`openAIPFrequencies`), and runways
/// (`openAIPRunways` — pairs OpenAIP's per-direction entries into le/he `Runway`s with PCN + declared
/// distances).
enum AirportDataMergeEngine {
    /// Two airports sharing an ICAO but more than this far apart are treated as DISTINCT fields
    /// (closed/moved/relocated), not the same airport — so neither overwrites the other.
    static let positionToleranceNm = 1.0

    /// Merge result: OurAirports as the base; an OpenAIP airport that matches an OurAirports ICAO within
    /// tolerance replaces it (OpenAIP's position/elevation/name win; OurAirports' IATA/local/region are
    /// preserved). OpenAIP airports with a usable ICAO and no match are appended (gap-fill). OpenAIP
    /// airports without an ICAO are skipped — the app keys airports on `ident`.
    static func merge(ourAirports: [Airport], openAIP: [OpenAIPAirport]) -> [Airport] {
        var result = ourAirports
        var indexByIcao: [String: Int] = [:]
        for (i, a) in result.enumerated() {
            let key = a.ident.uppercased()
            if !key.isEmpty { indexByIcao[key] = i }
        }

        for oa in openAIP {
            guard let icaoRaw = oa.icaoCode, !icaoRaw.isEmpty else { continue }
            let icao = icaoRaw.uppercased()
            if let idx = indexByIcao[icao] {
                let existing = result[idx]
                // Same ICAO + close enough → OpenAIP wins (more current European data).
                if existing.distance(from: oa.coordinate) <= positionToleranceNm {
                    result[idx] = makeAirport(from: oa, preserving: existing)
                }
                // Else: keep both — leave OurAirports in place, don't append a colliding ident.
            } else {
                let new = makeAirport(from: oa, preserving: nil)
                indexByIcao[icao] = result.count
                result.append(new)
            }
        }
        return result
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

    /// Convert OpenAIP airport runways into the app's `Runway` rows, keyed by ICAO. OpenAIP lists each
    /// runway DIRECTION separately (e.g. "10" and "28"); this pairs opposite directions into one le/he
    /// `Runway`, carrying OpenAIP's richer data (PCN + per-direction declared distances). A direction with
    /// no opposite present becomes an LE-only runway. Skips airports without an ICAO. (v4.1.0 runway merge)
    static func openAIPRunways(from airports: [OpenAIPAirport]) -> [Runway] {
        var result: [Runway] = []
        for apt in airports {
            guard let icaoRaw = apt.icaoCode, !icaoRaw.isEmpty else { continue }
            let icao = icaoRaw.uppercased()
            let ref = stableNegativeID(apt.id)

            // Index this airport's directions by canonical "<number><suffix>" key (e.g. "10", "16L").
            var byKey: [String: (entry: OpenAIPRunway, number: Int, suffix: String)] = [:]
            var order: [String] = []
            for rwy in apt.runways {
                guard let (num, suffix) = parseDesignator(rwy.designator) else { continue }
                let key = "\(num)\(suffix)"
                if byKey[key] == nil { byKey[key] = (rwy, num, suffix); order.append(key) }
            }

            var consumed = Set<String>()
            for key in order {
                guard !consumed.contains(key), let this = byKey[key] else { continue }
                consumed.insert(key)
                let (oppNum, oppSuffix) = oppositeDesignator(number: this.number, suffix: this.suffix)
                let oppKey = "\(oppNum)\(oppSuffix)"
                if let opp = byKey[oppKey], !consumed.contains(oppKey) {
                    consumed.insert(oppKey)
                    // Lower runway number is the LE end (e.g. "10" before "28", "16L" before "34R").
                    let (le, he) = this.number <= opp.number ? (this.entry, opp.entry) : (opp.entry, this.entry)
                    result.append(makeRunway(aptId: apt.id, ref: ref, icao: icao, le: le, he: he))
                } else {
                    result.append(makeRunway(aptId: apt.id, ref: ref, icao: icao, le: this.entry, he: nil))
                }
            }
        }
        return result
    }

    /// UNION an airport's runways: OpenAIP wins on a runway-identifier match, OurAirports-only runways
    /// (the ~62% of airports OpenAIP lacks) are kept. Pure + testable; used by `AirportDataService`.
    static func unionRunways(our: [Runway], openAIP: [Runway]) -> [Runway] {
        let openAIPKeys = Set(openAIP.map { runwayKey($0) })
        let keptOur = our.filter { !openAIPKeys.contains(runwayKey($0)) }
        return openAIP + keptOur
    }

    /// Normalised match key for a runway: the sorted pair of end designators (case/order-insensitive),
    /// so "10/28" and "28/10" collide. Single-ended runways key on their one designator.
    static func runwayKey(_ r: Runway) -> String {
        [r.leIdent, r.heIdent]
            .compactMap { $0?.uppercased() }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "/")
    }

    /// Build one `Runway` from a paired (or single) OpenAIP direction. Physical fields (length/width/
    /// surface/PCN) are shared by both ends — taken from the `mainRunway` entry when known, else the LE.
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
