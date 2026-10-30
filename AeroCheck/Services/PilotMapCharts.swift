import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The swisstopo charts and OpenAIP's tiles on the MapLibre map (6.8.0): raster sources whose tiles MapLibre asks of
/// `PilotTileURLProtocol` at https://tiles.aerocheck.app/local/…, which never reaches the network under that name. The
/// protocol answers them as the MapKit overlays did (`ChartTileSpec`): the downloaded copy first, then swisstopo's or
/// OpenAIP's own host unless the map is offline, the National Map's blank tiles as none, OpenAIP's fills stripped.
enum PilotMapCharts {
    /// The path prefix the protocol answers locally.
    static let localPrefix = "local"

    /// The swisstopo layers a chart source may name: nothing else is fetched.
    static let swisstopoLayers: [String: String] = [
        "ch.bazl.luftfahrtkarten-icao": "png",
        "ch.bazl.segelflugkarte": "png",
        "ch.swisstopo.pixelkarte-farbe": "jpeg",
        "ch.swisstopo.swissimage": "jpeg",
    ]

    static func chartTemplate(layer: String, offline: Bool) -> String {
        "https://\(PilotMapConfig.host)/\(localPrefix)/chart/\(layer)/{z}/{x}/{y}?offline=\(offline ? 1 : 0)"
    }

    static func openAIPTemplate(offline: Bool) -> String {
        "https://\(PilotMapConfig.host)/\(localPrefix)/openaip/{z}/{x}/{y}?offline=\(offline ? 1 : 0)"
    }

    /// A raster source and the zooms it shows at, in MapLibre's zoom (MapKit's − 1, `MapZoom`).
    struct Raster: Equatable {
        let id: String
        let template: String
        /// The tiles the source has (tile zooms, 256-pixel tiles: MapKit's numbers). Past `maxTileZoom`, MapLibre
        /// enlarges the last zoom, as `ChartTileRenderer` did.
        let minTileZoom: Int
        let maxTileZoom: Int
        /// Where the layer shows, in MapLibre's zoom; nil for no limit.
        let minZoom: Double?
        let maxZoom: Double?
    }

    /// The chart rasters for a layer choice, bottom first, as `ChartPolicy.overlay(for:)` draws it on MapKit: the ICAO
    /// chart, the glider chart from MapKit zoom 11, then the National Map from 13 (not when forced or offline); the
    /// forced ICAO chart alone; offline, the downloaded charts only.
    static func rasters(for layer: MapLayerType, policy: ChartPolicy) -> [Raster] {
        let offline = policy.strictOffline
        let icao = "ch.bazl.luftfahrtkarten-icao", glider = "ch.bazl.segelflugkarte"
        let national = ICAOSegelflugkarteTileOverlay.nationalMapLayerIdentifier
        func z(_ mapKit: Int) -> Double { MapZoom.mapLibre(fromMapKit: Double(mapKit)) }
        switch policy.layer(for: layer) {
        case .icao:
            if policy.forceICAO || (offline && !policy.segelflugCache) {
                return [Raster(id: "chart-icao", template: chartTemplate(layer: icao, offline: offline),
                               minTileZoom: 7, maxTileZoom: 11, minZoom: nil, maxZoom: nil)]
            }
            let gliderFrom = ICAOSegelflugkarteTileOverlay.gliderMinZoom
            var rasters = [
                Raster(id: "chart-icao", template: chartTemplate(layer: icao, offline: offline),
                       minTileZoom: 7, maxTileZoom: gliderFrom - 1, minZoom: nil, maxZoom: z(gliderFrom)),
                Raster(id: "chart-glider", template: chartTemplate(layer: glider, offline: offline),
                       minTileZoom: gliderFrom, maxTileZoom: 12, minZoom: z(gliderFrom),
                       maxZoom: offline ? nil : z(ICAOSegelflugkarteTileOverlay.nationalMapMinZoom)),
            ]
            if !offline {
                rasters.append(Raster(id: "chart-national", template: chartTemplate(layer: national, offline: false),
                                      minTileZoom: ICAOSegelflugkarteTileOverlay.nationalMapMinZoom, maxTileZoom: 18,
                                      minZoom: z(ICAOSegelflugkarteTileOverlay.nationalMapMinZoom), maxZoom: nil))
            }
            return rasters
        case .satellite:
            // Until the aerial imagery's sources (the plan's PR 5): SWISSIMAGE over Switzerland, as MapKit drew it over
            // Apple's satellite map.
            return rasters(for: .swissimage, policy: policy)
        case .landeskarten, .swissimage:
            guard let id = layer.swisstopoLayerIdentifier, !offline else { return [] }
            return [Raster(id: "chart-\(layer == .swissimage ? "swissimage" : "national")",
                           template: chartTemplate(layer: id, offline: false),
                           minTileZoom: layer.minimumZoom, maxTileZoom: layer.maximumZoom, minZoom: nil, maxZoom: nil)]
        case .standard:
            return []
        }
    }

