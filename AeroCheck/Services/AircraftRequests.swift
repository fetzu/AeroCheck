import Foundation

// MARK: - Aircraft requests from the app (6.3.0)
//
// A pilot or a club sends the checklist of an aircraft the app doesn't have yet, or a newer revision
// of one it has. Phase 1 (5 Oct 2026) is the website's form at aerocheck.app/send/ and the intake
// worker behind it (intake.aerocheck.app, AeroCheck-server's workers/intake, its routes in INTAKE.md).
// Phase 2 is this: the app speaks the website's protocol to the same worker.
//
//   GET  /v1/lookup?registration=   what the app has for a registration (known: an update)
//   POST /v1/requests               the form, with a Turnstile token → an upload slot per file
//   PUT  /v1/uploads/:id/:n?u=      each file, raw
//   POST /v1/requests/:id/complete  → the ticket, and the request's page with its token
//   GET  /v1/status/:token          where it stands
//
// The worker refuses a request without a Turnstile token; the app gets one from a small page of the
// website in a web view (`TurnstileCheckView`), the check the website's own form runs (author, 11 Oct).
//
// What the app keeps, on this device only: each request it sent (ticket, registrations, the status
// last read) in Application Support, and its status token, which opens the request's page, in the
// Keychain. The status is read when the app comes to the foreground, at most every few hours (author,
// 11 Oct: no background work); a request seen live for the first time calls `onLive`.

/// The intake's rules, as the worker and the website apply them: the app checks them first only to
/// spare the sender a round trip; the worker checks them all again.
enum AircraftRequestIntake {
    static let maxRegistrations = 10
    static let maxFiles = 4
    /// Decimal megabytes, as the website counts them: stricter than the worker's 10 MiB and 25 MiB,
    /// so a file accepted here is never refused there.
    static let maxFileBytes = 10_000_000
    static let maxTotalBytes = 25_000_000
    static let notesMax = 1000
    static let maxLanguages = 5
    static let aircraftTypeMax = 100
    static let clubMax = 120
    static let senderNameMax = 100
    /// The checklist languages offered as boxes, as the website does: Switzerland's three and English.
    static let commonLanguages = ["en", "fr", "de", "it"]

    /// Nationality marks a dash goes after (the worker's list, registration.ts), longest first. The
    /// US "N" and the Japanese "JA" are absent: those registrations are written without a dash.
    private static let prefixes: [String] = [
        "HB", "OE", "OO", "PH", "LX", "EC", "CS", "OK", "OM", "SP", "HA", "S5", "9A", "SE", "LN", "OY",
        "OH", "EI", "YR", "LZ", "SX", "YU", "ES", "YL", "LY", "TF", "ZS", "VH", "ZK", "TC", "UR", "4X",
        "9H", "5B", "E7", "Z3", "4O", "ZA", "T7", "3A",
        "D", "F", "G", "I", "M", "C",
    ].sorted { $0.count > $1.count }

