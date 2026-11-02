import CoreLocation
import Foundation

/// The aerodromes with an ICAO code, bundled from OurAirports (public domain): `aerodromes.tsv`, about 19,000 lines,
/// rebuilt before each tag. Onboarding's "Based at" finds the nearest and searches by code or name with it, offline
/// and without OpenAIP, whose API answered 500 to every request on 2 Nov 2026 (the author's go the same day). (6.8.0)
enum BundledAerodromes {

    struct Entry: Equatable {
        let ident: String
        let name: String
        let latitude: Double
        let longitude: Double
        /// The name folded for the search: no case, no accents.
        let folded: String
    }

    /// Read on first use, off the main actor by the callers below.
    static let all: [Entry] = load(Bundle.main.url(forResource: "aerodromes", withExtension: "tsv"))

    static func load(_ url: URL?) -> [Entry] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// One aerodrome a line, `CODE <tab> name <tab> latitude <tab> longitude`; `#` lines are comments.
    static func parse(_ text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4, let latitude = Double(fields[2]), let longitude = Double(fields[3]) else {
                return nil
            }
            let name = String(fields[1])
            return Entry(ident: String(fields[0]), name: name, latitude: latitude, longitude: longitude,
                         folded: fold(name))
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The nearest within `maxNM`, nil beyond it (no suggestion for a base that far).
    static func nearest(to coordinate: CLLocationCoordinate2D, within maxNM: Double = 50,
                        in entries: [Entry] = all) -> NearestAerodrome.Found? {
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // A degree of latitude is 60 NM: only what is inside the box is measured.
        let latSpan = maxNM / 60
        let lonSpan = maxNM / (60 * max(0.01, cos(coordinate.latitude * .pi / 180)))
        var best: (entry: Entry, nm: Double)?
        for entry in entries where abs(entry.latitude - coordinate.latitude) <= latSpan
            && abs(entry.longitude - coordinate.longitude) <= lonSpan {
            let nm = here.distance(from: CLLocation(latitude: entry.latitude, longitude: entry.longitude)) / 1852
            if nm <= maxNM, nm < best?.nm ?? .infinity { best = (entry, nm) }
        }
        return best.map { NearestAerodrome.Found(ident: $0.entry.ident, name: $0.entry.name, distanceNM: $0.nm) }
    }

    /// By code or name, best first: the code itself, a code starting so, a name starting with it as a word ("Bern"
    /// gives Bern Airport before San Bernardino), a name starting so, a word starting so, a name holding it.
    static func search(_ query: String, limit: Int = 6, in entries: [Entry] = all) -> [NearestAerodrome.Named] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard typed.count >= 2 else { return [] }
        let code = typed.uppercased()
        let folded = fold(typed)
        var ranked: [(rank: Int, entry: Entry)] = []
        for entry in entries {
            let rank: Int
            if entry.ident == code { rank = 0 }
            else if entry.ident.hasPrefix(code) { rank = 1 }
            else if entry.folded == folded || entry.folded.hasPrefix(folded + " ") || entry.folded.hasPrefix(folded + "-") {
                rank = 2
            }
            else if entry.folded.hasPrefix(folded) { rank = 3 }
            else if entry.folded.contains(" " + folded) || entry.folded.contains("-" + folded) { rank = 4 }
            else if entry.folded.contains(folded) { rank = 5 }
            else { continue }
            ranked.append((rank, entry))
        }
        return ranked.sorted { ($0.rank, $0.entry.ident) < ($1.rank, $1.entry.ident) }
            .prefix(limit)
            .map { NearestAerodrome.Named(ident: $0.entry.ident, name: $0.entry.name) }
    }
}
