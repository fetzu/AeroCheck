import CoreLocation
import Foundation

// MARK: - Which Swiss areas are active (6.9.0)
//
// skyguide's Daily Airspace Bulletin, read by the server four times a day (`scripts/dabs/`, the author's a13) and served
// at `/data/activation/v1/CH/<date>.json`. In Switzerland an R or D area not on a fresh bulletin is inactive: faded, no
// tag, no airspace-ahead state, as SkyDemon has done since 4.1.0 (a14 A). Without today's file everything counts as
// active, and the map says so. Outside Switzerland every R area counts as active: nothing like the DABS exists there.
// The file is free, like the airspace, and it never replaces the NOTAMs: one can change an area between versions.

/// The server's file. Only what the app reads: a new key is additive.
struct ActivationFile: Codable, Equatable {
    static let schema = 1

    struct Limit: Codable, Equatable {
        let raw: String
        let ft: Int
        let ref: String

        /// In OpenAIP's terms, so the bands work out as for any airspace.
        var altitudeLimit: AltitudeLimit {
            switch ref {
            case "GND": return AltitudeLimit(value: 0, unit: 1, referenceDatum: 0)
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

    init(files: [String: ActivationFile], now: Date) {
        file = files[Self.dayString(now)]
        self.now = now
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
    /// (they can differ from the AIP's), and the areas made by NOTAM added.
    func applied(_ airspaces: [Airspace]) -> [Airspace] {
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
        }
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

    /// What the tap card says of an airspace, or nil where the bulletin says nothing of it.
    func note(for airspace: Airspace) -> String? {
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

    /// Today's bulletin against the airspace.
    var board: ActivationBoard { ActivationBoard(files: files, now: now()) }

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