    /// A registration as the worker spells it ("hb pfa" and "HBPFA" are "HB-PFA"; "N12345" keeps no
    /// dash), or nil when it can't be one.
    static func normalisedRegistration(_ raw: String) -> String? {
        var value = raw.uppercased().filter { !$0.isWhitespace }
        guard !value.isEmpty, value.count <= 9 else { return nil }
        if !value.contains("-"),
           let prefix = prefixes.first(where: { value.hasPrefix($0) && value.count > $0.count }) {
            value = prefix + "-" + value.dropFirst(prefix.count)
        }
        return value.range(of: #"^[A-Z0-9]{1,2}-?[A-Z0-9]{1,5}$"#, options: .regularExpression) != nil ? value : nil
    }

    /// The worker's address check (validate.ts): one @, a dot in the domain, nothing that breaks a
    /// header. The real check is that the e-mail arrives.
    static func isEmail(_ value: String) -> Bool {
        value.count <= 254
            && value.range(of: #"^[^\s@<>()",;:]+@[^\s@<>()",;:]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }

    /// One checklist language as the worker keeps it: letters, spaces and dashes, 2 to 35 characters.
    static func isLanguage(_ value: String) -> Bool {
        (2...35).contains(value.count)
            && value.range(of: #"^\p{L}[\p{L} -]*$"#, options: .regularExpression) != nil
    }

    /// The token at the end of a request's page ("https://aerocheck.app/request/#t=<token>").
    static func statusToken(in statusURL: String) -> String? {
        guard let range = statusURL.range(of: "#t=") else { return nil }
        let token = String(statusURL[range.upperBound...])
        return token.isEmpty ? nil : token
    }

    /// The request's page without its token, kept with the request (the token goes to the Keychain).
    static func statusPage(of statusURL: String) -> String {
        statusURL.components(separatedBy: "#").first ?? statusURL
    }

    /// The e-mails' and the request page's language: French in a French app, English otherwise. Not
    /// the checklist's, which is whatever the document is written in.
    static var locale: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true ? "fr" : "en"
    }

    // MARK: Endpoints

    /// The intake worker. It has no sandbox twin: TestFlight and the App Store send to the one the
    /// website uses. A DEBUG build can point at a local `wrangler dev` (`AEROCHECK_INTAKE_URL`).
    static var baseURL: URL {
        #if DEBUG
        if let local = localOverride("AEROCHECK_INTAKE_URL") { return local }
        #endif
        return URL(string: "https://intake.aerocheck.app")!
    }

    /// The website's page that runs the Turnstile check for the app and hands its token back. A
    /// DEBUG build can use a local preview of the website (`AEROCHECK_INTAKE_CHECK_URL`), which runs
    /// Cloudflare's test key.
    static func checkPageURL(locale: String) -> URL {
        var base = URL(string: "https://aerocheck.app/send/app/")!
        #if DEBUG
        if let local = localOverride("AEROCHECK_INTAKE_CHECK_URL") { base = local }
        #endif
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "lang", value: locale)]
        return components.url!
    }

    /// The hosts the check page may load: the website, Cloudflare's challenge, and the local preview
    /// in a DEBUG build.
    static var checkPageHosts: Set<String> {
        var hosts: Set<String> = ["aerocheck.app", "challenges.cloudflare.com"]
        #if DEBUG
        if let local = localOverride("AEROCHECK_INTAKE_CHECK_URL")?.host { hosts.insert(local) }
        #endif
        return hosts
    }

    #if DEBUG
    private static func localOverride(_ key: String) -> URL? {
        guard let raw = ProcessInfo.processInfo.environment[key], let url = URL(string: raw),
              url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else { return nil }
        return url
    }
    #endif

    static func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    /// An upload slot or completion path the worker gave ("/v1/uploads/…?u=…"), relative to the intake.
    static func url(relative path: String) -> URL? {
        URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}

// MARK: - What the worker answers

/// `GET /v1/lookup`: what the app has for a registration.
struct AircraftLookup: Decodable, Equatable {
    let registration: String
    let known: Bool
    let aircraftId: String?
    let modelName: String?
    let aeroclub: String?
    let version: String?
    let languages: [String]?

    init(registration: String, known: Bool, aircraftId: String? = nil, modelName: String? = nil,
         aeroclub: String? = nil, version: String? = nil, languages: [String]? = nil) {
        self.registration = registration
        self.known = known
        self.aircraftId = aircraftId
        self.modelName = modelName
        self.aeroclub = aeroclub
        self.version = version
        self.languages = languages
    }
}

enum AircraftRequestKind: String, Codable, Equatable {
    /// An aircraft the app doesn't have.
    case new
    /// A newer revision of one it has.
    case update
}

/// A request's status, the worker's statuses. Read from a string so a status a later worker adds
/// doesn't break the list: an unknown one is shown as "received".
enum AircraftRequestStatus: String, CaseIterable, Equatable {
    case uploading, received, accepted, converting, proofreading, testflight, live
    case needInfo = "need-info"
    case declined, duplicate

    init(worker: String) {
        self = AircraftRequestStatus(rawValue: worker) ?? .received
    }

    /// The issue is closed: nothing more will happen to it.
    var isClosed: Bool { self == .live || self == .declined || self == .duplicate }
}

/// `GET /v1/status/:token`, the fields the app reads.
struct AircraftRequestStatusView: Decodable, Equatable {
    struct Club: Decodable, Equatable {
        let name: String?
        let state: String
    }
    let ticket: String
    let status: String
    let updatedAt: String?
    let club: Club?
}

/// An error the intake answered (`{ "error": "<code>", "field"?: … }`, INTAKE.md lists the codes), or
/// no answer at all.
enum AircraftRequestError: Error, Equatable {
    /// No answer: offline, a timeout, the worker unreachable.
    case network
    /// The worker's code, the field it is about, and for `known_registration` the registrations
    /// already in the app; for a second completion, the ticket it already has.
    case intake(code: String, field: String?, registrations: [String], ticket: String?)
    /// A 2xx the app can't read.
    case unexpected

    var code: String {
        switch self {
        case .network: return "network"
        case .intake(let code, _, _, _): return code
        case .unexpected: return "unknown"
        }
    }

    var field: String? {
        if case .intake(_, let field, _, _) = self { return field }
        return nil
    }

    /// From an error answer: its JSON, or the status alone when the body isn't JSON.
    static func from(status: Int, body: Data) -> AircraftRequestError {
        struct Body: Decodable {
            let error: String?
            let field: String?
            let registrations: [String]?
            let ticket: String?
        }
        let decoded = try? JSONDecoder().decode(Body.self, from: body)
        let code = decoded?.error ?? (status == 429 ? "rate_limited" : status >= 500 ? "internal" : "unknown")
        return .intake(code: code, field: decoded?.field, registrations: decoded?.registrations ?? [],
                       ticket: decoded?.ticket)
    }
}

// MARK: - The files

/// One file of the checklist: a PDF (a scan becomes one), or a photo of its pages.
struct AircraftRequestFile: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case pdf, jpeg, png, heic

        var mimeType: String {
            switch self {
            case .pdf: return "application/pdf"
            case .jpeg: return "image/jpeg"
            case .png: return "image/png"
            case .heic: return "image/heic"
            }
        }

        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .jpeg: return "jpg"
            case .png: return "png"
            case .heic: return "heic"
            }
        }

        /// What the bytes are, read from their start as the worker reads it after the upload:
        /// `%PDF-`, `FF D8 FF`, `89 50 4E 47`, or `ftyp` at 4 followed by a HEIF brand.
        static func sniff(_ data: Data) -> Kind? {
            let head = [UInt8](data.prefix(16))
            if head.starts(with: Array("%PDF-".utf8)) { return .pdf }
            if head.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
            if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
            if head.count >= 12, Array(head[4..<8]) == Array("ftyp".utf8),
               let brand = String(bytes: head[8..<12], encoding: .ascii),
               ["heic", "heix", "mif1", "msf1"].contains(brand) { return .heic }
            return nil
        }
    }

    let id: UUID
    var name: String
    let data: Data
    let kind: Kind

    var size: Int { data.count }

    /// A file whose bytes are a PDF, JPEG, PNG or HEIC (whatever its name says), or nil. The name gets
    /// the extension of what it is when it has another.
    init?(name: String, data: Data) {
        guard let kind = Kind.sniff(data) else { return nil }
        self.id = UUID()
        self.kind = kind
        self.data = data
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.lowercased()
        let fits = ext == kind.fileExtension || (kind == .jpeg && ext == "jpeg") || (kind == .heic && ext == "heif")
        self.name = fits ? name : "\(base.isEmpty ? "checklist" : base).\(kind.fileExtension)"
    }
}

