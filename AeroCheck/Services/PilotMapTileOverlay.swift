#if DEBUG
import MapKit
import MapLibre
import UIKit

// MARK: - Trial D: MapLibre draws tiles for MapKit (round 3, S2 A)

/// DEV-ONLY (`AEROCHECK_MAP_TRIAL=D`): the pilot's map as a chart overlay. Each 256-point tile is rendered on the device
/// by a MapLibre snapshotter from the downloaded vector data and relief (`style-tiles.json`, no labels: names would be
/// cut at tile edges and turn with the map; they'd be MapKit markers), at 2x, and drawn by `ChartTileRenderer` like any
/// chart. Every render is timed into `Documents/MapTrial/results-D.json`.
final class PilotMapTileOverlay: MKTileOverlay, ChartTileSource {
    override init(urlTemplate: String?) {
        super.init(urlTemplate: nil)
        minimumZ = 5
        maximumZ = 18
        canReplaceMapContent = true
    }

    convenience init() { self.init(urlTemplate: nil) }

    /// The renderer enlarges nothing: data is drawn at every zoom.
    var enlargesPastLastZoom: Int { 0 }

    func spec(for tile: ChartTile) -> ChartTileSpec? {
        ChartTileSpec(key: "pilot-trial/\(tile)", fetch: {
            let data = try await PilotTileRenderer.shared.render(tile)
            let response = HTTPURLResponse(url: URL(string: "https://trial.invalid/\(tile)")!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (data, response)
        })
    }
}

/// A few snapshotters, reused tile after tile; MapLibre wants them driven from the main thread.
@MainActor
final class PilotTileRenderer {
    static let shared = PilotTileRenderer()
    private var idle: [MLNMapSnapshotter] = []
    private var made = 0
    private let poolSize = 3
    private var waiting: [CheckedContinuation<MLNMapSnapshotter, Never>] = []
    private var timings: [(tile: String, ms: Double)] = []
    /// When each render finished and how long it took, for the trial's flight (`PilotTileTrialView`).
    var completions: [(at: CFTimeInterval, ms: Double)] = []
    private let style = MapTrial.styleURL(labels: false)

    enum Failure: Error { case noData, noImage }

    func render(_ tile: ChartTile) async throws -> Data {
        guard let style else { throw Failure.noData }
        let snapshotter = await take(style)
        defer { give(snapshotter) }
        let options = MLNMapSnapshotOptions(styleURL: style, camera: MLNMapCamera(), size: CGSize(width: 256, height: 256))
        options.coordinateBounds = Self.bounds(tile)
        options.scale = 2
        options.showsLogo = false
        options.showsAttribution = false
        snapshotter.options = options
        let started = CACurrentMediaTime()
        let image: UIImage = try await withCheckedThrowingContinuation { done in
            snapshotter.start { snapshot, error in
                if let image = snapshot?.image { done.resume(returning: image) } else { done.resume(throwing: error ?? Failure.noImage) }
            }
        }
        let ms = (CACurrentMediaTime() - started) * 1000
        record("\(tile)", ms)
        completions.append((CACurrentMediaTime(), ms))
        guard let png = image.pngData() else { throw Failure.noImage }
        return png
    }

    private func take(_ style: URL) async -> MLNMapSnapshotter {
        if let s = idle.popLast() { return s }
        if made < poolSize {
            made += 1
            return MLNMapSnapshotter(options: MLNMapSnapshotOptions(styleURL: style, camera: MLNMapCamera(), size: CGSize(width: 256, height: 256)))
        }
        return await withCheckedContinuation { waiting.append($0) }
    }

    private func give(_ s: MLNMapSnapshotter) {
        if waiting.isEmpty { idle.append(s) } else { waiting.removeFirst().resume(returning: s) }
    }

    private func record(_ tile: String, _ ms: Double) {
        timings.append((tile, ms))
        guard timings.count % 25 == 0 else { return }
        let sorted = timings.map(\.ms).sorted()
        func pct(_ p: Double) -> Double { sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)] }
        MapTrial.write(["tiles": sorted.count, "tile_ms_p50": pct(0.5), "tile_ms_p95": pct(0.95), "tile_ms_max": sorted.last ?? 0,
                        "pool": poolSize, "footprint_mb": MapTrial.footprintMB(),
                        "last": timings.suffix(25).map { ["tile": $0.tile, "ms": ($0.ms * 10).rounded() / 10] }],
                       to: "results-D.json")
    }

    /// The tile's corners in latitude and longitude (web Mercator, 256-point tiles).
    static func bounds(_ t: ChartTile) -> MLNCoordinateBounds {
        let n = Double(1 << t.z)
        func lon(_ x: Double) -> Double { x / n * 360 - 180 }
        func lat(_ y: Double) -> Double { atan(sinh(.pi * (1 - 2 * y / n))) * 180 / .pi }
        return MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: lat(Double(t.y + 1)), longitude: lon(Double(t.x))),
                                   ne: CLLocationCoordinate2D(latitude: lat(Double(t.y)), longitude: lon(Double(t.x + 1))))
    }
}
#endif
