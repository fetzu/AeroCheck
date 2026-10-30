import Compression
import Foundation

/// The PMTiles v3 format, as the AeroCheck-maps build writes it: a 127-byte header, a root directory within the
/// first 16 KiB, leaf directories, then the tiles. Directories are gzip (compression 2) or plain (1). (6.8.0)
///
/// Spec: github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md
enum PMTiles {
    struct Header: Equatable {
        let rootOffset, rootLength, leafOffset, tileDataOffset: Int
        let internalCompression, tileCompression, tileType: UInt8
        let minZoom, maxZoom: Int

        static let size = 127
        /// The header and the root directory always fit in the archive's first 16 KiB: one read finds both.
        static let firstRead = 16_384

        init(rootOffset: Int, rootLength: Int, leafOffset: Int, tileDataOffset: Int, internalCompression: UInt8,
             tileCompression: UInt8, tileType: UInt8, minZoom: Int, maxZoom: Int) {
            self.rootOffset = rootOffset; self.rootLength = rootLength
            self.leafOffset = leafOffset; self.tileDataOffset = tileDataOffset
            self.internalCompression = internalCompression; self.tileCompression = tileCompression
            self.tileType = tileType; self.minZoom = minZoom; self.maxZoom = maxZoom
        }

        init(_ bytes: Data) throws {
            guard bytes.count >= Self.size, bytes.prefix(7) == Data("PMTiles".utf8),
                  bytes[bytes.startIndex + 7] == 3 else { throw Failure.notPMTiles }
            func u64(_ at: Int) -> Int {
                Int(bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt64.self).littleEndian })
            }
            func u8(_ at: Int) -> UInt8 { bytes[bytes.startIndex + at] }
            self.init(rootOffset: u64(8), rootLength: u64(16), leafOffset: u64(40), tileDataOffset: u64(56),
                      internalCompression: u8(97), tileCompression: u8(98), tileType: u8(99),
                      minZoom: Int(u8(100)), maxZoom: Int(u8(101)))
        }

        /// Gzip tiles (the map's vector tiles); the relief's WebP tiles are stored plain.
        var tilesAreGzip: Bool { tileCompression == 2 }
    }

    struct Entry: Equatable {
        let tileID: UInt64
        let offset: Int
        let length: Int
        /// 0 for a leaf directory, else how many consecutive tile ids share these bytes.
        let runLength: Int
    }

    enum Failure: Error, Equatable { case notPMTiles, badDirectory, badGzip }

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

    /// The entry holding `id`: a tile's (its run covers the id) or the leaf directory to read next.
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

    /// A directory's entries from its uncompressed bytes.
    static func directory(_ bytes: Data) throws -> [Entry] {
        var index = bytes.startIndex
        func varint() throws -> UInt64 {
            var value: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard index < bytes.endIndex, shift < 64 else { throw Failure.badDirectory }
                let byte = bytes[index]; index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
        }
        let count = Int(try varint())
        // Each entry takes at least four bytes: a count past that is a corrupt directory, not a huge one.
        guard count <= bytes.count else { throw Failure.badDirectory }
        var ids = [UInt64](repeating: 0, count: count), runs = [Int](repeating: 0, count: count)
        var lengths = [Int](repeating: 0, count: count), offsets = [Int](repeating: 0, count: count)
        var last: UInt64 = 0
        for i in 0..<count { last &+= try varint(); ids[i] = last }
        for i in 0..<count { runs[i] = Int(try varint()) }
        for i in 0..<count { lengths[i] = Int(try varint()) }
        for i in 0..<count {
            let v = Int(try varint())
            guard v > 0 || i > 0 else { throw Failure.badDirectory }
            offsets[i] = v == 0 ? offsets[i - 1] + lengths[i - 1] : v - 1
        }
        return (0..<count).map { Entry(tileID: ids[$0], offset: offsets[$0], length: lengths[$0], runLength: runs[$0]) }
    }

    /// A directory's bytes as stored, uncompressed.
    static func inflate(_ bytes: Data, compression: UInt8) throws -> Data {
        guard compression == 2 else { return bytes }
        return try gunzip(bytes)
    }

    static func isGzip(_ bytes: Data) -> Bool {
        bytes.count > 2 && bytes[bytes.startIndex] == 0x1f && bytes[bytes.startIndex + 1] == 0x8b
    }

    /// The deflate stream inside a gzip member (RFC 1952): its header skipped, Apple's raw DEFLATE decoder on the rest.
    static func gunzip(_ gz: Data) throws -> Data {
        let b = [UInt8](gz)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw Failure.badGzip }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { guard i + 2 <= b.count else { throw Failure.badGzip }; i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
        if flags & 8 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { throw Failure.badGzip }
        let size = Int(b[b.count - 4]) | Int(b[b.count - 3]) << 8 | Int(b[b.count - 2]) << 16 | Int(b[b.count - 1]) << 24
        // ISIZE is the size modulo 4 GiB; a tile or a directory is never near it. Refuse a claim past 64 MB.
        guard size <= 64 << 20 else { throw Failure.badGzip }
        if size == 0 { return Data() }
        var out = [UInt8](repeating: 0, count: size)
        let written = b.withUnsafeBufferPointer { src in
            compression_decode_buffer(&out, out.count, src.baseAddress! + i, b.count - i - 8, nil, COMPRESSION_ZLIB)
        }
        guard written == size else { throw Failure.badGzip }
        return Data(out)
    }

    /// The tile's bytes as MapLibre wants them: URLSession inflates gzip only for its own HTTP loads, so what a
    /// URLProtocol hands over must be plain.
    static func plain(_ stored: Data) -> Data? {
        isGzip(stored) ? try? gunzip(stored) : stored
    }
}

