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

    func testTheHeightsComeOutAsEncoded() throws {
        // A height of 431.5 m (Delémont): 32768 + 431.5 = 33199.5 → R 129, G 175, B 128.
        let tile = relief(left: (129, 175, 128), right: (129, 175, 128))
        let pixels = try XCTUnwrap(PilotTileMerge.pixels(tile))
        XCTAssertEqual(Array(pixels.bytes[0..<3]), [129, 175, 128])
    }
}