// MARK: - The form

/// What the sender fills in, the website's form field for field.
struct AircraftRequestForm: Equatable {
    enum SendingFor: String, Equatable {
        /// The sender looks after the club's documents, or the club asked them: no confirmation.
        case forClub = "club"
        /// A pilot of the aircraft: the club is asked to confirm.
        case asPilot = "self"
    }

    /// What stops the form from being sent, the website's field errors.
    enum Problem: Equatable {
        case registrationLookup
        case otherRegistrationsInvalid([String])
        case tooManyRegistrations
        case typeRequired
        case sendingForRequired
        case contactRequired
        case contactInvalid
        case contactIsSender
        case emailRequired
        case emailInvalid
        case languagesRequired
        case languageInvalid(String)
        case languagesTooMany
        case filesRequired
        case tooManyFiles
        /// A file over 10 MB: its name and size.
        case fileTooBig(String, Int)
        /// The files over 25 MB together: their size.
        case totalTooBig(Int)
        case notesTooLong
        case rightsRequired
        case privacyRequired
    }

    /// The registration as typed.
    var registration = ""
    /// The lookup's answer for `registration`: nil until it has been looked up.
    var lookup: AircraftLookup?
    /// A new aircraft's other registrations with the same checklist, separated by commas or spaces.
    var otherRegistrations = ""
    var aircraftType = ""
    var club = ""
    var sendingFor: SendingFor?
    var clubContactEmail = ""
    /// The pilot doesn't know the club's contact: the request waits for the club's OK until someone
    /// adds it from the request's page.
    var contactUnknown = false
    var senderName = ""
    var senderEmail = ""
    /// The boxes ticked, codes of `AircraftRequestIntake.commonLanguages`.
    var languages: [String] = []
    /// Any other language, typed; several separated by commas.
    var otherLanguages = ""
    var notes = ""
    var files: [AircraftRequestFile] = []
    var rights = false
    var privacy = false

