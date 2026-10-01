import SwiftUI
import UIKit
import MapKit

/// What the card's map is asked for: the shape of its frame, the track, the plan's waypoints and how
/// they are drawn. (6.1)
struct ShareCardMapRequest {
    /// The map's frame on the card, in card points. The image is made at twice that
    /// (`ShareCardMapStyle.imageSize`), at the frame's exact shape, so nothing is cropped.
    var frame: CGSize
    /// Shares of the height the track keeps clear of, top and bottom (the Full map band's fades).
    var clearTop: CGFloat = 0
    var clearBottom: CGFloat = 0
    var style: ShareCardMapStyle = .standard
    /// The track to draw, already trimmed when the pilot hides where they parked.
    var track: [CLLocationCoordinate2D]
    var waypoints: [ShareCardMapWaypoint] = []
    /// Several legs instead of one track: the journey card. `track` is then every leg end to end,
    /// which frames the map. (6.1)
    var journey: ShareCardMapJourney?

    /// The journey card's map: framed on every leg, drawn leg by leg. (6.1)
    static func journey(_ journey: ShareCardMapJourney, frame: CGSize, clearTop: CGFloat = 0,
                        clearBottom: CGFloat = 0, style: ShareCardMapStyle) -> ShareCardMapRequest {
        ShareCardMapRequest(frame: frame, clearTop: clearTop, clearBottom: clearBottom, style: style,
                            track: journey.allCoordinates, waypoints: [], journey: journey)
    }
}

/// The map image and what it is made of, for the credit line and the sheet's note.
struct ShareCardMapImage {
    let image: UIImage
    let credit: ShareCardMapCredit
    /// The chart drawn instead of the one picked, sharper at this scale (`ShareCardMapZoom.choice`):
    /// the glider chart, or the national map for a circuit. Nil when it is the one picked.
    let substitute: ShareCardTileSource?
}

/// Draws the share card's map: swisstopo tiles composited in Web Mercator, or a MapKit snapshot,
/// with the track, the start and end dots and the plan's waypoints on top. (6.1: moved out of the
/// sheet, zoom 11 for the ICAO chart, the national map for short flights, the waypoints, a frame of
/// any shape.)
enum ShareCardMapRenderer {

