import Foundation
import CoreLocation

/// Pure, testable engine that folds OpenAIP airports into the OurAirports `Airport` backbone, behind the
/// `useOpenAIPPrimaryAirports` flag. Computed ONCE at load (never per-query), then cached in
/// `AirportDataService`. (v4.1.0, increment 9 — flag-gated; default OFF until validated.)
///
/// Scope: airport IDENTITY + POSITION only (the `Airport` struct). OpenAIP's runways and frequencies
/// live in separate stores and are a deliberate fast-follow — this engine does not touch them.
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
            ident: oa.icaoCode ?? our?.ident ?? oa.id,
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

    /// Deterministic, strictly-negative id from the OpenAIP `_id`, so OpenAIP-only airports never collide
    /// with positive OurAirports ids and stay stable across launches (FNV-1a — `Hasher` is per-run salted).
    static func stableNegativeID(_ s: String) -> Int {
        var hash: UInt64 = 14695981039346656037   // FNV-1a 64-bit offset basis
        for byte in s.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let positive = Int(hash & 0x3FFF_FFFF_FFFF_FFFF)   // 62 bits → always fits a positive Int
        return -(positive + 1)                              // strictly negative
    }
}
