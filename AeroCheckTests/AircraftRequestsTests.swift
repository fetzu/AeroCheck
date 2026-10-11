import XCTest
@testable import AeroCheck

/// Aircraft requests sent from the app (6.3.0): the intake's rules as the app applies them, the form,
/// the protocol (lookup, request, uploads, completion) against a stand-in intake, the requests kept on
/// the device and their status check.
@MainActor
final class AircraftRequestsTests: XCTestCase {

    // MARK: - The intake's rules

    func testRegistrationsAreSpelledAsTheWorkerSpellsThem() {
        XCTAssertEqual(AircraftRequestIntake.normalisedRegistration("hb pfa"), "HB-PFA")
        XCTAssertEqual(AircraftRequestIntake.normalisedRegistration("HBPFA"), "HB-PFA")
        XCTAssertEqual(AircraftRequestIntake.normalisedRegistration("f-hvxa"), "F-HVXA")
        XCTAssertEqual(AircraftRequestIntake.normalisedRegistration("DEABC"), "D-EABC")
        XCTAssertEqual(AircraftRequestIntake.normalisedRegistration("N12345"), "N12345")
        XCTAssertNil(AircraftRequestIntake.normalisedRegistration("HB--PFA"))
        XCTAssertNil(AircraftRequestIntake.normalisedRegistration(""))
        XCTAssertNil(AircraftRequestIntake.normalisedRegistration("HB-PFAXYZ12"))
    }

    func testAddressesAndLanguagesFollowTheWorkersChecks() {
        XCTAssertTrue(AircraftRequestIntake.isEmail("jeanne@example.com"))
        XCTAssertFalse(AircraftRequestIntake.isEmail("jeanne@example"))
        XCTAssertFalse(AircraftRequestIntake.isEmail("jeanne example.com"))
        XCTAssertTrue(AircraftRequestIntake.isLanguage("de"))
        XCTAssertTrue(AircraftRequestIntake.isLanguage("Swiss German"))
        XCTAssertTrue(AircraftRequestIntake.isLanguage("it-CH"))
        XCTAssertFalse(AircraftRequestIntake.isLanguage("d"))
        XCTAssertFalse(AircraftRequestIntake.isLanguage("de2"))
    }

    func testTheRequestsPageSplitsIntoPageAndToken() {
        let link = "https://aerocheck.app/fr/request/#t=abc_DEF-123"
        XCTAssertEqual(AircraftRequestIntake.statusToken(in: link), "abc_DEF-123")
        XCTAssertEqual(AircraftRequestIntake.statusPage(of: link), "https://aerocheck.app/fr/request/")
        XCTAssertNil(AircraftRequestIntake.statusToken(in: "https://aerocheck.app/request/"))
    }

    func testTheCheckPageCarriesTheLanguage() {
        let url = AircraftRequestIntake.checkPageURL(locale: "fr")
        XCTAssertEqual(url.query, "lang=fr")
        XCTAssertTrue(AircraftRequestIntake.checkPageHosts.contains("challenges.cloudflare.com"))
    }

    // MARK: - Files

