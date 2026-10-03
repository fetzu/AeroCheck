import Foundation

// MARK: - Aerodrome search (6.1)
//
// What the aerodrome search looks in, folded once when it is first needed: each airport's ident, its
// other codes (IATA, GPS, local), then its name, municipality and OurAirports keywords, in lower case
// and without accents, back to back in ONE byte buffer. A keystroke is then a `memmem` over a few
// megabytes, where it used to lowercase four strings for each of the ~86'000 airports (a few hundred
// thousand allocations per keystroke) and still missed "Genève", "Neuchatel" or "Zürich" whenever the
// data spelt them otherwise. One buffer rather than a string per airport: about 5 MB for the whole
// world, without the per-string overhead that would double it.

/// The folding the index and the query share: lower case, no accents, every run of anything but
/// letters and digits a single space. "Genève", "GENEVE" and "geneve" fold alike; "La Chaux-de-Fonds"
/// folds to "la chaux de fonds", so a pilot needn't know where the hyphens go.
enum AirportSearchText {

    /// `text` folded, as a string (tests, and anything that compares folded words).
    static func folded(_ text: String) -> String {
        var folder = Folder()
        folder.appendWords(text)
        return String(decoding: folder.bytes, as: UTF8.self)
    }

    /// Appends folded words to a byte buffer, one space between words, none at the start of a record
    /// or a field. Remembers how each non-ASCII character folds: a world's worth of names has only a
    /// few hundred distinct ones, and Foundation's folding is the slow part.
    struct Folder {
        var bytes: [UInt8] = []
        private var cache: [Unicode.Scalar: [UInt8]] = [:]

        /// 0x20 between words, 0x01 opens a record, 0x02 separates its fields: none of them can be
        /// part of a folded word, so a word found in the buffer never straddles two fields.
        static let space: UInt8 = 0x20
        static let recordStart: UInt8 = 0x01
        static let fieldSeparator: UInt8 = 0x02

        static func isBoundary(_ byte: UInt8) -> Bool {
            byte == space || byte == recordStart || byte == fieldSeparator
        }

        mutating func append(marker: UInt8) { bytes.append(marker) }

        mutating func appendWords(_ text: String) {
            var pendingSpace = false
            // A field starts a new word even when the text doesn't start with a separator.
            if let last = bytes.last, !Self.isBoundary(last) { pendingSpace = true }
            for scalar in text.unicodeScalars {
                let value = scalar.value
                if value < 0x80 {
                    let byte = UInt8(value)
                    switch byte {
                    case 0x30...0x39, 0x61...0x7A: emit(byte, &pendingSpace)
                    case 0x41...0x5A: emit(byte + 0x20, &pendingSpace)
                    default: pendingSpace = true
                    }
                    continue
                }
                let folded: [UInt8]
                if let known = cache[scalar] {
                    folded = known
                } else {
                    folded = Self.fold(scalar)
                    cache[scalar] = folded
                }
                if folded.isEmpty { continue }                        // an accent written apart: part of its letter
                if folded == [Self.space] { pendingSpace = true; continue }
                for byte in folded { emit(byte, &pendingSpace) }
            }
        }

        private mutating func emit(_ byte: UInt8, _ pendingSpace: inout Bool) {
            if pendingSpace, let last = bytes.last, !Self.isBoundary(last) { bytes.append(Self.space) }
            pendingSpace = false
            bytes.append(byte)
        }

        /// Letters Foundation's folding leaves alone (they are letters of their own, not accented ones),
        /// spelt the way an English or French keyboard would type them.
        private static let spelledOut: [Unicode.Scalar: String] = [
            "æ": "ae", "œ": "oe", "ø": "o", "ł": "l", "đ": "d", "ð": "d", "þ": "th", "ı": "i", "ĳ": "ij",
        ]

        /// One non-ASCII character, folded: its bytes, nothing for a combining accent, a space for
        /// punctuation and symbols.
        private static func fold(_ scalar: Unicode.Scalar) -> [UInt8] {
            let properties = scalar.properties
            switch properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return []
            default: break
            }
            guard properties.isAlphabetic || properties.numericType != nil else { return [space] }
            let folded = String(scalar).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                                locale: Locale(identifier: "en_US_POSIX"))
            var result: [UInt8] = []
            for part in folded.unicodeScalars {
                if let spelled = spelledOut[part] {
                    result.append(contentsOf: spelled.utf8)
                } else if part.value < 0x80 {
                    let byte = UInt8(part.value)
                    switch byte {
                    case 0x30...0x39, 0x61...0x7A: result.append(byte)
                    case 0x41...0x5A: result.append(byte + 0x20)
                    default: break
                    }
                } else if part.properties.isAlphabetic || part.properties.numericType != nil {
                    result.append(contentsOf: String(part).utf8)
                }
            }
            return result.isEmpty ? [space] : result
        }
    }
}