/// A PMTiles archive read from a local file (a downloaded region of the pilot's map). The file is memory-mapped, so
/// a 100 MB region costs only the pages a map actually reads. (6.8.0)
final class PMTilesArchive: @unchecked Sendable {
    let header: PMTiles.Header
    let url: URL
    private let data: Data
    private let root: [PMTiles.Entry]
    private var leaves: [Int: [PMTiles.Entry]] = [:]
    private let lock = NSLock()

    init(url: URL) throws {
        let bytes = try Data(contentsOf: url, options: .alwaysMapped)
        let h = try PMTiles.Header(bytes)
        guard h.rootOffset + h.rootLength <= bytes.count else { throw PMTiles.Failure.badDirectory }
        root = try PMTiles.directory(PMTiles.inflate(bytes.subdata(in: h.rootOffset..<(h.rootOffset + h.rootLength)),
                                                     compression: h.internalCompression))
        header = h
        data = bytes
        self.url = url
    }

    /// The tile's stored bytes (gzip-compressed MVT, or a WebP for the relief), nil when the archive has none.
    func tile(z: Int, x: Int, y: Int) -> Data? {
        guard z >= header.minZoom, z <= header.maxZoom else { return nil }
        let id = PMTiles.tileID(z: z, x: x, y: y)
        var entries = root
        // The spec allows a leaf under a leaf; the build writes one level. Four is the format's practical ceiling.
        for _ in 0..<4 {
            guard let entry = PMTiles.find(entries, id) else { return nil }
            if entry.runLength > 0 {
                let start = header.tileDataOffset + entry.offset
                guard start + entry.length <= data.count else { return nil }
                return data.subdata(in: start..<(start + entry.length))
            }
            guard let leaf = try? leafDirectory(entry) else { return nil }
            entries = leaf
        }
        return nil
    }

    private func leafDirectory(_ entry: PMTiles.Entry) throws -> [PMTiles.Entry] {
        lock.lock(); defer { lock.unlock() }
        if let cached = leaves[entry.offset] { return cached }
        let start = header.leafOffset + entry.offset
        guard start + entry.length <= data.count else { throw PMTiles.Failure.badDirectory }
        let parsed = try PMTiles.directory(PMTiles.inflate(data.subdata(in: start..<(start + entry.length)),
                                                           compression: header.internalCompression))
        leaves[entry.offset] = parsed
        return parsed
    }
}

/// A PMTiles archive on tiles.aerocheck.app, read by HTTP ranges: the header and root directory in one read, the
/// leaf directories as needed, both kept on disk (directories are small and never count against the allowance),
/// then one range per tile, which the caller counts. (6.8.0)
///
/// The cache is keyed by the archive's ETag: a read that answers with another one (the monthly build replaced the
/// file) wipes it, and the read fails rather than mixing two builds' offsets.
final class PMTilesRemoteArchive: @unchecked Sendable {
    /// One HTTP read: the request (with its `Range`), answered with the body and the response.
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    enum Failure: Error, Equatable { case http(Int), changed, badRange }

    /// Where a tile lies in the archive; read it with `read(_:)`.
    struct Location: Equatable { let offset: Int; let length: Int }

    let url: URL
    private let cacheDirectory: URL
    private let fetch: Fetch
    private let headers: [String: String]
    private let lock = NSLock()
    private var state: (header: PMTiles.Header, root: [PMTiles.Entry], etag: String?)?
    private var leaves: [Int: [PMTiles.Entry]] = [:]

