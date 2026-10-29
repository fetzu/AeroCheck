import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AeroCheck

/// One tile from several regions' parts (6.8.0, the pilot's map for every country): vector layers joined with their
/// key and value indexes moved, relief pixels taken from the region with terrain there.
final class PilotMapMergeTests: XCTestCase {
    // MARK: Vector

    /// A layer with one point feature tagged `key` = `value` (a string), as the build writes them.
    private func layer(_ name: String, key: String, value: String, extent: UInt64 = 4096) -> Data {
        var feature = Data()
        Proto.writeKey(field: 1, wire: 0, to: &feature); Proto.writeVarint(7, to: &feature)        // id
        Proto.writeBytes(field: 2, Data([0, 0]), to: &feature)                                      // tags: key 0 = value 0
        Proto.writeKey(field: 3, wire: 0, to: &feature); Proto.writeVarint(1, to: &feature)        // point
        Proto.writeBytes(field: 4, Data([9, 50, 34]), to: &feature)                                 // MoveTo(25, 17)
        var stringValue = Data()
        Proto.writeBytes(field: 1, Data(value.utf8), to: &stringValue)
        var out = Data()
        Proto.writeKey(field: 15, wire: 0, to: &out); Proto.writeVarint(2, to: &out)
        Proto.writeBytes(field: 1, Data(name.utf8), to: &out)
        Proto.writeBytes(field: 2, feature, to: &out)
        Proto.writeBytes(field: 3, Data(key.utf8), to: &out)
        Proto.writeBytes(field: 4, stringValue, to: &out)
        Proto.writeKey(field: 5, wire: 0, to: &out); Proto.writeVarint(extent, to: &out)
        return out
    }

    private func tile(_ layers: Data...) -> Data {
        var out = Data()
        for l in layers { Proto.writeBytes(field: 3, l, to: &out) }
        return out
    }

    private func tags(_ feature: Data) throws -> [UInt64] {
        var reader = Proto.Reader(feature)
        while let (field, wire) = try reader.key() {
            if field == 2, wire == 2 {
                var packed = Proto.Reader(try reader.bytes())
                var out: [UInt64] = []
                while !packed.atEnd { out.append(try packed.varint()) }
                return out
            }
            try reader.skip(wire)
        }
        return []
    }

    func testLayersOfTheSameNameAreJoined() throws {
        let ch = tile(layer("places", key: "name", value: "Delémont"))
        let fr = tile(layer("places", key: "kind_detail", value: "Belfort"))
        let merged = try XCTUnwrap(PilotTileMerge.vector([ch, fr]))
        let layers = try PilotTileMerge.layers(of: merged)
        XCTAssertEqual(layers.map(\.name), ["places"])
        let places = try XCTUnwrap(layers.first)
        XCTAssertEqual(places.features.count, 2)
        XCTAssertEqual(places.keys.map { String(decoding: $0, as: UTF8.self) }, ["name", "kind_detail"])
        XCTAssertEqual(places.values.count, 2)
        XCTAssertEqual(try tags(places.features[0]), [0, 0])
        XCTAssertEqual(try tags(places.features[1]), [1, 1], "the second part's tags moved past the first's")
        XCTAssertEqual(places.version, 2)
        XCTAssertEqual(places.extent, 4096)
    }

    func testOtherLayersAreKeptInOrder() throws {
        let a = tile(layer("water", key: "kind", value: "lake"), layer("places", key: "name", value: "A"))
        let b = tile(layer("roads", key: "kind", value: "highway"))
        let merged = try XCTUnwrap(PilotTileMerge.vector([a, b]))
        XCTAssertEqual(try PilotTileMerge.layers(of: merged).map(\.name), ["water", "places", "roads"])
    }

    func testAPartWithAnotherExtentIsLeftOut() throws {
        let a = tile(layer("places", key: "name", value: "A"))
        let b = tile(layer("places", key: "name", value: "B", extent: 512))
        let places = try XCTUnwrap(try PilotTileMerge.layers(of: XCTUnwrap(PilotTileMerge.vector([a, b]))).first)
        XCTAssertEqual(places.features.count, 1)
    }

    func testNothingParsesNothingJoined() {
        XCTAssertNil(PilotTileMerge.vector([Data([0xFF, 0xFF, 0xFF])]))
    }

    func testJoiningOneTileGivesItBack() throws {
        let a = tile(layer("places", key: "name", value: "A"))
        XCTAssertEqual(try PilotTileMerge.layers(of: XCTUnwrap(PilotTileMerge.vector([a]))).first?.features.count, 1)
    }

    // MARK: Relief