    /// Update or new, once the registration has been looked up.
    var kind: AircraftRequestKind? { lookup.map { $0.known ? .update : .new } }

    /// Whether the lookup answered for what is typed now.
    var lookupIsCurrent: Bool {
        guard let lookup else { return false }
        return AircraftRequestIntake.normalisedRegistration(registration) == lookup.registration
    }

    private var trimmedClub: String { club.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Who sends it, as the worker takes it: a private aircraft (no club) is always the sender's own.
    var effectiveSendingFor: SendingFor? { trimmedClub.isEmpty ? .asPilot : sendingFor }

    /// The other registrations typed: the valid ones normalised (duplicates and the first one folded),
    /// the rest as typed. Commas, semicolons or lines between them, as on the website; spaces too
    /// between registrations written with their dash ("HB-KFI HB-KFO"), since "HB KFI" is one.
    var parsedOtherRegistrations: (valid: [String], invalid: [String]) {
        let first = lookup?.registration
        var found: [String] = []
        var invalid: [String] = []
        for part in otherRegistrations.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }) {
            let raw = part.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            let pieces = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            let dashed = pieces.compactMap { $0.contains("-") ? AircraftRequestIntake.normalisedRegistration($0) : nil }
            if pieces.count > 1, dashed.count == pieces.count {
                found += dashed
            } else if let registration = AircraftRequestIntake.normalisedRegistration(raw) {
                found.append(registration)
            } else {
                invalid.append(raw)
            }
        }
        var valid: [String] = []
        for registration in found where registration != first && !valid.contains(registration) { valid.append(registration) }
        return (valid, invalid)
    }

    /// Every registration the request is about.
    var registrations: [String] {
        guard let lookup else { return [] }
        return kind == .update ? [lookup.registration] : [lookup.registration] + parsedOtherRegistrations.valid
    }

    /// The languages to send: the boxes, then each typed one (a name the app knows as its code, as
    /// the website sends "ja" for "Japanese").
    var checklistLanguages: [String] {
        var list = AircraftRequestIntake.commonLanguages.filter(languages.contains)
        for typed in typedLanguages where !list.contains(typed) { list.append(typed) }
        return list
    }

    private var typedLanguages: [String] {
        otherLanguages.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .map { Self.languageCode(named: $0) ?? $0 }
    }

    /// "German", "allemand" or "de" → "de"; nil for a name no ISO 639-1 code has in English or the
    /// app's language.
    static func languageCode(named name: String) -> String? {
        let wanted = name.lowercased()
        if wanted.count == 2, Locale.LanguageCode(wanted).isISOLanguage { return wanted }
        let locales = [Locale(identifier: "en"), Locale(identifier: AircraftRequestIntake.locale)]
        for code in Locale.LanguageCode.isoLanguageCodes where code.identifier.count == 2 {
            for locale in locales where locale.localizedString(forLanguageCode: code.identifier)?.lowercased() == wanted {
                return code.identifier
            }
        }
        return nil
    }

    var totalBytes: Int { files.reduce(0) { $0 + $1.size } }

    /// What the website would point at before sending, in the form's order.
    var problems: [Problem] {
        var problems: [Problem] = []
        if !lookupIsCurrent { problems.append(.registrationLookup) }
        if kind == .new {
            let others = parsedOtherRegistrations
            if !others.invalid.isEmpty { problems.append(.otherRegistrationsInvalid(others.invalid)) }
            if registrations.count > AircraftRequestIntake.maxRegistrations { problems.append(.tooManyRegistrations) }
            if aircraftType.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 { problems.append(.typeRequired) }
        }
        if !trimmedClub.isEmpty, sendingFor == nil { problems.append(.sendingForRequired) }
        let email = senderEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedClub.isEmpty, sendingFor == .asPilot, !contactUnknown {
            let contact = clubContactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            if contact.isEmpty { problems.append(.contactRequired) }
            else if !AircraftRequestIntake.isEmail(contact) { problems.append(.contactInvalid) }
            else if contact.lowercased() == email.lowercased() { problems.append(.contactIsSender) }
        }
        if email.isEmpty { problems.append(.emailRequired) }
        else if !AircraftRequestIntake.isEmail(email) { problems.append(.emailInvalid) }
        let languages = checklistLanguages
        if languages.isEmpty { problems.append(.languagesRequired) }
        if let invalid = typedLanguages.first(where: { !AircraftRequestIntake.isLanguage($0) }) {
            problems.append(.languageInvalid(invalid))
        }
        if languages.count > AircraftRequestIntake.maxLanguages { problems.append(.languagesTooMany) }
        if files.isEmpty { problems.append(.filesRequired) }
        if files.count > AircraftRequestIntake.maxFiles { problems.append(.tooManyFiles) }
        for file in files where file.size > AircraftRequestIntake.maxFileBytes { problems.append(.fileTooBig(file.name, file.size)) }
        if totalBytes > AircraftRequestIntake.maxTotalBytes { problems.append(.totalTooBig(totalBytes)) }
        if notes.trimmingCharacters(in: .whitespacesAndNewlines).count > AircraftRequestIntake.notesMax {
            problems.append(.notesTooLong)
        }
        if !rights { problems.append(.rightsRequired) }
        if !privacy { problems.append(.privacyRequired) }
        return problems
    }

    /// The `POST /v1/requests` body, once the form has no problem left.
    func submission(turnstileToken: String, locale: String) -> AircraftRequestSubmission? {
        guard problems.isEmpty, let kind, let lookup, let sendingFor = effectiveSendingFor else { return nil }
        func text(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let contact = sendingFor == .asPilot && !trimmedClub.isEmpty && !contactUnknown ? text(clubContactEmail) : nil
        return AircraftRequestSubmission(
            kind: kind.rawValue,
            registrations: registrations,
            aircraftType: kind == .update ? (lookup.modelName ?? "") : aircraftType.trimmingCharacters(in: .whitespacesAndNewlines),
            club: text(club),
            sendingFor: sendingFor.rawValue,
            clubContactEmail: contact,
            senderName: text(senderName),
            senderEmail: senderEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            checklistLanguages: checklistLanguages,
            notes: text(notes),
            locale: locale,
            rights: true,
            privacy: true,
            files: files.map { .init(name: $0.name, size: $0.size, type: $0.kind.mimeType) },
            turnstileToken: turnstileToken)
    }
}

