import Foundation
import Combine
import CoreLocation

/// The VFR reporting points the app shows, searches, snaps to and briefs: OpenAIP's, the primary source
/// as before, plus the open flightmaps points OpenAIP lacks (6.2.0, plan §3.3). Every map, the route
/// builder's search and snap, the briefing and the waypoint lookups read the points here, never one
/// source directly.
///
/// - OpenAIP is unchanged and comes first: every OpenAIP point shows, under its own id.
/// - An open flightmaps point joins when the extractor found no OpenAIP match (`inOpenAIP == false`)
///   AND the device, checking again against the OpenAIP points it has, finds none either
///   (`isInOpenAIP`). Only for a country whose OpenAIP reporting points are on the device: that check
///   means nothing without them, and OFM alone would be a partial layer.
/// - Kinds: on request, compulsory (OFM's MRP) and en-route always; helicopter and glider points only
///   with the map's "Glider, UL & helicopter" switch (`includingNonPowered`).
/// - Ids: OpenAIP's `_id` as before, `ofm:<OFM id>` for the others, so a saved route's `sourceId`
///   resolves to the same point, whichever build saved it.
///
/// The open flightmaps points are loaded lazily, when reporting points are shown or searched
/// (`loadIfNeeded`, `ensureLoaded`); `OFMDataService` decodes them off the main actor. The merge is a few
/// hundred points against a 1° grid, redone only when a source changes. (6.2.0)
@MainActor
final class ReportingPointCatalog: ObservableObject {
    static let shared = ReportingPointCatalog()

    /// The namespace of an open flightmaps point's id.
    nonisolated static let ofmIdPrefix = "ofm:"

    /// Changes whenever what a query returns may have: a source loaded, downloaded or deleted. The maps
    /// re-query on it.
    @Published private(set) var revision = 0

    private let openAIP: OpenAIPReportingPointDataService
    private let ofm: OFMDataService
    private let aerodromes: OpenAIPAirportDataService
    private var subscriptions: Set<AnyCancellable> = []
    private var merged: Merged?
    private var loadTask: Task<Void, Never>?
    private var attemptedLoadKey: MergeKey?

