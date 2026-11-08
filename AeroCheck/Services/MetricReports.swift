import Foundation
import MetricKit

/// iOS's daily reports on the app (MetricKit): energy, the GPS's time on, the screen's share, hangs and their stacks,
/// launch times. Kept on the device, the newest 14 of each kind, and never sent anywhere: Settings › About ›
/// Developer options shares them when the pilot chooses to. A simulator never receives one. (decision q5, 6.10.0)
final class MetricReports: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricReports()

    /// The reports kept of each kind.
    static let kept = 14

    enum Kind: String, CaseIterable {
        case metrics, diagnostics
    }

    private let folder: URL
    private let fileManager = FileManager.default
    private var isSubscribed = false

    init(folder: URL? = nil) {
        self.folder = folder ?? URL.applicationSupportDirectory.appending(path: "MetricReports", directoryHint: .isDirectory)
        super.init()
    }

    /// At launch: iOS hands over what it has gathered since the last report.
    func start() {
        guard !isSubscribed else { return }
        isSubscribed = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { keep(payload.jsonRepresentation(), kind: .metrics, ending: payload.timeStampEnd) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { keep(payload.jsonRepresentation(), kind: .diagnostics, ending: payload.timeStampEnd) }
    }

    /// A report, named by the day it ends and its kind; the oldest past `kept` go.
    func keep(_ json: Data, kind: Kind, ending: Date) {
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        // "2026-11-08T071500Z": sorts by time, no colon in a file name.
        let stamp = ending.ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: false, dateSeparator: .dash,
                                                  dateTimeSeparator: .standard, timeSeparator: .omitted))
        let url = folder.appending(path: "AeroCheck-\(stamp)-\(kind.rawValue).json")
        try? json.write(to: url, options: .atomic)
        let old = files(of: kind).dropLast(Self.kept)
        for url in old { try? fileManager.removeItem(at: url) }
        AppLog.general.publicNotice("MetricKit: a \(kind.rawValue) report kept (\(min(files(of: kind).count, Self.kept)) on the device)")
    }

    /// The reports on the device, oldest first.
    func files(of kind: Kind? = nil) -> [URL] {
        let all = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return all.filter { url in
            url.pathExtension == "json" && (kind.map { url.lastPathComponent.hasSuffix("-\($0.rawValue).json") } ?? true)
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
