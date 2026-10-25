import CoreLocation
import Foundation

/// A pilot's own note on an aerodrome: how to fly in (`arrival`), and what to know once there
/// (`onTheGround`: parking, fuel, food, contacts). On the device and in the pilot's iCloud Drive only,
/// never sent anywhere else. (6.7.0, the author's answers n1 to n7)
///
/// A note keeps the aerodrome's identifier, name and position as written, so it still finds its field
/// when the data renames it (an OurAirports "CH-0002" given its ICAO code later). The Cockpit reads
/// `arrival` only; `onTheGround` belongs to the ground screens.
struct AerodromeNote: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    /// The aerodrome's identifier when the note was written: its ICAO code, or OurAirports' own.
    var ident: String
    var name: String
    var latitude: Double
    var longitude: Double
    var arrival: String
    var onTheGround: String
    var createdAt: Date
    /// The content stamp: the deletion records and the merge of two copies read it.
    var updatedAt: Date
    /// The kind of device it was last changed on ("iPad", "iPhone"), never its name.
    var editedOn: String?

    init(id: UUID = UUID(), ident: String, name: String, latitude: Double, longitude: Double,
         arrival: String = "", onTheGround: String = "", createdAt: Date = Date(), updatedAt: Date = Date(),
         editedOn: String? = nil) {
        self.id = id
        self.ident = ident
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.arrival = arrival
        self.onTheGround = onTheGround
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.editedOn = editedOn
    }

    /// Every field but the id and identifier has a default, so a note a later build writes with
    /// fewer or more fields still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        ident = try c.decode(String.self, forKey: .ident)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ident
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude) ?? 0
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude) ?? 0
        arrival = try c.decodeIfPresent(String.self, forKey: .arrival) ?? ""
        onTheGround = try c.decodeIfPresent(String.self, forKey: .onTheGround) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        editedOn = try c.decodeIfPresent(String.self, forKey: .editedOn)
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    /// Nothing written in either part: such a note is deleted rather than kept.
    var isEmpty: Bool { Self.trimmed(arrival).isEmpty && Self.trimmed(onTheGround).isEmpty }

    var hasArrival: Bool { !Self.trimmed(arrival).isEmpty }

    /// The first line of the arrival part, else of the other: what a callout or a list row shows.
    var firstLine: String {
        let text = hasArrival ? arrival : onTheGround
        return Self.trimmed(text).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    enum Part: Equatable, Sendable { case arrival, onTheGround }

    /// The line that holds `query` and the part it is in, the arrival part's first: what the search
    /// shows under a field its note was found by, so a match on the ground part never shows the
    /// arrival's first line (the author's device check n-6). Nil when only the code or name holds it.
    /// A match far into a long line starts the line a little before it, after "…".
    func line(matching query: String) -> (part: Part, line: String)? {
        let q = AerodromeNoteMatch.folded(query)
        guard !q.isEmpty else { return nil }
        for (part, text) in [(Part.arrival, arrival), (.onTheGround, onTheGround)] {
            for line in Self.trimmed(text).split(whereSeparator: \.isNewline) {
                let folded = AerodromeNoteMatch.folded(String(line))
                guard let hit = folded.range(of: q) else { continue }
                let trimmed = Self.trimmed(String(line))
                let offset = folded.distance(from: folded.startIndex, to: hit.lowerBound)
                guard offset > Self.snippetLead, folded.count == trimmed.count else { return (part, trimmed) }
                let from = trimmed.index(trimmed.startIndex, offsetBy: offset - Self.snippetLead)
                let cut = trimmed[from...].firstIndex(of: " ").map { trimmed.index(after: $0) } ?? from
                return (part, "…" + trimmed[cut...])
            }
        }
        return nil
    }

    /// How much of a long line is kept before the words searched for.
    static let snippetLead = 24
}

// MARK: - Which aerodrome a note is on

/// The aerodrome a note is written for, wherever it comes from: an `Airport` of the data, or a
/// route's waypoint that names one.
struct AerodromeRef: Equatable, Sendable {
    var ident: String
    var name: String
    var latitude: Double
    var longitude: Double
    /// The other codes the same field goes by in the data (its GPS code, its local code).
    var otherIdents: [String] = []

    init(ident: String, name: String, latitude: Double, longitude: Double, otherIdents: [String] = []) {
        self.ident = ident
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.otherIdents = otherIdents
    }