/// Every airport's searchable text, folded once (`AirportSearchText`), and the search over it.
///
/// A query matches an airport when each of its words is found in the airport's text. The rank (`tier`)
/// says how it matched, best first: 0 the ident itself, 1 the start of the ident ("LSZ") or another
/// of its codes whole ("GVA"), 2 the start of a word for every word typed ("Bern", "Genf"), 3
/// anywhere ("ern"). Pure and `Sendable`: built off the main actor, read on it.
struct AirportSearchIndex: Sendable {

    struct Match: Equatable {
        /// The airport's position in the array the index was built from.
        let index: Int
        let tier: Int
    }

    /// One record per airport: 0x01, the ident, 0x02, its other codes, 0x02, its words.
    private let text: [UInt8]
    /// Where each record starts, and one more for the end of the last.
    private let starts: [Int32]

    /// How many airports the index covers: the array it was built from, at the time.
    var count: Int { starts.count - 1 }

    /// The buffer's size, for the log.
    var byteCount: Int { text.count + starts.count * MemoryLayout<Int32>.size }

    init(_ airports: [Airport], aliases: [AliasGroup] = AirportSearchIndex.aliases) {
        let aliasesByWord = Self.groupsByWord(aliases)
        let aliasCountries = Set(aliases.flatMap(\.countries))
        var folder = AirportSearchText.Folder()
        // Measured on the full OurAirports file: about 55 bytes an airport.
        folder.bytes.reserveCapacity(airports.count * 60)
        var starts: [Int32] = []
        starts.reserveCapacity(airports.count + 1)

        for airport in airports {
            starts.append(Int32(clamping: folder.bytes.count))
            folder.append(marker: AirportSearchText.Folder.recordStart)
            folder.appendWords(airport.ident)
            folder.append(marker: AirportSearchText.Folder.fieldSeparator)
            for code in [airport.iataCode, airport.gpsCode, airport.localCode]
            where code.map({ !$0.isEmpty && $0.caseInsensitiveCompare(airport.ident) != .orderedSame }) == true {
                folder.appendWords(code ?? "")
            }
            folder.append(marker: AirportSearchText.Folder.fieldSeparator)
            let wordsStart = folder.bytes.count
            folder.appendWords(airport.name)
            if let municipality = airport.municipality { folder.appendWords(municipality) }
            if let keywords = airport.keywords { folder.appendWords(keywords) }
            if aliasCountries.contains(airport.isoCountry) {
                let words = folder.bytes[wordsStart...].split(separator: AirportSearchText.Folder.space)
                    .map { String(decoding: $0, as: UTF8.self) }
                var added = Set(words)
                for word in words {
                    for group in aliasesByWord[word] ?? [] where group.countries.contains(airport.isoCountry) {
                        for name in group.names where added.insert(name).inserted {
                            folder.appendWords(name)
                        }
                    }
                }
            }
        }
        starts.append(Int32(clamping: folder.bytes.count))
        self.text = folder.bytes
        self.starts = starts
    }

