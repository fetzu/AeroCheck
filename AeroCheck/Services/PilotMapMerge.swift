import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One tile from the same tile of several regions (6.8.0, the pilot's map for every country): each region is cut at its
/// own outline, so a tile across a border, and a low-zoom tile spanning several regions, holds a part in each. MapLibre
/// takes one tile per address, so the parts are joined here before it sees them.
enum PilotTileMerge {
    // MARK: - Vector tiles

    /// The map's tiles (plain Mapbox Vector Tiles) as one: every layer of each, the layers of the same name joined, the
    /// later ones' features appended with their key and value indexes moved past the earlier ones'. Nil when no tile
    /// parses. A layer whose extent differs from the first of its name is left out (the build writes 4096 everywhere).
    static func vector(_ tiles: [Data]) -> Data? {
        var order: [String] = []
        var layers: [String: Layer] = [:]
        var parsed = 0
        for data in tiles {
            guard let tileLayers = try? Self.layers(of: data) else { continue }
            parsed += 1
            for layer in tileLayers {
                if var existing = layers[layer.name] {
                    guard existing.extent == layer.extent else { continue }
                    existing.append(layer)
                    layers[layer.name] = existing
                } else {
                    order.append(layer.name)
                    layers[layer.name] = layer
                }
            }
        }
        guard parsed > 0 else { return nil }
        var out = Data()
        for name in order {
            guard let layer = layers[name] else { continue }
            Proto.writeBytes(field: 3, layer.encoded(), to: &out)
        }
        return out
    }

    /// A tile's layers.
    static func layers(of data: Data) throws -> [Layer] {
        var reader = Proto.Reader(data)
        var out: [Layer] = []
        while let (field, wire) = try reader.key() {
            if field == 3, wire == 2 {
                out.append(try Layer(try reader.bytes()))
            } else {
                try reader.skip(wire)
            }
        }
        return out
    }

    /// A layer as the merge needs it: its features and values kept as their bytes, its keys as strings.
    struct Layer {
        var name = ""
        var version: UInt64 = 1
        var extent: UInt64 = 4096
        var keys: [Data] = []
        var values: [Data] = []
        var features: [Data] = []

        init(_ data: Data) throws {
            var reader = Proto.Reader(data)
            while let (field, wire) = try reader.key() {
                switch (field, wire) {
                case (15, 0): version = try reader.varint()
                case (1, 2): name = String(decoding: try reader.bytes(), as: UTF8.self)
                case (2, 2): features.append(try reader.bytes())
                case (3, 2): keys.append(try reader.bytes())
                case (4, 2): values.append(try reader.bytes())
                case (5, 0): extent = try reader.varint()
                default: try reader.skip(wire)
                }
            }
        }

        /// Another layer of the same name joined to this one.
        mutating func append(_ other: Layer) {
            let keyOffset = UInt64(keys.count), valueOffset = UInt64(values.count)
            keys += other.keys
            values += other.values
            for feature in other.features {
                if let moved = try? Self.moving(feature, keys: keyOffset, values: valueOffset) {
                    features.append(moved)
                }
            }
        }

        /// A feature with its tags (pairs of key and value indexes) moved by the offsets, every other field as it was.
        static func moving(_ feature: Data, keys: UInt64, values: UInt64) throws -> Data {
            var reader = Proto.Reader(feature)
            var out = Data()
            while let (field, wire) = try reader.key() {
                if field == 2, wire == 2 {
                    var tags = Proto.Reader(try reader.bytes())
                    var packed = Data()
                    var index = 0
                    while !tags.atEnd {
                        let value = try tags.varint()
                        Proto.writeVarint(value + (index % 2 == 0 ? keys : values), to: &packed)
                        index += 1
                    }
                    Proto.writeBytes(field: 2, packed, to: &out)
                } else {
                    out.append(try reader.raw(wire, field: field))
                }
            }
            return out
        }

        func encoded() -> Data {
            var out = Data()
            Proto.writeKey(field: 15, wire: 0, to: &out)
            Proto.writeVarint(version, to: &out)
            Proto.writeBytes(field: 1, Data(name.utf8), to: &out)
            for feature in features { Proto.writeBytes(field: 2, feature, to: &out) }
            for key in keys { Proto.writeBytes(field: 3, key, to: &out) }
            for value in values { Proto.writeBytes(field: 4, value, to: &out) }
            Proto.writeKey(field: 5, wire: 0, to: &out)
            Proto.writeVarint(extent, to: &out)
            return out
        }
    }

    // MARK: - Relief tiles

    /// The height the build writes outside a region's outline (AeroCheck-maps clip.py, RELIEF_OUTSIDE_M = -100 m), in
    /// Terrarium's encoding: R * 256 + G + B / 256 - 32768.
    static let outside: (r: UInt8, g: UInt8, b: UInt8) = (127, 156, 0)

    /// The relief's tiles (Terrarium, any format ImageIO reads) as one PNG: each pixel from the first tile with terrain
    /// there. Nil when none decodes or their sizes differ.
    static func relief(_ tiles: [Data]) -> Data? {
        let images = tiles.compactMap(Self.pixels)
        guard var merged = images.first else { return nil }
        for image in images.dropFirst() {
            guard image.width == merged.width, image.height == merged.height else { continue }
            for i in stride(from: 0, to: merged.bytes.count, by: 4)
            where merged.bytes[i] == outside.r && merged.bytes[i + 1] == outside.g && merged.bytes[i + 2] == outside.b {
                merged.bytes[i] = image.bytes[i]
                merged.bytes[i + 1] = image.bytes[i + 1]
                merged.bytes[i + 2] = image.bytes[i + 2]
            }
        }
        return png(merged)
    }

    struct Pixels {
        let width: Int
        let height: Int
        /// RGBA, 8 bits each, alpha unused.
        var bytes: [UInt8]
    }

    /// The image's exact RGB values: drawn into an sRGB bitmap of its own colour space and size, no interpolation, so
    /// the heights come out as encoded.
    static func pixels(_ data: Data) -> Pixels? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Pixels(width: width, height: height, bytes: bytes) : nil
    }

    static func png(_ pixels: Pixels) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels.bytes) as CFData),
              let image = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: pixels.width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