    func testAFileIsWhatItsBytesAre() {
        XCTAssertEqual(AircraftRequestFile(name: "card.pdf", data: Self.pdf)?.kind, .pdf)
        XCTAssertEqual(AircraftRequestFile(name: "p1.jpg", data: Self.jpeg)?.kind, .jpeg)
        XCTAssertEqual(AircraftRequestFile(name: "p1.png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]))?.kind, .png)
        let heic = Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8) + Data(repeating: 0, count: 8)
        XCTAssertEqual(AircraftRequestFile(name: "IMG_1.HEIC", data: heic)?.kind, .heic)
        XCTAssertNil(AircraftRequestFile(name: "notes.txt", data: Data("hello".utf8)))
    }

    func testAFileNamedForSomethingElseGetsTheRightExtension() {
        XCTAssertEqual(AircraftRequestFile(name: "scan.png", data: Self.jpeg)?.name, "scan.jpg")
        XCTAssertEqual(AircraftRequestFile(name: "photo.jpeg", data: Self.jpeg)?.name, "photo.jpeg")
        XCTAssertEqual(AircraftRequestFile(name: "", data: Self.pdf)?.name, "checklist.pdf")
    }

    // MARK: - The form

    func testAnEmptyFormSaysWhatIsMissing() {
        let problems = AircraftRequestForm().problems
        XCTAssertEqual(problems, [.registrationLookup, .emailRequired, .languagesRequired, .filesRequired,
                                  .rightsRequired, .privacyRequired])
    }

    func testANewAircraftIsSentWithItsOtherRegistrationsAndType() throws {
        var form = Self.newAircraftForm()
        form.otherRegistrations = "HB-KFI HB-KFO"
        XCTAssertEqual(form.parsedOtherRegistrations.valid, ["HB-KFI", "HB-KFO"], "dashed ones may be split by spaces")
        form.otherRegistrations = "hb kfi, HB-KFD; hbkfo"
        XCTAssertEqual(form.problems, [])
        let submission = try XCTUnwrap(form.submission(turnstileToken: "tok", locale: "fr"))
        XCTAssertEqual(submission.kind, "new")
        XCTAssertEqual(submission.registrations, ["HB-KFD", "HB-KFI", "HB-KFO"], "the first one once, the others normalised")
        XCTAssertEqual(submission.aircraftType, "Robin DR400/180")
        XCTAssertEqual(submission.sendingFor, "self", "a private aircraft is the sender's own")
        XCTAssertEqual(submission.locale, "fr")
        XCTAssertEqual(submission.files, [.init(name: "card.pdf", size: Self.pdf.count, type: "application/pdf")])

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(submission)) as? [String: Any])
        XCTAssertNil(json["club"], "absent fields are left out, as the website leaves them out")
        XCTAssertNil(json["clubContactEmail"])
        XCTAssertNil(json["notes"])
        XCTAssertEqual(json["rights"] as? Bool, true)
        XCTAssertEqual(json["turnstileToken"] as? String, "tok")
    }

    func testAnUpdateIsAboutTheOneRegistrationTheAppHas() throws {
        var form = Self.newAircraftForm()
        form.registration = "hb-pfa"
        form.lookup = AircraftLookup(registration: "HB-PFA", known: true, aircraftId: "pa28-181", modelName: "Piper Archer II",
                                     version: "2.0e", languages: ["en", "fr"])
        form.aircraftType = ""
        form.otherRegistrations = "HB-PFB"
        XCTAssertEqual(form.kind, .update)
        XCTAssertEqual(form.problems, [], "an update needs no type: the app's model name is sent")
        let submission = try XCTUnwrap(form.submission(turnstileToken: "tok", locale: "en"))
        XCTAssertEqual(submission.kind, "update")
        XCTAssertEqual(submission.registrations, ["HB-PFA"])
        XCTAssertEqual(submission.aircraftType, "Piper Archer II")
    }

    func testALookupForAnotherRegistrationMustBeDoneAgain() {
        var form = Self.newAircraftForm()
        form.registration = "HB-KFI"
        XCTAssertFalse(form.lookupIsCurrent)
        XCTAssertEqual(form.problems.first, .registrationLookup)
        XCTAssertNil(form.submission(turnstileToken: "tok", locale: "en"))
    }

    func testAPilotSendingForAClubGivesItsContactOrSaysTheyDontKnowIt() throws {
        var form = Self.newAircraftForm()
        form.club = "Aéroclub du Jura"
        XCTAssertEqual(form.problems, [.sendingForRequired])
        form.sendingFor = .asPilot
        XCTAssertEqual(form.problems, [.contactRequired])
        form.clubContactEmail = "JEANNE@example.com"
        XCTAssertEqual(form.problems, [.contactIsSender], "someone else at the club confirms")
        form.clubContactEmail = "board@club"
        XCTAssertEqual(form.problems, [.contactInvalid])
        form.clubContactEmail = "board@club.example"
        XCTAssertEqual(form.problems, [])
        var submission = try XCTUnwrap(form.submission(turnstileToken: "tok", locale: "en"))
        XCTAssertEqual(submission.sendingFor, "self")
        XCTAssertEqual(submission.club, "Aéroclub du Jura")
        XCTAssertEqual(submission.clubContactEmail, "board@club.example")

        form.contactUnknown = true
        submission = try XCTUnwrap(form.submission(turnstileToken: "tok", locale: "en"))
        XCTAssertNil(submission.clubContactEmail, "the request waits for the club's OK")

        form.sendingFor = .forClub
        form.contactUnknown = false
        form.clubContactEmail = ""
        submission = try XCTUnwrap(form.submission(turnstileToken: "tok", locale: "en"))
        XCTAssertEqual(submission.sendingFor, "club")
        XCTAssertNil(submission.clubContactEmail)
    }

    func testTypedLanguagesAreSentAsCodesWhenTheAppKnowsTheName() {
        var form = Self.newAircraftForm()
        form.languages = ["de", "en"]
        form.otherLanguages = "Japanese,  Swiss   German"
        XCTAssertEqual(form.checklistLanguages, ["en", "de", "ja", "Swiss German"])
        form.otherLanguages = "x9"
        XCTAssertEqual(form.problems, [.languageInvalid("x9")])
        form.otherLanguages = "es, pt, nl, sv"
        XCTAssertEqual(form.problems, [.languagesTooMany])
    }

    func testTheFilesLimitsAreTheWebsites() throws {
        var form = Self.newAircraftForm()
        let big = try XCTUnwrap(AircraftRequestFile(name: "big.pdf", data: Self.pdf + Data(count: 10_000_000)))
        form.files = [big]
        XCTAssertEqual(form.problems, [.fileTooBig("big.pdf", big.size)])
        let nine = try XCTUnwrap(AircraftRequestFile(name: "nine.pdf", data: Self.pdf + Data(count: 9_000_000)))
        form.files = [nine, nine, nine]
        XCTAssertEqual(form.problems, [.totalTooBig(3 * nine.size)])
        let small = try XCTUnwrap(AircraftRequestFile(name: "p.pdf", data: Self.pdf))
        form.files = Array(repeating: small, count: 5)
        XCTAssertEqual(form.problems, [.tooManyFiles])
    }

    // MARK: - Errors

    func testTheWorkersErrorsAreRead() {
        let body = Data(#"{"error":"known_registration","field":"registrations","registrations":["HB-PFA"]}"#.utf8)
        XCTAssertEqual(AircraftRequestError.from(status: 400, body: body),
                       .intake(code: "known_registration", field: "registrations", registrations: ["HB-PFA"], ticket: nil))
        XCTAssertEqual(AircraftRequestError.from(status: 503, body: Data("<html>".utf8)).code, "internal")
        XCTAssertEqual(AircraftRequestError.from(status: 429, body: Data()).code, "rate_limited")
        let again = Data(#"{"error":"wrong_state","ticket":"AC-2610-004"}"#.utf8)
        XCTAssertEqual(AircraftRequestError.from(status: 409, body: again),
                       .intake(code: "wrong_state", field: nil, registrations: [], ticket: "AC-2610-004"))
    }

    // MARK: - The protocol

    func testALookUpAsksTheIntakeForTheNormalisedRegistration() async throws {
        let intake = StandInIntake()
        intake.answer = { _ in (200, Data(#"{"registration":"HB-PFA","known":true,"modelName":"Piper Archer II","version":"2.0e"}"#.utf8)) }
        let store = makeStore(intake)
        let lookup = try await store.lookup("hb pfa")
        XCTAssertEqual(lookup.modelName, "Piper Archer II")
        XCTAssertEqual(intake.requests.first?.url?.path, "/v1/lookup")
        XCTAssertEqual(intake.requests.first?.url?.query, "registration=HB-PFA")
    }

    func testAnUnreadableRegistrationIsRefusedWithoutAsking() async {
        let intake = StandInIntake()
        let store = makeStore(intake)
        do {
            _ = try await store.lookup("HB--PFA")
            XCTFail("refused")
        } catch {
            XCTAssertEqual((error as? AircraftRequestError)?.code, "invalid_registration")
        }
        XCTAssertTrue(intake.requests.isEmpty)
    }

    func testARequestIsCreatedUploadedAndCompleted() async throws {
        let intake = StandInIntake()
        intake.answer = { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("POST", "/v1/requests"):
                return (201, Data(#"{"requestId":"r-1","uploads":[{"n":1,"url":"/v1/uploads/r-1/1?u=UPL"}]}"#.utf8))
            case ("POST", "/v1/requests/r-1/complete"):
                return (200, Data(#"{"ticket":"AC-2610-004","statusUrl":"https://aerocheck.app/request/#t=STATUS"}"#.utf8))
            default:
                return (404, Data(#"{"error":"not_found"}"#.utf8))
            }
        }
        let store = makeStore(intake)
        let form = Self.newAircraftForm()
        let submission = try XCTUnwrap(form.submission(turnstileToken: "tok", locale: "en"))

        let upload = try await store.create(submission)
        XCTAssertEqual(upload.requestId, "r-1")
        XCTAssertEqual(upload.uploadToken, "UPL")
        XCTAssertEqual(upload.slots.map(\.absoluteString), ["https://intake.aerocheck.app/v1/uploads/r-1/1?u=UPL"])
        let posted = try XCTUnwrap(intake.requests.first)
        XCTAssertEqual(posted.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(intake.retries.first, 0, "a submission is never sent twice")

        try await store.upload(form.files[0], to: upload.slots[0], progress: { _ in })
        XCTAssertEqual(intake.uploads.count, 1)
        XCTAssertEqual(intake.uploads.first?.request.httpMethod, "PUT")
        XCTAssertEqual(intake.uploads.first?.request.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
        XCTAssertEqual(intake.uploads.first?.body, Self.pdf)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sent = try await store.complete(upload, now: now)
        XCTAssertEqual(intake.requests.last?.url?.query, "u=UPL")
        XCTAssertEqual(sent.ticket, "AC-2610-004")
        XCTAssertEqual(sent.registrations, ["HB-KFD"])
        XCTAssertEqual(sent.currentStatus, .received)
        XCTAssertEqual(store.requests, [sent])
        XCTAssertEqual(store.pageURL(of: sent)?.absoluteString, "https://aerocheck.app/request/#t=STATUS")
        XCTAssertNil(sent.statusPage.range(of: "STATUS"), "the token stays out of the file")

        // A relaunch: the same file and Keychain.
        let again = AircraftRequestStore(fileURL: storeFile, keychain: keychain, transport: intake)
        XCTAssertEqual(again.requests, [sent])
        XCTAssertEqual(again.pageURL(of: sent)?.absoluteString, "https://aerocheck.app/request/#t=STATUS")
    }

    func testARefusedRequestSaysWhy() async throws {
        let intake = StandInIntake()
        intake.answer = { _ in (403, Data(#"{"error":"turnstile_failed","field":"turnstileToken"}"#.utf8)) }
        let store = makeStore(intake)
        let submission = try XCTUnwrap(Self.newAircraftForm().submission(turnstileToken: "tok", locale: "en"))
        do {
            _ = try await store.create(submission)
            XCTFail("refused")
        } catch {
            XCTAssertEqual(error as? AircraftRequestError,
                           .intake(code: "turnstile_failed", field: "turnstileToken", registrations: [], ticket: nil))
        }
    }

    func testNoAnswerIsANetworkError() async throws {
        let intake = StandInIntake()
        intake.fails = true
        let store = makeStore(intake)
        let submission = try XCTUnwrap(Self.newAircraftForm().submission(turnstileToken: "tok", locale: "en"))
        do {
            _ = try await store.create(submission)
            XCTFail("no answer")
        } catch {
            XCTAssertEqual(error as? AircraftRequestError, .network)
        }
    }

    // MARK: - The status check

    func testTheStatusIsReadOnlyWhenDueAndTheLiveNoticeComesOnce() async throws {
        let intake = StandInIntake()
        let store = try await sentStore(intake)
        var status = "accepted"
        intake.answer = { request in
            XCTAssertEqual(request.url?.path, "/v1/status/STATUS")
            return (200, Data(#"{"ticket":"AC-2610-004","status":"\#(status)","updatedAt":"2027-01-15T08:00:00.000Z","club":{"name":null,"state":"not-needed"}}"#.utf8))
        }
        var noticed: [String] = []
        store.onLive = { noticed.append($0.ticket) }
        let sentAt = try XCTUnwrap(store.requests.first?.sentAt)

        await store.refreshIfDue(now: sentAt.addingTimeInterval(60))
        XCTAssertEqual(intake.requests.count, 2, "read at the sending: not due a minute later")

        await store.refreshIfDue(now: sentAt.addingTimeInterval(AircraftRequestStore.checkInterval + 1))
        XCTAssertEqual(store.requests.first?.currentStatus, .accepted)
        XCTAssertEqual(store.requests.first?.changedAt, ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))

        status = "live"
        await store.refreshIfDue(now: sentAt.addingTimeInterval(1), force: true)
        XCTAssertEqual(store.requests.first?.currentStatus, .live)
        XCTAssertEqual(noticed, ["AC-2610-004"])

        let reads = intake.requests.count
        await store.refreshIfDue(now: sentAt.addingTimeInterval(10 * AircraftRequestStore.checkInterval), force: true)
        XCTAssertEqual(intake.requests.count, reads, "a closed request isn't read again")
        XCTAssertEqual(noticed, ["AC-2610-004"], "once")
    }

    func testAClosedRequestLeavesTheListAMonthLaterWithItsToken() async throws {
        let intake = StandInIntake()
        let store = try await sentStore(intake)
        intake.answer = { _ in (200, Data(#"{"ticket":"AC-2610-004","status":"declined","updatedAt":"2027-01-15T08:00:00Z"}"#.utf8)) }
        await store.refreshIfDue(now: Date(), force: true)
        let closedAt = try XCTUnwrap(store.requests.first?.changedAt)

        await store.refreshIfDue(now: closedAt.addingTimeInterval(AircraftRequestStore.keptAfterClosing - 60))
        XCTAssertEqual(store.requests.count, 1)
        await store.refreshIfDue(now: closedAt.addingTimeInterval(AircraftRequestStore.keptAfterClosing + 60))
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertNil(keychain.get(.aircraftRequestTokens), "its token goes with it")
    }

    func testAStatusThatCantBeReadIsTriedAgainLater() async throws {
        let intake = StandInIntake()
        let store = try await sentStore(intake)
        intake.answer = { _ in (404, Data(#"{"error":"not_found"}"#.utf8)) }
        let before = store.requests
        await store.refreshIfDue(now: Date(), force: true)
        XCTAssertEqual(store.requests, before, "nothing recorded, not even the time it was tried")
    }

    func testRemovingARequestDropsItsToken() async throws {
        let intake = StandInIntake()
        let store = try await sentStore(intake)
        store.remove(try XCTUnwrap(store.requests.first))
        XCTAssertTrue(store.requests.isEmpty)
        XCTAssertNil(keychain.get(.aircraftRequestTokens))
    }

    // MARK: - Helpers

    private var keychain: KeychainStore!
    private var storeFile: URL!

    private func makeStore(_ intake: StandInIntake) -> AircraftRequestStore {
        keychain = makeTestKeychain()
        storeFile = makeTestDirectory().appendingPathComponent("aircraft-requests.json")
        try? FileManager.default.createDirectory(at: storeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        return AircraftRequestStore(fileURL: storeFile, keychain: keychain, transport: intake)
    }

    /// A store with one request sent (AC-2610-004, status token STATUS).
    private func sentStore(_ intake: StandInIntake) async throws -> AircraftRequestStore {
        intake.answer = { request in
            request.url?.path == "/v1/requests"
                ? (201, Data(#"{"requestId":"r-1","uploads":[{"n":1,"url":"/v1/uploads/r-1/1?u=UPL"}]}"#.utf8))
                : (200, Data(#"{"ticket":"AC-2610-004","statusUrl":"https://aerocheck.app/request/#t=STATUS"}"#.utf8))
        }
        let store = makeStore(intake)
        let submission = try XCTUnwrap(Self.newAircraftForm().submission(turnstileToken: "tok", locale: "en"))
        let upload = try await store.create(submission)
        try await store.complete(upload, now: Date(timeIntervalSince1970: 1_800_000_000))
        return store
    }

    static let pdf = Data("%PDF-1.7\n%âãÏÓ\n".utf8)
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

    /// A new aircraft, private, ready to send.
    static func newAircraftForm() -> AircraftRequestForm {
        var form = AircraftRequestForm()
        form.registration = "hb kfd"
        form.lookup = AircraftLookup(registration: "HB-KFD", known: false)
        form.aircraftType = "  Robin DR400/180 "
        form.senderEmail = "jeanne@example.com"
        form.languages = ["fr"]
        form.files = [AircraftRequestFile(name: "card.pdf", data: pdf)!]
        form.rights = true
        form.privacy = true
        return form
    }
}

/// The intake, answering from a closure and keeping what it was sent.
private final class StandInIntake: AircraftRequestTransport, @unchecked Sendable {
    var answer: (URLRequest) -> (Int, Data) = { _ in (404, Data()) }
    var fails = false
    private(set) var requests: [URLRequest] = []
    private(set) var retries: [Int] = []
    private(set) var uploads: [(request: URLRequest, body: Data)] = []

    func data(for request: URLRequest, retries: Int) async throws -> (Data, HTTPURLResponse) {
        if fails { throw URLError(.notConnectedToInternet) }
        requests.append(request)
        self.retries.append(retries)
        return respond(request)
    }

    func upload(_ request: URLRequest, body: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, HTTPURLResponse) {
        if fails { throw URLError(.notConnectedToInternet) }
        uploads.append((request, body))
        progress(1)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
    }

    private func respond(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let (status, body) = answer(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
