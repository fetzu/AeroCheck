import Foundation

/// Where a file the pilot exports or shares is written while the share sheet, Quick Look or the
/// exporter reads it, and how it is removed afterwards. (S9-06)
///
/// Every export (the logbook ZIP and PDF with the pilot's name, a flight's GPX or JSON track, the
/// nav-log PDFs, share-card images, the cost CSV) was written straight into `tmp/` with a bare
/// `.atomic` and never deleted, so each "Share" left another copy of the flight history behind.
/// Now each export gets a directory of its own under `tmp/Exports/`, written with the datastore's
/// at-rest protection, and the directory goes when the last thing holding the file (the share
/// sheet, the preview, the sheet's state) lets go of it. `sweep()` at launch takes whatever a
/// crash or a kill left behind, and the loose files older builds wrote at the top of `tmp/`.
///
/// The same fix SEC-C27 made for the staged CloudKit assets in `SyncManager`.
enum ExportStaging {

    /// Holds every staged export, one directory per export.
    nonisolated static var rootDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    /// Extensions of the loose files older builds wrote at the top of `tmp/`.
    nonisolated static let legacyExtensions: Set<String> = ["zip", "pdf", "gpx", "json", "jpg", "csv", "xlsx"]

    /// Writes `data` as `filename` in a new directory of its own under `root`, so two exports with
    /// the same name never overwrite each other and removing one never removes the other.
    nonisolated static func stage(_ data: Data, filename: String, root: URL = rootDirectory) throws -> URL {
        let fileManager = FileManager.default
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(safeFilename(filename))
        do {
            try data.write(to: url, options: DataPersistenceManager.protectedWriteOptions)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return url
    }

    /// Removes the export directory that holds `url`. Anything that is not an export staged under
    /// `root` is left alone.
    nonisolated static func discard(_ url: URL, root: URL = rootDirectory) {
        let directory = url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes every export staged before `cutoff`, and the loose export files older builds left at
    /// the top of `legacyDirectory`. Run at launch with the launch time as the cutoff: nothing of
    /// this process can still be reading an older one, and one staged since is left alone.
    nonisolated static func sweep(before cutoff: Date = Date(),
                                  root: URL = rootDirectory,
                                  legacyDirectory: URL? = FileManager.default.temporaryDirectory) {
        let fileManager = FileManager.default
        let staged = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for directory in staged {
            let created = (try? directory.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if let created, created >= cutoff { continue }
            try? fileManager.removeItem(at: directory)
        }

        guard let legacyDirectory,
              let entries = try? fileManager.contentsOfDirectory(
                at: legacyDirectory, includingPropertiesForKeys: [.isRegularFileKey])
        else { return }
        for url in entries where legacyExtensions.contains(url.pathExtension.lowercased()) {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// A name that stays one path component: no separators, never empty, never `.` or `..`.
    nonisolated static func safeFilename(_ filename: String) -> String {
        let cleaned = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Export" : cleaned
    }
}

/// One staged export file. Its directory is removed when the last reference to it goes, which
/// ties the file's life to whatever presents it rather than to a callback that may never come.
final class StagedExport: Sendable {
    let url: URL
    private let root: URL

    init(data: Data, filename: String, root: URL = ExportStaging.rootDirectory) throws {
        self.url = try ExportStaging.stage(data, filename: filename, root: root)
        self.root = root
    }

    deinit {
        ExportStaging.discard(url, root: root)
    }
}