    static func openAIPRaster(offline: Bool) -> Raster {
        Raster(id: "openaip", template: openAIPTemplate(offline: offline), minTileZoom: OpenAIPConfig.tileMinZoom,
               maxTileZoom: OpenAIPConfig.tileMaxZoom, minZoom: nil, maxZoom: nil)
    }

    // MARK: - Answering a tile

    /// A chart tile as `ChartTileSpec`: the downloaded copy of the ICAO and glider charts, swisstopo's host, the
    /// National Map's blank tiles dropped. nil for a layer not on the list.
    static func chartSpec(layer: String, z: Int, x: Int, y: Int, offline: Bool) -> ChartTileSpec? {
        guard let ext = swisstopoLayers[layer], let url = SwisstopoTiles.url(layer: layer, z: z, x: x, y: y, fileExtension: ext)
        else { return nil }
        var spec = ChartTileSpec(key: url.absoluteString, dropsBlank: layer == ICAOSegelflugkarteTileOverlay.nationalMapLayerIdentifier)
        if let cached = CacheableLayer.allCases.first(where: { $0.swisstopoIdentifier == layer }) {
            spec.disk = OfflineMapManager.tileFileURL(z: z, x: x, y: y, layer: cached)
        }
        if !offline { spec.fetch = { try await SwisstopoTiles.fetch(url) } }
        return spec
    }

    /// An OpenAIP tile: the downloaded copy, else OpenAIP's host with the key in its header (SA-11), its fills stripped.
    static func openAIPSpec(z: Int, x: Int, y: Int, offline: Bool) -> ChartTileSpec? {
        guard z >= OpenAIPConfig.tileMinZoom, z <= OpenAIPConfig.tileMaxZoom else { return nil }
        var spec = ChartTileSpec(key: "openaip/\(z)/\(x)/\(y)", disk: OpenAIPCacheManager.tileFileURL(z: z, x: x, y: y))
        spec.process = { OpenAIPTileOverlay.strippingFills(of: $0) }
        if !offline, let request = OpenAIPConfig.tileRequest(z: z, x: x, y: y) {
            spec.fetch = { try await ExternalRequest.data(for: request, maxResponseBytes: OpenAIPConfig.maxTileBytes) }
        }
        return spec
    }

    /// The bytes MapLibre gets for a spec: the image as stored, or as processed (re-encoded as PNG); nil for none.
    static func bytes(for spec: ChartTileSpec) async -> Data? {
        var data: Data?
        if let disk = spec.disk { data = try? Data(contentsOf: disk) }
        if data == nil, let fetch = spec.fetch, let (fetched, response) = try? await fetch(), response.statusCode == 200 {
            data = fetched
        }
        guard let data, !data.isEmpty else { return nil }
        if spec.dropsBlank && SwisstopoTiles.isBlank(data) { return nil }
        guard let process = spec.process else { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let processed = process(image) else { return nil }
        return png(processed)
    }

    static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

/// The one place a zoom number crosses between MapKit and MapLibre: MapLibre counts zoom on 512-pixel tiles, so its
/// zoom z shows what MapKit, swisstopo's tile numbers and the proposal pages call z + 1. (6.8.0)
enum MapZoom {
    static func mapLibre(fromMapKit zoom: Double) -> Double { zoom - 1 }
    static func mapKit(fromMapLibre zoom: Double) -> Double { zoom + 1 }
}
