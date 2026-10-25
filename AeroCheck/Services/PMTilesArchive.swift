import Compression
import Foundation

/// A PMTiles v3 archive read from a local file (a downloaded region of the pilot's map): the header, the directories
/// (gzip, as the AeroCheck-maps build writes them) and a tile's bytes by zoom, x and y. The file is memory-mapped, so
/// a 100 MB region costs only the pages a map actually reads. (6.8.0)
///
/// Spec: github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md
final class PMTilesArchive: @unchecked Sendable {
    struct Header {
        let rootOffset, rootLength, leafOffset, tileDataOffset: Int
        let internalCompression, tileCompression, tileType: UInt8
        let minZoom, maxZoom: Int
    }

    struct Entry {
        let tileID: UInt64
        let offset: Int
        let length: Int
        let runLength: Int
    }

    enum Failure: Error { case notPMTiles, badDirectory }

    let header: Header
    private let data: Data
    private let root: [Entry]
    private var leaves: [Int: [Entry]] = [:]
    private let lock = NSLock()

    init(url: URL) throws {
        let bytes = try Data(contentsOf: url, options: .alwaysMapped)
        guard bytes.count >= 127, bytes.prefix(7) == Data("PMTiles".utf8), bytes[bytes.startIndex + 7] == 3 else { throw Failure.notPMTiles }
        func u64(_ at: Int) -> Int { Int(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt64.self).littleEndian }) }
        let h = Header(rootOffset: u64(8), rootLength: u64(16), leafOffset: u64(40), tileDataOffset: u64(56),
                       internalCompression: bytes[bytes.startIndex + 97], tileCompression: bytes[bytes.startIndex + 98],
                       tileType: bytes[bytes.startIndex + 99], minZoom: Int(bytes[bytes.startIndex + 100]),
                       maxZoom: Int(bytes[bytes.startIndex + 101]))
        root = try Self.directory(Self.inflate(bytes.subdata(in: h.rootOffset..<(h.rootOffset + h.rootLength)),
                                               compression: h.internalCompression))
        header = h
        data = bytes
    }

    /// The tile's stored bytes (gzip-compressed MVT, or a WebP for the relief), nil when the archive has none.
    func tile(z: Int, x: Int, y: Int) -> Data? {
        guard z >= header.minZoom, z <= header.maxZoom else { return nil }
        let id = Self.tileID(z: z, x: x, y: y)
        var entries = root
        for _ in 0..<4 {
            guard let entry = Self.find(entries, id) else { return nil }
            if entry.runLength > 0 {
                let start = header.tileDataOffset + entry.offset
                return data.subdata(in: start..<(start + entry.length))
            }
            guard let leaf = try? leafDirectory(entry) else { return nil }
            entries = leaf
        }
        return nil
    }

    private func leafDirectory(_ entry: Entry) throws -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        if let cached = leaves[entry.offset] { return cached }
        let start = header.leafOffset + entry.offset
        let parsed = try Self.directory(Self.inflate(data.subdata(in: start..<(start + entry.length)),
                                                     compression: header.internalCompression))
        leaves[entry.offset] = parsed
        return parsed
    }

    // MARK: Format

    /// The tile's position on the Hilbert curve, after every tile of the zooms above it.
    static func tileID(z: Int, x: Int, y: Int) -> UInt64 {
        var acc: UInt64 = 0
        for i in 0..<z { acc += UInt64(1) << (2 * i) }
        let n = UInt64(1) << z
        var tx = UInt64(x), ty = UInt64(y), d: UInt64 = 0
        var s = n / 2
        while s > 0 {
            let rx: UInt64 = (tx & s) > 0 ? 1 : 0
            let ry: UInt64 = (ty & s) > 0 ? 1 : 0
            d += s * s * ((3 * rx) ^ ry)
            if ry == 0 {
                if rx == 1 { tx = n - 1 - tx; ty = n - 1 - ty }
                swap(&tx, &ty)
            }
            s /= 2
        }
        return acc + d
    }

    static func find(_ entries: [Entry], _ id: UInt64) -> Entry? {
        var lo = 0, hi = entries.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if entries[mid].tileID < id { lo = mid + 1 } else if entries[mid].tileID > id { hi = mid - 1 } else { return entries[mid] }
        }
        guard hi >= 0 else { return nil }
        let entry = entries[hi]
        return entry.runLength == 0 || id - entry.tileID < UInt64(entry.runLength) ? entry : nil
    }

    static func directory(_ bytes: Data) throws -> [Entry] {
        var index = bytes.startIndex
        func varint() throws -> UInt64 {
            var value: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard index < bytes.endIndex else { throw Failure.badDirectory }
                let byte = bytes[index]; index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
        }
        let count = Int(try varint())
        var ids = [UInt64](repeating: 0, count: count), runs = [Int](repeating: 0, count: count)
        var lengths = [Int](repeating: 0, count: count), offsets = [Int](repeating: 0, count: count)
        var last: UInt64 = 0
        for i in 0..<count { last += try varint(); ids[i] = last }
        for i in 0..<count { runs[i] = Int(try varint()) }
        for i in 0..<count { lengths[i] = Int(try varint()) }
        for i in 0..<count {
            let v = Int(try varint())
            offsets[i] = v == 0 && i > 0 ? offsets[i - 1] + lengths[i - 1] : v - 1
        }
        return (0..<count).map { Entry(tileID: ids[$0], offset: offsets[$0], length: lengths[$0], runLength: runs[$0]) }
    }

    /// Directories are gzip (compression 2) or uncompressed (1).
    static func inflate(_ bytes: Data, compression: UInt8) throws -> Data {
        guard compression == 2 else { return bytes }
        return try gunzip(bytes)
    }

    /// The deflate stream inside a gzip member (RFC 1952): its header skipped, Apple's raw DEFLATE decoder on the rest.
    static func gunzip(_ gz: Data) throws -> Data {
        let b = [UInt8](gz)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw Failure.badDirectory }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { i += 2 + Int(b[i]) | Int(b[i + 1]) << 8 }
        if flags & 8 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        let size = Int(b[b.count - 4]) | Int(b[b.count - 3]) << 8 | Int(b[b.count - 2]) << 16 | Int(b[b.count - 1]) << 24
        var out = [UInt8](repeating: 0, count: max(size, 1))
        let written = b.withUnsafeBufferPointer { src in
            compression_decode_buffer(&out, out.count, src.baseAddress! + i, b.count - i - 8, nil, COMPRESSION_ZLIB)
        }
        guard written == size else { throw Failure.badDirectory }
        return Data(out)
    }
}