/// The `POST /v1/requests` body (INTAKE.md). Absent optionals are left out, as the website does.
struct AircraftRequestSubmission: Encodable, Equatable {
    struct File: Encodable, Equatable {
        let name: String
        let size: Int
        let type: String
    }
    let kind: String
    let registrations: [String]
    let aircraftType: String
    let club: String?
    let sendingFor: String
    let clubContactEmail: String?
    let senderName: String?
    let senderEmail: String
    let checklistLanguages: [String]
    let notes: String?
    let locale: String
    let rights: Bool
    let privacy: Bool
    let files: [File]
    let turnstileToken: String
}

/// A request created on the worker whose files are on their way: what the uploads and the completion
/// need. Kept by the sheet so a stopped upload goes on from the file it stopped at.
struct AircraftRequestUpload: Equatable {
    let requestId: String
    /// Each file's slot, in the order of the form's files.
    let slots: [URL]
    /// The one upload token of the request, which the completion carries too.
    let uploadToken: String
    let submission: AircraftRequestSubmission
}

// MARK: - The requests sent from this device

/// A request this device sent: enough to list it and to read its status.
struct SentAircraftRequest: Codable, Equatable, Identifiable {
    var id: String { ticket }
    let ticket: String
    let kind: AircraftRequestKind
    let registrations: [String]
    let aircraftType: String
    let sentAt: Date
    /// The request's page without its token ("https://aerocheck.app/request/"); the token is in the
    /// Keychain.
    let statusPage: String
    /// The worker's status, as last read.
    var status: String
    /// When the worker last changed the request (its `updatedAt`), or when it was sent.
    var changedAt: Date
    /// When the app last read the status.
    var checkedAt: Date?
    /// The live notice was given: once, the first time the app read `live`.
    var liveNoticed: Bool