    /// - Parameters: the sources; tests pass their own, the app the shared ones (nil).
    init(openAIP: OpenAIPReportingPointDataService? = nil,
         ofm: OFMDataService? = nil,
         aerodromes: OpenAIPAirportDataService? = nil) {
        let openAIP = openAIP ?? .shared
        let ofm = ofm ?? .shared
        self.openAIP = openAIP
        self.ofm = ofm
        self.aerodromes = aerodromes ?? .shared
        // `@Published` fires before the value is set: the bump only makes the maps re-query on their
        // next update, by which time it is. The merge itself is keyed on the sources' state.
        let changes: [AnyPublisher<Void, Never>] = [
            openAIP.$reportingPointCount.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            openAIP.$isDataAvailable.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            openAIP.$downloadedCountries.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            ofm.$revision.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            ofm.$downloadedCountries.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self] in self?.revision &+= 1 }
            .store(in: &subscriptions)
    }

    // MARK: - Loading

    /// Whether there is anything to show: OpenAIP's points (the open flightmaps ones only join them).
    var isDataAvailable: Bool { openAIP.isDataAvailable }

    /// Load both sources, OpenAIP's first, and the aerodromes that name them. The open flightmaps
    /// files are decoded off the main actor, and from now on reloaded after each download.
    func ensureLoaded() async {
        await openAIP.ensureLoaded()
        await aerodromes.ensureAerodromeIndexLoaded()
        guard openAIP.isDataAvailable else { return }
        await ofm.ensureLoaded()
    }

    /// `ensureLoaded()` without waiting: for a map that shows the points and re-queries on `revision`.
    /// Once per state of the sources, so a cache that can't be read isn't read again on every pan.
    func loadIfNeeded() {
        let key = currentKey
        guard loadTask == nil, key != attemptedLoadKey, openAIP.isDataAvailable,
              !openAIP.isLoaded || !ofm.isLoaded else { return }
        attemptedLoadKey = key
        loadTask = Task { [weak self] in
            await self?.ensureLoaded()
            self?.loadTask = nil
        }
    }

    /// Changes whenever a marker's label could: new points or a new cycle, or new aerodromes.
    var labelRevision: Int {
        openAIP.pointsRevision &+ aerodromes.aerodromeIndexRevision &+ ofm.revision
    }

    // MARK: - Queries

    /// The points within the ranges, for the map markers: OpenAIP's (capped as before), then the open
    /// flightmaps ones, `limit` in all.
    func points(latRange: ClosedRange<Double>, lonRange: ClosedRange<Double>,
                includingNonPowered: Bool, limit: Int = 250) -> [ReportingPoint] {
        let primary = openAIP.reportingPointsInRegion(latRange: latRange, lonRange: lonRange, limit: limit)
        guard primary.count < limit else { return primary }
        let extra = currentMerge().entries(latRange: latRange, lonRange: lonRange)
            .filter { includingNonPowered || !$0.isNonPowered }
            .prefix(limit - primary.count)
            .map(\.point)
        return primary + extra
    }

    /// The nearest points to `coordinate` within `maxDistanceNm`, closest first (a compulsory point
    /// first at the same distance), from both sources: the briefing's and the snap's.
    func pointsNear(to coordinate: CLLocationCoordinate2D, maxDistanceNm: Double, limit: Int,
                    includingNonPowered: Bool) -> [ReportingPoint] {
        let primary = openAIP.reportingPointsNear(to: coordinate, maxDistanceNm: maxDistanceNm, limit: limit)
        let extra = currentMerge().entries(near: coordinate, maxDistanceNm: maxDistanceNm)
            .filter { includingNonPowered || !$0.isNonPowered }
            .map(\.point)
        guard !extra.isEmpty else { return primary }
        return (primary + extra)
            .map { ($0, $0.distanceNM(from: coordinate)) }
            .sorted { ($0.1, $0.0.compulsory ? 0 : 1) < ($1.1, $1.0.compulsory ? 0 : 1) }
            .prefix(limit)
            .map(\.0)
    }

    /// Every point, for the route builder's search.
    func allPoints(includingNonPowered: Bool) -> [ReportingPoint] {
        openAIP.allLoadedPoints() + currentMerge().entries
            .filter { includingNonPowered || !$0.isNonPowered }
            .map(\.point)
    }

    /// The point a route waypoint was made from (its `sourceId`): an OpenAIP `_id`, as every build
    /// before 6.2.0 saved, or `ofm:<id>`. An open flightmaps point resolves whatever the switches and
    /// whatever OpenAIP has since added, so a saved route keeps its name. Nil when the point isn't
    /// loaded. A linear scan: it serves an export or an editor, not a map update.
    func point(withId id: String) -> ReportingPoint? {
        guard id.hasPrefix(Self.ofmIdPrefix) else { return openAIP.point(withId: id) }
        let ofmId = String(id.dropFirst(Self.ofmIdPrefix.count))
        for set in ofm.pointSets {
            if let point = set.points.first(where: { $0.id == ofmId }) {
                return Self.reportingPoint(from: point, airac: set.airac)
            }
        }
        return nil
    }

    // MARK: - Aerodromes and labels

    /// The aerodrome a point belongs to: OpenAIP's join by id, else (open flightmaps) its ICAO code,
    /// named from OpenAIP's airport layer when that has it, by the code alone otherwise. The code is
    /// what "E (LSGC)" needs.
    func aerodrome(for point: ReportingPoint) -> ReportingPointAerodrome? {
        if let joined = aerodromes.aerodrome(for: point) { return joined }
        guard let icao = point.aerodromeICAO, !icao.isEmpty else { return nil }
        return aerodromes.aerodrome(forICAO: icao) ?? ReportingPointAerodrome(icao: icao, name: "")
    }

    func label(for point: ReportingPoint) -> ReportingPointLabel {
        ReportingPointLabel(point: point, aerodrome: aerodrome(for: point))
    }

    /// The aerodrome of the point a waypoint was made from, by its `sourceId`.
    func aerodrome(forSourceId id: String) -> ReportingPointAerodrome? {
        point(withId: id).flatMap(aerodrome(for:))
    }

    // MARK: - The merge

    /// An open flightmaps point that joins OpenAIP's.
    struct Entry: Sendable {
        let point: ReportingPoint
        let kind: VFRPoint.Kind

        /// Behind the "Glider, UL & helicopter" switch.
        var isNonPowered: Bool { kind == .helicopter || kind == .glider }
    }

    private struct MergeKey: Equatable {
        let openAIPRevision: Int
        let openAIPLoaded: Bool
        let openAIPCountries: [String]
        let ofmRevision: Int
    }

    private struct Merged {
        let key: MergeKey
        let entries: [Entry]
        let grid: [GridKey: [Int]]

        func entries(latRange: ClosedRange<Double>, lonRange: ClosedRange<Double>) -> [Entry] {
            guard !entries.isEmpty else { return [] }
            let low = GridKey(latitude: latRange.lowerBound, longitude: lonRange.lowerBound)
            let high = GridKey(latitude: latRange.upperBound, longitude: lonRange.upperBound)
            guard high.lat - low.lat <= 180, high.lon - low.lon <= 360 else { return [] }
            var indices: [Int] = []
            for lat in low.lat...high.lat {
                for lon in low.lon...high.lon { indices.append(contentsOf: grid[GridKey(lat: lat, lon: lon)] ?? []) }
            }
            return indices.sorted().map { entries[$0] }.filter {
                latRange.contains($0.point.latitude) && lonRange.contains($0.point.longitude)
            }
        }

        func entries(near coordinate: CLLocationCoordinate2D, maxDistanceNm: Double) -> [Entry] {
            guard !entries.isEmpty, maxDistanceNm.isFinite, maxDistanceNm >= 0 else { return [] }
            let latSpan = maxDistanceNm / 60
            let lonSpan = latSpan / max(cos(coordinate.latitude * .pi / 180), 0.01)
            return entries(latRange: (coordinate.latitude - latSpan)...(coordinate.latitude + latSpan),
                           lonRange: (coordinate.longitude - lonSpan)...(coordinate.longitude + lonSpan))
                .filter { $0.point.distanceNM(from: coordinate) <= maxDistanceNm }
        }
    }

    fileprivate struct GridKey: Hashable {
        let lat: Int
        let lon: Int

        init(lat: Int, lon: Int) {
            self.lat = lat
            self.lon = lon
        }

        init(latitude: Double, longitude: Double) {
            lat = latitude.safeRoundedInt(.down, or: 0)
            lon = longitude.safeRoundedInt(.down, or: 0)
        }
    }

    private var currentKey: MergeKey {
        MergeKey(openAIPRevision: openAIP.pointsRevision, openAIPLoaded: openAIP.isLoaded,
                 openAIPCountries: openAIP.downloadedCountries, ofmRevision: ofm.revision)
    }

    /// The open flightmaps points that join, merged again only when a source changed.
    private func currentMerge() -> Merged {
        let key = currentKey
        if let merged, merged.key == key { return merged }
        // Before OpenAIP's points are loaded nothing joins: the check would let OpenAIP's own through.
        let entries = openAIP.isLoaded
            ? Self.pointsOpenAIPLacks(ofm.pointSets, openAIP: openAIP.allLoadedPoints(),
                                      openAIPCountries: Set(openAIP.downloadedCountries.map { $0.uppercased() }))
            : []
        var grid: [GridKey: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            grid[GridKey(latitude: entry.point.latitude, longitude: entry.point.longitude), default: []].append(index)
        }
        let result = Merged(key: key, entries: entries, grid: grid)
        merged = result
        return result
    }

    /// The open flightmaps points OpenAIP lacks, as they join the catalog: of the countries in
    /// `openAIPCountries`, those the extractor marked as not in OpenAIP and that `isInOpenAIP` doesn't
    /// match against `openAIP` either; then one per place when open flightmaps has two (Sion's "S" and
    /// "SIERRA" at the same position), the compulsory one first. Every kind; the caller filters the
    /// opt-in ones. Pure.
    nonisolated static func pointsOpenAIPLacks(_ sets: [OFMDataService.PointSet], openAIP: [ReportingPoint],
                                               openAIPCountries: Set<String>) -> [Entry] {
        var openAIPGrid: [GridKey: [(canon: String, latitude: Double, longitude: Double)]] = [:]
        for point in openAIP {
            openAIPGrid[GridKey(latitude: point.latitude, longitude: point.longitude), default: []]
                .append((ReportingPointMatch.canonicalName(point.name ?? ""), point.latitude, point.longitude))
        }

        var candidates: [(point: VFRPoint, airac: String)] = []
        for set in sets where openAIPCountries.contains(set.country.uppercased()) {
            for point in set.points where !point.inOpenAIP {
                let cell = GridKey(latitude: point.position.latitude, longitude: point.position.longitude)
                var nearby: [(canon: String, latitude: Double, longitude: Double)] = []
                for lat in (cell.lat - 1)...(cell.lat + 1) {
                    for lon in (cell.lon - 1)...(cell.lon + 1) { nearby += openAIPGrid[GridKey(lat: lat, lon: lon)] ?? [] }
                }
                if !ReportingPointMatch.isInOpenAIP(name: point.name, latitude: point.position.latitude,
                                                    longitude: point.position.longitude, openAIP: nearby) {
                    candidates.append((point, set.airac))
                }
            }
        }

        // One per place: by kind (compulsory first), then file order.
        let order: [VFRPoint.Kind] = [.compulsory, .onRequest, .enRoute, .helicopter, .glider]
        let ranked = candidates.enumerated().sorted {
            let a = order.firstIndex(of: $0.element.point.kind) ?? order.count
            let b = order.firstIndex(of: $1.element.point.kind) ?? order.count
            return (a, $0.offset) < (b, $1.offset)
        }.map(\.element)
        var kept: [Entry] = []
        var keptGrid: [GridKey: [(canon: String, latitude: Double, longitude: Double)]] = [:]
        var keptIds: Set<String> = []
        for candidate in ranked {
            let point = candidate.point
            guard !keptIds.contains(point.id) else { continue }
            let cell = GridKey(latitude: point.position.latitude, longitude: point.position.longitude)
            var nearby: [(canon: String, latitude: Double, longitude: Double)] = []
            for lat in (cell.lat - 1)...(cell.lat + 1) {
                for lon in (cell.lon - 1)...(cell.lon + 1) { nearby += keptGrid[GridKey(lat: lat, lon: lon)] ?? [] }
            }
            let canon = ReportingPointMatch.canonicalName(point.name)
            let duplicate = nearby.contains { other in
                let distance = ReportingPointMatch.distanceNM(point.position.latitude, point.position.longitude,
                                                              other.latitude, other.longitude)
                return distance <= ReportingPointMatch.anyNameNM
                    || (distance <= ReportingPointMatch.sameNameNM && !canon.isEmpty && canon == other.canon)
            }
            guard !duplicate else { continue }
            keptIds.insert(point.id)
            keptGrid[cell, default: []].append((canon, point.position.latitude, point.position.longitude))
            kept.append(Entry(point: reportingPoint(from: point, airac: candidate.airac), kind: point.kind))
        }
        return kept
    }

    /// An open flightmaps point as the app's reporting point: `ofm:` id, compulsory for an MRP, its
    /// aerodrome by ICAO code (OFM's own code for a field without one, "EDAGA", is no ICAO code and is
    /// left out), and what a helicopter or glider point is for, as its remark.
    nonisolated static func reportingPoint(from point: VFRPoint, airac: String) -> ReportingPoint {
        let remark: String?
        switch point.kind {
        case .helicopter: remark = L10n.Nav.helicopterReportingPoint
        case .glider: remark = L10n.Nav.gliderReportingPoint
        case .onRequest, .compulsory, .enRoute: remark = nil
        }
        return ReportingPoint(
            id: ofmIdPrefix + point.id, name: point.name, compulsory: point.kind == .compulsory,
            remarks: remark, latitude: point.position.latitude, longitude: point.position.longitude,
            airports: [], source: .openFlightmaps, aerodromeICAO: icaoCode(point.aerodrome), airac: airac)
    }

    /// Four letters, upper-cased: an ICAO location indicator. Anything else is nil.
    nonisolated static func icaoCode(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces).uppercased(), code.count == 4,
              code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
        return code
    }
}