    /// The navy under the waypoints' names and around their diamonds, whatever the card's theme: it
    /// is drawn on the chart, not on the card.
    private static let halo = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1)
    private static let chartTrack = UIColor(red: 0.9, green: 0.0, blue: 0.6, alpha: 1)

    @MainActor
    static func render(_ request: ShareCardMapRequest, layer: ShareCardMapLayer,
                       scheme: ShareCardColorScheme) async -> ShareCardMapImage? {
        guard request.track.count >= 2 else { return nil }
        let size = ShareCardMapStyle.imageSize(for: request.frame)
        guard let rect = ShareCardMapFraming.rect(for: request.track, aspect: size.width / size.height,
                                                  clearTop: request.clearTop, clearBottom: request.clearBottom)
        else { return nil }

        let lonSpan = MKMapPoint(x: rect.maxX, y: rect.midY).coordinate.longitude
            - MKMapPoint(x: rect.minX, y: rect.midY).coordinate.longitude
        if let choice = ShareCardMapZoom.choice(for: layer, lonSpan: lonSpan, outputWidth: size.width) {
            let (source, zoom) = choice
            // The charts and the national map take the magenta of a route; imagery the card's accent.
            let trackColor = source.credit == .imagery ? UIColor(scheme.accentColor) : chartTrack
            guard let image = await swissTiles(source: source, zoom: zoom, rect: rect, size: size,
                                               request: request, trackColor: trackColor,
                                               background: UIColor(scheme.backgroundColor))
            else { return nil }
            return ShareCardMapImage(image: image, credit: source.credit,
                                     substitute: source == layer.tileSource ? nil : source)
        }
        guard let image = await appleSnapshot(layer: layer, scheme: scheme, rect: rect, size: size, request: request)
        else { return nil }
        return ShareCardMapImage(image: image, credit: .appleMaps, substitute: nil)
    }

    // MARK: - Apple Maps

    @MainActor
    private static func appleSnapshot(layer: ShareCardMapLayer, scheme: ShareCardColorScheme, rect: MKMapRect,
                                      size: CGSize, request: ShareCardMapRequest) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = size
        // A fixed scale, not the screen's: the same image on every device.
        options.scale = ShareCardMapStyle.renderScale
        options.traitCollection = UITraitCollection(userInterfaceStyle: scheme.mapTraitStyle)
        options.mapType = layer == .satellite ? .satellite : .standard
        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            return UIGraphicsImageRenderer(size: snapshot.image.size, format: rendererFormat).image { context in
                snapshot.image.draw(at: .zero)
                drawOverlay(in: context.cgContext, request: request, trackColor: UIColor(scheme.accentColor),
                            size: size, project: { snapshot.point(for: $0) })
            }
        } catch {
            AppLog.general.debugLine("Share card map snapshot error: \(error)")
            return nil
        }
    }

    // MARK: - swisstopo tiles

    /// Tiles of `source` at `zoom` covering `rect`, drawn exactly where Web Mercator puts them (the
    /// old compositor placed latitudes linearly). A tile that does not come is left out; none at all
    /// is nil ("Map unavailable").
    private static func swissTiles(source: ShareCardTileSource, zoom: Int, rect: MKMapRect, size: CGSize,
                                   request: ShareCardMapRequest, trackColor: UIColor,
                                   background: UIColor) async -> UIImage? {
        let tiles = Double(1 << zoom)
        let tileWorld = MKMapSize.world.width / tiles
        let minX = max(0, Int(floor(rect.minX / tileWorld)))
        let maxX = min(Int(tiles) - 1, Int(floor((rect.maxX - 1) / tileWorld)))
        let minY = max(0, Int(floor(rect.minY / tileWorld)))
        let maxY = min(Int(tiles) - 1, Int(floor((rect.maxY - 1) / tileWorld)))
        guard minX <= maxX, minY <= maxY else { return nil }

        var images: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for x in minX...maxX {
                for y in minY...maxY {
                    group.addTask {
                        let key = "\(x)-\(y)"
                        // Through ExternalRequest like the nav map's tiles: the tile ceiling, the
                        // timeout, the host allow-list. (6.1)
                        guard let url = source.url(z: zoom, x: x, y: y),
                              let (data, response) = try? await SwisstopoTiles.fetch(url),
                              response.statusCode == 200,
                              let image = UIImage(data: data) else { return (key, nil) }
                        return (key, image)
                    }
                }
            }
            for await (key, image) in group {
                if let image { images[key] = image }
            }
        }
        guard !images.isEmpty else { return nil }

        let scale = size.width / rect.size.width
        func project(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
            let point = MKMapPoint(coordinate)
            return CGPoint(x: (point.x - rect.minX) * scale, y: (point.y - rect.minY) * scale)
        }
        return UIGraphicsImageRenderer(size: size, format: rendererFormat).image { context in
            // Outside a chart's coverage the server sends a transparent tile: the card's colour there.
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let side = tileWorld * scale
            for x in minX...maxX {
                for y in minY...maxY {
                    guard let tile = images["\(x)-\(y)"] else { continue }
                    tile.draw(in: CGRect(x: (Double(x) * tileWorld - rect.minX) * scale,
                                         y: (Double(y) * tileWorld - rect.minY) * scale,
                                         width: side, height: side))
                }
            }
            drawOverlay(in: context.cgContext, request: request, trackColor: trackColor,
                        size: size, project: project)
        }
    }

    // MARK: - Track, dots and waypoints

    /// The track (over a faint dark edge, so it reads on any chart), the plan's waypoints as small
    /// diamonds with their names, then the green start and the red end on top.
    private static func drawOverlay(in context: CGContext, request: ShareCardMapRequest, trackColor: UIColor,
                                    size: CGSize, project: (CLLocationCoordinate2D) -> CGPoint) {
        if let journey = request.journey {
            drawJourney(journey, in: context, style: request.style, trackColor: trackColor, size: size, project: project)
            return
        }
        let width = size.width, height = size.height
        let style = request.style
        let path = UIBezierPath()
        for (index, coordinate) in request.track.enumerated() {
            let point = project(coordinate)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(UIColor.black.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(style.trackWidth * 1.9)
        context.addPath(path.cgPath)
        context.strokePath()
        context.setStrokeColor(trackColor.cgColor)
        context.setLineWidth(style.trackWidth)
        context.addPath(path.cgPath)
        context.strokePath()

        let font = UIFont(name: AeroTypeface.monoBold, size: style.waypointFontSize)
            ?? .monospacedSystemFont(ofSize: style.waypointFontSize, weight: .bold)
        let half = style.waypointSide / 2.squareRoot()
        // What a name must not cover: the dots and the diamonds, then the names already placed.
        var taken: [CGRect] = [request.track.first, request.track.last].compactMap { $0 }.map { coordinate in
            let point = project(coordinate)
            return CGRect(x: point.x - style.markerDiameter / 2, y: point.y - style.markerDiameter / 2,
                          width: style.markerDiameter, height: style.markerDiameter)
        }
        taken += request.waypoints.map { waypoint in
            let point = project(waypoint.coordinate)
            return CGRect(x: point.x - half, y: point.y - half, width: 2 * half, height: 2 * half)
        }
        for waypoint in request.waypoints {
            let center = project(waypoint.coordinate)
            let diamond = UIBezierPath()
            diamond.move(to: CGPoint(x: center.x, y: center.y - half))
            diamond.addLine(to: CGPoint(x: center.x + half, y: center.y))
            diamond.addLine(to: CGPoint(x: center.x, y: center.y + half))
            diamond.addLine(to: CGPoint(x: center.x - half, y: center.y))
            diamond.close()
            context.setFillColor(UIColor.white.cgColor)
            context.addPath(diamond.cgPath)
            context.fillPath()
            context.setStrokeColor(halo.cgColor)
            context.setLineWidth(style.waypointRim)
            context.addPath(diamond.cgPath)
            context.strokePath()
            context.setFillColor(UIColor.white.cgColor)
            context.addPath(diamond.cgPath)
            context.fillPath()

            // The name to the right of its diamond, else to the left, above or below; left out
            // where each would cover another name, a diamond or a dot (the diamond stays).
            let text = waypoint.label as NSString
            let textWidth = text.size(withAttributes: [.font: font]).width
            let offset = half + style.waypointSide * 0.6
            let middle = center.y - font.lineHeight / 2
            let candidates = [
                CGPoint(x: center.x + offset, y: middle),
                CGPoint(x: center.x - offset - textWidth, y: middle),
                CGPoint(x: center.x - textWidth / 2, y: center.y - half - 4 - font.lineHeight),
                CGPoint(x: center.x - textWidth / 2, y: center.y + half + 4),
            ].map { CGRect(origin: $0, size: CGSize(width: textWidth, height: font.lineHeight)) }
            guard let frame = candidates.first(where: { frame in
                frame.minX >= 4 && frame.maxX <= width - 4 && frame.minY >= 4 && frame.maxY <= height - 4
                    && !taken.contains { $0.insetBy(dx: -4, dy: -2).intersects(frame) }
            }) else { continue }
            taken.append(frame)
            let origin = frame.origin
            text.draw(at: origin, withAttributes: [
                .font: font, .foregroundColor: halo,
                .strokeColor: halo, .strokeWidth: style.waypointHalo / style.waypointFontSize * 100,
            ])
            text.draw(at: origin, withAttributes: [.font: font, .foregroundColor: UIColor.white])
        }

        if let first = request.track.first {
            drawMarker(at: project(first), color: UIColor(Color.aviationGreen), style: style, in: context)
        }
        if let last = request.track.last {
            drawMarker(at: project(last), color: UIColor(Color.aviationRed), style: style, in: context)
        }
    }

    // MARK: - The journey (6.1)

    /// Each leg's track, the day's aerodromes (home in gold, or a green start and a red end; each stop
    /// white, ringed in the track's colour) with their idents, and each leg's number in a disc of the
    /// track's colour halfway along it (J1). Names that would cover a disc, a dot or another name move
    /// to another side, or are left out.
    private static func drawJourney(_ journey: ShareCardMapJourney, in context: CGContext, style: ShareCardMapStyle,
                                    trackColor: UIColor, size: CGSize, project: (CLLocationCoordinate2D) -> CGPoint) {
        let scale = ShareCardMapStyle.imagePointsPerCardPoint
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for leg in journey.legs {
            let path = UIBezierPath()
            for (index, coordinate) in leg.track.enumerated() {
                let point = project(coordinate)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.setStrokeColor(UIColor.black.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(style.trackWidth * 1.9)
            context.addPath(path.cgPath)
            context.strokePath()
            context.setStrokeColor(trackColor.cgColor)
            context.setLineWidth(style.trackWidth)
            context.addPath(path.cgPath)
            context.strokePath()
        }

        var taken: [CGRect] = []
        let markerPoints = journey.markers.map { project($0.coordinate) }
        for (marker, point) in zip(journey.markers, markerPoints) {
            let diameter: CGFloat
            switch marker.kind {
            case .home: diameter = style.markerDiameter * 1.3
            case .start, .end: diameter = style.markerDiameter
            case .stop: diameter = 22 * scale
            }
            let rect = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
            switch marker.kind {
            case .home: drawDisc(rect, fill: UIColor(Color.aviationGold), rim: .white, rimWidth: style.markerRim, in: context)
            case .start: drawDisc(rect, fill: UIColor(Color.aviationGreen), rim: .white, rimWidth: style.markerRim, in: context)
            case .end: drawDisc(rect, fill: UIColor(Color.aviationRed), rim: .white, rimWidth: style.markerRim, in: context)
            case .stop: drawDisc(rect, fill: .white, rim: trackColor, rimWidth: 4 * scale, in: context)
            }
            taken.append(rect)
        }

        // The numbers, on top of the tracks and the dots.
        let badge = 46 * scale
        let centers = ShareCardMapJourney.badgePoints(journey.legs, markers: markerPoints, clearance: badge * 1.1,
                                                      project: project)
        let numberFont = UIFont(name: AeroTypeface.bold, size: 26 * scale) ?? .boldSystemFont(ofSize: 26 * scale)
        for (leg, center) in zip(journey.legs, centers) {
            let rect = CGRect(x: center.x - badge / 2, y: center.y - badge / 2, width: badge, height: badge)
            drawDisc(rect, fill: trackColor, rim: .white, rimWidth: 3.5 * scale, in: context)
            let text = "\(leg.number)" as NSString
            let textSize = text.size(withAttributes: [.font: numberFont])
            text.draw(at: CGPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2),
                      withAttributes: [.font: numberFont, .foregroundColor: UIColor.white])
            taken.append(rect)
        }

        // The aerodromes' idents beside their dots.
        let font = UIFont(name: AeroTypeface.monoBold, size: 22 * scale)
            ?? .monospacedSystemFont(ofSize: 22 * scale, weight: .bold)
        for (marker, point) in zip(journey.markers, markerPoints) {
            guard let label = marker.label else { continue }
            let text = label as NSString
            let textWidth = text.size(withAttributes: [.font: font]).width
            let offset = 20 * scale
            let middle = point.y - font.lineHeight / 2
            let candidates = [
                CGPoint(x: point.x + offset, y: middle),
                CGPoint(x: point.x - offset - textWidth, y: middle),
                CGPoint(x: point.x - textWidth / 2, y: point.y - offset - font.lineHeight),
                CGPoint(x: point.x - textWidth / 2, y: point.y + offset),
            ].map { CGRect(origin: $0, size: CGSize(width: textWidth, height: font.lineHeight)) }
            guard let frame = candidates.first(where: { frame in
                frame.minX >= 4 && frame.maxX <= size.width - 4 && frame.minY >= 4 && frame.maxY <= size.height - 4
                    && !taken.contains { $0.insetBy(dx: -4, dy: -2).intersects(frame) }
            }) else { continue }
            taken.append(frame)
            text.draw(at: frame.origin, withAttributes: [
                .font: font, .foregroundColor: halo, .strokeColor: halo, .strokeWidth: 6.0 / 22 * 100,
            ])
            text.draw(at: frame.origin, withAttributes: [.font: font, .foregroundColor: UIColor.white])
        }
    }

    private static func drawDisc(_ rect: CGRect, fill: UIColor, rim: UIColor, rimWidth: CGFloat, in context: CGContext) {
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(rim.cgColor)
        context.setLineWidth(rimWidth)
        context.strokeEllipse(in: rect)
    }

    private static func drawMarker(at point: CGPoint, color: UIColor, style: ShareCardMapStyle, in context: CGContext) {
        let size = style.markerDiameter
        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(style.markerRim)
        context.strokeEllipse(in: rect)
    }

    /// Renders the map at `ShareCardMapStyle.renderScale`, not at the screen's scale.
    private static var rendererFormat: UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = ShareCardMapStyle.renderScale
        return format
    }
}