    var currentStatus: AircraftRequestStatus { AircraftRequestStatus(worker: status) }
}

/// How the app talks to the intake. A seam for the tests; the app's goes through `ExternalRequest`
/// (and a plain upload task for the files, whose progress it reports).
protocol AircraftRequestTransport: Sendable {
    /// A request and its answer, whatever its status. `retries` for the reads only: a submission is
    /// never sent twice.
    func data(for request: URLRequest, retries: Int) async throws -> (Data, HTTPURLResponse)
    /// A file's PUT, with its progress (0...1).
    func upload(_ request: URLRequest, body: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionAircraftRequestTransport: AircraftRequestTransport {
    /// A file of 10 MB on a slow connection takes minutes: the shared session's 60 s would cut it.
    private static let uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": ExternalRequest.userAgent]
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    func data(for request: URLRequest, retries: Int) async throws -> (Data, HTTPURLResponse) {
        // The intake and nothing else, redirects included. The allow-list takes https only, which a
        // DEBUG build's local `wrangler dev` (http://localhost) isn't: that one goes without it.
        let base = AircraftRequestIntake.baseURL
        let hosts: Set<String>? = base.scheme == "https" ? Set([base.host].compactMap { $0 }) : nil
        return try await ExternalRequest.data(for: request, maxRetries: retries, maxResponseBytes: 1_000_000,
                                              allowedHosts: hosts)
    }

    func upload(_ request: URLRequest, body: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.uploadSession.upload(for: request, from: body,
                                                                   delegate: UploadProgress(report: progress))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let report: @Sendable (Double) -> Void
        init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        }
    }
}

/// The requests sent from this device, the calls to the intake, and the status check.
@MainActor
final class AircraftRequestStore: ObservableObject {
    static let shared = AircraftRequestStore()

    /// Newest first.
    @Published private(set) var requests: [SentAircraftRequest] = []

    /// A request read as live for the first time. The app posts the notice and fetches the aircraft
    /// list, so the new aircraft is there when the pilot opens the app.
    var onLive: ((SentAircraftRequest) -> Void)?

    /// How often an open request's status is read, at most, when the app comes to the foreground. A
    /// DEBUG build can shorten it (`AEROCHECK_REQUEST_CHECK_SECONDS`) for a check against a local intake.
    static var checkInterval: TimeInterval {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["AEROCHECK_REQUEST_CHECK_SECONDS"],
           let seconds = TimeInterval(raw) { return seconds }
        #endif
        return 3 * 60 * 60
    }
    /// How long a closed request stays in the list after it closed.
    static let keptAfterClosing: TimeInterval = 30 * 24 * 60 * 60