// MARK: - Matching rule

/// Whether an open flightmaps point is one OpenAIP already has: the rule of the investigation
/// (`ofm-investigation.md` §3) as the extractor applies it (`extract_ofm.py` `mark_openaip`), so the
/// device agrees with the published `inOpenAIP`. Pure. (6.2.0)
///
/// 1. Within 0.1 NM, whatever the names: the same point.
/// 2. Within 0.5 NM with names that agree once reduced (`canonicalName`, `isSameName`).
/// 3. The same reduced name 0.5 to 3 NM apart (1 NM for a one- or two-letter name, the "S" of the next
///    field over): the same point with a disputed position. OpenAIP's record wins; the extractor flags
///    it for an error report.
enum ReportingPointMatch {
    static let anyNameNM = 0.1
    static let sameNameNM = 0.5
    static let disputedNM = 3.0
    static let disputedShortNameNM = 1.0

    private static let phonetic: [(word: String, letter: String)] = [
        ("ALPHA", "A"), ("ALFA", "A"), ("BRAVO", "B"), ("CHARLIE", "C"), ("DELTA", "D"), ("ECHO", "E"),
        ("FOXTROT", "F"), ("FOXTROTT", "F"), ("GOLF", "G"), ("HOTEL", "H"), ("INDIA", "I"), ("JULIET", "J"),
        ("JULIETT", "J"), ("KILO", "K"), ("LIMA", "L"), ("MIKE", "M"), ("NOVEMBER", "N"), ("OSCAR", "O"),
        ("PAPA", "P"), ("QUEBEC", "Q"), ("ROMEO", "R"), ("SIERRA", "S"), ("TANGO", "T"), ("UNIFORM", "U"),
        ("VICTOR", "V"), ("WHISKEY", "W"), ("WHISKY", "W"), ("XRAY", "X"), ("YANKEE", "Y"), ("ZULU", "Z"),
    ].sorted { $0.word.count > $1.word.count }