    /// The airports matching `query`, in the order they were built, each with its rank. `include`
    /// is asked before the rank is worked out, so a type filter costs nothing for the airports it drops.
    func matches(_ query: String, where include: (Int) -> Bool = { _ in true }) -> [Match] {
        var folder = AirportSearchText.Folder()
        folder.appendWords(query)
        let whole = folder.bytes
        let words = whole.split(separator: AirportSearchText.Folder.space).map(Array.init)
        // The longest word narrows the most: the scan looks for it, the others are checked per airport.
        guard let lead = words.max(by: { $0.count < $1.count }), !lead.isEmpty, count > 0 else { return [] }
        let others = words.filter { $0 != lead }

        var result: [Match] = []
        text.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            var record = 0
            while offset < buffer.count,
                  let hit = Self.find(lead, in: base, from: offset, to: buffer.count) {
                // Hits come in order, so the record only ever moves forward.
                while Int(starts[record + 1]) <= hit { record += 1 }
                let end = Int(starts[record + 1])
                offset = end
                let start = Int(starts[record])
                guard include(record),
                      others.allSatisfy({ Self.find($0, in: base, from: start, to: end) != nil }) else { continue }
                result.append(Match(index: record,
                                    tier: Self.tier(whole: whole, words: words, in: base, record: start..<end)))
            }
        }
        return result
    }

    // MARK: Ranking

    private static func tier(whole: [UInt8], words: [[UInt8]], in base: UnsafePointer<UInt8>,
                             record: Range<Int>) -> Int {
        let identStart = record.lowerBound + 1
        var identEnd = identStart
        while identEnd < record.upperBound, base[identEnd] != AirportSearchText.Folder.fieldSeparator { identEnd += 1 }
        let ident = UnsafeBufferPointer(start: base + identStart, count: identEnd - identStart)
        if ident.elementsEqual(whole) { return 0 }

        // A code typed whole ("GVA") and an ident typed in part ("LSZ") are the same rank, and the
        // distance sorts them: "LSZ" is also Lošinj's IATA code, and nobody typing it in Porrentruy
        // means Croatia.
        if ident.starts(with: whole) { return 1 }
        var codesEnd = identEnd + 1
        while codesEnd < record.upperBound, base[codesEnd] != AirportSearchText.Folder.fieldSeparator { codesEnd += 1 }
        if identEnd + 1 < codesEnd {
            let codes = UnsafeBufferPointer(start: base + identEnd + 1, count: codesEnd - identEnd - 1)
            if codes.split(separator: AirportSearchText.Folder.space).contains(where: { $0.elementsEqual(whole) }) {
                return 1
            }
        }
        let atWordStarts = words.allSatisfy { word in
            var from = record.lowerBound
            while let hit = find(word, in: base, from: from, to: record.upperBound) {
                // A record opens with a marker, so a hit is never its first byte.
                if AirportSearchText.Folder.isBoundary(base[hit - 1]) { return true }
                from = hit + 1
            }
            return false
        }
        return atWordStarts ? 2 : 3
    }

    /// Where `needle` first appears in `base[from..<to]`, or nil.
    private static func find(_ needle: [UInt8], in base: UnsafePointer<UInt8>, from: Int, to: Int) -> Int? {
        guard to - from >= needle.count else { return nil }
        return needle.withUnsafeBufferPointer { pattern -> Int? in
            guard let hit = memmem(base + from, to - from, pattern.baseAddress, pattern.count) else { return nil }
            return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
        }
    }

    // MARK: Names in other languages

    /// One place, named differently by language. No data source carries these: OurAirports files
    /// Geneva under "Geneva" only, OpenAIP under "GENEVA", and a pilot from Lausanne types "Genève"
    /// (or "Genf", from Bern). An airport in one of `countries` whose name, municipality or keywords
    /// hold one of `names` (as a whole word) is found by all of them.
    struct AliasGroup: Sendable {
        let countries: Set<String>
        let names: [String]

        init(_ countries: Set<String>, _ names: [String]) {
            self.countries = countries
            self.names = names.map(AirportSearchText.folded)
        }
    }

    /// Kept to the market: Switzerland's cities with an aerodrome, and the neighbours' that are filed
    /// under one language of several. Scoped by country so "Genf" doesn't bring up Geneva, Illinois.
    /// A pilot who misses one is a row to add here.
    static let aliases: [AliasGroup] = [
        AliasGroup(["CH"], ["Geneva", "Genève", "Genf", "Ginevra"]),
        AliasGroup(["CH"], ["Zurich", "Zuerich", "Zurigo"]),
        AliasGroup(["CH"], ["Bern", "Berne", "Berna"]),
        AliasGroup(["CH"], ["Luzern", "Lucerne", "Lucerna"]),
        AliasGroup(["CH"], ["Biel", "Bienne"]),
        AliasGroup(["CH"], ["Sion", "Sitten"]),
        AliasGroup(["CH"], ["Neuchâtel", "Neuenburg"]),
        AliasGroup(["CH"], ["Grenchen", "Granges"]),
        AliasGroup(["CH"], ["Payerne", "Peterlingen"]),
        // The EuroAirport is in France.
        AliasGroup(["CH", "FR"], ["Basel", "Bâle", "Basle", "Basilea"]),
        AliasGroup(["FR"], ["Mulhouse", "Mülhausen"]),
        AliasGroup(["FR"], ["Strasbourg", "Strassburg", "Strasburgo"]),
        AliasGroup(["DE"], ["München", "Muenchen", "Munich"]),
        AliasGroup(["DE"], ["Konstanz", "Constance", "Costanza"]),
        AliasGroup(["AT"], ["Wien", "Vienna", "Vienne"]),
        AliasGroup(["IT"], ["Milano", "Milan", "Mailand"]),
        AliasGroup(["IT"], ["Torino", "Turin"]),
        AliasGroup(["IT"], ["Venezia", "Venice", "Venise", "Venedig"]),
    ]

    /// The other names of a folded word, whatever the country: for a search over data that is already
    /// confined to the market (the reporting points' aerodromes, in CH, FR, DE and AT).
    static func otherNames(of word: String) -> [String] { otherNamesByWord[word] ?? [] }

    private static let otherNamesByWord: [String: [String]] = groupsByWord(aliases).mapValues { groups in
        Array(Set(groups.flatMap(\.names)))
    }.reduce(into: [:]) { result, entry in
        result[entry.key] = entry.value.filter { $0 != entry.key }.sorted()
    }

    private static func groupsByWord(_ aliases: [AliasGroup]) -> [String: [AliasGroup]] {
        var result: [String: [AliasGroup]] = [:]
        for group in aliases {
            for name in group.names { result[name, default: []].append(group) }
        }
        return result
    }
}
