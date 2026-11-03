import Compression
import Foundation
@testable import AeroCheck

/// A PMTiles v3 archive written in the test itself, from a few synthetic tiles: never map data in this repository.
/// Laid out as the AeroCheck-maps build writes one: header, root directory, metadata, leaf directories, tiles.
enum PMTilesFixture {
    struct Tile {
        let z: Int, x: Int, y: Int
        let bytes: Data
    }

    /// - Parameters:
    ///   - gzipTiles: stores the tiles gzip, as the map's vector tiles are (the relief's are plain).
    ///   - gzipDirectories: compression 2 for the directories, else 1 (none).
    ///   - leafSize: when set, the tile entries go into leaf directories of that many entries each.
    ///   - shareRuns: consecutive tile ids with equal bytes share one entry (a run), as the spec allows.
    static func archive(_ tiles: [Tile], gzipTiles: Bool = true, gzipDirectories: Bool = true,
                        leafSize: Int? = nil, shareRuns: Bool = false) -> Data {
        let sorted = tiles.map { (PMTiles.tileID(z: $0.z, x: $0.x, y: $0.y), $0.bytes) }.sorted { $0.0 < $1.0 }
        var tileData = Data()
        var entries: [PMTiles.Entry] = []
        for (id, bytes) in sorted {
            if shareRuns, let last = entries.last, last.tileID + UInt64(last.runLength) == id,
               tileData.suffix(last.length) == (gzipTiles ? gzip(bytes) : bytes) {
                entries[entries.count - 1] = PMTiles.Entry(tileID: last.tileID, offset: last.offset, length: last.length,
                                                           runLength: last.runLength + 1)
                continue
            }
            let stored = gzipTiles ? gzip(bytes) : bytes
            entries.append(PMTiles.Entry(tileID: id, offset: tileData.count, length: stored.count, runLength: 1))
            tileData.append(stored)
        }

        func compress(_ d: Data) -> Data { gzipDirectories ? gzip(d) : d }
        var rootEntries = entries
        var leaves = Data()
        if let leafSize {
            rootEntries = []
            for start in stride(from: 0, to: entries.count, by: leafSize) {
                let chunk = Array(entries[start..<min(start + leafSize, entries.count)])
                let bytes = compress(serialize(chunk))
                rootEntries.append(PMTiles.Entry(tileID: chunk[0].tileID, offset: leaves.count, length: bytes.count, runLength: 0))
                leaves.append(bytes)
            }
        }
        let root = compress(serialize(rootEntries))
        let metadata = compress(Data("{}".utf8))
        let rootOffset = 127
        let metadataOffset = rootOffset + root.count
        let leafOffset = metadataOffset + metadata.count
        let tileOffset = leafOffset + leaves.count
        let zooms = tiles.map(\.z)

        var header = Data("PMTiles".utf8)
        header.append(3)
        for value in [rootOffset, root.count, metadataOffset, metadata.count, leafOffset, leaves.count,
                      tileOffset, tileData.count, tiles.count, entries.count, entries.count] {
            header.append(contentsOf: withUnsafeBytes(of: UInt64(value).littleEndian, Array.init))
        }
        header.append(1)                                   // clustered
        header.append(gzipDirectories ? 2 : 1)             // internal compression
        header.append(gzipTiles ? 2 : 1)                   // tile compression
        header.append(gzipTiles ? 1 : 4)                   // MVT, or WebP
        header.append(UInt8(zooms.min() ?? 0))
        header.append(UInt8(zooms.max() ?? 0))
        header.append(Data(count: 127 - header.count))     // bounds and centre: unused by the reader
        return header + root + metadata + leaves + tileData
    }

    static func serialize(_ entries: [PMTiles.Entry]) -> Data {
        var out = Data()
        func varint(_ v: UInt64) {
            var v = v
            while v >= 0x80 { out.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
            out.append(UInt8(v))
        }
        varint(UInt64(entries.count))
        var last: UInt64 = 0
        for e in entries { varint(e.tileID - last); last = e.tileID }
        for e in entries { varint(UInt64(e.runLength)) }
        for e in entries { varint(UInt64(e.length)) }
        for (i, e) in entries.enumerated() {
            if i > 0, e.offset == entries[i - 1].offset + entries[i - 1].length { varint(0) } else { varint(UInt64(e.offset + 1)) }
        }
        return out
    }

    /// A gzip member (RFC 1952) around Apple's raw DEFLATE, with its CRC-32.
    static func gzip(_ data: Data) -> Data {
        let input = [UInt8](data)
        var out = [UInt8](repeating: 0, count: input.count + 1024)
        let written = input.withUnsafeBufferPointer { src in
            compression_encode_buffer(&out, out.count, src.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
        }
        var gz = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
        gz.append(contentsOf: out[0..<written])
        gz.append(contentsOf: withUnsafeBytes(of: crc32(input).littleEndian, Array.init))
        gz.append(contentsOf: withUnsafeBytes(of: UInt32(input.count).littleEndian, Array.init))
        return gz
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return ~crc
    }

    /// A tile's synthetic content: recognisable, and different per tile.
    static func content(_ z: Int, _ x: Int, _ y: Int, _ tag: String = "") -> Data {
        Data("tile \(z)/\(x)/\(y)\(tag) ".utf8) + Data(repeating: UInt8(truncatingIfNeeded: z &+ x &+ y), count: 64)
    }

    /// Serves an archive's bytes as tiles.aerocheck.app does (206 with the range, the archive's ETag) and counts
    /// the requests.
    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: (Data, String)] = [:]
        private(set) var requests: [URLRequest] = []
        var ignoresRange = false

        func put(_ path: String, _ data: Data, etag: String = "\"v1\"") { lock.withLock { files[path] = (data, etag) } }

        var count: Int { lock.withLock { requests.count } }

        func count(path: String) -> Int { lock.withLock { requests.filter { $0.url?.path == path }.count } }

        lazy var fetch: PMTilesRemoteArchive.Fetch = { [unowned self] request in
            let url = request.url!
            let file = self.lock.withLock { () -> (Data, String)? in
                self.requests.append(request)
                return self.files[url.path]
            }
            guard let (data, etag) = file else {
                return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
            }
            if !self.ignoresRange, let range = request.value(forHTTPHeaderField: "Range"),
               let parts = Optional(range.dropFirst(6).split(separator: "-").compactMap { Int($0) }), parts.count == 2 {
                let upper = min(parts[1] + 1, data.count)
                let body = parts[0] < upper ? data.subdata(in: parts[0]..<upper) : Data()
                return (body, HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: ["ETag": etag])!)
            }
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": etag])!)
        }
    }
}