    init(url: URL, cacheDirectory: URL, headers: [String: String] = [:], fetch: @escaping Fetch) {
        self.url = url
        self.cacheDirectory = cacheDirectory
        self.headers = headers
        self.fetch = fetch
    }

    func header() async throws -> PMTiles.Header { try await opened().header }

    /// Where the tile lies, nil when the archive has none. Reads directories only.
    func locate(z: Int, x: Int, y: Int) async throws -> Location? {
        let open = try await opened()
        guard z >= open.header.minZoom, z <= open.header.maxZoom else { return nil }
        let id = PMTiles.tileID(z: z, x: x, y: y)
        var entries = open.root
        for _ in 0..<4 {
            guard let entry = PMTiles.find(entries, id) else { return nil }
            if entry.runLength > 0 {
                return Location(offset: open.header.tileDataOffset + entry.offset, length: entry.length)
            }
            entries = try await leafDirectory(entry, open: open)
        }
        return nil
    }

    /// The tile's stored bytes: one network read.
    func read(_ location: Location) async throws -> Data {
        let open = try await opened()
        return try await range(location.offset, location.length, etag: open.etag)
    }

    // MARK: Directories

    private func opened() async throws -> (header: PMTiles.Header, root: [PMTiles.Entry], etag: String?) {
        if let state = lock.withLock({ state }) { return state }
        let firstFile = cacheDirectory.appendingPathComponent("first.bin")
        let etagFile = cacheDirectory.appendingPathComponent("etag.txt")
        var first = try? Data(contentsOf: firstFile)
        var etag = try? String(contentsOf: etagFile, encoding: .utf8)
        if first == nil {
            let (bytes, response) = try await get(range: 0..<PMTiles.Header.firstRead)
            first = bytes
            etag = response.value(forHTTPHeaderField: "ETag")
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? bytes.write(to: firstFile, options: .atomic)
            if let etag { try? etag.write(to: etagFile, atomically: true, encoding: .utf8) }
        }
        guard let first else { throw PMTiles.Failure.notPMTiles }
        do {
            let header = try PMTiles.Header(first)
            guard header.rootOffset + header.rootLength <= first.count else { throw PMTiles.Failure.badDirectory }
            let root = try PMTiles.directory(PMTiles.inflate(first.subdata(in: header.rootOffset..<(header.rootOffset + header.rootLength)),
                                                             compression: header.internalCompression))
            let open = (header: header, root: root, etag: etag)
            lock.withLock { state = open }
            return open
        } catch {
            discard()
            throw error
        }
    }

    private func leafDirectory(_ entry: PMTiles.Entry,
                               open: (header: PMTiles.Header, root: [PMTiles.Entry], etag: String?)) async throws -> [PMTiles.Entry] {
        if let cached = lock.withLock({ leaves[entry.offset] }) { return cached }
        let file = cacheDirectory.appendingPathComponent("leaf-\(entry.offset)-\(entry.length).bin")
        let stored: Data
        if let onDisk = try? Data(contentsOf: file), onDisk.count == entry.length {
            stored = onDisk
        } else {
            stored = try await range(open.header.leafOffset + entry.offset, entry.length, etag: open.etag)
            try? stored.write(to: file, options: .atomic)
        }
        let parsed = try PMTiles.directory(PMTiles.inflate(stored, compression: open.header.internalCompression))
        lock.withLock { leaves[entry.offset] = parsed }
        return parsed
    }

    /// Forgets the cached directories: the next read starts from the header again.
    func discard() {
        lock.withLock { state = nil; leaves = [:] }
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    // MARK: HTTP

    private func range(_ offset: Int, _ length: Int, etag: String?) async throws -> Data {
        let (bytes, response) = try await get(range: offset..<(offset + length))
        if let etag, let answered = response.value(forHTTPHeaderField: "ETag"), answered != etag {
            discard()
            throw Failure.changed
        }
        guard bytes.count == length else { throw Failure.badRange }
        return bytes
    }

    private func get(range: Range<Int>) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await fetch(request)
        switch response.statusCode {
        case 206:
            return (data, response)
        case 200:
            // A server that ignores Range sends the whole file: keep the part asked for.
            guard range.lowerBound < data.count else { return (Data(), response) }
            return (data.subdata(in: range.lowerBound..<min(range.upperBound, data.count)), response)
        default:
            throw Failure.http(response.statusCode)
        }
    }
}