    /// A 4 × 2 Terrarium PNG: the left half `left`, the right half `right`.
    private func relief(left: (UInt8, UInt8, UInt8), right: (UInt8, UInt8, UInt8)) -> Data {
        var bytes: [UInt8] = []
        for _ in 0..<2 { for x in 0..<4 { let c = x < 2 ? left : right; bytes += [c.0, c.1, c.2, 255] } }
        return PilotTileMerge.png(PilotTileMerge.Pixels(width: 4, height: 2, bytes: bytes))!
    }

    func testEachPixelFromTheRegionWithTerrainThere() throws {
        let out = PilotTileMerge.outside
        let ch = relief(left: (128, 10, 20), right: (out.r, out.g, out.b))
        let fr = relief(left: (out.r, out.g, out.b), right: (129, 30, 40))
        let merged = try XCTUnwrap(PilotTileMerge.pixels(XCTUnwrap(PilotTileMerge.relief([ch, fr]))))
        XCTAssertEqual(Array(merged.bytes[0..<3]), [128, 10, 20], "Switzerland's side")
        XCTAssertEqual(Array(merged.bytes[12..<15]), [129, 30, 40], "France's side")
    }

    /// A `size` × `size` Terrarium PNG, each pixel's height in metres from `height(column, row)`, the outside marker
    /// where it gives nil.
    private func relief(size: Int, height: (Int, Int) -> Double?) -> Data {
        var bytes: [UInt8] = []
        for row in 0..<size {
            for column in 0..<size {
                guard let h = height(column, row) else {
                    let out = PilotTileMerge.outside
                    bytes += [out.r, out.g, out.b, 255]
                    continue
                }
                let v = h + 32768, whole = v.rounded(.down)
                bytes += [UInt8(Int(whole) / 256), UInt8(Int(whole) % 256), UInt8(((v - whole) * 256).rounded(.down)), 255]
            }
        }
        return PilotTileMerge.png(PilotTileMerge.Pixels(width: size, height: size, bytes: bytes))!
    }

    private func height(_ p: PilotTileMerge.Pixels, _ column: Int, _ row: Int) -> Double {
        let i = (row * p.width + column) * 4
        return Double(p.bytes[i]) * 256 + Double(p.bytes[i + 1]) + Double(p.bytes[i + 2]) / 256 - 32768
    }

    func testAnEnlargedTileIsItsQuarterOfTheTileAbove() throws {
        // Heights rising 10 m a column and 100 m a row; the child one zoom down, east and north: columns 2–3, rows 0–1.
        let parent = relief(size: 4) { column, row in 1000 + Double(column) * 10 + Double(row) * 100 }
        let child = try XCTUnwrap(PilotTileMerge.pixels(XCTUnwrap(PilotTileMerge.reliefChild(parent, depth: 1, x: 1, y: 0))))
        XCTAssertEqual(child.width, 4)
        XCTAssertEqual(height(child, 0, 0), 1017.5, accuracy: 0.01, "between columns 1 and 2, on row 0")
        XCTAssertEqual(height(child, 3, 3), 1155, accuracy: 0.01, "column 3, between rows 1 and 2")
        XCTAssertEqual(height(child, 1, 1), 1047.5, accuracy: 0.01, "a quarter of the way across both")
    }

    func testTheOutsideStaysCrispWhenEnlarged() throws {
        // The west half outside the outline, the east at 500 m.
        let parent = relief(size: 4) { column, _ in column < 2 ? nil : 500 }
        let west = try XCTUnwrap(PilotTileMerge.pixels(XCTUnwrap(PilotTileMerge.reliefChild(parent, depth: 1, x: 0, y: 0))))
        let out = PilotTileMerge.outside
        XCTAssertEqual(Array(west.bytes[0..<3]), [out.r, out.g, out.b])
        let east = try XCTUnwrap(PilotTileMerge.pixels(XCTUnwrap(PilotTileMerge.reliefChild(parent, depth: 1, x: 1, y: 0))))
        for column in 0..<4 {
            XCTAssertEqual(height(east, column, 0), 500, accuracy: 0.01, "never blended with the -100 m marker")
        }
    }

    func testNoDepthGivesTheTileBack() {
        let tile = relief(size: 2) { _, _ in 300 }
        XCTAssertEqual(PilotTileMerge.reliefChild(tile, depth: 0, x: 5, y: 7), tile)
    }

    func testTheHeightsComeOutAsEncoded() throws {
        // A height of 431.5 m (Delémont): 32768 + 431.5 = 33199.5 → R 129, G 175, B 128.
        let tile = relief(left: (129, 175, 128), right: (129, 175, 128))
        let pixels = try XCTUnwrap(PilotTileMerge.pixels(tile))
        XCTAssertEqual(Array(pixels.bytes[0..<3]), [129, 175, 128])
    }
}