    /// A name reduced for comparison: upper case, umlauts as AE/OE/UE, accents folded, anything but
    /// letters and digits gone, a leading "ABM" (abeam) dropped, and a leading phonetic word followed
    /// by nothing or digits folded to its letter (SIERRA = S, ECHO1 = E1).
    static func canonicalName(_ name: String) -> String {
        var upper = name.uppercased()
            .replacingOccurrences(of: "Ä", with: "AE")
            .replacingOccurrences(of: "Ö", with: "OE")
            .replacingOccurrences(of: "Ü", with: "UE")
        upper = upper.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        upper = String(upper.unicodeScalars.filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
            .map(Character.init))
        if upper.hasPrefix("ABM") { upper.removeFirst(3) }
        for (word, letter) in phonetic where upper.hasPrefix(word) {
            let rest = upper.dropFirst(word.count)
            if rest.allSatisfy(\.isASCIIDigit) { return letter + rest }
        }
        return upper
    }

    /// Names that designate the same point: equal once reduced, one a 4+ character start of the other
    /// (PALEX and PALEXPO), or OpenAIP's 5-letter code built on OFM's short name (GE and GEGEN, S and
    /// SLUGA).
    static func isSameName(ofm: String, openAIP: String) -> Bool {
        isSameCanonicalName(canonicalName(ofm), canonicalName(openAIP))
    }

