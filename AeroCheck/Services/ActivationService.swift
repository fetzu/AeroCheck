import CoreLocation
import Foundation
import MapKit

// MARK: - Which Swiss areas are active (6.9.0)
//
// skyguide's Daily Airspace Bulletin, read by the server four times a day (`scripts/dabs/`, the author's a13) and served
// at `/data/activation/v1/CH/<date>.json`. In Switzerland an R or D area not on a fresh bulletin is inactive: faded, no
// tag, no airspace-ahead state, as SkyDemon has done since 4.1.0 (a14 A). Without today's file everything counts as
// active, and the map says so. Outside Switzerland every R area counts as active: nothing like the DABS exists there.
// The file is free, like the airspace, and it never replaces the NOTAMs: one can change an area between versions.
//
// Abroad the NOTAMs add (6.10.0, the author's answers of 7 Nov 2026): a NOTAM that creates or activates an area puts its
// times on the card of the area it names, and an area it draws itself joins the map, the tags and AIRSPACE AHEAD like an
// R area while it is active. Nothing abroad is ever faded: OpenAIP lists areas such as LF-R368A as active every day, so
// an area no NOTAM names can't be called inactive. The server reads the NOTAMs (`activation`); the board checks the clock.

/// The server's file. Only what the app reads: a new key is additive.
struct ActivationFile: Codable, Equatable {
    static let schema = 1

    struct Limit: Codable, Equatable, Hashable {
        let raw: String
        let ft: Int
        let ref: String

        /// In OpenAIP's terms, so the bands work out as for any airspace.
        var altitudeLimit: AltitudeLimit {
            switch ref {
            // "2000FT AGL" from a NOTAM; the DABS's ground is 0
            case "GND": return AltitudeLimit(value: ft, unit: 1, referenceDatum: 0)
            case "STD": return AltitudeLimit(value: ft / 100, unit: 6, referenceDatum: 2)
            default: return AltitudeLimit(value: ft, unit: 1, referenceDatum: 1)
            }
        }
    }

    struct Area: Codable, Equatable {
        let id: String
        let notam: String?
        let windowsUtc: [[String]]
        let lower: Limit
        let upper: Limit
    }

    struct TempArea: Codable, Equatable {
        let notam: String
        let centre: [Double]
        let radiusNm: Double
        let kind: String
        let name: String
        let windowsUtc: [[String]]
        let lower: Limit
        let upper: Limit
    }

    let v: Int
    let date: String
    let version: Int
    let generatedUtc: String
    let areas: [Area]
    let tempAreas: [TempArea]
}

/// Today's bulletin against the airspace. Pure: a file and a moment in, what each area is doing out.
struct ActivationBoard {
    /// What a tag or the slot looks ahead by: an area that goes active within this long counts as active.
    static let leadTime: TimeInterval = 10 * 60

    enum Status: Equatable {
        /// Not a Swiss R or D area, or no fresh file: it counts as active.
        case noBulletin
        /// On the bulletin and active now or within the look-ahead.
        case active(ActivationFile.Area)
        /// On the bulletin, later or earlier today.
        case laterToday(ActivationFile.Area)
        /// A fresh bulletin doesn't list it.
        case notListed
    }

    /// Today's file; nil with no file or an older one. Fresh is the file's date, never a version: with four runs a
    /// day an expected-version rule would wrongly fall back to active in summer.
    let file: ActivationFile?
    let now: Date
    /// Abroad, from the NOTAMs on the device.
    let notams: NotamAreaSet

