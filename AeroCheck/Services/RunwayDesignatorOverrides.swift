import Foundation

/// Runway designators set by hand, where the sources are wrong or disagree and an authoritative source
/// settles it. Applied LAST: after the OurAirports/OpenAIP merge (`AirportDataMergeEngine.mergedRunways`),
/// and on OurAirports alone when OpenAIP isn't downloaded (`AirportDataService`). An entry renames the
/// physical runway it matches (`AirportDataMergeEngine.physicalMatch`: true heading within 12°, either
/// end, or designator numbers within ±1 when the runway has no heading; same parallel suffix) and leaves
/// everything else as it was.
///
/// Checked each quarter, with the landing-fee links: re-read each entry's source, bump `checked`, and
/// drop the entries the sources have caught up with (both OurAirports and OpenAIP listing the same
/// designators). Each entry has a test in `OpenAIPAirportMergeTests`. (6.2.0)
enum RunwayDesignatorOverrides {
    struct Entry: Sendable {
        let icao: String
        let leIdent: String
        let heIdent: String
        /// True heading of the LE end, to find the physical runway.
        let leTrueHeading: Double
        /// Where the designators come from.
        let source: String
        /// When they were last checked against that source (yyyy-mm-dd).
        let checked: String
    }

    static let entries: [Entry] = [
        // OpenAIP: 06/24. OurAirports: 05/23.
        Entry(icao: "LSGC", leIdent: "05", heIdent: "23", leTrueHeading: 54,
              source: "Confirmed by the author", checked: "2026-10-01"),
        // OpenAIP: 10/27 (not even reciprocal). OurAirports: 11/29.
        Entry(icao: "LSPM", leIdent: "10", heIdent: "28", leTrueHeading: 104,
              source: "NOTAM B1662/26 (25 Sep to 3 Oct 2026): \"RWY 10/28 CLSD\"", checked: "2026-10-01"),
    ]

    /// The airports that have an entry.
    static let idents: Set<String> = Set(entries.map(\.icao))

    /// `runways` (one airport's) with the entries for `ident` applied. Each entry renames at most one
    /// runway, the closest match first; a closed runway is never renamed.
    static func apply(to runways: [Runway], ident: String) -> [Runway] {
        let fixes = entries.filter { $0.icao == ident.uppercased() }
        guard !fixes.isEmpty else { return runways }
        var candidates: [(score: Double, fix: Int, runway: Int, straight: Bool)] = []
        for (f, fix) in fixes.enumerated() {
            for (r, runway) in runways.enumerated() where !runway.closed {
                guard let match = AirportDataMergeEngine.physicalMatch(probe(for: fix), runway) else { continue }
                candidates.append((match.score, f, r, match.straight))
            }
        }
        var result = runways
        var usedFixes = Set<Int>(), usedRunways = Set<Int>()
        for candidate in candidates.sorted(by: { ($0.score, $0.fix, $0.runway) < ($1.score, $1.fix, $1.runway) })
        where !usedFixes.contains(candidate.fix) && !usedRunways.contains(candidate.runway) {
            let fix = fixes[candidate.fix]
            result[candidate.runway] = AirportDataMergeEngine.renamed(
                runways[candidate.runway], leIdent: fix.leIdent, heIdent: fix.heIdent, straight: candidate.straight)
            usedFixes.insert(candidate.fix)
            usedRunways.insert(candidate.runway)
        }
        return result
    }

    /// The entry as a bare runway, for `physicalMatch`.
    private static func probe(for fix: Entry) -> Runway {
        Runway(id: 0, airportRef: 0, airportIdent: fix.icao, lengthFt: nil, widthFt: nil, surface: nil,
               lighted: false, closed: false,
               leIdent: fix.leIdent, leLatitude: nil, leLongitude: nil, leElevationFt: nil,
               leHeadingDegT: fix.leTrueHeading, leDisplacedThresholdFt: nil,
               heIdent: fix.heIdent, heLatitude: nil, heLongitude: nil, heElevationFt: nil,
               heHeadingDegT: (fix.leTrueHeading + 180).truncatingRemainder(dividingBy: 360),
               heDisplacedThresholdFt: nil,
               pcn: nil, leToraFt: nil, leLdaFt: nil, heToraFt: nil, heLdaFt: nil)
    }
}