    private let fileURL: URL?
    private let keychain: KeychainStore
    private let transport: AircraftRequestTransport
    private var isRefreshing = false

    /// `fileURL` and `keychain` are injectable because the test host IS the app (TestDatastore.swift).
    init(fileURL: URL? = nil, keychain: KeychainStore = .app,
         transport: AircraftRequestTransport = URLSessionAircraftRequestTransport()) {
        self.fileURL = fileURL ?? DataPersistenceManager.shared.localAppDirectory
            .appendingPathComponent("aircraft-requests.json")
        self.keychain = keychain
        self.transport = transport
        load()
    }

    // MARK: Talking to the intake

    /// What the app has for a registration.
    func lookup(_ registration: String) async throws -> AircraftLookup {
        guard let normalised = AircraftRequestIntake.normalisedRegistration(registration) else {
            throw AircraftRequestError.intake(code: "invalid_registration", field: "registration", registrations: [], ticket: nil)
        }
        let url = AircraftRequestIntake.url("v1/lookup", query: [URLQueryItem(name: "registration", value: normalised)])
        return try await call(URLRequest(url: url), retries: 2, as: AircraftLookup.self)
    }

    /// The request itself: on success, a slot per file.
    func create(_ submission: AircraftRequestSubmission) async throws -> AircraftRequestUpload {
        struct Created: Decodable {
            struct Slot: Decodable { let n: Int; let url: String }
            let requestId: String
            let uploads: [Slot]
        }
        var request = URLRequest(url: AircraftRequestIntake.url("v1/requests"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(submission)
        let created = try await call(request, retries: 0, as: Created.self)
        let slots = created.uploads.sorted { $0.n < $1.n }.compactMap { AircraftRequestIntake.url(relative: $0.url) }
        guard slots.count == submission.files.count,
              let token = slots.first.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })?
                .queryItems?.first(where: { $0.name == "u" })?.value else {
            throw AircraftRequestError.unexpected
        }
        return AircraftRequestUpload(requestId: created.requestId, slots: slots, uploadToken: token, submission: submission)
    }