    static var swissCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich") ?? .gmt
        return calendar
    }

    /// The Swiss date as the files are named.
    static func dayString(_ date: Date, offset: Int = 0) -> String {
        let shifted = swissCalendar.date(byAdding: .day, value: offset, to: date) ?? date
        let parts = swissCalendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    init(files: [String: ActivationFile], now: Date, notams: NotamAreaSet = .empty) {
        file = files[Self.dayString(now)]
        self.now = now
        self.notams = notams
    }

    var isLoaded: Bool { file != nil }

    private static func covers(_ airspace: Airspace) -> Bool {
        airspace.country.uppercased() == "CH"
            && (airspace.airspaceType == .restricted || airspace.airspaceType == .danger)
    }

    private static func id(of airspace: Airspace) -> Substring { airspace.name.split(separator: " ").first ?? "" }

    func status(of airspace: Airspace) -> Status {
        guard let file, Self.covers(airspace) else { return .noBulletin }
        guard let area = file.areas.first(where: { $0.id == Self.id(of: airspace) }) else { return .notListed }
        return isActive(windows: area.windowsUtc, date: file.date) ? .active(area) : .laterToday(area)
    }

    /// Whether it counts for a tag and the slot.
    func isActive(_ airspace: Airspace) -> Bool {
        if let area = notams.drawn[airspace.id] { return area.activation.isActive(at: now, lead: Self.leadTime) }
        switch status(of: airspace) {
        case .noBulletin, .active: return true
        case .laterToday, .notListed: return false
        }
    }

    private func isActive(windows: [[String]], date: String) -> Bool {
        windows.contains { window in
            guard window.count == 2, let start = Self.moment(date, window[0]), let end = Self.moment(date, window[1])
            else { return false }
            return start <= now.addingTimeInterval(Self.leadTime) && now <= end
        }
    }

    /// "2026-11-04" and "06:30" (UTC) as a moment.
    static func moment(_ date: String, _ time: String) -> Date? {
        let day = date.split(separator: "-").compactMap { Int($0) }
        let clock = time.split(separator: ":").compactMap { Int($0) }
        guard day.count == 3, clock.count == 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: day[0], month: day[1], day: day[2], hour: clock[0], minute: clock[1]))
    }

    /// The airspace as a tag and the slot should read it: what isn't active left out, the bulletin's limits on what is
    /// (they can differ from the AIP's), and the areas made by NOTAM added: abroad, those over `region`.
    func applied(_ airspaces: [Airspace], region: MKCoordinateRegion? = nil) -> [Airspace] {
        var out: [Airspace] = []
        for airspace in airspaces {
            switch status(of: airspace) {
            case .noBulletin: out.append(airspace)
            case .active(let area): out.append(airspace.replacingLimits(lower: area.lower.altitudeLimit, upper: area.upper.altitudeLimit))
            case .laterToday, .notListed: break
            }
        }
        return out + tempAirspaces.filter { temp in
            file?.tempAreas.first { $0.notam == temp.id }.map { isActive(windows: $0.windowsUtc, date: file?.date ?? "") } ?? false
        } + notams.airspaces(in: region).filter(isActive)
    }

    /// The areas made by NOTAM to draw over `region`: the DABS's, and abroad those the NOTAMs draw, from
    /// `NotamAreaSet.drawAhead` before they go active (faded until then, by `isActive`).
    func drawnTempAirspaces(in region: MKCoordinateRegion?) -> [Airspace] {
        tempAirspaces + notams.airspaces(in: region)
    }

    /// The areas made by NOTAM as circles, for every map and rule that reads airspace.
    var tempAirspaces: [Airspace] {
        (file?.tempAreas ?? []).compactMap { temp in
            guard temp.centre.count == 2 else { return nil }
            let centre = CLLocationCoordinate2D(latitude: temp.centre[0], longitude: temp.centre[1])
            let ring = (0...36).map { step -> [Double] in
                let point = AirspaceAheadArea.offset(centre, trackDeg: Double(step) * 10, nm: temp.radiusNm)
                return [point.longitude, point.latitude]
            }
            let type: AirspaceTypeCategory = temp.kind == "D" ? .danger : .restricted
            return Airspace(id: temp.notam, name: "\(temp.kind) \(temp.name)", type: type.rawValue, icaoClass: nil, country: "CH",
                            upperCeiling: temp.upper.altitudeLimit, lowerCeiling: temp.lower.altitudeLimit,
                            geometry: AirspaceGeometry(type: "Polygon", coordinates: [ring]), activity: nil, frequencies: nil)
        }
    }

    /// "DABS v3, 12:45": the version and when it was made, in Swiss time.
    var sourceText: String? {
        guard let file, let generated = ISO8601DateFormatter().date(from: file.generatedUtc) else { return nil }
        let parts = Self.swissCalendar.dateComponents([.hour, .minute], from: generated)
        return String(format: "DABS v%d, %02d:%02d", file.version, parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Whether `note(for:)` is the DABS's own, not a NOTAM's from abroad.
    func isBulletinNote(for airspace: Airspace) -> Bool {
        notams.drawn[airspace.id] == nil && airspace.country.uppercased() == "CH"
    }

    /// What the tap card says of an airspace, or nil where the bulletin and the NOTAMs say nothing of it.
    func note(for airspace: Airspace) -> String? {
        // Its name carries the NOTAM's number already
        if let area = notams.drawn[airspace.id] { return area.note(now: now, naming: false) }
        if airspace.country.uppercased() != "CH", let key = airspace.designatorKey, let area = notams.naming(key, now: now) {
            return area.note(now: now)
        }
        guard let source = sourceText else { return nil }
        switch status(of: airspace) {
        case .noBulletin: return nil
        case .notListed: return L10n.Nav.dabsNotActive(source)
        case .active(let area), .laterToday(let area):
            let windows = area.windowsUtc.filter { $0.count == 2 }.map { "\($0[0])–\($0[1])" }.joined(separator: ", ")
            return L10n.Nav.dabsActive(windows, source)
        }
    }
}

extension Airspace {
    /// The same airspace with other limits.
    func replacingLimits(lower: AltitudeLimit, upper: AltitudeLimit) -> Airspace {
        Airspace(id: id, name: name, type: type, icaoClass: icaoClass, country: country, upperCeiling: upper, lowerCeiling: lower,
                 geometry: geometry, activity: activity, frequencies: frequencies)
    }
}

/// Fetches today's and tomorrow's bulletin at launch, on foreground and at START, and keeps them for the flight. Silent
/// on failure: the board then counts everything as active and the map says the DABS isn't loaded.
@MainActor
final class ActivationService: ObservableObject {
    static let shared = ActivationService()

    static let allowedHosts = Set([APIConfig.dataURL("activation/v1").host?.lowercased()].compactMap { $0 })
    static let maxBytes = 256 * 1024
    /// The job runs four times a day: half an hour keeps a foreground from fetching for nothing.
    nonisolated static let minInterval: TimeInterval = 30 * 60

    static func url(day: String) -> URL { APIConfig.dataURL("activation/v1/CH/\(day).json") }

    @Published private(set) var files: [String: ActivationFile] = [:]
    private var lastFetch: Date?
    private var isLoading = false

    private let cacheURL: URL
    private let fetchOverride: ((URL) async throws -> Data)?
    private let now: () -> Date

    init(cacheURL: URL? = nil, fetch: ((URL) async throws -> Data)? = nil, now: @escaping () -> Date = { FlightClock.now }) {
        self.cacheURL = cacheURL ?? DataPersistenceManager.shared.localAppDirectory.appendingPathComponent("activation.json")
        fetchOverride = fetch
        self.now = now
        if let data = try? Data(contentsOf: self.cacheURL),
           let cached = try? JSONDecoder().decode([String: ActivationFile].self, from: data) {
            files = cached
        }
    }

    /// Today's bulletin against the airspace, without the NOTAMs: whether the DABS is loaded.
    var board: ActivationBoard { ActivationBoard(files: files, now: now()) }

    /// Today's bulletin and, abroad, the NOTAMs on the device (never in a dry run). `knownAreas`: the designators of the
    /// device's airspace (`OpenAIPDataService.designatorKeys`). The NOTAMs' part is built once a minute.
    /// `notams` nil: the app's own (`NotamService.shared`), read here on the main actor; a default argument is evaluated
    /// outside it, which Swift 6 refuses.
    func board(knownAreas: Set<String>, notams: NotamService? = nil) -> ActivationBoard {
        let notams = notams ?? .shared
        let moment = now()
        let key = NotamMemoKey(revision: notams.revision, known: knownAreas.count,
                               minute: Int(moment.timeIntervalSinceReferenceDate / 60), dryRun: DryRunCenter.shared.isRunning)
        if notamMemo?.key != key {
            notamMemo = (key, NotamAreaSet(areas: key.dryRun ? [] : notams.areaActivations, knownAreas: knownAreas, now: moment))
        }
        return ActivationBoard(files: files, now: moment, notams: notamMemo?.set ?? .empty)
    }

    private struct NotamMemoKey: Equatable {
        let revision: Int
        let known: Int
        let minute: Int
        let dryRun: Bool
    }

    private var notamMemo: (key: NotamMemoKey, set: NotamAreaSet)?

    /// At launch and on foreground. `force`: at START, whatever the last fetch.
    func refreshIfNeeded(force: Bool = false) async {
        if !force, let lastFetch, now().timeIntervalSince(lastFetch) < Self.minInterval { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let moment = now()
        let days = [ActivationBoard.dayString(moment), ActivationBoard.dayString(moment, offset: 1)]
        var updated = files.filter { days.contains($0.key) }
        for day in days {
            guard let data = try? await fetch(Self.url(day: day)),
                  let file = try? JSONDecoder().decode(ActivationFile.self, from: data),
                  file.v == ActivationFile.schema, file.date == day else { continue }
            updated[day] = file
        }
        lastFetch = moment
        guard updated != files else { return }
        files = updated
        if let data = try? JSONEncoder().encode(updated) {
            try? data.write(to: cacheURL, options: DataPersistenceManager.protectedWriteOptions)
        }
    }

    private enum FetchError: Error { case http(Int), tooLarge }

    /// GET a file: on the allow-list, under the size cap, a 200. A 404 is a day with no file yet.
    private func fetch(_ url: URL) async throws -> Data {
        guard ExternalRequest.isAllowed(url, hosts: Self.allowedHosts) else { throw ExternalRequest.HostError.notAllowed }
        if let fetchOverride { return try await fetchOverride(url) }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let secret = APIConfig.appClientSecret { request.setValue(secret, forHTTPHeaderField: "X-AeroCheck-Client") }
        let (body, response) = try await ExternalRequest.data(for: request, maxResponseBytes: Self.maxBytes,
                                                              allowedHosts: Self.allowedHosts)
        guard response.statusCode == 200 else { throw FetchError.http(response.statusCode) }
        guard body.count <= Self.maxBytes else { throw FetchError.tooLarge }
        return body
    }

    /// Seeded directly in tests, so no test has to reach the network.
    func seedForTesting(_ seeded: [String: ActivationFile]) { files = seeded }
}

// MARK: - Abroad, from the NOTAMs (6.10.0)

/// A NOTAM that creates or activates an area outside Switzerland, with the country of its file.
struct NotamArea: Equatable {
    let notam: Notam
    let activation: NotamActivation
    let country: String

    /// "Active 08:30–09:30 UTC (NOTAM R3307/26)", without the number on the NOTAM's own area: its windows of the next day, else the next one; with the NOTAM's own
    /// schedule after them when the server couldn't read it, since the window is then its whole span.
    func note(now: Date, naming: Bool = true) -> String? {
        let ahead = activation.windows.filter { $0.end >= now && $0.start <= now.addingTimeInterval(24 * 3600) }
        let shown = ahead.isEmpty ? Array(activation.windows.filter { $0.end >= now }.prefix(1)) : Array(ahead.prefix(3))
        guard !shown.isEmpty else { return nil }
        // Past an estimated end the server keeps the area 7 days more: say the NOTAM's own end, marked EST, never that
        let estimatedEnd = notam.estimated ? notam.end : nil
        var text = shown.map { window -> String in
            guard let end = estimatedEnd, window.end > end else {
                return "\(Self.moment(window.start, now: now))–\(Self.moment(window.end, now: now))"
            }
            return window.start >= end ? L10n.Notams.from(Self.moment(end, now: now))
                : "\(Self.moment(window.start, now: now))–\(Self.moment(end, now: now))"
        }.joined(separator: ", ")
        if !activation.exact, let schedule = notam.schedule { text += ", \(schedule)" }
        let mark = estimatedEnd == nil ? "" : "EST, "
        return naming ? L10n.Nav.dabsActive(text, "\(mark)NOTAM \(notam.number)")
            : L10n.Nav.notamActive(text) + (estimatedEnd == nil ? "" : " EST")
    }

    /// "08:30" today (UTC), "02.12 11:00" on another day.
    private static func moment(_ date: Date, now: Date) -> String {
        let calendar = NotamTime.utc
        if calendar.isDate(date, inSameDayAs: now) { return NotamTime.clock(date) }
        let parts = calendar.dateComponents([.day, .month], from: date)
        return String(format: "%02d.%02d %@", parts.day ?? 0, parts.month ?? 0, NotamTime.clock(date))
    }

    /// What a tag and AIRSPACE AHEAD call it: the area it names, else its kind, then "NOTAM" and its number.
    var name: String {
        let kind: String
        switch activation.kind {
        case .restricted: kind = "R"
        case .danger: kind = "D"
        case .prohibited: kind = "P"
        case .reserved: kind = "TRA"
        case .military: kind = "MIL"
        }
        return "\(activation.areas.first ?? kind) NOTAM \(notam.number)"
    }

    /// Its shapes as airspace, in OpenAIP's terms so every map and rule reads them as any other: restricted for everything
    /// but a danger or prohibited area (the author: they count like an R area).
    var airspaces: [Airspace] {
        let type: AirspaceTypeCategory = activation.kind == .danger ? .danger
            : activation.kind == .prohibited ? .prohibited : .restricted
        return activation.shapes.enumerated().compactMap { index, shape -> Airspace? in
            let ring: [[Double]]
            switch shape {
            case .circle(let latitude, let longitude, let radiusNm):
                let centre = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                ring = (0...36).map { step in
                    let point = AirspaceAheadArea.offset(centre, trackDeg: Double(step) * 10, nm: radiusNm)
                    return [point.longitude, point.latitude]
                }
            case .polygon(let points):
                ring = points
            }
            let airspace = Airspace(id: "notam:\(notam.id):\(index)", name: name, type: type.rawValue, icaoClass: nil,
                                    country: country, upperCeiling: activation.upper.altitudeLimit,
                                    lowerCeiling: activation.lower.altitudeLimit,
                                    geometry: AirspaceGeometry(type: "Polygon", coordinates: [ring]), activity: nil, frequencies: nil)
            return airspace.polygonCoordinates.count >= 3 ? airspace : nil
        }
    }
}

/// The NOTAMs' areas abroad for one moment: built once a minute from the files on the device and the designators of the
/// device's airspace, then read by every board of that minute.
struct NotamAreaSet {
    /// An area the NOTAMs draw is on the map from this long before it goes active, faded until then.
    static let drawAhead: TimeInterval = 12 * 3600

    static let empty = NotamAreaSet(areas: [], knownAreas: [], now: .distantPast)

    /// Every one on the device, for the cards of the areas they name.
    let areas: [NotamArea]
    /// Those that draw their own area, by the airspace's id.
    let drawn: [String: NotamArea]
    private let shapes: [Airspace]

    /// `knownAreas`: a NOTAM naming one of these puts its times on that area's card and draws nothing of its own; one
    /// naming none draws its shapes, which the server keeps to what it can stand behind.
    init(areas: [NotamArea], knownAreas: Set<String>, now: Date) {
        self.areas = areas
        var drawn: [String: NotamArea] = [:]
        var shapes: [Airspace] = []
        for area in areas where area.activation.overlaps(from: now, to: now.addingTimeInterval(Self.drawAhead)) {
            guard !area.activation.areas.contains(where: knownAreas.contains) else { continue }
            for airspace in area.airspaces {
                drawn[airspace.id] = area
                shapes.append(airspace)
            }
        }
        self.drawn = drawn
        self.shapes = shapes
    }

    /// The drawn areas over `region`, all of them without one.
    func airspaces(in region: MKCoordinateRegion?) -> [Airspace] {
        guard let region else { return shapes }
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2
        return shapes.filter { airspace in
            guard let box = airspace.boundingBox else { return false }
            return box.maxLat >= minLat && box.minLat <= maxLat && box.maxLon >= minLon && box.minLon <= maxLon
        }
    }

    /// The NOTAM naming this area that matters most now: active, else the next to be.
    func naming(_ key: String, now: Date) -> NotamArea? {
        let named = areas.filter { $0.activation.areas.contains(key) && $0.activation.windows.contains { $0.end >= now } }
        func next(_ area: NotamArea) -> Date { area.activation.windows.first { $0.end >= now }?.start ?? .distantFuture }
        return named.first { $0.activation.isActive(at: now) } ?? named.min { next($0) < next($1) }
    }
}