    init(_ airport: Airport) {
        self.init(ident: airport.ident, name: airport.name, latitude: airport.latitude, longitude: airport.longitude,
                  otherIdents: [airport.gpsCode, airport.localCode].compactMap { $0 }.filter { !$0.isEmpty })
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

enum AerodromeNoteMatch {
    /// How far a note may be from the aerodrome and still be its own when only the name agrees: the
    /// same field moved in the data, never the next one along the valley.
    static let sameFieldMeters: CLLocationDistance = 1_000

    /// Whether `note` is the note on `ref`: the same identifier (any of the field's codes), else the
    /// same name within a kilometre. Names compare without case or accents ("Écuvillens").
    static func matches(_ note: AerodromeNote, _ ref: AerodromeRef) -> Bool {
        let idents = Set(([ref.ident] + ref.otherIdents).map { $0.uppercased() })
        if idents.contains(note.ident.uppercased()) { return true }
        guard folded(note.name) == folded(ref.name), !folded(ref.name).isEmpty else { return false }
        return distance(note.coordinate, ref.coordinate) <= sameFieldMeters
    }

    static func folded(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

// MARK: - Two copies of one aerodrome's note

enum AerodromeNoteMerge {
    /// What collapsing the notes found: the notes to keep (one per aerodrome), the kept ones that took
    /// text from another and must be written again, and the copies folded into them, whose files go.
    struct Result: Equatable {
        var kept: [AerodromeNote]
        var rewritten: [AerodromeNote]
        var folded: [AerodromeNote]
    }

    /// One note per aerodrome. Two devices can each write a note on the same field before iCloud
    /// brings them together. The newer note is kept, and any text of the older one it doesn't
    /// already hold is added under its own, so nothing the pilot wrote is lost. Notes of different
    /// identifiers are never folded together, however close.
    static func collapse(_ notes: [AerodromeNote]) -> Result {
        var byIdent: [String: [AerodromeNote]] = [:]
        var order: [String] = []
        for note in notes {
            let key = note.ident.uppercased()
            if byIdent[key] == nil { order.append(key) }
            byIdent[key, default: []].append(note)
        }
        var result = Result(kept: [], rewritten: [], folded: [])
        for key in order {
            let group = byIdent[key]!.sorted { $0.updatedAt > $1.updatedAt }
            guard var newest = group.first else { continue }
            guard group.count > 1 else {
                result.kept.append(newest)
                continue
            }
            for older in group.dropFirst() {
                newest.arrival = joined(newest.arrival, older.arrival)
                newest.onTheGround = joined(newest.onTheGround, older.onTheGround)
                newest.createdAt = min(newest.createdAt, older.createdAt)
                result.folded.append(older)
            }
            result.kept.append(newest)
            result.rewritten.append(newest)
        }
        return result
    }

    /// `kept`, with `other` under it when `kept` doesn't already hold it.
    static func joined(_ kept: String, _ other: String) -> String {
        let extra = AerodromeNote.trimmed(other)
        guard !extra.isEmpty, !kept.contains(extra) else { return kept }
        let base = AerodromeNote.trimmed(kept)
        return base.isEmpty ? extra : base + "\n\n" + extra
    }
}

// MARK: - The notes as one text file

enum AerodromeNoteExport {
    /// Every note by aerodrome, in identifier order: "## LSZG Grenchen", then each part under its
    /// "### " title. Plain text with Markdown's headings, so it reads anywhere it is shared to and
    /// the aerodromes, the parts and the notes stand apart (the author's device check n-9).
    static func text(_ notes: [AerodromeNote], arrivalTitle: String, groundTitle: String, header: String) -> String {
        var lines = ["# " + header, ""]
        for note in notes.sorted(by: { ($0.ident, $0.name) < ($1.ident, $1.name) }) where !note.isEmpty {
            lines.append("## \(note.ident) \(note.name)")
            lines.append("")
            if note.hasArrival {
                lines.append("### " + arrivalTitle)
                lines.append(AerodromeNote.trimmed(note.arrival))
                lines.append("")
            }
            if !AerodromeNote.trimmed(note.onTheGround).isEmpty {
                lines.append("### " + groundTitle)
                lines.append(AerodromeNote.trimmed(note.onTheGround))
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }
}