    /// One file into its slot.
    func upload(_ file: AircraftRequestFile, to slot: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: slot)
        request.httpMethod = "PUT"
        request.setValue(file.kind.mimeType, forHTTPHeaderField: "Content-Type")
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.upload(request, body: file.data, progress: progress)
        } catch {
            throw AircraftRequestError.network
        }
        guard (200...299).contains(response.statusCode) else {
            throw AircraftRequestError.from(status: response.statusCode, body: data)
        }
    }

    /// Every file in: the ticket, and the request joins the list (its token into the Keychain).
    @discardableResult
    func complete(_ upload: AircraftRequestUpload, now: Date = Date()) async throws -> SentAircraftRequest {
        struct Completed: Decodable { let ticket: String; let statusUrl: String }
        var components = URLComponents(url: AircraftRequestIntake.url("v1/requests/\(upload.requestId)/complete"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "u", value: upload.uploadToken)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let completed = try await call(request, retries: 0, as: Completed.self)
        let sent = SentAircraftRequest(
            ticket: completed.ticket,
            kind: AircraftRequestKind(rawValue: upload.submission.kind) ?? .new,
            registrations: upload.submission.registrations,
            aircraftType: upload.submission.aircraftType,
            sentAt: now,
            statusPage: AircraftRequestIntake.statusPage(of: completed.statusUrl),
            status: AircraftRequestStatus.received.rawValue,
            changedAt: now,
            checkedAt: now,
            liveNoticed: false)
        if let token = AircraftRequestIntake.statusToken(in: completed.statusUrl) {
            var tokens = storedTokens()
            tokens[sent.ticket] = token
            storeTokens(tokens)
        }
        requests.removeAll { $0.ticket == sent.ticket }
        requests.insert(sent, at: 0)
        save()
        return sent
    }

    /// The request's page, with its token: what the e-mail links to.
    func pageURL(of request: SentAircraftRequest) -> URL? {
        guard let token = storedTokens()[request.ticket] else { return URL(string: request.statusPage) }
        return URL(string: request.statusPage + "#t=" + token)
    }

    private func call<T: Decodable>(_ request: URLRequest, retries: Int, as type: T.Type) async throws -> T {
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.data(for: request, retries: retries)
        } catch {
            throw AircraftRequestError.network
        }
        guard (200...299).contains(response.statusCode) else {
            throw AircraftRequestError.from(status: response.statusCode, body: data)
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw AircraftRequestError.unexpected }
        return value
    }

    // MARK: The status

    /// The open requests' statuses, each at most every `checkInterval` unless `force`; closed requests
    /// past `keptAfterClosing` leave the list. Called when the app comes to the foreground.
    func refreshIfDue(now: Date = Date(), force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let before = requests.count
        requests.removeAll { $0.currentStatus.isClosed && now.timeIntervalSince($0.changedAt) > Self.keptAfterClosing }
        let removed = before != requests.count
        var changed = false
        for request in requests where !request.currentStatus.isClosed {
            if !force, let checked = request.checkedAt, now.timeIntervalSince(checked) < Self.checkInterval { continue }
            if await refresh(request.ticket, now: now) { changed = true }
        }
        if removed || changed {
            pruneTokens()
            save()
        }
    }

    /// Reads one request's status; true when anything was recorded.
    private func refresh(_ ticket: String, now: Date) async -> Bool {
        guard let token = storedTokens()[ticket] else { return false }
        let url = AircraftRequestIntake.url("v1/status/\(token)")
        let view: AircraftRequestStatusView
        do {
            view = try await call(URLRequest(url: url), retries: 1, as: AircraftRequestStatusView.self)
        } catch {
            // Offline, or the request purged (90 days after it closed): try again next time.
            AppLog.aircraftData.publicLine("Aircraft request status not read: \((error as? AircraftRequestError)?.code ?? "error")")
            return false
        }
        guard let index = requests.firstIndex(where: { $0.ticket == ticket }) else { return false }
        var request = requests[index]
        request.checkedAt = now
        if request.status != view.status {
            request.status = view.status
            request.changedAt = view.updatedAt.flatMap(Self.parseDate) ?? now
        }
        let noticeLive = request.currentStatus == .live && !request.liveNoticed
        if noticeLive { request.liveNoticed = true }
        requests[index] = request
        if noticeLive { onLive?(request) }
        return true
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Takes a request off the list (and its token off the Keychain). Its page stays open to the
    /// e-mail's link.
    func remove(_ request: SentAircraftRequest) {
        requests.removeAll { $0.ticket == request.ticket }
        pruneTokens()
        save()
    }

    // MARK: Storage

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        requests = (try? decoder.decode([SentAircraftRequest].self, from: data)) ?? []
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(requests).write(to: fileURL, options: DataPersistenceManager.protectedWriteOptions)
        } catch {
            AppLog.aircraftData.debugLine("Aircraft requests not saved: \(error.localizedDescription)")
        }
    }

    /// Ticket → status token, one Keychain item for all of them.
    private func storedTokens() -> [String: String] {
        guard let text = keychain.get(.aircraftRequestTokens), let data = text.data(using: .utf8),
              let tokens = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return tokens
    }

    private func storeTokens(_ tokens: [String: String]) {
        guard !tokens.isEmpty else {
            keychain.remove(.aircraftRequestTokens)
            return
        }
        guard let data = try? JSONEncoder().encode(tokens), let text = String(data: data, encoding: .utf8) else { return }
        keychain.set(text, for: .aircraftRequestTokens)
    }

    /// Drops the tokens of requests no longer listed.
    private func pruneTokens() {
        let tickets = Set(requests.map(\.ticket))
        let tokens = storedTokens()
        let kept = tokens.filter { tickets.contains($0.key) }
        if kept.count != tokens.count { storeTokens(kept) }
    }
}