/// The few protocol buffer operations a vector tile needs: keys, varints, length-delimited fields.
enum Proto {
    enum Failure: Error { case truncated, wireType }

    struct Reader {
        private let data: Data
        private var offset: Data.Index

        init(_ data: Data) {
            self.data = data
            offset = data.startIndex
        }

        var atEnd: Bool { offset >= data.endIndex }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard offset < data.endIndex, shift < 64 else { throw Failure.truncated }
                let byte = data[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        /// The next field's number and wire type, nil at the end.
        mutating func key() throws -> (Int, Int)? {
            guard !atEnd else { return nil }
            let key = try varint()
            return (Int(key >> 3), Int(key & 7))
        }

        mutating func bytes() throws -> Data {
            let length = Int(try varint())
            guard length >= 0, offset + length <= data.endIndex else { throw Failure.truncated }
            defer { offset += length }
            return Data(data[offset..<offset + length])
        }

        mutating func skip(_ wire: Int) throws {
            switch wire {
            case 0: _ = try varint()
            case 1: try advance(8)
            case 2: _ = try bytes()
            case 5: try advance(4)
            default: throw Failure.wireType
            }
        }

        /// A field's whole encoding, its key included, for a field kept as it was.
        mutating func raw(_ wire: Int, field: Int) throws -> Data {
            let start = offset
            try skip(wire)
            var out = Data()
            Proto.writeKey(field: field, wire: wire, to: &out)
            out.append(data[start..<offset])
            return out
        }

        private mutating func advance(_ count: Int) throws {
            guard offset + count <= data.endIndex else { throw Failure.truncated }
            offset += count
        }
    }

    static func writeVarint(_ value: UInt64, to out: inout Data) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    static func writeKey(field: Int, wire: Int, to out: inout Data) {
        writeVarint(UInt64(field << 3 | wire), to: &out)
    }

    static func writeBytes(field: Int, _ bytes: Data, to out: inout Data) {
        writeKey(field: field, wire: 2, to: &out)
        writeVarint(UInt64(bytes.count), to: &out)
        out.append(bytes)
    }
}