    /// Whether the point is one of `openAIP` (names already reduced), by the three rules above.
    static func isInOpenAIP(name: String, latitude: Double, longitude: Double,
                            openAIP: [(canon: String, latitude: Double, longitude: Double)]) -> Bool {
        let canon = canonicalName(name)
        for other in openAIP {
            let distance = distanceNM(latitude, longitude, other.latitude, other.longitude)
            if distance <= anyNameNM { return true }
            if distance <= sameNameNM, isSameCanonicalName(canon, other.canon) { return true }
            let reach = other.canon.count >= 3 ? disputedNM : disputedShortNameNM
            if distance <= reach, !canon.isEmpty, canon == other.canon { return true }
        }
        return false
    }

    /// `isSameName` on names already reduced, OFM's first.
    private static func isSameCanonicalName(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        if min(a.count, b.count) >= 4, a.hasPrefix(b) || b.hasPrefix(a) { return true }
        return b.count == 5 && b.allSatisfy(\.isLetter) && b.hasPrefix(a)
    }

    /// Great-circle distance in nautical miles (haversine, like the extractor).
    static func distanceNM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radiusNM = 6_371_008.8 / 1852
        let φ1 = lat1 * .pi / 180, φ2 = lat2 * .pi / 180
        let dφ = (lat2 - lat1) * .pi / 180, dλ = (lon2 - lon1) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * radiusNM * asin(min(1, h.squareRoot()))
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

// MARK: - The opt-in switch

extension AppSettings {
    /// Whether open flightmaps' helicopter and glider reporting points join the others: the map's
    /// "Glider, UL & helicopter" switch, `showNonPoweredCircuitsOnMap`, which the map-layers PR adds.
    /// Until that switch exists on this branch the points stay off; when both are in, this returns it.
    /// (6.2.0)
    var showsNonPoweredReportingPoints: Bool { false }
}
